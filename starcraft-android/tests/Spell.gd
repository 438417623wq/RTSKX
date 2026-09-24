extends SceneTree

## 战场法术与状态效果测试（M5）。
##
## 锁死五条铁律：
##   1. **dot 按固定间隔结算**，不随帧率漂移 —— 每帧扣 `dps * delta` 的话，
##      跳数会随帧率变，而 `take_damage` 里有 `maxf(1.0, ...)` 的地板，
##      跳数越多总伤害越高（144 帧下 28 dps 会变成 144 点/秒）。
##   2. **心灵风暴敌我不分** —— 这是它唯一的制衡，也是星际 1 的原样行为。
##      写成「只打敌人」的话，这个技能从「高风险高回报」变成「无脑扔」。
##   3. **黑暗虫群只挡远程，近战照打**，且只保护**地面**单位。
##      漏掉任一条，虫群都会从「战术遮蔽」变成「无敌圈」。
##   4. **同源效果不叠加**，只刷新时长；不同源可以并存。
##   5. **状态效果与法术区域都要能跨快照往返**（联机）——
##      不传的话客户端看到的是「主机的兵在掉血、画面上什么都没有」。
##
## ⚠️ 每条「做不到 X」的断言都配了阳性对照。
##    尤其是「黑暗虫群挡住了远程」：把 `blocked_by_dark_swarm` 直接 return true
##    也能让它通过，所以必须同时证明「近战真的打得到」。

var _pass := 0
var _fail := 0

func _init() -> void:
	seed(20260926)
	print("\n=============== 战场法术测试 ===============")
	print("  ---- 第一组：数据表自洽 ----")
	_test_tables()
	_test_five_tables()
	_test_net_tables()
	print("  ---- 第二组：状态效果（Unit 侧）----")
	_test_effect_no_stack()
	_test_effect_multi_source()
	_test_slow_mult()
	_test_clear_on_death()
	print("  ---- 第三组：心灵风暴 ----")
	_test_storm_spawns_and_costs()
	_test_storm_hits_all()
	_test_storm_out_of_range()
	_test_storm_expires()
	_test_storm_framerate()
	print("  ---- 第四组：黑暗虫群 ----")
	_test_swarm_marks_ground()
	_test_swarm_blocks_ranged()
	_test_swarm_melee_still_hits()
	_test_swarm_blocks_air_too()
	_test_swarm_linger()
	print("  ---- 第五组：辐照 ----")
	_test_irradiate_dot()
	_test_irradiate_spreads()
	_test_irradiate_expires()
	print("  ---- 第六组：快照往返 ----")
	_test_snapshot_energy()
	_test_snapshot_effects()
	_test_snapshot_zones()
	print("  ---- 第七组：AI 不自杀 ----")
	_test_ai_no_friendly_fire()
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

## 一个干净的法术测试场：清空单位 / 建筑 / 资源，铲平地形，关掉 AI 与胜负结算。
##
## ⚠️ 关 AI 是必须的：`_ai_use_abilities` 现在会放法术，
##    不关的话它会在测试中途往场上丢风暴，把「圈内掉血多少」搅乱。
## ⚠️ `game_ended = true` 只是为了让 `_check_game_over` 短路 ——
##    它**不会**拦住 `step()` 或 `cmd_ability`，所以对局照样能推。
func _arena(p_race: String = "terran", e_race: String = "zerg") -> World:
	var w := World.new(64, 40, p_race, e_race, "easy")
	w.units.clear()
	w.buildings.clear()
	w.resources.clear()
	w.ai_enabled = false
	w.game_ended = true
	for y in range(w.grid.h):
		for x in range(w.grid.w):
			w.grid.set_terrain(x, y, Grid.Terrain.GROUND)
			w.grid.set_elev(x, y, 0)
	w._rebuild_creep()
	w._refresh_terrain_flags()
	w._rebuild_hash()
	return w

func _mid(w: World) -> Vector2:
	return w.world_size * 0.5

## 场上放一个单位并返回它。测试里统一走这个，避免各处写 `_spawn_unit` 的
## 参数顺序（type, race, pos, owner）写反 —— 写反了不报错，只是单位不出来。
func _put(w: World, type_id: String, pos: Vector2, owner: int = World.PLAYER) -> Unit:
	var race := String(GameData.get_unit(type_id).get("faction", "terran"))
	return w._spawn_unit(type_id, race, pos, owner)

## 让世界跑 `seconds` 秒，固定步长。
func _run(w: World, seconds: float, step: float = 0.05) -> void:
	var n := int(round(seconds / step))
	for i in range(n):
		w.step(step)

## 把「效果列表」压成一个可比较的字符串，方便断言。
func _fx(u: Unit) -> String:
	var out: Array = []
	for e in u.effects:
		var d: Dictionary = e
		out.append("%s/%s" % [String(d.get("id", "")), String(d.get("kind", ""))])
	out.sort()
	return ",".join(out)

