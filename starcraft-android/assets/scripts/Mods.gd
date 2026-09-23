extends RefCounted
class_name Mods

## 模组系统（第十二轮 M3）。
##
## 三层能力，只做前两层：
##   · **皮肤模组** —— `user://mods/<id>/skins/*.png`，覆盖单位/建筑/地形贴图
##   · **数据模组** —— `user://mods/<id>/data/*.json`，覆盖单位/建筑/升级数值
##   · ~~脚本模组~~ —— **不做**。GDScript 热加载 = 任意代码执行，
##     手机上玩家无法审计模组内容，一个「模组」可以静默读取 `user://` 下的一切。
##     这个口子不值得开。
##
## 合规：模组**不进 APK**，全部由玩家自备 —— 与「自研引擎 + 全程序化美术 +
## 零外部素材」的策略完全一致。
##
## 包结构：
## ```
## user://mods/<mod_id>/
## ├── mod.json          元数据：名称 / 作者 / 版本 / 说明
## ├── skins/*.png       皮肤（可选）
## └── data/*.json       数值覆盖（可选）：units.json / buildings.json / upgrades.json
## ```
##
## 加载顺序：按 `list` 的顺序，**后加载的覆盖先加载的**。
## 冲突检测：两个及以上模组改同一个字段时，在列表里标黄提示。

const MOD_DIR := "user://mods"
const META_FILE := "mod.json"
const SKINS_SUB := "skins"
const DATA_SUB := "data"

## 状态（顺序 + 启用名单）序列化成一行 JSON 存进 `Settings` 的一个键。
## 用一个键而不是每模组一个：加一个模组时不用改 `Settings.DEFAULTS`，
## 也不会出现「只写进去一半」的中间状态。
const STATE_KEY := "mods_state"

## 模组的**根目录**。测试会把它指到别处（`user://mods_test`）来完全隔离 ——
## 否则测试造出来的假模组会被后续所有测试的 `scan()` 扫到，
## 而且症状是「别的套件莫名其妙多出几个模组」，完全无从排查。
static var root_dir := MOD_DIR

## 数据文件名 → `GameData` 里的表名。**按固定文件名映射**，不做自动嗅探 ——
## 自动嗅探遇到字段名巧合时会静默写错表，而模组作者根本查不出来。
const DATA_TABLES := {
	"units": "units",
	"buildings": "buildings",
	"upgrades": "upgrades",
}

## 扫描结果，**按加载顺序**排列。每项：
## `{id, dir, name, author, version, desc, enabled, error, skins, patch}`
static var list: Array = []

## 字段级归属：`"units/marine/hp" -> [mod_id, ...]`。长度 ≥ 2 即冲突。
static var _owners: Dictionary = {}

# ---------------------------------------------------------------- 目录与扫描

## 打开一个目录。
##
## ⚠️⚠️ **必须先 `globalize_path()`** —— 本项目实测（Godot 4.7.2 / Windows）：
##   `DirAccess.open("user://xxx")` **恒定返回 `null`**（错误码 31），而
##   `FileAccess.open("user://xxx")` 完全正常、
##   `DirAccess.open(ProjectSettings.globalize_path("user://xxx"))` 也完全正常。
##   `res://` 路径**不受影响**，只有 `user://` 有这个毛病。
##
##   症状是**静默的**，这才是最要命的地方：
##     · `scan()` 一个模组都扫不到 → 玩家装了模组、列表里空空如也；
##     · `GenTex.ensure_skin_dir()` 连 `user://skins/` 都建不出来
##       （实测那个目录**从来没有存在过**，README 却让玩家把 PNG 放进去）；
##     · 全程**不报任何错**、退出码 0。
##
##   👉 所以本项目**一律不许直接 `DirAccess.open("user://…")`**。
##      `GenTex.gd` 里有一份同样的 helper，改这里记得同步。
static func open_dir(p: String) -> DirAccess:
	return DirAccess.open(ProjectSettings.globalize_path(p))

