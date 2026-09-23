extends SceneTree

## 建造系统测试。
##
## 核心是锁死一个真实 bug：**放一个建筑会把整队农民都拉过来。**
##
## 根因是「判断要不要补人」用了「工地旁边站了几个农民」这个量 ——
## 而正在赶路的那个农民位置不在旁边，于是判据恒为 0，
## 每 0.5 秒重复派工，直到第一个走到为止。工地离基地 800px 时最多能派到 16 个。
##
## 这个 bug 之所以能活到现在，是因为现有 6 套测试里
## **没有任何一项断言过「建造者的数量」**。这个文件就是来补这一项的。

const WORKER := "scv"
const CHEAP := "supply_depot"      # build_time 15s，小型 → 自动只派 1 人
const BIG := "barracks"            # build_time 26s，大型 → AI 自动派 2 人

var _pass := 0
var _fail := 0

func _init() -> void:
	# 固定种子：地图生成与建筑落点都吃全局 RNG
	seed(20260922)
	print("\n=============== 建造系统测试 ===============")
	_test_single_builder()
	_test_builder_count_stable()
	_test_explicit_workers()
	_test_auto_pick_nearest()
	_test_refill_when_lost()
	_test_build_speed()
	_test_release_on_complete()
	_test_arrival_not_distance()
	_test_no_stealing()
	_test_descriptions()
	_test_ai_builder_count()
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

# ================================================================ 测试场

## 一个干净的测试场：清空所有单位，在基地旁摆 n 个农民，关掉 AI。
## 返回 [world, 主基地, 农民数组]
func _arena(n_workers: int) -> Array:
	var w := World.new(64, 40, "terran", "zerg", "easy")
	w.units.clear()
	w.game_ended = true                     # 关掉 AI 与胜负结算，只测建造
	w.factions[World.PLAYER]["minerals"] = 9000.0
	w.factions[World.PLAYER]["gas"] = 9000.0
	var base = w.buildings_of(World.PLAYER)[0]
	var crew := []
	for i in range(n_workers):
		crew.append(w._spawn_unit(WORKER, "terran",
			base.pos + Vector2(-40.0 + float(i % 6) * 16.0, 120.0 + float(i / 6) * 16.0),
			World.PLAYER))
	return [w, base, crew]

## 找一个能放下 CHEAP 的点。
## ⚠️ `can_place_building` 有一条「**必须建在己方建筑 190px 以内**」的建造半径约束，
## 所以这里只能在基地周边 100~185px 的环带里找 —— 不能随便丢到半张地图外。
func _far_spot(w: World, base, dist: float) -> Vector2:
	for ring in range(5):
		var d := dist + float(ring) * 15.0
		for ang in range(0, 360, 8):
			var a := deg_to_rad(float(ang))
			var p: Vector2 = base.pos + Vector2(cos(a), sin(a)) * d
			if w.can_place_building(CHEAP, p, World.PLAYER)["ok"]:
				return p
	return Vector2.ZERO

## 把农民停到离工地 dist 像素远的地方（方向 = 工地背离基地的那一侧）。
##
## 这一步是测试的关键：工地本身受 190px 建造半径限制，离基地不可能太远，
## 但**农民通常在更远的矿点上采矿**。把农民停远，才能复现
## 「第一个农民还在路上 → 判据为 0 → 每 0.5 秒再派一个」的重复派工。
## 不这么做的话步行只要一两秒，bug 也会被掩盖成「多派了 2 个」。
func _park_crew(w: World, crew: Array, site: Vector2, base, dist: float) -> void:
	var away: Vector2 = site - base.pos
	if away.length() < 1.0:
		away = Vector2(0, 1)
	away = away.normalized()
	for i in range(crew.size()):
		var p: Vector2 = site + away * dist + Vector2(float(i % 6) * 15.0, float(i / 6) * 15.0)
		p = p.clamp(Vector2(40.0, 40.0), w.world_size - Vector2(40.0, 40.0))
		crew[i].pos = w.grid.nearest_free_world(p)

func _newest(w: World):
	var b = null
	for x in w.buildings:
		b = x
	return b

## 被指派到这个工地的农民数（含在路上）
func _assigned(w: World, b) -> int:
	var n := 0
	for u in w.units:
		if not u.dead and u.build_target == b:
			n += 1
	return n

