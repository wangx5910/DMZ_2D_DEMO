extends Node2D
## Contracts · 动态合约导演（同时只能接一个普通合约）
## 电话合约：普通合约被接取后，打给其他队伍，用来搅动局势。

enum Phase { NONE, OFFERED, ACTIVE, EXTRACT, SUCCESS, FAILED }
enum PhonePhase { IDLE, RINGING, ACCEPTED, DECLINED, SUCCESS, FAILED }

const PX_PER_M := 8.0
const BOARD := preload("res://scripts/world/contract_board.gd")
const HOSTAGE := preload("res://scripts/world/hostage.gd")
const PHONE_LINE := "V，听说漩涡帮派人要带走一个重要人物，但是公司不鼓励这种行为，你愿意出面解决掉他们吗，这报酬可不菲。"

var world = null
var _fx = null
var phase: int = Phase.NONE
var time_left: float = 0.0
var board = null
var hostage = null
var extract_pos := Vector2.INF
var extract_t := 0.0
var offer_poi_name := ""
var hostage_poi_name := ""
var hostage_spawn_pos := Vector2.INF
var _hostage_poi := {}
var hostage_doors: Array = []
var _hostage_prepared := false
var status_line := ""
var owner_team: int = -1
var _rng := RandomNumberGenerator.new()

## 电话合约：抢回人质
var phone_phase: int = PhonePhase.IDLE
var phone_window_t := 0.0
var phone_hold_t := 0.0
var snatch_pos := Vector2.INF
var snatch_t := 0.0
var ping_pos := Vector2.INF
var ping_cd := 0.0
var phone_status := ""

func setup(w, fx) -> void:
	world = w
	_fx = fx
	_rng.randomize()
	add_to_group("contract_director")

func has_active_contract() -> bool:
	return phase == Phase.ACTIVE or phase == Phase.EXTRACT

func is_phone_ringing() -> bool:
	return phone_phase == PhonePhase.RINGING

func phone_dialogue() -> String:
	return PHONE_LINE

func player_is_rescuer() -> bool:
	var p = _player()
	if p == null or owner_team < 0:
		return false
	return int(p.get("team_id")) == owner_team and has_active_contract()

func player_is_snatcher() -> bool:
	return phone_phase == PhonePhase.ACCEPTED

func phone_hold_progress() -> float:
	return clampf(phone_hold_t / maxf(Tuning.phone_contract_hold, 0.01), 0.0, 1.0)

func spawn_opening() -> void:
	if world == null:
		return
	var safe = _pick_offer_safe()
	var pos := Vector2.ZERO
	if safe != null and is_instance_valid(safe):
		pos = _board_pos_beside_safe(safe)
		offer_poi_name = str(safe.get_meta("poi_name", "免保点"))
	else:
		if world.pois.is_empty():
			return
		var offer_poi: Dictionary = _pick_offer_poi()
		if offer_poi.is_empty():
			return
		pos = _standable_in(offer_poi)
		offer_poi_name = str(offer_poi["def"].get("name", "POI"))
	board = Area2D.new()
	board.set_script(BOARD)
	add_child(board)
	board.setup(self, pos, "救援人质")
	phase = Phase.OFFERED
	status_line = "合约点已刷新：%s 免保旁（小地图高亮）" % offer_poi_name
	_prepare_hostage_den()
	RaidLog.log_event("contract_offered", {"poi": offer_poi_name, "type": "rescue", "beside_safe": true})

func accept_from_board(b, actor = null) -> bool:
	if phase != Phase.OFFERED or b != board:
		return false
	if has_active_contract():
		return false
	if not _hostage_prepared:
		if not _prepare_hostage_den():
			status_line = "附近没有可关押人质的房间"
			return false
	if hostage_spawn_pos == Vector2.INF or _hostage_poi.is_empty():
		status_line = "人质房间无效"
		return false
	hostage = CharacterBody2D.new()
	hostage.set_script(HOSTAGE)
	add_child(hostage)
	hostage.setup(self, hostage_spawn_pos, "人质·艾拉")
	for d in hostage_doors:
		if is_instance_valid(d) and d.has_method("unlock"):
			d.unlock()
	owner_team = _actor_team(actor)
	_remove_board()
	time_left = Tuning.contract_hostage_time
	phase = Phase.ACTIVE
	status_line = "已接取：救援人质 → 前往 %s" % hostage_poi_name
	RaidLog.log_event("contract_accepted", {"hostage_poi": hostage_poi_name, "team": owner_team})
	_maybe_ring_phone()
	if world != null:
		world.queue_redraw()
	return true

