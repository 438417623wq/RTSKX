extends Node2D

## 主场景：负责渲染世界、处理触控/鼠标输入、绘制 HUD 与建造菜单。
## 逻辑全在 World 中；本脚本只做表现与交互。

const PANEL_H := 180.0          # 底部指令面板的**默认**顶边位置（逻辑像素）
                                # 156 → 180：信息行从 1 行变 2 行（选了什么 + 这是干什么的）。
                                # M2 起真正的面板高度由 `HudLayout.panel_rect()` 从
                                # info/queue/cmd 三个模块推导；本常量只当「默认值」与
                                # 兜底（模块被隐藏时用），`tests/Touch.gd` 也还引用它。
const TOP_H := 34.0             # 顶栏**默认**高度，同上（真值见 `HudLayout.topbar_rect()`）
const TAP_SLOP := 14.0          # 位移超过此值才算「拖」，否则算「点」
## 单指手势判定阈值。手指落下后先进入「待定」状态，由这两个阈值分流：
##   位移先超过 PAN_SLOP  → 平移视野（高频操作，要求即时响应）
##   停住超过 LONG_PRESS  → 框选部队（低频操作，多花 0.25 秒没关系）
## 也就是「先动 = 平移，先停 = 框选」，不需要额外的模式按钮。
const PAN_SLOP := 12.0
## 长按进入框选的阈值（秒）。**可变** —— 设置页里能调，由 `_apply_settings()` 灌入。
## ⚠️ 默认值必须和旧常量一致（0.25）：触屏回归里有几条长按断言是按这个值卡的。
var long_press := 0.25
## 按钮尺寸。触控目标不能太小 —— 46 逻辑像素在 2400×1080 上只有 4.3mm，
## 不到 Android 48dp 建议值（7.6mm）的六成，手指很难点准。
const BTN_BUILD_W := 96.0
const BTN_BUILD_H := 84.0
const BTN_TRAIN_W := 80.0
const BTN_TRAIN_H := 72.0
const BTN_CMD_W := 76.0
const BTN_CMD_H := 56.0
const BTN_GROUP_W := 52.0
const BTN_GROUP_H := 44.0
## 外部素材的朝向补偿。只在 SKIN_ORIENTATION == "rotate" 时生效：
## 本项目程序化贴图约定「正前方 = 上方」，所以为 0；
## 若素材是「正前方 = 右方」的常见精灵图约定，改成 -PI/2。
const SKIN_FACING_OFFSET := 0.0

## 外部素材的呈现方式。
##   "upright" —— 贴图始终正立，只按朝向左右翻转。
##                侧视精灵图必须这样：跟着朝向旋转的话，坦克朝上开时会「立起来」。
##                这也是经典 2D RTS（红警、帝国时代）的标准做法。
##   "rotate"  —— 贴图跟随朝向旋转。适合真正的俯视素材，例如本项目的程序化贴图。
## 内置皮肤（Kenney CC0 素材）是侧视图，所以默认 upright。
const SKIN_ORIENTATION := "upright"

## PENDING = 手指已按下但语义未定，由位移/时间阈值决定进入 PAN 还是 BOX。
enum Sel { NONE, PENDING, PAN, BOX, DRAG }
enum St { MENU, LAN_SCAN, LOBBY, PLAY, END }
## 菜单子页面。
## 用**页面栈**而不是一个变量：模组页将来要能弹出「导入确认」再退回来，
## 单变量会一路退回主菜单。
enum Page { HOME, SINGLE, LAN, SETTINGS, MODS }

var world: World
var state := St.MENU
var race := "terran"
var difficulty := "normal"
## 当前菜单页与页面栈（栈里存 Page 值，栈顶 == _page）。
var _page := Page.HOME
var _page_stack: Array = []
## 地图预设（见 World.map_preset）。在菜单里选，开局时交给 World。
var map_preset := "plateau"
## 游戏速度倍率。只乘在喂给 world.step() 的 delta 上 ——
## 不碰任何单位数值，所以 2× 局和 1× 局的平衡性完全一致。
var game_speed := 1.0
## 暂停。暂停时**完全不推进世界**（连 AI 都不动），但 UI 照常响应。
##
## ⚠️ 局域网里「暂停」只有主机算数：客户端本来就不跑模拟，
##    它按下暂停只是停掉本地的手势/刷新，世界仍然跟着主机走。
##    真正的「双方都停」需要一条暂停协议，那是 M4c 的事。
var paused := false

# ---------------------------------------------------------------- 局域网（M4b）
#
# ★权威模拟只在主机。★ 客户端一行 `world.step()` 都不跑 ——
# 它只把主机发来的快照贴上去再画出来。
#
# ⚠️ 单机时 `session` 恒为 `null`，所有指令走原来的直连路径。
#    **新增指令时不要只写 `world.cmd_*`**，要走 `_c_*` 包装 ——
#    漏了的话症状是「客户端点了没用，单位抖一下就弹回原位」
#    （本地跑了一遍、下一份快照又把它覆盖回去），而**单机永远正常**。
## 局域网会话。单机恒为 `null`。
var session: NetSession = null
## 本机是不是**权威模拟方**。单机 = true；局域网主机 = true；局域网客户端 = false。
##
## ⚠️ 单独记一个标志，而不是每次问 `session.is_host()` ——
##    会话失败或关闭之后 `NetLink.role` 会变回 `NONE`，于是
##    `is_host()` 变 false，主机会**突然停止模拟**，
##    表现成「对方一掉线，我这局也跟着卡住了」。
var _authoritative := true
## 大厅页的状态文本（等待加入 / 连接中 / 失败原因），直接显示给玩家。
var _lan_status := ""
var _lan_status_color := Color("8fd0ff")
## 本机玩家名与要连接的主机地址。跨会话保留（存进 Settings）。
var _lan_name := "指挥官"
var _lan_ip := ""
## 客户端开局自动采矿是否已发过 —— 它要等**第一份快照**到了才有单位可指挥。
var _lan_autoharvest_done := false
## 广播发现器。**只在局域网页（还没进房间）时活着** —— 进了房间还占着
## `Net.DISCOVER_PORT` 的话，房间里再想开第二台机器就会被自己挡住。
var _discovery: NetDiscovery = null
## 对局内聊天记录。每条 `{"from": String, "text": String}`，只留最近若干条。
var _chat_log: Array = []
## 聊天记录的保留条数。**必须有上限** —— 一局打一小时，几千条全留着
## 每帧都要重画一遍，而且内存只增不减。
const CHAT_LOG_MAX := 6
## 打开中的文本输入（"" = 没打开）。见 `_lan_open_input()`。
var _lan_input_key := ""
## 打开中的输入内容（确定后才写回 `_lan_name` / `_lan_ip`）。
var _lan_input_buf := ""

# 摄像机
var cam_pos := Vector2.ZERO
var cam_zoom := 1.0

# 触屏状态：
#   单指拖动   = 平移视野（默认；手指一动就判定为平移）
#   长按后拖动 = 框选部队（停住 0.25 秒再动）
#   双指拖动   = 平移镜头 · 双指捏合 = 缩放
#   小地图     = 点 / 拖跳转
# 默认给平移的理由：单指推镜是最高频操作，必须零延迟；
# 框选是低频操作，多花 0.25 秒完全可接受。
var _touches := {}                  # id -> {pos, start, time}
var _sel_mode := Sel.NONE
var _sel_start := Vector2.ZERO
var _sel_rect := Rect2()
## 单指拖动语义。true = 拖动平移 / 长按框选（默认）；false = 拖动框选 / 长按平移。
var _single_drag_pans := true
## 长按进入框选时的一次性视觉反馈计时
var _long_press_feedback := 0.0
# 双指手势
var _pinch_active := false
var _pinch_dist := 0.0
var _pinch_mid := Vector2.ZERO
var _pinch_zoom_start := 1.0
# 双击识别（双击 = 全选）
var _prev_tap_time := 0.0
var _prev_tap_pos := Vector2.ZERO
# 小地图
var _minimap_rect := Rect2()
var _minimap_tex: ImageTexture = null
var _minimap_fog_tex: ImageTexture = null
var _minimap_fog_timer := 0.0
var _minimap_id := -1
## 地貌图：每格 1 像素的低频色带，拉伸后铺在地面上。
## 没有它，整张地图就是一大片均匀的地面 —— 有了它才有「地形」的感觉。
var _biome_tex: ImageTexture = null
# 攻击移动模式
var _attack_move_mode := false

# UI 状态
var _build_menu_open := false
var _placing_build := ""
var _ghost_pos := Vector2.ZERO

## 法术瞄准态。非空时，下一次点地图 = 施放这个法术。
##
## 复刻「放置建筑」那套交互（按下 → 拖动改落点 → 松手确认），
## 而不是「点一下技能、再点一下地图」两步 —— 触屏上后者中间那一下
## 很容易被误判成平移视野，玩家会觉得「点了没反应」。
var _aim_spell := ""
var _aim_pos := Vector2.ZERO
var _aim_drag_id := -1

var _toasts: Array = []
var _show_help := false

# UI 命中表 —— 每帧由各 _draw_* 重建，触摸按下时倒序查找（后画的在上层）。
#
# 之前是用「屏幕 y 坐标落在面板 / 顶栏里」来猜一次触摸是不是 UI 操作，
# 结果建造菜单画在面板**上方**（浮层），永远被当成点地图 —— 点了没反应，
# 还会顺手给选中的农民下一条移动指令。
# 改成显式登记后，任何位置的浮层 / 悬浮按钮都自动可点。
var _ui_hits: Array = []            # [{rect, act, arg}]
var _ui_press_hit := {}

# 音效播放池 —— 几百个单位同时开火会直接爆音 + 掉帧，
# 所以必须限制并发：轮转复用固定的播放器，并对同一种音效限流。
const SFX_VOICES := 16
const SFX_MIN_GAP := 0.045          # 同一种音效的最小间隔（秒）
const SFX_PER_FRAME := 4            # 单帧最多触发几个
const SFX_RANGE := 620.0            # 超出这个距离就听不见
var _sfx_players: Array = []
var _sfx_last := {}                 # kind -> 上次播放时刻
var _sfx_next := 0                  # 播放池轮转游标
var _sfx_frame_count := 0
var _sfx_volume := 0.7
var _sfx_on := true

var font: Font
var TEX := {}
var _skins_loaded := 0
var _skin_names := {}               # 记录哪些贴图来自外部素材（决定呈现方式）
## 菌毯斑点的 4 个轮廓变体（见 _build_textures）。
## 不做成 TEX 里的固定键：它按格子坐标哈希轮换使用，不是「一种贴图」。
var _creep_variants: Array = []

func _ready() -> void:
	randomize()
	_acquire_font()
	# 设置必须在任何 UI 之前读入 —— 音量、手势语义、默认难度都从这里取初值。
	Settings.load_all()
	_apply_settings()
	print("[Skin] 外部素材目录：", GenTex.ensure_skin_dir())
	# ⚠️ 模组必须在**贴图烘焙之前**加载：皮肤覆盖表要先填好，
	#    否则 `_build_textures()` 会先按程序化贴图烘焙一遍、模组皮肤一张都不生效
	#    —— 而且不报错，只是「我明明放了皮肤却没换」。
	#    `Mods.apply_all()` 末尾会 `GameData.freeze()`，那之后数值表只读。
	print("[Mods] 模组目录：", Mods.ensure_dir())
	Mods.scan()
	var mr := Mods.apply_all()
	var m_err: Array = mr["errors"]
	print("[Mods] 已装 %d 个（启用 %d）· 皮肤 %d 张 · 覆盖 %d 个字段%s"
		% [Mods.list.size(), Mods.enabled_list().size(), int(mr["skins"]), int(mr["fields"]),
			"" if m_err.is_empty() else " · 错误 " + str(m_err)])
	_build_textures()
	_build_sfx()
	var args := OS.get_cmdline_user_args()
	if OS.has_feature("editor") and args.is_empty():
		# 编辑器内直接开局，便于调试
		pass

## 把设置里的值灌进运行期成员。
##
## 单独一个函数的理由：菜单里改设置时**只写 Settings**，等真正开局或返回菜单时
## 再调这个 —— 这样「改了没保存就返回」不会污染当前对局，
## 也让「设置项有没有真的生效」有唯一一个可测的入口。
func _apply_settings() -> void:
	_sfx_on = Settings.flag("sfx_on", true)
	_sfx_volume = Settings.num("sfx_volume", 0.7)
	_single_drag_pans = Settings.flag("drag_pans", true)
	long_press = Settings.num("long_press", 0.25)
	difficulty = Settings.text("default_difficulty", "normal")
	map_preset = Settings.text("default_map", "plateau")
	game_speed = float(Settings.text("default_speed", "1"))
	Engine.max_fps = int(Settings.text("max_fps", "60"))
	# 联机用的名字与主机地址。**跨会话保留** —— 每次联机都要重输一遍 IP
	# 是手机上最劝退的一件事（一个 192.168.x.x 要按十几次）。
	_lan_name = Settings.text("player_name", "指挥官")
	_lan_ip = Settings.text("lan_ip", "")

## 音效池：预建若干个 AudioStreamPlayer 轮转复用。
## 不用 AudioStreamPlayer2D —— 本作没有立体声定位需求，
## 自己算距离衰减反而更可控，也更好在无头测试里跳过。
func _build_sfx() -> void:
	var t0 := Time.get_ticks_msec()
	GenSfx.prewarm()
	for i in range(SFX_VOICES):
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_sfx_players.append(p)
	print("[Sfx] 音效就绪：%d 个播放通道，耗时 %d ms" % [SFX_VOICES, Time.get_ticks_msec() - t0])

## 播放一个音效事件。限流与空间化全部集中在这里：
##   · 迷雾里看不见的位置不播（否则会听到看不见的战斗）
##   · 屏幕外 / 超出 SFX_RANGE 的不播
##   · 同一种音效最小间隔 SFX_MIN_GAP，单帧最多 SFX_PER_FRAME 个
##   · 按距离衰减
## 这几条缺任何一条，几百单位交火时都会爆音 + 掉帧。
func _play_sfx(kind: String, pos: Vector2) -> void:
	if not _sfx_on or _sfx_players.is_empty() or world == null:
		return
	if world.vis.is_empty() or not world.is_visible(pos):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_sfx_last.get(kind, -99.0)) < SFX_MIN_GAP:
		return
	var dist: float = cam_pos.distance_to(pos)
	if dist > SFX_RANGE:
		return
	_sfx_last[kind] = now
	_sfx_frame_count += 1
	if _sfx_frame_count > SFX_PER_FRAME:
		return
	var p: AudioStreamPlayer = _sfx_players[_sfx_next % SFX_VOICES]
	_sfx_next += 1
	var atten := 1.0 - dist / SFX_RANGE
	p.stream = GenSfx.get_sfx(kind)
	p.volume_db = linear_to_db(maxf(0.02, atten * atten * _sfx_volume))
	# 轻微音高抖动：同一种音效连发时不会听起来像复读机
	p.pitch_scale = randf_range(0.93, 1.07)
	p.play()

func _on_sfx(kind: String, pos: Vector2) -> void:
	_play_sfx(kind, pos)

## 无视限流与位置直接播放：胜负音、界面音这类「必须响」的。
func _play_direct(kind: String) -> void:
	if not _sfx_on or _sfx_players.is_empty():
		return
	var p: AudioStreamPlayer = _sfx_players[_sfx_next % SFX_VOICES]
	_sfx_next += 1
	p.stream = GenSfx.get_sfx(kind)
	p.volume_db = linear_to_db(maxf(0.02, _sfx_volume))
	p.pitch_scale = 1.0
	p.play()

# ---------------------------------------------------------------- 字体
func _acquire_font() -> void:
	var sys := SystemFont.new()
	sys.font_names = PackedStringArray([
		"Noto Sans CJK SC", "Source Han Sans SC", "Microsoft YaHei",
		"PingFang SC", "SimHei", "Noto Sans SC", "sans-serif",
	])
	sys.allow_system_fallback = true
	sys.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	font = sys

# ---------------------------------------------------------------- 程序化贴图
## 全部贴图都在启动时用代码生成一次并缓存。零外部素材 —— 也就不存在任何版权问题。
##
## 想换美术？不用改代码：把 PNG 丢进 user://skins/ 即可（命名规则见该目录下的
## README.txt）。有同名文件就用文件，没有就回退到程序化贴图。
func _build_textures() -> void:
	var t0 := Time.get_ticks_msec()
	_skins_loaded = 0
	_skin_names.clear()
	# 地形与资源
	# 配色走卡通路线：比写实暗科幻**更亮、更饱和**。
	# 卡通画面的明度普遍偏高、色相更明确；压得太暗会立刻回到「写实军事」的观感。
	# 但仍然压住明度上限 —— 地面太亮会跟单位抢视觉，也会让迷雾层显得脏。
	TEX["ground"] = _pick("ground", func(): return GenTex.ground_tile(Color("3a4d68"), Color("587ba6")))
	TEX["ground_patch"] = _pick("ground_patch", func(): return GenTex.ground_patch(Color("1b2434"), Color("44648e")))
	TEX["rock"] = _pick("rock", func(): return GenTex.rock_tile(Color("6b7a9c"), Color("434d68")))
	TEX["chasm"] = _pick("chasm", func(): return GenTex.chasm_tile(Color("0b1c2e"), Color("1a4258")))
	TEX["mineral"] = _pick("mineral", func(): return GenTex.mineral_cluster(Color("59c8ff"), Color("1b5c85")))
	TEX["gas"] = _pick("gas", func(): return GenTex.gas_cluster(Color("7de08a"), Color("1d5c34")))
	TEX["glow"] = GenTex.soft_disc(64, Color(1, 1, 1, 0.5))
	TEX["shadow"] = GenTex.soft_disc(64, Color(0, 0, 0, 0.42))
	# 菌毯斑点：生成 4 个「轮廓相位」不同的变体，渲染时按格子坐标哈希选一张。
	# 只做一张的话每格图案完全相同，整片铺出来会看到明显的重复纹理。
	#
	# 走「紫色偏暗」而不是鲜紫：它要压在深蓝地面上，太亮会盖过单位和资源点，
	# 反而看不出谁站在上面。
	_creep_variants.clear()
	for i in range(4):
		_creep_variants.append({
			"body": GenTex.creep_blob(64, Color(0.46, 0.17, 0.60, 0.58), i),
			"edge": GenTex.creep_blob(64, Color(0.80, 0.48, 0.98, 0.32), i),
		})
	# 单位 / 建筑：按 id 逐一定制贴图
	for id in GameData.UNITS:
		var ud: Dictionary = GameData.UNITS[id]
		var uf: Dictionary = GameData.FACTIONS[String(ud["faction"])]
		var ukey := "u_" + String(id)
		TEX[ukey] = _pick(ukey, func(): return GenTex.unit_sprite(
			String(id), uf["color"], uf["color_dim"], uf["accent"]))
	for id in GameData.BUILDINGS:
		var bd: Dictionary = GameData.BUILDINGS[id]
		var bf: Dictionary = GameData.FACTIONS[String(bd["faction"])]
		var bkey := "b_" + String(id)
		TEX[bkey] = _pick(bkey, func(): return GenTex.building_sprite(
			String(id), bf["color"], bf["color_dim"], bf["accent"]))
	print("[Art] 贴图就绪：%d 张（其中外部素材 %d 张），耗时 %d ms"
		% [TEX.size(), _skins_loaded, Time.get_ticks_msec() - t0])

## 优先用外部素材，没有才现算程序化贴图。
## maker 传 Callable 而不是 ImageTexture —— 否则即使有外部素材，
## 程序化贴图也会被白白生成一遍，白白多花两秒启动时间。
func _pick(name: String, maker: Callable) -> Texture2D:
	var skin := GenTex.load_skin(name)
	if skin != null:
		_skins_loaded += 1
		_skin_names[name] = true
		return skin
	return maker.call() as Texture2D

# ---------------------------------------------------------------- 开局
func start_game(p_race: String, p_diff: String, p_map: String = "") -> void:
	# 单机开局。**先把上一局的局域网会话关掉** ——
	# 不关的话，上一局的 session 还活着，`_process` 会一边跑本地模拟
	# 一边把快照发给对方，而 `_authoritative` 也可能停在 false（如果上一局是客户端），
	# 症状是「单机开局后单位不动」。
	_close_session()
	# 先把上一局的 UI 状态清干净。
	# 少了这一步，上一局留下的放置模式会飘到新局里 ——
	# 症状是顶栏一直显示「拖动放置 传送门，松手确认」，而这一局根本没有传送门。
	_selection_clear()
	race = p_race
	difficulty = p_diff
	if p_map != "":
		map_preset = p_map
	# 设置里勾了「开局自动暂停」就以暂停态开局，方便先看清地图再动手。
	paused = Settings.flag("autopause", false)
	world = World.new(64, 40, p_race, _opponent_of(p_race), p_diff, map_preset)
	world.event_alert.connect(_on_alert)
	world.game_over.connect(_on_game_over)
	world.event_sfx.connect(_on_sfx)
	state = St.PLAY
	cam_pos = Vector2(10 * Grid.CELL, world.world_size.y * 0.5)
	_build_minimap_texture()
	_build_biome_texture()
	_minimap_fog_timer = 0.0
	# 开局选中所有单位，方便立刻上手
	world.selection = world.units_of(_me()).duplicate()
	# 初始农民自动采矿
	var workers := []
	for u in world.selection:
		if u.can_harvest():
			workers.append(u)
	if not workers.is_empty():
		var node = null
		for r in world.resources:
			if node == null or workers[0].pos.distance_squared_to(r["pos"]) < workers[0].pos.distance_squared_to(node["pos"]):
				node = r
		if node != null:
			_c_harvest(workers, node)
	queue_redraw()

func _opponent_of(r: String) -> String:
	match r:
		"terran": return "zerg"
		"zerg": return "protoss"
		_: return "terran"

# ---------------------------------------------------------------- 阵营口径
#
# ★**凡是「我的 / 敌方的」判断一律走这两个函数，不要写死 `World.PLAYER`。**★
#
# 单机时 `world.local_owner` 恒为 `World.PLAYER`，所以换成 `_me()` 之后
# **行为逐字节不变**（全量回归是这么验的）。但局域网客户端是 `World.ENEMY` ——
# 写死的话症状是「客户端把自己的部队当成敌人」：
# 不画（迷雾过滤掉）、点不中、框选不到、HUD 显示敌方资源，
# 而**单机永远测不出来**。
func _me() -> int:
	return world.local_owner if world != null else World.PLAYER

func _foe() -> int:
	return World.ENEMY if _me() == World.PLAYER else World.PLAYER

func _on_alert(pos: Vector2, text: String, color: Color) -> void:
	_toasts.append({"text": text, "color": color, "life": 2.6, "max": 2.6})
	if _toasts.size() > 4:
		_toasts.pop_front()
	_play_sfx("ui_error", pos)

# ================================================================ 指令分发
#
# ★**所有**玩家指令都必须走下面这组 `_c_*` 包装。★
#
# 单机：直接调 `world.cmd_*`，行为和以前**逐字节一致**。
# 局域网：编码成 `CMD` 包交给会话 ——
#   主机侧由 `NetSession.send_cmd()` **本地走一遍解码 + 应用**（拿到真实结果）；
#   客户端侧发给主机，真正结果通过 `cmd_rejected` 信号回来。
#
# ⚠️ 漏掉一处包装（直接写 `world.cmd_*`）的症状：
#    客户端点了没反应、单位抖一下就弹回原位（本地跑了一遍，下一份快照又覆盖回去），
#    而**单机永远正常** —— 这类漏网在无头测试里也看不出来。
#    所以新增指令时先加包装函数，再去调用点。

## 发一条指令（局域网用）。返回主机给的真实结果。
## 单机路径不会走到这里。
func _send_cmd(kind: int, ids: Array, p: Dictionary = {}) -> bool:
	if session == null:
		return false
	var r := session.send_cmd(kind, ids, p)
	var why := String(r.get("reason", ""))
	if not bool(r["ok"]) and why != "":
		_toast(why, Color("ffd166"))
	return bool(r["ok"])

## 单位数组 → id 数组。**指令里传的是 id 而不是对象引用** ——
## 客户端和主机是两份独立的世界，对象根本没法互指。
func _ids_of(arr: Array) -> Array:
	var out: Array = []
	for u in arr:
		out.append(int(u.id))
	return out

## 资源节点 → 它在 `world.resources` 里的下标（指令里传下标而不是字典）。
##
## ⚠️ 用 `is_same()` 比引用，不要用 `find()` / `==` ——
##    `world.resources` 里是 Dictionary，值比较的语义很容易踩空
##    （两个矿点字段全等时 `find()` 会返回第一个）。
func _node_idx(node) -> int:
	if node == null:
		return -1
	for i in range(world.resources.size()):
		if is_same(world.resources[i], node):
			return i
	return -1

func _c_move(units_arr: Array, pos: Vector2, attack_mode: bool = false) -> void:
	if session == null:
		world.cmd_move(units_arr, pos, attack_mode)
		return
	_send_cmd(Net.Cmd.MOVE, _ids_of(units_arr),
		{"x": pos.x, "y": pos.y, "flags": 1 if attack_mode else 0})

func _c_attack(units_arr: Array, target) -> void:
	if session == null:
		world.cmd_attack(units_arr, target)
		return
	_send_cmd(Net.Cmd.ATTACK, _ids_of(units_arr), {"target_id": int(target.id)})

func _c_smart(units_arr: Array, pos: Vector2, node, entity) -> void:
	if session == null:
		world.cmd_smart(units_arr, pos, node, entity)
		return
	var p := {"x": pos.x, "y": pos.y, "node_idx": _node_idx(node)}
	if entity != null:
		p["target_id"] = int(entity.id)
	_send_cmd(Net.Cmd.SMART, _ids_of(units_arr), p)

func _c_stop(units_arr: Array) -> void:
	if session == null:
		world.cmd_stop(units_arr)
		return
	_send_cmd(Net.Cmd.STOP, _ids_of(units_arr))

func _c_harvest(units_arr: Array, node) -> void:
	if session == null:
		world.cmd_harvest(units_arr, node)
		return
	_send_cmd(Net.Cmd.HARVEST, _ids_of(units_arr), {"node_idx": _node_idx(node)})

func _c_build(type_id: String, pos: Vector2, workers: Array) -> bool:
	if session == null:
		return world.cmd_build(type_id, pos, _me(), workers)
	# 客户端这里返回的是「已发出」，真正的结果由主机回 REJECT ——
	# 于是建造幽灵会先消失，被拒时再弹提示。有延迟但不会「卡着放不下」。
	return _send_cmd(Net.Cmd.BUILD, _ids_of(workers),
		{"type_id": type_id, "x": pos.x, "y": pos.y})

func _c_train(building, type_id: String) -> bool:
	if session == null:
		return world.cmd_train(building, type_id)
	return _send_cmd(Net.Cmd.TRAIN, [],
		{"building_id": int(building.id), "type_id": type_id})

func _c_research(building, uid: String) -> bool:
	if session == null:
		return world.cmd_research(building, uid)
	return _send_cmd(Net.Cmd.RESEARCH, [],
		{"building_id": int(building.id), "upgrade_id": uid})

func _c_ability(units_arr: Array, aid: String, target) -> bool:
	if session == null:
		return world.cmd_ability(units_arr, aid, target)
	var p := {"ability_id": aid}
	# 点地法术传的是 `Vector2` 落点，不是实体 —— 指令记录里本来就有 `x/y`
	# 两个 f32 字段，不用改线格式。
	# ⚠️ 顺序不能反：`Vector2` 也是 `Variant`，写成 `elif target != null`
	#    在前面的话，落点会被当成实体去取 `.id`，直接抛错。
	if target is Vector2:
		p["x"] = target.x
		p["y"] = target.y
	elif target != null:
		p["target_id"] = int(target.id)
	return _send_cmd(Net.Cmd.ABILITY, _ids_of(units_arr), p)

func _c_cancel_build(building) -> bool:
	if session == null:
		return world.cancel_build(building)
	return _send_cmd(Net.Cmd.CANCEL_BUILD, [], {"building_id": int(building.id)})

func _c_cancel_queue(building, index: int) -> bool:
	if session == null:
		return world.cancel_queue(building, index)
	return _send_cmd(Net.Cmd.CANCEL_QUEUE, [],
		{"building_id": int(building.id), "flags": index})

func _c_rally(building, pos: Vector2) -> void:
	if session == null:
		building.rally = pos
		building.has_rally = true
		return
	_send_cmd(Net.Cmd.RALLY, [], {"building_id": int(building.id), "x": pos.x, "y": pos.y})

# ================================================================ 局域网会话

## 接管一个会话。`w` 为主机侧已建好的世界；客户端传 `null`（世界要等 WELCOME）。
func _attach_session(s: NetSession, w: World, authoritative: bool) -> void:
	_close_session()
	session = s
	_authoritative = authoritative
	_lan_autoharvest_done = false
	# ⚠️ **无条件覆盖 `world`（包括置 null）** ——
	#    写成 `if w != null: world = w` 的话，「先开过主机房间 → 退出 → 再当客户端加入」
	#    会把主机那份旧世界留在 `world` 上，而 `_on_lan_ready()` 只在
	#    `world == null` 时才接管 `session.world` → **客户端全程在玩主机的世界**，
	#    而且不报错（地图、部队、资源全是对方的）。
	#    单机路径不受影响：`world` 由 `start_game()` 自己建。
	world = w
	s.session_ready.connect(_on_lan_ready)
	s.session_failed.connect(_on_lan_failed)
	s.cmd_rejected.connect(_on_cmd_rejected)
	s.peer_left.connect(_on_lan_peer_left)
	s.peer_joined.connect(_on_lan_peer_joined)
	s.chat_received.connect(_on_lan_chat)
	s.peer_surrendered.connect(_on_lan_surrender)
	s.pause_changed.connect(_on_lan_pause)
	s.lobby_updated.connect(func(): queue_redraw())
	s.game_started.connect(func(): queue_redraw())
	# 进房间了就关掉发现器 —— 别让它一直占着广播端口。
	_stop_discovery()

## 关掉会话（优雅退出）。单机时是空操作。
##
## ⚠️ 必须走 `NetSession.close()` 而不是丢掉引用 ——
##    直接丢掉的话 ENet host 不会被销毁，对方要等自己的超时才知道我们走了。
func _close_session() -> void:
	if session != null:
		session.close()
		session = null
	_authoritative = true
	_lan_status = ""
	_lan_status_color = Color("8fd0ff")
	_lan_autoharvest_done = false
	# 聊天记录属于**这一局**。不清的话下一局进来会看到上一局的发言，
	# 而玩家会以为对方在说话。
	_chat_log.clear()
	if _lan_input_key == "chat":
		_lan_input_key = ""
		_lan_input_buf = ""

func _on_lan_ready() -> void:
	# ⚠️ 用 `session.world` 无条件接管 —— 不再写 `if world == null`。
	#    那条守卫会让「上一局的旧世界」永远不被顶掉（见 `_attach_session()`）。
	if session == null or session.world == null:
		_on_lan_failed("世界没有建出来")
		return
	world = session.world
	world.local_owner = session.local_owner
	world.event_alert.connect(_on_alert)
	world.game_over.connect(_on_game_over)
	world.event_sfx.connect(_on_sfx)
	state = St.PLAY
	_lan_status = ""
	cam_pos = Vector2(10 * Grid.CELL, world.world_size.y * 0.5)
	_build_minimap_texture()
	_build_biome_texture()
	_minimap_fog_timer = 0.0
	_lan_autoharvest_done = false
	_toast("对局开始 · 你是 %s" % ("主机" if _authoritative else "客户端"), Color("8fe36b"))
	queue_redraw()

func _on_lan_failed(reason: String) -> void:
	_lan_status = reason
	_lan_status_color = Color("ff9a8f")
	_toast(reason, Color("ff9a8f"))
	if state == St.PLAY:
		# 打了一半掉线：留在结算画面，让玩家看到结果再退
		state = St.END
	else:
		state = St.MENU
		_page = Page.LAN
	queue_redraw()

func _on_lan_peer_left(_peer_id: int, why: String) -> void:
	# 主机侧：对方走了，但**世界还是完整的**（权威模拟在本机），
	# 所以不结束对局，只提示一句。
	_toast(why, Color("ffd166"))

func _on_lan_peer_joined(_peer_id: int) -> void:
	_toast("有玩家加入了", Color("8fe36b"))

func _on_cmd_rejected(_seq: int, reason: String) -> void:
	if reason != "":
		_toast(reason, Color("ffd166"))

## 开局自动采矿（局域网版）。
##
## ⚠️ 客户端**不能**在 `session_ready` 那一刻做：客户端的世界是收到 WELCOME
##    才建的，而 `NetSession._build_world()` 会 `reset_dynamic()` 把开局赠兵清掉 ——
##    所以那一刻 `world.units` 是**空的**，选农民会选到零个，
##    然后自动采矿静默不发生（兵站着不动，玩家以为联机坏了）。
##    所以这里每帧试一次，直到第一份快照把部队送过来。
func _lan_autoharvest() -> void:
	if _lan_autoharvest_done or session == null or world == null:
		return
	var workers: Array = []
	for u in world.units_of(_me()):
		if u.can_harvest():
			workers.append(u)
	if workers.is_empty():
		return
	_lan_autoharvest_done = true
	var node = null
	for r in world.resources:
		if node == null or workers[0].pos.distance_squared_to(r["pos"]) \
				< workers[0].pos.distance_squared_to(node["pos"]):
			node = r
	if node != null:
		_c_harvest(workers, node)

# ================================================================ 屏幕键盘（局域网输入）

## IP 地址用的键集。**故意只有数字和点** —— 输 IP 用不上字母。
const PAD_IP := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ".", "⌫"]
## 玩家名用的键集。**故意不做中文输入** —— 联机里要输的只有 IP 和昵称，
## 为它挂一个输入法远不划算（见 `lan_keypad_rects()` 的注释）。
const PAD_NAME := [
	"Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P",
	"A", "S", "D", "F", "G", "H", "J", "K", "L", "-",
	"Z", "X", "C", "V", "B", "N", "M", "_", "0", "1",
	"2", "3", "4", "5", "6", "7", "8", "9", " ", "⌫",
]

## 屏幕键盘的命中表。**纯函数** —— 绘制、命中、测试三边读同一份。
##
## 为什么自己画键盘，而不是用系统软键盘（`DisplayServer.virtual_keyboard_show`）：
##   1. 系统软键盘要挂一个真的 `LineEdit` 控件，而本项目所有 UI 都是
##      `_draw()` 手绘 + 纯函数命中表 —— 混进来一个 Control，
##      「无头测试能覆盖输入逻辑」这条线就断了（菜单页踩过同样的坑）。
##   2. 安卓上软键盘会**顶起整个视口**，而 `get_viewport_rect()` 在
##      真机与无头下本来就不一样（1280×720 vs 1280×1280），
##      再叠一层视口变化，布局很容易在真机上错位。
##   3. 要输的只有 IP 和昵称，0-9 / A-Z / `.` / `-` / `_` 就够。
func lan_keypad_rects(vp: Vector2) -> Array:
	var keys: Array = PAD_IP if _lan_input_key == "ip" else PAD_NAME
	var cols := 6 if _lan_input_key == "ip" else 10
	var gap := 10.0
	var kw := minf(150.0, (vp.x - 80.0 - gap * float(cols - 1)) / float(cols))
	var kh := 62.0
	var rows := int(ceil(float(keys.size()) / float(cols)))
	var total_w := kw * float(cols) + gap * float(cols - 1)
	var total_h := kh * float(rows + 1) + gap * float(rows) + 96.0
	var x0 := vp.x * 0.5 - total_w * 0.5
	var y0 := maxf(FORM_HEAD_H, vp.y * 0.5 - total_h * 0.5 + 30.0)
	var out := []
	for i in range(keys.size()):
		var c := i % cols
		var rw := i / cols
		out.append({
			"rect": Rect2(x0 + float(c) * (kw + gap), y0 + float(rw) * (kh + gap), kw, kh),
			"key": String(keys[i]),
		})
	var by := y0 + float(rows) * (kh + gap) + gap
	var bw := (total_w - gap) * 0.5
	out.append({"rect": Rect2(x0, by, bw, kh), "key": "取消"})
	out.append({"rect": Rect2(x0 + bw + gap, by, bw, kh), "key": "确定"})
	return out

