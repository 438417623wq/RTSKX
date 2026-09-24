extends SceneTree

## 局域网协议层（第十三轮 M4a）。
##
## 判据：**往返一致（编码 → 解码 → 逐字段相同）；300 单位快照 < 12 KB；
## 复用 buffer 时输出稳定**。
##
## 为什么这一套能纯无头跑：`Net.gd` 只做纯数据的事，**完全不碰 ENet**。
## 编解码是纯函数，可以直接构造世界 → 编码 → 解码 → 比对。
## 一旦掺进 ENet，就只能靠两个进程互连，复杂度和不确定性都上一个台阶。
##
## ⚠️ 两条纪律：
##   1. **两个世界必须用同一个种子生成**（地形与资源点不传输，
##      靠「同一个地图种子」重建）。种子不同的话地形都不一样，
##      比对结果毫无意义 —— 而且看起来像「编解码有 bug」。
##   2. **坐标比对要给容差**：快照里 x/y/hp 都是 f32，
##      而 GDScript 的 float 是 f64。往返必然有 ~1e-4 的误差，
##      写死 `==` 会得到一个永远红的断言。

## 地图尺寸。48×32 = 1536 格，够小、跑得快，也能放下 300 个单位。
const MW := 48
const MH := 32
const SEED := 20260923

## f32 往返容差。坐标绝对值最大到 48×32×32 = 1536，f32 的有效位约 7 位十进制，
## 误差量级 1e-4 —— 取 0.01 留两个数量级余量。
const EPS := 0.01

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

func _eqf(a: float, b: float, label: String) -> void:
	_ok(absf(a - b) <= EPS, "%s（期望 %.4f，实测 %.4f）" % [label, b, a])

## 用固定种子造一个世界。**必须每次调 `seed()`** —— 否则第二次生成的地形不同。
func _make_world(p_race: String = "terran", e_race: String = "zerg") -> World:
	seed(SEED)
	return World.new(MW, MH, p_race, e_race, "easy")

func _initialize() -> void:
	print("=============== 局域网协议测试 ===============")

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_g1_type_table()
	_g2_header()
	_g3_roundtrip()
	_g4_size()
	_g5_reuse()
	_g6_determinism()
	_g7_fog()
	_g8_malformed()
	_g9_reset_dynamic()
	_g10_local_owner()
	_g11_cmd()
	_g12_handshake()
	print("============================================")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

# ---------------------------------------------------------------- 1. 类型索引表

func _g1_type_table() -> void:
	print("-- 1. 类型索引表 --")
	Net._reset_type_table()
	Net.ensure_type_table()
	_eqi(Net.unit_ids.size(), GameData.base_ids("units").size(),
		"单位索引表覆盖全部 %d 个基础单位" % GameData.base_ids("units").size())
	_eqi(Net.building_ids.size(), GameData.base_ids("buildings").size(),
		"建筑索引表覆盖全部 %d 个基础建筑" % GameData.base_ids("buildings").size())

	# 字母序 —— 两端各自构建，顺序必须一致，不能依赖字典的插入序
	var sorted_ok := true
	for i in range(1, Net.unit_ids.size()):
		if String(Net.unit_ids[i - 1]) > String(Net.unit_ids[i]):
			sorted_ok = false
	_ok(sorted_ok, "单位索引表按字母序（两端才能算出同一份表）")

	var roundtrip_ok := true
	for id in Net.unit_ids:
		if Net.unit_type_id(Net.unit_type_index(String(id))) != String(id):
			roundtrip_ok = false
	_ok(roundtrip_ok, "每个单位 id 都能索引 → 反索引回来")

	_eqi(Net.unit_type_index("marine"), Net.unit_type_index("marine"), "同一 id 两次索引结果相同")
	_eqi(Net.unit_type_index("no_such_unit"), -1, "未知单位返回 -1")
	_eqs(Net.unit_type_id(-1), "", "非法索引返回空串")
	_eqs(Net.unit_type_id(99999), "", "越界索引返回空串")
	_eqi(Net.building_type_index("no_such_building"), -1, "未知建筑返回 -1")

	# ★索引表必须来自基础表，不能来自模组改过的副本★
	# 症状是「客户端装了模组、主机没装 → 我的陆战队员变成攻城坦克」。
	#
	# ⚠️ **不能靠 `apply_mod_patch` 来构造这个场景**：本版 `_merge_table` 明确
	#    拒绝「新建条目」（只允许覆盖已有 id），补丁永远改不动 key 集合 ——
	#    第一版就是这么写的，结果阳性对照**打不红**，等于一条永远为真的废断言。
	#    这里直接往 `UNITS` 里塞一个**排序在 marine 之前**的假单位，
	#    模拟「将来允许模组新建单位」时索引整体错位的后果。
	var before := Net.unit_type_index("marine")
	GameData.reset_to_base()
	GameData.UNITS["aaa_fake_unit"] = {"hp": 1, "name": "假单位", "cost": 1}
	_ok(not GameData.base_ids("units").has("aaa_fake_unit"),
		"基础表里没有这个假单位（它只污染了 UNITS 副本）")
	Net._reset_type_table()
	Net.ensure_type_table()
	_eqi(Net.unit_type_index("marine"), before, "★UNITS 被塞进新条目后 marine 的索引仍然不变★")
	_eqs(Net.unit_type_id(before), "marine", "★反索引仍指向 marine★")
	GameData.reset_to_base()
	Net._reset_type_table()
	Net.ensure_type_table()

# ---------------------------------------------------------------- 2. 包头

func _g2_header() -> void:
	print("-- 2. 包头与版本 --")
	var good := Net.packet(Net.Msg.HELLO, PackedByteArray([1, 2, 3]))
	_eqi(good.size(), 5, "包头 2 字节 + 载荷 3 字节")
	_eqi(int(good[0]), int(Net.Msg.HELLO), "类型写在首字节")
	_eqi(int(good[1]), Net.PROTOCOL_VERSION, "版本写在第二字节")

	var h := Net.check_header(good)
	_ok(bool(h["ok"]), "正常包通过校验")
	_eqi(int(h["msg"]), int(Net.Msg.HELLO), "解出类型")

	_ok(not bool(Net.check_header(PackedByteArray([1]))["ok"]), "1 字节的包被拒绝")
	_ok(not bool(Net.check_header(PackedByteArray())["ok"]), "空包被拒绝")

	var wrong := good.duplicate()
	wrong[1] = Net.PROTOCOL_VERSION + 7
	var h2 := Net.check_header(wrong)
	_ok(not bool(h2["ok"]), "★版本不一致被拒绝★")
	_ok(String(h2["reason"]).contains("版本"), "拒绝原因里说清是版本问题（「%s」）" % String(h2["reason"]))

	var huge := PackedByteArray()
	huge.resize(Net.MAX_PACKET + 1)
	_ok(not bool(Net.check_header(huge)["ok"]), "超大包被拒绝")

