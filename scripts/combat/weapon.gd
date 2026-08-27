class_name Weapon
extends RefCounted
## Weapon · 枪械运行时状态机（纯数据层，无 UI/节点依赖 → 可被服务端复用）
##
## 射击手感照鸭科夫：
## - 全自动 / 单发切换（V 键）
## - 弹匣 + 备弹分离，换弹分「战术换弹（膛内留一发）」与「空仓换弹」两种时长
## - 连发扩散累积（spread_per_shot），停火后按 spread_recover 回落
## - ADS（右键瞄准）压扩散、降移速
## - 姿态修正：冲刺扩散暴涨、潜行收敛
## - 距离衰减：超过 falloff_start 后伤害线性降到 falloff_min_mul
##
## GameData 走惰性获取，原因同 GridInventory —— class_name 全局类解析早于 autoload 注册。

signal fired(origin: Vector2, dir: Vector2, spread_deg: float)
signal reload_started(duration: float)
signal reload_finished()
signal ammo_changed(mag: int, reserve: int)
signal fire_mode_changed(mode: String)
signal dry_fire()

var id: String = "m4"
var def: Dictionary = {}

var mag: int = 0                 ## 弹匣内余弹
var reserve: int = 0             ## 备弹
var chambered: bool = false      ## 膛内是否有弹（决定战术换弹）
var fire_mode: String = "auto"
var _mode_index: int = 0

var reloading: bool = false
var reload_left: float = 0.0
var _reload_total: float = 0.0

var _cooldown: float = 0.0       ## 射速冷却
var spread: float = 0.0          ## 当前额外扩散（度）
var ads: float = 0.0             ## 瞄准进度 0–1
var _trigger_held_prev: bool = false
var _single_fired: bool = false  ## 单发模式下本次扣扳机是否已开火

static var _gd = null

static func _data():
	if _gd == null or not is_instance_valid(_gd):
		var loop := Engine.get_main_loop()
		if loop is SceneTree:
			_gd = (loop as SceneTree).root.get_node_or_null("/root/GameData")
	return _gd

func _init(weapon_id: String = "m4") -> void:
	id = weapon_id
	var gd = _data()
	if gd != null:
		def = gd.weapon(weapon_id)
	if def.is_empty():
		push_warning("Weapon: 未找到定义 %s" % weapon_id)
		def = {}
	fire_mode = _modes()[0]
	mag = mag_size()
	chambered = mag > 0
	reserve = _reserve_default()
	ammo_changed.emit(mag, reserve)

# ── 定义读取 ────────────────────────────────────────────
func _f(key: String, fallback: float) -> float:
	return float(def.get(key, fallback))

func _i(key: String, fallback: int) -> int:
	return int(def.get(key, fallback))

func display_name() -> String:
	return str(def.get("name", id))

func caliber() -> String:
	return str(def.get("caliber", "5.56"))

func mag_size() -> int:
	return _i("mag_size", 30)

func damage() -> float:
	return _f("damage", 12.0)

func rpm() -> float:
	return maxf(_f("rpm", 780.0), 1.0)

func shot_interval() -> float:
	return 60.0 / rpm()

func range_px() -> float:
	return _f("range", 900.0)

func bullet_speed() -> float:
	return _f("bullet_speed", 2600.0)

func _modes() -> Array:
	var m: Array = def.get("fire_modes", ["auto"])
	return m if m.size() > 0 else ["auto"]

func _reserve_default() -> int:
	var gd = _data()
	if gd == null:
		return 120
	return int(gd.ammo(caliber()).get("reserve_default", 120))

func reserve_max() -> int:
	var gd = _data()
	if gd == null:
		return 300
	return int(gd.ammo(caliber()).get("reserve_max", 300))

# ── 每帧推进 ────────────────────────────────────────────
## stance: 0=行走 1=冲刺 2=潜行
func tick(delta: float, aiming: bool, stance: int) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta

	# ADS 进度
	var ads_time: float = maxf(_f("ads_time", 0.22), 0.01)
	var ads_target := 1.0 if (aiming and stance != 1) else 0.0
	ads = move_toward(ads, ads_target, delta / ads_time)

	# 扩散回落
	if spread > 0.0:
		spread = maxf(0.0, spread - _f("spread_recover", 6.0) * delta)

	# 换弹推进
	if reloading:
		reload_left -= delta
		if reload_left <= 0.0:
			_finish_reload()

