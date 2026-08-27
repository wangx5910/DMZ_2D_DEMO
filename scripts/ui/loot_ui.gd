extends Control
## LootUI · 容器搜刮面板 + Tetris 网格背包
##
## 布局照鸭科夫：屏幕居中的双栏窗口，**左 = 容器（战利品）、右 = 玩家背包**。
## 全程自绘（不依赖任何美术资源）。
## - 左栏：容器格位。未搜索 = 问号遮罩；已搜索 = 显示实际内容（可能是空）
## - 右栏：网格背包。拖拽摆放，拖拽中按 R 旋转 90°
## - 右键容器格 → 自动塞进背包最优位；右键背包物品 → 丢弃
##
## 设计要点：**未搜索的格子不显示内容**，所以"值不值得继续搜"永远是赌。
##
## 布局实现要点（曾踩坑）：本 Control 必须真正撑满视口才能算居中。
## 只调 set_anchors_preset() 不设 offset 会让 size 保持 (0,0)，
## 导致居中公式算出负坐标、面板飞到屏幕左上角外。故统一用 _vp() 取视口尺寸。

const CELL := 36           ## 网格单元边长
const GAP := 2             ## 单元间隙
const PAD := 18            ## 窗口内边距
const HEADER_H := 52       ## 标题栏高度
const FOOTER_H := 30       ## 底部提示栏高度
const COL_W := 268         ## 左栏（容器）宽度
const ROW_H := 34          ## 左栏每格行高
const ROW_GAP := 4
const STASH_CELL := 28     ## 寄存预览格子
const STASH_HEAD := 20     ## 寄存预览标题高度
const SEALED_LOCKED_FLASH := "密闭舱尚未解锁：将飞船开到破解点完成破解后可取出"

var inv: GridInventory
## 无类型：需访问容器/玩家脚本自定义成员（GDScript 强类型会编译报错）
var container = null
var player = null

var _drag := {}                 ## {src, index, id, rotated}
var _hover_cell := Vector2i(-1, -1)
var _search_cur := 0.0
var _search_total := 0.0
var _search_slot := -1
var _cracking := false
var _font: Font
var _toast := ""
var _toast_t := 0.0

func setup(p, inventory: GridInventory) -> void:
	player = p
	inv = inventory
	inv.changed.connect(queue_redraw)
	if p != null and p.get("stash") != null:
		p.stash.changed.connect(queue_redraw)
	p.search_state_changed.connect(_on_search_state)
	p.search_progress.connect(_on_search_progress)

func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# 撑满视口：锚点 + offset 都要设，否则 size 恒为 0
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_viewport().size_changed.connect(_on_viewport_resized)

func _on_viewport_resized() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	queue_redraw()

## 可靠的视口尺寸（不依赖 Control.size 是否已布局完成）
func _vp() -> Vector2:
	return Vector2(get_viewport_rect().size)

func _on_search_state(active: bool, c) -> void:
	if active:
		container = c
		visible = true
	else:
		# 读条中断不关面板（已搜出的格子还能继续拿），仅在玩家主动关闭时隐藏
		_search_slot = -1
		_search_total = 0.0
	_sync_mouse_capture()
	queue_redraw()

## 面板可见时挂起玩家的鼠标转向与开火，避免在 UI 上拖拽时甩视野/走火
func _sync_mouse_capture() -> void:
	if player != null:
		player.ui_capturing_mouse = visible

func _on_search_progress(cur: float, total: float, slot: int, _n: int) -> void:
	_search_cur = cur
	_search_total = total
	_search_slot = slot
	_cracking = slot < 0
	queue_redraw()

func _process(delta: float) -> void:
	if not visible:
		return
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			queue_redraw()
	if player != null and _has_container():
		if player.global_position.distance_to(container.global_position) > Tuning.interact_range * 1.6:
			close_panel()

func close_panel() -> void:
	if player != null:
		player.close_container_panel()
	if container != null:
		var left: int = container.remaining_value()
		RaidLog.bump("value_left_behind", left)
		RaidLog.log_event("panel_closed", {
			"container": str(container.name),
			"left_value": left,
			"revealed": container.revealed_count(),
			"total": container.slot_count(),
		})
	container = null
	_drag.clear()
	visible = false
	_sync_mouse_capture()

