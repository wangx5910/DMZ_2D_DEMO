extends Node2D
## Spaceship · 巡航 / 驾驶 / 破解开放密闭舱

enum S { CRUISE, HIJACK, CRACKING, OPENED }

signal arrived_at_crack(pos: Vector2)
signal hijacked(by)
signal ship_extracted(by)
signal sealed_opened()

const TILE := 40.0
const ShipPoiScript := preload("res://scripts/world/ship_poi.gd")
const SHIP_W_CELLS := 40
const SHIP_H_CELLS := 20
const SHIP_W := float(SHIP_W_CELLS) * TILE
const SHIP_H := float(SHIP_H_CELLS) * TILE
const PORTAL_OUTSET := 100.0
const SHIP_WALL_LAYER := 1 << 6   ## project layer 7 = ship_interior
const SHIP_OCC_MASK := 2          ## 登舰后光源只吃这层遮光，避免地面 POI 切出格子阴影

var world = null
var state: int = S.CRUISE
var _t: float = 0.0
var _route: Array[Vector2] = []
var _route_i: int = 0
var _target: Vector2 = Vector2.ZERO

var hijacker = null
var crack_t: float = 0.0
var _aboard: Array = []
var _pilot_seated := false
var sealed_open := false
var _seat_local := Vector2.ZERO

var _portal_exterior: Array = []
var _portal_interior: Array = []
var _control_local := Vector2.ZERO
var _sealed_local := Vector2.ZERO
var _control_rect := Rect2i()
var _sealed_rect := Rect2i()

var _gen: PoiGenerator = null
var _interior_root: Node2D = null
var _walls_holder: Node2D = null
var _floor_rects: Array[Rect2] = []
var _wall_rects: Array[Rect2] = []
var _interior_built := false
var sealed_preview_value: int = 0
var sealed_containers: Array = []

func setup(w) -> void:
	world = w
	_route = _build_loop_route(w)
	if _route.is_empty():
		var wp: float = float(w.world_size_cells) * TILE
		_route = [Vector2(wp * 0.2, wp * 0.2), Vector2(wp * 0.8, wp * 0.2),
			Vector2(wp * 0.8, wp * 0.8), Vector2(wp * 0.2, wp * 0.8)]
	global_position = _route[0]
	_route_i = 1 % _route.size()
	_target = _route[_route_i]
	z_index = 60
	z_as_relative = false

## 调试：把飞船挪到 anchor（通常是玩家）附近，左舷传送门距玩家约 200px
func place_near(anchor: Vector2) -> void:
	if _portal_exterior.is_empty():
		return
	var portal_world := anchor + Vector2(200, 0)
	var center: Vector2 = portal_world - _portal_exterior[0]
	if world != null and world.has_method("find_clear_circle"):
		var cleared: Vector2 = world.find_clear_circle(22, center)
		if cleared != Vector2.INF:
			center = cleared
	global_position = center
	_target = center
	var r := Vector2(320, 180)
	_route = [
		center,
		center + Vector2(r.x, 0),
		center + r,
		center + Vector2(0, r.y),
		center + Vector2(-r.x * 0.5, 0),
	]
	_route_i = 1 % _route.size()
	_target = _route[_route_i]
	state = S.CRUISE
	hijacker = null
	crack_t = 0.0
	_pilot_seated = false
	sealed_open = false

