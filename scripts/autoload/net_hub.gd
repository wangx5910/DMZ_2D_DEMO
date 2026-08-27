extends Node
## NetHub · 局域网联机（ENet）
##
## 房主权威：世界 seed、AI、伤害结算。各端只操控自己的角色。
## 单机 mode=SOLO，行为与接入前一致。

enum Mode { SOLO, HOST, CLIENT }

signal peer_joined(id: int)
signal peer_left(id: int)
signal mode_changed(mode: Mode)
signal session_ready()
signal hosts_updated(hosts: Array)
signal net_message(text: String)
signal shot_fx(from: Vector2, to: Vector2, speed: float)
signal ai_snapshot(blob: PackedByteArray)
signal raid_restart(seed: int)

const DEFAULT_PORT := 24567
const DISCOVERY_PORT := 24568
const MAX_PLAYERS := 8
const STATE_HZ := 15.0
const AI_HZ := 8.0
const HUMAN_TEAM_BASE := 10000

var mode: Mode = Mode.SOLO
var local_peer_id: int = 1
var world_seed: int = 0
var host_name: String = "海湾城房间"
var join_ip: String = "127.0.0.1"
var bind_port: int = DEFAULT_PORT
var player_nodes: Dictionary = {}   ## peer_id -> Player
var discovered: Array = []          ## [{ip, port, name, n, age}]
var pending_peers: PackedInt32Array = []
var spawn_slot: Dictionary = {}     ## peer_id -> 出生槽（0=房主点，其后按距房主由近到远）

var _peer: ENetMultiplayerPeer = null
var _udp: PacketPeerUDP = null
var _udp_listen: PacketPeerUDP = null
var _discover_t := 0.0
var _state_t := 0.0
var _ai_t := 0.0
var _announce_t := 0.0
var _signals_bound := false

func is_online() -> bool:
	return mode != Mode.SOLO

func is_authority() -> bool:
	if mode == Mode.SOLO:
		return true
	return multiplayer.is_server()

func is_local(pid: int) -> bool:
	return pid == local_peer_id

func human_team_id(pid: int) -> int:
	return HUMAN_TEAM_BASE + pid

## 人类玩家之间视为队友（不开枪）；同 team_id 的 AI 也不互伤
func are_allied(a, b) -> bool:
	if a == null or b == null:
		return false
	if a == b:
		return true
	var ha: bool = a.is_in_group("human_players")
	var hb: bool = b.is_in_group("human_players")
	if ha and hb:
		return true
	var ta = a.get("team_id")
	var tb = b.get("team_id")
	if ta == null or tb == null:
		return false
	return int(ta) == int(tb)

func spawn_slot_of(pid: int) -> int:
	if spawn_slot.has(pid):
		return int(spawn_slot[pid])
	if spawn_slot.has(str(pid)):
		return int(spawn_slot[str(pid)])
	return 0

func claim_spawn_slot(pid: int) -> int:
	var cur: int = spawn_slot_of(pid)
	if spawn_slot.has(pid) or spawn_slot.has(str(pid)):
		return cur
	var used := {}
	for k in spawn_slot:
		used[int(spawn_slot[k])] = true
	var i := 0
	while used.has(i):
		i += 1
	spawn_slot[pid] = i
	return i

func connected_peer_ids() -> PackedInt32Array:
	var ids: PackedInt32Array = PackedInt32Array()
	if not is_online():
		ids.append(local_peer_id)
		return ids
	ids.append(1)
	if multiplayer.has_multiplayer_peer():
		for p in multiplayer.get_peers():
			if not ids.has(p):
				ids.append(p)
	if not ids.has(local_peer_id):
		ids.append(local_peer_id)
	return ids

func local_ips() -> PackedStringArray:
	var out: PackedStringArray = []
	for a in IP.get_local_addresses():
		var s := str(a)
		if s.begins_with("127.") or s.contains(":"):
			continue
		if s.begins_with("169.254."):
			continue
		out.append(s)
	return out

