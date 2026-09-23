extends SceneTree
## 平衡性对局：一个「会玩」的玩家 AI vs 内置 AI。
##
## 早期版本的玩家脚本只会训练基地自带的兵种（神族只出探机、人族只出 SCV），
## 于是「神族 187 秒崩盘」其实只是测试脚本不会造兵，跟平衡无关。
## 这里补齐：按科技树顺序铺建筑 → 开气 → 补人口 → 出兵 → 成军后推塔。

const STEP := 0.05
const LIMIT := 600.0
const WORKER_TARGET := 14
const ATTACK_AT := 10          # 战斗单位达到这个数量就发起总攻
const REPEATS := 5             # 每个对阵跑几局（AI 有随机性，单局结果不可信）

class Brain:
	var w
	var race := ""
	var worker_id := ""
	var supply_id := ""
	var gas_id := ""
	var mil_id := ""            # 第一个能出战斗单位的建筑（允许造 2 座）
	var attacking := false
	var peak_army := 0
	var peak_foe := 0
	var attacks := 0

	func _init(world, r: String) -> void:
		w = world
		race = r
		worker_id = String(GameData.FACTIONS[race]["worker"])
		supply_id = GameData.supply_building(race)
		gas_id = GameData.gas_building(race)
		for entry in GameData.BUILD_MENU[race]:
			var bid := String(entry["id"])
			if bid == supply_id or bid == gas_id:
				continue
			if _is_military(bid):
				mil_id = bid
				break

	func _is_military(bid: String) -> bool:
		for uid in GameData.get_building(bid).get("trains", []):
			if String(GameData.get_unit(String(uid)).get("role", "")) != "worker":
				return true
		return false

	func base_pos() -> Vector2:
		for b in w.buildings_of(World.PLAYER):
			if b.data.get("dropoff", false) and b.alive():
				return b.pos
		return Vector2.ZERO

	func fighters() -> Array:
		var out := []
		for u in w.units_of(World.PLAYER):
			if u.alive() and not u.can_harvest():
				out.append(u)
		return out

	## 找一个能放下该建筑的坐标；找不到返回 (-1,-1)
	func find_spot(bid: String) -> Vector2:
		var d := GameData.get_building(bid)
		# 气矿建筑只能压在未开发的气矿上
		if bool(d.get("gas_building", false)):
			var best = null
			var bd := INF
			for r in w.resources:
				if String(r.get("kind", "")) != "gas" or float(r["amount"]) <= 0.0:
					continue
				if w.gas_building_on(r, false) != null:
					continue
				if not w.can_place_building(bid, r["pos"], World.PLAYER)["ok"]:
					continue
				var dist: float = base_pos().distance_squared_to(r["pos"])
				if dist < bd:
					bd = dist
					best = r["pos"]
			return best if best != null else Vector2(-1, -1)
		# 神族的建筑必须落在水晶塔的能量场内，所以围着水晶塔找位置
		var origin: Vector2 = base_pos()
		if String(w.factions[World.PLAYER]["race"]) == "protoss" and bid != "pylon":
			var ps: Array = w.power_sources(World.PLAYER)
			if not ps.is_empty():
				var nb = ps[0]
				var nd := INF
				for b in ps:
					var dd: float = origin.distance_squared_to(b.pos)
					if dd < nd:
						nd = dd
						nb = b
				origin = nb.pos
		for ring in range(1, 5):
			var rad := 78.0 + float(ring) * 40.0
			for i in range(24):
				var ang: float = TAU * float(i) / 24.0 + float(ring) * 0.13
				var p: Vector2 = origin + Vector2(cos(ang), sin(ang)) * rad
				p = p.clamp(Vector2(60, 60), w.world_size - Vector2(60, 60))
				if w.can_place_building(bid, p, World.PLAYER)["ok"]:
					return p
		return Vector2(-1, -1)

	func built() -> Dictionary:
		var s := {}
		for b in w.buildings:
			if b.alive() and b.owner_id == World.PLAYER:
				s[b.type_id] = true
		return s

	func count(bid: String) -> int:
		return w.count_building(World.PLAYER, bid)

	## 按科技树顺序挑下一个该造的建筑，返回空串表示暂时没什么要造的
	func next_build() -> String:
		var f: Dictionary = w.factions[World.PLAYER]
		if int(f["supply_cap"]) - int(f["supply_used"]) < 4 and count(supply_id) < 6:
			return supply_id
		# 科技树里有吃瓦斯的建筑就先开气（否则高级兵种永远出不来）
		if count(gas_id) < 2 and _needs_gas() and f["minerals"] >= 75.0 + 60.0:
			return gas_id
		var bset := built()
		for entry in GameData.BUILD_MENU[race]:
			var bid := String(entry["id"])
			if bid == supply_id or bid == gas_id:
				continue
			var req = entry.get("requires", null)
			if req != null and not bset.has(String(req)):
				continue
			var cap := 3 if bid == mil_id else 1
			if count(bid) >= cap:
				continue
			return bid
		return ""

	func _needs_gas() -> bool:
		for entry in GameData.BUILD_MENU[race]:
			if float(GameData.get_building(String(entry["id"])).get("cost_g", 0)) > 0.0:
				return true
		return false

	func tick() -> void:
		var f: Dictionary = w.factions[World.PLAYER]
		# --- 1. 建造（每帧最多起一个工地，避免一口气把资源全花光）---
		var bid := next_build()
		if bid != "":
			var spot := find_spot(bid)
			if spot.x >= 0.0:
				w.cmd_build(bid, spot, World.PLAYER)
		# --- 2. 农民：补到目标数，剩下的全去挖矿/采气 ---
		var workers: int = w.count_units(World.PLAYER, worker_id)
		for b in w.buildings_of(World.PLAYER):
			if not b.complete or not b.data.get("dropoff", false):
				continue
			if workers < WORKER_TARGET and b.queue.size() == 0:
				w.cmd_train(b, worker_id)
		# --- 3. 出兵：所有已完工建筑都排队，队列别超过 2 ---
		for b in w.buildings_of(World.PLAYER):
			if not b.complete or b.dead:
				continue
			if b.queue.size() >= 2:
				continue
			for uid in b.trains():
				var d := GameData.get_unit(String(uid))
				if String(d.get("role", "")) == "worker":
					continue
				if w.can_afford(World.PLAYER, String(uid)):
					w.cmd_train(b, String(uid))
					break
		# --- 4. 采集：空闲农民派去最近的矿（有气矿建筑就分 2 个去采气）---
		_assign_workers()
		# --- 5. 成军后推进 ---
		var army := fighters()
		peak_army = maxi(peak_army, army.size())
		peak_foe = maxi(peak_foe, w.count_units(World.ENEMY) - _foe_workers())
		if army.size() >= ATTACK_AT:
			var targets: Array = w.buildings_of(World.ENEMY)
			if not targets.is_empty():
				var goal: Building = targets[0]
				var gd := INF
				for b in targets:
					var d2: float = base_pos().distance_squared_to(b.pos)
					if d2 < gd:
						gd = d2
						goal = b
				for u in army:
					if u.has_move_order or u.attack_target != null:
						continue
					u.attack_to(goal.pos + Vector2(randf_range(-40, 40), randf_range(-40, 40)))
				if not attacking:
					attacking = true
					attacks += 1

	func _foe_workers() -> int:
		var wt := String(GameData.FACTIONS[w.enemy_race]["worker"])
		return w.count_units(World.ENEMY, wt)

	func _assign_workers() -> void:
		var gas_b = null
		for b in w.buildings_of(World.PLAYER):
			if b.complete and not b.dead and b.gas_geyser != null:
				gas_b = b
				break
		var on_gas := 0
		var idle := []
		for u in w.units_of(World.PLAYER):
			if not u.alive() or not u.can_harvest():
				continue
			if u.build_target != null:
				continue      # 正在工地干活，别拉走
			if u.resource_target != null and String(u.resource_target.get("kind", "")) == "gas":
				on_gas += 1
				continue
			if u.resource_target == null and u.harvest_target == null and u.path.size() == 0 \
				and not u.has_move_order:
				idle.append(u)
		if gas_b != null:
			while on_gas < 2 and idle.size() > 2:
				var gw = idle.pop_back()
				w.cmd_harvest([gw], gas_b.gas_geyser)
				on_gas += 1
		for u in idle:
			var node = null
			var bd := INF
			for r in w.resources:
				if String(r.get("kind", "")) != "mineral" or float(r["amount"]) <= 0.0:
					continue
				var d: float = u.pos.distance_squared_to(r["pos"])
				if d < bd:
					bd = d
					node = r
			if node != null:
				w.cmd_harvest([u], node)

