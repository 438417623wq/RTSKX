extends RefCounted
class_name NetLink

## ENet 传输层（第十三轮 M4b）。
##
## 只做一件事：把「主机 / 客户端 / 收发 / 断线」包成一个小接口，
## **不掺任何协议语义**（握手、快照、指令都在 `Net` / `NetSession` 里）。
##
## 这样切分是为了让它可以被**单进程回环测试**完整覆盖 ——
## 真 UDP、真握手，而不是 mock。见 `tests/NetLink.gd`。
##
## ⚠️ 两条纪律：
##   1. **`poll()` 必须每帧调一次**，而且要在主线程。ENet 的收发全靠 `service()`。
##   2. 快照走**不可靠**通道，指令 / 握手走**可靠**通道。
##      快照丢了下一份马上就来（10 Hz），为它做重传只会让延迟更大；
##      而丢一条「造兵」指令玩家是能看见的。

enum Role { NONE, HOST, CLIENT }

## 通道 0 = 可靠有序（握手 / 指令 / 聊天）；通道 1 = 不可靠（快照）。
const CH_RELIABLE := 0
const CH_STATE := 1
const CHANNELS := 2

## 默认绑定到所有网卡 —— 安卓上要连同一个 WiFi，绑 `127.0.0.1` 就没法被连上了。
## 测试里改成 `127.0.0.1`，避免触发防火墙授权弹窗。
const BIND_ALL := "*"

var role := Role.NONE
var bind_port := Net.PORT
var last_error := ""

var _conn: ENetConnection = null
## peer 实例 id → ENetPacketPeer。用 `get_instance_id()` 而不是「数组下标」：
## 下标会在有 peer 断开之后整体前移，而会话层是按 id 记住「谁是客户端」的。
var _peers := {}
var _events: Array = []
## 客户端专用：连上主机之后的那一端。
var _host_peer: ENetPacketPeer = null
var _client_connected := false

# ---------------------------------------------------------------- 建立 / 关闭

## 开一个房间（主机）。失败时 `last_error` 里是能直接显示给玩家的原因。
func start_host(p_port: int = Net.PORT, bind_addr: String = BIND_ALL) -> bool:
	close()
	_conn = ENetConnection.new()
	# ⚠️ 端口被占用时必须**明确失败**，不能「假装开好了」——
	#    否则玩家看到「房间已创建」然后对方怎么都连不上，无从排查。
	var err := _conn.create_host_bound(bind_addr, p_port, 4, CHANNELS)
	if err != OK:
		last_error = "端口 %d 被占用或无法绑定（错误码 %d）" % [p_port, err]
		_conn = null
		return false
	role = Role.HOST
	bind_port = p_port
	last_error = ""
	return true

## 加入一个房间（客户端）。
func start_client(ip: String, p_port: int = Net.PORT) -> bool:
	close()
	if ip.strip_edges() == "":
		last_error = "请填写主机地址"
		return false
	_conn = ENetConnection.new()
	var err := _conn.create_host(4, CHANNELS)
	if err != OK:
		last_error = "本机无法建立网络连接（错误码 %d）" % err
		_conn = null
		return false
	# ⚠️ 这里**不阻塞等握手**。ENet 的 connect 是异步的，
	#    真正的结果在后续 `poll()` 的 EVENT_CONNECT / EVENT_ERROR 里。
	#    阻塞等待的话，UI 会卡住，而且「连不上」要等好几秒才有反馈。
	_host_peer = _conn.connect_to_host(ip.strip_edges(), p_port, CHANNELS, 0)
	if _host_peer == null:
		last_error = "无法连接到 %s:%d" % [ip, p_port]
		_conn = null
		return false
	role = Role.CLIENT
	bind_port = p_port
	_client_connected = false
	last_error = ""
	return true

func close() -> void:
	if _conn != null:
		_conn.destroy()
	_conn = null
	_peers.clear()
	_events.clear()
	_host_peer = null
	_client_connected = false
	role = Role.NONE

## 优雅退出：先告诉对方「我走了」，再销毁本地连接。
##
## ⚠️ **`close()` 只调 `enet_host_destroy`，不会给对方发任何东西。**
##    对方的 ENet 要等自己的超时（默认几十秒）才会报断开 ——
##    玩家看到的是「对方明明已经退了，我这边还在等他出兵」。
##    所以正常退出（点返回、关对局）**必须走这里**。
##
## ⚠️ 断连包也是攒在发送队列里的，`peer_disconnect()` 之后必须
##    再 `service()` 几次才真的出去。少了这个循环，等于白调。
func close_gracefully() -> void:
	if _conn == null:
		close()
		return
	if role == Role.CLIENT:
		if _host_peer != null:
			_host_peer.peer_disconnect(0)
	else:
		for k in _peers:
			var p: ENetPacketPeer = _peers[k]
			if p != null:
				p.peer_disconnect(0)
	for i in range(8):
		_conn.service(5)
		_conn.flush()
	close()

