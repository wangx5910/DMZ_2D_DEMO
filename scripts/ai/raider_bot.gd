extends CharacterBody2D
## RaiderBot · 功利型敌对玩家AI
## - 与真人玩家、其他 AI 均为敌对；遇敌优先互打
## - 冲免保途中遇怪先清；怪也会打 AI（与打玩家同规则）
## - 冲刺途中随机晃荡，约浪费 1/10 行程时间

enum S { RUSH_SAFE, OPEN_SAFE, LOOT, ROAM, COMBAT, CONTEST_SHIP, CONTRACT, DEAD }

const RADIUS := 11.0
const HitscanScript := preload("res://scripts/combat/hitscan.gd")
const PROBE_LEN := 52.0
const PROBE_ANGLES := [30.0, 55.0, 80.0, 105.0, 130.0, 155.0]
const CHECK_WINDOW := 0.6
const MIN_PROGRESS_RATIO := 0.25
const STUCK_GIVEUP := 1.8
const HOSTILE_NOTICE := 0.35
const THINK_INTERVAL := 0.20      # 感知/选目标节流
const LOOT_SCAN_INTERVAL := 0.35  # 开箱目标刷新节流
const COVER_RANGE_PX := 160.0     # 20m：附近掩体搜索半径
const COVER_ARRIVE := 16.0
const SHIP_WALL_LAYER := 1 << 6

enum CombatPhase { OPEN, SEEK_COVER, HOLD, PEEK }

var world = null
var _fx = null
var team_id: int = 1
var squad_member: int = 0
var state: int = S.RUSH_SAFE
var target_safe = null
var target_container = null
var combat_target = null
var health: Health = null
var weapon: Weapon = null
var inv: GridInventory = null
var aim_dir := Vector2.RIGHT
var aboard_ship = null
var _portal_channel_t := 0.0
var _portal_channel_label := ""
var _z_before_ship := 9

var _open_t := 0.0
var _rng := RandomNumberGenerator.new()
var _loot_value := 0
var _name_tag := "掠夺者AI"
var _resume_state: int = S.RUSH_SAFE
var first_safe_done: bool = false
var carried_hostage = null

## 搜刮读条（对齐玩家：先破解 → 逐格揭示 → 再装包）
enum SearchPhase { NONE, CRACK, REVEAL, TAKE }
var _search_phase: int = SearchPhase.NONE
var _search_elapsed := 0.0
var _search_slot := -1
var _take_slot := -1
var _active_search = null

var _wall_follow := 0
var _nav_stuck := 0.0
var _progress_timer := 0.0
var _last_goal_dist := -1.0
var _current_goal := Vector2.INF
var _stuck_flips := 0
var _detour := Vector2.INF
var _detour_t := 0.0
var _clear_streak := 0.0

# 性能缓存
var _think_cd := 0.0
var _loot_scan_cd := 0.0
var _cached_hostile = null
var _cached_enemy = null
var _cached_loot = null

var _notice_timer := 0.0
var _fire_burst_left := 0
var _fire_pause := 0.0
var _strafe_dir := 1
var _strafe_timer := 0.0

## 掩体战：先躲后 peek，避免平地硬刚
var _combat_phase: int = CombatPhase.OPEN
var _cover_node = null
var _cover_scan_cd := 0.0
var _hold_t := 0.0
var _peek_t := 0.0
var _seek_t := 0.0
var _perceive_hold := 0

## 冲免保晃荡：总预算约行程时间的 10%
var _wander_budget := 0.0
var _wander_point := Vector2.INF
var _wander_seg_t := 0.0
var _next_wander_roll := 1.5
var _rush_budget_ready := false

func setup(w, spawn_pos: Vector2, safe_node = null, tag := "掠夺者AI", tid: int = 1) -> void:
	world = w
	global_position = spawn_pos
	target_safe = safe_node
	_name_tag = tag
	team_id = tid
	_apply_vision_policy()

func set_fx(fx) -> void:
	_fx = fx

func _ready() -> void:
	_rng.randomize()
	add_to_group("raider_bots")
	collision_layer = 1 << 1
	collision_mask = 1 << 0
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	z_index = 9
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	shape.shape = circle
	add_child(shape)

	health = Health.new(Tuning.player_hp_max)
	health.died.connect(_on_died)
	weapon = Weapon.new("m4")
	inv = GridInventory.new(Tuning.backpack_cols, Tuning.backpack_rows)
	_strafe_dir = 1 if _rng.randf() > 0.5 else -1
	_nudge_out_of_wall()
	if not Tuning.value_changed.is_connected(_on_tuning_changed):
		Tuning.value_changed.connect(_on_tuning_changed)
	# setup() 可能在 add_child 之后才设 team_id；此处先按当前 team 处理一次
	_apply_vision_policy()

func _on_tuning_changed(key: String, _v: Variant) -> void:
	if key == "show_enemy_players":
		_apply_vision_policy()

func _is_local_ally() -> bool:
	var arr := get_tree().get_nodes_in_group("player")
	for p in arr:
		if is_instance_valid(p):
			return int(p.get("team_id")) == team_id
	return team_id == 0

## 友军始终可见；敌方默认进 vision_gated，仅扇形内可见（调试开关可强制全显）
func _apply_vision_policy() -> void:
	if state == S.DEAD:
		return
	if _is_local_ally():
		if is_in_group("vision_gated"):
			remove_from_group("vision_gated")
		visible = true
		return
	if not is_in_group("vision_gated"):
		add_to_group("vision_gated")
	visible = Tuning.show_enemy_players

func is_dead() -> bool:
	return state == S.DEAD or (health != null and health.dead)

func take_damage(amount: float, from: Vector2) -> void:
	if is_dead() or health == null:
		return
	if amount <= 0.0:
		return
	health.apply_damage(amount, from)
	if is_dead():
		return
	# 挨打立刻进入战斗：朝来向找敌
	var who = _hostile_near_point(from, 220.0)
	if who != null:
		combat_target = who
		_enter_combat(who)

func _on_died(_from: Vector2) -> void:
	state = S.DEAD
	velocity = Vector2.ZERO
	collision_layer = 0
	collision_mask = 0
	_abort_search()
	if carried_hostage != null:
		drop_hostage()
	if aboard_ship != null and is_instance_valid(aboard_ship):
		var drop: Vector2 = global_position
		if aboard_ship._portal_exterior.size() > 0:
			drop = aboard_ship.global_position + aboard_ship._portal_exterior[0]
		aboard_ship._aboard.erase(self)
		exit_ship(drop)
	_drop_corpse_bag()
	remove_from_group("raider_bots")
	if is_in_group("vision_gated"):
		remove_from_group("vision_gated")
	# 尸体留在死亡时的可见状态；已看到才看得见
	queue_redraw()
	set_physics_process(false)

