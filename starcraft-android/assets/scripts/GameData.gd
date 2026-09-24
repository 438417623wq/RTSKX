extends RefCounted
class_name GameData

## 全部游戏静态数据（单位 / 建筑 / 科技 / 阵营）。
## 所有数值集中在此，便于平衡调整。

const ARMOR_TYPES := ["light", "medium", "heavy", "building"]
const DAMAGE_TYPES := ["normal", "explosive", "concussive"]

## 伤害矩阵：DMG_TABLE[damage_type][armor_type]
const DMG_TABLE := {
	"normal":     {"light": 1.0,  "medium": 1.0,  "heavy": 1.0,   "building": 1.0},
	"explosive":  {"light": 0.5,  "medium": 0.75, "heavy": 1.0,   "building": 1.5},
	"concussive": {"light": 1.0,  "medium": 0.75, "heavy": 0.5,   "building": 0.75},
}

const FACTIONS := {
	"terran": {
		"name": "人族 · 自治联盟",
		"short": "人族",
		"color": Color("4a90d9"),
		"color_dim": Color("1d3f63"),
		"accent": Color("8fd0ff"),
		"desc": "攻守均衡，依赖掩体与机械化的正面推进。",
		"worker": "scv",
		"start_units": ["scv", "scv", "scv", "marine"],
		"start_buildings": ["command_center"],
	},
	"zerg": {
		"name": "虫族 · 虫巢意志",
		"short": "虫族",
		"color": Color("9b59b6"),
		"color_dim": Color("4a2560"),
		"accent": Color("d8a8f0"),
		"desc": "数量压制，单位廉价且成形极快，靠洪流取胜。",
		"worker": "drone",
		"start_units": ["drone", "drone", "drone", "zergling"],
		"start_buildings": ["hive"],
	},
	"protoss": {
		"name": "神族 · 达拉姆",
		"short": "神族",
		"color": Color("d4af37"),
		"color_dim": Color("6b5618"),
		"accent": Color("ffe58a"),
		"desc": "单位昂贵但极强，带等离子护盾，人口效率最高。",
		"worker": "probe",
		"start_units": ["probe", "probe", "probe", "zealot"],
		"start_buildings": ["nexus"],
	},
}

