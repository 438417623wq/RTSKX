extends SceneTree

## 空中维度测试（里程碑 A）。
##
## 三组对应三个时段：
##   第一组 H1 —— 数据自洽：谁能飞、谁能打空、生产链与描述是否齐全
##   第二组 H2 —— 索敌与伤害：地面近战打不到空中、防空建筑真的能打
##   第三组 H3 —— 移动与渲染：飞行单位直线走、不被地形阻挡、分层绘制
##
## 为什么第一组必须是「数据自洽」：
## 空 / 地能力漏配的症状**极具误导性** —— 整队跳虫会追着一架飞龙绕地图跑、
## 而且永远追不上，看上去像「AI 变傻了」。这类 bug 靠肉眼观察几乎不可能
## 定位到「表里少了一行」，只能靠断言。

const RACES := ["terran", "zerg", "protoss"]
const AA_BUILDING := {"terran": "missile_turret", "zerg": "spore_colony", "protoss": "photon_cannon"}
const AIR_UNIT := {"terran": "wraith", "zerg": "mutalisk", "protoss": "scout"}
## 本轮新增、必须带介绍文案的条目
const NEW_IDS := ["wraith", "scout", "missile_turret", "spore_colony", "photon_cannon", "stargate"]

var _pass := 0
var _fail := 0

func _init() -> void:
	seed(20260923)
	print("\n=============== 空中维度测试 ===============")
	_test_air_units_exist()
	_test_anti_air_units_exist()
	_test_aa_buildings_registered()
	_test_aa_can_hit_air()
	_test_air_unit_hits_both_layers()
	_test_ground_melee_cannot_hit_air()
	_test_air_units_skip_ground_logic()
	_test_air_units_trainable()
	_test_aa_in_build_menu()
	_test_aa_weapon_sane()
	_test_no_flying_worker()
	_test_no_air_attacker_without_damage()
	_test_id_namespaces_disjoint()
	_test_descriptions()
	print("  ---- 第二组：索敌与伤害 ----")
	_test_search_filters_layer()
	_test_aa_turret_ignores_ground()
	_test_aa_turret_deals_damage()
	_test_aa_turret_cannot_hurt_ground()
	_test_unfinished_turret_cannot_fire()
	_test_melee_cannot_kill_air()
	_test_splash_respects_layer()
	print("  ---- 第三组：移动与分层 ----")
	_test_flying_ignores_terrain()
	_test_air_ground_do_not_push()
	_test_air_air_push()
	_test_flying_not_picked_as_builder()
	_test_aa_building_lookup()
	_test_ai_prefers_aa_units()
	print("  ---- 第四组：美术与数据一致 ----")
	_test_bundled_skins_disabled()
	_test_every_id_has_dedicated_sprite()
	_test_building_base_plate_matches_faction()
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

# ================================================================ 工具

func _units_of(race: String) -> Array:
	var out := []
	for uid in GameData.UNITS:
		if String(GameData.UNITS[uid].get("faction", "")) == race:
			out.append(uid)
	return out

## 一个干净的测试场：清空单位、关掉 AI 与胜负结算。
## 返回 [world, 主基地]
func _arena() -> Array:
	var w := World.new(64, 40, "terran", "zerg", "easy")
	w.units.clear()
	w.game_ended = true
	return [w, w.buildings_of(World.PLAYER)[0]]

func _report(label: String, ok: bool, note: String = "") -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s  %s" % [label, note])
	else:
		_fail += 1
		print("  [FAIL] %s  %s" % [label, note])

# ================================================================ 第一组：数据自洽

