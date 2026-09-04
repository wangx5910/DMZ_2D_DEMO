extends Node2D
## ContractSite · 上传机柜 / 塔台天线（纯视觉锚点）

enum Kind { UPLOAD, TOWER }

var kind: int = Kind.UPLOAD
var label := "上传点"

func setup(world_pos: Vector2, k: int, tag: String) -> void:
	kind = k
	label = tag
	global_position = world_pos

func _ready() -> void:
	add_to_group("contract_sites")
	z_index = 6
	queue_redraw()

func _draw() -> void:
	if kind == Kind.TOWER:
		var col := Color(0.45, 0.92, 0.72)
		draw_circle(Vector2.ZERO, 10.0, Color(col.r, col.g, col.b, 0.22))
		draw_rect(Rect2(Vector2(-4, -22), Vector2(8, 28)), col, true)
		draw_line(Vector2(-10, -8), Vector2(10, -8), col, 2.0)
		draw_line(Vector2(-7, -16), Vector2(7, -16), col, 1.6)
		draw_circle(Vector2(0, -24), 4.0, Color(1.0, 0.85, 0.35))
		draw_string(ThemeDB.fallback_font, Vector2(-28, 18), label,
			HORIZONTAL_ALIGNMENT_CENTER, 56, 12, col)
	else:
		var col := Color(0.42, 0.78, 1.0)
		draw_rect(Rect2(Vector2(-12, -10), Vector2(24, 20)), col * Color(1, 1, 1, 0.85), true)
		draw_rect(Rect2(Vector2(-12, -10), Vector2(24, 20)), col.lightened(0.3), false, 1.6)
		draw_rect(Rect2(Vector2(-8, -6), Vector2(6, 4)), Color(0.15, 0.85, 0.55), true)
		draw_rect(Rect2(Vector2(1, -6), Vector2(6, 4)), Color(0.95, 0.72, 0.28), true)
		draw_string(ThemeDB.fallback_font, Vector2(-32, 18), label,
			HORIZONTAL_ALIGNMENT_CENTER, 64, 12, col)
