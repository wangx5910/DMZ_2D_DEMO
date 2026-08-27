extends Node2D
## WorldMap · 2km×2km 大地图（JSON 按 4km 坐标系撰写，加载时等比缩放）
##
## 规范见 demo-2d/关卡设计规范.md §三。结构：
##   分区（district）定义地形性格与 tier → POI 用 PoiGenerator 就地生成 →
##   主干道 / 河道作软边界 → 地标锚点
##
## 性能取舍：
##   - **不为整图建碰撞**。只给 POI 内部墙体和主干道边缘建 StaticBody2D，
##     开阔地不建碰撞（走得过去）。
##   - 渲染分层：远景（分区色块/道路）画在一个节点，POI 细节按可见性分块绘制。
##   - POI 墙体碰撞按横向段合并（沿用 level.gd 的做法）。

const TILE := 40.0            ## 1 格 = 40 像素 = 5 米
const PX_PER_M := 8.0         ## 1 米 = 8 像素（关卡设计规范 §一 比例尺）
const WORLD_SIZE_M := 2000.0  ## 运行时地图边长（米）
const MIN_PATROL_GAP := 200.0 ## 巡逻点最小间距（像素 ≈ 25 米）
const POI_MIN_GAP_M := 80.0   ## POI 外墙之间保底空地（米）
const CHUNK := 40             ## 渲染分块尺寸（格）——POI 细节按块绘制

var world_size_cells: int = 800
var districts: Dictionary = {}
var poi_defs: Array = []
var arterials: Dictionary = {}
var landmarks: Array = []

## POI 实例：{def, gen, origin_cell, walls:Array[Rect2], containers:Array}
var pois: Array[Dictionary] = []
var spawn_point := Vector2.ZERO
var spawn_poi_name := ""   ## 出生点旁的 POI 名（HUD 提示用）

var container_script := preload("res://scripts/world/loot_container.gd")
var cover_script := preload("res://scripts/world/cover.gd")
var grunt_script := preload("res://scripts/enemy/grunt.gd")
var raider_bot_script := preload("res://scripts/ai/raider_bot.gd")
var vehicle_script := preload("res://scripts/world/vehicle.gd")
var spaceship_script := preload("res://scripts/world/spaceship.gd")
var contracts_script := preload("res://scripts/world/contracts.gd")
var depot_script := preload("res://scripts/world/depot.gd")
var vehicles_root: Node2D
var enemies_root: Node2D
var contracts = null
var _fx_ref = null

## 玩法流程（公共撤离点 + 飞船）
## extract_pads: {pos, live}
var extract_pads: Array = []
var extraction_points: Array[Vector2] = []   ## 仍同步 live 撤离点坐标，给旧接口/测试用
var extraction_radius_px: float = 90.0
var extraction_hold_t: float = 6.0
var player_extract_t: float = 0.0
var extracted: bool = false
signal extraction_done
const EXTRACT_PAD_COUNT := 4
const EXTRACT_PAD_MIN_GAP := 520.0
const EXTRACT_FLASH_LIFE := 8.0
## 提交点波次：越晚倍率越高。delay = 刷出后多久才能交互。
const DEPOT_WAVES: Array = [
	{"t": 0.0, "delay": 0.0, "count": 4, "mul": 1.0},
	{"t": 60.0, "delay": 120.0, "count": 5, "mul": 2.0},
	{"t": 180.0, "delay": 120.0, "count": 3, "mul": 5.0},
]
const DEPOT_MIN_GAP := 720.0
var depot_wave_spawned: Array[bool] = []
var depot_ready_announced: Array[bool] = []
var depot_flash := ""
var depot_flash_t := 0.0
var depot_flash_mul := 1.0
var spaceship = null
var spaceship_spawned: bool = false
var raid_time: float = 0.0
var crack_points: Array = []          ## 破解点位置（飞船事件同期出现）
var hijack_active = null              ## 飞船劫持者（用于小地图弱信息提示）
var ship_contest_ids: Dictionary = {} ## 获准赶船抢控的 AI（限员，防卡死）
var ship_loot_nodes: Array = []       ## 飞船内部 POI 容器（随船移动，巡航期可搜刮）
const MAX_SHIP_CONTESTORS := 8
var _contest_refresh_cd := 0.0
var free_safe_nodes: Array = []       ## 地图上的免保节点（L4 必争点）
var raider_bots_root: Node2D
var player_spawn_target_safe = null
## 小队出生规划：[{squad_id, center, members:Array[Vector2], safe}]
var squad_spawns: Array = []
var player_squad_id: int = 0

var _walls_root: Node2D
var _poi_layer: Node2D
var _bg: Node2D
## 性能：只激活玩家附近的 POI（碰撞 + 绘制）。
var _player = null
var _active_radius_px: float = 2200.0
var _last_check_pos := Vector2(-99999, -99999)
var _rng := RandomNumberGenerator.new()
var stats := {}

func _ready() -> void:
	z_index = -10
	_load_def()
	_build()

func _load_def() -> void:
	var path := "res://data/world_map.json"
	if not FileAccess.file_exists(path):
		push_error("缺少 world_map.json")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if not (d is Dictionary):
		return
	var w: Dictionary = d.get("world", {})
	var authored_m: float = float(w.get("size_m", 4000))
	var cell_m: float = float(w.get("cell_m", 5))
	world_size_cells = int(WORLD_SIZE_M / cell_m)
	districts = d.get("districts", {})
	poi_defs = d.get("pois", [])
	arterials = d.get("arterials", {})
	landmarks = d.get("landmarks", {}).get("items", [])
	if authored_m > 1.0 and not is_equal_approx(authored_m, WORLD_SIZE_M):
		_scale_layout(WORLD_SIZE_M / authored_m)

func _sci(v, s: float) -> int:
	return int(round(float(v) * s))

## 把 JSON 里的 4km 格坐标等比缩到运行时边长。
func _scale_layout(s: float) -> void:
	if is_equal_approx(s, 1.0):
		return
	for key in districts:
		var d: Dictionary = districts[key]
		var r: Array = d.get("rect", [0, 0, 0, 0])
		if r.size() >= 4:
			d["rect"] = [_sci(r[0], s), _sci(r[1], s), _sci(r[2], s), _sci(r[3], s)]
	for pd in poi_defs:
		var cell: Array = pd.get("cell", [0, 0])
		if cell.size() >= 2:
			pd["cell"] = [_sci(cell[0], s), _sci(cell[1], s)]
		var size: Array = pd.get("size", [48, 36])
		if size.size() >= 2:
			pd["size"] = [maxi(16, _sci(size[0], s)), maxi(12, _sci(size[1], s))]
	for kind in ["roads", "rivers"]:
		var arr: Array = arterials.get(kind, [])
		for item in arr:
			if not (item is Dictionary):
				continue
			if item.has("width"):
				item["width"] = maxi(2, _sci(item["width"], s))
			var pts: Array = item.get("points", [])
			var npts: Array = []
			for p in pts:
				if p is Array and p.size() >= 2:
					npts.append([_sci(p[0], s), _sci(p[1], s)])
				else:
					npts.append(p)
			item["points"] = npts
	for lm in landmarks:
		if not (lm is Dictionary):
			continue
		var c: Array = lm.get("cell", [0, 0])
		if c.size() >= 2:
			lm["cell"] = [_sci(c[0], s), _sci(c[1], s)]

func _build() -> void:
	var seed_v: int = NetHub.ensure_seed()
	_rng.seed = seed_v
	GameData.rng.seed = seed_v ^ 0x9E3779B9
	_bg = Node2D.new()
	_bg.name = "Background"
	_bg.z_index = -20
	add_child(_bg)
	_bg.draw.connect(_draw_background)

	_walls_root = Node2D.new()
	_walls_root.name = "Walls"
	add_child(_walls_root)
	enemies_root = Node2D.new()
	enemies_root.name = "Enemies"
	add_child(enemies_root)
	raider_bots_root = Node2D.new()
	raider_bots_root.name = "RaiderBots"
	add_child(raider_bots_root)
	vehicles_root = Node2D.new()
	vehicles_root.name = "Vehicles"
	add_child(vehicles_root)
	_poi_layer = Node2D.new()
	_poi_layer.name = "PoiVisuals"
	_poi_layer.z_index = -8
	add_child(_poi_layer)

	_generate_pois()
	_pick_spawn()
	_build_extraction_points()
	_build_depots()
	_collect_stats()
	_bg.queue_redraw()
	queue_redraw()

# ── POI 生成 ────────────────────────────────────────────
func _generate_pois() -> void:
	free_safe_nodes.clear()
	var idx := 0
	for pd in poi_defs:
		idx += 1
		var cell: Array = pd.get("cell", [0, 0])
		var size: Array = pd.get("size", [48, 36])
		var cfg = PoiGenerator.Config.new()
		cfg.width = int(size[0])
		cfg.height = int(size[1])
		cfg.seed = 900000 + idx * 131 + NetHub.ensure_seed()
		cfg.place_spawn = false        # 大地图的出生点由世界统一决定
		cfg.containers_l4 = int(pd.get("l4", 1))
		# 封闭式 PvP POI：更少房间、更对称、主路更宽（对称擂台）
		if str(pd.get("type", "open")) == "pvp":
			cfg.main_rows = 1
			cfg.main_cols = 1
			cfg.corridor_w = 3 if cfg.width < 28 or cfg.height < 24 else 4
			cfg.corridor_jitter = 0
			cfg.interconnect_chance = 0.35   # 擂台要多路径
			cfg.atrium_count = 1
		elif cfg.width < 36 or cfg.height < 28:
			cfg.main_rows = 1
			cfg.main_cols = 1
			cfg.corridor_w = 3
			cfg.atrium_count = 0
		else:
			cfg.main_rows = 2 if cfg.width < 56 else 3
			cfg.main_cols = 2

		var gen = PoiGenerator.new(cfg)
		if not gen.generate():
			cfg.width = maxi(cfg.width, 26)
			cfg.height = maxi(cfg.height, 20)
			cfg.main_rows = 1
			cfg.main_cols = 1
			cfg.corridor_w = mini(cfg.corridor_w, 3)
			gen = PoiGenerator.new(cfg)
			if not gen.generate():
				push_warning("POI 生成失败：%s" % str(pd.get("name", "?")))
				continue

		var origin := Vector2i(int(cell[0]), int(cell[1]))
		origin.x = clampi(origin.x, 2, maxi(2, world_size_cells - cfg.width - 2))
		origin.y = clampi(origin.y, 2, maxi(2, world_size_cells - cfg.height - 2))
		var holder := Node2D.new()
		holder.name = "PoiWalls_%d" % idx
		_walls_root.add_child(holder)
		var walls := _build_poi_walls(gen, origin, holder)
		var safe_cell: Vector2i = _spawn_poi_containers(gen, origin, pd)
		_spawn_poi_corridor_covers(gen, origin, holder, safe_cell)
		# 预烘焙 POI 的地板绘制数据（避免每帧重算 to_lines）
		var floor_rects := _bake_floor_rects(gen, origin)
		var world_rect := Rect2(
			Vector2(origin.x * TILE, origin.y * TILE),
			Vector2(cfg.width * TILE, cfg.height * TILE))
		pois.append({
			"def": pd, "gen": gen, "origin": origin, "walls": walls,
			"holder": holder, "rect": world_rect, "floors": floor_rects,
			"active": true,
		})

