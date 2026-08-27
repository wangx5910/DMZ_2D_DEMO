extends Node2D
## VehicleWreck · 车辆爆炸后的焦黑残骸
##
## 存在的唯一理由是**情报**：搜打撤里"这里炸过车"意味着刚才有人经过、
## 可能还在附近、也可能这里有过一场交火。和小兵尸体同一个作用。
## 残骸不可驾驶、不阻挡（已经不是碰撞体），只是地面上的痕迹。

const BODY_LEN := 58.0
const BODY_WID := 30.0

func _ready() -> void:
	add_to_group("wrecks")
	z_index = 1

func _draw() -> void:
	var half := Vector2(BODY_LEN, BODY_WID) * 0.5
	# 焦痕（比车体大一圈的暗斑）
	draw_circle(Vector2.ZERO, BODY_LEN * 0.62, Color(0.06, 0.055, 0.05, 0.55))
	draw_rect(Rect2(-half, Vector2(BODY_LEN, BODY_WID)), Color(0.13, 0.11, 0.10), true)
	draw_rect(Rect2(-half, Vector2(BODY_LEN, BODY_WID)), Color(0.22, 0.18, 0.16), false, 2.0)
	# 扭曲的车架线条
	draw_line(Vector2(-half.x, -half.y), Vector2(half.x * 0.6, half.y * 0.7),
		Color(0.28, 0.22, 0.19), 2.0)
	draw_line(Vector2(-half.x * 0.7, half.y), Vector2(half.x, -half.y * 0.5),
		Color(0.28, 0.22, 0.19), 2.0)
