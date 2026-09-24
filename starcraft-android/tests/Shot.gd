extends SceneTree

## 渲染验证：把 Main.tscn 真正跑起来，抓取菜单 / 对局 / 后期三个时间点的画面。
## 用途：Main.gd 此前只做过语法检查，从未真正渲染过。

const OUT_DIR := "F:/KF/XJ/starcraft-android/shots/"

var _frames := 0
var _main: Node = null
var _ok := true
var _shot_bay = null      # 截图用：工程湾，用来展示升级面板
## 玩家的 settings.cfg 备份。模组截图会写 `mods_state` 键，
## 跑完必须还回去 —— 否则跑一次截图就把玩家的设置冲了。
var _cfg_backup := ""
var _cfg_existed := false

func _initialize() -> void:
	print("[shot] 初始化")
	_cfg_existed = FileAccess.file_exists(Settings.PATH)
	if _cfg_existed:
		var cf := FileAccess.open(Settings.PATH, FileAccess.READ)
		if cf != null:
			_cfg_backup = cf.get_as_text()
	var scene: PackedScene = load("res://assets/scripts/Main.tscn")
	if scene == null:
		print("[shot][FAIL] 无法加载 Main.tscn")
		_ok = false
		return
	_main = scene.instantiate()
	if _main == null:
		print("[shot][FAIL] 实例化失败")
		_ok = false
		return
	root.add_child(_main)
	print("[shot] 场景已挂载，state=", _main.state)