## 键盘背板矩形（绘制用）。由命中表推出来 —— 不另算一套坐标，
## 否则改一次键距就会出现「面板和按键对不上」。
func lan_keypad_panel(vp: Vector2) -> Rect2:
	var rs := lan_keypad_rects(vp)
	if rs.is_empty():
		return Rect2()
	var first: Rect2 = rs[0]["rect"]
	var last: Rect2 = rs[rs.size() - 1]["rect"]
	var x0 := first.position.x - 24.0
	var y0 := first.position.y - 74.0
	return Rect2(x0, y0, (last.end.x + 24.0) - x0, (last.end.y + 24.0) - y0)

## 打开文本输入。`key` 取 `"name"` / `"ip"` / `"chat"`。
func _lan_open_input(key: String) -> void:
	_lan_input_key = key
	match key:
		"name":
			_lan_input_buf = _lan_name
		"ip":
			_lan_input_buf = _lan_ip
		_:
			# 聊天：**每次从空开始**。带出上一条的话，玩家要先把旧内容删干净，
			# 而 `⌫` 一次只删一个字符 —— 在手机上非常难受。
			_lan_input_buf = ""
	# 键盘是模态的，清掉可能残留的「主按钮按下」状态，
	# 否则松手时会用旧矩形判一次，直接把对局开起来。
	_menu_press_rect = Vector2.ZERO
	_btn_primary = Rect2()
	queue_redraw()

func _lan_input_press(key: String) -> void:
	match key:
		"取消":
			_lan_input_key = ""
			_lan_input_buf = ""
		"确定":
			_lan_input_commit()
		"⌫":
			if _lan_input_buf.length() > 0:
				_lan_input_buf = _lan_input_buf.substr(0, _lan_input_buf.length() - 1)
		_:
			# 上限按输入类型分：名字 / IP 很短，聊天要能说一整句。
			# 共用 24 的话，聊天只能打 24 个字母 —— 话都说不完。
			var cap := 60 if _lan_input_key == "chat" else 24
			if _lan_input_buf.length() < cap:
				_lan_input_buf += key
	queue_redraw()

func _lan_input_commit() -> void:
	var v := _lan_input_buf.strip_edges()
	var key := _lan_input_key
	_lan_input_key = ""
	_lan_input_buf = ""
	if key == "name":
		_lan_name = v if v != "" else "指挥官"
		Settings.set_v("player_name", _lan_name)
		Settings.save_all()
		_toast("玩家名：" + _lan_name, Color("8fe36b"))
	elif key == "ip":
		_lan_ip = v
		Settings.set_v("lan_ip", _lan_ip)
		Settings.save_all()
		_toast("主机地址：" + (_lan_ip if _lan_ip != "" else "（还没填）"),
			Color("8fe36b") if _lan_ip != "" else Color("ffd166"))
	elif key == "chat":
		# ⚠️ **不在 Settings 里存**（`key == "chat"` 与上面两个分支的区别）：
		#    聊天内容是临时的，落盘的话下次打开游戏还能看到上一局的发言。
		if v != "":
			_send_chat(v)
	queue_redraw()

func _draw_lan_keypad(vp: Vector2) -> void:
	var panel := lan_keypad_panel(vp)
	# 全屏压暗：键盘是模态的，底下的菜单项不该被误触
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.58), true)
	draw_rect(panel, Color(0.055, 0.070, 0.110, 0.98), true)
	draw_rect(panel, Color(0.40, 0.62, 0.90, 0.45), false, 1.2)
	var title := "玩家名"
	if _lan_input_key == "ip":
		title = "主机地址（例：192.168.1.7）"
	elif _lan_input_key == "chat":
		title = "发言（对方会立刻看到）"
	draw_string(font, Vector2(panel.position.x + 24.0, panel.position.y + 34.0),
		title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18.0, Color(0.90, 0.94, 1.0))
	# 当前输入内容 + 光标块。没有它玩家不知道自己在往哪儿输。
	var shown := _lan_input_buf if _lan_input_buf != "" else "…"
	draw_string(font, Vector2(panel.position.x + 24.0, panel.position.y + 62.0),
		shown + "_", HORIZONTAL_ALIGNMENT_LEFT, panel.size.x - 48.0, 16.0, Color("8fd0ff"))
	for m in lan_keypad_rects(vp):
		var r: Rect2 = m["rect"]
		var k := String(m["key"])
		var bg := Color(1, 1, 1, 0.07)
		var bd := Color(1, 1, 1, 0.16)
		if k == "取消":
			bg = Color(0.75, 0.35, 0.30, 0.30)
			bd = Color("ff9a8f")
		elif k == "确定":
			bg = Color(0.56, 0.89, 0.42, 0.26)
			bd = Color("8fe36b")
		draw_rect(r, bg, true)
		draw_rect(r, bd, false, 1.2)
		_draw_text_center(k, r, 17.0, Color(0.94, 0.97, 1.0))

# ================================================================ 局域网开局

## 创建房间（我是主机）。
##
## `p_port` 只给测试用 —— 生产路径走 `Net.PORT`（27015），
## 而测试必须换一个端口，否则开发机上正好跑着一个真实例时就是「随机失败」。
func _lan_host(p_port: int = Net.PORT) -> void:
	if session != null:
		_toast("已经在房间里了", Color("ffd166"))
		return
	# ⚠️ 难度固定 `normal`：`World` 按 `DIFFICULTY[difficulty]["ai_eco"]` 给 ENEMY
	#    发初始资源，难度不同就**开局资源不对等** —— 联机 1v1 里等于开局定胜负。
	#    （AI 本身在联机里是关掉的，见 `World.ai_enabled`。）
	var made := NetSession.create_host_world(64, 40, race, _opponent_of(race),
		"normal", map_preset)
	var w: World = made["world"]
	var s := NetSession.new()
	if not s.start_host(w, int(made["seed"]), p_port, _lan_name):
		_toast("开房间失败：" + s.last_error, Color("ff9a8f"))
		return
	_attach_session(s, w, true)
	state = St.LOBBY
	# ⚠️ 状态行**不再拼地址** —— 地址由 `_draw_lobby()` 单独放大显示
	#    （见 `lan_address_lines()`）。两处都写的话同一串数字会出现两遍，
	#    而且状态行那一遍又长又挤。
	_lan_status = "等待玩家加入…"
	_lan_status_color = Color("8fd0ff")
	_toast("房间已创建", Color("8fe36b"))

## 加入房间（我是客户端）。`p_port` 同 `_lan_host()`，只给测试用。
func _lan_join(p_port: int = Net.PORT) -> void:
	if session != null:
		_toast("已经在房间里了", Color("ffd166"))
		return
	var ip := _lan_ip.strip_edges()
	if ip == "":
		_toast("先填主机地址", Color("ffd166"))
		_lan_open_input("ip")
		return
	var s := NetSession.new()
	if not s.start_client(ip, p_port, _lan_name):
		_toast("连接失败：" + s.last_error, Color("ff9a8f"))
		return
	_attach_session(s, null, false)
	state = St.LOBBY
	_lan_status = "正在连接 %s …" % ip
	_lan_status_color = Color("8fd0ff")

## 退出大厅 / 取消连接。
func _lan_leave() -> void:
	_close_session()
	state = St.MENU
	_page = Page.LAN
	queue_redraw()

# ---------------------------------------------------------------- 大厅：准备 / 开始 / 广播发现

## 主机点「开始游戏」。
func _lan_start() -> void:
	if session == null:
		return
	if not session.begin_game():
		# ⚠️ 失败必须说清**为什么** —— 只是「点了没反应」的话，
		#    主机只会反复点，然后以为联机坏了。
		_toast(session.last_error, Color("ffd166"))
		return
	_stop_discovery()
	_toast("对局开始", Color("8fe36b"))

## 客户端点「我准备好了 / 取消准备」。
func _lan_toggle_ready() -> void:
	if session == null:
		return
	var want := not session.client_ready()
	if not session.set_ready(want):
		_toast(session.last_error, Color("ffd166"))
		return
	_toast("已准备，等主机开始" if want else "已取消准备",
		Color("8fe36b") if want else Color("ffd166"))

## 从广播列表点了一行：填地址 + 直接加入。`spec` 是 `"ip:port"`。
func _lan_join_room(spec: String) -> void:
	if spec == "":
		return
	var ip := spec
	var port := Net.PORT
	var i := spec.rfind(":")
	if i > 0:
		ip = spec.substr(0, i)
		port = int(spec.substr(i + 1))
	if port <= 0 or port > 65535:
		port = Net.PORT
	_lan_ip = ip
	Settings.set_v("lan_ip", _lan_ip)
	Settings.save_all()
	_lan_join(port)

## 打开 / 关掉广播发现。
##
## 两个方向**互斥**（同一个 UDP 端口只能占一份），所以一次只开一个：
##   · 搜索页（`St.LAN_SCAN`）→ 当客户端，收公告；
##   · 大厅里且是主机（`St.LOBBY` + `_authoritative`）→ 当主机，发公告。
##
## ⚠️ 客户端**进房间后必须停掉** —— 它绑着 `Net.DISCOVER_PORT`，
##    不停的话同一台机器上再开第二个实例时两边都收不到公告，
##    而且没有任何报错，只是「房间列表永远是空的」。
func _sync_discovery() -> void:
	var want_browse := state == St.LAN_SCAN
	var want_adv := state == St.LOBBY and _authoritative and session != null
	if not want_browse and not want_adv:
		_stop_discovery()
		return
	if want_browse:
		if _discovery != null and _discovery.mode == NetDiscovery.Mode.BROWSE:
			return
		# ⚠️ 复用已有实例而不是新建 —— 新建会丢掉注入的房间（截图用）。
		if _discovery == null:
			_discovery = NetDiscovery.new()
		if not _discovery.start_browse():
			_discovery = null
		return
	if _discovery != null and _discovery.mode == NetDiscovery.Mode.ADVERTISE:
		# 人数 / 是否开局会变，公告内容每帧刷新一份（`poll()` 里按 1 秒节流发出）。
		_discovery.set_info(_announce_info())
		return
	_discovery = NetDiscovery.new()
	if not _discovery.start_advertise(_announce_info()):
		_discovery = null

## 主机对外广播的房间信息。
##
## ⚠️ **只放能公开的东西**：名字 / 地图 / 人数 / 是否开局。
##    不要往里加任何私人信息（IP 是收包方从 UDP 源地址自己拿的，不用我们发）。
func _announce_info() -> Dictionary:
	return {
		"host_name": _lan_name,
		"game_port": Net.PORT,
		"players": session.player_count() if session != null else 1,
		"max_players": 2,
		"started": _lan_active(),
		"map_preset": map_preset,
		"host_race": race,
	}

func _stop_discovery() -> void:
	if _discovery != null:
		_discovery.stop()
		_discovery = null

## 本机是不是**正在局域网对局中**（决定顶栏要不要多出「聊天 / 投降」两个键）。
##
## `_lan_active_override` 只给**截图**用：`tests/Shot.gd` 要在没有第二个进程
## 的情况下拍到「对局中的局域网界面」。真实的 2 人对局截图做不到确定性
## （要两台机器、要真连上），而这一屏恰恰是最需要眼睛看的
## （顶栏下面那行新键挤不挤、聊天记录盖没盖住小地图）。
var _lan_active_override := false

func _lan_active() -> bool:
	if _lan_active_override:
		return true
	return session != null and session.is_playing()

## 只给**截图**用：往发现器里塞几条假房间，不等真实广播。
##
## ⚠️ 走的是和真实路径**同一个** `_rooms` 字典 + 同一个 `rooms()` ——
##    另起一个「假房间数组」的话，画出来的排版就未必和真发现时一样了，
##    截图也就失去了「验证真实排版」的意义。
func _inject_fake_rooms(rooms: Array) -> void:
	if _discovery == null:
		_discovery = NetDiscovery.new()
	# ⚠️ 标成「已经在收公告」—— 否则下一帧 `_sync_discovery()` 会把它
	#    **重建一遍**，而 `start_browse()` 里有 `_rooms.clear()`，
	#    刚注入的房间下一帧就没了（截图上表现为「空列表」）。
	_discovery.mode = NetDiscovery.Mode.BROWSE
	for r in rooms:
		_discovery.inject_room(r)

## 现在是不是暂停中。局域网走会话（**主机权威**），单机走本地 `paused`。
func _is_paused() -> bool:
	if session != null and session.is_playing():
		return session.is_paused()
	return paused

func _on_lan_pause(v: bool) -> void:
	_toast("已暂停" if v else "继续", Color("ffd166") if v else Color("8fe36b"))

## 收到对方的聊天。
func _on_lan_chat(from_name: String, text: String) -> void:
	_push_chat(from_name, text)
	_play_direct("ui_click")          # 轻轻响一声，不然打仗时根本注意不到

## 对方认输了。`world.surrender()` 已经在会话层结算过，这里只补一条日志 ——
## 结算界面由 `world.game_over` → `_on_game_over()` 负责。
func _on_lan_surrender(_who: int) -> void:
	var who := session.client_name() if (_authoritative and session != null) else "对方"
	_push_chat("系统", "%s 认输了" % who)

## 往聊天记录里追加一条（超出上限就丢最旧的）。
func _push_chat(from_name: String, text: String) -> void:
	_chat_log.append({"from": from_name, "text": text})
	while _chat_log.size() > CHAT_LOG_MAX:
		_chat_log.pop_front()
	queue_redraw()

## 本机发言。**自己发的那条本端不会收到信号**（见 `NetSession.send_chat()`），
## 所以这里要手动补一条上屏。
func _send_chat(text: String) -> void:
	if session == null:
		return
	var t := text.strip_edges()
	if t == "":
		return
	if not session.send_chat(t):
		_toast(session.last_error, Color("ffd166"))
		return
	_push_chat(_lan_name, t)

func _on_game_over(w: int) -> void:
	state = St.END
	if w == _me():
		_play_direct("victory")
	elif w == _foe():
		_play_direct("defeat")
	queue_redraw()

# ---------------------------------------------------------------- 主循环
func _process(delta: float) -> void:
	# 广播发现：**只在大厅页、还没进房间时**开着（见 `_sync_discovery()`）。
	_sync_discovery()
	if _discovery != null:
		_discovery.poll(delta)
	# 大厅：只推会话（等握手 / 等 WELCOME）。世界这会儿可能还不存在。
	if state == St.LOBBY and session != null:
		session.step(delta)
	if state == St.PLAY and world != null:
		_sfx_frame_count = 0          # 每帧的音效配额在这里重置
		# 暂停时**一步都不推进**：不是把 delta 置 0，而是整段跳过 ——
		# 置 0 的话世界里的计时器（菌毯重铺、AI 节流、技能冷却）仍会被调用，
		# 一旦某个计时器写成 `t -= delta; if t <= 0: t = PERIOD` 就会每帧重置，
		# 暂停久了反而更慢。整段跳过最干净。
		#
		# ★局域网：只有主机推进模拟。★ 客户端**一步都不跑** ——
		# 它跑了的话，每 1/10 秒会被主机的快照整体覆盖回去，
		# 表现成单位「抖动 / 回弹」，而且两端都不报错。
		#
		# ⚠️ 判据用自己记的 `_authoritative`，不是 `session.is_host()` ——
		#    会话一旦失败/关闭，`link.role` 就变回 NONE，那样主机会突然停止模拟，
		#    表现成「对方一掉线，我这局也卡住了」。
		if _authoritative and not _is_paused():
			world.step(delta * game_speed)
		if session != null:
			# 会话负责 poll / 收快照 / 刷客户端视野 / 发快照 / 看门狗
			session.step(delta)
			_lan_autoharvest()
		# 小地图迷雾覆盖层按固定节奏重建（逐像素重建不贵，但没必要每帧做）
		_minimap_fog_timer -= delta
		if _minimap_fog_timer <= 0.0:
			_minimap_fog_timer = 0.2
			_rebuild_minimap_fog()
		_update_pending_gesture()
	if _long_press_feedback > 0.0:
		_long_press_feedback -= delta
	_guard_aim_state()
	if font == null:
		_acquire_font()
	for t in _toasts:
		t["life"] -= delta
	_toasts = _toasts.filter(func(t): return t["life"] > 0.0)
	queue_redraw()

## 手指按住不动时不会产生 drag 事件，所以长按判定必须在这里轮询。
## 超时后按当前语义切到 BOX（框选）或 PAN（平移），并给一次视觉反馈。
func _update_pending_gesture() -> void:
	if _sel_mode != Sel.PENDING or _touches.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for id in _touches:
		var info: Dictionary = _touches[id]
		if now - float(info["time"]) < long_press:
			continue
		_sel_start = info["start"]
		if _single_drag_pans:
			_sel_mode = Sel.BOX
			_sel_rect = Rect2(_sel_start, Vector2.ZERO)
			_long_press_feedback = 0.35
		else:
			_sel_mode = Sel.PAN
		return

## 正在拖动建筑幽灵的手指 id
var _place_drag_id := -1

func _clamp_camera() -> void:
	if world == null:
		return
	var vp := get_viewport_rect().size
	var half := vp * 0.5 / cam_zoom
	# 允许左右留白，但不要把地图推得太远
	var min_x := -220.0 / cam_zoom
	var max_x := world.world_size.x + 220.0 / cam_zoom
	var min_y := -140.0 / cam_zoom
	var max_y := world.world_size.y + 140.0 / cam_zoom
	cam_pos.x = clampf(cam_pos.x, min_x + half.x * 0.25, max_x - half.x * 0.25)
	cam_pos.y = clampf(cam_pos.y, min_y + half.y * 0.25, max_y - half.y * 0.25)

# ---------------------------------------------------------------- 渲染
func _draw() -> void:
	var vp := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), Color("0b0f1a"))
	# HUD 编辑模式整屏接管 —— 底下不再画菜单，玩家看到的就是编辑层本身。
	if _hud_edit:
		_draw_hud_editor(vp)
		_draw_toasts(vp)
		if Settings.flag("show_fps", false):
			_draw_fps(vp)
		return
	if state == St.LAN_SCAN:
		_draw_lan_scan(vp)
		_draw_toasts(vp)
		if Settings.flag("show_fps", false):
			_draw_fps(vp)
		return
	if state == St.MENU:
		_draw_page(vp)
		_draw_toasts(vp)
		if Settings.flag("show_fps", false):
			_draw_fps(vp)
		return
	# 大厅：等对方握手 / 等 WELCOME。**这一页可能还没有世界**
	# （客户端的世界要等 `WELCOME` 到了才建），所以必须排在
	# `if world == null: return` 之前 —— 排在后面的话客户端大厅是纯黑屏。
	if state == St.LOBBY:
		_draw_lobby(vp)
		_draw_toasts(vp)
		if Settings.flag("show_fps", false):
			_draw_fps(vp)
		return
	if world == null:
		return
	# 命中表每帧重建 —— 绘制和命中用同一份坐标，才不会漂移。
	_ui_hits.clear()
	# 世界直接在本节点的 _draw() 里绘制，顺序决定 z 序：世界 → 覆盖层 → HUD。
	# 注意：不要把 _draw_world 挂到子节点的 draw 信号上——那样 GDScript 的 self
	# 仍是 Main，所有 draw_* 调用都会因"不在本节点绘制上下文"而静默失败。
	_draw_world()
	_draw_fog()
	_draw_overlay(vp)
	_draw_world_ui(vp)
	_draw_panel(vp)
	_draw_minimap(vp)
	_draw_topbar(vp)
	_draw_chat_log(vp)
	_draw_toasts(vp)
	if _is_paused() and state == St.PLAY:
		# 暂停遮罩：压暗 + 一行提示。刻意**不盖住面板** ——
		# 暂停时玩家正要读建筑信息、看队列、决定下一步，遮住就等于逼他先恢复。
		draw_rect(Rect2(0, TOP_H, vp.x, vp.y - TOP_H), Color(0.02, 0.03, 0.06, 0.38))
		_draw_text_center("已 暂 停", Rect2(0, vp.y * 0.40, vp.x, 40.0), 30.0, Color(1.0, 0.84, 0.42, 0.92))
		_draw_text_center("点顶栏「继续」恢复 · 速度档位不影响平衡",
			Rect2(0, vp.y * 0.40 + 42.0, vp.x, 24.0), 14.0, Color(0.85, 0.88, 0.95, 0.75))
	# 聊天键盘画在**最上层**（模态，盖住整个战场）。
	if _lan_input_key != "":
		_draw_lan_keypad(vp)
	if _show_help:
		_draw_help(vp)
	if Settings.flag("show_fps", false):
		_draw_fps(vp)
	if state == St.END:
		_draw_end(vp)

# ================================================================ 大厅页

## 大厅页的按钮命中表。绘制 / 命中 / 测试三边读同一份。
## 大厅页该有哪些按钮。**纯函数**（不读任何全局状态）——
## 这样测试能直接喂「主机 / 客户端 × 已准备 / 未准备 × 能不能开局」的全部组合，
## 而不用真的去建一个会话。
##
## ⚠️ 主机和客户端的**主按钮语义不同**，不能合成一个：
##    主机是「开始游戏」（能不能点是**对方**准备没准备决定的），
##    客户端是「我准备好了」（自己就能切）。
##    合成一个的话，客户端会看到一个自己点不动的「开始游戏」，
##    而主机能看到一个「我准备好了」—— 两个人都不知道该干什么。
static func lobby_actions(in_room: bool, host: bool, me_ready: bool, can_start: bool) -> Array:
	var out: Array = []
	if in_room:
		if host:
			out.append({"act": "lan_start", "label": "开始游戏",
				"enabled": can_start, "hint": "" if can_start else "等对方准备"})
		else:
			out.append({"act": "lan_ready",
				"label": "取消准备" if me_ready else "我准备好了",
				"enabled": true, "hint": ""})
	out.append({"act": "lan_leave", "label": "取消并返回", "enabled": true, "hint": ""})
	return out

## 大厅页要用的实时状态。**绘制 / 命中两边都调它** ——
## 各算各的就会出现「画出来是「开始游戏」，点下去却按「取消准备」处理」。
func lobby_ui_state() -> Dictionary:
	var in_room := session != null and session.lobby_ready()
	var ready := session != null and session.client_ready()
	var can_go := session != null and session.can_start()
	return {"in_room": in_room, "host": _authoritative, "me_ready": ready, "can_start": can_go}

## 大厅页按钮的命中表（几何 + 动作 + 文案）。绘制 / 命中 / 测试三边读同一份。
##
## 布局：竖着排，整体落在屏幕下半部。
## ⚠️ 用「从下往上算总高」而不是「从某个固定 y 往下排」——
##    后者在按钮变多时会**冲出屏幕下沿**，而 `draw_rect` 不报错。
func lobby_button_rects(vp: Vector2, in_room: bool, host: bool,
		me_ready: bool, can_start: bool) -> Array:
	var acts := lobby_actions(in_room, host, me_ready, can_start)
	var w := minf(320.0, vp.x - 80.0)
	var h := 52.0
	# ⚠️ 有按钮要显示「为什么点不动」时，间距必须**留出那行小字的高度** ——
	#    否则理由会画到下一个键上，看着像文字叠字（`draw_string` 不报错）。
	var gap := 12.0
	for a in acts:
		if String(a.get("hint", "")) != "":
			gap = 30.0
			break
	var n := acts.size()
	var total := n * h + maxf(0.0, float(n - 1)) * gap
	var y := vp.y - 28.0 - total
	var x := vp.x * 0.5 - w * 0.5
	var out: Array = []
	for i in range(n):
		var m: Dictionary = acts[i]
		m["rect"] = Rect2(x, y + i * (h + gap), w, h)
		out.append(m)
	return out

## 按钮下方那行「为什么点不动」的小字占的矩形。**纯函数** ——
## 绘制与测试读同一份（测试要断言它**不压到下一个键**）。
func lobby_hint_rect(btn: Rect2) -> Rect2:
	return Rect2(btn.position.x, btn.end.y + 2.0, btn.size.x, 16.0)

## 房间行要显示的两段文本。**纯函数** —— 命中表与绘制读同一份。
##
## ⚠️ 键名是 `name`（`NetDiscovery` 收包时写进去的），**不是** `host`。
##    写错的话 `.get()` 会静默走默认值 → 每个房间的名字都变成「?」，
##    而 IP / 地图 / 人数**全是对的**，看着像「对方没设名字」。
##    （这个 bug 只有截图能发现 —— 无头测不了 `_draw_*`。
##     所以把「显示什么」抽成纯函数，让测试也能覆盖到。）
func room_display(room: Dictionary) -> Dictionary:
	return {
		"name": _safe_name(String(room.get("name", "?")), 12),
		"sub": "%s · %s · %d 人" % [String(room.get("ip", "")),
			String(room.get("map", "")), int(room.get("players", 1))],
	}

## 大厅按钮的**绘制计划**（纯函数）。绘制器照着执行，测试直接检查指令表。
##
## ⚠️ 为什么值得抽出来：这里曾经在「点不动」的分支里写了 `continue`，
##    顺手把**理由**（`hint`）一起跳过了 —— 而理由恰恰**只在点不动时才需要**。
##    症状是「灰键永远不告诉你为什么灰」，玩家只会一直点。
##    `_draw_*` 在无头里跑不起来，这个 bug 只有截图能发现。
##    把「画什么」变成数据之后，测试就能断言「**灰键必须带理由**」。
func lobby_button_plan(entries: Array) -> Array:
	var out: Array = []
	for e in entries:
		var en := bool(e.get("enabled", true))
		var is_leave := String(e.get("act", "")) == "lan_leave"
		var bg := Color(0.35, 0.72, 0.42, 0.26)
		var border := Color("8fe36b")
		var fg := Color(0.94, 0.97, 1.0)
		if not en:
			# 点不动的键要**看起来就点不动** —— 画成和可点的一样，
			# 玩家会一直点，然后以为联机坏了。
			bg = Color(1, 1, 1, 0.04)
			border = Color(1, 1, 1, 0.10)
			fg = Color(0.45, 0.48, 0.55)
		elif is_leave:
			bg = Color(0.75, 0.35, 0.30, 0.30)
			border = Color("ff9a8f")
		out.append({
			"rect": e.get("rect", Rect2()),
			"label": String(e.get("label", "")),
			"bg": bg, "border": border, "fg": fg,
			"hint": String(e.get("hint", "")),
		})
	return out

## 广播发现到的房间列表的命中表。绘制 / 命中 / 测试三边读同一份。
##
## ⚠️ 行高固定、最多显示 `max_rows` 行。房间多了也不能往下排 ——
##    排到「取消并返回」上面会把它盖住，那个键就点不到了。
func lobby_room_rects(vp: Vector2, rooms: Array, max_rows: int = 3) -> Array:
	var w := minf(420.0, vp.x - 60.0)
	var h := 44.0
	var gap := 8.0
	var x := vp.x * 0.5 - w * 0.5
	var y := vp.y * 0.5 - 40.0
	var out: Array = []
	var n := mini(rooms.size(), max_rows)
	for i in range(n):
		var r: Dictionary = rooms[i]
		var d := room_display(r)
		# ⚠️ `arg` 要带上**公告里的游戏端口**，不能只有 IP ——
		#    房间端口由主机自己定（`Net.PORT` 只是默认值），
		#    只传 IP 的话会去连 27015，而对方可能在别的端口上。
		out.append({
			"rect": Rect2(x, y + i * (h + gap), w, h),
			"act": "lan_room",
			"arg": "%s:%d" % [String(r.get("ip", "")), int(r.get("port", Net.PORT))],
			"label": "%s · %s" % [String(d["name"]), String(r.get("ip", ""))],
			"room": r,
		})
	return out

func _lobby_press(pos: Vector2) -> void:
	var st := lobby_ui_state()
	for m in lobby_button_rects(get_viewport_rect().size, bool(st["in_room"]),
			bool(st["host"]), bool(st["me_ready"]), bool(st["can_start"])):
		var r: Rect2 = m["rect"]
		if r.has_point(pos) and bool(m.get("enabled", true)):
			_menu_act(String(m["act"]), r, pos)
			return

## 大厅页要显示的地址文案。抽成**纯函数**是为了让测试钉得住两件事：
##   1. `main` 必须是**一个**地址（另一台照着输的就是它），不是一串；
##   2. `rest` 最多列 3 个。
##
## ⚠️ 第 2 条不是审美问题：装了 VMware / Hyper-V / WSL 的机器
##    `IP.get_local_addresses()` 能返回 8 个 IPv4，全拼成一行会
##    **直接冲出屏幕两侧** —— 而 `draw_string` 既不换行也不裁剪，**不报错**。
##    （这个缺陷就是靠 `tests/Shot.gd` 的 `30_lobby_host` 那张截图抓到的，
##      无头测试永远看不到。）
##
## `p_ips` 只给测试用：不传就取本机真实网卡。**必须能注入** ——
## 否则「最多列 3 个」这条断言只能靠「开发机正好有 8 个网卡」才跑得到，
## 换台机器就静默退化成恒真。
func lan_address_lines(p_ips: Array = []) -> Dictionary:
	var ips: Array = p_ips if not p_ips.is_empty() else NetLink.local_ipv4_list()
	if ips.is_empty():
		return {"main": "（没检测到局域网地址 · 检查 WiFi）", "rest": "", "count": 0}
	var rest: Array = []
	var shown := mini(ips.size(), 4)          # 下标 0 是 main，1..3 进 rest
	for i in range(1, shown):
		rest.append(String(ips[i]))
	var tail := " · ".join(rest)
	if ips.size() > shown:
		tail += " 等 %d 个" % ips.size()
	return {"main": String(ips[0]), "rest": tail, "count": ips.size()}

## 大厅页：等待加入 / 连接中。
##
## ⚠️ 这一页**可能没有世界** —— 客户端的世界要等 `WELCOME` 到了才建出来。
##    所以它不能走 `_draw_world()` 那条路，必须自己画。
func _draw_lobby(vp: Vector2) -> void:
	_draw_menu_bg(vp)
	_draw_text_center("局域网游戏", Rect2(0, 44.0, vp.x, 40.0), 32.0, Color(0.90, 0.94, 1.0))
	_draw_text_center("你是主机（权威模拟在本机）" if _authoritative else "你是客户端（只发指令）",
		Rect2(0, 88.0, vp.x, 28.0), 20.0, Color("8fd0ff"))
	_draw_text_center(_lan_status, Rect2(0, 118.0, vp.x, 24.0), 15.0, _lan_status_color)

	# ---- 玩家列表 ----
	# 主机侧只能靠会话知道自己和对方的名字；客户端侧同理。
	# ⚠️ 玩家名一律走 `_safe_name()` 截断 —— 名字是玩家自己输的，
	#    一个 24 字的名字会把整行推出屏幕（`draw_string` 不裁剪、不报错）。
	var host_n := _lan_name if _authoritative else (session.host_name if session != null else "?")
	var guest_n := "（等玩家加入…）"
	var guest_ready := false
	if session != null:
		if _authoritative:
			if session.player_count() >= 2:
				guest_n = session.client_name()
				guest_ready = session.client_ready()
		else:
			guest_n = _lan_name
			guest_ready = session.client_ready()
			host_n = session.host_name
	var py := vp.y * 0.5 - 118.0
	_draw_player_row(vp, py, "主机", host_n, true)
	_draw_player_row(vp, py + 40.0, "客户端", guest_n, guest_ready)

	# ---- 主机侧：把地址**放大**显示（另一台要照着这串数字一个一个输）----
	if _authoritative:
		var al := lan_address_lines()
		# 大号只画**最可能对的那一个**。以前是把 8 个地址用 ` · ` 拼成一行，
		# 结果整行冲出屏幕两侧（`draw_string` 不换行不裁剪，**不报错**）。
		_draw_text_center(String(al["main"]),
			Rect2(0, py + 88.0, vp.x, 32.0), 25.0, Color("8fe36b"))
		var rest := String(al["rest"])
		if rest != "":
			_draw_text_center("其他网卡：" + rest,
				Rect2(0, py + 122.0, vp.x, 20.0), 13.0, Color(0.45, 0.53, 0.66))
	if session != null and session.rtt_ms() >= 0:
		_draw_text_center("延迟 %d ms" % session.rtt_ms(),
			Rect2(0, py + 146.0, vp.x, 22.0), 14.0, Color(0.66, 0.73, 0.86))

	# ---- 按钮 ----
	# ⚠️ 「画什么」走 `lobby_button_plan()`（纯函数）—— 绘制与测试读同一份。
	#    理由（hint）在这里**无条件**尝试画：它只有在该画的时候才非空。
	var st := lobby_ui_state()
	for p in lobby_button_plan(lobby_button_rects(vp, bool(st["in_room"]),
			bool(st["host"]), bool(st["me_ready"]), bool(st["can_start"]))):
		var r: Rect2 = p["rect"]
		draw_rect(r, p["bg"], true)
		draw_rect(r, p["border"], false, 1.2)
		_draw_text_center(String(p["label"]), r, 17.0, p["fg"])
		# 理由必须画在**分支之外**：只有「点不动」时才需要理由，
		# 而「点不动」正是最容易被一条 `continue` 顺手跳过的那个分支。
		var hint := String(p["hint"])
		if hint != "":
			_draw_text_center(hint, lobby_hint_rect(r), 12.0, Color(0.55, 0.60, 0.72))

## 玩家列表里的一行：名字 + 准备状态。
##
## 名字要**截断**：它是玩家自己输的（最多 24 字符），不截的话
## 一个长名字能把整行推出屏幕 —— 而且 `draw_string` 不会报错。
func _draw_player_row(vp: Vector2, y: float, role: String, name: String, ready: bool) -> void:
	var w := minf(420.0, vp.x - 80.0)
	var r := Rect2(vp.x * 0.5 - w * 0.5, y, w, 34.0)
	draw_rect(r, Color(1, 1, 1, 0.05), true)
	draw_rect(r, Color(1, 1, 1, 0.12), false, 1.0)
	var col := Color("8fe36b") if ready else Color(0.72, 0.78, 0.88)
	draw_string(font, Vector2(r.position.x + 12.0, r.position.y + 23.0),
		"%s  %s" % [role, _safe_name(name, 14)],
		HORIZONTAL_ALIGNMENT_LEFT, w - 110.0, 15.0, col)
	var tag := "已准备" if ready else "未准备"
	draw_string(font, Vector2(r.end.x - 78.0, r.position.y + 23.0),
		tag, HORIZONTAL_ALIGNMENT_LEFT, 70.0, 14.0,
		Color("8fe36b") if ready else Color(0.55, 0.60, 0.72))

## 玩家名的显示截断。**纯函数**（测试钉得住）。
func _safe_name(n: String, max_chars: int) -> String:
	var s := n.strip_edges()
	if s == "":
		return "?"
	if s.length() <= max_chars:
		return s
	return s.substr(0, max_chars) + "…"

# ================================================================ 搜索房间页

