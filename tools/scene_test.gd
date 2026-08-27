extends Node
## 场景自检：作为节点挂进真实运行的主场景，跑几帧后自动断言并退出。
## 跑法：把本脚本作为 autoload 或在 main.gd 里按 --scene-test 参数挂载。

var fails: Array[String] = []
var _frames := 0
var _done := false

func _ready() -> void:
	print("=== 主场景运行自检 ===")

func ck(cond: bool, label: String) -> void:
	print(("  ✓ " if cond else "  ✗ ") + label)
	if not cond:
		fails.append(label)

func _process(_d: float) -> void:
	_frames += 1
	if _frames < 10 or _done:
		return
	_done = true
	_run()

func _run() -> void:
	var inst = get_parent()
	ck(inst != null, "主场景根节点存在")

	# 关卡节点名随模式不同：大地图 = World，小图 = Level
	var lvl = inst.get_node_or_null("World")
	var is_world: bool = lvl != null
	if lvl == null:
		lvl = inst.get_node_or_null("Level")
	ck(lvl != null, "关卡节点存在（%s 模式）" % ("大地图" if is_world else "小图"))

	var p = inst.get_node_or_null("Player")
	ck(p != null, "Player 节点存在")
	if p:
		ck(p.global_position != Vector2.ZERO, "玩家在出生点 %s" % str(p.global_position))
		ck(p.get_node_or_null("Vision") != null, "Vision 子节点存在")
		ck(p.get_node_or_null("Cam") != null, "相机存在")
		ck(p.get_node_or_null("Body") != null, "外观节点存在")
		ck(p.stamina > 0.0, "体力已初始化 = %.0f" % p.stamina)
		ck(p.vision_range() > 0.0, "视野范围 = %.0f px" % p.vision_range())
		ck(p.vision_half_angle_deg() > 0.0, "视野半角 = %.0f°" % p.vision_half_angle_deg())

	var containers := get_tree().get_nodes_in_group("containers")
	# 大地图容器由约 13 个放大 POI 程序化生成；小图是固定 22
	var min_c: int = 100 if is_world else 22
	ck(containers.size() >= min_c, "容器数 %d（≥%d）" % [containers.size(), min_c])

	# 墙体：小图直接挂在 Walls 下；大地图按 POI 分组（Walls/PoiWalls_N/...）
	var walls = lvl.get_node_or_null("Walls") if lvl else null
	var wall_n := 0
	if walls:
		for ch in walls.get_children():
			wall_n += 1 if ch is StaticBody2D else ch.get_child_count()
	ck(wall_n > 0, "墙体已生成 %d 段（横向合并后）" % wall_n)

	# 出生点不能卡墙
	if p:
		var space = get_viewport().world_2d.direct_space_state
		var q := PhysicsPointQueryParameters2D.new()
		q.position = p.global_position
		q.collision_mask = 1 << 0
		var hits: Array = space.intersect_point(q)
		ck(hits.is_empty(), "出生点未卡在墙里")

	# 所有容器都不能埋在墙里（否则玩家永远搜不到）
	if containers.size() > 0:
		var space2 = get_viewport().world_2d.direct_space_state
		var buried := 0
		for c in containers:
			var q2 := PhysicsPointQueryParameters2D.new()
			q2.position = c.global_position
			q2.collision_mask = 1 << 0
			if not space2.intersect_point(q2).is_empty():
				buried += 1
		ck(buried == 0, "无容器被埋在墙里（实际 %d 个）" % buried)

	# 视野射线
	var vis = p.get_node_or_null("Vision") if p else null
	if vis:
		var far: Vector2 = p.global_position + Vector2(5000, 0)
		ck(vis.is_point_visible(far, p) == false, "超远点不可见")
		# 正前方近点应可见（出生点朝右，右边是房间内部）
		p.aim_dir = Vector2.RIGHT
		var near: Vector2 = p.global_position + Vector2(25, 0)
		ck(vis.is_point_visible(near, p), "正前方 25px 可见")
		# 近身圆形视野（proximity_radius）内、扇形外的身后点应可见
		var behind_near: Vector2 = p.global_position + Vector2(-100, 0)
		ck(vis.is_point_visible(behind_near, p), "正后方 100px（圆形视野内）可见")
		# 超出圆形视野、且不在扇形内 → 仍不可见（扇形遮蔽依旧生效）
		var behind_far: Vector2 = p.global_position + Vector2(-260, 0)
		ck(vis.is_point_visible(behind_far, p) == false, "正后方 260px（圆形视野外）不可见（扇形生效）")

	# UI
	var hud = inst.get_node_or_null("HUD")
	ck(hud != null, "HUD 存在")
	ck(inst.inv != null, "背包实例已创建")
	if inst.inv:
		ck(inst.inv.capacity() == 60, "背包容量 60")
		ck(inst.inv.add_auto("gold_bar"), "背包可放入金条")
	ck(inst.loot_ui != null, "搜刮面板存在")
	ck(inst.loot_ui.visible == false, "面板初始隐藏")
	var mm = inst.get_node_or_null("Minimap")
	ck(mm != null, "小地图节点存在")
	if mm:
		ck(mm.full_screen == false, "全屏地图初始关闭")
		mm.full_screen = true
		ck(mm.full_screen, "可切换到全屏地图")
		mm.full_screen = false
	if is_world:
		ck(lvl.spawn_poi_name != "", "出生点绑定 POI：%s" % lvl.spawn_poi_name)
		var np2 = lvl.nearest_poi(lvl.spawn_point)
		if not np2.is_empty():
			# 出生点应贴着 POI 外墙：到 POI 矩形边缘的距离要小于视距
			var pr: Rect2 = Rect2()
			for pp in lvl.pois:
				if pp["def"]["name"] == lvl.spawn_poi_name:
					pr = pp["rect"]
					break
			if pr.size.x > 0:
				var edge_d: float = _rect_edge_distance(pr, lvl.spawn_point) / 8.0
				ck(edge_d <= 60.0, "出生点距建筑外墙 %.0f 米（应 ≤60，即视距内）" % edge_d)
	var dbg = inst.get_node_or_null("DebugPanel")
	ck(dbg != null, "调试面板存在")
	ck(dbg.visible == false, "调试面板初始隐藏")

	# 模拟一次完整搜刮：把玩家挪到最近容器旁，走完整个逐格流程
	if p and containers.size() > 0:
		var target = containers[0]
		p.global_position = target.global_position + Vector2(20, 0)
		var n: int = target.slot_count()
		print("      模拟搜刮 %s（%s，%d 格）" % [target.name, target.richness, n])
		var t0 := Time.get_ticks_msec()
		for i in n:
			target.reveal_slot(i)
		ck(target.is_fully_searched(), "模拟搜完全部 %d 格" % n)
		var got := 0
		for i in n:
			if target.take_slot(i) != "":
				got += 1
		print("      取出 %d 件，容器剩余价值 %d" % [got, target.remaining_value()])
		ck(target.remaining_value() == 0, "全部取走后剩余价值 = 0")


	# ── 枪械系统 ──
	if p and p.weapon != null:
		var w = p.weapon
		ck(w.display_name() != "", "枪械已装备：%s" % w.display_name())
		ck(w.mag == 30, "初始弹匣 30（实际 %d）" % w.mag)
		ck(w.mag_size() == 30, "弹匣容量 30")
		ck(w.fire_mode == "auto", "初始为全自动（实际 %s）" % w.fire_mode)
		ck(w.reserve > 0, "备弹 %d 发" % w.reserve)
		# 开火
		var fired := 0
		for i in 40:
			if w.try_fire(true, p.global_position, Vector2.RIGHT, 0, false):
				fired += 1
			w.tick(1.0 / 60.0, false, 0)
		ck(fired > 0, "全自动连发打出 %d 发" % fired)
		ck(w.mag < 30, "弹匣已消耗（剩 %d）" % w.mag)
		ck(w.spread > 0.0, "连发扩散累积到 %.2f°" % w.spread)
		# 扩散上限
		var sp_walk: float = w.effective_spread(0)
		var sp_sprint: float = w.effective_spread(1)
		var sp_crouch: float = w.effective_spread(2)
		ck(sp_sprint > sp_walk, "冲刺扩散 %.2f > 行走 %.2f" % [sp_sprint, sp_walk])
		ck(sp_crouch < sp_walk, "潜行扩散 %.2f < 行走 %.2f" % [sp_crouch, sp_walk])
		# 单发模式
		w.cycle_fire_mode()
		ck(w.fire_mode == "single", "切换到单发（实际 %s）" % w.fire_mode)
		var single_shots := 0
		for i in 30:
			if w.try_fire(true, p.global_position, Vector2.RIGHT, 0, false):
				single_shots += 1
			w.tick(1.0 / 60.0, false, 0)
		ck(single_shots <= 1, "单发模式按住只打 1 发（实际 %d）" % single_shots)
		# 换弹
		var mag_before: int = w.mag
		var res_before: int = w.reserve
		ck(w.start_reload(false), "可以开始换弹")
		ck(w.reloading, "处于换弹中")
		for i in 300:
			w.tick(1.0 / 60.0, false, 0)
			if not w.reloading:
				break
		ck(not w.reloading, "换弹已完成")
		ck(w.mag == 30, "换弹后弹匣满 30（实际 %d）" % w.mag)
		ck(w.reserve < res_before, "备弹已扣减 %d -> %d" % [res_before, w.reserve])
		# 距离衰减
		var d_near: float = w.damage_at(100.0)
		var d_far: float = w.damage_at(880.0)
		ck(d_near > d_far, "近距伤害 %.1f > 远距 %.1f" % [d_near, d_far])
		ck(is_equal_approx(d_near, w.damage()), "衰减起点内为满伤害")
		# 打空后无限备弹
		w.reserve = 0
		w.mag = 0
		ck(w.can_reload(false) == false, "无备弹时不能换弹")
		ck(w.can_reload(true), "无限备弹开关下可换弹")
		w.refill_all()
		ck(w.mag == 30 and w.reserve > 0, "refill_all 补满")
	else:
		ck(false, "枪械未初始化")

	# 射击表现层
	var fxn = inst.get_node_or_null("CombatFX")
	ck(fxn != null, "CombatFX 节点存在")
	if fxn:
		fxn.add_tracer(Vector2.ZERO, Vector2(300, 0), 2600.0)
		fxn.add_spark(Vector2(300, 0))
		fxn.add_muzzle(Vector2.ZERO, Vector2.RIGHT)
		ck(true, "表现层调用无异常")
	var chn = inst.get_node_or_null("Crosshair")
	ck(chn != null, "准星节点存在")

	# 日志导出
	var rl = get_node_or_null("/root/RaidLog")
	ck(rl != null, "RaidLog 存在")
	if rl:
		ck(rl.stats.has("slots_searched"), "统计字段已初始化")
		var path: String = rl.export_logs()
		ck(path != "", "日志导出路径 = %s" % path)

	# 参数系统
	var tn = get_node_or_null("/root/Tuning")
	ck(tn != null, "Tuning 存在")
	if tn:
		tn.reset_all()   # 先清掉可能存在的 user:// 存档覆盖，保证取样的是脚本默认值
		var before: float = tn.walk_speed
		tn.set_value("walk_speed", 222.0)
		ck(tn.walk_speed == 222.0, "参数可写入")
		tn.reset_all()
		ck(tn.walk_speed == before, "恢复默认生效")
		ck(tn.SPEC.size() > 0, "参数分组 = %d 组" % tn.SPEC.size())
		var slider_n := 0
		for g in tn.SPEC.values():
			slider_n += g.size()
		ck(slider_n > 0, "滑条参数 = %d 个" % slider_n)
		ck(tn.TOGGLES.size() > 0, "机制开关 = %d 个" % tn.TOGGLES.size())

	print("")
	if fails.is_empty():
		print("✅ 主场景自检全部通过")
	else:
		print("❌ 失败 %d 项：" % fails.size())
		for f in fails:
			print("   - ", f)
	get_tree().quit(0 if fails.is_empty() else 1)

## 点到矩形边缘的最短距离（点在矩形外时为正）
func _rect_edge_distance(r: Rect2, p: Vector2) -> float:
	var dx: float = maxf(maxf(r.position.x - p.x, 0.0), p.x - r.end.x)
	var dy: float = maxf(maxf(r.position.y - p.y, 0.0), p.y - r.end.y)
	return sqrt(dx * dx + dy * dy)
