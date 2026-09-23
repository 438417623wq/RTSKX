extends SceneTree

## HUD 布局（第十二轮 M2）的无头验证。
##
## 核心思路：**把 M2 之前那套硬编码坐标原样抄一份当参照**，逐像素比对新实现。
## 这不是「测试跟着实现写」—— 参照是从旧代码搬过来的常量，改实现不会让它自动通过。
## `tests/Touch.gd` 的 74 条断言是**间接**判据（菜单/卡片在不在面板之上），
## 本套是**直接**判据（每个矩形到底等不等于旧公式）。
##
## ⚠️ 视口一律**显式传真机尺寸**（1280×720 等）。headless 下 `get_viewport_rect()`
##    是 1280×1280 的正方形，用它算「装不装得下」会全绿 —— 本项目最大的假绿事故。

var _pass := 0
var _fail := 0
var _main: Node = null
var _ran := false

const VP := Vector2(1280.0, 720.0)          # 主测视口（与真机 / 全部截图一致）
const VP_TALL := Vector2(1080.0, 2340.0)    # 竖屏：锚点全在下方，最容易出问题
const VP_WIDE := Vector2(2340.0, 1080.0)    # 长条横屏

## 本作地图恒为 64×40 格、CELL = 24 → 世界 1536×960（比例正好 0.625）。
const REF_WORLD := Vector2(1536.0, 960.0)

# ---------------------------------------------------------------- 旧公式参照（M2 之前）
## 下面这些常量是 M2 之前的硬编码值，**照抄**过来当参照。
## 出处：`_panel_rect` / `_minimap_layout` / `_draw_topbar` / `topbar_button_rects` /
##       `build_menu_layout` / `build_info_layout` 的旧实现。
const REF_PANEL_H := 180.0
const REF_TOP_H := 34.0
const REF_MM_W := 172.0
const REF_MM_RATIO := 0.22

func _ref_panel(vp: Vector2) -> Rect2:
	return Rect2(0.0, vp.y - REF_PANEL_H, vp.x, REF_PANEL_H)

func _ref_minimap(vp: Vector2, ws: Vector2) -> Rect2:
	var ratio := ws.y / maxf(1.0, ws.x)
	var w := minf(REF_MM_W, vp.x * REF_MM_RATIO)
	var h := w * ratio
	return Rect2(12.0, vp.y - REF_PANEL_H - h - 12.0, w, h)

func _ref_topbar(vp: Vector2) -> Rect2:
	return Rect2(0.0, 0.0, vp.x, REF_TOP_H)

func _ref_sysbtns(vp: Vector2) -> Dictionary:
	return {
		"pause": Rect2(vp.x - 260.0, 4.0, 52.0, 26.0),
		"speed": Rect2(vp.x - 202.0, 4.0, 56.0, 26.0),
		"help": Rect2(vp.x - 140.0, 4.0, 70.0, 26.0),
		"sfx": Rect2(vp.x - 64.0, 4.0, 56.0, 26.0),
	}

func _ref_build_menu(vp: Vector2, menu_w: float, menu_h: float) -> Rect2:
	return Rect2(vp.x - 12.0 - menu_w, vp.y - REF_PANEL_H - 8.0 - menu_h, menu_w, menu_h)

# ---------------------------------------------------------------- 工具

func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] ", label)
	else:
		_fail += 1
		print("  [FAIL] ", label)

func _eqr(a: Rect2, b: Rect2, label: String) -> void:
	var same := absf(a.position.x - b.position.x) < 0.01 and absf(a.position.y - b.position.y) < 0.01 \
		and absf(a.size.x - b.size.x) < 0.01 and absf(a.size.y - b.size.y) < 0.01
	_ok(same, "%s（实测 %.1f,%.1f %.1fx%.1f / 旧 %.1f,%.1f %.1fx%.1f）"
		% [label, a.position.x, a.position.y, a.size.x, a.size.y,
			b.position.x, b.position.y, b.size.x, b.size.y])

func _eqf(a: float, b: float, label: String) -> void:
	_ok(absf(a - b) < 0.01, "%s（实测 %.2f / 期望 %.2f）" % [label, a, b])