func _report(label: String, ok: bool, note: String) -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s  %s" % [label, note])
	else:
		_fail += 1
		print("  [FAIL] %s  %s" % [label, note])

# ================================================================ 用例

## ★核心★ 一个工地只派一个农民。
## 修复前这里会数到十几个 —— 农民停得越远越夸张。
func _test_single_builder() -> void:
	var a := _arena(12)
	var w: World = a[0]
	var base = a[1]
	var crew: Array = a[2]
	var pos := _far_spot(w, base, 170.0)
	if pos == Vector2.ZERO:
		_report("一个工地只派一个农民", false, "（找不到可放置点）")
		return
	_park_crew(w, crew, pos, base, 430.0)
	var walk: float = crew[0].pos.distance_to(pos)
	w.cmd_build(CHEAP, pos, World.PLAYER)
	var b = _newest(w)
	var at_place := _assigned(w, b)
	# 跑 3 秒 —— 派工间隔 0.5 秒，足够触发 6 次重复派工
	for i in range(60):
		w.step(0.05)
	var after := _assigned(w, b)
	_report("一个工地只派一个农民", at_place == 1 and after == 1,
		"（农民步行 %.0f px：放下时 %d 个 → 3 秒后 %d 个）" % [walk, at_place, after])

## 全程稳定：跑满建造周期，建造者数量始终恰好 1
func _test_builder_count_stable() -> void:
	var a := _arena(12)
	var w: World = a[0]
	var crew: Array = a[2]
	var pos := _far_spot(w, a[1], 170.0)
	_park_crew(w, crew, pos, a[1], 380.0)
	w.cmd_build(CHEAP, pos, World.PLAYER)
	var b = _newest(w)
	var peak := 0
	var samples := 0
	for i in range(400):
		w.step(0.05)
		if b.complete:
			break
		peak = maxi(peak, _assigned(w, b))
		samples += 1
	_report("建造全程建造者数量始终为 1", peak == 1,
		"（采样 %d 次，峰值 %d 个）" % [samples, peak])

## 玩家选中了农民 → 派这些（选几个就几个去，星际 1 的行为）
func _test_explicit_workers() -> void:
	var a := _arena(12)
	var w: World = a[0]
	var crew: Array = a[2]
	var three := [crew[0], crew[3], crew[7]]
	var pos := _far_spot(w, a[1], 170.0)
	_park_crew(w, crew, pos, a[1], 430.0)
	w.cmd_build(CHEAP, pos, World.PLAYER, three)
	var b = _newest(w)
	var n := _assigned(w, b)
	var matched := 0
	for u in w.units:
		if u.build_target == b and three.has(u):
			matched += 1
	_report("选中的农民才去（选 3 个去 3 个）", n == 3 and matched == 3,
		"（被指派 %d 个，其中在选中列表里 %d 个）" % [n, matched])

## 没选中农民 → 自动挑最近的那一个
func _test_auto_pick_nearest() -> void:
	var a := _arena(12)
	var w: World = a[0]
	var crew: Array = a[2]
	var pos := _far_spot(w, a[1], 170.0)
	_park_crew(w, crew, pos, a[1], 430.0)
	var nearest = null
	var bd := INF
	for u in w.units:
		if not u.can_harvest():
			continue
		var d: float = u.pos.distance_squared_to(pos)
		if d < bd:
			bd = d
			nearest = u
	w.cmd_build(CHEAP, pos, World.PLAYER)
	var b = _newest(w)
	var n := _assigned(w, b)
	var got = null
	for u in w.units:
		if u.build_target == b:
			got = u
	_report("没选农民时自动挑最近的一个", n == 1 and got == nearest,
		"（指派 %d 个，是最近的那个：%s）" % [n, str(got == nearest)])

