extends Node
## 玩法流程检测：公共撤离点 + 飞船悬浮 POI
var _f := 0
var _done := false
var fails: Array[String] = []

func ck(cond: bool, label: String) -> void:
	print(("  ✓ " if cond else "  ✗ ") + label)
	if not cond: fails.append(label)

func _process(_d: float) -> void:
	_f += 1
	if _f < 10 or _done:
		return
	_done = true
	_run()

func _run() -> void:
	var p = get_parent().player
	var w = get_parent().level
	Tuning.set_value("enable_extraction", true)
	Tuning.set_value("enable_spaceship", true)
	Tuning.set_value("spaceship_spawn_time", 2.0)
	print("=== 玩法流程检测 ===")

	var spawned := false
	for i in 300:
		await _wait(1.0 / 30.0)
		if w.spaceship != null:
			spawned = true
			break
	ck(spawned, "飞船已刷出（悬浮巡航）")
	ck(w.ship_loot_nodes.size() > 0, "刷出即带船内 POI 容器（%d 个）" % w.ship_loot_nodes.size())

	if spawned:
		var rich := 0
		for n in w.ship_loot_nodes:
			if str(n.richness) in ["L3", "L4"]:
				rich += 1
		ck(rich > 0, "飞船 POI 容器为 L3/L4 富物资（%d/%d）" % [rich, w.ship_loot_nodes.size()])

	var pad_n: int = w.extract_pads.size() if "extract_pads" in w else 0
	ck(pad_n > 0, "开局已刷固定撤离点（%d）" % pad_n)
	ck(get_tree().get_nodes_in_group("depots").size() > 0, "物资提交点已刷出")

	if w.extraction_points.size() > 0:
		var inv = get_parent().inv
		inv.add_auto("gold_bar")
		p.secure_value(150)
		var ep: Vector2 = w.extraction_points[0]
		p.global_position = ep
		if w.has_method("_complete_pad_extract"):
			w._complete_pad_extract(0)
		ck(w.is_extracted(), "玩家在撤离点停留后成功撤离")
		ck(bool(p.get("raid_over")), "撤离后弹出本局结算")
		var rep: Dictionary = p.settle_report
		ck(int(rep.get("secured", 0)) == 150, "已提交金额计入结算")
		ck(int(rep.get("backpack_payout", 0)) == 900, "背包金条按面值折现 ¥900")
		ck(int(rep.get("total", 0)) == 1050, "本局收益 = 已提交 + 背包折现")

	print("")
	print("✅ 玩法流程合格" if fails.is_empty() else "❌ %d 项不合格" % fails.size())
	get_tree().quit(0 if fails.is_empty() else 1)

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