## 当前有效扩散（度），含姿态与 ADS 修正
func effective_spread(stance: int) -> float:
	var base: float = _f("spread_base", 0.6) + spread
	var mul := 1.0
	if stance == 1:
		mul *= _f("sprint_spread_mul", 3.2)
	elif stance == 2:
		mul *= _f("crouch_spread_mul", 0.7)
	# ADS 线性插值到 ads_spread_mul
	var ads_mul: float = lerpf(1.0, _f("ads_spread_mul", 0.35), ads)
	return clampf(base * mul * ads_mul, 0.0, _f("spread_max", 7.5) * 2.0)

## 移速倍率（ADS 时减速）
func move_speed_mul() -> float:
	return lerpf(1.0, _f("ads_move_mul", 0.45), ads)

# ── 开火 ────────────────────────────────────────────────
## 返回 true 表示本帧成功打出一发
func try_fire(trigger_held: bool, origin: Vector2, aim: Vector2, stance: int, infinite: bool) -> bool:
	var just_pressed := trigger_held and not _trigger_held_prev
	_trigger_held_prev = trigger_held
	if just_pressed:
		_single_fired = false

	if not trigger_held or reloading:
		return false
	if fire_mode == "single" and _single_fired:
		return false
	if _cooldown > 0.0:
		return false

	if mag <= 0:
		if just_pressed:
			dry_fire.emit()
		return false

	# 消耗
	if not infinite:
		mag -= 1
	chambered = mag > 0 or true   # 打过一发后膛内仍有壳→下次换弹算战术换弹
	_cooldown = shot_interval()
	_single_fired = true

	# 扩散累积
	spread = minf(spread + _f("spread_per_shot", 0.9), _f("spread_max", 7.5))

	var sp := effective_spread(stance)
	fired.emit(origin, aim, sp)
	ammo_changed.emit(mag, reserve)
	return true

## 单发弹道方向（含随机扩散）
func roll_direction(aim: Vector2, spread_deg: float, rng: RandomNumberGenerator) -> Vector2:
	if spread_deg <= 0.0:
		return aim
	var off := deg_to_rad(rng.randf_range(-spread_deg, spread_deg))
	return aim.rotated(off)

## 距离衰减后的伤害
func damage_at(dist: float) -> float:
	var start: float = _f("falloff_start", 420.0)
	var maxr := range_px()
	if dist <= start:
		return damage()
	if dist >= maxr:
		return damage() * _f("falloff_min_mul", 0.55)
	var t: float = (dist - start) / maxf(maxr - start, 1.0)
	return damage() * lerpf(1.0, _f("falloff_min_mul", 0.55), t)

# ── 换弹 ────────────────────────────────────────────────
func can_reload(infinite: bool) -> bool:
	if reloading:
		return false
	if mag >= mag_size():
		return false
	return infinite or reserve > 0

func start_reload(infinite: bool) -> bool:
	if not can_reload(infinite):
		return false
	reloading = true
	# 战术换弹：膛内还有弹（mag>0）时更快，因为不用拉栓上膛
	_reload_total = _f("reload_time_tactical", 2.0) if mag > 0 else _f("reload_time", 2.4)
	reload_left = _reload_total
	reload_started.emit(_reload_total)
	return true

func cancel_reload() -> void:
	if not reloading:
		return
	reloading = false
	reload_left = 0.0

func reload_progress() -> float:
	if not reloading or _reload_total <= 0.0:
		return 0.0
	return clampf(1.0 - reload_left / _reload_total, 0.0, 1.0)

func _finish_reload() -> void:
	reloading = false
	reload_left = 0.0
	var need: int = mag_size() - mag
	# 无限备弹由调用方在 tick 前把 reserve 补满，这里只做常规扣减
	var take: int = mini(need, reserve)
	mag += take
	reserve -= take
	chambered = mag > 0
	reload_finished.emit()
	ammo_changed.emit(mag, reserve)

# ── 射击模式 ────────────────────────────────────────────
func cycle_fire_mode() -> void:
	var m := _modes()
	if m.size() <= 1:
		return
	_mode_index = (_mode_index + 1) % m.size()
	fire_mode = str(m[_mode_index])
	fire_mode_changed.emit(fire_mode)

func add_reserve(amount: int) -> void:
	reserve = clampi(reserve + amount, 0, reserve_max())
	ammo_changed.emit(mag, reserve)

func refill_all() -> void:
	reserve = reserve_max()
	mag = mag_size()
	chambered = true
	ammo_changed.emit(mag, reserve)
