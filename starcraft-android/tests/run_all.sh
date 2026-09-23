#!/usr/bin/env bash
# 一次性跑完全部测试套件。
#
#   bash tests/run_all.sh              # 快速套件（18 套，约 15 分钟）
#   bash tests/run_all.sh full         # 再加上平衡性对局（每组合 5 局，约 10 分钟）
#   bash tests/run_all.sh bal          # 只跑平衡性对局
#
#   环境变量：
#     GODOT=<引擎路径>      覆盖引擎路径
#     TIMEOUT=<秒>          单个套件超时（默认 900）
#
# 跑的时候可以另开一个终端看进度：
#   tail -f /tmp/wb_test_Economy.log
#
# 快速套件：Matchup / Smoke / Economy / Touch / Menu / Hud / Mods / Upgrade / Ability /
#           Build / Air / Terrain / Creep / Net / NetLink / NetSession / Lan / Discovery
#
# ⚠️ NetLink / NetSession / Lan / Discovery 四套会**真的开 UDP 端口**
#    （27315/27316、27515/27516、27615/27616、27715/27716）。
#    开发机上如果已经有一个真的游戏实例在跑 `Net.PORT`（27015），不影响；
#    但如果手动改过这四套的端口常量，要保证不和别的进程撞。
#
# 平衡性对局很慢（3 组合 × 5 局 × 最长 600 秒模拟），不要加进默认流程。

set -u
cd "$(dirname "$0")/.." || exit 1

GODOT="${GODOT:-F:/godot/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe}"
PROJ="F:/KF/XJ/starcraft-android"
MODE="${1:-fast}"

fail=0
## 单个套件的硬超时（秒）。死循环比失败更糟 —— 失败会报错，死循环只会让人干等。
TIMEOUT="${TIMEOUT:-900}"
run() {
  local name="$1"
  echo ""
  echo "#####################  $name  #####################"
  local out="/tmp/wb_test_$name.log"
  # ⚠️ **不要用管道**（`... | grep ...`）。
  #    Godot 的 stdout 一旦被管道接住就变成**块缓冲**：套件没退出之前
  #    一个字节都不会刷出来。症状是「跑了很久一行输出都没有」，看起来像
  #    死循环，其实只是没刷盘 —— 实测因此误判过一次 6 小时「卡死」。
  #    重定向到文件既避开缓冲，也能在跑的时候 `tail -f /tmp/wb_test_X.log` 看进度。
  timeout "$TIMEOUT" "$GODOT" --headless --path "$PROJ" --script "res://tests/$name.gd" \
    > "$out" 2>&1
  local rc=$?
  grep -vE 'ObjectDB instances were leaked|resources still in use|at: cleanup|at: clear' "$out"
  if [ "$rc" -eq 124 ]; then
    echo "!! $name 超时 ${TIMEOUT} 秒被强杀（疑似死循环）"
    fail=1
  elif [ "$rc" -ne 0 ]; then
    echo "!! $name 退出码 $rc"
    fail=1
  fi
}

