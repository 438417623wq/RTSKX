extends SceneTree

## 战场法术与状态效果测试（M5 + M6）。
##
## 锁死七条铁律：
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
##   6. **诱捕网是一次性施法，效果跟着单位走**（M6）—— 和「留在战场上的
##      持久区域」是两种东西：被抓到的兵跑出圈照样慢满 25 秒，
##      后来才走进圈的完全不受影响。做成持久区域会强得离谱。
##   7. **诱捕网同时降移速和降射速**（移速 ×0.5 / 武器冷却 ×1.25）——
##      漏掉射速那一条的话，它就只剩一个减速，
##      而它在原作里真正的价值是「把对方的输出砍掉五分之一」。
##
## ⚠️ 每条「做不到 X」的断言都配了阳性对照。
##    尤其是「黑暗虫群挡住了远程」：把 `blocked_by_dark_swarm` 直接 return true
##    也能让它通过，所以必须同时证明「近战真的打得到」。
##    同理「诱捕网的效果跟着单位走」配了**持久区域的镜像对照**（走出去就失效）。

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
	print("  ---- 第八组：诱捕网（M6）----")
	_test_ensnare_tables()
	_test_ensnare_instant()
	_test_ensnare_hits_all()
	_test_ensnare_follows_unit()
	_test_ensnare_slows_and_dps()
	_test_ensnare_sieged_tank()
	_test_ensnare_no_damage()
	_test_ensnare_out_of_range()
	_test_ensnare_expires()
	_test_snapshot_ensnare()
	_test_ai_ensnare()
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

## 某个效果的剩余秒数，没有则返回 -1。
##
## ⚠️ 不要写 `u.effects[0]` —— 单位身上可能同时挂着别的效果，
##    下标取到哪一个取决于插入顺序。这种「碰巧对了」的断言在
##    加一个新法术之后会突然变红，而且看起来像新法术的问题。
func _remain_of(u: Unit, id: String) -> float:
	for e in u.effects:
		var d: Dictionary = e
		if String(d.get("id", "")) == id:
			return float(d.get("remain", -1.0))
	return -1.0

## 场上带某个效果的单位数量。
##
## ⚠️ 诱捕网是**一次性施法**，`spell_zones` 永远是空的 ——
##    「AI 有没有放」不能靠查区域，只能靠查单位身上的效果。
##    写错的话，AI 施法测试会变成「永远为假」的断言。
func _any_effect(w: World, id: String) -> int:
	var n := 0
	for u in w.units:
		if u.has_effect(id):
			n += 1
	return n

## 这个单位 / 建筑有没有专属造型（而不是落进兜底圆盘）。
##
## 兜底是**静默**的 —— 落进去了既不报错也不崩，只是长得像个圆球，
## 只有跑截图才看得见。所以必须有一条断言守着。
func _sprite_ok(id: String) -> bool:
	var c := Color(0.5, 0.5, 0.5)
	if GameData.get_unit(id).is_empty():
		GenTex.building_sprite(id, c, c, c)
	else:
		GenTex.unit_sprite(id, c, c, c)
	return not GenTex.last_was_fallback

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
	_report("每个法术的施法单位都进了五张表（可造 + 有升级分类）", bad.is_empty(), "; ".join(bad))

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

# ================================================================ 第八组：诱捕网（M6）

