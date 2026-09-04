extends Node2D
## PlayerBody · 程序化绘制的角色外观（占位美术）
##
## 资源插槽约定：将来接美术时，只需把本节点替换为 AnimatedSprite2D/Sprite2D，
## 不需要改动 player.gd。朝向由父节点 rotation 驱动，贴图请朝 +X 方向绘制。
##
## 除角色本体外还画出 M4 的枪身轮廓——2D 俯视下这是玩家判断"枪口指向哪"
## 最直接的读数，比单纯的三角形指示器更有武器感。

const RADIUS := 11.0

var _stance_color := Color(0.45, 0.78, 0.95)

func _ready() -> void:
	var p = get_parent()
	if p.has_signal("stance_changed"):
		p.stance_changed.connect(_on_stance)

func _on_stance(stance: int) -> void:
	match stance:
		0: _stance_color = Color(0.45, 0.78, 0.95)  # WALK
		1: _stance_color = Color(0.98, 0.62, 0.30)  # SPRINT
		2: _stance_color = Color(0.55, 0.90, 0.62)  # CROUCH
	queue_redraw()

func _process(_d: float) -> void:
	# 枪身随 ADS / 换弹状态变化，需每帧重绘
	queue_redraw()

func _draw() -> void:
	var p = get_parent()
	var r := RADIUS
	if p.stance == 2:
		r *= 0.82  # 蹲下缩一圈，给俯视角一个姿态读数

	_draw_weapon(p, r)

	# 身体（画在枪之后 → 盖住枪托，视觉上枪是"端在身前"）
	draw_circle(Vector2.ZERO, r + 1.5, Color(0.05, 0.06, 0.09, 0.9))
	draw_circle(Vector2.ZERO, r, _stance_color)
	if bool(p.get("contract_expose")):
		var pulse: float = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.012)
		draw_arc(Vector2.ZERO, r + 6.0 + pulse * 4.0, 0, TAU, 28,
			Color(0.35, 0.95, 1.0, 0.85), 2.2)
		draw_circle(Vector2.ZERO, r + 3.0, Color(0.30, 0.85, 1.0, 0.18))
	var tag := str(p.get("net_tag")) if p.get("net_tag") != null else ""
	var pid = p.get("peer_id")
	if tag != "" and (NetHub.is_online() or (pid != null and int(pid) != 1)):
		draw_string(ThemeDB.fallback_font, Vector2(-18, -r - 8), tag,
			HORIZONTAL_ALIGNMENT_CENTER, 36, 12, Color(1.0, 0.92, 0.55))

func _draw_weapon(p, r: float) -> void:
	var w = p.weapon
	if w == null or not Tuning.enable_shooting:
		# 无枪时退回朝向三角指示
		var tip := Vector2(r + 9.0, 0)
		draw_colored_polygon(
			PackedVector2Array([tip, Vector2(r * 0.35, -4.5), Vector2(r * 0.35, 4.5)]),
			Color(0.95, 0.96, 1.0, 0.95))
		return

	# ADS 时枪往前伸、更贴中线（视觉上"举枪瞄准"）
	var ads: float = w.ads
	var fwd: float = lerpf(4.0, 9.0, ads)
	var side: float = lerpf(4.5, 1.5, ads)
	var barrel_len: float = lerpf(20.0, 25.0, ads)
	# 后坐：枪身向后弹
	var kick: float = p.recoil_offset() * Tuning.recoil_visual_mul * 0.9

	var gun_col := Color(0.20, 0.22, 0.27)
	var metal := Color(0.34, 0.37, 0.44)
	if w.reloading:
		gun_col = Color(0.30, 0.24, 0.14)
		metal = Color(0.55, 0.44, 0.24)

	var origin := Vector2(fwd - kick, side)
	# 枪身
	draw_line(origin, origin + Vector2(barrel_len, 0), gun_col, 5.0)
	draw_line(origin, origin + Vector2(barrel_len, 0), metal, 2.2)
	# 枪托（往后）
	draw_line(origin, origin + Vector2(-9.0, 0), gun_col, 4.0)
	# 弹匣（向下垂）
	draw_line(origin + Vector2(5.0, 0), origin + Vector2(5.0, 6.0), gun_col, 3.4)
	# 枪口
	draw_circle(origin + Vector2(barrel_len, 0), 1.6, Color(0.55, 0.58, 0.66))

	# 空仓提示：枪口红点
	if w.mag <= 0 and not w.reloading:
		draw_circle(origin + Vector2(barrel_len, 0), 3.0, Color(1.0, 0.35, 0.35, 0.8))
