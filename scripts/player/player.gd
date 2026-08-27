extends CharacterBody2D
## Player · 角色 3C
##
## 参考《逃离鸭科夫》的移动与搜刮手感，改为纯 2D 俯视：
## - WASD 世界坐标位移（不是坦克式转向）
## - 鼠标决定朝向 → 朝向决定扇形视野方向（信息博弈的核心）
## - 走 / 跑 / 蹲 三档，带加速度与刹车惯性
## - 冲刺有体力约束 + 转向惩罚 + 视野收窄（管道视觉）
## - 搜刮中移动会打断（可在调试面板关掉对比）
##
## 联机预留：所有状态变更都走 NetHub.is_authority() 判定，
## 位置/朝向/姿态三个字段即为将来需同步的最小集合（见 TODO_NET）。

signal stance_changed(stance: Stance)
signal stamina_changed(cur: float, maxv: float)
signal interact_target_changed(target: Node)
signal search_progress(cur: float, total: float, slot_index: int, total_slots: int)
signal search_state_changed(active: bool, container: Node)
signal weapon_state_changed()
signal health_changed(hp: float, hp_max: float)
signal player_died()
signal vehicle_changed(veh, seat: int)

enum Stance { WALK, SPRINT, CROUCH }

@export var peer_id: int = 1

## 小队 ID：同队友善；人类玩家之间也不互伤。出生槽决定异队异点。
var team_id: int = 0
var spawn_squad_id: int = 0
var net_tag: String = ""
var _net_pos := Vector2.ZERO
var _net_aim := Vector2.RIGHT
var _net_ready := false
var _last_shot_time: float = -999.0

## 面板打开时挂起鼠标转向与开火——否则在 UI 上拖拽物品会把视野甩得到处跑、还会走火
var ui_capturing_mouse: bool = false

var stance: Stance = Stance.WALK
var aim_dir: Vector2 = Vector2.RIGHT      ## TODO_NET: 需同步
var stamina: float = 100.0
var _regen_cooldown: float = 0.0
var _sprint_blocked: bool = false          ## 体力耗尽后需回到阈值以上才能再跑

## 枪械（本版只有 M4）。TODO_NET: mag / reserve / fire_mode 需同步
var weapon: Weapon = null
var health: Health = null
var aiming: bool = false
var _recoil_kick: float = 0.0              ## 后坐视觉抖动（衰减到 0）
var _fx = null                             ## CombatFX 节点，由 main 注入
var inv = null                             ## 背包（GridInventory），由 main 注入
var stash = null                           ## 网络存储箱 / 寄存预览（开局 8×5，新提交点波次再加一块）

## 搜刮状态
## 注意：容器引用一律用无类型变量。GDScript 对强类型 Node 访问脚本自定义
## 属性/方法是**编译期错误**，而容器的 richness / slots 等都是运行时脚本属性。
var searching_container = null
var _search_slot: int = 0
var _search_elapsed: float = 0.0
var _cracking: bool = false                ## L4 破解前置阶段

var _interact_target = null
## 载具状态：在车上时玩家自身不跑移动逻辑（位置由车同步）
var vehicle = null
var vehicle_seat: int = -1
var _last_pos: Vector2
var _rng := RandomNumberGenerator.new()

## 飞船登舰状态
var aboard_ship = null
var _portal_channel_t: float = 0.0
var _portal_channel_label: String = ""
var _z_before_ship: int = 10
var carried_hostage = null

## 本局结算：提交点折现进保险箱；背包与未提交寄存撤离时按倍率折现，死亡掉落
var secured_value: int = 0
var raid_over: bool = false
var settle_report: Dictionary = {}
signal raid_settled(report: Dictionary)

const SHIP_WALL_LAYER := 1 << 6   ## 与飞船内墙碰撞，不与地面 POI 墙碰撞
const HitscanScript := preload("res://scripts/combat/hitscan.gd")

func _ready() -> void:
	add_to_group("player")
	add_to_group("human_players")
	stamina = Tuning.stamina_max
	_last_pos = global_position
	_rng.randomize()
	health = Health.new(Tuning.player_hp_max)
	health.damaged.connect(func(amt, from, left):
		health_changed.emit(left, health.hp_max)
		RaidLog.bump("damage_taken", amt)
		RaidLog.log_event("player_hit", {"dmg": snappedf(amt, 0.1), "hp": snappedf(left, 0.1)}))
	health.died.connect(func(_from):
		RaidLog.log_event("player_died", {"t": snappedf(RaidLog.t(), 0.1)})
		if carried_hostage != null:
			drop_hostage()
		if NetHub.is_local(peer_id):
			_close_raid_uis()
			settle_death()
			player_died.emit()
		queue_redraw())
	stamina_changed.emit(stamina, Tuning.stamina_max)
	health_changed.emit(health.hp, health.hp_max)
	_setup_weapon()

