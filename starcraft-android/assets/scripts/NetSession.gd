extends RefCounted
class_name NetSession

## 局域网会话层（第十三轮 M4b-4）。
##
## 它把 `Net`（纯数据协议）+ `NetLink`（纯传输）拼成一个**能跑一局的状态机**：
##
## ```
##   主机    等连接 → 收 HELLO → 回 WELCOME → 每 1/10 秒广播快照
##                                    ↓
##                            收 CMD → apply_cmd → 失败回 REJECT
##
##   客户端  连主机 → 发 HELLO → 等 WELCOME → 用**主机下发的种子**建世界
##                                    ↓
##                            收快照 → apply_snapshot → client_frame 刷视野
##                            收 REJECT → 攒起来给 UI 弹提示
## ```
##
## ★**权威模拟只在主机。**★ 客户端一行 `world.step()` 都不跑 ——
## 它只把主机发来的状态贴上去再画出来。代价是带宽（10 Hz 快照），
## 收益是**没有状态漂移**：锁步方案里两端的浮点累积误差会让
## 「我的兵明明没死」这种问题在十分钟后集中爆发，而且无法回溯。
##
## ⚠️ 每帧调用顺序：
##   主机  ：`world.step(d)` → `session.step(d)`
##   客户端：**只** `session.step(d)`（它内部会调 `world.client_frame`）
##
##   顺序反过来（客户端自己 `step()`）的话，客户端会**自己跑一套模拟**，
##   然后每 1/10 秒被主机快照整体覆盖 —— 表现为单位「抖动 / 回弹」。

enum State { IDLE, HOSTING, CONNECTING, LOBBY, PLAYING, FAILED, CLOSED }

# ---------------------------------------------------------------- 超时与限流
#
# ⚠️ 全部用**累加的 `_now`** 而不是 `Time.get_ticks_msec()`。
#    用真实时钟的话，测试里想验「握手超时」就得真的 sleep 8 秒，
#    整套测试从「毫秒级」变成「十几秒」，而且会随机器负载变红。

## 主机侧：peer 连上来之后多久没发 HELLO 就踢掉。
const HANDSHAKE_TIMEOUT := 8.0
## 客户端侧：发起连接后多久没完成 ENet 握手就报失败。
const CONNECT_TIMEOUT := 8.0
## 客户端侧：多久没收到快照就判「与主机失去联系」。
## 快照是 10 Hz，5 秒 = 连丢 50 份 —— 已经不是「网络抖动」了。
const SNAPSHOT_TIMEOUT := 5.0
## 应用层心跳间隔（大厅阶段没有快照，靠它证明对方还活着）。
const PING_INTERVAL := 1.0
## 单帧最多处理多少条指令。
##
## ⚠️ **必须有。** 一条被改过的客户端可以每帧灌几千条 `BUILD`，
##    主机要在同帧里逐条 `can_place_building`（每次都要扫一遍地图格子），
##    结果是**主机被卡死、客户端自己没事** —— 最坏的那种 DoS。
const MAX_CMD_PER_FRAME := 32
## 单帧最多处理多少条聊天。
##
## ⚠️ 和指令限流**同理但独立计数**。共用一个计数器的话，
##    「一边打仗一边打字」时聊天会把指令额度吃掉（反之亦然）——
##    表现成「打着打着某个操作突然没反应」，而且只在手快时复现。
const MAX_CHAT_PER_FRAME := 4

# ---------------------------------------------------------------- 信号

## 世界已就绪，可以进**大厅**画面了。
## 主机在握手完成时发（不是 `start_host()` 时 —— 那会儿还没人来）；
## 客户端在收到 `WELCOME` 并建好世界之后发。
##
## ⚠️ M4c 起它**不再表示「对局开始了」** —— 那是 `game_started`。
##    改名的代价太大（`Main` 里接了一堆），所以保留名字、改语义，
##    并在这里写清楚。**收到它就切到大厅页，不要切对局页。**
signal session_ready()
## 大厅里的「准备状态」变了（客户端点了准备 / 取消准备，或对方进出）。
signal lobby_updated()
## 对局真的开始了（主机点了开始）。双方都会收到。
signal game_started()
## 会话终止（连不上 / 掉线 / 被拒）。`reason` 是能直接显示给玩家的中文。
signal session_failed(reason: String)
## 主机侧：客户端握手完成，可以开局了。
signal peer_joined(peer_id: int)
## 任一侧：对方离开了。`reason` 区分「对方退了」和「对方掉线了」。
signal peer_left(peer_id: int, reason: String)
## 客户端侧：主机拒绝了一条指令（资源不足 / 位置不对 / 不是你的单位…）。
signal cmd_rejected(seq: int, reason: String)
## 收到对方发来的聊天。`from_name` 是**本端记录的**对方名字
## （包里不带名字 —— 带了的话客户端能冒充主机说话）。
signal chat_received(from_name: String, text: String)
## 对方认输了。`who` 是认输的一方在**本端视角**下的 owner。
signal peer_surrendered(who: int)
## 暂停状态变了。**只有主机能改**，客户端收到的是主机广播的结果。
signal pause_changed(paused: bool)

