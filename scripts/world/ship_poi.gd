class_name ShipPoi
extends RefCounted
## 飞船内部 POI · 田字形 + 操控室（船体边缘驾驶座）+ 密闭舱
##
## 规范见 demo-2d/关卡设计规范.md §二。在 PoiGenerator 骨架上后处理：
##   - 左右舷沿真实横向主路开传送门
##   - 中央操控室贴横向主路，只有西/东两个门
##   - 右上密闭舱独立房间，南墙单门接到甬道
##   - 最后从传送门洪泛，给孤立房间补通路

const W := 40
const H := 20
const SOLID := "#"
const FLOOR := "."

const SEALED_ITEMS := [
	"masterpiece", "quantum_storage", "corp_secrets", "neural_link",
]

static func generate() -> Dictionary:
	var cfg := PoiGenerator.Config.new()
	cfg.width = W
	cfg.height = H
	cfg.seed = 880001
	cfg.place_spawn = false
	cfg.main_rows = 2
	cfg.main_cols = 2
	cfg.corridor_w = 3
	cfg.corridor_jitter = 1
	cfg.interconnect_chance = 0.18
	cfg.atrium_count = 1
	cfg.entrances = 0
	cfg.solid_room_chance = 0.06
	cfg.containers_l1 = 2
	cfg.containers_l2 = 4
	cfg.containers_l3 = 5
	cfg.containers_l4 = 1
	var gen := PoiGenerator.new(cfg)
	if not gen.generate():
		push_warning("ShipPoi: generator failed, using fallback")
		_fallback_grid(gen)

	var road_y: int = _pick_horizontal_road(gen)
	var left_portal := Vector2i(2, road_y)
	var right_portal := Vector2i(W - 3, road_y)
	_carve_left_right_entrances(gen, road_y)
	var ctrl_data: Dictionary = _build_control_room(gen, road_y)
	var ctrl: Rect2i = ctrl_data["rect"]
	var sealed := _build_sealed_cabin(gen)
	_ensure_connected(gen, [left_portal, right_portal])

	var sealed_spots: Array[Vector2i] = []
	var inner := Rect2i(sealed.position + Vector2i(1, 1), sealed.size - Vector2i(2, 2))
	var candidates := [
		inner.position,
		Vector2i(inner.end.x - 1, inner.position.y),
		Vector2i(inner.position.x, inner.end.y - 1),
		Vector2i(inner.end.x - 1, inner.end.y - 1),
	]
	for c in candidates:
		if _is_walkable(gen, c.x, c.y):
			sealed_spots.append(c)
	while sealed_spots.size() < 4:
		sealed_spots.append(Vector2i(inner.position.x + sealed_spots.size() % inner.size.x,
			inner.position.y + 1))

	return {
		"gen": gen,
		"control_rect": ctrl,
		"seat_cell": ctrl_data["seat"],
		"sealed_rect": sealed,
		"left_portal_cell": left_portal,
		"right_portal_cell": right_portal,
		"sealed_items": SEALED_ITEMS.duplicate(),
		"sealed_spots": sealed_spots,
	}

static func _fallback_grid(gen: PoiGenerator) -> void:
	gen.grid = []
	gen.corridor_cells.clear()
	for y in H:
		var row: Array = []
		row.resize(W)
		for x in W:
			var edge := x == 0 or y == 0 or x == W - 1 or y == H - 1
			row[x] = SOLID if edge else FLOOR
		gen.grid.append(row)
	# 十字甬道，保证 fallback 也可走
	for x in range(1, W - 1):
		gen.grid[10][x] = FLOOR
		gen.corridor_cells.append(Vector2i(x, 10))
	for y in range(1, H - 1):
		gen.grid[y][13] = FLOOR
		gen.grid[y][26] = FLOOR

static func _pick_horizontal_road(gen: PoiGenerator) -> int:
	if gen._road_rows.size() > 0:
		var best: int = gen._road_rows[0]
		var best_d: int = absi(best + 1 - H / 2)
		for y in gen._road_rows:
			var d: int = absi(y + 1 - H / 2)
			if d < best_d:
				best_d = d
				best = y
		return clampi(best + 1, 2, H - 3)  # 3 格宽主路的中行
	return 10

static func _set_cell(gen: PoiGenerator, x: int, y: int, ch: String) -> void:
	if x < 0 or y < 0 or x >= W or y >= H:
		return
	gen.grid[y][x] = ch