func primary_ip() -> String:
	var ips := local_ips()
	for s in ips:
		if s.begins_with("192.168.") or s.begins_with("10.") or s.begins_with("172."):
			return s
	return ips[0] if ips.size() > 0 else "127.0.0.1"

func player_count() -> int:
	return maxi(1, player_nodes.size())

func register_player(p) -> void:
	if p == null:
		return
	player_nodes[int(p.peer_id)] = p

func unregister_player(pid: int) -> void:
	player_nodes.erase(pid)

func get_player(pid: int):
	return player_nodes.get(pid, null)

# ── 容器锁（联机时房主权威）────────────────────────────
var _container_locks: Dictionary = {}

func request_container_lock(container) -> bool:
	if container == null:
		return false
	var key: String = str(container.get_path())
	if mode == Mode.SOLO:
		if _container_locks.has(key) and _container_locks[key] != local_peer_id:
			return false
		_container_locks[key] = local_peer_id
		return true
	if is_authority():
		if _container_locks.has(key) and int(_container_locks[key]) != local_peer_id:
			return false
		_container_locks[key] = local_peer_id
		_rpc_lock_set.rpc(key, local_peer_id)
		return true
	_rpc_lock_ask.rpc_id(1, key, local_peer_id)
	if _container_locks.has(key) and int(_container_locks[key]) != local_peer_id:
		return false
	_container_locks[key] = local_peer_id
	return true

func release_container_lock(container) -> void:
	if container == null:
		return
	var key: String = str(container.get_path())
	if _container_locks.get(key, local_peer_id) != local_peer_id:
		return
	_container_locks.erase(key)
	if is_online():
		if is_authority():
			_rpc_lock_clear.rpc(key)
		else:
			_rpc_lock_clear.rpc_id(1, key)

func container_locked_by_other(container) -> bool:
	if container == null:
		return false
	var key: String = str(container.get_path())
	return _container_locks.has(key) and int(_container_locks[key]) != local_peer_id

@rpc("any_peer", "reliable")
func _rpc_lock_ask(key: String, pid: int) -> void:
	if not is_authority():
		return
	if _container_locks.has(key) and int(_container_locks[key]) != pid:
		return
	_container_locks[key] = pid
	_rpc_lock_set.rpc(key, pid)

@rpc("any_peer", "reliable")
func _rpc_lock_set(key: String, pid: int) -> void:
	_container_locks[key] = pid

@rpc("any_peer", "reliable")
func _rpc_lock_clear(key: String) -> void:
	_container_locks.erase(key)

# ── 开房 / 加入 ─────────────────────────────────────────
func host_lan(port: int = DEFAULT_PORT) -> Error:
	leave_lan()
	bind_port = port
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		net_message.emit("开房失败（端口 %d 被占用？）" % port)
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	local_peer_id = 1
	spawn_slot.clear()
	spawn_slot[1] = 0
	if world_seed == 0:
		world_seed = randi()
		if world_seed == 0:
			world_seed = 1
	_bind_mp_signals()
	_start_discovery_reply()
	mode_changed.emit(mode)
	net_message.emit("已开房  %s:%d" % [primary_ip(), port])
	session_ready.emit()
	return OK

func join_lan(ip: String, port: int = DEFAULT_PORT) -> Error:
	leave_lan()
	join_ip = ip.strip_edges()
	bind_port = port
	if join_ip == "":
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(join_ip, port)
	if err != OK:
		net_message.emit("连接失败")
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	_bind_mp_signals()
	mode_changed.emit(mode)
	net_message.emit("正在连接 %s:%d …" % [join_ip, port])
	return OK