## 独立背包视图（无容器时按 T 打开），用于检查负重取舍
func open_backpack_only() -> void:
	container = null
	visible = true
	_search_total = 0.0
	_sync_mouse_capture()
	queue_redraw()

# ── 布局 ────────────────────────────────────────────────
func _has_container() -> bool:
	return container != null and is_instance_valid(container)

func _grid_px() -> Vector2:
	return Vector2(inv.cols * (CELL + GAP) - GAP, inv.rows * (CELL + GAP) - GAP)

func _stash():
	if player != null:
		return player.get("stash")
	return null

func _stash_px() -> Vector2:
	var st = _stash()
	if st == null:
		return Vector2.ZERO
	return Vector2(st.cols * (STASH_CELL + GAP) - GAP, st.rows * (STASH_CELL + GAP) - GAP)

func _stash_block_h() -> float:
	if _stash() == null:
		return 0.0
	return STASH_HEAD + 8.0 + _stash_px().y

## 窗口矩形（屏幕居中，且保证不超出视口）
func _panel_rect() -> Rect2:
	var g := _grid_px()
	var body_h: float = g.y + _stash_block_h()
	if _has_container():
		var n: int = container.slot_count()
		var stash_n: int = 0
		if "stash_slots" in container:
			stash_n = container.stash_slots.size()
		var left_h: float = n * (ROW_H + ROW_GAP)
		if stash_n > 0:
			left_h += 28.0 + stash_n * (ROW_H + ROW_GAP)
		body_h = maxf(body_h, left_h)
	var w: float = g.x + PAD * 2
	if _has_container():
		w += COL_W + PAD
	var h: float = body_h + HEADER_H + FOOTER_H + PAD + 12.0
	var vp := _vp()
	# 万一窗口比视口还大（超小分辨率），至少保证左上角贴边可见
	var pos := Vector2(
		maxf(0.0, floorf((vp.x - w) * 0.5)),
		maxf(0.0, floorf((vp.y - h) * 0.5))
	)
	return Rect2(pos, Vector2(w, h))

func _container_origin() -> Vector2:
	var pr := _panel_rect()
	return pr.position + Vector2(PAD, HEADER_H)

func _grid_origin() -> Vector2:
	var pr := _panel_rect()
	var x: float = PAD
	if _has_container():
		x = PAD + COL_W + PAD
	return pr.position + Vector2(x, HEADER_H)

func _cell_at(pos: Vector2) -> Vector2i:
	var o := _grid_origin()
	var step := CELL + GAP
	var lx := int(floor((pos.x - o.x) / step))
	var ly := int(floor((pos.y - o.y) / step))
	if lx < 0 or ly < 0 or lx >= inv.cols or ly >= inv.rows:
		return Vector2i(-1, -1)
	return Vector2i(lx, ly)

func _cell_rect(x: int, y: int, w: int = 1, h: int = 1) -> Rect2:
	var o := _grid_origin()
	var step := CELL + GAP
	return Rect2(
		o + Vector2(x * step, y * step),
		Vector2(w * step - GAP, h * step - GAP)
	)

func _container_slot_at(pos: Vector2) -> int:
	if not _has_container():
		return -1
	var o := _container_origin()
	if pos.x < o.x or pos.x > o.x + COL_W:
		return -1
	var idx := int(floor((pos.y - o.y) / (ROW_H + ROW_GAP)))
	if idx < 0 or idx >= container.slot_count():
		return -1
	return idx

func _slot_rect(i: int) -> Rect2:
	return Rect2(_container_origin() + Vector2(0, i * (ROW_H + ROW_GAP)), Vector2(COL_W, ROW_H))

func _stash_origin() -> Vector2:
	var g := _grid_origin()
	return g + Vector2(0, _grid_px().y + STASH_HEAD + 8.0)

func _stash_cell_at(pos: Vector2) -> Vector2i:
	var st = _stash()
	if st == null:
		return Vector2i(-1, -1)
	var o := _stash_origin()
	var step := STASH_CELL + GAP
	var lx := int(floor((pos.x - o.x) / step))
	var ly := int(floor((pos.y - o.y) / step))
	if lx < 0 or ly < 0 or lx >= st.cols or ly >= st.rows:
		return Vector2i(-1, -1)
	return Vector2i(lx, ly)