const _BASE_UNITS := {
	# ---------- 人族 ----------
	"scv": {
		"name": "SCV", "faction": "terran", "role": "worker",
		"desc": "农民：采矿、采气与建造建筑",
		"hp": 45, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 5, "damage_type": "normal", "range": 40.0, "cooldown": 0.9,
		"speed": 88.0, "sight": 190.0, "cost_m": 50, "supply": 1, "build_time": 8.0,
		"size": 7.0, "can_harvest": true, "harvest_rate": 7.0,
	},
	"marine": {
		"name": "陆战队员", "faction": "terran", "role": "combat",
		"desc": "人族基础步兵；可用兴奋剂提速",
		"hp": 85, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 12, "damage_type": "normal", "range": 130.0, "cooldown": 0.65,
		"speed": 98.0, "sight": 230.0, "cost_m": 50, "supply": 1, "build_time": 9.0,
		"size": 7.0, "weapon": "bullet", "abilities": ["stim"],
	},
	"marauder": {
		"name": "劫掠者", "faction": "terran", "role": "combat",
		"desc": "重甲步兵，克制大型单位",
		"hp": 160, "shield": 0, "armor": 1, "armor_type": "medium",
		"damage": 28, "damage_type": "concussive", "range": 145.0, "cooldown": 1.5,
		"speed": 82.0, "sight": 230.0, "cost_m": 100, "cost_g": 25, "supply": 2, "build_time": 16.0,
		"size": 9.0, "weapon": "shell", "requires": "barracks",
	},
	"siege_tank": {
		"name": "攻城坦克", "faction": "terran", "role": "combat",
		"desc": "可展开攻城模式，射程伤害大增",
		"hp": 260, "shield": 0, "armor": 2, "armor_type": "heavy",
		"damage": 55, "damage_type": "explosive", "range": 205.0, "cooldown": 2.4,
		"speed": 62.0, "sight": 250.0, "cost_m": 180, "cost_g": 100, "supply": 3, "build_time": 28.0,
		"size": 12.0, "weapon": "cannon", "requires": "factory", "abilities": ["siege"],
	},
	"vulture": {
		"name": "秃鹫", "faction": "terran", "role": "combat",
		"desc": "高速侦察与骚扰用的轻型载具",
		"hp": 90, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 18, "damage_type": "concussive", "range": 120.0, "cooldown": 1.1,
		"speed": 155.0, "sight": 260.0, "cost_m": 75, "supply": 2, "build_time": 14.0,
		"size": 9.0, "weapon": "bullet", "requires": "factory",
	},
	"medic": {
		# damage 为 0：World 的索敌逻辑必须跳过零伤害单位，
		# 否则医疗兵会去找敌人「开火」并射出零伤害弹道。
		"name": "医疗兵", "faction": "terran", "role": "support",
		"desc": "自动治疗附近友军；没有攻击力",
		"hp": 60, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 0, "damage_type": "normal", "range": 0.0, "cooldown": 1.0,
		"speed": 100.0, "sight": 240.0, "cost_m": 50, "cost_g": 25, "supply": 1,
		"build_time": 12.0, "size": 7.0,
		"energy": 200.0, "abilities": ["heal"], "requires": "barracks",
	},
	"wraith": {
		"name": "幽灵战机", "faction": "terran", "role": "combat",
		"desc": "空中单位：快而脆，对空对地都好用",
		"hp": 110, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 20, "damage_type": "explosive", "range": 165.0, "cooldown": 1.0,
		"speed": 190.0, "sight": 290.0, "cost_m": 100, "cost_g": 75, "supply": 2, "build_time": 20.0,
		"size": 9.0, "weapon": "laser", "requires": "factory",
	},
	"science_vessel": {
		# damage 为 0：纯施法单位，没有攻击力（和医疗兵同理，
		# 索敌逻辑必须跳过零伤害单位，否则它会去找敌人「开火」）。
		"name": "科学球", "faction": "terran", "role": "support",
		"desc": "空中施法：辐照并传染给友军",
		"hp": 200, "shield": 0, "armor": 1, "armor_type": "heavy",
		"damage": 0, "damage_type": "normal", "range": 0.0, "cooldown": 1.0,
		"speed": 130.0, "sight": 300.0, "cost_m": 100, "cost_g": 225, "supply": 2,
		"build_time": 30.0, "size": 11.0,
		"energy": 200.0, "abilities": ["irradiate"], "requires": "factory",
	},

	# ---------- 虫族 ----------
	"drone": {
		"name": "工蜂", "faction": "zerg", "role": "worker",
		"desc": "虫族农民：采矿、采气与建造",
		"hp": 40, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 5, "damage_type": "normal", "range": 36.0, "cooldown": 1.0,
		"speed": 92.0, "sight": 190.0, "cost_m": 50, "supply": 1, "build_time": 7.0,
		"size": 7.0, "can_harvest": true, "harvest_rate": 7.0,
	},
	"zergling": {
		"name": "跳虫", "faction": "zerg", "role": "combat",
		"desc": "最便宜最快的近战单位，靠数量",
		"hp": 55, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 10, "damage_type": "normal", "range": 34.0, "cooldown": 0.5,
		"speed": 155.0, "sight": 210.0, "cost_m": 25, "supply": 1, "build_time": 5.0,
		"size": 6.0, "weapon": "claw",
	},
	"hydralisk": {
		"name": "刺蛇", "faction": "zerg", "role": "combat",
		"desc": "虫族远程单位，性价比高",
		"hp": 90, "shield": 0, "armor": 1, "armor_type": "light",
		"damage": 16, "damage_type": "explosive", "range": 140.0, "cooldown": 0.8,
		"speed": 90.0, "sight": 230.0, "cost_m": 75, "cost_g": 25, "supply": 2, "build_time": 14.0,
		"size": 8.0, "weapon": "spine", "requires": "spawning_pool",
	},
	"roach": {
		"name": "蟑螂", "faction": "zerg", "role": "combat",
		"desc": "皮厚耐打的近战肉盾",
		"hp": 200, "shield": 0, "armor": 2, "armor_type": "medium",
		"damage": 26, "damage_type": "explosive", "range": 105.0, "cooldown": 1.3,
		"speed": 78.0, "sight": 220.0, "cost_m": 100, "cost_g": 40, "supply": 3, "build_time": 20.0,
		"size": 10.0, "weapon": "acid", "requires": "spawning_pool",
	},
	"mutalisk": {
		"name": "飞龙", "faction": "zerg", "role": "combat",
		"desc": "空中单位：虫族主力空军，兼顾对空对地",
		"hp": 120, "shield": 0, "armor": 0, "armor_type": "light",
		"damage": 22, "damage_type": "explosive", "range": 150.0, "cooldown": 1.2,
		"speed": 175.0, "sight": 280.0, "cost_m": 100, "cost_g": 100, "supply": 2, "build_time": 22.0,
		"size": 9.0, "weapon": "glave", "requires": "spire",
	},
	"defiler": {
		"name": "蝎子", "faction": "zerg", "role": "support",
		"desc": "地面施法：黑暗虫群免疫远程",
		"hp": 80, "shield": 0, "armor": 1, "armor_type": "medium",
		"damage": 0, "damage_type": "normal", "range": 0.0, "cooldown": 1.0,
		"speed": 60.0, "sight": 230.0, "cost_m": 50, "cost_g": 150, "supply": 2,
		"build_time": 25.0, "size": 10.0,
		"energy": 200.0, "abilities": ["dark_swarm"], "requires": "spire",
	},
	"queen": {
		# 和星际 1 一样是**空中**施法单位：能跟队、不会被地面近战直接围死，
		# 代价是它自己一点攻击力都没有。
		"name": "虫后", "faction": "zerg", "role": "support",
		"desc": "空中施法：诱捕网让区域内单位变慢",
		"hp": 120, "shield": 0, "armor": 1, "armor_type": "medium",
		"damage": 0, "damage_type": "normal", "range": 0.0, "cooldown": 1.0,
		"speed": 90.0, "sight": 260.0, "cost_m": 100, "cost_g": 100, "supply": 2,
		"build_time": 26.0, "size": 11.0,
		"energy": 200.0, "abilities": ["ensnare"], "requires": "queen_nest",
	},

	# ---------- 神族 ----------
	"probe": {
		"name": "探机", "faction": "protoss", "role": "worker",
		"desc": "神族农民：采矿、采气与建造",
		"hp": 40, "shield": 20, "armor": 0, "armor_type": "light",
		"damage": 5, "damage_type": "normal", "range": 36.0, "cooldown": 1.0,
		"speed": 92.0, "sight": 190.0, "cost_m": 50, "supply": 1, "build_time": 8.0,
		"size": 7.0, "can_harvest": true, "harvest_rate": 7.0,
	},
	"zealot": {
		"name": "狂热者", "faction": "protoss", "role": "combat",
		"desc": "皮糙肉厚的近战主力",
		"hp": 130, "shield": 100, "armor": 2, "armor_type": "medium",
		"damage": 36, "damage_type": "normal", "range": 46.0, "cooldown": 0.85,
		"speed": 112.0, "sight": 220.0, "cost_m": 100, "supply": 2, "build_time": 14.0,
		"size": 9.0, "weapon": "psiblade",
	},
	"dragoon": {
		"name": "龙骑士", "faction": "protoss", "role": "combat",
		"desc": "远程重装单位，攻守兼备",
		"hp": 120, "shield": 110, "armor": 2, "armor_type": "medium",
		"damage": 38, "damage_type": "explosive", "range": 155.0, "cooldown": 1.15,
		"speed": 88.0, "sight": 240.0, "cost_m": 125, "cost_g": 50, "supply": 2, "build_time": 18.0,
		"size": 10.0, "weapon": "phase", "requires": "cybernetics_core",
	},
	"archon": {
		"name": "执政官", "faction": "protoss", "role": "combat",
		"desc": "护盾极高、伤害巨大的终极单位",
		"hp": 10, "shield": 400, "armor": 3, "armor_type": "heavy",
		"damage": 70, "damage_type": "normal", "range": 100.0, "cooldown": 0.85,
		"speed": 95.0, "sight": 260.0, "cost_m": 175, "cost_g": 175, "supply": 4, "build_time": 28.0,
		"size": 11.0, "weapon": "psionic", "requires": "templar_archives",
	},
	"high_templar": {
		"name": "圣堂武士", "faction": "protoss", "role": "support",
		"desc": "地面施法：心灵风暴敌我不分",
		"hp": 40, "shield": 40, "armor": 0, "armor_type": "light",
		"damage": 0, "damage_type": "normal", "range": 0.0, "cooldown": 1.0,
		"speed": 62.0, "sight": 240.0, "cost_m": 50, "cost_g": 150, "supply": 2,
		"build_time": 22.0, "size": 8.0,
		"energy": 200.0, "abilities": ["psionic_storm"], "requires": "templar_archives",
	},
	"scout": {
		"name": "侦察机", "faction": "protoss", "role": "combat",
		"desc": "重型空中单位：贵而硬，对空火力最强",
		"hp": 150, "shield": 100, "armor": 1, "armor_type": "medium",
		"damage": 30, "damage_type": "explosive", "range": 170.0, "cooldown": 1.3,
		"speed": 130.0, "sight": 300.0, "cost_m": 200, "cost_g": 125, "supply": 3, "build_time": 30.0,
		"size": 11.0, "weapon": "missile", "requires": "stargate",
	},
}