## 三族各有至少一个空中单位，且它是有攻击力的战斗单位。
## 「飞在天上的农民」是死配置 —— 采集、建造、寻路全都不认飞行层。
func _test_air_units_exist() -> void:
	for race in RACES:
		var air := []
		for uid in _units_of(race):
			if GameData.is_flying(uid):
				air.append(uid)
		var all_combat := true
		var offenders := []
		for uid in air:
			var d := GameData.get_unit(uid)
			# ⚠️ **支援单位（`role == "support"`）豁免**：科学球和星际 1 一样是
			#    零攻击的空中施法单位，它的价值全在辐照上。
			#    但它**必须带技能** —— 「不能打、也不能放技能」的空中单位
			#    才是真的死配置（造价 100/225，上场就是白送）。
			if String(d.get("role", "")) == "support":
				if (d.get("abilities", []) as Array).is_empty():
					all_combat = false
					offenders.append(String(uid) + "(支援单位却没有技能)")
				continue
			if float(d.get("damage", 0)) <= 0.0:
				all_combat = false
				offenders.append(String(uid))
		_report("%s 有空中单位" % race, air.size() >= 1,
			"共 %d 个：%s" % [air.size(), str(air)])
		_report("%s 的空中单位都有攻击力（支援单位豁免，但必须有技能）" % race,
			all_combat, "违规：%s" % str(offenders))

## 三族各有能打到空中的单位 —— 否则对方一出空军就无解。
func _test_anti_air_units_exist() -> void:
	for race in RACES:
		var aa := []
		for uid in _units_of(race):
			if GameData.can_attack_air(uid):
				aa.append(uid)
		_report("%s 有能对空的单位" % race, aa.size() >= 1,
			"%d 个：%s" % [aa.size(), str(aa)])

## 三族的防空建筑都已定义、都已注册进 AIR_RULES。
func _test_aa_buildings_registered() -> void:
	for race in RACES:
		var bid: String = AA_BUILDING[race]
		var d := GameData.get_building(bid)
		var ok: bool = not d.is_empty() and GameData.can_attack_air(bid)
		_report("%s 的防空建筑 %s 已注册且能对空" % [race, bid], ok,
			"伤害 %s / 射程 %s" % [str(d.get("damage", 0)), str(d.get("range", 0))])

## ★核心★ 防空建筑必须真的打得到空中 —— 用 can_hit 实测，不是看表。
## 同时锁定「只对空」与「对空+对地」两种定位（星际 1 的差异）。
func _test_aa_can_hit_air() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(420, 420), World.ENEMY)
	var ground: Unit = w._spawn_unit("marine", "terran", base.pos + Vector2(450, 420), World.ENEMY)
	var i := 0
	for race in RACES:
		var bid: String = AA_BUILDING[race]
		var b: Building = w._place_building(bid, race,
			base.pos + Vector2(260.0 + float(i) * 90.0, 300.0), World.PLAYER, true)
		i += 1
		_report("%s 能打到空中目标" % bid, b.can_hit(flyer),
			"can_hit(飞龙) = %s" % str(b.can_hit(flyer)))
		if bid == "photon_cannon":
			_report("%s 也能打到地面（按星际 1）" % bid, b.can_hit(ground),
				"can_hit(陆战队员) = %s" % str(b.can_hit(ground)))
		else:
			_report("%s 打不到地面（按星际 1 只对空）" % bid, not b.can_hit(ground),
				"can_hit(陆战队员) = %s" % str(b.can_hit(ground)))

## 空中单位对空 + 对地都能打（三族空军都是通用型）。
func _test_air_unit_hits_both_layers() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(500, 0), World.ENEMY)
	var ground: Unit = w._spawn_unit("marine", "terran", base.pos + Vector2(520, 0), World.ENEMY)
	for race in RACES:
		var uid: String = AIR_UNIT[race]
		var u: Unit = w._spawn_unit(uid, race, base.pos + Vector2(560, 0), World.PLAYER)
		_report("%s 能打到空中" % uid, u.can_hit(flyer), "")
		_report("%s 能打到地面" % uid, u.can_hit(ground), "")

