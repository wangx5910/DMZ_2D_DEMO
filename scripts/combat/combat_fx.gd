extends Node2D
## CombatFX · 射击表现层（曳光弹 / 命中火花 / 枪口闪光）
##
## 全部程序化绘制，无美术依赖。用单节点批量绘制而不是每颗子弹一个节点——
## 高射速下（780 RPM）节点创建/销毁开销会明显掉帧。
##
## 曳光弹用「线段 + 生命周期」模拟：给定起点终点与飞行时间，按进度画一段拖尾。
## 这比真实物理子弹便宜得多，且 2D 俯视下视觉效果等价。

const TRACER_LIFE := 0.085      ## 曳光弹可见时长（秒）
const TRACER_TAIL := 64.0       ## 拖尾长度（像素）
const SPARK_LIFE := 0.22
const MUZZLE_LIFE := 0.05

var _tracers: Array[Dictionary] = []   ## {from, to, t, speed}
var _sparks: Array[Dictionary] = []    ## {pos, t, normal}
var _muzzles: Array[Dictionary] = []   ## {pos, dir, t}

func _ready() -> void:
	z_index = 20

func add_tracer(from: Vector2, to: Vector2, speed: float) -> void:
	_tracers.append({"from": from, "to": to, "t": 0.0, "speed": maxf(speed, 100.0)})

func add_spark(pos: Vector2, normal: Vector2 = Vector2.ZERO) -> void:
	_sparks.append({"pos": pos, "t": 0.0, "normal": normal})

func add_muzzle(pos: Vector2, dir: Vector2) -> void:
	_muzzles.append({"pos": pos, "dir": dir, "t": 0.0})

func _process(delta: float) -> void:
	var dirty := false
	for i in range(_tracers.size() - 1, -1, -1):
		_tracers[i]["t"] += delta
		var flight: float = _tracers[i]["from"].distance_to(_tracers[i]["to"]) / _tracers[i]["speed"]
		if _tracers[i]["t"] > flight + TRACER_LIFE:
			_tracers.remove_at(i)
		dirty = true
	for i in range(_sparks.size() - 1, -1, -1):
		_sparks[i]["t"] += delta
		if _sparks[i]["t"] > SPARK_LIFE:
			_sparks.remove_at(i)
		dirty = true
	for i in range(_muzzles.size() - 1, -1, -1):
		_muzzles[i]["t"] += delta
		if _muzzles[i]["t"] > MUZZLE_LIFE:
			_muzzles.remove_at(i)
		dirty = true
	if dirty:
		queue_redraw()

func _draw() -> void:
	# 曳光弹
	for tr in _tracers:
		var from: Vector2 = tr["from"]
		var to: Vector2 = tr["to"]
		var total: float = from.distance_to(to)
		var flight: float = total / tr["speed"]
		var t: float = tr["t"]
		var head_d: float = minf(total, tr["speed"] * t)
		var tail_d: float = maxf(0.0, head_d - TRACER_TAIL)
		var dir: Vector2 = (to - from).normalized() if total > 0.1 else Vector2.RIGHT
		var head: Vector2 = from + dir * head_d
		var tail: Vector2 = from + dir * tail_d
		# 飞行结束后淡出
		var a := 1.0
		if t > flight:
			a = clampf(1.0 - (t - flight) / TRACER_LIFE, 0.0, 1.0)
		draw_line(tail, head, Color(1.0, 0.86, 0.45, 0.85 * a), 2.0)
		draw_line(tail, head, Color(1.0, 0.97, 0.80, 0.5 * a), 0.8)

	# 命中火花
	for sp in _sparks:
		var k: float = clampf(1.0 - sp["t"] / SPARK_LIFE, 0.0, 1.0)
		var pos: Vector2 = sp["pos"]
		var r: float = lerpf(2.0, 9.0, 1.0 - k)
		draw_circle(pos, r, Color(1.0, 0.75, 0.32, 0.35 * k))
		# 四向溅射线
		for i in 5:
			var ang: float = TAU * (float(i) / 5.0) + float(sp["t"]) * 6.0
			var v := Vector2.RIGHT.rotated(ang)
			draw_line(pos + v * r * 0.4, pos + v * (r * 1.9), Color(1.0, 0.88, 0.55, 0.7 * k), 1.4)

	# 枪口闪光
	for mz in _muzzles:
		var k2: float = clampf(1.0 - mz["t"] / MUZZLE_LIFE, 0.0, 1.0)
		var p: Vector2 = mz["pos"]
		var d: Vector2 = mz["dir"]
		var n := d.orthogonal()
		var len_px := lerpf(10.0, 22.0, k2)
		draw_colored_polygon(
			PackedVector2Array([p + d * len_px, p + n * 5.0, p - n * 5.0]),
			Color(1.0, 0.90, 0.55, 0.85 * k2)
		)
		draw_circle(p, 5.0 * k2, Color(1.0, 0.95, 0.72, 0.7 * k2))

func clear_all() -> void:
	_tracers.clear()
	_sparks.clear()
	_muzzles.clear()
	queue_redraw()
