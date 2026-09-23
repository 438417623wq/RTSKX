extends SceneTree

## 局域网页面 + 屏幕键盘的无头验证（第十三轮 M4b）。
##
## 为什么单独一套：局域网页是**唯一**一页「点了会开网络」的菜单，
## 而它的输入控件（屏幕键盘）是这一页独有的 ——
## 放进 `tests/Menu.gd` 会把那一套的「所有页都能装下」遍历搅浑。
##
## ⚠️ 一律通过 `menu_hit_table()` / `lan_keypad_rects()` 取坐标再走真实的
##    `_menu_press()`，**不手工构造 Rect2** —— 手工构造只能验证
##    「我以为的坐标」，验证不了「渲染器实际给出的坐标」。
##
## ⚠️ 不要在这一套里开真的房间：`_lan_host()` 会绑 `Net.PORT`(27015)，
##    开发机上正好跑着一个真实例时就是「随机失败」。测试统一换端口。
##
## ⚠️ 本套上线时抓到两个真 bug（都**不报错**）：
##    1. `menu_hit_table()` 对 `choice` 行硬读 `e["key"]` —— 「本局选项」那类
##       choice（单人页 / 局域网页）只有 `group`、没有 `key`。抛
##       「Invalid access to property or key 'key'」，而且是**遍历中途**抛的：
##       命中表直接返回空数组，于是「返回键点不到」「整页所有按钮都点不到」。
##       症状看着像布局全错，实际只少了一个默认值。
##    2. `_close_session()` 不清 `world`，`_on_lan_ready()` 又只在 `world == null`
##       时才接管 `session.world` —— 「先开主机房间 → 退出 → 再当客户端加入」
##       会让**客户端全程玩着主机那份旧世界**。见第 9 组最后三条断言。
##
## ⚠️ 状态断言一律走 `_eqst()`，不要 `_eqs(_main.state, ...)` ——
##    `St` 是 int 枚举，喂给 `_eqs()` 会抛「Cannot convert argument 1 from int to
##    String」，**在该函数里它后面所有断言一条都不跑**，却只打一行 SCRIPT ERROR、
##    `_fail` 不动，看着像「全过了」。

const TEST_PORT := 27615
const TEST_PORT2 := 27616

## 布局硬要求：真机逻辑视口恒为 1280×720（见 `tests/Menu.gd` 顶部那段长注释）。
const BASE := Vector2(1280, 720)

var _pass := 0
var _fail := 0
var _ran := false
var _main: Node = null
var _cfg_backup := ""
var _cfg_existed := false

func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] ", label)
	else:
		_fail += 1
		print("  [FAIL] ", label)

func _eqs(a: String, b: String, label: String) -> void:
	_ok(a == b, "%s（期望「%s」，实测「%s」）" % [label, b, a])

func _eqi(a: int, b: int, label: String) -> void:
	_ok(a == b, "%s（期望 %d，实测 %d）" % [label, b, a])

## `Main.state` 是 `St` **int 枚举**，直接喂给 `_eqs()` 会抛
## 「Cannot convert argument 1 from int to String」——
## 而且是在**断言执行前**抛的：那个 `_eqs` 后面的所有断言**一条都不跑**，
## 却只打一行 SCRIPT ERROR、`_fail` 不动，看着像「全过了」。
## 所以状态一律经这个名字表比字符串。
func _st_name() -> String:
	match _main.state:
		_main.St.MENU: return "menu"
		_main.St.LAN_SCAN: return "lan_scan"
		_main.St.LOBBY: return "lobby"
		_main.St.PLAY: return "play"
		_main.St.END: return "end"
	return "?"

func _eqst(b: String, label: String) -> void:
	_eqs(_st_name(), b, label)

func _initialize() -> void:
	print("=============== 局域网页面 / 屏幕键盘测试 ===============")
	var scene: PackedScene = load("res://assets/scripts/Main.tscn")
	_main = scene.instantiate()
	root.add_child(_main)
	_cfg_existed = FileAccess.file_exists(Settings.PATH)
	if _cfg_existed:
		var f := FileAccess.open(Settings.PATH, FileAccess.READ)
		if f != null:
			_cfg_backup = f.get_as_text()