func build_interior(w) -> void:
	if _interior_built:
		return
	_interior_built = true
	var data: Dictionary = ShipPoiScript.generate()
	_gen = data.gen
	_control_rect = data.control_rect
	_sealed_rect = data.sealed_rect
	_control_local = _cell_to_local(_control_rect.get_center())
	var seat_cell: Vector2i = data.get("seat_cell", _control_rect.get_center())
	_seat_local = _cell_to_local(seat_cell)
	_sealed_local = _cell_to_local(Vector2i(
		_sealed_rect.position.x + _sealed_rect.size.x / 2,
		_sealed_rect.position.y + 2))
	_portal_interior = [
		_cell_to_local(data.left_portal_cell),
		_cell_to_local(data.right_portal_cell),
	]
	_portal_exterior = [
		Vector2(-SHIP_W * 0.5 - PORTAL_OUTSET, _portal_interior[0].y),
		Vector2(SHIP_W * 0.5 + PORTAL_OUTSET, _portal_interior[1].y),
	]
	sealed_preview_value = ShipPoiScript.sealed_preview_value(data.sealed_items)

	_interior_root = Node2D.new()
	_interior_root.name = "Interior"
	_interior_root.position = Vector2(-SHIP_W * 0.5, -SHIP_H * 0.5)
	_interior_root.z_index = 1
	add_child(_interior_root)

	_walls_holder = Node2D.new()
	_walls_holder.name = "Walls"
	_interior_root.add_child(_walls_holder)
	_bake_floors()
	_build_interior_walls()
	_spawn_loot(w, data)
	_hook_floor_draw()
	RaidLog.log_event("ship_poi_built", {
		"containers": w.ship_loot_nodes.size(),
		"sealed_value": sealed_preview_value,
	})

func _cell_to_local(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5) - Vector2(SHIP_W * 0.5, SHIP_H * 0.5)

func _local_to_cell(local: Vector2) -> Vector2i:
	var p := local + Vector2(SHIP_W * 0.5, SHIP_H * 0.5)
	return Vector2i(int(p.x / TILE), int(p.y / TILE))

func _bake_floors() -> void:
	_floor_rects.clear()
	var lines: Array = _gen.to_lines()
	for y in lines.size():
		var row: String = lines[y]
		var run := -1
		for x in row.length() + 1:
			var walk: bool = x < row.length() and row[x] != "#"
			if walk and run < 0:
				run = x
			elif not walk and run >= 0:
				_floor_rects.append(Rect2(
					Vector2(run * TILE, y * TILE),
					Vector2((x - run) * TILE, TILE)))
				run = -1

func _build_interior_walls() -> void:
	_wall_rects.clear()
	var lines: Array = _gen.to_lines()
	var h: int = lines.size()
	var w: int = lines[0].length() if h > 0 else 0
	var used: Array = []
	for y in h:
		var row: Array = []
		row.resize(w)
		row.fill(false)
		used.append(row)
	for y in h:
		var row: String = lines[y]
		for x in w:
			if used[y][x] or row[x] != "#":
				continue
			var rw := 1
			while x + rw < w and row[x + rw] == "#" and not used[y][x + rw]:
				rw += 1
			var rh := 1
			var can_grow := true
			while y + rh < h and can_grow:
				for xx in range(x, x + rw):
					if lines[y + rh][xx] != "#" or used[y + rh][xx]:
						can_grow = false
						break
				if can_grow:
					rh += 1
			for yy in range(y, y + rh):
				for xx in range(x, x + rw):
					used[yy][xx] = true
			var rect := Rect2(Vector2(x * TILE, y * TILE), Vector2(rw * TILE, rh * TILE))
			_wall_rects.append(rect)
			_add_wall_body(rect)

func _add_wall_body(rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.position = rect.position + rect.size * 0.5
	body.collision_layer = SHIP_WALL_LAYER
	body.collision_mask = 0
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = rect.size
	shape.shape = box
	body.add_child(shape)
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var h := rect.size * 0.5
	poly.polygon = PackedVector2Array([
		Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)])
	poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
	occ.occluder = poly
	occ.occluder_light_mask = SHIP_OCC_MASK
	body.add_child(occ)
	_walls_holder.add_child(body)

