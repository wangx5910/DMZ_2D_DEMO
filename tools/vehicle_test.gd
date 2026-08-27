extends Node
## 载具验证：上下车、4 座、驾驶、受损、爆炸链、爆炸伤乘员、残骸留场
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
	print("=== 载具验证 ===")
	var vs = get_tree().get_nodes_in_group("vehicles")
	ck(vs.size() > 0, "已投放 %d 辆载具" % vs.size())
	if vs.is_empty():
		get_tree().quit(1); return

	# 投放分布
	print("\n[投放分布]")
	var near_spawn := 0
	var in_poi := 0
	for v in vs:
		if v.global_position.distance_to(w.spawn_point) < 700.0:
			near_spawn += 1
		var cell = Vector2i(int(v.global_position.x/40), int(v.global_position.y/40))
		if w._cell_in_any_poi(cell):
			in_poi += 1
	ck(near_spawn >= 2, "出生点 700m 内有 %d 辆（开局可用）" % near_spawn)
	ck(in_poi == 0, "没有载具生成在 POI 内部（%d 辆）" % in_poi)
	var kinds := {}
	for v in vs:
		kinds[v.vtype] = int(kinds.get(v.vtype, 0)) + 1
	print("      车型分布 ", kinds)

	# 生成位置不卡墙
	var stuck_in_wall := 0
	var space = get_viewport().world_2d.direct_space_state
	for v in vs:
		var q = PhysicsPointQueryParameters2D.new()
		q.position = v.global_position
		q.collision_mask = 1 << 0
		if not space.intersect_point(q, 1).is_empty():
			stuck_in_wall += 1
	ck(stuck_in_wall == 0, "没有载具卡在墙里（%d 辆）" % stuck_in_wall)

	# 上下车
	print("\n[上下车]")
	Tuning.set_value("god_mode", true)
	var v0 = vs[0]
	ck(v0.SEAT_COUNT == 4, "座位数 = 4")
	ck(v0.seats.size() == 4 and v0.occupant_count() == 0, "初始无乘员")
	p.global_position = v0.global_position + Vector2(30, 0)
	await _wait(0.05)
	ck(p._nearest_boardable_vehicle() == v0, "靠近时能识别到可上车的载具")
	p._enter_vehicle(v0)
	ck(p.vehicle == v0, "上车成功")
	ck(p.vehicle_seat == 0, "优先分配驾驶位（座位 %d）" % p.vehicle_seat)
	ck(v0.driver() == p, "驾驶位登记正确")
	ck(p.is_driving(), "is_driving 为真")
	ck(v0.occupant_count() == 1, "乘员数 = 1")

	# 4 座容量
	var dummies: Array = []
	for i in 3:
		var d = CharacterBody2D.new()
		add_child(d)
		dummies.append(d)
		ck(v0.board(d) == i + 1, "第 %d 个乘客上车（座位 %d）" % [i + 1, i + 1])
	ck(v0.occupant_count() == 4, "满座 4 人")
	ck(not v0.has_room(), "满座后无法再上人")
	var extra = CharacterBody2D.new()
	add_child(extra)
	ck(v0.board(extra) == -1, "第 5 人被拒绝")

	# 驾驶：位置应变化
	print("\n[驾驶]")
	var pos0: Vector2 = v0.global_position
	var spd_seen := 0.0
	# 直接给速度模拟油门（headless 下模拟按键不可靠）
	for i in 90:
		v0.speed = move_toward(v0.speed, Tuning.vehicle_max_speed, Tuning.vehicle_accel / 60.0)
		spd_seen = max(spd_seen, absf(v0.speed))
		await _wait(1.0/60.0)
	var moved: float = pos0.distance_to(v0.global_position)
	ck(moved > 100.0, "车辆行驶了 %.0f px（%.0f 米）" % [moved, moved/8.0])
	ck(spd_seen > 200.0, "达到速度 %.0f px/s（%.0f km/h）" % [spd_seen, spd_seen/8.0*3.6])
	# 乘员跟车
	ck(p.global_position.distance_to(v0.global_position) < 60.0, "乘员位置跟随车体")
	ck(Tuning.vehicle_max_speed > Tuning.sprint_speed * 1.5,
		"车速 %.0f 明显快于跑速 %.0f" % [Tuning.vehicle_max_speed, Tuning.sprint_speed])

	# 受损
	print("\n[受损与爆炸]")
	var hp0: float = v0.health.hp
	v0.take_damage(100.0, v0.global_position + Vector2(200, 0))
	ck(v0.health.hp < hp0, "受到伤害 %.0f -> %.0f" % [hp0, v0.health.hp])
	ck(not v0.is_wrecked(), "未到爆炸阈值时仍可驾驶")
	# 打空进入引信阶段
	v0.take_damage(9999.0, Vector2.ZERO)
	ck(v0.is_wrecked(), "血量归零 → 进入起火状态")
	ck(v0._exploding, "起火倒计时已启动（引信 %.1fs）" % Tuning.vehicle_fuse_time)
	ck(p.vehicle == v0, "起火但还没炸，玩家仍在车上（有跳车窗口）")
	# 等爆炸
	var hp_before: float = p.health.hp
	Tuning.set_value("god_mode", false)
	var wreck_count_before: int = get_tree().get_nodes_in_group("wrecks").size()
	for i in int((Tuning.vehicle_fuse_time + 0.6) * 60):
		await _wait(1.0/60.0)
		if not is_instance_valid(v0):
			break
	ck(not is_instance_valid(v0), "引信结束后车辆已销毁")
	ck(p.vehicle == null, "爆炸时乘员被强制踢下车")
	ck(p.health.hp < hp_before, "爆炸对乘员造成伤害 %.0f -> %.0f" % [hp_before, p.health.hp])
	ck(get_tree().get_nodes_in_group("wrecks").size() > wreck_count_before,
		"留下焦黑残骸（情报标记）")
	ck(int(RaidLog.stats.get("vehicles_destroyed", 0)) > 0, "击毁统计已记录")

	for d in dummies:
		d.queue_free()
	extra.queue_free()

	print("")
	if fails.is_empty():
		print("✅ 载具验证全部通过")
	else:
		print("❌ 失败 %d 项：" % fails.size())
		for f in fails: print("   - ", f)
	get_tree().quit(0 if fails.is_empty() else 1)

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout
