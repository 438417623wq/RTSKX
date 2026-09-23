# 第十三轮 · M4b 落地报告：局域网真的能打起来

> 范围：M4a 的地基（类型索引表 + 快照编解码）之上，把**传输、会话、主循环集成、
> 大厅界面**四层补齐，做到「同一 WiFi 下两台设备手动输 IP 直连，2 人对战」。
>
> 前置决策（用户已定）：路线「参考魔兽争霸 3 冰封王座，越完善越好」；
> 大厅形态「手动输 IP 直连 2 人」；存档入口「先留灰掉的入口」。
>
> 合规立场不变：自研引擎 + 全程序化美术 + 自研数值，零外部素材；
> 不使用暴雪名称与美术。模组**不进 APK**，全部由玩家自备。

---

## 一、交付清单

| 交付物 | 规模 | 说明 |
| --- | --- | --- |
| `assets/scripts/NetLink.gd` | 342 行 | ENet 传输层：双通道（可靠 / 状态）/ 事件泵 / 优雅退出 / 地址排序 |
| `assets/scripts/NetSession.gd` | 608 行 | 会话状态机：握手 / 快照 / 指令 / 看门狗 / 限流 |
| `assets/scripts/Net.gd` | 981 行 | 本期新增：`Cmd` 12 种指令 + `apply_cmd` 归属校验 + HELLO/WELCOME/REJECT |
| `assets/scripts/World.gd` | — | `local_owner` / `ai_enabled` / `map_seed` / `client_frame()` |
| `assets/scripts/Main.gd` | 4757 行 | 12 个 `_c_*` 指令包装 + 主循环改造 + 大厅页 + 屏幕键盘 |
| `tests/NetLink.gd` | 377 行 / 57 条 | 单进程真 UDP 回环：连接 / 收发 / 可靠按序 / 不可靠 / 分片 / 断线 / 错误路径 |
| `tests/NetSession.gd` | 639 行 / 99 条 | 8 组集成：握手 / 种子 / 快照 / 指令 / 拒绝 / 迷雾 / 断线 / 限流 |
| `tests/Lan.gd` | 503 行 / 100 条 | 10 组：布局 / 命中 / 路由 / 键盘 / 输入 / 模态 / 守卫 / 房间 / 地址行 |
| 截图 | 32 张 | 新增 `30_lobby_host` / `31_lobby_client` |

---

## 二、这一期真正难的地方

M4a 的地基是**纯函数**（编码 / 解码），错了就是数值对不上，测试一跑就红。
M4b 全是**有状态 + 异步**的东西，错的形态完全变了 —— 三处都是**不报错**的：

1. **传输层的错误表现为「静默」**。事件泵写错一个数据结构，双方都 poll 了、
   一个字节都没动、一个错误都没有。
2. **时序错误表现为「看起来正常」**。快照过滤、握手看门狗、限流阈值，
   写错了只是「有点怪」，不抛异常。
3. **集成错误表现为「单机永远正常」**。漏掉一处指令包装，只有联机时才复现。

所以这一期的测试重心从「数值对不对」转成「**事件到底有没有发生**」——
所有断言都尽量钉在**计数器**上（`snapshots_received` / `cmds_applied` /
`cmds_dropped` / `pings_received`），而不是「状态看起来对」。

---

## 三、ENet 传输层：四个只有真连一次才会暴露的坑

`tests/NetLink.gd` 是单进程回环：同一个进程里起 host 和 client，走**真 UDP**。
四个坑全部是「编译通过、逻辑看着对、跑起来什么都没有」：

### 坑 1：`service()` 返回的是**扁平四元组数组**

```gdscript
# ❌ 按「字典的数组」写 —— 所有事件都被过滤掉，双方永远连不上，零报错
for ev in evs:
    if ev["type"] == "connect": ...

# ✅ 实际是 [type, peer, channel_id, data] 依次铺平
var i := 0
while i + 1 < evs.size():
    var etype := int(evs[i])
    var peer  := evs[i + 1]
    ...
    i += 4
```

空转时它也会返回 `[EVENT_NONE, null, 0, 0]`，所以「数组非空」不代表有事件。