# ---------------------------------------------------------------- 配置备份

var _cfg_backup := ""
var _cfg_existed := false
const CFG_PATH := "user://settings.cfg"

func _backup_cfg() -> void:
	_cfg_existed = FileAccess.file_exists(CFG_PATH)
	if _cfg_existed:
		var f := FileAccess.open(CFG_PATH, FileAccess.READ)
		if f != null:
			_cfg_backup = f.get_as_text()
			f.close()

func _restore_cfg() -> void:
	if _cfg_backup != "":
		var f := FileAccess.open(CFG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_cfg_backup)
			f.close()

# ---------------------------------------------------------------- 生命周期

func _initialize() -> void:
	# ⚠️ 固定种子：`start_game` 会生成地图、布置 AI 落点，都吃全局 RNG。
	seed(20260923)
	print("=============== HUD 布局测试 ===============")
	_backup_cfg()
	Settings.reset_all()
	HudLayout.reset()
	var scene: PackedScene = load("res://assets/scripts/Main.tscn")
	_main = scene.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_main.start_game("terran", "normal")
	_run()
	_restore_cfg()
	print("--------------------------------------------")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	print("============================================")
	quit(0 if _fail == 0 else 1)
	return true

# ================================================================ 测试

func _run() -> void:
	_g1_default_layout()
	_g2_anchors()
	_g3_scale()
	_g4_json()
	_g5_visible_and_derive()
	_g6_editor()
	_g7_positive_control()
	_g8_structure()

# ---------------------------------------------------------------- 1. 默认布局 == 旧硬编码

func _g1_default_layout() -> void:
	print("\n-- 1. 默认布局必须逐像素等于 M2 之前的硬编码坐标")
	HudLayout.reset()
	var ws: Vector2 = _main.world.world_size
	_eqf(ws.x, REF_WORLD.x, "世界宽度就是参照值")
	_eqf(ws.y, REF_WORLD.y, "世界高度就是参照值")

	for vp in [VP, VP_WIDE, VP_TALL]:
		_eqr(_main._panel_rect(vp), _ref_panel(vp), "面板底板 %s" % vp)
		_eqr(_main._mod_rect("minimap", vp), _ref_minimap(vp, ws), "小地图 %s" % vp)
		_eqr(HudLayout.topbar_rect(vp), _ref_topbar(vp), "顶栏底板 %s" % vp)

	var ref_btns := _ref_sysbtns(VP)
	var got_btns: Dictionary = _main.topbar_button_rects(VP)
	for k in ref_btns:
		_eqr(got_btns[k], ref_btns[k], "系统按钮 %s" % k)

	# 三个底行模块的矩形（旧代码里就是这三个数）
	_eqr(_main._mod_rect("info", VP), Rect2(0.0, VP.y - 180.0, 470.0, 48.0), "信息行模块")
	_eqr(_main._mod_rect("queue", VP), Rect2(0.0, VP.y - 129.0, 410.0, 96.0), "编队模块")
	_eqr(_main._mod_rect("cmd", VP), Rect2(VP.x - 632.0, VP.y - 129.0, 620.0, 96.0), "指令区模块")

	# 指令区顶边 = 面板顶边 + 51 —— 旧代码里 `_draw_unit_panel(vp, py + 51.0)`
	_eqf(_main._cmd_top(VP), VP.y - REF_PANEL_H + 51.0, "指令区顶边 = 面板顶边 + 51")
	_eqf(_main._cmd_right(VP), VP.x - 12.0, "指令区右边界 = 屏宽 - 12")

	# 建造菜单：右贴指令区右边界、底贴面板顶边
	var ml: Dictionary = _main.build_menu_layout(VP)
	var origin: Rect2 = ml["origin"]
	var items: Array = ml["items"]
	_eqf(origin.size.x, 4.0 * 96.0 + 3.0 * 6.0 + 16.0, "建造菜单宽度（4 列）")
	_eqf(origin.size.y, float(int(ceil(float(items.size()) / 4.0))) * (84.0 + 6.0) - 6.0 + 16.0,
		"建造菜单高度（%d 条）" % items.size())
	_eqr(origin, _ref_build_menu(VP, origin.size.x, origin.size.y), "建造菜单整体位置")
	_eqf(origin.end.x, _main._cmd_right(VP), "建造菜单右边贴指令区右边")

	# 介绍卡
	var card: Rect2 = _main.build_info_layout(VP)
	var want_x := origin.position.x - 10.0 - 330.0
	if want_x < 10.0:
		want_x = 10.0
	if want_x + 330.0 > VP.x - 10.0:
		want_x = VP.x - 10.0 - 330.0
	var want_y: float = clampf(origin.position.y + origin.size.y - 178.0,
		REF_TOP_H + 10.0, VP.y - REF_PANEL_H - 178.0 - 10.0)
	_eqr(card, Rect2(want_x, want_y, 330.0, 178.0), "建造介绍卡位置")