# ---------------------------------------------------------------- 3. 往返一致

func _g3_roundtrip() -> void:
	print("-- 3. 往返一致 --")
	var a := _make_world()
	# 造点花样：满血 / 残血 / 带盾 / 攻城模式 / 带编队 / 采集中的农民
	a.elapsed = 123.75
	a.winner = -1
	a.factions[World.PLAYER]["minerals"] = 4321
	a.factions[World.PLAYER]["gas"] = 987
	a.factions[World.ENEMY]["minerals"] = 111
	var u0: Unit = a.units[0]
	u0.hp = 33.5
	u0.facing = 1.234
	u0.carry = 8.0
	u0.harvest_state = 1
	u0.attack_move = true
	u0.in_combat = true
	u0.mode = "sieged"
	a.units[1].hp = 12.25
	a.units[1].shield = 40.0
	# 加一个带队列的建筑
	var depot := a._place_building("supply_depot", "terran", a.buildings[0].pos + Vector2(140, 0),
		World.PLAYER, true)
	depot.queue = [{"type_id": "marine", "time_left": 3.25, "total": 9.0},
		{"type_id": "marauder", "time_left": 0.5, "total": 16.0},
		# 0.29 是「截断量化」唯一会露馅的一类值：0.29 * 100 在双精度下是
		# 28.999999999999996，`int()` 截成 28 → 解回来 0.28。
		# 3.25 和 0.5 都是精确值，无论截断还是四舍五入都对 —— 只用它们
		# 做样本的话，这条断言永远抓不到 bug（阳性对照实测打不红）。
		{"type_id": "scv", "time_left": 0.29, "total": 12.0}]
	depot.has_rally = true
	depot.rally = Vector2(500.0, 620.0)
	depot.build_progress = depot.build_time      # 完工建筑：build_progress 就是 build_time
	var half := a._place_building("barracks", "terran", a.buildings[0].pos + Vector2(0, 160),
		World.PLAYER, false)
	half.complete = false
	# ⚠️ 施工中的进度是**秒**不是比例：`progress_ratio()` 才是 0..1。
	#    写 `half.build_progress = 0.42` 的话比例只有 1.4%，
	#    断言会红得莫名其妙。
	half.build_progress = half.build_time * 0.42
	half.hp = 300.0
	# 一个资源点被采掉一些
	(a.resources[0] as Dictionary)["amount"] = 777.0

	var buf := Net.Buf.new()
	var bytes := Net.encode_snapshot(a, buf, 4242)
	var b := _make_world()
	var res := Net.apply_snapshot(b, bytes)
	_ok(bool(res["ok"]), "快照应用成功（%s）" % String(res["reason"]))
	_eqi(int(res["tick"]), 4242, "tick 解出来是 4242")

	# ---- 全局 ----
	_eqf(b.elapsed, 123.75, "elapsed 往返一致")
	_eqi(b.winner, -1, "winner 往返一致（未结束）")
	_eqi(int(b.factions[World.PLAYER]["minerals"]), 4321, "玩家矿物往返一致")
	_eqi(int(b.factions[World.PLAYER]["gas"]), 987, "玩家瓦斯往返一致")
	_eqi(int(b.factions[World.ENEMY]["minerals"]), 111, "敌方矿物往返一致")

	# ---- 单位 ----
	_eqi(b.units.size(), a.units.size(), "单位数量一致")
	var by_id := {}
	for u in b.units:
		by_id[u.id] = u
	var mism: Array = []
	for ua in a.units:
		if not by_id.has(ua.id):
			mism.append("缺 %d" % ua.id)
			continue
		var ub: Unit = by_id[ua.id]
		if ub.type_id != ua.type_id:
			mism.append("id%d 类型 %s≠%s" % [ua.id, ua.type_id, ub.type_id])
		if ub.owner_id != ua.owner_id:
			mism.append("id%d 归属" % ua.id)
		if absf(ub.pos.x - ua.pos.x) > EPS or absf(ub.pos.y - ua.pos.y) > EPS:
			mism.append("id%d 位置 %s≠%s" % [ua.id, ua.pos, ub.pos])
		if absf(ub.hp - ua.hp) > EPS:
			mism.append("id%d 血量 %.3f≠%.3f" % [ua.id, ua.hp, ub.hp])
		if absf(ub.shield - ua.shield) > EPS:
			mism.append("id%d 护盾" % ua.id)
		if ub.mode != ua.mode:
			mism.append("id%d 形态 %s≠%s" % [ua.id, ua.mode, ub.mode])
		if ub.harvest_state != ua.harvest_state:
			mism.append("id%d 采集状态" % ua.id)
		if absf(ub.carry - ua.carry) > 0.2:
			mism.append("id%d 载量" % ua.id)
		if ub.attack_move != ua.attack_move or ub.in_combat != ua.in_combat:
			mism.append("id%d 标志位" % ua.id)
	_ok(mism.is_empty(), "★%d 个单位逐字段一致（差异：%s）★" % [a.units.size(), str(mism.slice(0, 4))])

	# 朝向是 1 字节，容差就是 1/256 圈
	var u0b: Unit = by_id.get(u0.id, null)
	_ok(u0b != null and absf(u0b.facing - u0.facing) <= TAU / 256.0 + 0.001,
		"朝向往返一致（1 字节量化的误差内）")

	# ---- 建筑 ----
	_eqi(b.buildings.size(), a.buildings.size(), "建筑数量一致")
	var bb := {}
	for x in b.buildings:
		bb[x.id] = x
	var bm: Array = []
	for xa in a.buildings:
		if not bb.has(xa.id):
			bmiss(bm, xa.id, "缺失")
			continue
		var xb: Building = bb[xa.id]
		if xb.type_id != xa.type_id:
			bmiss(bm, xa.id, "类型 %s≠%s" % [xa.type_id, xb.type_id])
		if xb.owner_id != xa.owner_id:
			bmiss(bm, xa.id, "归属")
		if absf(xb.pos.x - xa.pos.x) > EPS or absf(xb.pos.y - xa.pos.y) > EPS:
			bmiss(bm, xa.id, "位置")
		if absf(xb.hp - xa.hp) > EPS:
			bmiss(bm, xa.id, "血量")
		if xb.complete != xa.complete:
			bmiss(bm, xa.id, "完工标志 %s≠%s" % [xa.complete, xb.complete])
		if absf(xb.progress_ratio() - xa.progress_ratio()) > 0.01:
			bmiss(bm, xa.id, "进度比例 %.3f≠%.3f" % [xa.progress_ratio(), xb.progress_ratio()])
		if xb.queue.size() != xa.queue.size():
			bmiss(bm, xa.id, "队列长度 %d≠%d" % [xa.queue.size(), xb.queue.size()])
	_ok(bm.is_empty(), "★%d 个建筑逐字段一致（差异：%s）★" % [a.buildings.size(), str(bm.slice(0, 4))])

	var depot_b: Building = bb.get(depot.id, null)
	_ok(depot_b != null and depot_b.queue.size() == 3, "队列长度往返一致")
	if depot_b != null and depot_b.queue.size() == 3:
		_eqs(String((depot_b.queue[1] as Dictionary)["type_id"]), "marauder", "队列第 2 项的兵种一致")
		_ok(absf(float((depot_b.queue[0] as Dictionary)["time_left"]) - 3.25) <= 0.01,
			"队列剩余时间一致")
		# ★1/100 秒的量化必须四舍五入★ 截断的话 0.29 会变成 0.28
		_ok(absf(float((depot_b.queue[2] as Dictionary)["time_left"]) - 0.29) <= 0.001,
			"★剩余时间 0.29 往返后仍是 0.29（量化用 roundi 而不是截断）★")
		_ok(depot_b.has_rally, "集结点点标记一致")
		_ok(absf(depot_b.rally.x - 500.0) <= EPS, "集结点坐标一致")
	var half_b: Building = bb.get(half.id, null)
	_ok(half_b != null and not half_b.complete, "未完工建筑往返后仍未完工")
	if half_b != null:
		_ok(absf(half_b.progress_ratio() - 0.42) <= 0.01,
			"建造进度比例一致（%.3f）" % half_b.progress_ratio())
		# 秒数比对要给「1/255 比例」的量化误差留量：0.4% × build_time
		_ok(absf(half_b.build_progress - half.build_progress) <= half.build_time * 0.005,
			"建造进度秒数一致（%.3f vs %.3f）" % [half.build_progress, half_b.build_progress])

	# ---- 资源 ----
	_eqf(float((b.resources[0] as Dictionary)["amount"]), 777.0, "资源点余量往返一致")
	_eqi(b.resources.size(), a.resources.size(), "资源点数量一致")

	# ---- 二次往返：拿解码结果再编一次，字节应当完全相同 ----
	# 这是比「逐字段比对」更强的判据：它同时证明「解码结果本身是可编码的」
	# 且「没有因为解码引入新的不确定性」。
	var bytes2 := Net.encode_snapshot(b, Net.Buf.new(), 4242)
	_ok(bytes2 == bytes, "★解码结果再编码，字节与首次完全相同★（%d vs %d 字节）"
		% [bytes.size(), bytes2.size()])