const _BASE_BUILDINGS := {
	# ---------- 人族 ----------
	"command_center": {
		"name": "指挥中心", "faction": "terran", "hp": 1500, "armor": 2, "armor_type": "building",
		"desc": "训练农民并接收资源；提供人口",
		"size": 34.0, "cost_m": 400, "build_time": 40.0, "sight": 300.0,
		"provides_supply": 10, "dropoff": true, "trains": ["scv"], "pop_dist": 2.0,
	},
	"supply_depot": {
		"name": "补给站", "faction": "terran", "hp": 500, "armor": 2, "armor_type": "building",
		"desc": "提供人口上限，解锁更多单位",
		"size": 22.0, "cost_m": 100, "build_time": 15.0, "sight": 150.0,
		"provides_supply": 8, "pop_dist": 2.2,
	},
	"barracks": {
		"name": "兵营", "faction": "terran", "hp": 1000, "armor": 2, "armor_type": "building",
		"desc": "训练陆战队员、劫掠者与医疗兵",
		"size": 28.0, "cost_m": 150, "build_time": 26.0, "sight": 200.0,
		"trains": ["marine", "marauder", "medic"], "pop_dist": 2.4,
	},
	"factory": {
		"name": "重工厂", "faction": "terran", "hp": 1250, "armor": 2, "armor_type": "building",
		"desc": "生产秃鹫、攻城坦克与幽灵战机",
		"size": 32.0, "cost_m": 200, "cost_g": 100, "build_time": 36.0, "sight": 200.0,
		"trains": ["vulture", "siege_tank", "wraith", "science_vessel"], "requires": "barracks", "pop_dist": 2.6,
	},
	"refinery": {
		"name": "精炼厂", "faction": "terran", "hp": 600, "armor": 2, "armor_type": "building",
		"desc": "建在瓦斯矿上，让农民采集瓦斯",
		"size": 24.0, "cost_m": 75, "build_time": 18.0, "sight": 160.0,
		"gas_building": true, "pop_dist": 2.2,
	},
	"engineering_bay": {
		# 不带 trains 字段 —— 开局赠送军事建筑靠「第一个带 trains 的条目」查找，
		# 新建筑必须放在 BUILD_MENU 末尾且不带 trains，否则会顶掉兵营。
		"name": "工程湾", "faction": "terran", "hp": 850, "armor": 2, "armor_type": "building",
		"desc": "研究人族步兵攻防与兴奋剂",
		"size": 28.0, "cost_m": 125, "build_time": 25.0, "sight": 180.0,
		"pop_dist": 2.4,
	},
	"missile_turret": {
		"name": "导弹塔", "faction": "terran", "hp": 400, "armor": 2, "armor_type": "building",
		"desc": "只对空的防御建筑，用来保护矿区",
		"size": 20.0, "cost_m": 75, "build_time": 16.0, "sight": 280.0,
		"damage": 20, "damage_type": "explosive", "range": 195.0, "cooldown": 0.9,
		"pop_dist": 2.2,
	},

	# ---------- 虫族 ----------
	"hive": {
		"name": "虫巢", "faction": "zerg", "hp": 1500, "armor": 2, "armor_type": "building",
		"desc": "虫族主巢，训练工蜂并接收资源",
		"size": 34.0, "cost_m": 400, "build_time": 40.0, "sight": 300.0,
		"provides_supply": 10, "dropoff": true, "trains": ["drone"], "pop_dist": 2.0,
	},
	"spawning_pool": {
		"name": "孵化池", "faction": "zerg", "hp": 800, "armor": 2, "armor_type": "building",
		"desc": "训练跳虫、刺蛇与蟑螂；提供人口",
		"size": 26.0, "cost_m": 150, "build_time": 24.0, "sight": 180.0,
		"trains": ["zergling", "hydralisk", "roach"], "provides_supply": 10, "pop_dist": 2.4,
	},
	"spire": {
		"name": "尖塔", "faction": "zerg", "hp": 900, "armor": 2, "armor_type": "building",
		"desc": "生产飞行单位飞龙",
		"size": 26.0, "cost_m": 200, "cost_g": 150, "build_time": 34.0, "sight": 200.0,
		"trains": ["mutalisk", "defiler"], "requires": "spawning_pool", "pop_dist": 2.6,
	},
	"queen_nest": {
		"name": "虫后巢穴", "faction": "zerg", "hp": 850, "armor": 2, "armor_type": "building",
		"desc": "训练虫后（诱捕网）",
		"size": 26.0, "cost_m": 150, "cost_g": 100, "build_time": 30.0, "sight": 180.0,
		"trains": ["queen"], "requires": "spire", "pop_dist": 2.4,
	},
	"extractor": {
		"name": "萃取房", "faction": "zerg", "hp": 600, "armor": 2, "armor_type": "building",
		"desc": "建在瓦斯矿上，让工蜂采集瓦斯",
		"size": 24.0, "cost_m": 75, "build_time": 18.0, "sight": 160.0,
		"gas_building": true, "pop_dist": 2.2,
	},
	"evolution_chamber": {
		"name": "进化腔", "faction": "zerg", "hp": 750, "armor": 2, "armor_type": "building",
		"desc": "研究虫族地面攻防与甲壳",
		"size": 26.0, "cost_m": 75, "build_time": 20.0, "sight": 180.0,
		"pop_dist": 2.2,
	},
	"spore_colony": {
		"name": "孢子菌落", "faction": "zerg", "hp": 400, "armor": 2, "armor_type": "building",
		"desc": "只对空的防御建筑，需要孵化池前置",
		"size": 20.0, "cost_m": 75, "build_time": 16.0, "sight": 280.0,
		"damage": 15, "damage_type": "explosive", "range": 185.0, "cooldown": 1.0, "weapon": "acid",
		"requires": "spawning_pool", "pop_dist": 2.2,
	},

	# ---------- 神族 ----------
	"nexus": {
		"name": "星灵枢纽", "faction": "protoss", "hp": 1500, "armor": 2, "armor_type": "building",
		"desc": "训练探机并接收资源；提供人口",
		"size": 34.0, "cost_m": 400, "build_time": 40.0, "sight": 300.0,
		"provides_supply": 10, "dropoff": true, "trains": ["probe"], "pop_dist": 2.0,
	},
	"pylon": {
		"name": "水晶塔", "faction": "protoss", "hp": 400, "armor": 2, "armor_type": "building",
		"desc": "提供人口与能量场；神族建筑须在其范围内",
		"size": 20.0, "cost_m": 100, "build_time": 16.0, "sight": 200.0,
		"provides_supply": 8, "pop_dist": 2.2,
	},
	"gateway": {
		"name": "传送门", "faction": "protoss", "hp": 1000, "armor": 2, "armor_type": "building",
		"desc": "训练近战单位狂热者",
		"size": 28.0, "cost_m": 125, "build_time": 22.0, "sight": 200.0,
		"trains": ["zealot"], "pop_dist": 2.4,
	},
	"cybernetics_core": {
		"name": "机械控制核心", "faction": "protoss", "hp": 1000, "armor": 2, "armor_type": "building",
		"desc": "训练龙骑士，解锁科技升级",
		"size": 28.0, "cost_m": 100, "build_time": 22.0, "sight": 200.0,
		"trains": ["dragoon"], "requires": "gateway", "pop_dist": 2.5,
	},
	"templar_archives": {
		"name": "圣堂文库", "faction": "protoss", "hp": 900, "armor": 2, "armor_type": "building",
		"desc": "训练执政官，神族的终极战力",
		"size": 26.0, "cost_m": 150, "cost_g": 150, "build_time": 28.0, "sight": 200.0,
		"trains": ["archon", "high_templar"], "requires": "cybernetics_core", "pop_dist": 2.6,
	},
	"assimilator": {
		"name": "吸收塔", "faction": "protoss", "hp": 600, "armor": 2, "armor_type": "building",
		"desc": "建在瓦斯矿上，让探机采集瓦斯",
		"size": 24.0, "cost_m": 75, "build_time": 18.0, "sight": 160.0,
		"gas_building": true, "pop_dist": 2.2,
	},
	"forge": {
		"name": "熔炉", "faction": "protoss", "hp": 550, "armor": 2, "armor_type": "building",
		"desc": "研究神族攻防与等离子护盾",
		"size": 24.0, "cost_m": 150, "build_time": 22.0, "sight": 180.0,
		"pop_dist": 2.2,
	},
	"photon_cannon": {
		"name": "光子炮台", "faction": "protoss", "hp": 450, "armor": 2, "armor_type": "building",
		"desc": "对空对地的防御建筑，须建在能量场内",
		"size": 20.0, "cost_m": 150, "build_time": 20.0, "sight": 280.0,
		"damage": 20, "damage_type": "normal", "range": 185.0, "cooldown": 1.1, "weapon": "phase",
		"requires": "forge", "pop_dist": 2.4,
	},
	"stargate": {
		"name": "星际之门", "faction": "protoss", "hp": 1000, "armor": 2, "armor_type": "building",
		"desc": "生产重型空中单位侦察机",
		"size": 30.0, "cost_m": 175, "cost_g": 100, "build_time": 30.0, "sight": 200.0,
		"trains": ["scout"], "requires": "cybernetics_core", "pop_dist": 2.6,
	},
}

