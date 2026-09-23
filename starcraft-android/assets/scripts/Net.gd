extends RefCounted
class_name Net

## 局域网对战的协议层（第十三轮 M4a）。
##
## 本文件只做**纯数据**的事：类型索引表 + 定长编解码 + 包头。
## **完全不碰 ENet** —— 网络对象在 M4b 接。
##
## 这样切分的理由：编解码是纯函数，无头测试能完整覆盖
## （往返一致 / 尺寸上限 / 零分配 / 字节确定性）。
## 一旦掺进 ENet，无头测试就只能靠两个进程互连，复杂度和不确定性都上一个台阶。
## **先把地基钉死，后面调协议才不会一动就崩。**
##
## ⚠️ 一条贯穿全文件的纪律：**迷雾按客户端过滤后再发**。
##    主机广播「完整世界状态」的话，客户端只要解包就能看到全图 —— 等于内置作弊。
##    而且这条决定了编码布局（哪些记录会被整个跳过），
##    **必须从一开始就在**，后补等于把快照格式重写一遍。

const PROTOCOL_VERSION := 1
const PORT := 27015
const DISCOVER_PORT := 27016
const SNAPSHOT_HZ := 10.0
const SNAPSHOT_INTERVAL := 1.0 / SNAPSHOT_HZ

## 包头是 `[u8 type][u8 proto_ver]`。
##
## ⚠️ 版本不匹配必须**直接拒绝**。靠「大概能跑」的话，症状是「单位乱飞」——
##    比连不上更难查。
enum Msg { HELLO = 1, WELCOME = 2, CMD = 3, SNAPSHOT = 4, CHAT = 5, PING = 6, PONG = 7, BYE = 8,
	REJECT = 9,
	# ---- M4c：大厅流程 ----
	# ⚠️ 这两个是**把「一收到 WELCOME 就开局」改成「显式开始」**的关键。
	#    没有它们的话，主机刚把世界发出去、客户端还在解包，对局就开始了 ——
	#    两边看到的开局时间差半秒，而且主机没法等对方准备好。
	READY = 10,          # 客户端 → 主机：我准备好了
	START = 11,          # 主机 → 客户端：开局
	# ---- M4c：对局内控制 ----
	SURRENDER = 12,      # 任一方 → 对方：我认输
	PAUSE = 13,          # 主机 → 客户端：暂停 / 恢复（客户端只能请求，见 NetSession）
	}

## `Unit.mode` 是字符串，快照里只发 1 字节。
const MODES := ["normal", "sieged"]

# ---- 单位 flags 位 ----
const UF_ATTACK_MOVE := 1
const UF_MOVE_ORDER := 2
const UF_FLASH := 4
const UF_IN_COMBAT := 8

# ---- 建筑 flags 位 ----
const BF_COMPLETE := 1
const BF_FLASH := 2
const BF_RALLY := 4

## 单包上限。超了直接拒绝 —— 不设上限的话一个畸形包能把内存吃光。
const MAX_PACKET := 65536

# ---------------------------------------------------------------- 类型索引表

## 名字 → 索引在启动时构建一次；索引 → 名字用数组直查。
##
## ⚠️ **从 `GameData.base_ids()`（基础表）构建，不读 `UNITS` / `BUILDINGS`** ——
##    那两个是模组改过的副本。客户端装了模组、主机没装的话索引会整体错位，
##    症状是「我的陆战队员变成了攻城坦克」，**而且不报错**。
static var unit_ids := PackedStringArray()
static var building_ids := PackedStringArray()
static var _unit_idx: Dictionary = {}
static var _building_idx: Dictionary = {}
static var _types_built := false

static func unit_type_index(id: String) -> int:
	ensure_type_table()
	return int(_unit_idx.get(id, -1))

static func building_type_index(id: String) -> int:
	ensure_type_table()
	return int(_building_idx.get(id, -1))

static func unit_type_id(idx: int) -> String:
	ensure_type_table()
	if idx < 0 or idx >= unit_ids.size():
		return ""
	return String(unit_ids[idx])

static func building_type_id(idx: int) -> String:
	ensure_type_table()
	if idx < 0 or idx >= building_ids.size():
		return ""
	return String(building_ids[idx])

# ---------------------------------------------------------------- 升级 / 技能索引表
#
# 指令里要引用「研究哪条升级」「放哪个技能」，同样不能发字符串。
# 两张表都从 `GameData` 的**基础表**构建并排序，规则和单位 / 建筑索引表一致。

## 「没有这个字段」的哨兵值。`0` 是合法索引（第一个 id），不能用它当空值。
const NO_IDX := 65535

static var upgrade_ids := PackedStringArray()
static var ability_ids := PackedStringArray()
static var _upgrade_idx: Dictionary = {}
static var _ability_idx: Dictionary = {}

static func ensure_type_table() -> void:
	if _types_built:
		return
	unit_ids = GameData.base_ids("units")
	building_ids = GameData.base_ids("buildings")
	upgrade_ids = GameData.base_ids("upgrades")
	for i in range(unit_ids.size()):
		_unit_idx[String(unit_ids[i])] = i
	for i in range(building_ids.size()):
		_building_idx[String(building_ids[i])] = i
	for i in range(upgrade_ids.size()):
		_upgrade_idx[String(upgrade_ids[i])] = i
	# 技能表是**所有单位 `abilities` 字段的并集**（`GameData` 里没有独立的技能表）。
	# 排序后固定，两端各自算出的顺序一致。
	var ab: Array = []
	for uid in unit_ids:
		var ud: Dictionary = GameData.get_unit(String(uid))
		for a in ud.get("abilities", []):
			var s := String(a)
			if not ab.has(s):
				ab.append(s)
	ab.sort()
	ability_ids = PackedStringArray(ab)
	for i in range(ability_ids.size()):
		_ability_idx[String(ability_ids[i])] = i
	_types_built = true