func _spawn_loot(w, data: Dictionary) -> void:
	w.ship_loot_nodes.clear()
	sealed_containers.clear()
	var script = w.container_script
	for ct in _gen.containers:
		var c: Vector2i = ct["cell"]
		var node = _make_container(script, c, str(ct["richness"]), "")
		w.ship_loot_nodes.append(node)
	var items: Array = data.sealed_items
	var spots: Array = data.get("sealed_spots", [
		Vector2i(30, 4), Vector2i(33, 4), Vector2i(30, 6), Vector2i(33, 6),
	])
	for i in items.size():
		var node = _make_container(script, spots[i], "L4", "密闭预览")
		node.take_locked = true
		node.is_sealed_preview = true
		node.cracked = true   # 免破解读条，开箱即预览
		node._rolled = true
		node.slots = [{"id": items[i]}]
		# revealed/taken 是 Array[bool]：只能 clear/append，不能 = [] / = [true]
		node.revealed.clear()
		node.taken.clear()
		node.revealed.append(true)
		node.taken.append(false)
		w.ship_loot_nodes.append(node)
		sealed_containers.append(node)

func _make_container(script, cell: Vector2i, richness: String, label: String):
	var node = Area2D.new()
	node.set_script(script)
	node.richness = richness
	if label != "":
		node.label = label
	node.position = Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5)
	_interior_root.add_child(node)
	return node

func portal_radius() -> float:
	return Tuning.spaceship_pillar_radius

func _build_loop_route(w) -> Array[Vector2]:
	var wp: float = float(w.world_size_cells) * TILE
	var anchors := [
		Vector2(wp * 0.16, wp * 0.14), Vector2(wp * 0.50, wp * 0.12),
		Vector2(wp * 0.84, wp * 0.18), Vector2(wp * 0.88, wp * 0.50),
		Vector2(wp * 0.84, wp * 0.82), Vector2(wp * 0.50, wp * 0.88),
		Vector2(wp * 0.16, wp * 0.82), Vector2(wp * 0.12, wp * 0.50),
	]
	var out: Array[Vector2] = []
	for a in anchors:
		var p: Vector2 = w.find_clear_circle(18, a)
		if p != Vector2.INF:
			out.append(p)
	return out

func tick(delta: float, w) -> void:
	var prev := global_position
	_t += delta
	match state:
		S.CRUISE: _cruise(delta)
		S.HIJACK, S.CRACKING, S.OPENED:
			_tick_hijacked(delta, w)
	var ship_delta := global_position - prev
	for p in _aboard:
		if is_instance_valid(p):
			p.global_position += ship_delta
	_sync_pilot_seat()
	_handle_portals(delta, w)
	if _interior_root != null:
		_interior_root.queue_redraw()
	queue_redraw()

func _cruise(delta: float) -> void:
	if _route.is_empty():
		return
	_go(_target, Tuning.spaceship_speed, delta)
	if global_position.distance_to(_target) < 20.0:
		_route_i = (_route_i + 1) % _route.size()
		_target = _route[_route_i]

func _go(to: Vector2, spd: float, delta: float) -> void:
	if global_position.distance_to(to) < spd * delta:
		global_position = to
	else:
		global_position = global_position.move_toward(to, spd * delta)

func force_hover_at_crack(w) -> void:
	var cps: Array = w.spaceship_crack_points()
	if not cps.is_empty():
		global_position = cps[0]
	_target = global_position
	if hijacker != null:
		state = S.CRACKING
	else:
		state = S.CRUISE
	crack_t = 0.0
	emit_signal("arrived_at_crack", global_position)

func _handle_portals(delta: float, w) -> void:
	# 只处理玩家、已登舰者、靠近传送门的 AI —— 禁止每帧扫全图 60+ 人
	var actors: Array = []
	if w._player != null and is_instance_valid(w._player):
		actors.append(w._player)
	var r: float = portal_radius()
	var near_r2: float = (r * 3.5) * (r * 3.5)
	for b in get_tree().get_nodes_in_group("raider_bots"):
		if not is_instance_valid(b):
			continue
		if b.get("aboard_ship") == self:
			actors.append(b)
			continue
		var near := false
		for off in _portal_exterior:
			if b.global_position.distance_squared_to(global_position + off) <= near_r2:
				near = true
				break
		if near:
			actors.append(b)
	for actor in actors:
		_tick_actor_portal(actor, delta)