func _process(delta: float) -> bool:
	if not _ok:
		return true
	_frames += 1

	if _frames == 20:
		_grab("01_menu")
		print("[shot] 菜单已截图，开始对局")
		_main.start_game("terran", "normal")

	elif _frames == 50:
		_grab("02_game_start")
		print("[shot] 对局开局已截图")

	elif _frames == 55:
		# 缩到最小看全图：验证战争迷雾（只有基地周边是亮的）
		_main.cam_zoom = 0.45
		_main.cam_pos = _main.world.buildings_of(World.PLAYER)[0].pos
		_main._clamp_camera()
		_main.queue_redraw()

	elif _frames == 57:
		_grab("02b_fog_zoomout")
		_main.cam_zoom = 1.0
		_main._clamp_camera()

	elif _frames == 60:
		# 推进 20 秒模拟，让采矿/建造/部队动起来
		for i in range(60 * 20):
			_main.world.step(1.0 / 60.0)
		_main.cam_pos = _main.world.units_of(World.PLAYER)[0].pos
		_main.queue_redraw()
		print("[shot] 已推进 20 秒模拟")

	elif _frames == 84:
		# 放大特写：验证单位贴图放大后的细节
		var mine: Array = _main.world.units_of(World.PLAYER)
		var ctr: Vector2 = _main.world.buildings_of(World.PLAYER)[0].pos
		for u in mine:
			ctr += u.pos
		ctr /= float(mine.size() + 1)
		_main.cam_zoom = 2.6
		_main.cam_pos = ctr
		_main._clamp_camera()
		_main.queue_redraw()

	elif _frames == 87:
		_grab("11_zoom_closeup")
		_main.cam_zoom = 1.0
		_main.cam_pos = _main.world.units_of(World.PLAYER)[0].pos
		_main._clamp_camera()
		_main.queue_redraw()

	elif _frames == 90:
		_grab("03_game_20s")
		# 打开建造菜单，验证面板渲染
		_main._toggle_build_menu()
		_main.queue_redraw()

	elif _frames == 110:
		_grab("04_build_menu")

	elif _frames == 120:
		# 关掉菜单，推进到 90 秒看中期战况
		_main._build_menu_open = false
		for i in range(60 * 70):
			_main.world.step(1.0 / 60.0)
		_main.cam_pos = _main.world.units_of(World.PLAYER)[0].pos if _main.world.units_of(World.PLAYER).size() > 0 else _main.cam_pos
		_main.queue_redraw()

	elif _frames == 150:
		_grab("05_game_90s")

	elif _frames == 155:
		# 派一个单位去地图中央开视野：验证迷雾边界（亮/暗过渡）
		var mine: Array = _main.world.units_of(World.PLAYER)
		if mine.size() > 0:
			mine[0].pos = _main.world.world_size * Vector2(0.5, 0.5)
			_main.world.update_visibility()
		_main.cam_zoom = 0.7
		_main.cam_pos = _main.world.world_size * Vector2(0.42, 0.5)
		_main._clamp_camera()
		_main.queue_redraw()

	elif _frames == 158:
		_grab("07_fog_boundary")
		_main.cam_zoom = 1.0
		_main.cam_pos = _main.world.buildings_of(World.PLAYER)[0].pos
		_main._clamp_camera()
		_main.queue_redraw()

	elif _frames == 161:
		# 选中部队：验证单位面板 + 编队行
		_main.world.selection = _main.world.units_of(World.PLAYER).duplicate()
		_main.world.selected_building = null
		_main._groups[0] = []
		for u in _main.world.selection:
			_main._groups[0].append(u.id)
		_main.queue_redraw()

	elif _frames == 164:
		_grab("08_panel_units")
		# 选中基地并排两个兵 + 设置集结点：验证队列与集结点旗
		var base: Building = _main.world.buildings_of(World.PLAYER)[0]
		_main.world.selection = []
		_main.world.selected_building = base
		_main.world.factions[World.PLAYER]["minerals"] = 900.0
		_main.world.cmd_train(base, "scv")
		_main.world.cmd_train(base, "scv")
		base.rally = base.pos + Vector2(210, -120)
		base.has_rally = true
		_main.cam_zoom = 1.0
		_main.queue_redraw()

	elif _frames == 167:
		_grab("09_panel_building")
		# 打开帮助页
		_main._show_help = true
		_main.queue_redraw()

	elif _frames == 175:
		_grab("06_help")
		_main._show_help = false
		# 换一局神族：验证水晶塔能量场的可视化（放置模式会画出能量场圆圈）
		_main.start_game("protoss", "normal")
		print("[shot] 已切到神族对局")

	elif _frames == 182:
		var w: World = _main.world
		w.factions[World.PLAYER]["minerals"] = 1200.0
		var base: Building = w.buildings_of(World.PLAYER)[0]
		var pylon = null
		for ang in range(0, 360, 20):
			var a := deg_to_rad(float(ang))
			var p: Vector2 = base.pos + Vector2(cos(a), sin(a)) * 170.0
			if w.can_place_building("pylon", p, World.PLAYER)["ok"]:
				if w.cmd_build("pylon", p, World.PLAYER):
					for b in w.buildings_of(World.PLAYER):
						if b.type_id == "pylon":
							pylon = b
					break
		if pylon != null:
			pylon.complete = true
			pylon.build_progress = pylon.build_time
		w.update_visibility()
		_main.cam_zoom = 1.0
		_main.cam_pos = base.pos
		_main._clamp_camera()
		_main._start_placing("gateway")
		_main._ghost_pos = base.pos + Vector2(215, -50)
		_main.queue_redraw()
		print("[shot] 神族放置模式（能量场）已就绪")

	elif _frames == 190:
		_grab("10_pylon_power")
		_make_art_sheet()
		# 再换一局虫族：三族都要有一张实机图，才能比对配色是否真的分得开
		_main.start_game("zerg", "normal")
		print("[shot] 已切到虫族对局")

	elif _frames == 197:
		# 虫族展示场景：把五种虫族单位和两种建筑都摆出来
		var w: World = _main.world
		w.factions[World.PLAYER]["minerals"] = 2000.0
		var base: Building = w.buildings_of(World.PLAYER)[0]
		for pair in [["spawning_pool", Vector2(-165, 128)], ["spire", Vector2(160, 128)]]:
			w._place_building(String(pair[0]), "zerg", base.pos + (pair[1] as Vector2),
				World.PLAYER, true)
		var ring := ["drone", "zergling", "hydralisk", "roach", "mutalisk"]
		for i in range(ring.size()):
			var a := -PI * 0.5 + float(i) * TAU / float(ring.size())
			w._spawn_unit(ring[i], "zerg", base.pos + Vector2(cos(a), sin(a)) * 82.0, World.PLAYER)
		w.update_visibility()
		_main.cam_zoom = 1.7
		_main.cam_pos = base.pos
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 虫族展示场景已就绪")

	elif _frames == 215:
		_grab("12_zerg_base")
		# 换回人族：验证第七轮新加的「升级面板」与「技能按钮」。
		# 这两个 UI 只有跑起来才能确认画得对（--import 不解析 Main.gd）。
		_main.start_game("terran", "normal")
		print("[shot] 已切回人族对局（准备截升级面板 / 技能按钮）")

	elif _frames == 222:
		var w: World = _main.world
		w.factions[World.PLAYER]["minerals"] = 3000.0
		w.factions[World.PLAYER]["gas"] = 3000.0
		var base: Building = w.buildings_of(World.PLAYER)[0]
		# 升级型建筑（工程湾）与训练型建筑（兵营）并排，方便对照两种面板
		_shot_bay = w._place_building("engineering_bay", "terran",
			base.pos + Vector2(-200, 150), World.PLAYER, true)
		w._place_building("barracks", "terran", base.pos + Vector2(190, 150), World.PLAYER, true)
		# 兴奋剂已解锁 + 步兵武器 2 级：面板上同时出现实心圆点与空心圆点
		w.factions[World.PLAYER]["upgrades"]["stim_pack"] = 1
		w.factions[World.PLAYER]["upgrades"]["infantry_weapons"] = 2
		# 三种带技能的单位都摆出来，一次展示三种技能按钮
		var m := w._spawn_unit("marine", "terran", base.pos + Vector2(-70, 70), World.PLAYER)
		var med := w._spawn_unit("medic", "terran", base.pos + Vector2(0, 70), World.PLAYER)
		var tank := w._spawn_unit("siege_tank", "terran", base.pos + Vector2(70, 70), World.PLAYER)
		# 让医疗兵能量不足、坦克正在展开 —— 把「不可用」的两种原因也画出来
		med.energy = 0.5
		tank.set_mode("sieged")
		w.update_visibility()
		_main.cam_zoom = 1.15
		_main.cam_pos = base.pos
		_main._clamp_camera()
		w.selection = [m, med, tank]
		w.selected_building = null
		_main.queue_redraw()
		print("[shot] 技能按钮场景已就绪（就绪 / 能量不足 / 变形中 三种状态）")

	elif _frames == 230:
		_grab("13_ability_buttons")
		var w2: World = _main.world
		w2.selection = []
		w2.selected_building = _shot_bay
		_main.queue_redraw()
		print("[shot] 升级面板场景已就绪")

	elif _frames == 238:
		_grab("14_upgrade_panel")
		print("[shot] 升级面板已截图，准备建造者可视化场景")

	elif _frames == 246:
		# 建造者可视化：一屏同时展示三种状态 ——
		#   工地 A：一个农民已到场（头顶扳手 + 进度环）
		#   工地 A：另一个农民还在路上（农民→工地的虚线）
		#   工地 B：无人接手（红色进度条 + 「等待建造者」）
		var w: World = _main.world
		w.factions[World.PLAYER]["minerals"] = 3000.0
		w.factions[World.PLAYER]["gas"] = 3000.0
		var base: Building = w.buildings_of(World.PLAYER)[0]
		w.selection = []
		w.selected_building = null
		# 清掉场上所有单位，只留下面这两个农民。
		# 否则经济/AI 逻辑会立刻给「无人接手」的工地补人，红色状态根本截不到。
		w.units.clear()
		_main._build_menu_open = false
		_main._build_info_id = ""
		var site := w._place_building("barracks", "terran", base.pos + Vector2(-20, 190), World.PLAYER, false)
		w._place_building("supply_depot", "terran", base.pos + Vector2(215, 120), World.PLAYER, false)
		var near_w := w._spawn_unit("scv", "terran", site.pos + Vector2(-30, 20), World.PLAYER)
		var far_w := w._spawn_unit("scv", "terran", base.pos + Vector2(-300, 300), World.PLAYER)
		w._assign_builder(site, near_w)
		w._assign_builder(site, far_w)
		w.update_visibility()
		_main.cam_zoom = 1.30
		_main.cam_pos = base.pos + Vector2(50, 150)
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 建造者标记场景已就绪（在场 / 在路上 / 无人接手 三种状态）")

	elif _frames == 254:
		_grab("15_builder_badge")
		# 建造介绍卡：打开建造菜单并弹出「重工厂」的说明 ——
		# 顺带展示「前置」一行（重工厂需要兵营）。
		var w3: World = _main.world
		var crew := w3.units_of(World.PLAYER)
		w3.selection = [crew[0]] if not crew.is_empty() else []
		w3.selected_building = null
		_main._build_menu_open = true
		_main._build_info_id = "factory"
		_main.queue_redraw()
		print("[shot] 建造介绍卡场景已就绪")

	elif _frames == 262:
		_grab("16_build_info")
		# 空中维度对照：前排地面单位、后排三族空军。
		# 要验证的是「一眼能看出谁在天上」—— 影子偏移、机翼、绘制层次
		# 这三样只有真的渲染出来才知道对不对（--import 不解析 Main.gd）。
		var w4: World = _main.world
		w4.factions[World.PLAYER]["minerals"] = 3000.0
		var base4: Building = w4.buildings_of(World.PLAYER)[0]
		w4.units.clear()
		w4.selection = []
		w4.selected_building = null
		_main._build_menu_open = false
		_main._build_info_id = ""
		w4._spawn_unit("marine", "terran", base4.pos + Vector2(-95, 55), World.PLAYER)
		w4._spawn_unit("zealot", "protoss", base4.pos + Vector2(-32, 55), World.PLAYER)
		w4._spawn_unit("hydralisk", "zerg", base4.pos + Vector2(32, 55), World.PLAYER)
		w4._spawn_unit("siege_tank", "terran", base4.pos + Vector2(98, 55), World.PLAYER)
		w4._spawn_unit("wraith", "terran", base4.pos + Vector2(-95, -55), World.PLAYER)
		w4._spawn_unit("scout", "protoss", base4.pos + Vector2(0, -55), World.PLAYER)
		w4._spawn_unit("mutalisk", "zerg", base4.pos + Vector2(98, -55), World.PLAYER)
		w4.update_visibility()
		_main.cam_zoom = 1.55
		_main.cam_pos = base4.pos
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 空军对照场景已就绪（上排空军 / 下排地面）")

	elif _frames == 270:
		_grab("17_air_units")
		# 防空网：三族防空建筑并排 + 一架来袭的飞龙。
		# 跑几帧让塔开火 —— 弹道速度 520，塔到目标约 180px（0.35 秒），
		# 只推进 6 帧刚好能截到「弹道还在飞」的那一瞬间。
		var w5: World = _main.world
		w5.factions[World.PLAYER]["minerals"] = 3000.0
		var base5: Building = w5.buildings_of(World.PLAYER)[0]
		w5.units.clear()
		w5.selection = []
		w5.selected_building = null
		w5._place_building("missile_turret", "terran", base5.pos + Vector2(-150, -40), World.PLAYER, true)
		w5._place_building("photon_cannon", "protoss", base5.pos + Vector2(0, -40), World.PLAYER, true)
		w5._place_building("spore_colony", "zerg", base5.pos + Vector2(150, -40), World.PLAYER, true)
		w5._spawn_unit("mutalisk", "zerg", base5.pos + Vector2(-40, 100), World.ENEMY)
		w5._spawn_unit("wraith", "terran", base5.pos + Vector2(60, 90), World.ENEMY)
		for i in range(6):
			w5.step(1.0 / 60.0)
		w5.update_visibility()
		_main.cam_zoom = 1.45
		_main.cam_pos = base5.pos + Vector2(0, 30)
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 防空网场景已就绪（三族防空建筑 + 来袭空军）")

	elif _frames == 278:
		_grab("18_anti_air")
		# 高低差：把镜头对准地图上的一块高地平台。
		# 平台坐标由地图生成器决定，所以这里**从网格反查**而不是写死 ——
		# 写死的话，地图生成一改这张图就对准了一片空地。
		var w6: World = _main.world
		w6.factions[World.PLAYER]["minerals"] = 3000.0
		w6.units.clear()
		w6.selection = []
		w6.selected_building = null
		var pc := _find_plateau_cell(w6)
		if pc.x < 0:
			print("[shot][WARN] 地图上没有找到高地平台，跳过高低差场景")
		else:
			var ppos := w6.grid.cell_to_world(pc)
			# 崖顶一队守军（正好站在平台南缘内侧）
			var south := ppos + Vector2(0, float(3 * int(Grid.CELL)))
			w6._spawn_unit("marine", "terran", south + Vector2(-26, 0), World.PLAYER)
			w6._spawn_unit("marine", "terran", south + Vector2(26, 0), World.PLAYER)
			w6._spawn_unit("siege_tank", "terran", ppos, World.PLAYER)
			# 崖底一队进攻方：正好卡在射程内，让「低打高 30% miss」打起来
			for i in range(3):
				w6._spawn_unit("hydralisk", "zerg",
					south + Vector2(-46 + float(i) * 46, 120), World.ENEMY)
			for i in range(24):
				w6.step(1.0 / 60.0)
			w6.update_visibility()
			_main.cam_zoom = 1.25
			_main.cam_pos = ppos + Vector2(0, 60)
			_main._clamp_camera()
			_main.queue_redraw()
			print("[shot] 高低差场景已就绪（崖顶守军 / 崖底进攻方）")

	elif _frames == 286:
		_grab("19_elevation")
		# 虫族菌毯：在玩家基地旁边手工摆一片虫族建筑，看菌毯的覆盖范围与边界。
		#
		# 刻意**不切对局** —— 切对局要重跑 start_game，会把前面几张图的
		# 世界状态整个换掉；而菌毯的判定只看「建筑是不是虫族」，
		# 在人族对局里摆几座虫族建筑照样长得出来。
		var w7: World = _main.world
		w7.units.clear()
		w7.selection = []
		w7.selected_building = null
		_main._build_menu_open = false
		_main._build_info_id = ""
		var base7: Building = w7.buildings_of(World.PLAYER)[0]
		var c7: Vector2 = base7.pos + Vector2(0, 210)
		w7._place_building("hive", "zerg", c7, World.PLAYER, true)
		w7._place_building("spawning_pool", "zerg", c7 + Vector2(-120, 70), World.PLAYER, true)
		w7._place_building("spire", "zerg", c7 + Vector2(120, 70), World.PLAYER, true)
		w7._rebuild_creep()
		# 菌毯内外各放一只跳虫 —— 这张图要能一眼看出菌毯铺到哪，
		# 因为那条边界正是玩家判断「兵吃不吃加速、建筑放不放得下」的依据。
		w7._spawn_unit("zergling", "zerg", c7 + Vector2(-70, 0), World.PLAYER)
		w7._spawn_unit("zergling", "zerg", c7 + Vector2(70, 0), World.PLAYER)
		w7._spawn_unit("hydralisk", "zerg", c7 + Vector2(0, 120), World.PLAYER)
		w7.update_visibility()
		_main.cam_zoom = 0.92
		_main.cam_pos = c7 + Vector2(0, 40)
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 菌毯场景已就绪")

	elif _frames == 294:
		_grab("20_creep")
		# 中间河道：换一张图看河道贴图与三座桥。
		# ⚠️ 必须真的换图重开一局 —— 河道是地图生成阶段画进网格的，
		#    在旧图上手工抹 CHASM 只能验证贴图，验证不了「生成器有没有把桥留出来」。
		_main.map_preset = "river"
		_main.start_game("terran", "normal", "river")
		# 揭开全图迷雾。河道横在正中间，而中间那一大片开局必然没探索过 ——
		# 不揭雾的话截图里就是一块纯黑，什么都验证不了。
		# （只改 vis 位，不动任何游戏规则。）
		for i in range(_main.world.vis.size()):
			_main.world.vis[i] = World.VIS_VISIBLE | World.VIS_EXPLORED
		_main._rebuild_minimap_fog()
		# 镜头拉到两军之间的河段，正好把桥和深渊一起框进去
		_main.cam_zoom = 0.78
		_main.cam_pos = _main.world.world_size * 0.5
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 中间河道场景已就绪")

	elif _frames == 302:
		_grab("21_river")
		# 主菜单首页：四个入口（单人 / 局域网 / 设置 / 模组）。
		_main.goto_menu()
		_main.queue_redraw()
		print("[shot] 主菜单首页已就绪")

	elif _frames == 310:
		_grab("22_menu")
		# 单人游戏页：阵营卡 + 难度 / 地图 / 速度三行。
		# ⚠️ 必须**显式切页** —— goto_menu() 现在回的是首页，
		#    只调它的话截出来的还是首页，那张图就白拍了。
		_main.goto_page(_main.Page.SINGLE)
		_main.queue_redraw()
		print("[shot] 单人游戏页已就绪")

	elif _frames == 318:
		_grab("23_single")
		# 设置页：五个分类 + 开关 + 滑块 + 恢复默认。
		_main.goto_page(_main.Page.SETTINGS)
		_main.queue_redraw()
		print("[shot] 设置页已就绪")

	elif _frames == 326:
		_grab("24_settings")
		# 局域网页。**这一页必须拍** —— 它是内容最多的表单页
		# （M4b 起改成 3 个分组 + 8 行，面板自然高度 566px，底边 670），
		# 是唯一会顶到「标题之下」边界的那一页。`FORM_HEAD_H` 那个改动就是为它做的。
		# ⚠️ 面板高度是**按条目数算**的：加一行就会把最后一行挤出屏幕，**且不报错**。
		#    改这一页的 `sections` 之后先跑 `tests/Lan.gd` 第 1 组。
		_main.goto_page(_main.Page.LAN)
		_main.queue_redraw()
		print("[shot] 局域网页已就绪")

	elif _frames == 330:
		# 装几个假模组，专供模组页截图（**必须在美术总览图之后**，理由见函数注释）
		_install_shot_mods()
		print("[shot] 假模组已装：%d 个" % Mods.list.size())

	elif _frames == 334:
		_grab("25_lan")
		# 模组页：5 行 + 翻页按钮，一屏里同时有「正常 / 数值冲突（黄）/ 缺元数据（红）」
		_main.goto_page(_main.Page.MODS)
		_main.queue_redraw()
		print("[shot] 模组页已就绪")

	elif _frames == 342:
		_grab("26_mods")
		# 设置页切到「游戏」分类 —— 验证 tab 切过去之后内容真的换了，
		# 而不只是高亮换了个位置。
		_main.goto_page(_main.Page.SETTINGS)
		_main._menu_act("stab:游戏", Rect2(), Vector2.ZERO)
		_main.queue_redraw()
		print("[shot] 设置页·游戏分类已就绪")

	elif _frames == 350:
		_grab("27_settings_game")
		# HUD 编辑模式：模块幽灵框 + 9 宫格参考线 + 工具栏 + 选中态。
		# **这一屏没有测试能替代** —— 无头环境调不了 `_draw_*`，
		# 幽灵框位置、拖动柄、工具栏排版、黄框警告只能靠眼睛看。
		_main._start_hud_edit()
		_main._hud_sel = "cmd"
		_main.queue_redraw()
		print("[shot] HUD 编辑模式已就绪")

	elif _frames == 358:
		_grab("28_hud_edit")
		# 模组页·禁用后：勾选框空、整行压暗、**冲突黄框应当消失**。
		# 这一屏验证的是「禁用一方之后冲突真的解除了」——
		# 而这正是 `Mods.set_enabled()` 漏掉 `_rebuild_owners()` 时的症状：
		# 勾变了、行暗了，黄框还挂着，玩家照着提示找第二个模组永远找不到。
		_main._exit_hud_edit()
		_main.goto_page(_main.Page.MODS)
		_main._menu_act("mod_toggle:b_balance", Rect2(), Vector2.ZERO)
		_main.queue_redraw()
		print("[shot] 模组页·禁用态已就绪")

	elif _frames == 470:
		# ⚠️ 不能在第 358 帧紧接着抓 —— `_toast()` 的生命周期是 **1.6 秒（约 96 帧）**，
		#    而 HUD 编辑提示条和「c_broken：缺少 mod.json」的报错提示都还在屏上，
		#    会把页面标题盖住。等它自然消失再抓。
		_grab("29_mods_disabled")
		_cleanup_shot_mods()
		# 大厅页（主机视角）。**这一屏没有测试能替代** ——
		# 无头环境调不了 `_draw_*`：标题 / 「你是主机」那行 / 状态文案 /
		# **放大的本机地址** / 离开按钮的位置只能靠眼睛看。
		#
		# ⚠️ 用测试端口 27715，**不碰 `Net.PORT`(27015)** ——
		#    开发机上可能正跑着一个真实例，撞上就是「随机失败」。
		_main._lan_host(27715)
		_main.queue_redraw()
		print("[shot] 大厅页（主机视角）已就绪")

	elif _frames == 578:
		# ⚠️ 从 470 等到 578：`_lan_host()` 会弹一条「房间已创建」toast，
		#    生命周期 1.6 秒（约 96 帧），它会压在底部那个「离开房间」按钮上。
		_grab("30_lobby_host")
		# 客户端视角的大厅：文案应当是「你是客户端（只发指令）」，
		# 而且**没有**那行放大的本机地址（只有主机需要看它）。
		_main._lan_leave()
		# ⚠️ 用**不可路由**地址（同 `tests/Lan.gd`）：`_lan_join()` 是非阻塞的，
		#    不会真连上，但也不该去骚扰局域网里某台真实设备。
		_main._lan_ip = "10.255.255.1"
		_main._lan_join(27716)
		_main.queue_redraw()
		print("[shot] 大厅页（客户端视角）已就绪")

	elif _frames == 586:
		# ⚠️ 必须在 `CONNECT_TIMEOUT`(8 秒 ≈ 480 帧) 之前抓 ——
		#    超时之后 `_lan_status` 会变成失败文案，就看不到「正在连接 …」了。
		_grab("31_lobby_client")
		_main._lan_leave()
		print("[shot] 大厅页（客户端视角）已就绪")

	elif _frames == 600:
		# 搜索房间页。**这一屏只能靠截图看** ——
		# 无头测不了 `_draw_*`：房间行里「名字 / IP · 地图 · 人数」三段的
		# 排版、以及「暂时没发现房间」那行提示的位置，都只有眼睛能验。
		#
		# ⚠️ 房间列表**手工塞进发现器**，不去等真实广播 ——
		#    截图是确定性的（跑几遍要一模一样），等真实 UDP 会时有时无。
		#    走的是和真实路径**同一个** `_rooms` 字段 + 同一个 `rooms()`，
		#    所以画出来的排版和真发现时逐像素相同。
		_main._open_lan_scan()
		_main._inject_fake_rooms([
			{"ip": "192.168.2.83", "port": 27015, "name": "老张的房间",
				"map": "plateau", "players": 1, "max": 2},
			{"ip": "192.168.2.17", "port": 27015, "name": "大厅里的第二台",
				"map": "river", "players": 2, "max": 2},
		])
		_main.queue_redraw()
		print("[shot] 搜索房间页已就绪")

	elif _frames == 610:
		_grab("32_lan_scan")
		# 对局内的聊天 / 投降键 + 聊天记录。
		# 这一屏守的是**顶栏下面那一行新键的排版**：它们必须和 `sysbtns`
		# 那一行**不重叠**（重叠的话点「聊天」会同时命中「音效」），
		# 而「重叠不重叠」在无头里只能比矩形、看不出「挤在一起」的观感。
		_main._menu_act("lan_scan_back", Rect2(), Vector2.ZERO)
		_main.start_game("terran", "easy", "plateau")
		_main._lan_active_override = true
		_main._push_chat("老张", "你那边矿够不够")
		_main._push_chat("指挥官", "够，先出坦克")
		_main._push_chat("系统", "老张 认输了")
		_main.queue_redraw()
		print("[shot] 对局内聊天已就绪")

	elif _frames == 640:
		_grab("33_ingame_chat")
		_main._lan_active_override = false
		# 法术区域：心灵风暴的伤害圈 + 黑暗虫群的免疫圈 + 单位身上的效果环。
		#
		# ⚠️ 这一屏**只有截图能验**（无头调不了 `_draw_*`）：
		#    区域是半透明的圆，叠在一起会不会糊成一块色斑、
		#    会不会把里面的单位盖住看不见血条、电弧的密度是不是过密，
		#    全是观感问题，任何断言都写不出来。
		_main.start_game("protoss", "easy", "plateau")
		var ws: World = _main.world
		ws.ai_enabled = false
		ws.factions[World.PLAYER]["minerals"] = 3000.0
		ws.factions[World.PLAYER]["gas"] = 3000.0
		var bs: Building = ws.buildings_of(World.PLAYER)[0]
		ws.units.clear()
		ws.selection = []
		ws.selected_building = null
		_main._build_menu_open = false
		_main._build_info_id = ""
		var storm_c := bs.pos + Vector2(-150, 30)
		var swarm_c := bs.pos + Vector2(110, 30)
		# 风暴圈里：自己人 + 敌人混在一起（正好展示「敌我不分」）
		ws._spawn_unit("zealot", "protoss", storm_c + Vector2(-18, 0), World.PLAYER)
		ws._spawn_unit("dragoon", "protoss", storm_c + Vector2(16, 14), World.PLAYER)
		ws._spawn_unit("zergling", "zerg", storm_c + Vector2(6, -20), World.ENEMY)
		ws._spawn_unit("hydralisk", "zerg", storm_c + Vector2(-14, 22), World.ENEMY)
		# 虫群圈里：自己人（展示紫色虚边环）
		ws._spawn_unit("zealot", "protoss", swarm_c + Vector2(-20, 0), World.PLAYER)
		ws._spawn_unit("zealot", "protoss", swarm_c + Vector2(14, 12), World.PLAYER)
		# 施法者站外面
		ws._spawn_unit("high_templar", "protoss", bs.pos + Vector2(-30, 150), World.PLAYER)
		var df2 := ws._spawn_unit("defiler", "zerg", bs.pos + Vector2(160, 150), World.ENEMY)
		ws.update_visibility()
		ws.cmd_ability([df2], "dark_swarm", swarm_c)
		var ht2: Unit = null
		for u in ws.units_of(World.PLAYER):
			if u.type_id == "high_templar":
				ht2 = u
		if ht2 != null:
			ws.cmd_ability([ht2], "psionic_storm", storm_c)
		# 跑 0.6 秒：让 dot 跳一次、也让「被辐照」的环有得画
		for i in range(12):
			ws.step(0.05)
		# 顺手挂一个辐照，把「dot 环」也画出来
		var sv := ws._spawn_unit("science_vessel", "terran", bs.pos + Vector2(-260, 150), World.PLAYER)
		var mark: Unit = ws.units_of(World.ENEMY)[0]
		sv.energy = 200.0
		ws.cmd_ability([sv], "irradiate", mark)
		ws.update_visibility()
		_main.cam_zoom = 1.05
		_main.cam_pos = bs.pos + Vector2(0, 60)
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 法术区域场景已就绪（风暴圈 / 虫群圈 / 三种效果环）")

	elif _frames == 650:
		_grab("34_spell_zones")
		# 瞄准态：预览圈 + 施法者射程环 + 顶部提示条。
		# 要验的是「预览圈和落地后的区域一样大」以及提示条不压顶栏。
		var wa: World = _main.world
		var ba: Building = wa.buildings_of(World.PLAYER)[0]
		var ht3: Unit = null
		for u in wa.units_of(World.PLAYER):
			if u.type_id == "high_templar":
				ht3 = u
		if ht3 != null:
			ht3.ability_cd = 0.0
			ht3.energy = 200.0
			wa.selection = [ht3]
			_main._aim_spell = "psionic_storm"
			_main._aim_pos = ba.pos + Vector2(-150, 30)
		_main.queue_redraw()
		print("[shot] 法术瞄准态已就绪")

	elif _frames == 660:
		_grab("35_spell_aim")
		_main._aim_spell = ""
		# 三个施法单位的技能按钮：展示「能量 N」这一行。
		var wb: World = _main.world
		var bb: Building = wb.buildings_of(World.PLAYER)[0]
		wb.units.clear()
		wb.factions[World.PLAYER]["minerals"] = 3000.0
		wb.factions[World.PLAYER]["gas"] = 3000.0
		var a := wb._spawn_unit("high_templar", "protoss", bb.pos + Vector2(-60, 80), World.PLAYER)
		var b2 := wb._spawn_unit("dragoon", "protoss", bb.pos + Vector2(0, 80), World.PLAYER)
		var c2 := wb._spawn_unit("archon", "protoss", bb.pos + Vector2(60, 80), World.PLAYER)
		a.energy = 200.0
		wb.update_visibility()
		_main.cam_zoom = 1.30
		_main.cam_pos = bb.pos + Vector2(0, 80)
		_main._clamp_camera()
		wb.selection = [a, b2, c2]
		wb.selected_building = null
		_main.queue_redraw()
		print("[shot] 法术技能按钮场景已就绪")

	elif _frames == 670:
		_grab("36_spell_buttons")
		# 三种状态效果的**特写**：dot（绿脉动）/ no_ranged（紫虚边）/ slow（蓝白链环）。
		#
		# ⚠️ 为什么单开一屏：这三种环半径只有单位半径的 1.6~1.8 倍，
		#    在正常的 1.0 缩放下就是十几个像素，糊在贴图上根本看不清
		#    「画了没有 / 画的哪一种」。而 `_draw_unit` 在无头里跑不起来，
		#    没有任何断言能替它说话 —— 只有放大截图能。
		#    另外 `slow` 目前**没有任何法术产出**（是给后续法术留的基础设施），
		#    靠 `apply_effect` 直接挂，正好一并把渲染验掉。
		var wc: World = _main.world
		var bc: Building = wc.buildings_of(World.PLAYER)[0]
		wc.units.clear()
		wc.spell_zones.clear()
		wc.selection = []
		wc.selected_building = null
		wc.ai_enabled = false
		var ids: PackedStringArray = ["dot", "no_ranged", "slow"]
		var offs: PackedVector2Array = [Vector2(-78, 0), Vector2(0, 0), Vector2(78, 0)]
		for i in range(ids.size()):
			var u := wc._spawn_unit("zealot", "protoss", bc.pos + offs[i], World.PLAYER)
			var sid := ids[i]
			if sid == "dot":
				u.apply_effect({"id": "irradiate", "kind": "dot", "duration": 15.0,
					"remain": 12.0, "dps": 12.0, "damage_type": "normal", "owner": World.ENEMY})
			elif sid == "no_ranged":
				u.apply_effect({"id": "dark_swarm", "kind": "no_ranged",
					"duration": 20.0, "remain": 16.0})
			else:
				u.apply_effect({"id": "ensnare", "kind": "slow", "duration": 8.0,
					"remain": 6.0, "slow_mult": 0.45})
		wc.update_visibility()
		_main.cam_zoom = 2.6
		_main.cam_pos = bc.pos + Vector2(0, 0)
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 状态效果特写场景已就绪（dot / no_ranged / slow）")

	elif _frames == 680:
		_grab("37_effect_rings")
		# 诱捕网的瞄准态。它和心灵风暴**共用同一套 `ground_aoe` 瞄准 UI**，
		# 但预览圈半径来自各自的表（诱捕网 80 / 风暴 52）——
		# 这一屏要验的正是「换一个法术，预览圈跟着换大小」。
		var wd: World = _main.world
		var bd: Building = wd.buildings_of(World.PLAYER)[0]
		wd.units.clear()
		wd.spell_zones.clear()
		wd.selected_building = null
		var qn := wd._spawn_unit("queen", "zerg", bd.pos + Vector2(-70, 90), World.PLAYER)
		qn.energy = 200.0
		wd.update_visibility()
		_main.cam_zoom = 1.15
		_main.cam_pos = bd.pos + Vector2(30, 130)
		_main._clamp_camera()
		wd.selection = [qn]
		_main._aim_spell = "ensnare"
		_main._aim_pos = bd.pos + Vector2(110, 60)
		_main.queue_redraw()
		print("[shot] 诱捕网瞄准态已就绪（预览圈半径 %.0f）"
			% float(GameData.get_spell("ensnare").get("radius", 0.0)))

	elif _frames == 690:
		_grab("38_ensnare_aim")
		_main._aim_spell = ""
		# 诱捕网**落地后**的画面：黏液光 + 被抓单位的蓝白减速环（含一个空中单位）。
		#
		# ⚠️ 落地反馈只有 0.35 秒的一圈光，而 `_add_effect` 的寿命是在 `step()`
		#    里递减的 —— 所以这里**施法之后一帧都不推进**，直接截图。
		#    先 `step()` 再截的话，光晕已经淡掉，看起来像「施放没有反馈」。
		# ⚠️ 不跑 `step()` 还有一个好处：四个单位挤在 100px 内，
		#    真打起来的话这一屏会变成「战斗现场」而不是「诱捕网现场」。
		var we: World = _main.world
		var be: Building = we.buildings_of(World.PLAYER)[0]
		we.units.clear()
		we.spell_zones.clear()
		we.ai_enabled = false
		var q2 := we._spawn_unit("queen", "zerg", be.pos + Vector2(-170, 40), World.PLAYER)
		q2.energy = 200.0
		var spot := be.pos + Vector2(0, 40)
		we._spawn_unit("marine", "terran", spot + Vector2(-72, 0), World.ENEMY)
		we._spawn_unit("mutalisk", "zerg", spot + Vector2(0, -68), World.ENEMY)
		we._spawn_unit("hydralisk", "zerg", spot + Vector2(72, 0), World.PLAYER)
		# ★圈外的对照单位★ —— 半径 80，摆到 108。
		# 这一屏要一眼看出「圈内画减速环、圈外不画」：
		# 只摆圈内的单位的话，玩家分不清「环是因为中招才有的」
		# 还是「所有单位本来就有一圈」（护盾环就长这样）。
		we._spawn_unit("marine", "terran", spot + Vector2(108, 0), World.ENEMY)
		var cast_ok := we.cmd_ability([q2], "ensnare", spot)
		var caught := 0
		for u in we.units:
			if u.has_effect("ensnare"):
				caught += 1
		we.selection = [q2]
		we.update_visibility()
		# ⚠️ 缩放到 2.2 是**必要的**：减速环半径只有单位半径的 1.55 倍，
		#    1.5 倍缩放下不到 20 像素，和底盘糊在一起分不出「画了没有」。
		#    2.2 倍下四圈蓝白环一眼可辨，同时整片黏液光还在画面里。
		_main.cam_zoom = 2.2
		_main.cam_pos = spot + Vector2(24, 6)
		_main._clamp_camera()
		_main.queue_redraw()
		print("[shot] 诱捕网落地场景已就绪 cast=%s 被抓 %d 个（含空中，另有 1 个圈外对照）"
			% [str(cast_ok), caught])

	elif _frames == 700:
		_grab("39_ensnare_cast")
		print("[shot] 全部截图完成")
		return true

	return false

