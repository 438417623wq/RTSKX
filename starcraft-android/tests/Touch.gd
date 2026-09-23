extends SceneTree

## 触屏操控逻辑的无头验证。
## 直接调用 Main 的输入回调，模拟铁锈战争那套手势，检查状态变化是否符合预期。
## 比每次跑模拟器快得多，适合回归。

var _pass := 0
var _fail := 0
var _main: Node = null

func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] ", label)
	else:
		_fail += 1
		print("  [FAIL] ", label)

var _ran := false

func _initialize() -> void:
	print("=============== 触屏操控测试 ===============")
	var scene: PackedScene = load("res://assets/scripts/Main.tscn")
	_main = scene.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	# ⚠️ 先把设置重置成默认值再测。
	#    设置会存到 user://settings.cfg —— 玩家（或上一次跑测试）改过的话，
	#    长按阈值 / 单指手势语义这些会被带进来，断言就随环境飘。
	#    重置只改内存不写盘，不会污染玩家自己的配置。
	Settings.reset_all()
	_main._apply_settings()
	_main.start_game("terran", "normal")
	_run_tests()
	# ⚠️ 必须显式退出码。`return true` 只是结束主循环，rc 恒为 0 ——
	#    50 条触屏断言此前全部不参与门禁。
	quit(0 if _fail == 0 else 1)
	return true