## 数据表自洽 + 科技链门槛。
##
## ⚠️ 这一组里最值钱的两条是「虫后是空中单位」和「巢穴挂在尖塔下面」——
##    两条都**不报错**，症状分别是「虫后在地上被跳虫围死」和
##    「虫后开局就能造、早期没有制衡」。
func _test_ensnare_tables() -> void:
	var bad: Array = []
	var d := GameData.get_unit("queen")
	if d.is_empty():
		bad.append("queen 不在 UNITS 里")
	else:
		if float(d.get("damage", 0)) > 0.0:
			bad.append("虫后有攻击力（会去索敌，不该肉搏）")
		if String(d.get("role", "")) != "support":
			bad.append("虫后 role 不是 support")
		if float(d.get("energy", 0.0)) <= 0.0:
			bad.append("虫后没有能量")
	_report("虫后是零伤害的支援单位", bad.is_empty(), "; ".join(bad))
	_report("★虫后是空中单位（漏了会被地面近战围死）★", GameData.is_flying("queen"),
		"AIR_RULES.queen.flying")
	_report("虫后有升级分类", GameData.UPGRADE_CLASS.has("queen"),
		String(GameData.UPGRADE_CLASS.get("queen", "")))

	var nest := GameData.get_building("queen_nest")
	_report("虫后巢穴能训练虫后",
		(nest.get("trains", []) as Array).has("queen")
			and String(nest.get("faction", "")) == "zerg",
		"trains=%s" % str(nest.get("trains", [])))
	# ⚠️ `requires` 必须是 spire，不能是 hive —— hive 是虫族**起始建筑**，
	#    写 hive 等于零门槛。而这条**不会报错**：科技树看着是对的，
	#    只是虫后从第一秒就能造。
	_report("★虫后巢穴挂在尖塔下面，而不是起始的虫巢（否则零门槛）★",
		String(nest.get("requires", "")) == "spire", String(nest.get("requires", "")))

	# 建造菜单**同时**驱动玩家菜单（`Main._draw_build_menu`）和 AI 建造顺序
	# （`World._ai_produce`）。不在菜单里 = 玩家看不见、AI 也不会造 =
	# 虫后和诱捕网变成永远见不到的死内容。
	var menu_ids: Array = []
	for entry in GameData.BUILD_MENU["zerg"]:
		menu_ids.append(String((entry as Dictionary)["id"]))
	_report("★虫后巢穴在虫族建造菜单里（不在菜单 = 玩家和 AI 都造不出来）★",
		menu_ids.has("queen_nest"), ", ".join(menu_ids))

	_report("虫后有专属造型（不落兜底圆盘）", _sprite_ok("queen"), "")
	_report("虫后巢穴有专属造型（不落兜底圆盘）", _sprite_ok("queen_nest"), "")

## 一次性施法的基本形态：扣能量、**不留区域**、圈内挂满时长效果、冷却生效。
func _test_ensnare_instant() -> void:
	var sp := GameData.get_spell("ensnare")
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	var u := _put(w, "hydralisk", spot, World.ENEMY)
	var e0: float = q.energy
	var need := float(sp.get("energy", 0.0))
	var ok := w.cmd_ability([q], "ensnare", spot)
	_report("诱捕网落下、扣能量、且**不留下持久区域**",
		ok and absf(q.energy - (e0 - need)) < 0.001 and w.spell_zones.is_empty(),
		"能量 %.0f → %.0f，区域 %d 个" % [e0, q.energy, w.spell_zones.size()])
	var dur := float(sp.get("duration", 0.0))
	_report("圈内单位被挂上**满时长**的减速效果",
		u.has_effect("ensnare") and absf(_remain_of(u, "ensnare") - dur) < 0.001,
		"剩余 %.1f / 时长 %.1f" % [_remain_of(u, "ensnare"), dur])
	_report("冷却期内不能重复施放（防触屏连点倒空能量）",
		not w.cmd_ability([q], "ensnare", spot + Vector2(10, 0)), "")

## 影响范围：**敌我不分 + 对空也有效 + 圈外不受影响**。
##
## ⚠️ 靶子一律摆到互相够不着的距离，而且这一组**不跑模拟** ——
##    跑了的话战斗伤害会混进来（M5 的心灵风暴测试就踩过「靶子自己打起来」）。
func _test_ensnare_hits_all() -> void:
	var sp := GameData.get_spell("ensnare")
	var r := float(sp.get("radius", 0.0))
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	var foe_g := _put(w, "probe", spot + Vector2(-55, 0), World.ENEMY)
	var mate_g := _put(w, "probe", spot + Vector2(55, 0), World.PLAYER)
	var foe_air := _put(w, "mutalisk", spot + Vector2(0, -55), World.ENEMY)
	# 圈外：半径 80，摆到 95 —— 差一点点也要挡住，否则「范围」是个摆设
	var outside := _put(w, "probe", spot + Vector2(r + 15.0, 0), World.ENEMY)
	var ok := w.cmd_ability([q], "ensnare", spot)
	_report("诱捕网施放成功（前提）", ok, "")
	_report("圈内的敌人被减速", foe_g.has_effect("ensnare"), _fx(foe_g))
	_report("★圈内的自己人也一样被减速（敌我不分，星际 1 的原样行为）★",
		mate_g.has_effect("ensnare"), _fx(mate_g))
	# ★对空★ —— 星际 1 的原文是「覆盖区域内**任何**未潜伏单位」，
	# 而且明确提到飞行单位的转向/加速也变慢。
	# 写成「只抓地面」的话，诱捕网对空军的价值直接归零，而且不报错。
	_report("★空中单位同样被抓（诱捕网对空也有效）★", foe_air.has_effect("ensnare"),
		_fx(foe_air))
	_report("圈外的单位不受影响", not outside.has_effect("ensnare"), _fx(outside))
	# 施法者自己站在 120px 外（>80），不该被自己的网抓住
	_report("施法者自己不在圈里就不受影响", not q.has_effect("ensnare"), _fx(q))

