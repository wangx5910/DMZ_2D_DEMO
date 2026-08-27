extends StaticBody2D
## PoiGate · POI 甬道大门
## - 默认关闭，人按 E 开关
## - 关闭时挡人、挡视线、挡车
## - 打开后行人可通过，载具永远撞上（vehicle_blocker 层）

const WORLD := 1 << 0
const VISION := 1 << 3
const VEHICLE_BLOCK := 1 << 7

var ns_span := false          ## true = 门横跨南北开口（东西向墙缝）
var half := Vector2(6.0, 60.0)
var is_open := false
var locked := false           ## 人质房：开局封锁，接取合约后才能开
var is_hostage_seal := false
var _focused := false
var _occ: LightOccluder2D = null

func setup(world_pos: Vector2, outward: Vector2, span_px: float) -> void:
	ns_span = absf(outward.x) > absf(outward.y)
	if ns_span:
		half = Vector2(6.0, maxf(span_px, 40.0) * 0.5)
	else:
		half = Vector2(maxf(span_px, 40.0) * 0.5, 6.0)
	if is_inside_tree():
		global_position = world_pos
	else:
		position = world_pos
	_sync_shape()
	_apply_layers()
	queue_redraw()

func _ready() -> void:
	add_to_group("poi_gates")
	z_index = 5
	if get_child_count() == 0:
		_build()
	_apply_layers()

func _build() -> void:
	collision_mask = 0
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = half * 2.0
	shape.shape = box
	add_child(shape)
	_occ = LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(half.x, half.y), Vector2(-half.x, half.y)
	])
	poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
	_occ.occluder = poly
	add_child(_occ)

func _sync_shape() -> void:
	if get_child_count() == 0:
		_build()
		return
	for c in get_children():
		if c is CollisionShape2D and c.shape is RectangleShape2D:
			c.shape.size = half * 2.0
		elif c is LightOccluder2D:
			_occ = c
			var poly := OccluderPolygon2D.new()
			poly.polygon = PackedVector2Array([
				Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
				Vector2(half.x, half.y), Vector2(-half.x, half.y)
			])
			poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
			c.occluder = poly

func _apply_layers() -> void:
	if is_open:
		collision_layer = VEHICLE_BLOCK
		if _occ != null:
			_occ.visible = false
	else:
		collision_layer = WORLD | VISION | VEHICLE_BLOCK
		if _occ != null:
			_occ.visible = true

func apply_stream_layer(near: bool) -> void:
	if not near:
		collision_layer = 0
		return
	_apply_layers()

func open() -> bool:
	if locked:
		return false
	if is_open:
		return true
	is_open = true
	_apply_layers()
	queue_redraw()
	return true

func unlock() -> void:
	if not locked:
		return
	locked = false
	queue_redraw()

func close() -> void:
	if not is_open:
		return
	is_open = false
	_apply_layers()
	queue_redraw()

func interact_prompt() -> String:
	if locked:
		return "此房间封锁"
	if is_open:
		return "[E] 关闭大门（车辆仍无法通过）"
	if is_hostage_seal:
		return "[E] 打开封锁门"
	return "[E] 打开大门"

func try_interact(_who) -> bool:
	if locked:
		return false
	if is_open:
		close()
	else:
		open()
	return true

func set_focused(on: bool) -> void:
	_focused = on
	queue_redraw()

func closest_point(pos: Vector2) -> Vector2:
	return Vector2(
		clampf(pos.x, global_position.x - half.x, global_position.x + half.x),
		clampf(pos.y, global_position.y - half.y, global_position.y + half.y)
	)

func in_reach(pos: Vector2, rng: float) -> bool:
	return pos.distance_to(closest_point(pos)) <= rng

func _draw() -> void:
	var door := Color(0.38, 0.28, 0.18) if not is_open else Color(0.28, 0.24, 0.20, 0.55)
	var edge := Color(0.62, 0.48, 0.28) if not is_open else Color(0.70, 0.55, 0.30, 0.85)
	if locked:
		door = Color(0.46, 0.16, 0.14)
		edge = Color(0.88, 0.38, 0.28)
	if is_open:
		# 打开：两侧门扇 + 地面禁行坎，车撞这块碰撞体
		var side: float = 7.0
		if ns_span:
			draw_rect(Rect2(Vector2(-half.x, -half.y), Vector2(half.x * 2.0, side)), door, true)
			draw_rect(Rect2(Vector2(-half.x, half.y - side), Vector2(half.x * 2.0, side)), door, true)
			draw_rect(Rect2(Vector2(-3.0, -half.y), Vector2(6.0, half.y * 2.0)), Color(0.90, 0.72, 0.22, 0.55), true)
		else:
			draw_rect(Rect2(Vector2(-half.x, -half.y), Vector2(side, half.y * 2.0)), door, true)
			draw_rect(Rect2(Vector2(half.x - side, -half.y), Vector2(side, half.y * 2.0)), door, true)
			draw_rect(Rect2(Vector2(-half.x, -3.0), Vector2(half.x * 2.0, 6.0)), Color(0.90, 0.72, 0.22, 0.55), true)
	else:
		draw_rect(Rect2(-half, half * 2.0), door, true)
		draw_rect(Rect2(-half, half * 2.0), edge, false, 2.0)
		if ns_span:
			draw_line(Vector2(0, -half.y + 4), Vector2(0, half.y - 4), Color(0.22, 0.16, 0.10), 2.0)
		else:
			draw_line(Vector2(-half.x + 4, 0), Vector2(half.x - 4, 0), Color(0.22, 0.16, 0.10), 2.0)
		if locked:
			var bar := Color(0.95, 0.72, 0.28, 0.9)
			if ns_span:
				draw_rect(Rect2(Vector2(-3.0, -half.y + 6.0), Vector2(6.0, half.y * 2.0 - 12.0)), bar, true)
			else:
				draw_rect(Rect2(Vector2(-half.x + 6.0, -3.0), Vector2(half.x * 2.0 - 12.0, 6.0)), bar, true)
	if _focused:
		draw_rect(Rect2(-half - Vector2(3, 3), half * 2.0 + Vector2(6, 6)),
			Color(1.0, 0.85, 0.35, 0.9), false, 2.0)
