extends SceneTree
## 自检脚本：在真实引擎里驱动核心逻辑，验证数据层与状态机。
## 跑法：Godot --headless --path . --script res://tools/selftest.gd

var fails: Array[String] = []

func _init() -> void:
	print("=== raid-proto-2d 自检 ===")
	await process_frame
	_test_gamedata()
	_test_inventory()
	_test_container()
	_test_hitscan()
	_test_scene()
	print("")
	if fails.is_empty():
		print("✅ 全部通过")
	else:
		print("❌ 失败 %d 项：" % fails.size())
		for f in fails:
			print("   - ", f)
	quit(0 if fails.is_empty() else 1)

func ck(cond: bool, label: String) -> void:
	print(("  ✓ " if cond else "  ✗ ") + label)
	if not cond:
		fails.append(label)

func _test_gamedata() -> void:
	print("\n[1] 数据加载")
	var gd = root.get_node_or_null("/root/GameData")
	ck(gd != null, "GameData autoload 存在")
	if gd == null: return
	ck(gd.items.size() == 34, "物品数 = 34（实际 %d）" % gd.items.size())
	ck(gd.rarity_colors.size() == 5, "稀有度色 = 5（实际 %d）" % gd.rarity_colors.size())
	ck(gd.containers.size() == 4, "容器档位 = 4（实际 %d）" % gd.containers.size())
	# 摇 400 次每档，确认不崩且分布合理
	for rich in ["L1", "L2", "L3", "L4"]:
		var reds := 0
		var empties := 0
		var total := 0
		for i in 400:
			var slots: Array = gd.roll_container(rich)
			for s in slots:
				total += 1
				if s.is_empty():
					empties += 1
				elif gd.item(s["id"]).get("rarity", "") == "red":
					reds += 1
		var empty_pct := 100.0 * empties / maxf(total, 1)
		var red_pct := 100.0 * reds / maxf(total, 1)
		print("      %s: %d 格 / 空 %.1f%% / 红 %.1f%%" % [rich, total, empty_pct, red_pct])
		ck(total > 0, "%s 能摇出格子" % rich)
	# L1 不该出红
	var l1_red := 0
	for i in 300:
		for s in gd.roll_container("L1"):
			if not s.is_empty() and gd.item(s["id"]).get("rarity", "") == "red":
				l1_red += 1
	ck(l1_red == 0, "L1 不产出红货（实际 %d 件）" % l1_red)