## 进搜索页：开广播发现，等局域网里的主机自报家门。
func _open_lan_scan() -> void:
	state = St.LAN_SCAN
	_sync_discovery()
	queue_redraw()

func _lan_scan_press(pos: Vector2) -> void:
	for m in lan_scan_button_rects(get_viewport_rect().size):
		var r: Rect2 = m["rect"]
		if r.has_point(pos):
			_menu_act(String(m["act"]), r, pos)
			return
	var rooms: Array = _discovery.rooms() if _discovery != null else []
	for m in lobby_room_rects(get_viewport_rect().size, rooms):
		var r: Rect2 = m["rect"]
		if r.has_point(pos):
			_menu_act(String(m["act"]), r, pos, m.get("arg", ""))
			return

## 搜索页的按钮（「返回」+「刷新」）。纯函数，绘制 / 命中 / 测试同源。
func lan_scan_button_rects(vp: Vector2) -> Array:
	var w := 150.0
	var h := 46.0
	var y := vp.y - 28.0 - h
	return [
		{"rect": Rect2(vp.x * 0.5 - w - 8.0, y, w, h), "act": "lan_scan_back", "label": "返回"},
		{"rect": Rect2(vp.x * 0.5 + 8.0, y, w, h), "act": "lan_scan_refresh", "label": "重新搜索"},
	]

func _draw_lan_scan(vp: Vector2) -> void:
	_draw_menu_bg(vp)
	_draw_text_center("搜索局域网房间", Rect2(0, 44.0, vp.x, 40.0), 30.0, Color(0.90, 0.94, 1.0))
	var rooms: Array = _discovery.rooms() if _discovery != null else []
	var sub := "正在监听局域网广播…"
	if _discovery == null:
		sub = "★收不到广播（端口被占用？）★ 可以直接用「手动输入地址」"
	elif not rooms.is_empty():
		sub = "发现 %d 个房间 · 点一下直接加入" % rooms.size()
	_draw_text_center(sub, Rect2(0, 90.0, vp.x, 24.0), 14.0,
		Color(0.55, 0.62, 0.76) if _discovery != null else Color("ff9a8f"))
	# 收不到广播时给一条**能走通的路**，而不是只报错。
	if _discovery != null and rooms.is_empty():
		_draw_text_center("（主机必须正在「等待玩家加入」才会广播）",
			Rect2(0, 116.0, vp.x, 20.0), 13.0, Color(0.45, 0.52, 0.66))

	var rows := lobby_room_rects(vp, rooms)
	if rows.is_empty() and _discovery != null:
		_draw_text_center("暂时没发现房间", Rect2(0, vp.y * 0.5 - 20.0, vp.x, 30.0),
			17.0, Color(0.40, 0.46, 0.58))
	for m in rows:
		var r: Rect2 = m["rect"]
		draw_rect(r, Color(0.35, 0.72, 0.42, 0.20), true)
		draw_rect(r, Color("8fe36b"), false, 1.2)
		var room: Dictionary = m["room"]
		# 显示内容走 `room_display()` —— 绘制与命中表读同一份，
		# 测试也钉得住（见那里的注释：曾经把 `name` 读成 `host`，
		# 结果每个房间的名字都显示成「?」）。
		var d := room_display(room)
		draw_string(font, Vector2(r.position.x + 14.0, r.position.y + 19.0),
			String(d["name"]),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 200.0, 15.0, Color(0.94, 0.97, 1.0))
		draw_string(font, Vector2(r.position.x + 14.0, r.position.y + 36.0),
			String(d["sub"]),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 28.0, 12.0, Color(0.60, 0.68, 0.82))
	for m in lan_scan_button_rects(vp):
		var r: Rect2 = m["rect"]
		draw_rect(r, Color(1, 1, 1, 0.07), true)
		draw_rect(r, Color(1, 1, 1, 0.16), false, 1.2)
		_draw_text_center(String(m["label"]), r, 16.0, Color(0.88, 0.92, 1.0))

## 帧率显示（设置里可开）。画在顶栏**下方**靠右 ——
## 放顶栏里会和「敌基地」挤在一起，放左下角会被小地图盖住。
func _draw_fps(vp: Vector2) -> void:
	var txt := "%d fps" % Engine.get_frames_per_second()
	var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0).x + 16.0
	var r := Rect2(vp.x - w - 8.0, TOP_H + 6.0, w, 22.0)
	draw_rect(r, Color(0, 0, 0, 0.45), true)
	_draw_text_center(txt, r, 13.0, Color(0.75, 0.92, 0.75))

func _xf(p: Vector2) -> Vector2:
	return (p - cam_pos) * cam_zoom + get_viewport_rect().size * 0.5

func _visible_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var half := vp * 0.5 / cam_zoom
	return Rect2(cam_pos - half, vp / cam_zoom)

func _draw_world() -> void:
	var vr := _visible_rect()
	var c0 := Vector2i(maxi(0, int(vr.position.x / Grid.CELL) - 1), maxi(0, int(vr.position.y / Grid.CELL) - 1))
	var c1 := Vector2i(mini(world.grid.w - 1, int((vr.end.x) / Grid.CELL) + 1), mini(world.grid.h - 1, int((vr.end.y) / Grid.CELL) + 1))

	# 地面：程序化纹理平铺。关键是用 draw_set_transform 把绘制坐标系临时切到世界空间，
	# 否则平铺图案会「粘」在屏幕上 —— 一推镜就露馅。
	var vp_size := get_viewport_rect().size
	draw_set_transform(-cam_pos * cam_zoom + vp_size * 0.5, 0.0, Vector2(cam_zoom, cam_zoom))
	draw_texture_rect(TEX["ground"], Rect2(Vector2.ZERO, world.world_size), true)
	if _biome_tex != null:
		draw_texture_rect(_biome_tex, Rect2(Vector2.ZERO, world.world_size), false, Color(1, 1, 1, 0.62))
	draw_texture_rect(TEX["ground_patch"], Rect2(Vector2.ZERO, world.world_size), true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# 高低差：高地台面提亮 + 崖壁描边 + 坡道斜纹。
	# 顺序很关键 —— 必须画在「地面之后、岩石之前」：
	# 地面是整张平铺的，画早了会被盖掉；岩石是逐格贴图，画晚了会压住崖壁线。
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			if not world.grid.in_bounds(x, y):
				continue
			var gi := world.grid.idx(x, y)
			var is_ramp: bool = world.grid.ramp[gi] != 0
			var on_high: bool = world.grid.elev[gi] == 1
			if not is_ramp and not on_high:
				continue
			var gwp := Vector2(x * Grid.CELL, y * Grid.CELL)
			var gr := Rect2(_xf(gwp), Vector2(Grid.CELL, Grid.CELL) * cam_zoom)
			if is_ramp:
				# 坡道：暖棕色，和冷色地面/高地一眼分开
				draw_rect(gr, Color(0.66, 0.53, 0.30, 0.34))
				draw_line(gr.position + Vector2(0, gr.size.y * 0.30),
					gr.position + Vector2(gr.size.x, gr.size.y * 0.30),
					Color(0.90, 0.78, 0.48, 0.40), maxf(1.0, 1.4 * cam_zoom))
				continue
			# 高地台面：整体提亮 + 偏冷，和低地拉开
			draw_rect(gr, Color(0.60, 0.72, 0.96, 0.15))
			# 崖壁：只在高地紧邻「低地且非坡道」的那条边上描一道暗边。
			# 不描的话，高地就是一块颜色略浅的区域，玩家看不出「这里是上不去的」——
			# 而这条边界恰恰是整张地图上战术意义最强的一条线。
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = x + d.x
				var ny: int = y + d.y
				if not world.grid.in_bounds(nx, ny):
					continue
				var ni := world.grid.idx(nx, ny)
				if world.grid.elev[ni] != 0 or world.grid.ramp[ni] != 0:
					continue
				var cl := Color(0.05, 0.07, 0.12, 0.62)
				var cw := maxf(1.6, 3.0 * cam_zoom)
				if d.x != 0:
					var ex := gr.position.x if d.x < 0 else gr.position.x + gr.size.x
					draw_line(Vector2(ex, gr.position.y), Vector2(ex, gr.position.y + gr.size.y), cl, cw)
				else:
					var ey := gr.position.y if d.y < 0 else gr.position.y + gr.size.y
					draw_line(Vector2(gr.position.x, ey), Vector2(gr.position.x + gr.size.x, ey), cl, cw)

	# 菌毯：紫黑色半透明覆盖。
	#
	# 顺序：必须画在「高低差之后、岩石之前」——
	# 菌毯会长到高地上（虫族在高地拍个基地就有了），所以得盖住台面提亮；
	# 但岩石是「实心石头」，菌毯不该糊在石头上。
	#
	# 每格一张斑点贴图，尺寸刻意**画到 1.40 格**：相邻斑点必须真的**重叠**，
	# 重叠区的 alpha 自然叠加变实，整片才连成一块生物质。
	# （第一版画成 1.06 格 —— 斑点直径刚好等于格子，相邻只相切不重叠，
	#   渲染出来是一张「圆点网格」，像在地上铺了瓷砖。）
	var creep_sz := Grid.CELL * 1.40 * cam_zoom
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			if not world.grid.in_bounds(x, y):
				continue
			if world.grid.creep[world.grid.idx(x, y)] == 0:
				continue
			var cc := Vector2(x * Grid.CELL, y * Grid.CELL) + Vector2(Grid.CELL, Grid.CELL) * 0.5
			# 没探索过的地方不画 —— 迷雾虽然「几乎全黑」，但仍然会透出 6%，
			# 而敌方基地那一整片菌毯正好全落在未探索区：
			# 漏出来等于一开局就白送对手的基地位置。
			if not world.is_explored(cc):
				continue
			var cs := _xf(cc)
			# 按格子坐标哈希挑一个轮廓变体，打破「每格图案一模一样」的重复感。
			# 用位运算取低 2 位而不是 % 4 —— 前者对负数也正确。
			var v: Dictionary = _creep_variants[((x * 73856093) ^ (y * 19349663)) & 3]
			var body: Texture2D = v["body"]
			draw_texture_rect(body,
				Rect2(cs - Vector2(creep_sz, creep_sz) * 0.5, Vector2(creep_sz, creep_sz)), false)
			# 边界：只给「紧邻无菌毯」的那些格叠一层亮色光晕。
			#
			# ⚠️ 第一版这里是逐格 draw_arc 画圆环，结果是灾难 —— 每个边界格
			#    都画出一个完整的圆圈，整片菌毯看上去就是一堆圈。
			#    改成「叠一张更亮的斑点」之后边界是柔和的光晕，不再是硬轮廓。
			var on_edge := false
			for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if not world.grid.in_bounds(x + dd.x, y + dd.y) \
						or world.grid.creep[world.grid.idx(x + dd.x, y + dd.y)] == 0:
					on_edge = true
					break
			if on_edge:
				var esz := creep_sz * 1.06
				var edge: Texture2D = v["edge"]
				draw_texture_rect(edge,
					Rect2(cs - Vector2(esz, esz) * 0.5, Vector2(esz, esz)), false)

	# 岩石（每格一张，带顶部受光边 —— 自然形成石块分界）
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			var i := world.grid.idx(x, y)
			if world.grid.cells[i] != Grid.Terrain.ROCK:
				continue
			var wp := Vector2(x * Grid.CELL, y * Grid.CELL)
			draw_texture_rect(TEX["rock"], Rect2(_xf(wp), Vector2(Grid.CELL, Grid.CELL) * cam_zoom), false)

	# 河道 / 深渊（和岩石同一个循环形状，但走另一张贴图 —— 见 GenTex.chasm_tile）
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			var i2 := world.grid.idx(x, y)
			if world.grid.cells[i2] != Grid.Terrain.CHASM:
				continue
			var wp2 := Vector2(x * Grid.CELL, y * Grid.CELL)
			draw_texture_rect(TEX["chasm"], Rect2(_xf(wp2), Vector2(Grid.CELL, Grid.CELL) * cam_zoom), false)

	# 资源点（只画已探索过的，迷雾里的矿不该被看见）
	for r in world.resources:
		if r["amount"] <= 0.0:
			continue
		var sp := _xf(r["pos"])
		if not vr.grow(40.0).has_point(r["pos"]):
			continue
		if not world.is_explored(r["pos"]):
			continue
		var ratio: float = clampf(r["amount"] / r["max"], 0.0, 1.0)
		var tex: Texture2D = TEX["mineral"] if r["kind"] == "mineral" else TEX["gas"]
		var sz := (20.0 + 12.0 * ratio) * cam_zoom
		# 投影，让矿簇「立」在地面上
		draw_texture_rect(TEX["shadow"],
			Rect2(sp - Vector2(sz * 0.60, sz * 0.32), Vector2(sz * 1.20, sz * 0.64)), false)
		draw_texture_rect(tex, Rect2(sp - Vector2(sz, sz) * 0.5, Vector2(sz, sz)), false)
		if cam_zoom > 0.62:
			var bar_w := 24.0 * cam_zoom
			draw_rect(Rect2(sp + Vector2(-bar_w * 0.5, sz * 0.5 + 3 * cam_zoom), Vector2(bar_w, 2.8 * cam_zoom)), Color(0, 0, 0, 0.55))
			draw_rect(Rect2(sp + Vector2(-bar_w * 0.5, sz * 0.5 + 3 * cam_zoom), Vector2(bar_w * ratio, 2.8 * cam_zoom)),
				Color("59c8ff") if r["kind"] == "mineral" else Color("7de08a"))

	# 建筑阴影 + 本体（敌方建筑在迷雾中不画）
	for b in world.buildings:
		if not vr.grow(80.0).has_point(b.pos):
			continue
		if b.owner_id != _me() and not world.is_visible(b.pos):
			continue
		var sp := _xf(b.pos)
		var brr: float = b.radius() * cam_zoom
		draw_texture_rect(TEX["shadow"], Rect2(sp - Vector2(brr * 2.0, brr * 1.4 - brr * 0.35), Vector2(brr * 4.0, brr * 2.6)), false)
		_draw_building(b, sp, brr)

	# 单位。
	# ⚠️ 分两遍画：地面单位在前、飞行单位在后。
	# 一遍过的话，一架飞龙会被排在它后面的地面单位盖住，看上去像「穿模」。
	# 分两遍的代价只是多遍历一次 units 数组，比给每个单位排序便宜得多。
	var sel := {}
	for u in world.selection:
		sel[u.id] = true
	for airborne: bool in [false, true]:
		for u in world.units:
			if u.is_flying() != airborne:
				continue
			if not vr.grow(60.0).has_point(u.pos):
				continue
			if u.owner_id != _me() and not world.is_visible(u.pos):
				continue
			var sp := _xf(u.pos)
			var urr: float = u.radius() * cam_zoom
			if airborne:
				# 飞行单位：本体上浮、影子往右下偏并缩小 ——
				# 用「光从左上来」的错觉表达高度。只把单位画在上面而不动影子的话，
				# 看起来就像贴在地面上滑行。
				# 偏移量给得比较足（本体抬 0.6r、影子再往右下甩 1.25r/0.95r），
				# 因为手机上大多是缩到 0.6 倍在打 —— 偏小了根本看不出高低差。
				sp.y -= urr * 0.60
				var off := Vector2(urr * 1.25, urr * 0.95)
				draw_texture_rect(TEX["shadow"],
					Rect2(sp + off - Vector2(urr * 0.95, urr * 0.50),
						Vector2(urr * 1.9, urr * 1.0)),
					false, Color(1, 1, 1, 0.46))
			else:
				draw_texture_rect(TEX["shadow"],
					Rect2(sp - Vector2(urr * 1.7, urr * 0.9), Vector2(urr * 3.4, urr * 1.8)), false)
			_draw_unit(u, sp, urr, sel.has(u.id))

	# 法术区域：画在**单位之后、弹道之前**。
	#
	# ⚠️ 顺序有讲究：画在单位之前的话，心灵风暴会把里面的兵盖住 ——
	#    玩家看不到自己的兵还剩多少血，而这正是他最需要知道的事。
	#    画在弹道之后又会被曳光盖掉一层。夹在中间最合适。
	_draw_spell_zones(vr)

	# 投射物（迷雾中的不画）。投射物没有 vel 字段，用「指向目标的方向」当拖尾方向。
	for p in world.projectiles:
		if not world.is_visible(p["pos"]):
			continue
		var psp := _xf(p["pos"])
		var col: Color = p["color"]
		var ppos: Vector2 = p["pos"]
		var tgt = p["target"]
		var tpos: Vector2 = tgt.pos if tgt != null else ppos
		var fwd := tpos - ppos
		fwd = fwd.normalized() if fwd.length_squared() > 1.0 else Vector2(0.0, -1.0)
		var side := Vector2(-fwd.y, fwd.x)
		match p["kind"]:
			"cannon", "shell":
				draw_line(psp - fwd * 16.0 * cam_zoom, psp, Color(col.r, col.g, col.b, 0.26), 5.0 * cam_zoom)
				draw_circle(psp, 7.5 * cam_zoom, Color(col.r, col.g, col.b, 0.20))
				draw_circle(psp, 4.2 * cam_zoom, col)
				draw_circle(psp, 1.9 * cam_zoom, Color(1, 1, 1, 0.85))
			"psionic", "phase":
				draw_circle(psp, 8.5 * cam_zoom, Color(col.r, col.g, col.b, 0.16))
				draw_circle(psp, 3.6 * cam_zoom, col)
				draw_circle(psp, 1.6 * cam_zoom, Color(1, 1, 1, 0.90))
			"acid":
				draw_circle(psp, 5.0 * cam_zoom, Color(col.r, col.g, col.b, 0.24))
				draw_circle(psp, 2.9 * cam_zoom, col)
			"glave", "spine":
				draw_line(psp - fwd * 6.0 * cam_zoom + side * 4.0 * cam_zoom,
					psp + fwd * 5.0 * cam_zoom - side * 4.0 * cam_zoom, col, 2.2 * cam_zoom)
				draw_circle(psp, 1.8 * cam_zoom, Color(1, 1, 1, 0.55))
			"laser", "missile":
				# 空中单位的弹道：细长曳光 + 白芯，和地面武器一眼能分开
				draw_line(psp - fwd * 22.0 * cam_zoom, psp, Color(col.r, col.g, col.b, 0.28), 2.6 * cam_zoom)
				draw_line(psp - fwd * 9.0 * cam_zoom, psp, Color(1, 1, 1, 0.85), 1.4 * cam_zoom)
				draw_circle(psp, 2.2 * cam_zoom, col)
			_:
				draw_line(psp - fwd * 13.0 * cam_zoom, psp, Color(col.r, col.g, col.b, 0.45), 2.2 * cam_zoom)
				draw_circle(psp, 2.4 * cam_zoom, col)
	# 特效：外环 + 光团 + 高亮核心 —— 比单层圆更有「爆开」的感觉
	for e in world.effects:
		var esp := _xf(e["pos"])
		var et: float = e["life"] / e["max"]
		var rr: float = e["r"] * cam_zoom
		var ec: Color = e["color"]
		var grow := 1.45 - et * 0.45
		draw_circle(esp, rr * grow, Color(ec.r, ec.g, ec.b, et * 0.42))
		draw_circle(esp, rr * grow * 0.45, Color(1, 1, 1, et * 0.30))
		draw_arc(esp, rr * grow * 1.2, 0.0, TAU, 26, Color(ec.r, ec.g, ec.b, et * 0.55), 2.2 * cam_zoom)

## 法术区域（心灵风暴的伤害圈 / 黑暗虫群的免疫圈）。
##
## 两条铁律：
##  ① **必须有边界圈**。没有边界，玩家不知道「站在这里到底安不安全」——
##     而这两个法术的全部玩法就是「站进去 / 别站进去」。
##  ② **剩余时间要看得出来**。用「闪烁频率 + 透明度」表达：
##     快没了就闪得更快、更淡，玩家才来得及补一发。
##
## ⚠️ 与 `_draw_spell_zones` 同名的概念只此一处，不要在别处再画一遍 ——
##    重复绘制会让半透明的圈叠加成不透明的色块，看上去像 bug。
func _draw_spell_zones(vr: Rect2) -> void:
	for z in world.spell_zones:
		var zd: Dictionary = z
		var pos: Vector2 = zd["pos"]
		var r := float(zd["radius"])
		if not vr.grow(r + 40.0).has_point(pos):
			continue
		# 敌方在迷雾里的法术不画 —— 否则等于告诉玩家「对面刚在这放了技能」。
		if int(zd.get("owner", 0)) != _me() and not world.is_visible(pos):
			continue
		var c := _xf(pos)
		var rr := r * cam_zoom
		var dur := maxf(0.001, float(zd.get("duration", 1.0)))
		var t := clampf(float(zd.get("remain", 0.0)) / dur, 0.0, 1.0)
		if String(zd.get("effect", "")) == "no_ranged":
			_draw_swarm_zone(c, rr, t)
		else:
			_draw_storm_zone(c, rr, t)

## 心灵风暴：冷白色的电球。
##
## 电弧的位置由 `world.elapsed` 算出来，**不用 `randf()`** ——
## 用随机数的话每帧的折线位置都在跳，画面上是一团噪点，
## 而且「同一时刻的画面」不可复现，截图测试没法钉。
func _draw_storm_zone(c: Vector2, rr: float, t: float) -> void:
	var tm := world.elapsed
	var flick := 0.5 + 0.5 * sin(tm * (6.0 + (1.0 - t) * 22.0))
	var fade := 0.30 + 0.70 * t
	var base := Color(0.62, 0.80, 1.0)
	draw_circle(c, rr, Color(base.r, base.g, base.b, (0.13 + 0.11 * flick) * fade))
	draw_circle(c, rr * 0.55, Color(0.88, 0.95, 1.0, (0.09 + 0.09 * flick) * fade))
	draw_arc(c, rr, 0.0, TAU, 48,
		Color(base.r, base.g, base.b, (0.42 + 0.32 * flick) * fade), 2.0 * cam_zoom)
	for k in range(4):
		var a0 := tm * (1.3 + 0.37 * float(k)) + float(k) * 1.9
		var a1 := a0 + 1.1 + 0.4 * sin(tm * 3.0 + float(k))
		var r0 := rr * (0.22 + 0.20 * float(k) / 3.0)
		draw_line(c + Vector2(cos(a0), sin(a0)) * r0,
			c + Vector2(cos(a1), sin(a1)) * rr * 0.98,
			Color(0.93, 0.97, 1.0, 0.30 * fade), 1.4 * cam_zoom)

## 黑暗虫群：暗紫绿的雾。
##
## 刻意画得**比风暴更实** —— 它不是一个「事件」，而是一片持续 20 秒的禁区，
## 必须一眼看出来。风暴可以淡（它是伤害，血条会说话），
## 虫群不能淡（它什么伤害都不造成，画面上没有任何别的反馈）。
func _draw_swarm_zone(c: Vector2, rr: float, t: float) -> void:
	var a := 0.26 + 0.14 * t
	draw_circle(c, rr, Color(0.42, 0.30, 0.52, a))
	draw_circle(c, rr * 0.70, Color(0.24, 0.34, 0.24, a * 0.85))
	draw_arc(c, rr, 0.0, TAU, 48, Color(0.64, 0.52, 0.80, 0.50 + 0.30 * t), 2.2 * cam_zoom)
	# 沿边缘爬动的一圈「虫」：位置由 elapsed 驱动，不是随机数（同上）。
	for k in range(10):
		var ang := TAU * float(k) / 10.0 + world.elapsed * 0.6
		draw_circle(c + Vector2(cos(ang), sin(ang)) * rr, 2.4 * cam_zoom,
			Color(0.80, 0.74, 0.96, 0.50))

# 战争迷雾：未探索 = 近乎全黑；探索过但当前不可见 = 压暗的蓝灰。
# 逐格状态做横向游程合并，避免每帧上千次 draw_rect。
func _draw_fog() -> void:
	if world == null or world.vis.is_empty():
		return
	var g := world.grid
	var vr := _visible_rect()
	var c0x := clampi(int(vr.position.x / Grid.CELL) - 1, 0, g.w - 1)
	var c0y := clampi(int(vr.position.y / Grid.CELL) - 1, 0, g.h - 1)
	var c1x := clampi(int(vr.end.x / Grid.CELL) + 1, 0, g.w - 1)
	var c1y := clampi(int(vr.end.y / Grid.CELL) + 1, 0, g.h - 1)
	var cell_sz := Vector2(Grid.CELL, Grid.CELL) * cam_zoom
	var mask := World.VIS_VISIBLE | World.VIS_EXPLORED
	var col_black := Color(0.016, 0.024, 0.043, 0.94)   # 未探索
	var col_dim := Color(0.024, 0.043, 0.078, 0.46)     # 已探索 · 当前不可见
	for y in range(c0y, c1y + 1):
		var x := c0x
		var row := y * g.w
		while x <= c1x:
			var st: int = world.vis[row + x] & mask
			if st == mask:
				x += 1
				continue
			var run := x
			while x <= c1x and (world.vis[row + x] & mask) == st:
				x += 1
			var r := Rect2(_xf(Vector2(run * Grid.CELL, y * Grid.CELL)), Vector2((x - run) * Grid.CELL, Grid.CELL) * cam_zoom)
			draw_rect(r, col_black if st == 0 else col_dim, true)

func _draw_building(b: Building, sp: Vector2, r: float) -> void:
	var fc: Dictionary = GameData.FACTIONS[b.faction]
	var col: Color = fc["color"]
	var accent: Color = fc["accent"]
	var br: float = r
	var tex: Texture2D = TEX.get("b_" + b.type_id, null)
	var side := br * 2.8
	# 贴图框按实际贴图长宽比算 —— 外部素材换成非正方形也不会被压扁
	var tw := side
	var th := side
	if tex != null:
		tw = float(tex.get_width())
		th = float(tex.get_height())
	var sc := side / maxf(tw, th)
	var rect := Rect2(sp - Vector2(tw, th) * 0.5 * sc, Vector2(tw, th) * sc)

	if not b.complete:
		var pr: float = b.progress_ratio()
		# 施工中：半透明的「蓝图」+ 虚线框 + 环形进度
		# 「有没有人在干」必须画出来 —— 工地停滞是最容易被误判成「游戏坏了」的状态。
		var waiting: bool = world.builder_count(b) == 0
		if tex != null:
			draw_texture_rect(tex, rect, false, Color(0.44, 0.56, 0.74, 0.32))
		_dashed_rect(rect, Color(0.95, 0.42, 0.34, 0.85) if waiting
			else Color(col.r, col.g, col.b, 0.72), 1.6 * cam_zoom)
		var bw: float = br * 2.2
		var bcol := Color("ff6b5a") if waiting else Color("ffd166")
		draw_rect(Rect2(sp + Vector2(-bw * 0.5, br + 8 * cam_zoom), Vector2(bw, 3.5 * cam_zoom)), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(sp + Vector2(-bw * 0.5, br + 8 * cam_zoom), Vector2(bw * pr, 3.5 * cam_zoom)), bcol)
		draw_arc(sp, br * 1.24, -PI * 0.5, -PI * 0.5 + TAU * pr, 28,
			Color(0.95, 0.42, 0.34, 0.70) if waiting else Color(col.r, col.g, col.b, 0.70), 1.8 * cam_zoom)
		if waiting:
			var wtxt := "等待建造者"
			var tw2 := font.get_string_size(wtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10.5).x + 12.0
			var tr := Rect2(sp.x - tw2 * 0.5, sp.y + br + 15.0 * cam_zoom, tw2, 15.0)
			draw_rect(tr, Color(0.10, 0.05, 0.06, 0.85), true)
			draw_rect(tr, Color(1.0, 0.42, 0.35, 0.55), false, 1.0)
			_draw_text_center(wtxt, tr, 10.5, Color("ff9b8a"))
		return

	if tex != null:
		var tint := Color(1, 1, 1)
		if b.flash > 0.0:
			var f: float = clampf(b.flash / 0.18, 0.0, 1.0)
			tint = Color(1.0 + f * 1.3, 1.0 + f * 0.35, 1.0 + f * 0.35)
		draw_texture_rect(tex, rect, false, tint)
	else:
		draw_rect(rect, Color(fc["color_dim"].r, fc["color_dim"].g, fc["color_dim"].b, 0.95))
		draw_rect(rect, col, false, 2.0 * cam_zoom)

	# 生产中的脉动光环：一眼看出「这个建筑在干活」
	if b.queue.size() > 0:
		var pulse := 0.5 + 0.5 * sin(b.anim_t * 5.0)
		draw_arc(sp, br * 1.16, 0.0, TAU, 30, Color(accent.r, accent.g, accent.b, 0.14 + 0.24 * pulse), 2.2 * cam_zoom)

	# 血条
	if b.hp < b.max_hp - 0.5:
		_draw_health(sp + Vector2(0, -br * 1.48 - 4.0 * cam_zoom), br * 2.6, b.hp / b.max_hp, cam_zoom, Color("6fe08a"))

	# 生产进度
	if b.queue.size() > 0:
		var q: Dictionary = b.queue[0]
		var pr2: float = 1.0 - clampf(float(q["time_left"]) / maxf(0.001, float(q["total"])), 0.0, 1.0)
		var bw2: float = br * 2.2
		draw_rect(Rect2(sp + Vector2(-bw2 * 0.5, br + 5 * cam_zoom), Vector2(bw2, 3.0 * cam_zoom)), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(sp + Vector2(-bw2 * 0.5, br + 5 * cam_zoom), Vector2(bw2 * pr2, 3.0 * cam_zoom)), Color("5fd0ff"))

	# 选中框
	if world.selected_building == b:
		draw_rect(rect.grow(3 * cam_zoom), Color(0.56, 0.89, 0.42, 0.10))
		draw_rect(rect.grow(3 * cam_zoom), Color("8fe36b"), false, 1.8 * cam_zoom)

func _draw_unit(u: Unit, sp: Vector2, r: float, selected: bool) -> void:
	var id := u.type_id
	var fc: Dictionary = GameData.FACTIONS[u.faction]
	var col: Color = fc["color"]
	var accent: Color = fc["accent"]
	var dir := Vector2(cos(u.facing), sin(u.facing))
	var kind := u.weapon_kind()

	# 护盾：画在贴图之下，形成光环 —— 一眼可辨「这个单位有盾」
	if u.shield > 0.0 and u.max_shield > 0.0:
		var sr := r * 1.98
		var srr: float = clampf(u.shield / u.max_shield, 0.0, 1.0)
		draw_circle(sp, sr, Color(accent.r, accent.g, accent.b, 0.07))
		draw_arc(sp, sr, 0.0, TAU * srr, 26, Color(accent.r, accent.g, accent.b, 0.62), 2.0 * cam_zoom)

	# 法术状态效果：**必须画在单位身上**，不能只靠区域。
	#
	# 心灵风暴有区域可看，但辐照是「挂在一个单位身上」的 ——
	# 不画的话，玩家看到某个兵在掉血却找不到原因，
	# 而且看不出「它在传染」。
	# 黑暗虫群同理：区域会跟着走，但**已经走出去的单位**还会残留 0.35 秒，
	# 那一瞬间的状态只有画在身上才看得见。
	if not u.effects.is_empty():
		var ekind := ""
		var eslow := 1.0
		for e in u.effects:
			var ed: Dictionary = e
			var k := String(ed.get("kind", ""))
			if k == "dot":
				ekind = "dot"
				break
			elif k == "no_ranged":
				ekind = "no_ranged"
			elif k == "slow":
				ekind = "slow"
				eslow = minf(eslow, float(ed.get("slow_mult", 1.0)))
		match ekind:
			"dot":
				# 辐照：脉动的绿色毒环。用 elapsed 驱动，截图可复现。
				var pulse := 0.5 + 0.5 * sin(world.elapsed * 7.0)
				draw_arc(sp, r * 1.75, 0.0, TAU, 22,
					Color(0.62, 1.0, 0.45, 0.35 + 0.45 * pulse), 2.2 * cam_zoom)
			"no_ranged":
				# 黑暗虫群：紫色虚边（实线会和平时的护盾环撞脸）。
				draw_arc(sp, r * 1.62, 0.0, TAU, 20, Color(0.70, 0.55, 0.95, 0.55), 2.0 * cam_zoom)
				draw_arc(sp, r * 1.62, PI * 0.25, PI * 1.25, 8, Color(0.86, 0.78, 1.0, 0.70), 2.0 * cam_zoom)
			"slow":
				# 减速：蓝白色链条环，越慢环越实。
				var t := clampf(1.0 - eslow, 0.0, 1.0)
				draw_arc(sp, r * 1.55, 0.0, TAU, 18, Color(0.60, 0.82, 1.0, 0.30 + 0.45 * t), 2.4 * cam_zoom)

	# ⚠️ 这里**不**给飞行单位叠「额外机翼」。
	#    曾经画过一层（`_draw_wings`），当时是为了救「新单位落进默认分支被画成圆球」
	#    那个 bug —— 圆球当然不像会飞。现在三个空军的贴图里都画了机翼
	#    （幽灵战机的大后掠翼 / 侦察机的引擎舱 / 飞龙的膜翼），再叠一层就是
	#    「四只翅膀」：侦察机上尤其难看，翼根和引擎舱错开成两根金色棍子。
	#    「在空中」这件事交给影子偏移 + 绘制顺序（飞行单位最后画）来表达。

	# 本体。两种呈现方式：
	#   外部素材（侧视精灵图）→ 始终正立，只按朝向左右翻转
	#   程序化贴图（俯视图）  → 跟随朝向旋转
	# 贴图内「正前方」= 上方（-PI/2），所以旋转模式要补 +PI/2 对齐 u.facing。
	var key := "u_" + id
	var tex: Texture2D = TEX.get(key, null)
	var upright: bool = SKIN_ORIENTATION == "upright" and _skin_names.has(key)
	if tex != null:
		var tw := float(tex.get_width())
		var th := float(tex.get_height())
		var sc := (r * 3.1) / maxf(tw, th)
		var tint := Color(1, 1, 1)
		if u.flash > 0.0:
			var f: float = clampf(u.flash / 0.18, 0.0, 1.0)
			tint = Color(1.0 + f * 1.4, 1.0 + f * 0.4, 1.0 + f * 0.4)
		if upright:
			# 内置素材默认朝右，朝左时水平镜像
			var flip := 1.0 if dir.x >= 0.0 else -1.0
			draw_set_transform(sp, 0.0, Vector2(sc * flip, sc))
		else:
			draw_set_transform(sp, u.facing + PI * 0.5 + SKIN_FACING_OFFSET, Vector2(sc, sc))
		draw_texture_rect(tex, Rect2(Vector2(-tw, -th) * 0.5, Vector2(tw, th)), false, tint)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_circle(sp, r, col)

	# 光刃（狂热者）：需要发光，所以用代码画在贴图之上
	if kind == "psiblade":
		var n := Vector2(dir.y, -dir.x)
		for sgn: float in [-1.0, 1.0]:
			var base := sp + dir * (r * 0.45) + n * (sgn * r * 0.62)
			var tip := base + dir * (r * 1.75)
			draw_line(base, tip, Color(0.55, 0.90, 1.0, 0.28), 4.6 * cam_zoom)
			draw_line(base, tip, Color(0.82, 0.96, 1.0, 0.92), 1.9 * cam_zoom)

	# 农民身上扛着的那块资源
	if u.is_worker() and u.carry > 0.0:
		var cp := sp + dir * (r * 1.35)
		var cc := Color("59c8ff") if u.carry_kind == "mineral" else Color("7de08a")
		draw_circle(cp, r * 0.36, Color(cc.r, cc.g, cc.b, 0.32))
		draw_circle(cp, r * 0.22, cc)

	# 建造者标记：被指派到工地的农民，头顶挂扳手 + 一圈工地进度环。
	# 逻辑层一直有 u.build_target，但渲染层从来没读过它 ——
	# 玩家反馈「放建筑时看不出是哪个农民在干活」就是这么来的。
	if u.build_target != null and cam_zoom > 0.6:
		_draw_builder_badge(sp, r, u.build_target)

	# 血条：位置按贴图视觉外缘算，不然一放大就飘到天上去了
	if u.hp < u.max_hp - 0.5 or selected:
		_draw_health(sp + Vector2(0, -r * 1.55 - 4.0 * cam_zoom), r * 2.6, u.hp / u.max_hp, cam_zoom,
			Color("6fe08a") if u.owner_id == _me() else Color("ff7b6b"))

	if selected:
		# 选中圈贴着贴图外缘，而不是逻辑半径 —— 否则放大后会盖住单位本身
		var selr := r * 1.64
		draw_arc(sp, selr, 0.0, TAU, 26, Color(0.56, 0.89, 0.42, 0.92), 1.9 * cam_zoom)
		draw_circle(sp + Vector2(0, selr + 3.6 * cam_zoom), 1.9 * cam_zoom, Color("8fe36b"))

## 建造者徽标：头顶一个扳手 + 身上一圈工地进度环。
##
## 为什么需要它：逻辑层一直有 `u.build_target`，但渲染层从来没读过 ——
## 于是「放一个建筑，整队农民都跑过去」在画面上完全看不出谁真的在干活。
## 修完派工 bug 之后，这一层可视化才让「只有一个农民在干」变得可见、可验证。
##
## `cam_zoom <= 0.6` 时不调用：那时单位只有几个像素，画上去只是一团糊。
func _draw_builder_badge(center: Vector2, r: float, b: Building) -> void:
	# 进度环：贴在单位外缘，比选中圈更细 —— 同时选中时两者不会认错
	var pr: float = clampf(b.progress_ratio(), 0.0, 1.0)
	draw_arc(center, r * 1.90, -PI * 0.5, -PI * 0.5 + TAU * pr, 24,
		Color(0.56, 0.89, 0.42, 0.90), 2.0 * cam_zoom)

	# 扳手：一块深色底 + 一根手柄 + 一段开口圆弧（开口 = 扳手嘴）
	var c := center + Vector2(0.0, -r * 2.25)
	var s := maxf(3.2, r * 0.50) * cam_zoom
	draw_circle(c, s * 1.70, Color(0.06, 0.09, 0.14, 0.85))
	var ang := -PI * 0.25
	var wdir := Vector2(cos(ang), sin(ang))
	var wcol := Color("ffd166")
	var lw := maxf(1.5, s * 0.40)
	draw_line(c - wdir * s * 0.85, c + wdir * s * 0.80, wcol, lw)
	draw_arc(c + wdir * s * 1.20, s * 0.55, ang - PI * 0.74, ang + PI * 0.74, 12, wcol, lw)

func _draw_health(center: Vector2, width: float, ratio: float, zoom: float, col: Color) -> void:
	var hh := 3.2 * zoom
	var hr := Rect2(center - Vector2(width * 0.5, hh * 0.5), Vector2(width, hh))
	draw_rect(hr, Color(0, 0, 0, 0.62))
	var c2 := col
	if ratio < 0.3:
		c2 = Color("ff6b5a")
	elif ratio < 0.6:
		c2 = Color("ffd166")
	draw_rect(Rect2(hr.position, Vector2(hr.size.x * clampf(ratio, 0.0, 1.0), hr.size.y)), c2)

# ---------------------------------------------------------------- 世界层叠加（路径、幽灵、选框）
func _draw_world_ui(vp: Vector2) -> void:
	pass

# ================================================================ 输入
# 触屏优先设计（实现见 _on_touch / _on_drag / _update_pending_gesture）：
#   · 轻点               → 选择己方单位 / 下达指令
#   · 单指滑动           → 平移视野（默认；面板左下可切换成「框选」）
#   · 长按 0.25 秒后拖动 → 框选部队
#   · 双指拖动 / 捏合    → 平移 / 缩放
#   · 小地图（左下）     → 点 / 拖跳转
#   · 双击               → 全选同类 / 全屏

# 编队（面板上的 1~6）：只存单位 id，调用时按 id 回查，避免持有失效引用
var _groups := {}                 # int -> Array[int]
var _group_press_idx := -1
var _group_press_time := 0.0
# 建造菜单的长按介绍卡。和编队行的长按是同一套机制：
# 按下时记下条目 id 与时刻，松手时按「按住多久」决定是进入放置还是弹介绍。
const BUILD_INFO_HOLD := 0.35
var _build_press_id := ""
var _build_press_time := 0.0
var _build_info_id := ""          # 正在展示介绍卡的建筑 id，"" = 不展示
var _markers: Array = []
var _ui_press_id := -1

# ---------------------------------------------------------------- HUD 编辑模式（第十二轮 M2）
var _hud_edit := false              # 是否处于 HUD 布局编辑模式
var _hud_drag := ""                 # 正在拖动的模块名（"" = 没在拖）
var _hud_drag_id := -1              # 拖动那根手指的 index
var _hud_drag_off := Vector2.ZERO   # 抓取点相对模块左上角的偏移
var _hud_sel := ""                  # 当前选中的模块（工具栏属性区用）
var _hud_dirty := false             # 有没有未保存的改动

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		# HUD 编辑模式独占输入：菜单与战斗两套输入栈都不该被触发，
		# 否则拖模块的时候会把底下的菜单项一起点了。
		if _hud_edit:
			_hud_edit_touch(event.index, event.position, event.pressed)
			return
		if state == St.MENU:
			if event.pressed:
				_menu_press(event.position)
			else:
				_menu_release(event.position)
			return
		if state == St.END:
			if event.pressed:
				_end_press(event.position)
			return
		if state == St.LAN_SCAN:
			# 搜索房间页也没有世界可操作 —— 只认房间行和「返回」。
			if event.pressed:
				_lan_scan_press(event.position)
			return
		if state == St.LOBBY:
			# 大厅里没有世界可操作，只认那一个「取消」按钮 ——
			# 不拦的话会落到 `_on_touch`，把还没建的摄像机拖来拖去。
			if event.pressed:
				_lobby_press(event.position)
			return
		_on_touch(event.index, event.position, event.pressed)
	elif event is InputEventScreenDrag and _hud_edit:
		_hud_edit_drag(event.position)
	elif event is InputEventScreenDrag and state == St.MENU:
		_menu_drag(event.position)
	elif event is InputEventScreenDrag and state == St.PLAY:
		_on_drag(event.index, event.position, event.relative)
	elif event is InputEventKey and event.pressed and not event.echo and state == St.PLAY:
		_on_key(event)

func _on_touch(index: int, pos: Vector2, pressed: bool) -> void:
	# 聊天键盘是**模态**的：打开时吞掉所有战场操作。
	# 少了这个 return，点键盘上那个 "A" 会同时在战场上框选一片部队 ——
	# 而玩家只会觉得「打字的时候部队自己动了」。
	if _lan_input_key != "":
		if pressed:
			for m in lan_keypad_rects(get_viewport_rect().size):
				var kr: Rect2 = m["rect"]
				if kr.has_point(pos):
					_lan_input_press(String(m["key"]))
					return
		return
	if pressed:
		_touches[index] = {"pos": pos, "start": pos, "time": Time.get_ticks_msec() / 1000.0}

		# 0) 帮助面板是全屏遮罩，点任意处先关掉它
		if _show_help:
			# ⚠️ 音量滑块必须排在「点任意处关闭」**之前**。
			#    反过来的话手指一按面板就关了，滑块永远拖不动 ——
			#    而且不报错，只是「这个滑块是坏的」。
			if _vol_slider_rect.has_point(pos):
				_vol_drag_id = index
				_set_volume_from_x(pos.x)
				_touches.erase(index)
				return
			_show_help = false
			_touches.erase(index)
			return

		# 0.5) 建造介绍卡同样是模态的：点任意处先关掉它。
		#      放在小地图之前 —— 卡片盖住了哪里，哪里就不该响应。
		if _build_info_id != "":
			_build_info_id = ""
			_touches.erase(index)
			return

		# 1) 小地图优先级最高：点一下就把镜头跳过去
		#    「点小地图跳转」关掉后单击不再瞬移，但**按住拖动仍然能拖镜头** ——
		#    拖是显式操作（有位移才会触发），把拖动也禁掉等于把小地图废掉。
		if _minimap_rect.has_point(pos):
			_minimap_id = index
			if Settings.flag("minimap_jump", true):
				_minimap_jump(pos)
			_touches.erase(index)
			return

		# 2) 统一 UI 命中表 —— 顶栏、底部面板、建造菜单浮层、悬浮按钮都在这里。
		#    不再靠 y 坐标猜，所以画在面板**外面**的菜单也能点到。
		var hit := _ui_pick(pos)
		if not hit.is_empty():
			_ui_press_id = index
			_ui_press_hit = hit
			_group_press_idx = -1
			_build_press_id = ""
			if String(hit["act"]) == "group":
				_group_press_idx = int(hit["arg"])
				_group_press_time = Time.get_ticks_msec() / 1000.0
			elif String(hit["act"]) == "pick_build":
				# 建造条目：轻点 = 进入放置，长按 = 弹介绍卡。松手时才分叉。
				_build_press_id = String(hit["arg"])
				_build_press_time = Time.get_ticks_msec() / 1000.0
			return

		# 3) 放置模式：拖动建筑幽灵，松手确认
		if _placing_build != "":
			_place_drag_id = index
			_ghost_pos = _screen_to_world(pos)
			return

		# 3b) 法术瞄准态：和放置建筑**同一套手势**（按下拖动、松手确认）。
		#     放在 UI 命中之后 —— 技能键本身仍然要能点（再点一次 = 取消瞄准）。
		if _aim_spell != "":
			_aim_drag_id = index
			_aim_pos = _screen_to_world(pos)
			return

		# 4) 第二根手指落下 → 转入双指手势，作废单指的待定状态
		if _touches.size() >= 2:
			_begin_pinch()
			return

		# 5) 单指：进入「待定」，由位移 / 时间阈值决定是平移还是框选
		_sel_mode = Sel.PENDING
		_sel_start = pos
		_sel_rect = Rect2(pos, Vector2.ZERO)
		return

	var info: Dictionary = _touches.get(index, {})
	_touches.erase(index)

	if index == _vol_drag_id:
		_vol_drag_id = -1
		return

	if index == _minimap_id:
		_minimap_id = -1
		return

	# 放置模式松手 → 确认落位
	if index == _place_drag_id:
		_place_drag_id = -1
		_confirm_place(_ghost_pos)
		return

	# 法术瞄准松手 → 施放
	if index == _aim_drag_id:
		_aim_drag_id = -1
		_confirm_cast()
		return

	if index == _ui_press_id:
		_ui_press_id = -1
		var h := _ui_press_hit
		_ui_press_hit = {}
		if _group_press_idx >= 0:
			var held := Time.get_ticks_msec() / 1000.0 - _group_press_time
			_group_apply(_group_press_idx, held > 0.45)
			_group_press_idx = -1
			return
		if _build_press_id != "":
			var bid := _build_press_id
			_build_press_id = ""
			if Time.get_ticks_msec() / 1000.0 - _build_press_time >= BUILD_INFO_HOLD:
				# 长按 → 弹介绍卡（再长按同一条 = 收起），**不**进入放置模式
				_build_info_id = "" if _build_info_id == bid else bid
				_play_direct("ui_open")
			elif not h.is_empty():
				_dispatch_ui(h)
			return
		if not h.is_empty():
			_dispatch_ui(h)
		return

	if _pinch_active:
		if _touches.size() < 2:
			_pinch_active = false
		return

	if info.is_empty():
		return
	var start: Vector2 = info["start"]

	if _sel_mode == Sel.PAN:
		_sel_mode = Sel.NONE
		return
	if _sel_mode == Sel.BOX:
		if start.distance_to(pos) > TAP_SLOP:
			_do_box_select()
		else:
			_do_tap_command(start)
		_sel_mode = Sel.NONE
		_sel_rect = Rect2()
		return
	if _sel_mode == Sel.PENDING:
		# 没动、也没停够长按时间 → 轻点
		if start.distance_to(pos) <= TAP_SLOP:
			_do_tap_command(start)
		_sel_mode = Sel.NONE
		_sel_rect = Rect2()

## 收集当前所有手指位置
func _active_points() -> Array:
	var out := []
	for id in _touches:
		out.append(_touches[id]["pos"])
	return out

## 第二根手指落下：开始捏合/双指平移
func _begin_pinch() -> void:
	_sel_mode = Sel.NONE
	_sel_rect = Rect2()
	_pinch_active = true
	var pts := _active_points()
	if pts.size() >= 2:
		_pinch_dist = pts[0].distance_to(pts[1])
		_pinch_mid = (pts[0] + pts[1]) * 0.5
		_pinch_zoom_start = cam_zoom

func _on_drag(index: int, pos: Vector2, rel: Vector2) -> void:
	if _touches.has(index):
		_touches[index]["pos"] = pos

	# 音量滑块拖动。放在最前面 —— 帮助面板是模态的，滑块必须能持续拖。
	if index == _vol_drag_id:
		_set_volume_from_x(pos.x)
		return

	# 放置模式：拖动幽灵
	if index == _place_drag_id:
		_ghost_pos = _screen_to_world(pos)
		return

	# 法术瞄准：拖动落点
	if index == _aim_drag_id:
		_aim_pos = _screen_to_world(pos)
		return

	# 小地图拖动 = 拖动镜头
	if index == _minimap_id:
		_minimap_jump(pos)
		return

	# 双指：捏合缩放 + 中点位移平移
	if _pinch_active:
		var pts := _active_points()
		if pts.size() >= 2:
			var d: float = pts[0].distance_to(pts[1])
			var mid: Vector2 = (pts[0] + pts[1]) * 0.5
			if _pinch_dist > 8.0:
				cam_zoom = clampf(_pinch_zoom_start * (d / _pinch_dist), 0.42, 2.0)
			cam_pos -= (mid - _pinch_mid) / cam_zoom
			_pinch_mid = mid
			_clamp_camera()
		return

	if not _touches.has(index):
		return

	# 待定 → 首次位移越过阈值时定型。
	# 「先动 = 平移，先停 = 框选」：不需要额外模式按钮，也不打断操作节奏。
	if _sel_mode == Sel.PENDING:
		var st: Vector2 = _touches[index]["start"]
		if st.distance_to(pos) <= PAN_SLOP:
			return
		if _single_drag_pans:
			_sel_mode = Sel.PAN
		else:
			_sel_mode = Sel.BOX
			_sel_start = st
			_sel_rect = _normalize_rect(st, pos)
			return
		# 落入平移分支，继续往下走，把这一次位移也应用上

	if _sel_mode == Sel.PAN:
		cam_pos -= rel / cam_zoom
		_clamp_camera()
		return

	if _sel_mode == Sel.BOX:
		_sel_rect = _normalize_rect(_sel_start, pos)

func _normalize_rect(a: Vector2, b: Vector2) -> Rect2:
	return Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), Vector2(absi(a.x - b.x), absi(a.y - b.y)))