func _stash_cell_rect(x: int, y: int, w: int = 1, h: int = 1) -> Rect2:
	var o := _stash_origin()
	var step := STASH_CELL + GAP
	return Rect2(o + Vector2(x * step, y * step), Vector2(w * step - GAP, h * step - GAP))

func _corpse_stash_n() -> int:
	if not _has_container() or not ("stash_slots" in container):
		return 0
	return container.stash_slots.size()

func _corpse_stash_origin() -> Vector2:
	var o := _container_origin()
	var n: int = container.slot_count() if _has_container() else 0
	return o + Vector2(0, n * (ROW_H + ROW_GAP) + 28.0)

func _corpse_stash_index_at(pos: Vector2) -> int:
	var n := _corpse_stash_n()
	if n <= 0:
		return -1
	var o := _corpse_stash_origin()
	if pos.x < o.x or pos.x > o.x + COL_W:
		return -1
	var idx := int(floor((pos.y - o.y) / (ROW_H + ROW_GAP)))
	if idx < 0 or idx >= n:
		return -1
	return idx

func _corpse_stash_rect(i: int) -> Rect2:
	return Rect2(_corpse_stash_origin() + Vector2(0, i * (ROW_H + ROW_GAP)), Vector2(COL_W, ROW_H))

# ── 输入 ────────────────────────────────────────────────
func _gui_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseMotion:
		_hover_cell = _cell_at(event.position)
		queue_redraw()
	elif event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_on_left_click(event.position)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_on_right_click(event.position)
		else:
			if event.button_index == MOUSE_BUTTON_LEFT and not _drag.is_empty():
				_drop_at(event.position)

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

func _on_left_click(pos: Vector2) -> void:
	var csi := _corpse_stash_index_at(pos)
	if csi >= 0:
		if container.take_locked:
			_flash(SEALED_LOCKED_FLASH)
			return
		if container.stash_taken[csi] or container.stash_slots[csi].is_empty():
			return
		_drag = {"src": "corpse_stash", "index": csi, "id": container.stash_slots[csi]["id"], "rotated": false}
		queue_redraw()
		return
	var cs := _container_slot_at(pos)
	if cs >= 0 and _has_container():
		if container.take_locked:
			_flash(SEALED_LOCKED_FLASH)
			return
		if not container.revealed[cs] or container.taken[cs] or container.slots[cs].is_empty():
			return
		_drag = {"src": "container", "index": cs, "id": container.slots[cs]["id"], "rotated": false}
		queue_redraw()
		return
	var sc := _stash_cell_at(pos)
	var st = _stash()
	if sc.x >= 0 and st != null:
		var sei: int = st.entry_at(sc.x, sc.y)
		if sei >= 0:
			var se: Dictionary = st.entries[sei]
			_drag = {"src": "stash", "index": sei, "id": se["id"], "rotated": se["rotated"]}
			queue_redraw()
			return
	var cell := _cell_at(pos)
	if cell.x >= 0:
		var ei := inv.entry_at(cell.x, cell.y)
		if ei >= 0:
			var e := inv.entries[ei]
			_drag = {"src": "grid", "index": ei, "id": e["id"], "rotated": e["rotated"]}
			queue_redraw()

func _on_right_click(pos: Vector2) -> void:
	var csi := _corpse_stash_index_at(pos)
	if csi >= 0:
		_quick_take_corpse_stash(csi)
		return
	var cs := _container_slot_at(pos)
	if cs >= 0 and _has_container():
		_quick_take(cs)
		return
	var sc := _stash_cell_at(pos)
	var st = _stash()
	if sc.x >= 0 and st != null:
		var sei: int = st.entry_at(sc.x, sc.y)
		if sei >= 0:
			var id: String = st.remove_at_index(sei)
			if id != "" and not inv.add_auto(id):
				st.add_auto(id)
				_flash("背包装不下，仍留在寄存预览")
			else:
				_flash("已移回背包（腾出寄存格）")
			return
	var cell := _cell_at(pos)
	if cell.x >= 0:
		var ei := inv.entry_at(cell.x, cell.y)
		if ei >= 0:
			var id: String = inv.entries[ei]["id"]
			inv.remove_at_index(ei)
			RaidLog.log_event("item_dropped", {"item": id})
			_flash("丢弃 %s" % GameData.item(id).get("name", id))