## 预烘焙地板矩形：按横向连续段合并，把每格一个 draw_rect 降到每段一个。
## 一个 60×46 的 POI 有约 1700 个地板格，17 个 POI 就是近 3 万次 draw 调用——
## 合并后降到约 1/6，是 4km 图能跑动的关键。
func _bake_floor_rects(gen, origin: Vector2i) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var lines: Array = gen.to_lines()
	for y in lines.size():
		var row: String = lines[y]
		var run := -1
		for x in row.length() + 1:
			var walk: bool = x < row.length() and row[x] != "#"
			if walk and run < 0:
				run = x
			elif not walk and run >= 0:
				out.append(Rect2(
					Vector2((origin.x + run) * TILE, (origin.y + y) * TILE),
					Vector2((x - run) * TILE, TILE)))
				run = -1
	return out

func set_player(p) -> void:
	_player = p
	_update_active_pois(true)

func spawn_point_for_peer(pid: int) -> Vector2:
	var s: Dictionary = spawn_squad_for_peer(pid)
	if s.is_empty():
		var ang: float = float((maxi(pid, 1) - 1) % 8) * TAU / 8.0
		var cand: Vector2 = spawn_point + Vector2.RIGHT.rotated(ang) * 52.0
		var cleared: Vector2 = find_clear_circle(14, cand)
		return cleared if cleared != Vector2.INF else cand
	var members: Array = s.get("members", [])
	var pos: Vector2 = members[0] if members.size() > 0 else s.get("center", spawn_point)
	var cleared2: Vector2 = find_clear_circle(14, pos)
	return cleared2 if cleared2 != Vector2.INF else pos

func spawn_squad_id_for_peer(pid: int) -> int:
	var s: Dictionary = spawn_squad_for_peer(pid)
	if s.is_empty():
		return player_squad_id
	return int(s.get("squad_id", player_squad_id))

func spawn_squad_for_peer(pid: int) -> Dictionary:
	var slots: Array = ordered_human_spawn_squads()
	if slots.is_empty():
		return {}
	var idx: int = NetHub.spawn_slot_of(pid)
	idx = clampi(idx, 0, slots.size() - 1)
	return slots[idx]

## 房主出生点为首，其余按距房主由近到远
func ordered_human_spawn_squads() -> Array:
	if squad_spawns.is_empty():
		return []
	var host_s: Dictionary = squad_spawns[0]
	var host_c: Vector2 = host_s.get("center", spawn_point)
	var rest: Array = []
	for s in squad_spawns:
		if int(s.get("squad_id", -1)) == int(host_s.get("squad_id", 0)):
			continue
		rest.append(s)
	rest.sort_custom(func(a, b):
		return a.get("center", host_c).distance_squared_to(host_c) \
			< b.get("center", host_c).distance_squared_to(host_c))
	var out: Array = [host_s]
	out.append_array(rest)
	return out

func occupied_squad_ids() -> Dictionary:
	var used := {}
	var slots: Array = ordered_human_spawn_squads()
	for pid in NetHub.spawn_slot:
		var idx: int = int(NetHub.spawn_slot[pid])
		if idx >= 0 and idx < slots.size():
			used[int(slots[idx].get("squad_id", -1))] = true
	for n in get_tree().get_nodes_in_group("human_players"):
		if is_instance_valid(n) and n.get("spawn_squad_id") != null:
			used[int(n.get("spawn_squad_id"))] = true
	return used

func despawn_ai_at_squad(sid: int) -> void:
	if raider_bots_root == null:
		return
	for b in raider_bots_root.get_children():
		if not is_instance_valid(b):
			continue
		if int(b.get("team_id")) == sid:
			b.queue_free()

## 刷全部小队 AI：有真人出生的出生点不刷 AI。需在 CombatFX 就绪后调用。
func spawn_raider_bots(fx = null) -> void:
	if not Tuning.enable_player_ai:
		return
	if raider_bots_root == null or _player == null:
		return
	if raider_bots_root.get_child_count() > 0:
		return
	if squad_spawns.is_empty():
		_plan_all_squad_spawns()
	var occupied: Dictionary = occupied_squad_ids()
	if _player != null:
		_player.team_id = int(_player.get("spawn_squad_id")) if _player.get("spawn_squad_id") != null else player_squad_id
		occupied[int(_player.team_id)] = true
	var bot_i := 0
	for s in squad_spawns:
		var sid: int = int(s.get("squad_id", 0))
		if occupied.has(sid):
			continue
		var members: Array = s.get("members", [])
		var safe = s.get("safe", player_spawn_target_safe)
		for mi in members.size():
			var pos: Vector2 = members[mi]
			if pos == Vector2.INF:
				continue
			var b := CharacterBody2D.new()
			b.set_script(raider_bot_script)
			b.name = "RaiderBot_S%d_M%d" % [sid, mi]
			raider_bots_root.add_child(b)
			var tag := "小队%d-%d" % [sid + 1, mi + 1]
			b.setup(self, pos, safe, tag, sid)
			if b.has_method("set_squad"):
				b.set_squad(sid, mi)
			if fx != null and b.has_method("set_fx"):
				b.set_fx(fx)
			bot_i += 1
	stats["raider_bots"] = bot_i
	stats["squads"] = squad_spawns.size()
	RaidLog.log_event("squads_spawned", {"squads": squad_spawns.size(), "bots": bot_i})

## 在锚点周围指定距离的环上找可行走出生点（角度可微调）
func _find_ring_spawn(anchor: Vector2, dist_px: float, base_ang: float, preferred: Vector2) -> Vector2:
	var pos: Vector2 = _find_clear_spawn(preferred, 48.0)
	if pos != Vector2.INF:
		return pos
	for step in range(1, 10):
		for sgn in [1, -1]:
			var ang: float = base_ang + deg_to_rad(12.0 * float(step) * float(sgn))
			var cand: Vector2 = anchor + Vector2.RIGHT.rotated(ang) * dist_px
			pos = _find_clear_spawn(cand, 40.0)
			if pos != Vector2.INF:
				return pos
		# 距离略缩/扩，避开墙带
		for mul in [0.85, 1.15, 0.7, 1.3]:
			var cand2: Vector2 = anchor + Vector2.RIGHT.rotated(base_ang) * (dist_px * mul)
			pos = _find_clear_spawn(cand2, 40.0)
			if pos != Vector2.INF:
				return pos
	return Vector2.INF

func _poi_by_point(pos: Vector2) -> Dictionary:
	var inside := {}
	var best := {}
	var best_d := INF
	for p in pois:
		var wr: Rect2 = p["rect"]
		if wr.has_point(pos):
			inside = p
			break
		var d: float = wr.get_center().distance_squared_to(pos)
		if wr.grow(80.0).has_point(pos) and d < best_d:
			best_d = d
			best = p
	return inside if not inside.is_empty() else best

## 在 preferred 附近找可行走空地（不嵌墙）。找不到返回 Vector2.INF
func _find_clear_spawn(preferred: Vector2, radius_px: float) -> Vector2:
	if _bot_spawn_clear(preferred):
		return preferred
	for ring in range(1, 8):
		var r: float = radius_px * float(ring)
		for step in 12:
			var ang: float = TAU * float(step) / 12.0
			var cand: Vector2 = preferred + Vector2.RIGHT.rotated(ang) * r
			if _bot_spawn_clear(cand):
				return cand
	return Vector2.INF

