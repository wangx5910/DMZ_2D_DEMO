class_name Health
extends RefCounted
## Health · 生命值（纯数据，玩家与怪物共用）
##
## 单独抽出来的理由：伤害结算规则必须两边一致，否则"玩家打怪"和"怪打玩家"
## 会出现两套判定。联机时这也是需要服务端权威的状态。

signal damaged(amount: float, from: Vector2, hp_left: float)
signal died(from: Vector2)
signal healed(amount: float)

var hp_max: float = 100.0
var hp: float = 100.0
var dead: bool = false
## 最近一次受击的方向（世界坐标），用于受击指示器与"往哪躲"
var last_hit_from := Vector2.ZERO
var last_hit_time: float = -999.0

func _init(maximum: float = 100.0) -> void:
	hp_max = maxf(maximum, 1.0)
	hp = hp_max

func ratio() -> float:
	return clampf(hp / maxf(hp_max, 0.001), 0.0, 1.0)

## 返回实际造成的伤害（死亡后为 0）
func apply_damage(amount: float, from: Vector2 = Vector2.ZERO) -> float:
	if dead or amount <= 0.0:
		return 0.0
	var before := hp
	hp = maxf(0.0, hp - amount)
	last_hit_from = from
	last_hit_time = Time.get_ticks_msec() / 1000.0
	var dealt := before - hp
	damaged.emit(dealt, from, hp)
	if hp <= 0.0:
		dead = true
		died.emit(from)
	return dealt

func heal(amount: float) -> void:
	if dead or amount <= 0.0:
		return
	hp = minf(hp_max, hp + amount)
	healed.emit(amount)

func reset(maximum: float = -1.0) -> void:
	if maximum > 0.0:
		hp_max = maximum
	hp = hp_max
	dead = false

## 距上次受击多久（秒）——用于受击方向指示器的淡出
func since_hit() -> float:
	return Time.get_ticks_msec() / 1000.0 - last_hit_time