func _quick_take(slot: int) -> void:
	if container.take_locked:
		_flash(SEALED_LOCKED_FLASH)
		return
	if not container.revealed[slot] or container.taken[slot] or container.slots[slot].is_empty():
		return
	var id: String = container.slots[slot]["id"]
	if not Tuning.enable_grid_backpack:
		container.take_slot(slot)
		_record_take(id)
		return
	if inv.add_auto(id):
		container.take_slot(slot)
		_record_take(id)
	else:
		_flash("背包装不下 %s（%d×%d）" % [
			GameData.item(id).get("name", id),
			GameData.item(id).get("w", 1), GameData.item(id).get("h", 1)])

func _quick_take_corpse_stash(slot: int) -> void:
	if container.take_locked:
		_flash(SEALED_LOCKED_FLASH)
		return
	if slot < 0 or slot >= container.stash_slots.size():
		return
	if container.stash_taken[slot] or container.stash_slots[slot].is_empty():
		return
	var st = _stash()
	if st == null:
		return
	var id: String = str(container.stash_slots[slot]["id"])
	if st.add_auto(id):
		container.take_stash_slot(slot)
		_record_take(id)
	else:
		_flash("寄存预览已满，先右键移回背包再筛选")

func _drop_at(pos: Vector2) -> void:
	var cell := _cell_at(pos)
	var sc := _stash_cell_at(pos)
	var d := _drag.duplicate()
	_drag.clear()
	var st = _stash()
	var src: String = str(d.get("src", ""))

	if src == "corpse_stash":
		if sc.x >= 0 and st != null:
			if st.can_place(d["id"], sc.x, sc.y, d["rotated"]):
				st.place(d["id"], sc.x, sc.y, d["rotated"])
				container.take_stash_slot(d["index"])
				_record_take(d["id"])
			else:
				_flash("寄存预览放不下——先筛选替换")
		else:
			_flash("寄存物资请放入寄存预览")
		queue_redraw()
		return

	if src == "stash" and st != null:
		if sc.x >= 0:
			if not st.move(int(d["index"]), sc.x, sc.y, bool(d["rotated"])):
				_flash("此处被占用")
		elif cell.x >= 0:
			if inv.can_place(d["id"], cell.x, cell.y, d["rotated"]):
				st.remove_at_index(int(d["index"]))
				inv.place(d["id"], cell.x, cell.y, d["rotated"])
			else:
				_flash("背包放不下——按 R 旋转试试")
		queue_redraw()
		return

	if cell.x < 0:
		# 拖出网格：从背包拖回容器栏 = 放回
		if src == "grid":
			var cs := _container_slot_at(pos)
			if cs >= 0:
				var id: String = inv.remove_at_index(d["index"])
				RaidLog.log_event("item_returned", {"item": id})
				_flash("放回 %s" % GameData.item(id).get("name", id))
		queue_redraw()
		return

	if src == "container":
		if container.take_locked:
			_flash(SEALED_LOCKED_FLASH)
			queue_redraw()
			return
		if inv.can_place(d["id"], cell.x, cell.y, d["rotated"]):
			inv.place(d["id"], cell.x, cell.y, d["rotated"])
			container.take_slot(d["index"])
			_record_take(d["id"])
		else:
			_flash("放不下——按 R 旋转试试")
	else:
		if not inv.move(d["index"], cell.x, cell.y, d["rotated"]):
			_flash("此处被占用")
	queue_redraw()

func _record_take(id: String) -> void:
	RaidLog.bump("items_taken")
	RaidLog.bump("value_taken", int(GameData.item(id).get("value", 0)))
	var cname := ""
	if container != null:
		cname = str(container.name)
	RaidLog.log_event("item_taken", {
		"item": id, "value": GameData.item(id).get("value", 0),
		"container": cname,
	})

func _flash(msg: String) -> void:
	_toast = msg
	_toast_t = 1.8
	queue_redraw()