func _bot_spawn_clear(pos: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var q := PhysicsShapeQueryParameters2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 14.0
	q.shape = circle
	q.transform = Transform2D(0.0, pos)
	q.collision_mask = 1 << 0
	return space.intersect_shape(q, 1).is_empty()

## 死亡掉落：把背包物品做成可搜刮容器（流程与开箱相同）
func spawn_corpse_bag(pos: Vector2, item_ids: Array, bag_label: String = "尸体背包", stash_ids: Array = []) -> Node:
	var node := Area2D.new()
	node.set_script(container_script)
	node.name = "CorpseBag"
	add_child(node)
	node.global_position = pos
	if node.has_method("setup_corpse_bag"):
		node.setup_corpse_bag(item_ids, bag_label, "L2", stash_ids)
	return node

## 刷怪：每个 POI 按 tier 刷若干持枪小兵，巡逻路线取该 POI 的主路点。
## 必须在 fx 建好后调用（小兵开枪要用曳光弹表现层）。
func spawn_enemies(fx) -> void:
	_fx_ref = fx
	if not Tuning.enable_enemies:
		return
	var total := 0
	for p in pois:
		var pd: Dictionary = p["def"]
		var dk := str(pd.get("district", ""))
		var tier: int = int(districts.get(dk, {}).get("tier", 1))
		var n: int = Tuning.enemies_per_poi_base + (tier - 1) * Tuning.enemy_spawn_tier_bonus
		# PvP 型 POI（对称擂台）少刷一点，留给玩家对抗；
		# 但不低于基数 —— 大锤要求每个 POI 至少 6 个
		if str(pd.get("type", "open")) == "pvp":
			n = maxi(Tuning.enemies_per_poi_base, n - 1)
		total += _spawn_in_poi(p, n)
	stats["enemies"] = total

## 载具投放（照 DMZ：出生点附近少量、POI 外围街道、空旷区零散）。
## 三处位置对应三种玩法意图：
##   出生点附近 —— 开局就能选「走过去搜」还是「开车冲远点」
##   POI 外部   —— 撤离前的接应工具；也是「有人来过」的情报
##   空旷区     —— 长距离转移的救命稻草，避免大图变成散步模拟器
func spawn_vehicles(fx) -> void:
	if not Tuning.enable_vehicles:
		return
	_fx_ref = fx
	var kinds := ["sedan", "pickup", "van"]
	var made := 0

	# 1. 出生点附近
	for i in Tuning.vehicles_near_spawn:
		var pos := _find_open_spot(spawn_point, 240.0, 620.0)
		if pos != Vector2.INF:
			_make_vehicle(pos, kinds[_rng.randi() % kinds.size()])
			made += 1

	# 2. 每个 POI 外部（停在建筑外沿的街道上）
	for p in pois:
		if _rng.randf() > Tuning.vehicles_per_poi_outside:
			continue
		var r: Rect2 = p["rect"]
		var side: int = _rng.randi() % 4
		var anchor: Vector2
		match side:
			0: anchor = Vector2(r.get_center().x, r.position.y - 120.0)
			1: anchor = Vector2(r.get_center().x, r.end.y + 120.0)
			2: anchor = Vector2(r.position.x - 120.0, r.get_center().y)
			_: anchor = Vector2(r.end.x + 120.0, r.get_center().y)
		var pos2 := _find_open_spot(anchor, 0.0, 300.0)
		if pos2 != Vector2.INF:
			_make_vehicle(pos2, kinds[_rng.randi() % kinds.size()])
			made += 1

	# 3. 空旷区随机撒（全图均匀，避开 POI 内部）
	var world_px: float = world_size_cells * TILE
	var guard := 0
	var open_made := 0
	while open_made < Tuning.vehicles_open_field and guard < Tuning.vehicles_open_field * 30:
		guard += 1
		var cand := Vector2(
			_rng.randf_range(world_px * 0.06, world_px * 0.94),
			_rng.randf_range(world_px * 0.06, world_px * 0.94))
		var cell := Vector2i(int(cand.x / TILE), int(cand.y / TILE))
		if _cell_in_any_poi(cell):
			continue
		if not _spot_is_clear(cand):
			continue
		_make_vehicle(cand, kinds[_rng.randi() % kinds.size()])
		open_made += 1
		made += 1

	stats["vehicles"] = made

func _make_vehicle(pos: Vector2, kind: String) -> void:
	var v = CharacterBody2D.new()
	v.set_script(vehicle_script)
	vehicles_root.add_child(v)
	v.net_id = vehicles_root.get_child_count() - 1
	v.name = "Vehicle_%d" % v.net_id
	v.setup(pos, _fx_ref, kind)

## 在 anchor 周围环形找一个空地（无墙、不在 POI 内）。找不到返回 Vector2.INF
func _find_open_spot(anchor: Vector2, min_r: float, max_r: float) -> Vector2:
	for i in 40:
		var ang: float = _rng.randf_range(0.0, TAU)
		var rad: float = _rng.randf_range(min_r, max_r)
		var cand := anchor + Vector2.RIGHT.rotated(ang) * rad
		var world_px: float = world_size_cells * TILE
		if cand.x < 120.0 or cand.y < 120.0 or cand.x > world_px - 120.0 or cand.y > world_px - 120.0:
			continue
		if _cell_in_any_poi(Vector2i(int(cand.x / TILE), int(cand.y / TILE))):
			continue
		if _spot_is_clear(cand):
			return cand
	return Vector2.INF

## 车体尺寸内是否无碰撞体（避免车生成时半个身子插在墙里）
func _spot_is_clear(pos: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var q := PhysicsShapeQueryParameters2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(74.0, 46.0)   # 略大于车体，留出余量
	q.shape = rect
	q.transform = Transform2D(0.0, pos)
	q.collision_mask = (1 << 0) | (1 << 5)   # 墙 + 其它载具
	return space.intersect_shape(q, 1).is_empty()

func _spawn_in_poi(p: Dictionary, count: int) -> int:
	var gen = p["gen"]
	var origin: Vector2i = p["origin"]
	# 落点池：**可站立格**（排除外圈入口格与紧贴墙的死角）。
	# 曾用 corridor_cells 直接取点 —— 里面包含 _carve_entrances 凿出的外墙通道口，
	# 怪刷在那儿会贴着外墙罚站，且巡逻目标常在墙另一侧，只能原地顶墙。
	var pool: Array[Vector2i] = gen.standable_cells(true)
	if pool.is_empty():
		return 0
	var made := 0
	for i in count:
		var c: Vector2i = pool[_rng.randi() % pool.size()]
		var pos := _cell_center(origin, c)
		# 巡逻点从**出生格 BFS 可达域**里取，保证一定走得到。
		# 半径 14 格 ≈ 70 米，正好是一个 POI 内部的活动尺度。
		var near: Array[Vector2i] = gen.nearby_standable(c, 14)
		# 巡逻点之间必须**拉开距离**（≥5 格 / 25 米），否则两个点挨在一起，
		# AI 走两步就到、然后站定扫视，看起来跟罚站没区别。
		var patrol: Array[Vector2] = []
		if near.size() >= 2:
			var pts: int = mini(_rng.randi_range(2, 4), near.size())
			var guard := 0
			while patrol.size() < pts and guard < 120:
				guard += 1
				var cand := _cell_center(origin, near[_rng.randi() % near.size()])
				var too_close := cand.distance_to(pos) < MIN_PATROL_GAP
				for existing in patrol:
					if cand.distance_to(existing) < MIN_PATROL_GAP:
						too_close = true
						break
				if too_close:
					continue
				patrol.append(cand)
		var g = CharacterBody2D.new()
		g.set_script(grunt_script)
		enemies_root.add_child(g)
		g.setup(pos, _fx_ref, patrol, self)
		made += 1
	return made

func _cell_center(origin: Vector2i, c: Vector2i) -> Vector2:
	return Vector2(
		(origin.x + c.x) * TILE + TILE * 0.5,
		(origin.y + c.y) * TILE + TILE * 0.5)

func _process(delta: float) -> void:
	if _player == null:
		return
	_tick_match(delta)
	# 移动超过半格阈值才重算，避免每帧遍历
	if _player.global_position.distance_to(_last_check_pos) < 400.0:
		return
	_last_check_pos = _player.global_position
	_update_active_pois(false)

## 只让玩家附近的 POI 保持碰撞与绘制。远处 POI 关掉 StaticBody2D 的处理，
## 4596 个墙体全量常驻时帧率只有 35，按距离启停后可回到 60。
func _update_active_pois(force: bool) -> void:
	var pos: Vector2 = _player.global_position
	var dirty := false
	for p in pois:
		var r: Rect2 = p["rect"]
		var near: bool = r.grow(_active_radius_px).has_point(pos)
		var was: bool = bool(p["active"])
		if near == was and not force:
			continue
		p["active"] = near
		var holder: Node2D = p["holder"]
		holder.visible = near
		holder.process_mode = Node.PROCESS_MODE_INHERIT if near else Node.PROCESS_MODE_DISABLED
		# 关掉远处墙体的碰撞（物理开销的主要来源）
		for body in holder.get_children():
			if body is StaticBody2D:
				body.set_collision_layer(((1 << 0) | (1 << 3)) if near else 0)
		# 墙重新打开后，把穿进墙格的怪顶回空地（远处无碰撞时它们会走进墙里）
		if near and not was:
			call_deferred("_unstick_enemies_in_rect", r)
		dirty = true
	if dirty:
		queue_redraw()

func poi_walls_on_at(pos: Vector2) -> bool:
	var p: Dictionary = _poi_by_point(pos)
	if p.is_empty():
		return true
	return bool(p.get("active", true))

func _unstick_enemies_in_rect(r: Rect2) -> void:
	if enemies_root == null:
		return
	for e in enemies_root.get_children():
		if not is_instance_valid(e) or not (e is Node2D):
			continue
		if not r.grow(80.0).has_point((e as Node2D).global_position):
			continue
		if e.has_method("unstick_from_walls"):
			e.unstick_from_walls()

## 把 POI 的墙体转成合并后的 StaticBody2D（横向连续段合并）。
## 每个 POI 的墙体挂在自己的容器节点下，便于按距离整组启停。
func _build_poi_walls(gen, origin: Vector2i, holder: Node2D) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var lines: Array = gen.to_lines()
	for y in lines.size():
		var row: String = lines[y]
		var run_start := -1
		for x in row.length() + 1:
			var is_wall: bool = x < row.length() and row[x] == "#"
			if is_wall and run_start < 0:
				run_start = x
			elif not is_wall and run_start >= 0:
				var rect := Rect2(
					Vector2((origin.x + run_start) * TILE, (origin.y + y) * TILE),
					Vector2((x - run_start) * TILE, TILE)
				)
				out.append(rect)
				_add_wall_body(rect, holder)
				run_start = -1
	return out

func _add_wall_body(rect: Rect2, holder: Node2D) -> void:
	var body := StaticBody2D.new()
	body.position = rect.position + rect.size * 0.5
	# world(层1) + vision_blocker(层4)
	body.collision_layer = (1 << 0) | (1 << 3)
	body.collision_mask = 0

	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = rect.size
	shape.shape = box
	body.add_child(shape)

	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var h := rect.size * 0.5
	poly.polygon = PackedVector2Array([
		Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)
	])
	poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
	occ.occluder = poly
	body.add_child(occ)
	holder.add_child(body)

func _spawn_poi_containers(gen, origin: Vector2i, pd: Dictionary, upgrade := 0) -> Vector2i:
	var tiers := ["L1", "L2", "L3", "L4"]
	var l4_nodes: Array = []
	var safe_cell := Vector2i(-1, -1)
	for ct in gen.containers:
		var c: Vector2i = ct["cell"]
		var node = Area2D.new()
		node.set_script(container_script)
		node.position = Vector2(
			(origin.x + c.x) * TILE + TILE * 0.5,
			(origin.y + c.y) * TILE + TILE * 0.5
		)
		# 富度提升：整体升 upgrade 档（飞船 POI 用，物资更丰富）
		var rich: String = ct["richness"]
		if upgrade > 0:
			var idx: int = tiers.find(rich)
			if idx >= 0:
				rich = tiers[clampi(idx + upgrade, 0, tiers.size() - 1)]
		node.richness = rich
		if rich == "L4":
			l4_nodes.append(node)
		add_child(node)
	# 每个 POI 强制一个免保点位：放在中心甬道可视位，保证多方向可见与可争夺
	if not l4_nodes.is_empty():
		var safe_node = l4_nodes[0]
		safe_cell = _pick_free_safe_cell(gen)
		safe_node.position = Vector2(
			(origin.x + safe_cell.x) * TILE + TILE * 0.5,
			(origin.y + safe_cell.y) * TILE + TILE * 0.5
		)
		safe_node.label = "免保保险箱"
		safe_node.add_to_group("free_safe")
		safe_node.set_meta("poi_name", str(pd.get("name", "")))
		free_safe_nodes.append(safe_node)
	return safe_cell

## 甬道边小型掩体：贴墙侧、留中央通行；免保附近强制放置。
func _spawn_poi_corridor_covers(gen, origin: Vector2i, holder: Node2D, safe_cell: Vector2i) -> void:
	var occupied: Dictionary = {}  # Vector2i -> true，已占格
	for ct in gen.containers:
		occupied[ct["cell"] as Vector2i] = true
	if safe_cell.x >= 0:
		occupied[safe_cell] = true
	for e in gen.entrances:
		occupied[e["cell"] as Vector2i] = true

	var edge: Array = []  # {c, wd, ns}
	for c in gen.corridor_cells:
		if occupied.has(c):
			continue
		var info := _corridor_cover_info(gen, c)
		if info["wd"] == Vector2.ZERO:
			continue  # 甬道正中：不摆，保证通行
		edge.append(info)

	var placed: Dictionary = {}
	var rng := RandomNumberGenerator.new()
	rng.seed = int(origin.x) * 73856093 ^ int(origin.y) * 19349663 ^ int(gen.cfg.seed)

	# 免保附近：强制 2–3 个贴边掩体（半径 3 格 ≈ 15m）
	if safe_cell.x >= 0:
		var near: Array = []
		for item in edge:
			var c2: Vector2i = item["c"]
			if absi(c2.x - safe_cell.x) + absi(c2.y - safe_cell.y) <= 3:
				near.append(item)
		near.shuffle()
		var need := mini(3, near.size())
		if need < 1 and not edge.is_empty():
			# 极端情况：边上没有候选，退到最近边格
			var best_i := 0
			var best_d := 1e9
			for i in edge.size():
				var c3: Vector2i = edge[i]["c"]
				var d3: float = Vector2(c3).distance_squared_to(Vector2(safe_cell))
				if d3 < best_d:
					best_d = d3
					best_i = i
			near = [edge[best_i]]
			need = 1
		for i in need:
			_place_cover_at(origin, holder, near[i], placed)

	# 其余甬道稀疏撒点（约每 5–7 个边格一个）
	for item in edge:
		var c: Vector2i = item["c"]
		if placed.has(c):
			continue
		# 与已摆掩体保持间距（曼哈顿 ≥ 4）
		var too_close := false
		for pcell in placed.keys():
			if absi(c.x - pcell.x) + absi(c.y - pcell.y) < 4:
				too_close = true
				break
		if too_close:
			continue
		if rng.randf() > 0.22:
			continue
		_place_cover_at(origin, holder, item, placed)

func _place_cover_at(origin: Vector2i, holder: Node2D, item: Dictionary, placed: Dictionary) -> void:
	var cell: Vector2i = item["c"]
	if placed.has(cell):
		return
	placed[cell] = true
	var node = StaticBody2D.new()
	node.set_script(cover_script)
	var world_pos := Vector2(
		(origin.x + cell.x) * TILE + TILE * 0.5,
		(origin.y + cell.y) * TILE + TILE * 0.5
	)
	node.setup(world_pos, item["wd"], bool(item.get("ns", false)))
	holder.add_child(node)

func _gen_is_wall(gen, n: Vector2i) -> bool:
	if n.y < 0 or n.y >= gen.grid.size():
		return true
	var row: Array = gen.grid[n.y]
	if n.x < 0 or n.x >= row.size():
		return true
	return str(row[n.x]) == "#"

## 甬道边格：贴墙方向 + 是否南北向甬道。正中格（四邻皆可行走）wd = ZERO。
func _corridor_cover_info(gen, c: Vector2i) -> Dictionary:
	var walls: Array[Vector2] = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if _gen_is_wall(gen, c + d):
			walls.append(Vector2(d))
	if walls.is_empty():
		return {"c": c, "wd": Vector2.ZERO, "ns": false}
	var walk_ns := (0 if _gen_is_wall(gen, c + Vector2i(0, -1)) else 1) \
		+ (0 if _gen_is_wall(gen, c + Vector2i(0, 1)) else 1)
	var walk_ew := (0 if _gen_is_wall(gen, c + Vector2i(-1, 0)) else 1) \
		+ (0 if _gen_is_wall(gen, c + Vector2i(1, 0)) else 1)
	var ns: bool = walk_ns >= walk_ew
	var wd := walls[0]
	for w in walls:
		# 南北甬道优先贴东/西墙；东西甬道优先贴南/北墙
		if ns and absf(w.x) > absf(w.y):
			wd = w
			break
		if not ns and absf(w.y) > absf(w.x):
			wd = w
			break
	return {"c": c, "wd": wd, "ns": ns}

func _corridor_wall_dir(gen, c: Vector2i) -> Vector2:
	return _corridor_cover_info(gen, c)["wd"]

func _pick_free_safe_cell(gen) -> Vector2i:
	var center := Vector2i(gen.cfg.width / 2, gen.cfg.height / 2)
	var best := center
	var best_d := 1e9
	for c in gen.corridor_cells:
		var d: float = Vector2(c).distance_squared_to(Vector2(center))
		if d < best_d:
			best_d = d
			best = c
	if best_d < 1e8:
		return best
	var cells: Array = gen.standable_cells(false)
	for c2 in cells:
		var d2: float = Vector2(c2).distance_squared_to(Vector2(center))
		if d2 < best_d:
			best_d = d2
			best = c2
	return best

# ── 出生点 ──────────────────────────────────────────────
## 玩家在地图最外沿、贴着上手区第一个核心 POI 外墙。
## 同免保的敌对小队在相反方向、相同半径，保证到免保时间一致。
## 径向从外到内：玩家出生 → ×1.0 提交点 → ×2.0 → ×5.0（中心）。
func _pick_spawn() -> void:
	_plan_all_squad_spawns()
	if squad_spawns.is_empty():
		spawn_point = _map_center()
		return
	var s0: Dictionary = squad_spawns[0]
	var members: Array = s0.get("members", [])
	if members.is_empty():
		spawn_point = _map_center()
		return
	spawn_point = members[0]
	player_spawn_target_safe = s0.get("safe", null)
	spawn_poi_name = ""
	if player_spawn_target_safe != null and is_instance_valid(player_spawn_target_safe):
		var poi := _poi_by_point(player_spawn_target_safe.global_position)
		if not poi.is_empty():
			spawn_poi_name = str(poi["def"].get("name", ""))

func _map_center() -> Vector2:
	var wp: float = world_size_cells * TILE
	return Vector2(wp, wp) * 0.5

func _map_half() -> float:
	return world_size_cells * TILE * 0.5

func _clamp_world(pos: Vector2, margin: float) -> Vector2:
	var wp: float = world_size_cells * TILE
	return Vector2(
		clampf(pos.x, margin, wp - margin),
		clampf(pos.y, margin, wp - margin))

func _outward_dir(pos: Vector2) -> Vector2:
	var d: Vector2 = pos - _map_center()
	if d.length_squared() < 1.0:
		return Vector2(-1, 1).normalized()
	return d.normalized()

func _dist_to_edge(pos: Vector2) -> float:
	var wp: float = world_size_cells * TILE
	return minf(minf(pos.x, pos.y), minf(wp - pos.x, wp - pos.y))

func _aabb_exit_t(origin: Vector2, dir: Vector2, r: Rect2) -> float:
	if dir.length_squared() < 0.0001:
		return r.size.length() * 0.5
	var t := INF
	if absf(dir.x) > 0.001:
		var tx: float = ((r.end.x if dir.x > 0.0 else r.position.x) - origin.x) / dir.x
		if tx > 0.0:
			t = minf(t, tx)
	if absf(dir.y) > 0.001:
		var ty: float = ((r.end.y if dir.y > 0.0 else r.position.y) - origin.y) / dir.y
		if ty > 0.0:
			t = minf(t, ty)
	if t == INF:
		return r.size.length() * 0.5
	return t

func _spawn_radius_px(safe_pos: Vector2, poi: Dictionary, outward: Vector2) -> float:
	var cap: float = Tuning.spawn_to_safe_m * PX_PER_M
	if poi.is_empty() or not poi.has("rect"):
		return cap
	var rect: Rect2 = poi["rect"]
	var wall_t: float
	if rect.has_point(safe_pos):
		wall_t = _aabb_exit_t(safe_pos, outward, rect)
	else:
		wall_t = _closest_dist_to_rect(safe_pos, rect)
	return clampf(wall_t + 48.0, 64.0, cap)

func _closest_dist_to_rect(p: Vector2, r: Rect2) -> float:
	var q := Vector2(
		clampf(p.x, r.position.x, r.end.x),
		clampf(p.y, r.position.y, r.end.y))
	return p.distance_to(q)

func _is_spawn_zone_poi(poi: Dictionary) -> bool:
	if poi.is_empty():
		return false
	var dk := str(poi["def"].get("district", ""))
	return bool(districts.get(dk, {}).get("is_spawn_zone", false))

func _pick_edge_spawn_safe(safes: Array):
	var best_zone = null
	var best_any = null
	var best_zone_d := INF
	var best_any_d := INF
	for n in safes:
		if not is_instance_valid(n):
			continue
		var d: float = _dist_to_edge(n.global_position)
		if d < best_any_d:
			best_any_d = d
			best_any = n
		if _is_spawn_zone_poi(_poi_by_point(n.global_position)) and d < best_zone_d:
			best_zone_d = d
			best_zone = n
	return best_zone if best_zone != null else best_any

func _make_squad_at(sid: int, safe, safe_pos: Vector2, dist_px: float, base_ang: float, size: int) -> Dictionary:
	var members: Array[Vector2] = []
	for mi in size:
		var ang: float = base_ang + deg_to_rad(float(mi - 1) * 12.0)
		var preferred: Vector2 = _clamp_world(safe_pos + Vector2.RIGHT.rotated(ang) * dist_px, 80.0)
		var pos: Vector2 = _find_ring_spawn(safe_pos, dist_px, ang, preferred)
		if pos == Vector2.INF:
			pos = preferred
		members.append(pos)
	var center: Vector2 = Vector2.ZERO
	for m in members:
		center += m
	center /= float(members.size())
	return {
		"squad_id": sid,
		"center": center,
		"members": members,
		"safe": safe,
	}

## 玩家小队贴地图外沿；同免保敌对小队反向同距。其余小队环绕其它免保。
func _plan_all_squad_spawns() -> void:
	squad_spawns.clear()
	player_squad_id = 0
	var n_squads: int = maxi(1, int(Tuning.squad_count))
	var size: int = maxi(1, int(Tuning.squad_size))
	var safes: Array = []
	for n in free_safe_nodes:
		if is_instance_valid(n):
			safes.append(n)
	var anchor_fallback: Array[Vector2] = []
	if safes.is_empty():
		for p in pois:
			var dk := str(p["def"].get("district", ""))
			if bool(districts.get(dk, {}).get("is_spawn_zone", false)) or int(p["def"].get("l4", 0)) > 0:
				anchor_fallback.append((p["rect"] as Rect2).get_center())
		if anchor_fallback.is_empty() and not pois.is_empty():
			anchor_fallback.append((pois[0]["rect"] as Rect2).get_center())
		if anchor_fallback.is_empty():
			return

	var player_safe = _pick_edge_spawn_safe(safes) if not safes.is_empty() else null
	var player_pos: Vector2 = player_safe.global_position if player_safe != null else (
		anchor_fallback[0] if not anchor_fallback.is_empty() else _map_center())
	var player_poi: Dictionary = _poi_by_point(player_pos)
	var outward: Vector2 = _outward_dir(player_pos)
	var dist_px: float = _spawn_radius_px(player_pos, player_poi, outward)
	var p_ang: float = outward.angle()
	squad_spawns.append(_make_squad_at(0, player_safe, player_pos, dist_px, p_ang, size))
	if n_squads >= 2:
		squad_spawns.append(_make_squad_at(1, player_safe, player_pos, dist_px, p_ang + PI, size))

	var rest_safes: Array = []
	for n2 in safes:
		if n2 != player_safe:
			rest_safes.append(n2)
	if rest_safes.is_empty():
		rest_safes = safes.duplicate()
	var rest_n: int = rest_safes.size() if not rest_safes.is_empty() else maxi(1, anchor_fallback.size())
	var per_slot: Dictionary = {}
	for sid in range(2, n_squads):
		var si: int = (sid - 2) % rest_n
		if not per_slot.has(si):
			per_slot[si] = []
		per_slot[si].append(sid)
	for sid in range(2, n_squads):
		var si2: int = (sid - 2) % rest_n
		var safe = rest_safes[si2] if not rest_safes.is_empty() else null
		var safe_pos: Vector2 = safe.global_position if safe != null else anchor_fallback[si2 % maxi(1, anchor_fallback.size())]
		var poi2: Dictionary = _poi_by_point(safe_pos)
		var out2: Vector2 = _outward_dir(safe_pos)
		var r2: float = _spawn_radius_px(safe_pos, poi2, out2)
		var peers: Array = per_slot.get(si2, [sid])
		var local_i: int = peers.find(sid)
		var peer_n: int = maxi(1, peers.size())
		var base_ang: float = out2.angle() + TAU * float(local_i) / float(peer_n)
		squad_spawns.append(_make_squad_at(sid, safe, safe_pos, r2, base_ang, size))
	if not squad_spawns.is_empty():
		player_spawn_target_safe = squad_spawns[0].get("safe", null)

func _nearest_poi_safe(p: Dictionary):
	var wr: Rect2 = p["rect"]
	var best = null
	var best_d := INF
	for n in free_safe_nodes:
		if not is_instance_valid(n):
			continue
		if not wr.grow(60.0).has_point(n.global_position):
			continue
		var d := wr.get_center().distance_squared_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

func _cell_in_any_poi(c: Vector2i) -> bool:
	for p in pois:
		var o: Vector2i = p["origin"]
		var g = p["gen"]
		var r := Rect2i(o, Vector2i(g.cfg.width, g.cfg.height))
		# 留 3 格余量，避免贴着 POI 外墙出生
		if r.grow(3).has_point(c):
			return true
	return false

# ── 玩法流程：公共撤离点 ────────────────────────────────
## 开局刷固定撤离点。无倍率、无限次；进圈站住一段时间后结算撤离。
func _build_extraction_points() -> void:
	extract_pads.clear()
	extraction_points.clear()
	if not Tuning.enable_extraction:
		return
	extraction_radius_px = Tuning.extraction_radius
	extraction_hold_t = Tuning.extraction_hold
	var n: int = EXTRACT_PAD_COUNT
	var world_px: float = world_size_cells * TILE
	var anchors := [
		Vector2(world_px * 0.16, world_px * 0.16),
		Vector2(world_px * 0.84, world_px * 0.22),
		Vector2(world_px * 0.22, world_px * 0.84),
		Vector2(world_px * 0.82, world_px * 0.82),
	]
	var spots: Array[Vector2] = []
	for a in anchors:
		if spots.size() >= n:
			break
		var spot := _find_open_spot(a, 0.0, 700.0)
		if spot != Vector2.INF:
			spots.append(spot)
	while spots.size() < n:
		var extra := _find_extract_spot()
		if extra == Vector2.INF:
			break
		spots.append(extra)
	if spots.is_empty():
		spots.append(spawn_point + Vector2(360, 0))
	for s in spots:
		extract_pads.append({"pos": s, "live": true})
	_sync_extraction_points()
	queue_redraw()
	RaidLog.log_event("extract_pads_spawned", {"count": extract_pads.size()})

func _find_extract_spot() -> Vector2:
	var world_px: float = world_size_cells * TILE
	for _try in 48:
		var near := Vector2(
			_rng.randf_range(world_px * 0.12, world_px * 0.88),
			_rng.randf_range(world_px * 0.12, world_px * 0.88))
		var spot := _find_open_spot(near, 0.0, 800.0)
		if spot == Vector2.INF:
			continue
		if spawn_point.distance_to(spot) < 420.0:
			continue
		var ok := true
		for p in extract_pads:
			if spot.distance_to(p.pos) < EXTRACT_PAD_MIN_GAP:
				ok = false
				break
		if ok:
			return spot
	return Vector2.INF

func _sync_extraction_points() -> void:
	extraction_points.clear()
	for p in extract_pads:
		if bool(p.get("live", true)):
			extraction_points.append(p.pos)

func _live_pad_index_at(pos: Vector2) -> int:
	for i in extract_pads.size():
		var p: Dictionary = extract_pads[i]
		if not bool(p.get("live", true)):
			continue
		if pos.distance_to(p.pos) <= extraction_radius_px:
			return i
	return -1

func current_extract_pad() -> Dictionary:
	if _player == null:
		return {}
	var i := _live_pad_index_at(_player.global_position)
	if i < 0:
		return {}
	return extract_pads[i]

func next_extract_wave_hint() -> String:
	return ""

func _build_depots() -> void:
	depot_wave_spawned.clear()
	depot_wave_spawned.resize(DEPOT_WAVES.size())
	depot_wave_spawned.fill(false)
	depot_ready_announced.clear()
	depot_ready_announced.resize(DEPOT_WAVES.size())
	depot_ready_announced.fill(false)
	_spawn_depot_wave(0)

func _spawn_depot_wave(wave: int) -> void:
	if wave < 0 or wave >= DEPOT_WAVES.size():
		return
	if depot_wave_spawned.size() <= wave:
		depot_wave_spawned.resize(DEPOT_WAVES.size())
	if depot_wave_spawned[wave]:
		return
	depot_wave_spawned[wave] = true
	var spec: Dictionary = DEPOT_WAVES[wave]
	var n: int = int(spec.get("count", 1))
	var mul: float = float(spec.get("mul", 1.0))
	var delay: float = float(spec.get("delay", 0.0))
	var ready_time: float = raid_time + delay
	var occupied: Array[Vector2] = []
	if is_inside_tree():
		for d in get_tree().get_nodes_in_group("depots"):
			if is_instance_valid(d):
				occupied.append(d.global_position)
	var spots: Array[Vector2] = _place_depots_on_ring(mul, n, wave, occupied)
	for s in spots:
		var node := Area2D.new()
		node.set_script(depot_script)
		node.name = "Depot"
		add_child(node)
		node.setup(s, mul, ready_time, wave)
	var delay_txt := "立即可用" if delay <= 0.01 else ("%.0f 秒后可用" % delay)
	depot_flash = "提交点已刷新  ×%.1f  %d个  %s" % [mul, spots.size(), delay_txt]
	depot_flash_t = EXTRACT_FLASH_LIFE
	depot_flash_mul = mul
	queue_redraw()
	RaidLog.log_event("depots_spawned", {
		"wave": wave, "mul": mul, "count": spots.size(), "ready_at": ready_time,
	})

func _depot_ring_frac(mul: float) -> float:
	if mul >= 4.5:
		return 0.24
	if mul >= 1.5:
		return 0.52
	return 0.82

func _place_depots_on_ring(mul: float, n: int, wave: int, occupied: Array[Vector2]) -> Array[Vector2]:
	var spots: Array[Vector2] = []
	var center := _map_center()
	var radius: float = _map_half() * _depot_ring_frac(mul)
	var start_ang: float = float(wave) * 0.41
	for i in n:
		var ang: float = start_ang + TAU * float(i) / float(maxi(n, 1))
		var preferred: Vector2 = _clamp_world(center + Vector2.RIGHT.rotated(ang) * radius, 180.0)
		var spot := Vector2.INF
		if not _cell_in_any_poi(Vector2i(int(preferred.x / TILE), int(preferred.y / TILE))) \
				and _spot_is_clear(preferred):
			spot = preferred
		if spot == Vector2.INF:
			spot = _find_open_spot(preferred, 40.0, 520.0)
		if spot == Vector2.INF:
			spot = _find_depot_spot(occupied)
		if spot == Vector2.INF:
			continue
		var far_enough := true
		for s in occupied:
			if spot.distance_to(s) < DEPOT_MIN_GAP:
				far_enough = false
				break
		if not far_enough:
			spot = _find_depot_spot(occupied)
			if spot == Vector2.INF:
				continue
		spots.append(spot)
		occupied.append(spot)
	return spots

func _find_depot_spot(existing: Array[Vector2]) -> Vector2:
	var world_px: float = world_size_cells * TILE
	for _try in 48:
		var near := Vector2(
			_rng.randf_range(world_px * 0.14, world_px * 0.86),
			_rng.randf_range(world_px * 0.14, world_px * 0.86))
		var cand := _find_open_spot(near, 0.0, 700.0)
		if cand == Vector2.INF:
			continue
		if spawn_point.distance_to(cand) < 280.0:
			continue
		var far_enough := true
		for s in existing:
			if cand.distance_to(s) < DEPOT_MIN_GAP:
				far_enough = false
				break
		if far_enough:
			return cand
	return Vector2.INF

func _tick_depot_waves() -> void:
	for i in DEPOT_WAVES.size():
		if i < depot_wave_spawned.size() and depot_wave_spawned[i]:
			continue
		if raid_time + 0.001 >= float(DEPOT_WAVES[i].get("t", 0.0)):
			_spawn_depot_wave(i)
	for i in DEPOT_WAVES.size():
		if i >= depot_ready_announced.size() or depot_ready_announced[i]:
			continue
		if i >= depot_wave_spawned.size() or not depot_wave_spawned[i]:
			continue
		var spec: Dictionary = DEPOT_WAVES[i]
		var ready_t: float = float(spec.get("t", 0.0)) + float(spec.get("delay", 0.0))
		if raid_time + 0.001 < ready_t:
			continue
		depot_ready_announced[i] = true
		if float(spec.get("delay", 0.0)) <= 0.01:
			continue
		_grant_stash_page_for_new_depot()
		depot_flash = "提交点已可用  ×%.1f  %d个  ｜  网络存储箱 +%d×%d" % [
			float(spec.get("mul", 1.0)), int(spec.get("count", 1)),
			int(Tuning.stash_cols), int(Tuning.stash_rows)]
		depot_flash_t = EXTRACT_FLASH_LIFE
		depot_flash_mul = float(spec.get("mul", 1.0))

func _grant_stash_page_for_new_depot() -> void:
	var p = _player
	if p == null:
		var root = get_tree().get_first_node_in_group("raid_root")
		if root != null:
			p = root.get("player")
	if p != null and p.has_method("expand_stash_page"):
		p.expand_stash_page()

func next_depot_wave_hint() -> String:
	for i in DEPOT_WAVES.size():
		var spec: Dictionary = DEPOT_WAVES[i]
		var spawn_at: float = float(spec.get("t", 0.0))
		var ready_at: float = spawn_at + float(spec.get("delay", 0.0))
		var mul: float = float(spec.get("mul", 1.0))
		var n: int = int(spec.get("count", 1))
		if i >= depot_wave_spawned.size() or not depot_wave_spawned[i]:
			var remain: float = spawn_at - raid_time
			if remain <= 0.0:
				continue
			return "%.0f 秒后刷新 ×%.1f 提交点（%d 个）" % [remain, mul, n]
		if i >= depot_ready_announced.size() or not depot_ready_announced[i]:
			var remain_r: float = ready_at - raid_time
			if remain_r <= 0.0:
				continue
			return "×%.1f 提交点 %.0f 秒后可用（%d 个）" % [mul, remain_r, n]
	return ""

func depot_mul_color(mul: float) -> Color:
	if mul >= 4.5:
		return Color(1.0, 0.28, 0.28)
	if mul >= 1.5:
		return Color(0.82, 0.38, 1.0)
	return Color(0.35, 0.95, 0.55)

func pad_color(mul: float) -> Color:
	if mul >= 9.5:
		return Color(1.0, 0.38, 0.18)
	if mul >= 4.5:
		return Color(1.0, 0.72, 0.22)
	if mul >= 1.5:
		return Color(0.62, 0.95, 0.38)
	return Color(0.35, 0.95, 0.55)

## 在玩家附近/任意合法空地找一个无遮挡的圆形区域，供飞船降落。
## 返回世界坐标，找不到返回 Vector2.INF。
## near != INF 时偏向该点周围搜索（飞船在巡航结束点附近降落，避免横跨大图）。
func find_clear_circle(radius_cells: float, near: Vector2 = Vector2.INF) -> Vector2:
	var world_px: float = world_size_cells * TILE
	var rpx: float = radius_cells * TILE
	var guard := 0
	var bias_r: float = 1600.0
	while guard < 500:
		guard += 1
		var cand: Vector2
		if near != Vector2.INF:
			cand = near + Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * bias_r
			cand.x = clampf(cand.x, 2000.0, world_px - 2000.0)
			cand.y = clampf(cand.y, 2000.0, world_px - 2000.0)
		else:
			cand = Vector2(
				_rng.randf_range(world_px * 0.12, world_px * 0.88),
				_rng.randf_range(world_px * 0.12, world_px * 0.88))
		# 整个圆都不能落进 POI（含余量）
		var center_cell := Vector2i(int(cand.x / TILE), int(cand.y / TILE))
		if _cell_in_any_poi(center_cell):
			continue
		var clear := true
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				if _cell_in_any_poi(Vector2i(int((cand.x + dx * rpx * 0.8) / TILE),
						int((cand.y + dy * rpx * 0.8) / TILE))):
					clear = false
					break
			if not clear:
				break
		if not clear:
			continue
		# 圆形区域本身无墙（方形九宫格近似检测）
		var ok := true
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				if not _spot_is_clear(cand + Vector2(dx, dy) * rpx * 0.7):
					ok = false
					break
			if not ok:
				break
		if not ok:
			continue
		# 别贴着出生点（避免开局撞上）；near 偏置模式下飞船已巡航远离，放宽
		if near == Vector2.INF and spawn_point.distance_to(cand) < 700.0:
			continue
		return cand
	return Vector2.INF

## 飞船降落后：在落点生成一个标准 POI，容器富度整体提升（物资更丰富）。
## 返回新 POI 字典（追加进 pois，自动参与渲染/碰撞/小地图）。
func add_dynamic_poi(center_world: Vector2, opts: Dictionary) -> Dictionary:
	var size: Array = opts.get("size", [46, 36])
	var cfg = PoiGenerator.Config.new()
	cfg.width = int(size[0])
	cfg.height = int(size[1])
	cfg.seed = int(opts.get("seed", 777013))
	cfg.place_spawn = false
	cfg.containers_l4 = int(opts.get("l4", 3))
	var gen = PoiGenerator.new(cfg)
	if not gen.generate():
		return {}
	var origin := Vector2i(
		int(center_world.x / TILE) - cfg.width / 2,
		int(center_world.y / TILE) - cfg.height / 2)
	origin.x = clampi(origin.x, 2, world_size_cells - cfg.width - 2)
	origin.y = clampi(origin.y, 2, world_size_cells - cfg.height - 2)
	var holder := Node2D.new()
	holder.name = "PoiWalls_Ship"
	_walls_root.add_child(holder)
	var walls := _build_poi_walls(gen, origin, holder)
	var upgrade: int = int(opts.get("richness_upgrade", 0))
	var safe_cell: Vector2i = _spawn_poi_containers(gen, origin, {"name": "坠星飞船", "type": "open"}, upgrade)
	_spawn_poi_corridor_covers(gen, origin, holder, safe_cell)
	var floor_rects := _bake_floor_rects(gen, origin)
	var world_rect := Rect2(
		Vector2(origin.x * TILE, origin.y * TILE),
		Vector2(cfg.width * TILE, cfg.height * TILE))
	var pdict := {
		"def": {"name": "坠星飞船", "type": "open"}, "gen": gen, "origin": origin,
		"walls": walls, "holder": holder, "rect": world_rect, "floors": floor_rects, "active": true,
	}
	pois.append(pdict)
	stats["pois"] = pois.size()
	# 富物资 = 高风险：内部刷少量守卫
	var guards: int = int(opts.get("guards", 4))
	if guards > 0 and Tuning.enable_enemies:
		_spawn_in_poi(pdict, guards)
	queue_redraw()
	RaidLog.log_event("dynamic_poi_added", {"pos": [int(center_world.x), int(center_world.y)]})
	return pdict

# ── 玩法流程：飞船调度 ──────────────────────────────────
func _spawn_spaceship() -> void:
	spaceship_spawned = true
	var s = Node2D.new()
	s.set_script(spaceship_script)
	spaceship = s
	add_child(s)
	s.setup(self)
	s.build_interior(self)
	spaceship.hijacked.connect(_on_ship_hijacked)
	spaceship.ship_extracted.connect(_on_ship_extracted)
	RaidLog.log_event("spaceship_spawned", {})

## 调试：F2 立即召唤飞船到玩家附近（绕过约 3 分钟计时）。
func force_spawn_spaceship() -> void:
	if spaceship_spawned:
		return
	_spawn_spaceship()
	if crack_points.is_empty():
		_build_crack_points()
	if spaceship != null and _player != null and is_instance_valid(_player):
		spaceship.place_near(_player.global_position)
	RaidLog.log_event("debug_spawn_ship", {"near_player": _player != null})

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		force_spawn_spaceship()
		get_viewport().set_input_as_handled()

## 调试面板「悬浮至破解点」：若未刷出则刷出，瞬移到破解点悬浮
func debug_force_descent() -> void:
	if not spaceship_spawned:
		_spawn_spaceship()
		_build_crack_points()
	if spaceship != null and is_instance_valid(spaceship):
		spaceship.force_hover_at_crack(self)

## 破解点：飞船事件同期出现，分布在地图各处的合法空地
func _build_crack_points() -> void:
	crack_points.clear()
	var wp: float = float(world_size_cells) * 40.0
	var n: int = int(Tuning.spaceship_crack_points)
	for i in n:
		var near := Vector2(
			_rng.randf_range(wp * 0.10, wp * 0.90),
			_rng.randf_range(wp * 0.10, wp * 0.90))
		var pt: Vector2 = find_clear_circle(14, near)
		if pt != Vector2.INF:
			crack_points.append(pt)
	RaidLog.log_event("crack_points_built", {"count": crack_points.size()})

func spaceship_crack_points() -> Array:
	return crack_points

## 飞船被劫持：全图广播 + 记录劫持者（小地图据此显示附近敌人弱信息）
func _on_ship_hijacked(by) -> void:
	hijack_active = by
	refresh_ship_contestors()
	RaidLog.log_event("ship_hijacked_broadcast", {"contestors": ship_contest_ids.size()})

## 只让离飞船最近的一小撮 AI 赶船，避免 60+ 全员关 LOD 把帧率打穿
func refresh_ship_contestors() -> void:
	ship_contest_ids.clear()
	if spaceship == null or not is_instance_valid(spaceship) or not is_hijack_active():
		return
	var sp: Vector2 = spaceship.global_position
	var hj = spaceship.hijacker
	var cands: Array = []
	for b in get_tree().get_nodes_in_group("raider_bots"):
		if not is_instance_valid(b):
			continue
		if b == hj:
			continue
		if b.has_method("is_dead") and b.is_dead():
			continue
		cands.append({
			"id": b.get_instance_id(),
			"d": b.global_position.distance_squared_to(sp),
		})
	cands.sort_custom(func(a, other): return a["d"] < other["d"])
	for i in mini(MAX_SHIP_CONTESTORS, cands.size()):
		ship_contest_ids[cands[i]["id"]] = true

func is_ship_contestor(bot) -> bool:
	if bot == null or not is_instance_valid(bot):
		return false
	return ship_contest_ids.has(bot.get_instance_id())

## 飞船刷出时即在船内生成 POI 容器（地面舱辐射区），挂为飞船子节点随船移动。
## 巡航期间玩家光柱登舰后即可像普通 POI 一样搜刮。
func spawn_ship_interior_loot(ship) -> void:
	ship_loot_nodes.clear()
	var sz: Vector2 = ship.ship_size()
	var tiers := ["L3", "L4", "L3", "L4", "L3", "L4"]
	var labels := ["辐射箱", "辐射箱", "高保柜", "高保柜", "辐射箱", "高保柜"]
	var spots := [
		Vector2(-0.30, -0.22), Vector2(0.30, -0.22),
		Vector2(-0.30, 0.22), Vector2(0.30, 0.22),
		Vector2(0.0, -0.36), Vector2(0.0, 0.36),
	]
	for i in spots.size():
		var local := Vector2(sz.x * spots[i].x, sz.y * spots[i].y)
		var node = Area2D.new()
		node.set_script(container_script)
		node.richness = tiers[i % tiers.size()]
		node.label = labels[i]
		node.position = local
		ship.add_child(node)
		ship_loot_nodes.append(node)
	RaidLog.log_event("ship_interior_loot", {"count": ship_loot_nodes.size()})

## 旧整船撤离入口：正常破解只开放密闭舱，不再触发。调试/兼容保留。
func _on_ship_extracted(by) -> void:
	ship_full_extract(by)

func ship_full_extract(player) -> void:
	if player == null or not is_instance_valid(player):
		return
	if player.has_method("grant_sealed_reward"):
		player.grant_sealed_reward()
	extracted = true
	hijack_active = null
	ship_contest_ids.clear()
	if player.is_in_group("player") and player.has_method("settle_extract"):
		player.settle_extract(1.0, "ship")
	emit_signal("extraction_done")
	RaidLog.log_event("ship_full_extracted", {"value": player.total_value() if player.has_method("total_value") else 0})

func spaceship_hijacker():
	if spaceship != null and is_instance_valid(spaceship):
		return spaceship.hijacker
	return null

func is_hijack_active() -> bool:
	return hijack_active != null

## 每帧推进：计时 / 撤离判定 / 飞船。被 _process 无条件调用（不依赖移动阈值）。
func _tick_match(delta: float) -> void:
	raid_time += delta
	if depot_flash_t > 0.0:
		depot_flash_t = maxf(0.0, depot_flash_t - delta)
	_tick_depot_waves()
	# 撤离判定（单玩家：判自身；LAN 时为每个玩家各判各的）
	var player_busy: bool = _player != null and (
		bool(_player.get("raid_over")) or (_player.has_method("is_dead") and _player.is_dead()))
	if Tuning.enable_extraction and not extracted and not player_busy and _player != null:
		var idx := _live_pad_index_at(_player.global_position)
		if idx >= 0:
			player_extract_t += delta
			if player_extract_t >= extraction_hold_t:
				_complete_pad_extract(idx)
		else:
			player_extract_t = maxf(0.0, player_extract_t - delta * 1.5)
	# 飞船
	if Tuning.enable_spaceship and not spaceship_spawned and raid_time >= Tuning.spaceship_spawn_time:
		_spawn_spaceship()
		_build_crack_points()
	if spaceship != null and is_instance_valid(spaceship):
		if NetHub.is_authority() or not NetHub.is_online():
			spaceship.tick(delta, self)
		queue_redraw()
		if is_hijack_active():
			_contest_refresh_cd -= delta
			if _contest_refresh_cd <= 0.0:
				_contest_refresh_cd = 2.5
				refresh_ship_contestors()
	if Tuning.enable_contracts and contracts == null:
		_spawn_contracts_now()
	if contracts != null and is_instance_valid(contracts):
		contracts.tick(delta)

func _complete_pad_extract(idx: int) -> void:
	if idx < 0 or idx >= extract_pads.size():
		return
	extracted = true
	if _player != null and _player.has_method("settle_extract"):
		_player.settle_extract(1.0, "extract")
	emit_signal("extraction_done")
	RaidLog.log_event("extracted", {})
	queue_redraw()

# ── 查询接口（HUD / 小地图用）─────────────────────────
func extraction_in_zone() -> bool:
	if not Tuning.enable_extraction or _player == null:
		return false
	return _live_pad_index_at(_player.global_position) >= 0

func extraction_progress() -> float:
	if extracted:
		return 1.0
	return clampf(player_extract_t / maxf(extraction_hold_t, 0.01), 0.0, 1.0)

func is_extracted() -> bool:
	return extracted

func spaceship_state() -> int:
	if spaceship != null and is_instance_valid(spaceship):
		return spaceship.state
	return -1

func spaceship_pos() -> Vector2:
	if spaceship != null and is_instance_valid(spaceship):
		return spaceship.global_position
	return Vector2.INF

# ── 渲染 ────────────────────────────────────────────────
## 背景：分区色块 + 河道 + 高架路。一次性绘制，不随相机变化
func _draw_background() -> void:
	var full := world_size_cells * TILE
	# 底色（未分区的空地 = 街区与荒地）
	# 注意亮度：这一层还会被 CanvasModulate（默认 0.30）整体压暗，
	# 所以底色必须给足，否则开阔地全黑、玩家看不见路——地形记忆层就失效了。
	_bg.draw_rect(Rect2(Vector2.ZERO, Vector2(full, full)), Color(0.19, 0.20, 0.235), true)

	# 分区色块
	for key in districts:
		var d: Dictionary = districts[key]
		var r: Array = d.get("rect", [0, 0, 0, 0])
		var rect := Rect2(
			Vector2(float(r[0]) * TILE, float(r[1]) * TILE),
			Vector2(float(r[2]) * TILE, float(r[3]) * TILE))
		var col := Color(str(d.get("color", "#444444")))
		# 分区色只做"地面色调"：与底色混合而不是直接铺原色，避免刺眼
		_bg.draw_rect(rect, col.lerp(Color(0.19, 0.20, 0.235), 0.78), true)
		_bg.draw_rect(rect, col.lightened(0.25), false, 4.0)
		# 分区名（大图导航靠它定位）
		_bg.draw_string(ThemeDB.fallback_font, rect.position + Vector2(24, 60),
			str(d.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 64,
			col.lightened(0.55))
		_bg.draw_string(ThemeDB.fallback_font, rect.position + Vector2(24, 108),
			"tier %d ｜ %s" % [int(d.get("tier", 0)), str(d.get("desc", ""))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 30, col.lightened(0.35))

	_draw_ground_grid(full)

	# 河道（画在道路下层）
	for river in arterials.get("rivers", []):
		_draw_polyline_band(river, Color(0.20, 0.34, 0.44), Color(0.34, 0.55, 0.68))
	# 高架路（比地面亮 → 开阔危险带在视觉上就"显眼"）
	for road in arterials.get("roads", []):
		_draw_polyline_band(road, Color(0.40, 0.42, 0.47), Color(0.58, 0.60, 0.66))

func _draw_polyline_band(band: Dictionary, fill: Color, edge: Color) -> void:
	var pts: Array = band.get("points", [])
	if pts.size() < 2:
		return
	var w: float = float(band.get("width", 4)) * TILE
	var poly := PackedVector2Array()
	for p in pts:
		poly.append(Vector2(float(p[0]) * TILE, float(p[1]) * TILE))
	_bg.draw_polyline(poly, fill, w)
	_bg.draw_polyline(poly, edge, w * 0.12)

## 前景：POI 地板与墙体、地标。按块绘制以控制单次 draw 调用量
func _draw() -> void:
	for p in pois:
		if p["active"]:
			_draw_poi(p)
		else:
			_draw_poi_far(p)
	_draw_free_safes()
	_draw_squad_spawns()
	_draw_landmarks()
	_draw_extraction()
	_draw_depots()
	_draw_crack_points()
	_draw_contract_extract()

## 小队出生点标注（世界层）
func _draw_squad_spawns() -> void:
	if squad_spawns.is_empty():
		return
	for s in squad_spawns:
		var sid: int = int(s.get("squad_id", 0))
		var center: Vector2 = s.get("center", Vector2.ZERO)
		var mine: bool = sid == player_squad_id
		var col := Color(0.35, 0.95, 0.55, 0.95) if mine else Color(0.95, 0.72, 0.28, 0.88)
		draw_circle(center, 22.0, Color(col.r, col.g, col.b, 0.12))
		draw_arc(center, 22.0, 0, TAU, 20, col, 2.0)
		# 三角旗
		var tip := center + Vector2(0, -18)
		var l := center + Vector2(-10, 10)
		var r := center + Vector2(10, 10)
		draw_colored_polygon(PackedVector2Array([tip, l, r]), col)
		draw_string(ThemeDB.fallback_font, center + Vector2(0, 34),
			"出生·小队%d" % (sid + 1), HORIZONTAL_ALIGNMENT_CENTER, 140, 16, col)
		# 队员位点
		for mpos in s.get("members", []):
			if mpos is Vector2:
				draw_circle(mpos, 6.0, col * Color(1, 1, 1, 0.85))

func _draw_crack_points() -> void:
	if crack_points.is_empty():
		return
	for cp in crack_points:
		draw_circle(cp, 68.0, Color(0.35, 0.65, 1.0, 0.08))
		draw_arc(cp, 68.0, 0, TAU, 28, Color(0.55, 0.85, 1.0, 0.68), 2.0)
		draw_circle(cp, 8.0, Color(0.75, 0.95, 1.0, 0.9))
		draw_string(ThemeDB.fallback_font, cp + Vector2(0, -82.0), "破解点",
			HORIZONTAL_ALIGNMENT_CENTER, 120, 18, Color(0.68, 0.9, 1.0))

## 撤离点标记（世界层）：固定圈，无倍率。
func _draw_extraction() -> void:
	if not Tuning.enable_extraction or extract_pads.is_empty():
		return
	var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.004)
	var base := Color(0.35, 0.95, 0.55)
	for p in extract_pads:
		if not bool(p.get("live", true)):
			continue
		var ep: Vector2 = p.pos
		draw_circle(ep, extraction_radius_px, Color(base.r, base.g, base.b, 0.10))
		draw_arc(ep, extraction_radius_px, 0, TAU, 40, base, 2.5)
		draw_arc(ep, extraction_radius_px * (0.42 + 0.30 * pulse), 0, TAU, 32,
			Color(base.r, base.g, base.b, 0.5), 2.0)
		draw_string(ThemeDB.fallback_font, ep + Vector2(-80, -extraction_radius_px - 18),
			"撤离点", HORIZONTAL_ALIGNMENT_CENTER, 160, 22, base)

func _draw_depots() -> void:
	for d in get_tree().get_nodes_in_group("depots"):
		if not is_instance_valid(d):
			continue
		var col := Color(0.35, 0.95, 0.55)
		if d.has_method("accent_color"):
			col = d.accent_color()
		var ready := true
		if d.has_method("is_ready"):
			ready = bool(d.is_ready())
		if bool(d.get("consumed")):
			col = Color(0.42, 0.43, 0.46, 0.7)
		elif not ready:
			col = col.darkened(0.4)
		var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.005)
		var pos: Vector2 = d.global_position
		draw_circle(pos, 42.0, Color(col.r, col.g, col.b, 0.10 if ready and not bool(d.get("consumed")) else 0.04))
		draw_arc(pos, 42.0, 0, TAU, 28, col, 2.0)
		if ready and not bool(d.get("consumed")):
			draw_arc(pos, 26.0 + 8.0 * pulse, 0, TAU, 20, Color(col.r, col.g, col.b, 0.45), 1.6)

func _draw_contract_extract() -> void:
	if contracts == null or not is_instance_valid(contracts):
		return
	var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.005)
	var r: float = Tuning.contract_extract_radius
	if contracts.player_is_rescuer() and contracts.extract_pos != Vector2.INF:
		var ep: Vector2 = contracts.extract_pos
		var col := Color(0.45, 0.95, 1.0, 0.95)
		draw_circle(ep, r, Color(0.15, 0.45, 0.55, 0.12))
		draw_arc(ep, r, 0, TAU, 40, col, 2.6)
		draw_arc(ep, r * (0.4 + 0.28 * pulse), 0, TAU, 28, Color(1.0, 0.85, 0.35, 0.7), 2.0)
		draw_string(ThemeDB.fallback_font, ep + Vector2(0, -r - 14),
			"人质撤离点", HORIZONTAL_ALIGNMENT_CENTER, 160, 22, col)
	if contracts.player_is_snatcher() and contracts.snatch_pos != Vector2.INF:
		var sp: Vector2 = contracts.snatch_pos
		var scol := Color(1.0, 0.52, 0.28, 0.95)
		draw_circle(sp, r, Color(0.45, 0.18, 0.08, 0.14))
		draw_arc(sp, r, 0, TAU, 40, scol, 2.6)
		draw_arc(sp, r * (0.4 + 0.28 * pulse), 0, TAU, 28, Color(1.0, 0.78, 0.35, 0.7), 2.0)
		draw_string(ThemeDB.fallback_font, sp + Vector2(0, -r - 14),
			"人质交接点", HORIZONTAL_ALIGNMENT_CENTER, 160, 22, scol)

