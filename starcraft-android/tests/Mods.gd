extends SceneTree

## 模组系统（第十二轮 M3）。
##
## 交付判据：「能装、能启用禁用、能排序；**冻结后写 UNITS 被拒**」。
##
## 这一套守的是本项目**风险最高的一处改动**：`GameData.UNITS` 从 `const`
## 变成了可变字典。它正踩在一条老铁律上 ——
## *「buff 绝不改 `data` —— `data` 是共享字典，改它污染所有同类型单位」*。
## 可变之后任何「顺手改一下 data」的代码都会**跨模组、跨对局**地污染全局，
## 而症状是「有些单位数值莫名其妙」，既不崩也不报错。
## 所以本套的重点不是「模组能装上」，而是**「没装模组时数值一个字节都没变」**。
##
## ⚠️ 三条纪律：
##   1. **模组根目录必须换到 `user://mods_test`**。用真的 `user://mods` 的话，
##      测试造出来的假模组会被后续所有套件的 `scan()` 扫到 ——
##      症状是「别的套件莫名其妙多出几个模组」，完全无从排查。
##   2. **设置文件要备份还原**（本套会写 `mods_state`）。
##   3. **UI 断言必须走真实的 `menu_hit_table()` + `_menu_press()`**，
##      不手工构造 Rect2 —— 手工构造只能验证「我以为的坐标」，
##      验证不了「渲染器实际给出的坐标」。这是 `tests/Menu.gd` 用血换来的
##      （tab 第一版漏了 `stab:` 分支，`_settings_tab` 改得动、玩家点不动）。

const TEST_DIR := "user://mods_test"

## 真机分辨率。理由见 `tests/Menu.gd` 顶部那段 —— headless 下
## `get_viewport_rect()` 是 **1280×1280**（正方形），而真机与全部截图都是
## **1280×720**。**「装不装得下」的断言一律不能用 `get_viewport_rect()`。**
const VP := Vector2(1280.0, 720.0)

## 面板上边界。`_form_metrics` 的 `FORM_HEAD_H`。
const HEAD_H := 104.0

var _pass := 0
var _fail := 0
var _ran := false
var _main: Node = null
## `_menu_press()` **内部用的是 `get_viewport_rect().size`**（没有 vp 参数），
## 而 headless 下那是 1280×1280，不是真机的 1280×720。
## 所以「真实点一下」这类用例必须用这个尺寸取坐标 —— 用 `VP` 取出来的
## 矩形拿到 1280×1280 的表里去命中，会落到**完全不相干的行**上，
## 而断言照样有 PASS 有 FAIL，看起来像逻辑 bug，其实是坐标口径不一致。
## （`tests/Menu.gd` 也是这个套路：按 `vp` 点，按 `DEVICE_SIZES` 验尺寸。）
var _vp := Vector2(1280.0, 720.0)
var _cfg_backup := ""
var _cfg_existed := false

# ---------------------------------------------------------------- 测试脚手架

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

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)