## 受击（由怪物 / 本地命中调用）
func take_damage(amount: float, from: Vector2) -> void:
	if raid_over or aboard_ship != null:
		return
	if not NetHub.is_local(peer_id):
		if NetHub.is_online():
			NetHub.report_player_hit(peer_id, amount, from)
		return
	if Tuning.god_mode or health == null or health.dead:
		return
	health.apply_damage(amount, from)

## 房主结算后的本机扣血（不再回传，避免循环）
func take_net_damage(amount: float, from: Vector2) -> void:
	if raid_over or health == null or health.dead:
		return
	if Tuning.god_mode:
		return
	health.apply_damage(amount, from)

func apply_net_state(pos: Vector2, aim: Vector2, st: int, hp: float, dead: bool) -> void:
	if vehicle == null or not is_instance_valid(vehicle):
		_net_pos = pos
	if aim.length_squared() > 0.01:
		_net_aim = aim.normalized()
	_net_ready = true
	stance = st as Stance
	if health == null:
		return
	if dead:
		health.hp = 0.0
		health.dead = true
	else:
		health.hp = clampf(hp, 0.0, health.hp_max)
		health.dead = false

func _apply_remote_motion(delta: float) -> void:
	if not _net_ready:
		return
	if vehicle != null and is_instance_valid(vehicle):
		if aim_dir.length_squared() > 0.01:
			aim_dir = aim_dir.slerp(_net_aim, clampf(16.0 * delta, 0.0, 1.0)).normalized()
			rotation = aim_dir.angle()
		return
	global_position = global_position.lerp(_net_pos, clampf(14.0 * delta, 0.0, 1.0))
	aim_dir = aim_dir.slerp(_net_aim, clampf(16.0 * delta, 0.0, 1.0)).normalized()
	rotation = aim_dir.angle()
	velocity = Vector2.ZERO

func is_dead() -> bool:
	return health != null and health.dead

func set_fx(fx) -> void:
	_fx = fx

func _setup_weapon() -> void:
	weapon = Weapon.new("m4")
	weapon.ammo_changed.connect(func(_m, _r): weapon_state_changed.emit())
	weapon.reload_started.connect(func(d):
		RaidLog.log_event("reload_start", {"duration": snappedf(d, 0.01), "mag": weapon.mag})
		weapon_state_changed.emit())
	weapon.reload_finished.connect(func():
		RaidLog.bump("reloads")
		RaidLog.log_event("reload_done", {"mag": weapon.mag, "reserve": weapon.reserve})
		weapon_state_changed.emit())
	weapon.fire_mode_changed.connect(func(m):
		RaidLog.log_event("fire_mode", {"mode": m})
		weapon_state_changed.emit())
	weapon.dry_fire.connect(func(): RaidLog.log_event("dry_fire"))

func _physics_process(delta: float) -> void:
	if not NetHub.is_local(peer_id):
		_apply_remote_motion(delta)
		return
	if is_dead() or raid_over:
		velocity = velocity.move_toward(Vector2.ZERO, Tuning.decel * delta)
		move_and_slide()
		return

	# 在车上：位置由载具同步，不跑自身移动；仍可转向观察与开枪
	if vehicle != null:
		if not is_instance_valid(vehicle):
			vehicle = null
			vehicle_seat = -1
		else:
			velocity = Vector2.ZERO
			_update_aim()
			_update_weapon(delta)
			_track_metrics(delta)
			_tick_ooc_regen(delta)
			return

	# 驾驶飞船：位置由船体同步，WASD 交给飞船位移
	if aboard_ship != null and aboard_ship.has_method("is_pilot") and aboard_ship.is_pilot(self):
		velocity = Vector2.ZERO
		_update_aim()
		_update_weapon(delta)
		_track_metrics(delta)
		return

	_update_aim()
	_update_stance()
	_move(delta)
	_update_stamina(delta)
	_update_weapon(delta)
	_scan_interactable()
	_tick_search(delta)
	_tick_ooc_regen(delta)
	_track_metrics(delta)

# ── 朝向 ────────────────────────────────────────────────
func _update_aim() -> void:
	if ui_capturing_mouse or _cracking:
		return
	if searching_container != null and Tuning.search_lock_rotation:
		return
	var to_mouse := get_global_mouse_position() - global_position
	if to_mouse.length_squared() > 4.0:
		var target := to_mouse.normalized()
		# 冲刺时转向变钝：制造"跑起来后视野难以快速扫描"的代价
		var turn_rate := 1.0
		if stance == Stance.SPRINT:
			turn_rate = Tuning.sprint_turn_penalty
		if turn_rate >= 1.0:
			aim_dir = target
		else:
			var max_rad := TAU * turn_rate * get_physics_process_delta_time() * 4.0
			aim_dir = aim_dir.rotated(clampf(aim_dir.angle_to(target), -max_rad, max_rad)).normalized()
	rotation = aim_dir.angle()