func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_g1_layout()
	_g2_hits()
	_g3_choice_routing()
	_g4_keypad_geometry()
	_g5_ip_input()
	_g6_name_input()
	_g7_modal()
	_g8_join_guard()
	_g9_host_and_leave()
	_g10_address_lines()
	_g11_lobby_actions()
	_g12_scan_page()
	_g13_ingame_ui()
	_restore_cfg()
	print("======================================================")
	print("  通过 %d / 失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

# ---------------------------------------------------------------- 工具

func _vp() -> Vector2:
	return _main.get_viewport_rect().size

## 切到局域网页，并确保没有残留的键盘 / 会话。
func _open_lan() -> void:
	_main._close_session()
	_main.state = _main.St.MENU
	_main._page = _main.Page.LAN
	_main._page_stack.clear()
	_main._lan_input_key = ""
	_main._lan_input_buf = ""
	_main._menu_press_rect = Vector2.ZERO
	_main._btn_primary = Rect2()

func _hits() -> Array:
	return _main.menu_hit_table(_vp())

## 按 act 找命中项。找不到返回空 Rect2。
func _rect_of_act(act: String) -> Rect2:
	for m in _hits():
		if String(m.get("act", "")) == act:
			return m["rect"]
	return Rect2()

## 按 act 点一下（走真实的 `_menu_press`）。
func _tap(act: String) -> bool:
	var r := _rect_of_act(act)
	if r.size == Vector2.ZERO:
		return false
	_main._menu_press(r.get_center())
	return true

## 按 `group` + `value` 点一个选择项。
func _tap_choice(group: String, value: String) -> bool:
	for m in _hits():
		if String(m.get("kind", "")) == "choice" \
				and String(m.get("group", "")) == group \
				and String(m.get("value", "")) == value:
			_main._menu_press((m["rect"] as Rect2).get_center())
			return true
	return false

## 点键盘上的某个键。
func _tap_key(k: String) -> bool:
	for m in _main.lan_keypad_rects(_vp()):
		if String(m["key"]) == k:
			_main._menu_press((m["rect"] as Rect2).get_center())
			return true
	return false

func _type(s: String) -> void:
	for i in range(s.length()):
		_tap_key(s[i])

func _restore_cfg() -> void:
	if _cfg_existed:
		var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_cfg_backup)
	elif FileAccess.file_exists(Settings.PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Settings.PATH))

# ---------------------------------------------------------------- 1. 装得下

func _g1_layout() -> void:
	print("-- 1. 1280×720 上面板装得下 --")
	_open_lan()
	var pm: Dictionary = _main._form_metrics(BASE, _main._page_def(_main.Page.LAN))
	var panel: Rect2 = pm["panel"]
	_ok(panel.position.y >= 100.0, "面板顶边不压副标题（y = %.0f）" % panel.position.y)
	_ok(panel.end.y <= BASE.y,
		"★面板底边在屏内（%.0f ≤ %.0f）★" % [panel.end.y, BASE.y])
	_ok(panel.end.y <= BASE.y - 24.0,
		"★底边留出至少 24px 余量（余 %.0f）★" % (BASE.y - panel.end.y))

	# 每一个可点项都必须在屏内。**只查面板不够** ——
	# 面板是按条目数算的，加一行就会把最后一行挤出去，而面板自己「看起来」没事。
	var outside: Array = []
	for m in _main.menu_hit_table(BASE):
		var r: Rect2 = m["rect"]
		if r.position.y < 0.0 or r.end.y > BASE.y or r.position.x < 0.0 or r.end.x > BASE.x:
			outside.append(String(m.get("act", m.get("label", "?"))))
	_ok(outside.is_empty(), "★所有可点项都在屏内★（越界：%s）" % str(outside))

	# 面板宽度也要能装下
	_ok(panel.size.x <= BASE.x - 40.0, "面板宽度合理（%.0f）" % panel.size.x)

# ---------------------------------------------------------------- 2. 命中表

func _g2_hits() -> void:
	print("-- 2. 局域网页的每个按钮都点得到 --")
	_open_lan()
	# 这一页自己的按钮：整行。
	#
	# ⚠️ 门槛是 **40px**，不是 44 —— 这是**全应用统一**的表单行高
	#    （`_form_layout` 给的行是 `FORM_ROW_H - 6` = 46 - 6 = 40，
	#    那 6px 是行间缝）。所有设置页 / 模组页都这么高，
	#    `tests/Menu.gd` 顶部那段注释也把它记作「触控下限」。
	#    要抬到 44 是**全局设计改动**（会让设置页多出一行的高度），
	#    不属于这一套的范围 —— 这里钉住「没变矮」即可。
	for act in ["lan_name", "lan_host", "lan_ip", "lan_join"]:
		var r := _rect_of_act(act)
		_ok(r.size != Vector2.ZERO and r.size.x >= 200.0 and r.size.y >= 40.0,
			"「%s」在命中表里且够大（%.0f×%.0f）" % [act, r.size.x, r.size.y])
	# 返回键是**所有子页共用的页头组件**（`_back_rect` 写死 98×38，
	# 贴屏幕左上角、外留 22px），不归这一页管 —— 门槛按它自己的真实尺寸走。
	# 这里只钉「它还在、还点得到」，改 `_back_rect` 的话 `tests/Menu.gd` 会先响。
	var rb := _rect_of_act("back")
	_ok(rb.size != Vector2.ZERO and rb.size.x >= 88.0 and rb.size.y >= 36.0,
		"「back」（页头共用）在命中表里（%.0f×%.0f）" % [rb.size.x, rb.size.y])
	# 两个选择组
	for g in ["race", "map"]:
		var n := 0
		for m in _hits():
			if String(m.get("kind", "")) == "choice" and String(m.get("group", "")) == g:
				n += 1
		_ok(n >= 3, "「%s」有 %d 个可选项（≥3）" % [g, n])

# ---------------------------------------------------------------- 3. 选择项路由

