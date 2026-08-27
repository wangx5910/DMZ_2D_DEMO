extends CharacterBody2D
## Vehicle · 四轮载具（照 COD-DMZ 的载具逻辑做 2D 俯视版）
##
## 设计要点（与 DMZ 对齐）：
##  - **4 个座位**：1 驾驶 + 3 乘客。驾驶位空出来时，车就是块能被推倒的铁。
##  - **交互键上下车**：靠近按 E 上车（优先驾驶位），车内按 E 下车。
##  - **四轮转向模型**：不是全向平移，而是「油门 + 方向」——只有在动的时候才能转向，
##    这样撞墙、掉头、被堵路都成为真实的战术代价（DMZ 里开车逃跑经常卡在电线杆上）。
##  - **健康值 → 冒烟 → 起火 → 爆炸**：血量分档改变外观与行为，
##    爆炸对车内乘员与周围造成范围伤害。这让"开车硬闯"是有风险的选择。
##
## 联机：位置/朝向由驾驶者广播，上车/下车走房主 RPC。

signal seats_changed()
signal exploded(pos: Vector2)

const SEAT_COUNT := 4
const BODY_LEN := 58.0      ## 车长（像素 ≈ 7.2 米）
const BODY_WID := 30.0      ## 车宽

## seats[0] = 驾驶位，1–3 乘客位。元素为 Node（玩家）或 null
var seats: Array = [null, null, null, null]
var net_id: int = -1

var _net_pos := Vector2.ZERO
var _net_ang := 0.0
var _net_speed := 0.0
var _has_net := false

var health: Health = null
var vtype: String = "sedan"       ## sedan / pickup / van —— 只影响外观与少量数值
var tint := Color(0.42, 0.46, 0.55)

var speed: float = 0.0            ## 当前前进速度（可为负 = 倒车）
var heading: Vector2 = Vector2.RIGHT

var _fx = null
var _rng := RandomNumberGenerator.new()
var _smoke_t := 0.0
var _burn_t := 0.0
var _exploding := false
var _explode_timer := 0.0
var _shake := 0.0

# ── 初始化 ──────────────────────────────────────────────
func setup(pos: Vector2, fx, kind: String = "sedan") -> void:
	global_position = pos
	_fx = fx
	vtype = kind

func _ready() -> void:
	_rng.randomize()
	add_to_group("vehicles")
	add_to_group("interactables")
	collision_layer = 1 << 5          # vehicle 层
	# 和世界墙体碰撞。不与玩家/敌人碰撞层互推 —— 2D 俯视下车挤人会把人塞进墙里。
	collision_mask = 1 << 0
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	z_index = 6

	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(BODY_LEN, BODY_WID)
	shape.shape = rect
	add_child(shape)

	match vtype:
		"pickup":
			tint = Color(0.50, 0.40, 0.30)
		"van":
			tint = Color(0.36, 0.44, 0.42)
		_:
			tint = Color(0.40, 0.44, 0.54)

	health = Health.new(Tuning.vehicle_hp_max)
	health.died.connect(_on_wrecked)
	heading = Vector2.RIGHT.rotated(_rng.randf_range(0.0, TAU))
	rotation = heading.angle()

# ── 座位 ────────────────────────────────────────────────
func driver():
	return seats[0]

func occupant_count() -> int:
	var n := 0
	for s in seats:
		if s != null and is_instance_valid(s):
			n += 1
	return n

func free_seat() -> int:
	# 驾驶位优先 —— 玩家上车的第一意图几乎总是开车
	for i in SEAT_COUNT:
		if seats[i] == null or not is_instance_valid(seats[i]):
			return i
	return -1

func has_room() -> bool:
	return free_seat() >= 0

## 给人质占乘客座（优先 1–3，避免人质当司机）
func board_passenger(who) -> int:
	if is_wrecked():
		return -1
	for i in range(1, SEAT_COUNT):
		if seats[i] == null or not is_instance_valid(seats[i]):
			seats[i] = who
			seats_changed.emit()
			return i
	if seats[0] == null or not is_instance_valid(seats[0]):
		seats[0] = who
		seats_changed.emit()
		return 0
	return -1

