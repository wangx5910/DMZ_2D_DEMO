class_name Hitscan
extends RefCounted
## Hitscan · 统一命中判定（玩家 / 玩家AI / 怪物共用）
##
## 旧逻辑用无限细射线打 11px 移动碰撞圆。角色剪影（身体描边 + 朝向三角 + 枪）
## 比碰撞圆大一圈，准星看起来打中了，射线却从身边擦过；枪口前移 16px 后射线
## 还经常从近距离目标体内出发，Godot 默认 hit_from_inside=false，整发穿透不计伤。
##
## 做法：墙/车仍走物理射线（遮挡）；角色用与剪影匹配的圆做射线-圆相交。

const HURT_RADIUS := 17.0          ## 约等于 RADIUS(11) + 朝向三角
const WORLD_MASK := 1 << 0
const VEHICLE_MASK := 1 << 5
const SHIP_WALL_MASK := 1 << 6

## 射线与圆的进入距离。未命中（含完全在身后）返回 -1。
static func ray_circle_enter(from: Vector2, dir: Vector2, center: Vector2, radius: float, max_t: float) -> float:
	if dir.length_squared() < 0.0001 or radius <= 0.0 or max_t <= 0.0:
		return -1.0
	var d: Vector2 = dir.normalized()
	var rel: Vector2 = center - from
	var along: float = rel.dot(d)
	var lat_sq: float = rel.length_squared() - along * along
	var r2: float = radius * radius
	if lat_sq > r2:
		return -1.0
	var half: float = sqrt(r2 - lat_sq)
	var t_enter: float = along - half
	var t_exit: float = along + half
	if t_exit < 0.05:
		return -1.0
	if t_enter < 0.05:
		t_enter = 0.05
	if t_enter >= max_t:
		return -1.0
	return t_enter

static func hurt_radius_of(_actor) -> float:
	return HURT_RADIUS

## 查询一发。origin 用角色中心（与准星锥一致），不要用枪口。
## 返回 { position, collider, normal, blocked }
static func query(world_2d: World2D, from: Vector2, dir: Vector2, range_px: float, shooter: Node2D) -> Dictionary:
	var d: Vector2 = dir.normalized() if dir.length_squared() > 0.0001 else Vector2.RIGHT
	var to: Vector2 = from + d * range_px
	var miss := {
		"position": to,
		"collider": null,
		"normal": Vector2.ZERO,
		"blocked": false,
	}
	if world_2d == null or shooter == null:
		return miss
	var space := world_2d.direct_space_state
	if space == null:
		return miss

	var mask: int = WORLD_MASK | VEHICLE_MASK
	if shooter.get("aboard_ship") != null:
		mask |= SHIP_WALL_MASK
	var q := PhysicsRayQueryParameters2D.create(from, to)
	q.collision_mask = mask
	q.collide_with_areas = false
	q.hit_from_inside = false
	var exclude: Array[RID] = []
	if shooter is CollisionObject2D:
		exclude.append((shooter as CollisionObject2D).get_rid())
	var veh = shooter.get("vehicle")
	if veh != null and is_instance_valid(veh) and veh is CollisionObject2D:
		exclude.append((veh as CollisionObject2D).get_rid())
	q.exclude = exclude

	var wall: Dictionary = space.intersect_ray(q)
	var max_along: float = range_px
	var wall_collider = null
	var wall_pos: Vector2 = to
	var wall_n: Vector2 = Vector2.ZERO
	if not wall.is_empty():
		wall_pos = wall["position"]
		max_along = from.distance_to(wall_pos)
		wall_collider = wall.get("collider")
		wall_n = wall.get("normal", Vector2.ZERO)

	var best_actor = null
	var best_t: float = max_along
	var tree := shooter.get_tree()
	if tree != null:
		for group in ["player", "raider_bots", "enemies", "hostages"]:
			for n in tree.get_nodes_in_group(group):
				if n == shooter or not is_instance_valid(n):
					continue
				if n.has_method("is_dead") and n.is_dead():
					continue
				var t: float = ray_circle_enter(from, d, n.global_position, hurt_radius_of(n), best_t)
				if t < 0.0:
					continue
				best_actor = n
				best_t = t

	if best_actor != null:
		return {
			"position": from + d * best_t,
			"collider": best_actor,
			"normal": -d,
			"blocked": true,
		}
	if wall_collider != null:
		return {
			"position": wall_pos,
			"collider": wall_collider,
			"normal": wall_n,
			"blocked": true,
		}
	return miss
