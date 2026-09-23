# -*- coding: utf-8 -*-
"""给 GameData.gd 的 UNITS / BUILDINGS 批量插入 desc 字段。

做法：逐行扫描，遇到 `\t"id": {` 记住当前 id；
在紧随其后的 `"name":` 行之后插入一行 `"desc": "...",`。
只处理 DESC 表里列出的 id，其他字典（FACTIONS / UPGRADES / ABILITIES）不受影响。
幂等：已存在 "desc" 的行会跳过。
"""
import re
import sys

PATH = r"F:/KF/XJ/starcraft-android/assets/scripts/GameData.gd"

DESC = {
    # ---------- 建筑：人族 ----------
    "command_center":     "训练农民并接收资源；提供人口",
    "supply_depot":       "提供人口上限，解锁更多单位",
    "barracks":           "训练陆战队员、劫掠者与医疗兵",
    "factory":            "生产秃鹫与攻城坦克",
    "refinery":           "建在瓦斯矿上，让农民采集瓦斯",
    "engineering_bay":    "研究人族步兵攻防与兴奋剂",
    # ---------- 建筑：虫族 ----------
    "hive":               "虫族主巢，训练工蜂并接收资源",
    "spawning_pool":      "训练跳虫、刺蛇与蟑螂；提供人口",
    "spire":              "生产飞行单位飞龙",
    "extractor":          "建在瓦斯矿上，让工蜂采集瓦斯",
    "evolution_chamber":  "研究虫族地面攻防与甲壳",
    # ---------- 建筑：神族 ----------
    "nexus":              "训练探机并接收资源；提供人口",
    "pylon":              "提供人口与能量场；神族建筑须在其范围内",
    "gateway":            "训练近战单位狂热者",
    "cybernetics_core":   "训练龙骑士，解锁科技升级",
    "templar_archives":   "训练执政官，神族的终极战力",
    "assimilator":        "建在瓦斯矿上，让探机采集瓦斯",
    "forge":              "研究神族攻防与等离子护盾",
    # ---------- 单位：人族 ----------
    "scv":                "农民：采矿、采气与建造建筑",
    "marine":             "人族基础步兵；可用兴奋剂提速",
    "marauder":           "重甲步兵，克制大型单位",
    "siege_tank":         "可展开攻城模式，射程伤害大增",
    "vulture":            "高速侦察与骚扰用的轻型载具",
    "medic":              "自动治疗附近友军；没有攻击力",
    # ---------- 单位：虫族 ----------
    "drone":              "虫族农民：采矿、采气与建造",
    "zergling":           "最便宜最快的近战单位，靠数量",
    "hydralisk":          "虫族远程单位，性价比高",
    "roach":              "皮厚耐打的近战肉盾",
    "mutalisk":           "虫族快速单位，擅长追击",
    # ---------- 单位：神族 ----------
    "probe":              "神族农民：采矿、采气与建造",
    "zealot":             "皮糙肉厚的近战主力",
    "dragoon":            "远程重装单位，攻守兼备",
    "archon":             "护盾极高、伤害巨大的终极单位",
}

# 长度自检：Godot 的 String.length() 对中文按码点计，Python len 一致
bad = {k: len(v) for k, v in DESC.items() if len(v) > 20 or not v}
if bad:
    print("!! 文案超长或为空:", bad)
    sys.exit(1)
dups = [v for v in DESC.values() if list(DESC.values()).count(v) > 1]
if dups:
    print("!! 文案重复:", set(dups))
    sys.exit(1)

lines = open(PATH, encoding="utf-8").read().split("\n")
out = []
cur = None
inserted = []
for ln in lines:
    out.append(ln)
    m = re.match(r'^\t"([a-z_0-9]+)": \{$', ln)
    if m:
        cur = m.group(1)
        continue
    if cur in DESC and '"name":' in ln and '"desc"' not in ln:
        out.append('\t\t"desc": "%s",' % DESC[cur])
        inserted.append(cur)
        cur = None

missing = [k for k in DESC if k not in inserted]
if missing:
    print("!! 没找到这些 id 的 name 行:", missing)
    sys.exit(1)

open(PATH, "w", encoding="utf-8", newline="\n").write("\n".join(out))
print("已插入 %d 条 desc" % len(inserted))
