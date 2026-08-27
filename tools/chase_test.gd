extends Node
## 追击卡墙检测：把玩家放在墙后面，看 AI 追击时会不会顶墙
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
	var p = get_parent().player
	var w = get_parent().level
	Tuning.set_value("god_mode", true)
	seed(20260819)   # 固定场景选择，便于复现与对比
	print("=== 追击卡墙检测（确定性种子）===")

	# 挑一个 POI，把 AI 放里面，玩家放到墙的另一侧
	var poi = w.pois[0]
	var gen = poi["gen"]
	var origin: Vector2i = poi["origin"]
	var pool: Array = gen.standable_cells(true)
	# **关键**：POI 墙体按距离启停碰撞，必须先把玩家挪进去激活，
	# 否则射线直接穿过"没有碰撞体"的墙，一个隔墙场景都找不到。
	p.global_position = Vector2(
		(origin.x + gen.cfg.width * 0.5) * 40.0,
		(origin.y + gen.cfg.height * 0.5) * 40.0)
	w.set_player(p)
	await _wait(0.3)

	# 找一对"直线不可达但绕路可达"的格子（中间隔墙）
	var space := get_viewport().world_2d.direct_space_state
	var tested := 0
	var frozen_cases := 0
	var reached := 0
	var enemies = get_tree().get_nodes_in_group("enemies")

	for trial in 60:
		if trial >= enemies.size(): break
		var e = enemies[trial]
		# 随机取两个格，要求它们之间有墙阻隔
		var a: Vector2i = pool[randi() % pool.size()]
		var b: Vector2i = pool[randi() % pool.size()]
		var pa := Vector2((origin.x+a.x)*40+20, (origin.y+a.y)*40+20)
		var pb := Vector2((origin.x+b.x)*40+20, (origin.y+b.y)*40+20)
		if pa.distance_to(pb) < 240.0 or pa.distance_to(pb) > 700.0:
			continue
		var q := PhysicsRayQueryParameters2D.create(pa, pb)
		q.collision_mask = 1 << 0
		if space.intersect_ray(q).is_empty():
			continue    # 直线通的，不是我们要测的情况
		tested += 1
		e.global_position = pa
		e.post = pa
		e.aim_dir = (pb - pa).normalized()
		e.target = p
		e.last_known_pos = pb
		e._lose_timer = 999.0
		e.state = 2   # CHASE
		p.global_position = pb
		var start := pa
		var path := 0.0
		var last := pa
		for i in 480:   # 8 秒（绕墙绕路需要更长时间，给足预算）
			await _wait(1.0/60.0)
			p.global_position = pb    # 玩家钉住不动
			e.target = p
			e.last_known_pos = pb
			e._lose_timer = 999.0
			if e.state == 2 or e.state == 3:
				pass
			else:
				e.state = 2
			path += last.distance_to(e.global_position)
			last = e.global_position
		var d_now: float = e.global_position.distance_to(pb)
		var got := d_now < 200.0
		var frozen := (not got) and path < 250.0   # 没到且几乎没动 = 真冻结
		if got: reached += 1
		if frozen: frozen_cases += 1
		var tag := "✓到达" if got else ("✗冻结" if frozen else "…绕路未达")
		print("    #%d 距目标 %.0f → 5秒后 %.0f ｜ 走了 %.0f px ｜ %s" % [
			tested, start.distance_to(pb), d_now, path, tag])

	print("")
	print("  隔墙追击测试 %d 例：到达 %d ｜ 真冻结 %d ｜ 绕路未达 %d" % [
		tested, reached, frozen_cases, tested - reached - frozen_cases])
	ck(tested >= 6, "找到了 %d 个隔墙场景（≥6）" % tested)
	ck(frozen_cases * 2 <= tested, "真冻结比例 %.0f%%（应 ≤50%%）" % (100.0*frozen_cases/maxi(tested,1)))
	ck(100.0*reached/maxi(tested,1) >= 40.0, "到达比例 %.0f%%（应 ≥40%%）" % (100.0*reached/maxi(tested,1)))

	print("")
	print("✅ 追击导航合格" if fails.is_empty() else "❌ %d 项不合格" % fails.size())
	get_tree().quit(0 if fails.is_empty() else 1)

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
