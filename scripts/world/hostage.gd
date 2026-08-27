extends CharacterBody2D
## Hostage · 合约人质。可被玩家子弹打死；K 背起/放下；可坐载具。

const RADIUS := 11.0

var display_name := "人质·艾拉"
var health: Health = null
var director = null
var carried_by = null
var vehicle = null
var vehicle_seat: int = -1

func setup(d, world_pos: Vector2, tag: String = "人质·艾拉") -> void:
	director = d
	display_name = tag
	global_position = world_pos

func _ready() -> void:
	add_to_group("hostages")
	add_to_group("vision_gated")
	collision_layer = 1 << 1
	collision_mask = 1 << 0
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	z_index = 9
	var shape := CollisionShape2D.new()
	var circ := CircleShape2D.new()
	circ.radius = RADIUS
	shape.shape = circ
	add_child(shape)
	health = Health.new(Tuning.hostage_hp)
	health.died.connect(_on_died)

func is_dead() -> bool:
	return health != null and health.dead

func take_damage(amount: float, from: Vector2) -> void:
	if is_dead() or health == null:
		return
	if carried_by != null:
		# 背着时仍可被误伤
		pass
	health.apply_damage(amount, from)

func _on_died(_from: Vector2) -> void:
	if carried_by != null and is_instance_valid(carried_by) and carried_by.has_method("drop_hostage"):
		carried_by.drop_hostage()
	if vehicle != null and is_instance_valid(vehicle):
		vehicle.disembark(self)
		leave_vehicle_forced()
	collision_layer = 0
	collision_mask = 0
	if director != null:
		director.fail_contract("人质死亡")
	queue_redraw()
	set_physics_process(false)

func set_carried(who) -> void:
	if who != carried_by and carried_by != null and is_instance_valid(carried_by):
		if carried_by.has_method("clear_carried_hostage"):
			carried_by.clear_carried_hostage()
	carried_by = who
	if who != null:
		collision_mask = 0
		z_index = 11
	else:
		collision_mask = 1 << 0
		z_index = 9
	queue_redraw()

func leave_vehicle_forced() -> void:
	vehicle = null
	vehicle_seat = -1

func _physics_process(_delta: float) -> void:
	if is_dead():
		return
	if vehicle != null:
		if not is_instance_valid(vehicle):
			leave_vehicle_forced()
		return
	if carried_by != null and is_instance_valid(carried_by):
		var back: Vector2 = -carried_by.aim_dir if carried_by.get("aim_dir") != null else Vector2.DOWN
		if back.length_squared() < 0.01:
			back = Vector2.DOWN
		global_position = carried_by.global_position + back.normalized() * 18.0
		rotation = carried_by.rotation
		velocity = Vector2.ZERO
		return
	velocity = Vector2.ZERO

func set_perceived(v: bool) -> void:
	if carried_by != null:
		visible = true
		return
	visible = v or Tuning.show_enemy_debug

func _draw() -> void:
	var col := Color(0.35, 0.92, 0.95)
	if is_dead():
		col = Color(0.45, 0.22, 0.28)
	draw_circle(Vector2.ZERO, RADIUS + 2.5, Color(0.08, 0.18, 0.20, 0.9))
	draw_circle(Vector2.ZERO, RADIUS, col)
	draw_arc(Vector2.ZERO, RADIUS + 5.0, 0, TAU, 20, Color(1.0, 0.92, 0.35, 0.95), 2.0)
	draw_string(ThemeDB.fallback_font, Vector2(-40, -26), display_name,
		HORIZONTAL_ALIGNMENT_CENTER, 80, 13, Color(1.0, 0.95, 0.45))
	if health != null and not health.dead:
		var bw := 26.0
		draw_rect(Rect2(Vector2(-bw * 0.5, -RADIUS - 12), Vector2(bw, 3)), Color(0.1, 0.1, 0.12, 0.85))
		draw_rect(Rect2(Vector2(-bw * 0.5, -RADIUS - 12), Vector2(bw * health.ratio(), 3)),
			Color(0.4, 0.95, 0.7))
	if carried_by != null:
		draw_string(ThemeDB.fallback_font, Vector2(-28, 20), "背负中",
			HORIZONTAL_ALIGNMENT_CENTER, 56, 11, Color(1.0, 0.88, 0.4))
