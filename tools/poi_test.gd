extends SceneTree
## POI 生成器验证：跑多次生成，检查连通性硬规则与结构统计，并打印一张可视化。
func _init() -> void:
	print("=== POI 生成器验证 ===")
	var fails := 0

	# 批量生成，检查连通性
	print("\n[批量 40 次生成]")
	var total_pruned := 0
	var total_orphan := 0
	var ok_count := 0
	for i in 40:
		var cfg = PoiGenerator.Config.new()
		cfg.width = 60
		cfg.height = 44
		cfg.seed = 1000 + i
		var g = PoiGenerator.new(cfg)
		if not g.generate():
			print("  ✗ 第 %d 次生成失败" % i)
			fails += 1
			continue
		ok_count += 1
		total_pruned += int(g.stats.get("pruned_rooms", 0))
		total_orphan += int(g.stats.get("orphan_cells", 0))
		# 硬校验：所有可行走格必须从出生点可达
		if not _all_reachable(g):
			print("  ✗ 第 %d 次存在不可达可行走格！" % i)
			fails += 1
	print("  成功 %d/40，累计剪除孤岛房间 %d 间 / 孤立格 %d 个" % [ok_count, total_pruned, total_orphan])
	if fails == 0:
		print("  ✓ 全部生成的图都 100%% 连通（含出生点）")

	# 单次详细统计 + 可视化
	print("\n[单次生成详情]")
	var cfg2 = PoiGenerator.Config.new()
	cfg2.width = 60
	cfg2.height = 40
	cfg2.seed = 20260818
	var g2 = PoiGenerator.new(cfg2)
	if g2.generate():
		for k in g2.stats:
			print("  %-16s %s" % [k, str(g2.stats[k])])
		var by_r := {}
		for c in g2.containers:
			var r: String = c["richness"]
			by_r[r] = int(by_r.get(r, 0)) + 1
		print("  容器分布      ", by_r)
		print("  出生点        ", g2.spawn_cell)
		# 房间深度分布
		var depths := []
		for r in g2.rooms:
			if not r["solid"]:
				depths.append(int(r["depth"]))
		depths.sort()
		if depths.size() > 0:
			print("  房间深度      最浅 %d / 中位 %d / 最深 %d" % [depths[0], depths[depths.size()/2], depths[-1]])
		# 单入口 vs 互通比例
		var single := 0
		var multi := 0
		for r in g2.rooms:
			if r["solid"]:
				continue
			if r["doors"].size() <= 1:
				single += 1
			else:
				multi += 1
		var tot: int = maxi(single + multi, 1)
		print("  入口结构      单入口 %d (%.0f%%) / 多入口 %d (%.0f%%)" % [
			single, 100.0*single/tot, multi, 100.0*multi/tot])
		print("\n[布局可视化]  # 墙  . 地板  P 出生  1-4 容器档")
		for line in g2.to_debug_lines():
			print("  " + line)
	else:
		print("  ✗ 生成失败")
		fails += 1

	print("")
	if fails == 0:
		print("✅ POI 生成器验证通过")
	else:
		print("❌ 有 %d 项失败" % fails)
	quit(0 if fails == 0 else 1)

## 从出生点洪泛，确认没有任何可行走格不可达
func _all_reachable(g) -> bool:
	var start = g.spawn_cell
	if start.x < 0:
		return false
	var seen := {}
	var q: Array = [start]
	seen[start] = true
	while not q.is_empty():
		var cur = q.pop_front()
		for d in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			var nx = cur + d
			if seen.has(nx):
				continue
			if nx.x < 0 or nx.y < 0 or nx.x >= g.cfg.width or nx.y >= g.cfg.height:
				continue
			var ch: String = g.grid[nx.y][nx.x]
			if ch == "#":
				continue
			seen[nx] = true
			q.append(nx)
	# 统计所有可行走格
	for y in g.cfg.height:
		for x in g.cfg.width:
			if g.grid[y][x] != "#" and not seen.has(Vector2i(x, y)):
				return false
	return true
