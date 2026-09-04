extends CanvasLayer
## Minimap · 小地图 + 全屏地图（M 键切换）
##
## 两种模式共用一套绘制代码，只是缩放与裁剪范围不同：
##   - **小地图**（右上角）：以玩家为中心，显示 minimap_range_m 半径内的内容
##   - **全屏地图**（M 键）：显示整张 2km 图，用于查看关卡全貌与规划路线
##
## 数据来源是 WorldMap 的分区/POI/道路定义 —— 不重新扫描世界，直接读定义，
## 所以画一张 2km 全图也只是几十次 draw 调用。
##
## 设计取舍：默认**北固定**不随朝向旋转。搜打撤大图里"记住地图朝向"是核心技能，
## 旋转小地图会破坏空间记忆（可在调试面板切换对比）。

const PX_PER_M := 8.0

var world = null      ## WorldMap 节点（无类型：需访问脚本自定义成员）
var player = null

var _canvas: Control
var _font: Font
var full_screen := false

func _ready() -> void:
	layer = 6
	_font = ThemeDB.fallback_font
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.clip_contents = true
	_canvas.draw.connect(_draw_map)
	add_child(_canvas)

func setup(w, p) -> void:
	world = w
	player = p

func _process(_d: float) -> void:
	_canvas.queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("map"):
		full_screen = not full_screen
		get_viewport().set_input_as_handled()

func _vp() -> Vector2:
	return Vector2(_canvas.size)

# ── 布局 ────────────────────────────────────────────────
func _map_rect() -> Rect2:
	var vp := _vp()
	if full_screen:
		var side: float = minf(vp.x, vp.y) - 90.0
		return Rect2(Vector2((vp.x - side) * 0.5, (vp.y - side) * 0.5), Vector2(side, side))
	var s: float = Tuning.minimap_size
	return Rect2(Vector2(vp.x - s - 24.0, 78.0), Vector2(s, s))

## 世界坐标 → 地图内像素。返回值可能落在 rect 外（由调用方裁剪）
func _w2m(world_pos: Vector2, rect: Rect2, center: Vector2, scale: float) -> Vector2:
	var rel := (world_pos - center) * scale
	if Tuning.minimap_rotate and not full_screen and player != null:
		# 让玩家朝向始终朝上：反向旋转世界
		rel = rel.rotated(-player.aim_dir.angle() - PI * 0.5)
	return rect.get_center() + rel

func _draw_map() -> void:
	if world == null or player == null or not Tuning.show_minimap:
		return
	if not ("districts" in world):
		return   # 小图模式（level.gd）无分区数据，不画

	var rect := _map_rect()
	var c := _canvas
	var world_px: float = float(world.world_size_cells) * 40.0

	var center: Vector2
	var scale: float
	if full_screen:
		center = Vector2(world_px, world_px) * 0.5
		scale = rect.size.x / world_px
		# 挡住地图方块四周露出来的世界层箱子图标
		c.draw_rect(Rect2(Vector2.ZERO, _vp()), Color(0.04, 0.05, 0.07, 1.0), true)
	else:
		center = player.global_position
		scale = rect.size.x / (Tuning.minimap_range_m * 2.0 * PX_PER_M)

	# 底板必须不透明，否则世界里的箱子会透上来
	c.draw_rect(rect, Color(0.055, 0.065, 0.085, 1.0), true)

	_draw_districts(c, rect, center, scale)
	_draw_arterials(c, rect, center, scale)
	_draw_pois(c, rect, center, scale)
	if full_screen:
		_draw_grid_overlay(c, rect, center, scale, world_px)
	_draw_free_safes(c, rect, center, scale)
	_draw_vehicles(c, rect, center, scale)
	_draw_extraction(c, rect, center, scale)
	_draw_depots(c, rect, center, scale)
	_draw_crack_points(c, rect, center, scale)
	_draw_spaceship(c, rect, center, scale)
	_draw_contracts(c, rect, center, scale)
	_draw_player(c, rect, center, scale)

	# 边框
	c.draw_rect(rect, Color(0.45, 0.55, 0.68, 0.95), false, 2.0)
	_draw_labels(c, rect)