## 造几个假模组，专供「模组页」截图。
##
## ⚠️ 三条纪律：
##   1. **根目录用 `user://mods_shot`**，绝不碰玩家真实的 `user://mods`；
##   2. **不能在 `_initialize()` 里装** —— 装了皮肤模组的话
##      `_main.TEX["u_marine"]` 会被那张假 PNG 顶掉，
##      `20_sheet_units.png` 里的陆战队员就变成一个 8×8 色块，
##      「一眼看清美术」的用途直接报废。所以等美术总览图（第 182 帧）出完再装；
##   3. 第 366 帧删掉整个目录 + 还原 settings.cfg（`_mods_apply` 会写 `mods_state`）。
##
## 6 个模组是**算过**的：`MODS_PER_PAGE = 5`，所以正好逼出翻页按钮；
## 而且 a/b 改同一字段（黄）、c 缺 mod.json（红），一屏三种状态齐全。
func _install_shot_mods() -> void:
	var d := "user://mods_shot"
	_shot_wipe(d)
	Mods.root_dir = d
	_shot_write(d + "/a_texture/mod.json",
		'{"name":"高清贴图包","author":"someone","version":"1.2","desc":"替换单位贴图"}')
	_shot_write(d + "/b_balance/mod.json",
		'{"name":"数值重制","author":"balance_guy","version":"0.9","desc":"调整基础单位血量"}')
	# a 与 b 都改 marine.hp ⇒ **冲突**（后加载的 b 赢）
	_shot_write(d + "/a_texture/data/units.json", '{"marine":{"hp":60}}')
	_shot_write(d + "/b_balance/data/units.json", '{"marine":{"hp":70},"zergling":{"hp":28}}')
	# c 故意不写 mod.json ⇒ 列表里标红，但**照样列出来**（静默跳过更难查）
	_shot_write(d + "/c_broken/skins/README.txt", "这里故意缺 mod.json")
	_shot_write(d + "/d_maps/mod.json", '{"name":"地图合集","author":"mapper","version":"2.1"}')
	_shot_write(d + "/e_sfx/mod.json", '{"name":"音效增强","author":"audio","version":"1.0"}')
	_shot_write(d + "/f_misc/mod.json", '{"name":"杂项调整","author":"someone","version":"0.3"}')
	Mods.scan()
	# 走真实路径：应用 + 重建贴图（等价于点一下「重新扫描目录」）
	Mods.apply_all()
	_main._build_textures()

