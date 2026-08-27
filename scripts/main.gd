extends Node2D
## Main · 局内根节点，负责组装与生命周期
##
## 全部子节点在代码里构建，理由：大锤不开编辑器也能通过读一份脚本理解结构；
## 场景文件保持最小，避免 .tscn 手改出错。

const LEVEL := preload("res://scripts/world/level.gd")
const WORLD_MAP := preload("res://scripts/world/world_map.gd")
const PLAYER := preload("res://scripts/player/player.gd")
const VISION := preload("res://scripts/player/vision.gd")
const BODY := preload("res://scripts/player/player_body.gd")
const CAMERA := preload("res://scripts/player/player_camera.gd")
const HUD := preload("res://scripts/ui/hud.gd")
const LOOT_UI := preload("res://scripts/ui/loot_ui.gd")
const DEPOSIT_UI := preload("res://scripts/ui/deposit_ui.gd")
const DEBUG_PANEL := preload("res://scripts/ui/debug_panel.gd")
const COMBAT_FX := preload("res://scripts/combat/combat_fx.gd")
const CROSSHAIR := preload("res://scripts/ui/crosshair.gd")
const MINIMAP := preload("res://scripts/ui/minimap.gd")
const LAN_LOBBY := preload("res://scripts/ui/lan_lobby.gd")
# GridInventory / Weapon 已通过 class_name 注册为全局类，直接 new 即可

## 无类型引用：这些节点的脚本自定义成员在强类型下会编译报错
var level
var player
var inv: GridInventory
var hud
var loot_ui
var deposit_ui
var minimap
var fx
var crosshair
var _darkness: CanvasModulate
var _lobby = null
var _session_started := false
var _rebuilding := false
var net_players: Dictionary = {}  ## peer_id -> node

func _ready() -> void:
	add_to_group("raid_root")
	Tuning.value_changed.connect(_on_tuning_changed)
	if not NetHub.session_ready.is_connected(_on_session_ready):
		NetHub.session_ready.connect(_on_session_ready)
	if not NetHub.peer_joined.is_connected(_on_net_peer_joined):
		NetHub.peer_joined.connect(_on_net_peer_joined)
	if not NetHub.peer_left.is_connected(_on_net_peer_left):
		NetHub.peer_left.connect(_on_net_peer_left)
	if not NetHub.shot_fx.is_connected(_on_net_shot_fx):
		NetHub.shot_fx.connect(_on_net_shot_fx)
	if not NetHub.ai_snapshot.is_connected(_on_ai_snapshot):
		NetHub.ai_snapshot.connect(_on_ai_snapshot)
	if not NetHub.raid_restart.is_connected(_on_raid_restart):
		NetHub.raid_restart.connect(_on_raid_restart)
	_maybe_attach_selftest()
	if _should_skip_lobby():
		_start_session()
	else:
		_show_lobby()

## 自动化自检挂载：命令行加 `-- --scene-test` 时挂上测试节点，跑几帧后自动断言退出。
## 用途：改完代码不用手动开窗口点，命令行就能验证整条链路没坏。
func _maybe_attach_selftest() -> void:
	var args := OS.get_cmdline_user_args()
	if "--scene-test" in args:
		var t := Node.new()
		t.set_script(load("res://tools/scene_test.gd"))
		t.name = "SceneTest"
		add_child(t)
	if "--world-test" in args:
		var wt := Node.new()
		wt.set_script(load("res://tools/world_test.gd"))
		wt.name = "WorldTest"
		add_child(wt)
	if "--ai-test" in args:
		var at := Node.new()
		at.set_script(load("res://tools/ai_test.gd"))
		at.name = "AiTest"
		add_child(at)
	if "--stuck-test" in args:
		var st := Node.new()
		st.set_script(load("res://tools/stuck_test.gd"))
		st.name = "StuckTest"
		add_child(st)
	if "--vehicle-test" in args:
		var vt := Node.new()
		vt.set_script(load("res://tools/vehicle_test.gd"))
		vt.name = "VehicleTest"
		add_child(vt)
	if "--loot-test" in args:
		var lt := Node.new()
		lt.set_script(load("res://tools/loot_test.gd"))
		lt.name = "LootTest"
		add_child(lt)
	if "--chase-test" in args:
		var ct := Node.new()
		ct.set_script(load("res://tools/chase_test.gd"))
		ct.name = "ChaseTest"
		add_child(ct)
	if "--flow-test" in args:
		var ft := Node.new()
		ft.set_script(load("res://tools/flow_test.gd"))
		ft.name = "FlowTest"
		add_child(ft)
	if "--ship-test" in args:
		var st2 := Node.new()
		st2.set_script(load("res://tools/ship_test.gd"))
		st2.name = "ShipTest"
		add_child(st2)
	if "--shot" in args:
		var s := Node.new()
		s.set_script(load("res://tools/shot.gd"))
		s.name = "ShotTool"
		add_child(s)
	if "--ship-shot" in args:
		var ss := Node.new()
		ss.set_script(load("res://tools/ship_shot.gd"))
		ss.name = "ShipShot"
		add_child(ss)