func bmiss(arr: Array, id: int, why: String) -> void:
	arr.append("id%d %s" % [id, why])

# ---------------------------------------------------------------- 4. 尺寸上限

func _g4_size() -> void:
	print("-- 4. 尺寸上限 --")
	var w := _make_world()
	# 300 个单位（绕圈铺开，避免全部堆在一个点上）
	for i in range(300):
		var ang := float(i) * 0.21
		var rad := 200.0 + float(i % 40) * 26.0
		var p := Vector2(900.0 + cos(ang) * rad, 700.0 + sin(ang) * rad)
		w._spawn_unit("marine", "terran", p, World.PLAYER if i % 2 == 0 else World.ENEMY)
	# 60 个建筑
	for i in range(60):
		w._place_building("supply_depot", "terran",
			Vector2(300.0 + float(i % 12) * 70.0, 300.0 + float(i / 12) * 70.0),
			World.PLAYER, true)
	var buf := Net.Buf.new()
	var bytes := Net.encode_snapshot(w, buf, 1)
	var kb := float(bytes.size()) / 1024.0
	_ok(w.units.size() >= 300, "至少 300 个单位（实测 %d）" % w.units.size())
	_ok(w.buildings.size() >= 60, "至少 60 个建筑（实测 %d）" % w.buildings.size())
	_ok(bytes.size() < 12 * 1024,
		"★快照 < 12 KB★（实测 %d 字节 = %.2f KB，%d 单位 / %d 建筑 / %d 资源点）"
		% [bytes.size(), kb, w.units.size(), w.buildings.size(), w.resources.size()])
	# 顺手算一下带宽，方便判断要不要压缩
	print("     10 Hz 下行 ≈ %.0f KB/s" % (kb * Net.SNAPSHOT_HZ))

# ---------------------------------------------------------------- 5. 复用 buffer

func _g5_reuse() -> void:
	print("-- 5. 复用 buffer（风险 2：序列化不能每帧分配）--")
	var w := _make_world()
	var buf := Net.Buf.new()
	var first := Net.encode_snapshot(w, buf, 1)
	var n := first.size()
	var same := true
	for i in range(1000):
		var b := Net.encode_snapshot(w, buf, 1)
		if b.size() != n:
			same = false
		if i == 999 and b != first:
			same = false
	_ok(same, "★同一个 Buf 连编 1000 次，输出字节完全一致（无残留脏数据）★")

	# 复用与新建必须给出同样的结果 —— 否则「复用」就是在偷偷改语义
	var fresh := Net.encode_snapshot(w, Net.Buf.new(), 1)
	_ok(fresh == first, "复用 buffer 与新建 buffer 的结果相同")

	# clear() 之后长度归零（容量保留是引擎内部的，GDScript 观测不到 ——
	# 所以这里钉的是「复用安全」，不是「零分配」本身）
	buf.clear()
	_eqi(buf.size(), 0, "clear() 之后长度为 0")

	# 读侧同样要能复用
	var r := Net.Buf.new()
	var left_ok := true
	for i in range(100):
		r.load_bytes(first)
		if r.left() != n:
			left_ok = false
	_ok(left_ok, "读缓冲复用 100 次后可读字节数始终是 %d" % n)
	_ok(r.ok(), "读缓冲复用 100 次后状态正常")

# ---------------------------------------------------------------- 6. 字节确定性

