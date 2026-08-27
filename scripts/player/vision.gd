extends Node2D
## Vision · 扇形视野 + 墙体遮断
##
## 实现路径（选型理由）：用 Godot 原生 2D 光照做遮蔽，而不是自己画多边形。
##   - PointLight2D + LightOccluder2D → 墙体阴影由引擎硬件加速计算，性能好、边缘干净
##   - 扇形通过**程序化生成的锥形光照贴图**实现，参数改动实时重建贴图
##   - 场景整体由 CanvasModulate 压暗，光照区域恢复全亮
##
## 两级可见性（关键设计取舍）：
##   - **静态地形**（墙/地板）→ 压暗常亮，玩家永远看得见路（否则纯 2D 俯视全黑是折磨而非博弈）
##   - **动态实体**（其他玩家/敌人/容器内物品）→ 严格只在扇形内且无遮挡时可见
##   即"地形记忆"与"实时情报"分离。【小皮设定，待大锤确认】

const TEX_SIZE := 384
const BLOCKER_MASK := 1 << 3   ## 物理层 4 = vision_blocker（地面 POI）
const SHIP_BLOCKER_MASK := 1 << 6  ## 物理层 7 = 舰内墙
const GROUND_OCC_MASK := 1
const SHIP_OCC_MASK := 2
## 贴图重建防抖：拖动滑条时避免每帧重建（GDScript 逐像素循环较慢）
const REBUILD_DEBOUNCE := 0.12

var _light: PointLight2D
var _tex_key := ""
var _pending_key := ""
var _debounce := 0.0
var _debug_draw := false
var _gate_cd := 0.0
const GATE_INTERVAL := 0.18

func _ready() -> void:
	_light = PointLight2D.new()
	_light.shadow_enabled = true
	_light.shadow_filter = Light2D.SHADOW_FILTER_PCF13
	_light.shadow_filter_smooth = 2.0
	# MIX 而非 ADD：ADD 是在压暗后的画面上叠加，亮度上不去且容易灰蒙蒙；
	# MIX 直接以光照色替换，配合 energy 能把视野内还原到接近原始亮度。
	_light.blend_mode = Light2D.BLEND_MODE_MIX
	_light.range_layer_min = -512
	_light.range_layer_max = 512
	_light.range_z_min = -4096
	_light.range_z_max = 4096
	add_child(_light)
	set_notify_transform(true)

func _process(delta: float) -> void:
	var p = get_parent()   # 无类型：需访问脚本自定义方法，强类型会编译报错
	if p == null:
		return
	_light.visible = Tuning.enable_vision_cone
	_light.shadow_enabled = Tuning.enable_wall_occlusion
	var aboard: bool = p.get("aboard_ship") != null and p.aboard_ship != null
	_light.shadow_item_cull_mask = SHIP_OCC_MASK if aboard else GROUND_OCC_MASK
	_rebuild_if_needed(p, delta)
	_gate_dynamic_entities(p)
	if Tuning.show_debug_overlay != _debug_draw:
		_debug_draw = Tuning.show_debug_overlay
		queue_redraw()
	if _debug_draw:
		queue_redraw()

# ── 锥形光照贴图 ────────────────────────────────────────
func _rebuild_if_needed(p, delta: float) -> void:
	var rng: float = p.vision_range()
	var half: float = p.vision_half_angle_deg()
	var key := "%.0f_%.0f_%.0f_%.0f" % [rng, half, Tuning.vision_edge_feather, Tuning.proximity_radius]
	# texture_scale 把 TEX_SIZE 像素的贴图映射到直径 = 2×视距
	_light.texture_scale = (rng * 2.0) / float(TEX_SIZE)
	# 亮度关系（踩过两次坑，记录清楚）：
	#   CanvasModulate 把全场乘到 terrain_memory_brightness（默认 0.30）= 视野外的"地形记忆"层。
	#   PointLight2D 用 MIX 混合把视野内还原。
	# **energy 必须固定 1.0**：MIX 下 energy>1 会把像素直接推向纯白（过曝），
	# 试过 1/b（≈3.3）和部分补偿（1.9）都是白片。视野内外的差异靠
	# CanvasModulate 的压暗量本身表达，不需要额外增益。
	_light.energy = 1.0
	if key == _tex_key:
		return
	# 首帧立即构建，避免开局 0.12 秒全黑
	if _tex_key == "":
		_tex_key = key
		_pending_key = key
		_light.texture = _make_cone_texture(rng, half)
		return
	if key != _pending_key:
		_pending_key = key
		_debounce = REBUILD_DEBOUNCE
		return
	_debounce -= delta
	if _debounce > 0.0:
		return
	_tex_key = key
	_light.texture = _make_cone_texture(rng, half)

