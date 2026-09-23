extends SceneTree

## 局域网**会话状态机**的单进程回环集成测试（第十三轮 M4b）。
##
## 和 `tests/NetLink.gd` 的分工：那一套测「字节能不能过去」，
## 这一套测「**过去之后双方看到的世界是不是同一个**」——
## 握手、种子一致性、快照下行、指令上行、归属校验、迷雾过滤、看门狗、限流。
##
## ⚠️ 四条纪律（前三条和 NetLink 一样，第四条是本套特有的）：
##   1. **端口要换**（不用 `Net.PORT`，也不用 NetLink 那套端口）。
##   2. **必须 `step()` 双方**。只推一边的话对面永远停在半路。
##   3. **等条件要带超时**。死循环比失败难查得多。
##   4. **`step(delta)` 的 delta 是虚拟时钟**（累加的 `_now`），不是真实时间。
##      所以「握手超时 / 失联看门狗」这类断言可以瞬间跑完，
##      不用真的 sleep 8 秒 —— 否则这一套会从毫秒级变成十几秒，
##      而且会随机器负载偶发变红。

const PORT := 27515
const PORT2 := 27516
## 单步推进的虚拟时间。50 FPS 的等效值。
const STEP_D := 0.02
const MW := 48
const MH := 32
const EPS := 1.0

var _pass := 0
var _fail := 0
var _ran := false

func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] ", label)
	else:
		_fail += 1
		print("  [FAIL] ", label)

func _eqi(a: int, b: int, label: String) -> void:
	_ok(a == b, "%s（期望 %d，实测 %d）" % [label, b, a])

func _eqs(a: String, b: String, label: String) -> void:
	_ok(a == b, "%s（期望「%s」，实测「%s」）" % [label, b, a])

func _initialize() -> void:
	print("=============== 局域网会话层回环测试 ===============")

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_g1_seed()
	_g2_handshake()
	_g3_snapshot()
	_g4_cmd()
	_g5_reject()
	_g6_fog()
	_g7_disconnect()
	_g8_flood()
	_g9_lobby()
	_g10_chat()
	_g11_surrender_pause()
	print("==================================================")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

# ---------------------------------------------------------------- 工具

## 双方各推一步。`world_delta > 0` 时顺便推进**主机的权威世界** ——
## 这正是真实主循环的顺序：先 `world.step()`，再 `session.step()`。
func _tick_once(hs: NetSession, cs: NetSession, world_delta: float) -> void:
	if world_delta > 0.0 and hs.world != null:
		hs.world.step(world_delta)
	hs.step(STEP_D)
	cs.step(STEP_D)

func _pump(hs: NetSession, cs: NetSession, ms: int, world_delta: float = 0.0) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		_tick_once(hs, cs, world_delta)
		OS.delay_msec(1)

