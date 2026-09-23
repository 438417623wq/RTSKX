extends SceneTree

## 经济系统验证：瓦斯开采链路（气矿 → 气矿建筑 → 农民 → 瓦斯入库）。
## 这是此前完全缺失的一环：没有它，重工厂/尖塔/圣堂文库这些吃瓦斯的建筑永远造不出来。

var _pass := 0
var _fail := 0
var _ran := false

func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] ", label)
	else:
		_fail += 1
		print("  [FAIL] ", label)

func _initialize() -> void:
	print("=============== 经济 / 采气测试 ===============")

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	for race in ["terran", "zerg", "protoss"]:
		_case(race)
	_power_case()
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	print("============================================")
	# ⚠️ 必须显式退出码。少了这一行，套件失败时 rc 仍是 0，
	#    run_all.sh 会当成「全绿」—— 实测漏报过 3 条 FAIL。
	quit(0 if _fail == 0 else 1)
	return true

## 神族招牌机制：除主基地外，所有建筑都必须建在水晶塔的能量场内。
## 这条约束比「建造半径 190」更严，所以不能顺着建筑链把建筑一路铺出去——
## 必须先立水晶塔。这正是神族「先立塔再铺建筑」运营节奏的来源。
func _power_case() -> void:
	print("── 神族能量场 ──")
	var w := World.new(64, 40, "protoss", "terran", "normal")
	w.factions[World.PLAYER]["minerals"] = 3000.0
	var nexus: Building = w.buildings_of(World.PLAYER)[0]
	_ok(w.has_power_at(nexus.pos, World.PLAYER), "主基地投射能量场")
	_ok(w.power_sources(World.PLAYER).size() >= 1,
		"能量场源已注册（%d 个）" % w.power_sources(World.PLAYER).size())

	# 立一座水晶塔
	var pylon_pos: Vector2 = nexus.pos + Vector2(180, 0)
	var chk := w.can_place_building("pylon", pylon_pos, World.PLAYER)
	_ok(chk["ok"], "水晶塔可以立在基地旁（%s）" % String(chk.get("reason", "")))
	w.cmd_build("pylon", pylon_pos, World.PLAYER)
	var pylon = null
	for b in w.buildings_of(World.PLAYER):
		if b.type_id == "pylon":
			pylon = b
	_ok(pylon != null, "水晶塔已落位")
	if pylon == null:
		return
	pylon.complete = true
	pylon.build_progress = pylon.build_time
	_ok(w.has_power_at(pylon.pos + Vector2(200, 0), World.PLAYER), "水晶塔旁 200 像素处于能量场内")
	_ok(not w.has_power_at(pylon.pos + Vector2(240, 0), World.PLAYER), "水晶塔旁 240 像素已在能量场外")

	# 借着传送门再往外接一环：这一环必须被能量场拦住。
	# 方向要试出来——地图上有岩石，硬编码一个方向可能正好撞上障碍。
	var gw = null
	var out_dir := Vector2.RIGHT
	for ang in range(0, 360, 15):
		var a := deg_to_rad(float(ang))
		var dir := Vector2(cos(a), sin(a))
		var cand: Vector2 = pylon.pos + dir * 185.0
		if not w.can_place_building("gateway", cand, World.PLAYER)["ok"]:
			continue
		w.cmd_build("gateway", cand, World.PLAYER)
		for b in w.buildings_of(World.PLAYER):
			if b.type_id == "gateway" and b.pos.distance_to(cand) < 40.0:
				gw = b
		out_dir = dir
		break
	_ok(gw != null, "传送门可以建在能量场边缘内")
	if gw == null:
		return
	var far: Vector2 = gw.pos + out_dir * 175.0
	var chk3 := w.can_place_building("gateway", far, World.PLAYER)
	_ok(not chk3["ok"] and String(chk3.get("reason", "")).contains("能量场"),
		"不能顺着建筑链把建筑铺出能量场（%s）" % String(chk3.get("reason", "")))