func _g6_determinism() -> void:
	print("-- 6. 字节确定性 --")
	var a := _make_world()
	var b := _make_world()
	var x := Net.encode_snapshot(a, Net.Buf.new(), 7)
	var y := Net.encode_snapshot(b, Net.Buf.new(), 7)
	_ok(x == y, "★两个同种子世界编出的快照字节完全相同★（%d 字节）" % x.size())
	# 阳性对照：改一个字段，字节必须变
	a.units[0].hp -= 1.0
	var z := Net.encode_snapshot(a, Net.Buf.new(), 7)
	_ok(z != x, "阳性对照：改掉 1 点血之后字节不同")

# ---------------------------------------------------------------- 7. 迷雾过滤

func _g7_fog() -> void:
	print("-- 7. 迷雾过滤（★必须一开始就在，后补要重写快照格式★）--")
	var w := _make_world()
	var home: Vector2 = w.buildings[0].pos
	# 「远点」不能随便写一个坐标 —— 地图是对称的，玩家基地有可能正好在左上角，
	# 那样 `(120,120)` 反而落在自家视野里，断言就成了「期望看不见、实际看得见」。
	# 用**敌方基地**当远点：开局必然在玩家视野之外，而且和地图布局无关。
	var enemy_home := Vector2.ZERO
	var found := false
	for b in w.buildings:
		if b.owner_id == World.ENEMY:
			enemy_home = b.pos
			found = true
			break
	_ok(found, "前置条件：地图上有敌方基地（用作「视野外」的锚点）")
	# 敌方单位一个贴脸（可见）、一个在敌方基地（不可见）
	var near := w._spawn_unit("zergling", "zerg", home + Vector2(70, 0), World.ENEMY)
	var far := w._spawn_unit("zergling", "zerg", enemy_home + Vector2(60, 0), World.ENEMY)
	w.update_visibility()
	_ok(w.is_visible(near.pos), "贴脸的敌方单位在玩家视野内（前置条件）")
	_ok(not w.is_visible(far.pos), "敌方基地旁的敌方单位在玩家视野外（前置条件）")

	# ⚠️ 这里**不再手写一遍单位记录的字段布局**。
	#
	#    原来是逐字段 `r.u32r(); r.u16r(); ...` 手工跳过的。协议升到 v2
	#    （单位记录尾部加了 `energy` + 效果列表）之后，这段手写解析**没跟上**：
	#    每个单位少读 2 字节，从第二个单位起全部错位 ——
	#    「★视野内的敌方单位在快照里★」和「★玩家自己的单位一个都没被过滤掉★」
	#    一起变红，而**产品代码完全正确**。
	#
	#    修法不是「把缺的字段补上」，而是**别再抄一份布局**：直接调生产解码器
	#    `Net.apply_snapshot()` 解进一份临时世界，再读它的单位表。
	#    这样「快照里有哪些单位」就只有一个定义，协议再改也不会漏。
	var ids_of := func(viewer: int) -> Dictionary:
		var bs := Net.encode_snapshot(w, Net.Buf.new(), 1, viewer)
		var scratch := _make_world()
		var res := Net.apply_snapshot(scratch, bs)
		var out := {}
		if not bool(res.get("ok", false)):
			return out
		for su in scratch.units:
			out[su.id] = su.pos
		return out

	var seen: Dictionary = ids_of.call(World.PLAYER)
	var all: Dictionary = ids_of.call(-1)
	_ok(seen.has(near.id), "★视野内的敌方单位在快照里★")
	_ok(not seen.has(far.id), "★视野外的敌方单位不在快照里（不是发坐标再让客户端隐藏）★")
	_ok(all.has(far.id), "阳性对照：不过滤时（viewer = -1）敌方单位都在")
	_ok(all.size() > seen.size(), "过滤后条目数变少（%d < %d）" % [seen.size(), all.size()])

	# 自己的单位永远在 —— 否则玩家看不到自己的兵
	var self_ok := true
	for u in w.units:
		if u.owner_id == World.PLAYER and not seen.has(u.id):
			self_ok = false
	_ok(self_ok, "★玩家自己的单位一个都没被过滤掉★")

# ---------------------------------------------------------------- 8. 畸形包

func _g8_malformed() -> void:
	print("-- 8. 畸形包（UDP 上半包是常态）--")
	var w := _make_world()
	var good := Net.encode_snapshot(w, Net.Buf.new(), 1)
	var t := _make_world()

	_ok(not bool(Net.apply_snapshot(t, PackedByteArray())["ok"]), "空包被拒绝且不崩")
	var bad_ver := good.duplicate()
	bad_ver[1] = 99
	_ok(not bool(Net.apply_snapshot(t, bad_ver)["ok"]), "版本不符的快照被拒绝")
	_ok(String(Net.apply_snapshot(t, bad_ver)["reason"]).contains("版本"), "给出「版本不一致」的原因")

	# 截断：逐段砍，任何一段都不能崩，且返回 ok=false
	var crashed := false
	var rejected := 0
	for cut in [3, 8, 20, good.size() / 2, good.size() - 3]:
		var piece := good.slice(0, cut)
		var rr := Net.apply_snapshot(_make_world(), piece)
		if not bool(rr["ok"]):
			rejected += 1
	_eqi(rejected, 5, "★5 种截断长度全部被拒绝且没有崩★")
	_ok(not crashed, "截断包没有引发脚本错误")

	# 包类型不对
	var wrong_type := good.duplicate()
	wrong_type[0] = int(Net.Msg.CHAT)
	_ok(not bool(Net.apply_snapshot(t, wrong_type)["ok"]), "非快照包被拒绝")

# ---------------------------------------------------------------- 9. 重建不累积

## 全图阻挡格数（地形岩石 + 建筑占位）。
func _count_blocked(w: World) -> int:
	var n := 0
	for i in range(w.grid.blocks.size()):
		if w.grid.blocks[i] != 0:
			n += 1
	return n

## 找 n 个「可走且没被建筑占」的格子，用来放临时建筑。
## 从左上角扫起 —— 那里离双方基地都远，不会撞上开局建筑。
func _free_spots(w: World, n: int) -> Array:
	var out: Array = []
	var g: Grid = w.grid
	for cy in range(g.h):
		if out.size() >= n:
			break
		for cx in range(g.w):
			if out.size() >= n:
				break
			if not g.is_walkable_cell(cx, cy):
				continue
			if g.occupied[g.idx(cx, cy)] != 0:
				continue
			out.append(Vector2i(cx, cy))
	return out