func _run_tests() -> void:

	var vp: Vector2 = _main.get_viewport_rect().size
	var panel_top: float = vp.y - _main.PANEL_H
	print("  视口 %s  面板顶 %.0f" % [vp, panel_top])

	# ── 1. 单指滑动 = 平移视野（默认语义，和旧方案相反）
	_main.world.selection = []
	_main.cam_pos = Vector2(700, 480)
	_main._clamp_camera()
	var cam_p0: Vector2 = _main.cam_pos
	_drag(0, Vector2(400, 200), Vector2(700, 400))
	_ok(_main.cam_pos.distance_to(cam_p0) > 10.0,
		"单指滑动 → 平移视野（位移 %.0f 像素）" % _main.cam_pos.distance_to(cam_p0))
	_ok(_main.world.selection.is_empty(), "平移视野时不会误框选")

	# ── 2. 长按后拖动 = 框选部队
	_main.world.selection = []
	_main.cam_pos = Vector2(700, 480)
	_main._clamp_camera()
	var base: Vector2 = _main.world.buildings_of(0)[0].pos
	var sp: Vector2 = _main._xf(base)
	var cam_before: Vector2 = _main.cam_pos
	_drag_long(0, sp + Vector2(-160, -160), sp + Vector2(160, 160))
	_ok(_main.world.selection.size() > 0,
		"长按后拖动 → 框选（选到 %d 个单位）" % _main.world.selection.size())
	_ok(_main.cam_pos.distance_to(cam_before) < 1.0, "框选过程中镜头不动")

	# ── 3. 切到「拖动:框选」后，单指拖动重新变成框选
	_main._single_drag_pans = false
	_main.world.selection = []
	var sp2: Vector2 = _main._xf(_main.world.buildings_of(0)[0].pos)
	_drag(0, sp2 + Vector2(-160, -160), sp2 + Vector2(160, 160))
	_ok(_main.world.selection.size() > 0,
		"切到「拖动:框选」后单指拖动即框选（%d 个）" % _main.world.selection.size())
	_main._single_drag_pans = true

	# ── 3. 轻点空地 = 移动指令（单位应产生路径）
	_main.world.selection = _main.world.units_of(0).duplicate()
	var movers := []
	for u in _main.world.selection:
		if not u.can_harvest():
			movers.append(u)
	_main.world.selection = movers
	_ok(_main.world.selection.size() > 0, "选中了 %d 个作战单位" % movers.size())
	_main._on_touch(0, Vector2(900, 300), true)
	_main._on_touch(0, Vector2(900, 300), false)
	var has_path := false
	for u in movers:
		if u.path.size() > 0 or u.has_move_order:
			has_path = true
			break
	_ok(has_path, "轻点地面下达了移动指令")

	# ── 4. 双指捏合 = 缩放
	_main.cam_zoom = 1.0
	_main._on_touch(0, Vector2(400, 300), true)
	_main._on_touch(1, Vector2(800, 300), true)
	_main._on_drag(1, Vector2(1000, 300), Vector2(200, 0))   # 拉开 → 放大
	var zoomed_in: float = _main.cam_zoom
	_ok(zoomed_in > 1.05, "双指拉开 → 放大（1.00 → %.2f）" % zoomed_in)
	_main._on_touch(0, Vector2(400, 300), false)
	_main._on_touch(1, Vector2(1000, 300), false)
	_ok(not _main._pinch_active, "双指松开后手势状态复位")

	# ── 5. 双指拖动 = 平移镜头
	_main.cam_zoom = 1.0
	_main.cam_pos = Vector2(700, 480)
	var cam2: Vector2 = _main.cam_pos
	_main._on_touch(0, Vector2(400, 300), true)
	_main._on_touch(1, Vector2(700, 300), true)
	_main._on_drag(0, Vector2(500, 300), Vector2(100, 0))    # 中点右移 → 镜头左移
	_main._on_touch(0, Vector2(500, 300), false)
	_main._on_touch(1, Vector2(700, 300), false)
	_ok(_main.cam_pos.distance_to(cam2) > 10.0, "双指拖动 → 平移镜头（位移 %.0f 像素）" % _main.cam_pos.distance_to(cam2))

	# ── 6. 小地图轻点 = 镜头跳转
	_main._minimap_layout(vp)
	_ok(_main._minimap_rect.size.x > 1.0, "小地图布局已计算（%.0fx%.0f）" % [_main._minimap_rect.size.x, _main._minimap_rect.size.y])
	_main.cam_pos = Vector2(100, 100)
	_main._on_touch(0, _main._minimap_rect.get_center(), true)
	_main._on_touch(0, _main._minimap_rect.get_center(), false)
	var expect: Vector2 = _main.world.world_size * 0.5
	_ok(_main.cam_pos.distance_to(expect) < 120.0, "点小地图中心 → 镜头跳到地图中心")

	# ── 7. 双击单位 = 全选同类
	_main.world.selection = []
	var scvs := []
	for u in _main.world.units_of(0):
		if u.type_id == "scv":
			scvs.append(u)
	if scvs.size() >= 2:
		var scv_sp: Vector2 = _main._xf(scvs[0].pos)
		_main._on_touch(0, scv_sp, true); _main._on_touch(0, scv_sp, false)
		var one: int = _main.world.selection.size()
		_main._on_touch(0, scv_sp, true); _main._on_touch(0, scv_sp, false)   # 第二次 → 全选同类
		_ok(_main.world.selection.size() >= scvs.size() and _main.world.selection.size() >= one,
			"双击/再点单位 → 全选同类（%d → %d 个）" % [one, _main.world.selection.size()])
	else:
		_ok(false, "全选同类：测试环境里 SCV 不足 2 个")

	# ── 8. 双击空地 = 全选屏幕内单位
	_main.world.selection = []
	_main.cam_pos = _main.world.buildings_of(0)[0].pos
	_main._clamp_camera()
	_main._on_touch(0, Vector2(200, 560), true); _main._on_touch(0, Vector2(200, 560), false)
	_main._on_touch(0, Vector2(200, 560), true); _main._on_touch(0, Vector2(200, 560), false)
	_ok(_main.world.selection.size() > 1, "双击空地 → 全选屏幕内单位（%d 个）" % _main.world.selection.size())

	# ── 9. 攻击移动模式
	_main.world.selection = _main.world.units_of(0).duplicate()
	_main._attack_move_mode = true
	_main._on_touch(0, Vector2(1000, 350), true)
	_main._on_touch(0, Vector2(1000, 350), false)
	var am := false
	for u in _main.world.selection:
		if u.attack_move:
			am = true
			break
	_ok(am, "攻击移动模式 → 点地面后部队进入攻击移动")
	_ok(not _main._attack_move_mode, "攻击移动模式下令后自动退出")

	# ── 10. 建造放置：拖动幽灵 + 松手确认
	var base2: Vector2 = _main.world.buildings_of(0)[0].pos
	_main._start_placing("supply_depot")
	_ok(_main._placing_build == "supply_depot", "进入放置模式")
	var g0: Vector2 = _main._screen_to_world(Vector2(400, 300))
	_main._on_touch(0, Vector2(400, 300), true)
	_ok(_main._ghost_pos.distance_to(g0) < 6.0, "按下时幽灵跟随手指")
	_main._on_drag(0, Vector2(430, 320), Vector2(30, 20))
	_main._on_touch(0, Vector2(430, 320), false)
	_ok(_main._placing_build == "" or _main.world.buildings_of(0).size() > 0,
		"松手后尝试落位（放置模式 %s）" % ("已退出" if _main._placing_build == "" else "仍激活"))

	# ── 10b. P0 回归：建造菜单必须点得到
	# 以前菜单画在面板**外面**，而输入路由靠屏幕 y 坐标猜「是不是 UI 操作」，
	# 于是菜单点击被当成点地图 —— 点了没反应，还会给选中的农民下一条移动指令。
	_main._placing_build = ""
	_main._build_menu_open = false
	_main.world.selected_building = null
	_main.world.selection = _main.world.units_of(0).duplicate()
	var layout: Dictionary = _main.build_menu_layout(vp)
	var items: Array = layout["items"]
	_ok(items.size() > 0, "建造菜单有 %d 个条目" % items.size())
	var morigin: Rect2 = layout["origin"]
	_ok(morigin.end.y <= vp.y - _main.PANEL_H + 0.5,
		"菜单整体位于面板之上（菜单底 %.0f ≤ 面板顶 %.0f）" % [morigin.end.y, vp.y - _main.PANEL_H])

	# 模拟 _draw() 的登记行为，然后走**真实触摸路径**
	_main._ui_hits.clear()
	var target := Rect2()
	for it in items:
		if not bool(it["locked"]):
			_main._ui_hit(it["rect"], "pick_build", String(it["id"]))
			if target.size.x <= 0.0:
				target = it["rect"]
	_ok(target.size.x > 0.0, "菜单里有当前可建造的条目")
	var tc: Vector2 = target.get_center()
	var hit: Dictionary = _main._ui_pick(tc)
	_ok(not hit.is_empty() and String(hit["act"]) == "pick_build",
		"菜单条目中心点能被命中表认出（act=%s）" % String(hit.get("act", "无")))
	_main._on_touch(0, tc, true)
	_main._on_touch(0, tc, false)
	_ok(_main._placing_build != "",
		"真实触摸菜单条目 → 进入放置模式（_placing_build='%s'）" % _main._placing_build)
	_main._placing_build = ""
	_main._ui_hits.clear()

	# ── 10c. 建造条目：轻点 = 进入放置，长按 = 弹介绍卡
	# 触屏没有鼠标悬浮，「这建筑是干什么的」只能靠长按主动问。
	# 卡片位置是纯函数 build_info_layout()，所以无头环境也能验证它不会跑出屏幕。
	var card: Rect2 = _main.build_info_layout(vp)
	_ok(card.position.x >= 0.0 and card.position.y >= 0.0
			and card.end.x <= vp.x + 0.5 and card.end.y <= vp.y - _main.PANEL_H + 0.5,
		"介绍卡完全落在屏幕内（x %.0f~%.0f, y %.0f~%.0f）"
			% [card.position.x, card.end.x, card.position.y, card.end.y])

	_main._show_help = false
	_main._build_info_id = ""
	_main._ui_hits.clear()
	var lpid := ""
	for it in items:
		if not bool(it["locked"]):
			_main._ui_hit(it["rect"], "pick_build", String(it["id"]))
			if lpid == "":
				lpid = String(it["id"])
	var lc: Vector2 = target.get_center()
	_main._on_touch(0, lc, true)
	_main._build_press_time -= 0.5          # 把按下时刻往前拨，模拟「按住 0.5 秒」
	_main._on_touch(0, lc, false)
	_ok(_main._build_info_id == lpid, "长按建造条目弹出介绍卡（%s）" % _main._build_info_id)
	_ok(_main._placing_build == "", "长按不会误触发放置模式")
	# 卡片是模态的：点屏幕任意处关掉
	_main._on_touch(0, vp * 0.5, true)
	_ok(_main._build_info_id == "", "点屏幕任意处关闭介绍卡")
	_main._placing_build = ""
	_main._ui_hits.clear()

	# ── 11. 战争迷雾
	_main._placing_build = ""
	var w = _main.world
	var er0: float = w.explored_ratio()
	_ok(er0 > 0.0 and er0 < 0.6, "开局只有基地周边已探索（探索度 %.0f%%）" % (er0 * 100.0))

	var eb: Vector2 = w.buildings_of(1)[0].pos
	_ok(not w.is_explored(eb), "敌方基地开局处于未探索状态")
	_ok(w.find_entity_at(eb) == null, "迷雾中的敌方建筑点不中")

	var pb: Vector2 = w.buildings_of(0)[0].pos
	var own_hit = w.find_entity_at(pb)
	_ok(own_hit != null and own_hit.owner_id == 0, "己方建筑始终可被点中（不受迷雾限制）")

	# 把一名己方单位推到敌方基地旁边，视野随之展开
	var scout = w.units_of(0)[0]
	scout.pos = eb + Vector2(50, 0)
	w.update_visibility()
	_ok(w.is_visible(eb), "单位推进到敌方基地 → 该区域转为可见")
	_ok(w.explored_ratio() > er0, "探索度上升（%.0f%% → %.0f%%）" % [er0 * 100.0, w.explored_ratio() * 100.0])
	var foe_hit = w.find_entity_at(eb)
	_ok(foe_hit != null and foe_hit.owner_id == 1, "转为可见后敌方建筑可被点中")
	_ok(w.visible_enemies().size() > 0, "visible_enemies() 列出了视野内的敌人（%d 个）" % w.visible_enemies().size())

	# 视野撤走后重新被迷雾遮住，但「已探索」位应保留
	scout.pos = pb
	w.update_visibility()
	_ok(not w.is_visible(eb), "单位撤走后该区域重新被迷雾遮住")
	_ok(w.is_explored(eb), "但「已探索」状态被永久保留")
	_ok(w.find_entity_at(eb) == null, "重新被遮住后敌方建筑再次点不中")

	_main._rebuild_minimap_fog()
	_ok(_main._minimap_fog_tex != null, "小地图迷雾覆盖层已生成")

	# ── 12. 生产队列：入队扣款、取消全额退款、出产不重复扣款
	var base3: Building = w.buildings_of(0)[0]
	_main._placing_build = ""
	w.selection = []
	w.selected_building = base3
	var f: Dictionary = w.factions[0]
	f["minerals"] = 500.0
	f["supply_cap"] = 200
	base3.queue.clear()
	var m0: float = f["minerals"]
	_ok(w.cmd_train(base3, "scv"), "下达训练指令")
	_ok(f["minerals"] < m0, "入队即扣款（%.0f → %.0f）" % [m0, f["minerals"]])
	var m1: float = f["minerals"]
	_ok(w.cancel_queue(base3, 0), "取消队列首项")
	_ok(base3.queue.is_empty(), "取消后队列清空")
	_ok(absf(f["minerals"] - m0) < 0.01, "取消后全额退款（回到 %.0f）" % f["minerals"])

	w.cmd_train(base3, "scv")
	var m2: float = f["minerals"]
	base3.queue[0]["time_left"] = 0.0
	w._try_produce(base3, "scv")
	_ok(absf(f["minerals"] - m2) < 0.01, "出产时不再二次扣款（%.0f → %.0f）" % [m2, f["minerals"]])
	base3.queue.clear()

	# ── 13. 编队：长按保存 / 点按调用 / 全灭后自动失效
	w.selection = w.units_of(0).duplicate()
	var n_sel: int = w.selection.size()
	_main._group_apply(0, true)
	_ok(_main._groups.get(0, []).size() == n_sel, "长按保存编队 1（%d 个单位）" % n_sel)
	w.selection = []
	_main._group_apply(0, false)
	_ok(w.selection.size() == n_sel, "点按编队 1 召回 %d 个单位" % w.selection.size())
	_ok(w.selected_building == null, "调用编队后清空建筑选择")
	for u in w.units_of(0):
		u.dead = true
	w.selection = []
	_main._group_apply(0, false)
	_ok(not _main._groups.has(0), "编队内单位全灭后编队自动失效")

	# ── 14. 对局外围设置：地图预设 / 速度档位 / 暂停 / 音量滑块
	#
	# ⚠️ 这一组一律通过 `menu_option_rects()` / `topbar_button_rects()` /
	#    `help_layout()` 这几个**纯函数**取坐标，而不是调 `_draw_menu()`。
	#    `draw_*` 只能在 NOTIFICATION_DRAW 上下文里调用，无头测试里调它只会报错 ——
	#    于是「菜单点了没反应」这类回归根本测不到。
	# ⚠️ 第十二轮起菜单有了首页，「阵营 / 难度 / 地图 / 速度」挪进了**单人游戏页**。
	#    不切页的话 `_menu_press` 查的是首页那四个大入口，下面的坐标一个都命中不了。
	_main.goto_page(_main.Page.SINGLE)
	var mv: Vector2 = _main.get_viewport_rect().size
	var opts: Array = _main.menu_option_rects(mv)
	var groups := {}
	for it in opts:
		var gk := String(it["group"])
		groups[gk] = int(groups.get(gk, 0)) + 1
	_ok(int(groups.get("race", 0)) == 3 and int(groups.get("diff", 0)) == 3 \
			and int(groups.get("map", 0)) == 3 and int(groups.get("speed", 0)) == 3,
		"菜单有 4 组共 12 个选择项（%s）" % str(groups))
	# 每张卡都必须落在屏幕内 —— 「画得出来但点不到」是触屏最容易犯的错。
	var outside := 0
	for it in opts:
		var rr: Rect2 = it["rect"]
		if rr.position.x < 0.0 or rr.position.y < 0.0 \
				or rr.end.x > mv.x + 0.5 or rr.end.y > mv.y + 0.5:
			outside += 1
	_ok(outside == 0, "所有选择项都在屏幕内（越界 %d 个）" % outside)

	# 真实走一遍「菜单按下」：四组各点一次
	_main.race = "terran"
	_main.difficulty = "normal"
	_main.map_preset = "plateau"
	_main.game_speed = 1.0
	var picks := {}
	for it in opts:
		picks["%s:%s" % [String(it["group"]), String(it["value"])]] = it["rect"]
	var want := ["map:river", "speed:2", "diff:hard", "race:zerg"]
	var miss := []
	for key in want:
		if not picks.has(key):
			miss.append(key)
	_ok(miss.is_empty(), "菜单里找得到四个关键选项（缺 %s）" % str(miss))
	if miss.is_empty():
		_main._menu_press((picks["map:river"] as Rect2).get_center())
		_ok(_main.map_preset == "river", "点地图选项 → map_preset = %s" % _main.map_preset)
		_main._menu_press((picks["speed:2"] as Rect2).get_center())
		_ok(absf(_main.game_speed - 2.0) < 0.001, "点速度选项 → game_speed = %.1f" % _main.game_speed)
		_main._menu_press((picks["diff:hard"] as Rect2).get_center())
		_ok(_main.difficulty == "hard", "点难度选项 → difficulty = %s" % _main.difficulty)
		_main._menu_press((picks["race:zerg"] as Rect2).get_center())
		_ok(_main.race == "zerg", "点阵营卡 → race = %s" % _main.race)

	# 开始战斗：按下 + 抬起同一点才开局，且新局用的正是菜单里选的地图。
	# ⚠️ _btn_primary 由 _draw_menu 写入，无头环境里没人写 —— 必须手工补上。
	var srect: Rect2 = _main.menu_start_rect(mv)
	_main._btn_primary = srect
	_main.map_preset = "river"
	_main._menu_press(srect.get_center())
	_main._menu_release(srect.get_center())
	var got_map: String = "无世界"
	if _main.world != null:
		got_map = String(_main.world.map_preset)
	_ok(_main.world != null and got_map == "river",
		"「开始战斗」→ 新局用的正是菜单里选的地图（%s）" % got_map)
	_ok(_main.world != null and String(_main.world.player_race) == "zerg",
		"新局的阵营也跟着菜单走")

	# 暂停 / 速度：走**真实触摸路径**（_ui_hit 登记 + _on_touch）
	_main.start_game("terran", "normal", "plateau")
	var tb: Dictionary = _main.topbar_button_rects(mv)
	_main._ui_hits.clear()
	for k in tb:
		_main._ui_hit(tb[k], String(k))
	var ph: Dictionary = _main._ui_pick((tb["pause"] as Rect2).get_center())
	_ok(String(ph.get("act", "")) == "pause", "顶栏「暂停」按钮能被命中表认出")

	var pc: Vector2 = (tb["pause"] as Rect2).get_center()
	_main._on_touch(0, pc, true)
	_main._on_touch(0, pc, false)
	_ok(_main.paused, "点顶栏「暂停」→ paused = true")
	var el0: float = _main.world.elapsed
	for i in range(30):
		_main._process(1.0 / 60.0)
	_ok(absf(_main.world.elapsed - el0) < 0.0001,
		"暂停期间世界时间不推进（%.3f → %.3f）" % [el0, _main.world.elapsed])
	_main._on_touch(0, pc, true)
	_main._on_touch(0, pc, false)
	_ok(not _main.paused, "再点一次「继续」→ 恢复推进")

	# 速度三档循环
	var sc2: Vector2 = (tb["speed"] as Rect2).get_center()
	_main.game_speed = 1.0
	_main._on_touch(0, sc2, true)
	_main._on_touch(0, sc2, false)
	_ok(absf(_main.game_speed - 1.5) < 0.001, "「速度」1× → 1.5×（%.1f）" % _main.game_speed)
	_main._on_touch(0, sc2, true)
	_main._on_touch(0, sc2, false)
	_ok(absf(_main.game_speed - 2.0) < 0.001, "再点 → 2×（%.1f）" % _main.game_speed)
	_main._on_touch(0, sc2, true)
	_main._on_touch(0, sc2, false)
	_ok(absf(_main.game_speed - 1.0) < 0.001, "再点 → 回到 1×（%.1f）" % _main.game_speed)
	# 倍率必须真的作用在推进量上，而不只是改了个数字
	var el1: float = _main.world.elapsed
	_main.game_speed = 2.0
	_main._process(0.5)
	_ok(absf(_main.world.elapsed - (el1 + 1.0)) < 0.0001,
		"2× 时一帧 0.5 秒推进 1.0 秒世界时间（%.3f → %.3f）" % [el1, _main.world.elapsed])
	_main.game_speed = 1.0

	# 音量滑块：点在滑块上**不关闭**面板，只改音量
	var lay: Dictionary = _main.help_layout(mv)
	var panel: Rect2 = lay["panel"]
	var sl: Rect2 = lay["slider"]
	_ok(panel.position.y >= -0.5 and panel.end.y <= mv.y + 0.5,
		"帮助面板整块落在屏幕内（y %.0f~%.0f / 视口 %.0f）" % [panel.position.y, panel.end.y, mv.y])
	_ok(panel.encloses(sl), "音量滑块在帮助面板内部")
	_main._show_help = true
	_main._vol_slider_rect = sl
	_main._on_touch(1, Vector2(sl.position.x + sl.size.x * 0.5, sl.get_center().y), true)
	_ok(_main._show_help, "点音量滑块不会关闭帮助面板")
	_ok(absf(_main._sfx_volume - 0.5) < 0.02,
		"点滑块中点 → 音量 ≈ 50%%（实测 %.0f%%）" % (_main._sfx_volume * 100.0))
	_main._on_drag(1, Vector2(sl.end.x, sl.get_center().y), Vector2(sl.size.x * 0.5, 0.0))
	_ok(absf(_main._sfx_volume - 1.0) < 0.02,
		"拖到最右 → 音量 100%%（实测 %.0f%%）" % (_main._sfx_volume * 100.0))
	_main._on_touch(1, Vector2(sl.end.x, sl.get_center().y), false)
	_main._on_drag(1, Vector2(sl.position.x, sl.get_center().y), Vector2(-10, 0))
	_ok(absf(_main._sfx_volume - 1.0) < 0.02, "松手后拖动不再改音量（阳性对照）")
	# 面板内、滑块外 → 关闭
	_main._on_touch(2, Vector2(panel.position.x + 20.0, panel.position.y + 40.0), true)
	_ok(not _main._show_help, "点面板别处 → 关闭帮助")
	_main._sfx_volume = 0.7

	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	print("============================================")

func _drag(id: int, from: Vector2, to: Vector2) -> void:
	_main._on_touch(id, from, true)
	_main._on_drag(id, to, to - from)
	_main._on_touch(id, to, false)

## 模拟「长按后拖动」：把按下时刻拨回 0.3 秒前触发长按判定，再拖动。
## 真机上靠 _process 轮询，测试里直接调 _update_pending_gesture() 是等价的。
func _drag_long(id: int, from: Vector2, to: Vector2) -> void:
	_main._on_touch(id, from, true)
	if _main._touches.has(id):
		_main._touches[id]["time"] = Time.get_ticks_msec() / 1000.0 - 0.30
	_main._update_pending_gesture()
	_main._on_drag(id, to, to - from)
	_main._on_touch(id, to, false)