## 玩家上车。返回座位号，失败返回 -1
func board(who) -> int:
	if is_wrecked():
		return -1
	var idx := free_seat()
	if idx < 0:
		return -1
	seats[idx] = who
	seats_changed.emit()
	RaidLog.log_event("vehicle_board", {"vehicle": name, "seat": idx, "type": vtype})
	return idx

func occupy_seat(who, idx: int) -> void:
	if who == null or idx < 0 or idx >= SEAT_COUNT:
		return
	for i in SEAT_COUNT:
		if seats[i] == who:
			seats[i] = null
	seats[idx] = who
	seats_changed.emit()

## 玩家下车。返回下车落点（车侧方，避免卡在车体里）
func disembark(who) -> Vector2:
	var idx := -1
	for i in SEAT_COUNT:
		if seats[i] == who:
			idx = i
			break
	if idx >= 0:
		seats[idx] = null
		seats_changed.emit()
		RaidLog.log_event("vehicle_exit", {"vehicle": name, "seat": idx})
	return exit_point(idx)

## 下车落点：车身侧方一段距离，且不能在墙里
func exit_point(seat_idx: int) -> Vector2:
	var side: float = 1.0 if seat_idx % 2 == 0 else -1.0
	var base := heading.rotated(PI * 0.5) * (BODY_WID * 0.5 + 22.0) * side
	var space := get_world_2d().direct_space_state
	for cand in [base, -base, heading * (BODY_LEN * 0.6 + 20.0), -heading * (BODY_LEN * 0.6 + 20.0)]:
		var target: Vector2 = global_position + cand
		var q := PhysicsPointQueryParameters2D.new()
		q.position = target
		q.collision_mask = 1 << 0
		if space.intersect_point(q, 1).is_empty():
			return target
	return global_position

# ── 驾驶 ────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if _exploding:
		_tick_explode(delta)
		return

	var d = driver()
	var d_pid := 0
	if d != null and is_instance_valid(d) and d.get("peer_id") != null:
		d_pid = int(d.get("peer_id"))
	var local_drive: bool = d_pid > 0 and not d.is_dead() and not is_wrecked() \
		and NetHub.is_local(d_pid)
	var remote_drive: bool = d_pid > 0 and not NetHub.is_local(d_pid)

	if local_drive:
		_drive(delta, d)
		velocity = heading * speed
		move_and_slide()
	elif remote_drive or (NetHub.is_online() and _has_net and not local_drive):
		_apply_net_motion(delta)
	else:
		speed = move_toward(speed, 0.0, Tuning.vehicle_brake * delta)
		velocity = heading * speed
		move_and_slide()

	# 撞墙掉血（DMZ 里高速撞墙也会冒烟）
	if local_drive and get_slide_collision_count() > 0 and absf(speed) > Tuning.vehicle_crash_min_speed:
		var impact: float = absf(speed) / Tuning.vehicle_max_speed
		_apply_damage(Tuning.vehicle_crash_damage * impact, global_position)
		speed *= -0.18                     # 撞墙反弹一点，避免贴墙持续刮擦
		_shake = 0.35
		if _fx != null:
			_fx.add_spark(global_position + heading * BODY_LEN * 0.5, Vector2.ZERO)

	_sync_passengers()
	_tick_damage_fx(delta)
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta)
	queue_redraw()