# ── 姿态 ────────────────────────────────────────────────
func _update_stance() -> void:
	var prev := stance
	var wants_sprint := Input.is_action_pressed("sprint")
	var wants_crouch := Input.is_action_pressed("crouch")
	var moving := _input_dir().length_squared() > 0.01

	if wants_crouch:
		stance = Stance.CROUCH
	elif wants_sprint and moving and _can_sprint():
		stance = Stance.SPRINT
	else:
		stance = Stance.WALK

	if stance != prev:
		stance_changed.emit(stance)
		RaidLog.log_event("stance", {"stance": Stance.keys()[stance]})

func _can_sprint() -> bool:
	if carried_hostage != null:
		return false
	if not Tuning.enable_stamina:
		return true
	if _sprint_blocked:
		return false
	return stamina > 0.5

func _input_dir() -> Vector2:
	return Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	).limit_length(1.0)

# ── 位移 ────────────────────────────────────────────────
func _move(delta: float) -> void:
	var dir := _input_dir()
	var target_speed := _current_speed()

	# 搜刮中的移动处理
	if searching_container != null:
		if dir.length_squared() > 0.01 and Tuning.search_break_on_move:
			abort_search("moved")
		else:
			target_speed *= Tuning.search_move_speed_mul

	var desired := dir * target_speed
	var rate := Tuning.accel if desired.length_squared() > velocity.length_squared() else Tuning.decel
	velocity = velocity.move_toward(desired, rate * delta)
	move_and_slide()

func _current_speed() -> float:
	var s := Tuning.walk_speed
	match stance:
		Stance.SPRINT: s = Tuning.sprint_speed
		Stance.CROUCH: s = Tuning.crouch_speed
	# ADS（瞄准）减速：瞄准就走不快，是"精度换机动"的代价
	if weapon != null:
		s *= weapon.move_speed_mul()
	if carried_hostage != null:
		s *= Tuning.carry_hostage_speed_mul
	return s

# ── 枪械 ────────────────────────────────────────────────
func _update_weapon(delta: float) -> void:
	if weapon == null:
		return

	# 无限备弹（调试开关）：每帧补满 reserve，换弹逻辑本身不变
	if Tuning.infinite_ammo:
		if weapon.reserve < weapon.reserve_max():
			weapon.reserve = weapon.reserve_max()

	# UI 打开 / 搜刮中 / 冲刺中 不能瞄准或开火
	var blocked: bool = ui_capturing_mouse or searching_container != null
	aiming = (not blocked) and Input.is_action_pressed("aim") and stance != Stance.SPRINT
	weapon.tick(delta, aiming, int(stance))

	# 后坐视觉抖动衰减
	if _recoil_kick > 0.0:
		_recoil_kick = maxf(0.0, _recoil_kick - delta * 14.0)

	if blocked or not Tuning.enable_shooting:
		weapon.try_fire(false, global_position, aim_dir, int(stance), Tuning.infinite_ammo)
		return

	# 冲刺中不能开火（照鸭科夫：要停下或至少走起来才能打）
	var trigger: bool = Input.is_action_pressed("fire") and stance != Stance.SPRINT
	var muzzle: Vector2 = global_position + aim_dir * 16.0
	if weapon.try_fire(trigger, muzzle, aim_dir, int(stance), Tuning.infinite_ammo):
		_last_shot_time = Time.get_ticks_msec() / 1000.0
		_do_shot(muzzle)

	# 空仓自动换弹
	if Tuning.auto_reload_on_empty and weapon.mag <= 0 and not weapon.reloading:
		weapon.start_reload(Tuning.infinite_ammo)

