extends SceneTree

## 科技升级系统测试。
##
## 核心验证点：升级是**阵营级**的，不是单位级。
## 也就是说「先造出来的老兵」也必须吃到加成 —— 如果做成单位级
## （造兵时把当时的等级写进单位数据），老兵会永远停在旧数值。
## 这个错误在肉眼观察下极难发现，只有在部队混编时才会暴露成
## 「同样一队陆战队员，打出的伤害参差不齐」。

func _init() -> void:
	var passes: Array = []
	var fails: Array = []

	# ---- 1. 三族都有升级线
	for fac in ["terran", "zerg", "protoss"]:
		var ups: Array = GameData.upgrades_for_faction(fac)
		if ups.size() >= 3:
			passes.append("%s 升级线 %d 条" % [fac, ups.size()])
		else:
			fails.append("%s 升级线不足（%d 条）" % [fac, ups.size()])

	# ---- 2. 每个单位都归了类。漏一个，那个单位就永远吃不到攻防升级
	var unclassified := []
	for uid in GameData.UNITS:
		if not GameData.UPGRADE_CLASS.has(uid):
			unclassified.append(String(uid))
	if unclassified.is_empty():
		passes.append("全部 %d 个单位都有升级分类" % GameData.UNITS.size())
	else:
		fails.append("单位缺升级分类：" + ", ".join(unclassified))

	# ---- 3. 升级前置建筑存在且同族
	var bad_req := []
	for uid in GameData.UPGRADES:
		var up: Dictionary = GameData.UPGRADES[uid]
		var req := String(up.get("requires", ""))
		var bd := GameData.get_building(req)
		if bd.is_empty():
			bad_req.append("%s → 建筑 %s 不存在" % [uid, req])
		elif String(bd.get("faction", "")) != String(up.get("faction", "")):
			bad_req.append("%s 与 %s 不同族" % [uid, req])
	if bad_req.is_empty():
		passes.append("升级前置建筑全部有效且同族")
	else:
		fails.append("升级前置建筑异常：" + "; ".join(bad_req))

	# ---- 4. 等级表自洽：levels 条数 == max_level，造价递增
	var bad_lv := []
	for uid in GameData.UPGRADES:
		var up: Dictionary = GameData.UPGRADES[uid]
		var levels: Array = up.get("levels", [])
		var mx := int(up.get("max_level", 0))
		if levels.size() != mx:
			bad_lv.append("%s：levels %d ≠ max_level %d" % [uid, levels.size(), mx])
			continue
		var last := 0
		for lv in levels:
			var cm := int((lv as Dictionary).get("cost_m", 0))
			if cm < last:
				bad_lv.append("%s 造价非递增" % uid)
				break
			last = cm
	if bad_lv.is_empty():
		passes.append("升级等级表自洽（levels == max_level，造价递增）")
	else:
		fails.append("升级等级表异常：" + "; ".join(bad_lv))

	# ---- 5. 完整研究流程：建前置建筑 → 排队 → 出队结算 → 等级 +1
	var w := World.new(48, 32, "terran", "zerg", "easy")
	w.factions[World.PLAYER]["minerals"] = 6000.0
	w.factions[World.PLAYER]["gas"] = 6000.0
	var bay := w._place_building("engineering_bay", "terran",
		_free_spot(w, Vector2(-240, 170)), World.PLAYER, true)
	var lv0 := w.upgrade_level(World.PLAYER, "infantry_weapons")
	var queued := w.cmd_research(bay, "infantry_weapons")
	if queued:
		for i in range(4000):
			w.step(0.05)
			if w.upgrade_level(World.PLAYER, "infantry_weapons") > lv0:
				break
	var lv1 := w.upgrade_level(World.PLAYER, "infantry_weapons")
	if queued and lv1 == lv0 + 1:
		passes.append("研究流程走通（步兵武器 %d → %d 级）" % [lv0, lv1])
	else:
		fails.append("研究流程失败（queued=%s，等级 %d → %d）" % [str(queued), lv0, lv1])

	# ---- 6. ★关键★ 先造兵再升级，老兵也要吃到加成（阵营级而非单位级）
	var w2 := World.new(48, 32, "terran", "zerg", "easy")
	var cc = w2.buildings_of(World.PLAYER)[0]
	var veteran = w2._spawn_unit("marine", "terran", cc.pos + Vector2(80, 0), World.PLAYER)
	var before := w2._atk_bonus_for(veteran)
	# 直接写阵营升级表（等价于研究完成），老兵此时已经存在
	w2.factions[World.PLAYER]["upgrades"]["infantry_weapons"] = 3
	var after := w2._atk_bonus_for(veteran)
	# 新兵同样吃到，两者必须一致
	var rookie = w2._spawn_unit("marine", "terran", cc.pos + Vector2(120, 0), World.PLAYER)
	var rookie_bonus := w2._atk_bonus_for(rookie)
	if before == 0 and after == 3 and rookie_bonus == 3:
		passes.append("老兵吃到升级（%d → %d 级，新兵同样 %d）" % [before, after, rookie_bonus])
	else:
		fails.append("升级未作用到已存在的单位（老兵 %d→%d，新兵 %d）" % [before, after, rookie_bonus])

	# ---- 7. 升级只作用于匹配的分类（步兵升级不该buff坦克）
	var tank = w2._spawn_unit("siege_tank", "terran", cc.pos + Vector2(160, 0), World.PLAYER)
	var tank_bonus := w2._atk_bonus_for(tank)
	if tank_bonus == 0:
		passes.append("分类隔离正确（步兵武器不影响攻城坦克）")
	else:
		fails.append("分类隔离失效（坦克也吃到步兵武器 +%d）" % tank_bonus)

	# ---- 8. 攻击加成真的进入伤害公式
	var d0 := GameData.compute_damage(6.0, "normal", "light", 0, 0)
	var d3 := GameData.compute_damage(6.0, "normal", "light", 0, 3)
	if d3 > d0:
		passes.append("攻击加成进入公式（%.1f → %.1f）" % [d0, d3])
	else:
		fails.append("攻击加成未生效（%.1f → %.1f）" % [d0, d3])

	# ---- 9. 护甲加成真的进入伤害公式
	var a0 := GameData.compute_damage(20.0, "normal", "light", 0, 0, 0)
	var a2 := GameData.compute_damage(20.0, "normal", "light", 0, 0, 2)
	if a2 < a0:
		passes.append("护甲加成进入公式（%.1f → %.1f）" % [a0, a2])
	else:
		fails.append("护甲加成未生效（%.1f → %.1f）" % [a0, a2])

	# ---- 10. 先乘后减：加成不能颠倒顺序
	# 12 点普通伤害 ×1.0，目标护甲 2 → 应为 10
	var order := GameData.compute_damage(12.0, "normal", "light", 2, 0, 0)
	if absf(order - 10.0) < 0.01:
		passes.append("伤害公式保持「先乘后减」")
	else:
		fails.append("伤害公式顺序错误（12 打护甲 2 应为 10，实得 %.2f）" % order)

	# ---- 11. 护盾升级的匹配规则：**有护盾的单位**才吃，其余一律不吃。
	# 注意别凭印象写断言 —— 神族单位在 SC1 里是全员带护盾的（狂热者也有 60 点），
	# 所以这里对全部单位逐一比对，而不是挑两个举例。
	var shield_bad := []
	for un in GameData.UNITS:
		var has_shield := float(GameData.get_unit(un).get("shield", 0)) > 0.0
		var applies := GameData.upgrade_applies("plasma_shields", un)
		if has_shield != applies:
			shield_bad.append("%s(护盾%.0f 但匹配=%s)" % [un,
				float(GameData.get_unit(un).get("shield", 0)), str(applies)])
	if shield_bad.is_empty():
		var shielded := 0
		for un in GameData.UNITS:
			if float(GameData.get_unit(un).get("shield", 0)) > 0.0:
				shielded += 1
		passes.append("护盾升级只匹配有护盾单位（%d / %d 个）" % [shielded, GameData.UNITS.size()])
	else:
		fails.append("护盾升级匹配错误：" + ", ".join(shield_bad))

	# ---- 11b. 攻防升级不吃护盾单位以外的规则：护盾升级不该给攻击加成
	var w_sh := World.new(48, 32, "protoss", "zerg", "easy")
	var dra = w_sh._spawn_unit("dragoon", "protoss", Vector2(400, 400), World.PLAYER)
	var dmg_before := w_sh._atk_bonus_for(dra)
	w_sh.factions[World.PLAYER]["upgrades"]["plasma_shields"] = 3
	var dmg_after := w_sh._atk_bonus_for(dra)
	var sh_bonus := w_sh._defense_bonus(dra, "shield_armor")
	if dmg_before == 0 and dmg_after == 0 and sh_bonus == 3:
		passes.append("护盾升级只加护盾不减攻击（护盾 +%d，攻击 +%d）" % [sh_bonus, dmg_after])
	else:
		fails.append("护盾升级接线错误（攻击 %d→%d，护盾加成 %d）" % [dmg_before, dmg_after, sh_bonus])

	# ---- 12. 满级后不能再研究，next_upgrade_cost 返回空
	var w3 := World.new(48, 32, "zerg", "terran", "easy")
	w3.factions[World.PLAYER]["minerals"] = 9000.0
	w3.factions[World.PLAYER]["gas"] = 9000.0
	var cham := w3._place_building("evolution_chamber", "zerg",
		_free_spot(w3, Vector2(-240, 170)), World.PLAYER, true)
	w3.factions[World.PLAYER]["upgrades"]["melee_attacks"] = 3
	var capped := w3.next_upgrade_cost(World.PLAYER, "melee_attacks").is_empty() \
		and not w3.can_research(cham, "melee_attacks")
	if capped:
		passes.append("满级后无法继续研究")
	else:
		fails.append("满级仍可研究（造价表空=%s）" % str(w3.next_upgrade_cost(World.PLAYER, "melee_attacks").is_empty()))

	# ---- 13. 资源不足时排队失败，且不产生队列条目
	var w4 := World.new(48, 32, "terran", "zerg", "easy")
	var bay4 := w4._place_building("engineering_bay", "terran",
		_free_spot(w4, Vector2(-240, 170)), World.PLAYER, true)
	w4.factions[World.PLAYER]["minerals"] = 0.0
	w4.factions[World.PLAYER]["gas"] = 0.0
	var poor_ok := w4.cmd_research(bay4, "infantry_weapons")
	if not poor_ok and bay4.queue.is_empty():
		passes.append("资源不足时拒绝研究且不污染队列")
	else:
		fails.append("资源不足仍排入了研究（返回 %s，队列 %d 条）" % [str(poor_ok), bay4.queue.size()])

	# ---- 14. 前置建筑不在场 / 建筑不对时拒绝研究
	var w5 := World.new(48, 32, "protoss", "zerg", "easy")
	w5.factions[World.PLAYER]["minerals"] = 6000.0
	w5.factions[World.PLAYER]["gas"] = 6000.0
	var nexus = w5.buildings_of(World.PLAYER)[0]
	var wrong_building := w5.cmd_research(nexus, "ground_weapons")
	var forge := w5._place_building("forge", "protoss",
		_free_spot(w5, Vector2(-240, 170)), World.PLAYER, true)
	var right_building := w5.can_research(forge, "ground_weapons")
	# 熔炉不能研究人族的升级
	var cross_race := w5.can_research(forge, "infantry_weapons")
	if not wrong_building and right_building and not cross_race:
		passes.append("研究建筑校验正确（主基地拒绝 / 熔炉接受 / 拒绝跨族）")
	else:
		fails.append("研究建筑校验异常（主基地 %s，熔炉 %s，跨族 %s）" % [
			str(wrong_building), str(right_building), str(cross_race)])

	# ---- 15. 研究占用生产队列（SC1 的「一个建筑同时只做一件事」）
	var w6 := World.new(48, 32, "terran", "zerg", "easy")
	w6.factions[World.PLAYER]["minerals"] = 9000.0
	w6.factions[World.PLAYER]["gas"] = 9000.0
	var bay6 := w6._place_building("engineering_bay", "terran",
		_free_spot(w6, Vector2(-240, 170)), World.PLAYER, true)
	var q_ok := w6.cmd_research(bay6, "infantry_weapons")
	var q_kind := bay6.head_kind()
	# 队列填满后必须拒绝
	while bay6.queue.size() < Building.QUEUE_MAX:
		bay6.queue_item("upgrade", "infantry_armor", 10.0)
	var overflow := w6.cmd_research(bay6, "infantry_armor")
	if q_ok and q_kind == "upgrade" and not overflow:
		passes.append("研究占用队列且队列满时拒绝")
	else:
		fails.append("队列互斥异常（kind=%s，满队列仍接受=%s）" % [q_kind, str(overflow)])

	# ---- 16. 取消研究要退款
	var w7 := World.new(48, 32, "terran", "zerg", "easy")
	w7.factions[World.PLAYER]["minerals"] = 6000.0
	w7.factions[World.PLAYER]["gas"] = 6000.0
	var bay7 := w7._place_building("engineering_bay", "terran",
		_free_spot(w7, Vector2(-240, 170)), World.PLAYER, true)
	var m_before: float = w7.factions[World.PLAYER]["minerals"]
	w7.cmd_research(bay7, "infantry_weapons")
	var m_spent: float = w7.factions[World.PLAYER]["minerals"]
	var refunded := w7.cancel_queue(bay7, 0)
	var m_back: float = w7.factions[World.PLAYER]["minerals"]
	if refunded and m_spent < m_before and absf(m_back - m_before) < 0.5:
		passes.append("取消研究全额退款（%.0f → %.0f → %.0f）" % [m_before, m_spent, m_back])
	else:
		fails.append("取消研究退款异常（%.0f → %.0f → %.0f）" % [m_before, m_spent, m_back])

	# ---- 17. 升级不污染 GameData 的共享数据
	# data 是 GameData.UNITS 的共享字典，改它会污染所有同类型单位（含敌方）
	var marine_dmg := float(GameData.get_unit("marine").get("damage", 0))
	var w8 := World.new(48, 32, "terran", "zerg", "easy")
	var m8 = w8._spawn_unit("marine", "terran", Vector2(200, 200), World.PLAYER)
	w8.factions[World.PLAYER]["upgrades"]["infantry_weapons"] = 3
	var dealt := m8.attack_damage()
	var shared_after := float(GameData.get_unit("marine").get("damage", 0))
	if dealt == marine_dmg and shared_after == marine_dmg:
		passes.append("升级不污染共享单位数据（基础伤害恒为 %.0f）" % marine_dmg)
	else:
		fails.append("共享数据被污染（基础 %.0f → %.0f，单位 %.0f）" % [marine_dmg, shared_after, dealt])

	# ---- 18. 各族升级都能被该族的单位吃到（防「表里写了但匹配不上」）
	var coverage := []
	for fac in ["terran", "zerg", "protoss"]:
		var ups: Array = GameData.upgrades_for_faction(fac)
		for uid in ups:
			var eff := String(GameData.get_upgrade(uid).get("effect", ""))
			if eff == "unlock":
				continue
			var hit := false
			for un in GameData.UNITS:
				if String(GameData.get_unit(un).get("faction", "")) == fac \
						and GameData.upgrade_applies(uid, un):
					hit = true
					break
			if not hit:
				coverage.append(uid)
	if coverage.is_empty():
		passes.append("每条升级线都至少能作用到一个本单位")
	else:
		fails.append("升级线无适用单位：" + ", ".join(coverage))

	# ---- 汇总
	print("")
	print("=============== 科技升级测试结果 ===============")
	for p in passes:
		print("  [PASS] " + p)
	for f in fails:
		print("  [FAIL] " + f)
	print("-----------------------------------------------")
	print("  通过 %d / 失败 %d" % [passes.size(), fails.size()])
	print("===============================================")
	quit(0 if fails.is_empty() else 1)

## 在主基地旁边找一个安全的落点。直接 _place_building 绕过放置规则 ——
## 这里测的是研究逻辑，不是放置逻辑，不该被「水晶塔能量场」之类的东西干扰。
func _free_spot(w: World, offset: Vector2) -> Vector2:
	var base = w.buildings_of(World.PLAYER)[0]
	var p: Vector2 = base.pos + offset
	p.x = clampf(p.x, 70.0, w.world_size.x - 70.0)
	p.y = clampf(p.y, 70.0, w.world_size.y - 70.0)
	return p