func _drop_corpse_bag() -> void:
	var ids: Array = inv.item_ids() if inv != null else []
	var pos := global_position + Vector2(16, 10)
	if world != null and world.has_method("spawn_corpse_bag"):
		world.spawn_corpse_bag(pos, ids, "%s的背包" % _name_tag)
		return
	var bag := Area2D.new()
	bag.set_script(load("res://scripts/world/loot_container.gd"))
	get_parent().add_child(bag)
	bag.global_position = pos
	bag.setup_corpse_bag(ids, "%s的背包" % _name_tag, "L2")

func _abort_search() -> void:
	_search_phase = SearchPhase.NONE
	_search_elapsed = 0.0
	_search_slot = -1
	_take_slot = -1
	_active_search = null
	_open_t = 0.0

func _physics_process(delta: float) -> void:
	if state == S.DEAD:
		return

	var ppos := _player_pos()
	var d2: float = global_position.distance_squared_to(ppos) if ppos != Vector2.INF else 0.0
	var frame: int = Engine.get_physics_frames()
	var slot: int = abs(get_instance_id()) % 8

	# 远距 LOD（相对玩家）。仅「已登舰」跳过远距冻结；抢船路上的 AI 仍走降频，
	# 否则劫持一瞬间 60+ AI 全开会直接卡死。
	const LOD_NEAR_PX := 3600.0   # 450m
	const LOD_FAR_PX := 5600.0    # 700m
	var skip_lod: bool = aboard_ship != null or state == S.CONTRACT \
			or carried_hostage != null or _want_rescue_contract()
	if not skip_lod and d2 > LOD_FAR_PX * LOD_FAR_PX:
		if frame % 8 != slot:
			move_and_slide()
			return
		_tick_lod_far(delta)
		return
	if not skip_lod and d2 > LOD_NEAR_PX * LOD_NEAR_PX:
		if frame % 3 != (slot % 3):
			move_and_slide()
			return
		delta *= 3.0

	if weapon != null:
		weapon.reserve = weapon.reserve_max()
		var ads := state == S.COMBAT
		if state == S.CONTRACT and (_cached_enemy != null or _cached_hostile != null):
			ads = true
		weapon.tick(delta, ads, 0)

	# 感知节流 + 缓存
	_think_cd -= delta
	if _think_cd <= 0.0 or state == S.COMBAT:
		_think_cd = THINK_INTERVAL + _rng.randf_range(0.0, 0.08)
		_cached_hostile = _nearest_hostile_visible()
		if state != S.COMBAT:
			_cached_enemy = _nearest_enemy_visible()

	var pursue_contract := _want_rescue_contract()
	var hostile = _cached_hostile
	if hostile != null and is_instance_valid(hostile):
		_notice_timer += delta
		if _notice_timer >= HOSTILE_NOTICE or state == S.COMBAT:
			_enter_combat(hostile)
	else:
		_notice_timer = maxf(0.0, _notice_timer - delta * 1.2)
		# 做合约时不因小兵进入 COMBAT，边走边打即可
		if not pursue_contract and state != S.COMBAT \
				and _cached_enemy != null and is_instance_valid(_cached_enemy):
			_enter_combat(_cached_enemy)

	# 合约小队：做完合约优先于抢船；遇敌方玩家才停下来互打
	if state != S.DEAD:
		if pursue_contract:
			if state == S.COMBAT and not _is_enemy_player(combat_target):
				_clear_cover_combat()
				combat_target = null
				state = S.CONTRACT
			elif state != S.COMBAT:
				if state != S.CONTRACT:
					_abort_search()
				state = S.CONTRACT
		elif state != S.COMBAT and _want_contest_ship():
			if state != S.CONTEST_SHIP:
				_abort_search()
				_resume_state = state if state != S.OPEN_SAFE else S.RUSH_SAFE
			state = S.CONTEST_SHIP
		elif state == S.CONTRACT:
			state = S.LOOT

	match state:
		S.RUSH_SAFE: _tick_rush(delta)
		S.OPEN_SAFE: _tick_open(delta)
		S.LOOT: _tick_loot(delta)
		S.ROAM: _tick_roam(delta)
		S.COMBAT: _tick_combat(delta)
		S.CONTEST_SHIP: _tick_contest_ship(delta)
		S.CONTRACT: _tick_contract(delta)
		S.DEAD:
			velocity = Vector2.ZERO
	move_and_slide()
	_track_stuck(delta)
	if velocity.length_squared() > 16.0 and state != S.COMBAT:
		aim_dir = velocity.normalized()
	rotation = aim_dir.angle()

func _player_pos() -> Vector2:
	if world != null and world.get("_player") != null and is_instance_valid(world._player):
		return world._player.global_position
	var arr := get_tree().get_nodes_in_group("player")
	for p in arr:
		if is_instance_valid(p):
			return p.global_position
	return Vector2.INF

## 远距简化：只推进目标，不做交战感知/绕障射线
func _tick_lod_far(delta: float) -> void:
	if _want_contest_ship():
		state = S.CONTEST_SHIP
		_tick_contest_ship(delta)
		move_and_slide()
		return
	# 远距简化不会跑开箱：到达免保后直接视为开完，才能去接旁边的合约
	if state == S.RUSH_SAFE or state == S.OPEN_SAFE:
		if target_safe == null or not is_instance_valid(target_safe):
			target_safe = _nearest_free_safe()
		if target_safe != null and is_instance_valid(target_safe):
			if global_position.distance_to((target_safe as Node2D).global_position) <= Tuning.interact_range:
				_finish_open_safe_lod()
	if _want_rescue_contract():
		state = S.CONTRACT
		_tick_contract(delta)
		move_and_slide()
		return
	var goal := Vector2.INF
	if state == S.RUSH_SAFE or state == S.OPEN_SAFE:
		if target_safe == null or not is_instance_valid(target_safe):
			target_safe = _nearest_free_safe()
		if target_safe != null and is_instance_valid(target_safe):
			goal = (target_safe as Node2D).global_position
			if global_position.distance_to(goal) <= Tuning.interact_range:
				state = S.OPEN_SAFE
	elif state == S.LOOT or state == S.ROAM:
		if target_container != null and is_instance_valid(target_container):
			goal = target_container.global_position
		elif target_safe != null and is_instance_valid(target_safe):
			goal = (target_safe as Node2D).global_position
	if goal != Vector2.INF:
		var to := goal - global_position
		if to.length() > 4.0:
			velocity = to.normalized() * Tuning.walk_speed
			aim_dir = velocity.normalized()
			rotation = aim_dir.angle()
	move_and_slide()

func _finish_open_safe_lod() -> void:
	if target_safe == null or not is_instance_valid(target_safe):
		return
	_vacuum_container(target_safe)
	first_safe_done = true
	state = S.LOOT