# ---------------------------------------------------------------- 2. 9 宫格锚点几何

func _g2_anchors() -> void:
	print("\n-- 2. 9 宫格锚点的几何")
	_ok(HudLayout.ANCHORS.size() == 9, "锚点共 9 个（实测 %d）" % HudLayout.ANCHORS.size())
	_eqr(Rect2(HudLayout.anchor_xy("tl", VP), Vector2.ZERO), Rect2(0.0, 0.0, 0.0, 0.0), "锚点 tl = 左上角")
	_eqr(Rect2(HudLayout.anchor_xy("br", VP), Vector2.ZERO), Rect2(VP.x, VP.y, 0.0, 0.0), "锚点 br = 右下角")
	_eqr(Rect2(HudLayout.anchor_xy("mc", VP), Vector2.ZERO), Rect2(VP.x * 0.5, VP.y * 0.5, 0.0, 0.0),
		"锚点 mc = 屏幕正中")
	_eqr(Rect2(HudLayout.anchor_xy("tc", VP), Vector2.ZERO), Rect2(VP.x * 0.5, 0.0, 0.0, 0.0),
		"锚点 tc = 上边中点")
	_eqr(Rect2(HudLayout.anchor_xy("ml", VP), Vector2.ZERO), Rect2(0.0, VP.y * 0.5, 0.0, 0.0),
		"锚点 ml = 左边中点")
	# pivot 与 anchor 同构 —— 两处各写一遍最容易漂，这里钉死
	for a in HudLayout.ANCHORS:
		_eqr(Rect2(HudLayout.pivot_of(a), Vector2.ZERO),
			Rect2(HudLayout.anchor_xy(a, Vector2.ONE), Vector2.ZERO), "pivot 与 anchor 同构：%s" % a)

# ---------------------------------------------------------------- 3. 缩放

func _g3_scale() -> void:
	print("\n-- 3. 三档缩放：只乘尺寸，offset 不跟着漂")
	HudLayout.reset()
	# tl 锚点：pivot = (0,0)，位置只由 offset 决定 —— 换缩放不该动它
	HudLayout.set_mod("cmd", {"anchor": "tl", "ox": 100.0, "oy": 50.0, "scale": 1.0})
	var r1: Rect2 = _main._mod_rect("cmd", VP)
	_eqf(r1.position.x, 100.0, "缩放前 x")
	_eqf(r1.position.y, 50.0, "缩放前 y")
	for s in [0.85, 1.15]:
		HudLayout.set_mod("cmd", {"scale": s})
		var r2: Rect2 = _main._mod_rect("cmd", VP)
		_eqf(r2.position.x, 100.0, "scale=%.2f 时 x 不漂" % s)
		_eqf(r2.position.y, 50.0, "scale=%.2f 时 y 不漂" % s)
		_eqf(r2.size.x, 620.0 * s, "scale=%.2f 时宽度 = 620 × %.2f" % [s, s])
		_eqf(r2.size.y, 96.0 * s, "scale=%.2f 时高度 = 96 × %.2f" % [s, s])
	# br 锚点：pivot = (1,1)，尺寸变了位置必须按 pivot 补偿，否则右下角会离开屏幕角
	HudLayout.set_mod("cmd", {"anchor": "br", "ox": -12.0, "oy": -33.0, "scale": 1.0})
	_eqf(_main._mod_rect("cmd", VP).end.x, VP.x - 12.0, "br 锚点：右边缘 = 屏宽 - 12")
	HudLayout.set_mod("cmd", {"scale": 1.15})
	_eqf(_main._mod_rect("cmd", VP).end.x, VP.x - 12.0, "缩放后右边缘仍在屏宽 - 12")
	HudLayout.reset()