## 打出一发：剪影命中 + 墙遮挡 → 曳光弹 → 命中火花
func _do_shot(muzzle: Vector2) -> void:
	var spread: float = weapon.effective_spread(int(stance))
	var pellets: int = maxi(1, int(weapon.def.get("pellets", 1)))

	for i in pellets:
		var dir: Vector2 = weapon.roll_direction(aim_dir, spread, _rng)
		var hit: Dictionary = HitscanScript.query(get_world_2d(), global_position, dir, weapon.range_px(), self)
		var end: Vector2 = hit["position"]
		var who = hit.get("collider")
		if who != null and who.has_method("take_damage"):
			var hit_ok := false
			if who.is_in_group("enemies") or who.is_in_group("vehicles"):
				hit_ok = true
			elif who.is_in_group("raider_bots") or who.is_in_group("player") \
					or who.is_in_group("human_players"):
				hit_ok = not NetHub.are_allied(self, who)
			elif who.is_in_group("hostages"):
				hit_ok = true
			if hit_ok:
				var dmg: float = weapon.damage_at(global_position.distance_to(end))
				who.take_damage(dmg, global_position)
				RaidLog.bump("shots_hit")
				if _fx != null:
					_fx.add_spark(end, Vector2.ZERO)
			elif _fx != null:
				_fx.add_spark(end, hit.get("normal", Vector2.ZERO))
		elif bool(hit.get("blocked", false)) and _fx != null:
			_fx.add_spark(end, hit.get("normal", Vector2.ZERO))
		if _fx != null:
			_fx.add_tracer(muzzle, end, weapon.bullet_speed())
		if NetHub.is_online():
			NetHub.send_shot(muzzle, end, weapon.bullet_speed())

	if _fx != null:
		_fx.add_muzzle(muzzle, aim_dir)

	_recoil_kick = weapon.def.get("recoil_kick", 2.2)
	# 枪声吸引附近的怪（照鸭科夫：开枪就是暴露）
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		if global_position.distance_squared_to(e.global_position) > Tuning.enemy_hearing_range * Tuning.enemy_hearing_range:
			continue
		if e.has_method("hear_gunshot"):
			e.hear_gunshot(global_position)
	RaidLog.bump("shots_fired")
	RaidLog.log_event("shot", {
		"mag": weapon.mag, "reserve": weapon.reserve,
		"spread": snappedf(spread, 0.01), "stance": Stance.keys()[stance],
		"ads": snappedf(weapon.ads, 0.01),
	})

func recoil_offset() -> float:
	return _recoil_kick

# ── 体力 ────────────────────────────────────────────────
func _update_stamina(delta: float) -> void:
	if not Tuning.enable_stamina:
		if stamina < Tuning.stamina_max:
			stamina = Tuning.stamina_max
			stamina_changed.emit(stamina, Tuning.stamina_max)
		return

	var before := stamina
	if stance == Stance.SPRINT and velocity.length() > 10.0:
		stamina = maxf(0.0, stamina - Tuning.stamina_drain_sprint * delta)
		_regen_cooldown = Tuning.stamina_regen_delay
		if stamina <= 0.0 and not _sprint_blocked:
			_sprint_blocked = true
			RaidLog.log_event("stamina_depleted")
	else:
		if _regen_cooldown > 0.0:
			_regen_cooldown -= delta
		else:
			stamina = minf(Tuning.stamina_max, stamina + Tuning.stamina_regen * delta)
	# 恢复到阈值以上才解除禁跑，避免"点跑抽搐"
	if _sprint_blocked and stamina >= Tuning.stamina_sprint_threshold:
		_sprint_blocked = false

	if not is_equal_approx(before, stamina):
		stamina_changed.emit(stamina, Tuning.stamina_max)

# ── 交互探测 ────────────────────────────────────────────
func _scan_interactable() -> void:
	var best = null
	var best_d := Tuning.interact_range * Tuning.interact_range
	for c in get_tree().get_nodes_in_group("containers"):
		if aboard_ship != null and not aboard_ship.is_ancestor_of(c):
			continue
		var d := global_position.distance_squared_to(c.global_position)
		if d <= best_d:
			best_d = d
			best = c
	for b in get_tree().get_nodes_in_group("contract_boards"):
		if not is_instance_valid(b) or bool(b.get("consumed")):
			continue
		var d2 := global_position.distance_squared_to(b.global_position)
		if d2 <= best_d:
			best_d = d2
			best = b
	for d in get_tree().get_nodes_in_group("depots"):
		if not is_instance_valid(d):
			continue
		if bool(d.get("consumed")):
			continue
		var d3 := global_position.distance_squared_to(d.global_position)
		if d3 <= best_d:
			best_d = d3
			best = d
	if best != _interact_target:
		_interact_target = best
		interact_target_changed.emit(best)

