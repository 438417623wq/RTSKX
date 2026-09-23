extends SceneTree

## 地形高低差测试。
##
## 锁死四条铁律：
##   1. 高低地之间**只有坡道**能过 —— 寻路、平滑、落点分配都必须走 can_step()
##   2. 建筑必须整体落在同一层，且不能压在坡道上（坡道是唯一通路，堵上就封死高地）
##   3. 低地打高地固定 30% 打空，且**只对地面对地面**生效（飞行单位无视高低差）
##   4. 低地看不到高地，高地看低地一览无余（单向透明）
##
## ⚠️ 每条「做不到 X」的断言都必须配一条**阳性对照**。
##    「走不上高地」这条尤其危险：把整张地图封死也能让它通过。
##    所以下面成对出现：先证明「没坡道时上不去」，再证明「开了坡道就上得去」。

const RACES := ["terran", "zerg", "protoss"]

var _pass := 0
var _fail := 0

func _init() -> void:
	seed(20260924)
	print("\n=============== 地形高低差测试 ===============")
	_test_map_has_plateau()
	_test_cliff_blocks_ramp_allows()
	_test_sealed_plateau_unreachable()
	_test_ramp_opens_path()
	_test_path_never_crosses_cliff()
	_test_spawn_can_reach_plateau()
	_test_landing_keeps_layer()
	_test_separation_keeps_layer()
	print("  ---- 第二组：战斗与视野 ----")
	_test_uphill_flagged()
	_test_uphill_miss_rate()
	_test_flat_ground_never_misses()
	_test_air_ignores_elevation()
	_test_build_layer_rules()
	_test_vision_layer()
	_test_high_ground_bonus()
	print("  ---- 第三组：AI 高低差感知 ----")
	_test_ai_finds_high_ground()
	_test_ai_holds_high_ground()
	print("  ---- 第四组：地图预设 ----")
	_test_preset_open()
	_test_preset_river()
	_test_preset_all_connected()
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

# ================================================================ 工具

func _report(label: String, ok: bool, note: String = "") -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s  %s" % [label, note])
	else:
		_fail += 1
		print("  [FAIL] %s  %s" % [label, note])

## 一个干净的测试场：清空单位、关掉 AI 与胜负结算。
func _arena() -> World:
	var w := World.new(64, 40, "terran", "zerg", "easy")
	w.units.clear()
	w.game_ended = true
	return w

## 手工造一块高地。
##
## 刻意不用地图生成器 —— 平台位置会随地图改动漂移，断言跟着飘。
## 这里位置完全固定，测试和地图生成解耦。
## 同时把平台**下方**一路清到平地，保证测试用的低地落脚点不是岩石。
func _carve_plateau(w: World, center: Vector2i, r: int, with_ramp: bool) -> void:
	for y in range(center.y - r, center.y + r + 1):
		for x in range(center.x - r, center.x + r + 1):
			if not w.grid.in_bounds(x, y):
				continue
			w.grid.set_terrain(x, y, Grid.Terrain.GROUND)
			w.grid.set_elev(x, y, 1)
	# 平台外圈也清干净。
	# 不清的话，地图自带的岩石会让「跨悬崖建造」的断言变成「此处有障碍」——
	# 测试仍然 FAIL，但测到的是岩石而不是高低差规则，等于白测。
	for y in range(center.y - r - 3, center.y + r + 4):
		for x in range(center.x - r - 3, center.x + r + 4):
			if not w.grid.in_bounds(x, y):
				continue
			if w.grid.elev_at_cell(x, y) == 1:
				continue      # 别把平台自己清掉
			w.grid.set_terrain(x, y, Grid.Terrain.GROUND)
			w.grid.set_elev(x, y, 0)
	# 平台下方清一条走廊，作为「低地」测试区
	for y in range(center.y + r + 1, center.y + r + 9):
		for x in range(center.x - 2, center.x + 3):
			if w.grid.in_bounds(x, y):
				w.grid.set_terrain(x, y, Grid.Terrain.GROUND)
				w.grid.set_elev(x, y, 0)
	if with_ramp:
		# 在平台左边缘开一条坡道：靠里的那格算高地，靠外的那格算低地
		for dy in range(-1, 2):
			var x := center.x - r
			w.grid.set_terrain(x, center.y + dy, Grid.Terrain.RAMP)
			w.grid.set_elev(x, center.y + dy, 1)
			w.grid.set_terrain(x - 1, center.y + dy, Grid.Terrain.RAMP)
			w.grid.set_elev(x - 1, center.y + dy, 0)

