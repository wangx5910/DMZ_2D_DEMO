extends Control
## DepositUI · 物资提交点：左 8×5 网络存储箱，右背包。寄存确认 / 按倍率提交。
## Esc 未操作则回滚打开时的背包与寄存。寄存或提交后再退出，提交点消耗。

const CELL := 36
const GAP := 2
const PAD := 18
const HEADER_H := 52
const FOOTER_H := 52

var inv: GridInventory
var player = null
var depot = null
var _font: Font
var _hover_cell := Vector2i(-1, -1)
var _hover_stash := Vector2i(-1, -1)
var _drag := {}
var _toast := ""
var _toast_t := 0.0
var _store_rect := Rect2()
var _submit_rect := Rect2()
var _snap_stash: Array = []
var _snap_bag: Array = []
var _acted := false

func setup(p, inventory: GridInventory) -> void:
	player = p
	inv = inventory
	inv.changed.connect(queue_redraw)
	if p != null and p.get("stash") != null:
		p.stash.changed.connect(queue_redraw)

func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_viewport().size_changed.connect(func():
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		queue_redraw())

func _stash():
	if player != null:
		return player.get("stash")
	return null

func open_at(d) -> void:
	depot = d
	_acted = false
	_drag.clear()
	var st = _stash()
	_snap_stash = st.clone_entries() if st != null else []
	_snap_bag = inv.clone_entries() if inv != null else []
	var root = get_tree().get_first_node_in_group("raid_root")
	if root != null and root.get("loot_ui") != null and root.loot_ui.visible:
		root.loot_ui.close_panel()
	visible = true
	_sync_mouse()
	queue_redraw()

func close_panel() -> void:
	_drag.clear()
	if _acted and depot != null and is_instance_valid(depot) and depot.has_method("consume"):
		depot.consume()
	elif not _acted:
		_restore_snap()
	depot = null
	visible = false
	_sync_mouse()

func _restore_snap() -> void:
	var st = _stash()
	if st != null:
		st.restore_entries(_snap_stash)
	if inv != null:
		inv.restore_entries(_snap_bag)

func _sync_mouse() -> void:
	if player != null:
		player.ui_capturing_mouse = visible

func _vp() -> Vector2:
	return Vector2(get_viewport_rect().size)

func _grid_px(g) -> Vector2:
	if g == null:
		return Vector2.ZERO
	return Vector2(g.cols * (CELL + GAP) - GAP, g.rows * (CELL + GAP) - GAP)

func _panel_rect() -> Rect2:
	var st = _stash()
	var bag_px := _grid_px(inv)
	var stash_px := _grid_px(st)
	var body_h: float = maxf(bag_px.y, stash_px.y)
	var w: float = stash_px.x + bag_px.x + PAD * 3
	var h: float = body_h + HEADER_H + FOOTER_H + PAD + 18.0
	var vp := _vp()
	var pos := Vector2(maxf(0.0, floorf((vp.x - w) * 0.5)), maxf(0.0, floorf((vp.y - h) * 0.5)))
	return Rect2(pos, Vector2(w, h))

func _stash_origin() -> Vector2:
	return _panel_rect().position + Vector2(PAD, HEADER_H + 8)

func _grid_origin() -> Vector2:
	var st = _stash()
	var stash_px := _grid_px(st)
	return _panel_rect().position + Vector2(PAD + stash_px.x + PAD, HEADER_H + 8)

func _cell_of(pos: Vector2, origin: Vector2, g) -> Vector2i:
	if g == null:
		return Vector2i(-1, -1)
	var step := CELL + GAP
	var lx := int(floor((pos.x - origin.x) / step))
	var ly := int(floor((pos.y - origin.y) / step))
	if lx < 0 or ly < 0 or lx >= g.cols or ly >= g.rows:
		return Vector2i(-1, -1)
	return Vector2i(lx, ly)

func _rect_of(origin: Vector2, x: int, y: int, w: int = 1, h: int = 1) -> Rect2:
	var step := CELL + GAP
	return Rect2(origin + Vector2(x * step, y * step), Vector2(w * step - GAP, h * step - GAP))

func _mul() -> float:
	if depot != null and is_instance_valid(depot):
		return float(depot.get("mul"))
	return 1.0

func _process(delta: float) -> void:
	if not visible:
		return
	if player != null and bool(player.get("raid_over")):
		close_panel()
		return
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			queue_redraw()
	if player != null and depot != null and is_instance_valid(depot):
		if player.global_position.distance_to(depot.global_position) > Tuning.interact_range * 1.8:
			close_panel()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R and not _drag.is_empty():
			_drag["rotated"] = not _drag["rotated"]
			queue_redraw()
			accept_event()
		elif event.keycode == KEY_ESCAPE or event.keycode == KEY_T:
			close_panel()
			accept_event()

func _gui_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseMotion:
		_hover_cell = _cell_of(event.position, _grid_origin(), inv)
		_hover_stash = _cell_of(event.position, _stash_origin(), _stash())
		queue_redraw()
	elif event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if _store_rect.has_point(event.position):
					_do_store()
					accept_event()
					return
				if _submit_rect.has_point(event.position):
					_do_submit()
					accept_event()
					return
				_on_left_click(event.position)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_on_right_click(event.position)
		else:
			if event.button_index == MOUSE_BUTTON_LEFT and not _drag.is_empty():
				_drop_at(event.position)