static func _reset_type_table() -> void:
	_types_built = false
	unit_ids = PackedStringArray()
	building_ids = PackedStringArray()
	upgrade_ids = PackedStringArray()
	ability_ids = PackedStringArray()
	_unit_idx.clear()
	_building_idx.clear()
	_upgrade_idx.clear()
	_ability_idx.clear()

static func upgrade_index(id: String) -> int:
	ensure_type_table()
	return int(_upgrade_idx.get(id, -1))

static func upgrade_id_of(idx: int) -> String:
	ensure_type_table()
	if idx < 0 or idx >= upgrade_ids.size():
		return ""
	return String(upgrade_ids[idx])

static func ability_index(id: String) -> int:
	ensure_type_table()
	return int(_ability_idx.get(id, -1))

static func ability_id_of(idx: int) -> String:
	ensure_type_table()
	if idx < 0 or idx >= ability_ids.size():
		return ""
	return String(ability_ids[idx])

# ---------------------------------------------------------------- 读写缓冲

## 可复用的读写缓冲。
##
## ⚠️ **不要每帧 `new()`** —— 见方案「风险 2：序列化不能每帧分配」。
##    几百个单位 × 每 100ms 一次，每帧新建 `StreamPeerBuffer` + 造中间字典，
##    GC 压力会让手机掉帧。`clear()` 把长度置 0 但**不释放底层容量**，
##    所以复用同一个实例时，除了头几帧，之后一次分配都不会有。
##
## 读侧带 `bad` 标记：越界读不会崩，而是把 `bad` 置位，由调用方整份丢弃。
## 畸形包（半包 / 被截断）在 UDP 上是常态，不能靠「不会发生」。
class Buf extends RefCounted:
	var sp := StreamPeerBuffer.new()
	var bad := false

	func clear() -> void:
		sp.clear()
		bad = false

	func size() -> int:
		return sp.get_size()

	func left() -> int:
		return sp.get_available_bytes()

	func ok() -> bool:
		return not bad

	func data() -> PackedByteArray:
		return sp.data_array

	## 把一份收到的字节装进来（解码用）。
	func load_bytes(b: PackedByteArray) -> void:
		sp.clear()
		bad = false
		sp.put_data(b)
		sp.seek(0)

	# ---- 写 ----
	func u8(v: int) -> void:
		sp.put_u8(v & 0xFF)

	func u16(v: int) -> void:
		sp.put_u16(clampi(v, 0, 65535))

	func u32(v: int) -> void:
		sp.put_u32(maxi(0, v))

	func f32(v: float) -> void:
		sp.put_float(v)

	# ---- 读（全部带越界保护）----
	func _need(n: int) -> bool:
		if sp.get_available_bytes() < n:
			bad = true
			return false
		return true

	func u8r() -> int:
		return sp.get_u8() if _need(1) else 0

	func u16r() -> int:
		return sp.get_u16() if _need(2) else 0

	func u32r() -> int:
		return sp.get_u32() if _need(4) else 0

	func f32r() -> float:
		return sp.get_float() if _need(4) else 0.0

	# ---- 短字符串（u8 长度前缀）----
	#
	# 玩家名 / 地图预设 / 种族名都很短，用 1 字节长度足够，也省掉
	# `put_utf8_string` 的 4 字节前缀。**不用 `put_utf8_string`** 还有一个理由：
	# 它的读侧 `get_utf8_string()` 越界时行为不明确，而这里一律走 `_need()`。
	func str8(v: String) -> void:
		var b := v.to_utf8_buffer()
		var n := mini(b.size(), 255)
		u8(n)
		for i in range(n):
			sp.put_u8(b[i])

	func str8r() -> String:
		var n := u8r()
		if bad or not _need(n):
			bad = true
			return ""
		var b := PackedByteArray()
		b.resize(n)
		for i in range(n):
			b[i] = sp.get_u8()
		return b.get_string_from_utf8()

# ---------------------------------------------------------------- 包头

## 组装一个普通包：`[type][proto_ver][payload...]`。
static func packet(msg: int, payload: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2 + payload.size())
	out[0] = msg & 0xFF
	out[1] = PROTOCOL_VERSION & 0xFF
	for i in range(payload.size()):
		out[2 + i] = payload[i]
	return out

## 校验包头。返回 `{"ok": bool, "msg": int, "reason": String}`。
##
## `reason` 一定要能直接显示给玩家 —— 「版本不一致」和「网络不通」
## 对玩家的下一步操作完全不同（前者要更新游戏，后者要检查 WiFi）。
static func check_header(data: PackedByteArray) -> Dictionary:
	if data.size() < 2:
		return {"ok": false, "msg": 0, "reason": "包太短（%d 字节）" % data.size()}
	if data.size() > MAX_PACKET:
		return {"ok": false, "msg": 0, "reason": "包过大（%d 字节）" % data.size()}
	var ver := data[1]
	if ver != PROTOCOL_VERSION:
		return {"ok": false, "msg": data[0],
			"reason": "版本不一致：对方 v%d，本机 v%d" % [ver, PROTOCOL_VERSION]}
	return {"ok": true, "msg": data[0], "reason": ""}

# ---------------------------------------------------------------- 快照：编码

