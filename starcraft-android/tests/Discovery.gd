extends SceneTree

## 局域网房间发现的无头验证（第十三轮 M4c）。
##
## 为什么单独一套：`NetDiscovery` 用的是**裸 `PacketPeerUDP`**，
## 和 `NetLink` 的 ENet 是两套互不相干的 socket ——
## 它俩的失败形态完全不一样（ENet 是「连不上」，UDP 是「收不到」），
## 混在一套里排查起来会互相干扰。
##
## ⚠️ 三条纪律（都是踩过的）：
##   1. **端口必须错开**：NetLink 27315/16、NetSession 27515/16、
##      Lan 27615/16、**本套 27815/16**。同一台机器上连续跑不撞。
##   2. **广播地址必须可注入**：单进程测试里发到 `255.255.255.255`
##      **不一定回环到本机自己的监听端口**，要发 `127.0.0.1`。
##      这也是 `start_advertise()` 多一个 `p_addr` 参数的唯一理由。
##   3. **虚拟时钟**：`poll(delta)` 的 delta 是累加的虚拟时间，
##      所以「TTL 过期」这类断言可以瞬间跑完，不用真的等 3.5 秒。

const PORT := 27815
const PORT2 := 27816

## 一帧虚拟时间。用 1/60 秒模拟真实帧率。
const FRAME := 1.0 / 60.0

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

func _eqs(a: String, b: String, label: String) -> void:
	_ok(a == b, "%s（期望「%s」，实测「%s」）" % [label, b, a])

func _eqi(a: int, b: int, label: String) -> void:
	_ok(a == b, "%s（期望 %d，实测 %d）" % [label, b, a])

func _initialize() -> void:
	print("=============== 局域网房间发现测试 ===============")

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_g1_roundtrip()
	_g2_reject()
	_g3_discover()
	_g4_ttl()
	_g5_stop()
	_g6_order_and_cap()
	print("================================================")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

# ---------------------------------------------------------------- 工具

## 推 `frames` 帧虚拟时间。
func _pump(d, frames: int) -> void:
	for i in range(frames):
		d.poll(FRAME)

## 造一份「主机公告」用的信息。
func _info(host_name := "指挥官", map := "plateau", race := "terran",
		players := 1, started := false) -> Dictionary:
	return {
		"host_name": host_name, "game_port": Net.PORT,
		"players": players, "max_players": 2, "started": started,
		"map_preset": map, "host_race": race,
	}

func _announce(info: Dictionary) -> PackedByteArray:
	var buf := Net.Buf.new()
	return NetDiscovery.encode_announce(buf, info)

# ---------------------------------------------------------------- 1. 往返

func _g1_roundtrip() -> void:
	print("-- 1. 公告编解码往返 --")
	var info := _info("老王", "river", "zerg", 2, true)
	var d := _announce(info)
	var a := NetDiscovery.decode_announce(d)
	_ok(bool(a["ok"]), "★自己编的包能解回来★（%s）" % String(a["reason"]))
	_eqs(String(a["host_name"]), "老王", "主机名往返一致（含中文）")
	_eqi(int(a["game_port"]), Net.PORT, "游戏端口往返一致")
	_eqi(int(a["players"]), 2, "人数往返一致")
	_eqi(int(a["max_players"]), 2, "上限往返一致")
	_ok(bool(a["started"]), "★已开局标记往返一致★")
	_eqs(String(a["map_preset"]), "river", "地图往返一致")
	_eqs(String(a["host_race"]), "zerg", "阵营往返一致")

	# 缺键时走缺省值，不报错 —— 公告是「尽力而为」的信息
	var bare := NetDiscovery.decode_announce(_announce({}))
	_ok(bool(bare["ok"]), "★缺字段的公告照样能解（不拒收整个房间）★")
	_eqi(int(bare["game_port"]), Net.PORT, "缺 game_port 时走缺省值")
	_eqi(int(bare["max_players"]), 2, "缺 max_players 时走缺省值")

	# 复用同一个 Buf 连编 1000 次，字节必须完全一致（否则「公告比对」做不了）
	var buf := Net.Buf.new()
	var first := NetDiscovery.encode_announce(buf, info)
	var same := true
	for i in range(1000):
		if NetDiscovery.encode_announce(buf, info) != first:
			same = false
	_ok(same, "★同一个 Buf 连编 1000 次字节完全一致★")

# ---------------------------------------------------------------- 2. 畸形包

