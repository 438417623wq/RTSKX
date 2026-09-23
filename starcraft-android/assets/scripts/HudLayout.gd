extends RefCounted
class_name HudLayout

## HUD 模块化布局（第十二轮 M2）。
##
## 为什么要有这个文件：改 M2 之前，HUD 的坐标散在 7 个地方硬编码
## （`_panel_rect` / `_minimap_layout` / `topbar_button_rects` / `build_menu_layout` /
## `_draw_quick_row` / `_draw_group_row` / 指令区），玩家一个都动不了。
##
## 模型：每个模块 = `anchor`（9 宫格）+ `offset`（相对锚点的逻辑像素）
##                        + `scale`（三档）+ `visible`。
##
## 模块矩形 = 屏幕锚点 + offset 定位「模块的 pivot 点」，再按 size 展开：
##     pivot  = 由 anchor 决定（tl→(0,0)、bc→(0.5,1)、br→(1,1) …）
##     rect.position = anchor_xy(anchor, vp) + offset - pivot * size
##
## ⚠️⚠️ **默认值必须精确复现 M2 之前那套硬编码坐标。**
##    `tests/Touch.gd` 的 74 条断言是按那套坐标写的（还直接引用了 `PANEL_H`），
##    默认对不上会红一片，把真正的回归掩盖掉。所以：
##      · `PANEL_H` 常量保留，含义改成「面板顶边的**默认**位置」
##      · 默认布局算出来的每个矩形都必须和旧公式**逐像素相等**
##    `tests/Hud.gd` 里把旧公式原样抄了一份当参照，逐模块比对。

const MODULES := ["res", "sysbtns", "minimap", "info", "queue", "cmd"]

const LABELS := {
	"res": "资源栏",
	"sysbtns": "系统按钮",
	"minimap": "小地图",
	"info": "信息行",
	"queue": "编队 / 快捷",
	"cmd": "指令区",
}

## 9 宫格锚点。字符串而不是枚举 —— 它要能存进配置文件。
const ANCHORS := ["tl", "tc", "tr", "ml", "mc", "mr", "bl", "bc", "br"]

## 缩放只给三档，不给连续值。
##
## 理由：最小按钮是 `BTN_BUILD_W=96 × BTN_BUILD_H=84`，0.85 档是 81.6×71.4，
## 仍高于触控下限；再往下就会破线 —— 46 逻辑像素在 2400×1080 上只有 4.3mm，
## 不到 Android 48dp 建议值（7.6mm）的六成。
const SCALES := [0.85, 1.0, 1.15]

## 默认布局。★这一组数字是被 `tests/Hud.gd` 逐像素钉死的，改之前先看测试。★
##
## offset 是「屏幕锚点 → 模块**被锚点钉住的那个角**」的位移（见 `pivot_of`），
## 所以有些值看起来不直观：
##   · `br` / `bc` / `bl` 的 pivot 在**底边**，oy 是「底边相对屏幕底边」的位移。
##     `cmd` 的 -33 = -(51 + 96 - 180)：它的底边落在屏幕底边上方 33px，
##     换算成顶边就是 `vp.y - 129`（旧代码里的 `面板顶边 + 51`）。
##     `info` 的 -132 = -(180 - 48)：底边落在屏幕底边上方 132px，顶边 = `vp.y - 180`。
##   · `tr` 的 pivot 在**右上角**，所以 `sysbtns` 的 oy = 0 表示「贴着屏幕上边」。
##
## ⚠️ 这一版之前 info / queue 的 oy 按「顶边偏移」填过（-180 / -129），
##    结果两个模块整体上移了 48 / 96px —— `tests/Touch.gd` 的 74 条断言
##    只查「菜单在不在面板之上」，面板自己跟着上移，于是**全部假通过**。
##    这就是 `tests/Hud.gd` 存在的理由：直接比矩形，而不是比相对关系。
const DEFAULTS := {
	"res":     {"anchor": "tl", "ox": 0.0,   "oy": 0.0,    "scale": 1.0, "visible": true},
	"sysbtns": {"anchor": "tr", "ox": -8.0,  "oy": 0.0,    "scale": 1.0, "visible": true},
	"minimap": {"anchor": "bl", "ox": 12.0,  "oy": -192.0, "scale": 1.0, "visible": true},
	"info":    {"anchor": "bl", "ox": 0.0,   "oy": -132.0, "scale": 1.0, "visible": true},
	"queue":   {"anchor": "bl", "ox": 0.0,   "oy": -33.0,  "scale": 1.0, "visible": true},
	"cmd":     {"anchor": "br", "ox": -12.0, "oy": -33.0,  "scale": 1.0, "visible": true},
}