## 建筑建造菜单（每个阵营可造的建筑及其解锁条件）
## ⚠️ 新建筑一律追加在**末尾**：World._mil_building_for() 取「第一个带 trains 的条目」
##    作为开局赠送的军事建筑，插在前面会顶掉兵营。
const BUILD_MENU := {
	"terran": [
		{"id": "supply_depot", "requires": null},
		{"id": "refinery", "requires": null},
		{"id": "barracks", "requires": null},
		{"id": "factory", "requires": "barracks"},
		{"id": "engineering_bay", "requires": null},
		{"id": "missile_turret", "requires": null},
	],
	"zerg": [
		{"id": "extractor", "requires": null},
		{"id": "spawning_pool", "requires": null},
		{"id": "spire", "requires": "spawning_pool"},
		# ⚠️ 虫后巢穴的 `requires` 是 **spire 而不是 hive**。
		#    虫族的 `hive` 是**起始建筑**（见 FACTIONS.zerg.start_buildings），
		#    写 `requires: "hive"` 等于没有任何门槛 —— 虫后开局就能造，
		#    而它 25 秒的群体减速 + 降射速在早期是没有制衡的。
		#    挂在 spire 下面和蝎子同一层，既符合「虫后是高科技兵种」，
		#    也让这条科技线有真正的代价（200/150 的尖塔）。
		{"id": "queen_nest", "requires": "spire"},
		{"id": "evolution_chamber", "requires": null},
		{"id": "spore_colony", "requires": "spawning_pool"},
	],
	"protoss": [
		{"id": "pylon", "requires": null},
		{"id": "assimilator", "requires": null},
		{"id": "gateway", "requires": null},
		{"id": "cybernetics_core", "requires": "gateway"},
		{"id": "templar_archives", "requires": "cybernetics_core"},
		{"id": "forge", "requires": null},
		{"id": "photon_cannon", "requires": "forge"},
		{"id": "stargate", "requires": "cybernetics_core"},
	],
}

## 各阵营的「补给建筑」与「气矿建筑」——AI 和测试都靠这两个查表，避免各处硬编码
const SUPPLY_BUILDING := {"terran": "supply_depot", "zerg": "spawning_pool", "protoss": "pylon"}
const GAS_BUILDING := {"terran": "refinery", "zerg": "extractor", "protoss": "assimilator"}

## 虫族单位站在菌毯上的移速倍率（星际 1 里虫族在菌毯上跑得更快）。
##
## ⚠️ 这个数值放在 GameData 而不是 World：Unit.speed() 要读它，
##    而 Unit 不该反向依赖 World（那会绕出一圈类引用）。
##    这也是「所有静态数值集中在 GameData」这条铁律的具体应用。
const CREEP_SPEED_MULT := 1.30

## 站在高地上的单位获得的加成。
##
## 视野 +1 格、射程 +1 格（1 格 = 24px，和星际 1「+1 格视野」同语义）。
## 高地本来就是「单向透明」的观察点（低地看不见高地），
## 再给一点射程，站上去才真的有「居高临下」的收益。
##
## ⚠️ 射程对**近战**单位比例上很大（狂热者 34 → 58，+70%）。这是刻意的，
##    但它会明显增强高地单位的输出 —— 改这两个数之后必须跑平衡对局，
##    而且**要跑两轮取累计**：单轮 5 局的波动就有 ±1 局，判不出真实变化。
const HIGH_GROUND_SIGHT_BONUS := 24.0
const HIGH_GROUND_RANGE_BONUS := 24.0

