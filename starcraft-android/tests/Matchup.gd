extends SceneTree

## 兵种对位测试：用真实战斗结算验证「谁打得过谁」。
##
## 这些对位关系是平衡的地基。数值可以调，但定位不能乱——
## 神族必须能以一敌多（贵、慢、但强），虫族必须单挑吃亏（便宜、快、量取胜），
## 人族夹在中间靠射程和人口效率吃饭。改数值后如果这里红了，说明定位被改坏了。

var _pass := 0
var _fail := 0
var _maxed := false

func _init() -> void:
	# 固定种子：地图生成与单位散开都吃全局 RNG。不固定的话这一套虽然一直能过，
	# 但一旦某个对位本来就在胜负边缘，就会变成偶发失败。
	seed(20260922)
	print("\n=============== 兵种对位测试 ===============")
	# 同一批对位跑两遍：0 级 和 双方所有升级线拉满。
	# 第二轮是第七轮加的 —— 升级会改变有效攻防，而「满级后兵种定位还在不在」
	# 在此之前完全没有数据。实测两轮结果一致（只有残兵数微调），
	# 也就是说升级是**同向**增强，没有把任何一对关系打反。
	for maxed in [false, true]:
		_maxed = maxed
		print("\n--- %s ---" % ("满级攻防（双方升级线全拉满）" if maxed else "0 级（基线）"))
		_duels()
	# ---- 指令语义 ----
	_test_distant_attack_order()
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	# ⚠️ 必须把失败带进退出码。原本写死 quit(0)，于是「兵种定位被打反」
	#    在 run_all.sh 里照样报全绿 —— 这套测试的全部意义就在这条 rc 上。
	quit(0 if _fail == 0 else 1)

func _duels() -> void:
	# ---- 神族：高价值单位必须能以一敌多 ----
	_duel("1 狂热者  vs  4 跳虫", "protoss", ["zealot"], "zerg", _n("zergling", 4), true)
	_duel("1 狂热者  vs  2 陆战队员", "protoss", ["zealot"], "terran", _n("marine", 2), true)
	_duel("2 狂热者  vs  4 陆战队员", "protoss", _n("zealot", 2), "terran", _n("marine", 4), true)
	_duel("1 龙骑士  vs  2 陆战队员", "protoss", ["dragoon"], "terran", _n("marine", 2), true)
	_duel("1 执政官  vs  5 陆战队员", "protoss", ["archon"], "terran", _n("marine", 5), true)
	# ---- 人族：靠射程与人口效率，单挑占优 ----
	_duel("1 陆战队员  vs  1 跳虫", "terran", ["marine"], "zerg", ["zergling"], true)
	_duel("1 陆战队员  vs  1 狂热者", "terran", ["marine"], "protoss", ["zealot"], false)
	# ---- 虫族：便宜量大，单挑吃亏，靠数量淹 ----
	_duel("2 跳虫  vs  1 陆战队员", "zerg", _n("zergling", 2), "terran", ["marine"], true)
	_duel("4 跳虫  vs  1 狂热者", "zerg", _n("zergling", 4), "protoss", ["zealot"], false)
	_duel("6 跳虫  vs  1 狂热者", "zerg", _n("zergling", 6), "protoss", ["zealot"], true)
	# ---- 跨族对位：龙骑士应该打得过刺蛇（同价位的远程兵）----
	_duel("1 龙骑士  vs  1 刺蛇", "protoss", ["dragoon"], "zerg", ["hydralisk"], true)

func _n(id: String, count: int) -> Array:
	var a := []
	for i in range(count):
		a.append(id)
	return a