func _g2_reject() -> void:
	print("-- 2. 畸形包必须被拒 --")
	var good := _announce(_info())

	# magic 错：局域网里飘着的不止我们一家
	var bad_magic := good.duplicate()
	bad_magic[0] = (bad_magic[0] + 1) & 0xFF
	var r1 := NetDiscovery.decode_announce(bad_magic)
	_ok(not bool(r1["ok"]), "★magic 不对的包被拒（%s）★" % String(r1["reason"]))

	# 版本错
	var bad_ver := good.duplicate()
	bad_ver[4] = 99
	var r2 := NetDiscovery.decode_announce(bad_ver)
	_ok(not bool(r2["ok"]), "★版本不一致的包被拒（%s）★" % String(r2["reason"]))

	# 空包 / 极短包
	_ok(not bool(NetDiscovery.decode_announce(PackedByteArray())["ok"]), "空包被拒")
	_ok(not bool(NetDiscovery.decode_announce(PackedByteArray([1, 2, 3]))["ok"]), "3 字节包被拒")

	# ★多种截断长度都要被拒且不崩★（只测一个长度会漏掉「刚好切在字段边界」的那种）
	var trunc_bad := 0
	var trunc_total := 0
	for cut in range(1, good.size()):
		trunc_total += 1
		var r := NetDiscovery.decode_announce(good.slice(0, cut))
		# 截断包「ok」的前提是它恰好只切掉了尾部的空字符串 ——
		# 那种情况解出来的 host_race 会是空的，属于可接受。
		if bool(r["ok"]) and String(r["host_race"]) != "":
			trunc_bad += 1
	_eqi(trunc_bad, 0, "★%d 种截断长度里没有一条解出「非空但错」的结果★" % trunc_total)

	# 端口非法（0）
	var bad_port := _announce(_info())
	bad_port[5] = 0
	bad_port[6] = 0
	var r3 := NetDiscovery.decode_announce(bad_port)
	_ok(not bool(r3["ok"]), "★端口为 0 的公告被拒（%s）★" % String(r3["reason"]))

	# 阳性对照：把 magic 校验去掉，上面第一条必须变绿（证明它不是恒真的）
	# ⚠️ 这里没法在运行时「去掉校验」，所以改成直接验证校验确实读到了那个字节：
	#    改回去之后必须又能解 —— 一正一反构成对照。
	bad_magic[0] = good[0]
	_ok(bool(NetDiscovery.decode_announce(bad_magic)["ok"]),
		"★阳性对照：把 magic 改回去就又能解（证明上一条不是恒真的）★")

# ---------------------------------------------------------------- 3. 单进程发现

func _g3_discover() -> void:
	print("-- 3. 单进程发现（真 UDP） --")
	var host := NetDiscovery.new()
	var client := NetDiscovery.new()
	var ok_h := host.start_advertise(_info("老王", "river", "zerg"), PORT, NetDiscovery.LOOPBACK)
	_ok(ok_h, "主机开始广播（%s）" % host.last_error)
	var ok_c := client.start_browse(PORT)
	_ok(ok_c, "客户端开始搜索（%s）" % client.last_error)
	_eqs(host.mode_name(), "advertise", "主机模式正确")
	_eqs(client.mode_name(), "browse", "客户端模式正确")

	_pump(host, 4)
	_pump(client, 4)
	_ok(host.announces_sent >= 1, "★主机真的发出去了（%d 条）★" % host.announces_sent)
	_ok(client.announces_received >= 1,
		"★客户端真的收到了（%d 条）★" % client.announces_received)
	_eqi(client.room_count(), 1, "★客户端看到 1 个房间★")

	var rooms := client.rooms()
	if rooms.size() > 0:
		var r: Dictionary = rooms[0]
		_eqs(String(r["name"]), "老王", "房间名对得上")
		_eqs(String(r["map"]), "river", "地图对得上")
		_eqs(String(r["race"]), "zerg", "阵营对得上")
		_eqi(int(r["port"]), Net.PORT, "★记的是公告里的游戏端口，不是发包的源端口★")
		_ok(String(r["ip"]) == NetDiscovery.LOOPBACK, "来源 IP 正确（%s）" % String(r["ip"]))

	# 重复公告不该产生重复房间
	_pump(host, 70)          # > 1 秒，会再广播一次
	_pump(client, 4)
	_ok(host.announces_sent >= 2, "过一会儿主机又广播了一次（%d 条）" % host.announces_sent)
	_eqi(client.room_count(), 1, "★同一个房间重复公告不会变成两个★")
	_ok(client.announces_received >= 2, "客户端累计收到 %d 条" % client.announces_received)

	# 第二个主机（另一个游戏端口）→ 两个房间
	var host2 := NetDiscovery.new()
	host2.start_advertise({"host_name": "小李", "game_port": Net.PORT + 1}, PORT, NetDiscovery.LOOPBACK)
	_pump(host2, 4)
	_pump(client, 4)
	_eqi(client.room_count(), 2, "★第二个房间被认出来了（不同 game_port）★")
	_ok(client.has_room(NetDiscovery.LOOPBACK, Net.PORT), "能按「地址:端口」查到房间 A")
	_ok(client.has_room(NetDiscovery.LOOPBACK, Net.PORT + 1), "能按「地址:端口」查到房间 B")

	host.stop()
	host2.stop()
	client.stop()
	_eqs(client.mode_name(), "off", "客户端已停止")
	_eqi(client.room_count(), 0, "停止后房间列表清空")

# ---------------------------------------------------------------- 4. TTL