## 法术每次 dot 结算实际打掉多少血（含护甲减伤）。
##
## ⚠️ 不能直接拿 `dps * DOT_TICK` 当期望值 —— 那忽略了护甲。
##    执政官护甲 3，每跳 14 点实际只掉 11，硬写 14 会让断言以「差额 24」失败，
##    而代码其实完全正确。期望值一律用 `GameData.compute_damage` 现算，
##    这样「伤害公式改了」和「跳数算错了」两种情况能分开看。
func _per_tick(sp: Dictionary, unit: Unit) -> float:
	var base := float(sp.get("dps", 0.0)) * GameData.DOT_TICK
	return GameData.compute_damage(base, String(sp.get("damage_type", "normal")),
		String(unit.data.get("armor_type", "light")), int(unit.data.get("armor", 0)))

# ================================================================ 第一组：数据表自洽

func _test_tables() -> void:
	var bad: Array = []
	for sid in GameData.SPELLS:
		var sp: Dictionary = GameData.SPELLS[sid]
		var uid := String(sp.get("unit", ""))
		var ud := GameData.get_unit(uid)
		if ud.is_empty():
			bad.append("%s → 单位 %s 不存在" % [sid, uid])
			continue
		if not (ud.get("abilities", []) as Array).has(sid):
			bad.append("%s 未挂到 %s 的 abilities 上" % [sid, uid])
		for k in ["name", "kind", "energy", "cast_range", "duration", "cooldown"]:
			if not sp.has(k):
				bad.append("%s 缺字段 %s" % [sid, k])
		# 施法单位必须是零伤害的支援单位 —— 否则它会去索敌开火，
		# 而「施法单位冲上去肉搏」不是任何一族的玩法。
		if float(ud.get("damage", 0)) > 0.0:
			bad.append("%s 的施法单位 %s 有攻击力（会去索敌）" % [sid, uid])
		if String(ud.get("role", "")) != "support":
			bad.append("%s 的施法单位 %s role 不是 support" % [sid, uid])
	_report("法术表自洽（%d 个法术都能挂到零伤害的支援单位上）" % GameData.SPELLS.size(),
		bad.is_empty(), "; ".join(bad))

	# `get_skill` 必须两张表都能查 —— 分头查表的写法会让法术按钮点得动但放不出来。
	var ok_ab: bool = not GameData.get_skill("stim").is_empty()
	var ok_sp: bool = not GameData.get_skill("psionic_storm").is_empty()
	var not_spell: bool = not GameData.is_spell("stim") and GameData.is_spell("psionic_storm")
	_report("get_skill 同时覆盖 ABILITIES 与 SPELLS", ok_ab and ok_sp and not_spell,
		"stim=%s storm=%s" % [str(ok_ab), str(ok_sp)])

func _test_five_tables() -> void:
	# 新增单位要同时进五张表：UNITS / BUILDINGS[x].trains / AIR_RULES /
	# UPGRADE_CLASS /（BUILD_MENU 不涉及，它们不是建筑）。
	# 缺任何一张都是静默半成品：造不出来、或者吃不到攻防升级，都不报错。
	var bad: Array = []
	for sid in GameData.SPELLS:
		var uid := String(GameData.SPELLS[sid].get("unit", ""))
		if not GameData.UPGRADE_CLASS.has(uid):
			bad.append("%s 缺 UPGRADE_CLASS" % uid)
		var trainer := ""
		for bid in GameData.BUILDINGS:
			var bd: Dictionary = GameData.BUILDINGS[bid]
			if (bd.get("trains", []) as Array).has(uid):
				trainer = String(bid)
				break
		if trainer == "":
			bad.append("%s 没有任何建筑能造它" % uid)
		elif String(GameData.get_building(trainer).get("faction", "")) \
				!= String(GameData.get_unit(uid).get("faction", "")):
			bad.append("%s 被异族建筑 %s 训练" % [uid, trainer])
	_report("三个施法单位都进了五张表（可造 + 有升级分类）", bad.is_empty(), "; ".join(bad))

	# 科学球在天上 —— 漏掉 AIR_RULES 的话它会被地面近战追着打。
	_report("科学球是空中单位", GameData.is_flying("science_vessel"),
		"AIR_RULES.science_vessel.flying")
	_report("蝎子 / 圣堂武士是地面单位",
		not GameData.is_flying("defiler") and not GameData.is_flying("high_templar"), "")

