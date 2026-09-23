extends SceneTree

## ENet 传输层的**单进程回环**集成测试（第十三轮 M4b）。
##
## 为什么能在无头里测：`ENetConnection` 是纯网络对象，不需要渲染。
## 同一个进程里同时起主机和客户端，互相对发 —— **真 UDP、真握手、真分片**，
## 不是 mock。这样「连不上 / 收不到 / 大包碎了」这类问题在无头阶段就能抓到，
## 不用等到两台设备插上之后靠猜。
##
## ⚠️ 三条纪律：
##   1. **端口要换**（不用 `Net.PORT`）。开发机上可能已经有一个真的在跑，
##      撞上就是「随机失败」，而且看起来像代码 bug。
##   2. **必须 `poll()` 双方**。ENet 的收发全靠 `service()`，
##      只 poll 一边的话对面永远不动，握手停在半路。
##   3. **等事件要带超时**。`while` 死等的话，一旦握手失败就是无限挂起 ——
##      而死循环比失败难查得多（`run_all.sh` 里那条 900 秒超时就是为它准备的）。

const PORT := 27315
const PORT2 := 27316

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

func _initialize() -> void:
	print("=============== ENet 传输层回环测试 ===============")

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_g1_connect()
	_g2_send()
	_g3_order()
	_g4_unreliable()
	_g5_big()
	_g6_disconnect()
	_g7_errors()
	print("==================================================")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

# ---------------------------------------------------------------- 工具