func _g3_choice_routing() -> void:
	print("-- 3. 阵营 / 地图改的是「本局选项」而不是持久化设置 --")
	_open_lan()
	_main.race = "terran"
	_main.map_preset = "plateau"
	_ok(_tap_choice("race", "zerg"), "点「虫族」")
	_eqs(_main.race, "zerg", "★本局阵营变成 zerg★")
	_ok(_tap_choice("map", "river"), "点「中间河道」")
	_eqs(_main.map_preset, "river", "★本局地图变成 river★")
	# 关键：它**不该**写进持久化设置（那是设置页的职责）
	_eqs(Settings.text("default_map", ""), "plateau",
		"★局域网页的选择没有污染 Settings★")
	_eqs(Settings.text("default_difficulty", ""), "normal", "难度设置也没被改")
	# 还原
	_main.race = "terran"
	_main.map_preset = "plateau"

# ---------------------------------------------------------------- 4. 键盘几何

func _g4_keypad_geometry() -> void:
	print("-- 4. 屏幕键盘的几何 --")
	_open_lan()
	for key in ["ip", "name"]:
		_main._lan_open_input(key)
		var rs: Array = _main.lan_keypad_rects(BASE)
		_ok(rs.size() >= 13, "「%s」键盘有 %d 个键（含取消 / 确定）" % [key, rs.size()])
		var panel: Rect2 = _main.lan_keypad_panel(BASE)
		_ok(panel.position.y >= 0.0 and panel.end.y <= BASE.y,
			"★「%s」键盘整体在屏内（%.0f ~ %.0f）★" % [key, panel.position.y, panel.end.y])
		_ok(panel.position.x >= 0.0 and panel.end.x <= BASE.x,
			"「%s」键盘左右也在屏内" % key)
		# 键必须够大（触控目标）
		var too_small := 0
		for m in rs:
			var r: Rect2 = m["rect"]
			if r.size.y < 44.0 or r.size.x < 44.0:
				too_small += 1
		_eqi(too_small, 0, "★「%s」没有小于 44px 的键★" % key)
		# 键之间不能重叠（重叠 = 点不准，而且不报错）
		var overlap := 0
		for i in range(rs.size()):
			for j in range(i + 1, rs.size()):
				if (rs[i]["rect"] as Rect2).intersects(rs[j]["rect"]):
					overlap += 1
		_eqi(overlap, 0, "★「%s」键盘没有互相重叠的键★" % key)
	# IP 键盘只该有数字和点。
	_main._lan_open_input("ip")
	var has_letter := false
	for m in _main.lan_keypad_rects(BASE):
		var k := String(m["key"])
		if k.length() == 1 and k.to_upper() != k.to_lower():
			has_letter = true
	_ok(not has_letter, "★IP 键盘里没有字母（只有数字和点）★")
	# 阳性对照：名字键盘**必须**有字母 ——
	# 少了这条，「IP 键盘没有字母」在「两个键盘其实是同一份」时照样通过。
	_main._lan_open_input("name")
	var name_has_letter := false
	for m in _main.lan_keypad_rects(BASE):
		var k2 := String(m["key"])
		if k2.length() == 1 and k2.to_upper() != k2.to_lower():
			name_has_letter = true
	_ok(name_has_letter, "★阳性对照：名字键盘里有字母（否则上面那条是恒真的）★")
	_main._lan_input_key = ""

# ---------------------------------------------------------------- 5. IP 输入

func _g5_ip_input() -> void:
	print("-- 5. 输入主机地址 --")
	_open_lan()
	_main._lan_ip = ""
	Settings.set_v("lan_ip", "")
	_ok(_tap("lan_ip"), "点「主机地址」")
	_eqs(_main._lan_input_key, "ip", "★键盘以 IP 模式打开★")

	_type("192.168.1.7")
	_eqs(_main._lan_input_buf, "192.168.1.7", "★键盘输入进了缓冲★")
	_ok(_tap_key("⌫"), "按退格")
	_eqs(_main._lan_input_buf, "192.168.1.", "退格删掉一个字符")
	_tap_key("7")
	_eqs(_main._lan_input_buf, "192.168.1.7", "补回来")

	_ok(_tap_key("确定"), "按确定")
	_eqs(_main._lan_input_key, "", "★键盘关掉了★")
	_eqs(_main._lan_ip, "192.168.1.7", "★地址写进了成员★")
	_eqs(Settings.text("lan_ip", ""), "192.168.1.7", "★地址落了盘（下次不用重输）★")

	# 取消：改了但不确认，值必须原样
	_ok(_tap("lan_ip"), "再打开一次")
	_type("999")
	_ok(_tap_key("取消"), "按取消")
	_eqs(_main._lan_input_key, "", "键盘关掉了")
	_eqs(_main._lan_ip, "192.168.1.7", "★取消之后地址没有被改★")

# ---------------------------------------------------------------- 6. 玩家名

func _g6_name_input() -> void:
	print("-- 6. 输入玩家名 --")
	_open_lan()
	_main._lan_name = "指挥官"
	_ok(_tap("lan_name"), "点「玩家名」")
	_eqs(_main._lan_input_key, "name", "键盘以名字模式打开")
	_eqs(_main._lan_input_buf, "指挥官", "★打开时带出当前名字（不是空白）★")
	_ok(_tap_key("取消"), "先取消")
	_ok(_tap("lan_name"), "再打开")
	# 清空后重新输
	for i in range(_main._lan_input_buf.length()):
		_tap_key("⌫")
	_eqs(_main._lan_input_buf, "", "退格能清空")
	_type("ALPHA")
	_eqs(_main._lan_input_buf, "ALPHA", "字母输入正常")
	_ok(_tap_key("确定"), "确定")
	_eqs(_main._lan_name, "ALPHA", "★名字更新了★")
	_eqs(Settings.text("player_name", ""), "ALPHA", "名字落了盘")
	# 空名字必须回落到默认值（否则大厅里显示一片空白）
	_ok(_tap("lan_name"), "打开")
	for i in range(_main._lan_input_buf.length()):
		_tap_key("⌫")
	_ok(_tap_key("确定"), "空名字点确定")
	_eqs(_main._lan_name, "指挥官", "★空名字回落到「指挥官」★")