## ★核心★ 地面单位（尤其是近战）绝不能锁定空中目标。
## 漏掉这道闸门的症状：整队跳虫追着一架飞龙绕地图跑、永远追不上。
func _test_ground_melee_cannot_hit_air() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(600, 0), World.ENEMY)
	# 近战 + 只对地的远程 + 三个农民
	var cannot := ["zergling", "zealot", "drone", "scv", "probe",
		"marauder", "vulture", "siege_tank", "roach"]
	for uid in cannot:
		var race := String(GameData.get_unit(uid).get("faction", "terran"))
		var u: Unit = w._spawn_unit(uid, race, base.pos + Vector2(620, 0), World.PLAYER)
		_report("%s 打不到空中的飞龙" % uid, not u.can_hit(flyer), "")
	# 星际 1 的四把「对空枪」必须打得到
	for uid in ["marine", "hydralisk", "dragoon", "archon"]:
		var race2 := String(GameData.get_unit(uid).get("faction", "terran"))
		var u2: Unit = w._spawn_unit(uid, race2, base.pos + Vector2(640, 0), World.PLAYER)
		_report("%s 能打到空中的飞龙" % uid, u2.can_hit(flyer), "")

## 空中单位不参与采集 / 建造这些地面逻辑。
func _test_air_units_skip_ground_logic() -> void:
	for race in RACES:
		var uid: String = AIR_UNIT[race]
		var d := GameData.get_unit(uid)
		var ok: bool = not bool(d.get("can_harvest", false)) \
			and String(d.get("role", "")) != "worker"
		_report("%s 不参与采集与建造" % uid, ok,
			"role=%s can_harvest=%s" % [String(d.get("role", "")), str(d.get("can_harvest", false))])

## ★核心★ 每个空中单位都要有建筑能生产它。
## 加了单位却忘了接生产链，玩家永远造不出来 —— 而且不会报任何错。
func _test_air_units_trainable() -> void:
	var trainable := {}
	for bid in GameData.BUILDINGS:
		for t in GameData.BUILDINGS[bid].get("trains", []):
			trainable[String(t)] = bid
	for race in RACES:
		var uid: String = AIR_UNIT[race]
		var src: String = String(trainable.get(uid, ""))
		_report("%s 有建筑能生产它" % uid, src != "",
			"生产建筑 = %s" % (src if src != "" else "无！"))

## 防空建筑必须在建造菜单里，否则玩家造不出来。
func _test_aa_in_build_menu() -> void:
	for race in RACES:
		var bid: String = AA_BUILDING[race]
		var found := false
		for e in GameData.BUILD_MENU.get(race, []):
			if String(e["id"]) == bid:
				found = true
		_report("%s 的 %s 在建造菜单里" % [race, bid], found, "")

## 防空建筑要有实际火力：有伤害、射程够远、弹道类型非空。
func _test_aa_weapon_sane() -> void:
	for race in RACES:
		var bid: String = AA_BUILDING[race]
		var d := GameData.get_building(bid)
		var dmg := float(d.get("damage", 0))
		var rng := float(d.get("range", 0))
		var wkind := String(d.get("weapon", "missile"))
		_report("%s 火力配置合理" % bid, dmg > 0.0 and rng >= 120.0 and wkind != "",
			"伤害 %.0f / 射程 %.0f / 弹道 %s" % [dmg, rng, wkind])

## 「会飞的农民」是死配置：采集、建造、寻路全都不认飞行层。
func _test_no_flying_worker() -> void:
	var bad := []
	for uid in GameData.UNITS:
		if GameData.is_flying(uid) and bool(GameData.UNITS[uid].get("can_harvest", false)):
			bad.append(uid)
	_report("不存在「会飞的农民」这种死配置", bad.is_empty(), str(bad))

## 声明了能对空却没有伤害，会让索敌逻辑找一个永远打不死的目标。
func _test_no_air_attacker_without_damage() -> void:
	var bad := []
	for uid in GameData.UNITS:
		if GameData.can_attack_air(uid) and float(GameData.UNITS[uid].get("damage", 0)) <= 0.0:
			bad.append(uid)
	_report("不存在「能对空但零伤害」的单位", bad.is_empty(), str(bad))

## AIR_RULES 把单位和建筑放在同一张表里，前提是两边的 id 不撞车。
func _test_id_namespaces_disjoint() -> void:
	var clash := []
	for uid in GameData.UNITS:
		if GameData.BUILDINGS.has(uid):
			clash.append(uid)
	_report("单位 id 与建筑 id 不冲突", clash.is_empty(), str(clash))

