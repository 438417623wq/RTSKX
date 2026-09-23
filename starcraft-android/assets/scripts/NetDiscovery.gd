extends RefCounted
class_name NetDiscovery

## 局域网房间发现（第十三轮 M4c）。
##
## 主机定期往 `Net.DISCOVER_PORT` **UDP 广播**一条「房间公告」；
## 客户端绑同一个端口收公告，维护一份带 TTL 的房间列表。
##
## ⚠️ **为什么不用 ENet**：ENet 是**点对点**的，没有广播语义 ——
##    它必须先知道对端地址才能建连接。而「发现」这件事的全部意义
##    恰恰是**还不知道对端地址**。所以这里用裸 `PacketPeerUDP`，
##    和 `NetLink` 是两套互不相干的 socket。
##
## ⚠️ **主机不绑 `DISCOVER_PORT`，只发不收**。绑了就和客户端的监听撞端口 ——
##    同一台机器上（开发机、单进程测试）会直接 bind 失败。
##    客户端才 `bind()`。
##
## ⚠️ **时钟是虚拟的**（内部累加 `_now += delta`，不读 `Time.get_ticks_msec()`）。
##    理由同 `NetSession`：TTL 过期这类断言要能瞬间跑完，不用真的等 3.5 秒。

const MAGIC := 0x53434E41
const ANNOUNCE_VER := 1

## 主机每隔多久广播一次。
const ANNOUNCE_INTERVAL := 1.0

## 超过这么久没收到公告就当作房间没了。
## **必须显著大于 `ANNOUNCE_INTERVAL`** —— 等于的话丢一个包房间就闪一下；
## 太大则关掉的房间会在列表里赖很久。
const ROOM_TTL := 3.5

## 广播地址。测试里改成 `127.0.0.1`（见 `start_advertise()`）。
const BROADCAST_ADDR := "255.255.255.255"
const LOOPBACK := "127.0.0.1"

## 房间列表最多记多少个。防「有人恶意刷公告」把内存吃满 ——
## 和 `Net.MAX_PACKET` 是同一类防御。
const MAX_ROOMS := 32

enum Mode { OFF, ADVERTISE, BROWSE }

var mode := Mode.OFF
var last_error := ""

## `"ip:port"` → 房间记录。用「地址+端口」做键而不是主机名 ——
## 两台机器可以重名，但地址不会。
var _rooms := {}
var _now := 0.0
var _timer := 0.0

## 发送用（ADVERTISE）。**不 bind**。
var _sender: PacketPeerUDP = null
## 接收用（BROWSE）。**bind(DISCOVER_PORT)**。
var _listener: PacketPeerUDP = null

var _info := {}
var _dest_addr := BROADCAST_ADDR
var _dest_port := Net.DISCOVER_PORT

## 统计（测试钉在计数器上，而不是「状态看起来对」）。
var announces_sent := 0
var announces_received := 0
var bad_packets := 0
var _buf := Net.Buf.new()

# ---------------------------------------------------------------- 编解码

## 组装一条房间公告。
##
## `info` 的键：`host_name` / `game_port` / `players` / `max_players` /
## `started` / `map_preset` / `host_race`。缺的键一律走缺省值，
## **不报错** —— 公告是「尽力而为」的信息，不值得为少一个字段拒收整个房间。
static func encode_announce(buf: Net.Buf, info: Dictionary) -> PackedByteArray:
	buf.clear()
	buf.u32(MAGIC)
	buf.u8(ANNOUNCE_VER)
	buf.u16(int(info.get("game_port", Net.PORT)))
	buf.u8(int(info.get("players", 1)))
	buf.u8(int(info.get("max_players", 2)))
	var flags := 0
	if bool(info.get("started", false)):
		flags |= 1
	buf.u8(flags)
	buf.str8(String(info.get("host_name", "主机")))
	buf.str8(String(info.get("map_preset", "plateau")))
	buf.str8(String(info.get("host_race", "terran")))
	return buf.data()