func _cleanup_shot_mods() -> void:
	_shot_wipe("user://mods_shot")
	Mods.root_dir = "user://mods"
	Mods._reset_for_test()
	GameData.reset_to_base()
	GenTex.skin_overrides.clear()
	if _cfg_existed:
		var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_cfg_backup)
			f.close()
	print("[shot] 假模组与设置已还原")

func _shot_write(p: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(p.get_base_dir()))
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()

## 递归删目录。
## ⚠️ `DirAccess.open("user://…")` 在本引擎下**恒返回 null**（见 `Mods.open_dir()`），
##    不 globalize 的话这里会静默地什么都不删。
func _shot_wipe(p: String) -> void:
	var d := DirAccess.open(ProjectSettings.globalize_path(p))
	if d == null:
		return
	var dirs: Array = []
	var files: Array = []
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			dirs.append(n)
		else:
			files.append(n)
		n = d.get_next()
	d.list_dir_end()
	for f in files:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p + "/" + String(f)))
	for sub in dirs:
		_shot_wipe(p + "/" + String(sub))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

## 在地图网格里找一块高地平台的**内部**格子（四周 3 格内全是高地）。
## 用来给截图定位 —— 平台坐标由地图生成器决定，写死会在改地图之后失效。
func _find_plateau_cell(w: World) -> Vector2i:
	var dirs: Array[Vector2i] = [Vector2i(3, 0), Vector2i(-3, 0), Vector2i(0, 3), Vector2i(0, -3)]
	for y in range(w.grid.h):
		for x in range(w.grid.w):
			if w.grid.elev_at_cell(x, y) != 1:
				continue
			var ok := true
			for d in dirs:
				if w.grid.elev_at_cell(x + d.x, y + d.y) != 1:
					ok = false
					break
			if ok:
				return Vector2i(x, y)
	return Vector2i(-1, -1)