## 描述文案：非空、≤20 字、全项目不重复。
func _test_descriptions() -> void:
	var all := {}
	for uid in GameData.UNITS:
		all[uid] = GameData.UNITS[uid]
	for bid in GameData.BUILDINGS:
		all[bid] = GameData.BUILDINGS[bid]
	var seen := {}
	var dup := []
	var too_long := []
	var missing := []
	for k in all:
		var entry: Dictionary = all[k]
		var d := String(entry.get("desc", ""))
		if d == "":
			missing.append(k)
			continue
		if d.length() > 20:
			too_long.append("%s(%d 字)" % [k, d.length()])
		if seen.has(d):
			dup.append("%s / %s" % [seen[d], k])
		else:
			seen[d] = k
	_report("所有单位与建筑都有介绍文案", missing.is_empty(),
		"缺 %d 个：%s" % [missing.size(), str(missing)])
	_report("介绍文案不超过 20 字", too_long.is_empty(), str(too_long))
	_report("介绍文案互不重复", dup.is_empty(), str(dup))
	var no_desc := []
	for nid in NEW_IDS:
		var e2: Dictionary = all.get(nid, {})
		if String(e2.get("desc", "")) == "":
			no_desc.append(nid)
	_report("本轮新增的 %d 项内容都带了介绍" % NEW_IDS.size(), no_desc.is_empty(), str(no_desc))

# ================================================================ 第二组：索敌与伤害

## ★核心★ 索敌必须做能力过滤。
##
## 漏掉这道闸门，跳虫会锁定飞龙并一路追出去 —— 而且永远追不上。
## 症状看起来是「AI 变傻了」，实际是索敌少了一个条件。
func _test_search_filters_layer() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(300, 300), World.ENEMY)
	var zl: Unit = w._spawn_unit("zergling", "zerg", base.pos + Vector2(310, 300), World.PLAYER)
	var mrn: Unit = w._spawn_unit("marine", "terran", base.pos + Vector2(320, 300), World.PLAYER)
	# ⚠️ query_units_near 走哈希网格，而 _hash 只在 step() 开头重建。
	#    不先重建的话，下面「找不到」的那条断言会因为「网格本来就是空的」而
	#    **假通过** —— 这正是「测试比没有测试更危险」的典型。
	w._rebuild_hash()
	var t1 = w.find_nearest_enemy(zl.pos, World.PLAYER, 400.0, zl)
	var t2 = w.find_nearest_enemy(mrn.pos, World.PLAYER, 400.0, mrn)
	_report("跳虫索敌找不到空中的飞龙", t1 == null,
		"找到 = %s" % ("null" if t1 == null else String(t1.type_id)))
	_report("陆战队员索敌能找到空中的飞龙", t2 == flyer,
		"找到 = %s" % ("null" if t2 == null else String(t2.type_id)))

## 只对空的塔不能把地面部队当成目标。
func _test_aa_turret_ignores_ground() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var turret: Building = w._place_building("missile_turret", "terran",
		base.pos + Vector2(0, 260), World.PLAYER, true)
	var grunt: Unit = w._spawn_unit("marauder", "terran", base.pos + Vector2(0, 320), World.ENEMY)
	w._rebuild_hash()
	var t1 = w.find_nearest_enemy(turret.pos, World.PLAYER, 400.0, turret)
	_report("只对空的导弹塔不锁定地面部队", t1 == null,
		"找到 = %s" % ("null" if t1 == null else String(t1.type_id)))
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(0, 340), World.ENEMY)
	w._rebuild_hash()
	var t2 = w.find_nearest_enemy(turret.pos, World.PLAYER, 400.0, turret)
	_report("场上出现空军后导弹塔立刻锁定它", t2 == flyer,
		"找到 = %s" % ("null" if t2 == null else String(t2.type_id)))

## ★核心★ 防空建筑要真的能打掉血 —— 这是「建筑能开火」子系统的端到端验证。
func _test_aa_turret_deals_damage() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var turret: Building = w._place_building("missile_turret", "terran",
		base.pos + Vector2(0, 260), World.PLAYER, true)
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(0, 330), World.ENEMY)
	var hp0: float = flyer.hp
	for i in range(300):
		w.step(1.0 / 60.0)
	_report("导弹塔 5 秒内打掉了空中单位的血", flyer.hp < hp0,
		"%.0f → %.0f（塔剩余 %d 座）" % [hp0, flyer.hp, w.count_building(World.PLAYER, "missile_turret")])