func leave_lan() -> void:
	_stop_discovery()
	if _signals_bound:
		if multiplayer.peer_connected.is_connected(_on_peer_connected):
			multiplayer.peer_connected.disconnect(_on_peer_connected)
		if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
			multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
		if multiplayer.connected_to_server.is_connected(_on_connected_ok):
			multiplayer.connected_to_server.disconnect(_on_connected_ok)
		if multiplayer.connection_failed.is_connected(_on_connected_fail):
			multiplayer.connection_failed.disconnect(_on_connected_fail)
		if multiplayer.server_disconnected.is_connected(_on_server_drop):
			multiplayer.server_disconnected.disconnect(_on_server_drop)
		_signals_bound = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	_peer = null
	mode = Mode.SOLO
	local_peer_id = 1
	player_nodes.clear()
	_container_locks.clear()
	spawn_slot.clear()
	mode_changed.emit(mode)

func ensure_seed() -> int:
	if world_seed == 0:
		world_seed = randi()
		if world_seed == 0:
			world_seed = 1
	return world_seed

# ── 信号 ────────────────────────────────────────────────
func _bind_mp_signals() -> void:
	if _signals_bound:
		return
	_signals_bound = true
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_drop)

func _on_peer_connected(id: int) -> void:
	if is_authority():
		claim_spawn_slot(id)
		_rpc_welcome.rpc_id(id, world_seed, host_name, _peer_list_plus(id), spawn_slot)
		_rpc_spawn_slots.rpc(spawn_slot)
		_rpc_peer_join.rpc(id)
	peer_joined.emit(id)
	net_message.emit("玩家 #%d 加入" % id)

func _on_peer_disconnected(id: int) -> void:
	unregister_player(id)
	peer_left.emit(id)
	net_message.emit("玩家 #%d 离开" % id)

func _on_connected_ok() -> void:
	local_peer_id = multiplayer.get_unique_id()
	net_message.emit("已连上房主，等待地图种子…")

func _on_connected_fail() -> void:
	net_message.emit("连接失败：检查 IP、端口和防火墙")
	leave_lan()

func _on_server_drop() -> void:
	net_message.emit("房主已断开")
	leave_lan()

func _peer_list_plus(new_id: int) -> PackedInt32Array:
	var ids: PackedInt32Array = [1]
	for p in multiplayer.get_peers():
		if not ids.has(p):
			ids.append(p)
	if not ids.has(new_id):
		ids.append(new_id)
	return ids

@rpc("authority", "reliable")
func _rpc_welcome(seed: int, room: String, ids: PackedInt32Array, slots: Dictionary) -> void:
	world_seed = seed
	host_name = room
	local_peer_id = multiplayer.get_unique_id()
	pending_peers = ids
	spawn_slot = slots
	net_message.emit("已进入「%s」" % room)
	session_ready.emit()

@rpc("authority", "reliable")
func _rpc_spawn_slots(slots: Dictionary) -> void:
	spawn_slot = slots

@rpc("authority", "reliable")
func _rpc_peer_join(id: int) -> void:
	if id == local_peer_id:
		return
	peer_joined.emit(id)

# ── 玩家状态 / 射击 / 伤害 ──────────────────────────────
func send_player_state(p) -> void:
	if not is_online() or p == null:
		return
	_rpc_player_state.rpc(int(p.peer_id), p.global_position.x, p.global_position.y,
		p.aim_dir.x, p.aim_dir.y, int(p.stance),
		float(p.health.hp) if p.health else 0.0,
		p.is_dead())

@rpc("any_peer", "unreliable")
func _rpc_player_state(pid: int, x: float, y: float, ax: float, ay: float, stance: int, hp: float, dead: bool) -> void:
	if pid == local_peer_id:
		return
	var p = get_player(pid)
	if p != null and p.has_method("apply_net_state"):
		p.apply_net_state(Vector2(x, y), Vector2(ax, ay), stance, hp, dead)

func send_shot(from: Vector2, to: Vector2, speed: float) -> void:
	if not is_online():
		return
	_rpc_shot.rpc(from.x, from.y, to.x, to.y, speed)