## 建好模组目录并放一份 README（说明怎么写一个模组）。
## 返回目录的**绝对路径** —— 安卓上 `user://` 是
## `Android/data/<包名>/files/`，玩家用文件管理器找得到，但必须告诉他全路径。
static func ensure_dir() -> String:
	# `make_dir_recursive_absolute` 对 `user://` 是**正常**的（和 `DirAccess.open`
	# 不一样），但统一 globalize 一遍没有代价，也免得以后再踩。
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root_dir))
	var readme := root_dir + "/README.txt"
	if not FileAccess.file_exists(readme):
		var f := FileAccess.open(readme, FileAccess.WRITE)
		if f != null:
			f.store_string(_readme_text())
			f.close()
	return ProjectSettings.globalize_path(root_dir)

## README 内容。**动态列出所有可用的皮肤文件名** —— 模组作者不可能猜到
## `u_marine` / `b_barracks` 这种内部 key，写死在文档里又会随新增单位而过期。
static func _readme_text() -> String:
	var lines: Array = [
		"# 模组目录",
		"",
		"每个模组是一个子目录：",
		"  mods/<你的模组id>/mod.json      元数据（必填）",
		"  mods/<你的模组id>/skins/*.png   皮肤（可选）",
		"  mods/<你的模组id>/data/*.json   数值覆盖（可选）",
		"",
		"mod.json 示例：",
		'  {"name": "我的模组", "author": "someone", "version": "1.0", "desc": "说明"}',
		"",
		"data/ 支持三个固定文件名：units.json / buildings.json / upgrades.json",
		'  例：units.json = {"marine": {"hp": 60}}  ← 只改 hp，其它字段不动',
		"",
		"skins/ 的文件名必须用下面这些 key（不含 .png）：",
	]
	var skin_keys: Array = ["ground", "ground_patch", "rock", "chasm", "mineral", "gas"]
	for id in GameData.UNITS:
		skin_keys.append("u_" + String(id))
	for id in GameData.BUILDINGS:
		skin_keys.append("b_" + String(id))
	lines.append("  " + ", ".join(skin_keys))
	lines.append("")
	lines.append("加载顺序：列表里靠下的模组覆盖靠上的。改完回游戏主菜单即生效。")
	lines.append("")
	return "\n".join(lines)

## 重扫磁盘。**保留**已有的启用状态与顺序（按模组 id 匹配）——
## 否则每次重扫都会把玩家的排序打回默认。
static func scan() -> Array:
	_owners.clear()
	var prev_order: Array = []
	var prev_enabled: Dictionary = {}
	for m in list:
		prev_order.append(String(m["id"]))
		prev_enabled[String(m["id"])] = bool(m["enabled"])
	var state := load_state()
	if not state.is_empty():
		prev_order = state.get("order", prev_order)
		for id in state.get("off", []):
			prev_enabled[String(id)] = false

	var found: Dictionary = {}
	var d := open_dir(root_dir)
	if d != null:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if d.current_is_dir() and not f.begins_with("."):
				var e := _read_mod(f)
				if not e.is_empty():
					found[String(e["id"])] = e
			f = d.get_next()
		d.list_dir_end()

	# 先按上次顺序排，新模组追加到末尾（按 id 字母序，保证结果稳定可测）
	var out: Array = []
	for id in prev_order:
		if found.has(id):
			out.append(found[id])
			found.erase(id)
	var rest: Array = found.keys()
	rest.sort()
	for id in rest:
		out.append(found[id])

	# 应用启用状态：上次记过就用记的，否则默认启用
	for m in out:
		var id := String(m["id"])
		if prev_enabled.has(id):
			m["enabled"] = bool(prev_enabled[id])

	list = out
	_rebuild_owners()
	return list