func _prepare_hostage_den() -> bool:
	if world == null:
		return false
	hostage_doors.clear()
	_hostage_prepared = false
	var origin: Vector2 = board.global_position if board != null else world.spawn_point
	var exclude: Dictionary = {}
	if board != null and world.has_method("_poi_by_point"):
		exclude = world._poi_by_point(board.global_position)
	var ranked: Array = []
	for p in world.pois:
		ranked.append(p)
	ranked.sort_custom(func(a, b):
		var da: float = (a["rect"] as Rect2).get_center().distance_squared_to(origin)
		var db: float = (b["rect"] as Rect2).get_center().distance_squared_to(origin)
		return da < db
	)
	var ordered: Array = []
	for p in ranked:
		if not exclude.is_empty() and p == exclude:
			continue
		ordered.append(p)
	if not exclude.is_empty():
		ordered.append(exclude)
	for p in ordered:
		if not world.has_method("setup_hostage_den"):
			break
		var site: Dictionary = world.setup_hostage_den(p)
		if site.is_empty():
			continue
		_hostage_poi = p
		hostage_poi_name = str(p["def"].get("name", "POI"))
		hostage_spawn_pos = site.get("spawn_pos", Vector2.INF)
		hostage_doors = site.get("doors", [])
		_hostage_prepared = hostage_spawn_pos != Vector2.INF
		if _hostage_prepared:
			RaidLog.log_event("hostage_den_prepared", {
				"poi": hostage_poi_name,
				"doors": hostage_doors.size(),
			})
			return true
	push_warning("人质房间准备失败：没有合适的 POI 房间")
	return false

func on_hostage_picked(who = null) -> void:
	if phase != Phase.ACTIVE and phase != Phase.EXTRACT:
		return
	var tid: int = _actor_team(who)
	if tid == owner_team and extract_pos == Vector2.INF:
		_spawn_extract_point()
	if phase == Phase.ACTIVE and tid == owner_team:
		phase = Phase.EXTRACT
		status_line = "已背起人质 · 送往撤离点（约 %d m）" % int(Tuning.contract_extract_m)

func fail_contract(reason: String) -> void:
	if phase == Phase.SUCCESS or phase == Phase.FAILED:
		return
	phase = Phase.FAILED
	status_line = "合约失败：%s" % reason
	extract_pos = Vector2.INF
	RaidLog.log_event("contract_failed", {"reason": reason})
	if phone_phase == PhonePhase.RINGING:
		_decline_phone("对方任务已结束")
	elif phone_phase == PhonePhase.ACCEPTED:
		phone_phase = PhonePhase.FAILED
		phone_status = "抢回失败：%s" % reason
		snatch_pos = Vector2.INF
	if world != null:
		world.queue_redraw()

func tick(delta: float) -> void:
	# TEMP：暂时关闭「抢回人质」电话合约
	# _tick_phone(delta)
	if phase == Phase.ACTIVE or phase == Phase.EXTRACT:
		time_left -= delta
		if time_left <= 0.0:
			fail_contract("超时失效")
			return
	if phase == Phase.EXTRACT:
		_tick_extract(delta)
	# TEMP：暂时关闭「抢回人质」
	# if phone_phase == PhonePhase.ACCEPTED:
	# 	_tick_snatch(delta)
	# 	_tick_ping(delta)

func should_ai_pursue_rescue(_bot) -> bool:
	# TEMP：暂时关闭 AI 接/做「救援人质」
	return false
	# if bot == null or not is_instance_valid(bot):
	# 	return false
	# var tid: int = int(bot.get("team_id"))
	# if phase == Phase.OFFERED:
	# 	if not bool(bot.get("first_safe_done")):
	# 		return false
	# 	if board == null or not is_instance_valid(board):
	# 		return false
	# 	return bot.global_position.distance_to(board.global_position) <= 320.0
	# if phase == Phase.ACTIVE or phase == Phase.EXTRACT:
	# 	return tid == owner_team
	# return false