func _g9_reset_dynamic() -> void:
	print("-- 9. 反复重建不累积 --")
	var a := _make_world()
	var b := _make_world()
	var bytes := Net.encode_snapshot(a, Net.Buf.new(), 1)
	for i in range(10):
		Net.apply_snapshot(b, bytes)
	_eqi(b.units.size(), a.units.size(), "连收 10 份快照后单位数仍是 %d" % a.units.size())
	_eqi(b.buildings.size(), a.buildings.size(), "连收 10 份快照后建筑数仍是 %d" % a.buildings.size())
	_eqi(b._next_id, a._next_id, "连收 10 份快照后 id 计数器没有跑飞")

	# ★幽灵墙测试★
	#
	# 「同一份快照连收 10 次」**测不出**这个问题 —— 那 10 次占的是同一批格子。
	# 真正的场景是「建筑被拆掉 / 卖掉了，但格子还锁着」：
	# 地图上留下一串走不进去、也看不见的墙。
	#
	# 所以这里要**先占、再撤**：给 d 多放 3 座建筑，把 d 的快照发给 f，
	# 再把「没有那 3 座建筑」的快照 s0 发回去 —— 那 3 格必须重新可通行。
	var e := _make_world()
	var base_blocked := _count_blocked(e)

	var d := _make_world()
	var spots := _free_spots(d, 3)
	_eqi(spots.size(), 3, "找到 3 个空闲可走格用来放临时建筑（前置条件）")
	var s0 := Net.encode_snapshot(e, Net.Buf.new(), 1)
	for s in spots:
		d._place_building("supply_depot", "terran", d.grid.cell_to_world(s), World.PLAYER, true)
	var s1 := Net.encode_snapshot(d, Net.Buf.new(), 1)

	var f := _make_world()
	_eqi(_count_blocked(f), base_blocked, "前置条件：同种子的两个世界初始阻挡格数相同")

	Net.apply_snapshot(f, s1)
	_eqi(f.buildings.size(), d.buildings.size(), "收到「多 3 座建筑」的快照后建筑数正确")
	var occupied := 0
	for s in spots:
		if not f.grid.is_walkable_cell(s.x, s.y):
			occupied += 1
	_eqi(occupied, 3, "前置条件：3 个落点都被占住了")
	_eqi(_count_blocked(f), base_blocked + 3, "阻挡格数 = 基线 + 3")

	Net.apply_snapshot(f, s0)
	_eqi(f.buildings.size(), e.buildings.size(), "收到「少 3 座建筑」的快照后建筑数回落")
	var freed := 0
	for s in spots:
		if f.grid.is_walkable_cell(s.x, s.y):
			freed += 1
	_eqi(freed, 3, "★建筑消失后那 3 格重新可通行（没有幽灵墙）★")
	_eqi(_count_blocked(f), base_blocked, "★阻挡格数回到基线（reset_dynamic 解封生效）★")

	# 阳性对照：把 reset_dynamic 里的解封那一行删掉，上面两条断言必须变红
	# （见 M3 的三次回退验证 —— 没做这一步的断言有可能是永远为真的废断言）
	b.reset_dynamic()
	_eqi(b.buildings.size(), 0, "阳性对照：reset_dynamic 之后一个建筑都没有")
	_eqi(b.units.size(), 0, "阳性对照：reset_dynamic 之后一个单位都没有")

# ---------------------------------------------------------------- 10. 本机阵营

## 局域网客户端是 ENEMY 而不是 PLAYER —— 这一组钉住「视野链不能只有 PLAYER 一个视角」。
##
## ⚠️ 第一版把 `update_visibility()` 里的判据写死成 `owner_id != PLAYER`，
##    `is_visible()` / 小地图 / 渲染又全读 `vis`。于是 1v1 局域网里
##    客户端（ENEMY）拿不到任何迷雾：整张地图要么全黑、要么全亮，
##    **而且不报错**。
func _g10_local_owner() -> void:
	print("-- 10. 本机阵营（客户端视角的迷雾）--")
	var w := _make_world()
	var own_home: Vector2 = w.buildings[0].pos
	var enemy_home := Vector2.ZERO
	var found := false
	for b in w.buildings:
		if b.owner_id == World.ENEMY:
			enemy_home = b.pos
			found = true
			break
	_ok(found, "前置条件：地图上有敌方基地")

	w.update_visibility()
	_ok(w.is_visible(own_home), "前置条件：默认视角下己方基地可见")
	_ok(not w.is_visible(enemy_home), "前置条件：默认视角下敌方基地不可见")
	var player_view: PackedByteArray = w.vis.duplicate()

	# ★切成客户端视角★
	w.local_owner = World.ENEMY
	w.update_visibility()
	_ok(w.is_visible(enemy_home), "★local_owner = ENEMY 之后敌方基地可见★")
	_ok(not w.is_visible(own_home), "★local_owner = ENEMY 之后玩家基地不可见★")
	_ok(w.vis != player_view, "★两种视角算出的位图不同（不是同一份）★")

	# fog_of 的捷径判的必须是 local_owner
	_ok(w.fog_of(World.ENEMY) == w.vis, "fog_of(local_owner) 返回 vis 本身，不是副本")
	var c := w.grid.world_to_cell(enemy_home)
	_ok((w.fog_of(World.ENEMY)[c.y * w.grid.w + c.x] & World.VIS_VISIBLE) != 0,
		"客户端自己的 fog_of(ENEMY) 能看到敌方基地")
	# 反过来：local_owner 是 ENEMY 时，fog_of(PLAYER) 走缓存分支，给出另一份
	var fp: PackedByteArray = w.fog_of(World.PLAYER)
	_ok(fp != w.vis, "local_owner 是 ENEMY 时 fog_of(PLAYER) 是另一份位图")
	_ok((fp[c.y * w.grid.w + c.x] & World.VIS_VISIBLE) == 0, "那份位图看不到敌方基地")

	# 主机侧：local_owner 仍是 PLAYER，为客户端生成快照时走 fog_of(ENEMY)
	var h := _make_world()
	h.update_visibility()
	var he: PackedByteArray = h.fog_of(World.ENEMY)
	_eqi(he.size(), h.vis.size(), "主机侧 fog_of(ENEMY) 与 vis 同样大小")
	_ok(h.fog_of(World.PLAYER) == h.vis, "主机侧 fog_of(PLAYER) 仍是 vis 本身")
	_ok(he != h.vis, "★主机侧 fog_of(ENEMY) 是另一份位图★")
	var hc := h.grid.world_to_cell(enemy_home)
	_ok((he[hc.y * h.grid.w + hc.x] & World.VIS_VISIBLE) != 0,
		"★主机为客户端算的视野里能看到客户端自己的基地★")
	_ok((h.vis[hc.y * h.grid.w + hc.x] & World.VIS_VISIBLE) == 0,
		"阳性对照：主机自己的视野里看不到敌方基地")

	# ★client_frame 只刷视野，绝不推进模拟★
	# 客户端一旦误调 step() 就会自己跑一份分叉的模拟 —— 症状是
	# 「单位越走越偏」，而且看起来像网络丢包。
	var t := _make_world()
	var before_units := t.units.size()
	var before_elapsed := t.elapsed
	var before_minerals := int(t.factions[World.PLAYER]["minerals"])
	for i in range(120):
		t.client_frame(1.0 / 60.0)
	_eqf(t.elapsed, before_elapsed, "★client_frame 不推进 elapsed（没有跑模拟）★")
	_eqi(t.units.size(), before_units, "client_frame 不产生新单位")
	_eqi(int(t.factions[World.PLAYER]["minerals"]), before_minerals, "client_frame 不推进经济")
	_ok(not t.vis.is_empty(), "client_frame 之后视野位图非空")