func _want_contest_ship() -> bool:
	if world == null or not Tuning.enable_spaceship_hijack:
		return false
	if not world.has_method("is_hijack_active") or not world.is_hijack_active():
		return false
	var ship = world.get("spaceship")
	if ship == null or not is_instance_valid(ship):
		return false
	# 自己是劫持者 / 已登舰：必须继续
	if ship.hijacker == self or aboard_ship == ship:
		return true
	# 仅离船最近的一小撮获准抢船（world 维护名单）
	if world.has_method("is_ship_contestor"):
		return world.is_ship_contestor(self)
	return false

func _want_rescue_contract() -> bool:
	# TEMP：暂时关闭 AI「救援人质」行为树入口
	return false
	# if world == null or world.get("contracts") == null:
	# 	return false
	# var con = world.contracts
	# if con == null or not is_instance_valid(con) or not con.has_method("should_ai_pursue_rescue"):
	# 	return false
	# return con.should_ai_pursue_rescue(self)

func _tick_contract(delta: float) -> void:
	if world == null or world.get("contracts") == null:
		state = S.LOOT
		return
	var con = world.contracts
	if int(con.phase) == 1:  # Phase.OFFERED
		_tick_contract_accept(delta, con)
		return
	_tick_contract_rescue(delta, con)

func _tick_contract_accept(delta: float, con) -> void:
	var b = con.board
	if b == null or not is_instance_valid(b):
		return
	var pos: Vector2 = b.global_position
	if global_position.distance_to(pos) <= Tuning.interact_range:
		velocity = Vector2.ZERO
		con.accept_from_board(b, self)
		return
	_move_towards(pos, Tuning.walk_speed, delta)

func _tick_contract_rescue(delta: float, con) -> void:
	var h = con.hostage
	if h == null or not is_instance_valid(h) or h.is_dead():
		if carried_hostage != null:
			drop_hostage()
		state = S.LOOT
		return
	if carried_hostage == h:
		var dest: Vector2 = con.extract_pos
		if dest != Vector2.INF and global_position.distance_to(dest) <= Tuning.contract_extract_radius * 0.7:
			velocity = Vector2.ZERO
		elif dest == Vector2.INF:
			_move_towards(h.global_position, Tuning.walk_speed * Tuning.carry_hostage_speed_mul, delta)
		else:
			var spd: float = Tuning.walk_speed * Tuning.carry_hostage_speed_mul
			_move_towards(dest, spd, delta)
		_try_contract_shoot(delta)
		return
	if h.carried_by != null and is_instance_valid(h.carried_by) \
			and int(h.carried_by.get("team_id")) == team_id:
		_escort_carrier(delta, h.carried_by, con.extract_pos)
		_try_contract_shoot(delta)
		return
	var hp: Vector2 = h.global_position
	if h.vehicle != null and is_instance_valid(h.vehicle):
		hp = h.vehicle.global_position
	if global_position.distance_to(hp) <= Tuning.interact_range:
		if h.carried_by != null and is_instance_valid(h.carried_by) \
				and int(h.carried_by.get("team_id")) != team_id:
			velocity = Vector2.ZERO
			_try_contract_shoot(delta)
			return
		_pick_up_hostage(h)
		_try_contract_shoot(delta)
		return
	_move_towards(hp, Tuning.walk_speed, delta)
	_try_contract_shoot(delta)

func _escort_carrier(delta: float, carrier, dest: Vector2) -> void:
	var cpos: Vector2 = carrier.global_position
	var toward: Vector2 = dest - cpos if dest != Vector2.INF else Vector2.RIGHT
	if carrier.get("aim_dir") != null and dest == Vector2.INF:
		var ad: Vector2 = carrier.aim_dir
		if ad.length_squared() > 0.01:
			toward = ad
	if toward.length_squared() < 1.0:
		toward = Vector2.RIGHT
	var fwd: Vector2 = toward.normalized()
	var side: Vector2 = fwd.orthogonal()
	var off := Vector2.ZERO
	match squad_member % 3:
		0:
			off = -fwd * 40.0 + side * 52.0
		1:
			off = -fwd * 40.0 - side * 52.0
		_:
			off = fwd * 44.0
	var goal: Vector2 = cpos + off
	var gap: float = global_position.distance_to(cpos)
	var spd: float = Tuning.sprint_speed if gap > 130.0 else Tuning.walk_speed
	_move_towards(goal, spd, delta)

func _try_contract_shoot(delta: float) -> void:
	var t = _cached_hostile
	if t == null or not is_instance_valid(t) or (t.has_method("is_dead") and t.is_dead()):
		t = _cached_enemy
	if t == null or not is_instance_valid(t) or (t.has_method("is_dead") and t.is_dead()):
		return
	var tpos: Vector2 = t.global_position
	_face(tpos, delta)
	if global_position.distance_to(tpos) <= Tuning.enemy_engage_range * 1.2 and _line_clear(tpos):
		_try_shoot(delta)

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

func _tick_contest_ship(delta: float) -> void:
	if not _want_contest_ship():
		state = _resume_state if _resume_state != S.CONTEST_SHIP else S.ROAM
		return
	var ship = world.spaceship
	# 自己是劫持者：坐上驾驶座后由飞船同步位置并自动飞向破解点
	if ship.hijacker == self:
		if ship.has_method("is_pilot") and ship.is_pilot(self):
			return
		var hold: Vector2 = ship.global_position + ship._control_local
		_move_towards(hold, Tuning.walk_speed, delta)
		_face(hold, delta)
		return
	# 未登舰：冲最近外部门，由飞船 tick 读条传送
	if aboard_ship != ship:
		var best: Vector2 = ship.global_position
		var bd := INF
		for off in ship._portal_exterior:
			var p: Vector2 = ship.global_position + off
			var d: float = global_position.distance_squared_to(p)
			if d < bd:
				bd = d
				best = p
		_move_towards(best, Tuning.walk_speed, delta)
		_face(best, delta)
		return
	# 已登舰：冲操控室；异队夺权，同队协防
	var ctrl: Vector2 = ship.global_position + ship._control_local
	_move_towards(ctrl, Tuning.walk_speed, delta)
	_face(ctrl, delta)
	if ship.is_in_control_room(self):
		# 已是劫持者就别每帧 seize；异队才夺权
		if ship.hijacker != self and ship.has_method("try_hijack"):
			ship.try_hijack(self)

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
	_abort_search()

func exit_ship(drop_pos: Vector2 = Vector2.INF) -> void:
	if aboard_ship == null:
		return
	var s = aboard_ship
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
	elif s != null and is_instance_valid(s) and s._portal_exterior.size() > 0:
		global_position = s.global_position + s._portal_exterior[0]

func grant_sealed_reward() -> void:
	if inv == null or aboard_ship == null or aboard_ship.sealed_containers == null:
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
			if inv.has_method("grant_no_weight"):
				inv.grant_no_weight(id)
			else:
				inv.add_auto(id)
			c.taken[i] = true

func total_value() -> int:
	return inv.total_value() if inv != null else _loot_value

