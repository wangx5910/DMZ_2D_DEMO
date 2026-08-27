extends CharacterBody2D
## Grunt · 持枪小兵（照《逃离鸭科夫》复刻）
##
## 与玩家的对等性（大锤指定）：
##   - **移速相同**（走/跑用同一套 Tuning 数值）
##   - **体型相同**（碰撞半径 11）
##   - **同样持枪**（grunt_rifle，射速更慢、扩散更大）
##   - **血量按系数远低于玩家**（enemy_hp_mul，默认 0.45）
##   - **伤害按系数远低于玩家**（enemy_damage_mul，默认 0.30）
##   → 难度差异来自"打得没你准、血没你厚"，而不是数值碾压。
##
## 行为树（显式状态机，比节点式行为树更好调试——状态能直接打在头顶）：
##
##   PATROL ──发现──> ALERT ──确认──> CHASE ──进入射程──> ENGAGE
##      ↑                │                │                 │
##      │             丢失目标            丢失视野          丢失视野
##      │                ↓                ↓                 ↓
##      └──── 超时/超距 ── SEARCH（去最后已知位置找） ────────┘
##
##   任何状态听到枪声 → INVESTIGATE（去查看声源）
##
## 追击规则（照鸭科夫）：
##   - 视野内 → 持续追击，不会走两步就忘
##   - 脱离视野 → 仍追 enemy_chase_lose_time 秒（去最后已知位置）
##   - 超出 enemy_chase_max_range 或离岗位太远 → 放弃，返回岗位
##
## 联机预留：位置/朝向/状态/HP 为需同步字段（TODO_NET）。AI 只在权威端跑。

signal died(pos: Vector2)
signal state_changed(state: State)

enum State { PATROL, ALERT, CHASE, ENGAGE, SEARCH, INVESTIGATE, RETURN, DEAD }

const RADIUS := 11.0
const HitscanScript := preload("res://scripts/combat/hitscan.gd")

var state: State = State.PATROL
var health: Health
var weapon: Weapon
var inv: GridInventory = null

var aim_dir := Vector2.RIGHT          ## TODO_NET
var post := Vector2.ZERO              ## 岗位（出生点），放弃追击后返回
var patrol_points: Array[Vector2] = []
var _patrol_index := 0
var _patrol_wait := 0.0

## 目标与记忆
var target = null                     ## 当前目标（玩家）
var last_known_pos := Vector2.ZERO    ## 目标最后出现的位置
var _notice_timer := 0.0              ## 察觉累积（进入视野后要持续一段才算发现）
var _lose_timer := 0.0                ## 脱离视野后的追击倒计时
var _search_timer := 0.0
var _investigate_pos := Vector2.ZERO

## 交战微移动
var _strafe_dir := 0                  ## -1 / 0 / 1
var _strafe_timer := 0.0
var _fire_burst_left := 0             ## 当前点射剩余发数
var _fire_pause := 0.0                ## 点射间隔

var _fx = null
var world = null
var _rng := RandomNumberGenerator.new()
var _nav_stuck := 0.0
var _last_pos := Vector2.ZERO
var _detour_dir := 0                  ## 撞墙时的绕行方向
var _nav_giveups := 0                 ## 连续放弃导航的次数
var _wall_follow := 0                 ## 沿墙行走的旋向（0 = 不在沿墙模式）
var _detour_timer := 0.0              ## 当前旋向的保持计时
var _progress_timer := 0.0            ## 进展采样窗口计时
var _last_goal_dist := -1.0           ## 上一次采样时到目标的距离

const PROBE_LEN := 52.0               ## 绕行探测射线长度（略大于体型+余量）
const PROBE_ANGLES := [30.0, 55.0, 80.0, 105.0, 130.0, 155.0]
const WALL_FOLLOW_HOLD := 0.9         ## 沿墙旋向保持时长（防左右横跳）
const CHECK_WINDOW := 0.6             ## 进展采样窗口（秒）
const MIN_PROGRESS_RATIO := 0.25      ## 一个窗口至少要逼近理论距离的这个比例
const STUCK_GIVEUP := 1.8             ## 累计卡这么久就换目标（秒）