## ★本组最重要的一条★ —— 诱捕网和「持久区域」的分水岭。
##
## 直接调 `_apply_instant_aoe` 的两种机制对照：
##   · 诱捕网（instant）  → 效果挂在单位身上，走出圈**照样**慢满 25 秒；
##   · 黑暗虫群（区域）   → 效果靠 `NO_RANGED_LINGER` 每帧续期，走出圈**立刻**失效。
##
## ⚠️ 只断言前一半是不够的：如果「效果列表根本不会掉」，
##    前一半也会通过。必须配一个**镜像对照**证明这套判据真的能分辨两种机制。
func _test_ensnare_follows_unit() -> void:
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	var caught := _put(w, "probe", spot, World.ENEMY)
	var late := _put(w, "probe", spot + Vector2(300, 0), World.ENEMY)
	var ok := w.cmd_ability([q], "ensnare", spot)
	_report("诱捕网测试场：圈内单位真的被抓到了（前提）",
		ok and caught.has_effect("ensnare"), _fx(caught))
	# 被抓到的兵跑出圈；一个后来才走进圈里的兵补位
	caught.pos = spot + Vector2(600, 0)
	late.pos = spot
	_run(w, 1.0)
	_report("★被抓到的单位跑出区域后仍然减速（效果跟着单位走）★",
		caught.has_effect("ensnare") and absf(caught.slow_mult() - 0.5) < 0.001,
		"%s，slow_mult %.2f" % [_fx(caught), caught.slow_mult()])
	_report("★后来才进入区域的单位完全不受影响（它不是持久区域）★",
		not late.has_effect("ensnare"), _fx(late))

	# ---- 镜像对照：持久区域（黑暗虫群）**必须**相反 ----
	#
	# ⚠️★这里必须**先推进一帧**★。持久区域是「每帧重新判定谁在圈里」，
	#    `cmd_ability` 只是把区域放进 `spell_zones`，真正挂效果的是
	#    `_tick_spell_zones` —— 它在 `step()` 里。施法完直接查的话，
	#    区域存在、效果一个都没有，下面那条「走出圈就失去免疫」于是
	#    **恒真**（因为它本来就从来没被挂上过），
	#    整条镜像对照变成一条什么都证明不了的假阳性。
	#    诱捕网（一次性）不需要这一步 —— 这正是两种机制的区别本身。
	var w2 := _arena("zerg", "zerg")
	var m2 := _mid(w2)
	var df := _put(w2, "defiler", m2, World.PLAYER)
	var spot2 := m2 + Vector2(120, 0)
	var out := _put(w2, "probe", spot2, World.ENEMY)
	w2.cmd_ability([df], "dark_swarm", spot2)
	_run(w2, 0.05)
	_report("持久区域对照：虫群落下时圈内地面单位被标记（前提）",
		out.has_effect("dark_swarm"), _fx(out))
	out.pos = spot2 + Vector2(600, 0)
	_run(w2, 1.0)
	_report("★持久区域对照：走出虫群的单位会失去免疫★（证明上面那条不是恒真）",
		not out.has_effect("dark_swarm"), _fx(out))

