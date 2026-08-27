extends Camera2D
## PlayerCamera · 跟随 + 向鼠标方向轻微前瞻
##
## 前瞻是 2D 俯视搜打撤的关键手感：让"你看的方向"比"你站的位置"多露出一点，
## 玩家转身扫视时能看得更远，鼓励主动观察而不是无脑贴墙。
##
## 实现要点：相机作为玩家子节点但 top_level=true（脱离父节点旋转——俯视图方向
## 必须稳定，否则天旋地转无法读图）。首帧必须直接吸附到玩家位置，
## 否则会从世界原点 (0,0) 平滑过来，导致开局画面偏移。

var _initialized := false

func _ready() -> void:
	top_level = true          # 不继承玩家的 rotation
	position_smoothing_enabled = false
	var p = get_parent()
	if p == null or NetHub.is_local(int(p.get("peer_id"))):
		make_current()

func _process(delta: float) -> void:
	var p = get_parent()
	if p == null:
		return
	zoom = Vector2.ONE * Tuning.camera_zoom

	var ahead := Vector2.ZERO
	if Tuning.camera_look_ahead > 0.0:
		var to_mouse: Vector2 = get_global_mouse_position() - p.global_position
		ahead = to_mouse * Tuning.camera_look_ahead
		ahead = ahead.limit_length(Tuning.camera_look_ahead_max)

	var target: Vector2 = p.global_position + ahead
	if not _initialized:
		# 首帧直接吸附，避免从 (0,0) lerp 过来造成开局镜头飞入
		_initialized = true
		global_position = target
	else:
		global_position = global_position.lerp(target, clampf(Tuning.camera_smooth * delta, 0.0, 1.0))
	rotation = 0.0