# ---------------------------------------------------------------- 状态

var state := State.IDLE
var link := NetLink.new()

## 本会话的世界。主机侧是**权威**世界；客户端侧是**副本**。
var world: World = null
## 本局的随机种子。客户端是主机下发的那个 —— 必须原样交给 `seed()`。
var world_seed := 0

var local_owner := World.PLAYER
var remote_owner := World.ENEMY
var host_name := "主机"
var player_name := "玩家"
## 最近一次失败 / 拒绝的原因，供 UI 直接显示。
var last_error := ""

# ---- 统计（测试与调试面板用）----
var snapshots_sent := 0
var snapshots_received := 0
var cmds_applied := 0
var cmds_rejected := 0
var cmds_dropped := 0
var pings_received := 0
var pongs_received := 0
var chats_received := 0
var chats_dropped := 0
## 包头不合法 / 半包 / 版本不符的包数。**不是 0 才要看** ——
## 一直涨说明有人在往端口上乱发，或者两端版本不同。
var bad_packets := 0
## 合法但本会话不处理的包。
var unknown_packets := 0

# ---------------------------------------------------------------- 内部

var _now := 0.0
var _tick := 0
var _seq := 0
var _snap_timer := 0.0
var _since_snapshot := 0.0
var _connect_started := 0.0
var _connected_at := 0.0
var _ping_timer := PING_INTERVAL
var _ping_sent_at := -1.0
var _rtt_ms := -1
## 主机侧：当前那个客户端的 peer id。0 = 还没有人。
var _client_peer := 0
var _client_name := ""
var _peer_ready := false
## 主机侧：客户端在大厅里点了「准备好了」没有。
##
## ⚠️ 它和 `_peer_ready` **不是一回事**：
##    `_peer_ready` = 「握手完成了，包能正常来回」；
##    `_client_ready` = 「人坐在那儿、点了准备」。
##    合成一个字段的话，客户端一连上就自动算「准备好了」，
##    主机可以在对方还在加载地图的时候就开局。
var _client_ready := false
var _hello_sent := false
var _host_ip := ""
var _cmds_this_frame := 0
## 本帧**本端发出**的聊天条数。
var _chats_this_frame := 0
## 本帧**从对方收到**的聊天条数（防被改过的客户端刷屏）。
var _chats_rx_this_frame := 0
## 暂停状态。**只有主机能改**；客户端这份是主机广播下来的结果。
var _paused := false
var _reject_seq := 0
var _reject_reason := ""
## 复用的编码缓冲 —— 每帧新建一个 `StreamPeerBuffer` 就是每帧一次分配，
## 10 Hz 快照 × 60 FPS 下很快就能在性能分析里看到它。
var _buf: Net.Buf = Net.Buf.new()

# ================================================================ 建世界

## ★建「主机世界」的唯一入口。★
##
## 为什么必须由这里建：客户端的整张地图是用**主机下发的种子**重建的。
## 主机如果没先 `seed()` 就 `World.new()`，客户端重建出来的地形就和主机不一样 ——
## 症状是客户端看到单位「穿墙」（主机认为那里是平地）、资源点位置对不上，
## 而且**两端都不报错**。
##
## 返回 `{"world": World, "seed": int}`；`seed` 要原样交给 `start_host()`。
##
## ⚠️ 种子会**同时**喂给 `seed()`（全局 RNG）和 `World` 的构造参数 ——
##    后者才是真正决定地形的那一个（`_generate_map` 用的是局部 RNG）。
##    只喂全局的话，客户端和主机拿到的还是同一张固定图，
##    「种子下发」这条链路就永远测不出问题。
static func create_host_world(map_w: int, map_h: int, race_p: String, race_e: String,
		difficulty: String, preset: String) -> Dictionary:
	var s := random_seed()
	seed(s)
	var w := World.new(map_w, map_h, race_p, race_e, difficulty, preset, s)
	return {"world": w, "seed": s}

## 一个非零的 31 位随机种子。
##
## ⚠️ 它会消费一次全局 RNG —— 但紧接着 `create_host_world` 就 `seed(s)` 重置，
##    所以对调用方没有副作用。
static func random_seed() -> int:
	var s := (int(Time.get_unix_time_from_system()) ^ randi()) & 0x7FFFFFFF
	return s if s != 0 else 1

# ================================================================ 开局