func _enter_combat(who) -> void:
	if who == null or not is_instance_valid(who):
		return
	var entering := state != S.COMBAT
	var prev = combat_target
	if entering:
		_resume_state = state
		_abort_search()
		_last_goal_dist = -1.0
		_wall_follow = 0
		_combat_phase = CombatPhase.OPEN
		_cover_node = null
		_cover_scan_cd = 0.0
	combat_target = who
	state = S.COMBAT
	# 仅首次进战或换目标时挑掩体（避免每帧重置 peek）
	if _is_enemy_player(who) and (entering or prev != who):
		_try_pick_cover(who.global_position)

func _is_enemy_player(who) -> bool:
	if who == null or not is_instance_valid(who):
		return false
	return who.is_in_group("player") or who.is_in_group("raider_bots")

func _tick_combat(delta: float) -> void:
	if combat_target == null or not is_instance_valid(combat_target) \
			or (combat_target.has_method("is_dead") and combat_target.is_dead()):
		combat_target = _nearest_hostile_visible()
		if combat_target == null:
			combat_target = _nearest_enemy_visible()
		if combat_target == null:
			_clear_cover_combat()
			state = _resume_state
			return
	var tpos: Vector2 = combat_target.global_position
	var d := global_position.distance_to(tpos)
	var see := _line_clear(tpos)

	# 对敌方玩家：附近有掩体就走躲掩体 / peek，否则平地战
	if _is_enemy_player(combat_target):
		_cover_scan_cd -= delta
		if _cover_node == null or not is_instance_valid(_cover_node) \
				or not _cover_node.is_visible_in_tree():
			if _cover_scan_cd <= 0.0:
				_try_pick_cover(tpos)
		if _cover_node != null and is_instance_valid(_cover_node):
			_tick_cover_combat(delta, tpos, d, see)
			return

	if not see and d > Tuning.enemy_engage_range * 1.4:
		_move_towards(tpos, Tuning.walk_speed, delta)
		_face(tpos, delta)
		return
	_tick_open_combat(delta, tpos, d, see)

func _clear_cover_combat() -> void:
	_combat_phase = CombatPhase.OPEN
	_cover_node = null
	_hold_t = 0.0
	_peek_t = 0.0
	_seek_t = 0.0

func _try_pick_cover(threat_pos: Vector2) -> void:
	_cover_scan_cd = 0.45
	var cover = _find_nearby_cover(threat_pos, COVER_RANGE_PX)
	if cover == null:
		_combat_phase = CombatPhase.OPEN
		_cover_node = null
		return
	_cover_node = cover
	_combat_phase = CombatPhase.SEEK_COVER
	_hold_t = 0.0
	_peek_t = 0.0
	_seek_t = 0.0

func _find_nearby_cover(threat_pos: Vector2, max_d: float):
	var best = null
	var best_score := 1e18
	for n in get_tree().get_nodes_in_group("cover"):
		if n == null or not is_instance_valid(n):
			continue
		if not n.is_visible_in_tree():
			continue
		var cd: float = global_position.distance_to(n.global_position)
		if cd > max_d:
			continue
		# 优先：离自己近，且掩体能挡在自己与威胁之间
		var stand: Vector2 = n.stand_behind(threat_pos) if n.has_method("stand_behind") \
				else n.global_position
		var mid: float = n.global_position.distance_to(threat_pos)
		var me_t: float = global_position.distance_to(threat_pos)
		var between_bonus := 0.0
		if mid + 8.0 < me_t:
			between_bonus = -40.0  # 掩体更靠近威胁侧时略加分（可挡线）
		var score: float = cd + stand.distance_to(global_position) * 0.25 + between_bonus
		if score < best_score:
			best_score = score
			best = n
	return best

func _tick_cover_combat(delta: float, tpos: Vector2, d: float, see: bool) -> void:
	var cover = _cover_node
	if cover == null or not is_instance_valid(cover):
		_clear_cover_combat()
		_tick_open_combat(delta, tpos, d, see)
		return
	_face(tpos, delta)

	match _combat_phase:
		CombatPhase.SEEK_COVER:
			var behind: Vector2 = cover.stand_behind(tpos)
			_move_towards(behind, Tuning.walk_speed, delta)
			_seek_t += delta
			if global_position.distance_to(behind) <= COVER_ARRIVE or _seek_t > 1.15:
				_combat_phase = CombatPhase.HOLD
				_hold_t = _rng.randf_range(0.35, 0.75)
				velocity = Vector2.ZERO
		CombatPhase.HOLD:
			var behind2: Vector2 = cover.stand_behind(tpos)
			# 只有站位仍在附近、且这一步走得动时才回撤，避免顶进墙再被弹开
			if global_position.distance_to(behind2) > COVER_ARRIVE * 1.4 \
					and _path_clear((behind2 - global_position).normalized(), minf(PROBE_LEN, global_position.distance_to(behind2))):
				_move_towards(behind2, Tuning.walk_speed * 0.85, delta)
			else:
				velocity = velocity.move_toward(Vector2.ZERO, Tuning.accel * delta)
			_hold_t -= delta
			# 掩体后偶尔盲射不划算；等 peek。极近被压时立刻 peek
			if _hold_t <= 0.0 or d < Tuning.enemy_engage_min * 0.85:
				_combat_phase = CombatPhase.PEEK
				_peek_t = _rng.randf_range(0.55, 1.15)
		CombatPhase.PEEK:
			var peek: Vector2 = cover.peek_point(tpos)
			_move_towards(peek, Tuning.walk_speed, delta)
			var peek_see := see or _line_clear(tpos)
			if peek_see and d <= Tuning.enemy_engage_range * 1.2:
				_try_shoot(delta)
			_peek_t -= delta
			if _peek_t <= 0.0:
				_combat_phase = CombatPhase.HOLD
				_hold_t = _rng.randf_range(0.4, 0.9)
		_:
			_tick_open_combat(delta, tpos, d, see)

	# 掩体太远或目标拉开 → 放弃改平地追/打
	if global_position.distance_to(cover.global_position) > COVER_RANGE_PX * 1.35 \
			and d > Tuning.enemy_engage_range:
		_clear_cover_combat()

func _tick_open_combat(delta: float, tpos: Vector2, d: float, see: bool) -> void:
	_face(tpos, delta)
	var to := (tpos - global_position).normalized()
	var desired := Vector2.ZERO
	if d < Tuning.enemy_engage_min:
		desired = -to * Tuning.walk_speed
	elif d > Tuning.enemy_engage_range * 0.9:
		desired = to * Tuning.walk_speed
	else:
		_strafe_timer -= delta
		if _strafe_timer <= 0.0:
			_strafe_dir = -_strafe_dir
			_strafe_timer = _rng.randf_range(0.5, 1.2)
		desired = to.orthogonal() * float(_strafe_dir) * Tuning.walk_speed
	velocity = velocity.move_toward(desired, Tuning.accel * delta)
	if see and d <= Tuning.enemy_engage_range * 1.15:
		_try_shoot(delta)