func _g4_ttl() -> void:
	print("-- 4. 房间会过期 --")
	var host := NetDiscovery.new()
	var client := NetDiscovery.new()
	host.start_advertise(_info(), PORT, NetDiscovery.LOOPBACK)
	client.start_browse(PORT)
	_pump(host, 4)
	_pump(client, 4)
	_eqi(client.room_count(), 1, "前置条件：先看到一个房间")

	# 主机停掉，客户端继续 poll —— 房间必须在 ROOM_TTL 之后消失
	host.stop()
	var ttl := NetDiscovery.ROOM_TTL
	# 推到「刚好还没到 TTL」
	_pump(client, int((ttl - 0.5) / FRAME))
	_eqi(client.room_count(), 1, "★还没到 TTL 时房间还在（%.1f 秒）★" % (ttl - 0.5))
	# 再推过去
	_pump(client, int(1.0 / FRAME) + 2)
	_eqi(client.room_count(), 0, "★超过 TTL 之后房间消失（%.1f 秒）★" % (ttl + 0.5))

	# 阳性对照：TTL 判据必须是「大于」而不是「大于等于 0」——
	# 若 TTL 被写成 0，房间会在第一帧就消失，上面那条「还在」就会红。
	_ok(ttl > NetDiscovery.ANNOUNCE_INTERVAL,
		"★阳性对照：TTL(%.1f) 必须大于广播周期(%.1f)★" % [ttl, NetDiscovery.ANNOUNCE_INTERVAL])

	client.stop()

# ---------------------------------------------------------------- 5. 停止后收不到

func _g5_stop() -> void:
	print("-- 5. 停止之后一个包都不该再收 --")
	var host := NetDiscovery.new()
	var client := NetDiscovery.new()
	host.start_advertise(_info(), PORT, NetDiscovery.LOOPBACK)
	client.start_browse(PORT)
	_pump(host, 4)
	_pump(client, 4)
	_eqi(client.room_count(), 1, "前置条件：收到一个房间")

	var before := client.announces_received
	client.stop()
	_pump(host, 70)          # 主机继续广播
	_pump(client, 10)        # 但客户端已经停了
	_eqi(client.announces_received, before,
		"★停止后计数不再增长（仍是 %d）★" % before)
	_eqi(client.room_count(), 0, "停止后房间列表为空")
	_eqs(client.mode_name(), "off", "模式回到 off")

	# ⚠️ 阳性对照：如果 stop() 只关了 sender 没关 listener，
	#    上面的计数就会继续涨。这里显式确认 listener 真的被释放了 ——
	#    重新 bind 同一个端口必须成功（没被自己占着）。
	var again := NetDiscovery.new()
	var ok2 := again.start_browse(PORT)
	_ok(ok2, "★阳性对照：停掉之后同一个端口能重新绑上（%s）★" % again.last_error)
	again.stop()
	host.stop()

# ---------------------------------------------------------------- 6. 排序与上限

func _g6_order_and_cap() -> void:
	print("-- 6. 排序与上限 --")
	var client := NetDiscovery.new()
	client.start_browse(PORT2)

	# 造 3 个房间，依次到，最后一个应当排最前
	var hosts: Array = []
	for i in range(3):
		var h := NetDiscovery.new()
		h.start_advertise({"host_name": "H%d" % i, "game_port": Net.PORT + i},
			PORT2, NetDiscovery.LOOPBACK)
		_pump(h, 4)
		_pump(client, 6)
		hosts.append(h)
	_eqi(client.room_count(), 3, "三个房间都在")

	var rs := client.rooms()
	var newest_first := true
	for i in range(1, rs.size()):
		if float((rs[i - 1] as Dictionary)["seen_at"]) < float((rs[i] as Dictionary)["seen_at"]):
			newest_first = false
	_ok(newest_first, "★列表按「最近看到」降序（刚看到的在最前）★")
	_eqs(String((rs[0] as Dictionary)["name"]), "H2", "最后广播的排第一")

	# 上限：灌进超过 MAX_ROOMS 个不同房间，列表不能无限涨
	for i in range(NetDiscovery.MAX_ROOMS + 5):
		var h2 := NetDiscovery.new()
		h2.start_advertise({"host_name": "X%d" % i, "game_port": 30000 + i},
			PORT2, NetDiscovery.LOOPBACK)
		_pump(h2, 2)
		_pump(client, 3)
		h2.stop()
	_eqi(client.room_count(), NetDiscovery.MAX_ROOMS,
		"★房间数被夹在 MAX_ROOMS(%d)★" % NetDiscovery.MAX_ROOMS)
	# 阳性对照：上限不是「拒绝新房间」而是「踢最旧的」——
	# 最后那批必须还在，否则「先来的一堆僵尸房间」会把真房间永远挡在外面。
	var has_newest := false
	for r in client.rooms():
		if String((r as Dictionary)["name"]) == "X%d" % (NetDiscovery.MAX_ROOMS + 4):
			has_newest = true
	_ok(has_newest, "★阳性对照：新房间进得来（踢的是最旧的那条）★")

	client.stop()
	for h in hosts:
		(h as NetDiscovery).stop()