### 坑 2：`ENetPacketPeer.ping()` 返回 **void**

RTT 不在返回值里，要读统计量：

```gdscript
_rtt_ms = int(peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) * 1000.0)
```

写成 `return p.ping()` 会让**整个脚本编译失败**，而调用方看到的报错是
「Nonexistent function 'new' in base 'GDScript'」——隔了两层，非常难定位。

### 坑 3：`close()` 一个字节都不发

`ENetConnection.close()` 只销毁**本地** host。对方要等自己的超时才知道我们走了。
优雅退出必须显式断开 + 把包推出去：

```gdscript
peer_disconnect(peer, 0)
for i in range(8):
    service(5)
    flush()
```

### 坑 4：包攒在发送队列里，**不 `flush()` 就出不去**

`send()` 返回 `OK`，对方永远收不到。所有发送路径后面都要跟一次 flush。

> **这四条都不是「写错了」而是「写对了但没人告诉你」。**
> 所以 `NetLink` 的注释密度比代码还高 —— 下一次改它的人不该重新踩一遍。

---

## 四、会话状态机：把「能跑一局」变成可测的东西

`NetSession` 是这一期的核心。它把 `Net`（纯数据）和 `NetLink`（纯传输）
拼成一个**有状态、有超时、有上限**的东西：

```
IDLE → HOSTING ──HELLO──→ PLAYING
     → CONNECTING ──WELCOME──→ PLAYING
     └→ FAILED / CLOSED
```

### 4.1 三个超时，三条看门狗

| 常量 | 值 | 作用 |
| --- | --- | --- |
| `HANDSHAKE_TIMEOUT` | 8.0 s | 主机侧：连上了但迟迟不发 HELLO → 踢回 `HOSTING` |
| `CONNECT_TIMEOUT` | 8.0 s | 客户端侧：连不上主机 → `FAILED` |
| `SNAPSHOT_TIMEOUT` | 5.0 s | 客户端侧：**收到过**快照后又断了 → `FAILED` |

第三条是**失联**判据，和第二条不同：第二条是「从来没连上」，第三条是
「连上了但对方没了」。少了它，客户端会安静地停在一个冻结的画面上。

### 4.2 ★时钟是虚拟的★

`NetSession` 内部累加 `_now += delta`，**不读 `Time.get_ticks_msec()`**。
这一个决定让整套测试从「要真的 sleep 8 秒」变成「瞬间跑完」：

```gdscript
for i in range(9):
    hs3.step(1.0)          # 直接推 9 秒虚拟时间
```

同时它也保证了「2× 速度下平衡与 1× 一致」这条既有性质不被破坏 ——
速度只乘在喂给 `world.step()` 的 delta 上，网络层完全不受影响。

### 4.3 限流：防「客户端刷爆主机」

```gdscript
const MAX_CMD_PER_FRAME := 32
```

`_cmds_this_frame` 在 `step()` 开头归零，超出上限的指令**计入 `cmds_dropped`
并丢弃**。测试直接打 `_host_cmd()` 把「同一帧」做成确定的：

```gdscript
var burst := NetSession.MAX_CMD_PER_FRAME + 20
for i in range(burst):
    hs._host_cmd(peer, Net.packet_cmd(buf, i + 1, Net.Cmd.STOP, [mine.id]))
_eqi(applied, NetSession.MAX_CMD_PER_FRAME, "上限内的都被应用了")
_eqi(dropped, burst - NetSession.MAX_CMD_PER_FRAME, "超出的都被丢弃了")
# ★新的一帧重新开始计数（限流不会永久卡死）★
hs._cmds_this_frame = 0
hs._host_cmd(...)
```

最后那条**必须有** —— 只测「超了会被丢」的话，一个「一旦超限就永久拒收」的
实现照样通过。

### 4.4 主机也走同一条解码路径

```gdscript
func send_cmd(kind, ids, p) -> Dictionary:
    if link.is_host():
        var cmd := Net.decode_cmd(data)
        return Net.apply_cmd(world, cmd, local_owner)   # 本地走一遍
```