func _unhandled_input(event: InputEvent) -> void:
	if not NetHub.is_local(peer_id):
		return
	if raid_over or is_dead():
		return
	# ── 枪械操作 ──
	if event.is_action_pressed("reload"):
		if weapon != null and not ui_capturing_mouse:
			if searching_container != null:
				abort_search("reload")
			if not weapon.start_reload(Tuning.infinite_ammo):
				if weapon.mag >= weapon.mag_size():
					RaidLog.log_event("reload_rejected", {"reason": "mag_full"})
				elif weapon.reserve <= 0:
					RaidLog.log_event("reload_rejected", {"reason": "no_reserve"})
		return
	if event.is_action_pressed("fire_mode"):
		if weapon != null and not ui_capturing_mouse:
			weapon.cycle_fire_mode()
		return

	if event.is_action_pressed("interact"):
		if _is_phone_ringing():
			get_viewport().set_input_as_handled()
			return
		if aboard_ship != null:
			if searching_container != null:
				abort_search("cancelled")
			elif aboard_ship.has_method("is_pilot") and aboard_ship.is_pilot(self):
				aboard_ship.leave_pilot(self)
			elif aboard_ship.has_method("try_hijack") and aboard_ship.is_in_control_room(self) \
					and aboard_ship.try_hijack(self):
				pass
			elif _interact_target != null:
				_begin_search(_interact_target)
			return
		if vehicle != null:
			if NetHub.is_online() and vehicle.get("net_id") != null:
				NetHub.request_vehicle_exit(int(vehicle.net_id))
			else:
				_exit_vehicle()
			return
		var veh = _nearest_boardable_vehicle()
		if veh != null:
			_enter_vehicle(veh)
			return
		if _interact_target != null and _interact_target.has_method("try_interact"):
			_interact_target.try_interact(self)
			return
		# **自动连搜**（大锤要求）：按一次 E 就自动逐格读条搜到底，不用按住。
		# 搜刮中再按 E = 主动停止（已搜出的格子保留，"搜一半就撤"仍然成立）。
		if searching_container != null:
			abort_search("cancelled")
		elif _interact_target != null:
			_begin_search(_interact_target)
		return
	if event.is_action_pressed("carry_hostage"):
		_toggle_carry_hostage()
	# 注意：不再监听 action_released —— 松手不再中断搜刮

# ── 载具 ────────────────────────────────────────────────
func _nearest_boardable_vehicle():
	var best = null
	var best_d: float = Tuning.interact_range * 2.4   # 车比箱子大，判定范围也大些
	best_d *= best_d
	for v in get_tree().get_nodes_in_group("vehicles"):
		if not is_instance_valid(v) or v.is_wrecked() or not v.has_room():
			continue
		var d: float = global_position.distance_squared_to(v.global_position)
		if d <= best_d:
			best_d = d
			best = v
	return best

func _enter_vehicle(veh) -> void:
	if searching_container != null:
		abort_search("boarded")
	# 先给人质占座（非驾驶），再自己上车
	if carried_hostage != null and is_instance_valid(carried_hostage) and veh.has_method("board_passenger"):
		var hs: int = veh.board_passenger(carried_hostage)
		if hs >= 0:
			carried_hostage.vehicle = veh
			carried_hostage.vehicle_seat = hs
			carried_hostage.set_carried(null)
			carried_hostage = null
		else:
			drop_hostage()
	if NetHub.is_online() and int(veh.get("net_id")) >= 0:
		NetHub.request_vehicle_board(int(veh.net_id))
		return
	var seat: int = veh.board(self)
	if seat < 0:
		return
	vehicle = veh
	vehicle_seat = seat
	aiming = false
	stance = Stance.WALK
	RaidLog.bump("vehicle_boards")
	vehicle_changed.emit(veh, seat)

func apply_vehicle_board(veh, seat: int) -> void:
	if veh == null or seat < 0:
		return
	if vehicle != null and vehicle != veh and is_instance_valid(vehicle):
		vehicle.disembark(self)
	veh.occupy_seat(self, seat)
	vehicle = veh
	vehicle_seat = seat
	aiming = false
	stance = Stance.WALK
	velocity = Vector2.ZERO
	vehicle_changed.emit(veh, seat)

func apply_vehicle_exit() -> void:
	if vehicle == null:
		return
	_exit_vehicle()

func _toggle_carry_hostage() -> void:
	if is_dead() or aboard_ship != null:
		return
	if carried_hostage != null:
		# 靠近载具且有空座 → 放上车
		var veh = _nearest_vehicle_any()
		if veh != null and veh.has_method("board_passenger") and veh.has_room():
			var hs: int = veh.board_passenger(carried_hostage)
			if hs >= 0:
				carried_hostage.vehicle = veh
				carried_hostage.vehicle_seat = hs
				carried_hostage.set_carried(null)
				carried_hostage = null
				return
		drop_hostage()
		return
	# 车上：从本车把人质抱下来
	if vehicle != null and is_instance_valid(vehicle):
		var h_in_car = _hostage_in_vehicle(vehicle)
		if h_in_car != null:
			vehicle.disembark(h_in_car)
			h_in_car.leave_vehicle_forced()
			_pick_up_hostage(h_in_car)
		return
	# 地上人质 / 附近车上的人质
	var h = _nearest_hostage()
	if h != null:
		if h.vehicle != null and is_instance_valid(h.vehicle):
			h.vehicle.disembark(h)
			h.leave_vehicle_forced()
		_pick_up_hostage(h)