@rpc("any_peer", "unreliable")
func _rpc_shot(fx: float, fy: float, tx: float, ty: float, speed: float) -> void:
	if multiplayer.get_remote_sender_id() == local_peer_id:
		return
	shot_fx.emit(Vector2(fx, fy), Vector2(tx, ty), speed)

func report_player_hit(target_peer: int, amount: float, from: Vector2) -> void:
	if not is_online() or amount <= 0.0:
		return
	if is_authority():
		_deliver_hit(target_peer, amount, from)
	else:
		_rpc_report_hit.rpc_id(1, target_peer, amount, from.x, from.y)

@rpc("any_peer", "reliable")
func _rpc_report_hit(target_peer: int, amount: float, fx: float, fy: float) -> void:
	if not is_authority():
		return
	_deliver_hit(target_peer, amount, Vector2(fx, fy))

func _deliver_hit(target_peer: int, amount: float, from: Vector2) -> void:
	_rpc_apply_hit.rpc(target_peer, amount, from.x, from.y)

@rpc("authority", "reliable", "call_local")
func _rpc_apply_hit(target_peer: int, amount: float, fx: float, fy: float) -> void:
	var p = get_player(target_peer)
	if p == null or not is_instance_valid(p):
		return
	if not is_local(int(p.peer_id)):
		return
	if p.has_method("take_net_damage"):
		p.take_net_damage(amount, Vector2(fx, fy))
	elif p.has_method("take_damage"):
		p.take_damage(amount, Vector2(fx, fy))

# ── 载具 ────────────────────────────────────────────────
func find_vehicle(nid: int):
	var tree := get_tree()
	if tree == null:
		return null
	for v in tree.get_nodes_in_group("vehicles"):
		if is_instance_valid(v) and int(v.get("net_id")) == nid:
			return v
	return null

func request_vehicle_board(veh_id: int) -> void:
	if not is_online():
		return
	if is_authority():
		_vehicle_try_board(veh_id, local_peer_id)
	else:
		_rpc_vehicle_board_ask.rpc_id(1, veh_id, local_peer_id)

func request_vehicle_exit(veh_id: int) -> void:
	if not is_online():
		return
	if is_authority():
		_vehicle_try_exit(veh_id, local_peer_id)
	else:
		_rpc_vehicle_exit_ask.rpc_id(1, veh_id, local_peer_id)

@rpc("any_peer", "reliable")
func _rpc_vehicle_board_ask(veh_id: int, pid: int) -> void:
	if not is_authority():
		return
	_vehicle_try_board(veh_id, pid)

@rpc("any_peer", "reliable")
func _rpc_vehicle_exit_ask(veh_id: int, pid: int) -> void:
	if not is_authority():
		return
	_vehicle_try_exit(veh_id, pid)

func _vehicle_try_board(veh_id: int, pid: int) -> void:
	var veh = find_vehicle(veh_id)
	if veh == null or not veh.has_method("free_seat"):
		return
	if veh.is_wrecked():
		return
	var seat: int = veh.free_seat()
	if seat < 0:
		return
	_rpc_vehicle_board.rpc(veh_id, pid, seat)

func _vehicle_try_exit(veh_id: int, pid: int) -> void:
	_rpc_vehicle_exit.rpc(veh_id, pid)

@rpc("authority", "reliable", "call_local")
func _rpc_vehicle_board(veh_id: int, pid: int, seat: int) -> void:
	var veh = find_vehicle(veh_id)
	var p = get_player(pid)
	if veh == null or p == null or not is_instance_valid(p):
		return
	if p.has_method("apply_vehicle_board"):
		p.apply_vehicle_board(veh, seat)

@rpc("authority", "reliable", "call_local")
func _rpc_vehicle_exit(veh_id: int, pid: int) -> void:
	var p = get_player(pid)
	if p == null or not is_instance_valid(p):
		return
	if p.has_method("apply_vehicle_exit"):
		p.apply_vehicle_exit()

