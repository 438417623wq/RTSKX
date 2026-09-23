extends SceneTree

## 无头冒烟测试：验证 World 模拟能长时间稳定运行、AI 能出兵、经济能增长、
## 战斗能发生、游戏能正常结束。不涉及任何渲染。

func _init() -> void:
	var fails: Array = []
	var passes: Array = []

	# ---- 1. 三个阵营各自开局
	for race in ["terran", "zerg", "protoss"]:
		var w := World.new(64, 40, race, _foe(race), "normal")
		if w.units_of(World.PLAYER).size() > 0 and w.buildings_of(World.PLAYER).size() > 0:
			passes.append("开局生成 · " + race)
		else:
			fails.append("开局生成失败 · " + race)

	# ---- 2. 长时间模拟（180 秒游戏时间，检查稳定性 / AI / 经济 / 战斗）
	var w2 := World.new(64, 40, "terran", "zerg", "normal")
	var start_min: float = w2.factions[World.PLAYER]["minerals"]
	var saw_combat := false
	var saw_projectile := false
	var max_units := 0
	var steps := int(180.0 / 0.05)
	var crashed := ""

	for i in range(steps):
		w2.step(0.05)
		if w2.projectiles.size() > 0:
			saw_projectile = true
		if w2.units_of(World.PLAYER).size() > max_units:
			max_units = w2.units_of(World.PLAYER).size()
		# 检测是否有单位受击（战斗发生）
		for u in w2.units_of(World.PLAYER):
			if u.hp < u.max_hp:
				saw_combat = true
				break
		if w2.game_ended:
			break
		if i % 600 == 0:
			# 每 30 游戏秒做一次一致性检查
			for u in w2.units:
				if is_nan(u.pos.x) or is_nan(u.pos.y):
					crashed = "单位坐标 NaN @ step %d" % i
					break
			if crashed != "":
				break

	if crashed == "":
		passes.append("180 秒无头模拟无崩溃")
	else:
		fails.append(crashed)

	# ---- 3. 玩家经济能增长（初始农民自动采矿）
	var w3 := World.new(48, 32, "terran", "zerg", "easy")
	var workers := []
	for u in w3.units_of(World.PLAYER):
		if u.can_harvest():
			workers.append(u)
	var node = null
	for r in w3.resources:
		node = r
		break
	if not workers.is_empty() and node != null:
		w3.cmd_harvest(workers, node)
		var m0: float = w3.factions[World.PLAYER]["minerals"]
		for i in range(1200):
			w3.step(0.05)
		var m1: float = w3.factions[World.PLAYER]["minerals"]
		if m1 > m0:
			passes.append("采集经济运转（%.0f → %.0f）" % [m0, m1])
		else:
			fails.append("采集未产生收益（%.0f → %.0f）" % [m0, m1])
	else:
		fails.append("未找到农民或矿点")

	# ---- 4. 建造流程
	var w4 := World.new(48, 32, "terran", "zerg", "easy")
	w4.factions[World.PLAYER]["minerals"] = 2000
	var base = null
	for b in w4.buildings_of(World.PLAYER):
		base = b
		break
	var built_ok := false
	if base != null:
		# 在主基地附近找一个可放置点
		for ang in range(0, 360, 15):
			var rad := deg_to_rad(float(ang))
			var p: Vector2 = base.pos + Vector2(cos(rad), sin(rad)) * 150.0
			if w4.can_place_building("supply_depot", p, World.PLAYER)["ok"]:
				built_ok = w4.cmd_build("supply_depot", p, World.PLAYER)
				break
	if built_ok:
		passes.append("建造指令可用")
	else:
		fails.append("建造指令失败（找不到可放置点）")

	# ---- 5. 训练 + 人口限制
	var w5 := World.new(48, 32, "terran", "zerg", "easy")
	w5.factions[World.PLAYER]["minerals"] = 3000
	var cc = null
	for b in w5.buildings_of(World.PLAYER):
		if b.type_id == "command_center":
			cc = b
			break
	var trained := false
	var peak_scv := 0
	if cc != null:
		for i in range(8):
			w5.cmd_train(cc, "scv")
		for i in range(4000):
			w5.step(0.05)
			# 记录峰值：这一节要验证的是「队列能产出单位」，
			# 后期 AI 会把毫无防守的农民杀光，用末态计数会误判
			peak_scv = maxi(peak_scv, w5.count_units(World.PLAYER, "scv"))
		trained = peak_scv > 3
	if trained:
		passes.append("训练队列产出单位（峰值 %d 个 SCV）" % peak_scv)
	else:
		fails.append("训练队列未产出单位（峰值 %d）" % peak_scv)

	# ---- 6. 敌方 AI 有实质行动（经济增长 / 出兵）
	var w6 := World.new(64, 40, "terran", "zerg", "normal")
	var e0 := w6.count_units(World.ENEMY)
	var e_buildings0 := w6.buildings_of(World.ENEMY).size()
	for i in range(4000):
		w6.step(0.05)
		if w6.game_ended:
			break
	var e1 := w6.count_units(World.ENEMY)
	var e_buildings1 := w6.buildings_of(World.ENEMY).size()
	if e1 > e0 or e_buildings1 > e_buildings0:
		passes.append("敌方 AI 在扩张（单位 %d→%d，建筑 %d→%d）" % [e0, e1, e_buildings0, e_buildings1])
	else:
		fails.append("敌方 AI 无行动（单位 %d→%d，建筑 %d→%d）" % [e0, e1, e_buildings0, e_buildings1])

	# ---- 7. 伤害矩阵正确性
	var dmg_expl_vs_building := GameData.compute_damage(100.0, "explosive", "building", 0)
	var dmg_conc_vs_heavy := GameData.compute_damage(100.0, "concussive", "heavy", 0)
	if dmg_expl_vs_building > dmg_conc_vs_heavy:
		passes.append("伤害矩阵生效（爆炸对建筑 %.0f > 冲击对重甲 %.0f）" % [dmg_expl_vs_building, dmg_conc_vs_heavy])
	else:
		fails.append("伤害矩阵异常")

	# ---- 8. 寻路可达性（穿越地图）
	var w8 := World.new(64, 40, "terran", "zerg", "normal")
	var a := Vector2(6 * Grid.CELL, 20 * Grid.CELL)
	var b := Vector2(58 * Grid.CELL, 20 * Grid.CELL)
	var path := w8.grid.find_path(a, b)
	if path.size() > 0:
		passes.append("跨地图寻路成功（%d 个路径点）" % path.size())
	else:
		fails.append("跨地图寻路失败")

	# ---- 9. 程序化音效：全部代码合成，零外部素材
	var sfx_names := ["ui_click", "ui_error", "ui_open", "build_start", "build_done",
		"train_done", "shot_bullet", "shot_cannon", "shot_laser", "shot_acid",
		"shot_psionic", "melee_hit", "explosion", "unit_death", "unit_ack",
		"place_ok", "place_bad", "victory", "defeat"]
	var sfx_bad := []
	var sfx_bytes := 0
	for n in sfx_names:
		var st := GenSfx.get_sfx(n)
		if st == null or st.data.is_empty():
			sfx_bad.append(n + "(空)")
			continue
		var dur := st.get_length()
		if dur < 0.03 or dur > 1.2:
			sfx_bad.append("%s(时长 %.2fs 异常)" % [n, dur])
			continue
		# 峰值必须非零 —— 全是静音说明合成参数写错了
		var peak := 0
		var data := st.data
		for i in range(0, data.size(), 2):
			var v := int(data[i]) | (int(data[i + 1]) << 8)
			if v >= 32768:
				v -= 65536
			peak = maxi(peak, absi(v))
		if peak < 1000:
			sfx_bad.append("%s(峰值仅 %d)" % [n, peak])
			continue
		sfx_bytes += data.size()
	if sfx_bad.is_empty():
		passes.append("程序化音效 %d 个全部有效（合计 %.0f KB）"
			% [sfx_names.size(), float(sfx_bytes) / 1024.0])
	else:
		fails.append("音效异常：" + ", ".join(sfx_bad))

	# ---- 10. 音效事件确实从逻辑层发出来了
	var w10 := World.new(48, 32, "terran", "zerg", "easy")
	var seen := {}
	w10.event_sfx.connect(func(kind: String, _pos: Vector2) -> void:
		seen[kind] = int(seen.get(kind, 0)) + 1)
	# 把玩家部队直接推到敌方基地，强制打出交火
	for u in w10.units_of(World.PLAYER):
		u.pos = w10.buildings_of(World.ENEMY)[0].pos + Vector2(70, 0)
	for i in range(600):
		w10.step(0.05)
	var combat_sfx := ["shot_bullet", "shot_cannon", "shot_laser", "melee_hit", "explosion"]
	var got := false
	for k in combat_sfx:
		if seen.has(k):
			got = true
			break
	if got:
		passes.append("交火音效事件已发出（%s）" % str(seen.keys()))
	else:
		fails.append("未收到任何交火音效事件（%s）" % str(seen.keys()))

	# ---- 汇总
	print("")
	print("=============== 冒烟测试结果 ===============")
	for p in passes:
		print("  [PASS] " + p)
	for f in fails:
		print("  [FAIL] " + f)
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [passes.size(), fails.size()])
	print("  （模拟末态：玩家单位 %d，AI 单位 %d，AI 建筑 %d，投射物 %d）" % [
		w2.count_units(World.PLAYER), w2.count_units(World.ENEMY),
		w2.buildings_of(World.ENEMY).size(), w2.projectiles.size()])
	print("============================================")
	quit(0 if fails.is_empty() else 1)

func _foe(r: String) -> String:
	match r:
		"terran": return "zerg"
		"zerg": return "protoss"
		_: return "terran"
