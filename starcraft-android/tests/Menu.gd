extends SceneTree

## 菜单页面的无头验证（第十二轮新增）。
##
## 为什么需要这一套：菜单从「一层平铺」变成「五页 + 通用表单渲染器」之后，
## 「点了没反应」的失败面一下变大了 —— 一个设置项要同时改
## 页面描述 / 排版 / 命中 / 写盘 / 应用**五处**，漏任何一处都是静默失效。
##
## ⚠️ 一律通过 `menu_hit_table()` 取坐标再走真实的 `_menu_press()`，
##    不手工构造 Rect2 —— 手工构造只能验证「我以为的坐标」，
##    验证不了「渲染器实际给出的坐标」。

## 真机分辨率。
##
## ⚠️⚠️ 这张表是这一套测试里**最重要的一段**。
##    实测 headless 下 `get_viewport_rect()` 返回的是 **1280×1280**（正方形），
##    而 project.godot 写的是 1280×720、shots/ 下 24 张截图也全是 1280×720。
##    设置页面板当初算出来 858px 高、在 720 屏上被切掉一半，
##    而 46 条断言全绿 —— 根因就是测试量的是那个虚高的 1280。
##
##    `stretch/mode = canvas_items` + 默认 `aspect = keep` ⇒
##    **真机上逻辑视口恒为 1280×720**，所以 1280×720 是唯一的硬要求。
##    其余几档都是**比基准更高**的（平板 / 将来若改成 `aspect = expand`），
##    这是唯一可能自然发生的方向。
##
## 📌 已知缺口（仍未修）：**矮于 720 的屏幕装不下局域网页**。
##    实测 1024×600 时局域网页面板高 **566**、y 夹到 104、底边 670 > 600。
##    行高 46 已是触控下限；要支持矮屏得加滚动或砍掉分组标题 ——
##    属于 M2 之后的事。这里**不写一条假装通过的断言**，把缺口如实记下来。
##
##    （M4b 把局域网页从 4 个分组 6 行改成 3 个分组 8 行：
##      1280×720 上面板 566 / 底边 670，比改造前的 613 更靠下但仍有 50px 余量。）
const DEVICE_SIZES := [
	Vector2(1280, 720),    # ★硬要求★ 项目基准 + 全部截图的尺寸
	Vector2(1280, 800),    # 4:3 平板
	Vector2(1920, 1080),   # 1080p
	Vector2(2400, 1080),   # 长条全面屏
	Vector2(2560, 1600),   # 大平板
]

var _pass := 0
var _fail := 0
var _ran := false
var _main: Node = null
## 玩家真实配置的备份 —— 下面要测持久化，会写 user://settings.cfg。
var _cfg_backup := ""
var _cfg_existed := false

func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] ", label)
	else:
		_fail += 1
		print("  [FAIL] ", label)

func _sz_label(v: Vector2) -> String:
	return "%d×%d" % [int(v.x), int(v.y)]

## 某一页要遍历的分类。只有设置页有 tab，其余页返回一个占位值。
func _tabs_of(p: int) -> Array:
	if p == _main.Page.SETTINGS:
		return _main.SETTINGS_TABS
	return ["-"]

## 切到某个分类。占位值 "-" 表示该页没有 tab，什么都不做。
func _use_tab(name: String) -> void:
	if name == "-":
		return
	_main._settings_tab = name

func _initialize() -> void:
	print("=============== 菜单页面测试 ===============")
	var scene: PackedScene = load("res://assets/scripts/Main.tscn")
	_main = scene.instantiate()
	root.add_child(_main)
	_cfg_existed = FileAccess.file_exists(Settings.PATH)
	if _cfg_existed:
		var f := FileAccess.open(Settings.PATH, FileAccess.READ)
		if f != null:
			_cfg_backup = f.get_as_text()

## 测试会写设置文件，跑完必须还回去 —— 否则跑一次回归就把玩家的配置冲了。
func _restore_config() -> void:
	if _cfg_existed:
		var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_cfg_backup)
	else:
		var abs_p := ProjectSettings.globalize_path(Settings.PATH)
		if FileAccess.file_exists(Settings.PATH):
			DirAccess.remove_absolute(abs_p)

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	Settings.reset_all()
	_main._apply_settings()
	_run_tests()
	_restore_config()
	quit(0 if _fail == 0 else 1)
	return true

