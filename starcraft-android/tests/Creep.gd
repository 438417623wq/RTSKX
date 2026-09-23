extends SceneTree

## 虫族菌毯测试。
##
## 锁死四条铁律：
##   1. 菌毯来自**已完工**的虫族建筑 —— 工地不产生菌毯，
##      否则虫族能靠一堆工地把菌毯铺满地图。
##   2. 虫族建筑（除虫巢、萃取房）必须建在菌毯上。
##   3. 只有**虫族地面单位**在菌毯上加速：人神站在菌毯上不受影响，空军也不吃。
##   4. 虫族 AI 在菌毯硬约束下仍然造得出东西。
##
## ⚠️ 第 4 条是整套里最重要的一条，也是最容易被忽略的回归点。
##    菌毯约束的风险不在玩家侧（玩家看到红框会换个地方），而在 **AI 静默卡死**：
##    AI 的建造位置搜索半径是 60~140（兜底 183），一旦超过菌毯半径，
##    它会每隔半秒试一次、每次都失败 —— 表现为「AI 突然不造东西了」，
##    而且不会有任何报错。所以必须真的跑一局虫族 AI 出来看。
##
## ⚠️ 每条「做不到 X」的断言都配了阳性对照。
##    「菌毯外建不了」这条尤其危险：把菌毯半径调成 0 也能让它通过，
##    所以必须同时证明「菌毯内建得了」。

var _pass := 0
var _fail := 0

func _init() -> void:
	seed(20260925)
	print("\n=============== 虫族菌毯测试 ===============")
	_test_hive_has_creep()
	_test_hive_radius()
	_test_normal_building_radius()
	_test_unfinished_building_no_creep()
	_test_creep_shrinks_when_destroyed()
	print("  ---- 第二组：建造硬约束 ----")
	_test_zerg_must_build_on_creep()
	_test_hive_exempt()
	_test_extractor_exempt()
	_test_non_zerg_unaffected()
	print("  ---- 第三组：移速加成 ----")
	_test_zerg_speed_on_creep()
	_test_zerg_speed_off_creep()
	_test_non_zerg_no_creep_speed()
	_test_air_no_creep_speed()
	print("  ---- 第四组：AI 不会卡死 ----")
	_test_ai_still_builds()
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

# ================================================================ 工具

func _report(label: String, ok: bool, note: String = "") -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s  %s" % [label, note])
	else:
		_fail += 1
		print("  [FAIL] %s  %s" % [label, note])

## 一个干净的菌毯测试场：清空单位、建筑与资源点，关掉 AI 与胜负结算。
##
## ⚠️ 玩家阵营必须是 **zerg**。菌毯约束的判据是 owner 的 race
##    （`String(f["race"]) == "zerg"`），测试场若默认成人族，
##    整条菌毯检查会被**静默跳过** —— 断言照样 PASS，但什么都没测到。
##    第一版就踩了这个坑：「菌毯外被拒」报的是「必须建在己方建筑附近」。
##
## 刻意**不用地图生成器自带的基地**：它的位置会随地图改动漂移，周围还可能
## 压着岩石，会让「半径 200 处有菌毯」这类断言跟着随机抖动。
## 这里一切从零摆，测试和地图生成彻底解耦。
##
## 同时把整张地图铲平 —— 菌毯测试不关心地形，但地图生成器撒的岩石
## 会让「菌毯外被拒」变成「此处有障碍」，断言通过与否取决于岩石撒在哪，
## 那就等于没测。
func _arena() -> World:
	var w := World.new(64, 40, "zerg", "zerg", "easy")
	w.units.clear()
	w.buildings.clear()
	w.resources.clear()
	w.game_ended = true
	for y in range(w.grid.h):
		for x in range(w.grid.w):
			w.grid.set_terrain(x, y, Grid.Terrain.GROUND)
			w.grid.set_elev(x, y, 0)
	# ⚠️ 必须重铺一次。`World._init()` 现在会在开局就铺一遍菌毯（否则新建世界
	#    在第一次 step() 之前菌毯全 0，虫族建筑一律被拒），所以清空建筑之后
	#    网格里还留着**地图生成器那座虫巢**的陈旧菌毯 —— 不重铺的话
	#    「菌毯外建不了」这类断言会踩在残留菌毯上，通过与否取决于地图随机。
	w._rebuild_creep()
	w._refresh_terrain_flags()
	return w