static func supply_building(race: String) -> String:
	return SUPPLY_BUILDING.get(race, "supply_depot")

static func gas_building(race: String) -> String:
	return GAS_BUILDING.get(race, "refinery")

## 各阵营的防空建筑。AI 与测试统一走 aa_building()，不要各处硬编码。
const AA_BUILDING := {"terran": "missile_turret", "zerg": "spore_colony", "protoss": "photon_cannon"}

static func aa_building(race: String) -> String:
	return AA_BUILDING.get(race, "")

static func get_unit(id: String) -> Dictionary:
	return UNITS.get(id, {})
static func get_building(id: String) -> Dictionary:
	return BUILDINGS.get(id, {})

static func is_unit(id: String) -> bool:
	return UNITS.has(id)

static func is_building(id: String) -> bool:
	return BUILDINGS.has(id)

## 返回该阵营当前已解锁的可训练单位
static func available_units(faction: String, built: Dictionary) -> Array:
	var out := []
	for uid in UNITS:
		var u: Dictionary = UNITS[uid]
		if u.get("faction", "") != faction:
			continue
		var req = u.get("requires", null)
		if req != null and not built.has(req):
			continue
		out.append(uid)
	return out

## 返回该阵营当前可建造的建筑
static func available_buildings(faction: String, built: Dictionary) -> Array:
	var out := []
	for entry in BUILD_MENU.get(faction, []):
		var req = entry.get("requires", null)
		if req != null and not built.has(req):
			continue
		out.append(entry["id"])
	return out

# ================================================================ 空中维度

## 空 / 地规则表。
##
## 单独一张表、而不是给 UNITS 里每个单位加字段 —— 理由和 UPGRADE_CLASS 一样：
## 「谁能打空、谁在天上飞」是一个**集合**，集中放才看得出全貌，
## 混进单位定义会让两张表都变难读。
##
## 缺省（不在表里的 id）：地面单位，只能打地面。
##   flying        —— 这个单位在空中（直线移动、不被地面近战锁定、不参与采集与建造）
##   attack_air    —— 能打到空中的目标
##   attack_ground —— 能打到地面的目标
##
## 攻击型建筑也在这张表里（建筑与单位的 id 不冲突）。
##
## ⚠️ 漏掉这里的后果极具误导性：整队跳虫会追着一架飞龙绕地图跑、而且永远追不上，
## 看上去像「AI 变傻了」。改这张表必须重跑 tests/Air.gd。
const AIR_RULES := {
	# ---- 能对空的地面单位（星际 1 的四把「对空枪」）----
	"marine":    {"attack_air": true},
	"hydralisk": {"attack_air": true},
	"dragoon":   {"attack_air": true},
	"archon":    {"attack_air": true},
	# ---- 空中单位 ----
	"mutalisk": {"flying": true, "attack_air": true},
	"wraith":   {"flying": true, "attack_air": true},
	"scout":    {"flying": true, "attack_air": true},
	# 科学球在**天上**，但 damage 为 0 —— 它没有攻击能力，
	# 所以 attack_air / attack_ground 都不写（缺省 attack_ground = true，
	# 但 Unit.is_combat() 会先把它挡在索敌之外，两个判据不冲突）。
	# ⚠️ 漏掉 `flying: true` 的话，科学球会变成一只「在地面上飘的胖球」，
	#    而且会被地面近战单位锁定追打 —— 不报错，只是看起来很怪。
	"science_vessel": {"flying": true},
	# 虫后同样在**天上**、同样 damage 为 0 —— 理由和科学球一字不差。
	# ⚠️ 忘了 `flying: true` 的话，虫后会在地面上飘着被跳虫围死，
	#    而且「诱捕网」这个技能原本就是设计给「跟着大部队飞的支援单位」的。
	"queen": {"flying": true},
	# ---- 攻击型建筑 ----
	"missile_turret": {"attack_air": true, "attack_ground": false},
	"spore_colony":   {"attack_air": true, "attack_ground": false},
	"photon_cannon":  {"attack_air": true, "attack_ground": true},
}

static func air_rule(id: String) -> Dictionary:
	return AIR_RULES.get(id, {})

## 是否在空中飞行
static func is_flying(id: String) -> bool:
	return bool(AIR_RULES.get(id, {}).get("flying", false))

## 能否攻击空中的目标
static func can_attack_air(id: String) -> bool:
	return bool(AIR_RULES.get(id, {}).get("attack_air", false))

## 能否攻击地面的目标。缺省 true —— 绝大多数单位都能打地面。
static func can_attack_ground(id: String) -> bool:
	return bool(AIR_RULES.get(id, {}).get("attack_ground", true))

## 伤害计算。
##
## atk_bonus / def_bonus 是攻防升级带来的加成，默认为 0 —— 所以现有调用点不用改。
## 加成位置很重要：**攻击加在 base 上、护甲加在 armor 上**，保持「先乘后减」。
## 如果把攻击加成放到乘区之后，爆炸伤害打轻甲会变得离谱。
static func compute_damage(base: float, damage_type: String, armor_type: String,
		target_armor: int, atk_bonus: int = 0, def_bonus: int = 0) -> float:
	var mult: float = DMG_TABLE.get(damage_type, {}).get(armor_type, 1.0)
	return maxf(1.0, (base + float(atk_bonus)) * mult - float(target_armor + def_bonus))

# ================================================================ 科技升级

## 单位 → 吃哪一套攻防升级。
## 单独一张表，不给 UNITS 里每个单位加字段 —— 升级分类是「科技系统」的概念，
## 混进单位定义会让两张表都变难读。
const UPGRADE_CLASS := {
	# 人族：步兵 / 载具
	"scv": "infantry", "marine": "infantry", "marauder": "infantry", "medic": "infantry",
	"vulture": "vehicle", "siege_tank": "vehicle", "wraith": "vehicle",
	"science_vessel": "vehicle",
	# 虫族：近战 / 远程 / 空中
	"drone": "melee", "zergling": "melee",
	"hydralisk": "missile", "roach": "missile",
	"mutalisk": "air",
	# 虫后也是空中单位，跟飞龙同一条线。
	# ⚠️ 它和蝎子一样没有攻击力，但**表必须完整** —— 漏一个 id 就是
	#    「升了级但没生效」，不报错，只是那 100 矿气白花。
	"queen": "air",
	# 蝎子是地面单位，吃地面远程那条线（虽然它本身没有攻击力，
	# 但攻防升级表必须完整 —— 漏一个 id 就是「升了级但没生效」，不报错）。
	"defiler": "missile",
	# 神族：地面（执政官不吃攻防升级，和 SC1 一致）
	"probe": "ground", "zealot": "ground", "dragoon": "ground",
	"high_templar": "ground",
	"archon": "none",
	# ⚠️ 侦察机暂归 "ground" —— 神族目前只有一条攻击升级线（地面武器 / 护甲）。
	#    独立的神族空军升级线（SC1 里在机库）留到空军科技树展开时再拆，
	#    现在就加会让平衡基线无谓地抖动一次。
	#    ⚠️ 同理，虫族的 "air" 目前只有 carapace 吃得到，没有对应的空中攻击线。
	"scout": "ground",
}

