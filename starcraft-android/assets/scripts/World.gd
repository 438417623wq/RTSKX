extends RefCounted
class_name World

## 世界：地图、阵营、单位/建筑容器、资源点、投射物、命令接口、AI。
## 只做逻辑与状态，不做渲染。渲染由 Main.gd 读取本对象的状态绘制。

signal event_alert(pos: Vector2, text: String, color: Color)
signal game_over(winner: int)
## 音效事件。逻辑层只报告「发生了什么、在哪里发生」——
## 播不播、播多响、要不要限流，全部由 Main 决定（和 event_alert 一个套路）。
## 这样逻辑层不需要知道 AudioStreamPlayer 的存在，测试里也不会被音频干扰。
signal event_sfx(kind: String, pos: Vector2)

const PLAYER := 0
const ENEMY := 1

var grid: Grid
var map_w := 0
var map_h := 0
var world_size := Vector2.ZERO

# 阵营状态
var factions := {}                 # owner_id -> {minerals, gas, supply_used, supply_cap, color, race, name}
var player_race := "terran"
var enemy_race := "zerg"

# 实体
var units: Array = []              # Array[Unit]
var buildings: Array = []          # Array[Building]
var resources: Array = []          # [{pos, amount, max, kind, cell}]
var projectiles: Array = []        # [{pos, target, dmg, dtype, speed, faction, kind, life}]
var effects: Array = []            # 爆炸/命中特效

var _next_id := 1
var elapsed := 0.0
var difficulty := "normal"

## 地图预设。三张，都是**对称**的 —— 非对称地图在 1v1 里等于开局定胜负。
##   "open"    开阔平原：没有高地，岩石稀疏。适合大兵团正面推进。
##   "plateau" 双坡道高地：两块对角高地，各自两条坡道。攻防转换最丰富（默认）。
##   "river"   中间河道：一条竖贯地图的深渊，只留三座桥。咽喉要地争夺。
var map_preset := "plateau"

# 选择
var selection: Array = []          # 选中的单位
var selected_building = null

# 输入意图（由 UI 写入）
var _pending_build: String = ""
var _pending_train := {}

# AI 状态
var ai := {}
var game_ended := false
var winner := -1

## 要不要跑 AI。
##
## ★**局域网必须关掉。**★ AI 指挥的是 `ENEMY` 那一方 ——
## 单机时 ENEMY 就是电脑，没问题；但局域网 1v1 里 `ENEMY` 是**客户端本人**，
## 于是 AI 会和客户端抢指挥权：客户端点「移动」，AI 下一秒把它派去进攻。
## 症状是「我的兵不听使唤、自己乱跑」，而且**主机与客户端都看不出是谁干的**。
##
## 关掉之后 `ENEMY` 完全由客户端的 `CMD` 包驱动。
var ai_enabled := true

# 空间哈希（加速范围内查询）
const HASH_CELL := 96.0
var _hash := {}

# ---- 战争迷雾 ----
# 每个格子一个字节：bit0 = 已探索过（永久保留），bit1 = 当前可见
const VIS_EXPLORED := 1
const VIS_VISIBLE := 2
const VIS_INTERVAL := 0.15         # 视野重算间隔（秒）
const BUILDING_SIGHT := 220.0      # 建筑的默认视野半径
const GAS_SNAP := 26.0             # 气矿建筑的吸附半径
## 神族水晶塔的能量场半径。神族建筑（主基地除外）必须建在能量场内——
## 这是神族最标志性的机制，也是「先立塔再铺建筑」这个运营节奏的来源。
const POWER_RADIUS := 210.0
## 开局赠送的基础军事建筑数量。
## 神族单位造价是其他族的两倍（狂热者 100 矿 / 2 人口），只给一座传送门的话
## 开局产能直接落后一半——实测神族 AI 会全程卡在一座传送门上被磨死。
const START_MIL_COUNT := {"terran": 1, "zerg": 1, "protoss": 2}
## 低地打高地的固定打空概率（星际 1 就是 30%，这里取同一个值）。
##
## ⚠️ 这是一条**只对地面对地面**生效的规则：飞行单位无视高低差。
##    星际 1 里空军不吃地形惩罚 —— 飞机从崖底往上打崖顶的坦克，
##    和打平地一样准；反过来崖顶的防空打崖底的飞机也不会 miss。
##    这条闸门写在 _is_uphill() 里，两边一起管。
const UPHILL_MISS := 0.30
## 菌毯半径。虫族建筑（除虫巢）必须建在菌毯上 —— 这是虫族最标志性的机制，
## 和神族的水晶塔能量场（POWER_RADIUS）是一对镜像：
## 神族是「先立塔再铺建筑」，虫族是「先有巢再往外长」。
##
## ⚠️ 虫巢半径别压到 AI 的建造搜索半径（60~140，兜底到 183）以下 ——
##    那样 AI 的撒点会大面积落空，只能靠已有建筑自己产生的菌毯兜底。
##    （实测把它压到 80 时 AI 仍然建得出来，因为孵化池自己也是菌毯源，
##     但那是靠兜底在撑，一点余量都没有了。）给到 200 是为了留足余量。
const CREEP_RADIUS := 110.0
const CREEP_RADIUS_HIVE := 200.0
## 菌毯加速的刷新间隔（秒）。没必要每帧算 —— 单位跑出一格菌毯再掉速，
## 玩家根本感觉不到 0.25 秒的延迟，但每帧遍历全部单位是实打实的开销。
const CREEP_REFRESH := 0.25
## AI 驻防时搜索高地的半径。
##
## ⚠️ 必须覆盖「基地 → 最近高地」的实际距离。地图生成器把平台放在
##    30% / 70% 位置，实测最近的一块距基地约 230px（平台有 11x9 格宽，
##    是它的**边角**离基地最近，不是中心 —— 按中心估会高估到 380px）。
##    给到 520 是留余量：半径给小了的话 `_ai_hold_high_ground()` 会永远拿到 INF，
##    AI 从不驻防高地，而且**不会有任何报错**（症状只是「AI 好像不会用高地」，
##    你无法从日志里看出它压根没找过）。
##    tests/Terrain.gd 第三组有一条断言专门钉住这件事。
const AI_HOLD_RADIUS := 520.0
var vis := PackedByteArray()
var _vis_timer := 0.0

## 本机是哪一个阵营。单机时永远是 `PLAYER`；局域网客户端会是 `ENEMY`。
##
## ⚠️ **没有这个字段的话，「视野 / 迷雾」这条链只有 `PLAYER` 一个视角。**
##    `update_visibility()` 里原本写死 `owner_id != PLAYER → continue`，
##    `is_visible()` / 小地图 / 渲染又全读 `vis` ——
##    1v1 局域网里主机是 PLAYER、客户端是 ENEMY，
##    于是**客户端整张地图要么全黑、要么全亮，而且不报错**。
##
## ⚠️ 客户端必须在 `World.new()` **之后**把它设成自己的 owner，
##    再调一次 `update_visibility()` —— 构造时它还是默认值。
## 地图生成用的种子。
##
## ⚠️ **以前它是硬编码在 `_generate_map()` 里的一个常量**，于是
##    「换个种子」完全不影响地形 —— 每一局都是同一张图。
##    这在单机时代只是「地图有点单调」，到了联机就是**真问题**：
##    `WELCOME` 里下发的种子变成了装饰品，而「客户端用同一种子重建地图」
##    这条链路**无法被证伪**（少了种子照样对得上，因为地图本来就只有一张）。
##
## 现在它由构造参数决定。传 0 时退化成原来的常量 ——
## 保证所有老调用方（单机、各测试）生成的仍是**逐格相同**的那张图。
const LEGACY_MAP_SEED := 20260920
var map_seed := LEGACY_MAP_SEED

var local_owner := PLAYER

## 按 owner 缓存的视野位图（局域网主机为每个客户端各维护一份）。
## 玩家那一份不走这里 —— 直接用 `vis`。见 `fog_of()`。
var _fog := {}
## 上一轮铺过的格子下标。重铺时**只清这些**，而不是把整个 creep 数组刷一遍 ——
## 地图 64x40 有 2560 格，菌毯永远只覆盖其中一小片，全清是纯浪费。
var _creep_cells: PackedInt32Array = PackedInt32Array()
var _creep_timer := 0.0

func _init(w_cells: int, h_cells: int, p_race: String, e_race: String, p_difficulty: String,
		p_map: String = "plateau", p_seed: int = 0) -> void:
	map_w = w_cells
	map_h = h_cells
	world_size = Vector2(map_w * Grid.CELL, map_h * Grid.CELL)
	player_race = p_race
	enemy_race = e_race
	difficulty = p_difficulty
	map_preset = p_map
	# 0 = 「用老的那张固定图」。显式传值才会生成不同的地形。
	map_seed = p_seed if p_seed != 0 else LEGACY_MAP_SEED
	grid = Grid.new(map_w, map_h)
	_generate_map()
	_init_factions()
	_spawn_starting_forces()
	_init_ai()
	_init_visibility()
	update_visibility()
	# 菌毯与地形标记必须**在开局就铺一遍**，不能等第一次 step()。
	# ⚠️ 踩过：重铺原本只在 step() 里定期做，于是「刚 new 出来的 World」
	#    grid.creep 全是 0 —— 虫族建筑一律被「必须建在菌毯上」拒掉，
	#    而 hive 是豁免项、照建不误，所以症状看起来只是「虫族 AI 变笨了」。
	#    tests/Economy.gd 的 zerg 分支就是这么红起来的。
	_rebuild_creep()
	_refresh_terrain_flags()

# ================================================================ 战争迷雾
func _init_visibility() -> void:
	vis.resize(grid.w * grid.h)
	vis.fill(0)

## 重算可见区域。只处理**本机阵营**（`local_owner`）。
##
## 局域网客户端（`local_owner == ENEMY`）也走这里 —— 它的单位来自快照，
## 所以算出来的就是「客户端自己能看到的范围」。
## 主机为客户端生成快照时走 `fog_of(client_owner)`，两者是同一套规则。
func update_visibility() -> void:
	# 清掉「当前可见」位，保留「已探索」位
	for i in range(vis.size()):
		vis[i] = vis[i] & VIS_EXPLORED
	for u in units:
		if u.dead or u.owner_id != local_owner:
			continue
		_mark_visible_into(vis, u.pos, u.sight())
	for b in buildings:
		if b.dead or b.owner_id != local_owner:
			continue
		var s: float = float(b.data.get("sight", BUILDING_SIGHT))
		# 未完工的建筑视野小一些
		if not b.complete:
			s *= 0.6
		_mark_visible_into(vis, b.pos, s)

## 客户端每帧调它：**只推进与渲染有关的定期刷新，不推进模拟**。
##
## 模拟由主机跑，客户端只负责把收到的快照画出来。所以客户端
## **不能调 `step()`**（那会自己跑一份分叉的模拟），但迷雾还是要重算 ——
## 否则单位走出去之后视野不跟着动。
##
## 单位 / 建筑 / 菌毯 / 地形标记在 `apply_snapshot()` 收尾时已经刷过一遍了，
## 这里再按固定间隔补刷一次，是因为**快照之间单位是在移动的** ——
## 只在快照到达时刷的话，「走上高地」要等到下一份快照才生效，
## 表现成「客户端站在高地上却打不到低地」「虫族在菌毯上没加速」。
func client_frame(delta: float) -> void:
	_vis_timer -= delta
	if _vis_timer <= 0.0:
		_vis_timer = VIS_INTERVAL
		update_visibility()
		refresh_derived()

## 重算「由地形 / 建筑派生出来的东西」：菌毯 + 每个单位的高低地与菌毯标记。
##
## 主机在 `step()` 里定期做这两件事；**客户端不跑 `step()`，必须自己调** ——
## 少了它，客户端的 `grid.creep` 会永远停在「刚建世界那一刻」，
## 单位也永远没有 `on_high_ground` / `creep_boost` 标记，而**全程不报错**。
##
## 幂等，可以放心重复调。
func refresh_derived() -> void:
	_rebuild_creep()
	_refresh_terrain_flags()

## 某个 owner 的可见性位图。**局域网主机要为每个客户端各维护一份** ——
## 直接广播「完整世界状态」的话，客户端只要解包就能看到全图，**等于内置作弊**。
##
## ⚠️ 这条必须**从一开始就在**：后补的话整个快照格式都要重写
##    （「哪些字段该被过滤」决定了编码布局）。
##
## 玩家那一份直接复用 `vis`（`update_visibility()` 已经在维护），不重复算。
## 其余 owner 按 `VIS_INTERVAL` 节流缓存 —— 每次重算是
## `O(单位数 × 视野格数)`，不能每帧每端各来一遍。
##
## ⚠️ 捷径判的是 **`local_owner`** 而不是写死 `PLAYER`：
##    主机为客户端 A 生成快照时 `fog_of(ENEMY)` 走缓存分支，
##    客户端自己调 `fog_of(ENEMY)` 则直接拿到 `vis`。同一份语义。
func fog_of(owner: int, force: bool = false) -> PackedByteArray:
	if owner == local_owner:
		return vis
	var e: Dictionary = _fog.get(owner, {})
	if not force and not e.is_empty() and elapsed - float(e["at"]) < VIS_INTERVAL:
		return e["buf"]
	var arr := PackedByteArray()
	arr.resize(grid.w * grid.h)
	arr.fill(0)
	# 保留「已探索」位 —— 快照只过滤「当前可见」，
	# 否则客户端的小地图会在敌人离开视野的瞬间整片变黑。
	var old: PackedByteArray = e.get("buf", PackedByteArray())
	if old.size() == arr.size():
		for i in range(arr.size()):
			arr[i] = old[i] & VIS_EXPLORED
	for u in units:
		if u.dead or u.owner_id != owner:
			continue
		_mark_visible_into(arr, u.pos, u.sight())
	for b in buildings:
		if b.dead or b.owner_id != owner:
			continue
		var s: float = float(b.data.get("sight", BUILDING_SIGHT))
		if not b.complete:
			s *= 0.6
		_mark_visible_into(arr, b.pos, s)
	_fog[owner] = {"buf": arr, "at": elapsed}
	return arr

func _mark_visible(world_pos: Vector2, radius: float) -> void:
	_mark_visible_into(vis, world_pos, radius)