func _init() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.is_empty():
		argv = OS.get_cmdline_args()
	var want_trace := false
	var only := ""
	var repeats := REPEATS
	for a in argv:
		if a == "trace":
			want_trace = true
		elif String(a).begins_with("race="):
			only = String(a).substr(5)
		elif String(a).begins_with("n="):
			repeats = maxi(1, int(String(a).substr(2)))
	if want_trace:
		_trace(only if only != "" else "protoss")
		quit(0)
		return
	print("=== 平衡性对局（会玩的玩家 AI vs 内置 AI，难度 normal，上限 %ds，每组合 %d 局）===" % [int(LIMIT), repeats])
	for race in ["terran", "zerg", "protoss"]:
		if only != "" and race != only:
			continue
		var foe := _foe(race)
		var wins := 0
		var losses := 0
		var draws := 0
		var durs := []
		var p_peaks := []
		var e_peaks := []
		for rep in range(repeats):
			var w := World.new(64, 40, race, foe, "normal")
			var b := Brain.new(w, race)
			_run(w, b)
			if w.winner == World.PLAYER:
				wins += 1
			elif w.winner == World.ENEMY:
				losses += 1
			else:
				draws += 1
			durs.append(w.elapsed)
			p_peaks.append(b.peak_army)
			e_peaks.append(b.peak_foe)
		var res := "玩家 %d 胜 / %d 负" % [wins, losses]
		if draws > 0:
			res += " / %d 平" % draws
		print("%-8s vs %-8s | %-16s | 时长中位 %4.0fs | 玩家峰值兵中位 %2d | AI峰值兵中位 %2d" % [
			race, foe, res, _median(durs), _median(p_peaks), _median(e_peaks)])
	quit(0)

