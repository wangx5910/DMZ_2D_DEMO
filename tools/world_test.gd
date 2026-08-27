extends Node
## 大地图验证：作为节点挂进主场景，检查分区/POI/出生点/性能相关统计
var _f := 0
var _done := false
func _process(_d: float) -> void:
	_f += 1
	if _f < 12 or _done: return
	_done = true
	var inst = get_parent()
	var w = inst.level
	print("=== 2km 大地图验证 ===")
	if w == null or not ("stats" in w):
		print("  ✗ 大地图未加载（可能 use_world_map=false）")
		get_tree().quit(1); return
	for k in w.stats:
		print("  %-16s %s" % [k, str(w.stats[k])])
	print("")
	# 分区明细
	print("[分区]")
	for key in w.districts:
		var d = w.districts[key]
		var r = d["rect"]
		var km_w = float(r[2]) * 5.0 / 1000.0
		var km_h = float(r[3]) * 5.0 / 1000.0
		print("  %-8s tier%d  %.2f×%.2f km  %s" % [d["name"], int(d.get("tier",0)), km_w, km_h, d.get("terrain","")])
	# POI 明细
	print("\n[POI]  名称 / 类型 / 所属区tier / 尺寸(米) / 容器数")
	for p in w.pois:
		var pd = p["def"]
		var g = p["gen"]
		var dk = str(pd.get("district",""))
		var tier = int(w.districts.get(dk, {}).get("tier", 0))
		print("  %-12s %-5s t%d  %dm×%dm  %d 容器 (单入口 %s)" % [
			pd["name"], pd.get("type","open"), tier,
			g.cfg.width*5, g.cfg.height*5, g.containers.size(),
			g.stats.get("single_entry_pct","?")])
	# 出生点检查
	print("\n[出生点]")
	var sp = w.spawn_point
	print("  坐标 ", sp, "  格 (%d, %d)" % [int(sp.x/40), int(sp.y/40)])
	var dist = w.district_at(sp)
	print("  所在区 ", dist.get("name","(无分区/空地)"))
	var space = get_viewport().world_2d.direct_space_state
	var q = PhysicsPointQueryParameters2D.new()
	q.position = sp
	q.collision_mask = 1
	print("  是否卡墙 ", "是（错误！）" if not space.intersect_point(q).is_empty() else "否 ✓")
	var np = w.nearest_poi(sp)
	if not np.is_empty():
		print("  最近 POI  %s  %.0f 米" % [np["def"]["name"], np["dist"]/8.0])
	# tier 递进检查：出生区到各 tier 的距离应递增
	print("\n[tier 距离梯度]（从出生点算，应大体递增）")
	var by_tier := {}
	for p in w.pois:
		var dk2 = str(p["def"].get("district",""))
		var t = int(w.districts.get(dk2, {}).get("tier", 0))
		var o = p["origin"]
		var c = Vector2((o.x + p["gen"].cfg.width*0.5)*40.0, (o.y + p["gen"].cfg.height*0.5)*40.0)
		var dm = sp.distance_to(c) / 8.0
		if not by_tier.has(t): by_tier[t] = []
		by_tier[t].append(dm)
	var tiers = by_tier.keys()
	tiers.sort()
	for t in tiers:
		var arr = by_tier[t]
		var sum = 0.0
		for v in arr: sum += v
		print("  tier%d  平均 %.0f 米  (%d 个 POI)" % [t, sum/arr.size(), arr.size()])
	# 容器总数分布
	var rich := {}
	for p in w.pois:
		for ct in p["gen"].containers:
			var r2 = str(ct["richness"])
			rich[r2] = int(rich.get(r2,0)) + 1
	print("\n[全图容器] ", rich)
	print("\n[POI 间距]  保底 %.0f 米（外墙到外墙）" % w.POI_MIN_GAP_M)
	var pairs: Array = []
	for i in w.pois.size():
		for j in range(i + 1, w.pois.size()):
			var ga: float = w.poi_clearance_m(w.pois[i], w.pois[j])
			pairs.append({
				"d": ga,
				"a": str(w.pois[i]["def"].get("name", "?")),
				"b": str(w.pois[j]["def"].get("name", "?")),
			})
	pairs.sort_custom(func(x, y): return float(x["d"]) < float(y["d"]))
	var tight := 0
	for pr in pairs:
		if float(pr["d"]) + 0.5 < w.POI_MIN_GAP_M:
			tight += 1
	for k in mini(5, pairs.size()):
		var pr = pairs[k]
		var ok: bool = float(pr["d"]) + 0.5 >= w.POI_MIN_GAP_M
		print("  %s  %s ↔ %s  %.0f 米" % [
			"✓" if ok else "✗", pr["a"], pr["b"], pr["d"]])
	if tight > 0:
		print("  ✗ %d 对 POI 间距不足" % tight)
		get_tree().quit(1)
		return
	var ns_h := 0
	var ns_v := 0
	var ew_h := 0
	var ew_v := 0
	for n in get_tree().get_nodes_in_group("cover"):
		if not ("half" in n):
			continue
		var hx: float = n.half.x
		var hy: float = n.half.y
		if bool(n.ns_corridor):
			if hx >= hy:
				ns_h += 1
			else:
				ns_v += 1
		else:
			if hy > hx:
				ew_v += 1
			else:
				ew_h += 1
	print("\n[甬道掩体]  南北向横向 %d / 竖向 %d；东西向竖向 %d / 横向 %d" % [ns_h, ns_v, ew_v, ew_h])
	if ns_v > 0 or ns_h < 1:
		print("  ✗ 南北向甬道掩体应全部为横向")
		get_tree().quit(1)
		return
	print("\n[节点数] 墙体 %d 个 / 容器 %d 个 / 总子节点 %d" % [
		w.stats.get("wall_bodies",0), get_tree().get_nodes_in_group("containers").size(),
		w.get_child_count()])
	get_tree().quit(0)