## 往**指定**位图里标记可见。抽出来是为了 `fog_of()` 能复用同一套规则 ——
## 两份实现的话，「低地看不到高地」这类规则迟早只改一处。
func _mark_visible_into(arr: PackedByteArray, world_pos: Vector2, radius: float) -> void:
	var c := grid.world_to_cell(world_pos)
	var viewer_elev := grid.elev_at_cell(c.x, c.y)
	var rc := int(ceil(radius / Grid.CELL))
	var r2 := radius * radius
	for dy in range(-rc, rc + 1):
		var cy := c.y + dy
		if cy < 0 or cy >= grid.h:
			continue
		for dx in range(-rc, rc + 1):
			var cx := c.x + dx
			if cx < 0 or cx >= grid.w:
				continue
			var d2 := float(dx * dx + dy * dy) * Grid.CELL * Grid.CELL
			if d2 > r2:
				continue
			# 低地看不到高地 —— 站在崖底的单位望不见崖顶。
			# 反过来高地看低地一览无余，于是高地成了「单向透明」的观察点。
			# 这是星际 1 里高低差最实际的一条作用：
			# 崖顶架一排坦克，崖底的人连它长什么样都看不见。
			if grid.elev_at_cell(cx, cy) > viewer_elev:
				continue
			var i := cy * grid.w + cx
			arr[i] = arr[i] | VIS_VISIBLE | VIS_EXPLORED

## 清掉一切动态内容（单位 / 建筑 / 弹药 / 特效），**保留地形与资源节点**。
##
## 局域网客户端每收到一份快照就重建一遍 —— 地形由同一个地图种子生成，
## 本来就在，不需要传输。
##
## ⚠️ 建筑占的格子必须**解封**，否则连收 10 份快照之后
##    地图上会留下一串永远走不进去的「幽灵墙」，而且不报错。
func reset_dynamic() -> void:
	for b in buildings:
		grid.mark_area(b.cell_pos, b.cells_w, b.cells_h, false)
	units.clear()
	buildings.clear()
	projectiles.clear()
	effects.clear()
	selection.clear()
	selected_building = null
	_rebuild_hash()

func is_visible(world_pos: Vector2) -> bool:
	var c := grid.world_to_cell(world_pos)
	if c.x < 0 or c.y < 0 or c.x >= grid.w or c.y >= grid.h:
		return false
	return (vis[c.y * grid.w + c.x] & VIS_VISIBLE) != 0

func is_explored(world_pos: Vector2) -> bool:
	var c := grid.world_to_cell(world_pos)
	if c.x < 0 or c.y < 0 or c.x >= grid.w or c.y >= grid.h:
		return false
	return (vis[c.y * grid.w + c.x] & VIS_EXPLORED) != 0

## 本机当前能看到哪些敌方单位（用于渲染和「能不能选中」判定）
##
## ⚠️ 判据是 **`local_owner`** 而不是写死 `PLAYER` ——
##    局域网客户端是 `ENEMY`，写死的话它会把**自己的部队**当成敌方，
##    症状是「客户端框选不到自己的兵、小地图上自己的兵显示成红点」。
func visible_enemies() -> Array:
	var out := []
	for u in units:
		if u.dead or u.owner_id == local_owner:
			continue
		if is_visible(u.pos):
			out.append(u)
	return out

## 探索进度（0~1），用于结算界面展示
func explored_ratio() -> float:
	if vis.is_empty():
		return 0.0
	var n := 0
	for i in range(vis.size()):
		if (vis[i] & VIS_EXPLORED) != 0:
			n += 1
	return float(n) / float(vis.size())

# ---------------------------------------------------------------- 初始化
func _init_factions() -> void:
	factions[PLAYER] = _make_faction(player_race, PLAYER)
	factions[ENEMY] = _make_faction(enemy_race, ENEMY)
	factions[PLAYER]["minerals"] = 240
	factions[ENEMY]["minerals"] = 240 * GameData.DIFFICULTY[difficulty]["ai_eco"]

func _make_faction(race: String, owner: int) -> Dictionary:
	var fd: Dictionary = GameData.FACTIONS[race]
	return {
		"race": race,
		"name": "你" if owner == PLAYER else "敌方 AI",
		"color": fd["color"],
		"color_dim": fd["color_dim"],
		"accent": fd["accent"],
		"minerals": 0.0,
		"gas": 0.0,
		"supply_used": 0,
		"supply_cap": 10,
		"harvested": 0.0,
		# 已完成的科技升级：{升级id: 等级}。**阵营级**，全族共享。
		# 存在阵营上而不是单位上，是 SC1 的做法：升完立刻作用于所有现有和未来的单位，
		# 不需要在单位创建时同步，也不需要遍历全军队刷新。
		"upgrades": {},
	}

# ================================================================ 科技升级

func upgrade_level(owner: int, uid: String) -> int:
	return int((factions.get(owner, {}).get("upgrades", {}) as Dictionary).get(uid, 0))

## 该阵营是否已解锁某个技能（对应的 unlock 型升级是否已完成）
func has_ability_unlock(owner: int, ability_id: String) -> bool:
	var ab := GameData.get_ability(ability_id)
	var need := String(ab.get("unlock", ""))
	if need == "":
		return true
	return upgrade_level(owner, need) > 0

## 升级的下一级造价 / 耗时。已满级返回空字典。
func next_upgrade_cost(owner: int, uid: String) -> Dictionary:
	var up := GameData.get_upgrade(uid)
	if up.is_empty():
		return {}
	var lv := upgrade_level(owner, uid)
	var levels: Array = up.get("levels", [])
	if lv >= levels.size():
		return {}
	return levels[lv]

## 能否研究。要求：建筑已完工 + 前置建筑在场 + 没满级 + 队列首条不是升级（互斥）
func can_research(building, uid: String) -> bool:
	if building == null or not building.alive() or not building.complete:
		return false
	var up := GameData.get_upgrade(uid)
	if up.is_empty():
		return false
	# ⚠️ 这里原本还有一条 `up.faction != player_race and building.owner_id == PLAYER`
	#    的守卫 —— 它和下面这条**完全重复**（`factions[PLAYER]["race"]` 恒等于
	#    `player_race`，见 `_make_faction`），而且在局域网客户端上是**错的**：
	#    客户端 `local_owner == ENEMY`、`player_race` 却是主机的种族，
	#    于是它自己的升级会被误判成「不是本种族的」。删掉，只留下面这条权威判据。
	if String(up.get("faction", "")) != factions[building.owner_id]["race"]:
		return false
	# 研究必须在对应的前置建筑里进行
	if String(up.get("requires", "")) != building.type_id:
		return false
	# 队列里已经有条目就不给排（一个建筑同一时间只做一件事）
	if building.queue.size() >= Building.QUEUE_MAX:
		return false
	var cost := next_upgrade_cost(building.owner_id, uid)
	if cost.is_empty():
		return false
	return true

func cmd_research(building, uid: String) -> bool:
	if not can_research(building, uid):
		return false
	var cost := next_upgrade_cost(building.owner_id, uid)
	if not can_afford(building.owner_id, uid):
		event_alert.emit(building.pos, "资源不足", Color("ff9b7b"))
		return false
	factions[building.owner_id]["minerals"] -= float(cost.get("cost_m", 0))
	factions[building.owner_id]["gas"] -= float(cost.get("cost_g", 0))
	building.queue_item("upgrade", uid, float(cost.get("time", 30.0)))
	event_sfx.emit("ui_open", building.pos)
	return true

## 研究完成结算（由 _try_produce 在队列出队时调用）
func _finish_research(b, uid: String) -> void:
	var cur := upgrade_level(b.owner_id, uid)
	factions[b.owner_id]["upgrades"][uid] = cur + 1
	var up := GameData.get_upgrade(uid)
	event_sfx.emit("build_done", b.pos)
	if b.owner_id == local_owner:
		event_alert.emit(b.pos, "%s %s" % [String(up.get("name", uid)),
			("已完成" if String(up.get("kind", "")) == "unlock" else "→ %d 级" % (cur + 1))],
			Color("8fe36b"))

func _generate_map() -> void:
	# 简单但有变化的地形：中央障碍群 + 边缘矿点
	#
	# ⚠️ 这里用的是**局部** RNG，和全局 `seed()` 无关 —— 所以它必须吃
	#    `map_seed`，否则地图永远只有一张（见 `map_seed` 的注释）。
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed

	# 中央岩石群（对角两条 + 中间块）。
	# 开阔平原刻意不放：那张地图要的就是「一眼望穿、大兵团正面推」。
	if map_preset != "open":
		for i in range(int(map_w * 0.18)):
			var t := rng.randf_range(0.3, 0.7)
			var cx := int(map_w * t) + rng.randi_range(-2, 2)
			var cy := int(map_h * 0.5) + rng.randi_range(-3, 3)
			_paint_rock(cx, cy, rng.randi_range(1, 3))

	# 上下两条横向岩带，形成通路
	for band in [0.22, 0.78]:
		for i in range(int(map_w * 0.35)):
			var cx := int(rng.randf_range(0.15, 0.85) * map_w)
			var cy := int(band * map_h) + rng.randi_range(-1, 1)
			if rng.randf() < 0.55:
				grid.set_terrain(cx, cy, Grid.Terrain.ROCK)

	# 随机小块岩石点缀。开阔平原减到三分之一 —— 岩石是「掩体」，也是「堵路」，
	# 撒太密的话「开阔」两个字就名不副实了。
	var scatter := int(map_w * map_h * 0.012)
	if map_preset == "open":
		scatter = int(float(scatter) * 0.34)
	for i in range(scatter):
		_paint_rock(rng.randi_range(3, map_w - 4), rng.randi_range(3, map_h - 4), 1)

	# 保证出生点周围空旷
	_clear_area(Vector2i(5, map_h / 2), 7)
	_clear_area(Vector2i(map_w - 6, map_h / 2), 7)

	# ---- 高低差与河道 ----
	# ⚠️ 顺序不能反：河道必须在岩石之后挖。反过来的话，横贯地图的岩带会压在
	#    桥上，把桥堵死 —— 而桥一堵，两岸就变成两座孤岛，AI 会一直在岸边打转，
	#    且**不会有任何报错**（和坡道口被岩石压住是同一类坑，见 _make_plateau）。
	if map_preset == "river":
		_make_river()
		# 两岸各一块小高地，各配两条坡道 —— 桥头堡的雏形。
		_make_plateau(Vector2i(int(map_w * 0.24), int(map_h * 0.26)), 4, 3)
		_make_plateau(Vector2i(int(map_w * 0.76), int(map_h * 0.74)), 4, 3)
	elif map_preset == "open":
		# 开阔平原：一块高地也不放。没有高低差，30% miss 和「低地看不见高地」
		# 这两条规则在这张图上就等于不存在 —— 这正是它的定位。
		pass
	else:
		# 两块高地平台（对角摆放，各自两条坡道）
		#
		# 高地是「低地打高地 30% miss」和「低地看不到高地」这两条规则的载体，
		# 也是防守方的天然据点。刻意放两块而不是一块：一块会变成「谁先占谁赢」，
		# 两块才能形成「一边一块、互相牵制」的格局。
		#
		# 位置刻意避开出生点（x=6 / x=map_w-6）和中央的矿点簇 ——
		# 平台压在矿上会让开局第一波采集直接乱掉。
		_make_plateau(Vector2i(int(map_w * 0.30), int(map_h * 0.30)), 5, 4)
		_make_plateau(Vector2i(int(map_w * 0.70), int(map_h * 0.70)), 5, 4)

## 中间河道：竖贯地图的深渊带，只留三座桥。
##
## 为什么是**竖**的：两个出生点分居左右（x=6 / x=map_w-6），竖河正好横在中间，
## 于是「过河」变成每一次进攻都必须回答的问题。横河的话双方各占一半、永不相见。
##
## ⚠️ 桥必须**至少 3 格宽**（72px）。1 格宽的桥在寻路里会被单位互相推挤堵死，
##    而且 A* 是 8 向邻接，斜着走会从窄桥边上「蹭」过去，让「过桥」变成随机事件。
func _make_river() -> void:
	var cx := map_w / 2
	for y in range(map_h):
		for dx in range(-1, 2):
			var x := cx + dx
			if not grid.in_bounds(x, y):
				continue
			grid.set_terrain(x, y, Grid.Terrain.CHASM)
			grid.set_elev(x, y, 0)
	# 三座桥：上、中、下。宽度 5 格、纵深 3 格，两边各多清一格做引桥。
	for by in [int(map_h * 0.22), int(map_h * 0.5), int(map_h * 0.78)]:
		for y in range(by - 1, by + 2):
			for dx in range(-3, 4):
				var x := cx + dx
				if not grid.in_bounds(x, y):
					continue
				grid.set_terrain(x, y, Grid.Terrain.GROUND)
				grid.set_elev(x, y, 0)


## 造一块高地平台，并在左右两条边缘各开一条坡道。
##
## 为什么必须**两条**坡道：只开一条的话，进攻方堵住那一条就能把整块高地变成
## 死地 —— 站在上面的单位下不来，AI 也会把自己卡死在上面。
## 两条分居两侧，才既守得住、又走得脱。
func _make_plateau(center: Vector2i, rw: int, rh: int) -> void:
	# 平台内部：先清成平地再抬升。
	# 顺序不能反 —— 原本长在里面的岩石必须先清掉，否则高地上会留着一堆
	# 谁也过不去的石头，而且很可能正好堵在坡道口。
	for y in range(center.y - rh, center.y + rh + 1):
		for x in range(center.x - rw, center.x + rw + 1):
			if not grid.in_bounds(x, y):
				continue
			grid.set_terrain(x, y, Grid.Terrain.GROUND)
			grid.set_elev(x, y, 1)
	# 坡道：从平台边缘再往外铺一格，形成两格长的斜面。
	# 靠里的那格算高地（和平台同层），靠外的那格算低地（和地面同层）——
	# 于是坡道自己就横跨了两层，can_step 的「其中一格是坡道」正好放行。
	for side: int in [-1, 1]:
		var edge_x: int = center.x + side * rw
		for k in range(2):
			var x: int = edge_x + side * k
			for dy in range(-1, 2):
				var y := center.y + dy
				if not grid.in_bounds(x, y):
					continue
				grid.set_terrain(x, y, Grid.Terrain.RAMP)
				grid.set_elev(x, y, 1 if k == 0 else 0)
		# 坡道口再往外清两格。
		# 少了这一步，横贯地图的岩石带正好压在坡道口时，整块高地就变成孤岛 ——
		# 单位上不去、AI 会一直在崖底打转，而且不会有任何报错。
		for k2 in range(2, 4):
			var ox: int = center.x + side * (rw + k2)
			for dy in range(-2, 3):
				grid.set_terrain(ox, center.y + dy, Grid.Terrain.GROUND)

func _paint_rock(cx: int, cy: int, r: int) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			if Vector2(x - cx, y - cy).length() <= float(r) + 0.3:
				grid.set_terrain(x, y, Grid.Terrain.ROCK)

func _clear_area(c: Vector2i, r: int) -> void:
	for y in range(c.y - r, c.y + r + 1):
		for x in range(c.x - r, c.x + r + 1):
			grid.set_terrain(x, y, Grid.Terrain.GROUND)