func _try_shoot(delta: float) -> void:
	if not Tuning.enable_shooting or weapon == null:
		return
	if weapon.reloading:
		return
	if weapon.mag <= 0:
		weapon.start_reload(true)
		return
	if _fire_pause > 0.0:
		_fire_pause -= delta
		weapon.try_fire(false, global_position, aim_dir, 0, true)
		return
	if _fire_burst_left <= 0:
		_fire_burst_left = _rng.randi_range(3, 6)
	var muzzle := global_position + aim_dir * 16.0
	if weapon.try_fire(true, muzzle, aim_dir, 0, true):
		_fire_burst_left -= 1
		_shoot_ray(muzzle)
		if _fire_burst_left <= 0:
			_fire_pause = _rng.randf_range(0.35, 0.85)

func _shoot_ray(muzzle: Vector2) -> void:
	var spread: float = weapon.effective_spread(0)
	var dir := weapon.roll_direction(aim_dir, spread, _rng)
	var hit: Dictionary = HitscanScript.query(get_world_2d(), global_position, dir, weapon.range_px(), self)
	var end: Vector2 = hit["position"]
	var who = hit.get("collider")
	if who != null and who != self and who.has_method("take_damage"):
		var ok: bool = who.is_in_group("player") or who.is_in_group("raider_bots") \
				or who.is_in_group("enemies") or who.is_in_group("vehicles")
		if ok and _is_hostile_to(who):
			var dmg: float = weapon.damage_at(global_position.distance_to(end))
			if who.is_in_group("enemies"):
				dmg = Tuning.ai_vs_monster_damage
			who.take_damage(dmg, global_position)
			if _fx != null:
				_fx.add_spark(end, Vector2.ZERO)
		elif _fx != null:
			_fx.add_spark(end, hit.get("normal", Vector2.ZERO))
	elif bool(hit.get("blocked", false)) and _fx != null:
		_fx.add_spark(end, hit.get("normal", Vector2.ZERO))
	if _fx != null:
		_fx.add_tracer(muzzle, end, weapon.bullet_speed())
		_fx.add_muzzle(muzzle, aim_dir)
	# 只通知附近怪物，避免每发子弹遍历全图敌人
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		if global_position.distance_squared_to(e.global_position) > 900.0 * 900.0:
			continue
		if e.has_method("hear_gunshot"):
			e.hear_gunshot(global_position)

func _is_hostile_to(who) -> bool:
	if who == null or who == self:
		return false
	if who.is_in_group("enemies") or who.is_in_group("vehicles"):
		return true
	if who.is_in_group("player") or who.is_in_group("raider_bots") or who.is_in_group("human_players"):
		return not NetHub.are_allied(self, who)
	return false

func set_squad(sid: int, member_i: int = 0) -> void:
	team_id = sid
	squad_member = member_i

func _nearest_hostile_visible():
	# 先按距离筛，只对最近 2 个做通视射线（避免 O(n) 射线）
	var cands: Array = []
	var vr2: float = Tuning.vision_range * Tuning.vision_range
	var list: Array = []
	list.append_array(get_tree().get_nodes_in_group("player"))
	list.append_array(get_tree().get_nodes_in_group("raider_bots"))
	for n in list:
		if not is_instance_valid(n) or n == self:
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		if n.get("aboard_ship") != null and n.aboard_ship != null:
			continue
		if not _is_hostile_to(n):
			continue
		var d: float = global_position.distance_squared_to(n.global_position)
		if d > vr2:
			continue
		cands.append({"n": n, "d": d})
	if cands.is_empty():
		return null
	cands.sort_custom(func(a, b): return a["d"] < b["d"])
	for i in mini(2, cands.size()):
		var n = cands[i]["n"]
		if _line_clear(n.global_position):
			return n
	return null

func _nearest_enemy_visible():
	var cands: Array = []
	var vr2: float = Tuning.enemy_vision_range * Tuning.enemy_vision_range
	for n in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(n):
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		var d: float = global_position.distance_squared_to(n.global_position)
		if d > vr2:
			continue
		cands.append({"n": n, "d": d})
	if cands.is_empty():
		return null
	cands.sort_custom(func(a, b): return a["d"] < b["d"])
	for i in mini(2, cands.size()):
		var n = cands[i]["n"]
		if _line_clear(n.global_position):
			return n
	return null

func _hostile_near_point(from: Vector2, radius: float):
	var best = null
	var best_d := INF
	var list: Array = []
	list.append_array(get_tree().get_nodes_in_group("player"))
	list.append_array(get_tree().get_nodes_in_group("raider_bots"))
	list.append_array(get_tree().get_nodes_in_group("enemies"))
	for n in list:
		if not is_instance_valid(n) or n == self:
			continue
		if n.has_method("is_dead") and n.is_dead():
			continue
		if not _is_hostile_to(n):
			continue
		var d: float = from.distance_squared_to(n.global_position)
		if d < best_d and d <= radius * radius:
			best_d = d
			best = n
	return best

func _face(pos: Vector2, delta: float) -> void:
	var want := (pos - global_position).normalized()
	if want.length_squared() < 0.01:
		return
	var max_rad := deg_to_rad(420.0) * delta
	aim_dir = aim_dir.rotated(clampf(aim_dir.angle_to(want), -max_rad, max_rad)).normalized()

func _tick_rush(delta: float) -> void:
	# 功利：始终冲向最近尚未被抢完的免保
	var prefer = _nearest_free_safe()
	if prefer != null:
		target_safe = prefer
	if target_safe == null or not is_instance_valid(target_safe):
		state = S.LOOT
		return
	_prepare_wander_budget()
	var safe_pos: Vector2 = (target_safe as Node2D).global_position
	var d := global_position.distance_to(safe_pos)
	if d <= Tuning.interact_range:
		velocity = Vector2.ZERO
		_open_t = 0.0
		_current_goal = Vector2.INF
		_wander_point = Vector2.INF
		state = S.OPEN_SAFE
		return
	if _tick_wander(delta, safe_pos):
		return
	_move_towards(safe_pos, Tuning.walk_speed, delta)

func _prepare_wander_budget() -> void:
	if _rush_budget_ready or target_safe == null:
		return
	_rush_budget_ready = true
	var d: float = global_position.distance_to((target_safe as Node2D).global_position)
	_wander_budget = (d / maxf(Tuning.walk_speed, 1.0)) * 0.1
	_next_wander_roll = _rng.randf_range(1.2, 3.0)