## 玩家点名攻击远处目标时，单位必须一路追过去。
## 早期版本会因为「目标距离 > 射程 + 140」直接放弃目标，
## 于是右键点远处的敌人毫无反应，部队带着攻击指令原地站桩。
func _test_distant_attack_order() -> void:
	var w := World.new(64, 40, "terran", "zerg", "normal")
	w.game_ended = true
	var center: Vector2 = w.world_size * 0.5
	var attacker := w._spawn_unit("marine", "terran", center + Vector2(-600, 0), World.PLAYER)
	var victim := w._spawn_unit("zergling", "zerg", center + Vector2(600, 0), World.ENEMY)
	w.cmd_attack([attacker], victim)
	var start: float = attacker.pos.distance_to(victim.pos)
	for i in range(int(90.0 / 0.05)):
		w.step(0.05)
		if not victim.alive():
			break
	var ok: bool = not victim.alive()
	var note := "起始相距 %.0f 像素 → " % start
	note += "已追上并击杀" if ok else "目标仍存活（当前相距 %.0f）" % attacker.pos.distance_to(victim.pos)
	_report("点名攻击远处的敌人（须跨半张地图追击）", ok, note)

## 把两队单位摆在地图中央对砍，验证哪边活下来。
## a_should_win 是期望结果；打不完（双方都活着）也算失败——那说明伤害输出不够。
func _duel(label: String, a_race: String, a_units: Array, b_race: String, b_units: Array, a_should_win: bool) -> void:
	var w := World.new(64, 40, a_race, b_race, "normal")
	w.game_ended = true            # 关掉 AI 与胜负结算，只留纯战斗
	if _maxed:
		# 双方升级线全拉满。注意神族拿到的是「地面护甲 +3 且等离子护盾 +3」两条线，
		# 比另外两族多一层 —— 这一点和 SC1 一致，但量级需要单独验证。
		_max_out(w, World.PLAYER, a_race)
		_max_out(w, World.ENEMY, b_race)
	var center: Vector2 = w.world_size * 0.5
	var side_a := []
	var side_b := []
	for i in range(a_units.size()):
		side_a.append(w._spawn_unit(String(a_units[i]), a_race,
			center + Vector2(-170.0, (float(i) - float(a_units.size()) * 0.5) * 34.0), World.PLAYER))
	for i in range(b_units.size()):
		side_b.append(w._spawn_unit(String(b_units[i]), b_race,
			center + Vector2(170.0, (float(i) - float(b_units.size()) * 0.5) * 34.0), World.ENEMY))
	for u in side_a:
		w.cmd_attack([u], side_b[0])
	for u in side_b:
		w.cmd_attack([u], side_a[0])

	var a_left := 0
	var b_left := 0
	for step in range(int(120.0 / 0.05)):
		w.step(0.05)
		a_left = _count_alive(side_a)
		b_left = _count_alive(side_b)
		if a_left == 0 or b_left == 0:
			break

	var a_won: bool = a_left > 0 and b_left == 0
	var b_won: bool = b_left > 0 and a_left == 0
	var ok: bool = (a_won == a_should_win) and (a_won or b_won)
	var note := ""
	if not (a_won or b_won):
		note = "（超时未分胜负）"
	elif ok:
		note = "（A 剩 %d，B 剩 %d）" % [a_left, b_left]
	else:
		note = "（A 剩 %d，B 剩 %d）" % [a_left, b_left]
	if ok:
		_pass += 1
		print("  [PASS] %s%s  → %s 胜 %s" % [label, _tag(), "A" if a_won else "B", note])
	else:
		_fail += 1
		print("  [FAIL] %s%s  → 期望 %s 胜，实际 %s 胜 %s" % [
			label, _tag(), "A" if a_should_win else "B", "A" if a_won else ("B" if b_won else "无人"), note])

func _tag() -> String:
	return "  [满级]" if _maxed else ""

## 把该族所有升级线拉满
func _max_out(w: World, owner: int, race: String) -> void:
	var d: Dictionary = w.factions[owner]["upgrades"]
	for uid in GameData.upgrades_for_faction(race):
		d[uid] = int(GameData.get_upgrade(uid).get("max_level", 0))

func _count_alive(arr: Array) -> int:
	var n := 0
	for u in arr:
		if u.alive():
			n += 1
	return n

func _report(label: String, ok: bool, note: String) -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s  → %s" % [label, note])
	else:
		_fail += 1
		print("  [FAIL] %s  → %s" % [label, note])