func _pump_until(hs: NetSession, cs: NetSession, done: Callable, ms: int,
		world_delta: float = 0.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		_tick_once(hs, cs, world_delta)
		if done.call():
			return true
		OS.delay_msec(1)
	return false

## 固定种子造主机世界。**种子要同时喂 `seed()` 和构造参数** ——
## 后者才真正决定地形（`_generate_map()` 用的是局部 RNG）。
func _host_world(sd: int) -> World:
	seed(sd)
	return World.new(MW, MH, "terran", "zerg", "easy", "plateau", sd)

## 起一对**已经握手完成**的主机 / 客户端会话。返回 `[hs, cs]`。
## 失败时 `cs` 仍返回（便于打印状态排查），调用方要用 `is_playing()` 兜住。
func _pair(p_port: int, sd: int) -> Array:
	var r := _pair_lobby(p_port, sd)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	if hs == null or cs == null:
		return r
	# ★M4c 起必须走「客户端准备 → 主机开始」这一道★
	# 少了它两端会停在大厅，后面所有「对局中」的断言都会假通过（状态不对就早退）。
	cs.set_ready(true)
	_pump(hs, cs, 60)
	hs.begin_game()
	_pump_until(hs, cs, func(): return hs.is_playing() and cs.is_playing(), 8000)
	return [hs, cs]

## 建对，但**停在大厅**（不准备、不开局）。给大厅那一组用。
func _pair_lobby(p_port: int, sd: int) -> Array:
	var hw := _host_world(sd)
	var hs := NetSession.new()
	if not hs.start_host(hw, sd, p_port, "主机甲"):
		return [hs, null]
	var cs := NetSession.new()
	if not cs.start_client("127.0.0.1", p_port, "客户端乙"):
		return [hs, cs]
	_pump_until(hs, cs, func(): return hs.is_in_lobby() and cs.is_in_lobby(), 8000)
	return [hs, cs]

## 两个世界的地形差异。返回 `""` 表示**逐格相同**。
##
## 只比纯地形（`cells` / `elev` / `ramp`）与资源点 ——
## `blocks` 里混了「建筑占格」，两端建筑集合不同时它本来就不该相同。
func _map_diff(a: World, b: World) -> String:
	if a == null or b == null:
		return "有一边世界不存在"
	if a.map_w != b.map_w or a.map_h != b.map_h:
		return "尺寸不同（%dx%d vs %dx%d）" % [a.map_w, a.map_h, b.map_w, b.map_h]
	if a.grid.cells != b.grid.cells:
		return "地形类型图不同"
	if a.grid.elev != b.grid.elev:
		return "高度图不同"
	if a.grid.ramp != b.grid.ramp:
		return "坡道图不同"
	if a.resources.size() != b.resources.size():
		return "资源点数量不同（%d vs %d）" % [a.resources.size(), b.resources.size()]
	for i in range(a.resources.size()):
		var ra: Dictionary = a.resources[i]
		var rb: Dictionary = b.resources[i]
		if ra["pos"] != rb["pos"]:
			return "资源点 %d 位置不同" % i
		if String(ra["kind"]) != String(rb["kind"]):
			return "资源点 %d 类型不同" % i
	return ""

func _count_units(w: World, owner: int) -> int:
	var n := 0
	for u in w.units:
		if not u.dead and u.owner_id == owner:
			n += 1
	return n

## 某个阵营基地的粗略中心（用它的建筑平均位置）。
func _base_pos(w: World, owner: int) -> Vector2:
	var bs := w.buildings_of(owner)
	if bs.is_empty():
		return w.world_size * 0.5
	var sum := Vector2.ZERO
	for b in bs:
		sum += b.pos
	return sum / float(bs.size())

## 找一格**本机看不见**的空地（用来验迷雾过滤）。
func _hidden_spot(w: World) -> Vector2:
	for cy in range(2, w.grid.h - 2):
		for cx in range(2, w.grid.w - 2):
			var p := w.grid.cell_to_world(Vector2i(cx, cy))
			if w.is_visible(p):
				continue
			if not w.grid.is_walkable_cell(cx, cy):
				continue
			return p
	return Vector2(-1, -1)

# ---------------------------------------------------------------- 1. 种子

func _g1_seed() -> void:
	print("-- 1. 主机世界与随机种子 --")
	var a := NetSession.create_host_world(MW, MH, "terran", "zerg", "easy", "plateau")
	var w1: World = a["world"]
	_ok(w1 != null, "create_host_world 返回了世界")
	_ok(int(a["seed"]) != 0, "种子非零（%d）" % int(a["seed"]))
	var b := NetSession.create_host_world(MW, MH, "terran", "zerg", "easy", "plateau")
	_ok(int(a["seed"]) != int(b["seed"]),
		"两次调用拿到不同种子（%d / %d）" % [int(a["seed"]), int(b["seed"])])

	# ★同一个种子必须生成逐格相同的地形★ —— 这是「客户端能重建地图」的前提。
	#   不成立的话，客户端看到的是一张**不一样的地图**，
	#   表现成单位穿墙、资源点错位，而且两端都不报错。
	var sd := int(a["seed"])
	_eqs(_map_diff(_host_world(sd), _host_world(sd)), "", "★同种子生成的地形逐格相同★")
	# 阳性对照：换个种子必须不同 —— 否则上面那条断言可能是恒真的。
	var other := sd ^ 0x5A5A5A5A
	var diff := _map_diff(_host_world(sd), _host_world(other))
	_ok(diff != "", "★换个种子地形就不同（%s）★" % diff)

# ---------------------------------------------------------------- 2. 握手

func _g2_handshake() -> void:
	print("-- 2. 握手（单进程回环，真 UDP）--")
	var sd := 20260925
	var hw := _host_world(sd)
	var hs := NetSession.new()
	var joined: Array = []
	var hready: Array = []
	hs.peer_joined.connect(func(pid): joined.append(pid))
	hs.session_ready.connect(func(): hready.append(1))

	_ok(hs.start_host(hw, sd, PORT, "主机甲"), "主机开房间（%s）" % hs.last_error)
	_eqs(hs.state_name(), "hosting", "主机状态是「等人加入」")
	_eqi(hs.player_count(), 1, "房间里只有主机自己")
	_eqi(hready.size(), 0, "★还没人来，主机不发 session_ready★")

	var cs := NetSession.new()
	var cready: Array = []
	cs.session_ready.connect(func(): cready.append(1))
	_ok(cs.start_client("127.0.0.1", PORT, "客户端乙"), "客户端发起连接（%s）" % cs.last_error)
	_eqs(cs.state_name(), "connecting", "客户端状态是「连接中」")
	_ok(cs.world == null, "★客户端此时还没有世界★")

	# ★M4c 起握手完**停在大厅**，不再直接进对局★
	var in_lobby := _pump_until(hs, cs,
		func(): return hs.is_in_lobby() and cs.is_in_lobby(), 8000)
	_ok(in_lobby, "★8 秒内双方都进入大厅（主机 %s / 客户端 %s）★"
		% [hs.state_name(), cs.state_name()])
	if not in_lobby:
		hs.close()
		cs.close()
		return

	_eqs(hs.client_name(), "客户端乙", "主机侧记下了客户端名字")
	_eqi(hs.player_count(), 2, "房间里 2 人")
	_eqi(joined.size(), 1, "主机收到 1 次 peer_joined")
	_eqi(hready.size(), 1, "主机收到 1 次 session_ready")
	_eqi(cready.size(), 1, "客户端收到 1 次 session_ready")

	# 世界已经建好了（客户端能逐格重建地形），但**还没开局** ——
	# 这是「大厅」与「对局」的分界。
	_ok(cs.world != null, "★客户端此时已经有世界（WELCOME 里带了地图参数）★")
	_ok(not hs.is_playing() and not cs.is_playing(), "★双方都还没进对局★")

	# 走完「客户端准备 → 主机开始」，本组后面的断言才是在「对局中」成立。
	_ok(cs.set_ready(true), "客户端点准备（%s）" % cs.last_error)
	_pump(hs, cs, 60)
	_ok(hs.client_ready(), "★主机收到「对方已准备」★")
	_ok(hs.can_start(), "★条件齐了，主机可以开局★")
	_ok(hs.begin_game(), "主机开局（%s）" % hs.last_error)
	var started := _pump_until(hs, cs, func(): return hs.is_playing() and cs.is_playing(), 8000)
	_ok(started, "★开局后双方都进入对局（主机 %s / 客户端 %s）★"
		% [hs.state_name(), cs.state_name()])
	if not started:
		hs.close()
		cs.close()
		return

	_eqi(cs.local_owner, World.ENEMY, "客户端拿到 ENEMY 阵营")
	_eqi(cs.remote_owner, World.PLAYER, "客户端认为主机是 PLAYER")
	_eqi(cs.world.local_owner, World.ENEMY, "★客户端世界的 local_owner 也设成了 ENEMY★")
	_eqs(cs.host_name, "主机甲", "客户端拿到了主机名")
	_eqi(cs.world_seed, sd, "★客户端拿到主机下发的种子★")

	# ★这一条是整套 M4b 的地基★
	_eqs(_map_diff(hw, cs.world), "", "★客户端重建的地形与主机逐格相同★")
	_eqs(_map_diff(cs.world, hw), "", "★反向比一遍也相同（不是单边巧合）★")

	# 客户端的迷雾判据必须认「自己人」——
	# `visible_enemies()` 里如果写死 `owner_id == PLAYER`，
	# 客户端会把自己的部队当成敌人（框选不到、小地图上自己是红点）。
	var wrong := 0
	for u in cs.world.visible_enemies():
		if u.owner_id == World.ENEMY:
			wrong += 1
	_eqi(wrong, 0, "★客户端不把自己的部队当敌人★")

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 3. 快照下行

func _g3_snapshot() -> void:
	print("-- 3. 快照下行（主机权威 → 客户端副本）--")
	var r := _pair(PORT2, 20260926)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：握手完成")
	if not cs.is_playing():
		return
	var hw: World = hs.world
	var cw: World = cs.world

	# 主机立刻会发第一份（`_snap_timer` 归零），所以这里应该已经有快照了
	_pump(hs, cs, 400)
	_ok(cs.snapshots_received >= 1, "★客户端收到了快照（%d 份）★" % cs.snapshots_received)
	_ok(hs.snapshots_sent >= 1, "主机发出了快照（%d 份）" % hs.snapshots_sent)
	_ok(cs.snapshots_received <= hs.snapshots_sent + 1, "收到的不会多于发出的")

	# ---- 单位集合一致（不推进世界，位置可以逐像素比）----
	_eqi(_count_units(cw, World.ENEMY), _count_units(hw, World.ENEMY),
		"★客户端看到的自己人数量与主机一致★")
	# 敌方的**只能更少**：快照按客户端视野过滤，看不见的不会被发过来
	_ok(_count_units(cw, World.PLAYER) <= _count_units(hw, World.PLAYER),
		"客户端看到的敌人不会多于主机实际拥有的（%d ≤ %d）"
		% [_count_units(cw, World.PLAYER), _count_units(hw, World.PLAYER)])

	var cu: Unit = null
	for u in cw.units:
		if u.owner_id == World.ENEMY and not u.dead:
			cu = u
			break
	if cu != null:
		var hu := Net.find_unit(hw, cu.id)
		_ok(hu != null, "客户端单位 id 在主机侧存在（id=%d）" % cu.id)
		if hu != null:
			_ok(cu.pos.distance_to(hu.pos) < EPS,
				"★位置一致（差 %.3f px）★" % cu.pos.distance_to(hu.pos))
			_eqi(int(cu.hp), int(hu.hp), "血量一致")
	else:
		_ok(false, "客户端世界里一个自己人都没有（快照链路断了）")

	# ---- 主机推进模拟，客户端必须跟上 ----
	# ⚠️ `world_delta` 是**每次 pump 迭代**推进的虚拟秒数。900 毫秒的 pump
	#    大约跑 900 次迭代，所以 0.05 会推进 45 秒游戏时间 —— 对局早结束了。
	#    这里用 0.004（约 2 秒）。
	var tick0 := cs.snapshots_received
	_pump(hs, cs, 500, 0.004)
	_ok(cs.snapshots_received > tick0,
		"★主机推进后客户端继续收到快照（%d → %d）★" % [tick0, cs.snapshots_received])
	_ok(hw.elapsed > 0.2, "主机世界的时间在走（%.2f 秒）" % hw.elapsed)
	_ok(absf(cw.elapsed - hw.elapsed) < 0.5,
		"★客户端的世界时间与主机同步（%.2f vs %.2f）★" % [cw.elapsed, hw.elapsed])

	# ---- 新单位必须传过去（放在客户端自己的基地旁，保证在它视野里）----
	# 这一段**不推进世界** —— 一推进 AI 就会动，单位数就不再是确定的。
	var ebase := _base_pos(hw, World.ENEMY)
	var n0 := _count_units(cw, World.ENEMY)
	for i in range(5):
		hw._spawn_unit("zergling", "zerg", ebase + Vector2(30.0 + float(i) * 10.0, 40.0),
			World.ENEMY)
	_pump(hs, cs, 900)
	_eqi(_count_units(cw, World.ENEMY), n0 + 5, "★客户端收到 5 个新单位★")

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 4. 指令上行

func _g4_cmd() -> void:
	print("-- 4. 指令上行（客户端只发指令，主机执行）--")
	var r := _pair(PORT, 20260927)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：握手完成")
	if not cs.is_playing():
		return
	var hw: World = hs.world

	# ---- MOVE ----
	var my: Array = []
	for u in hw.units_of(World.ENEMY):
		my.append(u)
	_ok(my.size() > 0, "主机侧有客户端的单位（%d 个）" % my.size())
	if my.is_empty():
		hs.close()
		cs.close()
		return
	var mover: Unit = my[0]
	var uid := mover.id
	var from := mover.pos
	var dest := from + Vector2(120.0, 60.0)
	var res := cs.send_cmd(Net.Cmd.MOVE, [uid], {"x": dest.x, "y": dest.y})
	_ok(bool(res["ok"]), "客户端发出 MOVE（%s）" % String(res["reason"]))
	# 0.006 × 约 600 次迭代 ≈ 3.6 秒游戏时间，够它走完 130 px
	_pump(hs, cs, 600, 0.006)
	var after := Net.find_unit(hw, uid)
	_ok(after != null, "单位还在（id=%d）" % uid)
	if after != null:
		_ok(after.pos.distance_to(from) > 5.0,
			"★主机侧的单位真的动了（移动 %.1f px）★" % after.pos.distance_to(from))
		_ok(hs.cmds_applied >= 1, "主机记了已应用的指令（%d 条）" % hs.cmds_applied)

	# ---- TRAIN：找一座能造兵的建筑 ----
	var trainer: Building = null
	var unit_id := ""
	for b in hw.buildings_of(World.ENEMY):
		if b.trains().is_empty():
			continue
		trainer = b
		unit_id = String(b.trains()[0])
		break
	_ok(trainer != null, "找到一座能训练的建筑")
	if trainer != null:
		# 保证资源与人口够（不然被拒的理由是「资源不足」，测的就不是链路了）
		hw.factions[World.ENEMY]["minerals"] = 2000.0
		hw.factions[World.ENEMY]["gas"] = 2000.0
		hw.factions[World.ENEMY]["supply_cap"] = 200
		var q0 := trainer.queue.size()
		var rt := cs.send_cmd(Net.Cmd.TRAIN, [],
			{"building_id": trainer.id, "type_id": unit_id})
		_ok(bool(rt["ok"]), "客户端发出 TRAIN %s（%s）" % [unit_id, String(rt["reason"])])
		_pump(hs, cs, 500)
		_eqi(trainer.queue.size(), q0 + 1, "★主机侧的建筑队列 +1★")

	# ---- 主机自己发指令走的是同一条路径 ----
	var enemy_unit: Unit = hw.units_of(World.ENEMY)[0]
	var r_self := hs.send_cmd(Net.Cmd.STOP, [enemy_unit.id])
	_ok(not bool(r_self["ok"]),
		"★主机自己指挥客户端的单位也会被归属校验挡住（%s）★" % String(r_self["reason"]))

	# ---- 不在对局中时发指令要干净地失败 ----
	# 用 FAILED 而不是 CLOSED：`close()` 遇到 CLOSED 会直接 return，
	# 那样这一侧的 ENet host 就漏在那儿了。
	cs.state = NetSession.State.FAILED
	var r_closed := cs.send_cmd(Net.Cmd.STOP, [uid])
	_ok(not bool(r_closed["ok"]), "不在对局中时发指令被拒（%s）" % String(r_closed["reason"]))

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 5. 拒绝回执

func _g5_reject() -> void:
	print("-- 5. 拒绝回执（客户端点了没反应必须能知道为什么）--")
	var r := _pair(PORT2, 20260928)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：握手完成")
	if not cs.is_playing():
		return
	var hw: World = hs.world

	# ---- ① 指挥不属于自己的单位 ----
	var foe: Unit = hw.units_of(World.PLAYER)[0]
	var n_before := hs.cmds_rejected
	cs.send_cmd(Net.Cmd.STOP, [foe.id])
	_pump(hs, cs, 600)
	_ok(hs.cmds_rejected > n_before, "★主机拒绝了「指挥对方单位」★")
	var rej := cs.take_reject()
	_ok(String(rej.get("reason", "")) != "",
		"★客户端拿到拒绝理由（「%s」）★" % String(rej.get("reason", "")))
	_eqs(String(rej.get("reason", "")), "没有可指挥的单位", "理由说的是「没有可指挥的单位」")
	# 对方单位必须毫发无伤
	_ok(Net.find_unit(hw, foe.id) != null, "★对方单位还在（没被指挥走）★")

	# ---- ② 目标点在地图外 ----
	var mine: Unit = hw.units_of(World.ENEMY)[0]
	var n2 := hs.cmds_rejected
	cs.send_cmd(Net.Cmd.MOVE, [mine.id], {"x": -50.0, "y": -50.0})
	_pump(hs, cs, 600)
	_ok(hs.cmds_rejected > n2, "★地图外的移动被拒★")
	var rej2 := cs.take_reject()
	_eqs(String(rej2.get("reason", "")), "目标点在地图外", "理由是「目标点在地图外」")

	# ---- ③ 不存在的建筑 ----
	var n3 := hs.cmds_rejected
	cs.send_cmd(Net.Cmd.TRAIN, [], {"building_id": 999999, "type_id": "marine"})
	_pump(hs, cs, 600)
	_ok(hs.cmds_rejected > n3, "★不存在的建筑被拒★")
	var rej3 := cs.take_reject()
	_eqs(String(rej3.get("reason", "")), "目标建筑不存在", "理由是「目标建筑不存在」")

	# ---- ④ 资源不足 ----
	var trainer: Building = null
	for b in hw.buildings_of(World.ENEMY):
		if not b.trains().is_empty():
			trainer = b
			break
	if trainer != null:
		hw.factions[World.ENEMY]["minerals"] = 0.0
		hw.factions[World.ENEMY]["gas"] = 0.0
		var q0 := trainer.queue.size()
		var n4 := hs.cmds_rejected
		cs.send_cmd(Net.Cmd.TRAIN, [],
			{"building_id": trainer.id, "type_id": String(trainer.trains()[0])})
		_pump(hs, cs, 600)
		_ok(hs.cmds_rejected > n4, "★资源不足时被拒★")
		_eqi(trainer.queue.size(), q0, "★队列没有被塞进去（拒绝是真拒绝）★")
		_ok(cs.take_reject().size() > 0, "资源不足的拒绝理由也回传了")

	# 取走的理由再取一次应该是空的（UI 每帧调它，不能重复弹）
	_ok(cs.take_reject().is_empty(), "拒绝理由取过一次就清空")

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 6. 迷雾过滤

func _g6_fog() -> void:
	print("-- 6. 快照按客户端视野过滤（客户端不能看全图）--")
	var r := _pair(PORT, 20260929)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：握手完成")
	if not cs.is_playing():
		return
	var hw: World = hs.world
	var cw: World = cs.world

	# 让客户端先把视野刷出来（`client_frame` 每 0.15 秒一次）
	_pump(hs, cs, 500)

	var spot := _hidden_spot(cw)
	_ok(spot.x >= 0.0, "找到了一格客户端看不见的空地（%.0f, %.0f）" % [spot.x, spot.y])
	if spot.x < 0.0:
		hs.close()
		cs.close()
		return
	_ok(not cw.is_visible(spot), "前置条件：该点对客户端不可见")

	var n0 := _count_units(cw, World.PLAYER)
	var hidden := hw._spawn_unit("marine", "terran", spot, World.PLAYER)
	_ok(hidden != null, "主机在视野外造了一个陆战队员（id=%d）" % hidden.id)
	_pump(hs, cs, 900)
	_eqi(_count_units(cw, World.PLAYER), n0,
		"★藏在视野外的单位没有出现在客户端的快照里★")

	# ★阳性对照★：把同一个单位挪到客户端基地旁边，它必须**立刻**出现。
	#   没有这一条的话，「没出现」也可能是因为快照链路整个断了。
	var inside := _base_pos(hw, World.ENEMY) + Vector2(40.0, 40.0)
	hidden.pos = inside
	hw._rebuild_hash()
	_pump(hs, cs, 900)
	_eqi(_count_units(cw, World.PLAYER), n0 + 1,
		"★同一个单位挪进视野后立刻出现（说明链路是通的，不是整体丢了）★")

	# ★过滤发生在「编码时」，不是把单位从世界里删掉★ ——
	#   主机自己的世界必须还有它（否则主机自己就看不见自己的兵了）。
	_ok(Net.find_unit(hw, hidden.id) != null,
		"★主机自己的世界里那个单位还在（过滤只影响编码）★")
	# 而且主机**为客户端算出来的那份迷雾**确实没覆盖那个点 ——
	# 这是 `_visible_cell` 读的那份数据，和客户端那边的判据必须一致。
	var hfog := hw.fog_of(World.ENEMY)
	var hc := hw.grid.world_to_cell(spot)
	_ok((hfog[hc.y * hw.grid.w + hc.x] & World.VIS_VISIBLE) == 0,
		"★主机为客户端算的迷雾也没覆盖那个点（两端判据一致）★")

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 7. 断线与看门狗

func _g7_disconnect() -> void:
	print("-- 7. 断线与看门狗 --")
	var r := _pair(PORT2, 20260930)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：握手完成")
	if not cs.is_playing():
		return

	var left: Array = []
	hs.peer_left.connect(func(pid, why): left.append(why))

	# ---- 优雅退出：主机必须 5 秒内感知 ----
	cs.close()
	var ok := _pump_until(hs, cs, func(): return hs.player_count() == 1, 5000)
	_ok(ok, "★主机 5 秒内感知到客户端退出★")
	_eqs(hs.state_name(), "hosting", "★主机回到「等人加入」，世界不受影响★")
	_eqi(left.size(), 1, "主机收到 1 次 peer_left")
	_eqs(String(left[0]) if not left.is_empty() else "", "对方已离开", "离开原因是「对方已离开」")
	# ⚠️ 必须关掉 —— 不关的话 PORT2 一直被占着，
	#    后面 `start_host(..., PORT2)` 会以「端口被占用」失败，
	#    而那个失败看起来像「握手超时逻辑坏了」，差得很远。
	hs.close()

	# ---- 客户端看门狗：主机不再发快照 ----
	var r2 := _pair(PORT, 20260931)
	var hs2: NetSession = r2[0]
	var cs2: NetSession = r2[1]
	_ok(cs2.is_playing(), "前置条件 2：握手完成")
	if cs2.is_playing():
		var failed: Array = []
		cs2.session_failed.connect(func(why): failed.append(why))
		# 只推客户端、**完全不推主机** —— 等价于主机卡死或网络断。
		# 虚拟时钟下 7 秒是瞬间跑完的。
		for i in range(7):
			cs2.step(1.0)
		_eqs(cs2.state_name(), "failed", "★5 秒没收到快照 → 客户端判定失联★")
		_ok(cs2.last_error.contains("失去联系"),
			"失败原因说清是失联（「%s」）" % cs2.last_error)
		_eqi(failed.size(), 1, "session_failed 只发了一次")
	hs2.close()
	cs2.close()

	# ---- 握手超时：连上了但一直不发 HELLO ----
	#
	# ⚠️ 这一段是**白盒**：直接伪造一个「连着但不握手」的 peer。
	#    走真实网络的话得让 ENet 完成握手、再拦住客户端的 `_send_hello()`
	#    —— 而 `_on_connect` 是同步发 HELLO 的，拦不住。
	#    这里要测的是**看门狗的逻辑**（超时 → 踢人 → 回到 HOSTING），
	#    伪造 peer 能把这件事做成确定的，不引入时序不确定性。
	var hs3 := NetSession.new()
	var hw3 := _host_world(20260932)
	hs3.start_host(hw3, 20260932, PORT2, "孤零零的主机")
	hs3._client_peer = 424242              # 一个不会真的存在的 peer id
	hs3._peer_ready = false
	hs3._connected_at = 0.0
	_eqs(hs3.state_name(), "hosting", "前置条件 3：主机在等人")
	_eqi(hs3.player_count(), 2, "前置条件 3：主机认为有人在连着")
	for i in range(9):
		hs3.step(1.0)
	_eqs(hs3.state_name(), "hosting", "★握手超时后主机回到「等人加入」★")
	_eqi(hs3._client_peer, 0, "★超时的 peer 被踢掉了★")
	_ok(hs3.last_error.contains("握手超时"),
		"超时原因说清了（「%s」）" % hs3.last_error)
	hs3.close()

	# ---- 客户端侧的握手超时（连上了但主机不回 WELCOME）----
	# 同理，白盒：伪造「ENet 已连上、但 WELCOME 一直不来」的状态。
	var cs4 := NetSession.new()
	cs4.start_client("127.0.0.1", PORT2, "苦等的客户端")
	var c4fail: Array = []
	cs4.session_failed.connect(func(why): c4fail.append(why))
	for i in range(9):
		cs4.step(1.0)
	_eqs(cs4.state_name(), "failed", "★客户端 8 秒没完成握手 → 失败★")
	_ok(cs4.last_error.contains("超时"), "原因说清是超时（「%s」）" % cs4.last_error)
	_eqi(c4fail.size(), 1, "session_failed 只发了一次")
	cs4.close()

	# ---- 连不上的地址：8 秒后干净失败 ----
	var dead := NetSession.new()
	var dready: Array = []
	dead.session_failed.connect(func(why): dready.append(why))
	_ok(dead.start_client("127.0.0.1", 27499, "孤儿"), "连一个没人监听的端口（发起不阻塞）")
	_eqs(dead.state_name(), "connecting", "状态是「连接中」")
	for i in range(9):
		dead.step(1.0)
	_eqs(dead.state_name(), "failed", "★8 秒连不上 → 失败（不是无限等待）★")
	_ok(dead.last_error.contains("超时"), "原因说清是超时（「%s」）" % dead.last_error)
	_eqi(dready.size(), 1, "session_failed 只发了一次")
	dead.close()

# ---------------------------------------------------------------- 8. 限流

func _g8_flood() -> void:
	print("-- 8. 指令限流（防「客户端刷爆主机」）--")
	var r := _pair(PORT, 20260933)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：握手完成")
	if not cs.is_playing():
		return
	var hw: World = hs.world
	var mine: Unit = hw.units_of(World.ENEMY)[0]
	var peer := hs.link.first_peer()
	_ok(peer != 0, "主机侧有 peer id")

	# ★直接打 `_host_cmd`，把「同一帧」这件事做成确定的★
	#   走真实网络的话，「ENet 一次 poll 会交上来多少个包」是不确定的，
	#   断言会时红时绿 —— 那种测试比没有测试更糟。
	var buf := Net.Buf.new()
	var a0 := hs.cmds_applied
	var d0 := hs.cmds_dropped
	hs._cmds_this_frame = 0
	var burst := NetSession.MAX_CMD_PER_FRAME + 20
	for i in range(burst):
		hs._host_cmd(peer, Net.packet_cmd(buf, i + 1, Net.Cmd.STOP, [mine.id]))
	var applied := hs.cmds_applied - a0
	var dropped := hs.cmds_dropped - d0
	_ok(applied <= NetSession.MAX_CMD_PER_FRAME,
		"★单帧应用的指令数不超过上限（%d ≤ %d）★" % [applied, NetSession.MAX_CMD_PER_FRAME])
	_eqi(applied, NetSession.MAX_CMD_PER_FRAME, "上限内的都被应用了")
	_eqi(dropped, burst - NetSession.MAX_CMD_PER_FRAME, "超出的都被丢弃了")
	# 阳性对照的等价物：换个「新帧」，剩下的还能进来
	hs._cmds_this_frame = 0
	var a1 := hs.cmds_applied
	hs._host_cmd(peer, Net.packet_cmd(buf, 999, Net.Cmd.STOP, [mine.id]))
	_eqi(hs.cmds_applied - a1, 1, "★新的一帧重新开始计数（限流不会永久卡死）★")

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 9. 大厅

func _g9_lobby() -> void:
	print("-- 9. 大厅（准备 / 开始）--")
	var r := _pair_lobby(PORT2, 20260940)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs != null and cs != null, "建对（停在大厅）")
	if hs == null or cs == null:
		return

	_eqs(hs.state_name(), "lobby", "主机在大厅")
	_eqs(cs.state_name(), "lobby", "客户端在大厅")
	_ok(hs.is_in_lobby() and cs.is_in_lobby(), "★双方 is_in_lobby 为真★")
	_ok(not hs.is_playing() and not cs.is_playing(), "★双方都还没进对局★")
	_eqi(hs.player_count(), 2, "★大厅里也算 2 人（不然玩家以为对方掉线了）★")
	_ok(cs.world != null, "客户端已经有世界了（WELCOME 里带了地图参数）")

	# 大厅里不该有快照 —— 有的话客户端会在「还没开局」时被推着动。
	var sr0 := cs.snapshots_received
	_pump(hs, cs, 600)
	_eqi(cs.snapshots_received - sr0, 0, "★大厅里主机一份快照都不发★")
	_ok(not cs.is_playing(), "★大厅里等 0.6 秒也不会自己进对局★")

	# 没准备就不能开局
	_ok(not hs.can_start(), "★对方没准备时 can_start 为假★")
	_ok(not hs.begin_game(), "★对方没准备时开不了局★")
	_eqs(hs.last_error, "对方还没有准备", "开局失败的理由说得清")

	# 指令在大厅里无效
	var bad := cs.send_cmd(Net.Cmd.STOP, [])
	_ok(not bool(bad["ok"]), "★大厅里发指令被拒（%s）★" % String(bad["reason"]))
	_eqs(String(bad["reason"]), "不在对局中", "拒的理由说得清")

	# 主机不能「准备」
	_ok(not hs.set_ready(true), "★主机调 set_ready 返回 false★")
	_eqs(hs.last_error, "主机不需要准备", "理由说得清")

	# 客户端准备
	var lobbies: Array = []
	hs.lobby_updated.connect(func(): lobbies.append(1))
	_ok(cs.set_ready(true), "客户端点准备（%s）" % cs.last_error)
	_ok(not hs.client_ready(), "★刚发出去时主机还没收到（要等一个来回）★")
	var got := _pump_until(hs, cs, func(): return hs.client_ready(), 3000)
	_ok(got, "★主机收到「对方已准备」★")
	_ok(lobbies.size() > 0, "主机发过 lobby_updated（UI 要重画玩家列表）")
	_ok(hs.can_start(), "★条件齐了 can_start 为真★")

	# 取消准备要能生效（不然「点错了就开不了局」）
	_ok(cs.set_ready(false), "客户端取消准备")
	var gone := _pump_until(hs, cs, func(): return not hs.client_ready(), 3000)
	_ok(gone, "★主机收到「对方取消准备」★")
	_ok(not hs.can_start(), "★取消后又不可以开局了★")
	cs.set_ready(true)
	_pump_until(hs, cs, func(): return hs.client_ready(), 3000)

	# 开局
	var hstart: Array = []
	var cstart: Array = []
	hs.game_started.connect(func(): hstart.append(1))
	cs.game_started.connect(func(): cstart.append(1))
	_ok(hs.begin_game(), "主机开局（%s）" % hs.last_error)
	_eqs(hs.state_name(), "playing", "★主机自己立刻进对局★")
	var both := _pump_until(hs, cs, func(): return cs.is_playing(), 3000)
	_ok(both, "★客户端收到 START 后进对局★")
	_eqi(hstart.size(), 1, "主机发过 1 次 game_started")
	_eqi(cstart.size(), 1, "客户端发过 1 次 game_started")

	# 开局后快照要真的开始发
	var sr1 := cs.snapshots_received
	_pump(hs, cs, 500, 0.05)
	_ok(cs.snapshots_received > sr1, "★开局后快照开始下行（%d 份）★" % (cs.snapshots_received - sr1))

	# 重复的 START 不能把已经开好的局重置
	# （直接打 `_client_packet` —— 真实网络里「重复的 START」什么时候到是不确定的，
	#  那种断言会时红时绿。`_peer_id` 参数客户端侧根本不读，传 0 即可。）
	cs._client_packet(0, Net.Msg.START, Net.packet(Net.Msg.START))
	_eqi(cstart.size(), 1, "★重复的 START 不再触发第二次 game_started★")
	_ok(cs.is_playing(), "★重复的 START 也不会把状态踢出对局★")

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 10. 聊天

