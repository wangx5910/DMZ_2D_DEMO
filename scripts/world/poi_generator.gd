class_name PoiGenerator
extends RefCounted
## PoiGenerator · POI 田字形程序化生成器
##
## 结构规范见 demo-2d/关卡设计规范.md §二。核心流程：
##   1. 铺满实心 → 2. 挖田字形主路 → 3. 沿主路挂房间 → 4. 挖门
##   5. 少量互通门 → 6. 中庭 → 7. 房间内掩体 → 8. **连通性洪泛校验**
##   9. 不可达房间填实 → 10. 摆容器
##
## 关键设计：**连通性校验是硬规则**。v0.1 关卡出现过"出生房间与外界不通"的硬伤，
## 本生成器保证任何留在图上的可行走格都从主路可达，不可达的一律填实为墙
## ——宁可少一个房间，也不留半个死房间误导玩家。
##
## 纯数据类（RefCounted），输出字符网格，不碰节点 → 可被服务端/测试复用。

## 格子类型
const SOLID := "#"      ## 墙 / 实心
const FLOOR := "."      ## 可行走
const CORRIDOR := ","    ## 主路（可行走，仅用于生成期区分，最终转 FLOOR）
const SPAWN := "P"
const DOOR := "+"        ## 门（可行走，视觉上标记）

## 生成配置
class Config extends RefCounted:
	var width: int = 60           ## 格
	var height: int = 44
	var corridor_w: int = 3       ## 主路宽度（格）
	var main_rows: int = 2        ## 横向主路条数
	var main_cols: int = 2        ## 纵向主路条数
	var room_min := Vector2i(3, 3)
	var room_max := Vector2i(7, 5)
	var interconnect_chance: float = 0.20   ## 房间互通比例
	var solid_room_chance: float = 0.12     ## 随机填实房间比例（制造不规则轮廓）
	var cover_chance: float = 0.40           ## 房间内摆掩体的比例
	var atrium_count: int = 2                ## 中庭数量
	var corridor_jitter: int = 3             ## 主路偏移量（避免完美对称）
	var place_spawn: bool = true
	## 出入口：在主路端点凿穿外墙。0 = 不开（封闭 POI），-1 = 每条主路两端全开
	var entrances: int = -1
	var seed: int = 0
	## 容器数量按档位（-1 = 自动按面积算）
	var containers_l1: int = -1
	var containers_l2: int = -1
	var containers_l3: int = -1
	var containers_l4: int = 1

var cfg: Config
var grid: Array = []              ## grid[y][x] = 字符
var rooms: Array[Dictionary] = [] ## {rect: Rect2i, doors: Array[Vector2i], solid: bool, depth: int}
var corridor_cells: Array[Vector2i] = []
var entrances: Array[Dictionary] = []   ## {cell, dir} —— 外墙上的通道口
var spawn_cell := Vector2i(-1, -1)
var containers: Array[Dictionary] = []  ## {cell: Vector2i, richness: String}
var _rng := RandomNumberGenerator.new()
var stats := {}

func _init(config: Config = null) -> void:
	cfg = config if config != null else Config.new()

## 生成。失败时自动重试（最多 tries 次），全部失败返回 false
func generate(tries: int = 8) -> bool:
	for attempt in tries:
		_rng.seed = cfg.seed + attempt * 7919 if cfg.seed != 0 else randi()
		if _attempt():
			stats["attempts"] = attempt + 1
			return true
	return false

func _attempt() -> bool:
	rooms.clear()
	corridor_cells.clear()
	entrances.clear()
	containers.clear()
	spawn_cell = Vector2i(-1, -1)
	_fill_solid()
	_carve_main_roads()
	_carve_entrances()          # 凿穿外墙 —— 否则 POI 完全封死进不去
	_place_rooms()
	_jitter_room_sizes()          # 尺寸抖动，制造大小房间层次
	_carve_doors()
	_ensure_room_connectivity()   # 内层房间接力连通（必须在互通门之前）
	_add_interconnects()
	_carve_atriums()
	# 连通性校验必须在掩体之前——掩体不影响连通性但会干扰洪泛判断
	if not _validate_and_prune():
		return false
	_add_covers()
	if cfg.place_spawn and not _place_spawn():
		return false
	_place_containers()
	_collect_stats()
	return true

# ── 1. 铺满实心 ─────────────────────────────────────────
func _fill_solid() -> void:
	grid = []
	for y in cfg.height:
		var row := []
		row.resize(cfg.width)
		row.fill(SOLID)
		grid.append(row)