# ================================================================ 小地图
## 小地图放**左下角**（面板上方）。
## 横屏双手持机时，右下是右手拇指的自然落点，那个位置应该留给高频指令；
## 小地图属于「偶尔看一眼、偶尔点一下」，放左边不占拇指区。
func _minimap_layout(vp: Vector2) -> void:
	if world == null:
		_minimap_rect = Rect2()
		return
	# M2：位置由 `HudLayout` 的 `minimap` 模块决定（默认仍是左下角、面板上方）。
	# 旧公式 `Rect2(12, vp.y - PANEL_H - h - 12, w, h)` 与默认布局**逐像素相等**，
	# 由 `tests/Hud.gd` 钉死 —— 改这里就要同步改那份参照。
	_minimap_rect = _mod_rect("minimap", vp)

## 地形底图烘焙成一张小纹理，避免每帧重画几千个格子
func _build_minimap_texture() -> void:
	if world == null:
		return
	var gw := world.grid.w
	var gh := world.grid.h
	var img := Image.create(gw, gh, false, Image.FORMAT_RGBA8)
	for y in range(gh):
		for x in range(gw):
			var t: int = world.grid.cells[y * gw + x]
			var c := Color("1b2537")
			if t == Grid.Terrain.ROCK:
				c = Color("3d4760")
			elif t == Grid.Terrain.CHASM:
				c = Color("080d15")
			# 高低差：高地和坡道在小地图上必须看得出来 ——
			# 小地图是玩家判断「崖顶有没有人」的唯一手段，
			# 画成同一个颜色的话，那条 30% miss 的规则在实战里完全用不上。
			elif t == Grid.Terrain.RAMP:
				c = Color("8a7440")
			elif world.grid.elev[y * gw + x] == 1:
				c = Color("4a5c85")
			img.set_pixel(x, y, c)
	_minimap_tex = ImageTexture.create_from_image(img)

## 小地图的迷雾覆盖层：一个像素对应一个格子，用透明度区分三种状态
## 地貌图：每格 1 像素，用低频正弦在几种地面色调之间插值。
## 拉伸到世界尺寸后形成柔和的大色带 —— 这是「地图有地形」的关键，
## 只靠 64px 的 tile 平铺，无论纹理多细，远看都是一整片均匀的地面。
func _build_biome_texture() -> void:
	if world == null:
		return
	var gw := world.grid.w
	var gh := world.grid.h
	var img := Image.create(gw, gh, false, Image.FORMAT_RGBA8)
	var fx := TAU / float(gw)
	var fy := TAU / float(gh)
	# 主调是深蓝灰，局部掺入青绿与紫灰。地貌变化靠「明度差」而不是「色相差」——
	# 色相拉太开会让地面显得脏，反而廉价。
	var pal := [Color("26303f"), Color("36465e"), Color("2b3739"), Color("373243")]
	for y in range(gh):
		var py := float(y)
		for x in range(gw):
			var px := float(x)
			var n := 0.5 \
				+ 0.34 * sin(px * fx * 1.0 + 0.8) * sin(py * fy * 1.0 + 2.3) \
				+ 0.22 * sin(px * fx * 2.0 + 3.1) * sin(py * fy * 2.0 + 1.2) \
				+ 0.14 * sin(px * fx * 3.0 + 0.4) * sin(py * fy * 3.0 + 4.0)
			var t := clampf(n, 0.0, 0.999) * float(pal.size() - 1)
			var i0 := int(t)
			var i1 := mini(i0 + 1, pal.size() - 1)
			img.set_pixel(x, y, (pal[i0] as Color).lerp(pal[i1] as Color, t - float(i0)))
	_biome_tex = ImageTexture.create_from_image(img)

func _rebuild_minimap_fog() -> void:
	if world == null or world.vis.is_empty():
		_minimap_fog_tex = null
		return
	var gw := world.grid.w
	var gh := world.grid.h
	var img := Image.create(gw, gh, false, Image.FORMAT_RGBA8)
	var mask := World.VIS_VISIBLE | World.VIS_EXPLORED
	for y in range(gh):
		var row := y * gw
		for x in range(gw):
			var st: int = world.vis[row + x] & mask
			if st == mask:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			elif st == 0:
				img.set_pixel(x, y, Color(0.012, 0.02, 0.035, 0.93))
			else:
				img.set_pixel(x, y, Color(0.02, 0.035, 0.06, 0.42))
	_minimap_fog_tex = ImageTexture.create_from_image(img)

## 屏幕坐标 → 世界坐标（小地图专用）
func _minimap_jump(screen_pos: Vector2) -> void:
	if _minimap_rect.size.x <= 1.0 or world == null:
		return
	var t := Vector2(
		(screen_pos.x - _minimap_rect.position.x) / _minimap_rect.size.x,
		(screen_pos.y - _minimap_rect.position.y) / _minimap_rect.size.y)
	t.x = clampf(t.x, 0.0, 1.0)
	t.y = clampf(t.y, 0.0, 1.0)
	cam_pos = t * world.world_size
	_clamp_camera()

func _minimap_to_screen(p: Vector2) -> Vector2:
	return _minimap_rect.position + Vector2(
		p.x / maxf(1.0, world.world_size.x) * _minimap_rect.size.x,
		p.y / maxf(1.0, world.world_size.y) * _minimap_rect.size.y)

func _draw_minimap(vp: Vector2) -> void:
	_minimap_layout(vp)
	var r := _minimap_rect
	if r.size.x <= 1.0:
		return
	draw_rect(r.grow(3.0), Color(0.04, 0.06, 0.10, 0.92), true)
	if _minimap_tex != null:
		draw_texture_rect(_minimap_tex, r, false)
	# 迷雾压在底图之上、单位之下：己方单位即使在暗区也要能看见
	if _minimap_fog_tex != null:
		draw_texture_rect(_minimap_fog_tex, r, false)

	# 资源点（只显示已探索区域）
	for res in world.resources:
		if float(res["amount"]) <= 0.0:
			continue
		if not world.is_explored(res["pos"]):
			continue
		var c := Color("59c8ff") if String(res["kind"]) == "mineral" else Color("7de08a")
		draw_circle(_minimap_to_screen(res["pos"]), 1.8, c)

	# 建筑
	for b in world.buildings:
		if b.dead:
			continue
		if b.owner_id != _me() and not world.is_visible(b.pos):
			continue
		var c: Color = GameData.FACTIONS[b.faction]["color"]
		var sp := _minimap_to_screen(b.pos)
		if b.owner_id != _me():
			c = Color("ff6b5a")
		draw_rect(Rect2(sp - Vector2(2.4, 2.4), Vector2(4.8, 4.8)), c, true)

	# 单位
	for u in world.units:
		if u.dead:
			continue
		if u.owner_id != _me() and not world.is_visible(u.pos):
			continue
		var c: Color = GameData.FACTIONS[u.faction]["color"]
		if u.owner_id != _me():
			c = Color("ff6b5a")
		draw_circle(_minimap_to_screen(u.pos), 1.6, c)

	# 当前镜头范围框
	var vr := _visible_rect()
	var a := _minimap_to_screen(vr.position)
	var b2 := _minimap_to_screen(vr.end)
	var box := Rect2(Vector2(minf(a.x, b2.x), minf(a.y, b2.y)),
		Vector2(absi(b2.x - a.x), absi(b2.y - a.y)))
	draw_rect(box, Color(1, 1, 1, 0.10), true)
	draw_rect(box, Color(0.85, 0.92, 1.0, 0.85), false, 1.2)
	draw_rect(r, Color(1, 1, 1, 0.22), false, 1.0)

# ================================================================ 全选
func _select_all_on_screen() -> void:
	var got := world.units_in_rect(_visible_rect(), _me())
	if got.is_empty():
		_toast("屏幕内没有己方单位", Color("ffd166"))
		return
	world.selection = got
	world.selected_building = null
	_build_menu_open = false
	_toast("全选屏幕内 %d 个单位" % got.size(), Color("8fe36b"))

func _select_all_of_type(type_id: String) -> void:
	var got := []
	for u in world.units_of(_me()):
		if u.type_id == type_id:
			got.append(u)
	if got.is_empty():
		return
	world.selection = got
	world.selected_building = null
	_build_menu_open = false
	_toast("全选 %s ×%d" % [String(GameData.get_unit(type_id).get("name", type_id)), got.size()], Color("8fe36b"))

# ================================================================ 编队
## 点按 = 调用编队（并把镜头带过去）；长按 = 用当前选择覆盖保存；编队为空时点按即保存。
func _group_apply(idx: int, force_save: bool) -> void:
	var ids: Array = _groups.get(idx, [])
	if force_save or ids.is_empty():
		if world.selection.is_empty():
			if _groups.has(idx):
				_groups.erase(idx)
				_toast("编队 %d 已清空" % (idx + 1), Color("ffd166"))
			else:
				_toast("先选中单位，再点编队 %d 保存" % (idx + 1), Color("ffd166"))
			return
		var new_ids := []
		for u in world.selection:
			new_ids.append(u.id)
		_groups[idx] = new_ids
		_toast("编队 %d ← %d 个单位" % [idx + 1, new_ids.size()], Color("8fe36b"))
		return

	var got := []
	for u in world.units_of(_me()):
		if ids.has(u.id):
			got.append(u)
	if got.is_empty():
		_groups.erase(idx)
		_toast("编队 %d 已失效" % (idx + 1), Color("ffd166"))
		return
	world.selection = got
	world.selected_building = null
	_build_menu_open = false
	_attack_move_mode = false
	# 移动端一次点击就能完成「调用 + 归位镜头」，比双击更省事
	var c := Vector2.ZERO
	for u in got:
		c += u.pos
	cam_pos = c / float(got.size())
	_clamp_camera()
	_toast("编队 %d · %d 个单位" % [idx + 1, got.size()], Color("8fd0ff"))

## 每帧重建编队按钮行。属于 `queue` 模块，坐标全部相对模块原点。
## 模块被拖走 / 缩放时，这里一个字都不用改。
func _draw_group_row(org: Rect2, sc: float) -> void:
	draw_string(font, Vector2(org.position.x + 12.0 * sc, org.position.y + 28.0 * sc),
		"编队", HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0 * sc, Color(0.55, 0.62, 0.74))
	var x := org.position.x + 54.0 * sc
	for i in range(6):
		var r := Rect2(x, org.position.y, BTN_GROUP_W * sc, BTN_GROUP_H * sc)
		var ids: Array = _groups.get(i, [])
		var active := not ids.is_empty()
		draw_rect(r, Color(0.56, 0.89, 0.42, 0.20) if active else Color(1, 1, 1, 0.06), true)
		draw_rect(r, Color("8fe36b") if active else Color(1, 1, 1, 0.14), false, 1.2)
		_draw_text_center(str(i + 1), r, 16.0 * sc,
			Color(0.92, 0.95, 1.0) if active else Color(0.58, 0.62, 0.70))
		if active:
			draw_string(font, Vector2(r.end.x - 15.0 * sc, r.end.y - 6.0 * sc),
				str(ids.size()), HORIZONTAL_ALIGNMENT_LEFT, -1, 10.0 * sc, Color("8fe36b"))
		_ui_hit(r, "group", i)
		x += (BTN_GROUP_W + 6.0) * sc

func _screen_to_world(pos: Vector2) -> Vector2:
	return (pos - get_viewport_rect().size * 0.5) / cam_zoom + cam_pos

func _do_tap_command(screen_pos: Vector2) -> void:
	if _placing_build != "":
		return

	# 双击识别：双击单位 = 全选同类；双击空地 = 全选屏幕内所有单位
	var now := Time.get_ticks_msec() / 1000.0
	var is_double := now - _prev_tap_time < 0.34 and screen_pos.distance_to(_prev_tap_pos) < 64.0
	_prev_tap_time = now
	_prev_tap_pos = screen_pos

	var wp := _screen_to_world(screen_pos)
	var entity = world.find_entity_at(wp)
	var node = world.find_resource_at(wp)

	if is_double:
		_prev_tap_time = 0.0
		if entity != null and entity is Unit and entity.owner_id == _me():
			_select_all_of_type(entity.type_id)
		else:
			_select_all_on_screen()
		return

	if entity != null and entity is Unit and entity.owner_id == _me():
		# 再点一次已单独选中的单位 → 全选同类（铁锈战争的手感）
		if world.selection.size() == 1 and world.selection[0] == entity:
			_select_all_of_type(entity.type_id)
			return
		world.selection = [entity]
		world.selected_building = null
		_build_menu_open = false
		_attack_move_mode = false
		return
	if entity != null and entity is Building and entity.owner_id == _me():
		world.selection = []
		world.selected_building = entity
		_build_menu_open = false
		_attack_move_mode = false
		return

	# 攻击移动模式：对地面下达攻击移动
	if _attack_move_mode and not world.selection.is_empty():
		_c_move(world.selection, wp, true)
		_add_marker(wp)
		_toast("攻击移动", Color("ff8a7a"))
		_attack_move_mode = false
		return

	if entity != null and not world.selection.is_empty():
		_c_attack(world.selection, entity)
		_add_marker(entity.pos)
		_toast("攻击", Color("ff8a7a"))
		return
	if node != null and not world.selection.is_empty():
		_c_smart(world.selection, wp, node, null)
		_add_marker(node["pos"])
		return
	if not world.selection.is_empty():
		_c_smart(world.selection, wp, null, null)
		_add_marker(wp)
	elif world.selected_building != null:
		_c_rally(world.selected_building, wp)
		_toast("已设置集结点", Color("8fe36b"))
	else:
		world.selected_building = null

func _add_marker(p: Vector2) -> void:
	_markers.append({"pos": p, "life": 0.65, "max": 0.65})

func _do_box_select() -> void:
	var a := _screen_to_world(_sel_rect.position)
	var b := _screen_to_world(_sel_rect.end)
	var wr := Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), Vector2(absi(a.x - b.x), absi(a.y - b.y)))
	var got := world.units_in_rect(wr, _me())
	if got.is_empty():
		world.selection = []
		world.selected_building = null
		return
	var fighters := []
	for u in got:
		if not u.can_harvest():
			fighters.append(u)
	world.selection = fighters if not fighters.is_empty() else got
	world.selected_building = null
	_build_menu_open = false

func _on_key(e: InputEventKey) -> void:
	match e.keycode:
		KEY_ESCAPE:
			if _placing_build != "":
				_placing_build = ""
			elif _build_menu_open:
				_build_menu_open = false
			elif _show_help:
				_show_help = false
		KEY_F1:
			_show_help = not _show_help
		KEY_SPACE:
			var bases := world.buildings_of(_me())
			cam_pos = bases[0].pos if not bases.is_empty() else world.world_size * 0.5
			_clamp_camera()
		KEY_B:
			_toggle_build_menu()
		KEY_A:
			world.selection = world.units_of(_me())
		KEY_S:
			_c_stop(world.selection)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
			_train_hotkey(e.keycode - KEY_1)

func _toggle_build_menu() -> void:
	if world.selected_building != null or world.selection.is_empty():
		return
	_build_menu_open = not _build_menu_open

func _train_hotkey(i: int) -> void:
	if world.selected_building == null:
		return
	var list: Array = world.selected_building.trains()
	if i < list.size():
		_c_train(world.selected_building, String(list[i]))

# ================================================================ UI 命中
## 倒序查找命中表 —— 后画的在上层，所以从后往前找。
func _ui_pick(p: Vector2) -> Dictionary:
	for i in range(_ui_hits.size() - 1, -1, -1):
		if (_ui_hits[i]["rect"] as Rect2).has_point(p):
			return _ui_hits[i]
	return {}

## 登记一个可点区域。act 决定点击行为，arg 是行为参数。
## 所有 _draw_* 里画出来的可点元素都要调这个 —— 画了不登记就等于点不到。
func _ui_hit(r: Rect2, act: String, arg: Variant = null) -> void:
	_ui_hits.append({"rect": r, "act": act, "arg": arg})

## 分发 UI 点击。所有可点元素统一走这里，不再靠坐标猜测。
func _dispatch_ui(hit: Dictionary) -> void:
	var act := String(hit.get("act", ""))
	var arg: Variant = hit.get("arg", null)
	_play_direct("ui_click")
	match act:
		"top_home":
			var b0 := world.buildings_of(_me())
			if not b0.is_empty():
				cam_pos = b0[0].pos
				_clamp_camera()
		"stop":
			_c_stop(world.selection)
			_toast("停止", Color("ffd166"))
		"all":
			world.selection = world.units_of(_me())
			world.selected_building = null
		"home":
			var bases := world.buildings_of(_me())
			if not bases.is_empty():
				cam_pos = bases[0].pos
				_clamp_camera()
		"sfx":
			_sfx_on = not _sfx_on
			_toast("音效已" + ("开启" if _sfx_on else "关闭"), Color("8fd0ff"))
		"pause":
			# ★局域网：暂停是**主机权威**的。★
			#   客户端只发「请求」，本地状态**不动** —— 它自己不跑模拟，
			#   本地暂停毫无意义，只会造成「我这边停了、主机还在打」的错觉。
			if _lan_active():
				if _authoritative:
					session.set_paused(not session.is_paused())
				else:
					session.request_pause(not session.is_paused())
				# 提示语统一由 `pause_changed` 回执时出（`_on_lan_pause`）——
				# 在这里也弹一条的话，客户端会看到「已暂停」和「主机已暂停」两条。
			else:
				paused = not paused
				_toast("已暂停" if paused else "继续", Color("ffd166") if paused else Color("8fe36b"))
		"chat":
			# 复用屏幕键盘：`chat` 是第三种输入类型（见 `_lan_open_input`）。
			if _lan_active():
				_lan_open_input("chat")
		"surrender":
			if _lan_active() and session.surrender():
				_push_chat("系统", "你认输了")
		"speed":
			# 1× → 1.5× → 2× → 1× 循环。
			# ⚠️ 写成嵌套三元表达式极易把方向写反（第一版就是：1× 点一下还是 1×），
			#    这里用显式分支，让「下一档是多少」一眼可读。
			# ⚠️ 只乘 delta，不动任何单位数值 —— 速度档位绝不能影响平衡。
			if game_speed < 1.25:
				game_speed = 1.5
			elif game_speed < 1.75:
				game_speed = 2.0
			else:
				game_speed = 1.0
			_toast("游戏速度 " + _speed_text(), Color("8fd0ff"))
		"dragmode":
			_single_drag_pans = not _single_drag_pans
			_toast("单指拖动：" + ("平移视野" if _single_drag_pans else "框选部队"), Color("8fd0ff"))
		"help":
			_show_help = true
		"close_help":
			_show_help = false
		"build":
			_build_info_id = ""
			if _placing_build != "":
				_placing_build = ""
				_toast("已取消放置", Color("ffd166"))
			else:
				_build_menu_open = not _build_menu_open
				if _build_menu_open:
					_play_direct("ui_open")
		"pick_build":
			_start_placing(String(arg))
		"harvest":
			var workers := []
			for u in world.selection:
				if u.can_harvest():
					workers.append(u)
			if not workers.is_empty():
				var best = null
				for r in world.resources:
					if r["amount"] <= 0.0:
						continue
					if best == null or workers[0].pos.distance_squared_to(r["pos"]) < workers[0].pos.distance_squared_to(best["pos"]):
						best = r
				if best != null:
					_c_harvest(workers, best)
					_play_direct("unit_ack")
		"amove":
			_attack_move_mode = not _attack_move_mode
			_toast("攻击移动：点地面下令" if _attack_move_mode else "已取消攻击移动",
				Color("ff8a7a") if _attack_move_mode else Color("8fd0ff"))
		"sametype":
			if not world.selection.is_empty():
				_select_all_of_type(String(world.selection[0].type_id))
		"cancelbuild":
			var cb: Building = world.selected_building
			if cb != null:
				var nm := String(cb.data.get("name", ""))
				if _c_cancel_build(cb):
					world.selected_building = null
					_toast("已取消建造 %s（已退款）" % nm, Color("ffd166"))
		"train":
			if world.selected_building != null:
				_c_train(world.selected_building, String(arg))
				_play_direct("unit_ack")
		"queue":
			var b: Building = world.selected_building
			if b != null:
				var qi := int(arg)
				if qi >= 0 and qi < b.queue.size():
					var qq: Dictionary = b.queue[qi]
					var nm := String(GameData.get_unit(String(qq["type_id"])).get("name", ""))
					if _c_cancel_queue(b, qi):
						_toast("取消生产 %s（已退款）" % nm, Color("ffd166"))
		"research":
			var rb: Building = world.selected_building
			if rb != null:
				var ruid := String(arg)
				var rc := world.next_upgrade_cost(_me(), ruid)
				var rn := String(GameData.get_upgrade(ruid).get("name", ruid))
				if rc.is_empty():
					_toast("%s 已满级" % rn, Color("ffd166"))
				elif not world.can_afford(_me(), ruid):
					_toast("资源不足：%s" % rn, Color("ff9b7b"))
					_play_direct("ui_error")
				elif _c_research(rb, ruid):
					_toast("开始研究 %s" % rn, Color("8fe36b"))
		"ability":
			var aid := String(arg)
			# 只对「选中单位里能用这个技能」的那些下指令 ——
			# 混编部队（陆战队员 + 坦克）点兴奋剂时，坦克不该报错。
			var users := []
			for su in world.selection:
				if world.can_use_ability(su, aid):
					users.append(su)
			# 再点一次正在瞄准的技能键 = 取消瞄准。
			# 没有这条的话，玩家点错了技能就只能硬放出去（或者去点别的地方）——
			# 而点别的地方会真的把法术放出去，代价是 75 点能量。
			if _aim_spell == aid:
				_aim_spell = ""
				_play_direct("ui_open")
				_toast("已取消 %s" % String(GameData.get_spell(aid).get("name", aid)),
					Color("8fd0ff"))
			elif _begin_aim(aid, users):
				pass
			elif users.is_empty():
				_play_direct("ui_error")
			elif _c_ability(users, aid, null):
				if aid == "stim":
					_toast("兴奋剂 ×%d" % users.size(), Color("ff8a7a"))
				elif aid == "siege":
					_toast("攻城模式", Color("ffd166"))
		_:
			pass