func _g10_chat() -> void:
	print("-- 10. 对局内聊天 --")
	var r := _pair(PORT, 20260941)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：已进对局")
	if not cs.is_playing():
		return

	var hgot: Array = []
	var cgot: Array = []
	hs.chat_received.connect(func(from, text): hgot.append([from, text]))
	cs.chat_received.connect(func(from, text): cgot.append([from, text]))

	# 客户端 → 主机
	_ok(cs.send_chat("你好，我是乙方"), "客户端发言（%s）" % cs.last_error)
	var a := _pump_until(hs, cs, func(): return hgot.size() > 0, 3000)
	_ok(a, "★主机收到客户端的消息★")
	if a:
		_eqi(hgot.size(), 1, "只收到 1 条（没有重复投递）")
		_eqs(String(hgot[0][0]), "客户端乙", "★发送者名字由收包方按 peer 查（包里不带名字）★")
		_eqs(String(hgot[0][1]), "你好，我是乙方", "内容一字不差")
	_eqi(cgot.size(), 0, "★客户端没收到自己的消息（不重复上屏）★")

	# 主机 → 客户端
	_ok(hs.send_chat("收到，开打吧"), "主机发言（%s）" % hs.last_error)
	var b := _pump_until(hs, cs, func(): return cgot.size() > 0, 3000)
	_ok(b, "★客户端收到主机的消息★")
	if b:
		_eqi(cgot.size(), 1, "只收到 1 条")
		_eqs(String(cgot[0][0]), "主机甲", "发送者名字是主机名")
		_eqs(String(cgot[0][1]), "收到，开打吧", "内容一字不差")
	_eqi(hgot.size(), 1, "★主机也没收到自己刚发的那条★")

	# 空消息
	var n0 := cs.chats_received
	_ok(not cs.send_chat("   "), "★空白消息发不出去★")
	_eqs(cs.last_error, "不能发空消息", "理由说得清")

	# 超长消息：截断到上限内，且**不能切出半个汉字**
	var long := "汉字"
	for i in range(200):
		long += "测试"
	_ok(cs.send_chat(long), "超长消息发得出去（会被截断）")
	var c := _pump_until(hs, cs, func(): return hgot.size() > 1, 3000)
	_ok(c, "★主机收到被截断的超长消息★")
	if c:
		var t := String(hgot[1][1])
		_ok(t.to_utf8_buffer().size() <= Net.MAX_CHAT_BYTES,
			"★截断后字节数不超上限（%d ≤ %d）★" % [t.to_utf8_buffer().size(), Net.MAX_CHAT_BYTES])
		_ok(not t.contains("\uFFFD"), "★截断没有切出半个汉字（无替换字符）★")
		_ok(t.length() > 0, "截断后还有内容（不是截成空串）")

	# ---- 截断修补是纯函数，单独钉死边界（它错一次就是「每条消息都少一个字」）----
	var full := "你好".to_utf8_buffer()                 # 6 字节
	_eqi(Net.trim_partial_utf8(full).size(), 6, "★完整的中文串一个字节都不动★")
	_eqi(Net.trim_partial_utf8(full.slice(0, 5)).size(), 3,
		"★切掉半个字后退到前一个完整字符（5 → 3）★")
	_eqi(Net.trim_partial_utf8(full.slice(0, 4)).size(), 3,
		"★切到只剩 1 个字节的残字也要退干净（4 → 3）★")
	_eqi(Net.trim_partial_utf8(full.slice(0, 1)).size(), 0, "★只剩半个字 → 空串★")
	var ascii := "hello".to_utf8_buffer()
	_eqi(Net.trim_partial_utf8(ascii).size(), 5, "★纯 ASCII 原样保留（末字节不是续字节）★")
	_eqi(Net.trim_partial_utf8(PackedByteArray()).size(), 0, "空数组不炸")

	# 限流：同一帧狂发
	var before := hs.chats_received
	var accepted := 0
	var rejected := 0
	for i in range(NetSession.MAX_CHAT_PER_FRAME + 6):
		if cs.send_chat("刷屏 %d" % i):
			accepted += 1
		else:
			rejected += 1
	_eqi(accepted, NetSession.MAX_CHAT_PER_FRAME, "★同一帧只放行上限条数★")
	_eqi(rejected, 6, "多出来的被挡下")
	_pump(hs, cs, 200)
	_eqi(hs.chats_received - before, NetSession.MAX_CHAT_PER_FRAME, "★主机侧实际只收到上限条数★")

	# 阳性对照的等价物：换一帧就能继续发（限流不是永久封禁）
	_pump(hs, cs, 60)
	_ok(cs.send_chat("新的一帧"), "★新的一帧又能发言了★")

	hs.close()
	cs.close()