## 只对空的塔打不到地面 —— 反过来也要成立。
func _test_aa_turret_cannot_hurt_ground() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var turret: Building = w._place_building("missile_turret", "terran",
		base.pos + Vector2(0, 260), World.PLAYER, true)
	var grunt: Unit = w._spawn_unit("marauder", "terran", base.pos + Vector2(0, 330), World.ENEMY)
	var hp0: float = grunt.hp
	for i in range(300):
		w.step(1.0 / 60.0)
	_report("只对空的导弹塔打不到地面部队", grunt.hp >= hp0,
		"%.0f → %.0f" % [hp0, grunt.hp])

## 没造完的塔不能开火 —— 否则「边造边打」会让防御塔变得无法拆除。
func _test_unfinished_turret_cannot_fire() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var turret: Building = w._place_building("missile_turret", "terran",
		base.pos + Vector2(0, 260), World.PLAYER, false)
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(0, 330), World.ENEMY)
	var hp0: float = flyer.hp
	for i in range(300):
		w.step(1.0 / 60.0)
	_report("未完工的导弹塔不能开火", flyer.hp >= hp0 and not turret.complete,
		"%.0f → %.0f，完工 = %s" % [hp0, flyer.hp, str(turret.complete)])

## ★核心★ 一整队近战也打不掉一架飞龙，而且不会追出去。
## 这一条同时覆盖了「索敌过滤」和「目标校验」两处改动。
func _test_melee_cannot_kill_air() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(0, 300), World.ENEMY)
	var hp0: float = flyer.hp
	for i in range(6):
		w._spawn_unit("zergling", "zerg",
			base.pos + Vector2(-25.0 + float(i) * 10.0, 320.0), World.PLAYER)
	for i in range(600):
		w.step(1.0 / 60.0)
	_report("6 只跳虫 10 秒内打不掉一架飞龙", flyer.hp >= hp0,
		"飞龙 %.0f → %.0f" % [hp0, flyer.hp])
	var strayed := 0
	for u in w.units_of(World.PLAYER):
		if u.type_id == "zergling" and u.pos.distance_to(base.pos) > 600.0:
			strayed += 1
	_report("跳虫没有追着飞龙绕地图跑", strayed == 0,
		"追出去 %d 只（场上还剩 %d 只）" % [strayed, w.count_units(World.PLAYER, "zergling")])

## 炮击溅射只影响和主目标同一层的单位 —— 炮弹不该顺带炸到天上的飞机。
func _test_splash_respects_layer() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	w._spawn_unit("siege_tank", "terran", base.pos + Vector2(0, 300), World.PLAYER)
	w._spawn_unit("marauder", "terran", base.pos + Vector2(0, 360), World.ENEMY)
	var flyer: Unit = w._spawn_unit("mutalisk", "zerg", base.pos + Vector2(20, 360), World.ENEMY)
	var f0: float = flyer.hp
	for i in range(600):
		w.step(1.0 / 60.0)
	_report("炮击溅射不会波及空中的飞龙", flyer.hp >= f0,
		"飞龙 %.0f → %.0f" % [f0, flyer.hp])

# ================================================================ 第三组：移动与分层