func _test_net_tables() -> void:
	# 法术与效果索引表必须覆盖全部 SPELLS，且往返一致。
	var bad: Array = []
	for sid in GameData.SPELLS:
		var i := Net.spell_index(sid)
		if i < 0:
			bad.append("%s 不在 spell_ids 里" % sid)
		elif Net.spell_id_of(i) != sid:
			bad.append("%s 往返不一致" % sid)
		var j := Net.effect_index(sid)
		if j < 0:
			bad.append("%s 不在 effect_ids 里" % sid)
		elif Net.effect_id_of(j) != sid:
			bad.append("%s 效果往返不一致" % sid)
	_report("Net 的法术 / 效果索引表覆盖全部 SPELLS 且往返一致", bad.is_empty(), "; ".join(bad))
	_report("EFFECT_KINDS 覆盖 Unit 会用到的三类", Net.EFFECT_KINDS.size() == 3,
		", ".join(Net.EFFECT_KINDS))

# ================================================================ 第二组：状态效果

func _test_effect_no_stack() -> void:
	var w := _arena()
	var u := _put(w, "marine", _mid(w))
	u.apply_effect({"id": "irradiate", "kind": "dot", "remain": 5.0, "duration": 5.0, "dps": 10.0})
	u.apply_effect({"id": "irradiate", "kind": "dot", "remain": 12.0, "duration": 12.0, "dps": 10.0})
	var n: int = u.effects.size()
	var rem := float((u.effects[0] as Dictionary)["remain"])
	_report("同源效果不叠加，只取更长时长", n == 1 and absf(rem - 12.0) < 0.001,
		"条数 %d，剩余 %.1f" % [n, rem])
	# 阳性对照：短的那次不能把长的压回去
	u.apply_effect({"id": "irradiate", "kind": "dot", "remain": 1.0, "duration": 1.0, "dps": 10.0})
	_report("后到的短时长不会覆盖长时长（阳性对照）",
		absf(float((u.effects[0] as Dictionary)["remain"]) - 12.0) < 0.001, "")

func _test_effect_multi_source() -> void:
	var w := _arena()
	var u := _put(w, "marine", _mid(w))
	u.apply_effect({"id": "irradiate", "kind": "dot", "remain": 5.0, "duration": 5.0, "dps": 10.0})
	u.apply_effect({"id": "plague", "kind": "slow", "remain": 5.0, "duration": 5.0, "slow_mult": 0.5})
	_report("不同源的效果可以并存", u.effects.size() == 2 and _fx(u) == "irradiate/dot,plague/slow",
		_fx(u))

func _test_slow_mult() -> void:
	var w := _arena()
	var u := _put(w, "marine", _mid(w))
	var base: float = u.speed()
	u.apply_effect({"id": "a", "kind": "slow", "remain": 5.0, "duration": 5.0, "slow_mult": 0.5})
	var half: float = u.speed()
	u.apply_effect({"id": "b", "kind": "slow", "remain": 5.0, "duration": 5.0, "slow_mult": 0.5})
	var quarter: float = u.speed()
	_report("多个减速效果乘算（0.5 × 0.5 = 0.25）",
		absf(half - base * 0.5) < 0.01 and absf(quarter - base * 0.25) < 0.01,
		"%.1f → %.1f → %.1f" % [base, half, quarter])

func _test_clear_on_death() -> void:
	var w := _arena()
	var u := _put(w, "marine", _mid(w))
	u.apply_effect({"id": "irradiate", "kind": "dot", "remain": 30.0, "duration": 30.0, "dps": 10.0})
	u.take_damage(99999.0, "normal")
	_report("单位死亡时清空效果", u.dead and u.effects.is_empty(),
		"dead=%s effects=%d" % [str(u.dead), u.effects.size()])

# ================================================================ 第三组：心灵风暴

func _test_storm_spawns_and_costs() -> void:
	var w := _arena("protoss", "zerg")
	var ht := _put(w, "high_templar", _mid(w), World.PLAYER)
	var e0: float = ht.energy
	var ok := w.cmd_ability([ht], "psionic_storm", _mid(w) + Vector2(100, 0))
	var need := float(GameData.get_spell("psionic_storm").get("energy", 0.0))
	_report("心灵风暴落下并扣能量",
		ok and w.spell_zones.size() == 1 and absf(ht.energy - (e0 - need)) < 0.001,
		"区域 %d 个，能量 %.0f → %.0f" % [w.spell_zones.size(), e0, ht.energy])
	# 冷却期内不能连放（防触屏输入抖动把能量一次倒空）
	var again := w.cmd_ability([ht], "psionic_storm", _mid(w) + Vector2(110, 0))
	_report("冷却期内不能重复施放", not again and w.spell_zones.size() == 1,
		"第二次返回 %s" % str(again))
	# 两个圣堂武士同时施放 → 两片风暴（星际 1 里可以叠）
	var ht2 := _put(w, "high_templar", _mid(w) + Vector2(20, 0), World.PLAYER)
	var ok2 := w.cmd_ability([ht2], "psionic_storm", _mid(w) + Vector2(110, 0))
	_report("第二个施法者可以独立放（冷却只挡自己）",
		ok2 and w.spell_zones.size() == 2, "区域 %d 个" % w.spell_zones.size())