func send_vehicle_state(v) -> void:
	if not is_online() or v == null:
		return
	var s0 := 0
	var s1 := 0
	var s2 := 0
	var s3 := 0
	if v.seats.size() > 0 and v.seats[0] != null and is_instance_valid(v.seats[0]):
		s0 = int(v.seats[0].get("peer_id")) if v.seats[0].get("peer_id") != null else 0
	if v.seats.size() > 1 and v.seats[1] != null and is_instance_valid(v.seats[1]):
		s1 = int(v.seats[1].get("peer_id")) if v.seats[1].get("peer_id") != null else 0
	if v.seats.size() > 2 and v.seats[2] != null and is_instance_valid(v.seats[2]):
		s2 = int(v.seats[2].get("peer_id")) if v.seats[2].get("peer_id") != null else 0
	if v.seats.size() > 3 and v.seats[3] != null and is_instance_valid(v.seats[3]):
		s3 = int(v.seats[3].get("peer_id")) if v.seats[3].get("peer_id") != null else 0
	var fuse: float = float(v.get("_explode_timer")) if v.get("_explode_timer") != null else 0.0
	_rpc_vehicle_state.rpc(
		int(v.net_id), v.global_position.x, v.global_position.y,
		v.heading.angle(), v.speed,
		float(v.health.hp) if v.health else 0.0,
		1 if v._exploding else 0, fuse,
		s0, s1, s2, s3)

@rpc("any_peer", "unreliable")
func _rpc_vehicle_state(nid: int, x: float, y: float, ang: float, spd: float,
		hp: float, exploding: int, fuse: float,
		s0: int, s1: int, s2: int, s3: int) -> void:
	if multiplayer.get_remote_sender_id() == local_peer_id:
		return
	var v = find_vehicle(nid)
	if v == null or not v.has_method("apply_net_state"):
		return
	v.apply_net_state(Vector2(x, y), ang, spd, hp, exploding != 0, fuse, [s0, s1, s2, s3])

func broadcast_raid_restart(seed: int) -> void:
	world_seed = seed
	_container_locks.clear()
	_rpc_raid_restart.rpc(seed)
	raid_restart.emit(seed)

@rpc("authority", "reliable")
func _rpc_raid_restart(seed: int) -> void:
	world_seed = seed
	_container_locks.clear()
	raid_restart.emit(seed)

func _flush_vehicle_states() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for v in tree.get_nodes_in_group("vehicles"):
		if not is_instance_valid(v) or not v.has_method("driver"):
			continue
		var d = v.driver()
		var pid := 0
		if d != null and is_instance_valid(d) and d.get("peer_id") != null:
			pid = int(d.get("peer_id"))
		var local_drive: bool = pid > 0 and is_local(pid)
		var remote_drive: bool = pid > 0 and not is_local(pid)
		if local_drive or (is_authority() and not remote_drive):
			send_vehicle_state(v)

# ── AI 快照（房主 → 全员）────────────────────────────────
func send_ai_blob(blob: PackedByteArray) -> void:
	if not is_authority() or not is_online() or blob.is_empty():
		return
	_rpc_ai_blob.rpc(blob)

@rpc("authority", "unreliable")
func _rpc_ai_blob(blob: PackedByteArray) -> void:
	if is_authority():
		return
	ai_snapshot.emit(blob)

# ── UDP 发现 ────────────────────────────────────────────
func start_discovering() -> void:
	if _udp == null:
		_udp = PacketPeerUDP.new()
		_udp.set_broadcast_enabled(true)
		_udp.bind(0)
	_discover_t = 0.0
	_broadcast_query()

func stop_discovering() -> void:
	if _udp != null:
		_udp.close()
		_udp = null

func _start_discovery_reply() -> void:
	if _udp_listen != null:
		return
	_udp_listen = PacketPeerUDP.new()
	_udp_listen.set_broadcast_enabled(true)
	if _udp_listen.bind(DISCOVERY_PORT) != OK:
		net_message.emit("房间广播端口 %d 被占用，别人可能搜不到，请用手输 IP" % DISCOVERY_PORT)