func _on_left_click(pos: Vector2) -> void:
	var st = _stash()
	var sc := _cell_of(pos, _stash_origin(), st)
	if sc.x >= 0 and st != null:
		var ei: int = st.entry_at(sc.x, sc.y)
		if ei >= 0:
			var e: Dictionary = st.entries[ei]
			_drag = {"src": "stash", "index": ei, "id": e["id"], "rotated": e["rotated"]}
			queue_redraw()
			return
	var cell := _cell_of(pos, _grid_origin(), inv)
	if cell.x >= 0:
		var bi := inv.entry_at(cell.x, cell.y)
		if bi >= 0:
			var be: Dictionary = inv.entries[bi]
			_drag = {"src": "grid", "index": bi, "id": be["id"], "rotated": be["rotated"]}
			queue_redraw()

func _on_right_click(pos: Vector2) -> void:
	var st = _stash()
	var sc := _cell_of(pos, _stash_origin(), st)
	if sc.x >= 0 and st != null:
		var ei: int = st.entry_at(sc.x, sc.y)
		if ei >= 0:
			var id: String = st.remove_at_index(ei)
			if id != "" and not inv.add_auto(id):
				st.add_auto(id)
				_flash("背包装不下，仍留在寄存箱")
			queue_redraw()
			return
	var cell := _cell_of(pos, _grid_origin(), inv)
	if cell.x >= 0:
		var bi := inv.entry_at(cell.x, cell.y)
		if bi >= 0:
			var id2: String = inv.remove_at_index(bi)
			if id2 != "" and st != null and not st.add_auto(id2):
				inv.add_auto(id2)
				_flash("寄存箱已满，先筛选替换")
			queue_redraw()

func _drop_at(pos: Vector2) -> void:
	var d: Dictionary = _drag.duplicate()
	_drag.clear()
	var st = _stash()
	var sc := _cell_of(pos, _stash_origin(), st)
	var bc := _cell_of(pos, _grid_origin(), inv)
	if d.get("src", "") == "stash" and st != null:
		if sc.x >= 0:
			if not st.move(int(d["index"]), sc.x, sc.y, bool(d["rotated"])):
				_flash("此处被占用")
		elif bc.x >= 0:
			var id: String = str(d["id"])
			if inv.can_place(id, bc.x, bc.y, bool(d["rotated"])):
				st.remove_at_index(int(d["index"]))
				inv.place(id, bc.x, bc.y, bool(d["rotated"]))
			else:
				_flash("背包放不下——按 R 旋转试试")
	elif d.get("src", "") == "grid":
		if bc.x >= 0:
			if not inv.move(int(d["index"]), bc.x, bc.y, bool(d["rotated"])):
				_flash("此处被占用")
		elif sc.x >= 0 and st != null:
			var id2: String = str(d["id"])
			if st.can_place(id2, sc.x, sc.y, bool(d["rotated"])):
				inv.remove_at_index(int(d["index"]))
				st.place(id2, sc.x, sc.y, bool(d["rotated"]))
			else:
				_flash("寄存箱放不下——按 R 旋转或先筛选")
	queue_redraw()

func _do_store() -> void:
	var st = _stash()
	if st == null or st.entries.is_empty():
		_flash("先把背包物资放入左侧寄存箱")
		return
	_acted = true
	_flash("已寄存 %d 件（¥%d），退出后本点关闭" % [st.entries.size(), st.total_value()])
	queue_redraw()

func _do_submit() -> void:
	var st = _stash()
	if st == null or st.entries.is_empty():
		_flash("寄存箱是空的，没有可提交的物资")
		return
	var mul: float = _mul()
	var base: int = st.total_value()
	var pay: int = int(round(float(base) * maxf(mul, 0.0)))
	var ids: Array = st.item_ids()
	if player != null and player.has_method("secure_value"):
		player.secure_value(pay, ids)
	st.clear()
	_acted = true
	_flash("已提交 ×%.1f  结算 ¥%d（原值 ¥%d）" % [mul, pay, base])
	queue_redraw()

func _flash(msg: String) -> void:
	_toast = msg
	_toast_t = 2.2
	queue_redraw()