func _write(p: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()

## 造一张**真的** PNG。不能只写个空文件 ——
## `GenTex._load_png()` 走 `Image.load_from_file()`，空文件返回 null，
## 断言「皮肤读得到」就会假通过成「读不到」。
func _write_png(p: String, col: Color) -> bool:
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var img := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(col)
	return img.save_png(p) == OK

## 递归删目录。先收集再删 —— 边遍历边删会让 `get_next()` 跳过条目。
##
## ⚠️ `DirAccess.open("user://…")` 在本引擎下**恒返回 null**（见 `Mods.open_dir()`），
##    不 globalize 的话这个函数会**静默地什么都不删** —— 而症状是
##    「上一组用例造的模组还在」，看起来像扫描逻辑坏了。
func _wipe_dir(p: String) -> void:
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
		DirAccess.remove_absolute(_abs(p + "/" + String(f)))
	for sub in dirs:
		_wipe_dir(p + "/" + String(sub))
	DirAccess.remove_absolute(_abs(p))

## 造三个假模组：
##   alpha —— 正常，带皮肤 + 改 marine.hp
##   beta  —— 正常，也改 marine.hp（与 alpha **冲突**）+ 改 marine.speed
##   gamma —— **缺 mod.json**，但有皮肤（用来验「出错的模组整份不生效」）
##
## 加载顺序 alpha → beta → gamma，所以 **beta 赢**（后加载的覆盖先加载的）。
func _build_fake_mods() -> void:
	_write(TEST_DIR + "/alpha/mod.json",
		'{"name":"阿尔法","author":"aaa","version":"1.0","desc":"测试模组"}')
	_write_png(TEST_DIR + "/alpha/skins/u_marine.png", Color(1, 0, 0, 1))
	_write(TEST_DIR + "/alpha/data/units.json", '{"marine":{"hp":60}}')

	_write(TEST_DIR + "/beta/mod.json",
		'{"name":"贝塔","author":"bbb","version":"2.0"}')
	_write(TEST_DIR + "/beta/data/units.json", '{"marine":{"hp":70,"speed":111.0}}')

	# gamma 故意不写 mod.json，但放一张皮肤 ——
	# 断言「有 error 的模组**连皮肤也不生效**」（不能只跳数据、皮肤照装）
	_write_png(TEST_DIR + "/gamma/skins/u_scv.png", Color(0, 1, 0, 1))

## 把模组目录重设成 n 个最简模组（只用来量面板高度）。
func _set_mod_count(n: int) -> void:
	_wipe_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	for i in range(n):
		_write("%s/m%02d/mod.json" % [TEST_DIR, i], '{"name":"模组%02d"}' % i)
	Mods.scan()
	_main._mods_page = 0

func _marine_hp() -> int:
	return int(GameData.UNITS["marine"]["hp"])

## 应用当前启用状态。等价于 UI 里点一下开关之后发生的事。
func _reapply() -> void:
	Mods.apply_all()

# ---------------------------------------------------------------- 生命周期

func _initialize() -> void:
	print("=============== 模组系统测试 ===============")
	_cfg_existed = FileAccess.file_exists(Settings.PATH)
	if _cfg_existed:
		var f := FileAccess.open(Settings.PATH, FileAccess.READ)
		if f != null:
			_cfg_backup = f.get_as_text()
	# ⚠️ 顺序不能反：`reset_all()` 会把 `_loaded` 置 true，
	#    之后 Main 的 `_ready()` 读设置就不会再去读盘上的玩家配置。
	Settings.reset_all()
	Mods.root_dir = TEST_DIR
	_wipe_dir(TEST_DIR)
	_build_fake_mods()
	# Main 的 `_ready()` 会依次跑 Mods.scan() / apply_all() / freeze()，
	# 也就是**玩家真实的开机流程** —— 这里不手工调，让它自己走一遍。
	var scene: PackedScene = load("res://assets/scripts/Main.tscn")
	_main = scene.instantiate()
	root.add_child(_main)

func _restore_config() -> void:
	if _cfg_existed:
		var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_cfg_backup)
	else:
		if FileAccess.file_exists(Settings.PATH):
			DirAccess.remove_absolute(_abs(Settings.PATH))

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_tests()
	# 收尾：别把假模组留在 user:// 里，也别把数据表留在冻结态。
	_wipe_dir(TEST_DIR)
	Mods.root_dir = "user://mods"
	Mods._reset_for_test()
	GameData.reset_to_base()
	GenTex.skin_overrides.clear()
	_restore_config()
	quit(0 if _fail == 0 else 1)
	return true

# ---------------------------------------------------------------- 用例

func _run_tests() -> void:
	_g1_scan()
	_g2_enable()
	_g3_order()
	_g4_persist()
	_g5_freeze()
	_g6_conflict()
	_g7_skin()
	_g8_ui()
	_g9_fit()
	_g10_positive()
	print("============================================")
	print("  通过 %d / 失败 %d" % [_pass, _fail])