# ---------------------------------------------------------------- 11. 指令

## 编码 → 解码 → **在主机上真的执行**，以及★归属校验★。
##
## ⚠️ 归属校验不是「自己人无所谓」—— 局域网里也是真作弊：
##    不做的话，一个改过的客户端可以直接 `STOP(对方全部单位)`。
func _g11_cmd() -> void:
	print("-- 11. 指令编解码与应用（主机侧权限）--")
	Net._reset_type_table()
	Net.ensure_type_table()
	_eqi(Net.upgrade_ids.size(), GameData.base_ids("upgrades").size(),
		"升级索引表覆盖全部 %d 条升级" % GameData.base_ids("upgrades").size())
	_ok(Net.ability_ids.size() >= 3, "技能索引表至少 3 条（实测 %d）" % Net.ability_ids.size())
	_eqs(Net.ability_id_of(Net.ability_index("stim")), "stim", "技能索引 ↔ 反索引往返")
	_eqi(Net.ability_index("no_such_ability"), -1, "未知技能返回 -1")
	_ok(Net.upgrade_index(String(Net.upgrade_ids[0])) == 0, "升级索引表排序后第一条是 0 号")
	_eqs(Net.upgrade_id_of(Net.NO_IDX), "", "NO_IDX 反索引得到空串")

	var w := _make_world()
	# 给足资源 —— 否则「训练失败」会因为造价而不是因为逻辑
	w.factions[World.PLAYER]["minerals"] = 5000
	w.factions[World.PLAYER]["gas"] = 5000
	w.factions[World.ENEMY]["minerals"] = 5000
	w.factions[World.ENEMY]["gas"] = 5000

	var mine: Array = w.units_of(World.PLAYER)
	_ok(mine.size() >= 2, "前置条件：玩家开局至少 2 个单位（实测 %d）" % mine.size())
	var ids: Array = []
	for i in range(mini(3, mine.size())):
		ids.append(mine[i].id)

	var buf := Net.Buf.new()
	var target := Vector2(520.0, 640.0)

	# ---- MOVE 往返 ----
	var bytes := Net.packet_cmd(buf, 7, Net.Cmd.MOVE, ids,
		{"x": target.x, "y": target.y, "flags": 1})
	var c := Net.decode_cmd(bytes)
	_ok(bool(c["ok"]), "MOVE 指令解码成功（%s）" % String(c["reason"]))
	_eqi(int(c["seq"]), 7, "序号往返一致")
	_eqi(int(c["kind"]), Net.Cmd.MOVE, "指令种类往返一致")
	_eqi(int(c["flags"]), 1, "标志位往返一致（攻击移动）")
	_eqi(int(c["n_units"]), ids.size(), "参战单位数往返一致")
	_eqf(float(c["x"]), target.x, "目标点 x 往返一致")
	_eqf(float(c["y"]), target.y, "目标点 y 往返一致")
	_eqi(int(c["node_idx"]), Net.NO_IDX, "未指定的资源点折成 NO_IDX")
	_eqi(int(c["building_id"]), 0, "未指定的建筑 id 是 0")
	var ids_ok := true
	for i in range(ids.size()):
		if int(c["ids"][i]) != int(ids[i]):
			ids_ok = false
	_ok(ids_ok, "单位 id 列表往返一致")

	# ★解码结果再编码，字节完全相同★
	var re := Net.packet_cmd(buf, int(c["seq"]), int(c["kind"]), c["ids"],
		{"x": c["x"], "y": c["y"], "flags": c["flags"]})
	_ok(re == bytes, "★指令解码结果再编码，字节完全相同★（%d vs %d）"
		% [bytes.size(), re.size()])

	# ---- 主机应用 ----
	var u: Unit = mine[0]
	u.stop()
	var res := Net.apply_cmd(w, c, World.PLAYER)
	_ok(bool(res["ok"]), "★主机应用 MOVE 成功（%s）★" % String(res["reason"]))
	_ok(u.has_move_order, "★单位真的收到了移动命令★")
	_ok(u.final_target.distance_to(target) <= 90.0,
		"目标点落在编队散开范围内（偏差 %.1f px）" % u.final_target.distance_to(target))

	# ---- ★归属校验：不能指挥对方的单位★ ----
	var stop_cmd := Net.decode_cmd(Net.packet_cmd(buf, 8, Net.Cmd.STOP, ids))
	var r_foe := Net.apply_cmd(w, stop_cmd, World.ENEMY)
	_ok(not bool(r_foe["ok"]), "★敌方指挥我的单位被拒绝（%s）★" % String(r_foe["reason"]))

	# 混编（一半自己的、一半敌方的）→ 只执行自己的那半，整体仍然成功
	var enemy_units: Array = w.units_of(World.ENEMY)
	if not enemy_units.is_empty():
		var mixed: Array = [mine[0].id, enemy_units[0].id]
		var mc := Net.decode_cmd(Net.packet_cmd(buf, 9, Net.Cmd.STOP, mixed))
		_ok(bool(Net.apply_cmd(w, mc, World.PLAYER)["ok"]),
			"混编指令仍然执行（敌方那几个被丢掉）")
		# 全部都是别人的 → 拒绝
		var only_foe: Array = [enemy_units[0].id]
		var oc := Net.decode_cmd(Net.packet_cmd(buf, 10, Net.Cmd.STOP, only_foe))
		_ok(not bool(Net.apply_cmd(w, oc, World.PLAYER)["ok"]),
			"★一个自己人都没有时拒绝★")

	# ---- ★归属校验：不能指挥对方的建筑★ ----
	var my_b: Building = w.buildings_of(World.PLAYER)[0]
	var foe_b: Building = null
	for b in w.buildings:
		if b.owner_id == World.ENEMY:
			foe_b = b
			break
	_ok(foe_b != null, "前置条件：敌方有建筑")
	if foe_b != null:
		# ⚠️ 断言必须**挑一个「没有归属校验就一定会成功」的场景**，
		#    否则它会因为别的原因失败，从而永远为真。
		#    第一版用敌方**已完工**的建筑测取消 —— 而 `cancel_build` 对完工建筑
		#    本来就返回 false，于是撤掉归属校验后断言照样通过（阳性对照实测）。
		#    这里改成「未完工的敌方建筑」：没有校验的话它真的会被拆掉。
		var foe_race := String(w.factions[World.ENEMY]["race"])
		var lab_type := ""
		var lab_uid := ""
		for uid in Net.upgrade_ids:
			var up := GameData.get_upgrade(String(uid))
			if String(up.get("faction", "")) == foe_race and String(up.get("requires", "")) != "":
				lab_type = String(up["requires"])
				lab_uid = String(uid)
				break
		_ok(lab_type != "" and lab_uid != "",
			"前置条件：找到敌方种族的 (研究建筑 %s, 升级 %s) 组合" % [lab_type, lab_uid])

		var foe_half := w._place_building(lab_type, foe_race,
			foe_b.pos + Vector2(0, 200), World.ENEMY, false)
		var cb := Net.decode_cmd(Net.packet_cmd(buf, 11, Net.Cmd.CANCEL_BUILD, [],
			{"building_id": foe_half.id}))
		var r_cb := Net.apply_cmd(w, cb, World.PLAYER)
		_ok(not bool(r_cb["ok"]), "★不能取消对方的建筑（%s）★" % String(r_cb["reason"]))
		_ok(not foe_half.dead, "★对方的建筑还在（没被拆掉、没被退款）★")

		var foe_lab := w._place_building(lab_type, foe_race,
			foe_b.pos + Vector2(0, 280), World.ENEMY, true)
		var rb := Net.decode_cmd(Net.packet_cmd(buf, 12, Net.Cmd.RESEARCH, [],
			{"building_id": foe_lab.id, "upgrade_id": lab_uid}))
		_ok(not bool(Net.apply_cmd(w, rb, World.PLAYER)["ok"]),
			"★不能在对方的建筑里研究★")
		_eqi(foe_lab.queue.size(), 0, "★对方的建筑队列里没有多出东西★")
		_eqi(w.upgrade_level(World.ENEMY, lab_uid), 0, "★对方阵营的升级等级没变★")

	# ---- 自己的建筑：集结点 ----
	var rc := Net.decode_cmd(Net.packet_cmd(buf, 13, Net.Cmd.RALLY, [],
		{"building_id": my_b.id, "x": 300.0, "y": 300.0}))
	_ok(bool(Net.apply_cmd(w, rc, World.PLAYER)["ok"]), "自己的建筑可以设集结点")
	_ok(my_b.has_rally, "★集结点真的设上了★")
	_eqf(my_b.rally.x, 300.0, "集结点坐标正确")

	# ---- 地图外的坐标被拒绝 ----
	var off := Net.decode_cmd(Net.packet_cmd(buf, 14, Net.Cmd.MOVE, ids, {"x": -50.0, "y": 10.0}))
	_ok(not bool(Net.apply_cmd(w, off, World.PLAYER)["ok"]), "地图外的目标点被拒绝")

	# ---- ★未知类型不能被当成 0 号★ ----
	# `u16(-1)` 会被 clampi 夹成 0，而 0 是合法索引 ——
	# 症状是「未知兵种被当成某个真实兵种造出来」。
	#
	# 用 `Buf` 按字段读，不数字节下标 —— 数下标的话改一次布局就得重算，
	# 而且第一版就数错了（把 kind/flags 当成了 str_idx）。
	var ub := Net.decode_cmd(Net.packet_cmd(buf, 15, Net.Cmd.BUILD, ids,
		{"type_id": "no_such_building", "x": 300.0, "y": 300.0}))
	_eqs(String(ub["type_id"]), "", "★未知建筑类型解出来是空串（不是 0 号那个真实建筑）★")
	var probe := Net.Buf.new()
	probe.load_bytes(Net.packet_cmd(buf, 15, Net.Cmd.BUILD, ids, {"type_id": "no_such_building"}))
	probe.u8r()
	probe.u8r()
	probe.u32r()
	probe.u8r()
	probe.u8r()
	_eqi(probe.u16r(), Net.NO_IDX, "★未知建筑类型写进包里是 NO_IDX（65535），不是 0★")
	_ok(not bool(Net.apply_cmd(w, ub, World.PLAYER)["ok"]),
		"★未知建筑类型被拒绝（%s）★" % String(Net.apply_cmd(w, ub, World.PLAYER)["reason"]))

	# ---- TRAIN：真的进队列 ----
	var trainer: Building = null
	for b in w.buildings_of(World.PLAYER):
		if not b.trains().is_empty():
			trainer = b
			break
	_ok(trainer != null, "前置条件：玩家有一座能训练的建筑")
	if trainer != null:
		var utid := String(trainer.trains()[0])
		var tc := Net.decode_cmd(Net.packet_cmd(buf, 16, Net.Cmd.TRAIN, [],
			{"building_id": trainer.id, "type_id": utid}))
		_eqs(String(tc["type_id"]), utid, "训练指令的兵种往返一致")
		var tr := Net.apply_cmd(w, tc, World.PLAYER)
		_ok(bool(tr["ok"]), "训练指令执行成功（%s）" % String(tr["reason"]))
		_eqi(trainer.queue.size(), 1, "★队列里真的多了一项★")
		var tc2 := Net.decode_cmd(Net.packet_cmd(buf, 17, Net.Cmd.TRAIN, [],
			{"building_id": trainer.id, "type_id": utid}))
		_ok(not bool(Net.apply_cmd(w, tc2, World.ENEMY)["ok"]),
			"★敌方不能指挥我的建筑训练★")

	# ---- ABILITY：只对能用它的单位生效 ----
	# ⚠️ 兴奋剂**要先研究 `stim_pack`**（`can_use_ability` 里有一道
	#    `has_ability_unlock` 闸门）。不先解锁的话这一组会红在
	#    「选中的单位都不能使用该技能」—— 看起来像指令编解码有 bug，
	#    其实是前置条件没摆。
	var mar: Unit = w._spawn_unit("marine", "terran", mine[0].pos + Vector2(40, 0), World.PLAYER)
	(w.factions[World.PLAYER]["upgrades"] as Dictionary)["stim_pack"] = 1
	var ac := Net.decode_cmd(Net.packet_cmd(buf, 18, Net.Cmd.ABILITY, [mar.id],
		{"ability_id": "stim"}))
	_eqs(String(ac["ability_id"]), "stim", "技能 id 往返一致")
	var ar := Net.apply_cmd(w, ac, World.PLAYER)
	_ok(bool(ar["ok"]), "★陆战队员能用兴奋剂（%s）★" % String(ar["reason"]))
	_ok(mar.has_buff("stim"), "★兴奋剂真的生效了★")
	# 医疗兵不能用兴奋剂 —— 混编时不该整条失败，但只有一个医疗兵时应当拒绝
	var med: Unit = w._spawn_unit("medic", "terran", mine[0].pos + Vector2(80, 0), World.PLAYER)
	var ac2 := Net.decode_cmd(Net.packet_cmd(buf, 19, Net.Cmd.ABILITY, [med.id],
		{"ability_id": "stim"}))
	var ar2 := Net.apply_cmd(w, ac2, World.PLAYER)
	_ok(not bool(ar2["ok"]), "★不能使用该技能的单位被拒绝（%s）★" % String(ar2["reason"]))

	# ---- 畸形指令包 ----
	_ok(not bool(Net.decode_cmd(bytes.slice(0, 20))["ok"]), "截断的指令包被拒绝")
	_ok(not bool(Net.decode_cmd(PackedByteArray())["ok"]), "空包被拒绝")
	_ok(not bool(Net.decode_cmd(Net.packet(Net.Msg.HELLO))["ok"]), "非指令包被拒绝")
	var bad_ver := bytes.duplicate()
	bad_ver[1] = 99
	_ok(not bool(Net.decode_cmd(bad_ver)["ok"]), "版本不符的指令包被拒绝")

	# ---- 对局结束后不再接受指令 ----
	var w2 := _make_world()
	var c2 := Net.decode_cmd(Net.packet_cmd(buf, 20, Net.Cmd.STOP, [w2.units_of(World.PLAYER)[0].id]))
	w2.game_ended = true
	_ok(not bool(Net.apply_cmd(w2, c2, World.PLAYER)["ok"]), "对局已结束时拒绝指令")