## 读一个模组目录。**读不出元数据也照样列出**（带 error），
## 而不是静默跳过 —— 静默跳过的症状是「我把模组放进去了但列表里没有」，
## 玩家完全无从下手。
static func _read_mod(dir_name: String) -> Dictionary:
	var base := root_dir + "/" + dir_name
	var e := {
		"id": dir_name, "dir": base,
		"name": dir_name, "author": "", "version": "", "desc": "",
		"enabled": true, "error": "",
		"skins": {}, "patch": {},
	}
	var meta_path := base + "/" + META_FILE
	if not FileAccess.file_exists(meta_path):
		e["error"] = "缺少 " + META_FILE
	else:
		var f := FileAccess.open(meta_path, FileAccess.READ)
		if f == null:
			e["error"] = META_FILE + " 打不开"
		else:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) != TYPE_DICTIONARY:
				e["error"] = META_FILE + " 不是合法 JSON"
			else:
				var md: Dictionary = parsed
				e["name"] = String(md.get("name", dir_name))
				e["author"] = String(md.get("author", ""))
				e["version"] = String(md.get("version", ""))
				e["desc"] = String(md.get("desc", ""))

	# 皮肤：文件名（去 .png）→ 绝对路径
	e["skins"] = _read_skins(base + "/" + SKINS_SUB)
	# 数据：按固定文件名映射到三张表
	e["patch"] = _read_data(base + "/" + DATA_SUB)
	return e