## 解一条房间公告。返回 `{"ok": bool, "reason": String, ...}`。
##
## ⚠️ **magic 与版本都要校验**。局域网里飘着的不止我们一家 ——
##    别的程序、别的版本、甚至同一台机器上的旧实例都会往这个端口发东西。
##    不校验的话，一个随机 UDP 包就能在房间列表里造出一条乱码房间。
static func decode_announce(data: PackedByteArray) -> Dictionary:
	var buf := Net.Buf.new()
	buf.load_bytes(data)
	if buf.u32r() != MAGIC:
		return {"ok": false, "reason": "不是本游戏的公告"}
	var ver := buf.u8r()
	if ver != ANNOUNCE_VER:
		return {"ok": false, "reason": "公告版本不一致（对方 v%d）" % ver}
	var out := {
		"ok": true, "reason": "",
		"game_port": buf.u16r(),
		"players": buf.u8r(),
		"max_players": buf.u8r(),
		"started": (buf.u8r() & 1) != 0,
		"host_name": buf.str8r(),
		"map_preset": buf.str8r(),
		"host_race": buf.str8r(),
	}
	# ⚠️ 读侧一律走 `Net.Buf` 的越界保护：截断包会把 `bad` 置位，
	#    而不是抛异常或读出垃圾。**必须在读完之后统一判一次。**
	if not buf.ok():
		return {"ok": false, "reason": "公告被截断（%d 字节）" % data.size()}
	if int(out["game_port"]) <= 0 or int(out["game_port"]) > 65535:
		return {"ok": false, "reason": "公告里的端口非法"}
	return out

# ---------------------------------------------------------------- 主机侧

## 开始广播。`p_addr` 只给测试用（单进程下用 `127.0.0.1`，
## 因为广播包不一定回环到本机自己的监听端口）。
func start_advertise(info: Dictionary, p_port: int = Net.DISCOVER_PORT,
		p_addr: String = BROADCAST_ADDR) -> bool:
	stop()
	_sender = PacketPeerUDP.new()
	# ⚠️ 不开广播开关的话，`put_packet()` 发往 255.255.255.255 会**静默失败**
	#    （返回 OK 但包出不去）。这是「房间列表永远是空的」最常见的原因。
	_sender.set_broadcast_enabled(true)
	var err := _sender.set_dest_address(p_addr, p_port)
	if err != OK:
		last_error = "广播地址 %s:%d 不可用（错误码 %d）" % [p_addr, p_port, err]
		_sender = null
		return false
	_info = info
	_dest_addr = p_addr
	_dest_port = p_port
	mode = Mode.ADVERTISE
	_now = 0.0
	_timer = 0.0
	last_error = ""
	# 立刻发一条 —— 等 1 秒的话客户端会觉得「搜不到房间」。
	_send_announce()
	return true

func _send_announce() -> void:
	if _sender == null:
		return
	var d := encode_announce(_buf, _info)
	if _sender.put_packet(d) == OK:
		announces_sent += 1

## 换一份公告内容（人数变了 / 开局了）。
##
## ⚠️ 只在**已经在广播**时才换。没在广播时换等于悄悄改了状态却不发出去 ——
##    调用方以为公告已经更新了，实际什么都没发生。
##    也不重新 `start_advertise()`：那会把 UDP socket 关掉重开，
##    中间那一下别的客户端正好在监听的话就漏掉一轮公告。
func set_info(info: Dictionary) -> void:
	if mode != Mode.ADVERTISE:
		return
	# ⚠️ **内容没变就什么都不做。** 调用方是每帧调的（60 FPS），
	#    无条件发的话就是每秒 60 条广播 —— 整个局域网被我们刷满，
	#    而且每台客户端都在做无谓的解码。
	if info == _info:
		return
	_info = info
	# 变了就立刻发一条，不等下一个节拍 —— 人数从 1 变 2 是「有人来了」
	# 这种即时事件，晚 1 秒才广播的话，另一台机器的列表里会先看到
	# 「1 人」再跳成「2 人」。
	_send_announce()

# ---------------------------------------------------------------- 客户端侧

## 开始搜索。绑 `p_port` 收公告。
func start_browse(p_port: int = Net.DISCOVER_PORT) -> bool:
	stop()
	_listener = PacketPeerUDP.new()
	# ⚠️ 必须 `set_broadcast_enabled(true)` 才能收到广播包
	#    （部分平台上收广播也要开这个开关）。
	_listener.set_broadcast_enabled(true)
	var err := _listener.bind(p_port)
	if err != OK:
		last_error = "端口 %d 被占用或无法绑定（错误码 %d）" % [p_port, err]
		_listener = null
		return false
	mode = Mode.BROWSE
	_now = 0.0
	last_error = ""
	_rooms.clear()
	return true

# ---------------------------------------------------------------- 每帧

## 每帧调一次。`delta` 是**虚拟时钟**（见文件头）。
func poll(delta: float) -> void:
	if mode == Mode.OFF:
		return
	_now += delta
	if mode == Mode.ADVERTISE:
		_timer -= delta
		if _timer <= 0.0:
			_timer = ANNOUNCE_INTERVAL
			_send_announce()
		return
	_drain()
	_expire()