## 移速 ×0.5 **和** 武器冷却 ×1.25。
##
## ⚠️ 后半条是最容易漏的：只做减速的话，诱捕网看起来「实现了」，
##    但它真正的战术价值（把对方输出砍掉五分之一）完全没有。
##    而且两个效果用的是**同一个 kind**（`slow`），漏了不会有任何报错。
func _test_ensnare_slows_and_dps() -> void:
	var sp := GameData.get_spell("ensnare")
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	var u := _put(w, "hydralisk", spot, World.ENEMY)
	var base_spd: float = u.speed()
	var base_cd: float = u.cooldown_time()
	w.cmd_ability([q], "ensnare", spot)
	var want_spd: float = base_spd * float(sp.get("slow_mult", 1.0))
	var want_cd: float = base_cd * float(sp.get("atk_cd_mult", 1.0))
	_report("诱捕网让移速减半",
		absf(u.speed() - want_spd) < 0.01,
		"%.1f → %.1f（期望 %.1f）" % [base_spd, u.speed(), want_spd])
	_report("★诱捕网同时让武器冷却 +25%（射速变慢）★",
		absf(u.cooldown_time() - want_cd) < 0.001,
		"%.3f → %.3f（期望 %.3f）" % [base_cd, u.cooldown_time(), want_cd])
	# 两个倍率必须**同时**来自同一条效果 —— 只挂一个字段的写法会让
	# 其中一个悄悄退回 1.0，而界面上两个效果环长得一模一样。
	_report("两个倍率都来自同一份效果（不是各挂一条）",
		u.effects.size() == 1
			and absf(u.slow_mult() - 0.5) < 0.001
			and absf(u.atk_cd_mult() - 1.25) < 0.001,
		"效果 %d 条，slow %.2f / atk_cd %.2f" % [u.effects.size(), u.slow_mult(),
			u.atk_cd_mult()])

## 诱捕网**不造成任何伤害**。
##
## 这条守着「误伤」的定义：它敌我不分，但代价只是「自己也慢了」。
## 一旦有人在 SPELLS 的 ensnare 上加一个 `dps`，它就变成「敌我不分且会打死自己人」，
## 而 AI 那边的判据是**按净收益**算的（允许牵连少量自己人）——
## 两者一叠加，AI 就会开始屠杀自己的部队。**不报错**。
func _test_ensnare_no_damage() -> void:
	var sp := GameData.get_spell("ensnare")
	_report("诱捕网的数据表里没有 dps（它不该有伤害）", not sp.has("dps"),
		"dps=%s" % str(sp.get("dps", "无")))
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	var foe := _put(w, "probe", spot + Vector2(-50, 0), World.ENEMY)
	var mate := _put(w, "probe", spot + Vector2(50, 0), World.PLAYER)
	var foe0: float = foe.hp + foe.shield
	var mate0: float = mate.hp + mate.shield
	w.cmd_ability([q], "ensnare", spot)
	_run(w, float(sp.get("duration", 25.0)))
	_report("整段时长内敌人一点血都没掉",
		absf(foe0 - (foe.hp + foe.shield)) < 0.001,
		"掉 %.3f" % (foe0 - (foe.hp + foe.shield)))
	_report("整段时长内自己人也一点血都没掉（误伤只是「也慢了」）",
		absf(mate0 - (mate.hp + mate.shield)) < 0.001,
		"掉 %.3f" % (mate0 - (mate.hp + mate.shield)))

func _test_ensnare_out_of_range() -> void:
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var reach := float(GameData.get_spell("ensnare").get("cast_range", 0.0))
	var far := _put(w, "probe", m + Vector2(reach + 200.0, 0), World.ENEMY)
	var e0: float = q.energy
	var ok_far := w.cmd_ability([q], "ensnare", m + Vector2(reach + 120.0, 0))
	# 施法失败**必须一个能量都不扣** —— 扣了的话，玩家点了远处一下，
	# 技能没放出去但能量没了，看起来像「能量凭空消失」。
	_report("超出施法距离放不出来（且不扣能量、不抓人）",
		(not ok_far) and absf(q.energy - e0) < 0.001 and (not far.has_effect("ensnare")),
		"返回 %s，能量 %.0f" % [str(ok_far), q.energy])
	var ok_near := w.cmd_ability([q], "ensnare", m + Vector2(reach - 40.0, 0))
	_report("距离内放得出来", ok_near, "")