## 把所有单位 / 建筑的贴图拼成一张总览图 —— 一眼看清美术长什么样。
func _make_art_sheet() -> void:
	_sheet(GameData.UNITS.keys(), "20_sheet_units", 7, 96)
	_sheet(GameData.BUILDINGS.keys(), "21_sheet_buildings", 6, 128)
	# 新造型放大图：总览图里 20+ 个挤在一起，新加的单位 / 建筑混在里面根本看不清。
	# 单独出一张 3 倍放大的，专供「新美术到底画成什么样」的回归对照。
	_sheet(["medic", "wraith", "scout", "mutalisk"], "22_zoom_units_new", 4, 320, 3)
	_sheet(["engineering_bay", "evolution_chamber", "forge",
		"missile_turret", "spore_colony", "photon_cannon", "stargate"],
		"23_zoom_buildings_new", 4, 320, 3)
	# 第十五轮（M5）新增的三个施法单位。单独出一张 —— `22_zoom_units_new`
	# 是第七轮的对照图，往里塞会把「那一轮画成什么样」的记录冲掉。
	#
	# ⚠️ 这三个单位的造型有三条**只有放大图能验**的约束（都写不出断言）：
	#    圣堂武士**不能有灵能刃**（否则和狂热者分不出来）、
	#    蝎子必须**扁而宽**（否则和跳虫、蟑螂糊成一团）、
	#    科学球**不能有炮管**（否则和幽灵战机混淆）。
	_sheet(["high_templar", "defiler", "science_vessel"], "24_zoom_units_m5", 3, 320, 3)
	# 第十六轮（M6）的虫后 + 虫后巢穴。
	#
	# ⚠️ 这两张的约束同样是「**只有放大图能验**」的：
	#    虫后**不能画成圆滚滚带环**（那是科学球，两个都是零攻击力的空中支援单位）、
	#    虫后巢穴**不能用圆形主轮廓**（虫族现有四个建筑全是圆形系，
	#    而它和孵化池职责最接近，缩到 0.6 倍几乎一样）。
	_sheet(["queen", "queen_nest"], "25_zoom_m6", 2, 320, 3)
	# 虫族建筑**同族对照图**（第十六轮 M6 加）。
	#
	# ⚠️ 为什么单出这一张：`_bg_zerg` 给**所有**虫族建筑画了同一个
	#    「14 根尖刺的圆环底盘」（r=40），所以外轮廓完全一样，
	#    能区分的只有半径 36 以内的**内芯**。
	#    而 `21_sheet_buildings` 是 1 倍缩放、6 列，虫族那 7 个挤在两行里，
	#    内芯只有二三十像素 —— 撞车了根本看不出来。
	#    `queen_nest` 和 `spawning_pool` 职责最接近（都是「造兵的建筑」），
	#    是这一轮最可能撞车的一对。
	_sheet(["hive", "spawning_pool", "spire", "queen_nest",
		"evolution_chamber", "extractor", "spore_colony"],
		"26_zoom_zerg_buildings", 4, 320, 3)