func _tick_actor_portal(actor, delta: float) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	if not actor.has_method("enter_ship"):
		return
	if is_pilot(actor):
		actor.set("_portal_channel_t", 0.0)
		actor.set("_portal_channel_label", "")
		return
	var r: float = portal_radius()
	var in_zone := false
	var idx := -1
	var aboard = actor.get("aboard_ship")
	var entering: bool = aboard == null
	if entering:
		for i in _portal_exterior.size():
			if actor.global_position.distance_to(global_position + _portal_exterior[i]) <= r:
				in_zone = true
				idx = i
				break
	elif aboard == self:
		for i in _portal_interior.size():
			if actor.global_position.distance_to(global_position + _portal_interior[i]) <= r:
				in_zone = true
				idx = i
				break
	var ch: float = float(actor.get("_portal_channel_t"))
	if in_zone:
		ch += delta
		actor.set("_portal_channel_t", ch)
		actor.set("_portal_channel_label", "进入飞船" if entering else "离开飞船")
		if ch >= Tuning.spaceship_lift_time:
			if entering:
				_board(actor, idx)
			else:
				_exit(actor, idx)
	else:
		actor.set("_portal_channel_t", maxf(0.0, ch - delta * 2.0))
		actor.set("_portal_channel_label", "")

func _board(actor, portal_idx: int) -> void:
	if actor.get("aboard_ship") != null:
		return
	actor.enter_ship(self)
	if not _aboard.has(actor):
		_aboard.append(actor)
	actor.set("_portal_channel_t", 0.0)
	actor.set("_portal_channel_label", "")
	actor.global_position = global_position + _portal_interior[portal_idx]
	RaidLog.log_event("ship_board", {"portal": portal_idx})

func _exit(actor, portal_idx: int) -> void:
	if actor.get("aboard_ship") != self:
		return
	if is_pilot(actor):
		leave_pilot(actor)
	_aboard.erase(actor)
	actor.exit_ship(global_position + _portal_exterior[portal_idx])
	actor.set("_portal_channel_t", 0.0)
	actor.set("_portal_channel_label", "")

func can_hijack(who) -> bool:
	if not Tuning.enable_spaceship_hijack or who == null:
		return false
	if who.get("aboard_ship") != self:
		return false
	# 巡航无人劫持：首次夺取
	if state == S.CRUISE and hijacker == null:
		return true
	# 已被劫持：异队可夺权
	return can_contest(who)

## 异队在操控室可夺取当前劫持（重置破解进度）
func can_contest(who) -> bool:
	if not Tuning.enable_spaceship_hijack or who == null:
		return false
	if who.get("aboard_ship") != self:
		return false
	if state != S.HIJACK and state != S.CRACKING and state != S.OPENED:
		return false
	if who == hijacker:
		return false
	if hijacker == null or not is_instance_valid(hijacker):
		return true
	return _actor_team(who) != _actor_team(hijacker)

func _actor_team(who) -> int:
	if who == null:
		return -1
	return int(who.get("team_id"))

func is_in_control_room(who) -> bool:
	if who == null or who.get("aboard_ship") != self:
		return false
	var local: Vector2 = who.global_position - global_position
	return _control_rect.has_point(_local_to_cell(local))

func try_hijack(who) -> bool:
	if not is_in_control_room(who):
		return false
	if state == S.CRUISE and hijacker == null and can_hijack(who):
		_start_hijack(who, world)
		return true
	if can_contest(who):
		_seize_hijack(who)
		return true
	if who == hijacker and not _pilot_seated:
		_sit_pilot(who)
		return true
	return false

func is_pilot(who) -> bool:
	return who != null and who == hijacker and _pilot_seated

func leave_pilot(who) -> bool:
	if who != hijacker or not _pilot_seated:
		return false
	_pilot_seated = false
	return true

func _sit_pilot(who) -> void:
	if who == null:
		return
	hijacker = who
	_pilot_seated = true
	who.global_position = global_position + _seat_local
	if who.has_method("on_ship_pilot"):
		who.on_ship_pilot(self)

func _sync_pilot_seat() -> void:
	if not _pilot_seated or not _hijacker_valid():
		return
	hijacker.global_position = global_position + _seat_local
	if "velocity" in hijacker:
		hijacker.velocity = Vector2.ZERO

