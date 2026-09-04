extends CanvasLayer
## HUD · 局内平视信息
##
## 只显示验证必需的读数：体力、姿态、交互提示、背包占用、局内计时。
## 全部自绘，不依赖美术资源。

var player = null   ## 无类型：需访问 player 脚本自定义成员
var inv: GridInventory = null
var world = null     ## WorldMap（撤离点 / 飞船状态查询）

var _font: Font
var _interact_target = null
var _search_cur := 0.0
var _search_total := 0.0
var _cracking := false
var _last_focus = null

@onready var _canvas: Control = Control.new()

func setup(p, inventory: GridInventory, w = null) -> void:
	player = p
	inv = inventory
	world = w
	p.interact_target_changed.connect(_on_target)
	p.search_progress.connect(_on_progress)
	p.search_state_changed.connect(_on_state)

func _ready() -> void:
	layer = 5
	_font = ThemeDB.fallback_font
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_hud)
	add_child(_canvas)

func _process(_delta: float) -> void:
	_canvas.queue_redraw()

func _on_target(t) -> void:
	if _last_focus != null and is_instance_valid(_last_focus) and _last_focus.has_method("set_focused"):
		_last_focus.set_focused(false)
	_interact_target = t
	_last_focus = t
	if t != null and t.has_method("set_focused"):
		t.set_focused(true)

func _on_progress(cur: float, total: float, slot: int, _n: int) -> void:
	_search_cur = cur
	_search_total = total
	_cracking = slot < 0

func _on_state(active: bool, _c) -> void:
	if not active:
		_search_total = 0.0

