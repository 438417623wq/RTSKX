"""阳性对照驱动器：逐个改坏关键代码，确认 tests/Spell.gd 的断言真的会红。

用法：python pos_control.py
每个对照跑完自动还原。输出每条对照打红的断言标签。
"""
import subprocess, shutil, os, re, sys

PROJ = r"F:/KF/XJ/starcraft-android"
GODOT = r"F:/godot/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
WORLD = os.path.join(PROJ, "assets/scripts/World.gd")
NET = os.path.join(PROJ, "assets/scripts/Net.gd")
UNIT = os.path.join(PROJ, "assets/scripts/Unit.gd")

FILES = [WORLD, NET, UNIT]
BAK = {f: f + ".pcbak" for f in FILES}


def backup():
    for f in FILES:
        shutil.copyfile(f, BAK[f])


def restore():
    for f in FILES:
        shutil.copyfile(BAK[f], f)


def cleanup():
    ## 跑完把备份删掉。放在 restore() **之后**：
    ## 中途被强杀时备份还在，至少能手工还原；正常退出则不留垃圾文件。
    for f in FILES:
        try:
            os.remove(BAK[f])
        except OSError:
            pass


def patch(path, old, new, count=1):
    s = open(path, encoding="utf-8").read()
    if s.count(old) < 1:
        raise SystemExit("PATTERN NOT FOUND in %s:\n%s" % (path, old[:200]))
    s = s.replace(old, new, count)
    open(path, "w", encoding="utf-8", newline="").write(s)


def run_spell():
    out = os.path.join(os.environ.get("TEMP", "/tmp"), "wb_pc.log")
    with open(out, "w", encoding="utf-8") as fh:
        subprocess.run([GODOT, "--headless", "--path", PROJ,
                        "--script", "res://tests/Spell.gd"],
                       stdout=fh, stderr=subprocess.STDOUT, timeout=600)
    txt = open(out, encoding="utf-8", errors="replace").read()
    fails = [l.strip() for l in txt.splitlines() if "[FAIL]" in l]
    total = ""
    for l in txt.splitlines():
        if "通过" in l and "失败" in l:
            total = l.strip()
    return fails, total


## 基线：tests/Spell.gd 正常跑完应该是 98 条断言。
## 改坏代码后如果连这个数都跑不到，说明**脚本没跑起来**（编译不过 / 提前崩），
## 而不是「断言没打红」—— 这两件事必须区分开。
BASELINE_ASSERTS = 98


def ran_count(total):
    m = re.search(r"通过\s*(\d+)\s*/\s*失败\s*(\d+)", total or "")
    return None if not m else int(m.group(1)) + int(m.group(2))


# ---------------------------------------------------------------- 对照组定义
CONTROLS = []


def control(name, expect_hint):
    def deco(fn):
        CONTROLS.append((name, expect_hint, fn))
        return fn
    return deco


@control("C1 心灵风暴按阵营过滤（不再敌我不分）", "圈内自己人也掉血")
def c1():
    patch(WORLD,
          'for u in query_units_near(pos, float(z["radius"])):',
          'for u in query_units_near(pos, float(z["radius"]), 1 - int(z["owner"])):')


@control("C2 dot 退回累加器写法（浮点漂移）", "帧率无关")
def c2():
    # 先在结算循环里把 delta 喂进累加器……
    patch(WORLD,
          '		z["remain"] = float(z["remain"]) - delta\n',
          '		z["remain"] = float(z["remain"]) - delta\n'
          '		z["acc"] = float(z.get("acc", 0.0)) + delta\n')
    # ……再把「由已过去时间推导跳数」整个换成累加器写法。
    #
    # ⚠️ 必须**整段替换**：只改开头两行的话，后面的
    #    `while done < should` 会引用到已经不存在的 `should`，
    #    脚本直接编译不过、测试一条断言都不跑 —— 那不是「打红」，
    #    是「没跑」。阳性对照的坏代码必须仍然是**能编译的**。
    patch(WORLD,
          '	var should := int(floor(_effect_elapsed(z) / GameData.DOT_TICK))\n'
          '	var done := int(z.get("ticks", 0))\n'
          '	if should <= done:\n'
          '		return\n'
          '	# 正常一帧最多补一两跳（delta 远小于 DOT_TICK）。上限是为了防\n'
          '	# 「某次卡顿给出 10 秒 delta」时一帧打出几十跳 —— 那会让血条直接跳没，\n'
          '	# 玩家以为是瞬杀。\n'
          '	var guard := 0\n'
          '	while done < should and guard < 16:\n'
          '		done += 1\n'
          '		guard += 1\n'
          '		_zone_apply_damage(z)\n'
          '	z["ticks"] = done\n',
          '	var acc := float(z.get("acc", 0.0))\n'
          '	var done := int(z.get("ticks", 0))\n'
          '	if acc < GameData.DOT_TICK:\n'
          '		return\n'
          '	z["acc"] = acc - GameData.DOT_TICK\n'
          '	done += 1\n'
          '	_zone_apply_damage(z)\n'
          '	z["ticks"] = done\n')