func _test_storm_hits_all() -> void:
	var w := _arena("protoss", "zerg")
	var m := _mid(w)
	var ht := _put(w, "high_templar", m + Vector2(-120, 0), World.PLAYER)
	# ⚠️ 靶子一律用**探机**，而且必须相距 100px。
	#    第一版用的是「狂热者 + 蟑螂」，结果两者相距 14px 互相打起来了 ——
	#    「敌人掉 80」里绝大部分是狂热者的近战伤害，风暴的真实伤害被淹掉，
	#    断言看到的是「自己人掉得比敌人少」，看起来像「按阵营过滤」的 bug，
	#    其实只是测试场自己打起来了。
	#    探机射程 36、伤害 5，相距 100px 时谁也够不着谁。
	var foe := _put(w, "probe", m + Vector2(50, 0), World.ENEMY)
	var mate := _put(w, "probe", m + Vector2(-50, 0), World.PLAYER)
	var far := _put(w, "probe", m + Vector2(400, 0), World.ENEMY)
	var foe0: float = foe.hp + foe.shield
	var mate0: float = mate.hp + mate.shield
	var far0: float = far.hp + far.shield
	w.cmd_ability([ht], "psionic_storm", m)
	_run(w, 1.0)
	var foe_lost: float = foe0 - (foe.hp + foe.shield)
	var mate_lost: float = mate0 - (mate.hp + mate.shield)
	var far_lost: float = far0 - (far.hp + far.shield)
	_report("圈内敌人掉血", foe_lost > 0.0, "掉 %.1f" % foe_lost)
	_report("★圈内自己人也掉血（敌我不分，星际 1 的原样行为）★", mate_lost > 0.0,
		"掉 %.1f" % mate_lost)
	_report("圈外的敌人不掉血", absf(far_lost) < 0.001, "掉 %.1f" % far_lost)
	# 两个探机的护甲 / 护盾完全相同，掉血量必须**逐点一致** ——
	# 不一致说明「按阵营过滤」被误加了（那正是敌我不分要防的事）。
	_report("自己人与敌人掉血完全一致（排除「偷偷按阵营过滤」）",
		absf(mate_lost - foe_lost) < 0.001, "敌人 %.1f / 自己人 %.1f" % [foe_lost, mate_lost])

func _test_storm_out_of_range() -> void:
	var w := _arena("protoss", "zerg")
	var m := _mid(w)
	var ht := _put(w, "high_templar", m, World.PLAYER)
	var reach := float(GameData.get_spell("psionic_storm").get("cast_range", 0.0))
	var ok_far := w.cmd_ability([ht], "psionic_storm", m + Vector2(reach + 80.0, 0))
	var ok_near := w.cmd_ability([ht], "psionic_storm", m + Vector2(reach - 40.0, 0))
	_report("超出施法距离放不出来，距离内放得出来",
		(not ok_far) and ok_near and w.spell_zones.size() == 1,
		"远 %s / 近 %s" % [str(ok_far), str(ok_near)])

func _test_storm_expires() -> void:
	var w := _arena("protoss", "zerg")
	var m := _mid(w)
	var ht := _put(w, "high_templar", m + Vector2(-100, 0), World.PLAYER)
	var sp := GameData.get_spell("psionic_storm")
	var dur := float(sp.get("duration", 0.0))
	# 用高血量的执政官当靶子，保证它撑得过 4 秒（否则测的是过量伤害）
	var tank := _put(w, "archon", m, World.ENEMY)
	var hp0: float = tank.hp + tank.shield
	w.cmd_ability([ht], "psionic_storm", m)
	_run(w, dur + 1.0)
	var lost: float = hp0 - (tank.hp + tank.shield)
	var ticks := int(floor(dur / GameData.DOT_TICK))
	var expect := _per_tick(sp, tank) * float(ticks)
	_report("区域在时长结束后消失", w.spell_zones.is_empty(),
		"剩余区域 %d" % w.spell_zones.size())
	_report("总伤害 = 每跳伤害 × 跳数（跳数 = floor(时长 / DOT_TICK)）",
		absf(lost - expect) < 0.01,
		"实掉 %.1f / 期望 %.1f（%d 跳 × %.1f）" % [lost, expect, ticks, _per_tick(sp, tank)])

