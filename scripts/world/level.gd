extends Node2D
## Level · 基础关卡（程序化构建）
##
## 用字符网格描述布局而不是 TileMap，理由：布局全在一份可读表里，改一个字符就换布局，
## 大锤不用开编辑器拖格子。将来接美术时把渲染层换成 TileMap 即可，碰撞/遮挡逻辑不变。
##
## 性能取舍：地板与墙面**单节点自绘**（不是每格一个 ColorRect），
## 墙体碰撞按**横向连续段合并**成长条 StaticBody2D —— 节点数从数百降到数十，
## 且光照阴影边缘更干净（避免相邻方块间的缝隙漏光）。
##
## 布局意图（本版验证目标）：
##   - **室内小房间群**：验证扇形视野在狭窄空间的门框窥视、拐角遭遇
##   - **长走廊**：验证视野范围与"看得见但打不着"的距离感
##   - **中庭开阔地**：验证开阔地的视野劣势（谁先看见谁）
##   - **右下 L4 免保柜独立小间**：验证"长读条 + 单一入口"的高风险高回报点位
## 容器摆位遵循母版 tier 原则：地点人定、越深越肥（见 局内/设计/tier-system.md §2）

const TILE := 40.0

## '#' 墙 ｜ '.' 地板 ｜ '1'~'4' 容器档位（L1 民用 → L4 免保）｜ 'P' 出生点
const MAP := [
	"###########################################",
	"#....#........#....#..........#...........#",
	"#.1..#...2....#.1..#....1.....#....2......#",
	"#....#........#....#..........#...........#",
	"#....######.###....###..###...#....####...#",
	"#....#........#......#....#...#.......#...#",
	"#..P.#...1....#..3...#..1.#...#...1...#...#",
	"#....#........#......#....#...#.......#...#",
	"######...######.######....#####.......#####",
	"#........#..............#.............#...#",
	"#...2....#....1.........#....2........#.4.#",
	"#........#..............#.............#...#",
	"#..#######..............#######.#######...#",
	"#..#..........................#.......#...#",
	"#..#...1...3.......1..........#...3...#####",
	"#..#..........................#.......#...#",
	"#..####################.#######.......#.1.#",
	"#......#..............#.......#.......#...#",
	"#...1..#.....2........#...1...#...2...#...#",
	"#......#..............#.......#.......#...#",
	"###########################################",
]

const COL_FLOOR := Color(0.155, 0.165, 0.195)
const COL_FLOOR_ALT := Color(0.175, 0.185, 0.215)
const COL_WALL := Color(0.30, 0.32, 0.38)
const COL_WALL_EDGE := Color(0.20, 0.22, 0.27)

var container_script := preload("res://scripts/world/loot_container.gd")
var spawn_point := Vector2.ZERO

var _floor_cells: Array[Vector2i] = []
var _wall_runs: Array[Rect2] = []   ## 合并后的墙段（世界坐标）

func _ready() -> void:
	z_index = -5
	_parse_map()
	_build_wall_bodies()

func _parse_map() -> void:
	for y in MAP.size():
		var row: String = MAP[y]
		for x in row.length():
			var ch := row[x]
			var pos := Vector2(x * TILE + TILE * 0.5, y * TILE + TILE * 0.5)
			match ch:
				"#":
					pass  # 墙在 _build_wall_bodies 里按段合并
				"P":
					spawn_point = pos
					_floor_cells.append(Vector2i(x, y))
				"1", "2", "3", "4":
					_floor_cells.append(Vector2i(x, y))
					_add_container(pos, "L" + ch)
				_:
					_floor_cells.append(Vector2i(x, y))

## 横向扫描，把连续的 '#' 合并成一个长条
func _build_wall_bodies() -> void:
	var walls := Node2D.new()
	walls.name = "Walls"
	add_child(walls)

	for y in MAP.size():
		var row: String = MAP[y]
		var run_start := -1
		for x in row.length() + 1:
			var is_wall := x < row.length() and row[x] == "#"
			if is_wall and run_start < 0:
				run_start = x
			elif not is_wall and run_start >= 0:
				var w := (x - run_start) * TILE
				var rect := Rect2(Vector2(run_start * TILE, y * TILE), Vector2(w, TILE))
				_wall_runs.append(rect)
				_add_wall_body(walls, rect)
				run_start = -1
	queue_redraw()

func _add_wall_body(parent: Node, rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.position = rect.position + rect.size * 0.5
	# world(层1) + vision_blocker(层4)：既挡人也挡视线
	body.collision_layer = (1 << 0) | (1 << 3)
	body.collision_mask = 0

	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = rect.size
	shape.shape = box
	body.add_child(shape)

	# 视线遮挡体：让 PointLight2D 的阴影把墙后切掉
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var h := rect.size * 0.5
	poly.polygon = PackedVector2Array([
		Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)
	])
	poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
	occ.occluder = poly
	body.add_child(occ)

	parent.add_child(body)

func _draw() -> void:
	# 地板：棋盘格微差，给俯视角一个空间尺度参照（否则纯色地面无法判断移速）
	for c in _floor_cells:
		var col := COL_FLOOR if (c.x + c.y) % 2 == 0 else COL_FLOOR_ALT
		draw_rect(Rect2(Vector2(c.x * TILE, c.y * TILE), Vector2(TILE, TILE)), col, true)
	# 墙面
	for r in _wall_runs:
		draw_rect(r, COL_WALL, true)
		draw_rect(r, COL_WALL_EDGE, false, 2.0)

func _add_container(pos: Vector2, richness: String) -> void:
	# 无类型变量：GDScript 对强类型 Node 访问脚本自定义属性是编译期错误
	var c = Area2D.new()
	c.set_script(container_script)
	c.position = pos
	c.richness = richness
	add_child(c)

func world_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(MAP[0].length() * TILE, MAP.size() * TILE))