## 开一个房间。`w` 必须是 `create_host_world()` 建出来的那个，
## `p_seed` 必须是它返回的 `seed`。
func start_host(w: World, p_seed: int, p_port: int = Net.PORT,
		p_host_name: String = "主机") -> bool:
	if w == null:
		last_error = "没有世界可以主持"
		return false
	if not link.start_host(p_port):
		last_error = link.last_error
		return false
	world = w
	world_seed = p_seed
	local_owner = World.PLAYER
	remote_owner = World.ENEMY
	# 主机的世界本来就是这个视角；显式写一遍是为了「单机 / 联机同一套代码」
	world.local_owner = local_owner
	# ★局域网关掉 AI★：AI 指挥的是 ENEMY，而联机里 ENEMY 是客户端本人。
	# 不关的话 AI 会和客户端抢指挥权（症状是「我的兵自己乱跑」）。
	world.ai_enabled = false
	host_name = p_host_name
	state = State.HOSTING
	_reset_session()
	# ⚠️ 这里**不发** `session_ready` —— 房间开好了但还没人来。
	#    等 HELLO 收下、WELCOME 发出之后再发。
	return true

## 加入一个房间。**不阻塞** —— 连接结果在后续 `step()` 里出来。
func start_client(ip: String, p_port: int = Net.PORT,
		p_player_name: String = "玩家") -> bool:
	if not link.start_client(ip, p_port):
		last_error = link.last_error
		return false
	_host_ip = ip.strip_edges()
	player_name = p_player_name
	state = State.CONNECTING
	world = null
	_reset_session()
	_connect_started = _now
	return true

func _reset_session() -> void:
	_tick = 0
	_seq = 0
	_snap_timer = 0.0
	_since_snapshot = 0.0
	_ping_timer = PING_INTERVAL
	_ping_sent_at = -1.0
	_rtt_ms = -1
	_client_peer = 0
	_client_name = ""
	_peer_ready = false
	_client_ready = false
	_hello_sent = false
	_cmds_this_frame = 0
	_chats_this_frame = 0
	_chats_rx_this_frame = 0
	_paused = false
	_reject_seq = 0
	_reject_reason = ""
	snapshots_sent = 0
	snapshots_received = 0
	cmds_applied = 0
	cmds_rejected = 0
	cmds_dropped = 0
	pings_received = 0
	pongs_received = 0
	bad_packets = 0
	unknown_packets = 0

# ================================================================ 主循环

## 收事件 + 推进会话。每帧调一次。
##
## `delta` 只用来驱动「快照节流 / 超时看门狗」，**不驱动任何模拟**。
func step(delta: float) -> void:
	if state == State.IDLE or state == State.CLOSED:
		return
	_now += delta
	_cmds_this_frame = 0
	_chats_this_frame = 0
	_chats_rx_this_frame = 0
	link.poll(0)
	var evs := link.drain()
	for e in evs:
		var ev: Dictionary = e
		var kind := String(ev.get("type", ""))
		var pid := int(ev.get("peer", 0))
		var data: PackedByteArray = ev.get("data", PackedByteArray())
		match kind:
			"connect":
				_on_connect(pid)
			"disconnect":
				_on_disconnect(pid)
			"packet":
				_on_packet(pid, data)
			"error":
				last_error = "网络错误"
	if link.is_host():
		_host_tick(delta)
	else:
		_client_tick(delta)

func _on_connect(peer_id: int) -> void:
	if link.is_host():
		if _client_peer != 0 and _client_peer != peer_id:
			# 2 人局。多出来的直接拒掉 —— 不拒的话它会在 PLAYING 状态下
			# 发指令，而 `_host_packet` 会因为 peer 不匹配静默丢弃，
			# 表现成「第三个人进来了但什么都不发生」。
			_send_reject(peer_id, 0, "房间已满（本版本只支持 2 人）")
			link.disconnect_peer(peer_id)
			return
		_client_peer = peer_id
		_peer_ready = false
		_client_ready = false
		_connected_at = _now
		last_error = ""
	else:
		# ENet 握手完成，可以发 HELLO 了。
		# ⚠️ 不能提前发 —— 连接还没建立时 `send_host()` 会直接返回 false。
		_send_hello()

func _on_disconnect(peer_id: int) -> void:
	if link.is_host():
		if peer_id != _client_peer:
			return
		_client_peer = 0
		_peer_ready = false
		_client_ready = false
		# ⚠️ `LOBBY` 也要一起处理 —— 只判 `PLAYING` 的话，
		#    对方在大厅里直接退出，主机就永远停在 LOBBY、再也收不到新连接
		#    （`_on_connect` 里 `_client_peer != 0` 会把下一个人当成「房间已满」拒掉）。
		if state == State.PLAYING or state == State.LOBBY:
			# 回到「等人加入」。**主机的世界不受影响** ——
			# 它是权威模拟，客户端走了这局照样能继续打完。
			state = State.HOSTING
		last_error = "对方已离开"
		peer_left.emit(peer_id, "对方已离开")
	else:
		_fail("与主机断开连接")

