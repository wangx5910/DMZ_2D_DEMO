extends Node
## 截图：AI 密度 / 载具 / 爆炸 / 搜刮面板
var _f := 0
var _shots := 0
var _fps: Array[float] = []
var _veh = null

func _process(_d: float) -> void:
	_f += 1
	if _f > 25: _fps.append(Engine.get_frames_per_second())
	var p = get_parent()
	match _f:
		30:
			Tuning.set_value("god_mode", true)
			# 先看 POI 内 AI 密度（还没上车，位置不会被锁）
			var w = p.level
			var np = w.nearest_poi(p.player.global_position)
			if not np.is_empty(): p.player.global_position = np["center"]
			Tuning.set_value("show_enemy_debug", true)
			Tuning.set_value("camera_zoom", 0.38)
		70: _grab("01_poi_ai_density")
		85:
			Tuning.set_value("camera_zoom", 1.0)
			Tuning.set_value("show_enemy_debug", false)
			# 打开最近容器
			var best_c = null
			var bd2 := 1e9
			for cc in get_tree().get_nodes_in_group("containers"):
				var d2 = p.player.global_position.distance_to(cc.global_position)
				if d2 < bd2: bd2 = d2; best_c = cc
			if best_c:
				p.player.global_position = best_c.global_position + Vector2(20, 0)
				p.player._begin_search(best_c)
		95:
			if p.player.searching_container:
				p.player.searching_container.reveal_all()
		130: _grab("02_loot_no_empty")
		145:
			p.loot_ui.close_panel()
			# 找车
			var best = null
			var bd := 1e9
			for v in get_tree().get_nodes_in_group("vehicles"):
				var d = p.player.global_position.distance_to(v.global_position)
				if d < bd: bd = d; best = v
			_veh = best
			if best: p.player.global_position = best.global_position + Vector2(45, 0)
		180: _grab("03_vehicle_closeup")
		195:
			if _veh:
				p.player._enter_vehicle(_veh)
				_veh.speed = 500.0
		230: _grab("04_driving")
		245:
			# 打爆车
			if _veh: _veh.take_damage(9999.0, Vector2.ZERO)
		265: _grab("05_burning_jump_window")
		290:
			# 玩家跳车逃命
			if p.player.vehicle: p.player._exit_vehicle()
		320: _grab("06_jumped_out")
		# 引信 3.2s = 192 帧，245+192 = 437
		450: _grab("07_after_explosion")
		465:
			if p.minimap: p.minimap.full_screen = true
		500: _grab("08_fullmap")
		_: pass
	if _f > 515:
		var sum := 0.0
		for v in _fps: sum += v
		var lo := 9999.0
		for i in _fps.size():
			if i > 30: lo = min(lo, _fps[i])
		print("截图 %d ｜ 平均 %.0f FPS ｜ 稳定后最低 %.0f FPS ｜ 敌人 %d ｜ 载具 %d ｜ 残骸 %d" % [
			_shots, sum/max(_fps.size(),1), lo,
			get_tree().get_nodes_in_group("enemies").size(),
			get_tree().get_nodes_in_group("vehicles").size(),
			get_tree().get_nodes_in_group("wrecks").size()])
		print("玩家血量 %.0f（跳车后应还活着）" % p.player.health.hp)
		get_tree().quit()

func _grab(n: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path("res://tools/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join(n + ".png"))
	_shots += 1
	print("  -> ", n, " (FPS ", Engine.get_frames_per_second(), ")")
