class_name GridInventory
extends RefCounted
## GridInventory · Tetris 网格背包数据模型
##
## 纯数据层，不含任何 UI 依赖 —— 因此可直接被服务端复用（联机预留）。
## 物品占 w×h 格，可旋转 90°。核心取舍：**同样的 6 格，装一件红货还是四件蓝货。**

signal changed()

var cols: int
var rows: int
## 占位图：grid[y][x] = entry_index，-1 = 空
var grid: Array = []
## entries[i] = {id, x, y, w, h, rotated}
var entries: Array[Dictionary] = []

## GameData 惰性获取。
## 原因：本类是 class_name 全局类，其解析早于 autoload 注册——直接写 `GameData.xxx`
## 会导致 "Identifier not found: GameData"，进而 GridInventory.new() 整个失败。
## 走节点路径取单例可彻底规避此顺序依赖，也让本类能被服务端/测试脱离场景树复用。
static var _gd = null

static func _data():
	if _gd == null or not is_instance_valid(_gd):
		var loop := Engine.get_main_loop()
		if loop is SceneTree:
			_gd = (loop as SceneTree).root.get_node_or_null("/root/GameData")
	return _gd

func _init(c: int = 10, r: int = 6) -> void:
	resize(c, r)

func resize(c: int, r: int) -> void:
	cols = maxi(1, c)
	rows = maxi(1, r)
	grid = []
	for _y in rows:
		var row := []
		row.resize(cols)
		row.fill(-1)
		grid.append(row)
	entries.clear()

func item_def(id: String) -> Dictionary:
	var gd = _data()
	if gd == null:
		return {}
	return gd.item(id)

func item_size(id: String, rotated: bool) -> Vector2i:
	var d := item_def(id)
	var w := int(d.get("w", 1))
	var h := int(d.get("h", 1))
	return Vector2i(h, w) if rotated else Vector2i(w, h)

func can_place(id: String, x: int, y: int, rotated: bool, ignore_index: int = -1) -> bool:
	var s := item_size(id, rotated)
	if x < 0 or y < 0 or x + s.x > cols or y + s.y > rows:
		return false
	for dy in s.y:
		for dx in s.x:
			var occ: int = grid[y + dy][x + dx]
			if occ != -1 and occ != ignore_index:
				return false
	return true

## 自动找位（先横向后竖向，再尝试旋转）。返回 {x,y,rotated} 或空字典
func find_slot(id: String) -> Dictionary:
	for rot in [false, true]:
		var s := item_size(id, rot)
		if s.x > cols or s.y > rows:
			continue
		for y in rows - s.y + 1:
			for x in cols - s.x + 1:
				if can_place(id, x, y, rot):
					return {"x": x, "y": y, "rotated": rot}
	return {}

func add_auto(id: String) -> bool:
	var slot := find_slot(id)
	if slot.is_empty():
		return false
	return place(id, slot["x"], slot["y"], slot["rotated"])

## 无视负重发放奖励（密闭舱奖励等）：即使背包满也强行落格（可重叠占位）
func grant_no_weight(id: String) -> bool:
	var s := item_size(id, false)
	var slot := find_slot(id)
	var x: int = 0
	var y: int = 0
	var rot := false
	if not slot.is_empty():
		x = slot["x"]; y = slot["y"]; rot = slot["rotated"]
	var idx := entries.size()
	entries.append({"id": id, "x": x, "y": y, "w": s.x, "h": s.y, "rotated": rot, "ignore_weight": true})
	_stamp(idx, x, y, s, idx)
	changed.emit()
	return true

func place(id: String, x: int, y: int, rotated: bool) -> bool:
	if not can_place(id, x, y, rotated):
		return false
	var idx := entries.size()
	entries.append({"id": id, "x": x, "y": y, "w": 0, "h": 0, "rotated": rotated})
	var s := item_size(id, rotated)
	entries[idx]["w"] = s.x
	entries[idx]["h"] = s.y
	_stamp(idx, x, y, s, idx)
	changed.emit()
	return true

func move(index: int, x: int, y: int, rotated: bool) -> bool:
	if index < 0 or index >= entries.size():
		return false
	var e := entries[index]
	if not can_place(e["id"], x, y, rotated, index):
		return false
	_stamp(index, e["x"], e["y"], Vector2i(e["w"], e["h"]), -1)
	var s := item_size(e["id"], rotated)
	e["x"] = x; e["y"] = y; e["rotated"] = rotated; e["w"] = s.x; e["h"] = s.y
	_stamp(index, x, y, s, index)
	changed.emit()
	return true

func remove_at_index(index: int) -> String:
	if index < 0 or index >= entries.size():
		return ""
	var e := entries[index]
	_stamp(index, e["x"], e["y"], Vector2i(e["w"], e["h"]), -1)
	var id: String = e["id"]
	entries.remove_at(index)
	_reindex()
	changed.emit()
	return id

func entry_at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= cols or y >= rows:
		return -1
	return grid[y][x]

func total_value() -> int:
	var v := 0
	for e in entries:
		v += int(item_def(e["id"]).get("value", 0))
	return v

func has_id(id: String) -> bool:
	for e in entries:
		if str(e.get("id", "")) == id:
			return true
	return false

## 扁平物品 id 列表（用于死亡掉落尸体包）
func item_ids() -> Array:
	var out: Array = []
	for e in entries:
		out.append(str(e.get("id", "")))
	return out

func used_cells() -> int:
	var n := 0
	for e in entries:
		n += int(e["w"]) * int(e["h"])
	return n

func capacity() -> int:
	return cols * rows

func clear() -> void:
	resize(cols, rows)
	changed.emit()

## 扩容并保留已有物品（提交点新开时给网络存储箱加一块 8×5）。
func expand(c: int, r: int) -> void:
	var nc := maxi(cols, c)
	var nr := maxi(rows, r)
	if nc == cols and nr == rows:
		return
	var snap := clone_entries()
	resize(nc, nr)
	restore_entries(snap)

## 快照当前格子（提交点打开时回滚用）
func clone_entries() -> Array:
	var out: Array = []
	for e in entries:
		out.append(e.duplicate())
	return out

func restore_entries(list: Array) -> void:
	resize(cols, rows)
	for e in list:
		var id := str(e.get("id", ""))
		if id == "":
			continue
		if not place(id, int(e.get("x", 0)), int(e.get("y", 0)), bool(e.get("rotated", false))):
			if not add_auto(id):
				grant_no_weight(id)
	changed.emit()

func _stamp(_idx: int, x: int, y: int, s: Vector2i, value: int) -> void:
	for dy in s.y:
		for dx in s.x:
			grid[y + dy][x + dx] = value

func _reindex() -> void:
	for y in rows:
		for x in cols:
			grid[y][x] = -1
	for i in entries.size():
		var e := entries[i]
		_stamp(i, e["x"], e["y"], Vector2i(e["w"], e["h"]), i)