# ── 绘制 ────────────────────────────────────────────────
func _draw() -> void:
	if inv == null:
		return
	var vp := _vp()
	var pr := _panel_rect()
	# 全屏压暗
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.55), true)
	# 窗口
	draw_rect(pr, Color(0.075, 0.085, 0.105, 0.985), true)
	draw_rect(pr, Color(0.32, 0.38, 0.48, 0.95), false, 2.0)
	# 标题栏底色
	draw_rect(Rect2(pr.position, Vector2(pr.size.x, HEADER_H - 10)), Color(0.11, 0.125, 0.155), true)

	_draw_header(pr)
	if _has_container():
		_draw_container_col()
	_draw_grid()
	_draw_stash_preview()
	_draw_drag_ghost()
	_draw_footer(pr)
	_draw_toast(pr)

func _draw_header(pr: Rect2) -> void:
	var title := "背包"
	if _has_container():
		title = "%s ｜ %s" % [container.label, container.richness]
	draw_string(_font, pr.position + Vector2(PAD, 28), title,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.93, 0.95, 1.0))
	var val := "¥%d ｜ %d/%d 格" % [inv.total_value(), inv.used_cells(), inv.capacity()]
	var st = _stash()
	if st != null:
		val = "背包 ¥%d  寄存 ¥%d" % [inv.total_value(), st.total_value()]
	draw_string(_font, pr.position + Vector2(pr.size.x - PAD - 300, 28), val,
		HORIZONTAL_ALIGNMENT_RIGHT, 300, 15, Color(0.78, 0.85, 0.97))

func _draw_footer(pr: Rect2) -> void:
	var hint := "左键拖拽 · R 旋转 · 右键丢弃 ｜ ESC / T 关闭"
	if _has_container():
		hint = "自动逐格搜刮中（E 停止）｜ 右键尸体寄存→自己寄存预览 ｜ ESC 关闭"
	if _stash() != null:
		hint += "  ｜  右键寄存预览→移回背包"
	draw_string(_font, pr.position + Vector2(PAD, pr.size.y - 10), hint,
		HORIZONTAL_ALIGNMENT_LEFT, pr.size.x - PAD * 2, 12, Color(0.52, 0.58, 0.68))

func _draw_container_col() -> void:
	var o := _container_origin()
	var n: int = container.slot_count()
	draw_string(_font, o + Vector2(0, -8), "战利品 · %d/%d 格已搜" % [container.revealed_count(), n],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.68, 0.75, 0.88))
	for i in n:
		var r := _slot_rect(i)
		var searching: bool = (i == _search_slot and _search_total > 0.0)
		if not container.revealed[i]:
			draw_rect(r, Color(0.125, 0.135, 0.165), true)
			draw_rect(r, Color(0.26, 0.28, 0.34), false, 1.0)
			if searching:
				var w: float = r.size.x * clampf(_search_cur / _search_total, 0.0, 1.0)
				draw_rect(Rect2(r.position, Vector2(w, r.size.y)), Color(0.28, 0.58, 0.85, 0.6), true)
				draw_string(_font, r.position + Vector2(9, 22),
					"搜索中… %.1f / %.1fs" % [_search_cur, _search_total],
					HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 14, 13, Color(0.88, 0.94, 1.0))
			else:
				draw_string(_font, r.position + Vector2(9, 22), "？ 未搜索",
					HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 14, 13, Color(0.42, 0.46, 0.55))
		elif container.slots[i].is_empty():
			draw_rect(r, Color(0.10, 0.105, 0.125), true)
			draw_rect(r, Color(0.20, 0.21, 0.25), false, 1.0)
			draw_string(_font, r.position + Vector2(9, 22), "— 空 —",
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 14, 13, Color(0.36, 0.38, 0.45))
		else:
			var id: String = container.slots[i]["id"]
			var d := GameData.item(id)
			var col := GameData.item_color(id)
			var was_taken: bool = container.taken[i]
			draw_rect(r, col.darkened(0.78 if was_taken else 0.66), true)
			draw_rect(r, col.darkened(0.5) if was_taken else col, false, 1.5)
			var txt := "%s   %d×%d   ¥%d" % [d.get("name", id), d.get("w", 1), d.get("h", 1), d.get("value", 0)]
			if was_taken:
				txt = "（已取）%s" % d.get("name", id)
			draw_string(_font, r.position + Vector2(9, 22), txt,
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 14, 13,
				Color(0.40, 0.43, 0.50) if was_taken else Color(0.93, 0.95, 1.0))

	_draw_corpse_stash_col()

	# L4 破解读条
	if _cracking and _search_total > 0.0:
		var n2: int = container.slot_count()
		var extra: float = 0.0
		if _corpse_stash_n() > 0:
			extra = 28.0 + _corpse_stash_n() * (ROW_H + ROW_GAP)
		var br := Rect2(o + Vector2(0, n2 * (ROW_H + ROW_GAP) + extra + 12), Vector2(COL_W, 22))
		draw_rect(br, Color(0.15, 0.12, 0.07), true)
		draw_rect(Rect2(br.position, Vector2(br.size.x * clampf(_search_cur / _search_total, 0, 1), br.size.y)),
			Color(0.90, 0.68, 0.25, 0.9), true)
		draw_string(_font, br.position + Vector2(8, 16),
			"破解免保柜… %.1f / %.1fs" % [_search_cur, _search_total],
			HORIZONTAL_ALIGNMENT_LEFT, br.size.x - 12, 12, Color(0.09, 0.08, 0.06))