## 把世界状态编成一份快照。
##
## `viewer >= 0` 时**按该 owner 的迷雾过滤** —— 迷雾外的单位与建筑整条不发
## （不是发坐标再让客户端隐藏：发了就能被解包推断出来）。
## `viewer = -1` 表示不过滤（主机自己的视角 / 测试用）。
##
## 返回编码后的字节；同时把可复用的 `buf` 留给调用方继续用。
static func encode_snapshot(w: World, buf: Buf, tick: int, viewer: int = -1) -> PackedByteArray:
	ensure_type_table()
	buf.clear()
	buf.u8(Msg.SNAPSHOT)
	buf.u8(PROTOCOL_VERSION)
	buf.u32(tick)
	buf.f32(w.elapsed)
	buf.u8(w.winner + 1)                       # -1（未结束）→ 0

	for o in [World.PLAYER, World.ENEMY]:
		var f: Dictionary = w.factions.get(o, {})
		buf.u32(int(f.get("minerals", 0)))
		buf.u32(int(f.get("gas", 0)))
		buf.u16(int(f.get("supply_used", 0)))
		buf.u16(int(f.get("supply_cap", 0)))

	var filtered := viewer >= 0
	var fog := w.fog_of(viewer) if filtered else PackedByteArray()

	# ---- 单位 ----
	var ulist: Array = []
	for u in w.units:
		if u.dead:
			continue
		if filtered and not _visible_cell(w, fog, u.pos):
			continue
		ulist.append(u)
	buf.u16(ulist.size())
	for u in ulist:
		var uu: Unit = u
		buf.u32(uu.id)
		buf.u16(unit_type_index(uu.type_id))
		buf.u8(uu.owner_id)
		buf.f32(uu.pos.x)
		buf.f32(uu.pos.y)
		buf.f32(uu.hp)
		buf.f32(uu.shield)
		# ⚠️ 量化一律用 **roundi 而不是 int（截断）**。
		#
		#    实测复算（Python 跑遍 0..2000）：分母是 255 / 8 时截断恰好也是幂等的，
		#    真正会出错的是 **/100** —— `0.29 * 100` 在双精度下是
		#    28.999999999999996，`int()` 截成 28，解回来 0.28，**凭空少 10 毫秒**。
		#    截断是系统性向下偏的，偏差不会互相抵消。
		#
		#    所以规则统一成一条：**量化用 roundi**。代价为零，且让
		#    「解码结果再编码 == 原始字节」（tests/Net.gd 第 3 组）成为构造性保证。
		buf.u8(roundi(fmod(uu.facing, TAU) / TAU * 256.0) & 0xFF)
		buf.u8(maxi(0, MODES.find(uu.mode)))
		var fl := 0
		if uu.attack_move:
			fl |= UF_ATTACK_MOVE
		if uu.has_move_order:
			fl |= UF_MOVE_ORDER
		if uu.flash > 0.0:
			fl |= UF_FLASH
		if uu.in_combat:
			fl |= UF_IN_COMBAT
		buf.u8(fl)
		buf.u8(clampi(roundi(uu.carry * 8.0), 0, 255))
		buf.u8(uu.harvest_state & 0xFF)

	# ---- 建筑 ----
	var blist: Array = []
	for b in w.buildings:
		if b.dead:
			continue
		if filtered and not _visible_cell(w, fog, b.pos):
			continue
		blist.append(b)
	buf.u16(blist.size())
	for b in blist:
		var bb: Building = b
		buf.u32(bb.id)
		buf.u16(building_type_index(bb.type_id))
		buf.u8(bb.owner_id)
		buf.f32(bb.pos.x)
		buf.f32(bb.pos.y)
		buf.f32(bb.hp)
		# ⚠️ 发的是 `progress_ratio()`（0..1 的比例），**不是 `build_progress` 本身**。
		#    `build_progress` 有两种含义：完工后它等于 `build_time`（40 / 26 / 24…），
		#    施工中才是「已投入的秒数」。直接发它会一路被 clamp 到 255，
		#    解回来全变成 1.0 —— 症状是「每个建筑往返后进度都不一样」。
		buf.u8(clampi(roundi(bb.progress_ratio() * 255.0), 0, 255))
		var bfl := 0
		if bb.complete:
			bfl |= BF_COMPLETE
		if bb.flash > 0.0:
			bfl |= BF_FLASH
		if bb.has_rally:
			bfl |= BF_RALLY
		buf.u8(bfl)
		var q: Array = bb.queue
		buf.u8(mini(q.size(), 255))
		for qi in range(mini(q.size(), 255)):
			var it: Dictionary = q[qi]
			buf.u16(unit_type_index(String(it.get("type_id", ""))))
			# 单位是 1/100 秒。这里必须 roundi —— 见上面 facing 那段
			buf.u16(clampi(roundi(float(it.get("time_left", 0.0)) * 100.0), 0, 65535))
		if bb.has_rally:
			buf.f32(bb.rally.x)
			buf.f32(bb.rally.y)

	# ---- 资源节点 ----
	# 位置不传：两端用同一个地图种子生成，资源点本来就在。
	# 只传「会变的量」—— 被采掉多少。80 个矿点 × 6 字节 = 480 字节，很便宜。
	buf.u16(w.resources.size())
	for i in range(w.resources.size()):
		var r: Dictionary = w.resources[i]
		buf.u16(i)
		buf.f32(float(r.get("amount", 0.0)))

	return buf.data()

# ---------------------------------------------------------------- 快照：解码