func _sheet(ids: Array, tag: String, cols: int, cell: int, scale: int = 1) -> void:
	var rows := int(ceil(float(ids.size()) / float(cols)))
	var img := Image.create(cols * cell, rows * cell, false, Image.FORMAT_RGBA8)
	img.fill(Color("1a2130"))
	for i in range(ids.size()):
		var id := String(ids[i])
		var d: Dictionary = GameData.UNITS[id] if GameData.is_unit(id) else GameData.BUILDINGS[id]
		var fc: Dictionary = GameData.FACTIONS[String(d["faction"])]
		# 优先用 Main 里实际生效的贴图（可能是外部皮肤），拿不到才现算程序化贴图。
		# 否则这张总览图会和实机画面不一致 —— 那就失去「一眼看清美术」的意义了。
		var key := ("u_" if GameData.is_unit(id) else "b_") + id
		var tex: Texture2D = _main.TEX.get(key, null)
		if tex == null:
			tex = GenTex.unit_sprite(id, fc["color"], fc["color_dim"], fc["accent"]) \
				if GameData.is_unit(id) else GenTex.building_sprite(id, fc["color"], fc["color_dim"], fc["accent"])
		var src := tex.get_image()
		# 放大用最近邻，不要线性插值 —— 插值会把像素风糊掉，
		# 而这张图的目的恰恰是看清像素级的造型细节。
		# 必须先 duplicate()：直接改 get_image() 拿到的图，可能动到 Main.TEX 里
		# 缓存的那份贴图数据，后面几帧的游戏画面就跟着被放大了。
		if scale > 1:
			src = src.duplicate()
			src.resize(src.get_width() * scale, src.get_height() * scale, Image.INTERPOLATE_NEAREST)
		var w := src.get_width()
		var h := src.get_height()
		var dx := (i % cols) * cell + (cell - w) / 2
		var dy := (i / cols) * cell + (cell - h) / 2
		img.blend_rect(src, Rect2i(0, 0, w, h), Vector2i(dx, dy))
	var path := OUT_DIR + tag + ".png"
	var err := img.save_png(path)
	if err != OK:
		print("[shot][FAIL] %s 保存失败 err=%d" % [tag, err])
	else:
		print("[shot][OK] %s  %dx%d  -> %s" % [tag, img.get_width(), img.get_height(), path])
func _grab(tag: String) -> void:
	var tex := root.get_texture()
	if tex == null:
		print("[shot][FAIL] %s 取不到 viewport texture" % tag)
		return
	var img := tex.get_image()
	if img == null:
		print("[shot][FAIL] %s 取不到 image" % tag)
		return
	var path := OUT_DIR + tag + ".png"
	var err := img.save_png(path)
	if err != OK:
		print("[shot][FAIL] %s 保存失败 err=%d" % [tag, err])
	else:
		print("[shot][OK] %s  %dx%d  -> %s" % [tag, img.get_width(), img.get_height(), path])