func _pick_up_hostage(h) -> void:
	if h == null or not is_instance_valid(h) or h.is_dead():
		return
	if h.vehicle != null and is_instance_valid(h.vehicle):
		h.vehicle.disembark(h)
		h.leave_vehicle_forced()
	carried_hostage = h
	h.set_carried(self)
	if h.director != null and h.director.has_method("on_hostage_picked"):
		h.director.on_hostage_picked(self)

func drop_hostage() -> void:
	if carried_hostage == null:
		return
	var h = carried_hostage
	carried_hostage = null
	if is_instance_valid(h) and h.carried_by == self:
		h.set_carried(null)
		h.global_position = global_position + Vector2.DOWN.rotated(rotation) * 22.0

func clear_carried_hostage() -> void:
	carried_hostage = null

func _nearest_hostage():
	var best = null
	var best_d: float = Tuning.interact_range * Tuning.interact_range * 1.6
	for n in get_tree().get_nodes_in_group("hostages"):
		if not is_instance_valid(n) or n.is_dead():
			continue
		var d: float = global_position.distance_squared_to(n.global_position)
		if d <= best_d:
			best_d = d
			best = n
	return best

func _hostage_in_vehicle(veh):
	for s in veh.seats:
		if s != null and is_instance_valid(s) and s.is_in_group("hostages"):
			return s
	return null

func _nearest_vehicle_any():
	var best = null
	var best_d: float = Tuning.interact_range * 2.4
	best_d *= best_d
	for v in get_tree().get_nodes_in_group("vehicles"):
		if not is_instance_valid(v) or v.is_wrecked():
			continue
		var d: float = global_position.distance_squared_to(v.global_position)
		if d <= best_d:
			best_d = d
			best = v
	return best

func hostage_prompt() -> String:
	if carried_hostage != null:
		var veh = _nearest_vehicle_any()
		if veh != null and veh.has_room():
			return "[K] 把人质放上车"
		return "[K] 放下人质"
	if vehicle != null and _hostage_in_vehicle(vehicle) != null:
		return "[K] 从车上抱起人质"
	var h = _nearest_hostage()
	if h != null:
		return "[K] 背起 %s" % str(h.display_name)
	return ""


func _is_phone_ringing() -> bool:
	var n = get_tree().get_first_node_in_group("contract_director")
	return n != null and n.has_method("is_phone_ringing") and n.is_phone_ringing()


func _exit_vehicle() -> void:
	if vehicle == null:
		return
	var v = vehicle
	var drop: Vector2 = v.disembark(self) if is_instance_valid(v) else global_position
	vehicle = null
	vehicle_seat = -1
	global_position = drop
	velocity = Vector2.ZERO
	vehicle_changed.emit(null, -1)

## 载具爆炸时强制把玩家踢下车（位置已由载具设置好）
func leave_vehicle_forced() -> void:
	vehicle = null
	vehicle_seat = -1
	velocity = Vector2.ZERO
	vehicle_changed.emit(null, -1)

# ── 飞船登舰 ────────────────────────────────────────────
func enter_ship(ship) -> void:
	if aboard_ship != null:
		return
	_z_before_ship = z_index
	aboard_ship = ship
	_portal_channel_t = 0.0
	_portal_channel_label = ""
	collision_mask = SHIP_WALL_LAYER
	collision_layer = 1 << 1
	z_as_relative = false
	z_index = 120
	add_to_group("aboard_ship")
	velocity = Vector2.ZERO
	if searching_container != null:
		abort_search("boarded")
	RaidLog.log_event("ship_enter", {})

func on_ship_pilot(_ship) -> void:
	velocity = Vector2.ZERO
	if searching_container != null:
		abort_search("seated")
	RaidLog.log_event("ship_pilot", {})

func on_ship_unpilot() -> void:
	RaidLog.log_event("ship_unpilot", {})

func exit_ship(drop_pos: Vector2 = Vector2.INF) -> void:
	if aboard_ship == null:
		return
	var s = aboard_ship
	if s.has_method("leave_pilot"):
		s.leave_pilot(self)
	aboard_ship = null
	_portal_channel_t = 0.0
	_portal_channel_label = ""
	collision_mask = 1 << 0
	z_as_relative = true
	z_index = _z_before_ship
	remove_from_group("aboard_ship")
	velocity = Vector2.ZERO
	if drop_pos != Vector2.INF:
		global_position = drop_pos
	else:
		global_position = s.global_position + s._portal_exterior[0]
	RaidLog.log_event("ship_exit", {})