func _draw_hud() -> void:
	var vp := _canvas.size
	var c := _canvas

	# ── 左下：血量 ──
	if player != null and player.health != null:
		var hb := Rect2(Vector2(28, vp.y - 84), Vector2(240, 16))
		c.draw_rect(hb, Color(0.10, 0.07, 0.07, 0.85), true)
		var hr: float = player.health.ratio()
		var hcol := Color(0.85, 0.28, 0.26)
		if hr > 0.6:
			hcol = Color(0.80, 0.32, 0.30)
		elif hr > 0.3:
			hcol = Color(0.92, 0.55, 0.25)
		else:
			hcol = Color(0.95, 0.22, 0.20)
		c.draw_rect(Rect2(hb.position, Vector2(hb.size.x * hr, hb.size.y)), hcol, true)
		c.draw_rect(hb, Color(0.45, 0.30, 0.30, 0.9), false, 1.0)
		c.draw_string(_font, hb.position + Vector2(6, 13),
			"%d / %d" % [int(player.health.hp), int(player.health.hp_max)],
			HORIZONTAL_ALIGNMENT_LEFT, hb.size.x, 12, Color(1, 0.92, 0.90))
		if Tuning.god_mode:
			c.draw_string(_font, hb.position + Vector2(hb.size.x + 8, 13), "无敵",
				HORIZONTAL_ALIGNMENT_LEFT, 60, 12, Color(0.55, 0.95, 0.65))

	# 载具信息（在车上时）
	_draw_vehicle_block(c, vp)

	# 受击方向指示器（照搜打撤：被打了要知道从哪来的）
	_draw_hit_indicator(c, vp)

	# 死亡遮罩（撤离/阵亡结算面板会盖在上面）
	if player != null and player.is_dead() and not bool(player.get("raid_over")):
		c.draw_rect(Rect2(Vector2.ZERO, vp), Color(0.35, 0.02, 0.02, 0.42), true)
		c.draw_string(_font, Vector2(0, vp.y * 0.45), "已阵亡",
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 48, Color(0.95, 0.75, 0.72))
		c.draw_string(_font, Vector2(0, vp.y * 0.45 + 40), "[F5] 重开本局",
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 18, Color(0.80, 0.70, 0.70))

	# ── 左下：体力 + 姿态 ──
	var bar := Rect2(Vector2(28, vp.y - 58), Vector2(240, 12))
	if Tuning.enable_stamina and player != null:
		c.draw_rect(bar, Color(0.10, 0.11, 0.14, 0.85), true)
		var ratio: float = player.stamina / maxf(Tuning.stamina_max, 1.0)
		var col := Color(0.45, 0.82, 0.55)
		if ratio < 0.3:
			col = Color(0.92, 0.55, 0.30)
		if ratio < 0.12:
			col = Color(0.90, 0.30, 0.32)
		c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), col, true)
		c.draw_rect(bar, Color(0.35, 0.40, 0.50, 0.9), false, 1.0)
	if player != null:
		var names := ["行走", "冲刺", "潜行"]
		c.draw_string(_font, Vector2(28, vp.y - 68), names[player.stance],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.80, 0.86, 0.95))

	# ── 底部中央：交互提示 / 搜刮读条 / 传送门读条 ──
	var phone_up := false
	if world != null and world.get("contracts") != null and is_instance_valid(world.contracts):
		phone_up = world.contracts.is_phone_ringing()
	if phone_up:
		pass
	elif player != null and player._portal_channel_t > 0.0 and Tuning.spaceship_lift_time > 0.0:
		var pw := 320.0
		var pr := Rect2(Vector2(vp.x * 0.5 - pw * 0.5, vp.y - 118), Vector2(pw, 18))
		c.draw_rect(pr, Color(0.06, 0.10, 0.16, 0.92), true)
		var fill: float = clampf(player._portal_channel_t / Tuning.spaceship_lift_time, 0.0, 1.0)
		c.draw_rect(Rect2(pr.position, Vector2(pr.size.x * fill, pr.size.y)), Color(0.45, 0.88, 1.0), true)
		c.draw_rect(pr, Color(0.45, 0.75, 0.95), false, 1.0)
		var plbl := "传送中：%s…" % player._portal_channel_label
		c.draw_string(_font, pr.position + Vector2(0, -6), plbl,
			HORIZONTAL_ALIGNMENT_CENTER, pw, 14, Color(0.80, 0.95, 1.0))
	elif player != null and player.aboard_ship != null \
			and player.aboard_ship.has_method("is_pilot") and player.aboard_ship.is_pilot(player):
		var ship = player.aboard_ship
		c.draw_string(_font, Vector2(0, vp.y - 118), "[WASD] 驾驶飞船  ｜  [E] 离开驾驶座",
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 18, Color(1.0, 0.82, 0.40))
		if int(ship.state) == 2:
			var hold: float = Tuning.spaceship_crack_hold
			var pw := 360.0
			var pr := Rect2(Vector2(vp.x * 0.5 - pw * 0.5, vp.y - 148), Vector2(pw, 16))
			var fill: float = clampf(float(ship.crack_t) / maxf(hold, 0.01), 0.0, 1.0)
			c.draw_rect(pr, Color(0.06, 0.12, 0.16, 0.92), true)
			c.draw_rect(Rect2(pr.position, Vector2(pr.size.x * fill, pr.size.y)), Color(0.45, 0.95, 0.70), true)
			c.draw_rect(pr, Color(0.45, 0.85, 0.70), false, 1.0)
			c.draw_string(_font, pr.position + Vector2(0, -6),
				"自动破解 %.0f / %.0f 秒" % [ship.crack_t, hold],
				HORIZONTAL_ALIGNMENT_CENTER, pw, 13, Color(0.70, 1.0, 0.85))
	elif player != null and player.aboard_ship != null \
			and player.aboard_ship.is_in_control_room(player):
		var ship = player.aboard_ship
		if ship.has_method("can_contest") and ship.can_contest(player):
			c.draw_string(_font, Vector2(0, vp.y - 118), "[E] 夺取飞船控制权",
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 18, Color(1.0, 0.55, 0.35))
		elif ship.has_method("can_hijack") and ship.can_hijack(player):
			c.draw_string(_font, Vector2(0, vp.y - 118), "[E] 劫持飞船",
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 18, Color(1.0, 0.78, 0.35))
		elif ship.hijacker == player:
			c.draw_string(_font, Vector2(0, vp.y - 118), "[E] 入座驾驶",
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 18, Color(1.0, 0.82, 0.40))
	elif _search_total > 0.0:
		var pw := 320.0
		var pr := Rect2(Vector2(vp.x * 0.5 - pw * 0.5, vp.y - 118), Vector2(pw, 18))
		c.draw_rect(pr, Color(0.08, 0.09, 0.12, 0.9), true)
		var fill: float = clampf(_search_cur / _search_total, 0.0, 1.0)
		var fc := Color(0.90, 0.68, 0.25) if _cracking else Color(0.35, 0.68, 0.92)
		c.draw_rect(Rect2(pr.position, Vector2(pr.size.x * fill, pr.size.y)), fc, true)
		c.draw_rect(pr, Color(0.40, 0.46, 0.56), false, 1.0)
		var lbl := "破解免保柜…" if _cracking else "搜索中…"
		c.draw_string(_font, pr.position + Vector2(0, -6), lbl,
			HORIZONTAL_ALIGNMENT_CENTER, pw, 13, Color(0.86, 0.92, 1.0))
	elif _interact_target != null and is_instance_valid(_interact_target):
		var t = _interact_target
		var txt := ""
		if t.has_method("interact_prompt"):
			txt = t.interact_prompt()
		else:
			txt = "[E] 自动搜刮 %s（%s · %d/%d 格）" % [
				t.label, t.richness, t.revealed_count(), t.slot_count()]
			if t.get("take_locked") == true:
				txt = "[E] 预览 %s（不可取出 · 破解后开放）" % t.label
			elif t.richness == "L4" and not t.cracked:
				txt = "[E] 破解 %s（需 %.0f 秒，全程暴露）" % [t.label, Tuning.l4_crack_time]
		c.draw_string(_font, Vector2(0, vp.y - 118), txt,
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 15, Color(1.0, 0.88, 0.55))
	elif player != null and player.has_method("hostage_prompt"):
		var kp: String = player.hostage_prompt()
		if kp != "":
			c.draw_string(_font, Vector2(0, vp.y - 118), kp,
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 16, Color(0.55, 0.95, 1.0))

	# ── 右上：已提交 / 背包 / 寄存预览 ──
	if inv != null:
		var secured := 0
		var stash_v := 0
		if player != null:
			secured = int(player.get("secured_value"))
			if player.get("stash") != null:
				stash_v = int(player.stash.total_value())
		var bag_v: int = inv.total_value()
		c.draw_string(_font, Vector2(vp.x - 380, 34),
			"已提交 ¥%d ｜ 背包 ¥%d ｜ 寄存 ¥%d" % [secured, bag_v, stash_v],
			HORIZONTAL_ALIGNMENT_RIGHT, 352, 15, Color(0.80, 0.88, 0.98))
		c.draw_string(_font, Vector2(vp.x - 380, 54),
			"未提交物资死亡掉落 ｜ [T] 背包 ｜ [M] 地图 ｜ [F5] 重开",
			HORIZONTAL_ALIGNMENT_RIGHT, 352, 12, Color(0.52, 0.58, 0.68))
		if Tuning.enable_enemies:
			var alive: int = get_tree().get_nodes_in_group("enemies").size()
			c.draw_string(_font, Vector2(vp.x - 340, 74),
				"敌人存活 %d ｜ 击杀 %d" % [alive, int(RaidLog.stats.get("enemies_killed", 0))],
				HORIZONTAL_ALIGNMENT_RIGHT, 312, 12, Color(0.88, 0.55, 0.50))

	# ── 右下：弹药与枪械状态 ──
	_draw_weapon_block(c, vp)

	# ── 左上：局内计时 ──
	c.draw_string(_font, Vector2(28, 36), "局内 %.0f 秒" % RaidLog.t(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.70, 0.76, 0.88))
	if NetHub.is_online():
		var role := "房主" if NetHub.mode == NetHub.Mode.HOST else "加入"
		var extra := ""
		if NetHub.mode == NetHub.Mode.HOST:
			extra = "  %s:%d%s" % [
				NetHub.primary_ip(), NetHub.bind_port,
				"  Tailscale" if NetHub.has_tailscale() else ""]
		c.draw_string(_font, Vector2(28, 54),
			"局域网 %s  人数 %d/%d  你是 P%d%s" % [
				role, NetHub.player_count(), NetHub.MAX_PLAYERS, NetHub.local_peer_id, extra],
			HORIZONTAL_ALIGNMENT_LEFT, 920, 13, Color(0.55, 0.92, 0.72))
		if NetHub.mode == NetHub.Mode.HOST:
			var others: PackedStringArray = []
			for e in NetHub.lan_addresses():
				var ip: String = str(e.get("ip", ""))
				if ip == NetHub.primary_ip():
					continue
				if bool(e.get("tailscale", false)):
					others.append(ip + "(Tailscale)")
				elif bool(e.get("virtual", false)):
					others.append(ip + "(虚拟)")
				else:
					others.append(ip)
			if others.size() > 0:
				c.draw_string(_font, Vector2(28, 70),
					"其他本机地址  " + "  ".join(others),
					HORIZONTAL_ALIGNMENT_LEFT, 920, 12, Color(0.50, 0.70, 0.62))

	# ── 撤离 / 飞船 流程信息 ──
	_draw_flow(c, vp)
	_draw_settle(c, vp)