## 测试场的固定基准点：地图正中，四周足够空旷。
func _mid(w: World) -> Vector2:
	return w.world_size * 0.5

## 往测试场里放一座建筑并重铺菌毯。
## instant=false 走「工地」路径，用来验证工地不产生菌毯。
func _put(w: World, id: String, pos: Vector2, owner: int,
		race: String = "zerg", instant: bool = true):
	var b = w._place_building(id, race, pos, owner, instant)
	w._rebuild_creep()
	return b

## 统计某阵营「需要菌毯才建得出来」的建筑数：虫族建筑，排除虫巢与气矿建筑
## （这两个是豁免项，不靠菌毯也建得出来，拿来当断言会被它们蒙混过关）。
func _creep_dependent(w: World, owner: int) -> int:
	var n := 0
	for b in w.buildings_of(owner):
		if not b.alive():
			continue
		var d: Dictionary = b.data
		if String(d.get("faction", "")) != "zerg":
			continue
		if b.type_id == "hive" or bool(d.get("gas_building", false)):
			continue
		n += 1
	return n

# ================================================================ 第一组：菌毯覆盖

func _test_hive_has_creep() -> void:
	var w := _arena()
	var m := _mid(w)
	_put(w, "hive", m, World.PLAYER)
	_report("虫巢周围长出菌毯", w.has_creep_at(m) and w.has_creep_at(m + Vector2(60, 0)),
		"中心与 +60px 处都覆盖")

func _test_hive_radius() -> void:
	var w := _arena()
	var m := _mid(w)
	_put(w, "hive", m, World.PLAYER)
	# ⚠️ 偏移量必须留出**一整格**的余量：has_creep_at 先把坐标换算成格子，
	#    格子中心可能比传入点偏 ±12px。贴着 200 取点会让断言随建筑落点的
	#    小数部分抖动（有时过有时不过）。往内收 40、往外放 40，把边界推进安全区。
	var inside := w.has_creep_at(m + Vector2(0, World.CREEP_RADIUS_HIVE - 40.0))
	var outside := w.has_creep_at(m + Vector2(0, World.CREEP_RADIUS_HIVE + 40.0))
	_report("虫巢菌毯半径约 200", inside and not outside,
		"距 %.0f 有 / 距 %.0f 无" % [World.CREEP_RADIUS_HIVE - 40.0, World.CREEP_RADIUS_HIVE + 40.0])

func _test_normal_building_radius() -> void:
	var w := _arena()
	var m := _mid(w)
	_put(w, "spawning_pool", m, World.PLAYER)
	var inside := w.has_creep_at(m + Vector2(0, World.CREEP_RADIUS - 40.0))
	var outside := w.has_creep_at(m + Vector2(0, World.CREEP_RADIUS + 40.0))
	_report("普通虫族建筑的菌毯半径约 110", inside and not outside,
		"距 %.0f 有 / 距 %.0f 无" % [World.CREEP_RADIUS - 40.0, World.CREEP_RADIUS + 40.0])

func _test_unfinished_building_no_creep() -> void:
	var w := _arena()
	var m := _mid(w)
	var site = _put(w, "spawning_pool", m, World.PLAYER, "zerg", false)
	_report("工地不产生菌毯", not w.has_creep_at(m),
		"工地 complete = %s" % site.complete)
	# 阳性对照：同一座建筑一旦完工就必须长菌毯。
	# 少了这条，「工地没菌毯」可能只是「菌毯系统整个坏了」的副作用。
	site.complete = true
	w._rebuild_creep()
	_report("同一座建筑完工后立刻长菌毯（阳性对照）", w.has_creep_at(m), "")

func _test_creep_shrinks_when_destroyed() -> void:
	var w := _arena()
	var m := _mid(w)
	var b = _put(w, "spawning_pool", m, World.PLAYER)
	var before := w.has_creep_at(m)
	b.dead = true
	w._rebuild_creep()
	var after := w.has_creep_at(m)
	_report("建筑被拆后菌毯收缩", before and not after,
		"拆前 %s / 拆后 %s" % [before, after])

# ================================================================ 第二组：建造硬约束

