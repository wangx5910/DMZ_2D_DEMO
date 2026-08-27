extends Node
## GameData · 物品 / 掉落表 / 枪械 定义加载器
##
## 数据驱动：data/*.json 改完重开即生效，无需改代码。

const ITEMS_PATH := "res://data/items.json"
const LOOT_PATH := "res://data/loot_tables.json"
const WEAPONS_PATH := "res://data/weapons.json"

var items: Dictionary = {}          ## id -> {name, cat, rarity, value, w, h}
var rarity_colors: Dictionary = {}  ## rarity -> Color
var containers: Dictionary = {}     ## richness -> table
var weapons: Dictionary = {}        ## id -> 枪械定义
var ammo_types: Dictionary = {}     ## caliber -> {name, reserve_default, reserve_max}

## rarity -> [item_id...] 反查索引，摇稀有度后从中取件
var _by_rarity: Dictionary = {}
## "rarity|cat" -> [item_id...]
var _by_rarity_cat: Dictionary = {}

var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.randomize()
	_load_items()
	_load_loot()
	_load_weapons()

func _load_weapons() -> void:
	var d := _read_json(WEAPONS_PATH)
	weapons = d.get("weapons", {})
	ammo_types = d.get("ammo", {})

func weapon(id: String) -> Dictionary:
	return weapons.get(id, {})

func ammo(caliber: String) -> Dictionary:
	return ammo_types.get(caliber, {})

func _load_items() -> void:
	var d := _read_json(ITEMS_PATH)
	items = d.get("items", {})
	for r in d.get("rarity_colors", {}):
		rarity_colors[r] = Color(d["rarity_colors"][r])
	for id in items:
		var it: Dictionary = items[id]
		var r: String = it.get("rarity", "green")
		var c: String = it.get("cat", "util")
		if not _by_rarity.has(r):
			_by_rarity[r] = []
		_by_rarity[r].append(id)
		var key := "%s|%s" % [r, c]
		if not _by_rarity_cat.has(key):
			_by_rarity_cat[key] = []
		_by_rarity_cat[key].append(id)

func _load_loot() -> void:
	containers = _read_json(LOOT_PATH).get("containers", {})

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("缺少数据文件: %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}

func item(id: String) -> Dictionary:
	return items.get(id, {})

func item_color(id: String) -> Color:
	return rarity_colors.get(item(id).get("rarity", "green"), Color.WHITE)

## 生成一个容器的内容。返回 Array[Dictionary]，元素为 {} 表示该格为空。
## 空格是设计上的重点：逐格搜刮时"搜到空气"才有博弈张力。
func roll_container(richness: String) -> Array:
	var table: Dictionary = containers.get(richness, {})
	if table.is_empty():
		return []
	var slot_range: Array = table.get("slots", [2, 3])
	var count := rng.randi_range(int(slot_range[0]), int(slot_range[1]))
	# **不产生空格**（大锤要求）：搜出来是空气纯粹是浪费玩家时间。
	# 原来 fill_chance 用来摇"这格是不是空的"；现在改成**缩放格子总数** ——
	# 穷容器给的格子本来就少，富容器格子多，富度差异照旧成立，
	# 但每一格读完必有东西，读条时间与收益一一对应。
	var fill: float = clampf(table.get("fill_chance", 0.6), 0.15, 1.0)
	count = maxi(1, int(round(count * fill)))
	var weights: Dictionary = table.get("weights", {})
	var cats: Array = table.get("cats", [])
	var out: Array = []
	var guard := 0
	while out.size() < count and guard < count * 12:
		guard += 1
		var id := _roll_item(weights, cats)
		if id == "":
			continue      # 摇空了重摇，绝不塞空格
		out.append({"id": id})
	if richness == "L4":
		_ensure_l4_jackpot(out, cats)
	# 极端情况（品类池为空）兜底：至少给一件，宁可给便宜货也不给空气
	if out.is_empty():
		var fb := _roll_item(weights, [])
		if fb != "":
			out.append({"id": fb})
	return out

func _ensure_l4_jackpot(out: Array, cats: Array) -> void:
	if out.is_empty():
		return
	for slot in out:
		if slot.is_empty():
			continue
		var id: String = str(slot.get("id", ""))
		var r: String = str(item(id).get("rarity", "green"))
		if r == "gold" or r == "red":
			return
	# 保底金/红：先红后金，按品类池过滤
	var pick := _roll_item({"red": 70, "gold": 30}, cats)
	if pick == "":
		pick = _roll_item({"gold": 100}, cats)
	if pick != "":
		out[0] = {"id": pick}

func _roll_item(weights: Dictionary, cats: Array) -> String:
	var total := 0.0
	for r in weights:
		total += float(weights[r])
	if total <= 0.0:
		return ""
	var pick := rng.randf() * total
	var chosen := ""
	for r in weights:
		pick -= float(weights[r])
		if pick <= 0.0:
			chosen = r
			break
	if chosen == "":
		return ""
	# 在该稀有度下按允许品类过滤
	var pool: Array = []
	for c in cats:
		var key := "%s|%s" % [chosen, c]
		if _by_rarity_cat.has(key):
			pool.append_array(_by_rarity_cat[key])
	if pool.is_empty():
		pool = _by_rarity.get(chosen, [])
	if pool.is_empty():
		return ""
	return pool[rng.randi() % pool.size()]

func search_time_mul(richness: String) -> float:
	match richness:
		"L1": return Tuning.search_time_mul_l1
		"L2": return Tuning.search_time_mul_l2
		"L3", "hostage": return Tuning.search_time_mul_l3
		"L4": return Tuning.search_time_mul_l4
	return 1.0

## 给怪物/AI 初始背包塞几件货用
func random_loot_id(weights: Dictionary = {}) -> String:
	if weights.is_empty():
		weights = {"green": 55, "blue": 30, "purple": 12, "gold": 3}
	return _roll_item(weights, [])