## 1. 扫描与元数据
func _g1_scan() -> void:
	print("-- 1. 扫描与元数据 --")
	_eqi(Mods.list.size(), 3, "扫到 3 个模组目录")
	var ids: Array = []
	for m in Mods.list:
		ids.append(String(m["id"]))
	_ok(ids == ["alpha", "beta", "gamma"], "顺序按 id 字母序（实测 %s）" % str(ids))

	var a := Mods.get_mod("alpha")
	_eqs(String(a["name"]), "阿尔法", "读到 mod.json 的 name")
	_eqs(String(a["author"]), "aaa", "读到 author")
	_eqs(String(a["version"]), "1.0", "读到 version")
	_eqs(String(a["error"]), "", "alpha 没有 error")
	_eqi((a["skins"] as Dictionary).size(), 1, "alpha 扫到 1 张皮肤")
	_ok((a["skins"] as Dictionary).has("u_marine"), "皮肤 key 是去扩展名的 u_marine")

	var g := Mods.get_mod("gamma")
	_eqs(String(g["error"]), "缺少 mod.json", "缺 mod.json 的模组**照样列出**并带 error")
	_eqs(String(g["name"]), "gamma", "缺元数据时名字退回目录名")

	# ★最重要的三条：开机之后数值到底变成什么★
	_eqi(_marine_hp(), 70, "★后加载的赢★ marine.hp = 70（alpha 60 → beta 70）")
	_ok(is_equal_approx(float(GameData.UNITS["marine"]["speed"]), 111.0), "beta 改的 speed 生效")
	_eqi(int(GameData.UNITS["marine"]["damage"]), 12, "★逐字段合并★ 没写的 damage 保持 12")

## 2. 启用 / 禁用
func _g2_enable() -> void:
	print("-- 2. 启用 / 禁用 --")
	_ok(Mods.set_enabled("beta", false), "禁用 beta 成功")
	_reapply()
	_eqi(_marine_hp(), 60, "禁用 beta 后 alpha 的 60 生效")

	_ok(Mods.set_enabled("alpha", false), "禁用 alpha 成功")
	_reapply()
	_eqi(_marine_hp(), 85, "★两个都禁用后回到基础值 85★")

	_ok(not Mods.set_enabled("no_such_mod", true), "不存在的模组返回 false")
	_eqi(Mods.enabled_list().size(), 1, "只剩 gamma 一个「启用」")

	# 复原
	Mods.set_enabled("alpha", true)
	Mods.set_enabled("beta", true)
	_reapply()
	_eqi(_marine_hp(), 70, "复原后回到 70")
	_eqi(Mods.enabled_list().size(), 3, "三个都启用")

## 3. 排序
func _g3_order() -> void:
	print("-- 3. 排序 --")
	_eqi(Mods.index_of("alpha"), 0, "alpha 初始在第 0 位")
	_ok(Mods.move("alpha", 1), "alpha 下移成功")
	_eqi(Mods.index_of("alpha"), 1, "alpha 到第 1 位")
	_reapply()
	_eqi(_marine_hp(), 60, "★顺序一变，赢家就变★ alpha 后加载 → 60")

	_ok(Mods.move("alpha", -1), "alpha 上移回来")
	_reapply()
	_eqi(_marine_hp(), 70, "回到 beta 赢 → 70")

	_ok(not Mods.move("alpha", -1), "已在顶部时上移返回 false（越界）")
	_ok(not Mods.move("gamma", 1), "已在底部时下移返回 false（越界）")
	_ok(not Mods.move("no_such_mod", 1), "不存在的模组返回 false")
	_eqi(Mods.index_of("alpha"), 0, "越界操作没有打乱顺序")

## 4. 持久化
func _g4_persist() -> void:
	print("-- 4. 持久化 --")
	Mods.set_enabled("gamma", false)
	Mods.move("alpha", 1)
	Mods.save_state()
	_ok(Settings.text("mods_state", "") != "", "状态写进了 Settings 的 mods_state 键")

	# 重扫：状态与顺序都要**保留**
	Mods.scan()
	_eqi(Mods.index_of("alpha"), 1, "重扫后顺序保留（alpha 仍在第 1 位）")
	_ok(not bool(Mods.get_mod("gamma")["enabled"]), "重扫后 gamma 仍是禁用")

	# 垃圾输入整份退回
	var before := Mods.to_json()
	_ok(not Mods.from_json("{ 这不是 json"), "非法 JSON 返回 false")
	_eqs(Mods.to_json(), before, "非法输入后状态一个字节没变")

	_ok(Mods.from_json('{"order":["gamma","beta","alpha"],"off":["alpha"]}'),
		"合法 JSON 解析成功")
	var ids: Array = []
	for m in Mods.list:
		ids.append(String(m["id"]))
	_ok(ids == ["gamma", "beta", "alpha"], "order 生效（实测 %s）" % str(ids))
	_ok(not bool(Mods.get_mod("alpha")["enabled"]), "off 里的模组被禁用")
	_ok(Mods.from_json(""), "空字符串视为「没有状态」，返回 true")

	# 复原成 alpha / beta / gamma 全启用
	Mods.from_json('{"order":["alpha","beta","gamma"],"off":[]}')
	_reapply()
	_eqi(_marine_hp(), 70, "复原后 hp 回到 70")