## 把一份快照应用到 `w`。
##
## `w` 必须**已经用同一个地图种子生成过地形**（地形与资源点不传输）。
## 返回 `{"ok": bool, "reason": String, "units": n, "buildings": n}`。
##
## 客户端每收到一份就重建一遍 —— `reset_dynamic()` 会先把上一帧的
## 单位 / 建筑清干净，并把建筑占的格子**解封**。
static func apply_snapshot(w: World, data: PackedByteArray) -> Dictionary:
	ensure_type_table()
	var hdr := check_header(data)
	if not hdr["ok"]:
		return {"ok": false, "reason": String(hdr["reason"]), "units": 0, "buildings": 0}
	if int(hdr["msg"]) != Msg.SNAPSHOT:
		return {"ok": false, "reason": "不是快照包", "units": 0, "buildings": 0}

	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()                                    # type
	r.u8r()                                    # proto_ver
	var tick := r.u32r()
	w.elapsed = r.f32r()
	# ★胜负是**单调**的：一旦结算过，后面的快照不能把它「复活」。★
	#
	#   投降是**会话层**决定，本端立刻结算；而主机要一个来回才知道。
	#   在这一个来回里，主机发出的快照仍然带着 `winner = -1`（它那边还没结束）。
	#   照抄的话，客户端刚弹出来的结算界面会被下一份快照顶回去 ——
	#   玩家看到的是「点了投降，画面闪一下又回到游戏里」，而且不报错。
	var snap_winner := r.u8r() - 1
	if not w.game_ended:
		w.winner = snap_winner
		w.game_ended = w.winner >= 0
		if w.game_ended:
			# 客户端不跑 `step()`，`_check_game_over()` 永远不会被调到，
			# 所以这个信号必须在这里补发 —— 否则客户端的结算界面永远不弹。
			w.game_over.emit(w.winner)

	for o in [World.PLAYER, World.ENEMY]:
		var f: Dictionary = w.factions.get(o, {})
		f["minerals"] = r.u32r()
		f["gas"] = r.u32r()
		f["supply_used"] = r.u16r()
		f["supply_cap"] = r.u16r()
		w.factions[o] = f

	w.reset_dynamic()

	# ---- 单位 ----
	var un := r.u16r()
	for i in range(un):
		if not r.ok():
			break
		var id := r.u32r()
		var ti := r.u16r()
		var owner := r.u8r()
		var x := r.f32r()
		var y := r.f32r()
		var hp := r.f32r()
		var shield := r.f32r()
		var fb := r.u8r()
		var mi := r.u8r()
		var fl := r.u8r()
		var carry := r.u8r()
		var hstate := r.u8r()
		var tid := unit_type_id(ti)
		if tid == "":
			# 未知类型：字段已经读掉了，只是不造单位。
			# 直接 break 的话后面全部错位，症状是「收到快照之后单位全乱」。
			continue
		var u := Unit.new()
		u.setup(tid, _race_of(w, owner), Vector2(x, y), owner, id)
		# ⚠️ `setup()` 会调 `grid.nearest_free_world()` 吸附 ——
		#    快照里的坐标是权威的，必须原样覆盖，否则客户端位置会持续漂移。
		u.pos = Vector2(x, y)
		u.final_target = Vector2(x, y)
		u.hp = hp
		u.shield = shield
		u.facing = float(fb) / 256.0 * TAU
		u.mode = String(MODES[clampi(mi, 0, MODES.size() - 1)])
		u.attack_move = (fl & UF_ATTACK_MOVE) != 0
		u.has_move_order = (fl & UF_MOVE_ORDER) != 0
		u.flash = 0.18 if (fl & UF_FLASH) != 0 else 0.0
		u.in_combat = (fl & UF_IN_COMBAT) != 0
		u.carry = float(carry) / 8.0
		u.harvest_state = hstate
		w.units.append(u)
		w._next_id = maxi(w._next_id, id + 1)

	# ---- 建筑 ----
	var bn := r.u16r()
	for i in range(bn):
		if not r.ok():
			break
		var id := r.u32r()
		var ti := r.u16r()
		var owner := r.u8r()
		var x := r.f32r()
		var y := r.f32r()
		var hp := r.f32r()
		var prog := r.u8r()
		var bfl := r.u8r()
		var qn := r.u8r()
		var qlist: Array = []
		for qi in range(qn):
			var qt := r.u16r()
			var qt_left := r.u16r()
			qlist.append({"type_id": unit_type_id(qt),
				"time_left": float(qt_left) / 100.0, "total": 1.0})
		var rally := Vector2.ZERO
		if (bfl & BF_RALLY) != 0:
			rally = Vector2(r.f32r(), r.f32r())
		var tid := building_type_id(ti)
		if tid == "":
			continue
		var complete := (bfl & BF_COMPLETE) != 0
		var b := Building.new()
		b.setup(tid, _race_of(w, owner), Vector2(x, y), owner, id, complete)
		b.pos = Vector2(x, y)
		b.complete = complete
		# 比例 → 秒。`complete` 的建筑这里会算回正好 `build_time`，
		# 与 `setup(instant=true)` 的结果一致 —— 否则每次快照都会「重算进度」。
		b.build_progress = float(prog) / 255.0 * b.build_time
		b.hp = hp
		b.flash = 0.18 if (bfl & BF_FLASH) != 0 else 0.0
		b.queue = qlist
		b.has_rally = (bfl & BF_RALLY) != 0
		b.rally = rally
		var c := w.grid.world_to_cell(Vector2(x, y))
		b.cell_pos = Vector2i(c.x - b.cells_w / 2, c.y - b.cells_h / 2)
		w.grid.mark_area(b.cell_pos, b.cells_w, b.cells_h, true)
		w.buildings.append(b)
		w._next_id = maxi(w._next_id, id + 1)

	# ---- 资源节点 ----
	var rn := r.u16r()
	for i in range(rn):
		if not r.ok():
			break
		var idx := r.u16r()
		var amount := r.f32r()
		if idx < w.resources.size():
			(w.resources[idx] as Dictionary)["amount"] = amount

	if not r.ok():
		return {"ok": false, "reason": "快照被截断", "units": w.units.size(),
			"buildings": w.buildings.size()}

	w._recount_supply(World.PLAYER)
	w._recount_supply(World.ENEMY)
	w._rebuild_hash()
	w._rebuild_creep()
	w._refresh_terrain_flags()
	return {"ok": true, "reason": "", "units": w.units.size(),
		"buildings": w.buildings.size(), "tick": tick}

# ---------------------------------------------------------------- 指令：编码 / 解码

## 客户端能上行的指令种类。
##
## 设计原则：**一包一条指令**。玩家手速最多每秒几次，一条一包省掉了
## 「一个包里塞多条、中间某条坏了整包怎么办」这类问题。
## 代价是每条 24 字节固定头 + 8 字节/单位，一次框选 100 个兵也就 800 字节。
enum Cmd {
	MOVE = 1,           # 目标点；flags bit0 = 攻击移动
	ATTACK = 2,         # 目标实体（`target_id`）
	SMART = 3,          # 智能右键：点资源 → 采集 / 点实体 → 攻击 / 点地面 → 移动
	STOP = 4,
	HARVEST = 5,        # `node_idx` 指向 `w.resources` 的下标
	BUILD = 6,          # `str_idx` = 建筑 type_id
	TRAIN = 7,          # `building_id` + `str_idx` = 单位 type_id
	RESEARCH = 8,       # `building_id` + `str_idx` = 升级 id
	ABILITY = 9,        # `str_idx` = 技能 id，`target_id` 可选
	CANCEL_BUILD = 10,  # `building_id`
	CANCEL_QUEUE = 11,  # `building_id` + flags 存队列下标
	RALLY = 12,         # `building_id` + 目标点
}