**主机不直接调 `world.cmd_*`。** 那样两端的**校验路径**就不一样了，
于是会出现「客户端建不了、主机能建」这种只在一端复现的怪事。
多花一次编解码，比起这种 bug 便宜太多。

同理，`_host_cmd()` 里传给 `apply_cmd()` 的 `sender` 是 `remote_owner` ——
传错的话客户端能指挥主机的部队（真作弊）。

---

## 五、★一个跨越 M4a 的真问题：地图种子★

这一期最重要的发现，而且是**被阳性对照逼出来的**。

`tests/NetSession.gd` 第 1 组要钉「两端用同一个种子重建出同一张地图」。
按纪律，我先把 `World` 的种子**故意改成不传**，看断言会不会红 —— **它没红**。

追下去发现：`World._generate_map()` 用的是**局部** `RandomNumberGenerator`，
种子是硬编码常量 `20260920`：

```gdscript
# ❌ 原状
var rng := RandomNumberGenerator.new()
rng.seed = 20260920
```

也就是说 **全局 `seed()` 完全不影响地形，每一局都是同一张图**。

后果不是「地图单调」（那只是体验问题），而是：
**「客户端用同一种子重建世界」这条链路无法被证伪** ——
少了种子照样对得上，因为地图本来就只有一张。
这条链路会一直「通过」，直到哪天地图真的随机了才炸。

修法（把「老常量」显式命名，保证单机逐格不变）：

```gdscript
const LEGACY_MAP_SEED := 20260920
var map_seed := LEGACY_MAP_SEED

func _init(..., p_seed := 0):
    map_seed = p_seed if p_seed != 0 else LEGACY_MAP_SEED

func _generate_map() -> void:
    var rng := RandomNumberGenerator.new()
    rng.seed = map_seed          # ★原来是 20260920★
```

`NetSession.create_host_world()` 与客户端 `_build_world()` 都把种子传进
**构造参数**（不是只 `seed()`）：

```gdscript
seed(sd)                                    # 全局 RNG：AI / 散兵落点
var w := World.new(..., sd)                 # ★地形：必须走构造参数★
```

改完再跑阳性对照：**不传种子 → 2 条红（「地形类型图不同」×2）**。
断言可证伪了。

> 教训与 `tests/Creep.gd` 那次一样：**阳性对照不是「额外步骤」，
> 它是唯一能区分「测了」和「看起来测了」的手段。**

---

## 六、Main 集成：12 个包装与「本机视角」

### 6.1 所有指令收口到 `_c_*`

```
_c_move  _c_attack  _c_smart  _c_stop  _c_harvest
_c_build _c_train   _c_research _c_ability
_c_cancel_build  _c_cancel_queue  _c_rally
```

每个都是：

```gdscript
if session == null:
    world.cmd_xxx(...)      # 单机：逐字节和以前一致
else:
    _send_cmd(Net.Cmd.XXX, _ids_of(units_arr), {...})
```

⚠️ **漏掉一处包装的症状**：客户端点了没反应、单位抖一下就弹回原位
（本地跑了一遍，下一份快照又覆盖回去），而**单机永远正常**。
所以「新增指令时先加包装函数，再去调用点」写进了代码注释。
收口后用 grep 确认 `world.cmd_*` 只剩包装函数内部 12 处。

### 6.2 「本机视角」必须读 `local_owner`，不能写死 `PLAYER`

M4a 报告第九节列出的缺口 6（「客户端当 ENEMY 时没有迷雾」）在这一期修掉。
一共 6 处判据写死了 `PLAYER`，全部改成 `local_owner`：

- `visible_enemies()`
- `visible_enemies_in_rect()`
- `entity_at(fogged = true)`（两条迷雾过滤）
- `cmd_build` / `cmd_train` 的失败提示
- `_finish_research()` 的提示
- `_update_buildings` 的人口不足提示

症状是「**自己的兵在小地图上是红点、框选不到**」——玩家会以为游戏坏了，
而代码里一个报错都没有。