# ---------------------------------------------------------------- 7. 模态

func _g7_modal() -> void:
	print("-- 7. 键盘是模态的 --")
	_open_lan()
	_main._lan_ip = ""
	_ok(_tap("lan_ip"), "打开 IP 键盘")
	# 键盘打开时，点「加入房间」按钮所在的**屏幕坐标**不该触发加入
	var jr := _rect_of_act("lan_join")
	_ok(jr.size != Vector2.ZERO, "前置条件：拿得到「加入房间」的矩形")
	_main._menu_press(jr.get_center())
	_eqs(_main._lan_input_key, "ip", "★点键盘区域外仍然保持键盘打开（没被吞掉）★")
	_eqst("menu", "★没有误触发「加入房间」★")
	_ok(_main.session == null, "★也没有开出会话★")
	# 键盘上没有键覆盖住「加入房间」的位置吗？如果盖住了，
	# 上面那条会「因为按到了键盘」而通过 —— 所以这里显式确认没盖住。
	var covered := false
	for m in _main.lan_keypad_rects(_vp()):
		if (m["rect"] as Rect2).has_point(jr.get_center()):
			covered = true
	_ok(not covered, "★「加入房间」的位置不在键盘覆盖范围内（上面那条断言才有效）★")
	_ok(_tap_key("取消"), "关掉键盘")

# ---------------------------------------------------------------- 8. 空地址守卫

func _g8_join_guard() -> void:
	print("-- 8. 地址为空时不给连 --")
	_open_lan()
	_main._lan_ip = ""
	_ok(_tap("lan_join"), "点「加入房间」")
	_ok(_main.session == null, "★没有开会话★")
	_eqst("menu", "★还停在菜单，没进大厅★")
	_eqs(_main._lan_input_key, "ip", "★顺手把 IP 键盘打开了（引导玩家去填）★")
	_main._lan_input_key = ""

# ---------------------------------------------------------------- 9. 创建 / 离开

func _g9_host_and_leave() -> void:
	print("-- 9. 创建房间与离开 --")
	_open_lan()
	_main._lan_host(TEST_PORT)
	_ok(_main.session != null, "★创建房间后有了会话（%s）★"
		% (_main.session.last_error if _main.session != null else "没有会话"))
	if _main.session == null:
		return
	_eqst("lobby", "★状态切到大厅★")
	_ok(_main._authoritative, "★主机是权威模拟方★")
	_ok(_main.world != null, "主机在大厅里就有世界了（要发给客户端）")
	_ok(not _main.world.ai_enabled, "★局域网里 AI 关掉了（否则它会指挥客户端那一方）★")
	_ok(_main._lan_status.contains("等待"), "状态文案是「等待玩家加入」（「%s」）" % _main._lan_status)

	# 大厅页的按钮在屏内
	# ⚠️ 参数从 `lobby_ui_state()` 取，**不手工构造** ——
	#    手工构造只能验证「我以为的状态」，验证不了「界面实际拿到的状态」。
	var lst: Dictionary = _main.lobby_ui_state()
	var hbtns: Array = _main.lobby_button_rects(BASE, bool(lst["in_room"]), bool(lst["host"]),
		bool(lst["me_ready"]), bool(lst["can_start"]))
	_ok(hbtns.size() >= 2, "★主机在大厅里至少有「开始游戏」+「取消并返回」两个键★")
	for m in hbtns:
		var r: Rect2 = m["rect"]
		_ok(r.position.y >= 0.0 and r.end.y <= BASE.y and r.position.x >= 0.0 and r.end.x <= BASE.x,
			"大厅按钮「%s」在屏内" % String(m.get("label", "")))

	# 重复点「创建房间」不该开出第二个会话
	var s1: NetSession = _main.session
	_main._lan_host(TEST_PORT)
	_ok(is_same(_main.session, s1), "★重复创建房间不会顶掉已有会话★")

	# 离开
	_main._lan_leave()
	_ok(_main.session == null, "★离开之后会话被关掉★")
	_eqst("menu", "回到菜单")
	_ok(_main._authoritative, "★离开后 _authoritative 复位（否则单机开局单位不动）★")

	# 客户端路径：地址填好后点「加入房间」→ 进大厅
	_open_lan()
	_main._lan_ip = "10.255.255.1"     # 不可路由：异步发起，不会真连上
	_main._lan_join(TEST_PORT2)
	_ok(_main.session != null, "客户端会话建出来了")
	if _main.session != null:
		_eqst("lobby", "客户端也进大厅")
		_ok(not _main._authoritative, "★客户端不是权威方（不跑 world.step）★")
		_ok(_main.world == null, "★客户端此刻还没有世界（要等 WELCOME）★")
		_main._lan_leave()
	_ok(_main.session == null and _main._authoritative, "客户端离开也清理干净")