## 5. 冻结机制 —— **本套最重要的一组**
func _g5_freeze() -> void:
	print("-- 5. 冻结机制 --")
	_ok(GameData.is_frozen(), "Main 启动后数据表已冻结")

	# 阳性对照：解冻状态下**必须能写**，否则「冻结后写不进」这条断言是假通过
	# （万一 apply_mod_patch 本身就坏了，两条断言都会 PASS）。
	GameData.reset_to_base()
	_ok(not GameData.is_frozen(), "reset_to_base 解冻")
	_eqi(_marine_hp(), 85, "reset_to_base 把数值还原成基础值")
	_eqi(GameData.apply_mod_patch({"units": {"marine": {"hp": 123}}}), 1, "解冻状态下能写入 1 个字段")
	_eqi(_marine_hp(), 123, "写入真的生效（123）")

	GameData.freeze()
	_eqi(GameData.apply_mod_patch({"units": {"marine": {"hp": 999}}}), -1,
		"★冻结后 apply_mod_patch 返回 -1★")
	_eqi(_marine_hp(), 123, "★冻结后数值没有被改动★")

	# 未知 id：拒绝而不是新建
	GameData.reset_to_base()
	_eqi(GameData.apply_mod_patch({"units": {"no_such_unit": {"hp": 1}}}), 0,
		"未知条目返回 0 个字段（拒绝新建）")
	_ok(not GameData.UNITS.has("no_such_unit"), "未知 id 没有进 UNITS")
	# 形状不对的 patch 不能崩
	_eqi(GameData.apply_mod_patch({"units": "这不是字典"}), 0, "非字典的 patch 被忽略")
	_eqi(GameData.apply_mod_patch({}), 0, "空 patch 返回 0")

	_eqi(GameData.table_of("units").size(), GameData._BASE_UNITS.size(), "table_of 取到的是同一张表")
	_ok(GameData.table_of("nonsense").is_empty(), "未知表名返回空字典")

	# 复原：重新应用模组（会 reset + apply + freeze）
	_reapply()
	_eqi(_marine_hp(), 70, "重新应用后回到 70")
	_ok(GameData.is_frozen(), "重新应用后再次冻结")

## 6. 冲突检测
func _g6_conflict() -> void:
	print("-- 6. 冲突检测 --")
	var cf := Mods.conflicts()
	_ok(cf.has("units/marine/hp"), "检出 units/marine/hp 冲突")
	var names: Array = cf.get("units/marine/hp", [])
	_eqi(names.size(), 2, "冲突方有 2 个")
	_ok(names.has("阿尔法") and names.has("贝塔"), "冲突方是阿尔法与贝塔（实测 %s）" % str(names))
	_ok(not cf.has("units/marine/speed"), "只有 beta 改的 speed 不算冲突")

	_ok(Mods.conflicted_fields_of("alpha").has("units/marine/hp"), "alpha 的冲突字段查得到")
	_ok(Mods.conflicted_fields_of("gamma").is_empty(), "gamma 不参与任何冲突")

	# 禁掉一方，冲突消失 —— 冲突只看**启用中**的模组
	Mods.set_enabled("beta", false)
	_reapply()
	_ok(Mods.conflicts().is_empty(), "禁用 beta 后冲突消失")
	Mods.set_enabled("beta", true)
	_reapply()