func is_active() -> bool:
	return _conn != null

func is_host() -> bool:
	return role == Role.HOST

func is_client() -> bool:
	return role == Role.CLIENT

func is_online() -> bool:
	if role == Role.CLIENT:
		return _client_connected
	return _peers.size() > 0

## 主机侧：已经连上的 peer 数量。
func peer_count() -> int:
	return _peers.size()

func peer_ids() -> Array:
	return _peers.keys()

## 主机侧：第一个连上来的 peer 的 id（2 人局够用）。
## 没有 peer 时返回 0（`send(0, ...)` 会静默丢弃）。
func first_peer() -> int:
	var ks := _peers.keys()
	return int(ks[0]) if not ks.is_empty() else 0

# ---------------------------------------------------------------- 轮询

## 收一次网络事件。**每帧都要调**（哪怕 `timeout_ms = 0`）。
##
## ★`ENetConnection.service()` 返回的是**扁平数组**，不是「字典的数组」。★
##   每个事件占 **4 个连续元素**：`[type, peer, channel_id, data]`。
##
##   第一版按「`for e in evs: e["type"]`」写（网上不少示例是那样），
##   结果 `typeof(e) != TYPE_DICTIONARY` 把**所有**事件都过滤掉了 ——
##   症状是「双方都 poll 了，但永远连不上」，而且**一个报错都没有**。
##
##   ⚠️ 空转时它也会返回一组 `[EVENT_NONE, null, 0, 0]`，
##      所以**不能靠「返回数组非空」判断有没有事件**。
func poll(timeout_ms: int = 0) -> void:
	if _conn == null:
		return
	var evs: Array = _conn.service(timeout_ms)
	if evs.is_empty():
		return
	if typeof(evs[0]) == TYPE_DICTIONARY:
		# 引擎换了返回形态。**响亮地失败**，别静默什么都不做 ——
		# 静默的话症状就是「连不上」，而根因隔了十万八千里。
		push_error("[NetLink] ENetConnection.service() 的返回形态变了"
			+ "（不再是扁平四元组），poll() 需要跟着改")
		return
	var i := 0
	while i + 1 < evs.size():
		var t := int(evs[i])
		var p: ENetPacketPeer = evs[i + 1]
		var ch := int(evs[i + 2]) if i + 2 < evs.size() else 0
		match t:
			ENetConnection.EVENT_CONNECT:
				if p != null:
					_peers[p.get_instance_id()] = p
					if role == Role.CLIENT:
						_client_connected = true
						_host_peer = p
					_push("connect", p, PackedByteArray())
			ENetConnection.EVENT_DISCONNECT:
				if p != null:
					_peers.erase(p.get_instance_id())
					if role == Role.CLIENT:
						_client_connected = false
					_push("disconnect", p, PackedByteArray())
			ENetConnection.EVENT_RECEIVE:
				if p != null and p.get_available_packet_count() > 0:
					# ⚠️ 先判 `get_available_packet_count()` ——
					#    空队列时 `get_packet()` 会 `ERR_UNAVAILABLE` 并返回空数组，
					#    看起来像「收到一个空包」，会把调用方带偏。
					_push("packet", p, p.get_packet())
			ENetConnection.EVENT_ERROR:
				last_error = "网络错误"
				_events.append({"type": "error", "peer": 0, "data": PackedByteArray()})
			_:
				pass                      # EVENT_NONE：空转，正常情况
		i += 4

func _push(kind: String, p: ENetPacketPeer, data: PackedByteArray) -> void:
	_events.append({"type": kind, "peer": p.get_instance_id(), "data": data})

## 取出并清空本帧攒下的事件。
func drain() -> Array:
	var out := _events
	_events = []
	return out

## 主机侧：把 peer 从表里摘掉（会话层踢人时用）。
func forget_peer(peer_id: int) -> void:
	_peers.erase(peer_id)

# ---------------------------------------------------------------- 收发

func send(peer_id: int, data: PackedByteArray, reliable: bool = true) -> bool:
	if _conn == null:
		return false
	var p: ENetPacketPeer = _peers.get(peer_id, null)
	if p == null:
		return false
	return _send(p, data, reliable)

func broadcast(data: PackedByteArray, reliable: bool = true) -> void:
	for k in _peers:
		_send(_peers[k], data, reliable)