func _drive(delta: float, d) -> void:
	# 四轮模型：W/S = 油门/刹车倒车，A/D = 方向（**只有在动时才能转**）
	var throttle := 0.0
	if Input.is_action_pressed("move_up"):
		throttle += 1.0
	if Input.is_action_pressed("move_down"):
		throttle -= 1.0
	var steer := 0.0
	if Input.is_action_pressed("move_right"):
		steer += 1.0
	if Input.is_action_pressed("move_left"):
		steer -= 1.0

	# 损坏会削弱动力：残血的车跑不快（DMZ 同款手感，逼你考虑换车）
	var power_mul: float = lerpf(Tuning.vehicle_wreck_power_mul, 1.0, health.ratio())
	var max_fwd: float = Tuning.vehicle_max_speed * power_mul
	var max_rev: float = -Tuning.vehicle_reverse_speed * power_mul

	if throttle > 0.0:
		speed = move_toward(speed, max_fwd, Tuning.vehicle_accel * delta)
	elif throttle < 0.0:
		# 前进中按 S = 刹车（比倒车加速快得多），停住后才开始倒车
		if speed > 5.0:
			speed = move_toward(speed, 0.0, Tuning.vehicle_brake * delta)
		else:
			speed = move_toward(speed, max_rev, Tuning.vehicle_accel * 0.6 * delta)
	else:
		speed = move_toward(speed, 0.0, Tuning.vehicle_coast * delta)

	# 转向速率与车速挂钩：静止不能转（真车如此），高速转向也变钝（避免原地打转）
	if absf(speed) > 4.0:
		var sp_ratio: float = clampf(absf(speed) / Tuning.vehicle_max_speed, 0.0, 1.0)
		var turn_mul: float = lerpf(1.0, Tuning.vehicle_highspeed_turn_mul, sp_ratio)
		var dir_sign: float = 1.0 if speed > 0.0 else -1.0
		heading = heading.rotated(
			deg_to_rad(Tuning.vehicle_turn_rate * steer * turn_mul * dir_sign) * delta).normalized()
		rotation = heading.angle()

func apply_net_state(pos: Vector2, ang: float, spd: float, hp: float,
		exploding: bool, fuse: float, seat_ids: Array) -> void:
	var d = driver()
	if d != null and is_instance_valid(d) and d.get("peer_id") != null \
			and NetHub.is_local(int(d.get("peer_id"))):
		return
	_net_pos = pos
	_net_ang = ang
	_net_speed = spd
	_has_net = true
	speed = spd
	if health != null:
		health.hp = hp
		health.dead = exploding and hp <= 0.01
	if exploding and not _exploding:
		_exploding = true
		_explode_timer = fuse
	_apply_seat_ids(seat_ids)

func _apply_net_motion(delta: float) -> void:
	if not _has_net:
		speed = move_toward(speed, 0.0, Tuning.vehicle_brake * delta)
		velocity = heading * speed
		move_and_slide()
		return
	global_position = global_position.lerp(_net_pos, clampf(16.0 * delta, 0.0, 1.0))
	heading = Vector2.RIGHT.rotated(_net_ang)
	rotation = heading.angle()
	speed = _net_speed
	velocity = Vector2.ZERO

func _apply_seat_ids(ids: Array) -> void:
	for i in mini(SEAT_COUNT, ids.size()):
		var pid: int = int(ids[i])
		var p = NetHub.get_player(pid) if pid > 0 else null
		if p != null and is_instance_valid(p):
			seats[i] = p
			p.vehicle = self
			p.vehicle_seat = i
		elif seats[i] != null and is_instance_valid(seats[i]) and seats[i].is_in_group("human_players"):
			var who = seats[i]
			seats[i] = null
			if who.vehicle == self:
				who.vehicle = null
				who.vehicle_seat = -1

## 乘员跟随车体（保持座位相对位置，方便俯视读数"车里有几个人"）
func _sync_passengers() -> void:
	for i in SEAT_COUNT:
		var p = seats[i]
		if p == null or not is_instance_valid(p):
			continue
		p.global_position = global_position + seat_offset(i).rotated(heading.angle())

func seat_offset(i: int) -> Vector2:
	# 0 左前(驾驶) 1 右前 2 左后 3 右后
	var fx: float = BODY_LEN * 0.20 if i < 2 else -BODY_LEN * 0.20
	var fy: float = -BODY_WID * 0.22 if i % 2 == 0 else BODY_WID * 0.22
	return Vector2(fx, fy)