## 科技升级表。
##
## 两种 kind：
##   "level"  —— 等级链，可叠加，每级 +1（攻 / 防 / 护盾）
##   "unlock" —— 只升一次，作用是给单位开一个技能（如兴奋剂）
##
## applies_to 是 UPGRADE_CLASS 的取值列表；"shielded" 是特殊值，
## 表示「任何有护盾的单位」，用于神族等离子护盾。
const _BASE_UPGRADES := {
	# ---------------- 人族 ----------------
	"infantry_weapons": {
		"name": "步兵武器", "faction": "terran", "kind": "level", "max_level": 3,
		"effect": "attack", "applies_to": ["infantry"],
		"requires": "engineering_bay",
		"levels": [
			{"cost_m": 100, "cost_g": 100, "time": 55.0},
			{"cost_m": 175, "cost_g": 175, "time": 70.0},
			{"cost_m": 250, "cost_g": 250, "time": 85.0},
		],
	},
	"infantry_armor": {
		"name": "步兵护甲", "faction": "terran", "kind": "level", "max_level": 3,
		"effect": "armor", "applies_to": ["infantry"],
		"requires": "engineering_bay",
		"levels": [
			{"cost_m": 100, "cost_g": 100, "time": 55.0},
			{"cost_m": 175, "cost_g": 175, "time": 70.0},
			{"cost_m": 250, "cost_g": 250, "time": 85.0},
		],
	},
	"stim_pack": {
		"name": "兴奋剂", "faction": "terran", "kind": "unlock", "max_level": 1,
		"effect": "unlock", "unlocks": "stim", "applies_to": ["infantry"],
		"requires": "engineering_bay",
		"levels": [{"cost_m": 100, "cost_g": 100, "time": 65.0}],
	},

	# ---------------- 虫族 ----------------
	"melee_attacks": {
		"name": "近战攻击", "faction": "zerg", "kind": "level", "max_level": 3,
		"effect": "attack", "applies_to": ["melee"],
		"requires": "evolution_chamber",
		"levels": [
			{"cost_m": 100, "cost_g": 100, "time": 55.0},
			{"cost_m": 150, "cost_g": 150, "time": 70.0},
			{"cost_m": 200, "cost_g": 200, "time": 85.0},
		],
	},
	"missile_attacks": {
		"name": "远程攻击", "faction": "zerg", "kind": "level", "max_level": 3,
		"effect": "attack", "applies_to": ["missile"],
		"requires": "evolution_chamber",
		"levels": [
			{"cost_m": 100, "cost_g": 100, "time": 55.0},
			{"cost_m": 150, "cost_g": 150, "time": 70.0},
			{"cost_m": 200, "cost_g": 200, "time": 85.0},
		],
	},
	"carapace": {
		"name": "甲壳", "faction": "zerg", "kind": "level", "max_level": 3,
		"effect": "armor", "applies_to": ["melee", "missile", "air"],
		"requires": "evolution_chamber",
		"levels": [
			{"cost_m": 150, "cost_g": 150, "time": 65.0},
			{"cost_m": 225, "cost_g": 225, "time": 80.0},
			{"cost_m": 300, "cost_g": 300, "time": 95.0},
		],
	},

	# ---------------- 神族 ----------------
	"ground_weapons": {
		"name": "地面武器", "faction": "protoss", "kind": "level", "max_level": 3,
		"effect": "attack", "applies_to": ["ground"],
		"requires": "forge",
		"levels": [
			{"cost_m": 100, "cost_g": 100, "time": 55.0},
			{"cost_m": 175, "cost_g": 175, "time": 70.0},
			{"cost_m": 250, "cost_g": 250, "time": 85.0},
		],
	},
	"ground_armor": {
		"name": "地面护甲", "faction": "protoss", "kind": "level", "max_level": 3,
		"effect": "armor", "applies_to": ["ground"],
		"requires": "forge",
		"levels": [
			{"cost_m": 100, "cost_g": 100, "time": 55.0},
			{"cost_m": 175, "cost_g": 175, "time": 70.0},
			{"cost_m": 250, "cost_g": 250, "time": 85.0},
		],
	},
	"plasma_shields": {
		"name": "等离子护盾", "faction": "protoss", "kind": "level", "max_level": 3,
		"effect": "shield_armor", "applies_to": ["shielded"],
		"requires": "forge",
		"levels": [
			{"cost_m": 200, "cost_g": 200, "time": 75.0},
			{"cost_m": 300, "cost_g": 300, "time": 90.0},
			{"cost_m": 400, "cost_g": 400, "time": 105.0},
		],
	},
}

## 单位技能表。
const ABILITIES := {
	"stim": {
		"name": "兴奋剂", "unit": "marine", "kind": "self",
		"unlock": "stim_pack",          # 必须先研究解锁型升级
		"self_damage": 10.0, "duration": 15.0, "cooldown": 0.0,
		"speed_mult": 1.5, "attack_cooldown_mult": 0.6,
	},
	"siege": {
		"name": "攻城模式", "unit": "siege_tank", "kind": "toggle",
		"deploy_time": 3.0, "cooldown": 1.0,
		"range": 360.0, "damage": 70.0, "attack_cooldown": 2.8, "speed": 0.0,
	},
	"heal": {
		"name": "治疗", "unit": "medic", "kind": "target_ally",
		"energy": 1.0, "range": 60.0, "heal": 15.0, "cooldown": 1.0,
	},
}

## 能量自然回复速率（点 / 秒）。
## 刻意用**固定速率**而不是「每秒回复最大值 N%」：
## 百分比会让高能量单位（医疗兵 200）回复得比低能量单位快得多，
## 医疗兵只要站着不动 20 秒就回满 200 点，能量形同虚设。
const ENERGY_REGEN := 0.75

