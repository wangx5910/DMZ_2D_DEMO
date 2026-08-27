extends Area2D
## Depot · 物资提交点。打开 8×5 网络存储箱：寄存 / 按倍率提交。
## 任意寄存或提交后退出，本点消耗，地图置灰。未就绪时只显示倒计时。

var mul: float = 1.0
var wave: int = 0
var ready_at: float = 0.0
var consumed: bool = false
var _focused := false

func setup(world_pos: Vector2, multiplier: float = 1.0, ready_time: float = 0.0, wave_i: int = 0) -> void:
	global_position = world_pos
	mul = multiplier
	ready_at = ready_time
	wave = wave_i

func _ready() -> void:
	add_to_group("depots")
	collision_layer = 1 << 2
	collision_mask = 0
	z_index = 4
	var shape := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = 18.0
	shape.shape = circ
	add_child(shape)

func raid_time() -> float:
	var w = get_parent()
	if w != null and "raid_time" in w:
		return float(w.raid_time)
	return 0.0

func is_ready() -> bool:
	return not consumed and raid_time() + 0.001 >= ready_at

func ready_remain() -> float:
	return maxf(0.0, ready_at - raid_time())

func consume() -> void:
	consumed = true
	queue_redraw()

func accent_color() -> Color:
	if consumed:
		return Color(0.42, 0.43, 0.46)
	if mul >= 4.5:
		return Color(1.0, 0.28, 0.28)
	if mul >= 1.5:
		return Color(0.82, 0.38, 1.0)
	return Color(0.35, 0.95, 0.55)

func interact_prompt() -> String:
	if consumed:
		return "提交点已使用"
	if not is_ready():
		return "提交点冷却中（%s 后可用 · ×%.1f）" % [_fmt_remain(ready_remain()), mul]
	return "[E] 物资提交点  ×%.1f" % mul

func try_interact(who) -> bool:
	if who == null or consumed:
		return false
	if not is_ready():
		return false
	if who.get("searching_container") != null and who.has_method("abort_search"):
		who.abort_search("deposit")
	var root = who.get_tree().get_first_node_in_group("raid_root")
	if root != null and root.get("deposit_ui") != null and root.deposit_ui.has_method("open_at"):
		root.deposit_ui.open_at(self)
		return true
	return false

func set_focused(on: bool) -> void:
	_focused = on
	queue_redraw()

func _process(_delta: float) -> void:
	if not consumed and not is_ready():
		queue_redraw()

func _fmt_remain(sec: float) -> String:
	var s: int = maxi(0, int(ceil(sec)))
	return "%d:%02d" % [s / 60, s % 60]

func _draw() -> void:
	var col := accent_color()
	if not consumed and not is_ready():
		col = col.darkened(0.45)
	var a: float = 0.14 if consumed else 0.22
	draw_circle(Vector2.ZERO, 16.0, Color(col.r, col.g, col.b, a))
	draw_arc(Vector2.ZERO, 16.0, 0, TAU, 24, col, 2.0 if consumed else 2.4)
	draw_rect(Rect2(Vector2(-8, -6), Vector2(16, 12)), col, true)
	draw_rect(Rect2(Vector2(-5, -9), Vector2(10, 5)), col, false, 1.6)
	var label := "提交点 ×%.1f" % mul
	if consumed:
		label = "提交点（已用）"
	elif not is_ready():
		label = "提交点 %s" % _fmt_remain(ready_remain())
	draw_string(ThemeDB.fallback_font, Vector2(-48, -24), label,
		HORIZONTAL_ALIGNMENT_CENTER, 96, 13, col)
	if _focused and not consumed:
		draw_arc(Vector2.ZERO, 22.0, 0, TAU, 28, Color(0.85, 0.95, 1.0), 1.6)