# ── 受损与爆炸 ──────────────────────────────────────────
func take_damage(amount: float, from: Vector2) -> void:
	_apply_damage(amount, from)

func _apply_damage(amount: float, from: Vector2) -> void:
	if health == null or is_wrecked():
		return
	health.apply_damage(amount, from)
	# 车体受击不会直接伤到乘员（钣金挡枪），但穿透会 —— 本版简化为不穿透。
	# 代价体现在：车更容易被打爆，而爆炸会把车里所有人带走。

func is_wrecked() -> bool:
	return health != null and health.dead

## 血量归零 = 起火进入爆炸倒计时（不是立刻炸），给乘员一个跳车逃命的窗口。
## 这是 DMZ 载具最有戏的瞬间：车着火了，跳还是再开两秒冲出去。
func _on_wrecked(_from) -> void:
	if _exploding:
		return
	_exploding = true
	_explode_timer = Tuning.vehicle_fuse_time
	speed *= 0.4
	RaidLog.log_event("vehicle_wrecked", {
		"vehicle": name, "occupants": occupant_count(), "fuse": Tuning.vehicle_fuse_time})

func _tick_explode(delta: float) -> void:
	_explode_timer -= delta
	# 起火后还会滑行一段（惯性），并持续喷火
	speed = move_toward(speed, 0.0, Tuning.vehicle_brake * 0.5 * delta)
	velocity = heading * speed
	move_and_slide()
	_sync_passengers()
	_burn_t += delta
	if _fx != null and _burn_t > 0.06:
		_burn_t = 0.0
		_fx.add_spark(global_position + Vector2(
			_rng.randf_range(-BODY_LEN * 0.4, BODY_LEN * 0.4),
			_rng.randf_range(-BODY_WID * 0.4, BODY_WID * 0.4)), Vector2.ZERO)
	queue_redraw()
	if _explode_timer <= 0.0:
		_do_explode()

func _do_explode() -> void:
	var pos := global_position
	# 范围伤害：先把乘员踢出车再结算，否则他们会跟着车节点一起被删
	for i in SEAT_COUNT:
		var p = seats[i]
		seats[i] = null
		if p != null and is_instance_valid(p):
			p.global_position = pos + Vector2.RIGHT.rotated(_rng.randf_range(0, TAU)) * 40.0
			if p.has_method("leave_vehicle_forced"):
				p.leave_vehicle_forced()
	for body in _nearby_damageables(pos, Tuning.vehicle_explosion_radius):
		var d: float = pos.distance_to(body.global_position)
		var falloff: float = clampf(1.0 - d / Tuning.vehicle_explosion_radius, 0.0, 1.0)
		if body.has_method("take_damage"):
			body.take_damage(Tuning.vehicle_explosion_damage * falloff, pos)
	if _fx != null:
		for k in 26:
			var ang: float = TAU * float(k) / 26.0
			_fx.add_tracer(pos, pos + Vector2.RIGHT.rotated(ang)
				* _rng.randf_range(50.0, Tuning.vehicle_explosion_radius), 1400.0)
			_fx.add_spark(pos + Vector2.RIGHT.rotated(ang) * _rng.randf_range(20.0, 90.0), Vector2.ZERO)
	# 爆炸声会吸引附近所有小兵 —— 炸车等于大声宣告自己的位置
	for e in get_tree().get_nodes_in_group("enemies"):
		if e.has_method("hear_gunshot"):
			e.hear_gunshot(pos)
	RaidLog.bump("vehicles_destroyed")
	RaidLog.log_event("vehicle_explode", {"vehicle": name, "pos": [int(pos.x), int(pos.y)]})
	exploded.emit(pos)
	# 留一个焦黑残骸标记（"这里炸过车"是情报）
	var wreck := Node2D.new()
	wreck.set_script(load("res://scripts/world/vehicle_wreck.gd"))
	wreck.global_position = pos
	wreck.rotation = rotation
	get_parent().add_child(wreck)
	queue_free()