func _make_cone_texture(rng: float, half_deg: float) -> ImageTexture:
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := TEX_SIZE * 0.5
	var half_rad := deg_to_rad(half_deg)
	# 边缘羽化：把像素宽度换算成角度，保证远处也有柔和过渡
	var feather_rad := deg_to_rad(clampf(rad_to_deg(Tuning.vision_edge_feather / maxf(rng, 1.0)), 1.0, 40.0))
	var prox_norm := Tuning.proximity_radius / maxf(rng, 1.0) * c

	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var dx := x - c
			var dy := y - c
			var dist := sqrt(dx * dx + dy * dy)
			if dist > c:
				continue
			# 径向衰减：中段保持全亮，末端 22% 渐隐，避免"亮度墙"
			var rn := dist / c
			var radial: float = 1.0 if rn < 0.78 else smoothstep(1.0, 0.78, rn)

			# 角度衰减（贴图朝 +X，光源随节点 rotation 旋转）
			var ang: float = absf(atan2(dy, dx))
			var angular := 0.0
			if ang <= half_rad:
				angular = 1.0
			elif ang <= half_rad + feather_rad:
				angular = smoothstep(half_rad + feather_rad, half_rad, ang)

			# 近身圆形视野（不受扇形限制，360° 点亮一圈，消除身后盲区）
			var prox := 0.0
			var prox_r := minf(prox_norm, c * 0.98)   # 防止超出贴图被裁成方形
			if prox_r > 1.0 and dist <= prox_r:
				prox = smoothstep(prox_r, prox_r * 0.4, dist)

			var a: float = clampf(maxf(angular * radial, prox), 0.0, 1.0)
			if a > 0.0:
				img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)

# ── 动态实体可见性 ──────────────────────────────────────
func _gate_dynamic_entities(p) -> void:
	# 节流：全图容器/怪物每帧射线会拖死帧率
	_gate_cd -= get_process_delta_time()
	if _gate_cd > 0.0:
		return
	_gate_cd = GATE_INTERVAL
	if not Tuning.enable_vision_cone:
		for n in get_tree().get_nodes_in_group("vision_gated"):
			if n.has_method("set_perceived"):
				n.set_perceived(true)
		return
	var origin: Vector2 = p.global_position
	var vr2: float = p.vision_range() * p.vision_range()
	for n in get_tree().get_nodes_in_group("vision_gated"):
		if n == p or not n.has_method("set_perceived"):
			continue
		# 粗筛距离，远处直接不可见，省射线
		var d2: float = origin.distance_squared_to(n.global_position)
		if d2 > vr2 * 1.15:
			n.set_perceived(false)
			continue
		n.set_perceived(is_point_visible(n.global_position, p))

## 目标点是否在视野扇形内且未被墙遮挡
func is_point_visible(target: Vector2, p = null) -> bool:
	if p == null:
		p = get_parent()
	var origin: Vector2 = p.global_position
	var to: Vector2 = target - origin
	var dist: float = to.length()
	if dist <= Tuning.proximity_radius:
		return true
	if dist > p.vision_range():
		return false
	var ang: float = rad_to_deg(absf(p.aim_dir.angle_to(to)))
	if ang > p.vision_half_angle_deg():
		return false
	if not Tuning.enable_wall_occlusion:
		return true
	var space := get_world_2d().direct_space_state
	# 射线停在目标体表，避免贴墙时中心点埋进墙/掩体而被误判遮挡
	var stop: Vector2 = target
	if dist > 12.0:
		stop = origin + to * ((dist - 10.0) / dist)
	var q := PhysicsRayQueryParameters2D.create(origin, stop)
	q.collision_mask = SHIP_BLOCKER_MASK if p.get("aboard_ship") != null and p.aboard_ship != null else BLOCKER_MASK
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	# 擦到目标自己贴着的那面墙，不算被挡住
	return hit.position.distance_to(target) <= 16.0

# ── 调试可视化 ──────────────────────────────────────────
func _draw() -> void:
	if not _debug_draw:
		return
	var p = get_parent()
	if p == null:
		return
	var rng: float = p.vision_range()
	var half := deg_to_rad(p.vision_half_angle_deg())
	var pts := PackedVector2Array([Vector2.ZERO])
	var steps := maxi(8, Tuning.vision_ray_count / 4)
	for i in steps + 1:
		var a := -half + (2.0 * half) * (float(i) / steps)
		pts.append(Vector2.RIGHT.rotated(a) * rng)
	draw_polyline(pts, Color(0.2, 0.9, 1.0, 0.45), 1.5)
	draw_arc(Vector2.ZERO, Tuning.interact_range, 0, TAU, 32, Color(1.0, 0.8, 0.2, 0.5), 1.0)
	if Tuning.proximity_radius > 1.0:
		draw_arc(Vector2.ZERO, Tuning.proximity_radius, 0, TAU, 32, Color(0.4, 1.0, 0.6, 0.35), 1.0)