func closest_eligible_team() -> int:
	if phase != Phase.OFFERED or board == null or not is_instance_valid(board):
		return -1
	var origin: Vector2 = board.global_position
	var best_team := -1
	var best_d := INF
	var tree := get_tree()
	if tree == null:
		return -1
	for b in tree.get_nodes_in_group("raider_bots"):
		if not is_instance_valid(b):
			continue
		if b.has_method("is_dead") and b.is_dead():
			continue
		if not bool(b.get("first_safe_done")):
			continue
		var d: float = b.global_position.distance_squared_to(origin)
		if d < best_d:
			best_d = d
			best_team = int(b.get("team_id"))
	return best_team

func _maybe_ring_phone() -> void:
	return  ## TEMP：暂时关闭「抢回人质」（原逻辑保留在 git 历史 / 下方注释）
	# if not Tuning.enable_phone_contracts:
	# 	return
	# if phone_phase != PhonePhase.IDLE:
	# 	return
	# var p = _player()
	# if p == null:
	# 	return
	# if int(p.get("team_id")) == owner_team:
	# 	return
	# phone_phase = PhonePhase.RINGING
	# phone_window_t = Tuning.phone_contract_window
	# phone_hold_t = 0.0
	# phone_status = "来电"
	# RaidLog.log_event("phone_ring", {"type": "snatch_hostage"})

func _tick_phone(delta: float) -> void:
	if phone_phase != PhonePhase.RINGING:
		return
	phone_window_t -= delta
	var p = _player()
	var holding := false
	if p != null and not p.is_dead() and not bool(p.get("ui_capturing_mouse")):
		holding = Input.is_action_pressed("interact")
	if holding:
		phone_hold_t += delta
		if phone_hold_t >= Tuning.phone_contract_hold:
			_accept_phone()
			return
	else:
		phone_hold_t = 0.0
	if phone_window_t <= 0.0:
		_decline_phone("未接听")

func _accept_phone() -> void:
	phone_phase = PhonePhase.ACCEPTED
	phone_hold_t = 0.0
	phone_window_t = 0.0
	phone_status = "已接取：抢回人质"
	_spawn_snatch_point()
	ping_pos = _hostage_world_pos()
	ping_cd = Tuning.phone_ping_interval
	RaidLog.log_event("phone_accepted", {"type": "snatch_hostage"})
	if world != null:
		world.queue_redraw()

func _decline_phone(reason: String) -> void:
	phone_phase = PhonePhase.DECLINED
	phone_hold_t = 0.0
	phone_window_t = 0.0
	phone_status = "已拒绝电话合约（%s）" % reason
	RaidLog.log_event("phone_declined", {"reason": reason})

func _tick_ping(delta: float) -> void:
	ping_cd -= delta
	if ping_cd > 0.0:
		return
	ping_cd = Tuning.phone_ping_interval
	var hp: Vector2 = _hostage_world_pos()
	if hp != Vector2.INF:
		ping_pos = hp

func _tick_extract(delta: float) -> void:
	if extract_pos == Vector2.INF:
		return
	if _hostage_and_team_in_zone(owner_team, extract_pos):
		extract_t += delta
		if extract_t >= Tuning.contract_extract_hold:
			_succeed_rescue()
	else:
		extract_t = maxf(0.0, extract_t - delta * 1.5)

func _tick_snatch(delta: float) -> void:
	if snatch_pos == Vector2.INF:
		return
	var p = _player()
	var tid: int = int(p.get("team_id")) if p != null else 0
	if _hostage_and_team_in_zone(tid, snatch_pos):
		snatch_t += delta
		if snatch_t >= Tuning.contract_extract_hold:
			_succeed_snatch()
	else:
		snatch_t = maxf(0.0, snatch_t - delta * 1.5)