顺带删掉 `can_research()` 里一条**重复且对客户端是错的**守卫
（它写死 `building.owner_id == PLAYER`，和下面那条判 `factions[owner]["race"]`
完全重复，但在客户端上会把合法的研究全部拒掉）。

### 6.3 主循环：只有权威方推进模拟

```gdscript
if state == St.PLAY and world != null:
    if _authoritative and not paused:
        world.step(delta * game_speed)      # ★只有主机跑★
    if session != null:
        session.step(delta)
        _lan_autoharvest()
```

⚠️ 判据是 `_authoritative`（一个成员标志），**不是 `session.is_host()`**。
会话失败或关闭之后 `NetLink.role` 会变回 `NONE`，那时主机将**突然停止模拟** ——
画面还在，但整个游戏冻住。

客户端的每一帧只做「与渲染有关」的定期刷新：

```gdscript
func client_frame(delta: float) -> void:
    _vis_timer -= delta
    if _vis_timer <= 0.0:
        _vis_timer = VIS_INTERVAL
        update_visibility()
        refresh_derived()      # 菌毯 + 地形标记（否则客户端没有菌毯加速）
```

### 6.4 局域网必须关掉 AI

`World.ai_enabled = false`（`start_host()` 与 `_build_world()` 两处）。
**AI 指挥的是 `ENEMY`，而联机里 `ENEMY` 是客户端本人** ——
不关的话 AI 会和客户端抢指挥权，症状是「我的兵自己乱跑」。

### 6.5 客户端的开局清场

`World.new()` 会按同一种子摆一份「开局阵容」，第一份快照马上会把它整个换掉。
不清的话，在收到第一份快照之前玩家会看到**两份部队叠在一起**。
所以 `_build_world()` 里要 `w.reset_dynamic()`。

### 6.6 开局自动采矿：必须「每帧试一次」

`_lan_autoharvest()` 每帧试一次，直到**第一次真的拿到部队**为止：

```gdscript
if _lan_autoharvest_done or session == null or world == null: return
var workers := [] # 收集 can_harvest() 的单位
if workers.is_empty(): return        # ← 客户端第一份快照之前，世界是空的
_lan_autoharvest_done = true
_c_harvest(workers, 最近的矿点)
```

⚠️ 不能在 `session_ready` 那一刻做一次。客户端的 `world` 是收到 `WELCOME`
才建的，而 `_build_world()` 会 `reset_dynamic()` 把开局赠兵清掉 ——
所以那一刻 `world.units` 是**空的**，选农民会选到零个，
然后自动采矿**静默不发生**（兵站着不动，玩家以为联机坏了）。

---

## 七、大厅页与屏幕键盘

### 7.1 大厅页可能**没有世界**

客户端的 `world` 要等 `WELCOME` 到了才建。所以大厅分支必须排在
`_draw()` 里 `if world == null: return` **之前**：

```gdscript
if state == St.LOBBY:
    _draw_lobby(vp)
    ...
    return
if world == null:
    return
```

排在后面的话，**客户端的大厅是纯黑屏**。

### 7.2 屏幕键盘：自绘，不用系统软键盘

`PAD_IP`（12 键：数字 + 点 + 退格）与 `PAD_NAME`（40 键：字母 + 数字 + 空格 + 退格）。
坐标抽成纯函数 `lan_keypad_rects(vp)`，背板由命中表反推
（`lan_keypad_panel(vp)`）—— 绘制、命中、测试三边读同一份。

**故意不做中文输入法**：联机里要输的只有 IP 和昵称，为它挂一个输入法远不划算。

### 7.3 键盘是**模态**的

`_menu_press()` 第一件事就是拦键盘：

```gdscript
if _lan_input_key != "":
    for m in lan_keypad_rects(vp):
        if (m["rect"] as Rect2).has_point(pos):
            _lan_input_press(String(m["key"]))
            return
    return          # ★点在键盘外面也不穿透★
```

不拦的话，键盘挡住「加入房间」时会误触发。

### 7.4 表单渲染器新增 `group` 支持

原来 `choice` 行的两套口径是分开的：单人页走 `{group, value}`（改本局选项），
设置页走 `{key, value}`（改持久化设置）。局域网页需要**在同一页里混用**
——所以命中表的 `choice` 项统一带 `group` 字段：