static func _read_skins(dir: String) -> Dictionary:
	var out: Dictionary = {}
	var d := open_dir(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.to_lower().ends_with(".png"):
			out[f.get_basename()] = dir + "/" + f
		f = d.get_next()
	d.list_dir_end()
	return out

static func _read_data(dir: String) -> Dictionary:
	var out: Dictionary = {}
	for fname in DATA_TABLES:
		# ⚠️ `fname` 来自 `for ... in 字典`，是 Variant —— 必须显式 `String()`，
		#    否则 `dir + "/" + fname` 推不出类型（本项目已踩过多次）。
		var p := dir + "/" + String(fname) + ".json"
		if not FileAccess.file_exists(p):
			continue
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			out[String(DATA_TABLES[fname])] = parsed
	return out

# ---------------------------------------------------------------- 查询 / 改状态

static func get_mod(id: String) -> Dictionary:
	for m in list:
		if String(m["id"]) == id:
			return m
	return {}

static func index_of(id: String) -> int:
	for i in range(list.size()):
		if String(list[i]["id"]) == id:
			return i
	return -1

static func set_enabled(id: String, on: bool) -> bool:
	var i := index_of(id)
	if i < 0:
		return false
	var m: Dictionary = list[i]
	m["enabled"] = on
	list[i] = m
	# ⚠️ **必须重算字段归属** —— `_owners` 只统计**启用中**的模组。
	#    漏了这一步的症状是：禁用掉冲突的一方之后，UI 上那个黄框**还挂着**
	#    （「数值冲突 ×1」），玩家照着提示去排查，却怎么都找不到第二个模组。
	#    实测踩过 —— `tests/Mods.gd` 第 6 组钉死。
	_rebuild_owners()
	return true

## 上移 / 下移。`delta` 为 -1 / +1。越界返回 false。
static func move(id: String, delta: int) -> bool:
	var i := index_of(id)
	if i < 0:
		return false
	var j := i + delta
	if j < 0 or j >= list.size():
		return false
	var t: Variant = list[i]
	list[i] = list[j]
	list[j] = t
	# 顺序一变，字段归属就可能变（后加载的赢）—— 必须重算
	_rebuild_owners()
	return true

static func enabled_list() -> Array:
	var out: Array = []
	for m in list:
		if bool(m["enabled"]):
			out.append(m)
	return out

## 字段级冲突。返回 `{字段: [模组名, ...]}`，只列长度 ≥ 2 的。
## 冲突不阻止加载（后加载的赢），只是**要让玩家知道** ——
## 静默覆盖的症状是「装了新模组之后老模组好像没生效」，无从排查。
static func conflicts() -> Dictionary:
	var out: Dictionary = {}
	for key in _owners:
		var ids: Array = _owners[key]
		if ids.size() < 2:
			continue
		var names: Array = []
		for id in ids:
			var m := get_mod(String(id))
			names.append(String(m.get("name", id)) if not m.is_empty() else String(id))
		out[String(key)] = names
	return out

## 某个模组参与的冲突字段名（UI 标黄用）。
static func conflicted_fields_of(id: String) -> Array:
	var out: Array = []
	for key in _owners:
		var ids: Array = _owners[key]
		if ids.size() >= 2 and ids.has(id):
			out.append(String(key))
	return out

static func _rebuild_owners() -> void:
	_owners.clear()
	for m in enabled_list():
		var patch: Dictionary = m["patch"]
		var mid := String(m["id"])
		for table in patch:
			var tbl: Dictionary = patch[table]
			for entry in tbl:
				var fields: Variant = tbl[entry]
				if typeof(fields) != TYPE_DICTIONARY:
					continue
				for k in (fields as Dictionary):
					var key := String(table) + "/" + String(entry) + "/" + String(k)
					if not _owners.has(key):
						_owners[key] = []
					(_owners[key] as Array).append(mid)

# ---------------------------------------------------------------- 应用

## 重载全部启用中的模组。**必须在没有对局的菜单里调** ——
## 它会 `GameData.reset_to_base()`，而正在跑的对局里的单位是读着旧字典构造的。
##
## 返回 `{"skins": 皮肤数, "fields": 字段数, "errors": [文案]}`。
## ⚠️⚠️ **函数名不能叫 `reload`** —— 这是本项目踩到的一个真实陷阱：
##   `Mods` 作为一个 GDScript 资源对象，本身就继承了 `Resource.reload()`
##   （重载脚本资源，返回 `Error`）。静态方法同名时会被它**遮蔽**，
##   调用方拿到的是 `Resource.reload()` 的返回值 `0`，而**函数体一行都不会执行**，
##   也**不报任何错** —— 症状是「我明明写了逻辑，它却什么都没做」。
##   实测排查了很久，最后靠「在函数体第一行 print」才确认没进去。
##   👉 教训：`class_name` 的静态方法名要避开 `Resource` / `Object` 的实例方法
##      （`reload` / `duplicate` / `get` / `set` / `call` / `free` / `to_string` …）。
static func apply_all() -> Dictionary:
	GameData.reset_to_base()
	GenTex.skin_overrides.clear()
	var skins := 0
	var fields := 0
	var errors: Array = []
	for m in list:
		if not bool(m["enabled"]):
			continue
		var mid := String(m["id"])
		if String(m["error"]) != "":
			errors.append("%s：%s" % [String(m["name"]), String(m["error"])])
			continue
		for key in (m["skins"] as Dictionary):
			GenTex.skin_overrides[String(key)] = String((m["skins"] as Dictionary)[key])
			skins += 1
		var n: int = GameData.apply_mod_patch(m["patch"], mid)
		if n < 0:
			errors.append("%s：数据表已冻结，未能应用" % String(m["name"]))
		else:
			fields += n
	GameData.freeze()
	return {"skins": skins, "fields": fields, "errors": errors}

# ---------------------------------------------------------------- 持久化

static func to_json() -> String:
	var order: Array = []
	var off: Array = []
	for m in list:
		order.append(String(m["id"]))
		if not bool(m["enabled"]):
			off.append(String(m["id"]))
	return JSON.stringify({"order": order, "off": off})

## 解析失败**整份退回默认**（全部启用、按目录名排序）——
## 半份状态比没有状态更难查。
static func from_json(s: String) -> bool:
	if s.strip_edges() == "":
		return true
	var parsed: Variant = JSON.parse_string(s)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = parsed
	var order: Array = d.get("order", [])
	var off: Array = d.get("off", [])
	var by_id: Dictionary = {}
	for m in list:
		by_id[String(m["id"])] = m
	var out: Array = []
	for id in order:
		var k := String(id)
		if by_id.has(k):
			out.append(by_id[k])
			by_id.erase(k)
	var rest: Array = by_id.keys()
	rest.sort()
	for k in rest:
		out.append(by_id[k])
	for m in out:
		m["enabled"] = not off.has(String(m["id"]))
	list = out
	_rebuild_owners()
	return true

## 读盘上的状态（**不直接改 `list`** —— `scan()` 要拿它当输入）。
static func load_state() -> Dictionary:
	var s := Settings.text(STATE_KEY, "")
	if s.strip_edges() == "":
		return {}
	var parsed: Variant = JSON.parse_string(s)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed

static func save_state() -> void:
	Settings.set_v(STATE_KEY, to_json())
	Settings.save_all()

# ---------------------------------------------------------------- 测试辅助

## 只改内存不写盘、不清磁盘。测试用。
static func _reset_for_test() -> void:
	list = []
	_owners.clear()