func _should_skip_lobby() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	var args := OS.get_cmdline_user_args()
	for a in args:
		if str(a).begins_with("--") and (str(a).ends_with("-test") or str(a) in ["--shot", "--ship-shot"]):
			return true
	return false

func _show_lobby() -> void:
	_lobby = CanvasLayer.new()
	_lobby.set_script(LAN_LOBBY)
	_lobby.name = "LanLobby"
	add_child(_lobby)
	_lobby.solo_requested.connect(_on_lobby_solo)
	_lobby.host_requested.connect(_on_lobby_host)
	_lobby.join_requested.connect(_on_lobby_join)

func _hide_lobby() -> void:
	if _lobby != null and is_instance_valid(_lobby):
		_lobby.queue_free()
	_lobby = null

func _on_lobby_solo() -> void:
	NetHub.leave_lan()
	NetHub.ensure_seed()
	_hide_lobby()
	_start_session()

func _on_lobby_host(room_name: String, port: int) -> void:
	NetHub.host_name = room_name
	var err: Error = NetHub.host_lan(port)
	if err != OK:
		return
	_hide_lobby()
	# session_ready 已由 host_lan 发出

func _on_lobby_join(ip: String, port: int) -> void:
	if ip == "":
		if _lobby != null:
			_lobby.set_busy("请填写房主 IP")
		return
	if _lobby != null:
		_lobby.set_busy("正在连接 %s:%d …" % [ip, port])
	NetHub.join_lan(ip, port)

func _on_session_ready() -> void:
	if _session_started:
		return
	_hide_lobby()
	_start_session()
	for id in NetHub.pending_peers:
		if id != NetHub.local_peer_id:
			_spawn_net_puppet(id)

func _start_session() -> void:
	if _session_started:
		return
	_session_started = true
	_build_world()
	_build_player()
	_build_ui()
	RaidLog.start_raid()

func _on_net_peer_joined(id: int) -> void:
	if not _session_started:
		return
	if level != null and level.has_method("despawn_ai_at_squad") \
			and level.has_method("spawn_squad_id_for_peer"):
		level.despawn_ai_at_squad(level.spawn_squad_id_for_peer(id))
	_spawn_net_puppet(id)

func _on_net_peer_left(id: int) -> void:
	var p = net_players.get(id, null)
	if p != null and is_instance_valid(p):
		p.queue_free()
	net_players.erase(id)
	NetHub.unregister_player(id)

func _on_net_shot_fx(from: Vector2, to: Vector2, speed: float) -> void:
	if fx != null:
		fx.add_tracer(from, to, speed)
		fx.add_muzzle(from, (to - from).normalized() if to.distance_to(from) > 1.0 else Vector2.RIGHT)

func _spawn_net_puppet(pid: int) -> void:
	if pid == NetHub.local_peer_id:
		return
	if net_players.has(pid) and is_instance_valid(net_players[pid]):
		return
	if player == null:
		return
	var puppet = _make_player_node(pid, false)
	net_players[pid] = puppet
	NetHub.register_player(puppet)
	if fx != null:
		puppet.set_fx(fx)

func pack_ai_snapshot() -> PackedByteArray:
	var sp := StreamPeerBuffer.new()
	sp.big_endian = false
	var enemies: Array = []
	if level != null and level.get("enemies_root") != null:
		enemies = level.enemies_root.get_children()
	var bots: Array = []
	if level != null and level.get("raider_bots_root") != null:
		bots = level.raider_bots_root.get_children()
	sp.put_u16(enemies.size())
	for e in enemies:
		sp.put_float(e.global_position.x)
		sp.put_float(e.global_position.y)
		sp.put_float(e.rotation)
		var hp := 0.0
		if e.get("health") != null:
			hp = float(e.health.hp)
		sp.put_float(hp)
		sp.put_u8(1 if (e.has_method("is_dead") and e.is_dead()) else 0)
	sp.put_u16(bots.size())
	for b in bots:
		sp.put_float(b.global_position.x)
		sp.put_float(b.global_position.y)
		sp.put_float(b.rotation)
		var hp2 := 0.0
		if b.get("health") != null:
			hp2 = float(b.health.hp)
		sp.put_float(hp2)
		sp.put_u8(1 if (b.has_method("is_dead") and b.is_dead()) else 0)
	if level != null and level.get("spaceship") != null and is_instance_valid(level.spaceship):
		sp.put_u8(1)
		sp.put_float(level.spaceship.global_position.x)
		sp.put_float(level.spaceship.global_position.y)
		sp.put_u8(int(level.spaceship.state))
		sp.put_float(float(level.raid_time))
	else:
		sp.put_u8(0)
		sp.put_float(float(level.raid_time) if level != null else 0.0)
	return sp.data_array