## 指令记录是**定长 24 字节**：
##
## ```
## u8   kind
## u8   flags          # bit0 = 攻击移动；CANCEL_QUEUE 时是队列下标
## u16  str_idx        0xFFFF = 无
## u16  n_units
## u16  node_idx       0xFFFF = 无
## u32  building_id    0 = 无
## u32  target_id      0 = 无
## f32  x, y
## ```
##
## 定长是为了让「复用 buffer」那条纪律成立 —— 变长记录一旦某条坏掉，
## 后面全部错位，而错位的症状是「指令下到了别的单位身上」。
static func packet_cmd(buf: Buf, seq: int, kind: int, ids: Array,
		p: Dictionary = {}) -> PackedByteArray:
	ensure_type_table()
	var sid := ""
	match kind:
		Cmd.BUILD:
			sid = String(p.get("type_id", ""))
		Cmd.TRAIN:
			sid = String(p.get("type_id", ""))
		Cmd.RESEARCH:
			sid = String(p.get("upgrade_id", ""))
		Cmd.ABILITY:
			sid = String(p.get("ability_id", ""))
	var si := NO_IDX
	match kind:
		Cmd.BUILD:
			si = _idx_or_none(building_type_index(sid))
		Cmd.TRAIN:
			si = _idx_or_none(unit_type_index(sid))
		Cmd.RESEARCH:
			si = _idx_or_none(upgrade_index(sid))
		Cmd.ABILITY:
			si = _idx_or_none(ability_index(sid))

	buf.clear()
	buf.u8(Msg.CMD)
	buf.u8(PROTOCOL_VERSION)
	buf.u32(seq)
	buf.u8(kind)
	buf.u8(int(p.get("flags", 0)) & 0xFF)
	buf.u16(si)
	buf.u16(mini(ids.size(), 65535))
	buf.u16(int(p.get("node_idx", NO_IDX)))
	buf.u32(int(p.get("building_id", 0)))
	buf.u32(int(p.get("target_id", 0)))
	buf.f32(float(p.get("x", 0.0)))
	buf.f32(float(p.get("y", 0.0)))
	for i in range(mini(ids.size(), 65535)):
		buf.u32(int(ids[i]))
	return buf.data()

## 合法索引 0..65534；非法（-1）统一折成 `NO_IDX`。
##
## ⚠️ 这里如果直接写 `u16(-1)`，会被 `clampi` 夹成 **0** —— 而 0 是
##    合法索引（排序后的第一个 id）。症状是「未知兵种被当成某个真实兵种造出来」。
static func _idx_or_none(i: int) -> int:
	return i if i >= 0 else NO_IDX

## 解码一个指令包。返回 `{"ok", "reason", "seq", "kind", "flags", "n_units",
## "node_idx", "building_id", "target_id", "x", "y", "ids", "type_id",
## "upgrade_id", "ability_id"}`。
static func decode_cmd(data: PackedByteArray) -> Dictionary:
	ensure_type_table()
	var hdr := check_header(data)
	if not bool(hdr["ok"]):
		return {"ok": false, "reason": String(hdr["reason"])}
	if int(hdr["msg"]) != Msg.CMD:
		return {"ok": false, "reason": "不是指令包"}
	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()
	r.u8r()
	var seq := r.u32r()
	var kind := r.u8r()
	var flags := r.u8r()
	var si := r.u16r()
	var n := r.u16r()
	var node := r.u16r()
	var bid := r.u32r()
	var tid := r.u32r()
	var x := r.f32r()
	var y := r.f32r()
	var ids: Array = []
	for i in range(n):
		ids.append(r.u32r())
	if not r.ok():
		# 半包在 UDP 上是常态。**不能靠「不会发生」**。
		return {"ok": false, "reason": "指令包被截断"}

	var out := {
		"ok": true, "reason": "", "seq": seq, "kind": kind, "flags": flags,
		"n_units": n, "node_idx": node, "building_id": bid, "target_id": tid,
		"x": x, "y": y, "ids": ids,
		"type_id": "", "upgrade_id": "", "ability_id": "",
	}
	match kind:
		Cmd.BUILD:
			out["type_id"] = building_type_id(si)
		Cmd.TRAIN:
			out["type_id"] = unit_type_id(si)
		Cmd.RESEARCH:
			out["upgrade_id"] = upgrade_id_of(si)
		Cmd.ABILITY:
			out["ability_id"] = ability_id_of(si)
	return out

# ---------------------------------------------------------------- 指令：应用（主机侧）