```gdscript
func _form_choice_cur(e: Dictionary) -> String:
    var g := String(e.get("group", ""))
    if g != "": return _menu_cur(g)          # 本局选项
    return _setting_text(String(e.get("key", "")))   # 持久化设置
```

`_menu_press()` 的分流判据必须**同时要求「有 group」且「group 非空」**：

```gdscript
if m.has("group") and String(m["group"]) != "":
    _menu_choose(...)
```

⚠️ 只判 `has("group")` 的话，设置页那些 `choice` 也会命中这里
（命中表统一带了 `group` 字段，值是空串）→ `_menu_choose("", ...)` 什么都不做
→ **设置页所有互斥选项点了都没反应，且不报错**。
这个 bug 在集成时真的发生了（`tests/Menu.gd` 一次红了 8 条）。

### 7.5 本机地址行：只有截图能发现的那个缺陷

主机大厅要把本机地址显示出来，让另一台照着输。第一版是：

```gdscript
var line := " · ".join(NetLink.local_ipv4_list())
_draw_text_center(line, ..., 22.0, Color("8fe36b"))
```

跑 `tests/Shot.gd` 拍出 `30_lobby_host` 之后发现两个问题：

1. **地址太多**：`IP.get_local_addresses()` 在装了 VMware / Hyper-V / WSL 的机器上
   返回 **8 个** IPv4（含 `169.254.*` 这类没拿到 DHCP 的 APIPA）。玩家**不知道该输哪一个** ——
   而「知道输哪一个」正是这一屏存在的唯一理由。
2. **几乎贴住屏幕两边**：实测宽 **1223px**，可用宽度 1240px，占 **98.6%**。

修法两层：

```gdscript
# NetLink：按「像不像一个能连的局域网地址」排序（小的排前面）
#   192.168.* → 0    家用路由器最常见
#   10.* / 172.16~31.* → 1
#   其它 → 5
#   169.254.* → 9   APIPA：没拿到 DHCP，两边基本连不通
static func ip_rank(s: String) -> int
```

```gdscript
# Main：大号只画**一个**，其余最多列 3 个 + 一个总数
func lan_address_lines(p_ips: Array = []) -> Dictionary
#   → {"main": "192.168.1.23", "rest": "169.254.20.33 · 10.0.0.5 · 172.20.10.2 等 8 个", "count": 8}
```

`p_ips` 参数**只给测试用**：不注入的话，「最多列 3 个」这条断言只能靠
「开发机正好有 8 张网卡」才跑得到，换台机器就**静默退化成恒真**。

> ⚠️ **这一节最该记住的是我在写断言时踩的坑。**
> 我第一版断言写的是「8 个地址按 22px 一行会**冲出屏幕**」—— 阳性对照打不红。
> 量下去才发现：真实列表 22px 下是 **1223px**，**并没有溢出**，
> 是我**目测截图**时被「贴住两边」的观感骗了，把「几乎占满」读成了「溢出」。
>
> 最后改成能真正证伪的判据：**大号行只占不到一半屏宽**（实测 156 ≤ 620）——
> 把整串塞回大号行（1186 > 620）就会红。
>
> **教训：截图能告诉你「哪里不对劲」，但「到底超了多少」必须量。**
> 这一条与项目既有的「不要凭印象写死断言」是同一条纪律。

---

## 八、测试：新增三套（57 + 99 + 100 条）

### 8.0 `tests/NetLink.gd`（7 组 / 57 条）

**单进程真 UDP 回环** —— 同一个进程里同时起 host 和 client。
7 组：建立连接 / 双向收发 / **可靠通道按序**（指令不能乱序）/
**不可靠通道**（快照走这里）/ **大包分片**（10 KB 快照）/ 断线感知 / 错误路径。

> ⚠️ 这一套是 M4b 的**第一个交付**，也是「ENet 能不能无头测」这个问题的答案：
> **能，而且是单进程。** 前提是被测代码留好两个口子（时钟虚拟化 + 端口可注入）。

