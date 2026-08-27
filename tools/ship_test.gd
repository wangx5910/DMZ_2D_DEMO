extends Node
## 飞船全链路检测（传送门 + E 劫持 + 船内隔离）
var _f := 0
var _done := false
var fails: Array[String] = []
var _log: Array[String] = []

func _emit(line: String) -> void:
	print(line)
	_log.append(line)

func ck(cond: bool, label: String) -> void:
	_emit(("  ✓ " if cond else "  ✗ ") + label)
	if not cond: fails.append(label)

func _process(_d: float) -> void:
	_f += 1
	if _f < 10 or _done:
		return
	_done = true
	_run()

func _run() -> void:
	var w = get_parent().level
	var p = get_parent().player
	Tuning.set_value("enable_spaceship", true)
	Tuning.set_value("enable_spaceship_hijack", true)
	Tuning.set_value("spaceship_lift_time", 1.0)
	Tuning.set_value("spaceship_crack_hold", 3.0)
	_emit("=== 飞船全链路检测 ===")

	ck(w.spaceship_state() < 0, "A0 召唤前无飞船")
	w.force_spawn_spaceship()
	var ship = w.spaceship
	ck(ship != null, "A1 飞船已刷出")
	ck(w.ship_loot_nodes.size() >= 12, "A2 船内 POI 容器（%d 个）" % w.ship_loot_nodes.size())
	ck(ship._portal_exterior.size() == 2, "A3 左右两侧各一个外部传送门")

	# B 外部传送门登舰
	p.aboard_ship = null
	p._portal_channel_t = 0.0
	var boarded := false
	for i in 120:
		p.global_position = ship.global_position + ship._portal_exterior[1]
		await _wait(1.0 / 30.0)
		if p.aboard_ship != null:
			boarded = true
			break
	ck(boarded, "B1 外部传送门读条登舰")

	# C 船内搜刮 + 密闭舱预览锁定
	if w.ship_loot_nodes.size() > 0:
		var c = w.ship_loot_nodes[0]
		p.global_position = c.global_position
		p._begin_search(c)
		ck(p.searching_container == c, "B2 船内可搜刮 POI 容器")
		if p.searching_container != null:
			p.abort_search("test_done")
	var sealed: Array = ship.sealed_containers
	ck(sealed.size() == 4, "B3 密闭舱预览容器 %d 个" % sealed.size())
	ck(ship.sealed_preview_value > 0, "B4 密闭舱预估价值 ¥%d" % ship.sealed_preview_value)
	if sealed.size() > 0:
		var sc = sealed[0]
		p.global_position = sc.global_position
		p._begin_search(sc)
		ck(p.searching_container == sc, "B5 密闭舱可预览打开")
		var took := sc.take_slot(0)
		ck(took == "" and sc.take_locked, "B6 预览态不可取出")
		if p.searching_container != null:
			p.abort_search("test_done")
	ck(ship._wall_rects.size() > 8, "B7 POI 墙体已绘制 %d 块" % ship._wall_rects.size())
	ck(ship._walls_holder.get_child_count() > 8, "B8 POI 墙体碰撞体 %d" % ship._walls_holder.get_child_count())

	# D E 键劫持 → 自动入座
	p.global_position = ship.global_position + ship._control_local
	var hijacked: bool = ship.try_hijack(p)
	ck(hijacked, "C1 操控室 [E] 劫持成功")
	ck(ship.is_pilot(p), "C4 劫持后自动入座驾驶")
	if sealed.size() > 0:
		ck(sealed[0].take_locked, "C3 劫持后密闭舱仍锁定")
	ck(w.is_hijack_active(), "C2 全图广播激活")

	# E 开到破解点：自动破解，开放密闭舱，不整船撤离
	if w.crack_points.is_empty():
		w._build_crack_points()
	if w.crack_points.is_empty():
		w.crack_points.append(ship.global_position)
	ship.global_position = w.crack_points[0]
	ship._target = ship.global_position
	if not ship._aboard.has(p):
		ship._aboard.append(p)
	p.aboard_ship = ship
	var opened := false
	for i in 120:
		ship.tick(0.05, w)
		if ship.sealed_open:
			opened = true
			break
	ck(opened, "D1 靠近破解点后自动破解完成")
	ck(not w.extracted, "D2 破解成功不整船撤离")
	ck(int(ship.state) == 3, "D3 飞船进入开放态")
	if sealed.size() > 0:
		ck(not sealed[0].take_locked, "D4 密闭舱已解锁可取出")
		var took2 := sealed[0].take_slot(0)
		ck(took2 != "", "D5 玩家可拾取密闭舱物资")

	# F 内部传送门离开
	w.extracted = false
	w.hijack_active = null
	ship.state = 0
	ship.hijacker = null
	p.aboard_ship = null
	ship._aboard.clear()
	p.enter_ship(ship)
	p.global_position = ship.global_position + ship._portal_interior[0]
	p._portal_channel_t = 0.0
	var left := false
	for i in 120:
		p.global_position = ship.global_position + ship._portal_interior[0]
		ship.tick(0.05, w)
		if p.aboard_ship == null:
			left = true
			p.global_position = ship.global_position + ship._portal_exterior[0] + Vector2(0, 200)
			break
	ck(left, "E1 内部传送门读条离开")

	print("")
	_emit("✅ 飞船全链路合格" if fails.is_empty() else "❌ %d 项不合格：%s" % [fails.size(), fails])
	_write_result()
	get_tree().quit(0 if fails.is_empty() else 1)

func _write_result() -> void:
	var path := ProjectSettings.globalize_path("res://ship_test_result.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("ship_test: cannot write %s" % path)
		return
	f.store_string("\n".join(_log) + "\n")
	f.close()

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