## 本局结算：提交点折现进保险箱；背包与未提交寄存撤离时按倍率折现，死亡掉落
func backpack_value() -> int:
	return inv.total_value() if inv != null else 0

func stash_value() -> int:
	return stash.total_value() if stash != null else 0

func expand_stash_page() -> void:
	if stash == null or not stash.has_method("expand"):
		return
	var add_c: int = maxi(1, int(Tuning.stash_cols))
	var add_r: int = maxi(1, int(Tuning.stash_rows))
	stash.expand(stash.cols + (add_c if stash.cols < add_c else 0), stash.rows + add_r)

func total_value() -> int:
	return secured_value + backpack_value() + stash_value()

func secure_value(amount: int, items: Array = []) -> void:
	if amount <= 0 or raid_over:
		return
	secured_value += amount
	RaidLog.log_event("items_secured", {"value": amount, "count": items.size(), "secured": secured_value})

func settle_extract(mul: float, reason: String = "extract") -> Dictionary:
	if raid_over:
		return settle_report
	_close_raid_uis()
	var bag: int = backpack_value()
	var st: int = stash_value()
	var bag_pay: int = int(round(float(bag) * maxf(mul, 0.0)))
	var stash_pay: int = int(round(float(st) * maxf(mul, 0.0)))
	settle_report = {
		"reason": reason,
		"secured": secured_value,
		"backpack": bag,
		"stash": st,
		"mul": mul,
		"backpack_payout": bag_pay,
		"stash_payout": stash_pay,
		"total": secured_value + bag_pay + stash_pay,
	}
	raid_over = true
	RaidLog.log_event("raid_settled", settle_report)
	raid_settled.emit(settle_report)
	return settle_report

func settle_death() -> Dictionary:
	if raid_over:
		return settle_report
	var bag: int = backpack_value()
	var st: int = stash_value()
	var ids: Array = inv.item_ids() if inv != null else []
	var stash_ids: Array = stash.item_ids() if stash != null else []
	var world = _raid_world()
	if (not ids.is_empty() or not stash_ids.is_empty()) and world != null and world.has_method("spawn_corpse_bag"):
		world.spawn_corpse_bag(global_position, ids, "你的背包", stash_ids)
	if inv != null:
		inv.clear()
	if stash != null:
		stash.clear()
	settle_report = {
		"reason": "death",
		"secured": secured_value,
		"backpack": bag,
		"stash": st,
		"mul": 0.0,
		"backpack_payout": 0,
		"stash_payout": 0,
		"total": secured_value,
	}
	raid_over = true
	RaidLog.log_event("raid_settled", settle_report)
	raid_settled.emit(settle_report)
	return settle_report

func _close_raid_uis() -> void:
	if searching_container != null:
		abort_search("settled")
	var root = get_tree().get_first_node_in_group("raid_root")
	if root == null:
		return
	if root.get("loot_ui") != null and root.loot_ui.visible:
		root.loot_ui.close_panel()
	if root.get("deposit_ui") != null and root.deposit_ui.visible:
		root.deposit_ui.close_panel()

func _raid_world():
	var root = get_tree().get_first_node_in_group("raid_root")
	if root != null and root.get("level") != null:
		return root.level
	return null

## 劫持破解成功：获密闭舱全部奖励，无视负重
func grant_sealed_reward() -> void:
	if inv == null:
		return
	if aboard_ship == null or aboard_ship.sealed_containers == null:
		return
	for c in aboard_ship.sealed_containers:
		if not is_instance_valid(c):
			continue
		for i in c.slots.size():
			if i >= c.revealed.size() or i >= c.taken.size():
				continue
			if not c.revealed[i] or c.taken[i] or c.slots[i].is_empty():
				continue
			var id: String = str(c.slots[i].get("id", ""))
			if id == "":
				continue
			inv.grant_no_weight(id)
			c.taken[i] = true
	RaidLog.log_event("sealed_reward_granted", {"value": inv.total_value()})

func is_driving() -> bool:
	return vehicle != null and vehicle_seat == 0

func _tick_ooc_regen(delta: float) -> void:
	if health == null or health.dead or raid_over:
		return
	if health.hp >= health.hp_max - 0.01:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var last: float = _last_shot_time
	if health.last_hit_time > last:
		last = health.last_hit_time
	if now - last < Tuning.ooc_regen_delay:
		return
	var before: float = health.hp
	health.heal(Tuning.ooc_regen_per_sec * delta)
	if not is_equal_approx(before, health.hp):
		health_changed.emit(health.hp, health.hp_max)