### 8.1 `tests/NetSession.gd`（8 组 / 99 条）

| 组 | 内容 |
| --- | --- |
| 1 | 种子一致性（逐格比 `cells` / `elev` / `ramp` / 资源点） |
| 2 | 握手：HELLO / WELCOME / 归属 / 客户端不把自己的部队当敌人 |
| 3 | 快照下行：计数器 + 单位真的出现 + 数量不超过主机实际拥有 |
| 4 | 指令上行：移动 / 停止 / 建造，主机侧真的执行了 |
| 5 | 拒绝回执：资源不足 / 归属不符 / 理由回传 |
| 6 | 迷雾过滤：客户端看不到视野外的单位 |
| 7 | 断线看门狗：握手超时 / 失联超时 / 优雅退出 |
| 8 | 限流：上限内应用、超出丢弃、**新一帧重新计数** |

**连跑三次全部 99/0 rc=0**（网络测试最怕偶发）。

三条阳性对照全部确认断言可证伪：

| 对照 | 回退内容 | 结果 |
| --- | --- | --- |
| G | 客户端不传地图种子 | 2 红（地形类型图不同 ×2） |
| I | 快照不做迷雾过滤 | 1 红（藏视野外的单位出现在客户端） |
| K | `SNAPSHOT_TIMEOUT` 放大到 600 | 3 红 |

### 8.2 `tests/Lan.gd`（10 组 / 100 条）

| 组 | 内容 |
| --- | --- |
| 1 | 1280×720 上面板装得下 + **每个可点项都在屏内** |
| 2 | 每个按钮都点得到 + 尺寸 |
| 3 | 阵营 / 地图改的是「本局选项」**而不是持久化设置** |
| 4 | 键盘几何：键数 / 在屏内 / 不小于阈值 / **不重叠** / IP 无字母 + 阳性对照 |
| 5 | IP 输入：输入 / 退格 / 确定落盘 / **取消不改值** |
| 6 | 玩家名：带出当前值 / 清空重输 / **空名字回落默认** |
| 7 | 键盘是模态的（点键盘外不穿透） |
| 8 | 空地址不给连（顺手打开 IP 键盘引导玩家） |
| 9 | 创建房间 / 重复创建不顶掉 / 离开清理 / 客户端路径 |
| 10 | 本机地址的**排序与限行**（含阳性对照） |

⚠️ **这一套里坐标一律从 `menu_hit_table()` / `lan_keypad_rects()` 取，
不手工构造 `Rect2`** —— 手工构造只能验证「我以为的坐标」，
验证不了「渲染器实际给出的坐标」。

⚠️ **状态断言一律走 `_eqst()`**（名字表），不要 `_eqs(_main.state, ...)` ——
`St` 是 int 枚举，喂给 `_eqs()` 会抛「Cannot convert argument 1 from int to String」，
**在该函数里它后面所有断言一条都不跑**，却只打一行 SCRIPT ERROR、`_fail` 不动，
看着像「全过了」。

---

## 九、测试结果

`bash tests/run_all.sh`（17 套，**14 分 49 秒**，退出码 0）：

| 套件 | 断言 | 套件 | 断言 |
| --- | ---: | --- | ---: |
| Matchup | 23 | Air | 83 |
| Smoke | 12 | Terrain | 43 |
| Economy | 74 | Creep | 19 |
| Touch | 74 | **Net** | **182** |
| Menu | 63 | **NetLink**（新） | **57** |
| Hud | 121 | **NetSession**（新） | **99** |
| Mods | 110 | **Lan**（新） | **100** |
| Upgrade | 21 | | |
| Ability | 20 | | |
| Build | 12 | | |

**合计 1113 条断言，0 失败。**

单套结果（这一期反复跑过的）：

| 套件 | 结果 | 备注 |
| --- | --- | --- |
| `NetSession` | **99 / 0** rc=0 | **连跑三次全绿**（网络测试最怕偶发） |
| `NetLink` | 57 / 0 rc=0 | — |
| `Lan` | **100 / 0** rc=0 | 从首跑 61/1 → 84/0 → 100/0 |
| `Menu` | 63 / 0 | 集成期曾一次红 8 条（见 §10 bug 5） |
| `Touch` / `Hud` | 74 / 0 · 121 / 0 | — |