func setup(spawn_pos: Vector2, fx, patrol: Array[Vector2] = [], w = null) -> void:
	global_position = spawn_pos
	post = spawn_pos
	_fx = fx
	world = w
	patrol_points = patrol
	_last_pos = spawn_pos

func _ready() -> void:
	_rng.randomize()
	add_to_group("enemies")
	add_to_group("vision_gated")
	collision_layer = 1 << 4          # enemy 层
	collision_mask = 1 << 0           # 只和世界墙体碰撞（彼此不挤，避免卡住）
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	z_index = 9

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	shape.shape = circle
	add_child(shape)

	health = Health.new(Tuning.player_hp_max * Tuning.enemy_hp_mul)
	health.died.connect(_on_died)

	weapon = Weapon.new("grunt_rifle")
	_seed_backpack()

	if post == Vector2.ZERO:
		post = global_position
	if _last_pos == Vector2.ZERO:
		_last_pos = global_position
	_pick_new_strafe()
	call_deferred("unstick_from_walls")

func _seed_backpack() -> void:
	inv = GridInventory.new(5, 4)
	var n: int = _rng.randi_range(1, 3)
	for _i in n:
		var id: String = GameData.random_loot_id({"green": 60, "blue": 28, "purple": 10, "gold": 2})
		if id == "":
			continue
		inv.add_auto(id)

# ── 主循环 ──────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return
	if not NetHub.is_authority():
		return   # TODO_NET: AI 只在权威端跑，客户端由同步驱动

	# 远处 POI 会关掉墙碰撞；此时再走就会穿进墙格，玩家靠近后嵌死。
	if world != null and world.has_method("poi_walls_on_at") and not world.poi_walls_on_at(global_position):
		velocity = Vector2.ZERO
		return

	# 远距降频：离玩家远的小兵少跑感知/状态机
	var frame: int = Engine.get_physics_frames()
	var slot: int = abs(get_instance_id()) % 6
	var ppos := Vector2.INF
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0 and is_instance_valid(players[0]):
		ppos = players[0].global_position
	var d2: float = global_position.distance_squared_to(ppos) if ppos != Vector2.INF else 0.0
	if d2 > 2200.0 * 2200.0 and state in [State.PATROL, State.RETURN, State.SEARCH]:
		if frame % 6 != slot:
			return
		delta *= 6.0
	elif d2 > 1200.0 * 1200.0 and state == State.PATROL:
		if frame % 3 != (slot % 3):
			move_and_slide()
			return
		delta *= 3.0

	if frame % 24 == slot:
		unstick_from_walls()

	if weapon != null:
		# 无限备弹：小兵不该因为没子弹而变哑巴（跑测关注的是行为，不是弹药管理）
		weapon.reserve = weapon.reserve_max()
		weapon.tick(delta, state == State.ENGAGE, 0)

	_sense(delta)
	_tick_state(delta)
	move_and_slide()
	_track_stuck(delta)
	if Tuning.show_enemy_debug:
		queue_redraw()

## 感知：视野扇形 + 墙体遮挡（玩家与掠夺者 AI 同等敌对目标）
func _sense(delta: float) -> void:
	var p = _find_hostile()
	if p == null:
		if target != null and is_instance_valid(target) \
				and target.get("aboard_ship") != null and target.aboard_ship != null:
			target = null
			_notice_timer = 0.0
			if state in [State.ALERT, State.CHASE, State.ENGAGE]:
				_set_state(State.SEARCH)
		return

	var visible_now := _can_see(p.global_position)
	if visible_now:
		target = p
		last_known_pos = p.global_position
		_lose_timer = Tuning.enemy_chase_lose_time
		_notice_timer += delta
	else:
		_notice_timer = maxf(0.0, _notice_timer - delta * 1.5)
		if _lose_timer > 0.0:
			_lose_timer -= delta

	# 察觉确认 → 进入战斗链
	if visible_now and _notice_timer >= Tuning.enemy_notice_time:
		if state in [State.PATROL, State.INVESTIGATE, State.RETURN, State.SEARCH]:
			_set_state(State.ALERT)