## 在 `w` 上执行一条来自 `sender` 的指令。
##
## ★**这里必须有归属校验。**★ 不做的话，一个改过的客户端可以直接
## `cmd_stop(对方全部单位)` 或者把对方的基地取消掉 ——
## 局域网里也是真作弊，不是「自己人无所谓」。
##
## 返回 `{"ok": bool, "reason": String}`。`reason` 会被回传给客户端显示 ——
## **不回传的话，客户端点了没反应且不知道为什么**。
static func apply_cmd(w: World, cmd: Dictionary, sender: int) -> Dictionary:
	if not bool(cmd.get("ok", false)):
		return {"ok": false, "reason": String(cmd.get("reason", "指令无效"))}
	if w == null:
		return {"ok": false, "reason": "世界不存在"}
	if w.game_ended:
		return {"ok": false, "reason": "对局已结束"}

	var kind := int(cmd["kind"])
	var ids: Array = cmd["ids"]

	# ---- 参战单位：只能是自己人 ----
	var picked: Array = []
	var foreign := 0
	for id in ids:
		var u := find_unit(w, int(id))
		if u == null:
			continue
		if u.owner_id != sender:
			foreign += 1
			continue
		picked.append(u)
	if foreign > 0:
		# 不回传具体数字 —— 玩家不需要知道，但日志里要留痕
		push_warning("[Net] 玩家 %d 试图指挥 %d 个不属于自己的单位，已忽略" % [sender, foreign])
	if not ids.is_empty() and picked.is_empty():
		return {"ok": false, "reason": "没有可指挥的单位"}

	# ---- 目标建筑：同样只能是自己人 ----
	var b: Building = null
	if int(cmd["building_id"]) != 0:
		b = find_building(w, int(cmd["building_id"]))
		if b == null:
			return {"ok": false, "reason": "目标建筑不存在"}
		if b.owner_id != sender:
			push_warning("[Net] 玩家 %d 试图指挥不属于自己的建筑 %d" % [sender, b.id])
			return {"ok": false, "reason": "那不是你的建筑"}

	var pos := Vector2(float(cmd["x"]), float(cmd["y"]))
	var flags := int(cmd["flags"])

	match kind:
		Cmd.MOVE:
			if not _in_map(w, pos):
				return {"ok": false, "reason": "目标点在地图外"}
			w.cmd_move(picked, pos, (flags & 1) != 0)
		Cmd.ATTACK:
			# ⚠️ `find_entity` 返回 Variant（单位或建筑），必须显式标注 ——
			#    `var tgt := ...` 会报「inferred from a Variant value」。
			var tgt: Variant = find_entity(w, int(cmd["target_id"]))
			if tgt == null:
				return {"ok": false, "reason": "目标已不存在"}
			w.cmd_attack(picked, tgt)
		Cmd.SMART:
			if not _in_map(w, pos):
				return {"ok": false, "reason": "目标点在地图外"}
			var ni := int(cmd["node_idx"])
			var node = null
			if ni != NO_IDX and ni >= 0 and ni < w.resources.size():
				node = w.resources[ni]
			w.cmd_smart(picked, pos, node, find_entity(w, int(cmd["target_id"])))
		Cmd.STOP:
			w.cmd_stop(picked)
		Cmd.HARVEST:
			var hi := int(cmd["node_idx"])
			if hi < 0 or hi >= w.resources.size():
				return {"ok": false, "reason": "资源点不存在"}
			w.cmd_harvest(picked, w.resources[hi])
		Cmd.BUILD:
			var tid2 := String(cmd["type_id"])
			if tid2 == "":
				return {"ok": false, "reason": "未知建筑类型"}
			if not _in_map(w, pos):
				return {"ok": false, "reason": "目标点在地图外"}
			# 用 sender 自己的农民；`picked` 里非农民会被 `cmd_build` 自己滤掉
			if not w.cmd_build(tid2, pos, sender, picked):
				return {"ok": false, "reason": _place_reason(w, tid2, pos, sender)}
		Cmd.TRAIN:
			if b == null:
				return {"ok": false, "reason": "没有选中建筑"}
			var utid := String(cmd["type_id"])
			if utid == "":
				return {"ok": false, "reason": "未知兵种"}
			if not w.cmd_train(b, utid):
				return {"ok": false, "reason": "无法训练（资源不足或队列已满）"}
		Cmd.RESEARCH:
			if b == null:
				return {"ok": false, "reason": "没有选中建筑"}
			var uid := String(cmd["upgrade_id"])
			if uid == "":
				return {"ok": false, "reason": "未知升级"}
			if not w.cmd_research(b, uid):
				return {"ok": false, "reason": "无法研究（已满级或资源不足）"}
		Cmd.ABILITY:
			var aid := String(cmd["ability_id"])
			if aid == "":
				return {"ok": false, "reason": "未知技能"}
			# 只对「能用这个技能」的那些下指令 —— 混编部队点兴奋剂时，
			# 坦克不该因此报错（和 Main 里的处理一致）。
			var users: Array = []
			for u in picked:
				if w.can_use_ability(u, aid):
					users.append(u)
			if users.is_empty():
				return {"ok": false, "reason": "选中的单位都不能使用该技能"}
			w.cmd_ability(users, aid, find_entity(w, int(cmd["target_id"])))
		Cmd.CANCEL_BUILD:
			if b == null:
				return {"ok": false, "reason": "没有选中建筑"}
			if not w.cancel_build(b):
				return {"ok": false, "reason": "无法取消"}
		Cmd.CANCEL_QUEUE:
			if b == null:
				return {"ok": false, "reason": "没有选中建筑"}
			if not w.cancel_queue(b, flags & 0xFF):
				return {"ok": false, "reason": "无法取消该队列项"}
		Cmd.RALLY:
			if b == null:
				return {"ok": false, "reason": "没有选中建筑"}
			if not _in_map(w, pos):
				return {"ok": false, "reason": "目标点在地图外"}
			b.rally = pos
			b.has_rally = true
		_:
			return {"ok": false, "reason": "未知指令 %d" % kind}
	return {"ok": true, "reason": ""}

static func _in_map(w: World, p: Vector2) -> bool:
	return p.x >= 0.0 and p.y >= 0.0 and p.x < w.world_size.x and p.y < w.world_size.y

## 建造失败时把 `can_place_building` 的原因抠出来 —— `cmd_build` 只返回 bool。
static func _place_reason(w: World, type_id: String, pos: Vector2, owner: int) -> String:
	var chk := w.can_place_building(type_id, pos, owner)
	return String(chk.get("reason", "无法在此建造"))

## 按 id 找单位。⚠️ 单位和建筑**共用同一个 `_next_id` 计数器**，
## 所以 id 在整个世界里是唯一的，可以分别查两张表。
static func find_unit(w: World, id: int) -> Unit:
	if id <= 0:
		return null
	for u in w.units:
		if u.id == id:
			return u
	return null

static func find_building(w: World, id: int) -> Building:
	if id <= 0:
		return null
	for b in w.buildings:
		if b.id == id:
			return b
	return null

## 单位或建筑都行（攻击 / 智能右键的目标可能是任意一种）。
static func find_entity(w: World, id: int) -> Variant:
	var u := find_unit(w, id)
	if u != null:
		return u
	return find_building(w, id)