func _draw_corpse_stash_col() -> void:
	var n := _corpse_stash_n()
	if n <= 0:
		return
	var o := _corpse_stash_origin()
	draw_string(_font, o + Vector2(0, -8), "对方寄存预览 · 右键转入自己寄存",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.92, 0.72, 0.45))
	for i in n:
		var r := _corpse_stash_rect(i)
		var slot: Dictionary = container.stash_slots[i]
		var was_taken: bool = container.stash_taken[i]
		if slot.is_empty():
			draw_rect(r, Color(0.10, 0.105, 0.125), true)
			draw_rect(r, Color(0.20, 0.21, 0.25), false, 1.0)
			draw_string(_font, r.position + Vector2(9, 22), "— 空 —",
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 14, 13, Color(0.36, 0.38, 0.45))
			continue
		var id: String = str(slot.get("id", ""))
		var d := GameData.item(id)
		var col := GameData.item_color(id)
		draw_rect(r, col.darkened(0.78 if was_taken else 0.66), true)
		draw_rect(r, col.darkened(0.5) if was_taken else col, false, 1.5)
		var txt := "%s   %d×%d   ¥%d" % [d.get("name", id), d.get("w", 1), d.get("h", 1), d.get("value", 0)]
		if was_taken:
			txt = "（已取）%s" % d.get("name", id)
		draw_string(_font, r.position + Vector2(9, 22), txt,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 14, 13,
			Color(0.40, 0.43, 0.50) if was_taken else Color(0.93, 0.95, 1.0))

func _draw_grid() -> void:
	var o := _grid_origin()
	draw_string(_font, o + Vector2(0, -8), "背包 %d×%d" % [inv.cols, inv.rows],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.68, 0.75, 0.88))
	# 底格
	for y in inv.rows:
		for x in inv.cols:
			var r := _cell_rect(x, y)
			draw_rect(r, Color(0.115, 0.125, 0.15), true)
			draw_rect(r, Color(0.19, 0.20, 0.245), false, 1.0)
	# 悬停高亮
	if _hover_cell.x >= 0 and _drag.is_empty():
		draw_rect(_cell_rect(_hover_cell.x, _hover_cell.y), Color(1, 1, 1, 0.06), true)
	# 物品
	for i in inv.entries.size():
		var e := inv.entries[i]
		if not _drag.is_empty() and _drag["src"] == "grid" and _drag["index"] == i:
			continue
		var id: String = e["id"]
		var col := GameData.item_color(id)
		var r := _cell_rect(e["x"], e["y"], e["w"], e["h"])
		draw_rect(r, col.darkened(0.62), true)
		draw_rect(r, col, false, 1.5)
		var d := GameData.item(id)
		draw_string(_font, r.position + Vector2(5, 15), str(d.get("name", id)),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, 11, Color(0.95, 0.96, 1.0))
		draw_string(_font, r.position + Vector2(5, r.size.y - 6), "¥%d" % d.get("value", 0),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, 10, Color(0.82, 0.88, 0.97, 0.9))