func _succeed_rescue() -> void:
	phase = Phase.SUCCESS
	status_line = "合约完成：人质已撤离"
	extract_pos = Vector2.INF
	_despawn_hostage()
	if phone_phase == PhonePhase.RINGING:
		_decline_phone("人质已被撤离")
	elif phone_phase == PhonePhase.ACCEPTED:
		phone_phase = PhonePhase.FAILED
		phone_status = "抢回失败：人质已被对方撤离"
		snatch_pos = Vector2.INF
	RaidLog.log_event("contract_success", {"type": "rescue"})
	if world != null:
		world.queue_redraw()

func _succeed_snatch() -> void:
	phone_phase = PhonePhase.SUCCESS
	phone_status = "电话合约完成：人质已抢回"
	snatch_pos = Vector2.INF
	if phase != Phase.SUCCESS and phase != Phase.FAILED:
		phase = Phase.FAILED
		status_line = "合约失败：人质被其他队伍抢回"
		extract_pos = Vector2.INF
		RaidLog.log_event("contract_failed", {"reason": "snatched"})
	_despawn_hostage()
	RaidLog.log_event("phone_success", {"type": "snatch_hostage"})
	if world != null:
		world.queue_redraw()

func _despawn_hostage() -> void:
	if hostage == null or not is_instance_valid(hostage):
		hostage = null
		return
	if not hostage.is_dead():
		var carrier = hostage.carried_by
		if carrier != null and is_instance_valid(carrier) and carrier.has_method("drop_hostage"):
			carrier.drop_hostage()
		if hostage.vehicle != null and is_instance_valid(hostage.vehicle):
			hostage.vehicle.disembark(hostage)
			hostage.leave_vehicle_forced()
	hostage.queue_free()
	hostage = null

func _hostage_and_team_in_zone(team: int, pos: Vector2) -> bool:
	if pos == Vector2.INF:
		return false
	var r: float = Tuning.contract_extract_radius
	var hp: Vector2 = _hostage_world_pos()
	if hp == Vector2.INF or hp.distance_to(pos) > r:
		return false
	return _team_member_in_zone(team, pos, r)

func _team_member_in_zone(team: int, pos: Vector2, r: float) -> bool:
	var p = _player()
	if p != null and is_instance_valid(p) and not p.is_dead() \
			and int(p.get("team_id")) == team and p.global_position.distance_to(pos) <= r:
		return true
	var tree := get_tree()
	if tree == null:
		return false
	for b in tree.get_nodes_in_group("raider_bots"):
		if not is_instance_valid(b):
			continue
		if b.has_method("is_dead") and b.is_dead():
			continue
		if int(b.get("team_id")) != team:
			continue
		if b.global_position.distance_to(pos) <= r:
			return true
	return false

func _hostage_world_pos() -> Vector2:
	if hostage == null or not is_instance_valid(hostage) or hostage.is_dead():
		return Vector2.INF
	return hostage.global_position

func _spawn_extract_point() -> void:
	var origin: Vector2 = _hostage_world_pos()
	if origin == Vector2.INF:
		var p = _player()
		origin = p.global_position if p != null else Vector2.ZERO
	var dist: float = Tuning.contract_extract_m * PX_PER_M
	var best := Vector2.INF
	for i in 16:
		var ang: float = TAU * float(i) / 16.0 + _rng.randf_range(-0.12, 0.12)
		var cand: Vector2 = origin + Vector2.RIGHT.rotated(ang) * dist
		if world.has_method("_find_open_spot"):
			var cleared: Vector2 = world._find_open_spot(cand, 0.0, 420.0)
			if cleared != Vector2.INF:
				best = cleared
				break
		if world.has_method("find_clear_circle"):
			var c2: Vector2 = world.find_clear_circle(12, cand)
			if c2 != Vector2.INF:
				best = c2
				break
	if best == Vector2.INF:
		best = origin + Vector2.RIGHT * dist
	extract_pos = best
	extract_t = 0.0
	if world != null:
		world.queue_redraw()