func _spawn_starting_forces() -> void:
	var pf: Dictionary = GameData.FACTIONS[player_race]
	var ef: Dictionary = GameData.FACTIONS[enemy_race]

	# 我方开局：3 农民 + 2 陆战队员，并给一座兵营，让玩家立刻能补兵防守
	var p_base_pos := Vector2(6 * Grid.CELL, map_h * 0.5 * Grid.CELL)
	var e_base_pos := Vector2((map_w - 6) * Grid.CELL, map_h * 0.5 * Grid.CELL)

	# 主基地
	var pb := _place_building(pf["start_buildings"][0], player_race, p_base_pos, PLAYER, true)
	var eb := _place_building(ef["start_buildings"][0], enemy_race, e_base_pos, ENEMY, true)

	# 起始单位
	var i := 0
	for uid in pf["start_units"]:
		_spawn_unit(uid, player_race, p_base_pos + Vector2(40 + i * 22, 52 + (i % 3) * 20), PLAYER)
		i += 1
	i = 0
	for uid in ef["start_units"]:
		_spawn_unit(uid, enemy_race, e_base_pos + Vector2(-40 - i * 22, 52 + (i % 3) * 20), ENEMY)
		i += 1
	# 双方各给一座基础军事建筑，开局即可出兵（避免"无事可做"和"来不及防守"）
	var p_mil := _mil_building_for(player_race)
	var e_mil := _mil_building_for(enemy_race)
	if p_mil != "":
		for mi in range(int(START_MIL_COUNT.get(player_race, 1))):
			_place_building(p_mil, player_race, p_base_pos + Vector2(-30 - mi * 74, 120), PLAYER, true)
	if e_mil != "":
		for mi in range(int(START_MIL_COUNT.get(enemy_race, 1))):
			_place_building(e_mil, enemy_race, e_base_pos + Vector2(30 + mi * 74, 120), ENEMY, true)

	# 双方开局各有 2 个基础作战单位（对等，后续靠运营拉开差距）
	_spawn_unit(_t1_unit(player_race), player_race, p_base_pos + Vector2(70, -56), PLAYER)
	_spawn_unit(_t1_unit(player_race), player_race, p_base_pos + Vector2(70, -26), PLAYER)
	_spawn_unit(_t1_unit(enemy_race), enemy_race, e_base_pos + Vector2(-70, -56), ENEMY)
	_spawn_unit(_t1_unit(enemy_race), enemy_race, e_base_pos + Vector2(-70, -26), ENEMY)

	# 矿点：每个阵营附近各 2 簇矿 + 2 座气矿，中间 1 簇中立矿 + 1 簇中立气矿
	# 气矿特意避开开局的军事建筑（它落在 base + (-30,120) / (+30,120)）
	_add_resource_cluster(p_base_pos + Vector2(70, -60), 6, "mineral")
	_add_resource_cluster(p_base_pos + Vector2(80, 40), 4, "mineral")
	_add_resource_cluster(p_base_pos + Vector2(60, 140), 2, "gas")
	_add_resource_cluster(e_base_pos + Vector2(-70, -60), 6, "mineral")
	_add_resource_cluster(e_base_pos + Vector2(-80, 40), 4, "mineral")
	_add_resource_cluster(e_base_pos + Vector2(-60, 140), 2, "gas")
	_add_resource_cluster(world_size * 0.5 + Vector2(0, -90), 8, "mineral")
	_add_resource_cluster(world_size * 0.5 + Vector2(0, 110), 5, "gas")

func _t1_unit(race: String) -> String:
	match race:
		"zerg": return "zergling"
		"protoss": return "zealot"
		_: return "marine"

## 各族的基础军事建筑（开局赠送一座）
func _mil_building_for(race: String) -> String:
	var menu: Array = GameData.BUILD_MENU.get(race, [])
	for entry in menu:
		var d := GameData.get_building(String(entry["id"]))
		if d.has("trains"):
			return String(entry["id"])
	return ""