func _test_ensnare_expires() -> void:
	var sp := GameData.get_spell("ensnare")
	var dur := float(sp.get("duration", 0.0))
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	# ⚠️ 靶子用**蝎子**（地面、零攻击力）而不是虫后 —— 这一条只该管「时长」，
	#    用空中靶子的话，「对空失效」这个无关缺陷也会把它打红，
	#    阳性对照里就分不清是哪一条规则破了。
	#    用零攻击力单位是为了不跑出战斗伤害（这一条要跑满 25 秒模拟）。
	var u := _put(w, "defiler", spot, World.ENEMY)
	w.cmd_ability([q], "ensnare", spot)
	_run(w, dur - 1.0)
	_report("时长内减速仍在（还没提前解除）",
		u.has_effect("ensnare") and absf(u.slow_mult() - 0.5) < 0.001,
		"剩 %.2f" % _remain_of(u, "ensnare"))
	_run(w, 2.0)
	_report("诱捕网在时长结束后解除，移速恢复正常",
		(not u.has_effect("ensnare")) and absf(u.slow_mult() - 1.0) < 0.001,
		"%s，slow_mult %.2f" % [_fx(u), u.slow_mult()])

## ★「减速对攻城模式也生效」★
##
## `Unit.cooldown_time()` 原来的写法是 `if mode == "sieged": return ...` —— **提前返回**。
## 把攻速倍率加在那个 return **之后**，代码看着像加上了，实际上永远轮不到，
## 而症状是「展开的攻城坦克完全不受诱捕网影响」—— 不报错、不崩，
## 甚至只看普通兵种的测试也全绿。所以必须专门测一次「展开状态」。
func _test_ensnare_sieged_tank() -> void:
	var w := _arena("zerg", "terran")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	var tank := _put(w, "siege_tank", spot, World.ENEMY)
	var base_n: float = tank.cooldown_time()
	w.cmd_ability([q], "ensnare", spot)
	var slow_n: float = tank.cooldown_time()
	_report("普通模式下诱捕网让武器冷却 +25%",
		absf(slow_n - base_n * 1.25) < 0.001, "%.3f → %.3f" % [base_n, slow_n])
	# 切到攻城模式：冷却换成 `siege` 技能表里的那个值，然后**同样**要吃倍率
	tank.set_mode("sieged")
	var slow_s: float = tank.cooldown_time()
	tank.clear_effects()
	var base_s: float = tank.cooldown_time()
	_report("展开确实换了另一套冷却（前提）", absf(base_s - base_n) > 0.001,
		"普通 %.3f / 展开 %.3f" % [base_n, base_s])
	_report("★攻城模式下诱捕网同样让冷却 +25%（倍率写在提前 return 之后会失效）★",
		absf(slow_s - base_s * 1.25) < 0.001, "展开 %.3f → %.3f" % [base_s, slow_s])

## 快照往返 + ★客户端从本地表重建效果参数★。
##
## 快照里只有「谁 + 哪一类 + 还剩多久」，`slow_mult` / `atk_cd_mult` **不传**。
## 客户端必须靠 `id` 去本地 `GameData.SPELLS` 重建 ——
## 漏掉的话客户端「看起来一点都没被减速」，而且**不报错**：
## 客户端不跑 `step()`，位置由快照纠正，连错位都看不出来。
func _test_snapshot_ensnare() -> void:
	var w := _arena("zerg", "zerg")
	var m := _mid(w)
	var q := _put(w, "queen", m, World.PLAYER)
	var spot := m + Vector2(120, 0)
	var u := _put(w, "hydralisk", spot, World.ENEMY)
	w.cmd_ability([q], "ensnare", spot)
	_report("快照测试场：诱捕网真的挂上了（前提）", u.has_effect("ensnare"), _fx(u))
	var b := World.new(64, 40, "zerg", "zerg", "easy")
	b.units.clear()
	b.buildings.clear()
	b.resources.clear()
	b.ai_enabled = false
	b.local_owner = World.ENEMY
	var bytes := Net.encode_snapshot(w, Net.Buf.new(), 7)
	var res := Net.apply_snapshot(b, bytes)
	var got: Unit = null
	for x in b.units:
		if x.type_id == "hydralisk":
			got = x
	_report("快照往返：减速效果原样还原",
		bool(res["ok"]) and got != null and got.has_effect("ensnare"),
		_fx(got) if got != null else "没有刺蛇")
	if got == null:
		_report("★客户端从本地表重建减速倍率与攻速倍率★", false, "单位没解出来")
		return
	_report("★客户端从本地法术表重建减速倍率与攻速倍率★",
		absf(got.slow_mult() - 0.5) < 0.001 and absf(got.atk_cd_mult() - 1.25) < 0.001,
		"slow %.2f / atk_cd %.2f" % [got.slow_mult(), got.atk_cd_mult()])
	# 解出来的单位真的会变慢 —— 上面两条是「参数对不对」，
	# 这一条是「参数有没有接到 speed() 上」。
	_report("客户端解出来的单位速度真的减半",
		absf(got.speed() - float(GameData.get_unit("hydralisk").get("speed", 0.0)) * 0.5) < 0.01,
		"%.1f" % got.speed())