func _start_placing(type_id: String) -> void:
	_placing_build = type_id
	_build_info_id = ""
	_build_menu_open = false
	_ghost_pos = cam_pos
	_attack_move_mode = false
	_toast("拖动到位置后松手放置 " + String(GameData.get_building(type_id).get("name", "")), Color("5fd0ff"))

func _confirm_place(world_pos: Vector2) -> void:
	if _placing_build == "":
		return
	# 把选中的农民传下去 —— 选中几个就派几个去（星际 1 的行为）。
	# 没选（或选的是战斗单位）时 World 会自动挑最近的一个，永远只挑一个：
	# 「放一个建筑整队农民全跑过来」是 bug，不是特性。
	var crew: Array = []
	for su in world.selection:
		if su.can_harvest():
			crew.append(su)
	if _c_build(_placing_build, world_pos, crew):
		_placing_build = ""
		_play_direct("place_ok")
	# 失败时 World 会 event_alert → _on_alert 播 ui_error，这里不用重复

func _toast(text: String, color: Color) -> void:
	_toasts.append({"text": text, "color": color, "life": 1.6, "max": 1.6})
	if _toasts.size() > 4:
		_toasts.pop_front()

## 进入法术瞄准态。返回 true 表示「这个技能需要点地，已经接管了」。
##
## 只有 `ground_aoe` 类的法术（心灵风暴 / 黑暗虫群）需要瞄准；
## 辐照是**点目标**的，和治疗一样直接施放 —— 让它也走瞄准态的话，
## 玩家要先把圈拖到敌人身上再松手，而圈是按「范围半径」画的，
## 会让人误以为辐照是范围技能。
##
## ⚠️ `users` 必须非空才进入瞄准：否则玩家选中一堆农民点技能键，
##    会进入一个「怎么点都放不出来」的瞄准态，还退不出去（只能再点一次键）。
func _begin_aim(aid: String, users: Array) -> bool:
	if users.is_empty():
		return false
	var sp := GameData.get_spell(aid)
	if sp.is_empty() or String(sp.get("kind", "")) != "ground_aoe":
		return false
	_aim_spell = aid
	# 落点初值给镜头中心：玩家点完技能键之后，手指本来就在屏幕中央附近，
	# 直接松手就能放出来（不用先拖到某处）。
	_aim_pos = cam_pos
	_aim_drag_id = -1
	_attack_move_mode = false
	_placing_build = ""
	_build_menu_open = false
	_toast("拖动选择落点，松手施放 %s" % String(sp.get("name", aid)), Color("9ad0ff"))
	return true

## 瞄准态的自愈检查：选中的部队里已经没人能放这个法术了，就退出瞄准。
##
## ⚠️ 为什么要有这一步：选择会从**十几个地方**被改（点选 / 框选 / 编队 /
##    全选同类 / 建筑被选中…）。在每一处都写一句「取消瞄准」，
##    漏一处就是「玩家切了选择，屏幕还挂着一个瞄准圈」——
##    这时候点地图会朝一个早已不存在的圣堂武士下施法指令，
##    客户端表现为「点了没反应」，而单机上只是白扣一次操作。
##    与其追着十几个调用点跑，不如每帧问一次「还能放吗」。
func _guard_aim_state() -> void:
	if _aim_spell == "":
		return
	if world == null or world.selected_building != null:
		_aim_spell = ""
		return
	for su in world.selection:
		if world.can_use_ability(su, _aim_spell):
			return
	_aim_spell = ""

## 确认施放瞄准中的法术。
##
## ⚠️ 落点合法性（施法距离）由 **World** 判，不在这里判 ——
##    这里再判一遍的话，两处判据一旦不一致（比如高地射程加成只在一边算了），
##    就会出现「提示条说够得着、实际放不出来」。UI 只负责「看起来对不对」。
func _confirm_cast() -> void:
	if _aim_spell == "":
		return
	var sid := _aim_spell
	_aim_spell = ""
	var users := []
	for su in world.selection:
		if world.can_use_ability(su, sid):
			users.append(su)
	if users.is_empty():
		_play_direct("ui_error")
		return
	var nm := String(GameData.get_spell(sid).get("name", sid))
	if _c_ability(users, sid, _aim_pos):
		_toast("%s ×%d" % [nm, users.size()], Color("9ad0ff"))
	else:
		_toast("%s 超出施法距离或能量不足" % nm, Color("ff9b7b"))
		_play_direct("ui_error")

# ================================================================ 底部指令面板
## 底部指令面板的底板。
##
## M2 起它不再是「通栏贴底 180px」的常量，而是由 `info` / `queue` / `cmd`
## 三个模块推导出来（见 `HudLayout.panel_rect()`）—— 玩家把指令区往上拖，
## 底板就跟着长上去。
##
## ⚠️ 默认布局下算出来仍然是 `Rect2(0, vp.y-180, vp.x, 180)`，和 M2 之前
##    **逐像素一致**（`PANEL_H` 保留成「面板顶边的默认位置」就是为了这个）。
##    `tests/Hud.gd` 钉死了这条，`tests/Touch.gd` 的 74 条断言也间接依赖它。
func _panel_rect(vp: Vector2) -> Rect2:
	return HudLayout.panel_rect(vp)

## 某个模块的矩形 + 缩放。模块被隐藏时返回空矩形。
func _mod_rect(m: String, vp: Vector2) -> Rect2:
	if not HudLayout.visible_of(m):
		return Rect2()
	var ws: Vector2 = world.world_size if world != null else Vector2.ZERO
	return HudLayout.rect(m, vp, ws)

func _mod_scale(m: String) -> float:
	return HudLayout.scale_of(m)

## 指令区模块的右边界。**所有右对齐的 HUD 内容都从这里取**，
## 不再写 `vp.x - 12.0` —— 玩家把指令区拖走后，右对齐的内容要跟着走。
func _cmd_right(vp: Vector2) -> float:
	var cr := _mod_rect("cmd", vp)
	return cr.end.x if cr.size.x > 0.0 else vp.x - 12.0

## 指令区模块的顶边（也就是那一行按钮的 y）。
func _cmd_top(vp: Vector2) -> float:
	var cr := _mod_rect("cmd", vp)
	return cr.position.y if cr.size.y > 0.0 else vp.y - PANEL_H + 51.0

## 指令区模块的缩放。按钮尺寸都要乘它。
func _cmd_scale() -> float:
	return HudLayout.scale_of("cmd")

func _draw_panel(vp: Vector2) -> void:
	var pr := _panel_rect(vp)
	# 底板只在有「底行模块」时才画。玩家把三个模块全拖到上面去的话，
	# 底部不该还留着一条空横条。
	if pr.size.y > 0.0:
		draw_rect(pr, Color(0.043, 0.058, 0.094, 0.96))
		draw_line(Vector2(0, pr.position.y), Vector2(vp.x, pr.position.y),
			Color(1, 1, 1, 0.10), 1.5)
	# 浮在底板之外的模块要自带底板，否则一片透明、字看不清。
	# ⚠️ 默认布局下三个模块都在底板上，这里一条都不会画 —— 默认观感不变。
	for m in ["info", "queue", "cmd"]:
		if not HudLayout.visible_of(m):
			continue
		var mr := _mod_rect(m, vp)
		if pr.size.y > 0.0 and pr.encloses(mr):
			continue
		draw_rect(mr.grow(6.0), Color(0.043, 0.058, 0.094, 0.94))
		draw_rect(mr.grow(6.0), Color(1, 1, 1, 0.10), false, 1.0)

	# ---- 选中信息行（独立成行，不再和按钮抢位置）----
	# 两行：
	#   第一行 = 「选了什么、还剩多少血」—— 随时在变
	#   第二行 = 「这东西是干什么的」  —— 来自 GameData 的 desc，恒定不变
	# 触屏没有鼠标悬浮，介绍必须常驻，否则玩家永远看不到它。
	var info := "未选择单位 · 轻点单位或框选部队开始指挥"
	var desc := ""
	var info_col := Color(0.62, 0.68, 0.80)
	if world.selected_building != null:
		var sb: Building = world.selected_building
		if sb.complete:
			if sb.is_combat():
				# 防御建筑：把火力写出来。
				# 选中一座塔却看不到它打多远、打多疼，玩家没法判断该把它放在哪；
				# 「轻点空地设置集结点」对塔也没有意义。
				info = "%s · 生命 %d/%d · 攻击 %d · 射程 %d" % [
					String(sb.data.get("name", "")), int(sb.hp), int(sb.max_hp),
					int(sb.attack_damage()), int(sb.attack_range())]
			else:
				info = "%s · 生命 %d/%d · 轻点空地设置集结点" % [
					String(sb.data.get("name", "")), int(sb.hp), int(sb.max_hp)]
		else:
			info = "%s · 建造中 %d%% · 生命 %d/%d" % [
				String(sb.data.get("name", "")), int(sb.progress_ratio() * 100.0),
				int(sb.hp), int(sb.max_hp)]
		desc = String(sb.data.get("desc", ""))
		info_col = Color(0.88, 0.92, 1.0)
	elif not world.selection.is_empty():
		var counts := {}
		for u in world.selection:
			var n := String(u.data.get("name", ""))
			counts[n] = counts.get(n, 0) + 1
		var parts := []
		for k in counts:
			parts.append(k + (" ×%d" % counts[k] if counts[k] > 1 else ""))
		info = "已选 %d 个单位 · %s" % [world.selection.size(), ", ".join(parts)]
		info_col = Color(0.88, 0.92, 1.0)
		desc = _selection_desc()
	# ---- 信息行模块（两行文字 + 分隔线）----
	if HudLayout.visible_of("info"):
		var ir := _mod_rect("info", vp)
		var isc := _mod_scale("info")
		var iy := ir.position.y
		draw_string(font, Vector2(ir.position.x + 16.0 * isc, iy + 20.0 * isc), info,
			HORIZONTAL_ALIGNMENT_LEFT, ir.size.x - 32.0 * isc, 13.5 * isc, info_col)
		if desc != "":
			draw_string(font, Vector2(ir.position.x + 16.0 * isc, iy + 37.0 * isc), desc,
				HORIZONTAL_ALIGNMENT_LEFT, ir.size.x - 32.0 * isc, 12.5 * isc,
				Color(0.60, 0.70, 0.84))
		draw_line(Vector2(ir.position.x + 12.0 * isc, iy + 45.0 * isc),
			Vector2(ir.end.x - 12.0 * isc, iy + 45.0 * isc), Color(1, 1, 1, 0.07), 1.0)

	# ---- 编队 + 快捷行模块（低频操作，让开右手拇指区）----
	# 快捷行在模块内部下移 52 —— 和 M2 之前 `py+51 / py+103` 的间距一致。
	if HudLayout.visible_of("queue"):
		var qr := _mod_rect("queue", vp)
		var qsc := _mod_scale("queue")
		_draw_group_row(qr, qsc)
		_draw_quick_row(Rect2(qr.position.x, qr.position.y + 52.0 * qsc,
			qr.size.x, qr.size.y), qsc)

	# ---- 指令区模块（右对齐，高频操作集中在右下角）----
	if HudLayout.visible_of("cmd"):
		var cy := _cmd_top(vp)
		if world.selected_building != null:
			_draw_building_panel(vp, cy)
		elif not world.selection.is_empty():
			_draw_unit_panel(vp, cy)
		else:
			_draw_hint(vp, cy)

	# ---- 建造菜单：从右下角就地向上展开 ----
	# 它画在面板**外面**（浮在战场上），但已经登记进 _ui_hits，所以点得到。
	if _build_menu_open:
		_draw_build_menu(vp)
		_draw_build_info(vp)

## 选中部队的介绍文案。混编时给「数量最多的那一种」——
## 一句话说不清混编部队，而玩家最关心的一般是里面的主力。
func _selection_desc() -> String:
	var counts := {}
	var best := ""
	var best_n := 0
	for u in world.selection:
		var t := String(u.type_id)
		var c: int = int(counts.get(t, 0)) + 1
		counts[t] = c
		if c > best_n:
			best_n = c
			best = t
	return String(GameData.get_unit(best).get("desc", ""))

## 快捷按钮行。属于 `queue` 模块，放模块左侧 ——
## 右下角要留给建造/训练这类高频操作。
func _draw_quick_row(org: Rect2, sc: float) -> void:
	var quick := [
		{"k": "停止", "w": 78.0, "act": "stop"},
		{"k": "全选", "w": 78.0, "act": "all"},
		{"k": "回基地", "w": 88.0, "act": "home"},
		{"k": ("拖动:平移" if _single_drag_pans else "拖动:框选"), "w": 96.0, "act": "dragmode"},
	]
	var x := org.position.x + 12.0 * sc
	for q in quick:
		var r := Rect2(x, org.position.y, float(q["w"]) * sc, BTN_GROUP_H * sc)
		draw_rect(r, Color(1, 1, 1, 0.07), true)
		draw_rect(r, Color(1, 1, 1, 0.14), false, 1.0)
		_draw_text_center(String(q["k"]), r, 13.0 * sc, Color(0.82, 0.86, 0.94))
		_ui_hit(r, String(q["act"]))
		x += (float(q["w"]) + 6.0) * sc

## 选中单位时的指令区（右列，右对齐）。
## 「建造」放在最右 —— 那是右手拇指最容易够到的位置，也是最高频的按钮。
func _draw_unit_panel(vp: Vector2, y: float) -> void:
	var items: Array = [{"label": "建造", "act": "build", "active": _build_menu_open}]
	var has_worker := false
	for u in world.selection:
		if u.can_harvest():
			has_worker = true
			break
	if has_worker:
		items.append({"label": "采矿", "act": "harvest", "active": false})
	items.append({"label": "攻击移动", "act": "amove", "active": _attack_move_mode})
	items.append({"label": "全选同类", "act": "sametype", "active": false})

	# 从右往左排：以后新增按钮不会把已有按钮挤走
	var csc := _cmd_scale()
	var x := _cmd_right(vp)
	for it in items:
		var r := Rect2(x - BTN_CMD_W * csc, y, BTN_CMD_W * csc, BTN_CMD_H * csc)
		_add_cmd_button(r, String(it["label"]), bool(it["active"]), String(it["act"]))
		x -= (BTN_CMD_W + 8.0) * csc

	# 技能按钮接在指令区左侧（离拇指最远）—— 技能是低频操作，
	# 但需要一眼看清「现在能不能按」，所以放在视线容易扫到的位置而不是最右。
	# 只在选中部队里真有单位带这个技能时才出现：纯农民部队不该看到「兴奋剂」。
	for aid in _selection_abilities():
		var users := []
		for su in world.selection:
			if (su.abilities() as Array).has(aid):
				users.append(su)
		var ar := Rect2(x - BTN_CMD_W * csc, y, BTN_CMD_W * csc, BTN_CMD_H * csc)
		_add_ability_button(ar, aid, users)
		x -= (BTN_CMD_W + 8.0) * csc

	# 单位头像：贴着指令区左侧。
	# 屏幕窄的时候优先丢掉头像 —— 它是装饰，技能键和指令键才是功能。
	# 一个满配选择（4 个指令键 + 3 个技能键 + 4 个头像）要占约 744px，
	# 在 800px 宽的窗口里就会压到小地图上。
	var ux := x - 6.0
	var safe_left: float = _minimap_rect.end.x + 6.0 if _minimap_rect.size.x > 0.0 else 0.0
	for i in range(mini(world.selection.size(), 4)):
		if ux - 34.0 * csc < safe_left:
			break
		var u: Unit = world.selection[i]
		var sr := Rect2(ux - 34.0 * csc, y + float(i % 2) * 30.0 * csc, 32.0 * csc, 28.0 * csc)
		var col: Color = GameData.FACTIONS[u.faction]["color"]
		draw_rect(sr, col.darkened(0.55), true)
		draw_rect(sr, Color(1, 1, 1, 0.16), false, 1.0)
		draw_circle(sr.get_center(), 7.0 * csc, col)
		ux -= 36.0 * csc

## 选中部队里出现的技能（去重）。遍历 GameData 的两张技能表保证按钮顺序稳定，
## 不会因为选中顺序变化而跳来跳去。
##
## ⚠️ **必须同时遍历 ABILITIES 和 SPELLS** —— 只遍历 ABILITIES 的话，
##    圣堂武士/蝎子/科学球被选中时技能键**一个都不出现**，
##    玩家只能看到「这个兵什么都不会」，而且不报错。
##    这是「数据层对了、界面没画」那类 bug 的又一例。
func _selection_abilities() -> Array:
	var out := []
	for aid in GameData.ABILITIES:
		for u in world.selection:
			if (u.abilities() as Array).has(aid):
				out.append(aid)
				break
	for aid in GameData.SPELLS:
		for u in world.selection:
			if (u.abilities() as Array).has(aid):
				out.append(aid)
				break
	return out

## 技能按钮。和普通指令按钮的区别是它必须把「为什么不能用」写在脸上 ——
## 触屏没有悬浮提示，状态不画出来玩家就只能靠猜。
func _add_ability_button(r: Rect2, aid: String, users: Array) -> void:
	# ⚠️ `get_skill` 而不是 `get_ability`：后者对法术返回空字典，
	#    于是法术按钮会画成一个**没有名字**的灰块（`ab.get("name", aid)`
	#    拿到的是兜底 id，实际上连 id 都不会显示，因为 `name` 字段读不到）。
	var ab := GameData.get_skill(aid)
	var unlocked: bool = world.has_ability_unlock(_me(), aid)
	var ready := 0
	for u in users:
		if world.can_use_ability(u, aid):
			ready += 1
	var on := ready > 0
	# 瞄准中的那个技能键高亮，玩家才知道「现在在放它」。
	var aiming := _aim_spell == aid
	draw_rect(r, Color(0.62, 0.80, 1.0, 0.30) if aiming
		else (Color(0.56, 0.89, 0.42, 0.22) if on else Color(1, 1, 1, 0.06)), true)
	draw_rect(r, Color("9ad0ff") if aiming
		else (Color("8fe36b") if on else Color(1, 1, 1, 0.14)), false, 1.2 if not aiming else 2.0)
	_draw_text_center(String(ab.get("name", aid)),
		Rect2(r.position.x, r.position.y + 7.0, r.size.x, 16.0), 14.0,
		Color(0.94, 0.97, 1.0) if (on or aiming) else Color(0.62, 0.64, 0.70))

	var sub := ""
	var subc := Color(0.60, 0.66, 0.76)
	var active := 0
	for u in users:
		if u.has_buff(aid):
			active += 1
	# 法术按钮的第二行显示**能量**，不是「就绪 ×N」——
	# 能量是这个系统里唯一的资源，玩家必须一眼看到还剩多少。
	# 单位混编时取最低的那个（最保守的估计，不会误报「能放」）。
	if aiming:
		sub = "选落点…"
		subc = Color("9ad0ff")
	elif not unlocked:
		sub = "未解锁"
		subc = Color(0.66, 0.54, 0.48)
	elif GameData.is_spell(aid):
		var need := float(ab.get("energy", 0.0))
		var lowest := 9999.0
		for u in users:
			lowest = minf(lowest, u.energy)
		if lowest >= need:
			sub = "能量 %d" % int(lowest)
			subc = Color("8fe36b")
		else:
			sub = "能量 %d/%d" % [int(lowest), int(need)]
			subc = Color("ffd166")
	elif on:
		sub = "就绪 ×%d" % ready
		subc = Color("8fe36b")
	elif active > 0:
		# 增益还在生效（兴奋剂 15 秒内不能再扎）。这条必须画出来，
		# 否则玩家会以为按钮坏了 —— 明明是「已经在生效」而不是「按不动」。
		sub = "生效中 ×%d" % active
		subc = Color("5fd0ff")
	else:
		# 找出第一个单位的阻塞原因，直接写出来
		sub = "不可用"
		for u in users:
			if not u.alive():
				continue
			if u.mode_timer > 0.0:
				sub = "变形中"
			elif u.ability_cd > 0.0:
				sub = "冷却中"
			elif u.has_buff(aid):
				sub = "生效中"
			elif ab.has("energy") and u.energy < float(ab["energy"]):
				sub = "能量不足"
			break
		subc = Color("ffd166")
	_draw_text_center(sub, Rect2(r.position.x, r.position.y + 28.0, r.size.x, 14.0), 10.5, subc)
	_ui_hit(r, "ability", aid)

## 选中建筑时的训练区（右列，右对齐）。
## 条目带图标 —— 纯文字按钮既小又认不出是什么兵。
func _draw_building_panel(vp: Vector2, y: float) -> void:
	var b: Building = world.selected_building
	var csc := _cmd_scale()
	var right := _cmd_right(vp)
	if not b.complete:
		# 进度已经写进信息行了，这里只留一个「取消建造」。
		# 以前在这里另起一行画「建造中…」，那行字会正好压在左列的「编队」标签上。
		_add_cmd_button(Rect2(right - 130.0 * csc, y, 130.0 * csc, BTN_CMD_H * csc),
			"取消建造", false, "cancelbuild")
		return

	# 升级型建筑（工程湾 / 进化腔 / 熔炉）没有 trains，改画升级列表。
	# 这两类列表**永不共存**（带训练的兵营没有升级，有升级的科技楼不训练），
	# 所以不需要页签切换 —— 少一层交互，也少一块要维护的布局。
	var ups: Array = GameData.upgrades_for_building(b.type_id)
	if not ups.is_empty():
		_draw_upgrade_list(vp, b, ups, y)
		return

	var list: Array = b.trains()
	var n := list.size()
	# 整块右对齐、内部正序 —— 顺序稳定，又贴着右下角
	var total := (float(n) * (BTN_TRAIN_W + 8.0) - 8.0) * csc
	var x := right - total
	for i in range(n):
		var uid: String = list[i]
		var d := GameData.get_unit(uid)
		var tr := Rect2(x, y, BTN_TRAIN_W * csc, BTN_TRAIN_H * csc)
		var afford := world.can_afford(_me(), uid)
		draw_rect(tr, Color(1, 1, 1, 0.08) if afford else Color(0.5, 0.2, 0.2, 0.20), true)
		draw_rect(tr, Color(1, 1, 1, 0.14), false, 1.0)

		# 图标：直接复用已经烘焙好的单位贴图，零新增美术
		var tex: Texture2D = TEX.get("u_" + uid, null)
		if tex != null:
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			var isc := 36.0 * csc / maxf(tw, th)
			draw_texture_rect(tex, Rect2(Vector2(x + tr.size.x * 0.5, y + 23.0 * csc) - Vector2(tw, th) * 0.5 * isc,
				Vector2(tw, th) * isc), false, Color(1, 1, 1, 1.0 if afford else 0.40))
		else:
			draw_rect(Rect2(x + tr.size.x * 0.5 - 18.0 * csc, y + 5.0 * csc,
				36.0 * csc, 36.0 * csc), Color(0.4, 0.5, 0.65, 0.6), true)

		_draw_text_center(String(d.get("name", uid)),
			Rect2(x, y + 44.0 * csc, tr.size.x, 15.0 * csc), 12.5 * csc,
			Color(0.92, 0.95, 1.0) if afford else Color(0.72, 0.62, 0.62))
		var cost := "%d矿" % int(d.get("cost_m", 0))
		if int(d.get("cost_g", 0)) > 0:
			cost += " +%d气" % int(d.get("cost_g", 0))
		_draw_text_center(cost, Rect2(x, y + 58.0 * csc, tr.size.x, 13.0 * csc), 10.5 * csc,
			Color("ffd166") if afford else Color(0.60, 0.50, 0.45))
		_ui_hit(tr, "train", uid)
		x += (BTN_TRAIN_W + 8.0) * csc

	_draw_building_queue(vp, b, y)

## 升级型建筑的条目列表（工程湾 / 进化腔 / 熔炉）。
##
## 升级没有贴图可复用，所以图标位置画「等级圆点」—— 一眼看出升到几级了，
## 而且不需要新增任何美术资源。
func _draw_upgrade_list(vp: Vector2, b: Building, ups: Array, y: float) -> void:
	var right := vp.x - 12.0
	var n := ups.size()
	var usc := _cmd_scale()
	var w := 106.0 * usc
	var gap := 8.0 * usc
	var total := float(n) * (w + gap) - gap
	var x := right - total
	# 一个建筑同一时间只能做一件事 —— 队列非空时研究按钮全部置灰
	var busy := b.queue.size() > 0
	for i in range(n):
		var uid: String = ups[i]
		var up := GameData.get_upgrade(uid)
		var lv := world.upgrade_level(_me(), uid)
		var maxlv := int(up.get("max_level", 3))
		var cost := world.next_upgrade_cost(_me(), uid)
		var full := cost.is_empty()
		var afford := (not full) and world.can_afford(_me(), uid)
		var ok := afford and not busy

		var r := Rect2(x, y, w, BTN_TRAIN_H * usc)
		draw_rect(r, Color(0.56, 0.89, 0.42, 0.16) if ok else Color(1, 1, 1, 0.06), true)
		draw_rect(r, Color("8fe36b") if ok else Color(1, 1, 1, 0.14), false, 1.0)

		# 等级圆点：已升级的实心，未升级的空心
		var dr := 4.0 * usc
		var step := dr * 2.0 + 3.0 * usc
		var dw := float(maxlv) * step - 3.0 * usc
		var dx := r.position.x + (w - dw) * 0.5 + dr
		for k in range(maxlv):
			var dc := Vector2(dx + float(k) * step, y + 15.0 * usc)
			if k < lv:
				draw_circle(dc, dr, Color("8fe36b"))
			else:
				draw_arc(dc, dr, 0.0, TAU, 16, Color(1, 1, 1, 0.30), 1.2)

		_draw_text_center(String(up.get("name", uid)),
			Rect2(x, y + 25.0 * usc, w, 15.0 * usc), 12.5 * usc,
			Color(0.92, 0.95, 1.0) if ok else Color(0.74, 0.76, 0.82))

		var sub := ""
		var subc := Color("ffd166")
		if full:
			sub = "已满级"
			subc = Color("8fe36b")
		elif busy:
			sub = "建筑忙碌中"
			subc = Color(0.66, 0.68, 0.74)
		else:
			sub = "%d矿" % int(cost.get("cost_m", 0))
			if int(cost.get("cost_g", 0)) > 0:
				sub += "+%d气" % int(cost.get("cost_g", 0))
			if not afford:
				subc = Color(0.70, 0.52, 0.48)
		_draw_text_center(sub, Rect2(x, y + 42.0 * usc, w, 13.0 * usc), 10.5 * usc, subc)
		_draw_text_center(_upgrade_effect_label(up), Rect2(x, y + 57.0 * usc, w, 12.0 * usc), 10.0 * usc,
			Color(0.55, 0.62, 0.74))
		_ui_hit(r, "research", uid)
		x += w + gap

	_draw_building_queue(vp, b, y)

## 升级效果的一句话说明，让玩家不用去猜「步兵武器」到底加什么
func _upgrade_effect_label(up: Dictionary) -> String:
	match String(up.get("effect", "")):
		"attack": return "攻击 +1 / 级"
		"armor": return "护甲 +1 / 级"
		"shield_armor": return "护盾 +1 / 级"
		"unlock": return "解锁单位技能"
		_: return ""