## 载具信息块：车内显示座位/时速/车况；车外靠近提示上车
func _draw_vehicle_block(c: Control, vp: Vector2) -> void:
	if player == null:
		return
	var v = player.vehicle
	if v == null or not is_instance_valid(v):
		# 车外：靠近可上车的车时给提示（跟容器提示同一区域，但优先级更高）
		var near = player._nearest_boardable_vehicle()
		if near != null:
			var seats_txt := "%d/%d 座" % [near.occupant_count(), near.SEAT_COUNT]
			var role_hint := "驾驶" if near.occupant_count() == 0 else "乘客"
			var t := "[E] 上车当%s（%s ｜ %s ｜ 车况 %d%%）" % [
				role_hint, near.vtype, seats_txt, int(near.health.ratio() * 100.0)]
			c.draw_string(_font, Vector2(0, vp.y * 0.62), t,
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 19, Color(0.85, 0.92, 0.72))
		return

	# 车内 HUD：时速 + 座位 + 车况 + 起火警告
	var kmh: float = absf(v.speed) / 8.0 * 3.6      # px/s → m/s → km/h
	var role := "驾驶" if player.vehicle_seat == 0 else "乘客%d" % player.vehicle_seat
	var box := Rect2(Vector2(vp.x * 0.5 - 170.0, vp.y - 150.0), Vector2(340.0, 54.0))
	c.draw_rect(box, Color(0.07, 0.08, 0.11, 0.80), true)
	c.draw_rect(box, Color(0.35, 0.42, 0.52, 0.7), false, 1.5)
	c.draw_string(_font, box.position + Vector2(12, 24),
		"%s ｜ %.0f km/h ｜ 乘员 %d/%d" % [role, kmh, v.occupant_count(), v.SEAT_COUNT],
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 20, 17, Color(0.88, 0.93, 1.0))
	# 车况条
	var hb := Rect2(box.position + Vector2(12, 32), Vector2(box.size.x - 24, 8))
	c.draw_rect(hb, Color(0.10, 0.10, 0.12, 0.9), true)
	var vr: float = v.health.ratio()
	var vc := Color(0.45, 0.82, 0.50)
	if vr < 0.3:
		vc = Color(0.92, 0.26, 0.22)
	elif vr < 0.55:
		vc = Color(0.92, 0.68, 0.28)
	c.draw_rect(Rect2(hb.position, Vector2(hb.size.x * vr, hb.size.y)), vc, true)
	c.draw_string(_font, box.position + Vector2(12, box.size.y + 16),
		"[WASD] 驾驶 ｜ [E] 下车" if player.vehicle_seat == 0 else "[鼠标] 射击 ｜ [E] 下车",
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x, 12,
		Color(0.55, 0.62, 0.72))
	if v.is_wrecked():
		# 引信倒计时：这是 DMZ 最有戏的瞬间 —— 跳还是再冲两秒
		c.draw_string(_font, Vector2(0, vp.y * 0.36), "⚠ 车辆起火，即将爆炸！[E] 跳车",
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 26, Color(1.0, 0.45, 0.30))