func _on_packet(peer_id: int, data: PackedByteArray) -> void:
	if data.is_empty():
		return
	var hdr := Net.check_header(data)
	if not bool(hdr["ok"]):
		bad_packets += 1
		return
	var msg := int(hdr["msg"])
	if link.is_host():
		_host_packet(peer_id, msg, data)
	else:
		_client_packet(peer_id, msg, data)

# ================================================================ 主机侧

func _host_tick(delta: float) -> void:
	# ---- 握手看门狗 ----
	if _client_peer != 0 and not _peer_ready and _now - _connected_at > HANDSHAKE_TIMEOUT:
		_send_reject(_client_peer, 0, "握手超时")
		link.disconnect_peer(_client_peer)
		link.forget_peer(_client_peer)
		var gone := _client_peer
		_client_peer = 0
		last_error = "对方握手超时"
		peer_left.emit(gone, "握手超时")
	# ---- 快照 ----
	if state != State.PLAYING or world == null or _client_peer == 0 or not _peer_ready:
		return
	_snap_timer -= delta
	if _snap_timer > 0.0:
		return
	_snap_timer = Net.SNAPSHOT_INTERVAL
	_tick += 1
	# ★`viewer = remote_owner`★ —— 快照按**客户端自己的视野**过滤。
	#   不过滤的话客户端能看见全图（作弊），这是 M4a 就定下的判据。
	var d := Net.encode_snapshot(world, _buf, _tick, remote_owner)
	if link.send(_client_peer, d, false):
		snapshots_sent += 1

func _host_packet(peer_id: int, msg: int, data: PackedByteArray) -> void:
	# 只认当前那个客户端。其余 peer 的包一律忽略。
	if peer_id != _client_peer:
		return
	match msg:
		Net.Msg.HELLO:
			_host_hello(peer_id, data)
		Net.Msg.CMD:
			if not _peer_ready or state != State.PLAYING:
				return
			_host_cmd(peer_id, data)
		Net.Msg.READY:
			# ⚠️ 只在 LOBBY 里认。PLAYING 里再来一条（比如迟到的包）
			#    不能把已经开好的局搅乱。
			if state != State.LOBBY:
				return
			_client_ready = Net.decode_ready(data)
			lobby_updated.emit()
		Net.Msg.PING:
			pings_received += 1
			link.send(peer_id, Net.packet(Net.Msg.PONG), true)
		Net.Msg.CHAT:
			# 大厅里也能聊 —— 等人齐的时候干等着最容易劝退。
			if not _peer_ready or (state != State.PLAYING and state != State.LOBBY):
				return
			if _chats_rx_this_frame >= MAX_CHAT_PER_FRAME:
				chats_dropped += 1
				return
			_chats_rx_this_frame += 1
			var chat := Net.decode_chat(data)
			if bool(chat["ok"]):
				chats_received += 1
				chat_received.emit(_client_name, String(chat["text"]))
			else:
				bad_packets += 1
		Net.Msg.SURRENDER:
			if not _peer_ready or state != State.PLAYING:
				return
			_apply_surrender(remote_owner)
		Net.Msg.PAUSE:
			# ⚠️ 客户端发来的是**请求**，不是命令。主机收到后自己裁决并广播
			#    （本版本直接采纳）。只让客户端「点一下就暂停」的话，
			#    两个人会各暂停各的 —— 而客户端根本不跑模拟，暂停毫无意义。
			if not _peer_ready or state != State.PLAYING:
				return
			set_paused(Net.decode_pause(data))
		Net.Msg.BYE:
			var gone := _client_peer
			_client_peer = 0
			_peer_ready = false
			_client_ready = false
			if state == State.PLAYING or state == State.LOBBY:
				state = State.HOSTING
			last_error = "对方退出了房间"
			peer_left.emit(gone, "对方退出了房间")
			lobby_updated.emit()
		_:
			unknown_packets += 1

func _host_hello(peer_id: int, data: PackedByteArray) -> void:
	var hi := Net.decode_hello(data)
	if not bool(hi["ok"]):
		# 版本 / 模组不一致 —— **必须在握手阶段就拒绝**。
		# 放进去的话玩家要打五分钟才发现「我的陆战队员变成了攻城坦克」。
		var why := String(hi["reason"])
		_send_reject(peer_id, 0, why)
		link.disconnect_peer(peer_id)
		link.forget_peer(peer_id)
		_client_peer = 0
		_peer_ready = false
		last_error = why
		peer_left.emit(peer_id, why)
		return
	_client_name = String(hi["name"])
	_peer_ready = true
	_client_ready = false
	_send_welcome(peer_id)
	# ⚠️ M4c 起**不直接进 PLAYING**，而是进 LOBBY 等双方都准备好。
	#    进 PLAYING 的话，主机能在客户端还在解包世界的时候就开局。
	state = State.LOBBY
	_snap_timer = 0.0            # 第一份快照在开局那一刻立刻发，别让客户端白等 100ms
	_tick = 0
	peer_joined.emit(peer_id)
	session_ready.emit()
	lobby_updated.emit()