# ---------------------------------------------------------------- 10. 地址行

## 这一组守的是**一个只有截图才能发现的缺陷**：主机大厅把本机所有 IPv4
## 用 ` · ` 拼成一行，而装了 VMware / Hyper-V / WSL 的机器有 8 个地址 ——
## 整行**冲出屏幕两侧**（`draw_string` 不换行也不裁剪，**不报错**）。
## 顺带修了「玩家不知道该输哪个」：改成按「像不像真的局域网地址」排序，
## 大号只显示**一个**，其余最多列 3 个。
func _g10_address_lines() -> void:
	print("-- 10. 本机地址的排序与限行 --")

	# 排序：家用路由器最常见 → 企业网 → 其它 → APIPA（没拿到 DHCP，基本连不通）
	_ok(NetLink.ip_rank("192.168.1.5") < NetLink.ip_rank("10.0.0.1"),
		"192.168.* 排在 10.* 前面")
	_ok(NetLink.ip_rank("10.0.0.1") < NetLink.ip_rank("8.8.8.8"),
		"常见私网排在公网前面")
	_ok(NetLink.ip_rank("8.8.8.8") < NetLink.ip_rank("169.254.1.1"),
		"★APIPA（169.254.*）排最后★")
	_eqi(NetLink.ip_rank("172.16.0.1"), 1, "172.16.* 算企业网")
	_eqi(NetLink.ip_rank("172.32.0.1"), 5, "★172.32.* 不算企业网（边界）★")
	_eqi(NetLink.ip_rank("172.15.0.1"), 5, "★172.15.* 不算企业网（边界）★")

	# 真实网卡列表：排好序 + 第一个就是最该让玩家输的那个
	var real := NetLink.local_ipv4_list()
	var sorted_ok := true
	for i in range(1, real.size()):
		if NetLink.ip_rank(String(real[i - 1])) > NetLink.ip_rank(String(real[i])):
			sorted_ok = false
	_ok(sorted_ok, "★真实网卡列表按权重升序（%d 个）★" % real.size())

	# 限行：**注入 8 个假地址**，不依赖开发机正好有几张网卡 ——
	# 不注入的话「最多列 3 个」这条断言换台机器就静默退化成恒真。
	#
	# ⚠️ 假地址必须是**真实长度**的（`169.254.96.180` 这种 14 字符），
	#    别图省事写成 `192.168.1.2`（11 字符）—— 我第一版就那么写的，
	#    结果下面那条阳性对照**打不红**（1085 < 1240），白白浪费一轮。
	var fake: Array = [
		"192.168.1.23", "169.254.20.33", "10.0.0.5", "172.20.10.2",
		"169.254.96.180", "192.168.79.1", "169.254.143.66", "10.255.255.1",
	]
	var al: Dictionary = _main.lan_address_lines(fake)
	_eqi(int(al["count"]), 8, "注入 8 个地址，count 对得上")
	_eqs(String(al["main"]), "192.168.1.23", "★main 是一个地址，不是一串★")
	_ok(not String(al["main"]).contains(" · "), "★main 里没有分隔符（另一台照着输的就是它）★")
	_eqs(String(al["rest"]), "169.254.20.33 · 10.0.0.5 · 172.20.10.2 等 8 个",
		"★rest 只列 3 个 + 一个总数★")

	# 溢出判据：**大号那一行只画一个地址**，所以宽度必然很小。
	#
	# ⚠️ 这一条同时是「不许把整串塞回大号行」的守卫 ——
	#    老写法（8 个地址 22px 一行）实测 **1223px**，而可用宽度只有 1240px，
	#    也就是占掉 **98.6%**，几乎贴住屏幕两边；换台网卡更多的机器就真的溢出了。
	#
	# ⚠️ 这里**故意不用 `w <= 1240`** 当判据 —— 老写法实测 1223 < 1240，
	#    按那个门槛写**阳性对照打不红**（我第一版就写错了，还据此以为「截图里溢出了」；
	#    目测被贴边的观感骗了）。用「不到一半屏宽」才是真的能红。
	var main_w: float = _main.font.get_string_size(String(al["main"]),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 26.0).x
	_ok(main_w <= (BASE.x - 40.0) * 0.5,
		"★大号地址行只占不到一半屏宽（%.0f ≤ %.0f）★"
			% [main_w, (BASE.x - 40.0) * 0.5])
	# 阳性对照：整串按老写法画，宽度远超一半屏宽 —— 证明上面那条不是恒真的。
	# 字号必须是 **22**（老代码用的就是它）；13px 下这串只有约 700px，打不红。
	var old_w: float = _main.font.get_string_size(" · ".join(fake),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 22.0).x
	_ok(old_w > (BASE.x - 40.0) * 0.5,
		"★阳性对照：整串按老写法（22px 一行）宽达 %.0f，远超一半屏宽 %.0f★"
			% [old_w, (BASE.x - 40.0) * 0.5])

	# 空列表 / 单地址
	var one: Dictionary = _main.lan_address_lines(["192.168.1.9"])
	_eqs(String(one["rest"]), "", "只有一个地址时没有「其他网卡」行")
	_eqi(int(one["count"]), 1, "count = 1")
	# 不传参数时读**真实**网卡 —— 这条同时确认默认分支没写反
	# （写成 `if p_ips.is_empty(): return 空` 的话，大厅永远显示「没检测到」）。
	var live: Dictionary = _main.lan_address_lines()
	_eqi(int(live["count"]), NetLink.local_ipv4_list().size(),
		"★不传参数时读真实网卡（默认分支没写反）★")