## 7. 皮肤覆盖
func _g7_skin() -> void:
	print("-- 7. 皮肤覆盖 --")
	_ok(GenTex.skin_overrides.has("u_marine"), "u_marine 进了皮肤覆盖表")
	var p := String(GenTex.skin_overrides.get("u_marine", ""))
	_ok(p.begins_with(TEST_DIR + "/alpha/"), "皮肤路径指向 alpha（实测 %s）" % p)

	var t := GenTex.load_skin("u_marine")
	_ok(t != null, "★load_skin 真的读到了 PNG★")
	if t != null:
		_ok(t.get_size() == Vector2(8.0, 8.0), "读到的是那张 8×8 的假皮肤（实测 %s）" % str(t.get_size()))

	# gamma 有皮肤但缺 mod.json → 整份不生效（**不能只跳数据、皮肤照装**）
	_ok(not GenTex.skin_overrides.has("u_scv"), "★出错的模组连皮肤也不生效★")

	# 禁用 alpha → 皮肤覆盖表里就该没有它
	Mods.set_enabled("alpha", false)
	_reapply()
	_ok(not GenTex.skin_overrides.has("u_marine"), "禁用 alpha 后皮肤覆盖被清掉")
	Mods.set_enabled("alpha", true)
	_reapply()
	_ok(GenTex.skin_overrides.has("u_marine"), "重新启用后皮肤回来了")

## 8. 模组页 UI —— 走真实命中表 + 真实按下
func _g8_ui() -> void:
	print("-- 8. 模组页 UI --")
	_main.goto_page(_main.Page.MODS)
	_vp = _main.get_viewport_rect().size
	var tb: Array = _main.menu_hit_table(_vp)
	var acts: Array = []
	for m in tb:
		acts.append(String(m.get("act", "")))

	for want in ["mod_toggle:alpha", "mod_up:alpha", "mod_down:alpha",
			"mod_toggle:beta", "mod_up:beta", "mod_down:beta", "mods_rescan"]:
		_ok(acts.has(want), "命中表里有 %s" % want)

	# 「勾选框」与「整行」共用一个 act —— 钉死「整行可点」这个设计。
	# 26px 的勾选框在手机上远低于 48dp 建议值，只能点它的话玩家得瞄着戳。
	var n_toggle := 0
	for a in acts:
		if String(a) == "mod_toggle:alpha":
			n_toggle += 1
	_eqi(n_toggle, 2, "alpha 有 2 个命中区（勾选框 + 整行）")

	# 子命中区互不重叠 —— 重叠的话「点整行」会误触到排序按钮。
	var a_rects: Array = []
	for m in tb:
		if String(m.get("act", "")).begins_with("mod_") and String(m.get("act", "")).ends_with(":alpha"):
			a_rects.append(m["rect"])
	var ov := 0
	for i in range(a_rects.size()):
		for j in range(i + 1, a_rects.size()):
			if (a_rects[i] as Rect2).intersects(a_rects[j] as Rect2):
				ov += 1
	_eqi(ov, 0, "alpha 的 4 个命中区互不重叠")

	# 真实点一下勾选框区域：禁用 beta
	_press_act("mod_toggle:beta")
	_ok(not bool(Mods.get_mod("beta")["enabled"]), "★点勾选框真的禁用了 beta★")
	_eqi(_marine_hp(), 60, "★禁用后数值立刻变成 60（不是「勾变了但没生效」）★")

	_press_act("mod_toggle:beta")
	_ok(bool(Mods.get_mod("beta")["enabled"]), "再点一下重新启用")
	_eqi(_marine_hp(), 70, "数值变回 70")

	# 排序按钮
	_press_act("mod_down:alpha")
	_eqi(Mods.index_of("alpha"), 1, "★点下移真的换了顺序★")
	_eqi(_marine_hp(), 60, "顺序变化立刻反映到数值")
	_press_act("mod_up:alpha")
	_eqi(Mods.index_of("alpha"), 0, "点上移换回来")
	_eqi(_marine_hp(), 70, "数值变回 70")

	# 顶部再点上移：不崩、不弹错、顺序不变
	_press_act("mod_up:alpha")
	_eqi(Mods.index_of("alpha"), 0, "已在顶部时点上移，顺序不变")

	# 重新扫描
	_press_act("mods_rescan")
	_eqi(Mods.list.size(), 3, "重新扫描后仍是 3 个")
	_eqi(_marine_hp(), 70, "重新扫描后数值不变")

