extends Area2D
## Depot · 物资提交点。先交互呼叫，倒计时结束后才可提交。
## 任意寄存或提交后退出，本点消耗，地图置灰。

enum Phase { CALLABLE, CALLING, OPEN, CONSUMED }

var mul: float = 1.0
var wave: int = 0
var depot_uid: int = 0
var phase: int = Phase.CALLABLE
var appear_at: float = 0.0
var consumed: bool = false
var _focused := false

func setup(world_pos: Vector2, multiplier: float = 1.0, _ready_time: float = 0.0, wave_i: int = 0) -> void:
	global_position = world_pos
	mul = multiplier
	wave = wave_i
	phase = Phase.CALLABLE
	consumed = false
	appear_at = 0.0

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

func is_calling() -> bool:
	return phase == Phase.CALLING and not consumed

func is_callable() -> bool:
	return phase == Phase.CALLABLE and not consumed

func is_open() -> bool:
	return phase == Phase.OPEN and not consumed

## 兼容旧接口：可提交才算 ready
func is_ready() -> bool:
	return is_open()

func ready_remain() -> float:
	if phase != Phase.CALLING:
		return 0.0
	return maxf(0.0, appear_at - raid_time())

func can_submit() -> bool:
	return is_open()

func consume() -> void:
	consumed = true
	phase = Phase.CONSUMED
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
	match phase:
		Phase.CALLABLE:
			return "[E] 呼叫提交点  ×%.1f（呼叫后 %.0f 秒出现）" % [mul, Tuning.depot_call_time]
		Phase.CALLING:
			return "提交点呼叫中（%s 后出现 · ×%.1f）" % [_fmt_remain(ready_remain()), mul]
		Phase.OPEN:
			return "[E] 物资提交点  ×%.1f" % mul
	return "提交点已使用"

func try_interact(who) -> bool:
	if who == null or consumed:
		return false
	if phase == Phase.CALLABLE:
		return _begin_call(who)
	if phase == Phase.CALLING:
		return false
	if phase != Phase.OPEN:
		return false
	if who.get("searching_container") != null and who.has_method("abort_search"):
		who.abort_search("deposit")
	var root = who.get_tree().get_first_node_in_group("raid_root")
	if root != null and root.get("deposit_ui") != null and root.deposit_ui.has_method("open_at"):
		root.deposit_ui.open_at(self)
		return true
	return false

func apply_call_state(at: float) -> void:
	if consumed or phase == Phase.OPEN or phase == Phase.CONSUMED:
		return
	phase = Phase.CALLING
	appear_at = at
	queue_redraw()

func _begin_call(who) -> bool:
	if NetHub.is_online() and not NetHub.is_authority():
		NetHub.request_depot_call(depot_uid)
		return true
	return start_call(who)

func start_call(_who = null) -> bool:
	if consumed or phase != Phase.CALLABLE:
		return false
	phase = Phase.CALLING
	appear_at = raid_time() + Tuning.depot_call_time
	queue_redraw()
	var w = get_parent()
	if w != null and w.has_method("on_depot_called"):
		w.on_depot_called(self)
	if NetHub.is_online() and NetHub.is_authority():
		NetHub.broadcast_depot_called(depot_uid, appear_at)
	return true

func set_focused(on: bool) -> void:
	_focused = on
	queue_redraw()

func _process(_delta: float) -> void:
	if consumed:
		return
	if phase == Phase.CALLING:
		if raid_time() + 0.001 >= appear_at:
			phase = Phase.OPEN
			var w = get_parent()
			if w != null and w.has_method("on_depot_opened"):
				w.on_depot_opened(self)
			queue_redraw()
		else:
			queue_redraw()
	elif phase == Phase.CALLABLE:
		queue_redraw()

func _fmt_remain(sec: float) -> String:
	var s: int = maxi(0, int(ceil(sec)))
	return "%d:%02d" % [s / 60, s % 60]

func _draw() -> void:
	var col := accent_color()
	if consumed:
		pass
	elif phase == Phase.CALLING:
		col = col.lightened(0.15)
	elif phase == Phase.CALLABLE:
		col = col.darkened(0.25)
	var a: float = 0.14 if consumed else 0.22
	draw_circle(Vector2.ZERO, 16.0, Color(col.r, col.g, col.b, a))
	draw_arc(Vector2.ZERO, 16.0, 0, TAU, 24, col, 2.0 if consumed else 2.4)
	draw_rect(Rect2(Vector2(-8, -6), Vector2(16, 12)), col, true)
	draw_rect(Rect2(Vector2(-5, -9), Vector2(10, 5)), col, false, 1.6)
	var label := "提交点 ×%.1f" % mul
	if consumed:
		label = "提交点（已用）"
	elif phase == Phase.CALLABLE:
		label = "呼叫点 ×%.1f" % mul
	elif phase == Phase.CALLING:
		label = "呼叫中 %s" % _fmt_remain(ready_remain())
	draw_string(ThemeDB.fallback_font, Vector2(-48, -24), label,
		HORIZONTAL_ALIGNMENT_CENTER, 96, 13, col)
	if _focused and not consumed:
		draw_arc(Vector2.ZERO, 22.0, 0, TAU, 28, Color(0.85, 0.95, 1.0), 1.6)
	if phase == Phase.CALLING:
		var pulse: float = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.012)
		draw_arc(Vector2.ZERO, 20.0 + pulse * 10.0, 0, TAU, 28,
			Color(col.r, col.g, col.b, 0.55), 1.8)