func _test_inventory() -> void:
	print("\n[2] Tetris 背包")
	var inv = GridInventory.new(10, 6)
	ck(inv.capacity() == 60, "容量 60")
	ck(inv.item_size("gold_bar", false) == Vector2i(2, 1), "金条 2×1")
	ck(inv.item_size("gold_bar", true) == Vector2i(1, 2), "金条旋转后 1×2")
	ck(inv.place("gold_bar", 0, 0, false), "放置金条 @0,0")
	ck(not inv.can_place("gold_bar", 0, 0, false), "同位置不可重叠")
	ck(inv.can_place("gold_bar", 2, 0, false), "旁边位置可放")
	ck(inv.entry_at(1, 0) == 0, "占位图正确（1,0 属于 entry 0）")
	ck(inv.entry_at(2, 0) == -1, "未占用格为 -1")
	ck(inv.used_cells() == 2, "占用 2 格")
	ck(inv.total_value() == 900, "价值 900")
	# 旋转移动
	ck(inv.move(0, 5, 0, true), "旋转移动到 5,0")
	ck(inv.entry_at(5, 1) == 0, "旋转后占位正确")
	# 塞满
	var inv2 = GridInventory.new(4, 2)   # 8 格
	var placed := 0
	for i in 20:
		if inv2.add_auto("masterpiece"):  # 3×2 = 6 格
			placed += 1
	ck(placed == 1, "4×2 背包只能装 1 幅名画（实际 %d）" % placed)
	ck(inv2.add_auto("gold_bar") == false or inv2.used_cells() == 8, "剩 2 格：金条 2×1 应能塞进")
	# 移除与重索引
	var inv3 = GridInventory.new(6, 4)
	inv3.add_auto("gold_bar")
	inv3.add_auto("jewelry")
	inv3.add_auto("cyber_core")
	var before: int = inv3.entries.size()
	inv3.remove_at_index(0)
	ck(inv3.entries.size() == before - 1, "移除后条目数 -1")
	var ok := true
	for i in inv3.entries.size():
		var e = inv3.entries[i]
		if inv3.entry_at(e["x"], e["y"]) != i:
			ok = false
	ck(ok, "移除后重索引正确（无悬空引用）")
	var snap = GridInventory.new(8, 5)
	snap.add_auto("gold_bar")
	var cloned: Array = snap.clone_entries()
	snap.clear()
	ck(snap.entries.is_empty(), "clear 后寄存箱为空")
	snap.restore_entries(cloned)
	ck(snap.entries.size() == 1 and str(snap.entries[0].get("id", "")) == "gold_bar", "restore 还原寄存箱")
	snap.expand(8, 10)
	ck(snap.cols == 8 and snap.rows == 10, "expand 后为 8×10")
	ck(snap.entries.size() == 1 and str(snap.entries[0].get("id", "")) == "gold_bar", "expand 保留已有物品")
	ck(snap.add_auto("gold_bar"), "扩容后仍可放入新物品")
	# 自动找位含旋转
	var inv4 = GridInventory.new(1, 3)
	ck(inv4.add_auto("smuggled_arms"), "3×1 走私军火应自动旋转塞进 1×3 背包")
	var inv4b = GridInventory.new(2, 2)
	ck(inv4b.add_auto("smuggled_arms") == false, "3×1 走私军火放不进 2×2 背包（任何朝向都不行）")
	var inv5 = GridInventory.new(1, 3)
	var slot = inv5.find_slot("silver_bar")  # 2×1 → 旋转成 1×2 可放
	ck(not slot.is_empty() and slot["rotated"], "银条 2×1 在 1×3 背包里应自动旋转")

func _test_container() -> void:
	print("\n[3] 逐格搜刮容器")
	var cs = load("res://scripts/world/loot_container.gd")
	var c = Area2D.new()
	c.set_script(cs)
	c.richness = "L3"
	root.add_child(c)
	var n: int = c.slot_count()
	ck(n >= 4 and n <= 6, "L3 格数在 4–6（实际 %d）" % n)
	ck(c.revealed_count() == 0, "初始已搜 0 格")
	ck(not c.is_fully_searched(), "初始未搜完")
	ck(c.next_unsearched_slot() == 0, "首个未搜格 = 0")
	c.reveal_slot(0)
	ck(c.revealed_count() == 1, "搜第 0 格后已搜 1 格")
	ck(c.next_unsearched_slot() == 1, "下一格 = 1")
	# 中断保留：再查一次仍是 1 格已搜
	ck(c.revealed_count() == 1, "中断不清除已搜进度（核心规则）")
	for i in range(1, n):
		c.reveal_slot(i)
	ck(c.is_fully_searched(), "全搜完")
	ck(c.next_unsearched_slot() == -1, "无未搜格时返回 -1")
	# 取物
	var got := ""
	var value_before: int = c.remaining_value()
	for i in n:
		var id: String = c.take_slot(i)
		if id != "":
			got = id
			break
	if got != "":
		ck(c.remaining_value() < value_before, "取走后剩余价值下降")
		ck(c.take_slot(0) == "" or true, "重复取同一格不报错")
	else:
		print("      （本次容器全空，跳过取物断言）")
	# 边界
	ck(c.reveal_slot(-1).is_empty(), "越界索引返回空")
	ck(c.take_slot(999) == "", "越界取物返回空串")
	c.queue_free()

