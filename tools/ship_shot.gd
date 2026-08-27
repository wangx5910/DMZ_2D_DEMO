extends Node
## 临时截图：强制刷出飞船（F2 链路）并把玩家挪到船旁，验证巨型建筑渲染无运行时错误
var _f := 0
func _process(_d: float) -> void:
	_f += 1
	var p = get_parent()
	match _f:
		5:
			Tuning.set_value("god_mode", true)
			p.level.force_spawn_spaceship()
			Tuning.set_value("camera_zoom", 0.30)
			# 等降落（约 2 秒）后把玩家挪到飞船中心，相机跟玩家即可框住整船
		90:
			if p.level.spaceship != null:
				p.player.global_position = p.level.spaceship.global_position + Vector2(0, 0)
		120: _grab("ship_building")
		140:
			# 站入光柱口（下方入口）示范登舰入口视觉
			if p.level.spaceship != null:
				p.player.global_position = p.level.spaceship.global_position + p.level.spaceship._entry_local[2]
		170: _grab("ship_pillar_entry")
		185: get_tree().quit(0)

func _grab(n: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var dir := ProjectSettings.globalize_path("res://tools/shots")
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir.path_join(n + ".png"))
	print("  -> ", n)
