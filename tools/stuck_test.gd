extends Node
## 严格卡墙检测：不只看"有没有位移"，而是统计
##  A) 卡住计时（_nav_stuck）累计占比 —— 贴墙磨蹭
##  B) 导航放弃次数（_nav_giveups）
##  C) 移动效率 = 实际位移 / 理论位移（速度积分）—— 抖动时效率极低
##  D) 与最近墙体的距离 —— 长期贴墙
var _f := 0
var _done := false
var _stat: Dictionary = {}   ## enemy -> {stuck_frames, samples, path, ideal, near_wall}
var _sampling := false
const SAMPLE_FRAMES := 900   ## 15 秒

func _process(d: float) -> void:
	_f += 1
	if _done: return
	if _f == 20:
		Tuning.set_value("god_mode", true)
		get_parent().player.global_position = Vector2(-90000, -90000)
		for e in get_tree().get_nodes_in_group("enemies"):
			_stat[e] = {"stuck": 0, "n": 0, "path": 0.0, "ideal": 0.0,
				"wall": 0, "last": e.global_position, "giveups0": e._nav_giveups}
		_sampling = true
		print("=== 严格卡墙检测：%d 个小兵 / %d 帧 ===" % [_stat.size(), SAMPLE_FRAMES])
	if _sampling:
		var space := get_viewport().world_2d.direct_space_state
		for e in _stat.keys():
			if not is_instance_valid(e): continue
			var st: Dictionary = _stat[e]
			st["n"] += 1
			if e._nav_stuck > 0.05:
				st["stuck"] += 1
			var moved: float = st["last"].distance_to(e.global_position)
			st["path"] += moved
			st["ideal"] += e.velocity.length() * d
			st["last"] = e.global_position
			# 每 15 帧测一次贴墙（省开销）
			if st["n"] % 15 == 0:
				var q := PhysicsShapeQueryParameters2D.new()
				var c := CircleShape2D.new()
				c.radius = e.RADIUS + 4.0
				q.shape = c
				q.transform = Transform2D(0.0, e.global_position)
				q.collision_mask = 1 << 0
				if not space.intersect_shape(q, 1).is_empty():
					st["wall"] += 1
	if _f == 20 + SAMPLE_FRAMES:
		_done = true
		_report()

func _report() -> void:
	var bad: Array = []
	var worst: Array = []
	for e in _stat.keys():
		if not is_instance_valid(e): continue
		var st: Dictionary = _stat[e]
		var n: int = maxi(st["n"], 1)
		var stuck_pct: float = 100.0 * st["stuck"] / n
		var eff: float = st["path"] / maxf(st["ideal"], 1.0)
		var wall_pct: float = 100.0 * st["wall"] / maxi(n / 15, 1)
		var giveups: int = e._nav_giveups - st["giveups0"]
		# 判定为"卡墙"：卡住计时占比 >12%，或移动效率 <0.55（抖动），或长期贴墙 >55%
		var is_bad: bool = stuck_pct > 12.0 or eff < 0.55 or wall_pct > 55.0
		var rec := {"e": e, "stuck": stuck_pct, "eff": eff, "wall": wall_pct, "gv": giveups}
		if is_bad:
			bad.append(rec)
		worst.append(rec)
	worst.sort_custom(func(a, b): return a["eff"] < b["eff"])
	var total: int = _stat.size()
	print("  卡墙个体 %d / %d（%.1f%%）" % [bad.size(), total, 100.0*bad.size()/maxi(total,1)])
	print("\n  [移动效率最差 8 个]")
	for i in mini(8, worst.size()):
		var r: Dictionary = worst[i]
		var e = r["e"]
		print("    格(%3d,%3d) 状态=%d 效率=%.2f 卡住占比=%.0f%% 贴墙=%.0f%% 放弃=%d 巡逻点=%d" % [
			int(e.global_position.x/40), int(e.global_position.y/40), e.state,
			r["eff"], r["stuck"], r["wall"], r["gv"], e.patrol_points.size()])
	# 整体分布
	var sum_eff := 0.0
	var sum_stuck := 0.0
	for r in worst:
		sum_eff += r["eff"]
		sum_stuck += r["stuck"]
	print("\n  全场平均：移动效率 %.2f ｜ 卡住占比 %.1f%%" % [
		sum_eff/maxi(worst.size(),1), sum_stuck/maxi(worst.size(),1)])
	print("")
	if bad.is_empty():
		print("✅ 无卡墙个体")
	else:
		print("❌ %d 个体卡墙" % bad.size())
	get_tree().quit(0 if bad.is_empty() else 1)