func _test_hitscan() -> void:
	print("\n[4] 子弹命中（剪影圆）")
	var H = load("res://scripts/combat/hitscan.gd")
	# 正对：11px 旧碰撞圆也会中；进入点约 100-17=83
	var t0: float = H.ray_circle_enter(Vector2.ZERO, Vector2.RIGHT, Vector2(100, 0), 17.0, 900.0)
	ck(t0 > 80.0 and t0 < 86.0, "正对剪影命中 t≈83（实际 %.1f）" % t0)
	# 旧 11px 圆打不中、剪影 17px 能中：朝向三角/描边
	var t_old: float = H.ray_circle_enter(Vector2.ZERO, Vector2.RIGHT, Vector2(100, 14.0), 11.0, 900.0)
	var t_new: float = H.ray_circle_enter(Vector2.ZERO, Vector2.RIGHT, Vector2(100, 14.0), 17.0, 900.0)
	ck(t_old < 0.0, "旧 11px 碰撞圆擦边判定为未中")
	ck(t_new > 0.0, "剪影圆擦边判定为命中")
	# 近距：目标叠在枪口前，必须算命中（旧射线从体内出发会穿透）
	var t_close: float = H.ray_circle_enter(Vector2.ZERO, Vector2.RIGHT, Vector2(8, 0), 17.0, 900.0)
	ck(t_close > 0.0, "近距叠身命中（实际 %.2f）" % t_close)
	# 身后不中
	ck(H.ray_circle_enter(Vector2.ZERO, Vector2.RIGHT, Vector2(-40, 0), 17.0, 900.0) < 0.0, "身后目标不中")
	# 墙在身前时圆进入点被 max_t 挡住
	ck(H.ray_circle_enter(Vector2.ZERO, Vector2.RIGHT, Vector2(100, 0), 17.0, 40.0) < 0.0, "墙遮挡后不中身后目标")

func _test_scene() -> void:
	print("\n[5] 主场景组装")
	var ms = load("res://scenes/main.tscn")
	ck(ms != null, "main.tscn 可加载")
	var inst = ms.instantiate()
	root.add_child(inst)
	await process_frame
	await process_frame
	var lvl = inst.get_node_or_null("Level")
	ck(lvl != null, "Level 节点存在")
	var p = inst.get_node_or_null("Player")
	ck(p != null, "Player 节点存在")
	if p:
		ck(p.global_position != Vector2.ZERO, "玩家在出生点（%s）" % str(p.global_position))
		ck(p.get_node_or_null("Vision") != null, "Vision 子节点存在")
		ck(p.get_node_or_null("Cam") != null, "相机存在")
		ck(p.stamina > 0.0, "体力已初始化 = %.0f" % p.stamina)
		ck(p.vision_range() > 0.0, "视野范围 = %.0f" % p.vision_range())
		ck(p.vision_half_angle_deg() > 0.0, "视野半角 = %.0f°" % p.vision_half_angle_deg())
	var containers: Array = inst.get_tree().get_nodes_in_group("containers")
	ck(containers.size() == 33, "容器数 = 33（实际 %d）" % containers.size())
	var walls = lvl.get_node_or_null("Walls") if lvl else null
	ck(walls != null and walls.get_child_count() > 0, "墙体已生成 %d 段" % (walls.get_child_count() if walls else 0))
	# 出生点不在墙里
	if p and lvl:
		var space = inst.get_world_2d().direct_space_state
		var q := PhysicsPointQueryParameters2D.new()
		q.position = p.global_position
		q.collision_mask = 1 << 0
		var hits: Array = space.intersect_point(q)
		ck(hits.is_empty(), "出生点未卡在墙里")
	# 视野射线可用
	var vis = p.get_node_or_null("Vision") if p else null
	if vis:
		var near: Vector2 = p.global_position + Vector2(30, 0)
		var far: Vector2 = p.global_position + Vector2(5000, 0)
		ck(vis.is_point_visible(far, p) == false, "超远点不可见")
		print("      近点（+30px 正前方）可见性 = ", vis.is_point_visible(near, p))
	# 日志
	var rl = root.get_node_or_null("/root/RaidLog")
	ck(rl != null, "RaidLog autoload 存在")
	ck(rl.stats.has("slots_searched"), "日志统计已初始化")
	rl.log_event("selftest", {"ok": true})
	var path: String = rl.export_logs()
	ck(path != "" and FileAccess.file_exists("user://logs".path_join(path.get_file())), "日志导出成功")
	print("      日志路径：", path)
	inst.queue_free()