## ★帧率无关性★ —— 这一条是整套里最重要的。
##
## 若 dot 写成「每帧扣 dps * delta」，两次跑的总伤害会**一样**（都等于 dps×T），
## 看起来没问题。真正会炸的是 `take_damage` 里的 `maxf(1.0, ...)` 地板：
## 每跳至少 1 点，跳数越多总伤害越高。
## 所以断言必须**同时**检查「跳数」和「总伤害」，只查总伤害抓不到。
func _test_storm_framerate() -> void:
	var sp := GameData.get_spell("psionic_storm")
	var dur := float(sp.get("duration", 0.0))
	var res: Array = []
	for step in [0.02, 0.05]:
		var w := _arena("protoss", "zerg")
		var m := _mid(w)
		var ht := _put(w, "high_templar", m + Vector2(-100, 0), World.PLAYER)
		var tank := _put(w, "archon", m, World.ENEMY)
		var hp0: float = tank.hp + tank.shield
		w.cmd_ability([ht], "psionic_storm", m)
		_run(w, dur, step)
		res.append(hp0 - (tank.hp + tank.shield))
	var ticks := int(floor(dur / GameData.DOT_TICK))
	var w0 := _arena("protoss", "zerg")
	var expect := _per_tick(sp, _put(w0, "archon", _mid(w0), World.ENEMY)) * float(ticks)
	_report("★dot 结算与帧率无关（0.02s 与 0.05s 步长总伤害逐点一致）★",
		absf(float(res[0]) - float(res[1])) < 0.01,
		"0.02s 步长 %.1f / 0.05s 步长 %.1f" % [res[0], res[1]])
	_report("两种步长的总伤害都等于 跳数 × 每跳伤害",
		absf(float(res[0]) - expect) < 0.01 and absf(float(res[1]) - expect) < 0.01,
		"期望 %.1f（%d 跳）" % [expect, ticks])

# ================================================================ 第四组：黑暗虫群

func _test_swarm_marks_ground() -> void:
	var w := _arena("zerg", "terran")
	var m := _mid(w)
	var df := _put(w, "defiler", m + Vector2(-150, 0), World.PLAYER)
	var mate := _put(w, "zergling", m, World.PLAYER)
	var mate_air := _put(w, "mutalisk", m + Vector2(20, 0), World.PLAYER)
	var ok := w.cmd_ability([df], "dark_swarm", m)
	_run(w, 0.2)
	_report("黑暗虫群在落点生成区域", ok and w.spell_zones.size() == 1,
		"区域 %d 个" % w.spell_zones.size())
	_report("圈内地面单位获得 no_ranged", mate.has_effect_kind("no_ranged"), _fx(mate))
	_report("圈内飞行单位不受影响（虫群只遮蔽地面）",
		not mate_air.has_effect_kind("no_ranged"), _fx(mate_air))

## 远程打不进去 —— 而且必须是「**不开火**」，不是「开了火但没伤害」。
##
## 判据用攻击者的 `cooldown`：只有真的开火才会被写成 `cooldown_time()`。
## 若把闸门挪到命中结算，弹道照样飞出去、落点照样有火花，
## 玩家看到的是「明明打中了却不掉血」——那是另一种观感，还白费性能。
func _test_swarm_blocks_ranged() -> void:
	var w := _arena("zerg", "terran")
	var m := _mid(w)
	var df := _put(w, "defiler", m + Vector2(-150, 0), World.PLAYER)
	var prey := _put(w, "zergling", m, World.PLAYER)
	var gun := _put(w, "marine", m + Vector2(70, 0), World.ENEMY)
	w.cmd_ability([df], "dark_swarm", m)
	_run(w, 0.2)
	prey.hp = prey.max_hp
	gun.cooldown = 0.0
	var fired := 0
	for i in range(60):
		w.step(0.05)
		if gun.cooldown > 0.0:
			fired += 1
	_report("黑暗虫群里的地面单位挡住远程（攻击者一次都没开火）",
		fired == 0 and prey.hp >= prey.max_hp - 0.01,
		"开火帧数 %d，猎物 %.0f/%.0f" % [fired, prey.hp, prey.max_hp])
	# 直接判据（纯函数）也验一遍，并确认它认的是「攻击者射程 > 阈值」
	_report("blocked_by_dark_swarm 认的是「远程 vs 近战」而不是「谁在里面」",
		w.blocked_by_dark_swarm(gun, prey) and not w.blocked_by_dark_swarm(
			_put(w, "zergling", m + Vector2(46, 0), World.ENEMY), prey),
		"陆战队员 %.0f / 跳虫 %.0f，阈值 %.0f" % [
			gun.attack_range(), 34.0, GameData.MELEE_RANGE])

func _test_swarm_melee_still_hits() -> void:
	var w := _arena("zerg", "terran")
	var m := _mid(w)
	var df := _put(w, "defiler", m + Vector2(-150, 0), World.PLAYER)
	var prey := _put(w, "zergling", m, World.PLAYER)
	var dog := _put(w, "zergling", m + Vector2(46, 0), World.ENEMY)
	w.cmd_ability([df], "dark_swarm", m)
	_run(w, 0.2)
	_report("虫群里的目标确实带着 no_ranged（前提成立）", prey.has_effect_kind("no_ranged"), _fx(prey))
	# ★阳性对照★：近战必须照样打得到。少了这条，`blocked_by_dark_swarm`
	# 直接 return true 也能让上一组通过 —— 那时虫群是「无敌圈」，不是遮蔽。
	var hp0: float = prey.hp
	_run(w, 3.0)
	_report("★近战照样打得到虫群里的单位（阳性对照）★", prey.hp < hp0 - 0.5,
		"%.1f → %.1f（攻击者射程 %.0f，阈值 %.0f）" % [
			hp0, prey.hp, dog.attack_range(), GameData.MELEE_RANGE])

