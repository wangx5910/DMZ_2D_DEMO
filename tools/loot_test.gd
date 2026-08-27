extends Node
## 验证：容器不再产生空格；各档位格数与价值仍有梯度
var _f := 0
var _done := false
func _process(_d: float) -> void:
	_f += 1
	if _f < 8 or _done: return
	_done = true
	print("=== 掉落表验证（无空格）===")
	var fails := 0
	for r in ["L1","L2","L3","L4"]:
		var empty := 0
		var total_slots := 0
		var total_value := 0
		var minS := 999
		var maxS := 0
		for i in 400:
			var slots: Array = GameData.roll_container(r)
			total_slots += slots.size()
			minS = mini(minS, slots.size())
			maxS = maxi(maxS, slots.size())
			for sl in slots:
				if sl.is_empty():
					empty += 1
				else:
					total_value += int(GameData.item(sl["id"]).get("value", 0))
		var avg_slots := float(total_slots) / 400.0
		var avg_value := float(total_value) / 400.0
		var ok: bool = empty == 0 and minS >= 1
		print("  %s  平均 %.1f 格（%d–%d）｜ 平均价值 ¥%.0f ｜ 空格 %d  %s" % [
			r, avg_slots, minS, maxS, avg_value, empty, "✓" if ok else "✗"])
		if not ok: fails += 1

	# 场景内实际容器也检查一遍
	var conts := get_tree().get_nodes_in_group("containers")
	var bad := 0
	var checked := 0
	for c in conts:
		if checked >= 300: break
		checked += 1
		c._ensure_rolled()
		if c.slots.is_empty():
			bad += 1
			continue
		for sl in c.slots:
			if sl.is_empty():
				bad += 1
				break
	print("  场景容器抽检 %d 个，含空格/空容器 %d 个 %s" % [checked, bad, "✓" if bad == 0 else "✗"])
	if bad > 0: fails += 1
	print("")
	print("✅ 无空格验证通过" if fails == 0 else "❌ %d 项不合格" % fails)
	get_tree().quit(0 if fails == 0 else 1)