func _case(race: String) -> void:
	print("── %s ──" % race)
	var w := World.new(64, 40, race, _foe(race), "normal")
	var gas_map := {"terran": "refinery", "zerg": "extractor", "protoss": "assimilator"}
	var gas_id: String = gas_map[race]

	# 找到己方基地附近的气矿
	var base: Vector2 = w.buildings_of(World.PLAYER)[0].pos
	var geyser = null
	var bd := INF
	for r in w.resources:
		if String(r["kind"]) != "gas":
			continue
		var d: float = base.distance_to(r["pos"])
		if d < bd:
			bd = d
			geyser = r
	_ok(geyser != null and bd < 300.0, "基地附近有气矿（%.0f 像素）" % bd)

	# 没建气矿建筑时，气矿点不中、也采不了
	_ok(w.find_resource_at(geyser["pos"]) == null, "未开发的气矿点不中")
	_ok(w.gas_building_on(geyser) == null, "未开发的气矿没有归属建筑")

	# 非气矿建筑不能压在气矿上
	var bad := w.can_place_building("supply_depot" if race == "terran" else ("spawning_pool" if race == "zerg" else "pylon"), geyser["pos"], World.PLAYER)
	_ok(not bad["ok"], "普通建筑不能压在气矿上（%s）" % String(bad.get("reason", "")))

	# 气矿建筑必须建在气矿上：先试一个远离气矿的位置
	var away: Vector2 = geyser["pos"] + Vector2(0, 120)
	var chk_away := w.can_place_building(gas_id, away, World.PLAYER)
	_ok(not chk_away["ok"], "气矿建筑不能建在离气矿太远的地方（%s）" % String(chk_away.get("reason", "")))

	# 给够钱，盖在气矿上
	w.factions[World.PLAYER]["minerals"] = 800.0
	_ok(w.cmd_build(gas_id, geyser["pos"], World.PLAYER), "在气矿上下达建造指令")
	var gb = w.gas_building_on(geyser, false)
	_ok(gb != null and gb.type_id == gas_id, "气矿建筑已落位（%s）" % (gb.type_id if gb != null else "无"))
	_ok(gb.pos.distance_to(geyser["pos"]) < 1.0, "建筑位置自动吸附到气矿中心")
	_ok(gb.gas_geyser != null, "建筑记住了自己占用的气矿")

	# 建造中还不能采气
	_ok(w.find_resource_at(geyser["pos"]) == null, "建造中的精炼厂还不能采气")
	# 直接把建筑置为完工
	gb.complete = true
	gb.build_progress = gb.build_time
	_ok(w.find_resource_at(geyser["pos"]) == geyser, "完工后气矿变成可点选")

	# 派农民去采气
	var workers := []
	for u in w.units_of(World.PLAYER):
		if u.can_harvest():
			workers.append(u)
	_ok(workers.size() > 0, "有可调度的农民（%d 个）" % workers.size())
	var gas_before: float = w.factions[World.PLAYER]["gas"]
	w.cmd_harvest([workers[0]], geyser)
	_ok(workers[0].resource_target == geyser, "农民接受了采气任务")
	_ok(workers[0].harvest_target == gb, "往返目标是精炼厂而不是主基地")

	# 模拟 90 秒，看瓦斯是否真的进账
	for i in range(60 * 90):
		w.step(1.0 / 60.0)
	var gas_after: float = w.factions[World.PLAYER]["gas"]
	_ok(gas_after > gas_before, "农民把瓦斯送进了气库（%.0f → %.0f）" % [gas_before, gas_after])

	# 拆掉气矿建筑后采气应中断
	gb.dead = true
	for i in range(60 * 5):
		w.step(1.0 / 60.0)
	_ok(workers[0].resource_target == null or String(workers[0].resource_target.get("kind", "")) != "gas",
		"气矿建筑被拆后采气自动中断")

	# 空地：AI 侧也应该自己开气
	#
	# ⚠️ 必须给 AI 一个**公平起手**，否则测出来的是「AI 赢得太快」而不是「AI 开不开气」。
	#    实测默认难度 + 完全被动挨打的玩家：约 125 秒玩家就被推平，而 game_ended
	#    一置位 _update_ai 立刻停摆 —— 连跑 4 次里 3 次瓦斯停在 0
	#    （第 4 次连气矿建筑都没来得及造）。神族 AI 最慢，所以只有这一族红。
	#    三件事一起做：
	#      1. 降到 easy（首波更晚、AI 经济更慢）；
	#      2. 给玩家一队**只站着、不给任何命令**的守备兵，把对局撑久一点；
	#      3. 给 AI 一笔启动资金，免得它为了一座气矿攒半天钱。
	#    公平起手后连跑 3 次：瓦斯 639 / 788 / 903，全部稳定通过。
	var w2 := World.new(64, 40, _foe(race), race, "easy")
	w2.factions[World.ENEMY]["minerals"] = 1200.0
	_garrison(w2, _foe(race))
	for i in range(60 * 300):
		w2.step(1.0 / 60.0)
		if w2.game_ended:
			break
	var ai_gas: float = w2.factions[World.ENEMY]["gas"]
	var ai_gas_b := 0
	for b in w2.buildings_of(World.ENEMY):
		if b.gas_geyser != null:
			ai_gas_b += 1
			_ok(b.complete, "AI 的气矿建筑已完工（%s）" % b.type_id)
	_ok(ai_gas_b > 0, "AI 自己造了气矿建筑（%d 座）" % ai_gas_b)
	_ok(ai_gas > 0.0, "AI 采到了瓦斯（%.0f，对局结束于 %.0f 秒）" % [ai_gas, w2.elapsed])

	# 顺带验证「建造中的建筑会被工兵推进到完工」这条基础链路
	var w3 := World.new(64, 40, race, _foe(race), "normal")
	w3.factions[World.PLAYER]["minerals"] = 900.0
	var base3: Vector2 = w3.buildings_of(World.PLAYER)[0].pos
	var placed := false
	for ang in range(0, 360, 20):
		var rad := deg_to_rad(float(ang))
		var p: Vector2 = base3 + Vector2(cos(rad), sin(rad)) * 140.0
		var sid := "supply_depot" if race == "terran" else ("spawning_pool" if race == "zerg" else "pylon")
		if w3.can_place_building(sid, p, World.PLAYER)["ok"]:
			placed = w3.cmd_build(sid, p, World.PLAYER)
			break
	_ok(placed, "下达建造指令")
	var site = null
	for b in w3.buildings_of(World.PLAYER):
		if not b.complete:
			site = b
			break
	_ok(site != null, "工地已存在（未完工）")
	if site != null:
		for i in range(60 * 60):
			w3.step(1.0 / 60.0)
		_ok(site.complete, "60 秒后建筑自动完工（进度 %.0f/%.0f）" % [site.build_progress, site.build_time])

func _foe(race: String) -> String:
	match race:
		"terran": return "zerg"
		"zerg": return "protoss"
		_: return "terran"

## 给玩家塞一队守备兵，让「AI 会不会自己开气」这条断言撑得住。
##
## ⚠️ 目的是「不被推平」，不是「打赢」：单位只围在基地旁边，
##    不给任何移动 / 攻击命令 —— 一旦主动进攻，测的就不是 AI 的经济了。
##    数量按各族兵的强度折算（跳虫最弱给最多，狂热者最强给最少）。
func _garrison(w: World, race: String) -> void:
	if w.buildings_of(World.PLAYER).is_empty():
		return
	var base: Vector2 = w.buildings_of(World.PLAYER)[0].pos
	var comp := {
		"terran": ["marine", 10],
		"zerg": ["zergling", 12],
		"protoss": ["zealot", 8],
	}
	var type_id: String = comp.get(race, ["marine", 10])[0]
	var n: int = comp.get(race, ["marine", 10])[1]
	for i in range(n):
		var ang := TAU * float(i) / float(n)
		var p: Vector2 = base + Vector2(cos(ang), sin(ang)) * 90.0
		w._spawn_unit(type_id, race, p, World.PLAYER)