func _on_ai_snapshot(blob: PackedByteArray) -> void:
	if NetHub.is_authority() or level == null:
		return
	var sp := StreamPeerBuffer.new()
	sp.data_array = blob
	sp.big_endian = false
	sp.seek(0)
	if sp.get_available_bytes() < 2:
		return
	var n_e: int = sp.get_u16()
	var eroot = level.get("enemies_root")
	for i in n_e:
		if sp.get_available_bytes() < 17:
			return
		var x := sp.get_float()
		var y := sp.get_float()
		var rot := sp.get_float()
		var hp := sp.get_float()
		var dead: bool = sp.get_u8() != 0
		if eroot != null and i < eroot.get_child_count():
			var e = eroot.get_child(i)
			e.global_position = Vector2(x, y)
			e.rotation = rot
			if e.get("health") != null:
				e.health.hp = hp
				e.health.dead = dead
	if sp.get_available_bytes() < 2:
		return
	var n_b: int = sp.get_u16()
	var broot = level.get("raider_bots_root")
	for i in n_b:
		if sp.get_available_bytes() < 17:
			return
		var x2 := sp.get_float()
		var y2 := sp.get_float()
		var rot2 := sp.get_float()
		var hp2 := sp.get_float()
		var dead2: bool = sp.get_u8() != 0
		if broot != null and i < broot.get_child_count():
			var b = broot.get_child(i)
			b.global_position = Vector2(x2, y2)
			b.rotation = rot2
			if b.get("health") != null:
				b.health.hp = hp2
				b.health.dead = dead2
	if sp.get_available_bytes() < 1:
		return
	var has_ship: int = sp.get_u8()
	if has_ship == 1 and sp.get_available_bytes() >= 13:
		var sx := sp.get_float()
		var sy := sp.get_float()
		var st: int = sp.get_u8()
		var rt := sp.get_float()
		level.raid_time = rt
		if level.get("spaceship") != null and is_instance_valid(level.spaceship):
			level.spaceship.global_position = Vector2(sx, sy)
			level.spaceship.state = st
	elif has_ship == 0 and sp.get_available_bytes() >= 4:
		level.raid_time = sp.get_float()

func _make_player_node(pid: int, is_local: bool):
	var node := CharacterBody2D.new()
	node.set_script(PLAYER)
	node.name = "Player_%d" % pid if not is_local else "Player"
	node.peer_id = pid
	var sid: int = 0
	if level != null and level.has_method("spawn_squad_id_for_peer"):
		sid = level.spawn_squad_id_for_peer(pid)
	node.spawn_squad_id = sid
	node.team_id = sid
	node.net_tag = "P%d" % pid
	node.collision_layer = 1 << 1
	node.collision_mask = 1 << 0
	node.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	node.z_index = 10
	if level != null and level.has_method("spawn_point_for_peer"):
		node.global_position = level.spawn_point_for_peer(pid)
	elif level != null:
		node.global_position = level.spawn_point

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 11.0
	shape.shape = circle
	node.add_child(shape)

	var body := Node2D.new()
	body.set_script(BODY)
	body.name = "Body"
	node.add_child(body)

	if is_local:
		var vision := Node2D.new()
		vision.set_script(VISION)
		vision.name = "Vision"
		node.add_child(vision)
		var cam := Camera2D.new()
		cam.set_script(CAMERA)
		cam.name = "Cam"
		node.add_child(cam)

	add_child(node)
	return node

func _build_world() -> void:
	# 场景整体压暗，扇形光照区域恢复亮度 = 视野遮蔽的实现基础
	_darkness = CanvasModulate.new()
	_apply_darkness()
	add_child(_darkness)

	# 关卡模式：大地图（2km 分区世界）或小图（单栈手工关卡，用于快速验证 3C）
	if Tuning.use_world_map:
		level = Node2D.new()
		level.set_script(WORLD_MAP)
		level.name = "World"
	else:
		level = Node2D.new()
		level.set_script(LEVEL)
		level.name = "Level"
	add_child(level)
	# 容器等子节点在 _ready() 里生成，此时 spawn_point 已就绪

func _apply_darkness() -> void:
	if _darkness == null:
		return
	if not Tuning.enable_vision_cone:
		_darkness.color = Color.WHITE
		return
	# 下限 0.02：CanvasModulate 是乘法，取 0 会把画面彻底乘没，
	# 连视野内的光照也救不回来（MIX 光照仍要乘底色）。
	# 0.02 在视觉上等同全黑，但保留了光照可恢复的余量。
	var b: float = clampf(Tuning.terrain_memory_brightness, 0.02, 1.0)
	_darkness.color = Color(b, b, minf(b * 1.06, 1.0), 1.0)