## 虫群保护的是**里面的人**，不管火力从哪来。
##
## ⚠️ 第一版这条写反了：断言「飞行单位能打虫群里的地面单位」。
##    星际 1 的黑暗虫群恰恰是**对空火力也有效**的 —— 那才是它被用来
##    对抗飞龙的原因。写反的断言会逼着实现去开一个「空中攻击无视虫群」的
##    后门，把虫群的战术价值砍掉一半。
##    这里改成正确的方向，并配阳性对照（把目标挪出虫群后必须打得中）。
func _test_swarm_blocks_air_too() -> void:
	var w := _arena("zerg", "terran")
	var m := _mid(w)
	var df := _put(w, "defiler", m + Vector2(-150, 0), World.PLAYER)
	var prey := _put(w, "zergling", m, World.PLAYER)
	var fly := _put(w, "wraith", m + Vector2(120, 0), World.ENEMY)
	w.cmd_ability([df], "dark_swarm", m)
	_run(w, 0.2)
	_report("飞行攻击者本身不在虫群的免疫对象里（前提成立）",
		not fly.has_effect_kind("no_ranged"), _fx(fly))
	prey.hp = prey.max_hp
	fly.cooldown = 0.0
	var fired := 0
	for i in range(80):
		w.step(0.05)
		if fly.cooldown > 0.0:
			fired += 1
	_report("★空中远程火力也打不进虫群（星际 1 的黑暗虫群就是这样）★",
		fired == 0 and prey.hp >= prey.max_hp - 0.01,
		"开火帧数 %d，猎物 %.0f/%.0f" % [fired, prey.hp, prey.max_hp])
	# 阳性对照：把猎物挪出虫群（400px 外），幽灵战机必须打得中。
	var prey2 := _put(w, "zergling", m + Vector2(400, 0), World.PLAYER)
	var fly2 := _put(w, "wraith", m + Vector2(500, 0), World.ENEMY)
	_run(w, 0.2)
	var hp2: float = prey2.hp
	_run(w, 4.0)
	_report("虫群外的地面单位照样被空中火力打（阳性对照）",
		prey2.hp < hp2 - 0.5, "%.1f → %.1f" % [hp2, prey2.hp])

func _test_swarm_linger() -> void:
	var w := _arena("zerg", "terran")
	var m := _mid(w)
	var df := _put(w, "defiler", m + Vector2(-150, 0), World.PLAYER)
	var walker := _put(w, "zergling", m, World.PLAYER)
	w.cmd_ability([df], "dark_swarm", m)
	_run(w, 0.2)
	var inside: bool = walker.has_effect_kind("no_ranged")
	# 走出区域：往远处挪 400px
	walker.pos = m + Vector2(400, 0)
	_run(w, World.NO_RANGED_LINGER + 0.3)
	var outside: bool = walker.has_effect_kind("no_ranged")
	_report("走出虫群后效果残留一小段再消失（不是瞬间、也不是永久）",
		inside and not outside, "圈内 %s → 圈外 %s" % [str(inside), str(outside)])
	# 区域到期后，留在原地的人也必须解除
	var w2 := _arena("zerg", "terran")
	var m2 := _mid(w2)
	var df2 := _put(w2, "defiler", m2 + Vector2(-150, 0), World.PLAYER)
	var stay := _put(w2, "zergling", m2, World.PLAYER)
	w2.cmd_ability([df2], "dark_swarm", m2)
	var dur := float(GameData.get_spell("dark_swarm").get("duration", 0.0))
	_run(w2, dur + 1.0)
	_report("区域到期后免疫解除（原地不动也一样）",
		w2.spell_zones.is_empty() and not stay.has_effect_kind("no_ranged"),
		"区域 %d 个" % w2.spell_zones.size())

# ================================================================ 第五组：辐照

func _test_irradiate_dot() -> void:
	var w := _arena("terran", "zerg")
	var m := _mid(w)
	var sv := _put(w, "science_vessel", m + Vector2(-150, 0), World.PLAYER)
	var foe := _put(w, "roach", m, World.ENEMY)
	var e0: float = sv.energy
	var ok := w.cmd_ability([sv], "irradiate", foe)
	var need := float(GameData.get_spell("irradiate").get("energy", 0.0))
	_report("辐照挂到目标身上并扣能量",
		ok and foe.has_effect("irradiate") and absf(sv.energy - (e0 - need)) < 0.001,
		"%s，能量 %.0f → %.0f" % [_fx(foe), e0, sv.energy])
	var hp0: float = foe.hp
	_run(w, 2.0)
	_report("辐照目标持续掉血", foe.hp < hp0, "%.1f → %.1f" % [hp0, foe.hp])
	# 不能对友军用
	var mate := _put(w, "marine", m + Vector2(-40, 0), World.PLAYER)
	var bad := w.cmd_ability([sv], "irradiate", mate)
	_report("辐照不能对自己人用", not bad and not mate.has_effect("irradiate"), _fx(mate))