func _stop_discovery() -> void:
	stop_discovering()
	if _udp_listen != null:
		_udp_listen.close()
		_udp_listen = null

func _broadcast_query() -> void:
	if _udp == null:
		return
	var payload := JSON.stringify({"t": "Q", "v": 1})
	var bytes := payload.to_utf8_buffer()
	_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_udp.put_packet(bytes)

func _process(delta: float) -> void:
	_poll_udp()
	if mode == Mode.CLIENT and _udp != null:
		_discover_t += delta
		if _discover_t >= 1.4:
			_discover_t = 0.0
			_broadcast_query()
		_age_hosts(delta)
	if mode == Mode.SOLO and _udp != null:
		_discover_t += delta
		if _discover_t >= 1.4:
			_discover_t = 0.0
			_broadcast_query()
		_age_hosts(delta)
	if not is_online():
		return
	_state_t += delta
	if _state_t >= 1.0 / STATE_HZ:
		_state_t = 0.0
		var mine = get_player(local_peer_id)
		if mine != null and is_instance_valid(mine):
			send_player_state(mine)
		_flush_vehicle_states()
	if is_authority():
		_ai_t += delta
		if _ai_t >= 1.0 / AI_HZ:
			_ai_t = 0.0
			var root = get_tree().get_first_node_in_group("raid_root")
			if root != null and root.has_method("pack_ai_snapshot"):
				send_ai_blob(root.pack_ai_snapshot())

func _poll_udp() -> void:
	if _udp_listen != null:
		while _udp_listen.get_available_packet_count() > 0:
			var pkt: PackedByteArray = _udp_listen.get_packet()
			var ip: String = _udp_listen.get_packet_ip()
			var from_port: int = _udp_listen.get_packet_port()
			_on_udp_packet(pkt, ip, from_port, true)
	if _udp != null:
		while _udp.get_available_packet_count() > 0:
			var pkt2: PackedByteArray = _udp.get_packet()
			var ip2: String = _udp.get_packet_ip()
			var from_port2: int = _udp.get_packet_port()
			_on_udp_packet(pkt2, ip2, from_port2, false)

func _on_udp_packet(pkt: PackedByteArray, ip: String, from_port: int, as_host: bool) -> void:
	var txt := pkt.get_string_from_utf8()
	var data = JSON.parse_string(txt)
	if not (data is Dictionary):
		return
	var t: String = str(data.get("t", ""))
	if as_host and t == "Q" and mode == Mode.HOST:
		var reply := JSON.stringify({
			"t": "R",
			"port": bind_port,
			"n": player_count(),
			"name": host_name,
			"ip": primary_ip(),
		})
		if from_port > 0:
			_udp_listen.set_dest_address(ip, from_port)
			_udp_listen.put_packet(reply.to_utf8_buffer())
		return
	if t == "R":
		_remember_host(ip if ip != "" else str(data.get("ip", "")),
			int(data.get("port", DEFAULT_PORT)),
			str(data.get("name", "房间")), int(data.get("n", 1)))

func _remember_host(ip: String, port: int, nam: String, n: int) -> void:
	if ip == "" or ip.begins_with("127."):
		# 仍记录，本机开两份客户端要用
		pass
	for h in discovered:
		if str(h.get("ip")) == ip and int(h.get("port")) == port:
			h["n"] = n
			h["name"] = nam
			h["age"] = 0.0
			hosts_updated.emit(discovered)
			return
	discovered.append({"ip": ip, "port": port, "name": nam, "n": n, "age": 0.0})
	hosts_updated.emit(discovered)

func _age_hosts(delta: float) -> void:
	var dirty := false
	for i in range(discovered.size() - 1, -1, -1):
		discovered[i]["age"] = float(discovered[i].get("age", 0.0)) + delta
		if float(discovered[i]["age"]) > 5.0:
			discovered.remove_at(i)
			dirty = true
	if dirty:
		hosts_updated.emit(discovered)