# ---------------------------------------------------------------- 4. JSON 往返与鲁棒性

func _g4_json() -> void:
	print("\n-- 4. 布局序列化：往返 + 垃圾输入整份退回默认")
	HudLayout.reset()
	_ok(not HudLayout.is_modified(), "刚重置时 is_modified() = false")
	HudLayout.set_mod("cmd", {"anchor": "mc", "ox": -30.0, "oy": 12.0, "scale": 1.15})
	HudLayout.set_mod("minimap", {"visible": false})
	_ok(HudLayout.is_modified(), "改过之后 is_modified() = true")
	var s := HudLayout.to_json()
	HudLayout.reset()
	_ok(not HudLayout.is_modified(), "reset 后回到未修改")
	_ok(HudLayout.from_json(s), "from_json 解析成功")
	_eqf(HudLayout.scale_of("cmd"), 1.15, "往返后 cmd 缩放保持")
	_ok(HudLayout.anchor_of("cmd") == "mc", "往返后 cmd 锚点保持（%s）" % HudLayout.anchor_of("cmd"))
	_eqf(HudLayout.offset_of("cmd").x, -30.0, "往返后 cmd ox 保持")
	_ok(not HudLayout.visible_of("minimap"), "往返后 minimap 仍是隐藏")

	# 垃圾输入：整份退回默认，不能留半份（半份的症状是「有几个模块位置莫名其妙」）
	HudLayout.set_mod("cmd", {"anchor": "br", "ox": -99.0, "oy": -99.0})
	_ok(not HudLayout.from_json("{这不是 JSON"), "垃圾输入返回 false")
	_eqf(HudLayout.offset_of("cmd").x, float(HudLayout.DEFAULTS["cmd"]["ox"]), "垃圾输入后整份退回默认")
	_ok(HudLayout.from_json(""), "空串返回 true")
	_ok(not HudLayout.is_modified(), "空串 = 用默认布局")
	_ok(not HudLayout.from_json("[1,2,3]"), "顶层不是字典也返回 false")
	_ok(not HudLayout.is_modified(), "顶层不是字典时整份退回默认")

	# 未知锚点被拒（否则配置文件被手改一下就整块飞走）
	HudLayout.reset()
	HudLayout.from_json('{"cmd":{"anchor":"xx"}}')
	_ok(HudLayout.anchor_of("cmd") == "br", "未知锚点被拒，仍是 br（%s）" % HudLayout.anchor_of("cmd"))
	# 缩放只认三档 —— 0.3 会破触控下限
	HudLayout.from_json('{"cmd":{"scale":0.3}}')
	_eqf(HudLayout.scale_of("cmd"), 0.85, "0.3 被吸附到最低档 0.85")
	HudLayout.from_json('{"cmd":{"scale":9.0}}')
	_eqf(HudLayout.scale_of("cmd"), 1.15, "9.0 被吸附到最高档 1.15")
	HudLayout.reset()

# ---------------------------------------------------------------- 5. 隐藏与底板派生