func _nearby_damageables(pos: Vector2, radius: float) -> Array:
	var out: Array = []
	for g in ["enemies", "player"]:
		for n in get_tree().get_nodes_in_group(g):
			if is_instance_valid(n) and pos.distance_to(n.global_position) <= radius:
				out.append(n)
	return out

## 受损表现：半血冒烟、三成血起火前兆
func _tick_damage_fx(delta: float) -> void:
	if _fx == null:
		return
	var r: float = health.ratio()
	if r > Tuning.vehicle_smoke_threshold:
		return
	_smoke_t += delta
	var interval: float = lerpf(0.10, 0.45, r / maxf(Tuning.vehicle_smoke_threshold, 0.01))
	if _smoke_t >= interval:
		_smoke_t = 0.0
		_fx.add_spark(global_position - heading * BODY_LEN * 0.35, Vector2.ZERO)

# ── 供视野遮蔽调用（载具是大件，属于地形记忆的一部分，始终可见）──
func set_perceived(_v: bool) -> void:
	visible = true

# ── 绘制 ────────────────────────────────────────────────
func _draw() -> void:
	var jitter := Vector2.ZERO
	if _shake > 0.0:
		jitter = Vector2(_rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0)) * (_shake / 0.35)

	var r: float = health.ratio() if health != null else 1.0
	var body_col: Color = tint.lerp(Color(0.20, 0.16, 0.14), 1.0 - r)
	if _exploding:
		# 起火：车体随倒计时闪红，越接近爆炸闪得越急
		var pulse: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.02
			* (1.0 + (Tuning.vehicle_fuse_time - _explode_timer)))
		body_col = Color(0.55 + 0.35 * pulse, 0.22, 0.14)

	var half := Vector2(BODY_LEN, BODY_WID) * 0.5
	var rect := Rect2(-half + jitter, Vector2(BODY_LEN, BODY_WID))
	draw_rect(rect, body_col, true)
	draw_rect(rect, body_col.lightened(0.35), false, 2.0)

	# 车头方向标记（俯视图里必须一眼看出车头朝哪）
	var nose := Vector2(BODY_LEN * 0.5, 0) + jitter
	draw_colored_polygon(PackedVector2Array([
		nose, nose + Vector2(-10, -7), nose + Vector2(-10, 7)]),
		body_col.lightened(0.55))
	# 车窗（深色块，占用中段）
	draw_rect(Rect2(Vector2(-BODY_LEN * 0.12, -BODY_WID * 0.32) + jitter,
		Vector2(BODY_LEN * 0.34, BODY_WID * 0.64)), Color(0.12, 0.14, 0.18, 0.9), true)
	# 四个轮子
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			draw_rect(Rect2(Vector2(sx * BODY_LEN * 0.30 - 5.0,
				sy * BODY_WID * 0.46 - 3.5) + jitter, Vector2(10, 7)),
				Color(0.10, 0.10, 0.12), true)

	# 乘员数标记：每个已占座位画一个亮点，远处也能读出"这车有人"
	for i in SEAT_COUNT:
		if seats[i] != null and is_instance_valid(seats[i]):
			draw_circle(seat_offset(i) + jitter, 3.4, Color(0.95, 0.88, 0.55))

	# 血条：只在受损后显示，避免满血时满地都是条
	if r < 0.999:
		var w := BODY_LEN
		var bar := Rect2(Vector2(-w * 0.5, -BODY_WID * 0.5 - 10.0), Vector2(w, 4.0))
		draw_rect(bar, Color(0.10, 0.08, 0.08, 0.85), true)
		var hc := Color(0.45, 0.85, 0.45)
		if r < 0.3:
			hc = Color(0.92, 0.28, 0.24)
		elif r < 0.6:
			hc = Color(0.92, 0.68, 0.28)
		draw_rect(Rect2(bar.position, Vector2(w * r, 4.0)), hc, true)