# ---------------------------------------------------------------- 11. 大厅动作表

## 这一组守的是**「主机和客户端的主按钮语义不同」**。
## 合成一个的话，客户端会看到一个自己点不动的「开始游戏」，
## 主机能看到一个「我准备好了」—— 两个人都不知道该干什么。
func _g11_lobby_actions() -> void:
	print("-- 11. 大厅按钮的动作表（纯函数全组合）--")

	# 还没进房间：只有「取消并返回」
	var a0: Array = _main.lobby_actions(false, true, false, false)
	_eqi(a0.size(), 1, "★没进房间时只有一个键★")
	_eqs(String(a0[0]["act"]), "lan_leave", "是「取消并返回」")

	# 主机 + 对方没准备：有「开始游戏」但**点不动**
	var a1: Array = _main.lobby_actions(true, true, false, false)
	_eqi(a1.size(), 2, "★主机在大厅里有两个键★")
	_eqs(String(a1[0]["act"]), "lan_start", "第一个是「开始游戏」")
	_eqs(String(a1[0]["label"]), "开始游戏", "文案对")
	_ok(not bool(a1[0]["enabled"]), "★对方没准备时「开始游戏」是灰的★")
	_ok(String(a1[0]["hint"]) != "", "★灰键要给出理由（不然玩家只会一直点）★")

	# 主机 + 对方已准备：可点
	var a2: Array = _main.lobby_actions(true, true, true, true)
	_ok(bool(a2[0]["enabled"]), "★对方准备好后「开始游戏」可点★")
	_eqs(String(a2[0]["hint"]), "", "可点时不再显示理由")

	# 客户端：主按钮是「我准备好了 / 取消准备」，**永远可点**
	var a3: Array = _main.lobby_actions(true, false, false, false)
	_eqs(String(a3[0]["act"]), "lan_ready", "★客户端的主键是「准备」而不是「开始」★")
	_eqs(String(a3[0]["label"]), "我准备好了", "未准备时的文案")
	_ok(bool(a3[0]["enabled"]), "客户端自己能切准备，所以可点")
	var a4: Array = _main.lobby_actions(true, false, true, false)
	_eqs(String(a4[0]["label"]), "取消准备", "★已准备时按钮变成「取消准备」★")

	# 两个键都在屏内（主机 / 客户端各试一遍）
	for st in [[true, true, false, false], [true, false, true, false]]:
		var rs: Array = _main.lobby_button_rects(BASE, bool(st[0]), bool(st[1]), bool(st[2]), bool(st[3]))
		_eqi(rs.size(), 2, "两个键")
		var last: Rect2 = rs[rs.size() - 1]["rect"]
		_ok(last.end.y <= BASE.y - 20.0,
			"★最下面那个键离屏幕下沿还有余量（底边 %.0f ≤ %.0f）★" % [last.end.y, BASE.y - 20.0])
		# 两个键不能重叠 —— 重叠时点下去命中谁由遍历顺序决定，玩家觉得「点错了」
		var r0: Rect2 = rs[0]["rect"]
		var r1: Rect2 = rs[1]["rect"]
		_ok(not r0.intersects(r1), "★两个键不重叠★")

	# 玩家名截断：长名字不能把整行推出屏幕
	_eqs(_main._safe_name("短名", 14), "短名", "短名字原样")
	_eqs(_main._safe_name("", 14), "?", "空名字回落成 ?")
	_ok(_main._safe_name("一二三四五六七八九十十一十二十三十四十五", 14).length() <= 15,
		"★长名字被截断（最多 14 字 + 省略号）★")
	_ok(_main._safe_name("一二三四五六七八九十十一十二十三十四十五", 14).ends_with("…"),
		"★截断了要有省略号（不然玩家以为名字本来就那样）★")

	# ★灰键必须带理由★
	#   这条守的是一个**只有截图能发现**的 bug：绘制器在「点不动」的分支里
	#   写了 `continue`，顺手把**理由**一起跳过了 —— 而理由恰恰只在点不动时
	#   才需要。症状是「灰键永远不告诉你为什么灰」。
	#   把「画什么」抽成 `lobby_button_plan()` 之后，测试才钉得住。
	var plan: Array = _main.lobby_button_plan(
		_main.lobby_button_rects(BASE, true, true, false, false))
	_ok(String(plan[0]["hint"]) != "", "★点不动的「开始游戏」必须带理由（%s）★" % String(plan[0]["hint"]))
	_ok((plan[0]["fg"] as Color).v < 0.6,
		"★灰键的文字颜色要明显偏暗（v=%.2f < 0.6）—— 画成和可点的一样玩家会一直点★"
		% (plan[0]["fg"] as Color).v)
	_ok((plan[0]["border"] as Color).a < 0.2, "灰键的边框也要淡（a=%.2f）" % (plan[0]["border"] as Color).a)
	# 可点的键：亮色文字、不带理由
	var plan2: Array = _main.lobby_button_plan(
		_main.lobby_button_rects(BASE, true, true, true, true))
	_eqs(String(plan2[0]["hint"]), "", "可点时不再显示理由")
	_ok((plan2[0]["fg"] as Color).v > 0.9, "★可点的键是亮色文字（v=%.2f）★" % (plan2[0]["fg"] as Color).v)
	# 「取消并返回」永远是红的（它是危险动作，不能和「开始」长得一样）
	var leave: Dictionary = plan2[plan2.size() - 1]
	_eqs(String(leave["label"]), "取消并返回", "最后一个键是返回")
	_ok((leave["border"] as Color).r > (leave["border"] as Color).g,
		"★返回键是红色系（r > g）★")
	# 计划表与命中表一一对应（少一项就会出现「画了但点不到」或反之）
	_eqi(plan.size(), _main.lobby_button_rects(BASE, true, true, false, false).size(),
		"★计划表与命中表条数一致★")

	# ★理由那行小字不能压到下面那个键★
	#   按钮是从下往上排的，间距默认 12px；而小字有 16px 高 ——
	#   不按需拉开间距的话，理由会画到「取消并返回」上，看着像文字叠字。
	var rs2: Array = _main.lobby_button_rects(BASE, true, true, false, false)
	var hz: Rect2 = _main.lobby_hint_rect(rs2[0]["rect"])
	var below: Rect2 = rs2[1]["rect"]
	_ok(not hz.intersects(below),
		"★「等对方准备」那行小字不与下面的键重叠（小字底 %.0f ≤ 下键顶 %.0f）★"
		% [hz.end.y, below.position.y])
	# 反过来：可点的键不带理由，间距也不该被无谓拉大
	var rs3: Array = _main.lobby_button_rects(BASE, true, true, true, true)
	_ok(String(_main.lobby_button_plan(rs3)[0]["hint"]) == "",
		"可点时没有理由，间距不需要预留")
	# 拉大间距后整组按钮仍然装得下
	_ok(rs2[0]["rect"].position.y > 0.0,
		"★拉开间距后最上面的键仍在屏内（顶 %.0f > 0）★" % rs2[0]["rect"].position.y)