## 能否看到某点（扇形 + 距离 + 墙体遮挡）
func _can_see(pos: Vector2) -> bool:
	var to := pos - global_position
	var d := to.length()
	if d > Tuning.enemy_vision_range:
		return false
	if rad_to_deg(absf(aim_dir.angle_to(to))) > Tuning.enemy_fov_half_angle:
		return false
	# 墙体遮挡
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(global_position, pos)
	q.collision_mask = 1 << 0
	q.exclude = [get_rid()]
	return space.intersect_ray(q).is_empty()

## 最近敌对目标：真人玩家 + 掠夺者 AI（距离优先；视野由 _can_see 判定）
func _find_hostile():
	# 保持当前目标，避免丢视野时被清掉导致追击链断裂
	if target != null and is_instance_valid(target):
		if not (target.has_method("is_dead") and target.is_dead()):
			if target.get("aboard_ship") == null or target.aboard_ship == null:
				if target.is_in_group("player") or target.is_in_group("raider_bots"):
					return target
	var best = null
	var best_d := INF
	var list: Array = []
	list.append_array(get_tree().get_nodes_in_group("player"))
	list.append_array(get_tree().get_nodes_in_group("raider_bots"))
	for p in list:
		if not is_instance_valid(p):
			continue
		if p.has_method("is_dead") and p.is_dead():
			continue
		if p.get("aboard_ship") != null and p.aboard_ship != null:
			continue
		var d: float = global_position.distance_squared_to(p.global_position)
		if d > Tuning.enemy_vision_range * Tuning.enemy_vision_range:
			continue
		if d < best_d:
			best_d = d
			best = p
	return best

# ── 状态机 ──────────────────────────────────────────────
func _set_state(s: State) -> void:
	if state == s:
		return
	state = s
	# 换状态 = 换目标，进展记录必须重置，否则用旧距离比会立刻误判卡住
	_last_goal_dist = -1.0
	_progress_timer = 0.0
	_wall_follow = 0
	state_changed.emit(s)
	queue_redraw()   # 状态色/血条变化立即刷新（调试关时也可见）
	match s:
		State.SEARCH:
			_search_timer = Tuning.enemy_chase_lose_time
		State.ENGAGE:
			_pick_new_strafe()

func _tick_state(delta: float) -> void:
	match state:
		State.PATROL:      _do_patrol(delta)
		State.ALERT:       _do_alert(delta)
		State.CHASE:       _do_chase(delta)
		State.ENGAGE:      _do_engage(delta)
		State.SEARCH:      _do_search(delta)
		State.INVESTIGATE: _do_investigate(delta)
		State.RETURN:      _do_return(delta)

## 巡逻：在预设点之间慢走，到点后停一会儿再走（不是无脑绕圈）
func _do_patrol(delta: float) -> void:
	if patrol_points.is_empty():
		_face_idle(delta)
		velocity = velocity.move_toward(Vector2.ZERO, Tuning.decel * delta)
		return
	if _patrol_wait > 0.0:
		_patrol_wait -= delta
		# 站定时缓慢扫视，模拟警戒（也让玩家有机会绕后）
		_face_idle(delta)
		velocity = velocity.move_toward(Vector2.ZERO, Tuning.decel * delta)
		return

	var goal: Vector2 = patrol_points[_patrol_index]
	if global_position.distance_to(goal) < 26.0:
		_nav_giveups = 0
		_last_goal_dist = -1.0
		_wall_follow = 0
		_patrol_index = (_patrol_index + 1) % patrol_points.size()
		_patrol_wait = _rng.randf_range(Tuning.enemy_patrol_wait_min, Tuning.enemy_patrol_wait_max)
		return
	_move_towards(goal, Tuning.walk_speed, delta)
	# 巡逻中视野朝向跟随巡逻路径（照鸭科夫：AI 行进时视线跟着走，不是永远朝出生点）
	_face(goal, delta, 5.0)

## 警觉：短暂停顿转向目标（给玩家反应窗口），然后转入追击
func _do_alert(delta: float) -> void:
	if target == null:
		_set_state(State.PATROL)
		return
	_face(last_known_pos, delta, 9.0)
	velocity = velocity.move_toward(Vector2.ZERO, Tuning.decel * delta)
	if _notice_timer >= Tuning.enemy_notice_time + 0.2:
		_set_state(State.CHASE)