## 兜底仍然有效：指派的农民被改派走之后，要能补上新的
func _test_refill_when_lost() -> void:
	var a := _arena(12)
	var w: World = a[0]
	var crew: Array = a[2]
	var pos := _far_spot(w, a[1], 170.0)
	_park_crew(w, crew, pos, a[1], 430.0)
	w.cmd_build(CHEAP, pos, World.PLAYER)
	var b = _newest(w)
	var lost := _assigned(w, b)
	for u in w.units:
		if u.build_target == b:
			u.build_target = null
	var refilled := false
	for i in range(60):          # 3 秒，派工间隔 0.5 秒，够补了
		w.step(0.05)
		if _assigned(w, b) > 0:
			refilled = true
			break
	_report("指派的农民被改派后会自动补位", lost == 1 and refilled,
		"（原有 %d 个 → 清空后 %s）" % [lost, ("已补位" if refilled else "未补位")])

## 建造速度：2 个农民明显更快，但不超过 2×（Building.update 里 minf(2.0, builders)）
## 农民停在工地旁边（步行≈0），这样测出来的才是纯建造耗时，不掺步行时间。
func _test_build_speed() -> void:
	var t1 := _time_to_build(1)
	var t2 := _time_to_build(2)
	var ratio := t2 / maxf(0.001, t1)
	_report("2 个农民建造更快且不超过 2×", t1 > 0.0 and t2 > 0.0 and ratio <= 0.62 and ratio >= 0.40,
		"（1 人 %.1fs → 2 人 %.1fs，倍率 %.2f）" % [t1, t2, ratio])

func _time_to_build(n: int) -> float:
	var a := _arena(n)
	var w: World = a[0]
	var crew: Array = a[2]
	var pos := _far_spot(w, a[1], 170.0)
	if pos == Vector2.ZERO:
		return -1.0
	_park_crew(w, crew, pos, a[1], 34.0)     # 就站在工地边上
	w.cmd_build(CHEAP, pos, World.PLAYER, crew)
	var b = _newest(w)
	var t := 0.0
	for i in range(2400):                    # 上限 120 秒
		w.step(0.05)
		t += 0.05
		if b.complete:
			return t
	return -1.0

## 完工后所有农民解绑，不会继续挂在工地上
func _test_release_on_complete() -> void:
	var a := _arena(3)
	var w: World = a[0]
	var crew: Array = a[2]
	var pos := _far_spot(w, a[1], 170.0)
	_park_crew(w, crew, pos, a[1], 34.0)
	w.cmd_build(CHEAP, pos, World.PLAYER, crew)
	var b = _newest(w)
	for i in range(2400):
		w.step(0.05)
		if b.complete:
			break
	var still := _assigned(w, b)
	_report("完工后农民全部解绑", b.complete and still == 0,
		"（完工=%s，仍挂在工地上的 %d 个）" % [str(b.complete), still])

## 每个建筑和单位都要有介绍，且长度受控、互不重复
func _test_descriptions() -> void:
	var missing := []
	var toolong := []
	for bid in GameData.BUILDINGS:
		var d := String(GameData.get_building(bid).get("desc", "")).strip_edges()
		if d == "":
			missing.append("建筑 " + String(bid))
		elif d.length() > 20:
			toolong.append("建筑 %s(%d 字)" % [bid, d.length()])
	for uid in GameData.UNITS:
		var d2 := String(GameData.get_unit(uid).get("desc", "")).strip_edges()
		if d2 == "":
			missing.append("单位 " + String(uid))
		elif d2.length() > 20:
			toolong.append("单位 %s(%d 字)" % [uid, d2.length()])
	_report("全部 %d 个建筑 + %d 个单位都有介绍"
			% [GameData.BUILDINGS.size(), GameData.UNITS.size()],
		missing.is_empty() and toolong.is_empty(),
		"" if (missing.is_empty() and toolong.is_empty())
		else "（缺 %d 条：%s；超长 %d 条：%s）" % [missing.size(), ", ".join(missing),
			toolong.size(), ", ".join(toolong)])

	# 互不重复 —— 防复制粘贴时漏改
	var seen := {}
	var dup := []
	for bid in GameData.BUILDINGS:
		var d3 := String(GameData.get_building(bid).get("desc", ""))
		if seen.has(d3):
			dup.append("%s 与 %s" % [bid, seen[d3]])
		else:
			seen[d3] = bid
	for uid in GameData.UNITS:
		var d4 := String(GameData.get_unit(uid).get("desc", ""))
		if seen.has(d4):
			dup.append("%s 与 %s" % [uid, seen[d4]])
		else:
			seen[d4] = uid
	_report("介绍文案互不重复", dup.is_empty(),
		"" if dup.is_empty() else "（重复：%s）" % ", ".join(dup))