## 受击方向指示器：屏幕边缘朝来袭方向亮一道弧
func _draw_hit_indicator(c: Control, vp: Vector2) -> void:
	if player == null or player.health == null:
		return
	var age: float = player.health.since_hit()
	if age > 1.2:
		return
	var a: float = clampf(1.0 - age / 1.2, 0.0, 1.0)
	var dir: Vector2 = (player.health.last_hit_from - player.global_position)
	if dir.length_squared() < 1.0:
		return
	dir = dir.normalized()
	var center := vp * 0.5
	var rad: float = minf(vp.x, vp.y) * 0.42
	var base := dir.angle()
	var pts := PackedVector2Array()
	for i in 15:
		var t: float = -0.32 + 0.64 * (float(i) / 14.0)
		pts.append(center + Vector2.RIGHT.rotated(base + t) * rad)
	c.draw_polyline(pts, Color(1.0, 0.25, 0.22, 0.85 * a), 5.0)

func _mmss(sec: float) -> String:
	var s: int = maxi(0, int(ceil(sec)))
	return "%d:%02d" % [s / 60, s % 60]

## 撤离 / 飞船流程信息：顶部居中横幅 + 撤离进度
func _draw_flow(c: Control, vp: Vector2) -> void:
	if world == null:
		return
	var y := 56.0
	if NetHub.is_online():
		y = 72.0
		if NetHub.mode == NetHub.Mode.HOST and NetHub.lan_addresses().size() > 1:
			y = 88.0
	var upcoming: PackedStringArray = []
	if Tuning.enable_spaceship and not bool(world.get("spaceship_spawned")) and "raid_time" in world:
		var st: float = Tuning.spaceship_spawn_time - float(world.raid_time)
		if st > 0.0:
			upcoming.append("飞船 " + _mmss(st))
	if not upcoming.is_empty():
		c.draw_string(_font, Vector2(28, y), " ｜ ".join(upcoming) + " 后出现",
			HORIZONTAL_ALIGNMENT_LEFT, 520, 13, Color(0.78, 0.72, 0.55))
		y += 16.0
	if world != null and float(world.get("depot_flash_t")) > 0.0:
		var show := true
		if bool(world.get("depot_flash_near_only")):
			var fp = world.get("depot_flash_pos")
			show = player != null and fp is Vector2 and fp != Vector2.INF \
				and player.global_position.distance_to(fp) <= Tuning.depot_call_broadcast_m * 8.0
		if show:
			c.draw_string(_font, Vector2(0, y + 8), str(world.get("depot_flash")),
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 16, Color(0.95, 0.72, 1.0))
	# 撤离
	if Tuning.enable_extraction and not world.is_extracted():
		if world.extraction_in_zone():
			var prog: float = world.extraction_progress()
			var remain: float = Tuning.extraction_hold * (1.0 - prog)
			var bag_v := 0
			if inv != null:
				bag_v = inv.total_value()
			if player != null and player.get("stash") != null:
				bag_v += int(player.stash.total_value())
			var txt := "撤离中 ｜ %.0f%% 还需 %.1f 秒 ｜ 未提交将得 ¥%d" % [
				prog * 100.0, remain, bag_v]
			var bw := 620.0
			var br := Rect2(Vector2(vp.x * 0.5 - bw * 0.5, 96.0), Vector2(bw, 22.0))
			c.draw_rect(br, Color(0.06, 0.16, 0.10, 0.85), true)
			c.draw_rect(Rect2(br.position, Vector2(bw * prog, br.size.y)),
				Color(0.35, 0.95, 0.55), true)
			c.draw_rect(br, Color(0.45, 0.85, 0.55), false, 1.5)
			c.draw_string(_font, Vector2(0, 92), txt,
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 15, Color(0.75, 1.0, 0.80))
	elif world.is_extracted():
		c.draw_string(_font, Vector2(0, 60), "✅ 已撤离",
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 20, Color(0.55, 1.0, 0.65))
	# 飞船
	if Tuning.enable_spaceship:
		var st: int = world.spaceship_state()
		var ship_txt := ""
		if st == 0:   # CRUISE
			ship_txt = "⚠ 飞船悬浮巡航中（两侧传送门登舰）"
		elif st == 1: # HIJACK
			ship_txt = "⚠ 飞船驾驶中 · WASD 开往破解点"
		elif st == 2: # CRACKING
			var hold: float = Tuning.spaceship_crack_hold
			var ct := 0.0
			if world.spaceship != null:
				ct = float(world.spaceship.crack_t)
			ship_txt = "⚠ 飞船破解中 %.0f / %.0f 秒" % [ct, hold]
		elif st == 3: # OPENED
			ship_txt = "⚠ 密闭舱已开放 · 搜刮后自行撤离"
		if ship_txt != "":
			var col := Color(0.55, 0.85, 1.0)
			if st == 1:
				col = Color(1.0, 0.78, 0.38)
			elif st == 2:
				col = Color(0.5, 1.0, 0.6)
			elif st == 3:
				col = Color(0.55, 1.0, 0.78)
			c.draw_string(_font, Vector2(0, 124), ship_txt,
				HORIZONTAL_ALIGNMENT_CENTER, vp.x, 16, col)
	_draw_contract(c, vp)
	_draw_phone(c, vp)

