extends Node2D
## Crosshair · 动态准星
##
## 准星张开度 = 当前有效扩散，直观反映"现在这一枪有多准"。
## 这是射击游戏最重要的信息反馈：跑动时张大、蹲下收紧、连发时逐渐张开、
## ADS 时最小。玩家不用看数字就知道该不该开枪。
##
## 画在世界坐标（跟随准心位置），而不是屏幕中心——2D 俯视下鼠标即准心。

var player = null

const MIN_GAP := 6.0
const LEN := 9.0

func _ready() -> void:
	z_index = 25
	top_level = true   # 不继承玩家旋转

func setup(p) -> void:
	player = p

func _process(_d: float) -> void:
	if player == null:
		return
	global_position = player.get_global_mouse_position()
	rotation = 0.0
	queue_redraw()

func _draw() -> void:
	if player == null or player.weapon == null:
		return
	if not Tuning.enable_shooting:
		return
	var w = player.weapon
	var spread: float = w.effective_spread(int(player.stance))
	# 扩散角度换算成屏幕像素：以玩家到准心的距离为半径
	var dist: float = maxf(player.global_position.distance_to(global_position), 40.0)
	var px: float = tan(deg_to_rad(spread)) * dist * Tuning.crosshair_scale
	var gap: float = clampf(MIN_GAP + px, MIN_GAP, 120.0)

	# 后坐抖动
	var kick: float = player.recoil_offset() * Tuning.recoil_visual_mul
	gap += kick

	var col := Color(0.95, 0.98, 1.0, 0.85)
	if w.reloading:
		col = Color(1.0, 0.72, 0.30, 0.7)
	elif w.mag <= 0:
		col = Color(1.0, 0.35, 0.35, 0.8)
	elif w.ads > 0.5:
		col = Color(0.55, 1.0, 0.72, 0.9)

	# 四段十字
	for v in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(v * gap, v * (gap + LEN), col, 1.6)
	# 中心点（ADS 时才显示，作为精确指示）
	if w.ads > 0.6:
		draw_circle(Vector2.ZERO, 1.4, col)

	# 换弹环形进度
	if w.reloading:
		var p: float = w.reload_progress()
		draw_arc(Vector2.ZERO, gap + LEN + 7.0, -PI * 0.5, -PI * 0.5 + TAU * p,
			28, Color(1.0, 0.78, 0.35, 0.9), 2.4)