@control("C3 先判到期、再结算（吞掉最后一跳）", "帧率无关")
def c3():
    patch(WORLD,
          '		if z.has("dps"):\n'
          '			_zone_dot_tick(z)\n'
          '		elif String(z.get("effect", "")) == "no_ranged":\n'
          '			_zone_refresh_no_ranged(z)\n'
          '		if float(z["remain"]) <= SPELL_EXPIRE_EPS:\n'
          '			spell_zones.remove_at(i)\n'
          '			continue\n',
          '		if float(z["remain"]) <= 0.0:\n'
          '			spell_zones.remove_at(i)\n'
          '			continue\n'
          '		if z.has("dps"):\n'
          '			_zone_dot_tick(z)\n'
          '		elif String(z.get("effect", "")) == "no_ranged":\n'
          '			_zone_refresh_no_ranged(z)\n')


@control("C4 去掉开火前的虫群闸门", "挡住远程")
def c4():
    patch(WORLD,
          '		if u.can_fire() and not blocked_by_dark_swarm(u, target):',
          '		if u.can_fire():')


@control("C5 虫群连近战一起挡（变成无敌圈）", "近战照样打得到")
def c5():
    patch(WORLD,
          '	return _weapon_reach(shooter) > GameData.MELEE_RANGE',
          '	return true')


@control("C6 同源效果改成叠加", "同源效果不叠加")
def c6():
    patch(UNIT,
          '	for cur in effects:\n'
          '		var c: Dictionary = cur\n'
          '		if String(c.get("id", "")) == id:',
          '	for cur in effects:\n'
          '		var c: Dictionary = cur\n'
          '		if false:')


@control("C7 快照不再传能量", "快照往返：能量原样还原")
def c7():
    patch(NET, '		buf.u8(clampi(roundi(uu.energy), 0, 255))\n', '')
    patch(NET, '		var energy := r.u8r()\n', '		var energy := 0\n')


@control("C8 快照不再传法术区域", "快照往返：法术区域原样还原")
def c8():
    patch(NET, '	buf.u8(mini(zlist.size(), 255))\n',
          '	buf.u8(0)\n')
    patch(NET, '	var zn := r.u8r()\n', '	var zn := 0\n')


@control("C9 AI 不再避开自己人", "AI 不会把敌我不分的心灵风暴丢在自己人头上")
def c9():
    patch(WORLD, '		if hit_friend:\n			continue\n', '')


@control("C10 辐照不再传染", "辐照传染给身边的同阵营单位")
def c10():
    patch(WORLD,
          '	var spread := float(e.get("spread_radius", 0.0))\n'
          '	if spread <= 0.0:\n'
          '		return\n',
          '	var spread := float(e.get("spread_radius", 0.0))\n'
          '	if spread >= 0.0:\n'
          '		return\n')


# ---------------------------------------------------------------- M6：诱捕网


@control("C11 诱捕网改成持久区域（每帧重新判定谁在圈里）",
         "后来才进入区域的单位完全不受影响")
def c11():
    # ① 不再走「一次性命中」分支 → 像黑暗虫群那样落下一个持久区域
    patch(WORLD,
          '			if bool(sp.get("instant", false)):\n'
          '				_apply_instant_aoe(caster, sid, sp, tpos)\n'
          '				return\n',
          '')
    # ② 让区域每帧给圈内单位续一份短促的减速（照 `_zone_refresh_no_ranged` 的写法）
    patch(WORLD,
          '		elif String(z.get("effect", "")) == "no_ranged":\n'
          '			_zone_refresh_no_ranged(z)\n',
          '		elif String(z.get("effect", "")) == "no_ranged":\n'
          '			_zone_refresh_no_ranged(z)\n'
          '		elif String(z.get("effect", "")) == "slow":\n'
          '			_zone_refresh_slow(z)\n')
    # ③ 补上那个续期函数。**必须用显式类型的局部变量接 `z["pos"]`** ——
    #    直接把它当 `Vector2` 参数传进去会触发类型检查告警，而本项目把告警当错误。
    patch(WORLD,
          'func _tick_unit_effects(delta: float) -> void:',
          'func _zone_refresh_slow(z: Dictionary) -> void:\n'
          '	var zp: Vector2 = z["pos"]\n'
          '	for u in query_units_near(zp, float(z["radius"])):\n'
          '		u.apply_effect({"id": String(z["id"]), "kind": "slow", "remain": 0.35,\n'
          '			"duration": 0.35, "slow_mult": 0.5, "atk_cd_mult": 1.25})\n'
          '\n'
          'func _tick_unit_effects(delta: float) -> void:')


@control("C12 只减速、不降射速（漏掉 atk_cd_mult）",
         "诱捕网同时让武器冷却 +25%")
def c12():
    patch(WORLD,
          '		"slow_mult": float(sp.get("slow_mult", 1.0)),\n'
          '		"atk_cd_mult": float(sp.get("atk_cd_mult", 1.0)),\n',
          '		"slow_mult": float(sp.get("slow_mult", 1.0)),\n')