---

## 十、这一期抓到的真 bug（全都不报错）

| # | 症状 | 根因 |
| --- | --- | --- |
| 1 | 每一局都是同一张地图；种子链路无法被证伪 | `_generate_map()` 用局部 RNG + 硬编码种子 |
| 2 | 客户端自己的兵是小地图红点、框选不到 | 6 处「本机视角」写死 `PLAYER` |
| 3 | **客户端全程玩着主机那份旧世界** | `_close_session()` 不清 `world` + `_on_lan_ready()` 只在 `world == null` 时接管 |
| 4 | **整页所有按钮都点不到**（看着像布局全错） | `menu_hit_table()` 对 `choice` 行硬读 `e["key"]`，而「本局选项」只有 `group`；**遍历中途**抛异常 → 命中表返回空数组 |
| 5 | 设置页所有互斥选项点了没反应 | `if m.has("group")` 没判空串，设置页的 choice 也被「本局选项」分支吃掉 |
| 6 | 局域网里「我的兵自己乱跑」 | AI 没关，而 AI 指挥的 `ENEMY` 就是客户端本人 |
| 7 | 大厅显示 8 个本机地址、几乎贴住屏幕两边，玩家不知道该输哪个 | 直接把 `local_ipv4_list()` 全拼成一行；地址没排序也没限行 |

> 第 3、4、7 条是**这一期测试 / 截图自己抓出来的**，而且症状都不指向根因：
> 第 4 条看起来像布局崩了，实际只少了一个 `.get()` 默认值；
> 第 7 条**只有截图能发现**（无头环境调不了 `_draw_*`）。

---

## 十一、缺口与后续

1. **没有广播发现。** 现在是手动输 IP。方案里 M4c 才做 UDP 广播
   （「同一 WiFi 自动列出房间」）。
2. **没有大厅内聊天 / 投降 / 暂停 / 断线重连提示。** 断线只到「回到等人加入」
   和一条状态文案。
3. **客户端没有预测。** 手感完全取决于 RTT（局域网通常 < 5 ms，可接受）。
   真要上公网必须做乐观执行 + 序号对齐。
4. **快照没做增量 / 压缩。** 102 KB/s 在局域网上没问题，公网必须降。
5. **只支持 2 人。** 第 3 个连接会被显式拒绝（`_on_connect` 里），
   而不是静默丢弃 —— 静默丢弃的症状是「第三个人进来了但什么都不发生」。
6. **没有存档 / 回放。** 菜单里留了灰掉的入口（用户已确认）。
7. **`_g8_join_guard` 的引导路径**：地址为空时自动打开 IP 键盘，
   但没有把「加入房间」按钮变成「去填地址」——手机上够用，不够精致。
8. **大厅页的按钮只有一个（取消并返回）。** 真正的「准备 / 开始」流程
   要等 M4c 的大厅做完整（现在是主机一收到 WELCOME 就开局）。
9. **真机验证还没做。** 两台设备真的对打一局需要 `godot-android-export`
   打两个 APK 装到两台机器上 —— 属于 M4b-6 之后的验收项。
10. **地址排序只是启发式。** `ip_rank()` 把 `192.168.*` 排最前，在装了虚拟网卡的机器上
    **不保证**真实 WiFi 地址一定排第一（本机实测 8 个地址里 `192.168.2.83` 排第一，是对的）。
   没有「复制到剪贴板」——手机上只能照着抄。真正的解法是 M4c 的广播发现。
11. **`_lan_status` 在主机侧恒为「等待玩家加入…」**，没有区分
    「已连接、正在下发世界」与「真的没人来」两种状态。

---

## 十二、下一步

| 期 | 内容 |
| --- | --- |
| M4c | UDP 广播发现 + 完整大厅（玩家列表 / 准备 / 开始）+ 聊天 / 投降 / 暂停 / 断线提示 |
| M4d | 公网直连（快照压缩 + 客户端预测 + 重连）+ 观战 / 回放 |