## AI 的诱捕网落点判据：**净收益**（抓到的敌人 − 被牵连的自己人）≥ 2。
##
## ⚠️ 和心灵风暴的「零容忍」判据**故意不同**，理由见 `World._ai_ensnare_spot`。
##    这里要证明的是「它真的按净收益算」，而不是「它压根没跑」——
##    所以三条：该放的时候放、净收益不够的时候不放、自己人更多的时候不放。
func _test_ai_ensnare() -> void:
	# ① 敌人聚堆、自己人（虫后）在 120px 外 → 必须放
	var w := _arena("zerg", "terran")
	var m := _mid(w)
	_put(w, "queen", m, World.ENEMY)
	for i in range(4):
		_put(w, "marine", m + Vector2(170.0 + 12.0 * float(i), 0), World.PLAYER)
	w._rebuild_hash()
	w._ai_cast_spells()
	_report("AI 在敌人聚堆时会放诱捕网（阳性对照）",
		_any_effect(w, "ensnare") >= 2, "被抓 %d 个" % _any_effect(w, "ensnare"))

	# ② 只有一个敌人 → 不值得花 75 点能量
	var w2 := _arena("zerg", "terran")
	var m2 := _mid(w2)
	_put(w2, "queen", m2, World.ENEMY)
	_put(w2, "marine", m2 + Vector2(170, 0), World.PLAYER)
	w2._rebuild_hash()
	w2._ai_cast_spells()
	_report("AI 不会为了一个敌人浪费 75 点能量（门槛 %d）" % World.AI_ENSNARE_MIN_SCORE,
		_any_effect(w2, "ensnare") == 0, "被抓 %d 个" % _any_effect(w2, "ensnare"))

	# ③ 自己的兵比敌人多 → 净收益为负，不许放。
	#    ⚠️ 这一条是「净收益判据」和「零容忍判据」的分界线：
	#       换成心灵风暴的判据（自己人一个都不能在圈里）它也会过，
	#       所以必须再加一条「自己人**略少于**敌人时仍然放」（见 ①'）。
	var w3 := _arena("zerg", "terran")
	var m3 := _mid(w3)
	_put(w3, "queen", m3, World.ENEMY)
	for i in range(2):
		_put(w3, "marine", m3 + Vector2(160.0 + 12.0 * float(i), 0), World.PLAYER)
	for i in range(4):
		_put(w3, "marine", m3 + Vector2(160.0 + 12.0 * float(i), 40.0), World.ENEMY)
	w3._rebuild_hash()
	w3._ai_cast_spells()
	_report("★自己人比敌人多时 AI 不放（净收益为负）★",
		_any_effect(w3, "ensnare") == 0, "被抓 %d 个" % _any_effect(w3, "ensnare"))

	# ①' 关键对照：**圈里既有敌人又有自己人**，但敌人更多 → 仍然该放。
	#     这一条是「净收益」区别于「零容忍」的唯一证据 ——
	#     心灵风暴的判据在这里会拒绝施放，而诱捕网应该接受。
	var w4 := _arena("zerg", "terran")
	var m4 := _mid(w4)
	_put(w4, "queen", m4, World.ENEMY)
	for i in range(4):
		_put(w4, "marine", m4 + Vector2(170.0 + 12.0 * float(i), 0), World.PLAYER)
	_put(w4, "marine", m4 + Vector2(178.0, 14.0), World.ENEMY)
	w4._rebuild_hash()
	w4._ai_cast_spells()
	var hit_friend := false
	for u in w4.units:
		if u.owner_id == World.ENEMY and u.type_id == "marine" and u.has_effect("ensnare"):
			hit_friend = true
	_report("★圈里有一个自己人、但有四个敌人时 AI 仍然放（净收益判据，不是零容忍）★",
		_any_effect(w4, "ensnare") >= 3 and hit_friend,
		"被抓 %d 个（含自己人 %s）" % [_any_effect(w4, "ensnare"), str(hit_friend)])