func _spawn_snatch_point() -> void:
	# 人质出生 POI 附近的另一个点，不是出生格本身
	var origin: Vector2 = hostage_spawn_pos
	if origin == Vector2.INF:
		origin = _hostage_world_pos()
	var best := Vector2.INF
	if not _hostage_poi.is_empty():
		best = _corridor_away(_hostage_poi, origin, 140.0)
	if best == Vector2.INF and world != null and world.has_method("_find_open_spot"):
		best = world._find_open_spot(origin, 120.0, 280.0)
	if best == Vector2.INF:
		best = origin + Vector2.RIGHT.rotated(_rng.randf() * TAU) * 180.0
	snatch_pos = best
	snatch_t = 0.0

func _pick_offer_safe():
	if world == null:
		return null
	var player_safe = world.get("player_spawn_target_safe")
	var spawns = world.get("squad_spawns")
	if spawns is Array:
		for s in spawns:
			if int(s.get("squad_id", -1)) == int(world.get("player_squad_id")):
				continue
			var safe = s.get("safe", null)
			if safe != null and is_instance_valid(safe) and safe != player_safe:
				return safe
	var nodes = world.get("free_safe_nodes")
	if nodes is Array:
		for n in nodes:
			if n != null and is_instance_valid(n) and n != player_safe:
				return n
		for n2 in nodes:
			if n2 != null and is_instance_valid(n2):
				return n2
	if player_safe != null and is_instance_valid(player_safe):
		return player_safe
	return null

func _board_pos_beside_safe(safe) -> Vector2:
	var origin_pos: Vector2 = safe.global_position
	var poi: Dictionary = {}
	if world != null and world.has_method("_poi_by_point"):
		poi = world._poi_by_point(origin_pos)
	if not poi.is_empty():
		var cells: Array = _corridor_cells(poi)
		if cells.is_empty() and poi.get("gen") != null:
			cells = poi["gen"].standable_cells(true)
		var best := Vector2.INF
		var best_d := INF
		var far_best := Vector2.INF
		var far_d := INF
		var poi_origin: Vector2i = poi["origin"]
		for c in cells:
			var pos: Vector2 = world._cell_center(poi_origin, c)
			var d: float = pos.distance_to(origin_pos)
			if d < 24.0:
				continue
			if d < far_d:
				far_d = d
				far_best = pos
			if d <= 90.0 and d < best_d:
				best_d = d
				best = pos
		if best != Vector2.INF:
			return best
		if far_best != Vector2.INF:
			return far_best
	# 网格找不到就叠在免保上：免保本身在甬道，保证可走
	return origin_pos

func _pick_offer_poi() -> Dictionary:
	var spawn: Vector2 = world.spawn_point
	return _nearest_poi_to(spawn, {})

func _pick_hostage_poi() -> Dictionary:
	var from: Vector2 = board.global_position if board != null else world.spawn_point
	var exclude: Dictionary = {}
	if board != null:
		var self_poi: Dictionary = world._poi_by_point(board.global_position)
		if not self_poi.is_empty():
			exclude = self_poi
	var other: Dictionary = _nearest_poi_to(from, exclude)
	if other.is_empty():
		return exclude
	return other

func _nearest_poi_to(pos: Vector2, exclude: Dictionary) -> Dictionary:
	var best := {}
	var best_d := INF
	for p in world.pois:
		if not exclude.is_empty() and p == exclude:
			continue
		var d: float = (p["rect"] as Rect2).get_center().distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = p
	return best

func _standable_in(p: Dictionary) -> Vector2:
	var gen = p["gen"]
	var origin: Vector2i = p["origin"]
	var pool: Array = gen.standable_cells(true)
	if pool.is_empty():
		return (p["rect"] as Rect2).get_center()
	var c: Vector2i = pool[_rng.randi() % pool.size()]
	return world._cell_center(origin, c)

## 甬道上的可站立格（排除外墙入口死角），简易绕障能走通
func _corridor_cells(p: Dictionary) -> Array:
	var gen = p["gen"]
	var stand: Dictionary = {}
	for c in gen.standable_cells(true):
		stand[c] = true
	var out: Array = []
	for c in gen.corridor_cells:
		if stand.has(c):
			out.append(c)
	return out