# ================================================================ 战场法术
#
# 和 `ABILITIES` **分开两张表**：ABILITIES 是「单位自己的技能」
# （兴奋剂 / 攻城模式 / 治疗），都是自增益或简单单体目标；
# SPELLS 是**战场法术** —— 有施法距离、有影响范围、会在战场上留下一片区域
# 或给目标挂上状态效果。两者的判定、UI（瞄准态）、结算都不同，
# 混在一张表里会让每个分支都要先问「这是哪种」。
#
# kind：
#   "ground_aoe"   —— 点地施放，在落点生成一片区域（心灵风暴 / 黑暗虫群）
#   "target_enemy" —— 指定敌方单位（辐照）
#
# affects（只对 ground_aoe 有意义）：
#   "all"        —— 敌我不分。**星际 1 的心灵风暴就是这样**，会打死自己人。
#                   这不是 bug，是它之所以强的原因之一：乱丢会自伤。
#   "all_ground" —— 范围内所有地面单位（黑暗虫群保护的是「里面的人」，
#                   不分敌我 —— 所以它也能保护被围的敌人）。
## 法术的 `cooldown` 是**防连点**用的，不是平衡数值。
##
## 星际 1 的施法单位没有冷却，只有能量约束。但本项目的操作是触屏 + 框选：
## 玩家一次框住 3 个圣堂武士点一下，会**同时**落下 3 片风暴（这是对的，
## 和星际 1 一致）；可如果同一帧里因为输入抖动重复触发，
## 一个圣堂武士就会瞬间把 200 点能量全倒空 —— 玩家只会觉得「能量怎么没了」。
## 1 秒的冷却足够挡住抖动，又不影响「多单位齐放」。
const SPELLS := {
	"psionic_storm": {
		"name": "心灵风暴", "unit": "high_templar", "kind": "ground_aoe",
		"desc": "在目标区域降下等离子风暴，4 秒内持续伤害范围内所有单位（敌我不分）",
		"energy": 75.0, "cast_range": 210.0, "radius": 52.0,
		"duration": 4.0, "dps": 28.0, "damage_type": "normal",
		"affects": "all", "cooldown": 1.0,
	},
	"dark_swarm": {
		"name": "黑暗虫群", "unit": "defiler", "kind": "ground_aoe",
		"desc": "一片虫群遮蔽：区域内地面单位免疫远程攻击，持续 20 秒",
		"energy": 100.0, "cast_range": 200.0, "radius": 76.0,
		"duration": 20.0, "effect": "no_ranged",
		"affects": "all_ground", "cooldown": 1.0,
	},
	"irradiate": {
		"name": "辐照", "unit": "science_vessel", "kind": "target_enemy",
		"desc": "目标单位持续受到伤害，并传染给身边的友军，持续 15 秒",
		"energy": 75.0, "cast_range": 230.0,
		"duration": 15.0, "dps": 12.0, "damage_type": "normal",
		"splash_radius": 44.0, "cooldown": 1.0,
	},
	"ensnare": {
		"name": "诱捕网", "unit": "queen", "kind": "ground_aoe",
		"desc": "黏液网：范围内单位移速减半、射速变慢",
		# 数值照星际 1：能量 75 / 持续 25.2 秒 / 区域 128×128px / 移速 ×0.5。
		"energy": 75.0, "cast_range": 200.0, "radius": 80.0,
		"duration": 25.0, "effect": "slow",
		"slow_mult": 0.5,
		# ★`instant: true` —— 这是本项目和另两个 ground_aoe 法术的**分水岭**★
		#
		#    心灵风暴 / 黑暗虫群是「**留在战场上的圈**」：圈自己倒计时，
		#    每帧重新判定谁在圈里，人走进来就中招、走出去就没事。
		#
		#    诱捕网不是。它在**放下去的那一瞬间**把圈里每个单位抓一遍，
		#    效果随后**跟着单位走** —— 被抓到的兵跑出圈了照样慢满 25 秒，
		#    而后来才走进这片区域的兵一点事都没有。这正是星际 1 的行为。
		#
		#    ⚠️ 做成持久区域的话，它就变成「25 秒内谁进圈谁变慢」——
		#       比原作强得多，而且和「移速减半持续 25 秒」这条数值对不上。
		"instant": true,
		# 星际 1 的 Ensnare 还把**武器冷却 +25%**（射速降约 1/5）。
		# 这一条很容易漏 —— 漏了的话「诱捕网」就只是个减速，
		# 而它在原作里真正的价值是「把对方的输出砍掉五分之一」。
		"atk_cd_mult": 1.25,
		# ⚠️ `affects: "all"` —— **敌我不分，而且对空也有效**。
		#
		#    星际 1 的原文是「覆盖区域内**任何**未潜伏单位」，
		#    而且明确提到飞行单位转向/加速也变慢。所以它不是
		#    「只坑敌人」的技能：丢在自己人头上照样变慢。
		#    好在它**不造成伤害**，误伤代价只是「自己也慢了」，
		#    和心灵风暴的「打死自己人」不是一个量级。
		"affects": "all", "cooldown": 1.0,
	},
}

## dot 的结算间隔（秒）。
##
## ⚠️ **必须固定**，不能「每帧扣 dps * delta」—— 那样总伤害会随帧率漂移，
##    而且弹道/特效的节奏也对不上。星际 1 的持续伤害是每 0.5 秒一跳。
const DOT_TICK := 0.5

## 远程 / 近战的判定阈值（像素）。
##
## 星际 1 里黑暗虫群挡的是「远程攻击」，近战照打。
## 本项目的近战单位射程是 34~46（跳虫 34 / 狂热者 46），远程最短 105（蟑螂）。
## 60 落在两者中间的空档里，不会误判。
const MELEE_RANGE := 60.0

## 该技能是不是战场法术。
static func is_spell(skill_id: String) -> bool:
	return SPELLS.has(skill_id)

## 统一取技能：先查 ABILITIES，再查 SPELLS。
##
## ⚠️ 不要在各处分别查两张表 —— 漏一处就是「技能按钮点得动但放不出来」，
##    而且不报错（`get_ability` 对法术 id 返回空字典，调用方多半只判了 `is_empty`）。
static func get_skill(skill_id: String) -> Dictionary:
	if ABILITIES.has(skill_id):
		return ABILITIES[skill_id]
	return SPELLS.get(skill_id, {})

static func get_spell(spell_id: String) -> Dictionary:
	return SPELLS.get(spell_id, {})

## 该阵营可研究的升级（按建筑筛选：只有对应建筑在场才能研究）
static func upgrades_for_faction(faction: String) -> Array:
	var out := []
	for uid in UPGRADES:
		if String(UPGRADES[uid].get("faction", "")) == faction:
			out.append(uid)
	return out