func _send_welcome(peer_id: int) -> void:
	var d := Net.packet_welcome(_buf, remote_owner, world_seed,
		world.map_w, world.map_h, world.map_preset,
		world.player_race, world.enemy_race, world.difficulty, host_name)
	link.send(peer_id, d, true)

func _send_hello() -> void:
	var d := Net.packet_hello(_buf, player_name)
	if link.send_host(d, true):
		_hello_sent = true
		_connect_started = _now

func _host_cmd(peer_id: int, data: PackedByteArray) -> void:
	if _cmds_this_frame >= MAX_CMD_PER_FRAME:
		cmds_dropped += 1
		return
	_cmds_this_frame += 1
	var cmd := Net.decode_cmd(data)
	if not bool(cmd["ok"]):
		_send_reject(peer_id, 0, String(cmd["reason"]))
		return
	# ★`sender = remote_owner`★ —— `apply_cmd` 靠它做归属校验。
	#   传错的话客户端能指挥主机的部队（真作弊）。
	var res := Net.apply_cmd(world, cmd, remote_owner)
	if bool(res["ok"]):
		cmds_applied += 1
	else:
		cmds_rejected += 1
		_send_reject(peer_id, int(cmd["seq"]), String(res["reason"]))

func _send_reject(peer_id: int, seq: int, reason: String) -> void:
	var d := Net.packet_reject(_buf, seq, reason)
	link.send(peer_id, d, true)

# ================================================================ 客户端侧

func _client_tick(delta: float) -> void:
	if state == State.CONNECTING:
		if _now - _connect_started > CONNECT_TIMEOUT:
			_fail("连接超时：%s 没有响应" % _host_ip)
		return
	if state != State.PLAYING and state != State.LOBBY:
		return
	# ⚠️ 大厅里**不能**判 `SNAPSHOT_TIMEOUT` —— 那时一份快照都还没发过，
	#    `_since_snapshot` 从 0 开始涨，5 秒后就会把好好的连接判成「失联」。
	#    症状是「在大厅里等 5 秒就掉线」。
	if state == State.PLAYING:
		# ⚠️ 必须在**应用完快照之后**刷视野。反过来的话，用的是上一帧的
		#    单位位置算这一帧的雾 —— 敌人移动时视野边缘会「拖影」。
		if world != null:
			world.client_frame(delta)
		_since_snapshot += delta
		if _since_snapshot > SNAPSHOT_TIMEOUT:
			_fail("与主机失去联系（%d 秒没收到快照）" % int(SNAPSHOT_TIMEOUT))
			return
	# 心跳在**大厅和对局里都要发** —— 大厅阶段没有快照，全靠它证明对方还活着。
	_ping_timer -= delta
	if _ping_timer <= 0.0:
		_ping_timer = PING_INTERVAL
		if link.send_host(Net.packet(Net.Msg.PING), true):
			_ping_sent_at = _now