## 找一对「相邻、不同层、都不是坡道」的格子 —— 也就是一条悬崖边。
## 返回 [Vector2i, Vector2i]，找不到返回 []。
func _find_cliff_pair(w: World) -> Array:
	for y in range(w.grid.h):
		for x in range(w.grid.w):
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nx := x + d.x
				var ny := y + d.y
				if not w.grid.in_bounds(nx, ny):
					continue
				if w.grid.elev_at_cell(x, y) == w.grid.elev_at_cell(nx, ny):
					continue
				if w.grid.is_ramp_cell(x, y) or w.grid.is_ramp_cell(nx, ny):
					continue
				return [Vector2i(x, y), Vector2i(nx, ny)]
	return []

## 造一发弹道字典。只填 _impact 真正会读的字段。
func _proj(dmg: float, uphill: bool, faction: String = "terran") -> Dictionary:
	return {
		"pos": Vector2.ZERO, "dmg": dmg, "dtype": "normal",
		"faction": faction, "kind": "bullet", "color": Color.WHITE,
		"atk_bonus": 0, "uphill": uphill,
	}

## 统计「打空率」：反复结算同一发弹道，看目标掉不掉血。
## 每轮把血补满，避免把目标打死导致后面的统计失真。
func _miss_rate(w: World, shooter_pos: Vector2, target, uphill: bool, trials: int = 800) -> float:
	var hits := 0
	for i in range(trials):
		target.hp = target.max_hp
		var before: float = target.hp
		var p := _proj(10.0, uphill)
		p["pos"] = target.pos
		w._impact(p, target)
		if target.hp < before:
			hits += 1
	return float(trials - hits) / float(trials)

# ================================================================ 第一组：网格与寻路

func _test_map_has_plateau() -> void:
	var w := _arena()
	var high := 0
	var ramps := 0
	for i in range(w.grid.w * w.grid.h):
		if w.grid.elev[i] == 1:
			high += 1
		if w.grid.ramp[i] != 0:
			ramps += 1
	_report("地图生成器产出了高地", high >= 40, "高地格数 = %d" % high)
	# 两块平台各两条坡道，每条两格长三格宽 = 12 格 → 至少 24 格
	_report("地图生成器产出了坡道", ramps >= 20, "坡道格数 = %d" % ramps)

func _test_cliff_blocks_ramp_allows() -> void:
	var w := _arena()
	var pair := _find_cliff_pair(w)
	if pair.is_empty():
		_report("地图上存在悬崖边", false, "一处都没找到")
		return
	var a: Vector2i = pair[0]
	var b: Vector2i = pair[1]
	_report("悬崖边不可跨越", not w.grid.can_step(a.x, a.y, b.x, b.y),
		"%s(e%d) → %s(e%d)" % [str(a), w.grid.elev_at_cell(a.x, a.y),
			str(b), w.grid.elev_at_cell(b.x, b.y)])
	# 阳性对照：把其中一格改成坡道，同一条边必须立刻放行
	w.grid.set_terrain(b.x, b.y, Grid.Terrain.RAMP)
	_report("改成坡道后同一条边放行（阳性对照）",
		w.grid.can_step(a.x, a.y, b.x, b.y), "%s 现在是坡道" % str(b))

func _test_sealed_plateau_unreachable() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var low := w.grid.cell_to_world(Vector2i(center.x, center.y + 6))
	var high := w.grid.cell_to_world(center)
	var path := w.grid.find_path(low, high)
	_report("没有坡道时低地走不上高地", path.size() == 0, "路径点数 = %d" % path.size())
	# 平滑也不能把「绕过去」变成「直接爬上去」—— 拿一条穿过崖壁的直线去试
	_report("直线畅通判定不会放行穿崖的线",
		not w.grid._clear_line(low, high), "低地 → 高地")

