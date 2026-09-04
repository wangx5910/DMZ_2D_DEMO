extends Area2D
## LootContainer · 可逐格搜刮的容器
##
## 逐格搜刮的核心数据结构：内容在**首次交互时才摇**（延迟生成），
## 每格有独立的 revealed 状态。中断只丢当前格进度，已搜出的永久保留。
## 这让"搜一半跑"成为真实战术，而不是全有或全无。
##
## 联机预留：slots / revealed / cracked 三个字段即为需同步的状态（TODO_NET）。

@export_enum("L1", "L2", "L3", "L4") var richness: String = "L1"
@export var label: String = ""

var slots: Array = []          ## TODO_NET: [{id:String}|{}] ，{} = 空格
var revealed: Array[bool] = []  ## TODO_NET
var taken: Array[bool] = []     ## 已被拿走
var cracked: bool = false       ## TODO_NET: L4 是否已破解
var take_locked: bool = false       ## 为 true 时可见但不可取出（密闭舱预览）
var is_sealed_preview: bool = false
var is_corpse_bag: bool = false     ## 尸体背包：搜刮流程与普通箱相同
var stash_slots: Array = []         ## 尸体寄存预览 [{id}]
var stash_taken: Array[bool] = []
var _rolled: bool = false

var _highlight := false
var _focused := false

func _ready() -> void:
	add_to_group("containers")
	add_to_group("vision_gated")
	collision_layer = 1 << 2   # interactable
	collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(30, 24)
	shape.shape = rect
	add_child(shape)
	if label == "":
		label = GameData.containers.get(richness, {}).get("label", richness)
	z_index = 2

func _ensure_rolled() -> void:
	if _rolled:
		return
	fill_now(richness, cracked)

## 立刻按掉落表填箱（人质房预填、免破解金箱）
func fill_now(table_key: String, pre_cracked: bool = false) -> void:
	_rolled = true
	cracked = pre_cracked
	slots = GameData.roll_container(table_key)
	revealed.resize(slots.size())
	taken.resize(slots.size())
	revealed.fill(false)
	taken.fill(false)
	queue_redraw()

## 用已有物品列表做成可搜刮容器（怪物/AI 死亡掉落的背包）
func setup_corpse_bag(item_ids: Array, bag_label: String = "尸体背包", search_tier: String = "L2", stash_ids: Array = []) -> void:
	is_corpse_bag = true
	richness = search_tier
	label = bag_label
	_rolled = true
	cracked = true   # 尸体包无需 L4 破解
	slots.clear()
	for id in item_ids:
		var sid := str(id)
		if sid == "":
			continue
		slots.append({"id": sid})
	if slots.is_empty():
		slots.append({})   # 空包也占一格，避免 0 格异常
	revealed.resize(slots.size())
	taken.resize(slots.size())
	revealed.fill(false)
	taken.fill(false)
	stash_slots.clear()
	for sid2 in stash_ids:
		var ssid := str(sid2)
		if ssid == "":
			continue
		stash_slots.append({"id": ssid})
	stash_taken.resize(stash_slots.size())
	stash_taken.fill(false)
	queue_redraw()

func stash_count() -> int:
	return stash_slots.size()

func take_stash_slot(index: int) -> String:
	if take_locked:
		return ""
	if index < 0 or index >= stash_slots.size():
		return ""
	if stash_taken[index] or stash_slots[index].is_empty():
		return ""
	stash_taken[index] = true
	queue_redraw()
	return str(stash_slots[index].get("id", ""))

func slot_count() -> int:
	_ensure_rolled()
	return slots.size()

func next_unsearched_slot() -> int:
	_ensure_rolled()
	for i in revealed.size():
		if not revealed[i]:
			return i
	return -1

func is_fully_searched() -> bool:
	if not _rolled:
		return false
	for i in revealed.size():
		if not revealed[i]:
			return false
	return true

func revealed_count() -> int:
	_ensure_rolled()
	var n := 0
	for r in revealed:
		if r:
			n += 1
	return n

func reveal_slot(index: int) -> Dictionary:
	_ensure_rolled()
	if index < 0 or index >= slots.size():
		return {}
	revealed[index] = true
	queue_redraw()
	return slots[index]

func reveal_all() -> void:
	_ensure_rolled()
	revealed.fill(true)
	cracked = true
	queue_redraw()

## 取走某格物品。返回物品 id，失败返回 ""
func take_slot(index: int) -> String:
	_ensure_rolled()
	if take_locked:
		return ""
	if index < 0 or index >= slots.size():
		return ""
	if not revealed[index] or taken[index] or slots[index].is_empty():
		return ""
	taken[index] = true
	queue_redraw()
	return slots[index].get("id", "")

## 剩余未取走的价值（用于统计"留下了多少钱"）
func remaining_value() -> int:
	_ensure_rolled()
	var v := 0
	for i in slots.size():
		if not taken[i] and not slots[i].is_empty():
			v += int(GameData.item(slots[i]["id"]).get("value", 0))
	for i in stash_slots.size():
		if i < stash_taken.size() and not stash_taken[i] and not stash_slots[i].is_empty():
			v += int(GameData.item(stash_slots[i]["id"]).get("value", 0))
	return v

func set_perceived(visible_now: bool) -> void:
	# 容器本身是静态陈设，一直可见（属于"地形记忆"）；
	# 高亮框只在视野内显示，避免视野外也能读出"这里有个箱子已被搜过"
	_highlight = visible_now
	queue_redraw()

func set_focused(on: bool) -> void:
	_focused = on
	queue_redraw()

func _draw() -> void:
	# 免保始终画；普通武器箱/杂物箱不当常驻地图图标，只在视野内或对准时出现
	if not is_in_group("free_safe") and not is_in_group("contract_reward") \
			and not _highlight and not _focused:
		return
	var base := _richness_color()
	if is_sealed_preview:
		base = Color(0.90, 0.45, 0.62)
	var size := Vector2(30, 24)
	var half := size * 0.5
	# 箱体
	draw_rect(Rect2(-half, size), base * (1.0 if _highlight else 0.55), true)
	draw_rect(Rect2(-half, size), base.lightened(0.35), false, 2.0)
	# 搜刮进度读数：右上角小格条，被搜过的格子点亮
	if _rolled and _highlight:
		var n := slots.size()
		var bw := size.x / maxf(n, 1)
		for i in n:
			var c := Color(0.25, 0.27, 0.32)
			if revealed[i]:
				c = Color(0.4, 0.42, 0.48) if slots[i].is_empty() else GameData.item_color(slots[i]["id"])
				if taken[i]:
					c = c.darkened(0.6)
			draw_rect(Rect2(Vector2(-half.x + i * bw, half.y + 3), Vector2(bw - 1.5, 3.5)), c, true)
	# 交互聚焦框
	if _focused:
		draw_rect(Rect2(-half - Vector2(4, 4), size + Vector2(8, 8)), Color(1.0, 0.85, 0.35, 0.9), false, 2.0)
	if take_locked and _highlight:
		draw_string(ThemeDB.fallback_font, Vector2(-half.x, -half.y - 4), "🔒",
			HORIZONTAL_ALIGNMENT_LEFT, size.x, 12, Color(0.95, 0.75, 0.35))

func _richness_color() -> Color:
	if is_corpse_bag:
		return Color(0.62, 0.42, 0.28)
	match richness:
		"L1": return Color(0.52, 0.50, 0.45)
		"L2": return Color(0.40, 0.58, 0.70)
		"L3": return Color(0.62, 0.45, 0.78)
		"L4": return Color(0.88, 0.68, 0.28)
	return Color.GRAY
