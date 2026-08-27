extends SceneTree
func _init() -> void:
	var cfg = PoiGenerator.Config.new()
	cfg.width = 60; cfg.height = 40; cfg.seed = 20260818
	var g = PoiGenerator.new(cfg)
	g.generate()
	print("rooms_total=", g.rooms.size())
	var szs := {}
	var door_dist := {}
	var adj_pairs := 0
	for i in g.rooms.size():
		var r = g.rooms[i]
		if r["solid"]: continue
		var k = "%dx%d" % [r["rect"].size.x, r["rect"].size.y]
		szs[k] = int(szs.get(k,0)) + 1
		var dn = r["doors"].size()
		door_dist[dn] = int(door_dist.get(dn,0)) + 1
		for j in range(i+1, g.rooms.size()):
			if g.rooms[j]["solid"]: continue
			if not g._shared_wall(r["rect"], g.rooms[j]["rect"]).is_empty():
				adj_pairs += 1
	print("房间尺寸分布 ", szs)
	print("门数分布 ", door_dist)
	print("相邻房间对数 ", adj_pairs)
	print("interconnect target = ", int(round(cfg.interconnect_chance * g._open_room_count())))
	quit()