func _g5_visible_and_derive() -> void:
	print("\n-- 5. 隐藏模块 / 底板派生")
	HudLayout.reset()
	_ok(_main._mod_rect("info", VP).size.x > 0.0, "默认 info 可见")
	HudLayout.set_mod("info", {"visible": false})
	_ok(_main._mod_rect("info", VP).size.x <= 0.0, "隐藏后 _mod_rect 返回空矩形")
	HudLayout.set_mod("info", {"visible": true})

	# 面板底板取三个底行模块里最靠上的那条边
	HudLayout.reset()
	_eqf(_main._panel_rect(VP).position.y, VP.y - 180.0, "默认面板顶边 = info 顶边")
	# info 挪到右下角（比 queue / cmd 都低）→ 面板顶边改由 queue 决定
	HudLayout.set_mod("info", {"anchor": "br", "ox": -12.0, "oy": -12.0})
	_eqf(_main._panel_rect(VP).position.y, VP.y - 129.0, "info 挪到更下方后面板顶边 = queue 顶边")
	HudLayout.set_mod("queue", {"anchor": "br", "ox": -12.0, "oy": -12.0})
	_eqf(_main._panel_rect(VP).position.y, VP.y - 129.0, "queue 也挪走后 = cmd 顶边")
	# ⚠️ 判据是**锚点**不是位置：模块还在屏幕下半部但锚点改成顶行的话，
	#    它就不再参与底板推导了（否则玩家把指令区拖到上半屏，底板会拉成半屏高）。
	HudLayout.set_mod("info", {"anchor": "tr", "ox": -12.0, "oy": 12.0})
	HudLayout.set_mod("queue", {"anchor": "tr", "ox": -12.0, "oy": 60.0})
	HudLayout.set_mod("cmd", {"anchor": "tr", "ox": -12.0, "oy": 12.0})
	_ok(_main._panel_rect(VP).size.y <= 0.0, "三个底行模块全改成顶行锚点后不再画底板")

	# 夹取：模块被拖到屏幕上半部时，底板不许长成半屏高把战场盖死
	HudLayout.reset()
	HudLayout.set_mod("info", {"anchor": "bl", "ox": 0.0, "oy": -500.0})
	_eqf(_main._panel_rect(VP).position.y, VP.y * 0.40, "极端摆放时底板顶边被夹到 40% 处")

	# 顶栏底板同理
	HudLayout.reset()
	_eqf(HudLayout.topbar_rect(VP).size.y, 34.0, "默认顶栏高 34")
	HudLayout.set_mod("res", {"visible": false})
	HudLayout.set_mod("sysbtns", {"visible": false})
	_ok(HudLayout.topbar_rect(VP).size.y <= 0.0, "两个顶行模块都隐藏后不画顶栏底板")
	# 系统按钮隐藏时命中表必须为空 —— 否则会留下四个点不到的鬼影按钮
	_ok(_main.topbar_button_rects(VP).is_empty(), "系统按钮隐藏后命中表为空")
	HudLayout.reset()

# ---------------------------------------------------------------- 6. 编辑模式