## ★核心★ 飞行单位直线飞，不寻路。
##
## 这是「空中」最核心的一条规则。如果飞行单位也走地面寻路，
## 它会被建筑和悬崖堵住，「空军」就退化成了「飞得快一点的陆军」。
func _test_flying_ignores_terrain() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	# 一道 3 座兵营连成的墙。兵营 size 28 → 2×2 格 = 48px，
	# 间隔正好 48px 才能接上；留缝的话地面单位会从缝里钻过去，对照组就失效了。
	for i in range(3):
		w._place_building("barracks", "terran",
			base.pos + Vector2(60.0 + float(i) * 48.0, 0.0), World.PLAYER, true)
	var start: Vector2 = base.pos + Vector2(108.0, -320.0)
	var goal: Vector2 = base.pos + Vector2(108.0, 320.0)
	var flyer: Unit = w._spawn_unit("wraith", "terran", start, World.PLAYER)
	var walker: Unit = w._spawn_unit("marine", "terran", start + Vector2(40.0, 0.0), World.PLAYER)
	flyer.move_to(goal)
	walker.move_to(goal + Vector2(40.0, 0.0))
	# 走一帧，比较两者的路径形态 —— 这是「有没有走寻路」最直接的证据
	w.step(1.0 / 60.0)
	var fly_pts: int = flyer.path.size()
	var walk_pts: int = walker.path.size()
	_report("飞行单位不寻路（路径是单点直线）", fly_pts <= 1, "路径点数 = %d" % fly_pts)
	_report("地面单位走寻路（路径多点）", walk_pts > 1, "路径点数 = %d" % walk_pts)
	for i in range(720):
		w.step(1.0 / 60.0)
	_report("飞行单位直线穿过建筑占位", absf(flyer.pos.x - start.x) < 24.0,
		"横向偏移 %.0fpx" % absf(flyer.pos.x - start.x))
	_report("飞行单位抵达目标", flyer.pos.distance_to(goal) < 70.0,
		"距目标 %.0fpx" % flyer.pos.distance_to(goal))
	_report("地面单位被迫绕行（对照组）", absf(walker.pos.x - start.x) > 40.0,
		"横向偏移 %.0fpx" % absf(walker.pos.x - start.x))

## 空中与地面互不推开。不分开的话，一架飞机飞到矿场上空会把采矿的农民挤开 ——
## 而农民根本够不到它，玩家只会看到矿工莫名其妙地乱走。
func _test_air_ground_do_not_push() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var spot: Vector2 = base.pos + Vector2(0, 170)
	var worker: Unit = w._spawn_unit("scv", "terran", spot, World.PLAYER)
	var flyer: Unit = w._spawn_unit("wraith", "terran", spot, World.PLAYER)
	var p0: Vector2 = worker.pos
	for i in range(90):
		w.step(1.0 / 60.0)
	_report("飞机悬停在农民头顶不会把农民挤开", worker.pos.distance_to(p0) < 5.0,
		"农民位移 %.1fpx" % worker.pos.distance_to(p0))

## 空中内部仍然要互推，否则一队飞机会叠成一个点。
func _test_air_air_push() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var spot: Vector2 = base.pos + Vector2(0, 210)
	var f1: Unit = w._spawn_unit("wraith", "terran", spot, World.PLAYER)
	var f2: Unit = w._spawn_unit("wraith", "terran", spot + Vector2(3.0, 0.0), World.PLAYER)
	for i in range(90):
		w.step(1.0 / 60.0)
	var gap: float = f1.pos.distance_to(f2.pos)
	_report("两架飞机重叠时互相推开", gap > f1.radius() * 1.4,
		"间距 %.1fpx（半径 %.1f）" % [gap, f1.radius()])

## 飞机不会成为建造者 —— 它既没有 can_harvest，也不是 worker。
##
## ⚠️ cmd_build 是「**先放工地、再派工**」：没有农民时它照样返回 true
## （工地先立着，等有农民了自动补人）。所以这里不能断言返回值，
## 要断言的是「有没有单位被指派到工地上」。
func _test_flying_not_picked_as_builder() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	var flyer: Unit = w._spawn_unit("wraith", "terran", base.pos + Vector2(0, 150), World.PLAYER)
	var site: Vector2 = base.pos + Vector2(0, 165)
	var chk: Dictionary = w.can_place_building("supply_depot", site, World.PLAYER)
	_report("（前置）工地位置合法", bool(chk.get("ok", false)),
		String(chk.get("msg", "")))
	w.cmd_build("supply_depot", site, World.PLAYER, [])
	var assigned := 0
	for u in w.units:
		if u.build_target != null:
			assigned += 1
	_report("放工地不会把飞机拉去建造（被指派者 = 0）",
		assigned == 0 and flyer.build_target == null,
		"被指派 %d 个，飞机的 build_target = %s" % [assigned, str(flyer.build_target)])