func _draw_stash_preview() -> void:
	var st = _stash()
	if st == null:
		return
	var o := _stash_origin()
	draw_string(_font, o + Vector2(0, -6), "寄存预览 %d×%d  ¥%d（死亡掉落）" % [st.cols, st.rows, st.total_value()],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.92, 0.72, 0.45))
	for y in st.rows:
		for x in st.cols:
			var r := _stash_cell_rect(x, y)
			draw_rect(r, Color(0.14, 0.12, 0.10), true)
			draw_rect(r, Color(0.32, 0.26, 0.18), false, 1.0)
	for i in st.entries.size():
		if not _drag.is_empty() and str(_drag.get("src", "")) == "stash" and int(_drag.get("index", -1)) == i:
			continue
		var e: Dictionary = st.entries[i]
		var id: String = str(e["id"])
		var col := GameData.item_color(id)
		var r2 := _stash_cell_rect(int(e["x"]), int(e["y"]), int(e["w"]), int(e["h"]))
		draw_rect(r2, col.darkened(0.62), true)
		draw_rect(r2, col, false, 1.5)
		var d := GameData.item(id)
		draw_string(_font, r2.position + Vector2(3, 13), str(d.get("name", id)),
			HORIZONTAL_ALIGNMENT_LEFT, r2.size.x - 4, 10, Color(0.95, 0.96, 1.0))

func _draw_drag_ghost() -> void:
	if _drag.is_empty():
		return
	var id: String = _drag["id"]
	var src: String = str(_drag.get("src", ""))
	var s := inv.item_size(id, _drag["rotated"])
	var col := GameData.item_color(id)
	var mp := get_local_mouse_position()
	var st = _stash()
	var sc := _stash_cell_at(mp)
	if sc.x >= 0 and st != null and src in ["stash", "corpse_stash"]:
		var ignore: int = int(_drag["index"]) if src == "stash" else -1
		var ok: bool = bool(st.can_place(id, sc.x, sc.y, _drag["rotated"], ignore))
		var pr := _stash_cell_rect(sc.x, sc.y, s.x, s.y)
		draw_rect(pr, (Color(0.32, 0.85, 0.45, 0.30) if ok else Color(0.90, 0.25, 0.28, 0.30)), true)
		draw_rect(pr, (Color(0.45, 0.95, 0.55) if ok else Color(0.95, 0.35, 0.38)), false, 2.0)
	else:
		var cell := _cell_at(mp)
		if cell.x >= 0:
			var ignore2: int = _drag["index"] if src == "grid" else -1
			var ok2 := inv.can_place(id, cell.x, cell.y, _drag["rotated"], ignore2)
			var pr2 := _cell_rect(cell.x, cell.y, s.x, s.y)
			draw_rect(pr2, (Color(0.32, 0.85, 0.45, 0.30) if ok2 else Color(0.90, 0.25, 0.28, 0.30)), true)
			draw_rect(pr2, (Color(0.45, 0.95, 0.55) if ok2 else Color(0.95, 0.35, 0.38)), false, 2.0)
	var step := CELL + GAP
	var gsize := Vector2(s.x * step - GAP, s.y * step - GAP)
	var gr := Rect2(mp - gsize * 0.5, gsize)
	draw_rect(gr, col.darkened(0.45) * Color(1, 1, 1, 0.8), true)
	draw_rect(gr, col, false, 1.5)
	draw_string(_font, gr.position + Vector2(5, 15), str(GameData.item(id).get("name", id)),
		HORIZONTAL_ALIGNMENT_LEFT, gr.size.x - 8, 11, Color.WHITE)

func _draw_toast(pr: Rect2) -> void:
	if _toast_t <= 0.0:
		return
	var a: float = clampf(_toast_t / 0.7, 0.0, 1.0)
	var w := 340.0
	var box := Rect2(pr.position + Vector2((pr.size.x - w) * 0.5, pr.size.y - 56), Vector2(w, 26))
	draw_rect(box, Color(0.55, 0.20, 0.18, 0.55 * a), true)
	draw_rect(box, Color(0.95, 0.45, 0.40, 0.7 * a), false, 1.0)
	draw_string(_font, box.position + Vector2(0, 18), _toast,
		HORIZONTAL_ALIGNMENT_CENTER, w, 14, Color(1.0, 0.85, 0.82, a))