func _g6_editor() -> void:
	print("\n-- 6. HUD 编辑模式")
	HudLayout.reset()
	_main._start_hud_edit()
	_ok(_main._hud_edit, "进入编辑模式")

	# 默认布局必须零重叠 —— 否则玩家一进来就看到黄框，以为本来就坏了
	_ok(_main.hud_edit_overlaps(VP).is_empty(),
		"默认布局零重叠（实测 %s）" % str(_main.hud_edit_overlaps(VP)))

	# 工具栏三个按钮都在屏内、互不重叠
	var tbl: Array = _main.hud_edit_hit_table(VP)
	_ok(tbl.size() == 3, "未选中模块时工具栏只有三个按钮（实测 %d）" % tbl.size())
	var all_in := true
	var no_overlap := true
	for e in tbl:
		var r: Rect2 = e["rect"]
		if r.position.x < 0.0 or r.end.x > VP.x or r.position.y < 0.0 or r.end.y > VP.y:
			all_in = false
	for i in range(tbl.size()):
		for j in range(i + 1, tbl.size()):
			if (tbl[i]["rect"] as Rect2).intersects(tbl[j]["rect"]):
				no_overlap = false
	_ok(all_in, "工具栏按钮全在屏内")
	_ok(no_overlap, "工具栏按钮互不重叠")

	# 选中模块 → 属性区出现（隐藏 + 三档缩放）
	_main._hud_sel = "cmd"
	var tbl2: Array = _main.hud_edit_hit_table(VP)
	_ok(tbl2.size() == 7, "选中模块后多出四个属性按钮（实测 %d）" % tbl2.size())
	var acts := []
	for e in tbl2:
		acts.append(String(e["act"]))
	_ok(acts.has("hud_vis") and acts.has("hud_sc:0") and acts.has("hud_sc:1") and acts.has("hud_sc:2"),
		"属性区含 隐藏 + 小/标准/大")

	# 拖动：按下 → 拖动 → 松手，模块应跟手并吸附
	_main._hud_sel = ""
	var before: Rect2 = _main._hud_rect("cmd", VP)
	var grab := before.position + Vector2(20.0, 20.0)
	_main._hud_edit_touch(0, grab, true, VP)
	_ok(_main._hud_sel == "cmd", "按下模块会选中它（%s）" % _main._hud_sel)
	_ok(_main._hud_drag == "cmd", "按下模块进入拖动状态")
	# 拖到屏幕左上角
	var target := Vector2(40.0, 40.0)
	_main._hud_edit_drag(target, VP)
	var mid: Rect2 = _main._hud_rect("cmd", VP)
	_eqf(mid.position.x, 20.0, "拖动跟手：抓在模块内 +20 处，拖到 x=40 时左上角落在 20")
	_main._hud_edit_touch(0, target, false, VP)
	_ok(_main._hud_drag == "", "松手后退出拖动状态")
	var after: Rect2 = _main._hud_rect("cmd", VP)
	_ok(HudLayout.anchor_of("cmd") == "tl", "拖到左上角后吸附到 tl（实测 %s）" % HudLayout.anchor_of("cmd"))
	_eqf(after.position.x, 12.0, "吸附后贴左边距 12")
	_eqf(after.position.y, 12.0, "吸附后贴上边距 12")
	_ok(after.position.distance_to(before.position) > 100.0, "模块确实被搬走了")

	# 拖到右下角 → br
	_main._hud_edit_touch(0, after.get_center(), true, VP)
	_main._hud_edit_drag(Vector2(VP.x - 40.0, VP.y - 40.0), VP)
	_main._hud_edit_touch(0, Vector2(VP.x - 40.0, VP.y - 40.0), false, VP)
	_ok(HudLayout.anchor_of("cmd") == "br", "拖到右下角后吸附到 br（实测 %s）" % HudLayout.anchor_of("cmd"))
	_eqf(_main._hud_rect("cmd", VP).end.x, VP.x - 12.0, "吸附后右边距 12")
	_eqf(_main._hud_rect("cmd", VP).end.y, VP.y - 12.0, "吸附后下边距 12")

	# 隐藏 / 显示
	_main._hud_sel = "minimap"
	_main._hud_act("hud_vis")
	_ok(not HudLayout.visible_of("minimap"), "属性区「隐藏」生效")
	_main._hud_act("hud_vis")
	_ok(HudLayout.visible_of("minimap"), "再点一次恢复显示")

	# 缩放三档
	_main._hud_act("hud_sc:0")
	_eqf(HudLayout.scale_of("minimap"), 0.85, "切到「小」= 0.85")
	_main._hud_act("hud_sc:2")
	_eqf(HudLayout.scale_of("minimap"), 1.15, "切到「大」= 1.15")
	_main._hud_act("hud_sc:1")
	_eqf(HudLayout.scale_of("minimap"), 1.0, "切回「标准」= 1.0")

	# 取消 = 回滚到盘上的状态
	_main._hud_act("hud_cancel")
	_ok(not _main._hud_edit, "「取消」退出编辑模式")
	_ok(not HudLayout.is_modified(), "「取消」把改动全部回滚")
	_ok(HudLayout.anchor_of("cmd") == "br" and absf(HudLayout.offset_of("cmd").y + 33.0) < 0.01,
		"回滚后 cmd 回到默认锚点与偏移")

	# 保存 = 落盘（不退出），随后取消能读回保存的内容
	_main._start_hud_edit()
	_main._hud_sel = "cmd"
	_main._hud_act("hud_sc:2")
	_main._hud_act("hud_save")
	_ok(not _main._hud_dirty, "保存后未保存标记清零")
	_ok(Settings.text("hud_layout", "") != "", "保存后 settings 里有 hud_layout")
	_ok(FileAccess.file_exists(CFG_PATH), "settings.cfg 已落盘")
	var saved := Settings.text("hud_layout", "")
	# 保存之后继续改，再取消 —— 应该回到**保存过的那一份**，而不是默认
	_main._hud_act("hud_sc:0")
	_eqf(HudLayout.scale_of("cmd"), 0.85, "保存后继续改：现在是 0.85")
	_main._hud_act("hud_cancel")
	_eqf(HudLayout.scale_of("cmd"), 1.15, "取消后回到已保存的 1.15（不是默认 1.0）")
	HudLayout.reset()
	Settings.set_v("hud_layout", "")
	Settings.save_all()

	# 「恢复默认」按钮只改内存不落盘
	_main._start_hud_edit()
	HudLayout.set_mod("cmd", {"scale": 1.15})
	_main._hud_act("hud_reset")
	_eqf(HudLayout.scale_of("cmd"), 1.0, "「恢复默认」把布局还原")
	_ok(_main._hud_dirty, "「恢复默认」之后标记为未保存")
	_main._hud_act("hud_cancel")
	HudLayout.reset()

	# 点空白 = 取消选中（工具栏属性区收起）
	_main._start_hud_edit()
	_main._hud_sel = "cmd"
	_main._hud_edit_touch(0, Vector2(VP.x * 0.5, VP.y * 0.5), true, VP)
	_ok(_main._hud_sel == "", "点空白处取消选中（%s）" % _main._hud_sel)
	_main._hud_edit_touch(0, Vector2(VP.x * 0.5, VP.y * 0.5), false, VP)
	_main._hud_act("hud_cancel")