## 在设置页找到 key == value 的那个选项，真实点一下。找不到返回 false。
func _press_setting(vp: Vector2, key: String, value: String) -> bool:
	for m in _main.menu_hit_table(vp):
		if String(m.get("key", "")) == key and String(m.get("value", "")) == value:
			_main._menu_press((m["rect"] as Rect2).get_center())
			return true
	return false

## 找到 key 对应的那一项（开关 / 滑块 / 文本），真实点一下。
func _press_key(vp: Vector2, key: String) -> bool:
	for m in _main.menu_hit_table(vp):
		if String(m.get("key", "")) == key:
			_main._menu_press((m["rect"] as Rect2).get_center())
			return true
	return false

func _row_of(vp: Vector2, key: String) -> Rect2:
	for m in _main.menu_hit_table(vp):
		if String(m.get("key", "")) == key:
			return m["rect"]
	return Rect2()

func _rect_of_act(vp: Vector2, act: String) -> Rect2:
	for m in _main.menu_hit_table(vp):
		if String(m.get("act", "")) == act:
			return m["rect"]
	return Rect2()

## 切到设置页的某个分类。
##
## ⚠️ 走真实的 `_menu_press`，不直接改 `_settings_tab` ——
##    直接改只能验证「我以为的切页方式」，验证不了 tab 到底点不点得到。
##    第十二轮改 tab 化的第一版就漏了 `stab:` 分支，`_settings_tab` 改得动、
##    玩家点不动，只有走真实命中才抓得出来。
func _goto_tab(vp: Vector2, name: String) -> bool:
	if _main.current_page() != _main.Page.SETTINGS:
		_main.goto_page(_main.Page.SETTINGS)
	var r := _rect_of_act(vp, "stab:" + name)
	if r.size.x <= 0.0:
		return false
	_main._menu_press(r.get_center())
	return _main._settings_tab == name