func _test_zerg_must_build_on_creep() -> void:
	var w := _arena()
	w.factions[World.PLAYER]["minerals"] = 9999.0
	w.factions[World.PLAYER]["gas"] = 9999.0
	var m := _mid(w)
	_put(w, "hive", m, World.PLAYER)
	# 菌毯内：虫巢正下方 60px
	var ok_in := w.can_place_building("spawning_pool", m + Vector2(0, 60), World.PLAYER)
	# 菌毯外：离虫巢 420px（远超 200 半径），但仍在地图内
	var ok_out := w.can_place_building("spawning_pool", m + Vector2(0, 420), World.PLAYER)
	_report("虫族建筑建在菌毯上（阳性对照）", bool(ok_in["ok"]),
		"理由 = %s" % ok_in.get("reason", "（通过，无 reason 字段）"))
	_report("虫族建筑建在菌毯外被拒",
		not bool(ok_out["ok"]) and String(ok_out["reason"]) == "必须建在菌毯上",
		"理由 = %s" % ok_out.get("reason", "（竟然通过了）"))

func _test_hive_exempt() -> void:
	var w := _arena()
	w.factions[World.PLAYER]["minerals"] = 9999.0
	var m := _mid(w)
	_report("（前置）场上一点菌毯都没有", w.creep_sources().is_empty(),
		"菌毯源 %d 个" % w.creep_sources().size())
	var chk := w.can_place_building("hive", m, World.PLAYER)
	# 只断言「不是因为菌毯被拒」。
	# 测试场刻意清空了所有建筑，所以空场里建虫巢还会撞上「必须建在己方建筑附近」——
	# 那是另一条规则的事，把它也摆平会让这条测试耦合到建造半径上。
	# 配合上面「场上一点菌毯都没有」的前置，这个弱断言是充分的：
	# 虫巢若受菌毯约束，reason 必然就是「必须建在菌毯上」。
	_report("虫巢不受菌毯约束（否则要求先有鸡）",
		String(chk.get("reason", "")) != "必须建在菌毯上",
		"理由 = %s" % chk.get("reason", "（通过，无 reason 字段）"))

func _test_extractor_exempt() -> void:
	var w := _arena()
	w.factions[World.PLAYER]["minerals"] = 9999.0
	w.factions[World.PLAYER]["gas"] = 9999.0
	var m := _mid(w)
	# 只断言「不是因为菌毯被拒」。萃取房还要满足「必须压在气矿上」等条件，
	# 把整条链路都摆对反而会把测试耦合到气矿的数据结构上。
	var chk := w.can_place_building("extractor", m, World.PLAYER)
	_report("萃取房不受菌毯约束（否则 AI 永远开不出气）",
		String(chk.get("reason", "")) != "必须建在菌毯上",
		"理由 = %s" % chk.get("reason", "（通过，无 reason 字段）"))

func _test_non_zerg_unaffected() -> void:
	var w := _arena()
	w.factions[World.PLAYER]["minerals"] = 9999.0
	w.factions[World.PLAYER]["gas"] = 9999.0
	var m := _mid(w)
	# 判据是 owner 的 race，直接改它就能把同一个 owner 判成人族 / 神族。
	w.factions[World.PLAYER]["race"] = "terran"
	var chk_t := w.can_place_building("barracks", m, World.PLAYER)
	_report("人族建筑不受菌毯约束", String(chk_t.get("reason", "")) != "必须建在菌毯上",
		"理由 = %s" % chk_t.get("reason", "（通过，无 reason 字段）"))
	w.factions[World.PLAYER]["race"] = "protoss"
	var chk_p := w.can_place_building("gateway", m, World.PLAYER)
	_report("神族建筑不受菌毯约束", String(chk_p.get("reason", "")) != "必须建在菌毯上",
		"理由 = %s" % chk_p.get("reason", "（通过，无 reason 字段）"))

# ================================================================ 第三组：移速加成

func _test_zerg_speed_on_creep() -> void:
	var w := _arena()
	var m := _mid(w)
	_put(w, "hive", m, World.PLAYER)
	var u = w._spawn_unit("zergling", "zerg", m, World.PLAYER)
	w._refresh_terrain_flags()
	var base := float(GameData.get_unit("zergling")["speed"])
	_report("虫族单位站在菌毯上加速 30%",
		w.has_creep_at(m) and u.creep_boost \
			and absf(u.speed() - base * GameData.CREEP_SPEED_MULT) < 0.01,
		"速度 %.1f → %.1f（基准 %.1f）" % [base, u.speed(), base])

