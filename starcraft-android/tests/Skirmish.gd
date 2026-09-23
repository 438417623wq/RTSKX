extends SceneTree

## 对局模拟：让玩家侧的"自动指挥"和 AI 各打一局，验证战斗、推进、
## 胜负判定在长时间尺度上都成立（这是核心玩法循环）。

func _init() -> void:
	for race in ["terran", "zerg", "protoss"]:
		var w := World.new(64, 40, race, _foe(race), "normal")
		_auto_play(w, 420.0)
		var summary := "%-8s | %5.0fs | 玩家单位 %2d 建筑 %d | AI 单位 %2d 建筑 %d | 击杀 %2d | 结果 %s" % [
			race, w.elapsed,
			w.count_units(World.PLAYER), w.buildings_of(World.PLAYER).size(),
			w.count_units(World.ENEMY), w.buildings_of(World.ENEMY).size(),
			w.ai.get("kills", 0),
			("玩家胜" if w.winner == World.PLAYER else ("AI 胜" if w.winner == World.ENEMY else "未分胜负")),
		]
		print(summary)
	quit(0)

## 简易玩家侧代理：自动采矿 + 自动补兵 + 满员就进攻
func _auto_play(w: World, seconds: float) -> void:
	var steps := int(seconds / 0.05)
	var attack_timer := 0.0
	var attack_sent := false
	for i in range(steps):
		w.step(0.05)
		if w.game_ended:
			attack_sent = false
			break
		# 玩家采矿
		var idle_workers := []
		for u in w.units_of(World.PLAYER):
			if u.can_harvest() and u.resource_target == null and u.harvest_target == null:
				idle_workers.append(u)
		if not idle_workers.is_empty():
			var node = null
			for r in w.resources:
				if r["amount"] <= 0.0:
					continue
				if node == null or idle_workers[0].pos.distance_squared_to(r["pos"]) < idle_workers[0].pos.distance_squared_to(node["pos"]):
					node = r
			if node != null:
				w.cmd_harvest(idle_workers, node)
		# 造兵（保持人口）
		for b in w.buildings_of(World.PLAYER):
			if not b.complete:
				continue
			if b.type_id in ["command_center", "hive", "nexus"] and w.count_units(World.PLAYER) < 14:
				if b.queue.size() == 0:
					w.cmd_train(b, String(GameData.FACTIONS[w.player_race]["worker"]))
			var tr: Array = b.trains()
			for uid in tr:
				var d := GameData.get_unit(uid)
				if d.get("role", "") == "worker":
					continue
				if b.queue.size() == 0 and w.can_afford(World.PLAYER, String(uid)):
					w.cmd_train(b, String(uid))
		# 人口
		var f: Dictionary = w.factions[World.PLAYER]
		if f["supply_cap"] - f["supply_used"] < 3:
			var sb := "supply_depot"
			if w.player_race == "zerg":
				sb = "extractor"
			elif w.player_race == "protoss":
				sb = "pylon"
			var base = null
			for b in w.buildings_of(World.PLAYER):
				if b.data.get("dropoff", false):
					base = b
					break
			if base != null and w.can_afford(World.PLAYER, sb):
				for ang in range(0, 360, 20):
					var p: Vector2 = base.pos + Vector2(cos(deg_to_rad(ang)), sin(deg_to_rad(ang))) * (90.0 + float(ang % 3) * 34.0)
					if w.can_place_building(sb, p, World.PLAYER)["ok"]:
						w.cmd_build(sb, p, World.PLAYER)
						break
		# 进攻
		attack_timer -= 0.05
		if attack_timer <= 0.0 and not attack_sent:
			attack_timer = 30.0
			var fighters := []
			for u in w.units_of(World.PLAYER):
				if not u.can_harvest():
					fighters.append(u)
			if fighters.size() >= 4:
				var target = null
				if not w.buildings_of(World.ENEMY).is_empty():
					target = w.buildings_of(World.ENEMY)[0].pos
				if target != null:
					for u in fighters:
						u.attack_to(target)
					attack_sent = true
		elif attack_sent:
			# 部队死光了就重置
			var n := 0
			for u in w.units_of(World.PLAYER):
				if not u.can_harvest():
					n += 1
			if n < 2:
				attack_sent = false

func _foe(r: String) -> String:
	match r:
		"terran": return "zerg"
		"zerg": return "protoss"
		_: return "terran"