func _tick_wander(delta: float, safe_pos: Vector2) -> bool:
	if _wander_budget <= 0.0 and _wander_point == Vector2.INF:
		return false
	if _wander_point != Vector2.INF:
		_wander_seg_t -= delta
		_wander_budget = maxf(0.0, _wander_budget - delta)
		if _wander_seg_t <= 0.0 or global_position.distance_to(_wander_point) < 36.0:
			_wander_point = Vector2.INF
			_next_wander_roll = _rng.randf_range(2.0, 4.5)
			return false
		_move_towards(_wander_point, Tuning.walk_speed, delta)
		return true
	_next_wander_roll -= delta
	if _next_wander_roll > 0.0 or _wander_budget <= 0.0:
		return false
	_next_wander_roll = _rng.randf_range(2.5, 5.0)
	if _rng.randf() > 0.55:
		return false
	var to := safe_pos - global_position
	if to.length() < 80.0:
		return false
	var side := to.normalized().orthogonal() * (1.0 if _rng.randf() > 0.5 else -1.0)
	var lat: float = _rng.randf_range(90.0, 240.0)
	var fwd: float = _rng.randf_range(40.0, 140.0)
	_wander_point = global_position + side * lat + to.normalized() * fwd
	_wander_seg_t = minf(_wander_budget, _rng.randf_range(1.2, 2.8))
	return false

func _tick_open(delta: float) -> void:
	if target_safe == null or not is_instance_valid(target_safe):
		_abort_search()
		state = S.LOOT
		return
	var d := global_position.distance_to((target_safe as Node2D).global_position)
	if d > Tuning.interact_range * 1.2:
		_abort_search()
		state = S.RUSH_SAFE
		return
	velocity = Vector2.ZERO
	_current_goal = Vector2.INF
	if _active_search != target_safe or _search_phase == SearchPhase.NONE:
		_begin_search(target_safe)
	if _tick_search(target_safe, delta):
		_abort_search()
		target_container = null
		first_safe_done = true
		state = S.LOOT

func _tick_loot(delta: float) -> void:
	# 功利：免保后优先把背包搜满
	if _backpack_nearly_full():
		_abort_search()
		target_container = null
		state = S.ROAM
		return
	if target_container != null and is_instance_valid(target_container):
		var fully: bool = target_container.is_fully_searched() and _container_empty_to_take(target_container)
		if fully and _search_phase == SearchPhase.NONE:
			target_container = null
	if target_container == null or not is_instance_valid(target_container):
		_abort_search()
		_loot_scan_cd -= delta
		if _loot_scan_cd <= 0.0 or _cached_loot == null or not is_instance_valid(_cached_loot):
			_loot_scan_cd = LOOT_SCAN_INTERVAL + _rng.randf_range(0.0, 0.1)
			_cached_loot = _nearest_loot_container()
		target_container = _cached_loot
		if target_container == null:
			var fs = _nearest_free_safe()
			if fs != null and not bool(fs.get("cracked")):
				target_safe = fs
				state = S.RUSH_SAFE
			else:
				state = S.ROAM
			return
	var d := global_position.distance_to(target_container.global_position)
	if d > Tuning.interact_range:
		_abort_search()
		_move_towards(target_container.global_position, Tuning.walk_speed, delta)
		return
	velocity = Vector2.ZERO
	_current_goal = Vector2.INF
	if _active_search != target_container or _search_phase == SearchPhase.NONE:
		_begin_search(target_container)
	if _tick_search(target_container, delta):
		_abort_search()
		target_container = null
		if _backpack_nearly_full():
			state = S.ROAM

func _begin_search(c) -> void:
	_active_search = c
	_search_elapsed = 0.0
	_search_slot = -1
	_take_slot = -1
	if c.is_in_group("free_safe") or str(c.richness) == "L4":
		if str(c.richness) == "L4" and not c.cracked:
			_search_phase = SearchPhase.CRACK
			return
		_vacuum_container(c)
		_search_phase = SearchPhase.TAKE
		return
	if not c.is_fully_searched():
		_search_phase = SearchPhase.REVEAL
		_search_slot = c.next_unsearched_slot()
	else:
		_search_phase = SearchPhase.TAKE
		_take_slot = _next_takeable_slot(c)

## 返回 true = 该容器处理完毕（已搜完且能拿的都拿了/拿不动）
func _tick_search(c, delta: float) -> bool:
	if c == null or not is_instance_valid(c):
		return true
	match _search_phase:
		SearchPhase.CRACK:
			_search_elapsed += delta
			var need_crack: float = Tuning.l4_crack_time * Tuning.ai_search_time_mul
			if _search_elapsed < need_crack:
				return false
			c.cracked = true
			_vacuum_container(c)
			first_safe_done = true
			_search_elapsed = 0.0
			return true
		SearchPhase.REVEAL:
			if _search_slot < 0:
				_search_slot = c.next_unsearched_slot()
			if _search_slot < 0:
				_search_phase = SearchPhase.TAKE
				_take_slot = _next_takeable_slot(c)
				_search_elapsed = 0.0
				return false
			_search_elapsed += delta
			var need_slot: float = Tuning.search_time_per_slot \
					* GameData.search_time_mul(str(c.richness)) \
					* Tuning.ai_search_time_mul
			if _search_elapsed < need_slot:
				return false
			c.reveal_slot(_search_slot)
			_search_elapsed = 0.0
			# 本格有货 → 先装包再搜下一格（对齐“搜到就捡”）
			if not c.slots[_search_slot].is_empty() and not c.taken[_search_slot]:
				_take_slot = _search_slot
				_search_phase = SearchPhase.TAKE
			else:
				_search_slot = c.next_unsearched_slot()
				if _search_slot < 0:
					_search_phase = SearchPhase.TAKE
					_take_slot = _next_takeable_slot(c)
			return false
		SearchPhase.TAKE:
			if _take_slot < 0:
				_take_slot = _next_takeable_slot(c)
			if _take_slot < 0:
				if not c.is_fully_searched():
					_search_phase = SearchPhase.REVEAL
					_search_slot = c.next_unsearched_slot()
					_search_elapsed = 0.0
					return false
				return true
			_search_elapsed += delta
			if _search_elapsed < Tuning.ai_take_time_per_item:
				return false
			_search_elapsed = 0.0
			var took: bool = _try_take_slot(c, _take_slot)
			var prev_take: int = _take_slot
			_take_slot = -1
			if not took:
				# 背包装不下：跳过该格，找下一件；若都装不下则放弃本箱
				_take_slot = _next_takeable_after(c, prev_take)
				if _take_slot < 0:
					return true
				return false
			if not c.is_fully_searched():
				_search_phase = SearchPhase.REVEAL
				_search_slot = c.next_unsearched_slot()
			else:
				_take_slot = _next_takeable_slot(c)
				if _take_slot < 0:
					return true
			return false
	return true

func _next_takeable_slot(c) -> int:
	return _next_takeable_after(c, -1)

func _next_takeable_after(c, after_idx: int) -> int:
	c.slot_count()
	for i in c.slots.size():
		if i <= after_idx:
			continue
		if c.revealed.size() > i and c.revealed[i] \
				and not c.taken[i] and not c.slots[i].is_empty():
			return i
	return -1