func _run(w, b) -> void:
	for i in range(int(LIMIT / STEP)):
		w.step(STEP)
		if w.game_ended:
			break
		b.tick()

func _median(arr: Array) -> float:
	var a := arr.duplicate()
	a.sort()
	if a.is_empty():
		return 0.0
	return float(a[a.size() / 2])

func _foe(r: String) -> String:
	return "zerg" if r == "terran" else ("protoss" if r == "zerg" else "terran")

## 单场对局的时间线追踪：每 15 秒打印双方经济/兵力/建筑，用来定位卡点。
## 用法：--script res://tests/bal.gd -- trace race=protoss
func _trace(race: String) -> void:
	var foe := _foe(race)
	var w := World.new(64, 40, race, foe, "normal")
	var b := Brain.new(w, race)
	var next_report := 0.0
	print("=== 时间线追踪：%s vs %s ===" % [race, foe])
	for i in range(int(LIMIT / STEP)):
		w.step(STEP)
		if w.game_ended:
			break
		b.tick()
		if w.elapsed >= next_report:
			next_report += 15.0
			print("t=%3.0f | 我 矿%4.0f 气%3.0f 人口%2d/%2d 农%2d 兵%2d | 敌 矿%4.0f 气%3.0f 人口%2d/%2d 农%2d 兵%2d | 我建:%s | 在建:%s" % [
				w.elapsed,
				float(w.factions[World.PLAYER]["minerals"]), float(w.factions[World.PLAYER]["gas"]),
				int(w.factions[World.PLAYER]["supply_used"]), int(w.factions[World.PLAYER]["supply_cap"]),
				w.count_units(World.PLAYER, b.worker_id), b.fighters().size(),
				float(w.factions[World.ENEMY]["minerals"]), float(w.factions[World.ENEMY]["gas"]),
				int(w.factions[World.ENEMY]["supply_used"]), int(w.factions[World.ENEMY]["supply_cap"]),
				w.count_units(World.ENEMY, String(GameData.FACTIONS[foe]["worker"])),
				w.count_units(World.ENEMY) - w.count_units(World.ENEMY, String(GameData.FACTIONS[foe]["worker"])),
				_owned(w, World.PLAYER), _building(w, World.PLAYER)])
			print("            敌建:%s | 敌在建:%s" % [_owned(w, World.ENEMY), _building(w, World.ENEMY)])
	print("结局：%s  t=%.0fs" % [
		("玩家胜" if w.winner == World.PLAYER else ("AI 胜" if w.winner == World.ENEMY else "未分胜负")),
		w.elapsed])

func _owned(w, owner: int) -> String:
	var c := {}
	for bl in w.buildings_of(owner):
		c[bl.type_id] = int(c.get(bl.type_id, 0)) + 1
	var parts := []
	for k in c:
		parts.append("%s×%d" % [k, c[k]])
	return ",".join(parts)

func _building(w, owner: int) -> String:
	var parts := []
	for bl in w.buildings_of(owner):
		if not bl.complete:
			parts.append("%s %d%%" % [bl.type_id, int(100.0 * bl.build_progress / maxf(1.0, bl.build_time))])
	return ",".join(parts)