func _test_ramp_opens_path() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, true)
	var low := w.grid.cell_to_world(Vector2i(center.x, center.y + 6))
	var high := w.grid.cell_to_world(center)
	var path := w.grid.find_path(low, high)
	_report("开了坡道后低地能走上高地（阳性对照）", path.size() > 0,
		"路径点数 = %d" % path.size())
	# 而且路径必须真的踩到坡道 —— 只判「路径非空」的话，
	# 地图上别处刚好有别的通路时这条断言会假通过
	var touched_ramp := false
	for p in path:
		var c := w.grid.world_to_cell(p)
		if w.grid.is_ramp_cell(c.x, c.y):
			touched_ramp = true
			break
	_report("这条路径确实经过了坡道", touched_ramp, "路径 = %s" % str(path))

func _test_path_never_crosses_cliff() -> void:
	# 在真实地图上随机抽若干「低地 → 高地」的点对，逐段检查路径合法性。
	# 只检查端点是不够的 —— 中间某一步穿崖才是最典型的 bug。
	var w := _arena()
	var lows := []
	var highs := []
	for i in range(w.grid.w * w.grid.h):
		var c := Vector2i(i % w.grid.w, i / w.grid.w)
		if w.grid.blocks[i] != 0:
			continue
		if w.grid.elev[i] == 1:
			highs.append(c)
		else:
			lows.append(c)
	if highs.is_empty() or lows.is_empty():
		_report("地图上高低地都有", false, "高地 %d / 低地 %d" % [highs.size(), lows.size()])
		return
	var bad := 0
	var found := 0
	for k in range(24):
		var a: Vector2i = lows[(k * 977) % lows.size()]
		var b: Vector2i = highs[(k * 613) % highs.size()]
		var path := w.grid.find_path(w.grid.cell_to_world(a), w.grid.cell_to_world(b))
		if path.is_empty():
			continue
		found += 1
		var prev := a
		for p in path:
			var c := w.grid.world_to_cell(p)
			if c != prev and not w.grid.can_step(prev.x, prev.y, c.x, c.y):
				bad += 1
				break
			prev = c
	_report("真实地图上的跨层路径每一步都合法", bad == 0 and found > 0,
		"抽查 %d 条（成功 %d 条），违规 %d 条" % [24, found, bad])

func _test_spawn_can_reach_plateau() -> void:
	# 生成器漏开坡道的话，那块高地就是纯装饰 —— 而且不会有任何报错。
	# 这条断言是「坡道口被岩石堵死」这个坑的唯一防线。
	var w := World.new(64, 40, "terran", "zerg", "easy")
	var base: Vector2 = w.buildings_of(World.PLAYER)[0].pos
	var high_cells := []
	for i in range(w.grid.w * w.grid.h):
		if w.grid.elev[i] == 1:
			high_cells.append(Vector2i(i % w.grid.w, i / w.grid.w))
	if high_cells.is_empty():
		_report("地图上有高地可走", false, "一块高地都没有")
		return
	var ok := 0
	# 只抽查 8 个高地格：只要有一个走得通，这块平台就是可达的
	for k in range(8):
		var c: Vector2i = high_cells[(k * 331) % high_cells.size()]
		if w.grid.find_path(base, w.grid.cell_to_world(c)).size() > 0:
			ok += 1
	_report("出生点能走到高地（坡道没被堵死）", ok > 0, "抽查 8 个高地格，可达 %d 个" % ok)

func _test_landing_keeps_layer() -> void:
	# 落点分配不能把低地单位扔到高地上 —— 那块高地可能没有坡道下来。
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var low := w.grid.cell_to_world(Vector2i(center.x, center.y + 6))
	var bad := 0
	for i in range(16):
		var slot := w.grid.scatter_slot(low, i, 30.0)
		if w.grid.elev_at(slot) != 0:
			bad += 1
	_report("落点分配不会把低地单位扔上高地", bad == 0, "16 个落点中越层 %d 个" % bad)