# ---------------------------------------------------------------- 12. 搜索房间页

func _g12_scan_page() -> void:
	print("-- 12. 搜索房间页 --")
	# 进搜索页
	_main._open_lan_scan()
	_eqst("lan_scan", "★进入搜索页★")
	# 发现器**应该**被拉起来了（无头下端口能绑上）
	_ok(_main._discovery != null, "★搜索页会开广播发现（%s）★"
		% (_main._discovery.last_error if _main._discovery != null else "没开"))
	if _main._discovery != null:
		_eqs(_main._discovery.mode_name(), "browse", "★是「收公告」那一侧，不是「发公告」★")
		_ok(_main._discovery.rooms().is_empty(), "刚开时列表是空的")

	# 返回键 / 重新搜索键都在屏内且不重叠
	var bs: Array = _main.lan_scan_button_rects(BASE)
	_eqi(bs.size(), 2, "两个键")
	for m in bs:
		var r: Rect2 = m["rect"]
		_ok(r.position.y >= 0.0 and r.end.y <= BASE.y and r.position.x >= 0.0 and r.end.x <= BASE.x,
			"搜索页按钮「%s」在屏内" % String(m["label"]))
	_ok(not (bs[0]["rect"] as Rect2).intersects(bs[1]["rect"]), "★两个键不重叠★")

	# 房间行：几何 + 不越界 + 最多 3 行
	var fake: Array = []
	for i in range(6):
		fake.append({"ip": "192.168.1.%d" % (10 + i), "port": 27015,
			"name": "房间%d" % i, "map": "plateau", "players": 1, "max": 2})
	var rows: Array = _main.lobby_room_rects(BASE, fake)
	_eqi(rows.size(), 3, "★最多显示 3 行（多了会盖住「返回」）★")
	for m in rows:
		var r: Rect2 = m["rect"]
		_ok(r.position.y >= 0.0 and r.end.y <= BASE.y and r.position.x >= 0.0 and r.end.x <= BASE.x,
			"房间行在屏内")
		_ok(not (bs[0]["rect"] as Rect2).intersects(r), "★房间行不与「返回」重叠★")
	# 行的 arg 必须带端口 —— 只带 IP 会去连默认端口，而房间端口是主机自己定的
	_ok(String(rows[0]["arg"]).contains(":"), "★行的 arg 带上了端口（%s）★" % String(rows[0]["arg"]))
	_eqi(rows.size(), mini(6, 3), "6 个房间也只画 3 行")

	# ★房间行显示的是「房间名」，不是「?」★
	#   这条守的是一个**只有截图抓到过**的 bug：绘制处把 `name` 读成了 `host`，
	#   于是每个房间的名字都显示成「?」，而 IP / 地图 / 人数全是对的 ——
	#   看着像「对方没设名字」。抽成 `room_display()` 之后测试也能覆盖。
	var disp: Dictionary = _main.room_display(fake[0])
	_eqs(String(disp["name"]), "房间0", "★房间名从 `name` 键取，不是 `host`★")
	_ok(String(disp["sub"]).contains("192.168.1.10"), "副行含 IP")
	_ok(String(disp["sub"]).contains("1 人"), "副行含人数")
	_eqs(String(_main.room_display({})["name"]), "?", "房间字典缺字段时回落成 ?（不炸）")
	_ok(String(rows[0]["label"]).contains("房间0"), "★命中表里的 label 也带上了房间名★")

	# 空列表不炸
	_eqi(_main.lobby_room_rects(BASE, []).size(), 0, "没有房间时命中表是空的")

	# 返回：要顺手关掉发现器（不然它会一直占着广播端口）
	_main._menu_act("lan_scan_back", Rect2(), Vector2.ZERO)
	_eqst("menu", "★返回后回到菜单★")
	_ok(_main._discovery == null, "★返回时关掉了广播发现（否则一直占着端口）★")