# ---------------------------------------------------------------- 握手：HELLO / WELCOME

## 双方**基础表**的指纹（单位 / 建筑 / 升级 / 技能四张表的名字集合）。
##
## 为什么要有它：索引表两端各自构建，只要键集相同结果就必然一致。
## 但如果**客户端装了模组、主机没装**（或两边装的模组不同），
## 键集就可能不同 —— 而本项目的模组只允许覆盖已有条目，
## 所以「键集不同」现在只可能来自**两边游戏版本不同**。
##
## 不管来源是什么，症状都是「我的陆战队员变成了攻城坦克」。
## 带一个指纹在 `HELLO` 里，就能在**握手阶段**直接拒绝，
## 而不是让玩家在打了 5 分钟之后发现兵种全乱。
static func table_fingerprint() -> int:
	ensure_type_table()
	var s := "|".join(unit_ids) + "#" + "|".join(building_ids) \
		+ "#" + "|".join(upgrade_ids) + "#" + "|".join(ability_ids)
	return hash(s) & 0x7FFFFFFF

static func packet_hello(buf: Buf, player_name: String) -> PackedByteArray:
	buf.clear()
	buf.u8(Msg.HELLO)
	buf.u8(PROTOCOL_VERSION)
	buf.u32(table_fingerprint())
	buf.str8(player_name)
	return buf.data()

static func decode_hello(data: PackedByteArray) -> Dictionary:
	var hdr := check_header(data)
	if not bool(hdr["ok"]):
		return {"ok": false, "reason": String(hdr["reason"]), "name": "", "fingerprint": 0}
	if int(hdr["msg"]) != Msg.HELLO:
		return {"ok": false, "reason": "不是握手包", "name": "", "fingerprint": 0}
	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()
	r.u8r()
	var fp := r.u32r()
	var nm := r.str8r()
	if not r.ok():
		return {"ok": false, "reason": "握手包被截断", "name": "", "fingerprint": 0}
	var mine := table_fingerprint()
	if fp != mine:
		return {"ok": false, "name": nm, "fingerprint": fp,
			"reason": "双方游戏版本 / 模组不一致（对方 %d，本机 %d）" % [fp, mine]}
	return {"ok": true, "reason": "", "name": nm, "fingerprint": fp}

## 主机告诉客户端「这一局长什么样」。
##
## ★**随机种子必须由主机下发**★。两端各自生成地图的话，只要有一格不一致，
## 客户端就会看到单位「穿墙」—— 因为主机认为那里是平地。
static func packet_welcome(buf: Buf, your_owner: int, world_seed: int,
		map_w: int, map_h: int, map_preset: String,
		race_p: String, race_e: String, difficulty: String,
		host_name: String = "") -> PackedByteArray:
	buf.clear()
	buf.u8(Msg.WELCOME)
	buf.u8(PROTOCOL_VERSION)
	buf.u8(your_owner & 0xFF)
	buf.u32(world_seed & 0xFFFFFFFF)
	buf.u16(map_w)
	buf.u16(map_h)
	buf.str8(map_preset)
	buf.str8(race_p)
	buf.str8(race_e)
	buf.str8(difficulty)
	buf.str8(host_name)
	return buf.data()

static func decode_welcome(data: PackedByteArray) -> Dictionary:
	var hdr := check_header(data)
	if not bool(hdr["ok"]):
		return {"ok": false, "reason": String(hdr["reason"])}
	if int(hdr["msg"]) != Msg.WELCOME:
		return {"ok": false, "reason": "不是欢迎包"}
	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()
	r.u8r()
	var owner := r.u8r()
	var sd := r.u32r()
	var mw := r.u16r()
	var mh := r.u16r()
	var preset := r.str8r()
	var rp := r.str8r()
	var re := r.str8r()
	var diff := r.str8r()
	var hname := r.str8r()
	if not r.ok():
		return {"ok": false, "reason": "欢迎包被截断"}
	if owner != World.PLAYER and owner != World.ENEMY:
		return {"ok": false, "reason": "主机分配的阵营号非法（%d）" % owner}
	if mw <= 0 or mh <= 0 or mw > 512 or mh > 512:
		return {"ok": false, "reason": "地图尺寸非法（%dx%d）" % [mw, mh]}
	if rp == "" or re == "":
		return {"ok": false, "reason": "种族为空"}
	return {"ok": true, "reason": "", "owner": owner, "seed": sd,
		"map_w": mw, "map_h": mh, "map_preset": preset,
		"race_p": rp, "race_e": re, "difficulty": diff, "host_name": hname}

# ---------------------------------------------------------------- 拒绝回执

## 主机拒绝一条指令时回给客户端的说明。
##
## **必须有。** 没有的话，客户端点了建筑放不下去、兵不造出来，
## 屏幕上什么都没有 —— 玩家唯一的结论是「联机有 bug」，
## 而实际上是「资源不足」或「离矿点太近」。
static func packet_reject(buf: Buf, seq: int, reason: String) -> PackedByteArray:
	buf.clear()
	buf.u8(Msg.REJECT)
	buf.u8(PROTOCOL_VERSION)
	buf.u32(seq)
	buf.str8(reason)
	return buf.data()

static func decode_reject(data: PackedByteArray) -> Dictionary:
	var hdr := check_header(data)
	if not bool(hdr["ok"]) or int(hdr["msg"]) != Msg.REJECT:
		return {"ok": false, "reason": "", "seq": 0}
	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()
	r.u8r()
	var seq := r.u32r()
	var why := r.str8r()
	return {"ok": r.ok(), "reason": why, "seq": seq}

# ---------------------------------------------------------------- 大厅：准备 / 开始（M4c）

## 客户端告诉主机「我准备好了」。
##
## ⚠️ 带一个显式的布尔值而不是「收到就算准备好」——
##    玩家要能**取消**准备（改主意、去接电话），而「无包 = 没准备好」
##    没法区分「还没点」和「点了又取消」。
static func packet_ready(buf: Buf, v: bool) -> PackedByteArray:
	buf.clear()
	buf.u8(Msg.READY)
	buf.u8(PROTOCOL_VERSION)
	buf.u8(1 if v else 0)
	return buf.data()