## 互相挤开（_separate）不能把单位挤到另一层。
##
## 这是一个真 bug：_separate 原本用 is_walkable_world 判落点，只检查「不挡路」，
## 不检查层。结果崖底一队兵互相挤几下，就有一个被推上崖顶 ——
## 画面上像瞬移，而且它会白拿高地那 30% 的闪避优势。
func _test_separation_keeps_layer() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	# ⚠️ 必须**竖直叠一列**，让下面的人把最上面那个往正上方顶。
	#    第一版摆了 3x2 的一坨，推挤互相抵消，最上面那个纹丝不动 ——
	#    断言照样 PASS，但根本没测到东西（假通过）。
	#    把旧代码改回去验过：那一版不会 FAIL，这一版会。
	var cliff_base := w.grid.cell_to_world(Vector2i(center.x, center.y + 4))
	var crew := []
	for i in range(5):
		crew.append(w._spawn_unit("marine", "terran",
			cliff_base + Vector2(0.0, float(i) * 4.0), World.PLAYER))
	for step in range(90):
		w._rebuild_hash()
		for u in crew:
			if u.alive():
				w._separate(u, 1.0 / 60.0)
	var bad := 0
	for u in crew:
		if w.grid.elev_at(u.pos) != 0:
			bad += 1
	_report("互相挤开不会把单位挤到另一层", bad == 0,
		"5 个兵竖叠 90 帧后越层 %d 个" % bad)

# ================================================================ 第二组：战斗与视野

func _test_uphill_flagged() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var low := w.grid.cell_to_world(Vector2i(center.x, center.y + 6))
	var high := w.grid.cell_to_world(center)
	var shooter = w._spawn_unit("marine", "terran", low, World.PLAYER)
	var target = w._spawn_unit("marine", "terran", high, World.ENEMY)
	_report("低打高被判为上坡", w._is_uphill(shooter, target), "低 → 高")
	_report("高打低不被判为上坡", not w._is_uphill(target, shooter), "高 → 低")

func _test_uphill_miss_rate() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var high := w.grid.cell_to_world(center)
	var target = w._spawn_unit("marine", "terran", high, World.ENEMY)
	var rate := _miss_rate(w, high, target, true)
	# 800 发、p=0.3 的标准差约 1.6%，±6% 是 3.7 个标准差，足够稳
	_report("低地打高地约 30% 打空", absf(rate - 0.30) < 0.06,
		"实测打空 %.1f%%（%d 发）" % [rate * 100.0, 800])

func _test_flat_ground_never_misses() -> void:
	# 阳性对照：同样的弹道，只是 uphill = false，必须一发不空。
	# 少了这条，「30% 打空」的断言可能只是「伤害计算坏了」的副作用。
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var high := w.grid.cell_to_world(center)
	var target = w._spawn_unit("marine", "terran", high, World.ENEMY)
	var rate := _miss_rate(w, high, target, false)
	_report("平地射击一发不空（阳性对照）", rate == 0.0, "实测打空 %.1f%%" % (rate * 100.0))

func _test_air_ignores_elevation() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var low := w.grid.cell_to_world(Vector2i(center.x, center.y + 6))
	var high := w.grid.cell_to_world(center)
	var ground = w._spawn_unit("marine", "terran", low, World.PLAYER)
	var flyer = w._spawn_unit("mutalisk", "zerg", low, World.PLAYER)
	var ground_target = w._spawn_unit("marine", "terran", high, World.ENEMY)
	var air_target = w._spawn_unit("wraith", "terran", high, World.ENEMY)
	_report("飞机从低处打高处不算上坡", not w._is_uphill(flyer, ground_target), "飞机 → 崖顶")
	_report("打高处的飞机不算上坡", not w._is_uphill(ground, air_target), "低地 → 天上的飞机")