func _build_player() -> void:
	var pid: int = NetHub.local_peer_id
	player = _make_player_node(pid, true)
	NetHub.register_player(player)
	net_players[pid] = player
	if level.has_method("set_player"):
		level.set_player(player)

	fx = Node2D.new()
	fx.set_script(COMBAT_FX)
	fx.name = "CombatFX"
	add_child(fx)
	player.set_fx(fx)

	if level.has_method("spawn_enemies"):
		level.spawn_enemies(fx)
	if level.has_method("spawn_vehicles"):
		level.spawn_vehicles(fx)
	if level.has_method("spawn_raider_bots"):
		level.spawn_raider_bots(fx)
	if level.has_method("spawn_contracts"):
		level.spawn_contracts(fx)
	player.team_id = player.spawn_squad_id

	crosshair = Node2D.new()
	crosshair.set_script(CROSSHAIR)
	crosshair.name = "Crosshair"
	add_child(crosshair)
	crosshair.setup(player)

func _build_ui() -> void:
	inv = GridInventory.new(Tuning.backpack_cols, Tuning.backpack_rows)
	player.inv = inv
	player.stash = GridInventory.new(Tuning.stash_cols, Tuning.stash_rows)

	hud = CanvasLayer.new()
	hud.set_script(HUD)
	hud.name = "HUD"
	add_child(hud)
	hud.setup(player, inv, level)

	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)
	loot_ui = Control.new()
	loot_ui.set_script(LOOT_UI)
	loot_ui.name = "LootUI"
	ui_layer.add_child(loot_ui)
	loot_ui.setup(player, inv)

	deposit_ui = Control.new()
	deposit_ui.set_script(DEPOSIT_UI)
	deposit_ui.name = "DepositUI"
	ui_layer.add_child(deposit_ui)
	deposit_ui.setup(player, inv)

	# 小地图 / 全屏地图（M 键）
	minimap = CanvasLayer.new()
	minimap.set_script(MINIMAP)
	minimap.name = "Minimap"
	add_child(minimap)
	minimap.setup(level, player)

	var dbg := CanvasLayer.new()
	dbg.set_script(DEBUG_PANEL)
	dbg.name = "DebugPanel"
	add_child(dbg)

func _on_tuning_changed(key: String, _v: Variant) -> void:
	if key in ["terrain_memory_brightness", "enable_vision_cone"]:
		_apply_darkness()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart_raid"):
		restart_raid()
	elif event.is_action_pressed("inventory"):
		# T = 背包开关。有容器/提交面板时关闭；否则打开独立背包视图
		if deposit_ui != null and deposit_ui.visible:
			deposit_ui.close_panel()
		elif loot_ui != null and loot_ui.visible:
			loot_ui.close_panel()
		else:
			loot_ui.open_backpack_only()

func restart_raid() -> void:
	if NetHub.is_online() and not NetHub.is_authority():
		return
	var path := RaidLog.end_raid("restart")
	print("[RaidLog] 本局日志已导出：", path)
	if NetHub.mode == NetHub.Mode.HOST:
		var seed: int = randi()
		if seed == 0:
			seed = 1
		NetHub.broadcast_raid_restart(seed)
		return
	NetHub.world_seed = 0
	get_tree().reload_current_scene()

func _on_raid_restart(_seed: int) -> void:
	_rebuild_raid()

func _rebuild_raid() -> void:
	if _rebuilding:
		return
	_rebuilding = true
	_teardown_session()
	await get_tree().process_frame
	await get_tree().process_frame
	_hide_lobby()
	_start_session()
	for id in NetHub.connected_peer_ids():
		if id != NetHub.local_peer_id:
			_spawn_net_puppet(id)
	_rebuilding = false

func _teardown_session() -> void:
	_session_started = false
	player = null
	level = null
	inv = null
	hud = null
	loot_ui = null
	deposit_ui = null
	minimap = null
	fx = null
	crosshair = null
	_darkness = null
	net_players.clear()
	NetHub.player_nodes.clear()
	var drop: Array = []
	for c in get_children():
		if c == _lobby:
			continue
		drop.append(c)
	for c in drop:
		c.queue_free()

func clear_backpack() -> void:
	inv.clear()
	if player != null and player.get("stash") != null:
		player.stash.clear()
	RaidLog.log_event("backpack_cleared")

## 调试面板「悬浮至破解点」按钮转发：level 即 WorldMap 实例
func debug_force_descent() -> void:
	if level != null and is_instance_valid(level) and level.has_method("debug_force_descent"):
		level.debug_force_descent()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		var path := RaidLog.end_raid("quit")
		print("[RaidLog] 退出前日志已导出：", path)
		NetHub.leave_lan()