func _seize_hijack(who) -> void:
	if hijacker != null and hijacker != who and hijacker.has_method("on_ship_unpilot"):
		hijacker.on_ship_unpilot()
	hijacker = who
	crack_t = 0.0
	if world != null:
		world.hijack_active = who
	_sit_pilot(who)
	if state == S.CRUISE:
		state = S.HIJACK
	emit_signal("hijacked", who)
	RaidLog.log_event("ship_hijack_seized", {"team": _actor_team(who)})

func _start_hijack(player, w) -> void:
	hijacker = player
	crack_t = 0.0
	state = S.HIJACK
	_sit_pilot(player)
	emit_signal("hijacked", player)
	RaidLog.log_event("ship_hijacked", {})
	if w != null:
		w.hijack_active = player

func _tick_hijacked(delta: float, w) -> void:
	if not _hijacker_valid():
		_abort_hijack()
		state = S.CRUISE
		return
	if sealed_open or state == S.OPENED:
		state = S.OPENED
		if _is_player_pilot():
			_drive_from_pilot(delta, w)
		return
	if _is_player_pilot():
		_drive_from_pilot(delta, w)
	elif not _is_player_hijacker():
		_ai_fly_to_crack(delta, w)
	if _near_crack_point(w):
		if state != S.CRACKING:
			state = S.CRACKING
			emit_signal("arrived_at_crack", global_position)
		crack_t += delta
		if crack_t >= Tuning.spaceship_crack_hold:
			_open_sealed()
	else:
		if state == S.CRACKING:
			state = S.HIJACK
		crack_t = maxf(0.0, crack_t - delta * 1.2)

func _is_player_pilot() -> bool:
	return _pilot_seated and _is_player_hijacker()

func _is_player_hijacker() -> bool:
	return hijacker != null and is_instance_valid(hijacker) and hijacker.is_in_group("player")

func _drive_from_pilot(delta: float, w) -> void:
	if not _pilot_seated:
		return
	var dir := Vector2.ZERO
	if hijacker.has_method("_input_dir"):
		dir = hijacker._input_dir()
	if dir.length_squared() < 0.01:
		return
	var spd: float = Tuning.spaceship_speed * 1.15
	global_position += dir.normalized() * spd * delta
	_clamp_ship_to_world(w)

func _ai_fly_to_crack(delta: float, w) -> void:
	var cps: Array = w.spaceship_crack_points() if w != null else []
	if cps.is_empty():
		return
	var best: Vector2 = cps[0]
	var bd: float = global_position.distance_to(best)
	for c in cps:
		var d: float = global_position.distance_to(c)
		if d < bd:
			bd = d
			best = c
	_go(best, Tuning.spaceship_speed * 1.2, delta)

func _near_crack_point(w) -> bool:
	if w == null:
		return false
	var r: float = Tuning.spaceship_crack_range
	for cp in w.spaceship_crack_points():
		if global_position.distance_to(cp) <= r:
			return true
	return false

func _clamp_ship_to_world(w) -> void:
	if w == null:
		return
	var wp: float = float(w.world_size_cells) * TILE
	var m := 240.0
	global_position.x = clampf(global_position.x, m, wp - m)
	global_position.y = clampf(global_position.y, m, wp - m)

func _open_sealed() -> void:
	if sealed_open:
		return
	sealed_open = true
	state = S.OPENED
	crack_t = Tuning.spaceship_crack_hold
	for c in sealed_containers:
		if not is_instance_valid(c):
			continue
		c.take_locked = false
		c.is_sealed_preview = false
		c.label = "密闭舱"
		c.queue_redraw()
	emit_signal("sealed_opened")
	RaidLog.log_event("ship_sealed_opened", {"value": sealed_preview_value})

func _hijacker_valid() -> bool:
	return hijacker != null and is_instance_valid(hijacker) and hijacker.aboard_ship == self

