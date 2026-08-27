extends CanvasLayer
## LanLobby · 开局选单机 / 开房 / 加入
##
## 全自绘+控件。自动化测试 / headless 不会打开本层。

signal solo_requested
signal host_requested(room_name: String, port: int)
signal join_requested(ip: String, port: int)

var _status: Label
var _ip_edit: LineEdit
var _port_edit: LineEdit
var _name_edit: LineEdit
var _list: VBoxContainer
var _banner: Label

func _ready() -> void:
	layer = 40
	_build()
	if not NetHub.hosts_updated.is_connected(_on_hosts):
		NetHub.hosts_updated.connect(_on_hosts)
	if not NetHub.net_message.is_connected(_on_msg):
		NetHub.net_message.connect(_on_msg)
	NetHub.start_discovering()

func _exit_tree() -> void:
	if NetHub.mode != NetHub.Mode.HOST:
		NetHub.stop_discovering()

func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.04, 0.05, 0.07, 0.92)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -280
	panel.offset_top = -260
	panel.offset_right = 280
	panel.offset_bottom = 280
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.98)
	sb.border_color = Color(0.42, 0.55, 0.72)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)

	var title := Label.new()
	title.text = "海湾城  ·  局域网对战"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	col.add_child(title)

	_banner = Label.new()
	_banner.text = "同一 Wi-Fi / 局域网。一人开房，其他人加入。"
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 13)
	_banner.add_theme_color_override("font_color", Color(0.70, 0.78, 0.88))
	col.add_child(_banner)

	col.add_child(_btn("单机进入", func(): solo_requested.emit()))

	var row_n := HBoxContainer.new()
	row_n.add_theme_constant_override("separation", 8)
	col.add_child(row_n)
	row_n.add_child(_lbl("房间名", 64))
	_name_edit = LineEdit.new()
	_name_edit.text = OS.get_environment("USERNAME")
	if _name_edit.text == "":
		_name_edit.text = "策划房"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_n.add_child(_name_edit)

	var row_p := HBoxContainer.new()
	row_p.add_theme_constant_override("separation", 8)
	col.add_child(row_p)
	row_p.add_child(_lbl("端口", 64))
	_port_edit = LineEdit.new()
	_port_edit.text = str(NetHub.DEFAULT_PORT)
	_port_edit.custom_minimum_size.x = 90
	row_p.add_child(_port_edit)
	var ip_hint := Label.new()
	ip_hint.text = "本机 " + NetHub.primary_ip()
	ip_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_hint.add_theme_color_override("font_color", Color(0.55, 0.90, 0.70))
	row_p.add_child(ip_hint)

	col.add_child(_btn("创建房间（房主）", func():
		NetHub.host_name = _name_edit.text.strip_edges()
		if NetHub.host_name == "":
			NetHub.host_name = "海湾城房间"
		host_requested.emit(NetHub.host_name, _port())))

	var row_j := HBoxContainer.new()
	row_j.add_theme_constant_override("separation", 8)
	col.add_child(row_j)
	row_j.add_child(_lbl("房主 IP", 64))
	_ip_edit = LineEdit.new()
	_ip_edit.placeholder_text = "192.168.x.x"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_j.add_child(_ip_edit)
	col.add_child(_btn("加入房间", func():
		join_requested.emit(_ip_edit.text.strip_edges(), _port())))

	var disc := Label.new()
	disc.text = "局域网房间"
	disc.add_theme_color_override("font_color", Color(0.55, 0.75, 0.95))
	col.add_child(disc)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 110)
	col.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_empty_list()

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color(0.85, 0.78, 0.45))
	_status.text = "正在搜索局域网房间…"
	col.add_child(_status)

	var tip := Label.new()
	tip.text = "搜不到时：关防火墙或允许端口 %d / %d，用手填房主 IP。" % [
		NetHub.DEFAULT_PORT, NetHub.DISCOVERY_PORT]
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", 11)
	tip.add_theme_color_override("font_color", Color(0.50, 0.56, 0.64))
	col.add_child(tip)

func _port() -> int:
	var p: int = int(_port_edit.text)
	return p if p > 0 else NetHub.DEFAULT_PORT

func _lbl(text: String, w: float) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = w
	return l

func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 32
	b.pressed.connect(cb)
	return b

func _empty_list() -> void:
	for c in _list.get_children():
		c.queue_free()
	var l := Label.new()
	l.text = "（暂无，可手动填 IP）"
	l.add_theme_color_override("font_color", Color(0.45, 0.50, 0.56))
	_list.add_child(l)

func _on_hosts(hosts: Array) -> void:
	for c in _list.get_children():
		c.queue_free()
	if hosts.is_empty():
		_empty_list()
		return
	for h in hosts:
		var ip := str(h.get("ip", ""))
		var port: int = int(h.get("port", NetHub.DEFAULT_PORT))
		var nam := str(h.get("name", "房间"))
		var n: int = int(h.get("n", 1))
		var b := Button.new()
		b.text = "%s  ·  %s:%d  ·  %d 人" % [nam, ip, port, n]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func():
			_ip_edit.text = ip
			_port_edit.text = str(port)
			join_requested.emit(ip, port))
		_list.add_child(b)

func _on_msg(text: String) -> void:
	_status.text = text

func set_busy(text: String) -> void:
	_status.text = text