# ---------------------------------------------------------------- 12. 握手

func _g12_handshake() -> void:
	print("-- 12. 握手（HELLO / WELCOME / REJECT）--")
	Net._reset_type_table()
	var fp := Net.table_fingerprint()
	_ok(fp > 0, "基础表指纹非零（%d）" % fp)
	_eqi(Net.table_fingerprint(), fp, "同一份基础表两次算出的指纹相同")

	var buf := Net.Buf.new()
	var hello := Net.packet_hello(buf, "小明")
	var h := Net.decode_hello(hello)
	_ok(bool(h["ok"]), "HELLO 往返成功（%s）" % String(h["reason"]))
	_eqs(String(h["name"]), "小明", "玩家名往返一致（含中文）")
	_eqi(int(h["fingerprint"]), fp, "指纹往返一致")
	_ok(not bool(Net.decode_hello(PackedByteArray())["ok"]), "空 HELLO 被拒绝")
	_ok(not bool(Net.decode_hello(hello.slice(0, 4))["ok"]), "截断的 HELLO 被拒绝")
	_ok(not bool(Net.decode_hello(Net.packet(Net.Msg.CHAT))["ok"]), "非握手包被拒绝")

	# ★指纹不符必须被拒绝★ 否则症状是「打了几分钟之后发现兵种全乱」
	var altered := hello.duplicate()
	altered[2] = (altered[2] + 1) & 0xFF
	var h2 := Net.decode_hello(altered)
	_ok(not bool(h2["ok"]), "★指纹不符的 HELLO 被拒绝★")
	_ok(String(h2["reason"]).contains("不一致"), "拒绝原因说清是版本 / 模组不一致")

	# WELCOME
	var wel := Net.packet_welcome(buf, World.ENEMY, 123456, 64, 40, "river",
		"terran", "zerg", "hard", "主机")
	var wc := Net.decode_welcome(wel)
	_ok(bool(wc["ok"]), "WELCOME 往返成功（%s）" % String(wc["reason"]))
	_eqi(int(wc["owner"]), World.ENEMY, "分配的阵营往返一致")
	_eqi(int(wc["seed"]), 123456, "★随机种子往返一致（两端才能生成同一张图）★")
	_eqi(int(wc["map_w"]), 64, "地图宽往返一致")
	_eqi(int(wc["map_h"]), 40, "地图高往返一致")
	_eqs(String(wc["map_preset"]), "river", "地图预设往返一致")
	_eqs(String(wc["race_p"]), "terran", "玩家种族往返一致")
	_eqs(String(wc["race_e"]), "zerg", "敌方种族往返一致")
	_eqs(String(wc["difficulty"]), "hard", "难度往返一致")
	_eqs(String(wc["host_name"]), "主机", "主机名往返一致")

	# 非法内容必须被拒 —— 客户端会拿这些字段直接建世界
	var bad_owner := Net.packet_welcome(buf, 7, 1, 64, 40, "open", "terran", "zerg", "easy")
	_ok(not bool(Net.decode_welcome(bad_owner)["ok"]), "★非法阵营号被拒绝★")
	var bad_size := Net.packet_welcome(buf, World.ENEMY, 1, 0, 40, "open", "terran", "zerg", "easy")
	_ok(not bool(Net.decode_welcome(bad_size)["ok"]), "★地图尺寸为 0 被拒绝★")
	var huge := Net.packet_welcome(buf, World.ENEMY, 1, 9999, 40, "open", "terran", "zerg", "easy")
	_ok(not bool(Net.decode_welcome(huge)["ok"]), "★地图尺寸大得离谱被拒绝（不让客户端分配巨型数组）★")
	var no_race := Net.packet_welcome(buf, World.ENEMY, 1, 64, 40, "open", "", "zerg", "easy")
	_ok(not bool(Net.decode_welcome(no_race)["ok"]), "种族为空被拒绝")

	# REJECT
	var rej := Net.packet_reject(buf, 42, "离矿点太近")
	var rj := Net.decode_reject(rej)
	_ok(bool(rj["ok"]), "REJECT 往返成功")
	_eqi(int(rj["seq"]), 42, "被拒的指令序号往返一致")
	_eqs(String(rj["reason"]), "离矿点太近", "拒绝原因往返一致（要能直接显示给玩家）")
	_ok(not bool(Net.decode_reject(Net.packet(Net.Msg.CHAT))["ok"]), "非拒绝包被拒")