func _complete_extraction(w) -> void:
	# 旧整船撤离入口保留给测试/调试；正常流程走 _open_sealed。
	_open_sealed()

func _abort_hijack() -> void:
	if hijacker != null and is_instance_valid(hijacker) and hijacker.has_method("on_ship_unpilot"):
		hijacker.on_ship_unpilot()
	hijacker = null
	crack_t = 0.0
	_pilot_seated = false
	if world != null:
		world.hijack_active = null
		if "ship_contest_ids" in world:
			world.ship_contest_ids.clear()

func ship_size() -> Vector2:
	return Vector2(SHIP_W, SHIP_H)

func _draw() -> void:
	_draw_portals()
	_draw_sealed_label()
	var font := ThemeDB.fallback_font
	var half := Vector2(SHIP_W * 0.5, SHIP_H * 0.5)
	draw_rect(Rect2(-half, Vector2(SHIP_W, SHIP_H)), Color(0.45, 0.65, 0.90, 0.70), false, 3.0)
	# 操控室标记（世界层，便于远处识别）
	var cr := _control_local
	draw_circle(cr, 28.0, Color(1.0, 0.85, 0.3, 0.12))
	draw_string(font, cr + Vector2(-50, -36), "【操控室】", HORIZONTAL_ALIGNMENT_CENTER, 100, 14, Color(1.0, 0.88, 0.35))
	draw_circle(_seat_local, 14.0, Color(0.95, 0.72, 0.28, 0.35))
	draw_arc(_seat_local, 16.0, 0, TAU, 18, Color(1.0, 0.82, 0.35, 0.9), 2.0)
	draw_string(font, _seat_local + Vector2(-40, -28), "驾驶座", HORIZONTAL_ALIGNMENT_CENTER, 80, 12, Color(1.0, 0.85, 0.40))
	if can_contest(world._player if world else null) and is_in_control_room(world._player if world else null):
		draw_string(font, cr + Vector2(-70, 40), "[E] 夺取飞船", HORIZONTAL_ALIGNMENT_CENTER, 140, 13, Color(1.0, 0.55, 0.32))
	elif can_hijack(world._player if world else null) and is_in_control_room(world._player if world else null):
		draw_string(font, cr + Vector2(-60, 40), "[E] 劫持飞船", HORIZONTAL_ALIGNMENT_CENTER, 120, 13, Color(1.0, 0.72, 0.28))
	var label: String
	if state == S.CRUISE:
		label = "飞船·悬浮巡航"
	elif state == S.HIJACK:
		label = "飞船·驾驶中  开往破解点"
	elif state == S.CRACKING:
		label = "飞船·破解 %.0f/%.0f 秒" % [crack_t, Tuning.spaceship_crack_hold]
	else:
		label = "飞船·密闭舱已开放"
	draw_string(font, Vector2(-half.x, -half.y - 14), label, HORIZONTAL_ALIGNMENT_LEFT, int(SHIP_W), 14, Color(0.8, 0.9, 1.0))

func _draw_portals() -> void:
	var r: float = portal_radius()
	var font := ThemeDB.fallback_font
	for i in _portal_exterior.size():
		var off: Vector2 = _portal_exterior[i]
		draw_circle(off, r, Color(0.55, 0.88, 1.0, 0.18))
		draw_arc(off, r, 0, TAU, 32, Color(0.65, 0.95, 1.0, 0.85), 3.0)
		draw_line(off, off + Vector2(0, 120), Color(0.5, 0.85, 1.0, 0.35), 4.0)
		var side := "左" if i == 0 else "右"
		draw_string(font, off + Vector2(-r, -r - 10),
			"【传送门·%s】" % side, HORIZONTAL_ALIGNMENT_CENTER, int(r * 2.8), 16, Color(0.75, 0.98, 1.0))
		draw_string(font, off + Vector2(-r, -r + 12),
			"进入/离开 · 靠近1秒", HORIZONTAL_ALIGNMENT_CENTER, int(r * 2.8), 13, Color(0.55, 0.85, 0.95))
	for i in _portal_interior.size():
		var off: Vector2 = _portal_interior[i]
		draw_circle(off, r * 0.7, Color(0.45, 0.92, 0.75, 0.10))
		draw_arc(off, r * 0.7, 0, TAU, 24, Color(0.50, 1.0, 0.70, 0.55), 2.0)
		var side := "左" if i == 0 else "右"
		draw_string(font, off + Vector2(-r, -20),
			"【传送门·%s】" % side, HORIZONTAL_ALIGNMENT_CENTER, int(r * 2.0), 13, Color(0.55, 1.0, 0.75))