func _draw_districts(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	for key in world.districts:
		var d: Dictionary = world.districts[key]
		var r: Array = d.get("rect", [0, 0, 0, 0])
		var p0 := _w2m(Vector2(float(r[0]) * 40.0, float(r[1]) * 40.0), rect, center, scale)
		var sz := Vector2(float(r[2]) * 40.0, float(r[3]) * 40.0) * scale
		var dr := Rect2(p0, sz)
		if not dr.intersects(rect):
			continue
		var col := Color(str(d.get("color", "#444444")))
		c.draw_rect(dr.intersection(rect), col * Color(1, 1, 1, 0.30), true)
		c.draw_rect(dr.intersection(rect), col.lightened(0.2) * Color(1, 1, 1, 0.6), false, 1.5)
		# 分区名（全屏时才标，小地图上会挤）
		if full_screen:
			var tier: int = int(d.get("tier", 0))
			c.draw_string(_font, p0 + Vector2(6, 18),
				"%s  T%d" % [str(d.get("name", "")), tier],
				HORIZONTAL_ALIGNMENT_LEFT, sz.x, 13, col.lightened(0.55))

func _draw_arterials(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	for river in world.arterials.get("rivers", []):
		_draw_band(c, rect, center, scale, river, Color(0.30, 0.52, 0.66, 0.75))
	for road in world.arterials.get("roads", []):
		_draw_band(c, rect, center, scale, road, Color(0.62, 0.64, 0.70, 0.75))

func _draw_band(c: Control, rect: Rect2, center: Vector2, scale: float,
		band: Dictionary, col: Color) -> void:
	var pts: Array = band.get("points", [])
	if pts.size() < 2:
		return
	var w: float = maxf(float(band.get("width", 4)) * 40.0 * scale, 1.2)
	var prev := Vector2.INF
	for p in pts:
		var cur := _w2m(Vector2(float(p[0]) * 40.0, float(p[1]) * 40.0), rect, center, scale)
		if prev != Vector2.INF:
			# 简易裁剪：两端都在框外就跳过
			if rect.has_point(cur) or rect.has_point(prev):
				c.draw_line(prev, cur, col, w)
		prev = cur

func _draw_pois(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	for p in world.pois:
		var pd: Dictionary = p["def"]
		var wr: Rect2 = p["rect"]
		var p0 := _w2m(wr.position, rect, center, scale)
		var sz := wr.size * scale
		var dr := Rect2(p0, sz)
		if not dr.intersects(rect):
			continue
		var is_pvp: bool = str(pd.get("type", "open")) == "pvp"
		var col := Color(0.70, 0.44, 0.42) if is_pvp else Color(0.60, 0.55, 0.48)
		c.draw_rect(dr.intersection(rect), col * Color(1, 1, 1, 0.26), true)
		c.draw_rect(dr.intersection(rect), col, false, 1.6)
		# 名称：全屏always，小地图只标在框内的
		var label_pos := p0 + Vector2(0, -4)
		if rect.has_point(label_pos):
			var fs: int = 12 if full_screen else 11
			c.draw_string(_font, label_pos, str(pd.get("name", "")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col.lightened(0.3))

## 地图只标免保。武器箱 / 杂物箱 / 高保一律不画。
func _draw_free_safes(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	for n in get_tree().get_nodes_in_group("free_safe"):
		if not is_instance_valid(n):
			continue
		if bool(n.get("is_corpse_bag")):
			continue
		var rich := str(n.get("richness"))
		if rich == "L1" or rich == "L2" or rich == "L3":
			continue
		var mp := _w2m(n.global_position, rect, center, scale)
		if not rect.has_point(mp):
			continue
		var col := Color(1.0, 0.84, 0.20)
		var r: float = 4.5 if full_screen else 5.2
		if n.has_method("is_fully_searched") and n.is_fully_searched():
			c.draw_arc(mp, r, 0, TAU, 10, col * Color(1, 1, 1, 0.6), 1.2)
		else:
			c.draw_circle(mp, r, col)
	for n2 in get_tree().get_nodes_in_group("contract_reward"):
		if not is_instance_valid(n2):
			continue
		if n2.has_method("is_fully_searched") and n2.is_fully_searched():
			continue
		var rp := _w2m(n2.global_position, rect, center, scale)
		if not rect.has_point(rp):
			continue
		var rcol := Color(1.0, 0.78, 0.22)
		c.draw_circle(rp, 5.4, rcol)
		c.draw_arc(rp, 8.0, 0, TAU, 12, rcol, 1.5)
		if full_screen:
			c.draw_string(_font, rp + Vector2(7, -4), "合约奖励",
				HORIZONTAL_ALIGNMENT_LEFT, 80, 11, rcol)

## 载具：全部显示（车是大件地标，DMZ 的地图上也标车）。
## 这不算透视挂 —— 车不会主动杀你，能提前知道哪有车正是导航价值。
func _draw_vehicles(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	if not Tuning.enable_vehicles:
		return
	for v in get_tree().get_nodes_in_group("vehicles"):
		if not is_instance_valid(v):
			continue
		var mp := _w2m(v.global_position, rect, center, scale)
		if not rect.has_point(mp):
			continue
		var col := Color(0.55, 0.85, 0.95, 0.9)
		if v.is_wrecked():
			col = Color(0.95, 0.45, 0.25, 0.9)
		elif not v.has_room():
			col = Color(0.95, 0.85, 0.40, 0.9)
		# 用小方块区别于容器的圆点
		c.draw_rect(Rect2(mp - Vector2(3.2, 2.2), Vector2(6.4, 4.4)), col, true)

## 公共撤离点：固定点，不标倍率
func _draw_extraction(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	if not Tuning.enable_extraction or world == null:
		return
	var pads: Array = world.get("extract_pads") if "extract_pads" in world else []
	var col := Color(0.35, 0.95, 0.55, 0.95)
	for p in pads:
		if not (p is Dictionary):
			continue
		if not bool(p.get("live", true)):
			continue
		var ep: Vector2 = p.pos
		var mp := _w2m(ep, rect, center, scale)
		if not rect.has_point(mp):
			continue
		c.draw_circle(mp, 6.0, col * Color(1, 1, 1, 0.28))
		c.draw_circle(mp, 4.0, col)
		if full_screen:
			var rp := _w2m(ep + Vector2(Tuning.extraction_radius, 0), rect, center, scale)
			c.draw_arc(mp, maxf(mp.distance_to(rp), 4.0), 0, TAU, 26, col * Color(1, 1, 1, 0.5), 1.5)
			c.draw_string(_font, mp + Vector2(6, -8), "撤离",
				HORIZONTAL_ALIGNMENT_LEFT, 48, 11, col)

func _clamp_map_pt(mp: Vector2, rect: Rect2, pad: float = 8.0) -> Vector2:
	var r := rect.grow(-pad)
	return Vector2(
		clampf(mp.x, r.position.x, r.end.x),
		clampf(mp.y, r.position.y, r.end.y))

func _draw_depots(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	for d in get_tree().get_nodes_in_group("depots"):
		if not is_instance_valid(d):
			continue
		var mp := _w2m(d.global_position, rect, center, scale)
		var calling: bool = d.has_method("is_calling") and bool(d.is_calling())
		# 呼叫中：全图所有玩家都能在小地图上看到闪烁（超出视野则钉在边缘）
		if calling:
			mp = _clamp_map_pt(mp, rect)
		elif not rect.has_point(mp):
			continue
		var col := Color(0.35, 0.95, 0.55, 0.95)
		if d.has_method("accent_color"):
			col = d.accent_color()
		var consumed := bool(d.get("consumed"))
		var ready := true
		if d.has_method("is_ready"):
			ready = bool(d.is_ready())
		if consumed:
			col = Color(0.42, 0.43, 0.46, 0.65)
		elif calling:
			var blink: float = 0.45 + 0.55 * sin(Time.get_ticks_msec() * 0.014)
			col = Color(col.r, col.g, col.b, 0.35 + 0.65 * blink)
			c.draw_circle(mp, 9.0 + blink * 5.0, Color(col.r, col.g, col.b, 0.22))
		elif not ready:
			col = Color(col.r, col.g, col.b, 0.45)
		c.draw_rect(Rect2(mp - Vector2(4, 4), Vector2(8, 8)), col, true)
		if calling:
			c.draw_arc(mp, 7.0 + 3.0 * sin(Time.get_ticks_msec() * 0.014), 0, TAU, 14, col, 1.6)
		if full_screen:
			var mul: float = float(d.get("mul"))
			var tag := "【提交点】×%.1f" % mul
			if consumed:
				tag = "【提交点】已用"
			elif calling and d.has_method("ready_remain"):
				var s: int = maxi(0, int(ceil(float(d.ready_remain()))))
				tag = "【呼叫中】%d:%02d ×%.1f" % [s / 60, s % 60, mul]
			elif not ready:
				tag = "【呼叫点】×%.1f" % mul
			c.draw_string(_font, mp + Vector2(6, -6), tag, HORIZONTAL_ALIGNMENT_LEFT, 110, 10, col)

func _draw_crack_points(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	if world == null or not ("crack_points" in world):
		return
	for cp in world.crack_points:
		var mp := _w2m(cp, rect, center, scale)
		if not rect.has_point(mp):
			continue
		var col := Color(0.55, 0.85, 1.0, 0.95)
		c.draw_circle(mp, 4.4, col * Color(1, 1, 1, 0.25))
		c.draw_circle(mp, 2.6, col)
		if full_screen:
			c.draw_string(_font, mp + Vector2(5, -6), "破解", HORIZONTAL_ALIGNMENT_LEFT, 40, 10, col)

## 飞船：巡航/转场/破解点状态标记
func _draw_spaceship(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	if not Tuning.enable_spaceship or world == null:
		return
	var st: int = world.spaceship_state()
	if st < 0:
		return
	var sp: Vector2 = world.spaceship_pos()
	if sp == Vector2.INF:
		return
	var mp := _w2m(sp, rect, center, scale)
	if not rect.has_point(mp):
		return
	if st == 2:   # CRACKING
		c.draw_arc(mp, 8.0, 0, TAU, 20, Color(0.5, 1.0, 0.6, 0.9), 2.0)
		c.draw_string(_font, mp + Vector2(0, -16), "破解中", HORIZONTAL_ALIGNMENT_CENTER, 60, 11, Color(0.5, 1.0, 0.6))
	elif st == 3: # OPENED
		c.draw_arc(mp, 8.0, 0, TAU, 20, Color(0.55, 1.0, 0.78, 0.9), 2.0)
		c.draw_string(_font, mp + Vector2(0, -16), "已开放", HORIZONTAL_ALIGNMENT_CENTER, 60, 11, Color(0.55, 1.0, 0.78))
	else:
		var col := Color(0.55, 0.85, 1.0, 0.95)
		if st == 1:
			col = Color(1.0, 0.75, 0.35, 0.95)
		var tip := mp + Vector2(0, -7)
		var l := mp + Vector2(-6, 6)
		var r2 := mp + Vector2(6, 6)
		c.draw_colored_polygon(PackedVector2Array([tip, l, r2]), col)
		var tag := "飞船"
		if st == 1:
			tag = "驾驶中"
		c.draw_string(_font, mp + Vector2(0, -18), tag, HORIZONTAL_ALIGNMENT_CENTER, 50, 11, col)

func _draw_contracts(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	if not Tuning.enable_contracts or world == null:
		return
	var pulse: float = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.006)
	for b in get_tree().get_nodes_in_group("contract_boards"):
		if not is_instance_valid(b) or bool(b.get("consumed")):
			continue
		var mp := _w2m(b.global_position, rect, center, scale)
		if not rect.has_point(mp):
			continue
		var col := Color(0.92, 0.28, 0.28, 0.95)
		c.draw_circle(mp, 7.0 + pulse * 2.5, Color(col.r, col.g, col.b, 0.22))
		c.draw_circle(mp, 4.5, col)
		c.draw_arc(mp, 8.0 + pulse * 2.0, 0, TAU, 16, col, 1.8)
		if full_screen:
			var tag := str(b.get("title")) if str(b.get("title")) != "" else "合约"
			c.draw_string(_font, mp + Vector2(8, -4), tag,
				HORIZONTAL_ALIGNMENT_LEFT, 80, 11, col)
	var con = world.get("contracts")
	if con != null and is_instance_valid(con):
		if con.player_is_rescuer():
			for h in get_tree().get_nodes_in_group("hostages"):
				if not is_instance_valid(h) or (h.has_method("is_dead") and h.is_dead()):
					continue
				var hp := _w2m(h.global_position, rect, center, scale)
				if not rect.has_point(hp):
					continue
				c.draw_circle(hp, 4.0, Color(0.35, 0.95, 1.0))
				c.draw_arc(hp, 6.5, 0, TAU, 14, Color(1.0, 0.9, 0.35), 1.4)
		elif con.player_is_snatcher() and con.ping_pos != Vector2.INF:
			var pp := _w2m(con.ping_pos, rect, center, scale)
			if rect.has_point(pp):
				var ping_pulse: float = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.008)
				c.draw_circle(pp, 6.0 + ping_pulse * 3.0, Color(1.0, 0.45, 0.22, 0.28))
				c.draw_circle(pp, 4.2, Color(1.0, 0.52, 0.22, 0.95))
				c.draw_arc(pp, 8.0 + ping_pulse * 2.0, 0, TAU, 16, Color(1.0, 0.72, 0.32), 1.8)
				if full_screen:
					c.draw_string(_font, pp + Vector2(8, -4), "人质",
						HORIZONTAL_ALIGNMENT_LEFT, 50, 11, Color(1.0, 0.72, 0.35))
		if con.player_is_rescuer() and con.extract_pos != Vector2.INF:
			var ep := _w2m(con.extract_pos, rect, center, scale)
			if rect.has_point(ep):
				c.draw_arc(ep, 7.0, 0, TAU, 16, Color(0.45, 0.95, 1.0), 2.0)
				c.draw_circle(ep, 3.2, Color(0.45, 0.95, 1.0))
				if full_screen:
					var tag := "人质撤离"
					if int(con.get("kind")) == 3:
						tag = "芯片上交"
					c.draw_string(_font, ep + Vector2(8, -4), tag,
						HORIZONTAL_ALIGNMENT_LEFT, 80, 11, Color(0.55, 0.95, 1.0))
		if con.has_method("player_sees_intel") and con.player_sees_intel():
			_draw_intel_blips(c, rect, center, scale)
		if con.has_method("fail_ping_active") and con.fail_ping_active():
			_draw_fail_ping(c, rect, center, scale, int(con.get("owner_team")))
		if con.player_is_owner() and con.site_pos != Vector2.INF and int(con.get("kind")) in [1, 2]:
			var sp2 := _w2m(con.site_pos, rect, center, scale)
			if rect.has_point(sp2):
				var scol := Color(0.40, 0.90, 1.0) if int(con.get("kind")) == 1 else Color(0.45, 0.95, 0.72)
				c.draw_circle(sp2, 5.0, scol)
				c.draw_arc(sp2, 8.0, 0, TAU, 14, scol, 1.6)
		if con.player_is_owner() and con.mark_target != null and is_instance_valid(con.mark_target):
			if not (con.mark_target.has_method("is_dead") and con.mark_target.is_dead()):
				var mp2 := _w2m(con.mark_target.global_position, rect, center, scale)
				if rect.has_point(mp2):
					var pulse2: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.007)
					c.draw_circle(mp2, 5.0 + pulse2 * 2.0, Color(1.0, 0.82, 0.28, 0.9))
					if full_screen:
						c.draw_string(_font, mp2 + Vector2(8, -4), "清洗目标",
							HORIZONTAL_ALIGNMENT_LEFT, 80, 11, Color(1.0, 0.85, 0.4))
		if con.player_is_snatcher() and con.snatch_pos != Vector2.INF:
			var sp := _w2m(con.snatch_pos, rect, center, scale)
			if rect.has_point(sp):
				c.draw_arc(sp, 7.0, 0, TAU, 16, Color(1.0, 0.55, 0.28), 2.0)
				c.draw_circle(sp, 3.2, Color(1.0, 0.55, 0.28))
				if full_screen:
					c.draw_string(_font, sp + Vector2(8, -4), "交接点",
						HORIZONTAL_ALIGNMENT_LEFT, 80, 11, Color(1.0, 0.62, 0.35))

func _draw_intel_blips(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	var groups := ["enemies", "raider_bots", "human_players"]
	for gname in groups:
		for n in get_tree().get_nodes_in_group(gname):
			if not is_instance_valid(n):
				continue
			if n.has_method("is_dead") and n.is_dead():
				continue
			if player != null and n == player:
				continue
			var bp := _w2m(n.global_position, rect, center, scale)
			if not rect.has_point(bp):
				continue
			var col := Color(1.0, 0.45, 0.38, 0.9)
			if n.is_in_group("human_players") or n.is_in_group("raider_bots"):
				col = Color(1.0, 0.72, 0.28, 0.95)
			c.draw_circle(bp, 3.2, col)

func _draw_fail_ping(c: Control, rect: Rect2, center: Vector2, scale: float, team: int) -> void:
	var pulse: float = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.01)
	var nodes: Array = []
	nodes.append_array(get_tree().get_nodes_in_group("human_players"))
	nodes.append_array(get_tree().get_nodes_in_group("raider_bots"))
	for n in nodes:
		if not is_instance_valid(n):
			continue
		if int(n.get("team_id")) != team:
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		var bp := _w2m(n.global_position, rect, center, scale)
		if not rect.has_point(bp):
			continue
		c.draw_circle(bp, 6.0 + pulse * 3.0, Color(1.0, 0.25, 0.22, 0.28))
		c.draw_circle(bp, 4.0, Color(1.0, 0.35, 0.28, 0.95))

func _draw_player(c: Control, rect: Rect2, center: Vector2, scale: float) -> void:
	var mp := _w2m(player.global_position, rect, center, scale)
	if not rect.has_point(mp):
		return
	# 视野扇形（小地图上看得出自己朝哪看）
	var vr: float = player.vision_range() * scale
	var half := deg_to_rad(player.vision_half_angle_deg())
	var facing: float = player.aim_dir.angle()
	if Tuning.minimap_rotate and not full_screen:
		facing = -PI * 0.5
	if vr > 3.0:
		var pts := PackedVector2Array([mp])
		for i in 13:
			var a: float = facing - half + (2.0 * half) * (float(i) / 12.0)
			pts.append(mp + Vector2.RIGHT.rotated(a) * vr)
		c.draw_colored_polygon(pts, Color(0.55, 0.85, 1.0, 0.20))
	# 玩家箭头
	var tip := mp + Vector2.RIGHT.rotated(facing) * 7.0
	var l := mp + Vector2.RIGHT.rotated(facing + 2.5) * 5.0
	var r2 := mp + Vector2.RIGHT.rotated(facing - 2.5) * 5.0
	c.draw_colored_polygon(PackedVector2Array([tip, l, r2]), Color(0.45, 0.95, 1.0))
	c.draw_circle(mp, 2.0, Color.WHITE)

## 全屏地图叠加网格坐标，与地表网格对应（A1/B2…）
func _draw_grid_overlay(c: Control, rect: Rect2, center: Vector2, scale: float,
		world_px: float) -> void:
	var step: float = Tuning.grid_coarse_m * PX_PER_M * scale
	if step < 12.0:
		return
	var col := Color(0.60, 0.75, 0.92, 0.16)
	var n: int = int(ceil(rect.size.x / step))
	for i in n + 1:
		var x: float = rect.position.x + i * step
		if x <= rect.end.x:
			c.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), col, 1.0)
		var y: float = rect.position.y + i * step
		if y <= rect.end.y:
			c.draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), col, 1.0)
	# 行列标签
	var lcol := Color(0.65, 0.78, 0.95, 0.40)
	for i in n:
		var tag := char(65 + (i % 26))
		c.draw_string(_font, Vector2(rect.position.x + i * step + 3, rect.position.y + 13),
			tag, HORIZONTAL_ALIGNMENT_LEFT, step, 11, lcol)
		c.draw_string(_font, Vector2(rect.position.x + 3, rect.position.y + i * step + 24),
			str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, step, 11, lcol)

func _draw_labels(c: Control, rect: Rect2) -> void:
	if full_screen:
		var km: float = float(world.world_size_cells) * 5.0 / 1000.0
		c.draw_string(_font, rect.position + Vector2(0, -30),
			"海湾城全图  %.1f × %.1f km  ｜  %d 个 POI ｜  [M] 关闭" % [
				km, km, world.pois.size()],
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, 16, Color(0.85, 0.90, 1.0))
		_draw_map_legend(c, rect)
	else:
		# 小地图角标：当前分区 + 最近 POI 距离（导航提示）
		var dist_name := "空地"
		var d: Dictionary = world.district_at(player.global_position)
		if not d.is_empty():
			dist_name = "%s T%d" % [str(d.get("name", "")), int(d.get("tier", 0))]
		c.draw_string(_font, rect.position + Vector2(2, -6), dist_name,
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, 13, Color(0.80, 0.86, 0.96))
		var y: float = rect.end.y + 8.0
		y = _draw_extract_ticker(c, rect, y)
		var np: Dictionary = world.nearest_poi(player.global_position)
		if not np.is_empty():
			c.draw_string(_font, Vector2(rect.position.x, y),
				"最近：%s  %.0f m" % [str(np["def"]["name"]), float(np["dist"]) / PX_PER_M],
				HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, 12, Color(0.72, 0.80, 0.92))
			y += 16.0
		c.draw_string(_font, Vector2(rect.position.x, y),
			"[M] 全图  ｜  %.0f m 视野" % Tuning.minimap_range_m,
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, 11, Color(0.50, 0.56, 0.66))

func _draw_extract_ticker(c: Control, rect: Rect2, y: float) -> float:
	if world == null:
		return y
	var w: float = rect.size.x
	var x: float = rect.position.x
	var flash_t: float = 0.0
	if Tuning.enable_extraction:
		flash_t = float(world.get("extract_flash_t")) if "extract_flash_t" in world else 0.0
	if flash_t > 0.0:
		var txt: String = str(world.get("extract_flash"))
		var mul: float = float(world.get("extract_flash_mul"))
		var col := Color(0.35, 0.95, 0.55)
		if world.has_method("pad_color"):
			col = world.pad_color(mul)
		var life := 8.0
		var a: float = clampf(flash_t / maxf(life * 0.35, 0.2), 0.0, 1.0)
		var pulse: float = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.012)
		var box := Rect2(Vector2(x, y), Vector2(w, 34.0))
		c.draw_rect(box, Color(col.r, col.g, col.b, 0.16 + 0.10 * pulse) * Color(1, 1, 1, a), true)
		c.draw_rect(box, Color(col.r, col.g, col.b, 0.85 * a), false, 1.5)
		c.draw_string(_font, Vector2(x + 6, y + 14), "撤离播报",
			HORIZONTAL_ALIGNMENT_LEFT, w - 12, 11, Color(col.r, col.g, col.b, 0.75 * a))
		c.draw_string(_font, Vector2(x + 6, y + 28), txt,
			HORIZONTAL_ALIGNMENT_LEFT, w - 12, 12, Color(0.95, 0.98, 1.0, a))
		y += 38.0
	var dflash_t: float = float(world.get("depot_flash_t")) if "depot_flash_t" in world else 0.0
	var show_dflash := dflash_t > 0.0
	if show_dflash and bool(world.get("depot_flash_near_only")):
		var fp = world.get("depot_flash_pos")
		if player == null or not (fp is Vector2) or fp == Vector2.INF:
			show_dflash = false
		else:
			var lim: float = Tuning.depot_call_broadcast_m * 8.0
			show_dflash = player.global_position.distance_to(fp) <= lim
	if show_dflash:
		var dtxt: String = str(world.get("depot_flash"))
		var dmul: float = float(world.get("depot_flash_mul"))
		var dcol := Color(0.35, 0.95, 0.55)
		if world.has_method("depot_mul_color"):
			dcol = world.depot_mul_color(dmul)
		var da: float = clampf(dflash_t / 2.8, 0.0, 1.0)
		var dpulse: float = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.012)
		var dbox := Rect2(Vector2(x, y), Vector2(w, 34.0))
		c.draw_rect(dbox, Color(dcol.r, dcol.g, dcol.b, 0.16 + 0.10 * dpulse) * Color(1, 1, 1, da), true)
		c.draw_rect(dbox, Color(dcol.r, dcol.g, dcol.b, 0.85 * da), false, 1.5)
		c.draw_string(_font, Vector2(x + 6, y + 14), "提交点播报",
			HORIZONTAL_ALIGNMENT_LEFT, w - 12, 11, Color(dcol.r, dcol.g, dcol.b, 0.75 * da))
		c.draw_string(_font, Vector2(x + 6, y + 28), dtxt,
			HORIZONTAL_ALIGNMENT_LEFT, w - 12, 12, Color(0.95, 0.98, 1.0, da))
		y += 38.0
	if Tuning.enable_extraction and world.has_method("next_extract_wave_hint") and not world.is_extracted():
		var hint: String = world.next_extract_wave_hint()
		if hint != "":
			c.draw_string(_font, Vector2(x, y + 12), hint,
				HORIZONTAL_ALIGNMENT_LEFT, w, 12, Color(0.70, 0.82, 0.55))
			y += 16.0
	if world.has_method("next_depot_wave_hint"):
		var dh: String = world.next_depot_wave_hint()
		if dh != "":
			c.draw_string(_font, Vector2(x, y + 12), dh,
				HORIZONTAL_ALIGNMENT_LEFT, w, 12, Color(0.82, 0.62, 0.95))
			y += 16.0
	return y

func _legend(c: Control, pos: Vector2, col: Color, text: String) -> void:
	c.draw_rect(Rect2(pos, Vector2(10, 10)), col, true)
	c.draw_string(_font, pos + Vector2(15, 10), text,
		HORIZONTAL_ALIGNMENT_LEFT, 140, 12, Color(0.82, 0.86, 0.94))

func _draw_map_legend(c: Control, rect: Rect2) -> void:
	var items: Array = [
		[Color(0.90, 0.78, 0.42), "开放 POI"],
		[Color(0.95, 0.48, 0.44), "PvP POI"],
		[Color(1.0, 0.84, 0.20), "免保"],
		[Color(1.0, 0.78, 0.22), "合约奖励"],
		[Color(0.92, 0.28, 0.28), "合约"],
		[Color(0.35, 0.95, 0.55), "撤离点"],
		[Color(0.82, 0.38, 1.0), "提交点"],
		[Color(0.55, 0.85, 0.95), "载具"],
		[Color(0.55, 0.85, 1.0), "飞船"],
		[Color(0.55, 0.85, 1.0), "破解点"],
		[Color(0.45, 0.95, 1.0), "自己"],
	]
	var row_h: float = 16.0
	var pad: float = 8.0
	var panel_w: float = 168.0
	var panel_h: float = pad * 2.0 + 16.0 + items.size() * row_h
	var origin := Vector2(rect.position.x + 8.0, rect.end.y - panel_h - 8.0)
	c.draw_rect(Rect2(origin, Vector2(panel_w, panel_h)), Color(0.04, 0.05, 0.07, 0.78), true)
	c.draw_rect(Rect2(origin, Vector2(panel_w, panel_h)), Color(0.45, 0.55, 0.68, 0.55), false, 1.0)
	c.draw_string(_font, origin + Vector2(pad, 14.0), "图例",
		HORIZONTAL_ALIGNMENT_LEFT, panel_w - pad * 2.0, 12, Color(0.88, 0.92, 1.0))
	var y: float = origin.y + 20.0
	for it in items:
		_legend(c, Vector2(origin.x + pad, y), it[0], it[1])
		y += row_h