## 防空建筑的查表接口 —— AI 与测试都走它，避免各处硬编码。
func _test_aa_building_lookup() -> void:
	for race in RACES:
		var bid: String = GameData.aa_building(race)
		_report("%s 能查到防空建筑（%s）" % [race, bid],
			bid != "" and GameData.BUILDINGS.has(bid), "")

## ★核心★ 敌方空军成规模时，AI 的出兵候选里「能对空的」必须全部排在前面。
## 否则 AI 会继续爆跳虫，眼睁睁看着它们被飞龙一口口吃掉。
func _test_ai_prefers_aa_units() -> void:
	var a := _arena()
	var w: World = a[0]
	var base = a[1]
	for i in range(3):
		w._spawn_unit("mutalisk", "zerg",
			base.pos + Vector2(240.0 + float(i) * 30.0, 60.0), World.PLAYER)
	var built := {"barracks": 1, "factory": 1}
	var cands: Array = w._ai_unit_candidates(GameData.available_units("terran", built))
	var first_cannot := -1
	var last_can := -1
	for i in range(cands.size()):
		if GameData.can_attack_air(String(cands[i])):
			last_can = i
		elif first_cannot < 0:
			first_cannot = i
	_report("敌方空军成规模时，能对空的兵全部排在不能对空的之前",
		first_cannot < 0 or last_can < first_cannot,
		"候选 = %s" % str(cands))
	# 清掉敌方空军后，判据必须归零 —— 否则分层会变成无条件生效
	for u in w.units_of(World.PLAYER):
		if u.is_flying():
			u.dead = true
	_report("清掉敌方空军后对空判据归零", w._enemy_air_count() == 0,
		"计数 = %d" % w._enemy_air_count())

# ================================================================ 第四组：美术与数据一致

## 打包的第三方皮肤包（Kenney CC0 那套）必须处于**关闭**状态。
## 见 GenTex.USE_BUNDLED_SKINS 的注释：它一旦被打开，老单位/建筑会换成
## 「小蓝盒子」图标，和自绘的新建筑（导弹塔 / 光子炮台 / 星际之门）风格直接打架，
## 一局里同时出现两种画风。这条断言让「有人手滑改回 true」在测试里立刻暴露，
## 而不是等到跑截图才从画面里看出来。
func _test_bundled_skins_disabled() -> void:
	var still_there := ResourceLoader.exists("res://assets/art/skins/b_barracks.png")
	_report("打包的第三方皮肤包处于关闭状态（全程序化自绘）",
		not GenTex.USE_BUNDLED_SKINS,
		"开关 = false；素材仍在 res://（%s），需要时可随时切回"
			% ("在" if still_there else "已移除"))

## 每个单位 / 建筑都必须有专属造型，不能落进「没写造型」的兜底分支。
##
## 兜底分支画的是一个光秃秃的圆盘，和真实单位一点都不像，而且**不报错**。
## 幽灵战机 / 侦察机第一次加进来时就是这样：造出来是一颗蓝球，
## 直到跑截图才发现。GenTex 现在会把「落进兜底」记在 last_was_fallback 上。
func _test_every_id_has_dedicated_sprite() -> void:
	var bad := []
	for id in GameData.UNITS.keys():
		var uid := String(id)
		var d: Dictionary = GameData.UNITS[uid]
		var fc: Dictionary = GameData.FACTIONS[String(d["faction"])]
		GenTex.unit_sprite(uid, fc["color"], fc["color_dim"], fc["accent"])
		if GenTex.last_was_fallback:
			bad.append(uid)
	for id in GameData.BUILDINGS.keys():
		var bid := String(id)
		var d2: Dictionary = GameData.BUILDINGS[bid]
		var fc2: Dictionary = GameData.FACTIONS[String(d2["faction"])]
		GenTex.building_sprite(bid, fc2["color"], fc2["color_dim"], fc2["accent"])
		if GenTex.last_was_fallback:
			bad.append(bid)
	var note := "全部有专属造型"
	if not bad.is_empty():
		note = "落进兜底圆盘：" + ", ".join(PackedStringArray(bad))
	_report("每个单位/建筑都有专属造型（共 %d 个）"
			% (GameData.UNITS.size() + GameData.BUILDINGS.size()),
		bad.is_empty(), note)