func _run_tests() -> void:
	var vp: Vector2 = _main.get_viewport_rect().size
	print("  视口 %s" % vp)

	var pages := [_main.Page.HOME, _main.Page.SINGLE, _main.Page.LAN,
		_main.Page.SETTINGS, _main.Page.MODS]
	var names := ["首页", "单人游戏", "局域网", "设置", "模组"]

	# ── 1. 五页都有标题 ──
	var no_title := []
	for i in range(pages.size()):
		var d: Dictionary = _main._page_def(pages[i])
		if String(d.get("title", "")) == "":
			no_title.append(names[i])
	_ok(no_title.is_empty(), "五个页面都有标题（缺 %s）" % str(no_title))

	# ── 2. 首页四个入口 ──
	_main.goto_page(_main.Page.HOME)
	var home: Array = _main.menu_hit_table(vp)
	_ok(home.size() == 4, "首页有 4 个入口（实测 %d）" % home.size())
	var acts := []
	var has_back := false
	for m in home:
		acts.append(String(m.get("act", "")))
		if String(m.get("act", "")) == "back":
			has_back = true
	var miss := []
	for w in ["goto:single", "goto:lan", "goto:settings", "goto:mods"]:
		if not acts.has(w):
			miss.append(w)
	_ok(miss.is_empty(), "四个入口是单人 / 局域网 / 设置 / 模组（缺 %s）" % str(miss))
	_ok(not has_back, "首页没有返回键")

	# ── 3. 每页的可点项都在屏幕内（★按真机分辨率★）──
	#    「画得出来但点不到」是触屏最容易犯的错，而且不会报错。
	#
	#    ⚠️⚠️ 必须**显式传真机分辨率**，不能只验 headless 的视口。
	#       实测：headless 下 `get_viewport_rect()` 返回的是 **1280×1280**（正方形），
	#       而项目设置 `viewport_width/height = 1280×720`、24 张截图也全是 1280×720。
	#       设置页当初面板高 858px 溢出 720 屏、而 46 条断言全绿，
	#       根因就是测试量的是那个虚高的 1280。
	#       `menu_hit_table(vp)` / `_form_metrics(vp, desc)` 都是纯函数，
	#       直接把分辨率传进去即可 —— 不需要真的去改窗口尺寸。
	for sz in DEVICE_SIZES:
		var bad := []
		for i in range(pages.size()):
			_main.goto_page(pages[i])
			for tb in _tabs_of(pages[i]):
				_use_tab(String(tb))
				for m in _main.menu_hit_table(sz):
					var r: Rect2 = m["rect"]
					if r.position.x < -0.5 or r.position.y < -0.5 \
							or r.end.x > sz.x + 0.5 or r.end.y > sz.y + 0.5:
						bad.append("%s/%s·%s" % [names[i], String(tb),
							String(m.get("act", m.get("key", "?")))])
		_ok(bad.is_empty(), "%s：所有可点项都在屏幕内（越界 %d 个 %s）"
			% [_sz_label(sz), bad.size(), str(bad.slice(0, 5))])

	# ── 3b. 表单面板本身必须装得下 ──
	#    ⚠️ 只查「每个项在屏幕内」是**不够的**：项是按 y 累加排的，
	#       内容一多整块面板就溢出屏幕，而「恢复默认」是按**面板底边**定位的 ——
	#       它会直接跑到屏幕外，一个可点项都查不出来（第 3 组因此全绿）。
	#       实测踩过：设置页 12 项时面板高 858px，屏幕只有 720px。
	for sz in DEVICE_SIZES:
		var over := []
		for i in range(pages.size()):
			if String(_main._page_def(pages[i]).get("layout", "form")) != "form":
				continue   # tiles / single 页没有表单面板
			_main.goto_page(pages[i])
			for tb in _tabs_of(pages[i]):
				_use_tab(String(tb))
				var pv: Rect2 = _main._form_metrics(sz, _main._page_def(pages[i]))["panel"]
				if pv.position.y < -0.5 or pv.end.y > sz.y + 0.5:
					over.append("%s/%s(底边%.0f)" % [names[i], String(tb), pv.end.y])
		_ok(over.is_empty(), "%s：每页表单面板都装得下（超出：%s）" % [_sz_label(sz), str(over)])
	_use_tab(_main.SETTINGS_TABS[0])

	# ── 3c. 面板不许压住标题 / 副标题 ──
	#    副标题基线在 86，标题基线在 60。内容多的页面（局域网）自然高度大，
	#    垂直居中会把它推到 y=85 —— 副标题就被压在面板上边框上。
	#    ⚠️ 这个症状只在**内容多的那一页**出现，设置页永远看不到。
	for sz in DEVICE_SIZES:
		var heads := []
		for i in range(pages.size()):
			if String(_main._page_def(pages[i]).get("layout", "form")) != "form":
				continue
			_main.goto_page(pages[i])
			for tb in _tabs_of(pages[i]):
				_use_tab(String(tb))
				var py: float = (_main._form_metrics(sz, _main._page_def(pages[i]))["panel"] as Rect2).position.y
				if py < 100.0:
					heads.append("%s/%s(y=%.0f)" % [names[i], String(tb), py])
		_ok(heads.is_empty(), "%s：表单面板不压住标题与副标题（%s）" % [_sz_label(sz), str(heads)])
	_use_tab(_main.SETTINGS_TABS[0])

	# ── 3d. 面板底部不许白留一块 ──
	#    底部主按钮区是**按需预留**的：只有声明了 `primary` 的页面才需要 68px。
	#    无条件预留的话，局域网页 / 模组页底部会空出一大块（实测截图可见）。
	#    判据：最后一行底边到面板底边的距离 ≤ 「该页预留的底高 + 40」。
	for sz in DEVICE_SIZES:
		var gaps := []
		for i in range(pages.size()):
			var d: Dictionary = _main._page_def(pages[i])
			if String(d.get("layout", "form")) != "form":
				continue
			_main.goto_page(pages[i])
			for tb in _tabs_of(pages[i]):
				_use_tab(String(tb))
				var pv2: Rect2 = _main._form_metrics(sz, d)["panel"]
				var rows: Array = _main._form_layout(sz, d)
				if rows.is_empty():
					continue
				var last_bottom: float = (rows[rows.size() - 1]["rect"] as Rect2).end.y
				var foot: float = _main.FORM_FOOT_H if d.get("primary", null) != null else 24.0
				if pv2.end.y - last_bottom > foot + 40.0:
					gaps.append("%s/%s(空 %.0f)" % [names[i], String(tb), pv2.end.y - last_bottom])
		_ok(gaps.is_empty(), "%s：面板底部没有白留（%s）" % [_sz_label(sz), str(gaps)])
	_use_tab(_main.SETTINGS_TABS[0])

	# ── 4. 设置页可点项互不重叠 ──
	#    重叠的后果是「后画的那个永远点不到」，而且完全不报错。
	#    ⚠️ 每个分类都要单独查 —— tab 化之后「同一页」不再只有一份布局。
	_main.goto_page(_main.Page.SETTINGS)
	var st: Array = _main.menu_hit_table(vp)
	var overlaps := []
	for a in range(st.size()):
		for b in range(a + 1, st.size()):
			if (st[a]["rect"] as Rect2).intersects(st[b]["rect"] as Rect2):
				overlaps.append("%s×%s" % [
					String(st[a].get("key", st[a].get("act", "?"))),
					String(st[b].get("key", st[b].get("act", "?")))])
	_ok(overlaps.is_empty(), "设置页可点项互不重叠（重叠 %d 组 %s）" % [overlaps.size(), str(overlaps)])
	var ov_tabs := []
	for tb in _main.SETTINGS_TABS:
		_main._settings_tab = String(tb)
		var arr: Array = _main.menu_hit_table(vp)
		var bad := false
		for a in range(arr.size()):
			for b in range(a + 1, arr.size()):
				if (arr[a]["rect"] as Rect2).intersects(arr[b]["rect"] as Rect2):
					bad = true
		if bad:
			ov_tabs.append(String(tb))
	_main._settings_tab = _main.SETTINGS_TABS[0]
	_ok(ov_tabs.is_empty(), "每个设置分类的可点项都不重叠（重叠：%s）" % str(ov_tabs))

	# ── 4b. tab 行不能压住第一行设置项 ──
	#    tab 是画在面板内部的，位置算错就会和「帧率上限」那一行叠在一起 ——
	#    叠了以后 tab 抢不到点击（先登记的反而先命中，所以症状是「点了没反应」）。
	_main.goto_page(_main.Page.SETTINGS)
	#    ⚠️ 显式标注类型：`_main` 是 Node，`_main.xxx()` 的返回值是 Variant，
	#       用 `:=` 会报 `Cannot infer the type`。（这个坑本项目踩过第九次了。）
	var tab_rects: Array = _main._tab_rects(
		_main._form_metrics(vp, _main._page_def(_main.Page.SETTINGS))["panel"])
	var first_row := Rect2()
	for e in _main._form_layout(vp, _main._page_def(_main.Page.SETTINGS)):
		first_row = e["rect"]
		break
	var clash := false
	for tr in tab_rects:
		if (tr as Rect2).intersects(first_row):
			clash = true
	_ok(tab_rects.size() == _main.SETTINGS_TABS.size(),
		"tab 数量与分类数一致（%d）" % tab_rects.size())
	_ok(not clash, "tab 行不压住第一行设置项（tab 底 %.0f / 首行顶 %.0f）"
		% [(tab_rects[0] as Rect2).end.y if tab_rects.size() > 0 else 0.0, first_row.position.y])

	# ── 4c. 分类 tab：五个都能点到、都能切过去 ──
	#    ⚠️ 这条是「tab 化」本身的回归。命中表登记了 tab 但 `_menu_act` 没有
	#       `stab:` 分支的话，点上去**什么都不会发生**，而且不报错。
	_main.goto_page(_main.Page.SETTINGS)
	var tabs_ok := []
	for tb in _main.SETTINGS_TABS:
		if not _goto_tab(vp, String(tb)):
			tabs_ok.append(String(tb))
	_ok(tabs_ok.is_empty(), "五个分类 tab 都能点到并切过去（失败：%s）" % str(tabs_ok))

	# 切 tab 之后显示的内容必须真的换掉 —— 只改高亮不改内容是很像样的假象
	_goto_tab(vp, "音频")
	var audio_keys := []
	for m in _main.menu_hit_table(vp):
		if m.has("key"):
			audio_keys.append(String(m["key"]))
	_ok(audio_keys.has("sfx_on"), "切到「音频」→ 出现音效开关（%s）" % str(audio_keys))
	_ok(not audio_keys.has("max_fps"), "切到「音频」→ 画面项已隐去（%s）" % str(audio_keys))

	# tab 是「换内容」不是「换页」，所以不该进页面栈：
	# 连点 5 个 tab 后按一次返回，必须直接回首页，而不是退 5 次。
	for tb in _main.SETTINGS_TABS:
		_goto_tab(vp, String(tb))
	_main._menu_press(_rect_of_act(vp, "back").get_center())
	_ok(_main.current_page() == _main.Page.HOME,
		"连点 5 个 tab 后按一次返回 → 直接回首页（实际 %d）" % _main.current_page())

	# ── 5. 导航：进得去、退得回 ──
	_main.goto_page(_main.Page.HOME)
	_main._menu_press(_rect_of_act(vp, "goto:single").get_center())
	_ok(_main.current_page() == _main.Page.SINGLE, "点「单人游戏」→ 进入单人页")
	_main._menu_press(_rect_of_act(vp, "back").get_center())
	_ok(_main.current_page() == _main.Page.HOME, "点「返回」→ 回到首页")

	# 页面栈：首页 → 设置 → 返回，应该回首页而不是别处
	_main._menu_press(_rect_of_act(vp, "goto:settings").get_center())
	_ok(_main.current_page() == _main.Page.SETTINGS, "点「设置」→ 进入设置页")
	_main._menu_press(_rect_of_act(vp, "back").get_center())
	_ok(_main.current_page() == _main.Page.HOME, "设置页返回 → 回首页（页面栈生效）")

	# ── 6. 设置项：点了真的改，改了真的作用到运行期 ──
	#    ⚠️ tab 化之后每个项只在**它所属的分类**里出现，先切 tab 再点。
	_main.goto_page(_main.Page.SETTINGS)

	_goto_tab(vp, "画面")
	_ok(_press_setting(vp, "max_fps", "30"), "「画面」里找得到「帧率上限 = 30」")
	_ok(Settings.text("max_fps") == "30", "点「30」→ max_fps = %s" % Settings.text("max_fps"))
	_ok(Engine.max_fps == 30, "帧率上限真的作用到引擎（%d）" % Engine.max_fps)

	_goto_tab(vp, "音频")
	var before := Settings.flag("sfx_on", true)
	_ok(_press_key(vp, "sfx_on"), "「音频」里找得到「音效开关」")
	_ok(Settings.flag("sfx_on", true) != before, "点开关 → 值翻转（%s）" % str(Settings.flag("sfx_on", true)))
	_ok(_main._sfx_on == Settings.flag("sfx_on", true), "音效开关联动到运行期成员")

	# 滑块：点轨道 60% 处
	var row := _row_of(vp, "sfx_volume")
	_ok(row.size.x > 0.0, "「音频」里找得到「音效音量」滑块")
	if row.size.x > 0.0:
		var tr: Rect2 = _main._slider_track(row)
		_main._menu_press(Vector2(tr.position.x + tr.size.x * 0.6, tr.get_center().y))
		_ok(absf(Settings.num("sfx_volume") - 0.6) < 0.03,
			"点音量轨道 60%% 处 → %.2f" % Settings.num("sfx_volume"))
		_ok(absf(_main._sfx_volume - Settings.num("sfx_volume")) < 0.001,
			"音量滑块联动到运行期成员（%.2f）" % _main._sfx_volume)

	# 游戏默认值：改设置要影响「下一局」的初始条件
	_goto_tab(vp, "游戏")
	_ok(_press_setting(vp, "default_difficulty", "hard"), "「游戏」里找得到「默认难度 = 困难」")
	_ok(_main.difficulty == "hard", "改默认难度 → 运行期 difficulty = %s" % _main.difficulty)
	_ok(_press_setting(vp, "default_speed", "2"), "「游戏」里找得到「默认速度 = 2×」")
	_ok(absf(_main.game_speed - 2.0) < 0.001, "改默认速度 → game_speed = %.1f" % _main.game_speed)

	_goto_tab(vp, "操作")
	_ok(_press_setting(vp, "long_press", "0.35"), "「操作」里找得到「长按阈值 = 0.35s」")
	_ok(absf(_main.long_press - 0.35) < 0.001, "改长按阈值 → long_press = %.2f" % _main.long_press)

	# ── 7. 持久化：写盘 → 清内存 → 重读 ──
	Settings.save_all()
	Settings._reset_for_test()
	Settings.load_all()
	_ok(Settings.text("max_fps") == "30", "存盘后重读 max_fps 仍是 30")
	_ok(Settings.text("default_difficulty") == "hard", "存盘后重读 default_difficulty 仍是 hard")
	_ok(absf(Settings.num("long_press") - 0.35) < 0.001, "存盘后重读 long_press 仍是 0.35")

	# ── 8. 恢复默认 ──
	var pr := _rect_of_act(vp, "settings_reset")
	_ok(pr.size.x > 0.0, "设置页有「恢复默认」按钮")
	if pr.size.x > 0.0:
		_main._menu_press(pr.get_center())
		_ok(Settings.text("max_fps") == "60", "「恢复默认」→ max_fps 回到 60")
		_ok(absf(_main.long_press - 0.25) < 0.001,
			"「恢复默认」→ 运行期 long_press 回到 0.25（%.2f）" % _main.long_press)

	# ── 9. 单人页仍然兼容旧接口 ──
	#    第十二轮只是把菜单包了一层，单人页的 12 个选项与开始按钮必须原样可用 ——
	#    tests/Touch.gd 第 14 组就是按这套坐标写的。
	_main.goto_page(_main.Page.SINGLE)
	var single: Array = _main.menu_hit_table(vp)
	var groups := {}
	var has_start := false
	for m in single:
		if m.has("group"):
			var g := String(m["group"])
			groups[g] = int(groups.get(g, 0)) + 1
		if String(m.get("act", "")) == "start":
			has_start = true
	_ok(int(groups.get("race", 0)) == 3 and int(groups.get("diff", 0)) == 3 \
			and int(groups.get("map", 0)) == 3 and int(groups.get("speed", 0)) == 3,
		"单人页仍是 4 组共 12 个选项（%s）" % str(groups))
	_ok(has_start, "单人页有「开始战斗」按钮")

	# ── 10. Settings 自身的健壮性 ──
	#     未登记的键必须报错并返回 fallback —— 静默收下的话，
	#     打错一个键名就会变成「设置了但永远读不回来」，且不报错。
	_ok(Settings.get_v("no_such_key", "FB") == "FB", "读未登记的键返回 fallback")
	Settings.set_v("no_such_key", 1)
	_ok(Settings.get_v("no_such_key", "FB") == "FB", "写未登记的键被拒绝")

	# ── 11. 页面描述里用到的每个 key 都必须在 Settings 里登记 ──
	#     ⚠️ 这条是**结构性**断言：它不测某个具体设置项，而是测
	#        「以后加设置项时有没有漏登记」。漏了的症状是
	#        `get_v()` 每帧报一次错、读回 null、点了没反应 —— 而且
	#        **页面照样画得出来**，只是那一格永远是空的。
	#        实测踩过：局域网页的 `lan_ip` 没登记，截一次图刷了 9 条 ERROR。
	#        有了这条，将来给任何一页加设置项都漏不掉。
	var unreg := []
	for p in pages:
		var d: Dictionary = _main._page_def(p)
		for s in d.get("sections", []):
			for it in (s["items"] as Array):
				var k := String((it as Dictionary).get("key", ""))
				if k != "" and not Settings.DEFAULTS.has(k):
					unreg.append("%s·%s" % [names[pages.find(p)], k])
	_ok(unreg.is_empty(), "所有页面用到的设置键都已登记（未登记：%s）" % str(unreg))

	# ── 12. 未登记的键只报一次错 ──
	#     每帧绘制都会读到未登记的键，不设闸门就是刷屏，
	#     刷屏的后果是「真正的错误被埋掉」—— 比不报错更糟。
	Settings._reset_for_test()
	Settings.get_v("no_such_key", "FB")
	Settings.get_v("no_such_key", "FB")
	_ok(Settings._warned.size() == 1 and Settings._warned.has("no_such_key"),
		"未登记的键只记一次（%d 个）" % Settings._warned.size())

	print("============================================")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