# ---------------------------------------------------------------- 11. 投降 / 暂停

func _g11_surrender_pause() -> void:
	print("-- 11. 对局内控制（投降 / 暂停）--")
	var r := _pair(PORT2, 20260942)
	var hs: NetSession = r[0]
	var cs: NetSession = r[1]
	_ok(hs.is_playing() and cs.is_playing(), "前置条件：已进对局")
	if not cs.is_playing():
		return

	# ---- 暂停：只有主机能改 ----
	_ok(not cs.set_paused(true), "★客户端调 set_paused 返回 false★")
	_eqs(cs.last_error, "只有主机能暂停游戏", "理由说得清")
	_ok(not cs.is_paused(), "★客户端本地没有被改掉★")

	# 客户端只能「请求」，本地不生效
	var cpause: Array = []
	var hpause: Array = []
	cs.pause_changed.connect(func(v): cpause.append(v))
	hs.pause_changed.connect(func(v): hpause.append(v))
	_ok(cs.request_pause(true), "客户端请求暂停（%s）" % cs.last_error)
	_ok(not cs.is_paused(), "★请求发出去的那一刻客户端还是「没暂停」★")
	var p1 := _pump_until(hs, cs, func(): return hs.is_paused() and cs.is_paused(), 3000)
	_ok(p1, "★主机采纳后两端都暂停了★")
	_eqi(cpause.size(), 1, "客户端只收到 1 次 pause_changed")
	_eqi(cpause[0], true, "收到的是「已暂停」")
	_eqi(hpause.size(), 1, "主机发过 1 次 pause_changed")

	# 幂等：主机重复设同一个值不再广播
	_ok(hs.set_paused(true), "主机重复设「暂停」返回 true")
	_pump(hs, cs, 120)
	_eqi(hpause.size(), 1, "★重复设同一个值不再广播★")

	# 主机恢复
	_ok(hs.set_paused(false), "主机恢复（%s）" % hs.last_error)
	var p2 := _pump_until(hs, cs, func(): return not hs.is_paused() and not cs.is_paused(), 3000)
	_ok(p2, "★恢复后两端都跑起来了★")
	_eqi(cpause.size(), 2, "客户端收到第 2 次 pause_changed")
	_eqi(cpause[1], false, "收到的是「已恢复」")

	# 主机请求暂停没有意义
	_ok(not hs.request_pause(true), "★主机调 request_pause 返回 false★")

	# ---- 投降：客户端认输 → 主机获胜 ----
	var hs_surr: Array = []
	var cs_surr: Array = []
	hs.peer_surrendered.connect(func(who): hs_surr.append(who))
	cs.peer_surrendered.connect(func(who): cs_surr.append(who))
	_ok(cs.surrender(), "客户端认输（%s）" % cs.last_error)
	_ok(cs.world.game_ended, "★客户端本地立刻结算★")
	_eqi(cs.world.winner, World.PLAYER, "★客户端视角：主机获胜★")
	var s1 := _pump_until(hs, cs, func(): return hs.world.game_ended, 3000)
	_ok(s1, "★主机收到投降并结算★")
	if s1:
		_eqi(hs.world.winner, World.PLAYER, "★主机视角：也是主机获胜（两端一致）★")
	_eqi(hs_surr.size(), 1, "★主机收到 1 次 peer_surrendered★")
	if hs_surr.size() > 0:
		_eqi(int(hs_surr[0]), World.ENEMY, "认输的是 ENEMY 那一方")
	_eqi(cs_surr.size(), 0, "★自己投降不给自己发信号（否则结算界面会弹两次）★")

	# 结算后再投降无效
	_ok(not cs.surrender(), "★已经结束的对局不能再投降★")
	_eqs(cs.last_error, "对局已经结束了", "理由说得清")

	# ★确定性复现「快照把已结算的对局复活」★
	#   上面那条「不能再投降」**不足以**钉死这个守卫：它能不能红取决于
	#   「主机那边结束时，客户端手上是不是正好有一份 winner=-1 的旧快照」，
	#   而这个时机是网络时序决定的 —— 撤掉守卫照样全绿（阳性对照打不红）。
	#   所以这里手工造一份「主机还没收到投降时发出的那种快照」。
	var buf := Net.Buf.new()
	var keep_ended := cs.world.game_ended
	var keep_winner := cs.world.winner
	cs.world.game_ended = false              # 临时装成「还没结束」的样子来编码
	cs.world.winner = -1
	var stale := Net.encode_snapshot(cs.world, buf, 9999, cs.local_owner)
	cs.world.game_ended = keep_ended
	cs.world.winner = keep_winner
	_ok(cs.world.game_ended, "喂之前客户端是「已结算」")
	var ares := Net.apply_snapshot(cs.world, stale)
	_ok(bool(ares["ok"]), "这份旧快照本身是合法包（不是被格式挡下来的）")
	_ok(cs.world.game_ended, "★旧快照不能把已结算的对局复活★")
	_eqi(cs.world.winner, World.PLAYER, "★胜负也没有被改写回「未结束」★")

	# 反过来：**没**结算过的世界必须照抄快照里的胜负
	# （少了这条，守卫写成 `if false:` 也能全绿）
	var w2 := _host_world(20260942)
	var src := _host_world(20260942)
	src.winner = World.ENEMY
	src.game_ended = true
	var ended := Net.encode_snapshot(src, buf, 10000, World.PLAYER)
	_ok(not w2.game_ended, "另一个世界还没结算")
	var fired: Array = []
	w2.game_over.connect(func(w): fired.append(w))
	Net.apply_snapshot(w2, ended)
	_ok(w2.game_ended, "★没结算过的世界照抄快照的胜负★")
	_eqi(w2.winner, World.ENEMY, "胜负抄对了")
	_eqi(fired.size(), 1, "★并且补发了 game_over 信号（客户端不跑 step，不补发界面永不弹）★")

	hs.close()
	cs.close()

	# ---- 主机认输 → 客户端获胜（反向也要对）----
	var r2 := _pair(PORT, 20260943)
	var h2: NetSession = r2[0]
	var c2: NetSession = r2[1]
	if h2 != null and c2 != null and h2.is_playing():
		var csurr: Array = []
		c2.peer_surrendered.connect(func(who): csurr.append(who))
		_ok(h2.surrender(), "主机认输（%s）" % h2.last_error)
		_eqi(h2.world.winner, World.ENEMY, "★主机视角：客户端获胜★")
		var s2 := _pump_until(h2, c2, func(): return c2.world.game_ended, 3000)
		_ok(s2, "★客户端收到主机投降并结算★")
		if s2:
			_eqi(c2.world.winner, World.ENEMY, "★客户端视角：自己获胜★")
		_eqi(csurr.size(), 1, "客户端收到 1 次 peer_surrendered")
		h2.close()
		c2.close()