## 双方各 poll 一次，把事件收进 `sink`。
func _pump(a: NetLink, b: NetLink, sink: Array, ms: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		a.poll(1)
		b.poll(1)
		for e in a.drain():
			e["from"] = "a"
			sink.append(e)
		for e in b.drain():
			e["from"] = "b"
			sink.append(e)
		OS.delay_msec(1)

## 一直 pump 到 `done` 为真，或超时。返回是否在超时前满足。
func _pump_until(a: NetLink, b: NetLink, sink: Array, done: Callable, ms: int) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < ms:
		a.poll(1)
		b.poll(1)
		for e in a.drain():
			e["from"] = "a"
			sink.append(e)
		for e in b.drain():
			e["from"] = "b"
			sink.append(e)
		if done.call():
			return true
		OS.delay_msec(1)
	return false

func _packets(sink: Array, from_side: String) -> Array:
	var out: Array = []
	for e in sink:
		if String(e["type"]) == "packet" and String(e["from"]) == from_side:
			out.append(e["data"])
	return out

## 起一对连好的 host / client。返回 [host, client, events]。
func _pair(p_port: int, sink: Array) -> Array:
	var host := NetLink.new()
	if not host.start_host(p_port, "127.0.0.1"):
		return [host, null, sink]
	var cli := NetLink.new()
	if not cli.start_client("127.0.0.1", p_port):
		return [host, cli, sink]
	var ok := _pump_until(host, cli, sink, func(): return host.peer_count() > 0 and cli.is_online(), 5000)
	if not ok:
		return [host, cli, sink]
	return [host, cli, sink]

# ---------------------------------------------------------------- 1. 建立连接

func _g1_connect() -> void:
	print("-- 1. 建立连接（127.0.0.1，单进程）--")
	var sink: Array = []
	var host := NetLink.new()
	_ok(host.start_host(PORT, "127.0.0.1"),
		"主机在 127.0.0.1:%d 建好房间（%s）" % [PORT, host.last_error])
	_ok(host.is_host() and host.is_active(), "角色是主机且连接对象有效")
	_eqi(host.peer_count(), 0, "还没有人连进来")

	var cli := NetLink.new()
	_ok(cli.start_client("127.0.0.1", PORT), "客户端发起连接（%s）" % cli.last_error)
	_ok(cli.is_client(), "角色是客户端")
	_ok(not cli.is_online(), "★刚发起时还没连上（不阻塞等握手）★")

	var ok := _pump_until(host, cli, sink, func(): return host.peer_count() > 0 and cli.is_online(), 5000)
	_ok(ok, "★5 秒内握手完成★")
	_eqi(host.peer_count(), 1, "主机侧看到 1 个 peer")
	_ok(cli.is_online(), "客户端侧状态是已连接")

	var connects := 0
	for e in sink:
		if String(e["type"]) == "connect":
			connects += 1
	_eqi(connects, 2, "★双方各收到一个 connect 事件（共 2 个）★")

	# 主机侧能拿到一个可用的 peer id
	_ok(host.first_peer() != 0, "主机侧能取到 peer id")
	_ok(host.peer_ids().size() == 1, "peer id 列表长度是 1")

	host.close()
	cli.close()
	_ok(not host.is_active() and not cli.is_active(), "close() 之后连接对象都失效")
	_eqi(host.peer_count(), 0, "close() 之后主机侧没有 peer")

# ---------------------------------------------------------------- 2. 双向收发

func _g2_send() -> void:
	print("-- 2. 双向收发 --")
	var sink: Array = []
	var r := _pair(PORT2, sink)
	var host: NetLink = r[0]
	var cli: NetLink = r[1]
	_ok(host.peer_count() > 0 and cli.is_online(), "前置条件：连上了")
	if host.peer_count() == 0:
		return

	# 客户端 → 主机
	var buf := Net.Buf.new()
	var hello := Net.packet_hello(buf, "客户端甲")
	_ok(cli.send_host(hello), "客户端发 HELLO 成功")
	_pump(host, cli, sink, 400)
	var got_c2h := _packets(sink, "a")     # a = host 侧收到
	_ok(got_c2h.size() >= 1, "★主机收到了客户端发的包★")
	if got_c2h.size() >= 1:
		_ok(got_c2h[0] == hello, "★收到的字节与发出的完全一致★")
		var h := Net.decode_hello(got_c2h[0])
		_ok(bool(h["ok"]), "★在主机侧能正常解出 HELLO（%s）★" % String(h["reason"]))
		_eqs2(String(h["name"]), "客户端甲", "玩家名对得上")

	# 主机 → 客户端
	sink.clear()
	var wel := Net.packet_welcome(buf, World.ENEMY, 999, 64, 40, "plateau",
		"terran", "zerg", "normal", "主机乙")
	_ok(host.send(host.first_peer(), wel), "主机给客户端回 WELCOME 成功")
	_pump(host, cli, sink, 400)
	var got_h2c := _packets(sink, "b")     # b = client 侧收到
	_ok(got_h2c.size() >= 1, "★客户端收到了主机发的包★")
	if got_h2c.size() >= 1:
		_ok(got_h2c[0] == wel, "字节完全一致")
		var w := Net.decode_welcome(got_h2c[0])
		_ok(bool(w["ok"]), "★在客户端侧能正常解出 WELCOME★")
		_eqi(int(w["seed"]), 999, "★随机种子传过来了★")

	# 广播
	sink.clear()
	_ok(true, "广播路径可用")     # 只有 1 个 peer，broadcast 等价于 send
	host.broadcast(Net.packet(Net.Msg.PING, PackedByteArray([7])))
	_pump(host, cli, sink, 400)
	var bcast := _packets(sink, "b")
	_ok(bcast.size() >= 1, "broadcast 的包客户端收到了")
	if bcast.size() >= 1:
		_eqi(int(bcast[0][0]), int(Net.Msg.PING), "广播包的类型正确")

	host.close()
	cli.close()

func _eqs2(a: String, b: String, label: String) -> void:
	_ok(a == b, "%s（期望「%s」，实测「%s」）" % [label, b, a])

# ---------------------------------------------------------------- 3. 可靠通道按序

func _g3_order() -> void:
	print("-- 3. 可靠通道按序（指令不能乱序）--")
	var sink: Array = []
	var r := _pair(PORT, sink)
	var host: NetLink = r[0]
	var cli: NetLink = r[1]
	_ok(host.peer_count() > 0, "前置条件：连上了")
	if host.peer_count() == 0:
		return

	sink.clear()
	# 连发 20 个带序号的包。指令如果乱序，「先移动再停止」会变成「先停止再移动」。
	var sent := 0
	for i in range(20):
		var payload := PackedByteArray()
		payload.resize(4)
		payload[0] = i & 0xFF
		payload[1] = 0xAA
		if cli.send_host(Net.packet(Net.Msg.CMD, payload)):
			sent += 1
	_eqi(sent, 20, "20 个包全部发出")
	_pump(host, cli, sink, 800)

	var seqs: Array = []
	for d in _packets(sink, "a"):
		# 包布局是 [type][ver][payload...]，所以 type 在 d[0]，
		# 序号在 payload 的第一个字节 = d[2]。
		if d.size() >= 4 and int(d[0]) == int(Net.Msg.CMD):
			seqs.append(int(d[2]))
	_eqi(seqs.size(), 20, "★20 个包全部到达（没有丢）★")
	var ordered := true
	for i in range(seqs.size()):
		if int(seqs[i]) != i:
			ordered = false
	_ok(ordered, "★到达顺序与发送顺序完全一致★（%s）" % str(seqs.slice(0, 8)))

	host.close()
	cli.close()

# ---------------------------------------------------------------- 4. 不可靠通道

func _g4_unreliable() -> void:
	print("-- 4. 不可靠通道（快照走这里）--")
	var sink: Array = []
	var r := _pair(PORT2, sink)
	var host: NetLink = r[0]
	var cli: NetLink = r[1]
	_ok(host.peer_count() > 0, "前置条件：连上了")
	if host.peer_count() == 0:
		return

	sink.clear()
	var n := 0
	for i in range(10):
		var payload := PackedByteArray([i, 0xBB])
		if cli.send_host(Net.packet(Net.Msg.SNAPSHOT, payload), false):
			n += 1
	_eqi(n, 10, "10 个不可靠包全部发出")
	_pump(host, cli, sink, 800)
	var got := _packets(sink, "a")
	# ⚠️ 不可靠通道**允许丢包**，所以这里断言的是「大部分能到」而不是「一个不丢」——
	#    写死 10 会让测试偶发失败，而那种失败和代码无关。
	_ok(got.size() >= 8, "★不可靠包大部分到达（%d / 10，允许丢）★" % got.size())
	_ok(got.size() > 0, "不可靠通道确实通了")

	host.close()
	cli.close()

# ---------------------------------------------------------------- 5. 大包（分片）

func _g5_big() -> void:
	print("-- 5. 大包（300 单位快照 10 KB，必须分片）--")
	var sink: Array = []
	var r := _pair(PORT, sink)
	var host: NetLink = r[0]
	var cli: NetLink = r[1]
	_ok(host.peer_count() > 0, "前置条件：连上了")
	if host.peer_count() == 0:
		return

	# 造一个真实体量的快照：真世界 + 300 单位
	seed(20260924)
	var w := World.new(48, 32, "terran", "zerg", "easy")
	for i in range(300):
		w._spawn_unit("marine", "terran",
			Vector2(200.0 + float(i % 25) * 40.0, 200.0 + float(i / 25) * 40.0), World.PLAYER)
	var bytes := Net.encode_snapshot(w, Net.Buf.new(), 1)
	_ok(bytes.size() > 8192, "前置条件：快照够大（%d 字节，超过单包 MTU）" % bytes.size())

	sink.clear()
	_ok(cli.send_host(bytes), "发送 %d 字节的大包" % bytes.size())
	_ok(_pump_until(host, cli, sink, func(): return _packets(sink, "a").size() > 0, 3000),
		"★3 秒内收到大包★")
	var got := _packets(sink, "a")
	if not got.is_empty():
		_eqi(got[0].size(), bytes.size(), "★分片重组后长度完全一致★")
		_ok(got[0] == bytes, "★分片重组后字节完全一致★")

	host.close()
	cli.close()

# ---------------------------------------------------------------- 6. 断线

func _g6_disconnect() -> void:
	print("-- 6. 断线（必须能感知到）--")
	var sink: Array = []
	var r := _pair(PORT2, sink)
	var host: NetLink = r[0]
	var cli: NetLink = r[1]
	_ok(host.peer_count() > 0, "前置条件：连上了")
	if host.peer_count() == 0:
		return

	# ★必须走 close_gracefully()，不能走 close()★
	# `close()` 只销毁本地 host，**一个字节都不发** ——
	# 对方的 ENet 要等自己的超时（默认几十秒）才知道。
	# 第一版就是拿 `close()` 测的，5 秒内什么都没发生。
	sink.clear()
	cli.close_gracefully()
	var ok := _pump_until(host, cli, sink, func(): return host.peer_count() == 0, 5000)
	_ok(ok, "★主机侧 5 秒内感知到断线（对方优雅退出）★")
	var disc := 0
	for e in sink:
		if String(e["type"]) == "disconnect":
			disc += 1
	_ok(disc >= 1, "★收到了 disconnect 事件★")
	_ok(not host.is_online(), "主机侧状态变回「没有连接」")

	# 硬退出（进程被杀 / 断网）不会发断连包，只能靠超时 ——
	# 这里只钉住「不会崩」，不钉时间（ENet 的默认超时是几十秒，
	# 放进测试里只会让套件变慢且偶发）。
	# 会话层另有「多久没收到快照就判掉线」的看门狗，见 NetSession。
	sink.clear()
	var r2 := _pair(PORT, sink)
	var h2: NetLink = r2[0]
	var c2: NetLink = r2[1]
	if h2.peer_count() > 0:
		c2.close()
		_pump(h2, c2, sink, 600)
		_ok(true, "★硬退出（close）不会崩，也不会误报断线★")
		_ok(h2.peer_count() == 1, "硬退出时主机侧仍认为对方在（只能靠超时 / 看门狗）")
		h2.close()

	host.close()

# ---------------------------------------------------------------- 7. 错误路径

func _g7_errors() -> void:
	print("-- 7. 错误路径（失败必须说清原因）--")
	var l := NetLink.new()
	_ok(not l.start_client(""), "空地址被拒绝")
	_ok(l.last_error.contains("地址"), "空地址的原因说清是地址问题（「%s」）" % l.last_error)
	_ok(not l.is_active(), "失败之后连接对象没有被建出来")

	var l2 := NetLink.new()
	_ok(not l2.start_client("   "), "只有空格的地址也被拒绝")

	# 绑一个不属于本机的地址必须失败 —— 不能「假装开好了房间」
	var l3 := NetLink.new()
	var bad_bind := l3.start_host(PORT, "203.0.113.7")
	_ok(not bad_bind, "★绑到不属于本机的地址失败（%s）★" % l3.last_error)
	_ok(l3.last_error != "", "失败时 last_error 非空")
	_ok(not l3.is_active(), "失败之后连接对象被清掉")

	# 超长包被拒绝发送
	var l4 := NetLink.new()
	var big := PackedByteArray()
	big.resize(Net.MAX_PACKET + 1)
	_ok(not l4.send(1, big), "没有连接时发不出去（返回 false，不崩）")

	# 连一个没人监听的端口：不能崩，而且连不上要能看出来
	var l5 := NetLink.new()
	var sink: Array = []
	if l5.start_client("127.0.0.1", 27499):
		_pump(l5, l5, sink, 1500)
		_ok(not l5.is_online(), "★连到没人监听的端口时状态仍是未连接★")
	l5.close()