func _client_packet(_peer_id: int, msg: int, data: PackedByteArray) -> void:
	match msg:
		Net.Msg.WELCOME:
			if state != State.CONNECTING:
				return                       # 重复的 WELCOME：忽略
			var w := Net.decode_welcome(data)
			if not bool(w["ok"]):
				_fail("主机拒绝了本机：%s" % String(w["reason"]))
				return
			_build_world(w)
			# ⚠️ M4c 起先进 **LOBBY**，等主机点「开始」才进 PLAYING。
			#    直接进 PLAYING 的话，客户端会在「自己还没看完大厅」
			#    的状态下被快照推着走 —— 玩家看到的是「刚进房间就已经打起来了」。
			state = State.LOBBY
			_since_snapshot = 0.0
			_ping_timer = PING_INTERVAL
			session_ready.emit()
			lobby_updated.emit()
		Net.Msg.START:
			# ⚠️ 只在 LOBBY 里认。PLAYING 里再来一条（迟到的 / 重复的）
			#    不能把已经开好的局重置掉 —— 重置 `_since_snapshot` 倒还好，
			#    但重复发 `game_started` 会让 Main 重跑一遍建贴图 / 摆镜头。
			if state != State.LOBBY:
				return
			state = State.PLAYING
			_since_snapshot = 0.0
			_snap_timer = 0.0
			_paused = false
			game_started.emit()
		Net.Msg.SNAPSHOT:
			if state != State.PLAYING or world == null:
				return
			var res := Net.apply_snapshot(world, data)
			if bool(res["ok"]):
				_since_snapshot = 0.0
				snapshots_received += 1
			else:
				bad_packets += 1
		Net.Msg.REJECT:
			var r := Net.decode_reject(data)
			_reject_seq = int(r["seq"])
			_reject_reason = String(r["reason"])
			cmds_rejected += 1
			cmd_rejected.emit(_reject_seq, _reject_reason)
		Net.Msg.PONG:
			pongs_received += 1
			if _ping_sent_at >= 0.0:
				_rtt_ms = maxi(0, int(round((_now - _ping_sent_at) * 1000.0)))
		Net.Msg.CHAT:
			if state != State.PLAYING and state != State.LOBBY:
				return
			if _chats_rx_this_frame >= MAX_CHAT_PER_FRAME:
				chats_dropped += 1
				return
			_chats_rx_this_frame += 1
			var chat := Net.decode_chat(data)
			if bool(chat["ok"]):
				chats_received += 1
				chat_received.emit(host_name, String(chat["text"]))
			else:
				bad_packets += 1
		Net.Msg.SURRENDER:
			if state != State.PLAYING:
				return
			_apply_surrender(remote_owner)
		Net.Msg.PAUSE:
			# 客户端**照单全收**主机广播的暂停状态，不自己裁决。
			if state != State.PLAYING:
				return
			_apply_pause(Net.decode_pause(data))
		Net.Msg.BYE:
			_fail("主机结束了游戏")
		_:
			unknown_packets += 1

## 用主机下发的参数把世界重建出来。
##
## ★**种子必须来自主机。**★ 两端各自生成地图的话，只要有一格不一致，
## 客户端就会看到单位「穿墙」—— 因为主机认为那里是平地。
func _build_world(msg: Dictionary) -> void:
	var sd := int(msg["seed"])
	seed(sd)
	# ⚠️ 种子要传给**构造参数**，不能只 `seed()` —— `_generate_map()` 用的是
	#    局部 RNG，不吃全局种子。漏了这个参数的话，客户端拿到的是一张
	#    「碰巧和主机一样」的固定图（因为地图本来就只有一张），
	#    于是这条链路在测试里**永远不会红**，直到哪天地图真的随机了才炸。
	var w := World.new(int(msg["map_w"]), int(msg["map_h"]),
		String(msg["race_p"]), String(msg["race_e"]),
		String(msg["difficulty"]), String(msg["map_preset"]), sd)
	local_owner = int(msg["owner"])
	remote_owner = World.PLAYER if local_owner == World.ENEMY else World.ENEMY
	w.local_owner = local_owner
	# 客户端同样不跑 AI（它本来也不跑 `step()`，这里只是把状态标干净，
	# 免得将来有人加了客户端预测之后 AI 突然复活）。
	w.ai_enabled = false
	# ⚠️ 客户端**不跑 AI**。`World.new()` 里 `_init_ai()` 已经建了 AI 状态，
	#    但 `_update_ai` 只在 `step()` 里调，而客户端永远不调 `step()`。
	#
	# ⚠️ 顺手清掉开局赠兵：`World.new()` 会按同一种子摆一份「开局阵容」，
	#    第一份快照马上会把它整个换掉。不清的话，在收到第一份快照之前
	#    玩家会看到**两份部队**叠在一起（同一位置，但数量翻倍）。
	w.reset_dynamic()
	world = w
	world_seed = sd
	host_name = String(msg.get("host_name", ""))

# ================================================================ 大厅（准备 / 开始）

## 客户端：告诉主机「我准备好了 / 我取消准备」。
##
## 主机侧调用它**没有意义**（主机天然就是准备好了的一方），
## 所以这里直接返回 `false` 并说明原因 —— 静默成功会让 UI 画出一个
## 「点了有反馈但其实什么都没发生」的按钮。
func set_ready(v: bool) -> bool:
	if state != State.LOBBY:
		last_error = "不在大厅里"
		return false
	if link.is_host():
		last_error = "主机不需要准备"
		return false
	_client_ready = v
	if not link.send_host(Net.packet_ready(_buf, v), true):
		last_error = "准备状态发送失败"
		return false
	lobby_updated.emit()
	return true

## 主机：现在能不能开局。
##
## ⚠️ 三个条件缺一不可：在大厅里、对方握手完成、**对方点了准备**。
##    少了最后一条，主机可以在对方还在加载地图的时候开局。
func can_start() -> bool:
	return state == State.LOBBY and _peer_ready and _client_ready