## 追击：跑向目标。进入射程转交战；丢失视野转搜索；超距/离岗太远则放弃
func _do_chase(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		_set_state(State.SEARCH)
		return
	var d := global_position.distance_to(target.global_position)
	if d > Tuning.enemy_chase_max_range or global_position.distance_to(post) > Tuning.enemy_leash_from_post:
		# 放弃条件（照鸭科夫：超出一定范围停止追击）
		target = null
		_set_state(State.RETURN)
		return
	if not _can_see(target.global_position):
		if _lose_timer <= 0.0:
			_set_state(State.SEARCH)
			return
	elif d <= Tuning.enemy_engage_range:
		_set_state(State.ENGAGE)
		return
	_move_towards(last_known_pos, Tuning.walk_speed, delta)
	_face(last_known_pos, delta, 10.0)

## 交战：保持距离带内、边打边挪、开火
func _do_engage(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		_set_state(State.SEARCH)
		return
	var tpos: Vector2 = target.global_position
	var d := global_position.distance_to(tpos)
	var see := _can_see(tpos)
	if not see:
		if _lose_timer <= 0.0:
			_set_state(State.SEARCH)
		else:
			_set_state(State.CHASE)
		return
	if d > Tuning.enemy_engage_range * 1.25:
		_set_state(State.CHASE)
		return

	_face(tpos, delta, 12.0)

	# 距离带：太近后退、太远推进、带内横向游走
	var to := (tpos - global_position).normalized()
	var desired := Vector2.ZERO
	if d < Tuning.enemy_engage_min:
		desired = -to * Tuning.walk_speed              # 后退
	elif d > Tuning.enemy_engage_range * 0.85:
		desired = to * Tuning.walk_speed                # 推进
	else:
		# 带内：横向 strafe（照鸭科夫，边打边挪不站桩）
		_strafe_timer -= delta
		if _strafe_timer <= 0.0:
			_pick_new_strafe()
		desired = to.orthogonal() * float(_strafe_dir) * Tuning.walk_speed
	velocity = velocity.move_toward(desired, Tuning.accel * delta)

	_try_shoot(delta, tpos)

## 搜索：去最后已知位置找，找不到就放弃返回
func _do_search(delta: float) -> void:
	_search_timer -= delta
	if _search_timer <= 0.0:
		target = null
		_set_state(State.RETURN)
		return
	if global_position.distance_to(last_known_pos) < 34.0:
		# 到了但没人 —— 原地扫视
		_face_idle(delta)
		velocity = velocity.move_toward(Vector2.ZERO, Tuning.decel * delta)
		return
	_move_towards(last_known_pos, Tuning.walk_speed, delta)
	_face(last_known_pos, delta, 8.0)

## 查看：被枪声吸引，走过去看
func _do_investigate(delta: float) -> void:
	if global_position.distance_to(_investigate_pos) < 40.0:
		_set_state(State.RETURN)
		return
	if global_position.distance_to(post) > Tuning.enemy_leash_from_post:
		_set_state(State.RETURN)
		return
	_move_towards(_investigate_pos, Tuning.walk_speed, delta)
	_face(_investigate_pos, delta, 8.0)

## 返回岗位
func _do_return(delta: float) -> void:
	if global_position.distance_to(post) < 40.0:
		_set_state(State.PATROL)
		return
	_move_towards(post, Tuning.walk_speed, delta)
	_face(post, delta, 7.0)

# ── 开火 ────────────────────────────────────────────────
## 点射而不是无脑长按：给玩家换弹/转移的窗口，也更像人
func _try_shoot(delta: float, tpos: Vector2) -> void:
	if not (Tuning.enemy_can_shoot and Tuning.enable_shooting) or weapon == null:
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
		_fire_burst_left = _rng.randi_range(
			int(weapon.def.get("burst_min", 3)), int(weapon.def.get("burst_max", 6)))

	var muzzle := global_position + aim_dir * 16.0
	if weapon.try_fire(true, muzzle, aim_dir, 0, true):
		_fire_burst_left -= 1
		_shoot_ray(muzzle)
		if _fire_burst_left <= 0:
			_fire_pause = _rng.randf_range(
				float(weapon.def.get("burst_pause_min", 0.45)),
				float(weapon.def.get("burst_pause_max", 1.1)))

func _shoot_ray(muzzle: Vector2) -> void:
	var spread: float = weapon.effective_spread(0)
	var dir := weapon.roll_direction(aim_dir, spread, _rng)
	var hit: Dictionary = HitscanScript.query(get_world_2d(), global_position, dir, weapon.range_px(), self)
	var end: Vector2 = hit["position"]
	var who = hit.get("collider")
	if who != null and (who.is_in_group("player") or who.is_in_group("raider_bots") \
			or who.is_in_group("vehicles")):
		var dmg: float = weapon.damage_at(global_position.distance_to(end)) * Tuning.enemy_damage_mul
		if who.is_in_group("raider_bots"):
			dmg *= Tuning.monster_vs_ai_mul
		if dmg > 0.0 and who.has_method("take_damage"):
			who.take_damage(dmg, global_position)
			if _fx != null:
				_fx.add_spark(end, Vector2.ZERO)
	elif bool(hit.get("blocked", false)) and _fx != null:
		_fx.add_spark(end, hit.get("normal", Vector2.ZERO))
	if _fx != null:
		_fx.add_tracer(muzzle, end, weapon.bullet_speed())
		_fx.add_muzzle(muzzle, aim_dir)

# ── 被打 ────────────────────────────────────────────────
func take_damage(amount: float, from: Vector2) -> void:
	if state == State.DEAD:
		return
	health.apply_damage(amount, from)
	if state == State.DEAD:
		return
	# 被打了但没看见人 → 朝来向搜索（不能站着挨枪）
	if state in [State.PATROL, State.INVESTIGATE, State.RETURN]:
		last_known_pos = from
		_notice_timer = Tuning.enemy_notice_time
		_lose_timer = Tuning.enemy_chase_lose_time
		_set_state(State.CHASE)

## 听到枪声（由射击方广播）
func hear_gunshot(pos: Vector2) -> void:
	if state in [State.CHASE, State.ENGAGE, State.ALERT, State.DEAD]:
		return
	if global_position.distance_to(pos) > Tuning.enemy_hearing_range:
		return
	_investigate_pos = pos
	_set_state(State.INVESTIGATE)

func _on_died(from: Vector2) -> void:
	_set_state(State.DEAD)
	velocity = Vector2.ZERO
	collision_layer = 0
	collision_mask = 0
	remove_from_group("enemies")
	_drop_corpse_bag()
	RaidLog.bump("enemies_killed")
	RaidLog.log_event("enemy_killed", {"pos": [int(global_position.x), int(global_position.y)]})
	died.emit(global_position)
	queue_redraw()
	# 留一具尸体作为"这里打过架"的信息（照搜打撤：尸体是情报）
	set_physics_process(false)

func _drop_corpse_bag() -> void:
	var ids: Array = inv.item_ids() if inv != null else []
	var pos := global_position + Vector2(14, 8)
	var world = _find_world_with_bags()
	if world != null:
		world.spawn_corpse_bag(pos, ids, "小兵背包")
		return
	var bag := Area2D.new()
	bag.set_script(load("res://scripts/world/loot_container.gd"))
	var parent := get_parent()
	if parent != null:
		parent.add_child(bag)
	else:
		get_tree().current_scene.add_child(bag)
	bag.global_position = pos
	bag.setup_corpse_bag(ids, "小兵背包", "L2")

func _find_world_with_bags():
	var n = get_parent()
	while n != null:
		if n.has_method("spawn_corpse_bag"):
			return n
		n = n.get_parent()
	return null

func is_dead() -> bool:
	return state == State.DEAD

# ── 移动辅助 ────────────────────────────────────────────
## 朝目标移动。本版不做 A*，用「射线探测 + 有记忆的沿墙行走」代替。
##
## 为什么需要"有记忆"：`move_and_slide` 会让角色沿墙侧滑，所以**速度和位移都是满的**，
## 只看"位移够不够"永远检测不到卡住 —— 它其实在贴着墙原地打圈。
## v0.4 的 bug 就是这样：`_nav_stuck` 一直是 0%，但 5 秒只前进了 30px。
## 正确判据是「朝目标的**净进展**」，见 `_track_stuck`。
func _move_towards(goal: Vector2, speed: float, delta: float) -> void:
	var to := goal - global_position
	if to.length() < 4.0:
		velocity = velocity.move_toward(Vector2.ZERO, Tuning.decel * delta)
		_wall_follow = 0
		return
	var dir := to.normalized()

	# 1) 直线通畅 → 直走，并结束沿墙模式
	if _path_clear(dir):
		_wall_follow = 0
		_detour_timer = 0.0
		velocity = velocity.move_toward(dir * speed, Tuning.accel * delta)
		return

	# 2) 前方有墙 → 沿墙走。**一旦选定旋向就保持不动**，直到绕过去（_path_clear 重新为真）
	#    或彻底卡死（_on_navigation_giveup 翻到另一侧再试）。
	#    之前的 bug：每 0.9 秒重选旋向，贴墙时左右横跳、永远绕不过去。
	if _wall_follow == 0:
		_wall_follow = _choose_wall_side(dir)
	_detour_timer = WALL_FOLLOW_HOLD

	var follow := _probe_free_dir(dir, _wall_follow)
	velocity = velocity.move_toward(follow * speed, Tuning.accel * delta)

## 朝某方向一段距离内是否无墙
func _path_clear(dir: Vector2, dist: float = PROBE_LEN) -> bool:
	var space := get_world_2d().direct_space_state
	var q := PhysicsRayQueryParameters2D.create(
		global_position, global_position + dir * dist)
	q.collision_mask = 1 << 0
	q.exclude = [get_rid()]
	return space.intersect_ray(q).is_empty()

## 选沿墙旋向：两侧各探一次，选"能更快绕开"的那侧（探到通路所需偏转角更小）。
## 随机选旋向的问题是可能选到墙更长的那一侧，绕一大圈甚至绕不出来。
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

## 沿一个旋向逐步加大偏转角，找第一个前方无墙的方向。
## 全试完还是撞墙 → 直接回头（一定能脱离墙面）。
func _probe_free_dir(base: Vector2, sign_dir: int) -> Vector2:
	for step in PROBE_ANGLES:
		var cand := base.rotated(deg_to_rad(step * sign_dir))
		if _path_clear(cand):
			return cand
	# 该侧全堵 → 试另一侧（可能是走进了死胡同）
	for step in PROBE_ANGLES:
		var cand2 := base.rotated(deg_to_rad(step * -sign_dir))
		if _path_clear(cand2):
			_wall_follow = -sign_dir
			return cand2
	return -base

## 检测卡住：**看朝目标的净进展**，不看位移大小。
##
## 沿墙侧滑时位移是满的（move_and_slide 的行为），只比位移永远测不出卡住。
## 改为每 CHECK_WINDOW 秒采样一次"到当前目标的距离"，若净逼近量太小就算卡住。
func _track_stuck(delta: float) -> void:
	_last_pos = global_position
	var goal := _current_goal()
	if goal == Vector2.INF:
		_nav_stuck = 0.0
		_progress_timer = 0.0
		return

	_progress_timer += delta
	if _progress_timer < CHECK_WINDOW:
		return
	_progress_timer = 0.0

	var d: float = global_position.distance_to(goal)
	if _last_goal_dist < 0.0:
		_last_goal_dist = d
		return
	var gained: float = _last_goal_dist - d
	_last_goal_dist = d
	# 一个窗口内应该至少逼近 走速×窗口×MIN_PROGRESS_RATIO
	var need: float = Tuning.walk_speed * CHECK_WINDOW * MIN_PROGRESS_RATIO
	if gained < need:
		_nav_stuck += CHECK_WINDOW
	else:
		_nav_stuck = maxf(0.0, _nav_stuck - CHECK_WINDOW)

	# **自愈**：连续几个窗口都没进展 → 这个目标点走不到，换目标
	if _nav_stuck >= STUCK_GIVEUP:
		_nav_stuck = 0.0
		_wall_follow = 0
		_last_goal_dist = -1.0
		_on_navigation_giveup()

## 当前状态正在走向哪里（没有目标返回 Vector2.INF）
func _current_goal() -> Vector2:
	match state:
		State.PATROL:
			if patrol_points.is_empty() or _patrol_wait > 0.0:
				return Vector2.INF
			return patrol_points[_patrol_index % patrol_points.size()]
		State.CHASE, State.SEARCH:
			return last_known_pos
		State.INVESTIGATE:
			return _investigate_pos
		State.RETURN:
			return post
	return Vector2.INF

## 走不到目标时的兜底：巡逻状态跳下一个点，其它状态回岗位。
## 若连续放弃多次，说明整条巡逻路线不可达 → 清空路线转为原地警戒，
## 让它至少表现得像个哨兵，而不是永远抖动的木桩。
func _on_navigation_giveup() -> void:
	unstick_from_walls()
	_nav_giveups += 1
	match state:
		State.PATROL:
			if not patrol_points.is_empty():
				_patrol_index = (_patrol_index + 1) % patrol_points.size()
				_patrol_wait = _rng.randf_range(0.4, 1.2)
			_last_goal_dist = -1.0
			if _nav_giveups >= 3:
				patrol_points.clear()
		State.CHASE, State.SEARCH, State.INVESTIGATE:
			# 第一次卡死：翻到墙的另一侧再绕一次（很多"隔墙"场景只是选错了绕行方向）
			if _nav_giveups < 2:
				_wall_follow = (_wall_follow if _wall_follow != 0 else 1) * -1
				_last_goal_dist = -1.0
				_nav_stuck = 0.0
			else:
				_set_state(State.RETURN)
		State.RETURN:
			# 连回岗位都走不到：就地认领新岗位
			post = global_position
			_set_state(State.PATROL)
		State.ENGAGE:
			_pick_new_strafe()

## 若身体叠在墙碰撞里，弹到最近空地（远处关墙后走进去、墙再打开会嵌死）
func unstick_from_walls() -> void:
	if state == State.DEAD:
		return
	if not _point_in_wall(global_position):
		return
	for ring in range(1, 14):
		var r: float = 22.0 * float(ring)
		for step in 16:
			var cand: Vector2 = global_position + Vector2.RIGHT.rotated(TAU * float(step) / 16.0) * r
			if _point_in_wall(cand):
				continue
			global_position = cand
			velocity = Vector2.ZERO
			_wall_follow = 0
			if _point_in_wall(post):
				post = cand
			return

func _point_in_wall(pos: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	if space == null:
		return false
	var q := PhysicsShapeQueryParameters2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS + 1.5
	q.shape = circle
	q.transform = Transform2D(0.0, pos)
	q.collision_mask = 1 << 0
	q.exclude = [get_rid()]
	return not space.intersect_shape(q, 1).is_empty()

func _face(pos: Vector2, delta: float, rate: float) -> void:
	var to := pos - global_position
	if to.length_squared() < 1.0:
		return
	var want := to.normalized()
	aim_dir = aim_dir.slerp(want, clampf(rate * delta, 0.0, 1.0)).normalized()
	rotation = aim_dir.angle()

## 空闲扫视：缓慢左右摆头，让玩家有绕后的机会（也是可读的"没发现你"信号）
func _face_idle(delta: float) -> void:
	aim_dir = aim_dir.rotated(sin(Time.get_ticks_msec() * 0.0007 + float(get_instance_id() % 100)) * delta * 0.9)
	aim_dir = aim_dir.normalized()
	rotation = aim_dir.angle()

func _pick_new_strafe() -> void:
	_strafe_timer = _rng.randf_range(Tuning.enemy_strafe_interval_min, Tuning.enemy_strafe_interval_max)
	if _rng.randf() < Tuning.enemy_strafe_chance:
		_strafe_dir = 1 if _rng.randf() < 0.5 else -1
	else:
		_strafe_dir = 0

## 供 Vision 的动态实体遮蔽调用
func set_perceived(v: bool) -> void:
	# 调试可视化开着时无视视野遮蔽 —— 跑测时要能一眼看到全场 AI 的分布与状态，
	# 否则「AI 密度够不够」「有没有人罚站」这类问题根本没法看。
	visible = v or Tuning.show_enemy_debug

# ── 绘制（占位美术）────────────────────────────────────
func _draw() -> void:
	var dead := state == State.DEAD
	var r := RADIUS

	if dead:
		# 尸体：暗色叉号，且不再画枪
		draw_circle(Vector2.ZERO, r, Color(0.22, 0.10, 0.10, 0.75))
		draw_line(Vector2(-6, -6), Vector2(6, 6), Color(0.55, 0.25, 0.25), 2.0)
		draw_line(Vector2(-6, 6), Vector2(6, -6), Color(0.55, 0.25, 0.25), 2.0)
		return

	# 枪（先画，被身体压住枪托）
	var gun_col := Color(0.20, 0.20, 0.24)
	draw_line(Vector2(4, 4), Vector2(24, 4), gun_col, 5.0)
	draw_line(Vector2(4, 4), Vector2(24, 4), Color(0.40, 0.36, 0.34), 2.0)
	draw_line(Vector2(4, 4), Vector2(-5, 4), gun_col, 4.0)

	# 身体：颜色随状态变化，跑测时一眼看出 AI 在干什么
	var body_col := _state_color()
	draw_circle(Vector2.ZERO, r + 1.5, Color(0.05, 0.04, 0.04, 0.9))
	draw_circle(Vector2.ZERO, r, body_col)
	# 朝向缺口
	draw_colored_polygon(
		PackedVector2Array([Vector2(r + 7, 0), Vector2(r * 0.3, -4), Vector2(r * 0.3, 4)]),
		Color(1, 0.95, 0.85, 0.9))

	# 血条（低血时才显示，避免刷屏）
	if health != null and health.ratio() < 0.999:
		var bw := 24.0
		var br := Rect2(Vector2(-bw * 0.5, -r - 11.0), Vector2(bw, 3.5))
		draw_rect(br, Color(0.08, 0.06, 0.06, 0.85), true)
		draw_rect(Rect2(br.position, Vector2(bw * health.ratio(), br.size.y)),
			Color(0.90, 0.30, 0.28), true)

	if Tuning.show_enemy_debug:
		_draw_debug()

func _state_color() -> Color:
	match state:
		State.PATROL:      return Color(0.62, 0.60, 0.52)   # 灰：没发现你
		State.ALERT:       return Color(0.95, 0.82, 0.35)   # 黄：起疑
		State.CHASE:       return Color(0.95, 0.52, 0.22)   # 橙：追击
		State.ENGAGE:      return Color(0.92, 0.26, 0.24)   # 红：交战
		State.SEARCH:      return Color(0.72, 0.55, 0.85)   # 紫：搜索
		State.INVESTIGATE: return Color(0.55, 0.75, 0.92)   # 蓝：查看声源
		State.RETURN:      return Color(0.50, 0.68, 0.55)   # 绿：返回
	return Color.GRAY

func _draw_debug() -> void:
	# 视野扇形（本地坐标，节点已随 aim_dir 旋转）
	var half := deg_to_rad(Tuning.enemy_fov_half_angle)
	var rng: float = Tuning.enemy_vision_range
	var pts := PackedVector2Array([Vector2.ZERO])
	for i in 15:
		var a := -half + (2.0 * half) * (float(i) / 14.0)
		pts.append(Vector2.RIGHT.rotated(a) * rng)
	draw_polyline(pts, Color(1.0, 0.45, 0.35, 0.28), 1.5)
	# 状态名（反向旋转以保持水平可读）
	var names := ["巡逻", "警觉", "追击", "交战", "搜索", "查看", "返回", "死亡"]
	draw_set_transform(Vector2(-16, -r_offset()), -rotation, Vector2.ONE)
	draw_string(ThemeDB.fallback_font, Vector2.ZERO, names[state],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, _state_color())
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func r_offset() -> float:
	return RADIUS + 22.0