if [ "$MODE" != "bal" ]; then
  run Matchup
  run Smoke
  run Economy
  run Touch
  # 菜单：锁死「五个页面都能进能出」「设置项点了真的生效」「存盘后重读还在」。
  # 改页面描述 / 表单渲染器 / Settings.gd 之后必须重跑 ——
  # 一个设置项要同时改五处（描述 / 排版 / 命中 / 写盘 / 应用），
  # 漏任何一处都是「点了没反应」且不报错。
  #
  # ⚠️ 这套里有张 `DEVICE_SIZES` 表，必须显式传真机分辨率。
  #    headless 下 `get_viewport_rect()` 返回 **1280×1280**（正方形），
  #    而真机与全部截图都是 **1280×720** —— 设置页面板高 858px 溢出 720 屏、
  #    而当时 46 条断言全绿，根因就是量错了视口。
  #    **凡是「装不装得下」的断言，一律不能用 `get_viewport_rect()`。**
  run Menu
  # HUD 布局（M2）：把 M2 之前那套硬编码坐标**原样抄了一份当参照**，逐像素比对。
  # `tests/Touch.gd` 只是间接判据（菜单在不在面板之上），这一套是直接判据。
  # ⚠️ 本套上线时立刻抓到一个真 bug：`info` / `queue` 的默认 offset 按「顶边」
  #    填了，而 `bl` 锚点的 pivot 在**底边** —— 两个模块整体上移 48 / 96px，
  #    而 Touch 的 74 条断言因为「面板自己跟着上移」全部假通过。
  #    改 `HudLayout.DEFAULTS` / 模块矩形公式 / 编辑模式后必须重跑。
  run Hud
  # 模组系统（M3）：锁死「能装 / 能启停 / 能排序」+ **「冻结后写 UNITS 被拒」**。
  # 这一套守的是本项目**风险最高的一处改动** —— `GameData.UNITS` 从 `const`
  # 变成了可变字典，任何「顺手改一下 data」的代码都会跨模组、跨对局地污染全局。
  # 改 GameData 的模组接口 / Mods.gd / 模组页 UI 后必须重跑。
  #
  # ⚠️ 本套上线时立刻抓到两个真 bug：
  #    1. `DirAccess.open("user://…")` 在本引擎下**恒返回 null**
  #       （`res://` 与 `FileAccess` 都正常）→ 模组一个都扫不到、
  #       `user://skins/` 从来没被建出来过，**全程不报错**。
  #       修法：一律 `ProjectSettings.globalize_path()` 之后再 open。
  #    2. `Mods.set_enabled()` 漏了 `_rebuild_owners()` → 禁用掉冲突的一方之后
  #       黄框还挂着，玩家照着提示永远找不到第二个模组。
  run Mods
  # 科技升级 / 技能：这两套锁定了「升级是阵营级」和「医疗兵零伤害」两条铁律，
  # 改伤害公式或单位数值后必须重跑。
  run Upgrade
  run Ability
  # 建造：锁死「一个工地只派一个农民」这条判据（曾用「物理在场数」判补人，
  # 导致一个远处的工地把整队农民拉走）。改派工逻辑或建造速度公式后必须重跑。
  run Build
  # 空中维度：锁死「地面近战打不到空中」「飞行单位不寻路」两条铁律。
  # 改 AIR_RULES / 索敌过滤 / 建筑开火 / 建造派工后必须重跑。
  run Air
  # 地形高低差：锁死「高低地之间只有坡道能过」「低地打高地 30% miss」
  # 「低地看不到高地」三条铁律。改 Grid.can_step / 地图生成 / 建造规则 /
  # 伤害结算 / 视野后必须重跑。
  run Terrain
  # 虫族菌毯：锁死「虫族建筑必须建在菌毯上」「只有虫族地面单位在菌毯上加速」
  # 「AI 不会被菌毯约束卡死」三条铁律。改 CREEP_RADIUS / can_place_building /
  # Unit.speed 后必须重跑。
  run Creep
  # 局域网协议层（M4a）：类型索引表 + 世界状态编解码 + 包头与版本。
  # 这一套守的是**「主机与客户端算出的索引必须一模一样」** ——
  # 索引表一旦从 `GameData.UNITS`（模组改过的副本）构建而不是 `base_ids()`，
  # 症状是「我的陆战队员变成攻城坦克」，而且**不报错、只在联机时出现**。
  #
  # ⚠️ 本套上线时抓到三个真 bug / 三条废断言：
  #    1. 索引表的稳定性断言原本用 `apply_mod_patch` 构造场景 ——
  #       而本版 `_merge_table` 明确拒绝新建条目，key 集合永远不变，
  #       断言**永远为真**（阳性对照实测打不红）。改成直接往 `UNITS` 里塞假条目。
  #    2. `build_progress` 完工后等于 `build_time`（40 / 26 / 24），
  #       不是 0..1 的比例 —— 直接发它会被 clamp 到 255、解回来全变 1.0。
  #       要发 `progress_ratio()`。
  #    3. 量化用 `int()` 截断会丢精度：`0.29 * 100` 在双精度下是
  #       28.999999999999996 → 截成 28 → 解回来 0.28。一律 `roundi()`。
  #    4. 「幽灵墙」断言原本是「同一份快照连收 10 次」—— 那 10 次占的是
  #       **同一批格子**，测不出问题。要「先占、再撤」才抓得到。
  # 改 Net.gd / GameData.base_ids / World.reset_dynamic / fog_of 后必须重跑。
  run Net
  # ENet 传输层（M4b）：单进程回环，真 UDP、真握手、真分片。
  # 这一套守的是**「字节真的能过去」** —— 抓过四个只有真连一次才会暴露的坑：
  #   1. `ENetConnection.service()` 返回的是**扁平四元组数组**
  #      `[type, peer, channel_id, data]`，不是「字典的数组」。
  #      按字典写会把**所有**事件过滤掉，症状是「双方都 poll 了但永远连不上，
  #      一个报错都没有」。
  #   2. `ENetPacketPeer.ping()` 返回 **void**，RTT 要读 `get_statistic()`。
  #      写成 `return p.ping()` 会让**整个脚本编译失败**，而调用方拿到的报错是
  #      「Nonexistent function 'new' in base 'GDScript'」——隔了两层。
  #   3. `close()` 只销毁本地 host，**一个字节都不发**，对方要等自己的超时。
  #      优雅退出必须 `peer_disconnect()` + 若干次 `service()/flush()`。
  #   4. ENet 的包攒在发送队列里，**不 `flush()` 就出不去** ——
  #      `send()` 返回 OK，对方永远收不到。
  # 改 NetLink.gd 后必须重跑。
  run NetLink
  # 局域网会话状态机（M4b）：握手 + 种子一致性 + 快照下行 + 指令上行 +
  # 归属校验 + 迷雾过滤 + 看门狗 + 限流。
  # 这一套守的是**「过去之后双方看到的世界是不是同一个」**。
  #
  # ⚠️ 本套上线时抓到一个**跨越 M4a 就一直存在的真问题**：
  #    `_generate_map()` 用的是**局部** `RandomNumberGenerator`，种子是硬编码的
  #    常量 20260920 —— 也就是说**全局 `seed()` 根本不影响地形，每一局都是同一张图**。
  #    后果不是「地图单调」，而是「客户端用同种子重建世界」这条链路
  #    **无法被证伪**：少了种子照样对得上，因为地图本来就只有一张。
  #    修法：`World` 增加 `map_seed`（构造参数，传 0 退化成老常量，
  #    所以单机与所有老测试生成的地图**逐格不变**）。
  #
  # ⚠️ 另有三条「本机视角」判据在客户端上是错的（写死 `PLAYER` 而不是
  #    `local_owner`）：`visible_enemies()` / `visible_enemies_in_rect()` /
  #    `entity_at(fogged=true)`。客户端是 `ENEMY`，症状是
  #    「自己的兵在小地图上是红点、框选不到」。
  # 改 NetSession.gd / World.local_owner / World.client_frame / map_seed 后必须重跑。
  run NetSession
  # 局域网页面 + 屏幕键盘（M4b）：布局装得下 + 每个按钮点得到 + 选择项改的是
  # **本局选项而不是持久化设置** + 键盘几何（够大 / 不重叠 / 在屏内）+
  # IP 与玩家名输入 + **键盘是模态的** + 空地址守卫 + 创建/离开房间 +
  # 本机地址的**排序与限行**。
  # 这一套守的是**「大厅这条路上点了没反应」** —— 无头测试测不到 `_draw_*`，
  # 所以坐标一律从 `menu_hit_table()` / `lan_keypad_rects()` 取，
  # 再走真实的 `_menu_press()`（绘制 / 命中 / 测试三边读同一份）。
  #
  # ⚠️ 本套上线时抓到三个真 bug：
  #    1. `menu_hit_table()` 里对 `choice` 行硬读 `e["key"]`，而「本局选项」那类
  #       choice 只有 `group`、**没有 `key`** —— 抛
  #       「Invalid access to property or key 'key'」，而且是在**遍历中途**抛的：
  #       `menu_hit_table()` 直接返回空数组，连带「返回键点不到」「整页所有按钮
  #       都点不到」。症状看着像布局全错，实际只少了一个默认值。
  #       修法：`String(e.get("key", ""))`。
  #    2. `_close_session()` 不清 `world`，而 `_on_lan_ready()` 只在 `world == null`
  #       时才接管 `session.world` —— 「先开过主机房间 → 退出 → 再当客户端加入」
  #       会让**客户端全程玩着主机那份旧世界**（地图 / 部队 / 资源全是对方的），
  #       而且不报错。修法：`_attach_session()` 无条件 `world = w`（含 null），
  #       `_on_lan_ready()` 无条件 `world = session.world`。
  #    3. 主机大厅把本机**全部** IPv4 拼成一行（`IP.get_local_addresses()` 在装了
  #       VMware / Hyper-V / WSL 的机器上返回 8 个），实测宽 1223px / 可用 1240px ——
  #       占 98.6%，几乎贴住屏幕两边，而且玩家**不知道该输哪一个**。
  #       修法：`NetLink.ip_rank()` 排序（192.168.* → 10.* → 其它 → APIPA 最后）+
  #       `Main.lan_address_lines()` 大号只显示一个、其余最多列 3 个 + 一个总数。
  #       ⚠️ 这个缺陷**只有截图能发现**（无头调不了 `_draw_*`）。
  # 改 Main.gd 的大厅页 / 屏幕键盘 / `_attach_session` / `_on_lan_ready` /
  # `lan_address_lines`，或改 `NetLink.local_ipv4_list` / `ip_rank` 后必须重跑。
  #
  # ⚠️ 本套里的端口是 27615/27616，**故意和 NetLink(27315/27316)、
  #    NetSession(27515/27516) 错开** —— 三套在同一台机器上并行/连续跑时不撞。
  run Lan
  # UDP 广播发现（M4c）：主机公告的编解码往返 + 畸形包拒绝 +
  # **单进程真发现**（真的往 127.0.0.1 发一份公告，另一端真的收到）+
  # TTL 过期 + 上限淘汰 + 停止后收不到。
  # 这一套守的是**「房间列表里那行字是不是真的」**：
  #   1. `key` 必须用**公告里的 `game_port`**，不是收到包的**源端口**
  #      （源端口是发送方的临时端口，实测是 49841 这种）——
  #      用错的话列表里每个房间的端口都是错的，玩家照着连永远连不上。
  #   2. 列表满了要**踢最旧的**，不是拒收新的 ——
  #      拒收会让「先来的一堆僵尸房间」把真房间永远挡在外面。
  #   3. magic + 版本都要校验，否则一个随机 UDP 包就能造出一条乱码房间。
  # 改 NetDiscovery.gd / Net.DISCOVER_PORT / Main._sync_discovery 后必须重跑。
  #
  # ⚠️ 本套用的端口是 27715/27716，和上面三套错开。
  run Discovery
fi

if [ "$MODE" = "full" ] || [ "$MODE" = "bal" ]; then
  run bal
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "===== 全部套件执行完毕 ====="
else
  echo "===== 有套件异常退出，请检查上面的输出 ====="
fi
exit "$fail"