func _test_irradiate_spreads() -> void:
	var w := _arena("terran", "zerg")
	var m := _mid(w)
	var sv := _put(w, "science_vessel", m + Vector2(-200, 0), World.PLAYER)
	var victim := _put(w, "roach", m, World.ENEMY)
	var buddy := _put(w, "roach", m + Vector2(30, 0), World.ENEMY)
	var stranger := _put(w, "roach", m + Vector2(600, 0), World.ENEMY)
	var mate := _put(w, "marine", m + Vector2(-60, 0), World.PLAYER)
	w.cmd_ability([sv], "irradiate", victim)
	# 传染发生在 dot 结算时（每 DOT_TICK 一次），跑够三跳
	_run(w, GameData.DOT_TICK * 3.0)
	_report("辐照传染给身边的同阵营单位", buddy.has_effect("irradiate"), _fx(buddy))
	_report("传染不越过距离（远处同阵营不受影响）",
		not stranger.has_effect("irradiate"), _fx(stranger))
	_report("传染不跨阵营（施法者自己人不受影响）",
		not mate.has_effect("irradiate"), _fx(mate))
	# 阳性对照：被传染的人必须真的开始掉血，而不是只挂了个空壳效果
	var hp0: float = buddy.hp
	_run(w, 1.0)
	_report("被传染的单位真的掉血（阳性对照）", buddy.hp < hp0, "%.1f → %.1f" % [hp0, buddy.hp])

func _test_irradiate_expires() -> void:
	var w := _arena("terran", "zerg")
	var m := _mid(w)
	var sv := _put(w, "science_vessel", m + Vector2(-200, 0), World.PLAYER)
	var foe := _put(w, "roach", m, World.ENEMY)
	var dur := float(GameData.get_spell("irradiate").get("duration", 0.0))
	w.cmd_ability([sv], "irradiate", foe)
	_run(w, dur + 1.0)
	_report("辐照在时长结束后解除", not foe.has_effect("irradiate") and not foe.dead,
		"%s，hp %.0f" % [_fx(foe), foe.hp])

# ================================================================ 第六组：快照往返

## 造一个带能量 / 效果 / 法术区域的世界对，编码后解码到客户端世界。
##
## ⚠️ `b` 的**资源节点数量必须和 `a` 一样**（都是 0）。
##    快照里资源是「按数量 + 逐条下标」编码的，两边数量不同的话
##    「解码结果再编码 == 原字节」这条断言会因为多出一堆记录而失败，
##    看起来像量化出问题，其实是测试场没摆平。
func _snap_pair() -> Array:
	var a := _arena("protoss", "zerg")
	var m := _mid(a)
	var ht := _put(a, "high_templar", m + Vector2(-100, 0), World.PLAYER)
	var foe := _put(a, "roach", m, World.ENEMY)
	# ⚠️ 蝎子必须站得离落点足够近。第一版放在 m+(-300,0)、落点在 m+(200,0)，
	#    距离 500 远超施法距离 200 → 施法**静默失败**，区域根本不存在。
	#    而「往返一致」那条断言照样 PASS（两边都是空的），
	#    连字节往返也是绿的 —— 三条断言一起变成了恒真。
	var df := _put(a, "defiler", m + Vector2(-110, 0), World.PLAYER)
	ht.energy = 137.0
	foe.apply_effect({"id": "irradiate", "kind": "dot", "remain": 6.5, "duration": 15.0, "dps": 12.0})
	var cast_ok := a.cmd_ability([df], "dark_swarm", m + Vector2(80, 0))
	# 先把「前提成立」钉死：区域没落下来的话，下面三条断言会一起变成恒真。
	_report("快照测试场：黑暗虫群真的落下来了（前提）",
		cast_ok and a.spell_zones.size() == 1, "区域 %d 个" % a.spell_zones.size())
	var b := World.new(64, 40, "protoss", "zerg", "easy")
	b.units.clear()
	b.buildings.clear()
	b.resources.clear()
	b.ai_enabled = false
	b.local_owner = World.ENEMY
	return [a, b]