func _add_resource_cluster(center: Vector2, count: int, kind: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(center.x * 31.0 + center.y * 17.0)
	for i in range(count):
		var ang := TAU * float(i) / float(count) + rng.randf() * 0.3
		var rad := 26.0 if count <= 5 else 42.0
		var p := center + Vector2(cos(ang), sin(ang)) * rad
		p = grid.nearest_free_world(p)
		var c := grid.world_to_cell(p)
		if not grid.in_bounds(c.x, c.y):
			continue
		var amount := 1500.0
		if kind == "gas":
			amount = 2500.0
		resources.append({
			"pos": p, "amount": amount, "max": amount,
			"kind": kind, "cell": c, "id": _next_id,
		})
		_next_id += 1

func _init_ai() -> void:
	var d: Dictionary = GameData.DIFFICULTY[difficulty]
	ai = {
		"eco_mult": d["ai_eco"],
		"aggro": d["ai_aggro"],
		"wave_interval": 52.0 * d["ai_wave"],
		# 首波延后：给玩家足够时间建立经济、造兵、构筑防线
		"wave_timer": 105.0 * d["ai_wave"],
		"attack_force": [],
		"base_center": Vector2((map_w - 6) * Grid.CELL, map_h * 0.5 * Grid.CELL),
		"army_target": 4,
		"scout_timer": 0.0,
		"last_wave_size": 0,
		"mode": "build",
		# 驻防重排的节流计时器（见 _ai_hold_high_ground）。
		# 不节流的话每帧都会重新下命令，部队会在原地反复重算路径、永远走不到。
		"hold_timer": 0.0,
	}

# ---------------------------------------------------------------- 生成
func _spawn_unit(type_id: String, race: String, pos: Vector2, owner: int) -> Unit:
	var u := Unit.new()
	u.setup(type_id, race, grid.nearest_free_world(pos), owner, _next_id)
	_next_id += 1
	units.append(u)
	_recount_supply(owner)
	return u

func _place_building(type_id: String, race: String, pos: Vector2, owner: int, instant: bool) -> Building:
	var b := Building.new()
	b.setup(type_id, race, pos, owner, _next_id, instant)
	_next_id += 1
	var c := grid.world_to_cell(pos)
	b.cell_pos = Vector2i(c.x - b.cells_w / 2, c.y - b.cells_h / 2)
	grid.mark_area(b.cell_pos, b.cells_w, b.cells_h, true)
	buildings.append(b)
	_recount_supply(owner)
	return b

func _recount_supply(owner: int) -> void:
	var used := 0
	for u in units:
		if u.owner_id == owner and u.alive():
			used += int(u.data.get("supply", 1))
	var cap := 0
	for b in buildings:
		if b.owner_id == owner and b.alive():
			cap += b.provides_supply()
	factions[owner]["supply_used"] = used
	factions[owner]["supply_cap"] = maxi(cap, 10)

# ---------------------------------------------------------------- 主循环
func step(delta: float) -> void:
	elapsed += delta
	_rebuild_hash()
	_update_buildings(delta)
	_update_units(delta)
	_tick_abilities(delta)
	_update_projectiles(delta)
	_update_effects(delta)
	# 局域网对局里 AI 关掉 —— 它指挥的是 ENEMY，而那是客户端本人（见 `ai_enabled`）。
	if ai_enabled:
		_update_ai(delta)
	_recount_supply(PLAYER)
	_recount_supply(ENEMY)
	# 菌毯：定期重铺 + 刷新「谁站在菌毯上」。
	# 放在 _update_buildings 之后 —— 完工与拆除都发生在那里，
	# 提前算的话这一帧的菌毯还是旧的。
	_creep_timer -= delta
	if _creep_timer <= 0.0:
		_creep_timer = CREEP_REFRESH
		_rebuild_creep()
		_refresh_terrain_flags()
	# 视野按固定间隔重算，不必每帧
	_vis_timer -= delta
	if _vis_timer <= 0.0:
		_vis_timer = VIS_INTERVAL
		update_visibility()
	_check_game_over()
	_check_stall(delta)

func _rebuild_hash() -> void:
	_hash.clear()
	for u in units:
		if not u.alive():
			continue
		var k := _hash_key(u.pos)
		if not _hash.has(k):
			_hash[k] = []
		_hash[k].append(u)

func _hash_key(p: Vector2) -> int:
	var cx := int(p.x / HASH_CELL)
	var cy := int(p.y / HASH_CELL)
	return cy * 4096 + cx

func query_units_near(p: Vector2, radius: float, owner: int = -1) -> Array:
	var out := []
	var r := int(ceil(radius / HASH_CELL))
	var base := Vector2i(int(p.x / HASH_CELL), int(p.y / HASH_CELL))
	var r2 := radius * radius
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var k := (base.y + dy) * 4096 + (base.x + dx)
			if not _hash.has(k):
				continue
			for u in _hash[k]:
				if not u.alive():
					continue
				if owner >= 0 and u.owner_id != owner:
					continue
				if u.pos.distance_squared_to(p) <= r2:
					out.append(u)
	return out

## 找最近的可攻击目标（单位或建筑）。
##
## attacker 不为空时会做**能力过滤** —— 只返回「它真的打得到」的目标。
## 这道过滤是空 / 地维度的唯一闸门：少了它，整队跳虫会锁定一架飞龙、
## 追着绕地图跑而且永远追不上，看上去像「AI 变傻了」。
func find_nearest_enemy(from: Vector2, owner: int, radius: float, attacker = null) -> Variant:
	var best = null
	var best_d := radius * radius
	for u in query_units_near(from, radius):
		if u.owner_id == owner:
			continue
		if not _can_engage(attacker, u):
			continue
		var d: float = u.pos.distance_squared_to(from)
		if d < best_d:
			best_d = d
			best = u
	for b in buildings:
		if not b.alive() or b.owner_id == owner:
			continue
		if not _can_engage(attacker, b):
			continue
		var d2: float = b.pos.distance_squared_to(from)
		if d2 < best_d:
			best_d = d2
			best = b
	return best

## 攻击方能否打到目标。Unit 与 Building 都有 can_hit()，鸭子类型直接调。
## attacker 为 null（调用点没指定攻击方）时一律放行 —— 保持旧行为不变。
func _can_engage(attacker, target) -> bool:
	if attacker == null:
		return true
	return bool(attacker.can_hit(target))

func enemy_units_of(owner: int) -> Array:
	var out := []
	for u in units:
		if u.alive() and u.owner_id != owner:
			out.append(u)
	return out

func units_of(owner: int) -> Array:
	var out := []
	for u in units:
		if u.alive() and u.owner_id == owner:
			out.append(u)
	return out

func buildings_of(owner: int) -> Array:
	var out := []
	for b in buildings:
		if b.alive() and b.owner_id == owner:
			out.append(b)
	return out

func has_building(owner: int, type_id: String) -> bool:
	for b in buildings:
		if b.alive() and b.owner_id == owner and b.type_id == type_id:
			return true
	return false

func count_building(owner: int, type_id: String) -> int:
	var n := 0
	for b in buildings:
		if b.alive() and b.owner_id == owner and b.type_id == type_id:
			n += 1
	return n

func count_units(owner: int, type_id: String = "") -> int:
	var n := 0
	for u in units:
		if u.alive() and u.owner_id == owner:
			if type_id == "" or u.type_id == type_id:
				n += 1
	return n

# ---------------------------------------------------------------- 建筑更新
func _update_buildings(delta: float) -> void:
	var i := 0
	while i < buildings.size():
		var b: Building = buildings[i]
		if b.dead:
			grid.mark_area(b.cell_pos, b.cells_w, b.cells_h, false)
			_add_effect(b.pos, b.radius() + 18.0, Color(1, 0.6, 0.2, 0.8), 0.6)
			event_sfx.emit("explosion", b.pos)
			buildings.remove_at(i)
			_recount_supply(b.owner_id)
			_release_builders(b)
			continue
		# ⚠️ 这里有**两个不能混用的量**：
		#   n_present = 已指派**且已到场**的建造者 → 决定建造速度
		#   已指派总数（**含在路上**）           → 决定要不要补人
		# 曾经用「工地旁边站了几个农民」同时判断这两件事。在路上的人位置不在旁边，
		# 于是补人判据恒为 0 → 每 0.5 秒再派一个 → 一个远处的工地
		# 能把整队农民都拉走（离基地 800px 时最多派到 16 个）。
		var n_present := _assigned_present(b)
		var was_complete := b.complete
		b.update(delta, n_present)
		if b.complete and not was_complete:
			_recount_supply(b.owner_id)
			_release_builders(b)
			event_sfx.emit("build_done", b.pos)
		elif not b.complete and _assigned_total(b) == 0:
			# 没人接手才补一个：否则 AI 的工兵被经济逻辑拉走后工地会永久烂尾
			_send_builder(b)
		# 出产单位：队首完工后由此处结算（扣资源 + 生成单位 + 出队）
		if b.ready_to_spawn():
			_try_produce(b, String(b.queue[0]["type_id"]))
		# 防御建筑开火（导弹塔 / 孢子菌落 / 光子炮台）
		_update_building_combat(b)
		i += 1

## 防御建筑的开火循环。
##
## 这是「建筑能开火」这个子系统的全部。在它之前，Building 一行攻击代码都没有 ——
## 所以防空建筑不是「给建筑加个 damage 字段」那么简单，而是要把单位那套
## 索敌 / 开火 / 弹道 / 伤害结算在建筑上重新实现一遍
## （弹道与结算复用单位那套，见 _fire / _impact）。
##
## 三条闸门缺一不可：
##   ① is_combat()  —— 非攻击建筑（主基地、兵营…）完全不进这个函数
##   ② complete     —— 没造完的塔不能开火，否则「边造边打」会让塔无法拆除
##   ③ can_hit()    —— 只对空的塔不能去打地面部队（见 find_nearest_enemy 的能力过滤）
func _update_building_combat(b: Building) -> void:
	if not b.complete or not b.is_combat():
		return
	var target = b.attack_target
	if target != null:
		if target is Unit and not target.alive():
			target = null
		elif target is Building and not target.alive():
			target = null
	if target != null and not b.can_hit(target):
		target = null
	if target == null:
		target = find_nearest_enemy(b.pos, b.owner_id, b.attack_range() + 24.0, b)
		b.attack_target = target
	if target == null:
		return
	# 目标跑出射程就丢掉，等它再进来 —— 塔不追人。
	var reach: float = b.attack_range() + (target.radius() if target is Building else 0.0)
	if b.pos.distance_to(target.pos) > reach + 40.0:
		b.attack_target = null
		return
	if b.can_fire():
		b.cooldown = b.attack_interval()
		_fire(b, target)

## 工地完工或被拆后，解开绑在它上面的工兵，让它们回去采矿
func _release_builders(b: Building) -> void:
	for u in units:
		if u.build_target == b:
			u.build_target = null

## 这个建造者是否**已经站到工地上**（而不是还在赶路）。
##
## ⚠️ 判据是「已经站定」而**不是**「离工地多近」。
## 踩过的坑：AI 会把建筑摆得很密，`_stand_point()` 算出的站位经常落在阻挡格里，
## 被 `grid.nearest_free_world()` 吸附到 60~75px 外 —— 而按距离判的半径是
## `radius + 36 ≈ 49`，于是**永远到不了场**：建造者就站在自己的站位上，
## 工地进度却卡在 0% 一动不动。实测一次对局里有 5 个工地同时烂尾一百多秒。
func builder_arrived(b: Building, u: Unit) -> bool:
	if u == null or u.dead or u.build_target != b:
		return false
	# 路径走完 / 没有移动指令 = 已经站定（见 _update_movement 的收尾处理）
	if u.has_move_order:
		return false
	# 兜底：万一被别的逻辑 stop() 在半路上，别把它算成在场
	return u.pos.distance_to(b.pos) <= 260.0

## 已指派到这个工地、**且已经到场**的建造者数 —— 用它算建造速度。
func _assigned_present(b: Building) -> int:
	var n := 0
	for u in units:
		if u.dead or u.owner_id != b.owner_id or u.build_target != b:
			continue
		if builder_arrived(b, u):
			n += 1
	return n

## 已指派到这个工地的建造者数，**含还在路上的** —— 用它判断「要不要补人」。
## 判「要不要补人」必须看这个而不是 `_assigned_present()`：
## 在路上的人已经接手了，这时候再派一个就是重复派工。
func _assigned_total(b: Building) -> int:
	var n := 0
	for u in units:
		if u.dead or u.owner_id != b.owner_id or u.build_target != b:
			continue
		n += 1
	return n

## 公开查询：这个工地有几个建造者被指派（含在路上）。
## 渲染层用它判断要不要给玩家显示「等待建造者」—— 工地停滞是
## 最容易让人误以为游戏坏了的状态，必须显式说出来。
func builder_count(b: Building) -> int:
	return _assigned_total(b)

## 建造者是否**已经到场**。渲染层用它决定画不画「赶往工地」的虚线。
func builder_present(b: Building) -> bool:
	return _assigned_present(b) > 0

## 把一个农民正式指派到工地：停下手上的活、走到站位、打上标记。
## 所有指派都必须走这里。**顺序很重要** —— `move_to()` 内部会调 `stop()`，
## 而 `stop()` 会把 `build_target` 清成 null，所以标记必须最后打。
func _assign_builder(b: Building, u: Unit) -> void:
	if u == null or u.dead:
		return
	u.stop()
	u.move_to(_stand_point(u, b))
	u.build_target = b

## 自动挑空闲工兵派到工地（每 0.5 秒最多一次，避免每帧抖动）。
## `count` 是这次要补的人数。玩家侧永远只补 1 个，AI 给大型建筑补 2 个。
func _send_builder(b: Building, count: int = 1) -> void:
	# 已经有人接手就不再派。这是防重复派工的**最后一道闸**：
	# 调用方已经用 `_assigned_total()` 判过一次，但把闸门也放在这里，
	# 以后新增调用点就不会重新引入「一个工地拉走整队农民」的 bug。
	if _assigned_total(b) > 0:
		return
	var last := float(b.get_meta("builder_ping", -99.0))
	if b.anim_t - last < 0.5:
		return
	b.set_meta("builder_ping", b.anim_t)
	var sent := 0
	while sent < count:
		var best: Unit = null
		var bd := INF
		for u in units:
			if u.dead or u.owner_id != b.owner_id or not u.can_harvest():
				continue
			if u.build_target != null:
				continue      # 已经绑在别的工地上
			if u.has_move_order or u.carry > 0.0:
				continue      # 已经在赶路 / 正在卸货的不打扰
			var d: float = u.pos.distance_squared_to(b.pos)
			if d < bd:
				bd = d
				best = u
		if best == null:
			return
		_assign_builder(b, best)
		sent += 1

func _try_produce(b: Building, type_id: String) -> void:
	# 队列条目分两类：出兵 和 研究。
	# 研究不占人口、不生成单位，出队后直接结算等级。
	if b.head_kind() == "upgrade":
		b.pop_head()
		_finish_research(b, type_id)
		return
	var u := GameData.get_unit(type_id)
	if u.is_empty():
		b.pop_head()
		return
	var f: Dictionary = factions[b.owner_id]
	var supply := int(u.get("supply", 1))
	# 资源在 cmd_train 入队时已扣除，此处只校验人口（不要再扣一次）
	if f["supply_used"] + supply > f["supply_cap"]:
		# 人口不足：暂缓出产，给玩家提示
		if b.owner_id == local_owner and b.anim_t - float(b.get_meta("last_cap_warn", -99.0)) > 3.0:
			b.set_meta("last_cap_warn", b.anim_t)
			event_alert.emit(b.pos, "人口不足，无法出产", Color(1, 0.6, 0.3))
		# 把时间回退一点，形成"等待人口"的状态
		b.queue[0]["time_left"] = -0.0
		return
	b.pop_head()
	var spawn_pos := b.pos + Vector2(cos(b.anim_t * 3.0), sin(b.anim_t * 3.0)) * (b.radius() + 26.0)
	var newu := _spawn_unit(type_id, b.faction, spawn_pos, b.owner_id)
	event_sfx.emit("train_done", spawn_pos)
	if b.has_rally:
		newu.move_to(b.rally)

# ---------------------------------------------------------------- 单位更新
func _update_units(delta: float) -> void:
	var i := 0
	while i < units.size():
		var u: Unit = units[i]
		if u.dead:
			_add_effect(u.pos, u.radius() + 8.0, Color(1, 0.4, 0.3, 0.7), 0.4)
			event_sfx.emit("unit_death", u.pos)
			units.remove_at(i)
			_recount_supply(u.owner_id)
			continue
		u.update_common(delta)
		if u.is_worker():
			_update_worker(u, delta)
		if u.alive():
			_update_combat(u, delta)
			_update_order(u, delta)
			_update_movement(u, delta)
			_separate(u, delta)
		i += 1

## 普通移动指令：Unit.move_to 只记下目的地，真正的寻路在这里发生。
## 缺了这一步，move_to 永远不会产生路径，单位会带着「有移动指令」的标记原地不动。
func _update_order(u: Unit, delta: float) -> void:
	if not u.has_move_order or u.path.size() > 0:
		return
	# 攻击移动的目的地由 _update_combat 负责推进
	if u.attack_move or u.forced_target_pos != null:
		return
	# 正在交火（目标已在射程内）就先打完，_update_combat 已经清掉了路径
	var t = u.attack_target
	if t != null and t.alive():
		var reach: float = u.attack_range() + (t.radius() if t is Building else 0.0)
		if u.pos.distance_to(t.pos) <= reach:
			return
	if u.pos.distance_to(u.final_target) <= u.radius() + 10.0:
		u.has_move_order = false
		return
	_set_path(u, u.final_target, 1.2)

# ---- 采集
func _update_worker(u: Unit, delta: float) -> void:
	# 工地上的工兵：目标建筑没完工就原地待命，绝不回去采矿。
	# 这里是防抖动的关键——否则工兵走到工地后会被判为空闲，反复来回跑。
	if u.build_target != null:
		var bt = u.build_target
		if bt == null or not bt.alive() or bt.complete:
			u.build_target = null
		else:
			u.resource_target = null
			u.harvest_target = null
			u.harvest_state = 0
			u.harvest_timer = 0.0
			u.carry = 0.0
			return
	if u.harvest_target == null and u.resource_target == null:
		return
	# 校验目标
	var rt = u.resource_target
	if rt != null:
		if rt.get("amount", 0.0) <= 0.0:
			u.resource_target = null
			rt = null
		elif String(rt.get("kind", "mineral")) == "gas" and gas_building_on(rt) == null:
			# 精炼厂被拆/还没建好，采气中断
			u.resource_target = null
			u.carry = 0.0
			u.harvest_target = _nearest_dropoff(u.pos, u.owner_id)
			u.harvest_state = 1
			rt = null
	if u.harvest_target != null and not u.harvest_target.alive():
		u.harvest_target = null
		# 换一个最近的主基地
		u.harvest_target = _nearest_dropoff(u.pos, u.owner_id)

	if u.harvest_state == 0:
		# 前往矿点
		if rt == null:
			if u.harvest_target != null:
				u.harvest_state = 1
			return
		var goal: Vector2 = rt["pos"]
		if String(rt.get("kind", "mineral")) == "gas":
			# 气矿被建筑压住，格子是阻挡的：必须走到建筑旁边而不是中心
			var gb2 = gas_building_on(rt)
			if gb2 == null:
				return
			goal = _stand_point(u, gb2)
		var d := u.pos.distance_to(goal)
		if d <= u.radius() + 16.0:
			u.harvest_timer += delta
			if u.harvest_timer >= 1.4:
				u.harvest_timer = 0.0
				var take := minf(float(u.data.get("harvest_rate", 7.0)), rt["amount"])
				rt["amount"] -= take
				u.carry = take
				u.carry_kind = String(rt.get("kind", "mineral"))
				u.harvest_state = 1
				if u.harvest_target == null:
					if u.carry_kind == "gas":
						u.harvest_target = gas_building_on(rt)
					else:
						u.harvest_target = _nearest_dropoff(u.pos, u.owner_id)
		else:
			_set_path(u, goal, 2.5)
	elif u.harvest_state == 1:
		var hb = u.harvest_target
		if hb == null:
			u.harvest_state = 0
			return
		var d2 := u.pos.distance_to(hb.pos)
		# 建筑本体在网格上是阻挡的，工人只能站到边上，所以判定要留足余量
		var slack := 30.0 if u.carry_kind == "gas" else 22.0
		if d2 <= hb.radius() + u.radius() + slack:
			if u.carry_kind == "gas":
				factions[u.owner_id]["gas"] = float(factions[u.owner_id]["gas"]) + u.carry
			else:
				factions[u.owner_id]["minerals"] = float(factions[u.owner_id]["minerals"]) + u.carry
				factions[u.owner_id]["harvested"] = float(factions[u.owner_id]["harvested"]) + u.carry
			u.carry = 0.0
			u.harvest_state = 0
		else:
			_set_path(u, _stand_point(u, hb), 2.5)

## 建筑周围一个可站立的点（建筑本体在网格上是阻挡的，直接寻路到中心会失败）
func _stand_point(u: Unit, b) -> Vector2:
	var off: Vector2 = u.pos - b.pos
	if off.length() < 1.0:
		off = Vector2(1, 0)
	var p: Vector2 = b.pos + off.normalized() * (b.radius() + u.radius() + 6.0)
	# 建筑占的是整格，算出来的点仍可能落在阻挡格里 —— 吸附到最近的可通行格
	return grid.nearest_free_world(p)

func _nearest_dropoff(from: Vector2, owner: int):
	var best = null
	var bd := INF
	for b in buildings:
		if not b.alive() or b.owner_id != owner:
			continue
		if not b.data.get("dropoff", false):
			continue
		var d := from.distance_squared_to(b.pos)
		if d < bd:
			bd = d
			best = b
	return best

# ---- 战斗
func _update_combat(u: Unit, delta: float) -> void:
	if u.is_worker() or not u.is_combat():
		# 工兵不主动索敌；非战斗单位（医疗兵 damage 为 0）也必须挡在这里，
		# 否则它会去找敌人「开火」并射出零伤害弹道，白白占满弹道列表。
		return
	var atk_range := u.attack_range()

	# 主动索敌
	var target = u.attack_target
	if target != null:
		if target is Unit and not target.alive():
			target = null
		elif target is Building and not target.alive():
			target = null
	# 目标还活着、但**自己根本打不到它**（跳虫锁定了飞龙、陆战队员想打建筑）：
	# 必须在这里清掉。否则单位会一直「有目标」——既不重新索敌也不移动，
	# 变成追着空军绕地图跑的木偶。
	if target != null and not u.can_hit(target):
		target = null
	# 「太远就放弃」只适用于自动索敌得到的目标。
	# 指令点名的目标必须一路追过去——否则右键点远处的敌人会毫无反应，
	# 单位会带着攻击指令原地站桩（这是实测出来的硬伤）。
	if target != null and not u.attack_ordered:
		# 攻击移动的终点在很远的地方，不能因为距离远就丢目标，
		# 否则单位会既不移动也不攻击，原地卡死。
		var en_route: bool = u.attack_move and u.forced_target_pos != null \
			and u.pos.distance_to(u.forced_target_pos) > 20.0
		if not en_route and u.pos.distance_to(target.pos) > atk_range + 140.0:
			target = null
	if target == null:
		u.attack_ordered = false
		var search_r := atk_range + 30.0
		target = find_nearest_enemy(u.pos, u.owner_id, search_r, u)
		# 攻击移动时扩大索敌
		if target == null and u.attack_move:
			target = find_nearest_enemy(u.pos, u.owner_id, u.sight(), u)
		u.attack_target = target

	if target == null:
		# 攻击移动但附近无敌人：继续向指定地点推进，而不是原地待命。
		# 这是 RTS 的关键行为——否则远程攻击移动会永久卡在出发地。
		if u.attack_move and u.forced_target_pos != null:
			if u.pos.distance_to(u.forced_target_pos) > 26.0:
				_set_path(u, u.forced_target_pos, 0.8)
			else:
				u.attack_move = false
				u.forced_target_pos = null
				u.has_move_order = false
				u.path = PackedVector2Array()
		return

	var dist: float = u.pos.distance_to(target.pos)
	var reach: float = atk_range + (target.radius() if target is Building else 0.0)
	if dist <= reach:
		# 到达射程：停下开火（但保留移动指令，打完继续走；攻击移动另有终点）
		u.path = PackedVector2Array()
		u.vel = Vector2.ZERO
		u.facing = (target.pos - u.pos).angle()
		if u.can_fire():
			u.cooldown = u.cooldown_time()
			_fire(u, target)
	else:
		# 追近
		if u.attack_move or not u.has_move_order:
			_set_path(u, target.pos, 0.4)

## 发射一发弹道。
##
## shooter 可以是 Unit 也可以是 Building —— 两者的 weapon_kind() / attack_damage() /
## radius() / faction 接口一致，唯一差别是**建筑不会转身**，
## 所以它的朝向由「目标在哪」实时算出来。
func _fire(shooter, target) -> void:
	var kind := String(shooter.weapon_kind())
	var ang: float
	if shooter is Unit:
		ang = shooter.facing
	else:
		ang = (target.pos - shooter.pos).angle()
	var speed := 620.0
	match kind:
		"cannon", "shell": speed = 460.0
		"bullet": speed = 900.0
		"acid": speed = 380.0
		"phase": speed = 700.0
		"spine": speed = 640.0
		"glave": speed = 560.0
		"laser": speed = 950.0
		"missile": speed = 520.0
		_: speed = 620.0
	projectiles.append({
		"pos": shooter.pos + Vector2(cos(ang), sin(ang)) * (shooter.radius() + 4.0),
		"target": target,
		"dmg": shooter.attack_damage(),
		"dtype": String(shooter.data.get("damage_type", "normal")),
		"speed": speed,
		"faction": shooter.faction,
		"kind": kind,
		"life": 2.5,
		"color": GameData.FACTIONS[shooter.faction]["accent"],
		# 攻击加成在开火时就锁定。若改成命中时再查，弹道飞行途中刚好研究完成
		# 会让同一发子弹的伤害前后不一致。
		"atk_bonus": _atk_bonus_for(shooter),
		# 这一发是不是「从低处往高处打」。在开火时锁定，
		# 因为命中时 shooter 可能已经死了、也可能已经跑到了别的高度。
		"uphill": _is_uphill(shooter, target),
	})
	event_sfx.emit(_sfx_for_weapon(kind), shooter.pos)

## 这一发是不是「从低处往高处打」。
##
## 飞行单位**无视**高低差 —— 一条规则同时管住两边：
## 从飞机上往下打、以及打天上的飞机，都不吃地形惩罚。
## 少了前一条，一架贴着崖壁飞的飞机打崖顶的坦克会莫名其妙地空一半。
func _is_uphill(shooter, target) -> bool:
	if shooter is Unit and shooter.is_flying():
		return false
	if target is Unit and target.is_flying():
		return false
	return grid.elev_at(shooter.pos) < grid.elev_at(target.pos)

## 攻击方的攻击加成。升级是阵营级的，所以按「单位分类」去匹配对应的升级线。
##
## 防空建筑开火也会走这里，但 UPGRADE_CLASS 里没有建筑，
## upgrade_applies() 一律返回 false —— 建筑的攻击加成恒为 0，这是对的。
func _atk_bonus_for(shooter) -> int:
	var up: Dictionary = factions[shooter.owner_id].get("upgrades", {})
	var total := 0
	for uid in up:
		var d := GameData.get_upgrade(uid)
		if String(d.get("effect", "")) != "attack":
			continue
		if GameData.upgrade_applies(uid, shooter.type_id):
			total += int(up[uid])
	return total

## 防守方的加成。effect 传 "armor"（本体护甲）或 "shield_armor"（等离子护盾）。
## 建筑吃不到 —— UPGRADE_CLASS 里没有建筑，upgrade_applies 会返回 false。
func _defense_bonus(target, effect: String) -> int:
	if target == null:
		return 0
	var tid := String(target.type_id)
	var up: Dictionary = factions.get(int(target.owner_id), {}).get("upgrades", {})
	var total := 0
	for uid in up:
		var d := GameData.get_upgrade(uid)
		if String(d.get("effect", "")) != effect:
			continue
		if GameData.upgrade_applies(uid, tid):
			total += int(up[uid])
	return total

## 武器类型 → 音效名。只有逻辑层知道「开的是什么武器」，所以映射放在这里；
## 具体播不播、播多响由 Main 决定。
static func _sfx_for_weapon(kind: String) -> String:
	match kind:
		"bullet": return "shot_bullet"
		"cannon", "shell": return "shot_cannon"
		"acid": return "shot_acid"
		"psionic": return "shot_psionic"
		"psiblade", "claw": return "melee_hit"
		"phase", "spine", "glave", "laser", "missile": return "shot_laser"
		_: return "shot_bullet"

var _pending_hits := {}

func _update_projectiles(delta: float) -> void:
	var i := 0
	while i < projectiles.size():
		var p: Dictionary = projectiles[i]
		p["life"] -= delta
		var target = p["target"]
		var tp: Vector2
		var valid := true
		if target is Unit:
			valid = target.alive()
			tp = target.pos if valid else p["pos"]
		elif target is Building:
			valid = target.alive()
			tp = target.pos if valid else p["pos"]
		else:
			valid = false
			tp = p["pos"]

		if not valid or p["life"] <= 0.0:
			projectiles.remove_at(i)
			continue

		var dir: Vector2 = (tp - p["pos"])
		var step: float = float(p["speed"]) * delta
		if dir.length() <= step + 6.0:
			_impact(p, target)
			projectiles.remove_at(i)
			continue
		p["pos"] = p["pos"] + dir.normalized() * step
		i += 1

func _impact(p: Dictionary, target) -> void:
	_add_effect(p["pos"], 9.0, p["color"], 0.18)
	# 低地打高地：固定 30% 打空。
	#
	# 掷骰放在**命中结算**处，而不是开火时 —— 弹道照飞、落点照样有火花，
	# 只是不掉血。玩家看到的是「明明打中了却没伤害」，和星际 1 的观感一致；
	# 若在开火时就决定不发弹，画面上会变成「一半的兵在哑火」，看起来像 bug。
	#
	# 掷骰必须在 `target == null` 之前：否则「打空的概率」会随着目标
	# 在弹道飞行途中死掉而变小，等于变相提高了高地的收益。
	if bool(p.get("uphill", false)) and randf() < UPHILL_MISS:
		_add_effect(p["pos"], 8.0, Color(0.90, 0.93, 1.0, 0.85), 0.20)
		return
	# 命中音极高频（一次齐射十几个），Main 侧会做同音限流
	event_sfx.emit("hit", p["pos"])
	if target == null:
		return
	var atk := int(p.get("atk_bonus", 0))
	var killed := false
	if target is Unit:
		killed = target.take_damage(p["dmg"], p["dtype"], atk,
			_defense_bonus(target, "armor"), _defense_bonus(target, "shield_armor"))
	elif target is Building:
		killed = target.take_damage(p["dmg"], p["dtype"])
	if p["kind"] in ["cannon", "shell", "psionic"]:
		# 溅射
		var splash := 34.0 if p["kind"] == "cannon" else 24.0
		# 溅射只影响**和主目标同一层**的单位 —— 炮弹不会顺带炸到天上的飞机。
		# 少了这一句，一架飞龙飞过坦克的炮击落点就会被莫名其妙地溅到。
		var air_layer: bool = target is Unit and target.is_flying()
		for u in query_units_near(p["pos"], splash):
			if u.faction == p["faction"]:
				continue
			if u.is_flying() != air_layer:
				continue
			u.take_damage(p["dmg"] * 0.4, p["dtype"], atk,
				_defense_bonus(u, "armor"), _defense_bonus(u, "shield_armor"))
	if killed and target is Unit:
		_add_effect(target.pos, 14.0, Color(1, 0.5, 0.3, 0.9), 0.4)

func _add_effect(pos: Vector2, radius: float, color: Color, life: float) -> void:
	effects.append({"pos": pos, "r": radius, "color": color, "life": life, "max": life})

func _update_effects(delta: float) -> void:
	var i := 0
	while i < effects.size():
		effects[i]["life"] -= delta
		if effects[i]["life"] <= 0.0:
			effects.remove_at(i)
		else:
			i += 1

# ---- 移动
func _set_path(u: Unit, goal: Vector2, tolerance: float) -> void:
	# 已有路径且目标没变、且在重算冷却内 → 不重复算路
	if u.path.size() > 0 and u.final_target.distance_to(goal) < 14.0 and u.repath_timer > 0.0:
		u.has_move_order = true
		return
	u.repath_timer = tolerance
	# 飞行单位**不寻路**：一条直线飞过去，忽略岩石与建筑占位。
	# 这是「空中」最核心的一条规则 —— 如果飞行单位也走地面寻路，
	# 它会被建筑和悬崖堵住，「空军」就退化成了「飞得快一点的陆军」。
	if u.is_flying():
		var dst: Vector2 = goal.clamp(Vector2(6, 6), world_size - Vector2(6, 6))
		u.path = PackedVector2Array([dst])
		u.path_index = 0
		u.final_target = goal
		u.has_move_order = true
		return
	var raw := grid.find_path(u.pos, goal)
	# 寻路失败时不覆盖已有路径（避免把正在走的路径清空导致原地卡死）
	if raw.size() == 0:
		if u.path.size() == 0:
			u.has_move_order = false
		return
	raw = grid.smooth(raw, u.pos)
	u.path = raw
	u.path_index = 0
	u.final_target = goal
	u.has_move_order = true

func _update_movement(u: Unit, delta: float) -> void:
	if u.repath_timer > 0.0:
		u.repath_timer -= delta
	if u.path.size() == 0:
		u.vel = u.vel.lerp(Vector2.ZERO, minf(1.0, delta * 9.0))
		return
	var wp := u.path[mini(u.path_index, u.path.size() - 1)]
	var to := wp - u.pos
	var arrive_r := u.radius() + 8.0
	if u.path_index >= u.path.size() - 1:
		arrive_r = u.radius() + 7.0
	if to.length() <= arrive_r:
		u.path_index += 1
		if u.path_index >= u.path.size():
			u.path = PackedVector2Array()
			u.has_move_order = false
			u.vel = Vector2.ZERO
			return
		return
	var desired := to.normalized() * u.speed()
	u.vel = u.vel.lerp(desired, minf(1.0, delta * 8.0))
	u.pos += u.vel * delta
	u.facing = lerp_angle(u.facing, u.vel.angle(), minf(1.0, delta * 9.0))
	u.pos = u.pos.clamp(Vector2(6, 6), world_size - Vector2(6, 6))

## 单位互相推开，避免堆叠。
##
## 分层规则：**空中与地面互不推开**。
## 不分开的话，一架飞龙飞到矿场上空会把正在采矿的农民挤开，
## 而农民根本够不到它 —— 玩家会看到矿工莫名其妙地乱走，还找不到原因。
func _separate(u: Unit, delta: float) -> void:
	var push := Vector2.ZERO
	var near := query_units_near(u.pos, u.radius() * 2.6)
	var u_fly: bool = u.is_flying()
	for o in near:
		if o == u:
			continue
		if o.is_flying() != u_fly:
			continue
		var d: Vector2 = u.pos - o.pos
		var dist: float = d.length()
		var min_d: float = u.radius() + o.radius()
		if dist < min_d and dist > 0.001:
			push += d.normalized() * (min_d - dist)
	if push != Vector2.ZERO:
		var p := push * minf(1.0, delta * 7.0)
		var cand := u.pos + p
		# 飞行单位不受地形阻挡，只需要夹在地图内
		if u_fly:
			u.pos = cand.clamp(Vector2(6, 6), world_size - Vector2(6, 6))
		# 地面单位必须站在**同一层**：只判 is_walkable 的话，
		# 崖底一队兵互相挤一下就能把其中一个挤上崖顶（画面上像瞬移），
		# 而且它会白拿高地那 30% 的闪避优势。
		elif grid.is_walkable_on_layer(cand, grid.elev_at(u.pos)):
			u.pos = cand

# ---------------------------------------------------------------- 命令接口
# ================================================================ 单位技能

## 该单位此刻能否使用某个技能。UI 的按钮可用状态也走这里，
## 保证「按钮亮着但点了没反应」这种情况不会出现。
func can_use_ability(u: Unit, aid: String) -> bool:
	if u == null or not u.alive():
		return false
	var ab := GameData.get_ability(aid)
	if ab.is_empty():
		return false
	if String(ab.get("unit", "")) != u.type_id:
		return false
	if not u.abilities().has(aid):
		return false
	if u.ability_cd > 0.0 or u.mode_timer > 0.0:
		return false
	if not has_ability_unlock(u.owner_id, aid):
		return false
	# 已经处于该增益中就不能再施放。
	# 兴奋剂的 cooldown 是 0（SC1 里也是），AI 每帧都会来问一次 ——
	# 少了这道闸，10 点自伤会每 0.05 秒扣一次，整队陆战队员瞬间被扎到 1 血。
	# 玩家按住技能键同理。buff 键名就用技能 id，一条规则覆盖所有持续型技能。
	if u.has_buff(aid):
		return false
	if ab.has("energy") and u.energy < float(ab["energy"]):
		return false
	return true

## 释放技能。target 只有指向型技能（治疗）需要。
## 返回是否有至少一个单位成功释放。
func cmd_ability(units_arr: Array, aid: String, target = null) -> bool:
	var any_ok := false
	for u in units_arr:
		if not can_use_ability(u, aid):
			continue
		match aid:
			"stim":
				var ab := GameData.get_ability("stim")
				# 兴奋剂会扣血，但不致命 —— 卡在 1 点血而不是打死自己。
				u.hp = maxf(1.0, u.hp - float(ab.get("self_damage", 0.0)))
				u.apply_buff("stim", float(ab.get("duration", 10.0)))
				u.ability_cd = float(ab.get("cooldown", 0.0))
				event_sfx.emit("stim", u.pos)
				any_ok = true
			"siege":
				u.set_mode("normal" if u.mode == "sieged" else "sieged")
				u.ability_cd = float(GameData.get_ability("siege").get("cooldown", 1.0))
				event_sfx.emit("siege_deploy", u.pos)
				any_ok = true
			"heal":
				if _try_heal(u, target):
					any_ok = true
	return any_ok

func _try_heal(medic: Unit, target) -> bool:
	if target == null or not (target is Unit):
		return false
	var t: Unit = target
	if not t.alive() or t.owner_id != medic.owner_id:
		return false
	var ab := GameData.get_ability("heal")
	if medic.pos.distance_to(t.pos) > float(ab.get("range", 60.0)):
		return false
	if t.hp >= t.max_hp - 0.5:
		return false
	t.hp = minf(t.max_hp, t.hp + float(ab.get("heal", 15.0)))
	medic.energy -= float(ab.get("energy", 1.0))
	medic.ability_cd = float(ab.get("cooldown", 1.0))
	event_sfx.emit("heal", t.pos)
	return true

## 医疗兵的自动治疗。
## SC1 里医疗兵就是自动治疗附近伤员的 —— 触屏上更是必须自动，
## 否则每次治疗都要「选中医疗兵 → 点技能 → 点目标」三步，微操负担太重。
func _tick_abilities(delta: float) -> void:
	for u in units:
		if u.dead or u.abilities().is_empty():
			continue
		if u.abilities().has("heal"):
			_medic_auto_heal(u)

func _medic_auto_heal(u: Unit) -> void:
	if not can_use_ability(u, "heal"):
		return
	var reach := float(GameData.get_ability("heal").get("range", 60.0))
	var best: Unit = null
	var best_ratio := 1.0
	for o in units:
		if o.dead or o.owner_id != u.owner_id or o == u:
			continue
		# 满血的不管。护盾不满也治 —— 护盾虽然会自然回复，但治疗更快。
		if o.hp >= o.max_hp - 0.5 and o.shield >= o.max_shield - 0.5:
			continue
		if u.pos.distance_to(o.pos) > reach:
			continue
		var ratio: float = o.total_hp_ratio()
		if ratio < best_ratio:
			best_ratio = ratio
			best = o
	if best != null:
		_try_heal(u, best)

# ---------------------------------------------------------------- 指令
func cmd_move(units_arr: Array, target: Vector2, attack_mode: bool = false) -> void:
	if units_arr.is_empty():
		return
	# 编队散开
	var formation := _formation_offsets(units_arr.size(), 34.0)
	for i in range(units_arr.size()):
		var u: Unit = units_arr[i]
		var slot: Vector2 = target + formation[i]
		slot = grid.nearest_free_world(slot)
		if attack_mode:
			u.attack_to(slot)
		else:
			u.move_to(slot)

func _formation_offsets(n: int, spacing: float) -> Array:
	var out := []
	if n == 1:
		out.append(Vector2.ZERO)
		return out
	var cols := int(ceil(sqrt(float(n))))
	var rows := int(ceil(float(n) / float(cols)))
	for i in range(n):
		var r := i / cols
		var c := i % cols
		out.append(Vector2(
			(float(c) - float(cols - 1) * 0.5) * spacing,
			(float(r) - float(rows - 1) * 0.5) * spacing
		))
	return out

func cmd_attack(units_arr: Array, target) -> void:
	for u in units_arr:
		if u.alive():
			u.attack(target)

func cmd_stop(units_arr: Array) -> void:
	for u in units_arr:
		u.stop()

func cmd_harvest(units_arr: Array, node: Dictionary) -> void:
	if node.is_empty():
		return
	var is_gas := String(node.get("kind", "mineral")) == "gas"
	for u in units_arr:
		if not u.can_harvest():
			continue
		u.stop()
		u.resource_target = node
		if is_gas:
			# 采气：往返目标就是压在气矿上的那座建筑
			u.harvest_target = gas_building_on(node)
		else:
			u.harvest_target = _nearest_dropoff(u.pos, u.owner_id)
		u.harvest_state = 0

## 单位移动到资源点时自动转为采集
func cmd_smart(units_arr: Array, target_pos: Vector2, node, target_entity) -> void:
	if node != null:
		var workers := []
		var others := []
		for u in units_arr:
			if u.can_harvest():
				workers.append(u)
			else:
				others.append(u)
		if not workers.is_empty():
			cmd_harvest(workers, node)
		if not others.is_empty():
			cmd_move(others, target_pos)
		return
	if target_entity != null:
		cmd_attack(units_arr, target_entity)
		return
	cmd_move(units_arr, target_pos, false)

# ---- 建造
## 该坐标是否处在己方能量场内（水晶塔或星灵枢纽投射）
func has_power_at(pos: Vector2, owner: int) -> bool:
	for b in buildings_of(owner):
		if not b.complete:
			continue
		if b.type_id != "pylon" and not b.data.get("dropoff", false):
			continue
		if b.pos.distance_to(pos) <= POWER_RADIUS:
			return true
	return false

## 己方所有能量场源（用于绘制能量场范围）
func power_sources(owner: int) -> Array:
	var out := []
	for b in buildings_of(owner):
		if not b.complete:
			continue
		if b.type_id != "pylon" and not b.data.get("dropoff", false):
			continue
		out.append(b)
	return out

# ---- 菌毯：虫族的「地形红利」，和神族的能量场是一对镜像

## 该建筑是不是菌毯源：所有**已完工**的虫族建筑都算。
##
## ⚠️ 必须判 complete —— 未完工的工地不产生菌毯。
##    少了这一条，虫族就能靠一堆工地把菌毯铺满地图（工地本身不花几秒就消失），
##    星际 1 里工地同样是不产生菌毯的。
func _is_creep_source(b) -> bool:
	if b == null or b.dead or not b.complete:
		return false
	return String(b.data.get("faction", "")) == "zerg"

## 该坐标是否被菌毯覆盖。
##
## ⚠️ 刻意**不按 owner 过滤**：菌毯是铺在地上的东西，不分敌我。
##    星际 1 里你的部队可以站在敌方菌毯上（只是不享受加速）。
##    按 owner 过滤会造出一个「同一格菌毯对 A 是菌毯、对 B 不是」的怪规则，
##    渲染层也没法画 —— 那一格到底画不画？
func has_creep_at(pos: Vector2) -> bool:
	return grid.creep_at(pos)

## 场上所有菌毯源（用于绘制菌毯范围 / 建造预览）
func creep_sources() -> Array:
	var out := []
	for b in buildings:
		if _is_creep_source(b):
			out.append(b)
	return out

## 重铺菌毯：把所有菌毯源的覆盖范围重新算一遍。
##
## 刻意**定期无条件重铺**，而不是给「建筑完工 / 被拆」挂钩子 ——
## 挂钩子需要在 World 里逐帧比对每座建筑的上一帧状态，比定期重铺更容易漏，
## 而且漏了**完全不报错**（症状就是菌毯永远不长）。菌毯源最多十来座、
## 每座百来格，半秒重铺一次的开销可以忽略。
func _rebuild_creep() -> void:
	for i in _creep_cells:
		grid.creep[i] = 0
	_creep_cells.clear()
	for b in creep_sources():
		var rad: float = CREEP_RADIUS_HIVE if b.type_id == "hive" else CREEP_RADIUS
		var c := grid.world_to_cell(b.pos)
		var rc := int(ceil(rad / Grid.CELL))
		var r2 := rad * rad
		for dy in range(-rc, rc + 1):
			var cy := c.y + dy
			if cy < 0 or cy >= grid.h:
				continue
			for dx in range(-rc, rc + 1):
				var cx := c.x + dx
				if cx < 0 or cx >= grid.w:
					continue
				# 用**格子中心**到建筑中心的距离，不是格子原点 ——
				# 用原点会让整片菌毯往左上偏半格，渲染出的圆和判定边界对不上。
				if grid.cell_to_world(Vector2i(cx, cy)).distance_squared_to(b.pos) > r2:
					continue
				var i := cy * grid.w + cx
				if grid.creep[i] == 0:
					grid.creep[i] = 1
					_creep_cells.append(i)

## 刷新每个单位脚下的地形标记（菌毯加速 / 高地加成）。
##
## 两个标记都在这里刷，而不是让 Unit 自己算 —— 单位拿不到 world 引用，
## 而且「谁站在哪一格上」本来就是个按格子查的全局问题。
##
## 菌毯：只有**虫族地面单位**吃加成（人神站在菌毯上不受影响，空军也不吃 ——
## 星际 1 里飞机飞过菌毯不会变快）。
## 高地：**不分阵营、不分空陆**，谁站上去谁受益。
func _refresh_terrain_flags() -> void:
	for u in units:
		if not u.alive():
			continue
		u.creep_boost = String(u.data.get("faction", "")) == "zerg" \
			and not u.is_flying() and grid.creep_at(u.pos)
		# 飞行单位不吃高地加成：它在空中，脚下的地形跟它没关系。
		# 少了这一条，一架低空飞过崖顶的飞机也会莫名其妙多出 24px 射程。
		u.on_high_ground = not u.is_flying() and grid.elev_at(u.pos) == 1

## 落在某个气矿上的（已完工）气矿建筑
func gas_building_on(geyser, require_complete: bool = true):
	if geyser == null:
		return null
	for b in buildings:
		if b.dead or b.gas_geyser == null:
			continue
		if int(b.gas_geyser.get("id", -1)) != int(geyser.get("id", -2)):
			continue
		if require_complete and not b.complete:
			continue
		return b
	return null

## 某个坐标附近的气矿节点（不管有没有开发过）
func gas_geyser_at(pos: Vector2):
	for r in resources:
		if String(r.get("kind", "")) != "gas":
			continue
		if pos.distance_to(r["pos"]) <= GAS_SNAP:
			return r
	return null

## 坐标附近「可开工」的气矿：还没有气矿建筑压在上面
func free_geyser_near(pos: Vector2):
	var best = null
	var bd := INF
	for r in resources:
		if String(r.get("kind", "")) != "gas" or r["amount"] <= 0.0:
			continue
		var d := pos.distance_to(r["pos"])
		if d <= GAS_SNAP and d < bd and gas_building_on(r, false) == null:
			bd = d
			best = r
	return best

func can_place_building(type_id: String, pos: Vector2, owner: int) -> Dictionary:
	var d := GameData.get_building(type_id)
	if d.is_empty():
		return {"ok": false, "reason": "无此建筑"}
	var f: Dictionary = factions[owner]
	if d.has("requires"):
		if not has_building(owner, String(d["requires"])):
			return {"ok": false, "reason": "需要先建造 " + String(GameData.get_building(String(d["requires"])).get("name", ""))}
	if f["minerals"] < float(d.get("cost_m", 0)) or f["gas"] < float(d.get("cost_g", 0)):
		return {"ok": false, "reason": "资源不足"}

	var is_gas_b := bool(d.get("gas_building", false))
	var sz := float(d.get("size", 28.0))
	var cw := maxi(1, int(ceil(sz / Grid.CELL)))
	var c := grid.world_to_cell(pos)
	var origin := Vector2i(c.x - cw / 2, c.y - cw / 2)
	# 占地检查
	var base_elev := grid.elev_at_cell(origin.x, origin.y)
	for y in range(origin.y, origin.y + cw):
		for x in range(origin.x, origin.x + cw):
			if not grid.in_bounds(x, y):
				return {"ok": false, "reason": "超出地图"}
			if grid.blocks[grid.idx(x, y)] != 0:
				return {"ok": false, "reason": "此处有障碍"}
			# 坡道是两层之间唯一的通路，拿建筑堵上就等于把高地封死。
			# 星际 1 里也禁止在坡道上建造。
			#
			# ⚠️ 这一条必须排在「跨悬崖」**之前**：坡道自己就横跨两层，
			#    先判高低差的话，任何建在坡道上的尝试都只会报「跨悬崖」，
			#    「不能建在坡道上」这条规则永远不会被触发（等于没写）。
			if grid.is_ramp_cell(x, y):
				return {"ok": false, "reason": "不能建在坡道上"}
			# 高低差：建筑必须**整体**落在同一层。
			# 跨着悬崖建会出现「一半在崖顶、一半在崖底」的建筑，
			# 它的射程该按哪一层算、视野该不该被挡住，都无从谈起。
			if grid.elev_at_cell(x, y) != base_elev:
				return {"ok": false, "reason": "不能跨悬崖建造"}
	# 菌毯硬约束：虫族建筑必须建在菌毯上。
	#
	# ⚠️ 两个豁免，缺任何一个都会让游戏**静默坏掉**：
	#   1. 虫巢 hive —— 它自己就是菌毯源，要求它建在菌毯上等于要求「先有鸡」。
	#   2. 气矿建筑（萃取房）—— 它只能压在气矿上，而气矿位置是地图定的，
	#      完全可能整片都不在菌毯内。不豁免的话 AI 永远开不出气，
	#      整条吃瓦斯的科技树直接死掉 —— 而且不报错，只会「莫名不出高级兵」。
	#
	# 判定用 owner 的 race 而不是建筑的 faction：语义是「你玩虫族，
	# 所以你的建筑得长在菌毯上」，和 Main 里神族画能量场用的是同一套判据。
	if String(f["race"]) == "zerg" and type_id != "hive" \
			and not bool(d.get("gas_building", false)):
		if not has_creep_at(pos):
			return {"ok": false, "reason": "必须建在菌毯上"}
	# 与已有建筑/资源保持距离
	for b in buildings:
		if b.pos.distance_to(pos) < sz * 0.5 + b.radius() + 6.0:
			return {"ok": false, "reason": "离其他建筑太近"}
	for r in resources:
		# 气矿建筑必须压在气矿上，所以不对气矿做「离矿点太近」的拦截
		if is_gas_b and String(r.get("kind", "")) == "gas":
			continue
		if r["pos"].distance_to(pos) < sz * 0.5 + 22.0:
			return {"ok": false, "reason": "离矿点太近"}
	# 必须靠近已有建筑（建造半径）
	var near_own := false
	for b in buildings_of(owner):
		if b.pos.distance_to(pos) < 190.0:
			near_own = true
			break
	if not near_own:
		return {"ok": false, "reason": "必须建在己方建筑附近"}

	# 神族的招牌机制：除了主基地，所有建筑都必须建在水晶塔的能量场内。
	# 这一条比上面的「建造半径」更严，所以实际约束是能量场。
	if String(factions[owner]["race"]) == "protoss" and type_id != "nexus":
		if not has_power_at(pos, owner):
			return {"ok": false, "reason": "必须在能量场内（先在水晶塔旁建）"}

	# 气矿建筑：必须正好压在一条气矿上，并且那条气矿还没被占用
	var geyser = null
	if is_gas_b:
		geyser = free_geyser_near(pos)
		if geyser == null:
			return {"ok": false, "reason": "必须建在未开发的气矿上"}

	return {"ok": true, "origin": origin, "cw": cw, "geyser": geyser}

func cmd_build(type_id: String, pos: Vector2, owner: int, workers: Array = [],
		auto_count: int = 1) -> bool:
	var chk := can_place_building(type_id, pos, owner)
	if not chk["ok"]:
		if owner == local_owner:
			event_alert.emit(pos, String(chk["reason"]), Color(1, 0.4, 0.35))
		return false
	var d := GameData.get_building(type_id)
	factions[owner]["minerals"] -= float(d.get("cost_m", 0))
	factions[owner]["gas"] -= float(d.get("cost_g", 0))
	var b := _place_building(type_id, String(factions[owner]["race"]), pos, owner, false)
	# 气矿建筑记下它占的是哪条气矿
	if bool(d.get("gas_building", false)) and chk.has("geyser"):
		b.gas_geyser = chk["geyser"]
		b.pos = b.gas_geyser["pos"]      # 吸附到气矿正上方

	# ---- 派工 ----
	# 规则（第八轮前哨改）：
	#   玩家选中了农民 → 派**这些**（选几个就几个去，和星际 1 一致）
	#   没选 / 选中的不是农民 → 自动挑 `auto_count` 个最近的（玩家侧恒为 1）
	# 「放一个建筑整队农民全跑过来」是 bug 不是特性，见 `_assigned_total()` 的注释。
	var chosen: Array = []
	for u in workers:
		if u is Unit and u.alive() and u.owner_id == owner and u.can_harvest():
			chosen.append(u)
	if chosen.is_empty():
		# 只从**手上没活**的农民里挑。已经在别的工地上的不能被抢走 ——
		# 抢人的话前一个工地会永久烂尾，而抢到人的工地也不会因此更快。
		var picked: Array = []
		for u in units:
			if not u.alive() or u.owner_id != owner or not u.can_harvest():
				continue
			if u.build_target != null:
				continue
			picked.append(u)
		picked.sort_custom(func(a, c): return a.pos.distance_squared_to(pos) < c.pos.distance_squared_to(pos))
		for i in range(mini(auto_count, picked.size())):
			chosen.append(picked[i])
	for w in chosen:
		_assign_builder(b, w)
	event_sfx.emit("build_start", pos)
	return true

## AI 建造时自动派几个农民。
## 大型建筑派 2 个 —— 建造速度是 `minf(2.0, 建造者数)`，2 个就够拿满。
## 以前 AI 靠「工地旁边采矿的农民被算进建造者」白拿这个加成，
## 改成只算被指派者之后必须显式补回来，否则 AI 的扩张节奏会整体变慢。
func _ai_builder_count(type_id: String) -> int:
	return 2 if float(GameData.get_building(type_id).get("build_time", 0.0)) >= 24.0 else 1

func cmd_train(building: Building, type_id: String) -> bool:
	var u := GameData.get_unit(type_id)
	if u.is_empty():
		return false
	var f: Dictionary = factions[building.owner_id]
	if building.queue.size() >= 5:
		return false
	var cost_m := float(u.get("cost_m", 0))
	var cost_g := float(u.get("cost_g", 0))
	if f["minerals"] < cost_m or f["gas"] < cost_g:
		if building.owner_id == local_owner:
			event_alert.emit(building.pos, "资源不足", Color(1, 0.6, 0.3))
		return false
	var supply := int(u.get("supply", 1))
	if f["supply_used"] + supply + _queued_supply(building.owner_id) > f["supply_cap"]:
		if building.owner_id == local_owner:
			event_alert.emit(building.pos, "人口不足，请建造补给建筑", Color(1, 0.6, 0.3))
		return false
	f["minerals"] -= cost_m
	f["gas"] -= cost_g
	return building.queue_unit(type_id)

func _queued_supply(owner: int) -> int:
	var n := 0
	for b in buildings:
		if b.owner_id != owner:
			continue
		for q in b.queue:
			n += int(GameData.get_unit(q["type_id"]).get("supply", 1))
	return n

## 取消生产队列中的一项，并全额返还资源（星际里取消生产也是全额退款）
func cancel_queue(building: Building, index: int) -> bool:
	if building == null:
		return false
	if index < 0 or index >= building.queue.size():
		return false
	var uid := String(building.queue[index]["type_id"])
	var d := GameData.get_unit(uid)
	if d.is_empty():
		# 队列条目可能是升级 —— 退款要按它入队时的**那一级**造价算，
		# 不能按 next_upgrade_cost（等级还没加，两者恰好相同，但语义不同）。
		d = GameData.get_building(uid)
	if d.is_empty():
		var lv := upgrade_level(building.owner_id, uid)
		var levels: Array = GameData.get_upgrade(uid).get("levels", [])
		if lv < levels.size():
			d = levels[lv]
	var f: Dictionary = factions[building.owner_id]
	f["minerals"] = float(f["minerals"]) + float(d.get("cost_m", 0))
	f["gas"] = float(f["gas"]) + float(d.get("cost_g", 0))
	building.queue.remove_at(index)
	return true

## 取消正在建造的建筑（未完工），返还已投入的资源
func cancel_build(building: Building) -> bool:
	if building == null or building.complete:
		return false
	var d := GameData.get_building(building.type_id)
	var f: Dictionary = factions[building.owner_id]
	f["minerals"] = float(f["minerals"]) + float(d.get("cost_m", 0))
	f["gas"] = float(f["gas"]) + float(d.get("cost_g", 0))
	building.dead = true
	_recount_supply(building.owner_id)
	return true

# ---------------------------------------------------------------- AI
func _update_ai(delta: float) -> void:
	if game_ended:
		return
	ai["wave_timer"] -= delta
	# 经济
	_ai_economy(delta)
	# 生产
	_ai_produce()
	# 科技
	_ai_research()
	# 技能
	_ai_use_abilities()
	# 驻防：定期把待命部队摆上高地。
	# 必须节流 —— 不节流的话每帧重新下命令，部队会原地反复重算路径、永远走不到。
	ai["hold_timer"] -= delta
	if ai["hold_timer"] <= 0.0:
		ai["hold_timer"] = 6.0
		_ai_hold_high_ground()
	# 进攻
	if ai["wave_timer"] <= 0.0:
		_ai_launch_wave()

## AI 研究科技。
##
## 这一步不能省：玩家能升攻防而 AI 不能的话，玩家升满后会碾压，
## 而 bal.gd 跑出来的平衡数据会「看起来没问题」—— 这是最隐蔽的一类错误。
func _ai_research() -> void:
	var f: Dictionary = factions[ENEMY]
	for b in buildings_of(ENEMY):
		if not b.alive() or not b.complete or b.queue.size() > 0:
			continue
		for uid in GameData.upgrades_for_building(b.type_id):
			var up := GameData.get_upgrade(uid)
			if String(up.get("faction", "")) != enemy_race:
				continue
			var lv := upgrade_level(ENEMY, uid)
			var levels: Array = up.get("levels", [])
			if lv >= levels.size():
				continue
			var cost: Dictionary = levels[lv]
			# 留 150 余粮：把出兵的钱全砸进科技，AI 会被自己的科技拖死。
			if float(f["minerals"]) < float(cost.get("cost_m", 0)) + 150.0:
				continue
			if float(f["gas"]) < float(cost.get("cost_g", 0)):
				continue
			if cmd_research(b, uid):
				return

## AI 用技能。不用的话，AI 手里的陆战队员和攻城坦克会明显弱于
## 玩家手里的同一种兵 —— 平衡测试又会失真。
func _ai_use_abilities() -> void:
	for u in units_of(ENEMY):
		if not u.alive() or u.abilities().is_empty():
			continue
		# 传 u 做能力过滤：附近只有空军时，狂热者不该嗑兴奋剂冲上去送。
		var e = find_nearest_enemy(u.pos, ENEMY, u.sight(), u)
		if e == null:
			continue
		if u.abilities().has("stim") and can_use_ability(u, "stim"):
			cmd_ability([u], "stim")
		if u.abilities().has("siege") and can_use_ability(u, "siege"):
			var d: float = u.pos.distance_to(e.pos)
			# 远距离展开、贴脸收起 —— 这正是攻城坦克的用法
			if u.mode == "normal" and d > 230.0:
				cmd_ability([u], "siege")
			elif u.mode == "sieged" and d < 110.0:
				cmd_ability([u], "siege")

func _ai_base() -> Vector2:
	return ai["base_center"]

## AI 当前的作战单位数量（不含农民）
func _ai_army_size() -> int:
	var n := 0
	for u in units_of(ENEMY):
		if u.alive() and not u.can_harvest():
			n += 1
	return n

## 玩家（AI 的对手）当前的作战单位数量
func _player_army_size() -> int:
	var n := 0
	for u in units_of(PLAYER):
		if u.alive() and not u.can_harvest():
			n += 1
	return n

func _ai_economy(delta: float) -> void:
	var econ_mult: float = ai["eco_mult"]
	var base = null
	for b in buildings_of(ENEMY):
		if b.data.get("dropoff", false):
			base = b
			break
	if base == null:
		return
	var worker_type := String(GameData.FACTIONS[enemy_race]["worker"])
	var n_workers := count_units(ENEMY, worker_type)

	# 农民目标数量随战局增长。一座基地的标准配置是 12~16 个农民：
	# 定得太低会陷入「矿不够 → 造不起兵 → 被推平」的死亡螺旋。
	var target_workers: int = mini(20, 12 + int(elapsed / 100.0))

	# 人口吃紧时优先造补给建筑，而不是继续堆农民
	var f: Dictionary = factions[ENEMY]
	var supply_tight: bool = (int(f["supply_cap"]) - int(f["supply_used"])) < 4
	# 农民和兵抢同一笔钱：兵力落后时继续补农民就是自杀。
	# 但反过来，开局就把矿全砸在兵上也不行——AI 会永远停在 3 个农民、
	# 收入上不来，然后被活活耗死。所以前 3 分钟是「经济期」，农民优先。
	var army_size := _ai_army_size()
	var want_army := int(5 * econ_mult) + int(elapsed / 26.0)
	# 对方兵力明显超过我们时，经济期立刻结束——再补农民就是送人头
	var threatened: bool = _player_army_size() > army_size + 2
	var economy_phase: bool = elapsed < 180.0 and not threatened
	var can_spare: bool = economy_phase or float(f["minerals"]) >= 200.0 or army_size >= want_army
	if n_workers < target_workers and base.queue.size() == 0 and not supply_tight and can_spare:
		cmd_train(base, worker_type)

	# 让空闲农民去挖矿（先保证采气的名额，再补矿工）
	var gas_b = null
	for b in buildings_of(ENEMY):
		if b.complete and not b.dead and b.gas_geyser != null:
			gas_b = b
			break
	if gas_b != null:
		var on_gas := 0
		var miners := []
		for u in units_of(ENEMY):
			if not u.can_harvest():
				continue
			if u.build_target != null:
				continue      # 在工地上干活的不能抽走
			if u.resource_target != null and String(u.resource_target.get("kind", "")) == "gas":
				on_gas += 1
			else:
				miners.append(u)
		# 采气名额：经济没起来之前，矿物远比瓦斯重要。
		# 早期把仅有的几个农民抽去采气会直接饿死经济（实测神族 AI 曾攒下 378 瓦斯、30 矿）。
		var total_w := miners.size() + on_gas
		var want_gas := 0
		if total_w >= 8:
			want_gas = clampi(int(round(float(total_w) / 5.0)), 1, 2)
		if float(f["minerals"]) < 80.0:
			want_gas = 0        # 矿物告急，全员回矿
		while on_gas < want_gas and miners.size() > 2:
			var gw = miners.pop_back()
			cmd_harvest([gw], gas_b.gas_geyser)
			on_gas += 1
		# 采气的人多了就撤回矿点
		if on_gas > want_gas:
			for u in units_of(ENEMY):
				if on_gas <= want_gas:
					break
				if u.can_harvest() and u.build_target == null and u.resource_target != null \
					and String(u.resource_target.get("kind", "")) == "gas":
					var back = _nearest_resource(u.pos)
					if back != null:
						cmd_harvest([u], back)
						on_gas -= 1

	for u in units_of(ENEMY):
		if u.can_harvest() and u.build_target == null and u.resource_target == null \
			and u.harvest_target == null and u.path.size() == 0 and not u.has_move_order:
			var node = _nearest_resource(u.pos)
			if node != null:
				cmd_harvest([u], node)

# AI 建造顺序：人口 → 气矿 → 科技 → 出兵（有数量上限，不做无意义铺建筑）
func _ai_produce() -> void:
	var f: Dictionary = factions[ENEMY]
	var menu: Array = GameData.BUILD_MENU[enemy_race]
	var sup_b := _ai_supply_building()
	var gas_b := _ai_gas_building()
	var aa_b := _ai_aa_building()

	# 人口：只在快满时补。补给建筑的门槛必须为 0——
	# 人口卡死等于全面停摆，这时候攒余粮是最蠢的选择。
	if f["supply_cap"] - f["supply_used"] < 3:
		if count_building(ENEMY, sup_b) < 6:
			if f["minerals"] >= float(GameData.get_building(sup_b).get("cost_m", 100)):
				if _ai_build(sup_b):
					return

	# 气矿：科技树里有吃瓦斯的建筑时，先把气开出来。
	# 一座基地只要一口井——多开的钱是从矿物经济里抠的，会把 AI 饿死。
	if gas_b != "" and _ai_needs_gas() and count_building(ENEMY, gas_b) < 1:
		var gd := GameData.get_building(gas_b)
		if f["minerals"] >= float(gd.get("cost_m", 0)) + 100.0:
			var g = _ai_pick_geyser()
			if g != null and cmd_build(gas_b, g["pos"], ENEMY, [], _ai_builder_count(gas_b)):
				return

	# 科技：按菜单顺序逐个补齐（基础军事建筑最多 2 座，其余 1 座）
	# 但经济没铺开时先别摊大饼——只有 6 个农民却去点高级科技，会直接把自己饿死。
	var mil_b := _mil_building_for(enemy_race)
	var n_workers := count_units(ENEMY, String(GameData.FACTIONS[enemy_race]["worker"]))
	var econ_ready := n_workers >= 8
	for entry in menu:
		var bid := String(entry["id"])
		if bid == sup_b or bid == gas_b or bid == aa_b:
			continue      # 防空建筑单独处理，见下面「防空」那一段
		var d := GameData.get_building(bid)
		var cap := 2 if bid == mil_b else 1
		if count_building(ENEMY, bid) >= cap:
			continue
		if not econ_ready and bid != mil_b:
			continue
		# 军事建筑是产能，门槛要低（+40）；高级科技是奢侈品，必须留足余粮（+150）
		var reserve := 0.0 if bid == mil_b else 150.0
		if f["minerals"] > float(d.get("cost_m", 0)) + reserve and f["gas"] >= float(d.get("cost_g", 0)):
			if _ai_build(bid):
				return

	# 防空：只在对方**真的有空军**时才造，最多 2 座。
	# 无脑造塔是「AI 看起来在做事、实际在空转」的典型 ——
	# 钱花在永远打不到人的建筑上，正面兵力就少了一截。
	if aa_b != "" and econ_ready and _enemy_air_count() > 0 \
			and count_building(ENEMY, aa_b) < 2:
		var ad := GameData.get_building(aa_b)
		if f["minerals"] > float(ad.get("cost_m", 0)) + 60.0 \
				and f["gas"] >= float(ad.get("cost_g", 0)):
			if _ai_build(aa_b):
				return

	# 出兵：有闲钱才屯兵，避免"只造建筑不出兵"
	var army_size := _ai_army_size()
	var want_army := int(5 * ai["eco_mult"]) + int(elapsed / 26.0)
	var reserve := 90.0 if army_size >= want_army else 0.0
	if army_size < want_army + 6:
		var built := _built_set(ENEMY)
		# 按造价从高到低逐个尝试，直到有一个真的造得起。
		# 只试「最贵的那个」会让神族这种高价兵种大量空转——
		# AI 每帧都在挑 350 矿的执政官，挑不起就直接放弃，于是一个兵都不出。
		for pick in _ai_unit_candidates(GameData.available_units(enemy_race, built)):
			var pu := GameData.get_unit(pick)
			if f["minerals"] < float(pu.get("cost_m", 0)) + reserve:
				continue
			if f["gas"] < float(pu.get("cost_g", 0)):
				continue
			for b in buildings_of(ENEMY):
				if b.queue.size() >= 2 or not b.complete:
					continue
				if not b.trains().has(pick):
					continue
				if cmd_train(b, pick):
					return

func _ai_pick_unit(opts: Array) -> String:
	var c := _ai_unit_candidates(opts)
	return String(c[0]) if not c.is_empty() else ""

## 作战单位候选列表：按造价从高到低（偏向更强的单位），
## 但保留一点随机性，免得每局都是同一套阵容。
func _ai_unit_candidates(opts: Array) -> Array:
	var fighters := []
	for o in opts:
		var d := GameData.get_unit(o)
		if String(d.get("role", "")) == "worker":
			continue
		fighters.append(o)
	fighters.sort_custom(func(a, b):
		var ca: float = float(GameData.get_unit(a).get("cost_m", 0)) + float(GameData.get_unit(a).get("cost_g", 0))
		var cb: float = float(GameData.get_unit(b).get("cost_m", 0)) + float(GameData.get_unit(b).get("cost_g", 0))
		return ca > cb)
	# 随机扰动放在**分层之前** —— 放到之后会把一个「打不到空中的兵」
	# 换到队首，分层就白做了。
	if fighters.size() > 1 and randf() < 0.35:
		var i := randi() % fighters.size()
		var tmp = fighters[0]
		fighters[0] = fighters[i]
		fighters[i] = tmp
	# 对方空军成规模时，把「打不到空中的兵」整体排到后面。
	# 不这么做的话，AI 会继续爆跳虫，然后眼睁睁看着它们被飞龙一口口吃掉 ——
	# 而它手里的刺蛇明明能还手。
	if _enemy_air_count() >= 3:
		var can_aa := []
		var cannot := []
		for o in fighters:
			if GameData.can_attack_air(o):
				can_aa.append(o)
			else:
				cannot.append(o)
		fighters = can_aa + cannot
	return fighters

func _ai_supply_building() -> String:
	return GameData.supply_building(enemy_race)

func _ai_gas_building() -> String:
	return GameData.gas_building(enemy_race)

func _ai_aa_building() -> String:
	return GameData.aa_building(enemy_race)

## 玩家（AI 的对手）场上有几个飞行单位。
## 防空建筑的建造决策、以及「该不该爆对空兵」都看它 ——
## 没有敌方空军时造塔，就是把出兵的钱花在永远打不到人的建筑上。
func _enemy_air_count() -> int:
	var n := 0
	for u in units_of(PLAYER):
		if u.is_flying():
			n += 1
	return n

## 本族的科技树里是否存在吃瓦斯的建筑——有的话 AI 就必须开气
func _ai_needs_gas() -> bool:
	for entry in GameData.BUILD_MENU.get(enemy_race, []):
		var d := GameData.get_building(String(entry["id"]))
		if float(d.get("cost_g", 0)) > 0.0:
			return true
	return false

## 离 AI 基地最近、还没被占用的气矿
func _ai_pick_geyser():
	var best = null
	var bd := INF
	for r in resources:
		if String(r.get("kind", "")) != "gas" or r["amount"] <= 0.0:
			continue
		if gas_building_on(r, false) != null:
			continue
		var d := _ai_base().distance_squared_to(r["pos"])
		if d < bd:
			bd = d
			best = r
	return best

func _built_set(owner: int) -> Dictionary:
	var s := {}
	for b in buildings:
		if b.alive() and b.owner_id == owner:
			s[b.type_id] = true
	return s

func _ai_build(type_id: String) -> bool:
	var d := GameData.get_building(type_id)
	if d.is_empty():
		return false
	var f: Dictionary = factions[ENEMY]
	if f["minerals"] < float(d.get("cost_m", 0)) + 30:
		return false
	if f["gas"] < float(d.get("cost_g", 0)):
		return false
	# 气矿建筑必须压在未开发的气矿上，随机撒点是撒不中的
	if bool(d.get("gas_building", false)):
		var g = _ai_pick_geyser()
		if g == null:
			return false
		if can_place_building(type_id, g["pos"], ENEMY)["ok"]:
			return cmd_build(type_id, g["pos"], ENEMY, [], _ai_builder_count(type_id))
		# 神族：气矿落在能量场外，先在气矿旁边立一座水晶塔
		if enemy_race == "protoss" and count_building(ENEMY, "pylon") < 8:
			return _ai_build_at("pylon", g["pos"])
		return false
	var center := _ai_base()
	# 神族的建筑必须落在能量场内，所以围着水晶塔找位置而不是围着基地中心
	if enemy_race == "protoss" and type_id != "pylon":
		var ps := power_sources(ENEMY)
		if not ps.is_empty():
			var best = ps[0]
			var bd := INF
			for b in ps:
				var dd: float = _ai_base().distance_squared_to(b.pos)
				if dd < bd:
					bd = dd
					best = b
			center = best.pos
	return _ai_build_at(type_id, center)

## 在指定中心附近找一个能放下建筑的点。
## 先随机撒点（位置自然），失败再改成同心圆系统搜索——
## 地形复杂时随机撒点命中率很低，光靠它会白白浪费资源。
## 搜索半径刻意压在 210 以内，保证神族的建筑不会跑出能量场。
func _ai_build_at(type_id: String, center: Vector2) -> bool:
	for attempt in range(16):
		var ang := randf() * TAU
		var rad := randf_range(60.0, 140.0)
		var p := center + Vector2(cos(ang), sin(ang)) * rad
		p = p.clamp(Vector2(60, 60), world_size - Vector2(60, 60))
		if can_place_building(type_id, p, ENEMY)["ok"]:
			return cmd_build(type_id, p, ENEMY, [], _ai_builder_count(type_id))
	for ring in range(1, 5):
		var rad2 := 55.0 + float(ring) * 32.0
		for i in range(24):
			var ang2: float = TAU * float(i) / 24.0 + float(ring) * 0.17
			var p2: Vector2 = center + Vector2(cos(ang2), sin(ang2)) * rad2
			p2 = p2.clamp(Vector2(60, 60), world_size - Vector2(60, 60))
			if can_place_building(type_id, p2, ENEMY)["ok"]:
				return cmd_build(type_id, p2, ENEMY, [], _ai_builder_count(type_id))
	return false

## 找离 from 最近的高地格（世界坐标）。找不到返回 Vector2.INF。
##
## 从 from 向外一圈圈扫，而不是遍历整张地图 —— 基地附近的高地才有驻防价值，
## 扫描半径给上限能顺带把「地图另一头的高地」排除掉。
func _nearest_high_ground(from: Vector2, max_dist: float) -> Vector2:
	var c := grid.world_to_cell(from)
	var rc := int(ceil(max_dist / Grid.CELL))
	var best := Vector2.INF
	var bd := INF
	for dy in range(-rc, rc + 1):
		var cy := c.y + dy
		if cy < 0 or cy >= grid.h:
			continue
		for dx in range(-rc, rc + 1):
			var cx := c.x + dx
			if cx < 0 or cx >= grid.w:
				continue
			if grid.elev_at_cell(cx, cy) != 1 or not grid.is_walkable_cell(cx, cy):
				continue
			var wp := grid.cell_to_world(Vector2i(cx, cy))
			var d := wp.distance_squared_to(from)
			if d < bd:
				bd = d
				best = wp
	return best

## 把待命中的防守部队摆到自家附近的高地上。
##
## 高地的价值是「低地打上来固定 miss 30%」+ 射程 +1 格 ——
## 守方站上去等于白拿一层减伤和一段先手距离。
##
## ⚠️ 只搬「已经空闲、没有任何命令」的作战单位。正在进攻、正在路上、
##    正在采矿的一律不动 —— 少了这道闸，AI 每次补兵都会把自己正在推进的
##    部队拉回高地，症状是「AI 的兵永远在基地里打转、不出门」。
func _ai_hold_high_ground() -> void:
	var spot := _nearest_high_ground(_ai_base(), AI_HOLD_RADIUS)
	if spot == Vector2.INF:
		return
	var i := 0
	for u in units_of(ENEMY):
		if u.can_harvest() or not u.is_combat() or u.is_flying():
			continue
		if u.attack_target != null or u.has_move_order or u.path.size() > 0:
			continue
		if grid.elev_at(u.pos) == 1:
			continue      # 已经在高地上，别折腾
		cmd_move([u], grid.scatter_slot(spot, i))
		i += 1

func _nearest_resource(from: Vector2):
	# 只找矿（不主动去碰未开发的气矿）
	var best = null
	var bd := INF
	for r in resources:
		if r["amount"] <= 0.0 or String(r.get("kind", "")) != "mineral":
			continue
		var d := from.distance_squared_to(r["pos"])
		if d < bd:
			bd = d
			best = r
	return best

func _ai_launch_wave() -> void:
	ai["wave_timer"] = ai["wave_interval"] * randf_range(0.85, 1.15)
	var fighters := []
	for u in units_of(ENEMY):
		if u.can_harvest():
			continue
		fighters.append(u)
	# 出兵门槛要克制：AI 兵少时应继续攒兵，而不是永远推迟导致一兵不出
	var need := maxi(3, int(3 * ai["eco_mult"]) + int(elapsed / 45.0))
	# 对方农民全灭 = 经济已经死了，此时有一兵就压上去收尾，别在角落里攒兵
	if count_units(PLAYER, String(GameData.FACTIONS[player_race]["worker"])) == 0:
		need = 1
	if fighters.size() < need:
		return
	# 如果连续多次因兵力不足推迟，就降低门槛发起进攻，保证压力持续存在
	ai["last_wave_size"] = fighters.size()
	var targets := buildings_of(PLAYER)
	if targets.is_empty():
		return
	var goal := _ai_base()
	var best_d := INF
	for b in targets:
		var d := _ai_base().distance_squared_to(b.pos)
		if d < best_d:
			best_d = d
			goal = b.pos
	# 有点策略：一半去打建筑，一半找兵
	var nearest_enemy_unit = null
	var nud := INF
	for u in units_of(PLAYER):
		var d2 := _ai_base().distance_squared_to(u.pos)
		if d2 < nud:
			nud = d2
			nearest_enemy_unit = u
	var dest := goal
	if nearest_enemy_unit != null and randf() < 0.5:
		dest = nearest_enemy_unit.pos
	for u in fighters:
		u.attack_to(dest + Vector2(randf_range(-40, 40), randf_range(-40, 40)))
	event_alert.emit(_ai_base(), "敌方部队来袭！", Color(1, 0.35, 0.35))

func _check_game_over() -> void:
	if game_ended:
		return
	var p_alive := buildings_of(PLAYER).size() > 0
	var e_alive := buildings_of(ENEMY).size() > 0
	if not e_alive:
		game_ended = true
		winner = PLAYER
		game_over.emit(PLAYER)
	elif not p_alive:
		game_ended = true
		winner = ENEMY
		game_over.emit(ENEMY)

## 主动认输。`who` 认输 → 对方获胜。
##
## ⚠️ 走的是和 `_check_game_over()` **同一条结算出口**（`game_ended` + `winner` +
##    `game_over` 信号），不是另开一个字段。否则「投降后界面显示赢了、
##    但世界还在跑」——因为各处读的是 `game_ended`。
func surrender(who: int) -> void:
	if game_ended:
		return
	game_ended = true
	winner = ENEMY if who == PLAYER else PLAYER
	game_over.emit(winner)

# ---------------------------------------------------------------- 僵局检测
## 一段时间内双方都没有任何实质变化（没人死、没建筑完工/被拆、没出兵），
## 就说明这局再也打不动了——按剩余资产定胜负，完全对等则平局。
##
## 没有这条的话对局会永远卡住：两个基地隔着地图，双方农民全灭、
## 矿又都不够 50 补农民，于是谁也打不到谁、谁也造不出东西，600 秒都不动一下。
const STALL_LIMIT := 150.0
var _stall_time := 0.0
var _stall_sig := ""
var _stall_hp := INF

## 双方剩余资产总值（用最大值，避免护盾回血干扰）
func assets_value(owner: int) -> float:
	var v := 0.0
	for u in units_of(owner):
		v += u.max_hp + u.max_shield
	for b in buildings_of(owner):
		v += b.max_hp
	return v

func _total_hp() -> float:
	var s := 0.0
	for u in units:
		if u.alive():
			s += u.hp + u.shield
	for b in buildings:
		if b.alive():
			s += b.hp
	return s

func _check_stall(delta: float) -> void:
	if game_ended:
		return
	var sig := "%d:%d:%d:%d" % [
		count_units(PLAYER), buildings_of(PLAYER).size(),
		count_units(ENEMY), buildings_of(ENEMY).size()]
	var hp_now := _total_hp()
	# 兵力/建筑数变了，或总血量掉了（挨打了）→ 战局仍在推进
	# 注意：护盾回血只会让血量上升，不会误判成「有事发生」
	if sig != _stall_sig or hp_now < _stall_hp - 1.0:
		_stall_sig = sig
		_stall_hp = hp_now
		_stall_time = 0.0
		return
	_stall_hp = minf(_stall_hp, hp_now)
	_stall_time += delta
	if _stall_time < STALL_LIMIT:
		return
	var pv := assets_value(PLAYER)
	var ev := assets_value(ENEMY)
	game_ended = true
	winner = -1 if absf(pv - ev) < 1.0 else (PLAYER if pv > ev else ENEMY)
	game_over.emit(winner)

# ---------------------------------------------------------------- 查询辅助
func find_entity_at(pos: Vector2, owner: int = -1):
	var fogged := owner < 0      # 玩家视角点击：需要过迷雾
	# 优先建筑
	for b in buildings:
		if not b.alive():
			continue
		if owner >= 0 and b.owner_id != owner:
			continue
		if fogged and b.owner_id != local_owner and not is_visible(b.pos):
			continue
		if pos.distance_to(b.pos) <= b.radius() + 4.0:
			return b
	var best = null
	var bd := INF
	for u in units:
		if not u.alive():
			continue
		if owner >= 0 and u.owner_id != owner:
			continue
		if fogged and u.owner_id != local_owner and not is_visible(u.pos):
			continue
		var d := pos.distance_to(u.pos)
		if d <= u.radius() + 14.0 and d < bd:
			bd = d
			best = u
	return best

func find_resource_at(pos: Vector2):
	for r in resources:
		if r["amount"] <= 0.0:
			continue
		# 没开发的气矿点不中：得先在上面盖精炼厂/萃取房/吸收塔
		if String(r.get("kind", "")) == "gas" and gas_building_on(r) == null:
			continue
		if pos.distance_to(r["pos"]) <= 22.0:
			return r
	return null

## 框选：返回矩形内的己方单位（敌方单位在星际争霸里不可选，因此不纳入）
func units_in_rect(rect: Rect2, owner: int) -> Array:
	var out := []
	for u in units:
		if u.alive() and u.owner_id == owner and rect.has_point(u.pos):
			out.append(u)
	return out

## 矩形内「本机当前看得见」的敌方单位，供渲染/小地图做威胁提示
func visible_enemies_in_rect(rect: Rect2) -> Array:
	var out := []
	for u in units:
		if u.dead or u.owner_id == local_owner:
			continue
		if rect.has_point(u.pos) and is_visible(u.pos):
			out.append(u)
	return out

func can_afford(owner: int, type_id: String) -> bool:
	var d := GameData.get_unit(type_id)
	if d.is_empty():
		d = GameData.get_building(type_id)
	if d.is_empty():
		# 既不是单位也不是建筑 → 当成升级 id，按「下一级」的造价算
		d = next_upgrade_cost(owner, type_id)
	var f: Dictionary = factions[owner]
	return f["minerals"] >= float(d.get("cost_m", 0)) and f["gas"] >= float(d.get("cost_g", 0))