# ---------------------------------------------------------------- 13. 对局内 UI

func _g13_ingame_ui() -> void:
	print("-- 13. 对局内 UI（聊天 / 投降 / 暂停）--")
	# 单机对局：**不该**出现聊天 / 投降键
	_open_lan()
	_main._close_session()
	_main.start_game("terran", "easy", "plateau")
	_ok(_main.session == null, "单机没有会话")
	_ok(_main.lan_button_rects(BASE).is_empty(),
		"★单机对局里没有「聊天 / 投降」两个键（它们只属于局域网）★")

	# 局域网对局：两个键出现，且在屏内、不重叠、不压住 sysbtns 那一行
	_open_lan()
	_main._lan_host(TEST_PORT)
	if _main.session == null:
		_ok(false, "建会话失败")
		return
	# 直接把它推成「对局中」—— 不真连第二台机器，靠内部状态注入。
	_main.session.state = _main.session.State.PLAYING
	_main.state = _main.St.PLAY
	var lb: Dictionary = _main.lan_button_rects(BASE)
	_eqi(lb.size(), 2, "★局域网对局里多出两个键★")
	for k in ["chat", "surrender"]:
		_ok(lb.has(k), "有「%s」键" % k)
		var r: Rect2 = lb[k]
		_ok(r.position.y >= 0.0 and r.end.y <= BASE.y and r.position.x >= 0.0 and r.end.x <= BASE.x,
			"「%s」键在屏内" % k)
	_ok(not (lb["chat"] as Rect2).intersects(lb["surrender"]), "★两个键不重叠★")

	# ★不能和 `sysbtns` 那一行重叠★ —— 重叠的话点「聊天」会同时命中「音效」。
	#   这条是「别再往 sysbtns 里塞键」这个决定的判据。
	var tb: Dictionary = _main.topbar_button_rects(BASE)
	for k in ["pause", "speed", "help", "sfx"]:
		if not tb.has(k):
			continue
		_ok(not (lb["chat"] as Rect2).intersects(tb[k]),
			"★「聊天」不与顶栏「%s」重叠★" % k)
		_ok(not (lb["surrender"] as Rect2).intersects(tb[k]),
			"★「投降」不与顶栏「%s」重叠★" % k)

	# 聊天输入：键盘要认得 "chat" 这个类型（否则点聊天什么都不弹）
	_main._lan_open_input("chat")
	_eqs(_main._lan_input_key, "chat", "★聊天输入打开了★")
	_eqs(_main._lan_input_buf, "", "★从空开始（不带出上一条）★")
	_ok(_main.lan_keypad_rects(BASE).size() > 0, "键盘有键")
	# 打几个字再退格
	_main._lan_input_press("A")
	_main._lan_input_press("B")
	_eqs(_main._lan_input_buf, "AB", "能输入")
	_main._lan_input_press("⌫")
	_eqs(_main._lan_input_buf, "A", "能退格")
	# 取消不改任何东西
	_main._lan_input_press("取消")
	_eqs(_main._lan_input_key, "", "★取消关掉了键盘★")
	_eqs(_main._lan_input_buf, "", "★取消清空了缓冲★")
	_eqs(_main._lan_name, "指挥官", "★取消聊天不会改玩家名★")

	# 聊天内容**不能落盘**（落盘的话下次打开还能看到上一局的发言）
	_main._lan_name = "指挥官"
	_main._lan_open_input("chat")
	for ch in ["H", "I"]:
		_main._lan_input_press(ch)
	_main._lan_input_commit()
	_eqs(_main._lan_input_key, "", "确定后关掉键盘")
	_ok(Settings.text("player_name", "") != "HI", "★聊天内容没有写进玩家名★")
	_ok(Settings.text("lan_ip", "") != "HI", "★聊天内容没有写进主机地址★")

	# 聊天记录上限
	for i in range(_main.CHAT_LOG_MAX + 5):
		_main._push_chat("甲", "第 %d 条" % i)
	_eqi(_main._chat_log.size(), _main.CHAT_LOG_MAX, "★聊天记录有上限，不会无限涨★")
	_eqs(String((_main._chat_log[_main._chat_log.size() - 1] as Dictionary)["text"]),
		"第 %d 条" % (_main.CHAT_LOG_MAX + 4), "★留下的是最新的那几条★")

	# 关会话要清掉聊天记录（否则下一局看到上一局的发言）
	_main._close_session()
	_eqi(_main._chat_log.size(), 0, "★关会话清空聊天记录★")
	_open_lan()