## 9. 面板不溢出 —— 模组数量是玩家决定的，必须翻页
func _g9_fit() -> void:
	print("-- 9. 面板不溢出 --")
	# 设置页踩过这个坑：12 个设置项排成一条列表，面板算出 858px，
	# 而屏幕只有 720px，底部整块被推出屏幕 —— 而「逐项查在不在屏内」查不出来。
	# 模组的数量更不可控，所以这里**逐个数量验面板本身**。
	for n in [0, 1, 5, 6, 12, 30]:
		_set_mod_count(n)
		var pm: Dictionary = _main._form_metrics(VP, _main._page_def(_main.Page.MODS))
		var p: Rect2 = pm["panel"]
		_ok(p.end.y <= VP.y + 0.5 and p.position.y >= HEAD_H - 0.5,
			"%2d 个模组时面板在屏内（y %.0f→%.0f，屏高 %.0f）" % [n, p.position.y, p.end.y, VP.y])

	# 6 个模组（超一页）时必须有翻页按钮，且只显示 5 行
	_set_mod_count(6)
	var tb: Array = _main.menu_hit_table(VP)
	var ids: Dictionary = {}
	var has_pager := false
	for m in tb:
		var a := String(m.get("act", ""))
		if a == "mods_page":
			has_pager = true
		elif a.begins_with("mod_toggle:"):
			ids[a.substr(11)] = true
	_ok(has_pager, "6 个模组时出现「下一页」按钮")
	_eqi(ids.size(), int(_main.MODS_PER_PAGE), "一页只列 %d 行" % int(_main.MODS_PER_PAGE))

	# 翻一页之后能看到剩下的
	_press_act("mods_page")
	_ok(_main._mods_page == 1, "翻页后页码变 1")
	var ids2: Dictionary = {}
	for m in _main.menu_hit_table(VP):
		var a2 := String(m.get("act", ""))
		if a2.begins_with("mod_toggle:"):
			ids2[a2.substr(11)] = true
	_eqi(ids2.size(), 1, "第 2 页只剩 1 个模组")
	_ok(not ids2.has("m00"), "第 2 页不重复显示第 1 页的模组")

	# 空列表时给的是说明文案，不是空白面板
	_set_mod_count(0)
	var d: Dictionary = _main._page_def(_main.Page.MODS)
	var txt := ""
	for s in d.get("sections", []):
		for it in (s["items"] as Array):
			txt += String((it as Dictionary).get("text", ""))
	_ok(txt.contains("还没有安装任何模组"), "空列表时有说明文案（实测「%s」）" % txt.substr(0, 40))
	_ok(String(d.get("subtitle", "")).contains("mods_test"), "副标题里印出了模组目录的绝对路径")

## 10. 阳性对照 —— 证明上面的断言真的会 FAIL
func _g10_positive() -> void:
	print("-- 10. 阳性对照 --")
	# 10a. 目录清空 → 一切回到基础值
	_wipe_dir(TEST_DIR)
	Mods.scan()
	_eqi(Mods.list.size(), 0, "目录清空后扫到 0 个模组")
	_reapply()
	_eqi(_marine_hp(), 85, "★没有模组时 marine.hp 就是基础值 85★")
	_ok(GenTex.skin_overrides.is_empty(), "★没有模组时皮肤覆盖表是空的★")
	_ok(GameData.is_frozen(), "空模组列表也会冻结（防止运行期被顺手改）")

	# 10b. 造一个**坏 JSON** 的数据文件 → 整份忽略，不崩
	_write(TEST_DIR + "/broken/mod.json", '{"name":"坏数据"}')
	_write(TEST_DIR + "/broken/data/units.json", "{ 这不是 json")
	Mods.scan()
	_eqi(Mods.list.size(), 1, "坏数据模组照样被列出")
	_reapply()
	_eqi(_marine_hp(), 85, "坏 JSON 的 data 被整份忽略（不崩、不改数值）")

	# 10c. 单个模组也能装：证明前面「3 个模组」的结论不是靠巧合
	_write(TEST_DIR + "/broken/data/units.json", '{"marine":{"hp":42}}')
	Mods.scan()
	_reapply()
	_eqi(_marine_hp(), 42, "合法 JSON 生效（42）")

# ---------------------------------------------------------------- 命中辅助

## 在模组页按 act 真实点一下。**走 `_menu_press()`**，不直接调 `_mods_*`。
##
## 坐标必须按 `_vp`（headless 真实视口）取 —— 理由见 `_vp` 的注释。
func _press_act(act: String) -> bool:
	for m in _main.menu_hit_table(_vp):
		if String(m.get("act", "")) == act:
			_main._menu_press((m["rect"] as Rect2).get_center())
			return true
	return false
