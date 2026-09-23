extends RefCounted
class_name Settings

## 全局设置：集中定义 + ConfigFile 持久化。
##
## 为什么要有这个文件：设置项原本散落在 Main 的成员变量里
## （`_sfx_volume` / `_sfx_on` / `difficulty` / `map_preset` / `game_speed` /
## `_single_drag_pans` …），关掉游戏就全丢。第十二轮要把它们变成
## 「有默认值、可存可读、能被测试遍历」的一等公民。
##
## ⚠️ 所有键必须在 `DEFAULTS` 里登记。
##    `get_v()` 对未登记的键返回 fallback 并 `push_error` ——
##    少写一个默认值的症状是「设置项点了没反应」，而且**不报错**
##    （读出来是 null，写回去也写不进去）。
##
## ⚠️ 存盘用 `user://settings.cfg`（ConfigFile，Godot 内置）。
##    安卓上落在 `Android/data/<包名>/files/settings.cfg`，卸载即清除。

const PATH := "user://settings.cfg"

## 默认值表。加一个设置项 = 这里加一行 + Main 的页面描述里加一行。
## 只改一处时，`get_v()` 会在控制台报错，不会静默失效。
##
## ⚠️ 只放**真的生效**的项。放一个「有开关但没人读」的装饰项，
##    玩家会当成 bug（点了没反应）—— 那比没有这个开关更糟。
const DEFAULTS := {
	# ---- 画面 ----
	"max_fps": "60",
	"show_fps": false,
	# ---- 音频 ----
	"sfx_on": true,
	"sfx_volume": 0.7,
	# ---- 操作 ----
	"drag_pans": true,
	"long_press": 0.25,
	"minimap_jump": true,
	# ---- 游戏 ----
	"default_difficulty": "normal",
	"default_map": "plateau",
	"default_speed": "1",
	"autopause": false,
	# ---- 联机 ----
	"player_name": "指挥官",
	## 主机地址。M1 只在局域网页**显示**（文本输入随 M4 一起做）。
	## ⚠️ 它必须在表里 —— 否则 `_setting_text("lan_ip")` 每帧报一次错，
	##    一次截图就刷了 9 条，把别的错误埋掉。
	"lan_ip": "",
	# ---- 界面 ----
	## HUD 布局。整份布局序列化成一行 JSON 存在这**一个**键里（见 `HudLayout`）——
	## 每模块 5 个键的话，加一个模块就要改这里，还会出现「只写进去一半」的中间状态。
	## 空字符串 = 用默认布局。
	"hud_layout": "",
	# ---- 模组 ----
	## 模组的启用状态与加载顺序（一行 JSON，见 `Mods`）。
	## 理由同 `hud_layout`：一个键装整份状态，加一个模组时不用改这里。
	"mods_state": "",
}

static var _data: Dictionary = {}
static var _loaded := false
## 已经报过错的键。同一个键只报一次 ——
## 漏登记一个键会在**每帧绘制**里被读到，不设闸门就是刷屏，
## 而刷屏的后果是「真正的错误被埋掉」，比不报错更糟。
static var _warned: Dictionary = {}

## 从磁盘读入。文件不存在（第一次运行）就整份用默认值 —— 不报错。
static func load_all() -> void:
	_data = DEFAULTS.duplicate(true)
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		_loaded = true
		return
	# 逐键读：磁盘上多出来的旧键会被忽略（旧版本残留），少掉的键保持默认值
	# （新版本加了设置项时，老配置文件不会缺项）。
	for k in DEFAULTS.keys():
		if cf.has_section_key("settings", k):
			_data[k] = cf.get_value("settings", k)
	_loaded = true

static func save_all() -> void:
	if not _loaded:
		load_all()
	var cf := ConfigFile.new()
	for k in _data.keys():
		cf.set_value("settings", k, _data[k])
	var err := cf.save(PATH)
	if err != OK:
		push_error("[Settings] 保存失败：%d" % err)

static func get_v(key: String, fallback: Variant = null) -> Variant:
	if not _loaded:
		load_all()
	if not _data.has(key):
		_warn_missing(key)
		return fallback
	return _data[key]

static func set_v(key: String, v: Variant) -> void:
	if not DEFAULTS.has(key):
		_warn_missing(key)
		return
	if not _loaded:
		load_all()
	_data[key] = v

## 报一次就够了。见 `_warned` 的注释。
static func _warn_missing(key: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_error("[Settings] 未登记的键：" + key + "（请在 Settings.DEFAULTS 里补上默认值）")

static func reset_all() -> void:
	_data = DEFAULTS.duplicate(true)
	_loaded = true

# ---- 类型化读取：GDScript 里到处 Variant 转换很啰嗦 ----

static func num(key: String, fallback: float = 0.0) -> float:
	return float(get_v(key, fallback))

static func flag(key: String, fallback: bool = false) -> bool:
	return bool(get_v(key, fallback))

static func text(key: String, fallback: String = "") -> String:
	return String(get_v(key, fallback))

## 测试用：把内存状态清掉，模拟「刚启动还没读盘」。
static func _reset_for_test() -> void:
	_data = {}
	_loaded = false
	_warned.clear()