static func _at(gen: PoiGenerator, x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= W or y >= H:
		return SOLID
	return str(gen.grid[y][x])

static func _is_walkable(gen: PoiGenerator, x: int, y: int) -> bool:
	var ch := _at(gen, x, y)
	return ch != SOLID and ch != ""

## 沿真实横向主路凿穿左右舷，并保证入口接到主路
static func _carve_left_right_entrances(gen: PoiGenerator, road_y: int) -> void:
	for dy in [-1, 0, 1]:
		var y: int = clampi(road_y + dy, 1, H - 2)
		for x in [0, 1, 2, 3]:
			_set_cell(gen, x, y, FLOOR)
		for x in [W - 1, W - 2, W - 3, W - 4]:
			_set_cell(gen, x, y, FLOOR)

## 操控室贴北舷左缘：8×5，南墙单门接到横向主路。驾驶座在靠船体一侧。
static func _build_control_room(gen: PoiGenerator, road_y: int) -> Dictionary:
	var room := Rect2i(2, 1, 8, 5)
	for y in range(room.position.y, room.end.y):
		for x in range(room.position.x, room.end.x):
			_set_cell(gen, x, y, FLOOR)
	for y in range(room.position.y - 1, room.end.y + 1):
		_set_cell(gen, room.position.x - 1, y, SOLID)
		_set_cell(gen, room.end.x, y, SOLID)
	for x in range(room.position.x - 1, room.end.x + 1):
		_set_cell(gen, x, room.position.y - 1, SOLID)
		_set_cell(gen, x, room.end.y, SOLID)
	var door_x: int = room.position.x + room.size.x / 2
	_set_cell(gen, door_x, room.end.y - 1, FLOOR)
	_set_cell(gen, door_x, room.end.y, FLOOR)
	_set_cell(gen, door_x - 1, room.end.y, FLOOR)
	_set_cell(gen, door_x + 1, room.end.y, FLOOR)
	var y: int = room.end.y
	while y < road_y:
		y += 1
		_set_cell(gen, door_x, y, FLOOR)
		_set_cell(gen, door_x - 1, y, FLOOR)
		_set_cell(gen, door_x + 1, y, FLOOR)
	var seat := Vector2i(room.position.x + 1, room.position.y + 2)
	_set_cell(gen, seat.x, seat.y, FLOOR)
	return {"rect": room, "seat": seat}

## 密闭舱：右上独立房间，南墙单门接到下方地板
static func _build_sealed_cabin(gen: PoiGenerator) -> Rect2i:
	var room := Rect2i(28, 2, 9, 6)
	for y in range(room.position.y - 1, room.end.y + 1):
		for x in range(room.position.x - 1, room.end.x + 1):
			if x >= 0 and y >= 0 and x < W and y < H:
				_set_cell(gen, x, y, SOLID)
	for y in range(room.position.y + 1, room.end.y - 1):
		for x in range(room.position.x + 1, room.end.x - 1):
			_set_cell(gen, x, y, FLOOR)
	var door_x := room.position.x + room.size.x / 2
	_set_cell(gen, door_x, room.end.y - 1, FLOOR)
	_set_cell(gen, door_x, room.end.y, FLOOR)
	for d in range(1, 4):
		_set_cell(gen, door_x, room.end.y + d, FLOOR)
		_set_cell(gen, door_x - 1, room.end.y + d, FLOOR)
		_set_cell(gen, door_x + 1, room.end.y + d, FLOOR)
	return room

## 从传送门洪泛；孤立地板用 L 形通路接到最近可达格
static func _ensure_connected(gen: PoiGenerator, seeds: Array[Vector2i]) -> void:
	var reachable := _flood(gen, seeds)
	for _i in 24:
		var orphan := _first_orphan(gen, reachable)
		if orphan.x < 0:
			return
		var target := _nearest_reachable(orphan, reachable)
		if target.x < 0:
			_set_cell(gen, orphan.x, orphan.y, SOLID)
			continue
		_carve_l_path(gen, orphan, target)
		reachable = _flood(gen, seeds)

static func _flood(gen: PoiGenerator, seeds: Array[Vector2i]) -> Dictionary:
	var seen := {}
	var q: Array[Vector2i] = []
	for s in seeds:
		if _is_walkable(gen, s.x, s.y):
			seen[s] = true
			q.append(s)
	var i := 0
	while i < q.size():
		var c: Vector2i = q[i]
		i += 1
		for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = c + d
			if seen.has(n) or not _is_walkable(gen, n.x, n.y):
				continue
			seen[n] = true
			q.append(n)
	return seen

static func _first_orphan(gen: PoiGenerator, reachable: Dictionary) -> Vector2i:
	for y in range(1, H - 1):
		for x in range(1, W - 1):
			var c := Vector2i(x, y)
			if _is_walkable(gen, x, y) and not reachable.has(c):
				return c
	return Vector2i(-1, -1)

static func _nearest_reachable(from: Vector2i, reachable: Dictionary) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := 9999
	for k in reachable.keys():
		var c: Vector2i = k
		var d: int = absi(c.x - from.x) + absi(c.y - from.y)
		if d < bd:
			bd = d
			best = c
	return best

static func _carve_l_path(gen: PoiGenerator, a: Vector2i, b: Vector2i) -> void:
	var x: int = a.x
	var y: int = a.y
	while x != b.x:
		x += 1 if b.x > x else -1
		_set_cell(gen, x, y, FLOOR)
	while y != b.y:
		y += 1 if b.y > y else -1
		_set_cell(gen, x, y, FLOOR)

static func sealed_preview_value(items: Array) -> int:
	var total := 0
	for id in items:
		total += int(GameData.item(str(id)).get("value", 0))
	return total
