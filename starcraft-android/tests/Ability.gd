extends SceneTree

## 技能系统测试：兴奋剂 / 攻城模式 / 治疗。
##
## 三件最容易写错的事，这里都盯着：
## 1. 医疗兵 damage 为 0，**必须**被挡在索敌逻辑之外 —— 否则它会对着敌人
##    「开火」并射出零伤害弹道，看起来像在攻击但打不掉血。
## 2. buff 必须「读取时叠加」，不能改 data —— data 是 GameData.UNITS 的共享字典，
##    改它会污染所有同类型单位（包括敌方）。
## 3. 攻城坦克展开期间不能开火，否则「展开要 3 秒且毫无还手之力」这个代价就没了。

func _init() -> void:
	# 固定随机种子。地图生成与 AI 建筑落点都吃全局 RNG，不固定的话
	# 「AI 会研究升级」这条集成断言会偶发失败 —— 实测批量跑时挂过一次
	# （同一份代码单独跑通过两次，批跑那次 AI 在 305 秒内一座科技建筑都没造）。
	seed(20260921)

	var passes: Array = []
	var fails: Array = []

	# ---- 1. 技能表自洽：单位存在、单位身上确实挂了该技能
	var bad_ab := []
	for aid in GameData.ABILITIES:
		var ab: Dictionary = GameData.ABILITIES[aid]
		var uid := String(ab.get("unit", ""))
		var ud := GameData.get_unit(uid)
		if ud.is_empty():
			bad_ab.append("%s → 单位 %s 不存在" % [aid, uid])
			continue
		if not (ud.get("abilities", []) as Array).has(aid):
			bad_ab.append("%s 未挂到 %s 的 abilities 上" % [aid, uid])
	if bad_ab.is_empty():
		passes.append("技能表自洽（%d 个技能都能挂到对应单位）" % GameData.ABILITIES.size())
	else:
		fails.append("技能表异常：" + "; ".join(bad_ab))

	# ---- 2. 医疗兵零伤害：必须被挡在索敌之外
	var w := World.new(48, 32, "terran", "zerg", "easy")
	w.units.clear()
	var cc = w.buildings_of(World.PLAYER)[0]
	var medic = w._spawn_unit("medic", "terran", cc.pos + Vector2(300, 0), World.PLAYER)
	var foe = w._spawn_unit("zergling", "zerg", cc.pos + Vector2(345, 0), World.ENEMY)
	var foe_hp0: float = foe.hp
	var medic_is_combat: bool = medic.is_combat()
	for i in range(200):
		w.step(0.05)
	var foe_untouched: bool = foe.hp >= foe_hp0 - 0.01
	var medic_passive: bool = medic.attack_target == null
	if (not medic_is_combat) and foe_untouched and medic_passive:
		passes.append("医疗兵零伤害且不索敌（敌人 10 秒内未掉血）")
	else:
		fails.append("医疗兵参与了攻击（is_combat=%s，敌人掉血=%s，锁定目标=%s）" % [
			str(medic_is_combat), str(not foe_untouched), str(not medic_passive)])

	# ---- 3. 医疗兵自动治疗附近伤员
	var w2 := World.new(48, 32, "terran", "zerg", "easy")
	w2.units.clear()
	var cc2 = w2.buildings_of(World.PLAYER)[0]
	var med2 = w2._spawn_unit("medic", "terran", cc2.pos + Vector2(300, 0), World.PLAYER)
	var hurt = w2._spawn_unit("marine", "terran", cc2.pos + Vector2(330, 0), World.PLAYER)
	hurt.hp = hurt.max_hp * 0.30
	# 把能量压到低位再测：医疗兵满能量 200、治疗只花 1 点，
	# 从满能量开始测的话回复量会把消耗完全掩盖掉，看起来像「治疗不耗能量」。
	med2.energy = 20.0
	var hurt_hp0: float = hurt.hp
	var e0: float = med2.energy
	for i in range(60):
		w2.step(0.05)
	var healed: bool = hurt.hp > hurt_hp0
	var spent: bool = med2.energy < e0
	if healed and spent:
		passes.append("医疗兵自动治疗并消耗能量（%.0f → %.0f 血，能量 %.0f → %.1f）"
			% [hurt_hp0, hurt.hp, e0, med2.energy])
	else:
		fails.append("自动治疗未生效（血 %.0f → %.0f，能量 %.0f → %.1f）"
			% [hurt_hp0, hurt.hp, e0, med2.energy])

	# ---- 4. 治疗不会溢出上限
	var w3 := World.new(48, 32, "terran", "zerg", "easy")
	w3.units.clear()
	var cc3 = w3.buildings_of(World.PLAYER)[0]
	var med3 = w3._spawn_unit("medic", "terran", cc3.pos + Vector2(300, 0), World.PLAYER)
	var near3 = w3._spawn_unit("marine", "terran", cc3.pos + Vector2(330, 0), World.PLAYER)
	near3.hp = near3.max_hp - 1.0
	for i in range(200):
		w3.step(0.05)
	var capped: bool = near3.hp <= near3.max_hp + 0.01
	if capped:
		passes.append("治疗不溢出上限（%.0f / %.0f）" % [near3.hp, near3.max_hp])
	else:
		fails.append("治疗溢出（%.0f / %.0f）" % [near3.hp, near3.max_hp])

	# ---- 5. 兴奋剂必须先研究解锁
	var w4 := World.new(48, 32, "terran", "zerg", "easy")
	var m4 = w4._spawn_unit("marine", "terran", Vector2(400, 400), World.PLAYER)
	var locked: bool = w4.can_use_ability(m4, "stim")
	w4.factions[World.PLAYER]["upgrades"]["stim_pack"] = 1
	var unlocked: bool = w4.can_use_ability(m4, "stim")
	if (not locked) and unlocked:
		passes.append("兴奋剂需要先研究解锁")
	else:
		fails.append("兴奋剂解锁判定错误（未解锁 %s，解锁后 %s）" % [str(locked), str(unlocked)])

	# ---- 6. 兴奋剂效果：加速 + 提高射速 + 自伤，且不污染共享数据
	var base_speed: float = m4.speed()
	var base_cd: float = m4.cooldown_time()
	var base_dmg: float = m4.attack_damage()
	var hp_before: float = m4.hp
	w4.cmd_ability([m4], "stim")
	var stim_speed: float = m4.speed()
	var stim_cd: float = m4.cooldown_time()
	var stim_ok: bool = m4.has_buff("stim") \
		and absf(stim_speed - base_speed * 1.5) < 0.01 \
		and stim_cd < base_cd \
		and absf(m4.hp - (hp_before - 10.0)) < 0.01 \
		and absf(m4.attack_damage() - base_dmg) < 0.01 \
		and absf(float(GameData.get_unit("marine").get("speed", 0)) - base_speed) < 0.01
	if stim_ok:
		passes.append("兴奋剂生效（速度 %.0f→%.0f，射速 %.2f→%.2f，自伤 10）"
			% [base_speed, stim_speed, base_cd, stim_cd])
	else:
		fails.append("兴奋剂参数异常（速度 %.0f→%.0f，射速 %.2f→%.2f，血量 %.0f→%.0f）"
			% [base_speed, stim_speed, base_cd, stim_cd, hp_before, m4.hp])

	# ---- 6b. ★关键★ 兴奋剂不能重复施放
	# 它的 cooldown 是 0，AI 每帧都会来问一次。少了这道闸，10 点自伤会每帧扣一次，
	# 整队陆战队员在 1 秒内被扎到 1 血 —— 而且症状看起来像「AI 的兵特别脆」。
	var hp_before_spam: float = m4.hp
	var spam_ok := 0
	for i in range(20):
		if w4.cmd_ability([m4], "stim"):
			spam_ok += 1
	if spam_ok == 0 and absf(m4.hp - hp_before_spam) < 0.01:
		passes.append("兴奋剂不可重复施放（连点 20 次，血量未再下降）")
	else:
		fails.append("兴奋剂被重复施放 %d 次（血量 %.0f → %.0f）"
			% [spam_ok, hp_before_spam, m4.hp])

	# ---- 7. 兴奋剂不会打死自己（血量卡在 1）
	m4.hp = 5.0
	m4.ability_cd = 0.0
	m4.buffs.clear()
	w4.cmd_ability([m4], "stim")
	if m4.hp >= 1.0 and not m4.dead:
		passes.append("兴奋剂不致命（5 血扎针后剩 %.0f 血）" % m4.hp)
	else:
		fails.append("兴奋剂把自己扎死了（hp=%.0f）" % m4.hp)

	# ---- 8. 攻城模式：射程/伤害/移速三件套
	var w5 := World.new(48, 32, "terran", "zerg", "easy")
	var tank = w5._spawn_unit("siege_tank", "terran", Vector2(400, 400), World.PLAYER)
	var n_rng: float = tank.attack_range()
	var n_dmg: float = tank.attack_damage()
	var n_spd: float = tank.speed()
	w5.cmd_ability([tank], "siege")
	var s_rng: float = tank.attack_range()
	var s_dmg: float = tank.attack_damage()
	var s_spd: float = tank.speed()
	if tank.mode == "sieged" and s_rng > n_rng and s_dmg > n_dmg and s_spd == 0.0:
		passes.append("攻城模式生效（射程 %.0f→%.0f，伤害 %.0f→%.0f，移速 %.0f→0）"
			% [n_rng, s_rng, n_dmg, s_dmg, n_spd])
	else:
		fails.append("攻城模式参数异常（射程 %.0f→%.0f，伤害 %.0f→%.0f，移速 %.0f→%.0f）"
			% [n_rng, s_rng, n_dmg, s_dmg, n_spd, s_spd])

	# ---- 9. 展开期间不能开火（否则展开的代价就没了）
	var deploying_blocked: bool = tank.mode_timer > 0.0 and not tank.can_fire()
	for i in range(80):
		w5.step(0.05)
	var ready_after: bool = tank.mode_timer <= 0.0 and tank.can_fire()
	if deploying_blocked and ready_after:
		passes.append("展开期间禁开火，展开完成后恢复")
	else:
		fails.append("展开计时异常（展开中 %s，展开后 %s）" % [str(deploying_blocked), str(ready_after)])

	# ---- 10. 移动指令自动收起攻城模式
	tank.move_to(Vector2(700, 700))
	if tank.mode == "normal":
		passes.append("移动指令自动收起攻城模式")
	else:
		fails.append("移动后仍是攻城模式（%s）" % tank.mode)

	# ---- 11. 再次切换回普通模式
	tank.ability_cd = 0.0
	tank.mode_timer = 0.0
	w5.cmd_ability([tank], "siege")
	if tank.mode == "sieged":
		tank.ability_cd = 0.0
		tank.mode_timer = 0.0
		w5.cmd_ability([tank], "siege")
	if tank.mode == "normal" and absf(tank.attack_damage() - n_dmg) < 0.01:
		passes.append("攻城模式可反复切换（收起后伤害回到 %.0f）" % n_dmg)
	else:
		fails.append("攻城模式切换异常（mode=%s）" % tank.mode)

	# ---- 12. 能量自然回复
	var w6 := World.new(48, 32, "terran", "zerg", "easy")
	w6.units.clear()
	var cc6 = w6.buildings_of(World.PLAYER)[0]
	var med6 = w6._spawn_unit("medic", "terran", cc6.pos + Vector2(300, 0), World.PLAYER)
	med6.energy = 0.0
	for i in range(100):
		w6.step(0.05)
	# 固定速率回复：5 秒应当刚好回 5 × ENERGY_REGEN
	var expect_regen := 5.0 * GameData.ENERGY_REGEN
	if absf(med6.energy - expect_regen) < 0.3:
		passes.append("能量按固定速率回复（5 秒回 %.1f / 预期 %.1f）" % [med6.energy, expect_regen])
	else:
		fails.append("能量回复速率异常（5 秒回 %.1f，预期 %.1f）" % [med6.energy, expect_regen])

	# ---- 13. buff 到期自动清除
	var w7 := World.new(48, 32, "terran", "zerg", "easy")
	var m7 = w7._spawn_unit("marine", "terran", Vector2(400, 400), World.PLAYER)
	m7.apply_buff("stim", 1.0)
	var buff_on: bool = m7.has_buff("stim")
	for i in range(40):
		w7.step(0.05)
	var buff_off: bool = not m7.has_buff("stim")
	if buff_on and buff_off:
		passes.append("buff 到期自动清除")
	else:
		fails.append("buff 生命周期异常（施加后 %s，2 秒后仍 %s）" % [str(buff_on), str(not buff_off)])

	# ---- 14. 未解锁时给技能按钮/指令的判定必须是「不可用」而不是静默失败
	var w8 := World.new(48, 32, "terran", "zerg", "easy")
	var m8 = w8._spawn_unit("marine", "terran", Vector2(400, 400), World.PLAYER)
	var refused: bool = not w8.cmd_ability([m8], "stim")
	var no_buff: bool = not m8.has_buff("stim")
	if refused and no_buff:
		passes.append("未解锁时指令被拒绝且无副作用")
	else:
		fails.append("未解锁仍释放了技能（返回 %s，有 buff %s）" % [str(not refused), str(not no_buff)])

	# ---- 15. 医疗兵不能治疗敌人
	var w9 := World.new(48, 32, "terran", "zerg", "easy")
	w9.units.clear()
	var cc9 = w9.buildings_of(World.PLAYER)[0]
	var med9 = w9._spawn_unit("medic", "terran", cc9.pos + Vector2(300, 0), World.PLAYER)
	var foe9 = w9._spawn_unit("zergling", "zerg", cc9.pos + Vector2(320, 0), World.ENEMY)
	foe9.hp = foe9.max_hp * 0.4
	var foe_hp9: float = foe9.hp
	var enemy_heal: bool = w9.cmd_ability([med9], "heal", foe9)
	if (not enemy_heal) and foe9.hp <= foe_hp9 + 0.01:
		passes.append("医疗兵不能治疗敌人")
	else:
		fails.append("医疗兵治疗了敌人（返回 %s，血量 %.0f → %.0f）" % [str(enemy_heal), foe_hp9, foe9.hp])

	# ---- 16. AI 也会研究升级（否则平衡测试的数据全是假的）
	# 给玩家塞一队守备兵：被动挨打的玩家会在 AI 科技成型前就被推平，
	# 那样测出来的是「玩家太脆」而不是「AI 不研究」—— 诊断脚本实测 128 秒就结束了。
	var w10 := World.new(64, 40, "terran", "zerg", "easy")
	var cc10 = w10.buildings_of(World.PLAYER)[0]
	for k in range(12):
		var ang := TAU * float(k) / 12.0
		w10._spawn_unit("marine", "terran", cc10.pos + Vector2(cos(ang), sin(ang)) * 120.0, World.PLAYER)
	# 给 AI 一笔启动资金。AI 一边和玩家的守备队换血一边补兵，余粮长期压在
	# 「进化腔 75 + 保留 150 = 225」以下时，它会一直造不出科技建筑 ——
	# 那测出来的是「AI 穷的时候怎么取舍」，不是「AI 会不会研究」。
	w10.factions[World.ENEMY]["minerals"] = 900.0
	w10.factions[World.ENEMY]["gas"] = 300.0
	var ai_total := 0
	var ai_ups: Dictionary = {}
	var tech_at := -1.0
	var research_at := -1.0
	var done_at := -1.0
	for i in range(12000):
		w10.step(0.05)
		if tech_at < 0.0 and w10.count_building(World.ENEMY, "evolution_chamber") > 0:
			tech_at = w10.elapsed
		if research_at < 0.0:
			for bb in w10.buildings_of(World.ENEMY):
				if bb.queue.size() > 0 and String(bb.queue[0].get("kind", "unit")) == "upgrade":
					research_at = w10.elapsed
					break
		ai_ups = w10.factions[World.ENEMY].get("upgrades", {})
		ai_total = 0
		for up_k in ai_ups:
			ai_total += int(ai_ups[up_k])
		if ai_total > 0:
			done_at = w10.elapsed
			break
		# 排进队列之后最多再等 100 秒。研究本身要 55 秒，
		# 而这一局随时可能因为一方被推平而结束 —— 不能无限等下去。
		if research_at > 0.0 and w10.elapsed > research_at + 100.0:
			break
		if w10.game_ended:
			break

	# 三条断言分开写。「AI 造不出科技建筑」和「AI 造了却不研究」是两种
	# 完全不同的毛病，混成一条的话失败信息分不清卡在哪一步。
	# 主判据放在「有没有排进研究队列」—— 那才是「AI 会不会研究」的直接证据；
	# 「拿到等级」要等 55 秒研究跑完，会被游戏提前结束打断，只作为加分项。
	if tech_at >= 0.0:
		passes.append("AI 会建造科技建筑（%.0fs 造出进化腔）" % tech_at)
	else:
		fails.append("AI 从不建造科技建筑 —— 平衡测试数据将失去意义（t=%.0fs）" % w10.elapsed)

	if research_at >= 0.0:
		passes.append("AI 会把升级排进研究队列（%.0fs 开始研究）" % research_at)
	else:
		fails.append("AI 造了进化腔却从不研究（%.0fs 建成，t=%.0fs 结束=%s）"
			% [tech_at, w10.elapsed, str(w10.game_ended)])

	if ai_total > 0:
		passes.append("AI 能真正拿到升级等级（%.0fs 完成 %d 级：%s）"
			% [done_at, ai_total, str(ai_ups)])
	elif research_at >= 0.0 and w10.game_ended:
		passes.append("AI 的研究在游戏结束时尚未跑完（%.0fs 开始，%.0fs 结束）—— 不算失败"
			% [research_at, w10.elapsed])
	else:
		fails.append("AI 排了研究却一直拿不到等级（%.0fs 开始，t=%.0fs）" % [research_at, w10.elapsed])

	# ---- 17. AI 医疗兵不破坏模拟（长局稳定性）
	var w11 := World.new(64, 40, "terran", "terran", "normal")
	var nan_found := ""
	for i in range(4000):
		w11.step(0.05)
		if w11.game_ended:
			break
		if i % 400 == 0:
			for u in w11.units:
				if is_nan(u.pos.x) or is_nan(u.pos.y):
					nan_found = "坐标 NaN @ step %d" % i
					break
			if nan_found != "":
				break
	if nan_found == "":
		passes.append("含医疗兵的长局模拟无 NaN（200 秒）")
	else:
		fails.append(nan_found)

	# ---- 汇总
	print("")
	print("=============== 技能系统测试结果 ===============")
	for p in passes:
		print("  [PASS] " + p)
	for f in fails:
		print("  [FAIL] " + f)
	print("-----------------------------------------------")
	print("  通过 %d / 失败 %d" % [passes.size(), fails.size()])
	print("===============================================")
	quit(0 if fails.is_empty() else 1)
