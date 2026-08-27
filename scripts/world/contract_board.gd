extends Area2D
## ContractBoard · 合约交互点（E 接取）

var director = null
var title := "救援人质"
var _focused := false
var consumed := false

func setup(d, world_pos: Vector2, contract_title: String) -> void:
	director = d
	title = contract_title
	global_position = world_pos

func _ready() -> void:
	add_to_group("contract_boards")
	collision_layer = 1 << 2
	collision_mask = 0
	z_index = 4
	var shape := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = 18.0
	shape.shape = circ
	add_child(shape)

func interact_prompt() -> String:
	if consumed:
		return "合约点已使用"
	if director != null and director.has_active_contract():
		return "[E] 已有进行中的合约（同时只能接一个）"
	return "[E] 接取合约：%s" % title

func try_interact(who) -> bool:
	if consumed or director == null:
		return false
	return director.accept_from_board(self, who)

func set_focused(on: bool) -> void:
	_focused = on
	queue_redraw()

func mark_consumed() -> void:
	consumed = true
	queue_redraw()

func _draw() -> void:
	var col := Color(1.0, 0.82, 0.28) if not consumed else Color(0.45, 0.42, 0.38)
	draw_circle(Vector2.ZERO, 16.0, Color(col.r, col.g, col.b, 0.22))
	draw_arc(Vector2.ZERO, 16.0, 0, TAU, 24, col, 2.4)
	draw_rect(Rect2(Vector2(-7, -9), Vector2(14, 18)), col, true)
	draw_rect(Rect2(Vector2(-5, -6), Vector2(10, 3)), Color(0.12, 0.10, 0.08), true)
	draw_string(ThemeDB.fallback_font, Vector2(-36, -22), "合约",
		HORIZONTAL_ALIGNMENT_CENTER, 72, 13, col)
	if _focused and not consumed:
		draw_arc(Vector2.ZERO, 22.0, 0, TAU, 28, Color(1.0, 0.95, 0.55), 1.6)