func _container_empty_to_take(c) -> bool:
	return _next_takeable_slot(c) < 0

func _try_take_slot(c, idx: int) -> bool:
	if c.take_locked:
		return false
	if idx < 0 or idx >= c.slots.size():
		return false
	if not c.revealed[idx] or c.taken[idx] or c.slots[idx].is_empty():
		return false
	var id: String = str(c.slots[idx].get("id", ""))
	if id == "":
		return false
	if inv != null:
		if c.is_in_group("free_safe") or str(c.richness) == "L4":
			inv.grant_no_weight(id)
		elif not inv.add_auto(id):
			return false
	c.take_slot(idx)
	_loot_value += int(GameData.item(id).get("value", 0))
	return true

## 免保 / 远距开箱：破解完就把箱子里的东西装进背包。
## 旧逻辑只标 cracked，物品仍留在柜里，打死 AI 尸体包是空的。
func _vacuum_container(c) -> void:
	if c == null or not is_instance_valid(c):
		return
	if c.has_method("reveal_all"):
		c.reveal_all()
	c.cracked = true
	if inv == null:
		return
	c.slot_count()
	for i in c.slots.size():
		if i >= c.revealed.size() or i >= c.taken.size():
			continue
		if c.taken[i] or c.slots[i].is_empty():
			continue
		var id: String = str(c.slots[i].get("id", ""))
		if id == "":
			continue
		inv.grant_no_weight(id)
		c.take_slot(i)
		_loot_value += int(GameData.item(id).get("value", 0))

func _tick_roam(delta: float) -> void:
	# 背包未满继续搜；满了则游荡（交战仍由 COMBAT 优先）
	if not _backpack_nearly_full():
		target_container = _nearest_loot_container()
		if target_container != null:
			state = S.LOOT
			return
		var fs = _nearest_free_safe()
		if fs != null and not bool(fs.get("cracked")):
			target_safe = fs
			state = S.RUSH_SAFE
			return
	if target_safe != null and is_instance_valid(target_safe):
		_move_towards((target_safe as Node2D).global_position + Vector2(_rng.randf_range(-160, 160), _rng.randf_range(-160, 160)),
			Tuning.walk_speed, delta)
	else:
		var dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		_move_towards(global_position + dir * 220.0, Tuning.walk_speed, delta)

func _backpack_nearly_full() -> bool:
	if inv == null:
		return false
	return inv.used_cells() >= int(ceil(float(inv.capacity()) * 0.88))

# ── 绕障移动 ───────────────────────────────────────────
func _move_towards(goal: Vector2, speed: float, delta: float) -> void:
	_current_goal = goal
	var to := goal - global_position
	var dist: float = to.length()
	if dist < 4.0:
		velocity = velocity.move_toward(Vector2.ZERO, Tuning.decel * delta)
		_wall_follow = 0
		_detour = Vector2.INF
		return
	var dir := to.normalized()
	_detour_t = maxf(0.0, _detour_t - delta)
	# 直达：前方短探无墙。贴墙时探针会抖，连续通畅才退出沿墙。
	if _path_clear(dir, minf(PROBE_LEN, dist)):
		_clear_streak += delta
		if _wall_follow == 0 or _clear_streak >= 0.20:
			_wall_follow = 0
			_detour = Vector2.INF
			_clear_streak = 0.0
			velocity = velocity.move_toward(dir * speed, Tuning.accel * delta)
			return
	else:
		_clear_streak = 0.0
	# 隔墙：先找能看见目标或更接近目标的旁路点，避免贴着房间外墙空转
	if _detour != Vector2.INF and _detour_t > 0.0 \
			and global_position.distance_to(_detour) > 22.0:
		var dd: Vector2 = (_detour - global_position).normalized()
		if _path_clear(dd):
			velocity = velocity.move_toward(dd * speed, Tuning.accel * delta)
			return
		_detour = Vector2.INF
	if _detour == Vector2.INF or _detour_t <= 0.0:
		_detour = _pick_detour(goal)
		_detour_t = 1.25
	if _detour != Vector2.INF:
		var ddir: Vector2 = (_detour - global_position).normalized()
		_wall_follow = 0
		velocity = velocity.move_toward(ddir * speed, Tuning.accel * delta)
		return
	if _wall_follow == 0:
		_wall_follow = _choose_wall_side(dir)
	var follow := _probe_free_dir(dir, _wall_follow)
	velocity = velocity.move_toward(follow * speed, Tuning.accel * delta)

func _pick_detour(goal: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_score := INF
	var here_d: float = global_position.distance_to(goal)
	for i in 16:
		var ang: float = TAU * float(i) / 16.0
		for r in [64.0, 110.0, 160.0]:
			var cand: Vector2 = global_position + Vector2.RIGHT.rotated(ang) * r
			if _ray_blocked(global_position, cand):
				continue
			var see: bool = not _ray_blocked(cand, goal)
			var d: float = cand.distance_to(goal)
			if not see and d >= here_d - 12.0:
				continue
			var score: float = d
			if see:
				score -= 320.0
			if score < best_score:
				best_score = score
				best = cand
	return best

func _ray_blocked(from: Vector2, to: Vector2) -> bool:
	if from.distance_squared_to(to) < 4.0:
		return false
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(from, to)
	q.collision_mask = 1 << 0
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return false
	var col = hit.get("collider")
	if col != null and col.is_in_group("poi_gates") and col.has_method("open"):
		return not bool(col.open())
	return true

func _path_clear(dir: Vector2, dist: float = PROBE_LEN) -> bool:
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(
		global_position, global_position + dir * dist)
	q.collision_mask = 1 << 0
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	var col = hit.get("collider")
	if col != null and col.is_in_group("poi_gates") and col.has_method("open"):
		return bool(col.open())
	return false

func _choose_wall_side(base: Vector2) -> int:
	var best_side := 1
	var best_step := 999.0
	for sg in [1, -1]:
		for step in PROBE_ANGLES:
			if _path_clear(base.rotated(deg_to_rad(step * sg))):
				if step < best_step:
					best_step = step
					best_side = sg
				break
	return best_side

func _probe_free_dir(base: Vector2, sign_dir: int) -> Vector2:
	for step in PROBE_ANGLES:
		var cand := base.rotated(deg_to_rad(step * sign_dir))
		if _path_clear(cand):
			return cand
	for step in PROBE_ANGLES:
		var cand2 := base.rotated(deg_to_rad(step * -sign_dir))
		if _path_clear(cand2):
			_wall_follow = -sign_dir
			return cand2
	return -base

func _track_stuck(delta: float) -> void:
	if _current_goal == Vector2.INF or state == S.COMBAT:
		_nav_stuck = 0.0
		_progress_timer = 0.0
		return
	_progress_timer += delta
	if _progress_timer < CHECK_WINDOW:
		return
	_progress_timer = 0.0
	var d: float = global_position.distance_to(_current_goal)
	if _last_goal_dist < 0.0:
		_last_goal_dist = d
		return
	var gained: float = _last_goal_dist - d
	_last_goal_dist = d
	var need: float = Tuning.walk_speed * CHECK_WINDOW * MIN_PROGRESS_RATIO
	if gained < need:
		_nav_stuck += CHECK_WINDOW
	else:
		_nav_stuck = maxf(0.0, _nav_stuck - CHECK_WINDOW)
		_stuck_flips = 0
	if _nav_stuck >= STUCK_GIVEUP:
		_nav_stuck = 0.0
		_last_goal_dist = -1.0
		_wall_follow = (_wall_follow if _wall_follow != 0 else 1) * -1
		_detour = Vector2.INF
		_detour_t = 0.0
		_stuck_flips += 1
		if _stuck_flips >= 3:
			_nudge_out_of_wall()
			_stuck_flips = 0
			if state == S.LOOT:
				target_container = null
			elif state == S.RUSH_SAFE:
				_nudge_toward_open_side()

func _nudge_out_of_wall() -> void:
	for ang in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]:
		var dir := Vector2.RIGHT.rotated(deg_to_rad(ang))
		if _path_clear(dir, 70.0):
			global_position += dir * 48.0
			return
	global_position += Vector2.RIGHT.rotated(_rng.randf() * TAU) * 80.0