## 建筑底盘的阵营必须和 GameData 里的 faction 一致。
##
## 回归的是一个真 bug：building_sprite 原本用**硬编码 id 列表**判断底盘阵营，
## 于是每加一个新建筑都会悄悄落进 else 分支被画成神族底盘 —— 而且不报错。
## （人族的导弹塔顶着神族底盘；第七轮的工程湾 / 进化腔 / 熔炉也一样。）
##
## 判据：在**三个阵营的底盘都覆盖得到**的一圈上取 8 个采样点（半径 34），
## 拿三个阵营各自「只画底盘」的参考图去比，投票选出最像的那个，必须是自己。
## 半径为什么是 34：底盘最大半径 40，但神族底盘是八边形（内切半径只有 37）、
## 人族是圆角方（角上半径 40 的地方其实是空的），34 是三者都实心的安全圈。
## 取 8 个点投票而不是只看一个点 —— 建筑本体有可能盖住其中某一个。
##
## ⚠️ 参考图必须走**和真实贴图完全相同的后处理**（_fit / _global_light / _outline）。
##    第一版忘了这一步，直接拿「裸底盘」去比，结果 _global_light 把深色像素提亮
##    的幅度和颜色有关，距离排序就被带偏了 —— 孢子菌落被误判成 terran 底盘。
func _test_building_base_plate_matches_faction() -> void:
	var c := float(GenTex.B_SIZE) * 0.5
	var probes: Array[Vector2i] = []
	for k in range(8):
		var a := TAU * float(k) / 8.0
		probes.append(Vector2i(int(c + cos(a) * 34.0), int(c + sin(a) * 34.0)))
	var refs := {}
	for r in RACES:
		var fc: Dictionary = GameData.FACTIONS[r]
		var img := Image.create(GenTex.B_SIZE, GenTex.B_SIZE, false, Image.FORMAT_RGBA8)
		match r:
			"terran": GenTex._bg_terran(img, c, fc["color"], fc["color_dim"], fc["accent"])
			"zerg":   GenTex._bg_zerg(img, c, fc["color"], fc["color_dim"], fc["accent"])
			_:        GenTex._bg_protoss(img, c, fc["color"], fc["color_dim"], fc["accent"])
		# 与 building_sprite 结尾处一模一样的收尾三步
		img = GenTex._fit(img, 0.94)
		GenTex._global_light(img, 0.26)
		GenTex._outline(img, Color(0.02, 0.035, 0.06, 0.95))
		refs[r] = img
	var bad := []
	for id in GameData.BUILDINGS.keys():
		var bid := String(id)
		var race := String(GameData.get_building(bid).get("faction", "protoss"))
		var fc2: Dictionary = GameData.FACTIONS[race]
		var got := GenTex.building_sprite(bid, fc2["color"], fc2["color_dim"], fc2["accent"]).get_image()
		var votes := {"terran": 0, "zerg": 0, "protoss": 0}
		for p in probes:
			var best := ""
			var best_d := 1e9
			for r2 in RACES:
				var d := _rgb_dist(got.get_pixelv(p), refs[r2].get_pixelv(p))
				if d < best_d:
					best_d = d
					best = r2
			votes[best] += 1
		# 票数最高且必须是自己那一个
		var win := race
		for r3 in RACES:
			if votes[r3] > votes[win]:
				win = r3
		if win != race:
			bad.append("%s 底盘像 %s（应为 %s，得票 %s）" % [bid, win, race, str(votes)])
	var note2 := "全部正确"
	if not bad.is_empty():
		note2 = "；".join(PackedStringArray(bad))
	_report("建筑底盘阵营与 GameData 一致（%d 个建筑）" % GameData.BUILDINGS.size(),
		bad.is_empty(), note2)

func _rgb_dist(a: Color, b: Color) -> float:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