func _test_zerg_speed_off_creep() -> void:
	var w := _arena()
	var m := _mid(w)
	_put(w, "hive", m, World.PLAYER)
	var u = w._spawn_unit("zergling", "zerg", m, World.PLAYER)
	w._refresh_terrain_flags()
	var boosted := u.speed()
	# 挪到菌毯外（+320 远超虫巢的 200 半径）
	u.pos = m + Vector2(0, World.CREEP_RADIUS_HIVE + 120.0)
	w._refresh_terrain_flags()
	var base := float(GameData.get_unit("zergling")["speed"])
	_report("虫族单位离开菌毯后恢复原速",
		not u.creep_boost and absf(u.speed() - base) < 0.01,
		"菌毯上 %.1f → 菌毯外 %.1f（基准 %.1f）" % [boosted, u.speed(), base])

func _test_non_zerg_no_creep_speed() -> void:
	var w := _arena()
	var m := _mid(w)
	_put(w, "hive", m, World.PLAYER)
	var u = w._spawn_unit("marine", "terran", m, World.PLAYER)
	w._refresh_terrain_flags()
	var base := float(GameData.get_unit("marine")["speed"])
	# 阳性对照必须同时断言「该位置真的有菌毯」，否则这条会因为
	# 「单位压根没站在菌毯上」而假通过。
	_report("人族单位站在菌毯上不加速（阳性对照）",
		w.has_creep_at(m) and not u.creep_boost and absf(u.speed() - base) < 0.01,
		"该处有菌毯 = %s，速度 %.1f（基准 %.1f）" % [w.has_creep_at(m), u.speed(), base])

func _test_air_no_creep_speed() -> void:
	var w := _arena()
	var m := _mid(w)
	_put(w, "hive", m, World.PLAYER)
	var u = w._spawn_unit("mutalisk", "zerg", m, World.PLAYER)
	w._refresh_terrain_flags()
	var base := float(GameData.get_unit("mutalisk")["speed"])
	_report("虫族空军在菌毯上不加速（飞机不吃地形红利）",
		w.has_creep_at(m) and u.is_flying() and not u.creep_boost \
			and absf(u.speed() - base) < 0.01,
		"该处有菌毯 = %s，is_flying = %s，速度 %.1f（基准 %.1f）"
			% [w.has_creep_at(m), u.is_flying(), u.speed(), base])

# ================================================================ 第四组：AI 不卡死

func _test_ai_still_builds() -> void:
	# 给 AI 一笔启动资金 —— 这一条测的是「菌毯约束会不会卡住 AI 的建造」，
	# 不是「AI 的经济发展得快不快」。让它缺钱缺到造不出东西，
	# 测出来的就是经济问题而不是菌毯问题。
	var w := World.new(64, 40, "terran", "zerg", "easy")
	w.factions[World.ENEMY]["minerals"] = 2000.0
	w.factions[World.ENEMY]["gas"] = 800.0
	var before := w.buildings_of(World.ENEMY).size()
	var before_dep := _creep_dependent(w, World.ENEMY)
	for i in range(7200):        # 240 秒 @ 30fps
		w.step(1.0 / 30.0)
		if w.game_ended:
			break
	var after := w.buildings_of(World.ENEMY).size()
	var after_dep := _creep_dependent(w, World.ENEMY)
	# 关键断言：AI 真的在菌毯上建成了东西。
	# ⚠️ 这条做过「回退验证」：把 has_creep_at 临时改成恒返回 false 时，
	#    它报的是「需要菌毯的建筑 1 → 1 座」直接 FAIL —— 所以它确实咬得住，
	#    不是假通过。
	_report("虫族 AI 真的造出了需要菌毯的新建筑", after_dep > before_dep,
		"需要菌毯的建筑 %d → %d 座" % [before_dep, after_dep])
	# 辅助断言：AI 整体没停摆。
	# ⚠️ 注意这条**在菌毯彻底卡死时也会通过**（虫巢豁免菌毯，AI 还能造它），
	#    所以它只能证明「AI 还在干活」，不能证明菌毯约束没卡住 AI。
	#    两条一起看：上面那条挂了就是菌毯的问题，只有这条挂了才是经济的问题。
	_report("虫族 AI 整体没有停摆", after > before,
		"建筑总数 %d → %d 座（game_ended = %s）" % [before, after, w.game_ended])