func _draw_sealed_label() -> void:
	if sealed_preview_value <= 0:
		return
	var font := ThemeDB.fallback_font
	var sr := _sealed_local
	draw_rect(Rect2(sr - Vector2(90, 50), Vector2(180, 36)), Color(0.25, 0.08, 0.14, 0.75), true)
	draw_string(font, sr + Vector2(0, -38),
		"【密闭舱】", HORIZONTAL_ALIGNMENT_CENTER, 160, 15, Color(0.95, 0.55, 0.72))
	draw_string(font, sr + Vector2(0, -20),
		"预估总价值 ¥%d" % sealed_preview_value, HORIZONTAL_ALIGNMENT_CENTER, 180, 14, Color(1.0, 0.82, 0.42))
	draw_string(font, sr + Vector2(0, -4),
		"密闭舱已开放，可搜刮" if sealed_open else "破解后可搜刮取出", HORIZONTAL_ALIGNMENT_CENTER, 180, 11,
		Color(0.55, 1.0, 0.72) if sealed_open else Color(0.85, 0.70, 0.75))

func _ready() -> void:
	if _interior_root != null:
		pass
	# 地板绘制挂在 interior_root
	call_deferred("_hook_floor_draw")

func _hook_floor_draw() -> void:
	if _interior_root == null:
		return
	if not _interior_root.draw.is_connected(_draw_interior_floors):
		_interior_root.draw.connect(_draw_interior_floors)

func _draw_interior_floors() -> void:
	for fr in _floor_rects:
		_interior_root.draw_rect(fr, Color(0.38, 0.42, 0.48), true)
	for wr in _wall_rects:
		_interior_root.draw_rect(wr, Color(0.17, 0.18, 0.22), true)
		_interior_root.draw_rect(wr, Color(0.34, 0.36, 0.42), false, 2.0)
	# 操控室地面高亮
	var cr := Rect2(
		Vector2(_control_rect.position.x * TILE, _control_rect.position.y * TILE),
		Vector2(_control_rect.size.x * TILE, _control_rect.size.y * TILE))
	_interior_root.draw_rect(cr, Color(1.0, 0.85, 0.3, 0.10), true)
	_interior_root.draw_rect(cr, Color(1.0, 0.85, 0.35, 0.55), false, 2.0)
	var font := ThemeDB.fallback_font
	_interior_root.draw_string(font,
		Vector2(cr.position.x + cr.size.x * 0.5, cr.position.y + 16),
		"操控室  驾驶座 [E]劫持" if not sealed_open else "操控室  驾驶座",
		HORIZONTAL_ALIGNMENT_CENTER, int(cr.size.x), 13, Color(1.0, 0.88, 0.35))
	var seat_px := Vector2(
		(_seat_local.x + SHIP_W * 0.5) - 10.0,
		(_seat_local.y + SHIP_H * 0.5) - 10.0)
	_interior_root.draw_rect(Rect2(seat_px, Vector2(20, 20)), Color(1.0, 0.78, 0.28, 0.55), true)
	# 密闭舱地面
	var sr := Rect2(
		Vector2(_sealed_rect.position.x * TILE, _sealed_rect.position.y * TILE),
		Vector2(_sealed_rect.size.x * TILE, _sealed_rect.size.y * TILE))
	_interior_root.draw_rect(sr, Color(0.85, 0.35, 0.55, 0.08), true)
	_interior_root.draw_rect(sr, Color(0.95, 0.45, 0.65, 0.45), false, 2.0)