## 动态合约：开局即刷交互点。
func spawn_contracts(fx) -> void:
	_fx_ref = fx
	if not Tuning.enable_contracts:
		return
	_spawn_contracts_now()

func _spawn_contracts_now() -> void:
	if not Tuning.enable_contracts:
		return
	if contracts != null:
		return
	contracts = Node2D.new()
	contracts.set_script(contracts_script)
	contracts.name = "Contracts"
	add_child(contracts)
	contracts.setup(self, _fx_ref)
	contracts.spawn_opening()
	RaidLog.log_event("contracts_spawned", {"t": snappedf(raid_time, 0.1)})

## 远处 POI 只画一个轮廓块 + 名字（大图导航用），不画内部细节
func _draw_poi_far(p: Dictionary) -> void:
	var r: Rect2 = p["rect"]
	var pd: Dictionary = p["def"]
	var col := Color(0.31, 0.34, 0.39, 0.62)
	if str(pd.get("type", "open")) == "pvp":
		col = Color(0.46, 0.33, 0.36, 0.66)
	draw_rect(r, col, true)
	draw_rect(r, col, false, 3.0)
	draw_string(ThemeDB.fallback_font, r.position + Vector2(0, -12),
		str(pd.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 26,
		Color(0.70, 0.62, 0.45, 0.75))

func _draw_poi(p: Dictionary) -> void:
	var o: Vector2i = p["origin"]
	# 地板用预烘焙的合并矩形
	for fr in p["floors"]:
		draw_rect(fr, Color(0.33, 0.36, 0.40), true)
	# 墙体
	for rect in p["walls"]:
		draw_rect(rect, Color(0.14, 0.16, 0.20), true)
		draw_rect(rect, Color(0.26, 0.28, 0.34), false, 2.0)
	# POI 名称标签（大图导航用）
	var pd: Dictionary = p["def"]
	var label_pos := Vector2(o.x * TILE, (o.y - 2) * TILE)
	var tcol := Color(0.69, 0.63, 0.53, 0.72)
	if str(pd.get("type", "open")) == "pvp":
		tcol = Color(0.78, 0.50, 0.50, 0.76)
	draw_string(ThemeDB.fallback_font, label_pos, str(pd.get("name", "")),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 26, tcol)

func _draw_free_safes() -> void:
	for n in free_safe_nodes:
		if n == null or not is_instance_valid(n):
			continue
		var p: Vector2 = n.global_position
		draw_circle(p, 38.0, Color(1.0, 0.85, 0.30, 0.12))
		draw_arc(p, 38.0, 0, TAU, 32, Color(1.0, 0.82, 0.26, 0.86), 3.0)
		draw_circle(p, 8.5, Color(1.0, 0.78, 0.20, 0.95))
		draw_string(ThemeDB.fallback_font, p + Vector2(0, -46), "【免保】",
			HORIZONTAL_ALIGNMENT_CENTER, 100, 18, Color(1.0, 0.86, 0.32, 0.96))

func _draw_cell(origin: Vector2i, x: int, y: int, col: Color) -> void:
	draw_rect(Rect2(
		Vector2((origin.x + x) * TILE, (origin.y + y) * TILE),
		Vector2(TILE, TILE)), col, true)

func _draw_landmarks() -> void:
	for lm in landmarks:
		var c: Array = lm.get("cell", [0, 0])
		var pos := Vector2(float(c[0]) * TILE, float(c[1]) * TILE)
		var kind := str(lm.get("kind", ""))
		var h: float = float(lm.get("height", 1))
		var r: float = 26.0 + h * 12.0
		var col := Color(0.55, 0.72, 0.95, 0.55)
		match kind:
			"holo_tower":  col = Color(0.45, 0.90, 1.0, 0.60)
			"corp_spire":  col = Color(0.95, 0.45, 0.80, 0.60)
			"crane":       col = Color(0.95, 0.72, 0.30, 0.55)
			"cooling":     col = Color(0.70, 0.75, 0.82, 0.50)
			"gate_arch":   col = Color(0.95, 0.40, 0.35, 0.60)
			"radar":       col = Color(0.55, 0.90, 0.62, 0.55)
			"billboard":   col = Color(0.90, 0.85, 0.35, 0.55)
			"metro":       col = Color(0.60, 0.55, 0.90, 0.60)
		draw_circle(pos, r, Color(col.r, col.g, col.b, 0.13))
		draw_arc(pos, r, 0, TAU, 28, col, 2.5)
		draw_string(ThemeDB.fallback_font, pos + Vector2(-30, r + 26),
			str(lm.get("name", "")), HORIZONTAL_ALIGNMENT_CENTER, 60, 22,
			Color(col.r, col.g, col.b, 0.85))

# ── 查询接口（供 HUD / 小地图用）─────────────────────────
func world_bounds() -> Rect2:
	var full := world_size_cells * TILE
	return Rect2(Vector2.ZERO, Vector2(full, full))

## 某个世界坐标属于哪个分区
func district_at(pos: Vector2) -> Dictionary:
	var c := Vector2i(int(pos.x / TILE), int(pos.y / TILE))
	for key in districts:
		var d: Dictionary = districts[key]
		var r: Array = d.get("rect", [0, 0, 0, 0])
		if Rect2i(int(r[0]), int(r[1]), int(r[2]), int(r[3])).has_point(c):
			return d
	return {}

## 最近的 POI（名称 + 距离），用于 HUD 导航提示
func nearest_poi(pos: Vector2) -> Dictionary:
	var best := {}
	var best_d := INF
	for p in pois:
		var o: Vector2i = p["origin"]
		var g = p["gen"]
		var center := Vector2(
			(o.x + g.cfg.width * 0.5) * TILE, (o.y + g.cfg.height * 0.5) * TILE)
		var d := pos.distance_to(center)
		if d < best_d:
			best_d = d
			best = {"def": p["def"], "center": center, "dist": d}
	return best

func _collect_stats() -> void:
	var total_containers := 0
	var by_type := {"open": 0, "pvp": 0}
	var by_tier := {}
	for p in pois:
		total_containers += p["gen"].containers.size()
		var t := str(p["def"].get("type", "open"))
		by_type[t] = int(by_type.get(t, 0)) + 1
		var dk := str(p["def"].get("district", ""))
		var tier: int = int(districts.get(dk, {}).get("tier", 0))
		by_tier[tier] = int(by_tier.get(tier, 0)) + 1
	stats["world_cells"] = "%d×%d" % [world_size_cells, world_size_cells]
	stats["world_km"] = "%.1f×%.1f km" % [
		world_size_cells * 5.0 / 1000.0, world_size_cells * 5.0 / 1000.0]
	stats["districts"] = districts.size()
	stats["pois"] = pois.size()
	stats["poi_by_type"] = by_type
	stats["poi_by_tier"] = by_tier
	stats["containers"] = total_containers
	stats["wall_bodies"] = _walls_root.get_child_count()
	stats["entrances_total"] = _count_entrances()
	stats["spawn"] = spawn_point

## 地表网格线 —— 移动参照系。
##
## 为什么需要：2D 俯视 + 大地图开阔地里，纯色地面让人完全感知不到自己在移动
## （走了 5 秒还是同一片灰）。网格提供固定参照物，让位移变得可读。
##
## 双层设计：
##   - 细格（50 米）：短距离位移感，走一格 ≈ 3 秒
##   - 粗格（250 米）：大尺度定位，配合坐标标签能快速判断"我在图上哪"
## 尺寸取整为米数而非格数，方便和视距（57 米）、POI 尺寸（200–320 米）对照。
func _draw_ground_grid(full: float) -> void:
	if not Tuning.show_ground_grid:
		return
	var fine_px: float = Tuning.grid_fine_m * PX_PER_M
	var coarse_px: float = Tuning.grid_coarse_m * PX_PER_M
	var fine_col := Color(1, 1, 1, 0.055)
	var coarse_col := Color(0.62, 0.78, 0.95, 0.16)

	# 细格
	var x := 0.0
	while x <= full:
		_bg.draw_line(Vector2(x, 0), Vector2(x, full), fine_col, 1.5)
		x += fine_px
	var y := 0.0
	while y <= full:
		_bg.draw_line(Vector2(0, y), Vector2(full, y), fine_col, 1.5)
		y += fine_px

	# 粗格 + 坐标标签
	var font := ThemeDB.fallback_font
	var gx := 0.0
	var col_idx := 0
	while gx <= full:
		_bg.draw_line(Vector2(gx, 0), Vector2(gx, full), coarse_col, 4.0)
		gx += coarse_px
		col_idx += 1
	var gy := 0.0
	var row_idx := 0
	while gy <= full:
		_bg.draw_line(Vector2(0, gy), Vector2(full, gy), coarse_col, 4.0)
		gy += coarse_px
		row_idx += 1

	# 网格坐标标签（棋盘式 A1/B2…），大图导航用
	if not Tuning.show_grid_labels:
		return
	var cols: int = int(ceil(full / coarse_px))
	var lbl_col := Color(0.70, 0.82, 0.96, 0.30)
	for cy in cols:
		for cx in cols:
			var pos := Vector2(cx * coarse_px + 12.0, cy * coarse_px + 52.0)
			var tag := "%s%d" % [char(65 + (cx % 26)), cy + 1]
			_bg.draw_string(font, pos, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 44, lbl_col)

func poi_clearance_m(a: Dictionary, b: Dictionary) -> float:
	var ra: Rect2 = a["rect"]
	var rb: Rect2 = b["rect"]
	var sep_x: float = maxf(0.0, maxf(ra.position.x - rb.end.x, rb.position.x - ra.end.x))
	var sep_y: float = maxf(0.0, maxf(ra.position.y - rb.end.y, rb.position.y - ra.end.y))
	if sep_x <= 0.0 and sep_y <= 0.0:
		return 0.0
	if sep_x <= 0.0:
		return sep_y / PX_PER_M
	if sep_y <= 0.0:
		return sep_x / PX_PER_M
	return Vector2(sep_x, sep_y).length() / PX_PER_M

func _count_entrances() -> int:
	var n := 0
	for p in pois:
		n += p["gen"].entrances.size()
	return n