func _draw_settle(c: Control, vp: Vector2) -> void:
	if player == null or not bool(player.get("raid_over")):
		return
	var r: Dictionary = player.settle_report
	if r.is_empty():
		return
	c.draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.62), true)
	var box := Rect2(Vector2(vp.x * 0.5 - 280.0, vp.y * 0.5 - 170.0), Vector2(560.0, 340.0))
	c.draw_rect(box, Color(0.07, 0.08, 0.10, 0.96), true)
	c.draw_rect(box, Color(0.78, 0.86, 0.55, 0.95), false, 2.0)
	var reason: String = str(r.get("reason", "extract"))
	var title := "撤离成功"
	if reason == "ship":
		title = "整船撤离成功"
	elif reason == "death":
		title = "阵亡结算"
	c.draw_string(_font, box.position + Vector2(24, 40), title,
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 22, Color(0.92, 0.96, 0.78))
	var secured: int = int(r.get("secured", 0))
	var bag: int = int(r.get("backpack", 0))
	var st: int = int(r.get("stash", 0))
	var bag_pay: int = int(r.get("backpack_payout", 0))
	var stash_pay: int = int(r.get("stash_payout", 0))
	var total: int = int(r.get("total", 0))
	c.draw_string(_font, box.position + Vector2(24, 84),
		"已提交（保险箱）          ¥%d" % secured,
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 16, Color(0.75, 0.90, 1.0))
	if reason == "death":
		c.draw_string(_font, box.position + Vector2(24, 114),
			"未提交背包（已掉落）      ¥%d" % bag,
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 16, Color(1.0, 0.55, 0.42))
		c.draw_string(_font, box.position + Vector2(24, 144),
			"寄存预览（已掉落）        ¥%d" % st,
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 16, Color(1.0, 0.55, 0.42))
	else:
		c.draw_string(_font, box.position + Vector2(24, 114),
			"背包物资                    ¥%d" % bag_pay,
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 16, Color(0.85, 0.95, 0.70))
		c.draw_string(_font, box.position + Vector2(24, 144),
			"寄存                        ¥%d" % stash_pay,
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 16, Color(0.85, 0.95, 0.70))
	c.draw_string(_font, box.position + Vector2(24, 188),
		"本局收益                    ¥%d" % total,
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 22, Color(1.0, 0.92, 0.45))
	c.draw_string(_font, box.position + Vector2(24, 250),
		"[F5] 重新开始本局",
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 16, Color(0.62, 0.70, 0.80))
	c.draw_string(_font, box.position + Vector2(24, 278),
		"提交点按倍率结算进保险箱；未提交的背包与寄存仍会在撤离时折现、死亡时掉落。",
		HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 48, 13, Color(0.50, 0.56, 0.64))