## ★回归★ 到场判据必须是「站定」，不能是「离得多近」。
##
## 真 bug：AI 把建筑摆得很密时，`_stand_point()` 算出的站位会落在阻挡格里，
## 被 `grid.nearest_free_world()` 吸附到 60~75px 外 —— 而按距离判的半径是
## `radius + 36 ≈ 49`。于是建造者就站在自己的站位上，工地进度却永远卡在 0%，
## 而且因为「已指派数 > 0」也不会再补人 —— 工地永久烂尾，农民被永久占用。
## 实测一次对局里 5 个工地同时烂尾一百多秒，AI 的经济整个停摆。
func _test_arrival_not_distance() -> void:
	var a := _arena(1)
	var w: World = a[0]
	var base = a[1]
	var crew: Array = a[2]
	var site := _far_spot(w, base, 170.0)
	w.cmd_build(CHEAP, site, World.PLAYER, crew)
	var b = _newest(w)
	var u: Unit = crew[0]

	# ① 还在赶路 → 不算到场
	u.pos = b.pos + Vector2(200.0, 0.0)
	u.move_to(b.pos)
	u.build_target = b
	var moving_ok: bool = not w.builder_arrived(b, u)

	# ② 站定（哪怕站位被地形吸附到 70px 外）→ 算到场
	u.pos = b.pos + Vector2(70.0, 0.0)
	u.stop()
	u.build_target = b
	var stopped_ok: bool = w.builder_arrived(b, u)

	# ③ 并且工地真的开始推进
	var before: float = b.build_progress
	for i in range(60):
		w._update_buildings(1.0 / 60.0)
	var adv: bool = b.build_progress > before

	_report("到场判据是「站定」而不是「离得多近」", moving_ok and stopped_ok and adv,
		"（赶路中=%s，站定在 70px 外=%s，工地推进 %.1f→%.1f）"
			% [str(moving_ok), str(stopped_ok), before, b.build_progress])

## ★回归★ 新工地不能把别的工地上的农民抢走。
##
## 真 bug：`cmd_build` 的自动挑人没有排除「已经挂在别的工地上」的农民，
## 于是新工地会把老工地的建造者挖走 —— 老工地烂尾，新工地也不会因此更快，
## 而且被挖走的农民**永远不会回到原来的工地**。
func _test_no_stealing() -> void:
	var a := _arena(2)
	var w: World = a[0]
	var base = a[1]
	var crew: Array = a[2]
	var s1 := _far_spot(w, base, 165.0)
	w.cmd_build(CHEAP, s1, World.PLAYER, crew)      # 明确派 2 个
	var b1 = _newest(w)
	var kept0 := _assigned(w, b1)

	var s2 := _far_spot(w, base, 185.0)
	var ok2: bool = w.cmd_build(CHEAP, s2, World.PLAYER, [])   # 自动挑人
	var b2 = _newest(w) if ok2 else null
	var kept := _assigned(w, b1)
	var got := _assigned(w, b2) if b2 != null and b2 != b1 else -1

	_report("新工地不抢已在别的工地上的农民", kept0 == 2 and kept == 2 and got == 0,
		"（原工地 %d→%d 个，新工地拿到 %d 个）" % [kept0, kept, got])

## AI 的自动派工数：小型 1 个、大型 2 个。
## 这一条是「改建造速度统计口径」的补偿措施，必须有测试盯着 ——
## 少了它，AI 的扩张节奏会整体变慢而没人发现。
func _test_ai_builder_count() -> void:
	var a := _arena(1)
	var w: World = a[0]
	var small := w._ai_builder_count(CHEAP)
	var big := w._ai_builder_count(BIG)
	var bad := []
	for bid in GameData.BUILDINGS:
		var n := w._ai_builder_count(String(bid))
		if n < 1 or n > 2:
			bad.append("%s→%d" % [bid, n])
	_report("AI 自动派工数：小型 1 个 / 大型 2 个", small == 1 and big == 2 and bad.is_empty(),
		"（补给站 %d 个、兵营 %d 个%s）" % [small, big,
			"" if bad.is_empty() else "，越界：" + ", ".join(bad)])