# ── 逐格搜刮 ────────────────────────────────────────────
func _begin_search(container) -> void:
	if container == null or not container.has_method("slot_count"):
		return
	if global_position.distance_to(container.global_position) > Tuning.interact_range:
		return
	if NetHub.container_locked_by_other(container):
		return
	if not NetHub.request_container_lock(container):
		return
	if container.is_fully_searched():
		# 已搜完的容器直接开面板取物，不再读条
		searching_container = container
		search_state_changed.emit(true, container)
		return

	searching_container = container
	_search_slot = container.next_unsearched_slot()
	_search_elapsed = 0.0
	_cracking = container.richness == "L4" and not container.cracked
	search_state_changed.emit(true, container)
	RaidLog.log_event("search_begin", {
		"container": container.name,
		"richness": container.richness,
		"slot": _search_slot,
		"cracking": _cracking,
	})

	if not Tuning.enable_search_progress:
		# 对照模式：即时全开
		container.reveal_all()
		_search_elapsed = 0.0
		_cracking = false
		RaidLog.bump("containers_opened")

## NetHub 的容器锁需要节点路径，用无类型引用即可
func _lock_key(c) -> NodePath:
	return c.get_path()

func _tick_search(delta: float) -> void:
	if searching_container == null:
		return
	var container = searching_container
	if global_position.distance_to(container.global_position) > Tuning.interact_range * 1.25:
		abort_search("out_of_range")
		return
	if container.is_fully_searched():
		return

	RaidLog.bump("time_searching", delta)
	_search_elapsed += delta

	if _cracking:
		search_progress.emit(_search_elapsed, Tuning.l4_crack_time, -1, container.slot_count())
		if _search_elapsed >= Tuning.l4_crack_time:
			container.cracked = true
			_cracking = false
			_search_elapsed = 0.0
			RaidLog.log_event("l4_cracked", {"container": container.name})
		return

	var need := Tuning.search_time_per_slot * GameData.search_time_mul(container.richness)
	search_progress.emit(_search_elapsed, need, _search_slot, container.slot_count())
	if _search_elapsed >= need:
		var found = container.reveal_slot(_search_slot)
		RaidLog.bump("slots_searched")
		if found.is_empty():
			RaidLog.bump("slots_empty")
		RaidLog.log_event("slot_revealed", {
			"container": container.name,
			"slot": _search_slot,
			"item": found.get("id", ""),
		})
		_search_elapsed = 0.0
		if container.is_fully_searched():
			RaidLog.bump("containers_opened")
			RaidLog.log_event("container_cleared", {"container": container.name})
			# 全部搜完 → 结束读条但**保持面板打开**，玩家继续挑东西拿
			_search_slot = -1
			search_progress.emit(0.0, 0.0, -1, container.slot_count())
		else:
			_search_slot = container.next_unsearched_slot()

func abort_search(reason: String) -> void:
	if searching_container == null:
		return
	var c = searching_container
	# 逐格搜刮的关键设计：中断只丢失"当前这一格"的进度，已搜出的格子永久保留。
	# 这让"搜一半听到脚步就撤"成为一个真实可行的战术选择。
	if reason != "released" or _search_elapsed > 0.05:
		RaidLog.bump("searches_aborted")
	RaidLog.log_event("search_abort", {
		"container": c.name, "reason": reason,
		"progress": snappedf(_search_elapsed, 0.01),
		"revealed": c.revealed_count(), "total": c.slot_count(),
	})
	_search_elapsed = 0.0
	_cracking = false
	searching_container = null
	NetHub.release_container_lock(c)
	search_state_changed.emit(false, c)

func close_container_panel() -> void:
	if searching_container != null:
		abort_search("panel_closed")

# ── 视野参数（供 Vision 节点读取）────────────────────────
func vision_range() -> float:
	var r := Tuning.vision_range
	if stance == Stance.CROUCH:
		r *= Tuning.crouch_vision_range_mul
	return r

func vision_half_angle_deg() -> float:
	var a := Tuning.fov_half_angle
	if stance == Stance.CROUCH:
		a += Tuning.crouch_fov_bonus
	elif stance == Stance.SPRINT:
		a -= Tuning.sprint_fov_penalty
	return clampf(a, 5.0, 180.0)

# ── 指标 ────────────────────────────────────────────────
func _track_metrics(delta: float) -> void:
	RaidLog.bump("distance_walked", global_position.distance_to(_last_pos))
	_last_pos = global_position
	if stance == Stance.SPRINT:
		RaidLog.bump("time_sprinting", delta)
	elif stance == Stance.CROUCH:
		RaidLog.bump("time_crouching", delta)
	if weapon != null and weapon.ads > 0.5:
		RaidLog.bump("time_aiming", delta)