func _in_bounds(x: int, y: int) -> bool:
	return x >= 1 and y >= 1 and x < cfg.width - 1 and y < cfg.height - 1

func _put(x: int, y: int, ch: String) -> void:
	if _in_bounds(x, y):
		grid[y][x] = ch

func _at(x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= cfg.width or y >= cfg.height:
		return SOLID
	return grid[y][x]

func _walkable(ch: String) -> bool:
	return ch == FLOOR or ch == CORRIDOR or ch == SPAWN or ch == DOOR

# ── 2. 田字形主路 ───────────────────────────────────────
## 主路带随机偏移，避免完美对称的"网格感"（规范 §2.4 手段四）
var _road_rows: Array[int] = []
var _road_cols: Array[int] = []

func _carve_main_roads() -> void:
	_road_rows.clear()
	_road_cols.clear()
	var w := cfg.corridor_w
	var jit := cfg.corridor_jitter

	# 横向主路：把高度均分为 main_rows+1 段，主路落在分界处
	for i in range(1, cfg.main_rows + 1):
		var base: int = int(round(float(cfg.height) * i / (cfg.main_rows + 1)))
		var y: int = clampi(base + _rng.randi_range(-jit, jit), 2, cfg.height - w - 2)
		_road_rows.append(y)
		for dy in w:
			for x in range(1, cfg.width - 1):
				_put(x, y + dy, CORRIDOR)

	# 纵向主路
	for i in range(1, cfg.main_cols + 1):
		var base2: int = int(round(float(cfg.width) * i / (cfg.main_cols + 1)))
		var x2: int = clampi(base2 + _rng.randi_range(-jit, jit), 2, cfg.width - w - 2)
		_road_cols.append(x2)
		for dx in w:
			for y2 in range(1, cfg.height - 1):
				_put(x2 + dx, y2, CORRIDOR)

	for y in cfg.height:
		for x in cfg.width:
			if grid[y][x] == CORRIDOR:
				corridor_cells.append(Vector2i(x, y))

# ── 2.5 出入口（凿穿外墙）───────────────────────────────
## 在每条主路的端点把外墙凿穿，形成通往 POI 外部的通道。
##
## 为什么必须有：`_in_bounds()` 把最外圈一整环锁成墙（防止越界写入），
## 主路挖到边界前一格就停了 —— 结果 POI 是个完全封死的盒子，玩家进不去也出不来。
## 按大锤要求**不做门，直接是敞开通道**（宽度 = 主路宽），
## 这样入口在视觉与玩法上都是"缺口"，远处就能看出哪里能进。
##
## 通道口同时是战术要点：搜打撤里"守出入口"和"换个口进"是核心博弈，
## 所以入口位置需要可读、且一个 POI 有多个（默认全开 = 每条主路两端）。
func _carve_entrances() -> void:
	var w := cfg.corridor_w
	if cfg.entrances == 0:
		return

	var slots: Array[Dictionary] = []
	# 横向主路 → 左右两端各一个口
	for y in _road_rows:
		slots.append({"axis": "h", "at": y, "side": -1})   # 西
		slots.append({"axis": "h", "at": y, "side": 1})    # 东
	# 纵向主路 → 上下两端各一个口
	for x in _road_cols:
		slots.append({"axis": "v", "at": x, "side": -1})   # 北
		slots.append({"axis": "v", "at": x, "side": 1})    # 南

	if cfg.entrances > 0 and slots.size() > cfg.entrances:
		slots.shuffle()
		slots.resize(cfg.entrances)

	for sl in slots:
		var axis: String = sl["axis"]
		var at: int = sl["at"]
		var side: int = sl["side"]
		if axis == "h":
			# 凿穿左/右外墙：把 x=0 或 x=width-1 那一列在主路宽度上打通
			var ex: int = 0 if side < 0 else cfg.width - 1
			for dy in w:
				var yy: int = at + dy
				if yy <= 0 or yy >= cfg.height - 1:
					continue
				grid[yy][ex] = CORRIDOR      # 直接写，绕过 _in_bounds 的边界锁
				corridor_cells.append(Vector2i(ex, yy))
			entrances.append({
				"cell": Vector2i(ex, at + int(w / 2)),
				"dir": Vector2i(-1 if side < 0 else 1, 0),
			})
		else:
			var ey: int = 0 if side < 0 else cfg.height - 1
			for dx in w:
				var xx: int = at + dx
				if xx <= 0 or xx >= cfg.width - 1:
					continue
				grid[ey][xx] = CORRIDOR
				corridor_cells.append(Vector2i(xx, ey))
			entrances.append({
				"cell": Vector2i(at + int(w / 2), ey),
				"dir": Vector2i(0, -1 if side < 0 else 1),
			})
	stats["entrances"] = entrances.size()

# ── 3. 沿主路挂房间 ─────────────────────────────────────
## 把主路分割出的每个"街区"填成房间。房间之间留 1 格公共墙（供互通门用）。
func _place_rooms() -> void:
	var w := cfg.corridor_w
	# 街区边界：主路把地图切成若干块。
	# **关键**：街区要从主路边缘再内缩 1 格，留出隔墙 —— 否则房间直接贴着主路，
	# 门位候选（要求"该格是墙且外侧是主路"）永远找不到，一个门都挖不出来，
	# 房间只能靠边界重合"自然连通"，单入口/互通的设计意图全部失效。
	var y_bounds: Array[int] = [1]
	for y in _road_rows:
		y_bounds.append(y - 1)      # 主路上沿再留 1 格墙
		y_bounds.append(y + w + 1)  # 主路下沿再留 1 格墙
	y_bounds.append(cfg.height - 1)

	var x_bounds: Array[int] = [1]
	for x in _road_cols:
		x_bounds.append(x - 1)
		x_bounds.append(x + w + 1)
	x_bounds.append(cfg.width - 1)

	# 成对取块：(0,1) (2,3) (4,5)...
	var by := 0
	while by + 1 < y_bounds.size():
		var y0: int = y_bounds[by]
		var y1: int = y_bounds[by + 1]
		var bx := 0
		while bx + 1 < x_bounds.size():
			var x0: int = x_bounds[bx]
			var x1: int = x_bounds[bx + 1]
			if y1 - y0 >= cfg.room_min.y and x1 - x0 >= cfg.room_min.x:
				_fill_block_with_rooms(Rect2i(x0, y0, x1 - x0, y1 - y0))
			bx += 2
		by += 2

## 在一个街区内切出若干房间。
##
## 结构：**双排背靠背** —— 街区的两条长边各排一列房间（都贴主路，都能开单入口门），
## 中间若有剩余厚度就留作实心承重带。这是三角洲行政楼那类建筑的真实结构：
## 走廊两侧各一排办公室，背靠背共用一道墙。
##
## 走过的弯路：
##  - 切成 2×2 网格 → 内层房间不贴主路，只能借邻居接力 → 单入口率崩到 43%
##  - 只切单排 → 街区中间大片浪费成实心，地板率只有 44%，像三条平行长廊
func _fill_block_with_rooms(block: Rect2i) -> void:
	if block.size.x < cfg.room_min.x or block.size.y < cfg.room_min.y:
		return

	var horizontal: bool = block.size.x >= block.size.y
	var span: int = block.size.x if horizontal else block.size.y
	var thick: int = block.size.y if horizontal else block.size.x
	var span_min: int = cfg.room_min.x if horizontal else cfg.room_min.y
	var span_max: int = cfg.room_max.x if horizontal else cfg.room_max.y
	var depth_min: int = cfg.room_min.y if horizontal else cfg.room_min.x
	var depth_max: int = cfg.room_max.y if horizontal else cfg.room_max.x

	# 决定排几列：厚度够两排就背靠背，否则单排占满
	var two_rows: bool = thick >= depth_min * 2 + 1
	var d1: int = thick
	var d2: int = 0
	if two_rows:
		d1 = clampi(int(round(thick * _rng.randf_range(0.42, 0.58))), depth_min, depth_max)
		d2 = thick - d1 - 1   # -1 = 背靠背的公共墙
		if d2 < depth_min:
			# 放不下第二排就退回单排，把厚度全用掉（避免浪费成实心）
			two_rows = false
			d1 = mini(thick, depth_max * 2)
	else:
		d1 = thick

	_lay_room_row(block, horizontal, 0, d1, span, span_min, span_max)
	if two_rows and d2 >= depth_min:
		_lay_room_row(block, horizontal, d1 + 1, d2, span, span_min, span_max)

## 沿街区一条边排一列房间。offset = 距街区起始边的厚度偏移
func _lay_room_row(block: Rect2i, horizontal: bool, offset: int, depth: int,
		span: int, span_min: int, span_max: int) -> void:
	var cursor := 0
	while cursor < span:
		var remain: int = span - cursor
		if remain < span_min:
			break
		var w: int = mini(_rng.randi_range(span_min, span_max), remain)
		# 剩下的塞不出一间了就并入当前间，避免留下过窄的碎片
		if remain - w > 0 and remain - w < span_min + 1:
			w = remain
		var rect: Rect2i
		if horizontal:
			rect = Rect2i(block.position.x + cursor, block.position.y + offset, w, depth)
		else:
			rect = Rect2i(block.position.x + offset, block.position.y + cursor, depth, w)

		# 规范 §2.4 手段一：随机填实（承重墙/设备间），制造不规则轮廓
		var is_solid: bool = _rng.randf() < cfg.solid_room_chance
		if not is_solid:
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					_put(x, y, FLOOR)
		rooms.append({"rect": rect, "doors": [], "solid": is_solid, "depth": 0})
		cursor += w + 1   # +1 = 相邻房间的公共墙

## 房间尺寸抖动：把过大的房间随机切成一大一小两间，制造尺寸层次。
## 不做这步的话，所有房间会是同一尺寸的一排排"仓库"，缺少三角洲行政楼
## 那种大小房间混杂的层次感。切出的小间靠 _ensure_room_connectivity 接力连通。
func _jitter_room_sizes() -> void:
	var split := 0
	var src := rooms.duplicate()
	for room in src:
		if room["solid"]:
			continue
		var rect: Rect2i = room["rect"]
		# 只切"深"的方向：房间沿主路排成一排，切深度方向能得到
		# 「靠主路的浅间 + 里侧的深间」，浅间仍直连主路，深间借浅间进——
		# 这正是我们想要的"套间"结构，深间天然是最好的 L4 位置。
		var horizontal: bool = rect.size.x >= rect.size.y
		var can_split: bool = (rect.size.y >= cfg.room_min.y * 2 + 1) if horizontal \
			else (rect.size.x >= cfg.room_min.x * 2 + 1)
		if not can_split or _rng.randf() > 0.35:
			continue
		if horizontal:
			var cut: int = rect.position.y + _rng.randi_range(cfg.room_min.y, rect.size.y - cfg.room_min.y - 1)
			for x in range(rect.position.x, rect.end.x):
				_put(x, cut, SOLID)
			var top := Rect2i(rect.position, Vector2i(rect.size.x, cut - rect.position.y))
			var bot := Rect2i(Vector2i(rect.position.x, cut + 1), Vector2i(rect.size.x, rect.end.y - cut - 1))
			room["rect"] = top
			rooms.append({"rect": bot, "doors": [], "solid": false, "depth": 0})
		else:
			var cut2: int = rect.position.x + _rng.randi_range(cfg.room_min.x, rect.size.x - cfg.room_min.x - 1)
			for y in range(rect.position.y, rect.end.y):
				_put(cut2, y, SOLID)
			var left := Rect2i(rect.position, Vector2i(cut2 - rect.position.x, rect.size.y))
			var right := Rect2i(Vector2i(cut2 + 1, rect.position.y), Vector2i(rect.end.x - cut2 - 1, rect.size.y))
			room["rect"] = left
			rooms.append({"rect": right, "doors": [], "solid": false, "depth": 0})
		split += 1
	stats["rooms_split"] = split

# ── 4. 挖门（单入口为主）─────────────────────────────────
func _carve_doors() -> void:
	for room in rooms:
		if room["solid"]:
			continue
		var cands: Array[Dictionary] = []
		_gather_door_candidates(room["rect"], cands)
		if cands.is_empty():
			continue
		# 单入口：只挖一个门
		var pick: Dictionary = cands[_rng.randi() % cands.size()]
		var cell: Vector2i = pick["cell"]
		_put(cell.x, cell.y, DOOR)
		room["doors"].append(cell)

## 门位有效条件：该格是墙，且它的外侧邻格是主路
func _try_door_candidate(out: Array, cell: Vector2i, dir: Vector2i) -> void:
	if not _in_bounds(cell.x, cell.y):
		return
	if _at(cell.x, cell.y) != SOLID:
		return
	var outside := cell + dir
	if _at(outside.x, outside.y) == CORRIDOR:
		out.append({"cell": cell, "dir": dir})

## 保证每个房间都能连通：贴主路的直连，内层房间通过邻居房间接力。
## 不这么做的话，被其他房间包围的内层房间永远挖不到门 → 全被连通性校验剪掉，
## 结果是 POI 只剩沿主路一圈房间，中间全是实心。
##
## 关键约束：**只开必要的最少门**。每个孤立房间只接一个门就停——多开会让所有房间
## 互相打通，"进房间＝进死角"的紧张感就没了（实测过头会把单入口率从 83% 压到 33%）。
func _ensure_room_connectivity() -> void:
	var linked := {}
	for i in rooms.size():
		if not rooms[i]["solid"] and rooms[i]["doors"].size() > 0:
			linked[i] = true

	# 第一步：再给没门的房间一次直连主路的机会。
	# 房间被 _jitter_room_sizes 切碎后边界变了，可能新贴上了主路。
	var direct := 0
	for i in rooms.size():
		var r: Dictionary = rooms[i]
		if r["solid"] or linked.has(i):
			continue
		var cands: Array[Dictionary] = []
		_gather_door_candidates(r["rect"], cands)
		if cands.is_empty():
			continue
		var pick: Dictionary = cands[_rng.randi() % cands.size()]
		var c: Vector2i = pick["cell"]
		_put(c.x, c.y, DOOR)
		r["doors"].append(c)
		linked[i] = true
		direct += 1
	stats["direct_doors_2nd"] = direct

	# 第二步：仍孤立的（真正的内层房间）借邻居接力，每间只开一扇。
	# 借道时**优先挑已经是多入口的邻居** —— 它已经不算单入口了，
	# 再开一扇门不会额外损失单入口率。这一条把单入口率从 46% 拉回 70%+。
	var relay := 0
	var progress := true
	while progress:
		progress = false
		for i in rooms.size():
			var a: Dictionary = rooms[i]
			if a["solid"] or linked.has(i):
				continue
			if a["doors"].size() > 0:
				linked[i] = true
				continue
			var best_j := -1
			var best_doors := -1
			for j in rooms.size():
				if i == j or not linked.has(j):
					continue
				var b: Dictionary = rooms[j]
				if b["solid"]:
					continue
				if _shared_wall(a["rect"], b["rect"]).is_empty():
					continue
				var dn: int = b["doors"].size()
				if dn > best_doors:
					best_doors = dn
					best_j = j
			if best_j < 0:
				continue
			var wall := _shared_wall(a["rect"], rooms[best_j]["rect"])
			var cell: Vector2i = wall[_rng.randi() % wall.size()]
			_put(cell.x, cell.y, DOOR)
			a["doors"].append(cell)
			rooms[best_j]["doors"].append(cell)
			linked[i] = true
			relay += 1
			progress = true
	stats["relay_doors"] = relay
	stats["unlinked_rooms"] = rooms.size() - linked.size()

## 收集一个房间四周所有能通往主路的门位候选
func _gather_door_candidates(rect: Rect2i, out: Array) -> void:
	for x in range(rect.position.x, rect.end.x):
		_try_door_candidate(out, Vector2i(x, rect.position.y - 1), Vector2i(0, -1))
		_try_door_candidate(out, Vector2i(x, rect.end.y), Vector2i(0, 1))
	for y in range(rect.position.y, rect.end.y):
		_try_door_candidate(out, Vector2i(rect.position.x - 1, y), Vector2i(-1, 0))
		_try_door_candidate(out, Vector2i(rect.end.x, y), Vector2i(1, 0))

# ── 5. 少量互通门（规范 §2.2 规则 3）────────────────────
## 只在双方都还是单入口时才开，保证"单入口 80% / 互通 20%"的目标比例。
## 不加这个约束的话，接力门 + 互通门会叠加，把大多数房间变成多入口。
func _add_interconnects() -> void:
	var added := 0
	# 每扇互通门会让 **两间** 房间变成多入口，所以目标门数 = 目标多入口房间数 / 2。
	# 不除 2 的话实际多入口率会是配置值的两倍。
	var target: int = int(round(cfg.interconnect_chance * _open_room_count() * 0.5))
	for i in rooms.size():
		if added >= target:
			break
		var a: Dictionary = rooms[i]
		if a["solid"] or a["doors"].size() != 1:
			continue
		for j in range(i + 1, rooms.size()):
			var b: Dictionary = rooms[j]
			if b["solid"] or b["doors"].size() != 1:
				continue
			var wall := _shared_wall(a["rect"], b["rect"])
			if wall.is_empty():
				continue
			var cell: Vector2i = wall[_rng.randi() % wall.size()]
			_put(cell.x, cell.y, DOOR)
			a["doors"].append(cell)
			b["doors"].append(cell)
			added += 1
			break
	stats["interconnects"] = added

func _open_room_count() -> int:
	var n := 0
	for r in rooms:
		if not r["solid"]:
			n += 1
	return n

## 两个矩形之间的公共墙格（相隔恰好 1 格）
func _shared_wall(a: Rect2i, b: Rect2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	# 水平相邻
	if a.end.x + 1 == b.position.x or b.end.x + 1 == a.position.x:
		var wx: int = a.end.x if a.end.x + 1 == b.position.x else b.end.x
		var y0: int = maxi(a.position.y, b.position.y)
		var y1: int = mini(a.end.y, b.end.y)
		for y in range(y0, y1):
			out.append(Vector2i(wx, y))
	# 垂直相邻
	elif a.end.y + 1 == b.position.y or b.end.y + 1 == a.position.y:
		var wy: int = a.end.y if a.end.y + 1 == b.position.y else b.end.y
		var x0: int = maxi(a.position.x, b.position.x)
		var x1: int = mini(a.end.x, b.end.x)
		for x in range(x0, x1):
			out.append(Vector2i(x, wy))
	return out

# ── 6. 中庭（规范 §2.4 手段二）──────────────────────────
## 挖掉相邻的 2–3 个房间形成开阔厅，破坏网格节奏
func _carve_atriums() -> void:
	var made := 0
	var tries := 0
	while made < cfg.atrium_count and tries < 40:
		tries += 1
		if rooms.size() < 3:
			break
		var i := _rng.randi() % rooms.size()
		var a: Dictionary = rooms[i]
		if a["solid"]:
			continue
		var merged := false
		for j in rooms.size():
			if j == i:
				continue
			var b: Dictionary = rooms[j]
			if b["solid"]:
				continue
			var wall := _shared_wall(a["rect"], b["rect"])
			if wall.size() < 2:
				continue
			# 打通整面公共墙 → 两间合成一个厅
			for cell in wall:
				_put(cell.x, cell.y, FLOOR)
			a["atrium"] = true
			b["atrium"] = true
			merged = true
			break
		if merged:
			made += 1
	stats["atriums"] = made

# ── 7. 房间内掩体（规范 §2.4 手段三）───────────────────
## 房间内摆 1–2 个独立小墙块（柱子/货架），让房间内部也有视线遮断
func _add_covers() -> void:
	var placed := 0
	for room in rooms:
		if room["solid"] or room.get("atrium", false):
			continue
		if _rng.randf() >= cfg.cover_chance:
			continue
		var rect: Rect2i = room["rect"]
		if rect.size.x < 4 or rect.size.y < 4:
			continue
		var n := _rng.randi_range(1, 2)
		for k in n:
			# 只在房间内部（离墙 1 格）摆，避免堵住门
			var cx := _rng.randi_range(rect.position.x + 1, rect.end.x - 2)
			var cy := _rng.randi_range(rect.position.y + 1, rect.end.y - 2)
			if _at(cx, cy) != FLOOR:
				continue
			# 摆之前确认不会把房间切断：掩体是 1×1 或 1×2，且四周至少留出通路
			if _would_block(cx, cy):
				continue
			_put(cx, cy, SOLID)
			placed += 1
	stats["covers"] = placed

## 简易判定：该格填实后，其四邻的可行走格是否仍互相连通（防止 1 格宽走廊被堵死）
func _would_block(x: int, y: int) -> bool:
	var open := 0
	for d in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
		if _walkable(_at(x + d.x, y + d.y)):
			open += 1
	# 四邻全通 = 在开阔处，安全；只有 1–2 个通 = 可能是走廊/角落，不摆
	return open < 3

# ── 8/9. 连通性洪泛校验 + 不可达填实（硬规则）──────────
func _validate_and_prune() -> bool:
	if corridor_cells.is_empty():
		return false
	# 从主路第一格洪泛
	var start: Vector2i = corridor_cells[0]
	var reached := _flood(start)

	# 主路本身必须全连通
	for c in corridor_cells:
		if not reached.has(c):
			return false

	# 不可达房间 → 整间填实
	var pruned := 0
	for room in rooms:
		if room["solid"]:
			continue
		var rect: Rect2i = room["rect"]
		var any_reached := false
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if reached.has(Vector2i(x, y)):
					any_reached = true
					break
			if any_reached:
				break
		if not any_reached:
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					_put(x, y, SOLID)
			# 门也一起封掉
			for d in room["doors"]:
				_put(d.x, d.y, SOLID)
			room["solid"] = true
			pruned += 1
	stats["pruned_rooms"] = pruned

	# 再洪泛一次，清掉零散的不可达碎片（被填实房间遗留的孤立格）
	var reached2 := _flood(start)
	var orphans := 0
	for y in cfg.height:
		for x in cfg.width:
			if _walkable(grid[y][x]) and not reached2.has(Vector2i(x, y)):
				grid[y][x] = SOLID
				orphans += 1
	stats["orphan_cells"] = orphans

	# 计算每个房间的"深度"（离主路多少步），供 L4 容器选址
	_compute_depths(reached2)
	return true

func _flood(start: Vector2i) -> Dictionary:
	var seen := {}
	if not _walkable(_at(start.x, start.y)):
		return seen
	var queue: Array[Vector2i] = [start]
	seen[start] = 0
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		var d: int = seen[cur]
		for dd in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			var nx: Vector2i = cur + dd
			if seen.has(nx):
				continue
			if not _walkable(_at(nx.x, nx.y)):
				continue
			seen[nx] = d + 1
			queue.append(nx)
	return seen

## 房间深度 = 房间内格子到主路的最大步数（越深越适合放 L4）
func _compute_depths(dist: Dictionary) -> void:
	for room in rooms:
		if room["solid"]:
			room["depth"] = -1
			continue
		var rect: Rect2i = room["rect"]
		var maxd := 0
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var c := Vector2i(x, y)
				if dist.has(c):
					maxd = maxi(maxd, int(dist[c]))
		room["depth"] = maxd

# ── 出生点 ──────────────────────────────────────────────
## 出生点必须在主路上或紧邻主路的浅房间——保证一定连通（修 v0.1 孤岛 bug）
func _place_spawn() -> bool:
	if corridor_cells.is_empty():
		return false
	# 优先放在主路端点附近（模拟从 POI 边缘进入）
	var best: Vector2i = corridor_cells[0]
	var best_score := -1.0
	var center := Vector2(cfg.width, cfg.height) * 0.5
	for c in corridor_cells:
		if not _walkable(_at(c.x, c.y)):
			continue
		var d := Vector2(c).distance_to(center)
		if d > best_score:
			best_score = d
			best = c
	spawn_cell = best
	_put(best.x, best.y, SPAWN)
	return true

# ── 容器摆放（规范 §2.5）────────────────────────────────
func _place_containers() -> void:
	var open_rooms: Array[Dictionary] = []
	for room in rooms:
		if not room["solid"]:
			open_rooms.append(room)
	if open_rooms.is_empty():
		return

	# 按深度排序，最深的留给 L4
	open_rooms.sort_custom(func(a, b): return int(a["depth"]) > int(b["depth"]))

	var area: int = cfg.width * cfg.height
	var n1: int = cfg.containers_l1 if cfg.containers_l1 >= 0 else maxi(4, area / 240)
	var n2: int = cfg.containers_l2 if cfg.containers_l2 >= 0 else maxi(2, area / 520)
	var n3: int = cfg.containers_l3 if cfg.containers_l3 >= 0 else maxi(1, area / 1100)
	var n4: int = maxi(0, cfg.containers_l4)

	# L4：最深的单入口房间
	var used := {}
	var placed4 := 0
	for room in open_rooms:
		if placed4 >= n4:
			break
		if room["doors"].size() > 1:
			continue   # L4 要单入口
		var cell := _random_floor_in(room["rect"])
		if cell.x < 0:
			continue
		containers.append({"cell": cell, "richness": "L4"})
		used[room["rect"]] = true
		placed4 += 1
	# L4 没找到单入口房间时退让到最深房间
	if placed4 < n4 and open_rooms.size() > 0:
		var cell2 := _random_floor_in(open_rooms[0]["rect"])
		if cell2.x >= 0:
			containers.append({"cell": cell2, "richness": "L4"})

	# L3 深处、L2 房间内、L1 随处
	_scatter_containers(open_rooms, "L3", n3, 0.0, 0.4)
	_scatter_containers(open_rooms, "L2", n2, 0.25, 0.85)
	_scatter_containers(open_rooms, "L1", n1, 0.3, 1.0)

## 在按深度排序的房间列表的 [from, to] 区间内撒容器
func _scatter_containers(sorted_rooms: Array, richness: String, count: int,
		from_pct: float, to_pct: float) -> void:
	if sorted_rooms.is_empty() or count <= 0:
		return
	var lo: int = int(from_pct * sorted_rooms.size())
	var hi: int = maxi(lo + 1, int(to_pct * sorted_rooms.size()))
	for i in count:
		var idx: int = lo + (_rng.randi() % maxi(1, hi - lo))
		idx = clampi(idx, 0, sorted_rooms.size() - 1)
		var cell := _random_floor_in(sorted_rooms[idx]["rect"])
		if cell.x >= 0:
			containers.append({"cell": cell, "richness": richness})

func _random_floor_in(rect: Rect2i) -> Vector2i:
	for attempt in 24:
		var x := _rng.randi_range(rect.position.x, rect.end.x - 1)
		var y := _rng.randi_range(rect.position.y, rect.end.y - 1)
		if _at(x, y) == FLOOR and not _cell_taken(Vector2i(x, y)):
			return Vector2i(x, y)
	return Vector2i(-1, -1)

func _cell_taken(c: Vector2i) -> bool:
	for ct in containers:
		if ct["cell"] == c:
			return true
	return false

# ── 输出 ────────────────────────────────────────────────
func _collect_stats() -> void:
	var floor_n := 0
	var solid_n := 0
	for y in cfg.height:
		for x in cfg.width:
			if _walkable(grid[y][x]):
				floor_n += 1
			else:
				solid_n += 1
	var open_rooms := 0
	var single := 0
	var multi := 0
	for r in rooms:
		if r["solid"]:
			continue
		open_rooms += 1
		if r["doors"].size() <= 1:
			single += 1
		else:
			multi += 1
	stats["size"] = "%dx%d" % [cfg.width, cfg.height]
	stats["floor_cells"] = floor_n
	stats["solid_cells"] = solid_n
	stats["floor_pct"] = "%.0f%%" % (100.0 * floor_n / maxf(floor_n + solid_n, 1))
	stats["rooms_total"] = rooms.size()
	stats["rooms_open"] = open_rooms
	stats["rooms_single_entry"] = single
	stats["rooms_multi_entry"] = multi
	stats["single_entry_pct"] = "%.0f%%" % (100.0 * single / maxf(open_rooms, 1))
	stats["containers"] = containers.size()
	stats["corridor_cells"] = corridor_cells.size()

## 导出为字符串数组（与 level.gd 的 MAP 格式兼容）

## 可站立格池：所有可行走格，**排除最外圈**。
##
## 为什么要排除最外圈：`_carve_entrances()` 会把外墙凿穿成通道口，那些格子
## 虽然可行走，但三面贴着外墙 —— 怪刷在那里会贴墙罚站（v0.3 的实际 bug：
## 左下角那个 AI 就是刷在入口格上，巡逻目标又在墙另一侧，于是原地顶墙）。
##
## 另外排除紧贴墙的格子（四邻有 2 个以上是墙），这类格子转身空间不足，
## 简易避障（无 A*）很容易在里面打转。
func standable_cells(strict: bool = true) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(1, cfg.height - 1):
		for x in range(1, cfg.width - 1):
			if not _walkable(grid[y][x]):
				continue
			if strict:
				var walls := 0
				for d in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
					var n: Vector2i = Vector2i(x, y) + d
					if not _walkable(grid[n.y][n.x]):
						walls += 1
				if walls >= 2:
					continue
			out.append(Vector2i(x, y))
	# strict 过滤太狠（窄 POI 可能一个都不剩）→ 退回宽松版
	if out.is_empty() and strict:
		return standable_cells(false)
	return out

## 从 start 出发、限定步数内可达的可站立格（用于取"附近的巡逻点"）。
## 巡逻点必须与出生点在同一连通域且不太远，否则怪会朝一个够不到的点顶墙。
func nearby_standable(start: Vector2i, max_steps: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var seen := {start: 0}
	var q: Array[Vector2i] = [start]
	while not q.is_empty():
		var cur: Vector2i = q.pop_front()
		var step: int = seen[cur]
		if step > 0:
			out.append(cur)
		if step >= max_steps:
			continue
		for d in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			var n: Vector2i = cur + d
			if seen.has(n):
				continue
			if n.x <= 0 or n.y <= 0 or n.x >= cfg.width - 1 or n.y >= cfg.height - 1:
				continue
			if not _walkable(grid[n.y][n.x]):
				continue
			seen[n] = step + 1
			q.append(n)
	return out

func to_lines() -> Array[String]:
	var out: Array[String] = []
	for y in cfg.height:
		var s := ""
		for x in cfg.width:
			var ch: String = grid[y][x]
			# CORRIDOR / DOOR 统一转成可行走地板；容器在外部按 containers[] 摆
			if ch == CORRIDOR or ch == DOOR:
				ch = FLOOR
			s += ch
		out.append(s)
	return out

## 带容器标记的调试输出（1–4 = 容器档位）
func to_debug_lines() -> Array[String]:
	var lines := to_lines()
	for ct in containers:
		var c: Vector2i = ct["cell"]
		var digit: String = str(ct["richness"]).substr(1, 1)
		var row: String = lines[c.y]
		lines[c.y] = row.substr(0, c.x) + digit + row.substr(c.x + 1)
	return lines