func _send(p: ENetPacketPeer, data: PackedByteArray, reliable: bool) -> bool:
	# 超过单包上限的直接丢 —— 不丢的话 ENet 会自己分片，
	# 而分片失败的报错信息对排查毫无帮助。
	if data.size() > Net.MAX_PACKET:
		push_error("[NetLink] 拒绝发送 %d 字节的包（上限 %d）" % [data.size(), Net.MAX_PACKET])
		return false
	var ch := CH_RELIABLE if reliable else CH_STATE
	var flags := ENetPacketPeer.FLAG_RELIABLE if reliable else ENetPacketPeer.FLAG_UNRELIABLE_FRAGMENT
	var err := p.send(ch, data, flags)
	if err != OK:
		last_error = "发送失败（错误码 %d）" % err
		return false
	# ⚠️ **发完立刻 flush**。ENet 平时把包攒在发送队列里，等下一次
	#    `service()` 才真正发出去。只发不 poll 的话，包会一直躺在队列里 ——
	#    症状是「发出去了但对方永远收不到」，而且 `send()` 返回的是 OK。
	_conn.flush()
	return true

## 主机侧：给指定 peer 回包（`peer_id` 来自事件）。
func send_back(peer_id: int, data: PackedByteArray, reliable: bool = true) -> bool:
	return send(peer_id, data, reliable)

## 客户端侧：给主机发包。
func send_host(data: PackedByteArray, reliable: bool = true) -> bool:
	if _host_peer == null or not _client_connected:
		return false
	return _send(_host_peer, data, reliable)

## 主动断开某个 peer（主机踢人）。
func disconnect_peer(peer_id: int) -> void:
	var p: ENetPacketPeer = _peers.get(peer_id, null)
	if p != null:
		p.peer_disconnect(0)

## 往返延迟（毫秒）。大厅里显示「延迟 12ms」用。
##
## ⚠️ `ENetPacketPeer.ping()` 返回 **void** —— 它只是「发一个 ping」，
##    RTT 要用 `get_statistic(PEER_ROUND_TRIP_TIME)` 读。
##    第一版写成 `return p.ping()`，报的是
##    「Cannot get return value of call to "ping()" because it returns "void"」，
##    而且**整个脚本编译失败** → 调用方拿到的 `NetLink` 变成一个空 GDScript，
##    报错变成「Nonexistent function 'new' in base 'GDScript'」——
##    和真正的原因隔了两层，很容易查错方向。
func rtt_of(peer_id: int) -> int:
	var p: ENetPacketPeer = null
	if role == Role.CLIENT:
		p = _host_peer
	else:
		p = _peers.get(peer_id, null)
	if p == null:
		return -1
	return int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))

# ---------------------------------------------------------------- 本机地址（给玩家照着输）

## 本机在局域网里的 IPv4 地址列表，**按「像不像一个真的局域网地址」排好序**。
##
## 玩家要在主机屏幕上看到这个地址，然后到另一台上手动输进去 ——
## 这就是「手动输 IP 直连」的全部 UX。**取不到时返回空数组**，
## 由调用方决定怎么提示（不要在这里编一个假地址，那会让玩家白输一遍）。
##
## ⚠️ **必须排序。** 一台装了 VMware / Hyper-V / WSL / 虚拟网卡的开发机
##    会返回**七八个**地址（实测 8 个），全列出来玩家根本不知道该输哪个；
##    而且它们在屏幕上会排成一行冲出两侧（`draw_string` 既不换行也不裁剪）。
##    排序之后「第一个」就是最该让玩家输的那个。
static func local_ipv4_list() -> Array:
	var out: Array = []
	for a in IP.get_local_addresses():
		var s := String(a)
		if s.contains(":"):
			continue                       # IPv6 先不列
		if s.begins_with("127."):
			continue                       # 回环
		out.append(s)
	# `sort_custom` 是**不稳定**的，所以同 rank 之间要保持原始相对顺序 ——
	# 这里再带上下标做次级键，避免「每次刷新顺序都不一样」。
	var idx := {}
	for i in range(out.size()):
		idx[out[i]] = i
	out.sort_custom(func(a, b):
		var ra := ip_rank(a)
		var rb := ip_rank(b)
		if ra != rb:
			return ra < rb
		return int(idx[a]) < int(idx[b]))
	return out

## 地址「像不像一个能连的局域网地址」的权重，**小的排前面**。
##
## - `192.168.*` 家用路由器最常见 → 0
## - `10.*` / `172.16~31.*` 企业网 → 1
## - 其它（公网 / 非常见私网）→ 5
## - `169.254.*` 是 **APIPA**：没拿到 DHCP，两边**基本连不通** → 9
##
## ⚠️ 不做**硬过滤**，只排序 —— 如果机器上只有 APIPA 地址，
##    显示它总比显示「没检测到」更有用（玩家至少能确认网卡在）。
static func ip_rank(s: String) -> int:
	if s.begins_with("192.168."):
		return 0
	if s.begins_with("10."):
		return 1
	if s.begins_with("172."):
		var parts := s.split(".")
		if parts.size() >= 2:
			var b := int(parts[1])
			if b >= 16 and b <= 31:
				return 1
	if s.begins_with("169.254."):
		return 9
	return 5