## 生产 / 研究队列。训练条目和升级条目共用一条队列，点按取消并全额退款。
## 队列里的条目可能是单位也可能是升级，名字要分开查 ——
## 用 GameData.get_unit() 查升级会拿到空字典，显示成空白格子。
func _draw_building_queue(vp: Vector2, b: Building, y: float) -> void:
	if b.queue.is_empty():
		return
	var qsc := _cmd_scale()
	var right := _cmd_right(vp)
	var qy := y + (BTN_TRAIN_H + 8.0) * qsc
	var qw := float(b.queue.size()) * 26.0 * qsc
	var qx := right - qw
	draw_string(font, Vector2(qx - 76.0 * qsc, qy + 18.0 * qsc), "队列",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11.5 * qsc, Color(0.6, 0.68, 0.8))
	for i in range(b.queue.size()):
		var q: Dictionary = b.queue[i]
		var is_up := String(q.get("kind", "unit")) == "upgrade"
		var qr := Rect2(qx + float(i) * 26.0 * qsc, qy, 22.0 * qsc, 30.0 * qsc)
		draw_rect(qr, Color(0.5, 0.42, 0.15, 0.42) if is_up else Color(0.2, 0.5, 0.7, 0.35), true)
		draw_rect(qr, Color("ffd166") if is_up else Color("5fd0ff"), false, 1.0)
		var qn := ""
		if is_up:
			qn = String(GameData.get_upgrade(String(q["id"])).get("name", ""))
		else:
			qn = String(GameData.get_unit(String(q["type_id"])).get("name", ""))
		if qn.length() > 0:
			draw_string(font, Vector2(qr.position.x + 3.0 * qsc, qr.position.y + 18.0 * qsc),
				qn.substr(0, 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11.0 * qsc,
				Color(0.85, 0.93, 1.0))
		if i == 0:
			var pr2: float = 1.0 - clampf(float(q["time_left"]) / maxf(0.001, float(q["total"])), 0.0, 1.0)
			draw_rect(Rect2(qr.position + Vector2(0, qr.size.y - 3.0), Vector2(qr.size.x * pr2, 3.0)),
				Color("ffd166") if is_up else Color("8fe36b"))
		_ui_hit(qr, "queue", i)

## 没选中任何东西时的右列提示。
## M2：它填在「编队区右边缘 → 指令区左边界」之间的空白里 ——
## 两个模块各自被拖动时它都跟着调整，默认布局下与旧硬编码
## （`Vector2(400, ...)` + 宽 `vp.x - 420`）**逐像素相等**。
func _draw_hint(vp: Vector2, y: float) -> void:
	var qr := _mod_rect("queue", vp)
	var x0: float = qr.end.x - 10.0 if qr.size.x > 0.0 else 400.0
	var w: float = maxf(120.0, _cmd_right(vp) - 8.0 - x0)
	var lines := [
		"单指滑动 = 移动视角 · 长按后拖动 = 框选部队",
		"双指拖动 = 移镜 · 双指捏合 = 缩放 · 双击 = 全选同类",
		"选中农民后点「建造」，拖动幽灵到位置再松手",
	]
	for i in range(lines.size()):
		draw_string(font, Vector2(x0, y + 22 + i * 22), lines[i],
			HORIZONTAL_ALIGNMENT_LEFT, w, 12.5, Color(0.55, 0.62, 0.74))

func _add_cmd_button(r: Rect2, label: String, active: bool, act: String) -> void:
	draw_rect(r, Color(0.56, 0.89, 0.42, 0.22) if active else Color(1, 1, 1, 0.08), true)
	draw_rect(r, Color("8fe36b") if active else Color(1, 1, 1, 0.16), false, 1.2)
	_draw_text_center(label, r, 15.0, Color(0.92, 0.95, 1.0))
	_ui_hit(r, act)

## 计算建造菜单的布局（纯函数，不绘制）。
## 抽出来是为了让测试能在无头环境下验证「菜单条目落在哪、能不能被点到」，
## 不必真的跑一次 _draw()。
func build_menu_layout(vp: Vector2) -> Dictionary:
	var built := {}
	for b in world.buildings_of(_me()):
		built[b.type_id] = true
	var unlocked := GameData.available_buildings(race, built)
	var cols := 4
	var gap := 6.0
	var pad := 8.0
	var all: Array = []
	for entry in GameData.BUILD_MENU[race]:
		all.append(entry["id"])
	var rows := int(ceil(float(all.size()) / float(cols)))
	var menu_w := float(cols) * (BTN_BUILD_W + gap) - gap + pad * 2.0
	var menu_h := float(rows) * (BTN_BUILD_H + gap) - gap + pad * 2.0
	# 右边缘贴**指令区模块**的右边界，底边贴**面板顶边** —— 也就是「从右下角长出来」。
	# M2：两个基准都改成从模块取，默认布局与旧公式
	# `(vp.x - 12 - menu_w, vp.y - PANEL_H - 8 - menu_h)` **逐像素相等**。
	var base_y: float = _panel_rect(vp).position.y
	if base_y <= 0.0:
		base_y = _cmd_top(vp)
	var oy := base_y - 8.0 - menu_h
	if oy < TOP_H + 10.0:
		# 上方放不下（指令区被拖到屏幕上半部）就翻到下方展开，否则菜单会顶出屏幕
		oy = base_y + 8.0
	var origin := Rect2(_cmd_right(vp) - menu_w, oy, menu_w, menu_h)
	var items := []
	for i in range(all.size()):
		var bid: String = all[i]
		var c := i % cols
		var rw := i / cols
		items.append({
			"id": bid,
			"locked": not unlocked.has(bid),
			"rect": Rect2(origin.position.x + pad + float(c) * (BTN_BUILD_W + gap),
				origin.position.y + pad + float(rw) * (BTN_BUILD_H + gap),
				BTN_BUILD_W, BTN_BUILD_H),
		})
	return {"origin": origin, "items": items}

## 建造菜单。从**右下角就地向上展开**，不再是一个漂在面板外的孤儿浮层。
## 它虽然画在面板上方（战场区），但登记进了 _ui_hits，所以照样点得到。
## 条目做成「图标 + 名称 + 造价」的大按钮 —— 纯文字的小按钮在手机上认不出也点不准。
func _draw_build_menu(vp: Vector2) -> void:
	var layout := build_menu_layout(vp)
	var origin: Rect2 = layout["origin"]
	draw_rect(origin, Color(0.06, 0.08, 0.13, 0.98), true)
	draw_rect(origin, Color(1, 1, 1, 0.16), false, 1.2)

	for it in layout["items"]:
		var bid: String = String(it["id"])
		var r: Rect2 = it["rect"]
		var locked: bool = bool(it["locked"])
		var d := GameData.get_building(bid)
		var afford := world.can_afford(_me(), bid)
		var bg := Color(1, 1, 1, 0.08)
		if locked:
			bg = Color(0.25, 0.25, 0.30, 0.35)
		elif not afford:
			bg = Color(0.5, 0.2, 0.2, 0.22)
		draw_rect(r, bg, true)
		draw_rect(r, Color(1, 1, 1, 0.16) if not locked else Color(1, 1, 1, 0.06), false, 1.0)

		# 图标直接用已经烘焙好的建筑贴图 —— 零新增美术资源
		var icon_c := Vector2(r.position.x + BTN_BUILD_W * 0.5, r.position.y + 28.0)
		var tex: Texture2D = TEX.get("b_" + bid, null)
		if tex != null:
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			var sc := 44.0 / maxf(tw, th)
			draw_texture_rect(tex, Rect2(icon_c - Vector2(tw, th) * 0.5 * sc, Vector2(tw, th) * sc),
				false, Color(1, 1, 1, 0.42 if locked else 1.0))
		else:
			draw_rect(Rect2(icon_c - Vector2(22.0, 22.0), Vector2(44.0, 44.0)),
				Color(0.4, 0.5, 0.65, 0.6), true)

		var tc := Color(0.92, 0.95, 1.0) if (not locked and afford) else Color(0.62, 0.62, 0.68)
		_draw_text_center(String(d.get("name", bid)),
			Rect2(r.position.x, r.position.y + 52.0, BTN_BUILD_W, 16.0), 12.5, tc)
		if locked:
			var req := String(d.get("requires", ""))
			_draw_text_center("需 " + String(GameData.get_building(req).get("name", "前置")),
				Rect2(r.position.x, r.position.y + 67.0, BTN_BUILD_W, 14.0), 10.5, Color(0.72, 0.55, 0.5))
		else:
			var cost := "%d矿" % int(d.get("cost_m", 0))
			if int(d.get("cost_g", 0)) > 0:
				cost += " +%d气" % int(d.get("cost_g", 0))
			_draw_text_center(cost, Rect2(r.position.x, r.position.y + 67.0, BTN_BUILD_W, 14.0), 10.5,
				Color("ffd166") if afford else Color(0.55, 0.50, 0.48))
			_ui_hit(r, "pick_build", bid)

## 介绍卡的落位（纯函数，抽出来让无头测试能验证「卡片不会跑出屏幕」）。
## 默认贴在建造菜单左侧；放不下就往右挪，并夹在顶栏与面板之间。
func build_info_layout(vp: Vector2) -> Rect2:
	var origin: Rect2 = build_menu_layout(vp)["origin"]
	var w := 330.0
	var h := 178.0
	var x: float = origin.position.x - 10.0 - w
	if x < 10.0:
		x = 10.0
	if x + w > vp.x - 10.0:
		x = vp.x - 10.0 - w
	var pr := _panel_rect(vp)
	var bot: float = (pr.position.y if pr.size.y > 0.0 else _cmd_top(vp)) - 10.0
	var y: float = clampf(origin.position.y + origin.size.y - h,
		TOP_H + 10.0, maxf(TOP_H + 10.0, bot - h))
	return Rect2(x, y, w, h)

## 建造条目的介绍卡：在建造菜单里**长按**任意条目 0.35 秒弹出。
## 卡片是模态的 —— 点屏幕任意处关掉（见 _on_touch 里第 0.5 步）。
## 内容是「这建筑干什么用」+ 造价 / 生命 / 前置，全部读 GameData，没有硬编码数值。
##
## 为什么不用悬浮提示：触屏没有鼠标，没有「划过去看一眼」这回事。
func _draw_build_info(vp: Vector2) -> void:
	if _build_info_id == "":
		return
	var d := GameData.get_building(_build_info_id)
	if d.is_empty():
		return
	var r := build_info_layout(vp)
	draw_rect(r, Color(0.055, 0.075, 0.125, 0.98), true)
	draw_rect(r, Color("8fd0ff"), false, 1.4)

	draw_string(font, Vector2(r.position.x + 14.0, r.position.y + 26.0),
		String(d.get("name", _build_info_id)), HORIZONTAL_ALIGNMENT_LEFT, -1, 17.0,
		Color(0.92, 0.96, 1.0))
	draw_string(font, Vector2(r.position.x + 14.0, r.position.y + 26.0),
		"建造 %.0f 秒" % float(d.get("build_time", 0.0)),
		HORIZONTAL_ALIGNMENT_RIGHT, r.size.x - 28.0, 12.0, Color("ffd166"))
	draw_line(Vector2(r.position.x + 12.0, r.position.y + 34.0),
		Vector2(r.end.x - 12.0, r.position.y + 34.0), Color(1, 1, 1, 0.10), 1.0)

	_wrap_text(String(d.get("desc", "—")), Vector2(r.position.x + 14.0, r.position.y + 54.0),
		r.size.x - 28.0, 12.5, Color(0.72, 0.82, 0.94), 17.0, 2)

	var rows: Array = []
	var cost := "%d 矿" % int(d.get("cost_m", 0))
	if int(d.get("cost_g", 0)) > 0:
		cost += "   %d 气" % int(d.get("cost_g", 0))
	rows.append(["造价", cost, Color("ffd166")])
	rows.append(["生命", "%d  ·  护甲 %d" % [int(d.get("hp", 0)), int(d.get("armor", 0))],
		Color(0.85, 0.90, 0.98)])
	var req := String(d.get("requires", ""))
	rows.append(["前置", String(GameData.get_building(req).get("name", "无")) if req != "" else "无",
		Color(0.85, 0.90, 0.98)])
	if bool(d.get("gas_building", false)):
		rows.append(["注意", "必须建在瓦斯矿上", Color("ff9b7b")])

	var ry := r.position.y + 96.0
	for row in rows:
		draw_string(font, Vector2(r.position.x + 14.0, ry), String(row[0]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12.0, Color(0.55, 0.62, 0.74))
		draw_string(font, Vector2(r.position.x + 62.0, ry), String(row[1]),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 76.0, 12.5, row[2])
		ry += 19.0

	draw_string(font, Vector2(r.position.x + 14.0, r.end.y - 10.0),
		"点任意处关闭 · 轻点条目开始放置",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11.0, Color(0.50, 0.58, 0.70))

func _draw_topbar(vp: Vector2) -> void:
	# M2：底板高度由 `res` / `sysbtns` 两个顶行模块推导（默认 = 旧 `TOP_H` 通栏）。
	var tb := HudLayout.topbar_rect(vp)
	if tb.size.y > 0.0:
		draw_rect(tb, Color(0.043, 0.058, 0.094, 0.92))
		draw_line(Vector2(0, tb.end.y), Vector2(vp.x, tb.end.y), Color(1, 1, 1, 0.09), 1.0)
	var f: Dictionary = world.factions[_me()]
	var used := int(f["supply_used"])
	var cap := int(f["supply_cap"])
	# M2：资源栏内容跟着 `res` 模块走 —— 拖动资源栏时整组文字一起移动。
	# ⚠️ 计时与敌基地数**借** res 模块的坐标，但**不受它的 visible 开关影响**：
	#    它们是战斗关键信息，玩家只想关掉矿物数字时不该连计时一起消失。
	var rr := HudLayout.rect("res", vp)
	if rr.size.x > 0.0:
		var rx := rr.position.x
		var ry := rr.position.y
		if HudLayout.visible_of("res"):
			draw_string(font, Vector2(rx + 12.0, ry + 23.0),
				"矿物 %d    瓦斯 %d    人口 %d/%d" % [int(f["minerals"]), int(f["gas"]), used, cap],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13.5, Color(0.9, 0.94, 1.0))
			if used >= cap - 1:
				draw_string(font, Vector2(rx + 310.0, ry + 23.0), "人口已满",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13.5, Color("ff8a7a"))
		var mn := int(world.elapsed) / 60
		var sec := int(world.elapsed) % 60
		# 计时与敌基地数挪到**正中**：右上角让给暂停 / 速度 / 说明 / 音效四个按钮。
		# 挤在右边的话，手机上这四个键会互相压住 —— 而顶栏是唯一放得下它们的地方。
		draw_string(font, Vector2(rx + vp.x * 0.5 - 70.0, ry + 23.0), "%02d:%02d" % [mn, sec],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13.5, Color(0.7, 0.78, 0.9))
		draw_string(font, Vector2(rx + vp.x * 0.5 + 10.0, ry + 23.0),
			"敌基地 %d" % world.buildings_of(_foe()).size(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0, Color("ff9b8a"))

	# 暂停 / 速度 / 帮助 / 音效 放顶栏 —— 面板的每一寸都留给高频操作。
	# 坐标来自纯函数 topbar_button_rects()，绘制与命中同源。
	# 系统按钮模块被隐藏时它返回空字典 —— 这里整段跳过，不留点不到的鬼影按钮。
	# 局域网对局中多出来的一行：聊天 / 投降（见 `lan_button_rects()`）。
	# ⚠️ 画在 `btns.is_empty()` 的早退**之前** —— 排在后面的话，
	#    玩家一旦在设置里把「系统按钮」模块关掉，聊天和投降就再也点不到了，
	#    而且画面上看不出少了什么（那两个键本来就在另一行）。
	var lbtns := lan_button_rects(vp)
	if not lbtns.is_empty():
		var cr: Rect2 = lbtns["chat"]
		draw_rect(cr, Color(1, 1, 1, 0.07), true)
		draw_rect(cr, Color("8fd0ff"), false, 1.0)
		_draw_text_center("聊天", cr, 12.0, Color("8fd0ff"))
		_ui_hit(cr, "chat")

		var ur: Rect2 = lbtns["surrender"]
		draw_rect(ur, Color(0.75, 0.35, 0.30, 0.22), true)
		draw_rect(ur, Color("ff9a8f"), false, 1.0)
		_draw_text_center("投降", ur, 12.0, Color("ff9a8f"))
		_ui_hit(ur, "surrender")

	var btns := topbar_button_rects(vp)
	if btns.is_empty():
		return
	var pr: Rect2 = btns["pause"]
	var pause_on := _is_paused()
	draw_rect(pr, Color(0.95, 0.72, 0.30, 0.22) if pause_on else Color(1, 1, 1, 0.07), true)
	draw_rect(pr, Color("ffd166") if pause_on else Color(1, 1, 1, 0.14), false, 1.0)
	_draw_text_center("继续" if pause_on else "暂停", pr, 12.0,
		Color("ffd166") if pause_on else Color(0.82, 0.86, 0.94))
	_ui_hit(pr, "pause")

	var gr: Rect2 = btns["speed"]
	draw_rect(gr, Color(1, 1, 1, 0.07), true)
	draw_rect(gr, Color(1, 1, 1, 0.14), false, 1.0)
	_draw_text_center("速度 " + _speed_text(), gr, 12.0,
		Color("8fd0ff") if game_speed > 1.01 else Color(0.82, 0.86, 0.94))
	_ui_hit(gr, "speed")

	var hr: Rect2 = btns["help"]
	draw_rect(hr, Color(1, 1, 1, 0.07), true)
	draw_rect(hr, Color(1, 1, 1, 0.14), false, 1.0)
	_draw_text_center("操作说明", hr, 12.0, Color(0.82, 0.86, 0.94))
	_ui_hit(hr, "help")

	var sr: Rect2 = btns["sfx"]
	draw_rect(sr, Color(1, 1, 1, 0.07), true)
	draw_rect(sr, Color(1, 1, 1, 0.14), false, 1.0)
	_draw_text_center("音效" + ("开" if _sfx_on else "关"), sr, 12.0,
		Color("8fe36b") if _sfx_on else Color(0.60, 0.62, 0.68))
	_ui_hit(sr, "sfx")

## 聊天记录：从顶栏下方往下排，最多 `CHAT_LOG_MAX` 条。
##
## ⚠️ 每条都要**按可用宽度截断**。`draw_string` 不换行、不裁剪、**不报错** ——
##    一条 60 字的发言会把整行推出屏幕右侧，而画面上只是「字突然没了」。
func _draw_chat_log(vp: Vector2) -> void:
	if _chat_log.is_empty() or _lan_input_key != "":
		return
	var lh := 20.0
	var w := minf(360.0, vp.x * 0.42)
	var y := HudLayout.topbar_rect(vp).end.y + 40.0
	for e in _chat_log:
		var m: Dictionary = e
		var who := _safe_name(String(m["from"]), 8)
		var body := _safe_name(String(m["text"]), 22)
		var r := Rect2(12.0, y, w, lh - 2.0)
		draw_rect(r, Color(0.03, 0.05, 0.09, 0.62), true)
		draw_string(font, Vector2(r.position.x + 8.0, r.position.y + 14.0),
			"%s：%s" % [who, body],
			HORIZONTAL_ALIGNMENT_LEFT, w - 14.0, 12.5, Color(0.88, 0.92, 1.0))
		y += lh

func _draw_toasts(vp: Vector2) -> void:
	var y := 50.0
	for t in _toasts:
		var a: float = clampf(t["life"] / t["max"], 0.0, 1.0)
		var col: Color = t["color"]
		var w := font.get_string_size(t["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 13.5).x + 26.0
		var r := Rect2(vp.x * 0.5 - w * 0.5, y, w, 29.0)
		draw_rect(r, Color(0.04, 0.06, 0.11, 0.88 * a), true)
		draw_rect(r, Color(col.r, col.g, col.b, 0.65 * a), false, 1.0)
		_draw_text_center(t["text"], r, 13.5, Color(col.r, col.g, col.b, a))
		y += 33.0

func _draw_text_center(text: String, r: Rect2, size: float, col: Color) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font, Vector2(r.position.x + (r.size.x - w) * 0.5, r.position.y + r.size.y * 0.5 + size * 0.36),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

# ================================================================ 战场叠加层
func _draw_overlay(vp: Vector2) -> void:
	# 选中建筑时把集结点画出来（星际里选中建筑会显示集结点旗）
	if world.selected_building != null and world.selected_building.complete and world.selected_building.has_rally:
		var rb: Building = world.selected_building
		var a := _xf(rb.pos)
		var c := _xf(rb.rally)
		_dashed_line(a, c, Color(0.56, 0.89, 0.42, 0.45), 1.6 * cam_zoom)
		var tip := c - Vector2(0, 14.0 * cam_zoom)
		draw_line(c, tip, Color(0.56, 0.89, 0.42, 0.85), 1.6 * cam_zoom)
		draw_colored_polygon(PackedVector2Array([
			tip, tip + Vector2(11.0, 4.0) * cam_zoom, tip + Vector2(0.0, 8.0) * cam_zoom
		]), Color("8fe36b"))

	for i in range(_markers.size() - 1, -1, -1):
		var m: Dictionary = _markers[i]
		m["life"] -= get_process_delta_time()
		if m["life"] <= 0.0:
			_markers.remove_at(i)
			continue
		var t: float = m["life"] / m["max"]
		var sp := _xf(m["pos"])
		draw_arc(sp, (10.0 + (1.0 - t) * 22.0) * cam_zoom, 0.0, TAU, 20, Color(0.56, 0.89, 0.42, t * 0.85), 1.8 * cam_zoom)

	# 建造指派线：农民被派去工地、但还没走到时拉一条虚线。
	# 有了它，「已经有人在赶来的路上」和「工地卡住了」才分得清 ——
	# 前者有虚线，后者画的是红色的「等待建造者」。
	# 「到没到场」统一问 World.builder_arrived()：站位可能被地形吸附到几十像素外，
	# 渲染层自己按距离判会和逻辑层不一致（虚线永远不消失）。
	if cam_zoom > 0.45:
		for u in world.units_of(_me()):
			if u.build_target == null:
				continue
			var tb: Building = u.build_target
			if world.builder_arrived(tb, u):
				continue          # 已到场：头顶的进度环会说明一切，不必再拉线
			_dashed_line(_xf(u.pos), _xf(tb.pos), Color(0.56, 0.89, 0.42, 0.42), 1.5 * cam_zoom)

	if cam_zoom > 0.7:
		for u in world.selection:
			if u.path.size() > 1 and u.path_index < u.path.size():
				var pts := PackedVector2Array()
				pts.append(_xf(u.pos))
				for k in range(u.path_index, u.path.size()):
					pts.append(_xf(u.path[k]))
				if pts.size() > 1:
					draw_polyline(pts, Color(0.56, 0.89, 0.42, 0.16), 1.4 * cam_zoom)

	# 长按进入框选时的一次性反馈：扩散的圆环，提示「现在拖动就是框选」
	if _long_press_feedback > 0.0:
		var lt: float = 1.0 - _long_press_feedback / 0.35
		draw_arc(_sel_start, 18.0 + lt * 36.0, 0.0, TAU, 30,
			Color(0.56, 0.89, 0.42, (1.0 - lt) * 0.9), 2.0)

	if _sel_mode == Sel.BOX and _sel_rect.size.length() > 6.0:
		draw_rect(_sel_rect, Color(0.56, 0.89, 0.42, 0.10), true)
		draw_rect(_sel_rect, Color(0.56, 0.89, 0.42, 0.75), false, 1.4)

	if _placing_build != "":
		var gsz := float(GameData.get_building(_placing_build).get("size", 28.0)) * cam_zoom
		var gp := _xf(_ghost_pos)
		# 神族：先把能量场画出来，让玩家一眼看到「哪里能建」
		if String(world.factions[_me()]["race"]) == "protoss" and _placing_build != "nexus":
			for b in world.power_sources(_me()):
				draw_arc(_xf(b.pos), World.POWER_RADIUS * cam_zoom, 0.0, TAU, 64,
					Color(0.83, 0.69, 0.21, 0.34), 1.4)
		var ok: bool = world.can_place_building(_placing_build, _ghost_pos, _me())["ok"]
		var gc := Color(0.56, 0.89, 0.42, 0.40) if ok else Color(1.0, 0.35, 0.3, 0.40)
		draw_rect(Rect2(gp - Vector2(gsz, gsz) * 0.5, Vector2(gsz, gsz)), gc, true)
		draw_rect(Rect2(gp - Vector2(gsz, gsz) * 0.5, Vector2(gsz, gsz)), Color(gc.r, gc.g, gc.b, 0.95), false, 1.6)
		var near := false
		for b in world.buildings_of(_me()):
			if b.pos.distance_to(_ghost_pos) < 190.0:
				near = true
				break
		if not near:
			draw_arc(gp, 190.0 * cam_zoom, 0.0, TAU, 48, Color(1, 0.5, 0.4, 0.13), 1.0)
		var txt := "拖动放置 " + String(GameData.get_building(_placing_build).get("name", "")) + " · 松手确认 · 点「建造」取消"
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13.5).x + 28.0
		var r := Rect2(vp.x * 0.5 - w * 0.5, TOP_H + 8.0, w, 30.0)
		draw_rect(r, Color(0.05, 0.09, 0.14, 0.92), true)
		draw_rect(r, Color("5fd0ff"), false, 1.2)
		_draw_text_center(txt, r, 13.5, Color(0.85, 0.93, 1.0))

	# 法术瞄准态：预览圈 + 射程环 + 提示条。
	#
	# ⚠️ 预览圈画的**就是**施法半径 `SPELLS[x].radius` —— 和落地后的区域
	#    用同一个数。另写一个「好看一点」的预览半径，玩家会按预览圈去
	#    估范围，然后发现打不到边上的人。
	if _aim_spell != "":
		var asp := GameData.get_spell(_aim_spell)
		if not asp.is_empty():
			var ac := _xf(_aim_pos)
			var ar := float(asp.get("radius", 40.0)) * cam_zoom
			var is_swarm := String(asp.get("effect", "")) == "no_ranged"
			var tint := Color(0.42, 0.30, 0.52) if is_swarm else Color(0.62, 0.80, 1.0)
			# 射程环：**以施法者为中心**，让玩家一眼看出「这个落点够不够得着」。
			# 够不着就整体转成红色 —— 触屏上没有悬浮提示，颜色是唯一的手段。
			var reach := float(asp.get("cast_range", 0.0))
			var reachable := false
			for su in world.selection:
				if not world.can_use_ability(su, _aim_spell):
					continue
				draw_arc(_xf(su.pos), reach * cam_zoom, 0.0, TAU, 72,
					Color(tint.r, tint.g, tint.b, 0.22), 1.2)
				if su.pos.distance_to(_aim_pos) <= reach:
					reachable = true
			if not reachable:
				tint = Color(1.0, 0.42, 0.36)
			draw_circle(ac, ar, Color(tint.r, tint.g, tint.b, 0.26))
			draw_arc(ac, ar, 0.0, TAU, 56, Color(tint.r, tint.g, tint.b, 0.95), 2.2)
			# 十字准星
			draw_line(ac - Vector2(ar * 0.28, 0), ac + Vector2(ar * 0.28, 0),
				Color(1, 1, 1, 0.55), 1.2)
			draw_line(ac - Vector2(0, ar * 0.28), ac + Vector2(0, ar * 0.28),
				Color(1, 1, 1, 0.55), 1.2)
			var nm := String(asp.get("name", _aim_spell))
			var hint := "拖动选择落点 · 松手施放 %s · 点技能键取消" % nm
			if not reachable:
				hint = "超出施法距离 · 靠近一点再放"
			var hw := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 13.5).x + 28.0
			var hr := Rect2(vp.x * 0.5 - hw * 0.5, TOP_H + 8.0, hw, 30.0)
			draw_rect(hr, Color(0.05, 0.09, 0.14, 0.92), true)
			draw_rect(hr, tint, false, 1.2)
			_draw_text_center(hint, hr, 13.5, Color(0.85, 0.93, 1.0))

	# 双指手势提示环
	if _pinch_active and _touches.size() >= 2:
		var pts := _active_points()
		for i in range(mini(pts.size(), 2)):
			draw_arc(pts[i], 26.0, 0.0, TAU, 20, Color(0.56, 0.89, 0.42, 0.55), 1.6)
		if pts.size() >= 2:
			draw_line(pts[0], pts[1], Color(0.56, 0.89, 0.42, 0.35), 1.4)

## 虚线：分段绘制，避免依赖任何额外资源
func _dashed_line(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	var total := a.distance_to(b)
	if total < 1.0:
		return
	var dir := (b - a) / total
	var dash := 9.0
	var gap := 7.0
	var t := 0.0
	while t < total:
		var seg := minf(dash, total - t)
		draw_line(a + dir * t, a + dir * (t + seg), col, width)
		t += dash + gap

## 虚线矩形（建造工地的轮廓）
func _dashed_rect(r: Rect2, col: Color, width: float) -> void:
	_dashed_line(r.position, Vector2(r.end.x, r.position.y), col, width)
	_dashed_line(Vector2(r.end.x, r.position.y), r.end, col, width)
	_dashed_line(r.end, Vector2(r.position.x, r.end.y), col, width)
	_dashed_line(Vector2(r.position.x, r.end.y), r.position, col, width)

# ================================================================ 帮助
## 帮助面板的条目文案。
##
## ⚠️ 提成常量而不是写在 _draw_help 里：面板高度是按条目数算的，
##    文案和高度分居两处时，加一行就会把最后几行挤出面板 —— 而且不报错。
##    （旧版这里写着「加文案时必须同步」，那种注释等于没有约束。）
const HELP_LINES := [
	"轻点己方单位 → 选中；再点一次 → 全选同类",
	"单指滑动 → 移动视角；长按 0.25 秒后拖动 → 框选部队",
	"双击单位 → 全选同类；双击空地 → 全选屏幕内单位",
	"双指拖动 → 平移镜头；双指捏合 → 缩放视野",
	"小地图（左下）→ 轻点跳转，按住拖动 → 拖动镜头",
	"选中部队后：点地面移动，点敌人攻击，点矿采集",
	"「攻击移动」按钮 → 再点地面，部队边打边推进",
	"「建造」→ 右下角展开菜单 → 选建筑 → 拖动幽灵到位置 → 松手放置",
	"选中建筑后：右下角按钮训练单位，点空地设集结点",
	"「编队」1~6（左下）：长按 = 存下当前部队，点按 = 召回并归位镜头",
	"生产队列：点队列里的格子 → 取消该单位并全额退款",
	"面板左下「拖动:平移 / 框选」可切换单指拖动的手势语义",
	"选中部队后：指令区左侧出现技能键（兴奋剂 / 攻城模式 / 治疗）",
	"升级型建筑（工程湾 / 进化腔 / 熔炉）：点面板升级项研究，圆点 = 已升等级",
	"研究占用生产队列，同一建筑一次只做一件事；医疗兵自动治疗附近友军",
	"顶栏「暂停」冻结战场，「速度」在 1× / 1.5× / 2× 之间切换（只加快时间，不改数值）",
	"开局菜单可选地图：开阔平原 / 双坡道高地 / 中间河道",
	"高地加成：站上高地的部队视野与射程 +1 格，低地打高地有 30% 打空",
	"虫族建筑必须建在菌毯上；虫族地面单位站在菌毯上移速 +30%",
	"目标：摧毁敌方全部建筑",
]

## 帮助面板与音量滑块的几何。纯函数 —— 绘制、命中、测试读同一份。
func help_layout(vp: Vector2) -> Dictionary:
	var w := minf(600.0, vp.x - 60.0)
	# 62 起始偏移 + 23 行距 + 46 给滑块 + 58 给关闭按钮
	var h := 62.0 + 23.0 * float(HELP_LINES.size()) + 46.0 + 58.0
	var r := Rect2(vp.x * 0.5 - w * 0.5, vp.y * 0.5 - h * 0.5, w, h)
	var sy := r.position.y + 62.0 + 23.0 * float(HELP_LINES.size()) + 8.0
	var tx := r.position.x + 106.0
	var tw := w - 106.0 - 78.0
	return {
		"panel": r,
		"slider": Rect2(tx, sy - 4.0, tw, 20.0),
		"track_x": tx,
		"track_w": tw,
		"track_y": sy + 4.0,
	}

## 音量滑块的命中区与正在拖动它的手指 id。由 _draw_help 每帧写入 ——
## 绘制与命中读同一份坐标，缩放 / 分辨率变化时才不会漂移。
var _vol_slider_rect := Rect2()
var _vol_drag_id := -1

## 按 x 坐标反算音量（0.0~1.0）。
func _set_volume_from_x(x: float) -> void:
	if _vol_slider_rect.size.x <= 1.0:
		return
	var t: float = clampf((x - _vol_slider_rect.position.x) / _vol_slider_rect.size.x, 0.0, 1.0)
	# 下限给 0 而不是 0.05：滑到最左就是静音，这是玩家的直觉。
	# 单个音效内部的衰减仍在 _play_sfx 里做，这里只管总线音量。
	_sfx_volume = t
	if t > 0.0:
		_sfx_on = true      # 拖动滑块视为「我要听」，顺手把总开关打开

func _draw_help(vp: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, 0.62))
	var w := minf(600.0, vp.x - 60.0)
	# 几何全部来自 help_layout()，这里只负责画。
	var lay := help_layout(vp)
	var r: Rect2 = lay["panel"]
	var sl: Rect2 = lay["slider"]
	var tx: float = lay["track_x"]
	var tw: float = lay["track_w"]
	var sy: float = lay["track_y"] - 4.0
	_vol_slider_rect = sl
	draw_rect(r, Color(0.05, 0.07, 0.12, 0.98), true)
	draw_rect(r, Color(1, 1, 1, 0.16), false, 1.2)
	_draw_text_center("操作说明", Rect2(r.position.x, r.position.y + 12, r.size.x, 28), 17.0, Color(0.95, 0.97, 1.0))
	var y := r.position.y + 62.0
	for l in HELP_LINES:
		draw_circle(Vector2(r.position.x + 26, y - 4), 2.4, Color("8fe36b"))
		draw_string(font, Vector2(r.position.x + 38, y), l, HORIZONTAL_ALIGNMENT_LEFT, w - 60, 13.5, Color(0.80, 0.86, 0.95))
		y += 23.0

	# ---- 音量滑块 ----
	draw_string(font, Vector2(r.position.x + 26, sy + 6), "音效音量", HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0,
		Color(0.72, 0.78, 0.90))
	draw_rect(Rect2(tx, sy + 4.0, tw, 5.0), Color(1, 1, 1, 0.10), true)
	draw_rect(Rect2(tx, sy + 4.0, tw * _sfx_volume, 5.0), Color("8fd0ff"), true)
	var kx := tx + tw * _sfx_volume
	draw_circle(Vector2(kx, sy + 6.5), 9.0, Color("8fd0ff"))
	draw_circle(Vector2(kx, sy + 6.5), 9.0, Color(1, 1, 1, 0.65))
	draw_circle(Vector2(kx, sy + 6.5), 7.0, Color(0.10, 0.16, 0.24))
	_draw_text_center("%d%%" % int(round(_sfx_volume * 100.0)),
		Rect2(tx + tw + 8.0, sy - 6.0, 56.0, 24.0), 12.5, Color(0.85, 0.90, 0.98))

	_add_cmd_button(Rect2(r.position.x + w * 0.5 - 90.0, r.position.y + r.size.y - 48.0, 180.0, 36.0),
		"关 闭", false, "close_help")
# ---------------------------------------------------------------- 菜单交互
## 菜单的命中表不再是一份「绘制时填、命中时查」的成员变量 ——
## 第十二轮改成 `menu_hit_table(vp)` 纯函数（见「菜单页面」一节）。
## 理由是**无头测试**：测试里没有绘制，绘制时填的成员永远是空的，
## 于是「菜单点了没反应」这类回归根本测不出来。
var _btn_primary := Rect2()
var _menu_press_rect := Vector2.ZERO
## 正在拖动的设置滑块 key（空串 = 没在拖）。
## 和帮助页那个音量滑块**分开存** —— 帮助页是模态浮层，
## 共用一份状态的话，关掉帮助面板会把设置页的拖动一起清掉。
var _form_drag_key := ""

const _DIFF_LABEL := {"easy": "轻松", "normal": "标准", "hard": "困难"}
const _MAP_LABEL := {"open": "开阔平原", "plateau": "双坡道高地", "river": "中间河道"}

## 速度档位的显示文本。
##
## ⚠️ 刻意不用 `%.1g` —— Godot 的 String 格式化**不支持 `%g`**，会直接抛
##    「unsupported format character」并把整段文本吞掉（顶栏那一格变成空白）。
##    也不要用 `%s` 直接格式化 float：会印出 "1.5000000000000002"。
func _speed_text() -> String:
	if game_speed >= 1.75:
		return "2×"
	if game_speed >= 1.25:
		return "1.5×"
	return "1×"

## 当前速度对应的选项键。用「就近取整」而不是 `str(game_speed)` ——
## 后者在浮点误差下会得到 "1.5000000000000002" 这种匹配不上的键。
func _speed_key() -> String:
	if game_speed >= 1.75:
		return "2"
	if game_speed >= 1.25:
		return "1.5"
	return "1"

## 菜单按下。命中表来自 `menu_hit_table()` —— **纯函数**。
##
## ⚠️ 不能再用「绘制时填、命中时查」的成员变量：无头测试里没有绘制，
##    那样填出来的表永远是空的，「菜单点了没反应」这类回归就测不出来。
func _menu_press(pos: Vector2) -> void:
	var vp := get_viewport_rect().size
	# 屏幕键盘是**模态**的：打开时吞掉所有点击，底下的菜单项一律不响应。
	# 少了这个 return，点键盘的同时会把下面的「创建房间」也点掉。
	if _lan_input_key != "":
		for m in lan_keypad_rects(vp):
			var kr: Rect2 = m["rect"]
			if kr.has_point(pos):
				_lan_input_press(String(m["key"]))
				return
		return
	for m in menu_hit_table(vp):
		var r: Rect2 = m["rect"]
		if not r.has_point(pos):
			continue
		# 单人页的老格式 {group, value}：改的是**本局**的选项。
		#
		# ⚠️ 判据必须同时要求「有 group」**且「group 非空」**。
		#    只判 `has("group")` 的话，设置页那些 `choice` 也会命中这里
		#    （命中表统一带了 `group` 字段，值是空串），于是
		#    `_menu_choose("", ...)` 什么都不做 ——
		#    症状是「设置页所有互斥选项点了都没反应」，而**不报错**。
		if m.has("group") and String(m["group"]) != "":
			_menu_choose(String(m["group"]), String(m["value"]))
			return
		match String(m.get("kind", "button")):
			"choice":
				# 带非空 `group` 的（本局选项）已经在上面拦掉了，走到这里
				# 的必然是不带 group 的「持久化设置」。
				_setting_choose(String(m.get("key", "")), String(m["value"]))
			"toggle":
				_setting_toggle(String(m["key"]))
			"slider":
				_form_drag_key = String(m["key"])
				_setting_slider_from_x(String(m["key"]), r, pos.x)
			"text":
				_toast("文本输入随联机功能一起开放", Color("ffd166"))
			_:
				_menu_act(String(m.get("act", "")), r, pos)
		return
	_menu_press_rect = pos

## 设置项：互斥选项。写入后**立刻应用并保存**。
##
## 「立刻保存」是有意的：手机上玩家随时可能被电话或切后台打断，
## 攒着等一个「保存」按钮，等于默认会丢。
func _setting_choose(key: String, value: String) -> void:
	Settings.set_v(key, value)
	Settings.save_all()
	_apply_settings()
	_toast("已设置 · 即时保存", Color("8fe36b"))

func _setting_toggle(key: String) -> void:
	Settings.set_v(key, not Settings.flag(key, false))
	Settings.save_all()
	_apply_settings()
	_toast("已设置 · 即时保存", Color("8fe36b"))

## 滑块：按点击位置换算 0~1。轨道矩形由 `_slider_track()` 给出，绘制与命中同源。
##
## `commit = false` 用于拖动过程中 —— 拖动会触发几十次回调，
## 每次都写盘等于把设置文件当画板刷。松手时才落盘（见 `_menu_release`）。
func _setting_slider_from_x(key: String, row: Rect2, x: float, commit: bool = true) -> void:
	var tr := _slider_track(row)
	if tr.size.x <= 1.0:
		return
	var t: float = clampf((x - tr.position.x) / tr.size.x, 0.0, 1.0)
	Settings.set_v(key, t)
	if commit:
		Settings.save_all()
	_apply_settings()

## 菜单里拖动。目前只有设置页的滑块需要 ——
## 菜单若不处理拖动事件，滑块就只能「点」不能「拖」，
## 而「按住拖一下听音量变化」是玩家对滑块的默认预期。
func _menu_drag(pos: Vector2) -> void:
	if _form_drag_key == "":
		return
	for e in _form_layout(get_viewport_rect().size, _page_def(_page)):
		if String(e.get("key", "")) != _form_drag_key:
			continue
		_setting_slider_from_x(_form_drag_key, e["rect"], pos.x, false)
		return

func _settings_reset() -> void:
	Settings.reset_all()
	Settings.save_all()
	_apply_settings()
	_toast("已恢复默认设置", Color("ffd166"))

## 按钮类 act 的分发。`arg` 只有带参数的 act（如 `lan_room:<ip>`）会用。
func _menu_act(act: String, r: Rect2, pos: Vector2, arg: Variant = null) -> void:
	if act.begins_with("goto:"):
		_goto_page(act.substr(5))
		return
	# 设置页的分类 tab。切 tab 只改数据、不改页面 ——
	# 所以**不进页面栈**，否则连点几个 tab 后要按好几次「返回」才回得去。
	if act.begins_with("stab:"):
		_settings_tab = act.substr(5)
		return
	# 模组行。前缀带 id（`mod_toggle:<id>`），所以只能前缀匹配 ——
	# 写进 match 的话每装一个模组就要多一个分支。
	if act.begins_with("mod_toggle:"):
		_mods_toggle(act.substr(11))
		return
	if act.begins_with("mod_up:"):
		_mods_move(act.substr(7), -1)
		return
	if act.begins_with("mod_down:"):
		_mods_move(act.substr(9), 1)
		return
	match act:
		"back":
			_page_back()
		"start":
			# 保留「按下 + 抬起同一点才开局」的防误触语义
			_btn_primary = r
			_menu_press_rect = pos
		"settings_reset":
			_settings_reset()
		"hud_edit":
			_start_hud_edit()
		"lan_name":
			_lan_open_input("name")
		"lan_ip":
			_lan_open_input("ip")
		"lan_host":
			_lan_host()
		"lan_join":
			_lan_join()
		"lan_start":
			_lan_start()
		"lan_ready":
			_lan_toggle_ready()
		"lan_room":
			_lan_join_room(String(arg) if arg != null else "")
		"lan_scan":
			_open_lan_scan()
		"lan_scan_back":
			_stop_discovery()
			state = St.MENU
			_page = Page.LAN
			queue_redraw()
		"lan_scan_refresh":
			# 「重新搜索」= 关掉再开。只清列表的话，绑在同一份 socket 上
			# 还是会立刻把刚收到的房间填回来，看起来像没反应。
			_stop_discovery()
			_sync_discovery()
			_toast("正在重新搜索…", Color("8fd0ff"))
		"lan_leave":
			_lan_leave()
		"mods_page":
			# 只翻页，不重载。页数由 `_mods_page_def()` 夹取 ——
			# 这里不自己算，避免两处口径不一致（装了新模组页数就变了）。
			_mods_page += 1
		"mods_rescan":
			_mods_rescan()
		"mods_open_dir":
			_toast(_mods_dir_text(), Color("8fd0ff"))

# ---------------------------------------------------------------- 模组操作
#
# 三个动作（启停 / 排序 / 重扫）改完之后都要走 `_mods_apply()` ——
# **只改 `Mods.list` 是不够的**：真正生效的是 `Mods.apply_all()`，
# 它会把启用的模组合并进 `GameData` 的副本表、填 `GenTex.skin_overrides`。
# 漏掉这一步的症状是「开关点了、勾选框也变了，但游戏里数值没变」——
# 静默、且看起来完全正常。

## 应用模组改动。**只能在菜单里调** ——
## `Mods.apply_all()` 开头会 `GameData.reset_to_base()`，
## 而正在跑的对局里的单位是读着旧字典构造出来的，重置等于把
## 「同屏两个陆战队员一个 40 血一个 60 血」这种事变成现实。
func _mods_apply() -> void:
	Mods.save_state()
	var res := Mods.apply_all()
	# 皮肤模组换的是贴图，必须重建 —— 否则要重启才看得见新皮肤。
	_build_textures()
	var errs: Array = res["errors"]
	if not errs.is_empty():
		_toast(String(errs[0]), Color("ff9a8f"))
		return
	_toast("已应用 · 皮肤 %d 张 · 数值 %d 项" % [int(res["skins"]), int(res["fields"])],
		Color("8fe36b"))

func _mods_toggle(id: String) -> void:
	var m := Mods.get_mod(id)
	if m.is_empty():
		return
	Mods.set_enabled(id, not bool(m["enabled"]))
	_mods_apply()

func _mods_move(id: String, delta: int) -> void:
	if not Mods.move(id, delta):
		# 已经在顶 / 底了。**不报错也不提示** —— 排序按钮在两端
		# 点不动是符合预期的，弹个「已经是第一个了」反而更烦。
		return
	_mods_apply()

func _mods_rescan() -> void:
	Mods.scan()
	_mods_page = 0
	_mods_apply()

## 跳到某一页。用页面栈，返回时回到上一页而不是主菜单。
func _goto_page(name: String) -> void:
	var target := Page.HOME
	match name:
		"single": target = Page.SINGLE
		"lan": target = Page.LAN
		"settings": target = Page.SETTINGS
		"mods": target = Page.MODS
		_: target = Page.HOME
	if target == _page:
		return
	_page_stack.append(_page)
	_page = target

func _page_back() -> void:
	if _page_stack.is_empty():
		_page = Page.HOME
		return
	_page = int(_page_stack.pop_back())

func _menu_choose(group: String, value: String) -> void:
	match group:
		"race":
			race = value
			_toast(String(GameData.FACTIONS[race]["name"]), GameData.FACTIONS[race]["color"])
		"diff":
			difficulty = value
			_toast("难度：" + String(_DIFF_LABEL.get(value, value)), Color("8fe36b"))
		"map":
			map_preset = value
			_toast("地图：" + String(_MAP_LABEL.get(value, value)), Color("8fd0ff"))
		"speed":
			game_speed = float(value)
			_toast("游戏速度 " + _speed_text(), Color("8fd0ff"))

## 某个 group 当前选中的值，用来决定高亮。
func _menu_cur(group: String) -> String:
	match group:
		"race": return race
		"diff": return difficulty
		"map": return map_preset
		"speed": return _speed_key()
	return ""

## 菜单里**所有**选择项的矩形：3 张阵营卡 + 难度 / 地图 / 速度三行。
##
## 抽成纯函数的理由：`draw_*` 只能在 NOTIFICATION_DRAW 上下文里调用，
## 无头测试里调 `_draw_menu()` 只会报「不在绘制上下文」而拿不到任何坐标 ——
## 于是「菜单点了没反应」这类回归根本测不到。把坐标算在这里，
## 绘制、命中、测试三边读同一份数据。
func menu_option_rects(vp: Vector2) -> Array:
	var cw := 210.0
	var gap := 22.0
	var total := 3.0 * cw + 2.0 * gap
	var x0 := vp.x * 0.5 - total * 0.5
	var by := vp.y * 0.36
	var dy := by + 178.0
	var out := []
	# 阵营卡
	for i in range(3):
		var k: String = ["terran", "zerg", "protoss"][i]
		out.append({
			"rect": Rect2(x0 + float(i) * (cw + gap), by, cw, 150.0),
			"group": "race", "value": k,
			"label": String(GameData.FACTIONS[k]["name"]),
			"row_y": by,
		})
	# 三行同构的选项
	var rows := [
		{"group": "diff", "y": dy,
			"items": [["easy", "轻松"], ["normal", "标准"], ["hard", "困难"]]},
		{"group": "map", "y": dy + 50.0,
			"items": [["open", "开阔平原"], ["plateau", "双坡道高地"], ["river", "中间河道"]]},
		{"group": "speed", "y": dy + 100.0,
			"items": [["1", "1×"], ["1.5", "1.5×"], ["2", "2×"]]},
	]
	for row in rows:
		var x := x0 + 52.0
		for pair in row["items"]:
			out.append({
				"rect": Rect2(x, float(row["y"]), 92.0, 34.0),
				"group": String(row["group"]), "value": String(pair[0]),
				"label": String(pair[1]),
				"row_y": float(row["y"]),
			})
			x += 100.0
	return out

## 菜单各组的显示名，绘制时用来画行标签。
const _GROUP_LABEL := {"diff": "难度", "map": "地图", "speed": "速度"}

## 「开始战斗」按钮的矩形。同样是纯函数，理由见 menu_option_rects。
func menu_start_rect(vp: Vector2) -> Rect2:
	return Rect2(vp.x * 0.5 - 130.0, vp.y * 0.36 + 178.0 + 150.0, 260.0, 54.0)

## 顶栏右侧四个按钮（暂停 / 速度 / 说明 / 音效）的矩形。
## 纯函数 —— 理由同 menu_option_rects：无头测试调不了 _draw_topbar()。
##
## M2：位置由 `HudLayout` 的 `sysbtns` 模块决定（默认仍是右上角）。
## 从模块右边缘往左排、间距 6 —— 默认布局算出来与旧硬编码
## （`vp.x - 260 / 202 / 140 / 64`）**逐像素相等**。
## 模块被隐藏时返回**空字典**，调用方据此跳过绘制（否则会留下四个点不到的鬼影按钮）。
func topbar_button_rects(vp: Vector2) -> Dictionary:
	var sr := _mod_rect("sysbtns", vp)
	if sr.size.x <= 0.0:
		return {}
	var sc := _mod_scale("sysbtns")
	var y := sr.position.y + 4.0 * sc
	var x := sr.end.x
	var out := {}
	# 从右往左：音效 → 说明 → 速度 → 暂停（顺序与旧硬编码一致）
	for e in [["sfx", 56.0], ["help", 70.0], ["speed", 56.0], ["pause", 52.0]]:
		var w := float(e[1]) * sc
		out[String(e[0])] = Rect2(x - w, y, w, 26.0 * sc)
		x -= w + 6.0 * sc
	return out

## 局域网对局中多出来的两个键：聊天 / 投降。
##
## ⚠️ **不能塞进 `sysbtns` 模块** —— 那个模块的自然宽度（252px）正好被
##    原有的 4 个键占满（56+70+56+52 + 3×6 间隔 = 252），再往里加会把
##    「音效」挤出屏幕右边，而 `tests/Hud.gd` 是逐像素比对的。
##    所以另起一行、右对齐贴在顶栏下面。
##
## 绘制 / 命中 / 测试三边读同一份。不在局域网对局中时返回空字典。
func lan_button_rects(vp: Vector2) -> Dictionary:
	if not _lan_active():
		return {}
	var tb := HudLayout.topbar_rect(vp)
	var y := maxf(tb.end.y, 34.0) + 6.0
	var x := vp.x - 8.0
	var out := {}
	# 从右往左：聊天 → 投降
	for e in [["chat", 56.0], ["surrender", 64.0]]:
		var w := float(e[1])
		out[String(e[0])] = Rect2(x - w, y, w, 26.0)
		x -= w + 6.0
	return out

func _menu_release(pos: Vector2) -> void:
	# 键盘打开时不吃松手事件 —— 否则「在键盘上按一下再松手」
	# 会顺手把下面那个主按钮也触发一次。
	if _lan_input_key != "":
		return
	# 滑块松手 → 落盘。拖动过程只改内存（否则拖动几十帧就写盘几十次）。
	if _form_drag_key != "":
		Settings.save_all()
		_form_drag_key = ""
		return
	if _btn_primary.has_point(pos) and _menu_press_rect != Vector2.ZERO and _btn_primary.has_point(_menu_press_rect):
		start_game(race, difficulty, map_preset)

## 回到开局菜单。必须把世界与全部 UI 状态一起清掉 ——
## 少了 _selection_clear()，上一局的放置模式会飘进菜单（顶栏一直显示「拖动放置…」）。
## 页面也要重置回首页并清空栈，否则上一局前停留的设置页会「继承」到下一局之后。
func goto_menu() -> void:
	# 局域网会话必须**优雅关闭**（告诉对方「我走了」再销毁本地连接）。
	# 直接丢掉引用的话 ENet host 不会被销毁，对方要等自己的超时才知道。
	_close_session()
	_stop_discovery()
	state = St.MENU
	world = null
	_selection_clear()
	_page = Page.HOME
	_page_stack.clear()

## 直接跳到某一页（截图与测试用；会清空返回栈）。
func goto_page(p: int) -> void:
	_page_stack.clear()
	_page = p

## 当前页（测试与截图用）。
func current_page() -> int:
	return _page

func _end_press(pos: Vector2) -> void:
	if _btn_primary.has_point(pos):
		goto_menu()

func _selection_clear() -> void:
	_touches.clear()
	_pinch_active = false
	_sel_mode = Sel.NONE
	_sel_rect = Rect2()
	_minimap_id = -1
	_place_drag_id = -1
	_aim_drag_id = -1
	_aim_spell = ""
	_attack_move_mode = false
	_build_menu_open = false
	_placing_build = ""
	_show_help = false
	_markers.clear()
	_toasts.clear()
	_ui_press_id = -1
	_ui_press_hit = {}
	_form_drag_key = ""
	_group_press_idx = -1
	_build_press_id = ""
	_build_info_id = ""
	_ui_hits.clear()
	_sfx_last.clear()
	_sfx_frame_count = 0
	_sel_mode = Sel.NONE
	_sel_rect = Rect2()

# ================================================================ 菜单页面
#
# 第十二轮把单层菜单拆成五页（HOME / SINGLE / LAN / SETTINGS / MODS）。
# 核心是「页面描述 + 通用渲染器」：
#   一页 = 一份数据（sections[].items[]），渲染器按 kind 分派。
#   加一个设置项 = 加一行数据，不用动绘制也不用动命中。
#
# ⚠️ 坐标一律走 menu_hit_table()，绘制 / 命中 / 测试三边读同一份 ——
#    否则「画得出来但点不到」这类回归根本测不出来（draw_* 在无头环境里调不了）。

## 表单排版常量。调版只改这里，不用碰各个页面。
const FORM_W := 620.0
const FORM_PAD := 26.0
const FORM_ROW_H := 46.0
const FORM_SEC_H := 32.0
const FORM_TITLE_H := 78.0
const FORM_FOOT_H := 68.0
## 面板顶部的最小留白。
##
## ⚠️ 不能写成 `maxf(60.0, ...)`：标题基线在 60、副标题基线在 86，
##    面板一旦顶到 60，副标题就直接压在面板上边框上（局域网页内容多，
##    面板 550px 高，垂直居中算出来正是 y=85 —— 实测会压住）。
const FORM_HEAD_H := 104.0
## 菜单底部那行操作提示。提成常量是为了**只有一份** ——
## 内联在各页里的话，两处写法不一致就会叠成糊字。
const MENU_HINT := "触屏操作 · 单指滑动移动视角 · 长按后拖动框选部队 · 双指捏合缩放"
## 设置页分类 tab 行的高度（0 = 该页没有 tab）。
const FORM_TAB_H := 48.0
const FORM_LABEL_W := 176.0
const FORM_OPT_W := 96.0
const FORM_OPT_GAP := 8.0

## 星海背景。所有菜单页共用。
func _draw_menu_bg(vp: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color("070b14"))
	var t := Time.get_ticks_msec() / 1000.0
	for i in range(110):
		var seed_x := fmod(float(i) * 137.508, 1.0)
		var seed_y := fmod(float(i) * 61.803, 1.0)
		var p := Vector2(seed_x * vp.x, seed_y * vp.y)
		var tw := 0.4 + 0.6 * absf(sin(t * 1.2 + float(i)))
		var sz := 1.0 + float(i % 3) * 0.7
		draw_circle(p, sz, Color(0.8, 0.88, 1.0, 0.30 * tw))
	draw_rect(Rect2(0, vp.y * 0.30, vp.x, 2.0), Color(0.35, 0.65, 1.0, 0.16))
	draw_rect(Rect2(0, vp.y * 0.30 + 3, vp.x, 1.0), Color(0.35, 0.65, 1.0, 0.08))

## 返回键。首页没有返回键，其余页都有。
func _back_rect(vp: Vector2) -> Rect2:
	return Rect2(22.0, 22.0, 98.0, 38.0)

## 一页的描述 —— 这就是「加一个页面 = 加一段数据」的那份数据。
##
## item 的 kind：
##   tile   主菜单的大卡片（只有 HOME 用）
##   button 整行按钮，点了执行 act
##   choice 互斥选项，key + options[[值, 显示文本]]
##   toggle 开关，key
##   slider 拖动条，key（取值 0~1）
##   text   文本项，key（M1 只显示，点一下给提示）
##   label  纯文字说明，不可点
func _page_def(p: int) -> Dictionary:
	match p:
		Page.HOME:
			return {
				"title": "星 海 战 火",
				"subtitle": "ORIGINAL RTS · BUILT FOR TOUCH",
				"layout": "tiles",
				"items": [
					{"kind": "tile", "act": "goto:single", "label": "单人游戏",
						"desc": "与电脑对战 · 选阵营 / 难度 / 地图"},
					{"kind": "tile", "act": "goto:lan", "label": "局域网游戏",
						"desc": "同一 WiFi 下两台设备对打"},
					{"kind": "tile", "act": "goto:settings", "label": "设置",
						"desc": "画面 / 音频 / 操作 / 游戏 / 界面"},
					{"kind": "tile", "act": "goto:mods", "label": "模组",
						"desc": "自备皮肤与数值包"},
				],
			}
		Page.SINGLE:
			return {"title": "单人游戏", "subtitle": "选择阵营与开局条件", "layout": "single"}
		Page.LAN:
			# ⚠️ 这一页的**条目数直接决定面板高度**
			#    （`_form_metrics`：FORM_TITLE_H 78 + 每 section 32 + 每行 46 + 底部 24）。
			#    实测：3 个 section + 8 行 → 面板高 **566**，y 被夹到 104，
			#    底边 670 ≤ 720，留 50px 余量。
			#    **再加一行就会逼近屏幕底部**，而且不报错 ——
			#    `tests/Menu.gd` 里有一条钉住「所有项都在屏内」，加行之前先跑它。
			var al := lan_address_lines()
			var addr := String(al["main"])
			if int(al["count"]) > 1:
				addr += "（等 %d 个）" % int(al["count"])
			var status := _lan_status if _lan_status != "" else "未连接"
			return {
				"title": "局域网游戏",
				"subtitle": "同一 WiFi 下直连对战 · 2 人",
				"sections": [
					{"name": "本机", "items": [
						{"kind": "button", "act": "lan_name", "label": "玩家名",
							"desc": _lan_name},
						# ⚠️ 地址与状态**合成一行**。原来是两行，加「搜索房间」会
						#    把面板顶出屏幕下沿（见上面的行数警告）——
						#    而这一行本身用 `lan_address_lines()` 只取**一个**地址，
						#    不再把 8 个网卡拼成长串（那是 `30_lobby_host` 截图抓到的坑）。
						{"kind": "label", "text": "本机 %s · %s" % [addr, status]},
					]},
					{"name": "创建房间（我是主机）", "items": [
						{"kind": "choice", "group": "race", "label": "阵营", "options": [
							["terran", "人族"], ["zerg", "虫族"], ["protoss", "神族"]]},
						{"kind": "choice", "group": "map", "label": "地图", "options": [
							["open", "开阔平原"], ["plateau", "双坡道高地"],
							["river", "中间河道"]]},
						{"kind": "button", "act": "lan_host", "label": "创建房间"},
					]},
					{"name": "加入房间（我是客户端）", "items": [
						{"kind": "button", "act": "lan_scan", "label": "搜索局域网房间",
							"desc": "自动发现 · 点一下直接进"},
						{"kind": "button", "act": "lan_ip", "label": "手动输入地址",
							"desc": _lan_ip if _lan_ip != "" else "点一下输入"},
						{"kind": "button", "act": "lan_join", "label": "加入房间"},
					]},
				],
			}
		Page.SETTINGS:
			return _settings_page_def()
		Page.MODS:
			return _mods_page_def()
	return {"title": "", "subtitle": "", "sections": []}

## 设置页的分类。做成 tab，而不是一条长列表。
##
## ⚠️ 实测踩过：12 个设置项排成一条列表时，面板算出来高 **858px**，
##    而屏幕只有 720px —— 底部的「默认速度 / 开局自动暂停 / 恢复默认」
##    整块被推出屏幕，而**按项逐个查「在不在屏幕内」查不出来**
##    （「恢复默认」是按面板底边定位的，它自己一个项都不在屏内，反而没得查）。
##
## ⚠️ 也不能靠压行高解决：行高 46 已经是触控下限，
##    压到能装下（约 30px）就低于 Android 48dp 建议值了。
const SETTINGS_TABS := ["画面", "音频", "操作", "游戏", "界面"]

var _settings_tab := "画面"

func _settings_page_def() -> Dictionary:
	var groups := {
		"画面": [
			{"kind": "choice", "key": "max_fps", "label": "帧率上限",
				"options": [["30", "30"], ["60", "60"], ["120", "120"]]},
			{"kind": "toggle", "key": "show_fps", "label": "显示帧率"},
		],
		"音频": [
			{"kind": "toggle", "key": "sfx_on", "label": "音效开关"},
			{"kind": "slider", "key": "sfx_volume", "label": "音效音量"},
		],
		"操作": [
			{"kind": "choice", "key": "drag_pans", "label": "单指拖动",
				"options": [["true", "平移视野"], ["false", "框选部队"]]},
			{"kind": "choice", "key": "long_press", "label": "长按阈值",
				"options": [["0.18", "0.18s"], ["0.25", "0.25s"], ["0.35", "0.35s"]]},
			{"kind": "toggle", "key": "minimap_jump", "label": "点小地图跳转"},
		],
		"游戏": [
			{"kind": "choice", "key": "default_difficulty", "label": "默认难度",
				"options": [["easy", "轻松"], ["normal", "标准"], ["hard", "困难"]]},
			{"kind": "choice", "key": "default_map", "label": "默认地图",
				"options": [["open", "开阔平原"], ["plateau", "双坡道高地"], ["river", "中间河道"]]},
			{"kind": "choice", "key": "default_speed", "label": "默认速度",
				"options": [["1", "1×"], ["1.5", "1.5×"], ["2", "2×"]]},
			{"kind": "toggle", "key": "autopause", "label": "开局自动暂停"},
		],
		"界面": [
			{"kind": "button", "act": "hud_edit", "label": "编辑 HUD 布局",
				"desc": "拖动各面板位置 · M2 开放"},
		],
	}
	var items: Array = groups.get(_settings_tab, groups["画面"])
	return {
		"title": "设置",
		"subtitle": "改动即时写入 user://settings.cfg",
		"tabs": true,
		"primary": {"act": "settings_reset", "label": "恢复默认"},
		# section 名留空：tab 已经说明了这是哪一类，再画一遍标题是重复的
		"sections": [{"name": "", "items": items}],
	}

## 模组页每页显示几个。
##
## ⚠️ 这里踩的是**和设置页同一个坑**，只是更不可控：
##    设置页 12 个设置项排成一条列表，面板算出 858px，而屏幕只有 720px，
##    底部整块被推出屏幕 —— 而且「逐项查在不在屏内」查不出来。
##    模组的**数量是玩家决定的**（装 50 个完全可能），所以不能靠「让它自然变高」，
##    必须翻页。
##
## 📐 高度算术（`_form_metrics` 的口径，1280×720 基准屏）：
##    可用高度 = 720 - FORM_HEAD_H(104) - 24 = 592
##    面板固定开销 = FORM_TITLE_H(78) + 底部留白(24) = 102
##    ⇒ body 上限 490 = 两个 section 标题(64) + 46 × 行数  ⇒ 最多 9 行
##    本页固定占 4 行（模组行之外的：翻页按钮 / 重新扫描 / 路径 / 说明）
##    ⇒ 模组行最多 5 行。**改这个常量必须重算上面这段**，`tests/Mods.gd`
##      里有一条断言钉死「0 / 1 / 5 / 6 / 12 个模组时面板都不溢出」。
const MODS_PER_PAGE := 5

## 当前翻到第几页（从 0 起）。`_mods_page_def()` 里会夹取到合法范围 ——
## 因为模组数量会在玩家删/装模组后变化，页数跟着变，
## 存一个「曾经合法」的页码迟早越界。
var _mods_page := 0

## 模组页。
##
## M3 起这一页是**真能用的**：列出已装模组、可勾选启停、可上下排序、
## 冲突标黄、缺 mod.json 标红。所有改动立刻 `Mods.apply_all()` 生效。
func _mods_page_def() -> Dictionary:
	var n := Mods.list.size()
	var pages := maxi(1, int(ceil(float(n) / float(MODS_PER_PAGE))))
	# 夹取。放在这里是因为「页数」只有这里知道；
	# 重复调用是幂等的，所以从绘制 / 命中 / 测试三边调都安全。
	_mods_page = clampi(_mods_page, 0, pages - 1)

	var rows: Array = []
	if n == 0:
		rows.append({"kind": "label", "text": "还没有安装任何模组。"})
		rows.append({"kind": "label", "text": "把模组目录放进下面这个路径，回到本页即可看到。"})
	else:
		var lo := _mods_page * MODS_PER_PAGE
		var hi := mini(n, lo + MODS_PER_PAGE)
		for i in range(lo, hi):
			var m: Dictionary = Mods.list[i]
			var id := String(m["id"])
			var cf: Array = Mods.conflicted_fields_of(id)
			rows.append({
				"kind": "modrow", "id": id,
				"name": String(m["name"]),
				"version": String(m["version"]),
				"author": String(m["author"]),
				"enabled": bool(m["enabled"]),
				"error": String(m["error"]),
				"conflict": cf.size() > 0,
				"conflict_n": cf.size(),
				"skins": (m["skins"] as Dictionary).size(),
			})
	if pages > 1:
		rows.append({
			"kind": "button", "act": "mods_page", "label": "下一页 ▶",
			"desc": "第 %d / %d 页 · 共 %d 个" % [_mods_page + 1, pages, n],
		})

	var enabled := Mods.enabled_list().size()
	return {
		"title": "模组",
		# 目录路径放**副标题**：副标题画在 `FORM_HEAD_H`（104）之上，
		# **不占面板高度**。放进面板里的话每多一行就多 46px，
		# 而面板已经被「5 行模组 + 翻页 + 两个按钮 + 一行说明」占满了
		# （见 `MODS_PER_PAGE` 上面那段算术）。
		"subtitle": "玩家自备 · " + _mods_dir_text(),
		"sections": [
			{"name": "已安装（%d）" % n, "items": rows},
			{"name": "目录", "items": [
				{"kind": "button", "act": "mods_rescan", "label": "重新扫描目录",
					"desc": "启用 %d / 共 %d" % [enabled, n]},
				{"kind": "button", "act": "mods_open_dir", "label": "模组目录在哪",
					"desc": "点一下显示完整路径"},
				{"kind": "label", "text": "mod.json 必填 · skins/ 放皮肤 PNG · data/ 放数值 JSON"},
			]},
		],
	}

## 模组根目录的**绝对路径**。安卓上是
## `Android/data/<包名>/files/mods/`，玩家用文件管理器找得到，
## 但必须把全路径印出来 —— 只写 `user://mods/` 等于没说。
##
## ⚠️ 这里**不调 `Mods.ensure_dir()`**：那会建目录、可能写 README，
##    而本函数是被 `_page_def()` 每帧调用的（绘制 + 命中 + 度量三处）。
##    `globalize_path` 是纯函数，没有副作用。
func _mods_dir_text() -> String:
	return ProjectSettings.globalize_path(Mods.root_dir) + "/"

## 分类 tab 的矩形。绘制与命中读**同一份** ——
## 分开算的话，改一下 FORM_TAB_H 就会出现「看得见、点不到」。
##
## tab 平分面板宽度但**限宽 150**：平板横屏下面板 620px 宽，
## 5 个 tab 平分会拉成又宽又扁的长条，看着像输入框而不是标签。
## 限宽后整行居中，视觉上仍是一组。
func _tab_rects(panel: Rect2) -> Array:
	var n := SETTINGS_TABS.size()
	var out := []
	if n <= 0:
		return out
	var avail := panel.size.x - FORM_PAD * 2.0 - FORM_OPT_GAP * float(n - 1)
	var tw := minf(150.0, avail / float(n))
	var total := tw * float(n) + FORM_OPT_GAP * float(n - 1)
	var x0 := panel.position.x + (panel.size.x - total) * 0.5
	var y := panel.position.y + FORM_TITLE_H + 5.0
	for i in range(n):
		out.append(Rect2(x0 + float(i) * (tw + FORM_OPT_GAP), y, tw, 38.0))
	return out

## 表单面板的几何。抽出来是因为 _form_layout 与 _draw_form 都要用，
## 两处各算一遍迟早会漂移（改了行高只改一处 → 按钮和底框对不上）。
func _form_metrics(vp: Vector2, desc: Dictionary) -> Dictionary:
	var secs: Array = desc.get("sections", [])
	var body := 0.0
	for s in secs:
		# section 名为空时不占标题高度（设置页的 tab 已经说明了分类）
		if String(s["name"]) != "":
			body += FORM_SEC_H
		body += FORM_ROW_H * float((s["items"] as Array).size())
	var tab_h := FORM_TAB_H if bool(desc.get("tabs", false)) else 0.0
	var w := minf(FORM_W, vp.x - 60.0)
	# 底部主按钮区**按需预留**：只有声明了 `primary` 的页面才需要那 68px。
	# 无条件预留的话，局域网页 / 模组页底部会白白空出一大块。
	var foot_h := FORM_FOOT_H if desc.get("primary", null) != null else 24.0
	var h := FORM_TITLE_H + tab_h + body + foot_h
	# 垂直居中，但**上下都不许越界**：内容多的页面（局域网）自然高度可能
	# 超过「标题之下到屏幕底」这段，居中算出来会顶到 y=85 压住副标题。
	var y := clampf(vp.y * 0.5 - h * 0.5, FORM_HEAD_H, maxf(FORM_HEAD_H, vp.y - h - 24.0))
	var r := Rect2(vp.x * 0.5 - w * 0.5, y, w, h)
	return {"panel": r, "body": body, "tab_h": tab_h, "foot_h": foot_h}

## 某个 `choice` 行**当前选中**的值。绘制高亮与命中都读它。
##
## ⚠️ 两类 `choice` 走的是**两套**取值口径，不能混：
##    - 带 `group` 的（阵营 / 难度 / 地图）改的是**本局选项**，读 `_menu_cur()`；
##    - 不带 `group` 的（设置页那些）改的是**持久化设置**，读 `Settings`。
##    混了的话症状是「点了没反应」或者「选中的高亮跳到了另一个选项上」。
func _form_choice_cur(e: Dictionary) -> String:
	var g := String(e.get("group", ""))
	if g != "":
		return _menu_cur(g)
	return _setting_text(String(e.get("key", "")))

## 表单排版。返回每一行的矩形（含 choice 的子选项），绘制与命中都读它。
func _form_layout(vp: Vector2, desc: Dictionary) -> Array:
	var pm := _form_metrics(vp, desc)
	var panel: Rect2 = pm["panel"]
	var secs: Array = desc.get("sections", [])
	var out := []
	var y := panel.position.y + FORM_TITLE_H + float(pm["tab_h"])
	for s in secs:
		# ⚠️ 必须和 `_form_metrics` 用**同一个判据**：空 section 名不占标题高度。
		#    两处不一致的话，算出来的面板高度会比实际排版矮一个 FORM_SEC_H，
		#    最后一行会压到底部主按钮上（不报错，只是看着挤）。
		if String(s["name"]) != "":
			y += FORM_SEC_H
		for it in s["items"]:
			var e: Dictionary = (it as Dictionary).duplicate()
			var r := Rect2(panel.position.x + FORM_PAD, y, panel.size.x - FORM_PAD * 2.0, FORM_ROW_H - 6.0)
			e["rect"] = r
			e["row_y"] = y
			e["sec"] = String(s["name"])
			if String(e.get("kind", "")) == "choice":
				var opts: Array = e.get("options", [])
				var avail := r.size.x - FORM_LABEL_W - FORM_OPT_GAP * float(maxi(0, opts.size() - 1))
				var ow := minf(FORM_OPT_W, avail / float(maxi(1, opts.size())))
				var ox := r.position.x + FORM_LABEL_W
				var subs := []
				for pair in opts:
					subs.append({
						"rect": Rect2(ox, y, ow, FORM_ROW_H - 6.0),
						"value": String(pair[0]), "label": String(pair[1]),
					})
					ox += ow + FORM_OPT_GAP
				e["subs"] = subs
			elif String(e.get("kind", "")) == "modrow":
				e["subs"] = _modrow_subs(r)
			out.append(e)
			y += FORM_ROW_H
	return out

## 一行模组的四个命中区。绘制与命中读**同一份** ——
## 分开算的话改一下 FORM_ROW_H 就会出现「看得见、点不到」。
##
## `body`（勾选框 + 名称这一整块）**和勾选框共用一个 act**，是有意的：
## 26px 的勾选框在手机上远低于 48dp 建议值，只让勾选框能点的话
## 玩家得瞄着戳；整行可点之后，戳哪儿都能启停。
##
## 排序按钮放右侧（上 / 下），34×30 —— 比勾选框大一圈，
## 因为「排序」是低频操作，玩家不会去记它的精确位置。
func _modrow_subs(r: Rect2) -> Dictionary:
	var cy := r.get_center().y
	var chk := Rect2(r.position.x + 2.0, cy - 13.0, 26.0, 26.0)
	var dn := Rect2(r.end.x - 34.0, cy - 15.0, 34.0, 30.0)
	var up := Rect2(dn.position.x - 40.0, cy - 15.0, 34.0, 30.0)
	var body := Rect2(chk.end.x + 8.0, r.position.y, up.position.x - chk.end.x - 14.0, r.size.y)
	return {"chk": chk, "up": up, "down": dn, "body": body}

## 主菜单的四个大入口：2×2 卡片。
func _tiles_layout(vp: Vector2, desc: Dictionary) -> Array:
	var items: Array = desc.get("items", [])
	var cw := minf(272.0, (vp.x - 140.0) * 0.5)
	var ch := 104.0
	var gap := 24.0
	var total_w := cw * 2.0 + gap
	var x0 := vp.x * 0.5 - total_w * 0.5
	var y0 := maxf(150.0, vp.y * 0.5 - (ch * 2.0 + gap) * 0.5 + 26.0)
	var out := []
	for i in range(items.size()):
		var e: Dictionary = (items[i] as Dictionary).duplicate()
		e["rect"] = Rect2(x0 + float(i % 2) * (cw + gap), y0 + float(i / 2) * (ch + gap), cw, ch)
		out.append(e)
	return out

## 当前页的**全部**可点项。绘制 / 命中 / 测试三边读同一份。
##
## 纯函数：只依赖 _page 与当前取值，不碰绘制上下文 ——
## 所以无头测试里可以直接调它，把「点了没反应」这类回归测出来。
func menu_hit_table(vp: Vector2) -> Array:
	var desc := _page_def(_page)
	var layout := String(desc.get("layout", "form"))
	var out := []
	# 返回键（首页没有）
	if _page != Page.HOME:
		out.append({"rect": _back_rect(vp), "kind": "button", "act": "back"})
	if layout == "tiles":
		out.append_array(_tiles_layout(vp, desc))
		return out
	if layout == "single":
		# 单人页沿用原有的纯函数坐标，接口一个字没改 ——
		# 这样 tests/Touch.gd 第 14 组那 18 条断言不用动就继续有效。
		out.append_array(menu_option_rects(vp))
		out.append({"rect": menu_start_rect(vp), "kind": "button", "act": "start"})
		return out
	# 分类 tab（设置页）
	if bool(desc.get("tabs", false)):
		var p0: Rect2 = _form_metrics(vp, desc)["panel"]
		var trs := _tab_rects(p0)
		for i in range(trs.size()):
			out.append({
				"rect": trs[i],
				"kind": "button", "act": "stab:" + String(SETTINGS_TABS[i]),
				"label": String(SETTINGS_TABS[i])})
	for e in _form_layout(vp, desc):
		var k := String(e.get("kind", ""))
		if k == "choice":
			for sub in e["subs"]:
				# ⚠️ `key` 必须用 `.get()` —— 「本局选项」那类 choice 行（单人页 /
				#    局域网页）只有 `group`，**没有 `key`**。硬读 `e["key"]` 会抛
				#    「Invalid access to property or key 'key'」，而且是在
				#    **遍历中途**抛的：`menu_hit_table` 直接返回空数组，
				#    连带「返回键点不到」「整个页面所有按钮都点不到」，
				#    症状看着像布局全错，实际只少了一个默认值。
				out.append({"rect": sub["rect"], "kind": "choice",
					"key": String(e.get("key", "")),
					"group": String(e.get("group", "")),
					"value": String(sub["value"]), "label": String(sub["label"])})
		elif k == "button" or k == "toggle" or k == "slider" or k == "text":
			out.append(e)
		elif k == "modrow":
			# 子命中区**先登记小的**（勾选框 / 排序），再登记整行 ——
			# `_menu_press` 取第一个命中的项，虽然这几个区互不重叠，
			# 但顺序上「更具体的在前」是个不容易写错的习惯。
			var mid := String(e.get("id", ""))
			var sb: Dictionary = e["subs"]
			out.append({"rect": sb["chk"], "kind": "button", "act": "mod_toggle:" + mid})
			out.append({"rect": sb["up"], "kind": "button", "act": "mod_up:" + mid})
			out.append({"rect": sb["down"], "kind": "button", "act": "mod_down:" + mid})
			out.append({"rect": sb["body"], "kind": "button", "act": "mod_toggle:" + mid})
		# label 不可点，不登记
	var prim: Variant = desc.get("primary", null)
	if prim != null:
		var p := _form_metrics(vp, desc)["panel"] as Rect2
		out.append({"rect": Rect2(p.position.x + FORM_PAD, p.end.y - FORM_FOOT_H + 14.0,
			p.size.x - FORM_PAD * 2.0, 42.0),
			"kind": "button", "act": String((prim as Dictionary)["act"]),
			"label": String((prim as Dictionary)["label"])})
	return out

## 菜单页顶部：标题 + 副标题 + 返回键。
func _draw_page_head(vp: Vector2, desc: Dictionary) -> void:
	draw_string(font, Vector2(0, 60.0), String(desc.get("title", "")),
		HORIZONTAL_ALIGNMENT_CENTER, vp.x, 38.0, Color(0.90, 0.94, 1.0))
	var sub := String(desc.get("subtitle", ""))
	if sub != "":
		draw_string(font, Vector2(0, 86.0), sub,
			HORIZONTAL_ALIGNMENT_CENTER, vp.x, 13.0, Color(0.42, 0.55, 0.72))
	if _page != Page.HOME:
		var br := _back_rect(vp)
		draw_rect(br, Color(1, 1, 1, 0.07), true)
		draw_rect(br, Color(1, 1, 1, 0.14), false, 1.0)
		_draw_text_center("← 返回", br, 14.0, Color(0.82, 0.86, 0.94))

## 菜单页总入口：背景 + 顶部 + 按 layout 分派。
func _draw_page(vp: Vector2) -> void:
	var desc := _page_def(_page)
	_draw_menu_bg(vp)
	_draw_page_head(vp, desc)
	var layout := String(desc.get("layout", "form"))
	if layout == "tiles":
		_draw_tiles(vp, desc)
	elif layout == "single":
		_draw_single(vp)
	else:
		_draw_form(vp, desc)
	# 底部说明。**只在 `_draw_page` 里画这一处** ——
	# 各页自己的 `_draw_*` 不要再画一遍：两处的 y 差几像素就会叠成糊字
	# （单人页实测踩过，`_draw_page` 用 vp.y-22、`_draw_single` 用 vp.y-26）。
	draw_string(font, Vector2(0, vp.y - 22.0), MENU_HINT,
		HORIZONTAL_ALIGNMENT_CENTER, vp.x, 12.0, Color(0.42, 0.50, 0.64))
	# 屏幕键盘画在**最上层**：它是模态的，要盖住整页。
	if _lan_input_key != "":
		_draw_lan_keypad(vp)

func _draw_tiles(vp: Vector2, desc: Dictionary) -> void:
	for e in _tiles_layout(vp, desc):
		var r: Rect2 = e["rect"]
		draw_rect(r, Color(0.09, 0.13, 0.20, 0.92), true)
		draw_rect(r, Color(0.35, 0.65, 1.0, 0.35), false, 1.4)
		draw_rect(Rect2(r.position.x, r.position.y, 4.0, r.size.y), Color(0.35, 0.65, 1.0, 0.85), true)
		draw_string(font, Vector2(r.position.x + 22.0, r.position.y + 40.0), String(e["label"]),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 40.0, 22.0, Color(0.94, 0.97, 1.0))
		_wrap_text(String(e.get("desc", "")), Vector2(r.position.x + 22.0, r.position.y + 64.0),
			r.size.x - 40.0, 12.5, Color(0.58, 0.66, 0.80), 17.0, 2)

## 通用表单渲染。所有非 tile / 非 single 的页面都走这里。
func _draw_form(vp: Vector2, desc: Dictionary) -> void:
	var pm := _form_metrics(vp, desc)
	var panel: Rect2 = pm["panel"]
	draw_rect(panel, Color(0.055, 0.070, 0.110, 0.94), true)
	draw_rect(panel, Color(1, 1, 1, 0.10), false, 1.0)

	# 分类 tab 行（设置页）。未选中的也要有底 —— 只有边框的话，
	# 在深色面板上会看不出「这里是可以点的」。
	if bool(desc.get("tabs", false)):
		var trs := _tab_rects(panel)
		for i in range(trs.size()):
			var tr: Rect2 = trs[i]
			var tname := String(SETTINGS_TABS[i])
			var tsel := tname == _settings_tab
			draw_rect(tr, Color(0.56, 0.89, 0.42, 0.22) if tsel else Color(1, 1, 1, 0.05), true)
			draw_rect(tr, Color("8fe36b") if tsel else Color(1, 1, 1, 0.12), false, 1.2)
			_draw_text_center(tname, tr, 14.0,
				Color(0.94, 0.97, 1.0) if tsel else Color(0.66, 0.73, 0.86))

	var cur_sec := ""
	for e in _form_layout(vp, desc):
		var sec := String(e.get("sec", ""))
		if sec != cur_sec:
			cur_sec = sec
			draw_string(font, Vector2(panel.position.x + FORM_PAD, float(e["row_y"]) - 10.0),
				sec, HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0, Color(0.45, 0.72, 0.95))
		var r: Rect2 = e["rect"]
		var kind := String(e.get("kind", ""))
		# 左列标签。
		# ⚠️ `button` **不画** —— 按钮自己的居中文字就是它的标签，
		#    两边都画会看到同一句话出现两次（实测踩过：局域网页的
		#    「创建房间（我是主机）」左边一次、中间又一次）。
		#    `label` 也不是「标签 + 值」结构，它的正文就是 text。
		#    `modrow` 同理：一行里要放勾选框 + 名称 + 版本 + 作者 + 排序按钮，
		#    左边再画一列标签就没地方了。
		if kind != "label" and kind != "button" and kind != "modrow":
			draw_string(font, Vector2(r.position.x, r.get_center().y + 5.0), String(e.get("label", "")),
				HORIZONTAL_ALIGNMENT_LEFT, FORM_LABEL_W - 12.0, 14.0, Color(0.86, 0.90, 0.97))
		match kind:
			"label":
				draw_string(font, Vector2(r.position.x, r.get_center().y + 5.0), String(e.get("text", "")),
					HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 12.5, Color(0.52, 0.60, 0.74))
			"button":
				draw_rect(r, Color(0.20, 0.30, 0.44, 0.85), true)
				draw_rect(r, Color(0.40, 0.62, 0.90, 0.55), false, 1.2)
				_draw_text_center(String(e.get("label", "")), r, 15.0, Color(0.94, 0.97, 1.0))
				var d := String(e.get("desc", ""))
				if d != "":
					draw_string(font, Vector2(r.position.x + r.size.x - 200.0, r.get_center().y + 5.0),
						d, HORIZONTAL_ALIGNMENT_RIGHT, 196.0, 11.5, Color(0.55, 0.63, 0.78))
			"choice":
				for sub in e["subs"]:
					var sr: Rect2 = sub["rect"]
					var sel := _form_choice_cur(e) == String(sub["value"])
					draw_rect(sr, Color(0.56, 0.89, 0.42, 0.24) if sel else Color(1, 1, 1, 0.06), true)
					draw_rect(sr, Color("8fe36b") if sel else Color(1, 1, 1, 0.14), false, 1.2)
					_draw_text_center(String(sub["label"]), sr, 13.5,
						Color(0.94, 0.97, 1.0) if sel else Color(0.72, 0.78, 0.88))
			"toggle":
				var on := _setting_flag(String(e["key"]))
				var tr := Rect2(r.position.x + FORM_LABEL_W, r.get_center().y - 15.0, 66.0, 30.0)
				draw_rect(tr, Color(0.56, 0.89, 0.42, 0.55) if on else Color(1, 1, 1, 0.08), true)
				draw_rect(tr, Color("8fe36b") if on else Color(1, 1, 1, 0.18), false, 1.2)
				var kr := Rect2(tr.position.x + (38.0 if on else 4.0), tr.position.y + 4.0, 24.0, 22.0)
				draw_rect(kr, Color(0.95, 0.98, 1.0) if on else Color(0.62, 0.66, 0.74), true)
			"slider":
				var v := _setting_num(String(e["key"]))
				var sr2 := _slider_track(r)
				draw_rect(sr2, Color(1, 1, 1, 0.10), true)
				draw_rect(Rect2(sr2.position.x, sr2.position.y, sr2.size.x * v, sr2.size.y),
					Color(0.45, 0.78, 1.0, 0.85), true)
				draw_circle(Vector2(sr2.position.x + sr2.size.x * v, sr2.get_center().y), 8.0,
					Color(0.92, 0.96, 1.0))
				draw_string(font, Vector2(sr2.end.x + 12.0, r.get_center().y + 5.0),
					"%d%%" % int(round(v * 100.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0,
					Color(0.80, 0.86, 0.95))
			"text":
				draw_rect(r, Color(1, 1, 1, 0.05), true)
				draw_rect(r, Color(1, 1, 1, 0.12), false, 1.0)
				draw_string(font, Vector2(r.position.x + FORM_LABEL_W, r.get_center().y + 5.0),
					_setting_text(String(e["key"])), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - FORM_LABEL_W - 16.0,
					14.0, Color(0.92, 0.96, 1.0))
			"modrow":
				_draw_mod_row(e, r)

	# 底部主按钮（如「恢复默认」）
	var prim: Variant = desc.get("primary", null)
	if prim != null:
		var pr := Rect2(panel.position.x + FORM_PAD, panel.end.y - FORM_FOOT_H + 14.0,
			panel.size.x - FORM_PAD * 2.0, 42.0)
		draw_rect(pr, Color(0.30, 0.24, 0.20, 0.85), true)
		draw_rect(pr, Color(0.90, 0.72, 0.42, 0.55), false, 1.2)
		_draw_text_center(String((prim as Dictionary)["label"]), pr, 15.0, Color(0.96, 0.92, 0.84))

## 一行模组。命中区来自 `_modrow_subs()` —— 绘制与命中同源。
##
## 三种状态用**颜色**区分，不用图标：
##   正常 → 中性灰；**冲突**（多个模组改同一字段）→ 黄；**缺 mod.json** → 红。
## 黄不是「错误」，模组照样加载（后加载的赢），只是要让玩家知道
## 「装了新模组之后老模组好像没生效」是**正常的**、不是 bug。
func _draw_mod_row(e: Dictionary, r: Rect2) -> void:
	var on := bool(e.get("enabled", true))
	var err := String(e.get("error", ""))
	var cf := bool(e.get("conflict", false))
	var sb: Dictionary = e["subs"]
	var body: Rect2 = sb["body"]
	var ck: Rect2 = sb["chk"]
	var up: Rect2 = sb["up"]
	var dn: Rect2 = sb["down"]

	var bg := Color(1, 1, 1, 0.05)
	var bd := Color(1, 1, 1, 0.12)
	if err != "":
		bg = Color(0.90, 0.32, 0.28, 0.16)
		bd = Color("e85c50")
	elif cf:
		bg = Color(0.95, 0.78, 0.28, 0.15)
		bd = Color("ffd166")
	draw_rect(r, bg, true)
	draw_rect(r, bd, false, 1.2)

	# 勾选框。**用线段画对勾，不用「✓」字符** ——
	# 字体缺字时 draw_string 会画成方块或空白，且不报错。
	draw_rect(ck, Color(0.56, 0.89, 0.42, 0.55) if on else Color(1, 1, 1, 0.07), true)
	draw_rect(ck, Color("8fe36b") if on else Color(1, 1, 1, 0.22), false, 1.4)
	if on:
		var ink := Color(0.10, 0.18, 0.10)
		draw_line(Vector2(ck.position.x + 6.0, ck.get_center().y + 1.0),
			Vector2(ck.get_center().x - 1.0, ck.end.y - 7.0), ink, 2.6)
		draw_line(Vector2(ck.get_center().x - 1.0, ck.end.y - 7.0),
			Vector2(ck.end.x - 5.0, ck.position.y + 7.0), ink, 2.6)

	# 名称 + 版本。禁用时压暗 —— 压暗比加删除线好认，
	# 而且删除线在 14px 下会和小字号笔画糊在一起。
	var txt := String(e.get("name", ""))
	var ver := String(e.get("version", ""))
	if ver != "":
		txt += "  v" + ver
	draw_string(font, Vector2(body.position.x, r.get_center().y + 5.0), txt,
		HORIZONTAL_ALIGNMENT_LEFT, body.size.x - 130.0, 14.0,
		Color(0.92, 0.96, 1.0) if on else Color(0.44, 0.50, 0.62))

	# 右侧状态位：错误 > 冲突 > 作者。三选一，不叠着画。
	var note := ""
	var nc := Color(0.52, 0.60, 0.74)
	if err != "":
		note = err
		nc = Color("ff9a8f")
	elif cf:
		note = "数值冲突 ×%d" % int(e.get("conflict_n", 0))
		nc = Color("ffd166")
	else:
		note = String(e.get("author", ""))
	if note != "":
		draw_string(font, Vector2(up.position.x - 138.0, r.get_center().y + 5.0), note,
			HORIZONTAL_ALIGNMENT_RIGHT, 132.0, 11.5, nc)

	_draw_mod_arrow(up, true)
	_draw_mod_arrow(dn, false)

## 排序箭头。同样用线段画，不用「▲▼」字符。
func _draw_mod_arrow(r: Rect2, up: bool) -> void:
	draw_rect(r, Color(1, 1, 1, 0.06), true)
	draw_rect(r, Color(1, 1, 1, 0.16), false, 1.0)
	var c := r.get_center()
	var col := Color(0.86, 0.92, 1.0)
	var d := -1.0 if up else 1.0
	draw_line(Vector2(c.x - 7.0, c.y - d * 4.0), Vector2(c.x, c.y + d * 5.0), col, 2.2)
	draw_line(Vector2(c.x + 7.0, c.y - d * 4.0), Vector2(c.x, c.y + d * 5.0), col, 2.2)

## 滑块的轨道矩形。绘制与命中同源。
func _slider_track(r: Rect2) -> Rect2:
	var w := minf(260.0, r.size.x - FORM_LABEL_W - 70.0)
	return Rect2(r.position.x + FORM_LABEL_W, r.get_center().y - 5.0, w, 10.0)

# ---- 设置项的读写小包装：把 Settings 的 Variant 转成 UI 要的类型 ----

func _setting_text(key: String) -> String:
	return Settings.text(key, "")

func _setting_flag(key: String) -> bool:
	return Settings.flag(key, false)

func _setting_num(key: String) -> float:
	return Settings.num(key, 0.0)

# ---------------------------------------------------------------- 单人页
## 单人页沿用第十二轮之前的那套布局（阵营卡 + 难度 / 地图 / 速度 + 开始战斗）。
## 坐标仍由 menu_option_rects() / menu_start_rect() 这两个纯函数给出。
func _draw_single(vp: Vector2) -> void:
	# 阵营卡 + 难度 / 地图 / 速度 —— 坐标全部来自 menu_option_rects()。
	# 绘制与命中读同一份数据；测试也调它，所以「菜单点了没反应」测得出来。
	var opts := menu_option_rects(vp)
	var cw := 210.0
	var total := 3.0 * cw + 2.0 * 22.0
	var x0 := vp.x * 0.5 - total * 0.5
	var by := vp.y * 0.36
	var dy := by + 178.0
	var traits := {
		"terran": ["均衡", "远程火力", "建筑便宜"],
		"zerg": ["爆兵快", "单位廉价", "机动高"],
		"protoss": ["单位强", "护盾", "人口高效"],
	}
	var labeled := {}
	for it in opts:
		var g := String(it["group"])
		var val := String(it["value"])
		var r: Rect2 = it["rect"]
		var sel := _menu_cur(g) == val
		# 每组的行标签只画一次（用 row_y 定位，和按钮同源）
		if g != "race" and not labeled.has(g):
			labeled[g] = true
			draw_string(font, Vector2(x0, float(it["row_y"]) + 16), String(_GROUP_LABEL.get(g, g)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14.0, Color(0.65, 0.72, 0.85))
		if g == "race":
			var fd: Dictionary = GameData.FACTIONS[val]
			draw_rect(r, Color(fd["color_dim"].r, fd["color_dim"].g, fd["color_dim"].b,
				0.55 if sel else 0.28), true)
			draw_rect(r, fd["color"] if sel else Color(1, 1, 1, 0.15), false, 2.0 if sel else 1.0)
			# 旗帜色块
			draw_rect(Rect2(r.position.x + 14, r.position.y + 14, 34.0, 34.0), fd["color"])
			draw_rect(Rect2(r.position.x + 14, r.position.y + 14, 34.0, 34.0), Color(1, 1, 1, 0.5), false, 1.0)
			draw_string(font, Vector2(r.position.x + 58, r.position.y + 36), String(fd["name"]),
				HORIZONTAL_ALIGNMENT_LEFT, cw - 70, 16.0, Color(0.95, 0.97, 1.0))
			# 描述换行
			_wrap_text(String(fd["desc"]), Vector2(r.position.x + 14, r.position.y + 72),
				cw - 28, 12.0, Color(0.70, 0.76, 0.88), 16.0, 3)
			# 特点
			var tx := r.position.x + 14
			for tr in traits[val]:
				var tw2 := font.get_string_size(String(tr), HORIZONTAL_ALIGNMENT_LEFT, -1, 11.0).x + 12.0
				draw_rect(Rect2(tx, r.position.y + 116, tw2, 20.0),
					Color(fd["color"].r, fd["color"].g, fd["color"].b, 0.28), true)
				_draw_text_center(String(tr), Rect2(tx, r.position.y + 116, tw2, 20.0), 11.0,
					Color(0.92, 0.95, 1.0))
				tx += tw2 + 6.0
		else:
			draw_rect(r, Color(0.56, 0.89, 0.42, 0.24) if sel else Color(1, 1, 1, 0.06), true)
			draw_rect(r, Color("8fe36b") if sel else Color(1, 1, 1, 0.14), false, 1.4)
			_draw_text_center(String(it["label"]), r, 14.0, Color(0.92, 0.96, 1.0))

	# 开始按钮
	var sr := menu_start_rect(vp)
	_btn_primary = sr
	draw_rect(sr, Color(0.35, 0.70, 0.42, 0.92), true)
	draw_rect(sr, Color(0.6, 0.95, 0.55), false, 2.0)
	_draw_text_center("开 始 战 斗", sr, 20.0, Color(0.97, 1.0, 0.97))

	# ⚠️ 底部说明**不在这里画** —— `_draw_page()` 已经统一画了一遍。
	#    这里再画一遍会差 4px 叠在一起，字迹发糊（实测截图里能看出来）。

func _wrap_text(text: String, pos: Vector2, max_w: float, size: float, col: Color, lh: float, max_lines: int) -> void:
	var line := ""
	var y := pos.y
	var n := 0
	for i in range(text.length()):
		var ch := text[i]
		var test := line + ch
		if font.get_string_size(test, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > max_w:
			draw_string(font, Vector2(pos.x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
			line = ch
			y += lh
			n += 1
			if n >= max_lines:
				return
		else:
			line = test
	if line != "":
		draw_string(font, Vector2(pos.x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _draw_end(vp: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.03, 0.05, 0.82))
	var drawn := world.winner < 0
	var win := world.winner == _me()
	var t := "平  局" if drawn else ("胜  利" if win else "战  败")
	var tc := Color("e8d48a") if drawn else (Color("8fe36b") if win else Color("ff7b6b"))
	draw_string(font, Vector2(0, vp.y * 0.38), t, HORIZONTAL_ALIGNMENT_CENTER, vp.x, 46.0, tc)
	var f: Dictionary = world.factions[_me()]
	var stat := "采集矿物 %d · 用时 %d:%02d · 剩余部队 %d" % [
		int(f["harvested"]), int(world.elapsed) / 60, int(world.elapsed) % 60, world.count_units(_me())]
	if drawn:
		stat = "双方都已无力再战 · 用时 %d:%02d" % [int(world.elapsed) / 60, int(world.elapsed) % 60]
	draw_string(font, Vector2(0, vp.y * 0.38 + 40), stat, HORIZONTAL_ALIGNMENT_CENTER, vp.x, 15.0, Color(0.75, 0.82, 0.92))
	var r := Rect2(vp.x * 0.5 - 110.0, vp.y * 0.38 + 76.0, 220.0, 50.0)
	draw_rect(r, Color(0.35, 0.70, 0.42, 0.9), true)
	draw_rect(r, Color(0.6, 0.95, 0.55), false, 1.6)
	_draw_text_center("再 来 一 局", r, 18.0, Color(0.97, 1.0, 0.97))
	_btn_primary = r

# ---------------------------------------------------------------- UI 命中
## 旧的「按屏幕坐标猜 UI 区域」实现已删除。
## 现在统一走 _ui_hit() 登记 + _ui_pick() 查找，见文件上半部分。

# ================================================================ HUD 编辑模式（第十二轮 M2）
## 入口：设置 → 界面 → 「编辑 HUD 布局」。
##
## 设计取舍：
##   · **不做自由摆放**，只做「9 宫格吸附 + 三档缩放」。手指把 620×96 的指令区
##     对到 ±1px 是不可能的，自由摆放只会让 HUD 越调越乱；而锚点 + 偏移的模型
##     天然适配任何屏幕尺寸（换手机不会错位）。
##   · 编辑模式只从菜单进入，那时 `world == null` —— 世界本来就不推进，
##     不需要额外暂停。小地图模块会退到 `HudLayout` 的兜底比例 0.625，
##     正好等于本作 64×40 地图的宽高比（1536×960），所以框画出来和实机一致。
##   · 重叠不做硬禁止，只给黄色警告描边 —— 硬禁止会带来「为什么拖不过去」的困惑，
##     而且玩家有时确实想叠一点（比如把资源栏压在小地图上）。
##   · 隐藏的模块**照常画出来**（灰色）。否则藏起来之后就再也点不到、永远找不回来，
##     这类「操作后无法回退」的 UI 是设计事故。
const HUD_SNAP_MARGIN := 12.0   # 吸附到屏幕边时留的边距
const HUD_BAR_H := 96.0         # 编辑工具栏高度

func _start_hud_edit() -> void:
	_hud_edit = true
	_hud_drag = ""
	_hud_drag_id = -1
	_hud_sel = ""
	_hud_dirty = false
	_ui_hits.clear()
	_toast("按住模块拖动 · 松手自动吸附到最近的格子", Color("8fd0ff"))

## 退出编辑模式。**不传 save 参数** —— 「保存」按钮只落盘不退出，
## 「取消」按钮落盘回滚后退出；两个动作正交，比「保存并退出 / 放弃并退出」更好懂。
func _exit_hud_edit() -> void:
	HudLayout.load()
	_hud_edit = false
	_hud_drag = ""
	_hud_drag_id = -1
	_hud_sel = ""
	_hud_dirty = false

## 编辑模式下模块的矩形。**不检查 visible** —— 理由见上面的设计取舍。
func _hud_rect(m: String, vp: Vector2) -> Rect2:
	var ws: Vector2 = world.world_size if world != null else Vector2.ZERO
	return HudLayout.rect(m, vp, ws)

## 编辑模式下互相重叠的模块名（去重）。纯函数，无头测试要能用。
## 默认布局零重叠 —— `tests/Hud.gd` 钉死这一条。
func hud_edit_overlaps(vp: Vector2) -> Array:
	var ms := HudLayout.MODULES
	var out: Array = []
	for i in range(ms.size()):
		for j in range(i + 1, ms.size()):
			var a: String = ms[i]
			var b: String = ms[j]
			if _hud_rect(a, vp).intersects(_hud_rect(b, vp)):
				if not out.has(a):
					out.append(a)
				if not out.has(b):
					out.append(b)
	return out

## 工具栏按钮的命中表。纯函数 —— `_draw_hud_editor()` 在无头环境下调不了，
## 绘制与命中必须读同一份坐标（本项目铁律）。
## act 取值：`hud_reset` / `hud_save` / `hud_cancel` / `hud_vis` / `hud_sc:0|1|2`
func hud_edit_hit_table(vp: Vector2) -> Array:
	var out: Array = []
	var bh := 44.0
	var y := vp.y - HUD_BAR_H + (HUD_BAR_H - bh) * 0.5
	var x := 12.0
	for e in [["hud_reset", "恢复默认", 104.0], ["hud_save", "保存", 84.0], ["hud_cancel", "取消", 84.0]]:
		out.append({"rect": Rect2(x, y, float(e[2]), bh), "act": String(e[0])})
		x += float(e[2]) + 8.0
	# 右侧属性区：只在选中模块时出现。从右往左排，顺序固定 ——
	# 选中项一变按钮就换位置的话，手指会点错。
	if _hud_sel == "":
		return out
	var rx := vp.x - 12.0
	for e in [["hud_sc:2", 60.0], ["hud_sc:1", 76.0], ["hud_sc:0", 60.0], ["hud_vis", 84.0]]:
		var w := float(e[1])
		out.append({"rect": Rect2(rx - w, y, w, bh), "act": String(e[0])})
		rx -= w + 8.0
	return out

func _hud_scale_label(s: float) -> String:
	if absf(s - 0.85) < 0.01:
		return "小"
	if absf(s - 1.15) < 0.01:
		return "大"
	return "标准"

## 工具栏中间那行状态文字。
func _hud_sel_label() -> String:
	if _hud_sel == "":
		return "未选中模块 · 轻点任一模块开始拖动"
	return "%s · %s · %s" % [
		String(HudLayout.LABELS.get(_hud_sel, _hud_sel)),
		"已隐藏" if not HudLayout.visible_of(_hud_sel) else "显示中",
		_hud_scale_label(HudLayout.scale_of(_hud_sel)),
	]

# ---------------------------------------------------------------- 编辑模式的输入

## ⚠️ `vp` 可以显式传入 —— 无头环境下 `get_viewport_rect()` 是 1280×1280（正方形），
##    与真机 1280×720 不符；测试要按真机尺寸验，就必须能把视口喂进来。
func _hud_edit_touch(index: int, pos: Vector2, pressed: bool, vp: Vector2 = Vector2.ZERO) -> void:
	if vp == Vector2.ZERO:
		vp = get_viewport_rect().size
	if not pressed:
		# 松手：把拖走的模块吸附到最近的格子。**吸附只在松手时发生** ——
		# 拖动过程中换锚点会让模块在屏幕中线附近「跳」一下。
		if index == _hud_drag_id and _hud_drag != "":
			_hud_snap(_hud_drag, vp)
			_hud_dirty = true
		_hud_drag = ""
		_hud_drag_id = -1
		return
	# 1) 工具栏优先 —— 它画在最上层
	for m in hud_edit_hit_table(vp):
		if (m["rect"] as Rect2).has_point(pos):
			_hud_act(String(m["act"]))
			return
	# 2) 模块。从后往前找（后画的在上面），隐藏的模块也能被选中
	var ms := HudLayout.MODULES
	for i in range(ms.size() - 1, -1, -1):
		var nm: String = ms[i]
		var r := _hud_rect(nm, vp)
		if not r.has_point(pos):
			continue
		_hud_sel = nm
		_hud_drag = nm
		_hud_drag_id = index
		_hud_drag_off = pos - r.position
		return
	# 3) 点空白 = 取消选中（工具栏属性区随之收起）
	_hud_sel = ""

## 拖动中：反解 offset，**不换锚点**。`vp` 的理由同上。
func _hud_edit_drag(pos: Vector2, vp: Vector2 = Vector2.ZERO) -> void:
	if _hud_drag == "":
		return
	if vp == Vector2.ZERO:
		vp = get_viewport_rect().size
	var m := _hud_drag
	var ws: Vector2 = world.world_size if world != null else Vector2.ZERO
	var size: Vector2 = HudLayout.base_size(m, vp, ws) * HudLayout.scale_of(m)
	var a := HudLayout.anchor_of(m)
	var piv := HudLayout.pivot_of(a)
	var off: Vector2 = (pos - _hud_drag_off) + Vector2(piv.x * size.x, piv.y * size.y) \
		- HudLayout.anchor_xy(a, vp)
	HudLayout.set_mod(m, {"ox": off.x, "oy": off.y})

## 松手吸附：按模块**中心**落在 3×3 的哪一格决定锚点，再把模块贴到该格的屏幕边。
## 贴边而不是「保持原位只换锚点」—— 后者玩家看不到任何反馈，会以为吸附坏了。
func _hud_snap(m: String, vp: Vector2) -> void:
	var c := _hud_rect(m, vp).get_center()
	var col := 0
	if c.x > vp.x * 2.0 / 3.0:
		col = 2
	elif c.x >= vp.x / 3.0:
		col = 1
	var row := 0
	if c.y > vp.y * 2.0 / 3.0:
		row = 2
	elif c.y >= vp.y / 3.0:
		row = 1
	var a: String = HudLayout.ANCHORS[row * 3 + col]
	var dx := 0.0
	if col == 0:
		dx = HUD_SNAP_MARGIN
	elif col == 2:
		dx = -HUD_SNAP_MARGIN
	var dy := 0.0
	if row == 0:
		dy = HUD_SNAP_MARGIN
	elif row == 2:
		dy = -HUD_SNAP_MARGIN
	HudLayout.set_mod(m, {"anchor": a, "ox": dx, "oy": dy})

func _hud_act(act: String) -> void:
	if act.begins_with("hud_sc:"):
		if _hud_sel == "":
			return
		var i: int = clampi(int(act.substr(7)), 0, HudLayout.SCALES.size() - 1)
		HudLayout.set_mod(_hud_sel, {"scale": float(HudLayout.SCALES[i])})
		_hud_dirty = true
		return
	match act:
		"hud_reset":
			HudLayout.reset()
			_hud_dirty = true
			_toast("已恢复默认布局（还没保存）", Color("ffd166"))
		"hud_save":
			HudLayout.save()
			_hud_dirty = false
			_toast("HUD 布局已保存", Color("8fe36b"))
		"hud_cancel":
			_exit_hud_edit()
		"hud_vis":
			if _hud_sel == "":
				return
			HudLayout.set_mod(_hud_sel, {"visible": not HudLayout.visible_of(_hud_sel)})
			_hud_dirty = true

# ---------------------------------------------------------------- 编辑模式的绘制

func _draw_hud_editor(vp: Vector2) -> void:
	# 1) 遮罩：压暗战场，同时让幽灵框看得清
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.03, 0.06, 0.78))
	# 2) 3×3 锚点参考格
	for i in range(1, 3):
		var fx := vp.x * float(i) / 3.0
		var fy := vp.y * float(i) / 3.0
		draw_line(Vector2(fx, 0), Vector2(fx, vp.y), Color(1, 1, 1, 0.07), 1.0)
		draw_line(Vector2(0, fy), Vector2(vp.x, fy), Color(1, 1, 1, 0.07), 1.0)
	# 3) 重叠警告先算一次，别在循环里 O(n²) 反复算
	var ov := hud_edit_overlaps(vp)
	# 4) 各模块的幽灵框
	for m in HudLayout.MODULES:
		var r := _hud_rect(m, vp)
		if r.size.x <= 0.0:
			continue
		var vis := HudLayout.visible_of(m)
		# ⚠️ `m` 来自 `for m in Array`，是 Variant —— `m == _hud_sel` 推不出类型，
		#    必须显式标注（本项目已踩过多次同类坑）。
		var sel: bool = String(m) == _hud_sel
		draw_rect(r, Color(0.16, 0.22, 0.34, 0.86) if vis else Color(0.14, 0.14, 0.18, 0.74), true)
		var edge := Color(1, 1, 1, 0.22)
		if sel:
			edge = Color("8fd0ff")
		elif ov.has(m):
			edge = Color("ffd166")
		draw_rect(r, edge, false, 2.0 if sel else 1.2)
		# 左上角拖动柄（三条横线）—— 手机上没有光标，必须给出「这里能抓」的暗示
		var hx := r.position.x + 10.0
		var hy := r.position.y + 12.0
		for k in range(3):
			draw_line(Vector2(hx, hy + float(k) * 5.0), Vector2(hx + 14.0, hy + float(k) * 5.0),
				Color(1, 1, 1, 0.45 if vis else 0.22), 1.6)
		var nm := String(HudLayout.LABELS.get(m, m))
		if not vis:
			nm += "（已隐藏）"
		var nm_col := Color(0.92, 0.95, 1.0) if vis else Color(0.60, 0.62, 0.70)
		draw_string(font, Vector2(r.position.x + 32.0, r.position.y + 22.0), nm,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0, nm_col)
		var dim := "%d × %d" % [int(r.size.x), int(r.size.y)]
		var dim_col := Color(0.55, 0.62, 0.74)
		if r.size.y < 46.0:
			# 矮模块（高 34 的资源栏 / 系统按钮）放不下第二行 —— 尺寸挪到名称右边。
			# 照旧画在 +38 的话文字会溢出框外，压在 3×3 参考线和隔壁模块上（截图发现的）。
			var nw := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0).x
			draw_string(font, Vector2(r.position.x + 42.0 + nw, r.position.y + 22.0), dim,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11.0, dim_col)
		else:
			draw_string(font, Vector2(r.position.x + 32.0, r.position.y + 38.0), dim,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11.0, dim_col)
	# 5) 工具栏
	draw_rect(Rect2(0, vp.y - HUD_BAR_H, vp.x, HUD_BAR_H), Color(0.043, 0.058, 0.094, 0.98))
	draw_line(Vector2(0, vp.y - HUD_BAR_H), Vector2(vp.x, vp.y - HUD_BAR_H), Color(1, 1, 1, 0.12), 1.5)
	for e in hud_edit_hit_table(vp):
		var br: Rect2 = e["rect"]
		var act := String(e["act"])
		var label := ""
		var on := false
		match act:
			"hud_reset": label = "恢复默认"
			"hud_save": label = "保存"
			"hud_cancel": label = "取消"
			"hud_vis":
				label = "显示" if (_hud_sel != "" and not HudLayout.visible_of(_hud_sel)) else "隐藏"
			"hud_sc:0": label = "小"
			"hud_sc:1": label = "标准"
			"hud_sc:2": label = "大"
		if act.begins_with("hud_sc:") and _hud_sel != "":
			var si: int = clampi(int(act.substr(7)), 0, HudLayout.SCALES.size() - 1)
			on = absf(HudLayout.scale_of(_hud_sel) - float(HudLayout.SCALES[si])) < 0.01
		draw_rect(br, Color(0.56, 0.89, 0.42, 0.20) if on else Color(1, 1, 1, 0.07), true)
		draw_rect(br, Color("8fe36b") if on else Color(1, 1, 1, 0.16), false, 1.2)
		_draw_text_center(label, br, 13.0, Color(0.92, 0.95, 1.0))
	# 6) 状态与提示
	draw_string(font, Vector2(320.0, vp.y - HUD_BAR_H + 34.0), _hud_sel_label(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13.0, Color(0.75, 0.82, 0.94))
	draw_string(font, Vector2(320.0, vp.y - HUD_BAR_H + 56.0),
		"按住模块拖动 · 松手吸附到最近的格子 · 黄框 = 与其他模块重叠",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11.5, Color(0.55, 0.62, 0.74))
	if not ov.is_empty() or _hud_dirty:
		# 两条提示合并成一行 —— 分开画会叠在同一个 y 上，字迹发糊（本项目踩过）
		var notes: Array = []
		if not ov.is_empty():
			notes.append("有模块互相重叠：" + ", ".join(ov))
		if _hud_dirty:
			notes.append("● 有未保存的改动")
		_draw_text_center("   ·   ".join(notes),
			Rect2(0, vp.y - HUD_BAR_H - 32.0, vp.x, 24.0), 13.0, Color("ffd166"))