func _drain() -> void:
	if _listener == null:
		return
	while _listener.get_available_packet_count() > 0:
		var data := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var port := _listener.get_packet_port()
		var a := decode_announce(data)
		if not bool(a["ok"]):
			bad_packets += 1
			continue
		announces_received += 1
		# ⚠️ 记的是**公告里的 `game_port`**，不是收到包的源端口 ——
		#    源端口是发送方的临时端口（实测是 49841 这种），跟游戏端口没关系。
		#    用错的话房间列表里每个房间的端口都是错的，玩家照着连永远连不上。
		var key := room_key(ip, int(a["game_port"]))
		if not _rooms.has(key) and _rooms.size() >= MAX_ROOMS:
			# 列表满了：踢掉最旧的那条，而不是拒收新的。
			# 拒收新的会让「先来的一堆僵尸房间」把真房间永远挡在外面。
			_drop_oldest()
		_rooms[key] = {
			"ip": ip,
			"port": int(a["game_port"]),
			"name": String(a["host_name"]),
			"map": String(a["map_preset"]),
			"race": String(a["host_race"]),
			"players": int(a["players"]),
			"max": int(a["max_players"]),
			"started": bool(a["started"]),
			"seen_at": _now,
		}

func _drop_oldest() -> void:
	var oldest_key := ""
	var oldest := 1e30
	for k in _rooms:
		var t := float((_rooms[k] as Dictionary)["seen_at"])
		if t < oldest:
			oldest = t
			oldest_key = String(k)
	if oldest_key != "":
		_rooms.erase(oldest_key)

func _expire() -> void:
	var dead: Array = []
	for k in _rooms:
		if _now - float((_rooms[k] as Dictionary)["seen_at"]) > ROOM_TTL:
			dead.append(k)
	for k in dead:
		_rooms.erase(k)

# ---------------------------------------------------------------- 查询

## 房间键。`"ip:port"`。
static func room_key(ip: String, port: int) -> String:
	return "%s:%d" % [ip, port]

## 当前「还活着」的房间列表，**新看到的排前面**。
##
## ⚠️ 排序是必须的：UDP 到达顺序不保证，不排的话列表会跳来跳去，
##    玩家刚要点的那一行可能已经跑到别的位置了。
func rooms() -> Array:
	var out: Array = []
	for k in _rooms:
		var r: Dictionary = (_rooms[k] as Dictionary).duplicate()
		r["key"] = String(k)
		out.append(r)
	out.sort_custom(func(a, b):
		var ta := float((a as Dictionary)["seen_at"])
		var tb := float((b as Dictionary)["seen_at"])
		if ta != tb:
			return ta > tb
		# `sort_custom` 不稳定，同时间戳再按名字排一下，保证顺序确定。
		return String((a as Dictionary)["key"]) < String((b as Dictionary)["key"]))
	return out

func room_count() -> int:
	return _rooms.size()

func has_room(ip: String, port: int) -> bool:
	return _rooms.has(room_key(ip, port))

## 只给**截图 / 测试**用：塞一条房间进去，不等真实广播。
##
## ⚠️ 走的是和真实收包**同一个** `_rooms` 字典 —— 另起一个「假房间数组」的话，
##    画出来的排版就未必和真发现时一样，截图也就失去意义了。
##
## `seen_at` 设成一个很大的值 = 「刚刚才看到」：设 0 的话下一次
## `poll()` 就把它当过期清掉了（截图是跨帧的，房间会在拍之前消失）。
func inject_room(r: Dictionary) -> void:
	var ip := String(r.get("ip", ""))
	if ip == "":
		return
	var port := int(r.get("port", Net.PORT))
	_rooms[room_key(ip, port)] = {
		"ip": ip,
		"port": port,
		"name": String(r.get("name", "?")),
		"map": String(r.get("map", "plateau")),
		"race": String(r.get("race", "terran")),
		"players": int(r.get("players", 1)),
		"max": int(r.get("max", 2)),
		"started": bool(r.get("started", false)),
		"seen_at": 1.0e9,
	}

# ---------------------------------------------------------------- 收尾

func stop() -> void:
	# ⚠️ 两个都要关，而且都要置 null —— 只关一个的话，
	#    `stop()` 之后 `poll()` 仍然会收包（因为 `_listener` 还在）。
	if _sender != null:
		_sender.close()
		_sender = null
	if _listener != null:
		_listener.close()
		_listener = null
	mode = Mode.OFF
	_rooms.clear()
	_timer = 0.0
	_now = 0.0

func is_active() -> bool:
	return mode != Mode.OFF

func mode_name() -> String:
	match mode:
		Mode.ADVERTISE: return "advertise"
		Mode.BROWSE: return "browse"
	return "off"