func _test_snapshot_energy() -> void:
	var pair := _snap_pair()
	var a: World = pair[0]
	var b: World = pair[1]
	var bytes := Net.encode_snapshot(a, Net.Buf.new(), 7)
	var res := Net.apply_snapshot(b, bytes)
	var got := -1.0
	for u in b.units:
		if u.type_id == "high_templar":
			got = u.energy
	_report("快照往返：能量原样还原", bool(res["ok"]) and absf(got - 137.0) < 0.001,
		"137.0 → %.1f" % got)

func _test_snapshot_effects() -> void:
	var pair := _snap_pair()
	var a: World = pair[0]
	var b: World = pair[1]
	var bytes := Net.encode_snapshot(a, Net.Buf.new(), 7)
	Net.apply_snapshot(b, bytes)
	var got := ""
	for u in b.units:
		if u.type_id == "roach":
			got = _fx(u)
	_report("快照往返：单位身上的状态效果原样还原", got == "irradiate/dot", got)

func _test_snapshot_zones() -> void:
	var pair := _snap_pair()
	var a: World = pair[0]
	var b: World = pair[1]
	var bytes := Net.encode_snapshot(a, Net.Buf.new(), 7)
	Net.apply_snapshot(b, bytes)
	var ids: Array = []
	for z in b.spell_zones:
		ids.append(String((z as Dictionary).get("id", "")))
	_report("快照往返：法术区域原样还原",
		ids.size() == 1 and String(ids[0]) == "dark_swarm", ",".join(ids))
	# 半径 / 时长从本地表重建 —— 不传这些字段，但解出来必须和主机一致
	var z0: Dictionary = b.spell_zones[0] if not b.spell_zones.is_empty() else {}
	var sp := GameData.get_spell("dark_swarm")
	_report("法术区域的范围从本地表重建（不占带宽）",
		not z0.is_empty()
			and absf(float(z0.get("radius", 0.0)) - float(sp.get("radius", -1.0))) < 0.001,
		"radius %.0f" % float(z0.get("radius", 0.0)))

	# ★构造性往返★：解码结果再编码必须逐字节相同。
	# 这是本项目量化纪律的守门人 —— 任何一处 `int()` 截断都会在这里暴露。
	var again := Net.encode_snapshot(b, Net.Buf.new(), 7)
	_report("★解码结果再编码 == 原始字节（量化精确往返）★", again == bytes,
		"%d B → %d B" % [bytes.size(), again.size()])

# ================================================================ 第七组：AI

## AI 放心灵风暴时**必须**避开自己人 —— 它敌我不分。
##
## 直接调 `_ai_cast_spells()`，不跑整局 AI：跑整局的话「AI 有没有造出圣堂武士」
## 取决于地图与经济随机，断言会偶发（有时它压根没造出来，于是「没误伤」恒真）。
func _test_ai_no_friendly_fire() -> void:
	var w := _arena("terran", "protoss")
	var m := _mid(w)
	var ht := _put(w, "high_templar", m, World.ENEMY)
	# 玩家的兵与 AI 自己的兵**混在一起**（相距 20px，都落在 52px 的风暴半径内）。
	# 这种局面下「只打敌人不打自己人」在几何上不可能，正确行为是放弃施放。
	for i in range(4):
		_put(w, "marine", m + Vector2(160.0 + 14.0 * float(i), 0), World.PLAYER)
	for i in range(3):
		_put(w, "zealot", m + Vector2(150.0 + 14.0 * float(i), 6), World.ENEMY)
	w._rebuild_hash()
	w._ai_cast_spells()
	_report("★AI 不会把敌我不分的心灵风暴丢在自己人头上★",
		w.spell_zones.is_empty(), "区域 %d 个" % w.spell_zones.size())

	# 阳性对照：敌人聚成一堆、自己人退到远处之后，AI **必须**放得出来。
	# 少了这条，「不放」可能只是「AI 施法逻辑整个没跑」的副作用。
	var w2 := _arena("terran", "protoss")
	var m2 := _mid(w2)
	_put(w2, "high_templar", m2, World.ENEMY)
	for i in range(4):
		_put(w2, "marine", m2 + Vector2(160.0 + 12.0 * float(i), 0), World.PLAYER)
	w2._rebuild_hash()
	w2._ai_cast_spells()
	_report("AI 在「圈里只有敌人」时会放风暴（阳性对照）",
		w2.spell_zones.size() == 1, "区域 %d 个" % w2.spell_zones.size())

	# 阳性对照二：**只放一个**敌人的兵时不该浪费 75 点能量。
	var w3 := _arena("terran", "protoss")
	var m3 := _mid(w3)
	_put(w3, "high_templar", m3, World.ENEMY)
	_put(w3, "marine", m3 + Vector2(160, 0), World.PLAYER)
	w3._rebuild_hash()
	w3._ai_cast_spells()
	_report("AI 不会为了一个敌人浪费 75 点能量（门槛 %d）" % World.AI_STORM_MIN_HITS,
		w3.spell_zones.is_empty(), "区域 %d 个" % w3.spell_zones.size())