## 该建筑的升级列表（需要建筑在场）
static func upgrades_for_building(bid: String) -> Array:
	var out := []
	for uid in UPGRADES:
		if String(UPGRADES[uid].get("requires", "")) == bid:
			out.append(uid)
	return out

static func get_upgrade(uid: String) -> Dictionary:
	return UPGRADES.get(uid, {})

static func get_ability(aid: String) -> Dictionary:
	return ABILITIES.get(aid, {})

## 单位能吃哪些升级 —— 攻击/护甲按 upgrade_class 匹配，护盾按「有没有护盾」匹配
static func upgrade_applies(upgrade_id: String, unit_id: String) -> bool:
	var up := get_upgrade(upgrade_id)
	if up.is_empty():
		return false
	if String(up.get("effect", "")) == "shield_armor":
		return float(get_unit(unit_id).get("shield", 0)) > 0.0
	var cls := String(UPGRADE_CLASS.get(unit_id, "none"))
	return cls != "none" and (up.get("applies_to", []) as Array).has(cls)

## 数值平衡系数（用于难度调节）
const DIFFICULTY := {
	"easy":   {"ai_eco": 0.75, "ai_aggro": 0.7, "ai_wave": 1.35},
	"normal": {"ai_eco": 1.0,  "ai_aggro": 1.0, "ai_wave": 1.0},
	"hard":   {"ai_eco": 1.4,  "ai_aggro": 1.35, "ai_wave": 0.72},
}

# ================================================================ 模组可变层（第十二轮 M3）
## 上面三张表原本是 `const`。要支持「数据模组覆盖数值」，必须变成
## 「启动时拷贝一份 → 按模组顺序合并 → 冻结」。
##
## ⚠️⚠️ **这是本项目风险最高的一处改动**，因为它正踩在一条老铁律上：
##   *「buff 绝不改 `data` —— `data` 是 `GameData.UNITS` 的共享字典，
##     改它污染所有同类型单位（含敌方）」*
##   `UNITS` 从 `const` 变成可变之后，任何「顺手改一下 data」的代码都会
##   **跨模组、跨对局**地污染全局 —— 而症状是「有些单位数值莫名其妙」，
##   既不崩也不报错。
##
## 三道防线：
##   1. **只有模组加载器能写**，而且必须走 `apply_mod_patch()`
##   2. `freeze()` 之后一切写入被拒（`push_error` + 返回 -1）
##   3. `tests/Mods.gd` 钉死「冻结后写 UNITS 被拒」
##
## 换句话说：**可变是给模组开的口子，不是给游戏逻辑开的口子。**

static var UNITS: Dictionary = _BASE_UNITS.duplicate(true)
static var BUILDINGS: Dictionary = _BASE_BUILDINGS.duplicate(true)
static var UPGRADES: Dictionary = _BASE_UPGRADES.duplicate(true)

static var _frozen := false

## 还原成原始数据并解冻。**只有模组重载会调它**，游戏逻辑不许调。
static func reset_to_base() -> void:
	_frozen = false
	UNITS = _BASE_UNITS.duplicate(true)
	BUILDINGS = _BASE_BUILDINGS.duplicate(true)
	UPGRADES = _BASE_UPGRADES.duplicate(true)

static func freeze() -> void:
	_frozen = true

static func is_frozen() -> bool:
	return _frozen

## 按名字取表（`"units"` / `"buildings"` / `"upgrades"`）。给模组加载器与测试用。
static func table_of(name: String) -> Dictionary:
	match name:
		"units": return UNITS
		"buildings": return BUILDINGS
		"upgrades": return UPGRADES
	return {}

## 基础条目 id，**按字母序**。
##
## ⚠️ 局域网快照的类型索引表必须用它，**不能用 `UNITS` / `BUILDINGS`** ——
##    那两个是模组改过的副本。客户端装了模组、主机没装的话，
##    索引会整体错位，症状是「我的陆战队员变成了攻城坦克」，**而且不报错**。
##    （模组只允许覆盖已有条目、不允许新建，所以基础键集是稳定的。）
static func base_ids(kind: String) -> PackedStringArray:
	var keys: Array = []
	if kind == "units":
		keys = _BASE_UNITS.keys()
	elif kind == "buildings":
		keys = _BASE_BUILDINGS.keys()
	elif kind == "upgrades":
		keys = _BASE_UPGRADES.keys()
	else:
		# ⚠️ 拼错 kind 会静默返回空表 —— 而「空表」在联机里表现为
		#    「所有指令都被当成未知类型丢掉」，不报错、只是点了没反应。
		push_error("[GameData] base_ids() 不认识 kind = %s" % kind)
	keys.sort()
	return PackedStringArray(keys)

## 合并一个模组的数值覆盖。返回实际改动的字段数；**被冻结时返回 -1**。
##
## `patch` 形状（三张表都可选）：
##   {"units": {"marine": {"hp": 60}}, "buildings": {...}, "upgrades": {...}}
##
## 合并是**逐字段**的（不是整条替换）：只写 `{"hp": 60}` 不会把陆战队员的
## 其它字段抹掉 —— 否则模组作者少写一个字段就会把单位弄成残废。
static func apply_mod_patch(patch: Dictionary, mod_id: String = "") -> int:
	if _frozen:
		push_error("[GameData] 数据表已冻结，拒绝写入（模组加载必须在 freeze() 之前）")
		return -1
	var n := 0
	n += _merge_table(UNITS, patch.get("units", {}), mod_id, "units")
	n += _merge_table(BUILDINGS, patch.get("buildings", {}), mod_id, "buildings")
	n += _merge_table(UPGRADES, patch.get("upgrades", {}), mod_id, "upgrades")
	return n

static func _merge_table(dst: Dictionary, src: Variant, mod_id: String, table: String) -> int:
	if typeof(src) != TYPE_DICTIONARY:
		return 0
	var n := 0
	var sd: Dictionary = src
	for id in sd:
		if not dst.has(id):
			# 未知 id：**拒绝**而不是新建。模组新建一个单位要同时改
			# `UNITS` / `BUILDINGS[x].trains` / `BUILD_MENU` / `AIR_RULES` /
			# `UPGRADE_CLASS` 五张表，缺任何一张都是静默半成品
			# （造不出来 / 吃不到攻防升级，都不报错）。
			# 所以本版只允许**覆盖已有条目**，新建留给后续版本。
			push_warning("[GameData] 模组 %s 想改未知条目 %s/%s，已忽略" % [mod_id, table, String(id)])
			continue
		var entry: Variant = sd[id]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var cur: Dictionary = dst[id]
		var ed: Dictionary = entry
		for k in ed:
			cur[k] = ed[k]
			n += 1
		dst[id] = cur
	return n