## 主机：开局。返回是否真的开起来了（不能开时 `last_error` 说明原因）。
func begin_game() -> bool:
	if not link.is_host():
		last_error = "只有主机能开始游戏"
		return false
	if state != State.LOBBY:
		last_error = "不在大厅里"
		return false
	if not _peer_ready:
		last_error = "还没有玩家加入"
		return false
	if not _client_ready:
		last_error = "对方还没有准备"
		return false
	if not link.send(_client_peer, Net.packet_start(), true):
		last_error = "开局包发送失败"
		return false
	state = State.PLAYING
	_snap_timer = 0.0          # 第一份快照立刻发
	_since_snapshot = 0.0
	_paused = false            # 新一局一定是「跑着的」
	game_started.emit()
	return true

## 主机：对方准备了没有。
func client_ready() -> bool:
	return _client_ready

# ================================================================ 对局内：聊天 / 投降 / 暂停

## 发一条聊天。返回是否真的发出去了（`last_error` 说明原因）。
##
## ⚠️ **本端不会收到自己的 `chat_received`** —— 发出去的那条由 `Main`
##    在调用点直接上屏。让本端也走一遍信号的话，两边要各自判断
##    「这条是不是我发的」，很容易变成「自己说的话显示两遍」。
func send_chat(text: String) -> bool:
	if state != State.PLAYING and state != State.LOBBY:
		last_error = "不在房间里"
		return false
	var t := text.strip_edges()
	if t == "":
		last_error = "不能发空消息"
		return false
	if _chats_this_frame >= MAX_CHAT_PER_FRAME:
		last_error = "发言太快了"
		return false
	_chats_this_frame += 1
	var d := Net.packet_chat(_buf, t)
	if link.is_host():
		if _client_peer == 0 or not _peer_ready:
			last_error = "房间里没有别人"
			return false
		if not link.send(_client_peer, d, true):
			last_error = "发送失败：%s" % link.last_error
			return false
		return true
	if not link.send_host(d, true):
		last_error = "发送失败：%s" % link.last_error
		return false
	return true

## 认输。**本端立刻结算**（不等对方回包），并通知对方。
func surrender() -> bool:
	if state != State.PLAYING:
		last_error = "不在对局中"
		return false
	if world == null or world.game_ended:
		last_error = "对局已经结束了"
		return false
	# 先告诉对方，再本地结算 —— 反过来的话本地 `game_over` 可能触发
	# 结算界面并 `close()` 掉会话，包就发不出去了。
	var d := Net.packet_surrender()
	if link.is_host():
		if _client_peer != 0:
			link.send(_client_peer, d, true)
	else:
		link.send_host(d, true)
	_settle_surrender(local_owner)
	return true

## 主机：暂停 / 恢复。返回是否生效。
##
## ⚠️ **只有主机能调。** 客户端调它只改自己那一份状态，而客户端不跑模拟，
##    于是「我这边暂停了、主机那边还在打」—— 最坏的错觉。
func set_paused(v: bool) -> bool:
	if not link.is_host():
		last_error = "只有主机能暂停游戏"
		return false
	if state != State.PLAYING:
		last_error = "不在对局中"
		return false
	if _paused == v:
		return true                      # 幂等：重复点不重复广播
	_apply_pause(v)
	if _client_peer != 0 and _peer_ready:
		link.send(_client_peer, Net.packet_pause(_buf, v), true)
	return true

## 客户端：请主机暂停 / 恢复。**本地状态不动**，等主机广播回来才生效。
func request_pause(v: bool) -> bool:
	if not link.is_client():
		last_error = "主机直接调 set_paused"
		return false
	if state != State.PLAYING:
		last_error = "不在对局中"
		return false
	if not link.send_host(Net.packet_pause(_buf, v), true):
		last_error = "请求发送失败：%s" % link.last_error
		return false
	return true

## 现在是不是暂停中。
func is_paused() -> bool:
	return _paused

## 结算：`who` 认输 → 对方获胜。两端共用同一条路径。
func _settle_surrender(who: int) -> void:
	if world != null and not world.game_ended:
		world.surrender(who)

## 收到**对方**认输。本地主动认输不走这里（那是 `surrender()` 自己的事），
## 否则 `peer_surrendered` 会在「我投降」时也发一次，语义就反了。
func _apply_surrender(who: int) -> void:
	_settle_surrender(who)
	peer_surrendered.emit(who)

func _apply_pause(v: bool) -> void:
	if _paused == v:
		return
	_paused = v
	pause_changed.emit(v)

# ================================================================ 发指令