func _test_build_layer_rules() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, true)
	# 在平台下方放一座主基地，满足「必须建在己方建筑附近」的前置条件。
	# 位置要卡得近一点：建造半径是 190px，放远了后面几条断言会先撞上
	# 「必须建在己方建筑附近」，测不到高低差规则本身。
	var cc_pos := w.grid.cell_to_world(Vector2i(center.x, center.y + 5))
	w._place_building("command_center", "terran", cc_pos, World.PLAYER, true)

	# ⚠️ 必须挑一个 size > 24 的建筑（cw ≥ 2 格）。
	#    补给站 size 22 → 只占 1 格，**永远跨不了悬崖**，
	#    用它测「跨悬崖被拒」会一直通过 —— 但通过的原因是「根本跨不了」。
	#    兵营 size 28 → 2x2 格，才真的能压在边界上。
	# ① 跨着悬崖建：把它的右下角压到平台外面
	var straddle := w.grid.cell_to_world(Vector2i(center.x + 4, center.y + 1))
	var chk1 := w.can_place_building("barracks", straddle, World.PLAYER)
	_report("跨悬崖建造被拒", not bool(chk1["ok"]) and String(chk1["reason"]).contains("悬崖"),
		"理由 = %s" % String(chk1.get("reason", "")))

	# ② 建在坡道上：坡道是两层之间唯一的通路，堵上等于把高地封死
	var ramp_cell := Vector2i(center.x - 4, center.y)
	var on_ramp := w.grid.cell_to_world(ramp_cell)
	var chk2 := w.can_place_building("barracks", on_ramp, World.PLAYER)
	_report("建在坡道上被拒", not bool(chk2["ok"]) and String(chk2["reason"]).contains("坡道"),
		"理由 = %s" % String(chk2.get("reason", "")))

	# ③ 阳性对照：平台正中央必须能建 —— 否则前两条可能只是「什么都建不了」
	var on_top := w.grid.cell_to_world(Vector2i(center.x + 1, center.y - 1))
	var chk3 := w.can_place_building("barracks", on_top, World.PLAYER)
	_report("高地上正常建造（阳性对照）", bool(chk3["ok"]),
		"理由 = %s" % String(chk3.get("reason", "")))

func _test_vision_layer() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var high := w.grid.cell_to_world(center)
	var low := w.grid.cell_to_world(Vector2i(center.x, center.y + 6))
	var u = w._spawn_unit("marine", "terran", low, World.PLAYER)
	w.update_visibility()
	_report("低地看不到高地", not w.is_visible(high),
		"高地可见 = %s" % str(w.is_visible(high)))
	_report("低地能看到自己附近的低地（阳性对照）",
		w.is_visible(low + Vector2(0, 40)), "同层邻格")
	# 把同一个单位搬上崖顶：立刻变成「看得见低地」
	u.pos = high
	w.update_visibility()
	_report("站上高地后能看到低地（单向透明）", w.is_visible(low),
		"低地可见 = %s" % str(w.is_visible(low)))
	_report("高地上仍然看得见高地", w.is_visible(high + Vector2(30, 0)), "同层邻格")

func _test_high_ground_bonus() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var on_high := w.grid.cell_to_world(center)
	var low := w.grid.cell_to_world(Vector2i(center.x, center.y + 5))
	var u_hi = w._spawn_unit("marine", "terran", on_high, World.PLAYER)
	var u_lo = w._spawn_unit("marine", "terran", low, World.PLAYER)
	var u_air = w._spawn_unit("wraith", "terran", on_high, World.PLAYER)
	w._refresh_terrain_flags()
	var s_base := float(GameData.get_unit("marine")["sight"])
	var r_base := float(GameData.get_unit("marine")["range"])
	_report("高地单位视野 +1 格",
		u_hi.on_high_ground \
			and absf(u_hi.sight() - (s_base + GameData.HIGH_GROUND_SIGHT_BONUS)) < 0.01,
		"视野 %.0f → %.0f" % [s_base, u_hi.sight()])
	_report("高地单位射程 +1 格",
		absf(u_hi.attack_range() - (r_base + GameData.HIGH_GROUND_RANGE_BONUS)) < 0.01,
		"射程 %.0f → %.0f" % [r_base, u_hi.attack_range()])
	# 阳性对照：少了这条，「+24」可能只是「所有单位都 +24」的副作用。
	_report("平地单位视野 / 射程不加成（阳性对照）",
		not u_lo.on_high_ground and absf(u_lo.sight() - s_base) < 0.01 \
			and absf(u_lo.attack_range() - r_base) < 0.01,
		"视野 %.0f / 射程 %.0f（基准 %.0f / %.0f）"
			% [u_lo.sight(), u_lo.attack_range(), s_base, r_base])
	# 空军豁免：飞机在崖顶上空飞过，脚下的地形跟它没关系。
	_report("飞行单位站在高地上也不加成（它在空中）",
		not u_air.on_high_ground and u_air.is_flying(),
		"is_flying = %s，on_high_ground = %s" % [u_air.is_flying(), u_air.on_high_ground])