## 模块的**自然尺寸**（scale = 1.0 时）。小地图依赖世界宽高比，单独走 `minimap_size()`。
const SIZES := {
	"sysbtns": Vector2(252.0, 34.0),
	"info": Vector2(470.0, 48.0),
	"queue": Vector2(410.0, 96.0),
	"cmd": Vector2(620.0, 96.0),
}

## 小地图默认宽度上限，以及它占屏幕宽度的比例上限。
const MM_W := 172.0
const MM_W_RATIO := 0.22

static var _mods: Dictionary = {}

# ---------------------------------------------------------------- 状态读写

static func reset() -> void:
	_mods = DEFAULTS.duplicate(true)

static func _ensure() -> void:
	if _mods.is_empty():
		reset()

static func get_mod(m: String) -> Dictionary:
	_ensure()
	if not _mods.has(m):
		push_error("[HudLayout] 未知模块：" + m)
		return {}
	return _mods[m]

static func set_mod(m: String, d: Dictionary) -> void:
	_ensure()
	if not _mods.has(m):
		push_error("[HudLayout] 未知模块：" + m)
		return
	var cur: Dictionary = _mods[m]
	# 逐字段合并：调用方只改一个字段时不用把整份都填上
	for k in ["anchor", "ox", "oy", "scale", "visible"]:
		if d.has(k):
			cur[k] = d[k]
	_mods[m] = cur

static func anchor_of(m: String) -> String:
	return String(get_mod(m).get("anchor", "tl"))

static func scale_of(m: String) -> float:
	return float(get_mod(m).get("scale", 1.0))

static func visible_of(m: String) -> bool:
	return bool(get_mod(m).get("visible", true))

static func offset_of(m: String) -> Vector2:
	var d := get_mod(m)
	return Vector2(float(d.get("ox", 0.0)), float(d.get("oy", 0.0)))

static func is_modified() -> bool:
	_ensure()
	for m in MODULES:
		var a: Dictionary = _mods[m]
		var b: Dictionary = DEFAULTS[m]
		if String(a["anchor"]) != String(b["anchor"]):
			return true
		if absf(float(a["ox"]) - float(b["ox"])) > 0.01:
			return true
		if absf(float(a["oy"]) - float(b["oy"])) > 0.01:
			return true
		if absf(float(a["scale"]) - float(b["scale"])) > 0.01:
			return true
		if bool(a["visible"]) != bool(b["visible"]):
			return true
	return false

# ---------------------------------------------------------------- 几何

## 锚点在屏幕上的坐标。
static func anchor_xy(anchor: String, vp: Vector2) -> Vector2:
	var hx := 0.5
	var hy := 0.5
	if anchor.length() == 2:
		hx = {"l": 0.0, "c": 0.5, "r": 1.0}.get(anchor[1], 0.5)
		hy = {"t": 0.0, "m": 0.5, "b": 1.0}.get(anchor[0], 0.5)
	return Vector2(vp.x * hx, vp.y * hy)

## 模块上被锚点钉住的那个点（0~1 的归一化坐标）。
static func pivot_of(anchor: String) -> Vector2:
	var px := 0.5
	var py := 0.5
	if anchor.length() == 2:
		px = {"l": 0.0, "c": 0.5, "r": 1.0}.get(anchor[1], 0.5)
		py = {"t": 0.0, "m": 0.5, "b": 1.0}.get(anchor[0], 0.5)
	return Vector2(px, py)

## 小地图的自然尺寸。宽度按屏幕比例封顶，高度跟着世界宽高比。
static func minimap_size(vp: Vector2, world_size: Vector2) -> Vector2:
	var ratio := world_size.y / maxf(1.0, world_size.x)
	var w := minf(MM_W, vp.x * MM_W_RATIO)
	return Vector2(w, w * ratio)

## 模块在 scale = 1.0 时的尺寸。
## `world_size` 只给小地图用 —— 它的宽高比跟着地图走。
static func base_size(m: String, vp: Vector2, world_size: Vector2 = Vector2.ZERO) -> Vector2:
	if m == "minimap":
		if world_size == Vector2.ZERO:
			return Vector2(MM_W, MM_W * 0.625)
		return minimap_size(vp, world_size)
	if m == "res":
		# 资源栏横跨屏幕左半 —— 计时与敌基地数画在它的右端，
		# 这样拖动资源栏时它们一起走，而默认位置仍是屏幕正中（和旧代码一致）。
		return Vector2(vp.x * 0.5 + 90.0, 34.0)
	return SIZES.get(m, Vector2(200.0, 40.0))