func _draw_phone(c: Control, vp: Vector2) -> void:
	if world == null or world.get("contracts") == null:
		return
	var con = world.contracts
	if con == null or not is_instance_valid(con) or not con.is_phone_ringing():
		return
	var pw := 560.0
	var ph := 188.0
	var box := Rect2(Vector2(vp.x * 0.5 - pw * 0.5, vp.y * 0.34), Vector2(pw, ph))
	c.draw_rect(box, Color(0.06, 0.07, 0.10, 0.94), true)
	c.draw_rect(box, Color(1.0, 0.78, 0.32, 0.95), false, 2.0)
	c.draw_string(_font, box.position + Vector2(16, 28), "来电 · 电话合约「抢回人质」",
		HORIZONTAL_ALIGNMENT_LEFT, pw - 32, 18, Color(1.0, 0.86, 0.42))
	c.draw_multiline_string(_font, box.position + Vector2(16, 48), con.phone_dialogue(),
		HORIZONTAL_ALIGNMENT_LEFT, pw - 32, 14, 3, Color(0.90, 0.93, 0.98))
	var left_t: float = maxf(0.0, float(con.phone_window_t))
	c.draw_string(_font, box.position + Vector2(16, 128),
		"长按 [E] 接受    ｜    %.0f 秒内未接将自动取消" % left_t,
		HORIZONTAL_ALIGNMENT_LEFT, pw - 32, 14, Color(0.75, 0.82, 0.92))
	var bar := Rect2(box.position + Vector2(16, 148), Vector2(pw - 32, 16))
	c.draw_rect(bar, Color(0.12, 0.13, 0.16, 0.95), true)
	var fill: float = con.phone_hold_progress()
	c.draw_rect(Rect2(bar.position, Vector2(bar.size.x * fill, bar.size.y)), Color(1.0, 0.72, 0.28), true)
	c.draw_rect(bar, Color(0.85, 0.70, 0.35), false, 1.0)