# ================================================================ 第三组：AI 高低差感知

func _test_ai_finds_high_ground() -> void:
	var w := _arena()
	var center := Vector2i(30, 20)
	_carve_plateau(w, center, 3, false)
	var hg := w._nearest_high_ground(w.grid.cell_to_world(center), 320.0)
	_report("AI 能找到附近的高地（驻防用）",
		hg != Vector2.INF and w.grid.elev_at(hg) == 1,
		"找到 = %s" % str(hg))
	# 阳性对照：地图角落附近 60px 内不该有高地 ——
	# 少了这条，「找得到」可能只是「它把任意一格都当高地返回了」。
	var far := w._nearest_high_ground(w.grid.cell_to_world(Vector2i(2, 2)), 60.0)
	_report("附近没有高地时返回 INF（阳性对照）", far == Vector2.INF,
		"找到 = %s" % str(far))
	# 真实地图上：基地到最近高地的距离必须落在驻防搜索半径内。
	# ⚠️ 这条是防「静默失效」的 —— 地图生成一改、平台挪远一点，
	#    AI 就会永远找不到高地可守，而且不会有任何报错。
	var ai_base := Vector2((w.map_w - 6) * Grid.CELL, w.map_h * 0.5 * Grid.CELL)
	var real := w._nearest_high_ground(ai_base, World.AI_HOLD_RADIUS)
	_report("真实地图的高地落在 AI 驻防半径内", real != Vector2.INF,
		"距 AI 基地 %.0fpx（半径 %.0f）"
			% [ai_base.distance_to(real) if real != Vector2.INF else -1.0, World.AI_HOLD_RADIUS])

## AI 真的会把待命部队派上高地。
##
## 直接调 `_ai_hold_high_ground()` 而不是端到端跑一局 —— 跑一局的话
## 「有兵站在高地上」可能只是碰巧路过，断言会假通过。
func _test_ai_holds_high_ground() -> void:
	var w := _arena()
	var ai_base := Vector2((w.map_w - 6) * Grid.CELL, w.map_h * 0.5 * Grid.CELL)
	# 手工在 AI 基地旁造一块高地，不依赖地图生成器的落点
	var c := w.grid.world_to_cell(ai_base + Vector2(-260, 0))
	for y in range(c.y - 3, c.y + 4):
		for x in range(c.x - 3, c.x + 4):
			if not w.grid.in_bounds(x, y):
				continue
			w.grid.set_terrain(x, y, Grid.Terrain.GROUND)
			w.grid.set_elev(x, y, 1)
	# 三个「待命」的兵：不采矿、没有命令
	var crew := []
	for i in range(3):
		crew.append(w._spawn_unit("zergling", "zerg",
			ai_base + Vector2(-70, float(i) * 24.0 - 24.0), World.ENEMY))
	w._ai_hold_high_ground()
	var moving := 0
	for u in crew:
		if u.has_move_order or u.path.size() > 0:
			moving += 1
	_report("AI 会把待命部队派上高地", moving > 0,
		"3 个待命兵中 %d 个被派往高地" % moving)
	# 阳性对照：已经站在高地上的兵不该被反复派走。
	# 少了这条闸，AI 每 6 秒就把部队重新下令一次，它们会在高地边缘原地打转。
	for u in crew:
		u.pos = w.grid.cell_to_world(c)
		u.has_move_order = false
		u.path = PackedVector2Array()
	w._ai_hold_high_ground()
	var again := 0
	for u in crew:
		if u.has_move_order or u.path.size() > 0:
			again += 1
	_report("已在高地上的部队不会被反复派走（阳性对照）", again == 0,
		"3 个已在高地上的兵中 %d 个被重新下令" % again)

# ================================================================ 第四组：地图预设

## 统计整张图上属于某个地形 / 高度层的格子数。
func _count_cells(w: World, terrain: int) -> int:
	var n := 0
	for i in range(w.grid.cells.size()):
		if w.grid.cells[i] == terrain:
			n += 1
	return n