## 模块矩形。缩放只乘在**尺寸**上，offset 保持原值 ——
## 否则改一下缩放，模块位置也会跟着漂，拖动时手感会突然跳。
static func rect(m: String, vp: Vector2, world_size: Vector2 = Vector2.ZERO) -> Rect2:
	var d := get_mod(m)
	if d.is_empty():
		return Rect2()
	var sc := float(d.get("scale", 1.0))
	var size: Vector2 = base_size(m, vp, world_size) * sc
	var a := anchor_xy(String(d["anchor"]), vp)
	var piv := pivot_of(String(d["anchor"]))
	var pos: Vector2 = a + Vector2(float(d["ox"]), float(d["oy"])) - Vector2(piv.x * size.x, piv.y * size.y)
	return Rect2(pos, size)

# ---------------------------------------------------------------- 面板 / 顶栏底板

## 底部面板底板：从**最靠上的那个底部模块**顶边，一直铺到屏幕底，通栏。
##
## ⚠️ 只在模块仍处于「底行锚点」时才参与推导。玩家把指令区拖到屏幕上半部时，
##    底板不该跟着长成半屏高 —— 那会把战场整块盖住。
static func panel_rect(vp: Vector2) -> Rect2:
	var top := INF
	for m in ["info", "queue", "cmd"]:
		if not visible_of(m):
			continue
		if not String(anchor_of(m)).begins_with("b"):
			continue
		top = minf(top, rect(m, vp).position.y)
	if top == INF:
		return Rect2()
	# 兜底夹一下：底板最多占屏幕下半 60%，免得极端摆放把战场盖死
	top = clampf(top, vp.y * 0.40, vp.y)
	return Rect2(0.0, top, vp.x, vp.y - top)

## 顶部横条底板。规则同上，只是方向相反。
static func topbar_rect(vp: Vector2) -> Rect2:
	var bot := -INF
	for m in ["res", "sysbtns"]:
		if not visible_of(m):
			continue
		if not String(anchor_of(m)).begins_with("t"):
			continue
		bot = maxf(bot, rect(m, vp).end.y)
	if bot == -INF:
		return Rect2()
	bot = clampf(bot, 0.0, vp.y * 0.30)
	return Rect2(0.0, 0.0, vp.x, bot)

# ---------------------------------------------------------------- 持久化

## 整份布局序列化成一行 JSON 存进 `Settings`。
## 用**一个键**而不是每模块 5 个键：加一个模块时不用改 `Settings.DEFAULTS`，
## 也不会出现「只写进去一半」的中间状态。
static func to_json() -> String:
	_ensure()
	return JSON.stringify(_mods)

## 返回是否成功。**解析失败要整份退回默认**，不能留半份 ——
## 半份布局的症状是「有几个模块位置莫名其妙」，玩家根本查不出来。
static func from_json(s: String) -> bool:
	_ensure()
	if s.strip_edges() == "":
		reset()
		return true
	var parsed: Variant = JSON.parse_string(s)
	if typeof(parsed) != TYPE_DICTIONARY:
		reset()
		return false
	var d: Dictionary = parsed
	for m in MODULES:
		if not d.has(m):
			continue
		var e: Variant = d[m]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var dd: Dictionary = e
		var patch := {}
		if dd.has("anchor") and ANCHORS.has(String(dd["anchor"])):
			patch["anchor"] = String(dd["anchor"])
		if dd.has("ox"):
			patch["ox"] = float(dd["ox"])
		if dd.has("oy"):
			patch["oy"] = float(dd["oy"])
		if dd.has("scale"):
			# 缩放只认三档：配置文件被手改过也不会出现 0.3 这种破线值
			var sc := float(dd["scale"])
			var best := 1.0
			for s2 in SCALES:
				if absf(float(s2) - sc) < absf(best - sc):
					best = float(s2)
			patch["scale"] = best
		if dd.has("visible"):
			patch["visible"] = bool(dd["visible"])
		set_mod(m, patch)
	return true

static func save() -> void:
	Settings.set_v("hud_layout", to_json())
	Settings.save_all()

static func load() -> void:
	reset()
	var s := Settings.text("hud_layout", "")
	if s != "":
		from_json(s)

## 测试用：只改内存不写盘。
static func _reset_for_test() -> void:
	reset()