func _draw_contract(c: Control, vp: Vector2) -> void:
	if world == null or world.get("contracts") == null:
		return
	var con = world.contracts
	if con == null or not is_instance_valid(con):
		return
	var line: String = con.hud_banner() if con.has_method("hud_banner") else ""
	if line != "":
		c.draw_string(_font, Vector2(0, 116), line,
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 15, Color(1.0, 0.86, 0.42))
	var hold_t: float = 0.0
	if con.player_is_snatcher():
		hold_t = float(con.get("snatch_t"))
	elif con.player_is_owner() and (int(con.get("kind")) == 1 or int(con.get("kind")) == 2):
		hold_t = float(con.get("hold_t"))
		if not bool(con.get("exposing")) and hold_t <= 0.01:
			hold_t = 0.0
	elif con.player_is_owner() and con.extract_pos != Vector2.INF:
		hold_t = float(con.get("extract_t"))
	if hold_t > 0.0:
		var prog: float = con.extract_progress()
		var bw := 420.0
		var br := Rect2(Vector2(vp.x * 0.5 - bw * 0.5, 132.0), Vector2(bw, 16.0))
		var fill_col := Color(1.0, 0.62, 0.32) if con.player_is_snatcher() else Color(0.45, 0.92, 1.0)
		c.draw_rect(br, Color(0.06, 0.12, 0.16, 0.88), true)
		c.draw_rect(Rect2(br.position, Vector2(bw * prog, br.size.y)), fill_col, true)
		c.draw_rect(br, fill_col, false, 1.2)

## 弹药块：弹匣数大字 + 备弹小字 + 火力模式 + 换弹提示
func _draw_weapon_block(c: Control, vp: Vector2) -> void:
	if player == null or player.weapon == null or not Tuning.enable_shooting:
		return
	var w = player.weapon
	var right: float = vp.x - 34.0
	var base_y: float = vp.y - 44.0

	# 弹匣 / 备弹
	var mag_col := Color(0.95, 0.97, 1.0)
	if w.mag == 0:
		mag_col = Color(1.0, 0.35, 0.35)
	elif float(w.mag) / maxf(w.mag_size(), 1) <= 0.25:
		mag_col = Color(1.0, 0.68, 0.30)
	var mag_txt := str(w.mag)
	var mag_w := 90.0
	c.draw_string(_font, Vector2(right - 150.0, base_y), mag_txt,
		HORIZONTAL_ALIGNMENT_RIGHT, mag_w, 34, mag_col)
	var res_txt := "∞" if Tuning.infinite_ammo else str(w.reserve)
	c.draw_string(_font, Vector2(right - 56.0, base_y), "/ " + res_txt,
		HORIZONTAL_ALIGNMENT_LEFT, 90, 17, Color(0.62, 0.68, 0.80))

	# 枪名 + 火力模式
	var mode_label := "全自动" if w.fire_mode == "auto" else "单发"
	c.draw_string(_font, Vector2(right - 260.0, base_y - 30.0),
		"%s ｜ %s" % [w.display_name(), mode_label],
		HORIZONTAL_ALIGNMENT_RIGHT, 260, 14, Color(0.72, 0.79, 0.92))

	# 换弹进度条 / 空仓提示
	if w.reloading:
		var bw := 176.0
		var br := Rect2(Vector2(right - bw, base_y + 10.0), Vector2(bw, 7.0))
		c.draw_rect(br, Color(0.12, 0.13, 0.16), true)
		c.draw_rect(Rect2(br.position, Vector2(bw * w.reload_progress(), br.size.y)),
			Color(1.0, 0.76, 0.32), true)
		c.draw_string(_font, Vector2(right - 260.0, base_y + 32.0), "换弹中…",
			HORIZONTAL_ALIGNMENT_RIGHT, 260, 13, Color(1.0, 0.80, 0.42))
	elif w.mag == 0:
		c.draw_string(_font, Vector2(right - 260.0, base_y + 26.0), "[R] 换弹",
			HORIZONTAL_ALIGNMENT_RIGHT, 260, 15, Color(1.0, 0.42, 0.42))

	# 操作提示
	c.draw_string(_font, Vector2(right - 300.0, vp.y - 12.0),
		"左键 开火 ｜ 右键 瞄准 ｜ [R] 换弹 ｜ [V] 切换射击模式",
		HORIZONTAL_ALIGNMENT_RIGHT, 300, 11, Color(0.45, 0.50, 0.60))