func _count_elev(w: World, e: int) -> int:
	var n := 0
	for i in range(w.grid.elev.size()):
		if w.grid.elev[i] == e:
			n += 1
	return n

## 开阔平原：**一块高地都不该有**。
##
## ⚠️ 必须配阳性对照（plateau 预设必须真的有高地），否则「一块高地都没有」
##    这条断言在「地图生成整个坏掉、什么都没生成」时也会通过。
func _test_preset_open() -> void:
	var wo := World.new(64, 40, "terran", "zerg", "easy", "open")
	var hi_open := _count_elev(wo, 1)
	_report("开阔平原没有任何高地", hi_open == 0, "高地格 %d" % hi_open)
	var wp := World.new(64, 40, "terran", "zerg", "easy", "plateau")
	var hi_pl := _count_elev(wp, 1)
	_report("阳性对照：双坡道高地确实有高地", hi_pl > 0, "高地格 %d" % hi_pl)
	# 没有高地 → AI 驻防高地必须安全地「什么都不做」，不能崩也不能乱派人。
	var spot := wo._nearest_high_ground(wo.world_size * 0.5, World.AI_HOLD_RADIUS)
	_report("开阔平原上 AI 找不到高地 → 驻防逻辑静默跳过", spot == Vector2.INF,
		"返回 %s" % ("INF" if spot == Vector2.INF else str(spot)))

## 中间河道：真的有河道，且**三座桥都通**。
func _test_preset_river() -> void:
	var w := World.new(64, 40, "terran", "zerg", "easy", "river")
	var chasm := _count_cells(w, Grid.Terrain.CHASM)
	_report("中间河道确实有深渊带", chasm > 0, "深渊格 %d" % chasm)
	# 河道必须是**竖贯**的：横贯的话两个左右分居的出生点根本不相见。
	# 判据：存在某一列，其上的深渊格数接近满高。
	var cx := w.map_w / 2
	var col := 0
	for y in range(w.grid.h):
		if w.grid.cells[y * w.grid.w + cx] == Grid.Terrain.CHASM:
			col += 1
	_report("河道竖贯地图（中轴列几乎全是深渊）", col >= w.grid.h - 12,
		"中轴列 %d/%d 格是深渊" % [col, w.grid.h])

## 三张图都必须**从己方基地走得到敌方基地**。
##
## ⚠️ 这是整套地图预设里最重要的一条。河道 / 岩带 / 高地是**不可通行**的地形，
##    任何一处把通路堵死，就会变成「两岸孤岛」—— 玩家推不过去、AI 也推不过来，
##    而且**不会有任何报错**，只是两边各自憋着造兵，对局永远打不完。
##    （坡道口被岩石压住是同一类坑，见 _make_plateau 里的注释。）
func _test_preset_all_connected() -> void:
	var names := {"open": "开阔平原", "plateau": "双坡道高地", "river": "中间河道"}
	for key in ["open", "plateau", "river"]:
		var w := World.new(64, 40, "terran", "zerg", "easy", String(key))
		var pb: Vector2 = w.buildings_of(World.PLAYER)[0].pos
		var eb: Vector2 = w.buildings_of(World.ENEMY)[0].pos
		var p: PackedVector2Array = w.grid.find_path(pb, eb)
		_report("%s：己方基地走得到敌方基地" % String(names[key]), p.size() > 0,
			"路径 %d 个点" % p.size())
	# 阳性对照：把河道预设的中轴整列封死，路径必须断掉。
	# 少了这条，「三张图都通」可能只是因为 find_path 根本不看障碍。
	var w2 := World.new(64, 40, "terran", "zerg", "easy", "river")
	var cx2 := w2.map_w / 2
	for y in range(w2.grid.h):
		for dx in range(-3, 4):
			w2.grid.set_terrain(cx2 + dx, y, Grid.Terrain.CHASM)
	var pb2: Vector2 = w2.buildings_of(World.PLAYER)[0].pos
	var eb2: Vector2 = w2.buildings_of(World.ENEMY)[0].pos
	var p2: PackedVector2Array = w2.grid.find_path(pb2, eb2)
	_report("阳性对照：整列封死后两岸不通", p2.size() == 0,
		"路径 %d 个点" % p2.size())