@control("C13 诱捕网只抓地面（对空无效）", "空中单位同样被抓")
def c13():
    # ⚠️ 锚点必须带上下两行：`var ground_only := ...` 这一句在 World.gd 里
    #    出现了三次（区域伤害 / 虫群续期 / 一次性施法），
    #    只给单行的话 `patch()` 会改掉**第一处**，改错地方。
    patch(WORLD,
          '	var ground_only := String(sp.get("affects", "all")) == "all_ground"\n'
          '	var r2 := radius * radius\n'
          '	var hit := 0\n',
          '	var ground_only := true\n'
          '	var r2 := radius * radius\n'
          '	var hit := 0\n')


@control("C14 AI 用心灵风暴的零容忍判据挑诱捕网落点",
         "圈里有一个自己人、但有四个敌人时 AI 仍然放")
def c14():
    patch(WORLD,
          '		var score := n_foe - n_mine\n'
          '		if score > best_score:\n',
          '		if n_mine > 0:\n'
          '			continue\n'
          '		var score := n_foe - n_mine\n'
          '		if score > best_score:\n')


@control("C15 快照不重建减速参数（客户端解出来不减速）",
         "客户端从本地法术表重建减速倍率与攻速倍率")
def c15():
    # 还原成 M6 之前的样子：只传 id / kind / remain
    patch(NET,
          '			var esp := GameData.get_spell(eid)\n'
          '			efs.append({\n'
          '				"id": eid,\n'
          '				"kind": String(EFFECT_KINDS[clampi(ki, 0, EFFECT_KINDS.size() - 1)]),\n'
          '				"remain": float(erem) / 100.0,\n'
          '				"duration": float(esp.get("duration", float(erem) / 100.0)),\n'
          '				"slow_mult": float(esp.get("slow_mult", 1.0)),\n'
          '				"atk_cd_mult": float(esp.get("atk_cd_mult", 1.0)),\n'
          '			})\n',
          '			efs.append({\n'
          '				"id": eid,\n'
          '				"kind": String(EFFECT_KINDS[clampi(ki, 0, EFFECT_KINDS.size() - 1)]),\n'
          '				"remain": float(erem) / 100.0,\n'
          '				"duration": float(erem) / 100.0,\n'
          '			})\n')


@control("C16 诱捕网按阵营过滤（不再敌我不分）",
         "圈内的自己人也一样被减速")
def c16():
    patch(WORLD,
          '	for u in units:\n'
          '		if not u.alive():\n'
          '			continue\n'
          '		if ground_only and u.is_flying():\n',
          '	for u in units:\n'
          '		if not u.alive():\n'
          '			continue\n'
          '		if u.owner_id == caster.owner_id:\n'
          '			continue\n'
          '		if ground_only and u.is_flying():\n')


@control("C17 攻速倍率写在攻城模式的提前 return 之后",
         "攻城模式下诱捕网同样让冷却")
def c17():
    # 还原成 M5 之前的写法：`if mode == "sieged": return ...` —— 提前返回，
    # 后面那句 `c *= atk_cd_mult()` 永远轮不到。代码能编译、普通兵种也正常，
    # 只有「展开的攻城坦克」这一条会红。
    patch(UNIT,
          '	if mode == "sieged":\n'
          '		c = float(GameData.get_ability("siege").get("attack_cooldown", c))\n'
          '	elif buffs.has("stim"):\n'
          '		c *= float(GameData.get_ability("stim").get("attack_cooldown_mult", 1.0))\n',
          '	if mode == "sieged":\n'
          '		return float(GameData.get_ability("siege").get("attack_cooldown", c))\n'
          '	if buffs.has("stim"):\n'
          '		c *= float(GameData.get_ability("stim").get("attack_cooldown_mult", 1.0))\n')


def main():
    backup()
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    ok = 0
    bad = []
    try:
        for name, hint, fn in CONTROLS:
            if only and name.split()[0] not in only:
                continue
            restore()
            fn()
            fails, total = run_spell()
            ran = ran_count(total)
            hit = [f for f in fails if hint in f]
            if ran is None or ran < BASELINE_ASSERTS:
                # 坏代码编译不过 / 测试提前崩 → 不是「打红」，是「没跑」。
                mark = "XX "
                bad.append(name + "（测试没跑起来，只跑了 %s 条）" % ran)
            elif hit:
                mark = "OK "
                ok += 1
            else:
                mark = "!! "
                bad.append(name)
            print("%s%s  ->  %s" % (mark, name, total))
            for f in fails:
                print("        %s" % f.replace("[FAIL]", "").strip())
            if mark == "XX ":
                print("        ^^ ⚠️ 断言数不足（基线 %d），坏代码大概率编译不过 ——"
                      " 阳性对照的坏代码必须是**能编译的**" % BASELINE_ASSERTS)
            elif not hit:
                print("        ^^ 期望打红的断言（含「%s」）没有出现" % hint)
    finally:
        restore()
        cleanup()
    print("\n打红成功 %d / %d" % (ok, ok + len(bad)))
    if bad:
        print("未打红：" + "; ".join(bad))


main()