static func decode_ready(data: PackedByteArray) -> bool:
	var hdr := check_header(data)
	if not bool(hdr["ok"]) or int(hdr["msg"]) != Msg.READY:
		return false
	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()
	r.u8r()
	return r.u8r() != 0

## 主机宣布开局。**没有载荷** —— 开局的参数早在 `WELCOME` 里发过了。
static func packet_start() -> PackedByteArray:
	return packet(Msg.START)

# ---------------------------------------------------------------- 对局内：聊天 / 投降 / 暂停（M4c）

## 聊天文本长度上限（**按字节**，不是字符）。
##
## ⚠️ 中文一个字 3 字节，所以 240 字节 ≈ 80 个汉字。
##    上限的作用不是「防刷屏」（那是限流的事），而是**防止一个畸形包
##    把 `str8` 的 1 字节长度前缀撑爆** —— `str8` 最多存 255 字节。
const MAX_CHAT_BYTES := 240

## 聊天包。
##
## ⚠️ **包里不带发送者名字。** 名字由收包方按 peer 查自己的会话状态 ——
##    带名字的话客户端能冒充主机说话。
static func packet_chat(buf: Buf, text: String) -> PackedByteArray:
	buf.clear()
	buf.u8(Msg.CHAT)
	buf.u8(PROTOCOL_VERSION)
	var b := text.to_utf8_buffer()
	if b.size() > MAX_CHAT_BYTES:
		b = b.slice(0, MAX_CHAT_BYTES)
		# ⚠️ 截断可能把一个多字节汉字切成半个 → `get_string_from_utf8()`
		#    会给出替换字符。宁可少一个字也不要乱码。
		#
		# ★只在**真的截断过**的时候才修补。★ 放到 `if` 外面的话，
		#   每一条消息的最后一个字都会被吃掉 —— 因为**任何**多字节字符的
		#   最后一个字节都是 `10xxxxxx`。症状极隐蔽：只有中文消息末尾
		#   少一截，纯英文消息（末字节是 `0xxxxxxx`）完全正常。
		b = trim_partial_utf8(b)
	buf.u8(b.size())
	for i in range(b.size()):
		buf.sp.put_u8(b[i])
	return buf.data()

## 去掉结尾处**被切了一半**的 UTF-8 字符，返回落在完整字符边界上的前缀。
##
## ⚠️ 这里最容易写错的地方：**不能**用「长度」变量一边当扫描游标、
##    一边当返回值。`while (最后一个字节是续字节) 长度 -= 1` 这种写法
##    会把**完整的最后一个字**也砍掉（任何多字节字符的末字节都是续字节），
##    而且砍完还不觉得错 —— 于是「每条中文消息末尾都少一个字」。
##
## 正确做法：先找到**最后一个字符的起始下标**，再看它够不够长。
static func trim_partial_utf8(b: PackedByteArray) -> PackedByteArray:
	var n := b.size()
	if n == 0:
		return b
	var i := n - 1
	while i > 0 and (b[i] & 0xC0) == 0x80:
		i -= 1                     # 续字节 → 继续往前找前导字节
	var c := b[i]
	var need := 1
	if (c & 0xE0) == 0xC0:
		need = 2
	elif (c & 0xF0) == 0xE0:
		need = 3
	elif (c & 0xF8) == 0xF0:
		need = 4
	if i + need <= n:
		return b                   # 最后一个字符是完整的 → 原样保留
	return b.slice(0, i)           # 残字 → 切到它的前导字节之前

static func decode_chat(data: PackedByteArray) -> Dictionary:
	var hdr := check_header(data)
	if not bool(hdr["ok"]) or int(hdr["msg"]) != Msg.CHAT:
		return {"ok": false, "reason": "不是聊天包", "text": ""}
	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()
	r.u8r()
	var n := r.u8r()
	if n > MAX_CHAT_BYTES:
		return {"ok": false, "reason": "聊天内容过长", "text": ""}
	if r.sp.get_available_bytes() < n:
		return {"ok": false, "reason": "聊天包被截断", "text": ""}
	var b := PackedByteArray()
	b.resize(n)
	for i in range(n):
		b[i] = r.sp.get_u8()
	var t := b.get_string_from_utf8()
	if t.strip_edges() == "":
		return {"ok": false, "reason": "空消息", "text": ""}
	return {"ok": true, "reason": "", "text": t}

## 投降。**没有载荷** —— 收到就代表对方认输了。
static func packet_surrender() -> PackedByteArray:
	return packet(Msg.SURRENDER)

## 暂停 / 恢复。`paused` = 要不要暂停。
static func packet_pause(buf: Buf, paused: bool) -> PackedByteArray:
	buf.clear()
	buf.u8(Msg.PAUSE)
	buf.u8(PROTOCOL_VERSION)
	buf.u8(1 if paused else 0)
	return buf.data()

static func decode_pause(data: PackedByteArray) -> bool:
	var hdr := check_header(data)
	if not bool(hdr["ok"]) or int(hdr["msg"]) != Msg.PAUSE:
		return false
	var r := Buf.new()
	r.load_bytes(data)
	r.u8r()
	r.u8r()
	return r.u8r() != 0

# ---------------------------------------------------------------- 内部

static func _race_of(w: World, owner: int) -> String:
	var f: Dictionary = w.factions.get(owner, {})
	return String(f.get("race", "terran"))

static func _visible_cell(w: World, fog: PackedByteArray, p: Vector2) -> bool:
	var c := w.grid.world_to_cell(p)
	if c.x < 0 or c.y < 0 or c.x >= w.grid.w or c.y >= w.grid.h:
		return false
	var i := c.y * w.grid.w + c.x
	if i < 0 or i >= fog.size():
		return false
	return (fog[i] & World.VIS_VISIBLE) != 0