func _corridor_near(p: Dictionary, toward: Vector2) -> Vector2:
	var origin: Vector2i = p["origin"]
	var pool: Array = _corridor_cells(p)
	if pool.is_empty():
		return _standable_in(p)
	var best: Vector2i = pool[0]
	var best_d := INF
	for c in pool:
		var pos: Vector2 = world._cell_center(origin, c)
		var d: float = pos.distance_squared_to(toward)
		if d < best_d:
			best_d = d
			best = c
	return world._cell_center(origin, best)

func _corridor_away(p: Dictionary, away: Vector2, min_dist: float) -> Vector2:
	var origin: Vector2i = p["origin"]
	var pool: Array = _corridor_cells(p)
	if pool.is_empty():
		return _standable_in_away(p, away, min_dist)
	var best := Vector2.INF
	var best_score := -INF
	for c in pool:
		var pos: Vector2 = world._cell_center(origin, c)
		var d: float = pos.distance_to(away)
		if d < min_dist:
			continue
		if d > best_score:
			best_score = d
			best = pos
	if best != Vector2.INF:
		return best
	return _corridor_near(p, away)

func _standable_in_away(p: Dictionary, away: Vector2, min_dist: float) -> Vector2:
	var gen = p["gen"]
	var origin: Vector2i = p["origin"]
	var pool: Array = gen.standable_cells(true)
	if pool.is_empty():
		return Vector2.INF
	var best := Vector2.INF
	var best_score := -INF
	for cell in pool:
		var pos: Vector2 = world._cell_center(origin, cell)
		var d: float = pos.distance_to(away)
		if d < min_dist:
			continue
		if d > best_score:
			best_score = d
			best = pos
	if best != Vector2.INF:
		return best
	# POI 太小：退而求其次，取离出生点最远的格
	for cell in pool:
		var pos2: Vector2 = world._cell_center(origin, cell)
		var d2: float = pos2.distance_to(away)
		if d2 > best_score:
			best_score = d2
			best = pos2
	return best

func _remove_board() -> void:
	if board != null and is_instance_valid(board):
		board.queue_free()
	board = null

func _actor_team(actor) -> int:
	if actor != null and is_instance_valid(actor) and actor.get("team_id") != null:
		return int(actor.get("team_id"))
	var p = _player()
	if p != null:
		return int(p.get("team_id"))
	return 0

func _player():
	if world != null and world.get("_player") != null:
		return world._player
	return null

func hud_banner() -> String:
	if phone_phase == PhonePhase.RINGING:
		return ""
	if player_is_snatcher():
		var hold := ""
		if snatch_t > 0.0:
			hold = " ｜ 交接 %.0f%%" % (snatch_t / maxf(Tuning.contract_extract_hold, 0.01) * 100.0)
		return "电话合约：抢回人质｜送回 %s 附近交接点%s" % [hostage_poi_name, hold]
	if phone_phase == PhonePhase.SUCCESS:
		return "✅ 电话合约完成：人质已抢回"
	if phone_phase == PhonePhase.FAILED and not player_is_rescuer():
		return "✗ %s" % phone_status
	match phase:
		Phase.OFFERED:
			return "动态合约：%s 免保旁有救援合约点" % offer_poi_name
		Phase.ACTIVE:
			if player_is_rescuer():
				return "合约进行中：救援人质（%s）｜剩余 %.0f 秒" % [hostage_poi_name, time_left]
			return ""
		Phase.EXTRACT:
			if not player_is_rescuer():
				return ""
			var hold2 := ""
			if extract_t > 0.0:
				hold2 = " ｜ 撤离 %.0f%%" % (extract_t / maxf(Tuning.contract_extract_hold, 0.01) * 100.0)
			return "护送人质撤离｜剩余 %.0f 秒%s" % [time_left, hold2]
		Phase.SUCCESS:
			return "✅ 合约完成：人质已安全撤离"
		Phase.FAILED:
			if player_is_snatcher() or phone_phase == PhonePhase.SUCCESS:
				return ""
			return "✗ %s" % status_line
	return ""

func extract_progress() -> float:
	if player_is_snatcher():
		return clampf(snatch_t / maxf(Tuning.contract_extract_hold, 0.01), 0.0, 1.0)
	return clampf(extract_t / maxf(Tuning.contract_extract_hold, 0.01), 0.0, 1.0)
