extends CanvasLayer
## DebugPanel · 实时参数面板 + 机制开关 + 日志导出
##
## 从 Tuning.SPEC / Tuning.TOGGLES 自动生成 UI —— 加一个新参数只需在 tuning.gd
## 里加一行，面板自动出现滑条，无需改本文件。这是让大锤能自己调数值的关键。
##
## F1 开关面板。面板打开时游戏不暂停（要边跑边调才有意义）。

var _root: PanelContainer
var _sliders := {}
var _status: Label

func _ready() -> void:
	layer = 20
	_build()
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		visible = not visible
		get_viewport().set_input_as_handled()

func _build() -> void:
	_root = PanelContainer.new()
	_root.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_root.offset_left = -430
	_root.offset_top = 12
	_root.offset_right = -12
	_root.offset_bottom = 900
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.10, 0.96)
	sb.border_color = Color(0.30, 0.36, 0.46)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	_root.add_theme_stylebox_override("panel", sb)
	add_child(_root)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(400, 760)
	_root.add_child(scroll)

	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 386
	col.add_theme_constant_override("separation", 4)
	scroll.add_child(col)

	col.add_child(_title("调试面板 · F1 开关"))

	# ── 机制开关 ──
	col.add_child(_section("机制开关（A/B 对比）"))
	var toggle_grid := GridContainer.new()
	toggle_grid.columns = 2
	col.add_child(toggle_grid)
	for t in Tuning.TOGGLES:
		var cb := CheckBox.new()
		cb.text = t[1]
		cb.button_pressed = Tuning.get(t[0])
		var key: String = t[0]
		cb.toggled.connect(func(on: bool):
			Tuning.set_value(key, on)
			RaidLog.log_event("toggle", {"key": key, "value": on}))
		toggle_grid.add_child(cb)

	# ── 参数滑条（按分组自动生成）──
	for group in Tuning.SPEC:
		col.add_child(_section(group))
		for entry in Tuning.SPEC[group]:
			col.add_child(_slider_row(entry[0], entry[1], entry[2]))

	# ── 操作 ──
	col.add_child(_section("操作"))
	var btns := HBoxContainer.new()
	col.add_child(btns)
	btns.add_child(_button("导出日志", func():
		var path := RaidLog.export_logs()
		_set_status("已导出：%s" % path)))
	btns.add_child(_button("保存数值", func():
		Tuning.save_overrides()
		_set_status("数值已存到 user://tuning_override.json，下次启动自动沿用")))
	btns.add_child(_button("恢复默认", func():
		Tuning.reset_all()
		_refresh_sliders()
		_set_status("已恢复默认数值")))

	var btns2 := HBoxContainer.new()
	col.add_child(btns2)
	btns2.add_child(_button("重开本局 (F5)", func():
		get_tree().call_group("raid_root", "restart_raid")))
	btns2.add_child(_button("清空背包", func():
		get_tree().call_group("raid_root", "clear_backpack")
		_set_status("背包已清空")))
	btns2.add_child(_button("悬浮至破解点", func():
		get_tree().call_group("raid_root", "debug_force_descent")
		_set_status("已触发飞船悬浮至破解点（未刷出则先刷出）")))

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(380, 40)
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))
	col.add_child(_status)

	col.add_child(_hint("日志与数值文件位置：Godot 菜单 → 项目 → 打开用户数据文件夹 → logs/"))

func _title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	return l

func _section(text: String) -> Label:
	var l := Label.new()
	l.text = "── " + text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.55, 0.75, 0.95))
	return l

func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(380, 32)
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", Color(0.45, 0.50, 0.58))
	return l

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b

func _slider_row(key: String, lo: float, hi: float) -> Control:
	var row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = key
	name_lbl.custom_minimum_size.x = 168
	name_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(name_lbl)

	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = _step_for(lo, hi)
	s.value = Tuning.get(key)
	s.custom_minimum_size.x = 150
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(s)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size.x = 56
	val_lbl.add_theme_font_size_override("font_size", 11)
	val_lbl.text = _fmt(s.value)
	row.add_child(val_lbl)

	s.value_changed.connect(func(v: float):
		Tuning.set_value(key, v)
		val_lbl.text = _fmt(v))
	_sliders[key] = [s, val_lbl]
	return row

func _step_for(lo: float, hi: float) -> float:
	var span := hi - lo
	if span <= 2.0:
		return 0.01
	if span <= 60.0:
		return 0.5
	return 1.0

func _fmt(v: float) -> String:
	return ("%.2f" % v) if absf(v) < 10.0 else ("%.0f" % v)

func _refresh_sliders() -> void:
	for key in _sliders:
		var s: HSlider = _sliders[key][0]
		s.set_value_no_signal(Tuning.get(key))
		_sliders[key][1].text = _fmt(Tuning.get(key))

func _set_status(msg: String) -> void:
	if _status:
		_status.text = msg