## 发一条指令。返回 `{"ok": bool, "reason": String}`。
##
## - **客户端**：编码后发给主机。`ok` 只表示「已发出」——
##   真正的结果由主机回 `REJECT`，通过 `cmd_rejected` 信号出来。
## - **主机**：★本地走一遍和客户端**完全相同**的解码 + 应用路径★，
##   直接拿到真实结果。
##
##   为什么主机不直接调 `world.cmd_*`：那样两端的**校验路径**就不一样了，
##   于是会出现「客户端建不了、主机能建」这种只在一端复现的怪事。
##   多花的一次编码/解码，比起这种 bug 便宜太多。
func send_cmd(kind: int, ids: Array, p: Dictionary = {}) -> Dictionary:
	if state != State.PLAYING:
		return {"ok": false, "reason": "不在对局中"}
	if world == null:
		return {"ok": false, "reason": "世界不存在"}
	_seq += 1
	var data := Net.packet_cmd(_buf, _seq, kind, ids, p)
	if link.is_host():
		var cmd := Net.decode_cmd(data)
		var res := Net.apply_cmd(world, cmd, local_owner)
		if bool(res["ok"]):
			cmds_applied += 1
		return res
	if not link.send_host(data, true):
		return {"ok": false, "reason": "发送失败：%s" % link.last_error}
	return {"ok": true, "reason": ""}

# ================================================================ 收尾

## 结束会话。**优雅退出**（先告诉对方，再销毁本地连接）。
func close() -> void:
	if state == State.CLOSED:
		return
	# ⚠️ `LOBBY` 也要发 `BYE` —— 只判 `PLAYING` 的话，对方在大厅里退房间，
	#    主机只会收到一个 DISCONNECT，提示语退化成「与主机断开连接」。
	if (state == State.PLAYING or state == State.LOBBY) and link.is_active():
		# ⚠️ 这只是「尽力而为」：`BYE` 走可靠通道，而 `peer_disconnect()`
		#    是协议层的包，两者**不保证先后**。对方没收到 `BYE` 也不影响
		#    正确性 —— 它自己的 DISCONNECT 事件照样会到，只是提示语
		#    从「对方结束了游戏」退化成「与主机断开连接」。
		var d := Net.packet(Net.Msg.BYE)
		if link.is_host():
			link.broadcast(d, true)
		else:
			link.send_host(d, true)
	link.close_gracefully()
	state = State.CLOSED

func _fail(reason: String) -> void:
	if state == State.CLOSED or state == State.FAILED:
		return
	state = State.FAILED
	last_error = reason
	link.close()
	session_failed.emit(reason)

# ================================================================ 查询

func is_playing() -> bool:
	return state == State.PLAYING

## 在大厅里（世界已就绪，但还没开局）。
func is_in_lobby() -> bool:
	return state == State.LOBBY

## 大厅**界面**可以操作了吗（对手已经握手完成）。
##
## ⚠️ 不能直接用 `is_in_lobby()`：主机在**还没人来**的时候停在 `HOSTING`，
##    不是 `LOBBY`。用 `is_in_lobby()` 的话，主机等待页上的「开始游戏」
##    会整个消失 —— 玩家看不到「还要等对方准备」这条信息，
##    只会觉得「怎么连开始按钮都没有」，然后一直等。
func lobby_ready() -> bool:
	if link.is_host():
		return state == State.HOSTING or state == State.LOBBY
	return state == State.LOBBY

func is_host() -> bool:
	return link.is_host()

func is_client() -> bool:
	return link.is_client()

## 主机侧：房间里有几个人（含主机自己）。客户端侧恒为 2（连上时）。
func player_count() -> int:
	if link.is_host():
		return 1 + (1 if _client_peer != 0 else 0)
	# ⚠️ `LOBBY` 也要算 2 —— 只判 `PLAYING` 的话，大厅里的玩家列表会显示「1 人」，
	#    玩家会以为对方掉线了。
	return 2 if (state == State.PLAYING or state == State.LOBBY) else 1

## 客户端的延迟（毫秒）。还没测到时返回 -1。
##
## 用的是**应用层** PING/PONG 而不是 ENet 自带的 RTT ——
## ENet 的心跳由传输层独立维持，主机主循环卡死了它也照样在跳。
## 应用层心跳能顺带证明「对方的游戏循环还活着」。
func rtt_ms() -> int:
	return _rtt_ms

## 客户端的名字（主机侧；握手完成后才有）。
func client_name() -> String:
	return _client_name

## 取走最近一条被拒绝的指令理由（取完清空）。UI 每帧调它来弹提示。
func take_reject() -> Dictionary:
	if _reject_reason == "":
		return {}
	var out := {"seq": _reject_seq, "reason": _reject_reason}
	_reject_seq = 0
	_reject_reason = ""
	return out

func state_name() -> String:
	match state:
		State.IDLE:
			return "idle"
		State.HOSTING:
			return "hosting"
		State.CONNECTING:
			return "connecting"
		State.LOBBY:
			return "lobby"
		State.PLAYING:
			return "playing"
		State.FAILED:
			return "failed"
		State.CLOSED:
			return "closed"
	return "?"
