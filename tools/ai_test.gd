extends Node
## 怪物 AI 行为验证：把玩家放到小兵面前 / 身后 / 远处，观察状态迁移是否符合设计。
var _f := 0
var _done := false
var fails: Array[String] = []

func ck(cond: bool, label: String) -> void:
	print(("  ✓ " if cond else "  ✗ ") + label)
	if not cond: fails.append(label)

func _process(_d: float) -> void:
	_f += 1
	if _f < 15 or _done: return
	_done = true
	_run()

func _run() -> void:
	var inst = get_parent()
	var w = inst.level
	var p = inst.player
	print("=== 怪物 AI 验证 ===")

	var enemies = get_tree().get_nodes_in_group("enemies")
	ck(enemies.size() > 0, "已刷出 %d 个小兵" % enemies.size())
	if enemies.is_empty():
		get_tree().quit(1); return

	# 与玩家的对等性（大锤指定）
	var e = enemies[0]
	print("\n[对等性检查]")
	ck(e.RADIUS == 11.0, "体型与玩家相同（半径 %.0f）" % e.RADIUS)
	var php: float = p.health.hp_max
	var ehp: float = e.health.hp_max
	ck(ehp < php * 0.6, "血量远低于玩家：%.0f vs %.0f（系数 %.2f）" % [ehp, php, ehp/php])
	var pdmg: float = p.weapon.damage()
	var edmg: float = e.weapon.damage() * Tuning.enemy_damage_mul
	ck(edmg < pdmg * 0.5, "伤害远低于玩家：%.1f vs %.1f（系数 %.2f）" % [edmg, pdmg, edmg/pdmg])
	ck(e.weapon != null and e.weapon.display_name() != "", "小兵持枪：%s" % e.weapon.display_name())
	print("      小兵移速上限与玩家共用 Tuning（walk %.0f / sprint %.0f）" % [Tuning.walk_speed, Tuning.sprint_speed])

	# 行为链：把玩家挪到小兵正前方
	print("\n[视野发现 → 追击 → 交战]")
	Tuning.set_value("god_mode", true)
	e.global_position = Vector2(5000, 5000)
	e.post = e.global_position
	e.aim_dir = Vector2.RIGHT
	e.state = 0  # PATROL
	e.patrol_points.clear()
	# 玩家放在正前方 250px（视野内、交战距离内）
	p.global_position = e.global_position + Vector2(250, 0)
	await _wait(0.1)
	ck(e._can_see(p.global_position), "小兵能看见正前方 250px 的玩家")
	var behind = e.global_position + Vector2(-250, 0)
	ck(not e._can_see(behind), "小兵看不见正后方（扇形生效）")
	var far = e.global_position + Vector2(Tuning.enemy_vision_range + 300, 0)
	ck(not e._can_see(far), "超出视距不可见")

	# 等它确认发现
	var saw_alert := false
	var saw_chase_or_engage := false
	for i in 90:
		await _wait(1.0/60.0)
		if e.state == 1: saw_alert = true
		if e.state == 2 or e.state == 3: saw_chase_or_engage = true
		if saw_chase_or_engage: break
	ck(saw_alert, "经过 ALERT 警觉阶段（有反应窗口）")
	ck(saw_chase_or_engage, "进入 CHASE/ENGAGE（当前 %s）" % _sname(e.state))

	# 交战时会开火吗
	print("\n[交战行为]")
	var shots_before: int = int(RaidLog.stats.get("shots_fired", 0))
	var hp_before: float = p.health.hp
	Tuning.set_value("god_mode", false)
	var moved_positions: Array[Vector2] = []
	for i in 180:
		await _wait(1.0/60.0)
		moved_positions.append(e.global_position)
	ck(p.health.hp < hp_before or Tuning.god_mode, "小兵造成了伤害（玩家 %.0f -> %.0f）" % [hp_before, p.health.hp])
	# 交战微移动：位置应有变化（不站桩）
	var spread := 0.0
	for pos in moved_positions:
		spread = max(spread, moved_positions[0].distance_to(pos))
	ck(spread > 15.0, "交战中有移动（位移范围 %.0f px，不是站桩）" % spread)
	Tuning.set_value("god_mode", true)
	p.health.reset()

	# 追击放弃：把玩家传到极远处
	print("\n[丢失目标 → 搜索 → 返回]")
	p.global_position = e.global_position + Vector2(Tuning.enemy_chase_max_range + 2000, 0)
	var saw_search := false
	var saw_return := false
	for i in 700:
		await _wait(1.0/60.0)
		if e.state == 4: saw_search = true
		if e.state == 6: saw_return = true
		if saw_return: break
	ck(saw_search or saw_return, "丢失目标后进入 SEARCH/RETURN（当前 %s）" % _sname(e.state))
	ck(saw_return, "最终放弃追击并返回岗位")

	# 听觉
	print("\n[听觉：枪声吸引]")
	var e2 = null
	for x in get_tree().get_nodes_in_group("enemies"):
		if x != e: e2 = x; break
	if e2:
		e2.state = 0
		e2.hear_gunshot(e2.global_position + Vector2(200, 0))
		ck(e2.state == 5, "听到枪声进入 INVESTIGATE（当前 %s）" % _sname(e2.state))
	else:
		print("      （只有一个小兵，跳过）")

	# 被打反应
	print("\n[背后受击反应]")
	var e3 = null
	for x in get_tree().get_nodes_in_group("enemies"):
		if x != e and x != e2: e3 = x; break
	if e3:
		e3.state = 0
		var hp0: float = e3.health.hp
		e3.take_damage(5.0, e3.global_position + Vector2(-300, 0))
		ck(e3.health.hp < hp0, "受到伤害 %.0f -> %.0f" % [hp0, e3.health.hp])
		ck(e3.state == 2, "被背后打击后转入 CHASE 朝来向找（当前 %s）" % _sname(e3.state))
	# 击杀
	print("\n[击杀]")
	if e3:
		e3.take_damage(9999.0, Vector2.ZERO)
		ck(e3.is_dead(), "血量归零后死亡")
		ck(not e3.is_in_group("enemies"), "死亡后移出 enemies 组")

	print("")
	if fails.is_empty():
		print("✅ 怪物 AI 验证全部通过")
	else:
		print("❌ 失败 %d 项：" % fails.size())
		for f in fails: print("   - ", f)
	get_tree().quit(0 if fails.is_empty() else 1)

func _sname(s: int) -> String:
	var n := ["PATROL","ALERT","CHASE","ENGAGE","SEARCH","INVESTIGATE","RETURN","DEAD"]
	return n[s] if s < n.size() else str(s)

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