func _nudge_toward_open_side() -> void:
	if target_safe == null or not is_instance_valid(target_safe):
		return
	var safe_pos: Vector2 = (target_safe as Node2D).global_position
	var away: Vector2 = (global_position - safe_pos).normalized()
	if away.length_squared() < 0.01:
		away = Vector2.RIGHT.rotated(_rng.randf() * TAU)
	global_position += away * 90.0

func _nearest_free_safe():
	var best = null
	var best_d := INF
	var best_any = null
	var best_any_d := INF
	for n in get_tree().get_nodes_in_group("free_safe"):
		if not is_instance_valid(n):
			continue
		var d := global_position.distance_squared_to(n.global_position)
		if d < best_any_d:
			best_any_d = d
			best_any = n
		# 优先抢还没被开完的免保
		if bool(n.get("cracked")) and n.is_fully_searched() and _container_empty_to_take(n):
			continue
		if d < best_d:
			best_d = d
			best = n
	return best if best != null else best_any

func _nearest_loot_container():
	# 先按距离/富度粗排，只对前几名做通视，避免扫完全图箱子
	var cands: Array = []
	for n in get_tree().get_nodes_in_group("containers"):
		if not is_instance_valid(n):
			continue
		if n.is_fully_searched() and _container_empty_to_take(n):
			continue
		if n.get("take_locked") == true:
			continue
		var dist := global_position.distance_squared_to(n.global_position)
		if dist > 1800.0 * 1800.0:
			continue
		var rich := str(n.richness)
		var w := 1.0
		if rich == "L4":
			w = 0.35
		elif rich == "L3":
			w = 0.55
		elif rich == "L2":
			w = 0.8
		cands.append({"n": n, "score": dist * w, "dist": dist})
	if cands.is_empty():
		return null
	cands.sort_custom(func(a, b): return a["score"] < b["score"])
	for i in mini(5, cands.size()):
		var n = cands[i]["n"]
		if _line_clear(n.global_position):
			return n
	return cands[0]["n"]

func _line_clear(to: Vector2) -> bool:
	var q := PhysicsRayQueryParameters2D.create(global_position, to)
	q.collision_mask = 1 << 0
	q.exclude = [get_rid()]
	var hit := get_world_2d().direct_space_state.intersect_ray(q)
	return hit.is_empty()

func set_perceived(v: bool) -> void:
	if _is_local_ally():
		visible = true
		_perceive_hold = 2
		return
	if Tuning.show_enemy_players:
		visible = true
		_perceive_hold = 2
		return
	if v:
		_perceive_hold = 2
		visible = true
	else:
		_perceive_hold -= 1
		if _perceive_hold <= 0:
			visible = false

func _draw() -> void:
	var col := Color(0.95, 0.35, 0.32)
	# 玩家小队（team 0）用绿色区分友军
	if team_id == 0:
		col = Color(0.35, 0.92, 0.55)
	if state == S.COMBAT:
		col = Color(1.0, 0.2, 0.15) if team_id != 0 else Color(0.2, 0.85, 0.45)
	elif state == S.RUSH_SAFE or state == S.OPEN_SAFE:
		col = Color(1.0, 0.78, 0.28) if team_id != 0 else Color(0.55, 1.0, 0.65)
	elif state == S.CONTRACT:
		col = Color(0.45, 0.92, 1.0) if team_id != 0 else Color(0.55, 1.0, 0.75)
	elif state == S.DEAD:
		col = Color(0.35, 0.35, 0.38)
	draw_circle(Vector2.ZERO, RADIUS + 1.4, Color(0.05, 0.08, 0.1, 0.85))
	draw_circle(Vector2.ZERO, RADIUS, col)
	var tip := Vector2(RADIUS + 7, 0)
	draw_colored_polygon(PackedVector2Array([tip, Vector2(RADIUS * 0.2, -4), Vector2(RADIUS * 0.2, 4)]),
		Color(0.95, 1.0, 1.0, 0.95))
	draw_string(ThemeDB.fallback_font, Vector2(-38, -24), _name_tag,
		HORIZONTAL_ALIGNMENT_LEFT, 90, 12, Color(1.0, 0.92, 0.55))
	if health != null and not health.dead:
		var bw := 28.0
		var ratio: float = health.ratio()
		draw_rect(Rect2(Vector2(-bw * 0.5, -RADIUS - 10), Vector2(bw, 3)), Color(0.1, 0.1, 0.12, 0.8))
		draw_rect(Rect2(Vector2(-bw * 0.5, -RADIUS - 10), Vector2(bw * ratio, 3)), Color(0.9, 0.25, 0.2))
	if Tuning.show_enemy_debug:
		var bag_v: int = inv.total_value() if inv != null else _loot_value
		draw_string(ThemeDB.fallback_font, Vector2(-28, -10), "¥%d" % bag_v,
			HORIZONTAL_ALIGNMENT_LEFT, 72, 11, Color(0.75, 0.9, 1.0))
	# 搜刮读条提示
	if _search_phase != SearchPhase.NONE and state != S.DEAD:
		var tag := "破解中" if _search_phase == SearchPhase.CRACK \
				else ("搜刮中" if _search_phase == SearchPhase.REVEAL else "装包中")
		draw_string(ThemeDB.fallback_font, Vector2(-24, RADIUS + 14), tag,
			HORIZONTAL_ALIGNMENT_LEFT, 72, 10, Color(1.0, 0.85, 0.4))