func _draw() -> void:
	if inv == null:
		return
	var st = _stash()
	var vp := _vp()
	var pr := _panel_rect()
	var accent := Color(0.35, 0.95, 0.55)
	if depot != null and is_instance_valid(depot) and depot.has_method("accent_color"):
		accent = depot.accent_color()
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.55), true)
	draw_rect(pr, Color(0.075, 0.085, 0.105, 0.985), true)
	draw_rect(pr, accent, false, 2.0)
	draw_rect(Rect2(pr.position, Vector2(pr.size.x, HEADER_H - 10)), Color(0.10, 0.14, 0.18), true)
	draw_string(_font, pr.position + Vector2(PAD, 28), "物资提交点  ×%.1f" % _mul(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, accent)
	var secured := 0
	if player != null:
		secured = int(player.get("secured_value"))
	var st_v: int = st.total_value() if st != null else 0
	var pay: int = int(round(float(st_v) * _mul()))
	draw_string(_font, pr.position + Vector2(pr.size.x - PAD - 420, 28),
		"已提交 ¥%d  ｜  寄存箱 ¥%d → ¥%d" % [secured, st_v, pay],
		HORIZONTAL_ALIGNMENT_RIGHT, 420, 14, Color(0.75, 0.90, 1.0))
	_draw_inv_grid(st, _stash_origin(), _hover_stash,
		"网络存储箱 %d×%d" % [st.cols, st.rows] if st != null else "网络存储箱", "stash")
	_draw_inv_grid(inv, _grid_origin(), _hover_cell, "背包", "grid")
	_draw_drag_ghost(st)
	var by: float = pr.position.y + pr.size.y - FOOTER_H + 10
	_store_rect = Rect2(pr.position + Vector2(PAD, by), Vector2(120, 30))
	_submit_rect = Rect2(pr.position + Vector2(PAD + 132, by), Vector2(168, 30))
	draw_rect(_store_rect, Color(0.16, 0.28, 0.42, 0.95), true)
	draw_rect(_store_rect, Color(0.55, 0.78, 1.0), false, 1.4)
	draw_string(_font, _store_rect.position + Vector2(0, 21), "寄存",
		HORIZONTAL_ALIGNMENT_CENTER, _store_rect.size.x, 14, Color(0.88, 0.94, 1.0))
	draw_rect(_submit_rect, Color(0.18, 0.42, 0.28, 0.95), true)
	draw_rect(_submit_rect, accent, false, 1.4)
	draw_string(_font, _submit_rect.position + Vector2(0, 21), "提交  ×%.1f" % _mul(),
		HORIZONTAL_ALIGNMENT_CENTER, _submit_rect.size.x, 14, Color(0.90, 1.0, 0.92))
	draw_string(_font, pr.position + Vector2(PAD + 316, by + 22),
		"右键背包→寄存箱  右键寄存箱→背包  左键拖拽  R旋转  Esc关闭（未操作会退回）",
		HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - 340, 12, Color(0.55, 0.62, 0.72))
	if _toast_t > 0.0:
		draw_string(_font, pr.position + Vector2(PAD, HEADER_H - 8), _toast,
			HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - PAD * 2, 13, Color(1.0, 0.86, 0.45))

func _draw_inv_grid(g, origin: Vector2, hover: Vector2i, title: String, src: String) -> void:
	if g == null:
		return
	draw_string(_font, origin + Vector2(0, -6), title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.70, 0.82, 0.95))
	for y in g.rows:
		for x in g.cols:
			var r := _rect_of(origin, x, y)
			draw_rect(r, Color(0.12, 0.14, 0.18, 0.95), true)
			draw_rect(r, Color(0.22, 0.26, 0.32, 0.8), false, 1.0)
	if hover.x >= 0 and _drag.is_empty():
		draw_rect(_rect_of(origin, hover.x, hover.y), Color(1, 1, 1, 0.12), true)
	for i in g.entries.size():
		if not _drag.is_empty() and str(_drag.get("src", "")) == src and int(_drag.get("index", -1)) == i:
			continue
		var e: Dictionary = g.entries[i]
		var id: String = str(e["id"])
		var col: Color = GameData.item_color(id)
		var r2 := _rect_of(origin, int(e["x"]), int(e["y"]), int(e["w"]), int(e["h"]))
		draw_rect(r2, col.darkened(0.62), true)
		draw_rect(r2, col, false, 1.5)
		var def: Dictionary = GameData.item(id)
		draw_string(_font, r2.position + Vector2(4, 15), str(def.get("name", id)),
			HORIZONTAL_ALIGNMENT_LEFT, r2.size.x - 6, 11, Color(0.95, 0.96, 1.0))
		draw_string(_font, r2.position + Vector2(4, r2.size.y - 5), "¥%d" % int(def.get("value", 0)),
			HORIZONTAL_ALIGNMENT_LEFT, r2.size.x - 6, 10, Color(0.82, 0.88, 0.97, 0.9))

func _draw_drag_ghost(st) -> void:
	if _drag.is_empty():
		return
	var id: String = str(_drag["id"])
	var g = st if str(_drag.get("src", "")) == "stash" else inv
	if g == null:
		g = inv
	var s: Vector2i = g.item_size(id, bool(_drag["rotated"]))
	var col: Color = GameData.item_color(id)
	var mp := get_local_mouse_position()
	var step := CELL + GAP
	var gsize := Vector2(s.x * step - GAP, s.y * step - GAP)
	var gr := Rect2(mp - gsize * 0.5, gsize)
	draw_rect(gr, col.darkened(0.45) * Color(1, 1, 1, 0.8), true)
	draw_rect(gr, col, false, 1.5)
	draw_string(_font, gr.position + Vector2(5, 15), str(GameData.item(id).get("name", id)),
		HORIZONTAL_ALIGNMENT_LEFT, gr.size.x - 8, 11, Color.WHITE)
