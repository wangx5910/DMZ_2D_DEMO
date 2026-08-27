extends StaticBody2D
## Cover · 甬道边小型掩体
## - 挡子弹 / 挡视线（与墙同层）
## - 贴墙侧放置，不堵甬道中央通行
## - 南北向甬道 → 横向长条（探进甬道，不当竖条贴墙）
## - 东西向甬道 → 竖向长条
## - 提供站位：威胁方向的反侧 = 掩体后；侧面 = peek

var wall_dir := Vector2.RIGHT
var half := Vector2(16.0, 6.0)
var ns_corridor := false
var _configured := false

func setup(world_pos: Vector2, toward_wall: Vector2, along_ns: bool = false) -> void:
	ns_corridor = along_ns
	if toward_wall.length_squared() > 0.01:
		wall_dir = toward_wall.normalized()
	else:
		wall_dir = Vector2.DOWN if along_ns else Vector2.RIGHT
	_apply_half()
	_configured = true
	if is_inside_tree():
		global_position = world_pos + wall_dir * 5.0
	else:
		position = world_pos + wall_dir * 5.0
	if get_child_count() == 0:
		_build()
	else:
		_sync_shape()
	queue_redraw()

func _ready() -> void:
	add_to_group("cover")
	if get_child_count() == 0 and _configured:
		_build()

func _apply_half() -> void:
	# 长轴垂直于甬道：南北走 → 横向；东西走 → 竖向
	if ns_corridor or absf(wall_dir.x) > absf(wall_dir.y):
		half = Vector2(16.0, 6.0)
	else:
		half = Vector2(6.0, 16.0)

func _build() -> void:
	collision_layer = (1 << 0) | (1 << 3)
	collision_mask = 0
	z_index = 3
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = half * 2.0
	shape.shape = box
	add_child(shape)
	_add_occluder()

func _sync_shape() -> void:
	collision_layer = (1 << 0) | (1 << 3)
	for c in get_children():
		if c is CollisionShape2D and c.shape is RectangleShape2D:
			c.shape.size = half * 2.0
		elif c is LightOccluder2D:
			c.queue_free()
	_add_occluder()

func _add_occluder() -> void:
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(half.x, half.y), Vector2(-half.x, half.y)
	])
	poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
	occ.occluder = poly
	add_child(occ)

func _into_corridor() -> Vector2:
	if wall_dir.length_squared() < 0.01:
		return Vector2.DOWN
	return -wall_dir.normalized()

func _along_corridor() -> Vector2:
	return _into_corridor().orthogonal()

## 站在掩体后：必须留在甬道可行走侧。旧版沿“远离威胁”推 22px，
## 威胁在甬道里时这个方向就是墙内，AI 会顶墙抖动。
func stand_behind(threat_pos: Vector2) -> Vector2:
	var into := _into_corridor()
	var along := _along_corridor()
	var away := global_position - threat_pos
	var s: float = signf(away.dot(along))
	if s == 0.0:
		s = 1.0
	return global_position + into * 14.0 + along * s * 12.0

## peek：沿甬道探出，同样不往墙里走
func peek_point(threat_pos: Vector2) -> Vector2:
	var into := _into_corridor()
	var along := _along_corridor()
	var to_threat := threat_pos - global_position
	var s: float = signf(to_threat.dot(along))
	if s == 0.0:
		s = 1.0
	return global_position + into * 14.0 + along * s * 22.0

func _draw() -> void:
	draw_rect(Rect2(-half, half * 2.0), Color(0.42, 0.36, 0.28), true)
	draw_rect(Rect2(-half, half * 2.0), Color(0.55, 0.48, 0.38), false, 1.5)
	if half.x >= half.y:
		draw_line(Vector2(-half.x + 2, 0), Vector2(half.x - 2, 0), Color(0.32, 0.28, 0.22), 1.2)
	else:
		draw_line(Vector2(0, -half.y + 2), Vector2(0, half.y - 2), Color(0.32, 0.28, 0.22), 1.2)