# ---------------------------------------------------------------- 7. 阳性对照

func _g7_positive_control() -> void:
	print("\n-- 7. 阳性对照：断言真的会失败")
	HudLayout.reset()
	# 把 cmd 的偏移改掉 —— 第 1 组的「逐像素相等」必须立刻失败
	HudLayout.set_mod("cmd", {"ox": 0.0})
	var got: Rect2 = _main._mod_rect("cmd", VP)
	var ref := Rect2(VP.x - 632.0, VP.y - 129.0, 620.0, 96.0)
	_ok(absf(got.end.x - ref.end.x) > 1.0,
		"改掉偏移后与旧公式不再相等（%.1f vs %.1f）—— 证明第 1 组断言在真的比较" % [got.end.x, ref.end.x])
	HudLayout.reset()

	# 手工把两个模块摆重叠 → 重叠检测必须报出来
	HudLayout.set_mod("info", {"anchor": "tl", "ox": 0.0, "oy": 0.0})
	HudLayout.set_mod("res", {"anchor": "tl", "ox": 0.0, "oy": 0.0})
	var ov: Array = _main.hud_edit_overlaps(VP)
	_ok(ov.has("info") and ov.has("res"),
		"手工重叠两个模块后能被检出（%s）—— 证明「默认零重叠」不是因为检测没生效" % str(ov))
	HudLayout.reset()
	_ok(_main.hud_edit_overlaps(VP).is_empty(), "还原后又不重叠了")

# ---------------------------------------------------------------- 8. 结构性

func _g8_structure() -> void:
	print("\n-- 8. 结构性断言")
	var miss_label := []
	var miss_default := []
	for m in HudLayout.MODULES:
		if not HudLayout.LABELS.has(m):
			miss_label.append(m)
		if not HudLayout.DEFAULTS.has(m):
			miss_default.append(m)
	_ok(miss_label.is_empty(), "每个模块都有显示名（缺 %s）" % str(miss_label))
	_ok(miss_default.is_empty(), "每个模块都有默认布局（缺 %s）" % str(miss_default))
	_ok(Settings.DEFAULTS.has("hud_layout"), "Settings 里登记了 hud_layout 键")
	# 默认布局里每个锚点都必须是合法锚点
	var bad := []
	for m in HudLayout.MODULES:
		if not HudLayout.ANCHORS.has(String(HudLayout.DEFAULTS[m]["anchor"])):
			bad.append(m)
	_ok(bad.is_empty(), "默认布局的锚点全部合法（非法 %s）" % str(bad))
	# 默认缩放必须是三档之一
	var bads := []
	for m in HudLayout.MODULES:
		var sc := float(HudLayout.DEFAULTS[m]["scale"])
		if not HudLayout.SCALES.has(sc):
			bads.append(m)
	_ok(bads.is_empty(), "默认缩放全部落在三档内（越界 %s）" % str(bads))
