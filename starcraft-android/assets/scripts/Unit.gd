extends RefCounted
class_name Unit

## 单个单位实例。纯逻辑对象（不继承 Node），由 World 的 Mover 统一驱动渲染。
## 大量单位时这种「数据 + 渲染批处理」的结构比每个单位一个 Node 快得多。

var id: int = -1
var type_id: String = ""
var faction: String = ""
var data: Dictionary = {}

var pos: Vector2 = Vector2.ZERO
var vel: Vector2 = Vector2.ZERO
var facing: float = 0.0

var hp: float = 1.0
var max_hp: float = 1.0
var shield: float = 0.0
var max_shield: float = 0.0
var shield_regen_delay: float = 0.0

var cooldown: float = 0.0
var dead: bool = false

# 移动
var path: PackedVector2Array = PackedVector2Array()
var path_index: int = 0
var final_target: Vector2 = Vector2.ZERO
var has_move_order: bool = false
var repath_timer: float = 0.0

# 战斗
var attack_target = null            # Unit 或 Building 引用
var attack_move: bool = false
var forced_target_pos = null        # 攻击移动的最终目的地
## 目标是玩家/指令手动点名的（而非自动索敌得到的）。
## 手动点名的目标必须一路追到底——否则右键点远处的敌人会毫无反应。
var attack_ordered: bool = false

# 采集
var harvest_target = null           # Building（主基地）
var resource_target = null          # ResourceNode
var carry: float = 0.0
var carry_kind: String = "mineral"   # mineral / gas —— 决定回程时把资源算进哪一项
var harvest_state: int = 0          # 0=去矿 1=返程
var harvest_timer: float = 0.0

# 建造：被派去工地的农民会一直绑在这个建筑上，直到它完工。
# 没有这个字段的话，农民走到工地、has_move_order 清零后就会被
# 采集逻辑判定为「空闲」而拉回矿点，工地永远无法推进。
var build_target = null             # Building

# 集结/编队
var group_id: int = -1
var formation_slot: Vector2 = Vector2.ZERO
var has_formation_slot: bool = false

# 技能与增益
#
# ⚠️ 铁律：增益**只在读取时叠加**，绝不写回 data。
# data 是 GameData.UNITS 里的共享字典 —— 直接改 u.data["speed"] 会污染
# 所有同类型单位（包括敌方），而且症状极隐蔽：一个陆战队员用兴奋剂，
# 全地图的陆战队员都变快。所以 speed()/attack_range()/cooldown_time() 都是
# 「基准值 + 增益」算出来的，不落盘。
var energy := 0.0
var max_energy := 0.0
var ability_cd := 0.0
var buffs := {}                     # {"stim": 剩余秒数}
var mode := "normal"                # 攻城坦克：normal / sieged
var mode_timer := 0.0               # 形态切换剩余时间（>0 时不能移动/开火）
var heal_target = null              # 医疗兵当前的治疗目标

## 状态效果 —— 法术留在单位身上的持续影响（星际的「心灵风暴 / 黑暗虫群 / 辐照」）。
##
## ⚠️ 和 `buffs` 同一条铁律：**只在读取时叠加，绝不写回 `data`**。
##    效果是「这个实例的临时状态」，不是类型属性。
##
## 每一项：
##   id           来源法术 id
##   kind         "dot"（持续伤害）/ "no_ranged"（挡远程）/ "slow"（减速）
##   remain       剩余秒数
##   duration     总时长（UI 画进度条、玩家判断还能撑多久）
##   dps          每秒伤害（kind == "dot"）
##   damage_type  伤害类型（dot 用 —— 决定吃哪套减伤）
##   owner        施法方阵营（dot 打死人时算谁的击杀）
##   slow_mult    减速倍率（kind == "slow"，多个效果**乘算**）
##   ticks        已结算的 dot 跳数。**不是累加器** —— 实际跳数由
##                `duration - remain`（已过去的时间）推导出来，见
##                `World._zone_dot_tick` 里那段「浮点漂移」的说明。
##
## ⚠️ **同源不叠加**（见 `apply_effect`）：星际里两个心灵风暴叠在一起
##    也只有一份伤害，重复施放只刷新时长。做成可叠加的话，
##    两个圣堂武士一起放就能秒掉任何单位，平衡直接崩。
##
## ⚠️ 计时与伤害结算**都在 `World._tick_spell_effects()`**，不在这里 ——
##    因为 dot 要走 World 的伤害管线（攻防升级、护盾、击杀归属都在那边）。
##    把计时也放过去，是为了让「到期」和「结算」永远在同一处，不会错位。
var effects: Array = []

## 有没有某一类效果。
##
## **热路径**：每一次命中结算都会问一次「目标是不是在黑暗虫群里」，
## 所以必须先判空 —— 绝大多数单位身上一个效果都没有。
func has_effect_kind(kind: String) -> bool:
	if effects.is_empty():
		return false
	for e in effects:
		if String((e as Dictionary).get("kind", "")) == kind:
			return true
	return false

func has_effect(id: String) -> bool:
	if effects.is_empty():
		return false
	for e in effects:
		if String((e as Dictionary).get("id", "")) == id:
			return true
	return false

## 施加一个效果。**同源取更长的时长**，不叠加。
func apply_effect(e: Dictionary) -> void:
	var id := String(e.get("id", ""))
	for cur in effects:
		var c: Dictionary = cur
		if String(c.get("id", "")) == id:
			var old_dur := float(c.get("duration", 0.0))
			var new_dur := maxf(old_dur, float(e.get("duration", 0.0)))
			# ⚠️ 时长被拉长时**必须把 dot 的跳数计数清零**。
			#    dot 的跳数是由 `duration - remain` 推出来的（见
			#    `World._zone_dot_tick`）；只改 remain 不改 duration 的话，
			#    `duration - remain` 会变成负数，新的一轮 dot 一跳都不打。
			#    症状是「补一发辐照反而把伤害补没了」。
			if new_dur > old_dur:
				c["ticks"] = 0
			c["duration"] = new_dur
			c["remain"] = maxf(float(c["remain"]), float(e.get("remain", 0.0)))
			return
	effects.append(e)

## 减速倍率：所有 slow 效果**乘算**。
func slow_mult() -> float:
	if effects.is_empty():
		return 1.0
	var m := 1.0
	for e in effects:
		var d: Dictionary = e
		if String(d.get("kind", "")) == "slow":
			m *= float(d.get("slow_mult", 1.0))
	return m

## 攻速倍率（**乘在冷却时间上**，所以 >1 = 变慢）。
##
## 星际 1 的诱捕网不只是「走得慢」——它同时把**武器冷却 +25%**，
## 也就是把对方的输出砍掉五分之一。漏掉这一条的话，「诱捕网」就只剩
## 一个减速，而它在原作里真正的价值是「让对方这 25 秒打不出伤害」。
##
## ⚠️ 和 `slow_mult()` 分开写、而不是合成一个 `spell_mult()`：
##    两者读的字段不同（`slow_mult` / `atk_cd_mult`），而且**取不到时
##    的缺省值方向相反** —— 移速缺省是 ×1.0（不变），攻速缺省也是 ×1.0
##    （冷却不变）。合并成一个函数后，任何一处加字段都会同时影响另一边，
##    而症状是「减速顺手把射速也改了」，很难查。
func atk_cd_mult() -> float:
	if effects.is_empty():
		return 1.0
	var m := 1.0
	for e in effects:
		var d: Dictionary = e
		if String(d.get("kind", "")) == "slow":
			m *= float(d.get("atk_cd_mult", 1.0))
	return m

func clear_effects() -> void:
	effects.clear()

## 是否正站在菌毯上。**由 World 定期刷新，单位自己不要算** ——
## 单位拿不到 world 引用，而且「谁站在菌毯上」本来就是个按格子查的全局问题。
##
## ⚠️ 和 buff 一样，这个加成只在 speed() 里**读取时**叠加，绝不写回 data。
var creep_boost := false

## 是否正站在高地上（视野与射程 +1 格）。同样由 World 定期刷新。
var on_high_ground := false

# 控制器：0=玩家 1=AI
var owner_id: int = 0

# 渲染用
var flash: float = 0.0
var anim_t: float = 0.0
var in_combat: bool = false

func setup(p_type_id: String, p_faction: String, p_pos: Vector2, p_owner: int, p_id: int) -> void:
	type_id = p_type_id
	faction = p_faction
	owner_id = p_owner
	id = p_id
	data = GameData.get_unit(p_type_id)
	pos = p_pos
	final_target = p_pos
	max_hp = float(data.get("hp", 50))
	hp = max_hp
	max_shield = float(data.get("shield", 0))
	shield = max_shield
	max_energy = float(data.get("energy", 0))
	energy = max_energy
	facing = randf() * TAU

func radius() -> float:
	return float(data.get("size", 8.0))

func speed() -> float:
	# 攻城模式是「形态」，优先级高于增益：展开后完全不能动。
	if mode == "sieged":
		return float(GameData.get_ability("siege").get("speed", 0.0))
	var s := float(data.get("speed", 90.0))
	if buffs.has("stim"):
		s *= float(GameData.get_ability("stim").get("speed_mult", 1.0))
	# 法术减速（瘟疫 / 冰冻之类）。和增益一样**读取时叠加**。
	s *= slow_mult()
	# 菌毯加速：虫族单位站在菌毯上跑得更快（星际 1 的招牌机制）。
	# 标记由 World._refresh_creep_boost() 刷新 —— 它已经替我们挡掉了
	# 「非虫族」和「飞行单位」两种情况，这里不再重复判。
	if creep_boost:
		s *= GameData.CREEP_SPEED_MULT
	return s

func sight() -> float:
	var s := float(data.get("sight", 200.0))
	# 高地视野 +1 格。低地看不见高地（见 World._mark_visible），
	# 反过来高地看低地一览无余 —— 这一条让「站上去」真的能看到更多。
	if on_high_ground:
		s += GameData.HIGH_GROUND_SIGHT_BONUS
	return s

func attack_range() -> float:
	var r := float(GameData.get_ability("siege").get("range", 40.0)) if mode == "sieged" \
		else float(data.get("range", 40.0))
	# 高地射程 +1 格。攻城模式也吃 —— 架在崖顶的坦克打得更远，符合直觉。
	if on_high_ground:
		r += GameData.HIGH_GROUND_RANGE_BONUS
	return r

## 单发伤害。攻城模式会换一套完全不同的火力参数。
func attack_damage() -> float:
	if mode == "sieged":
		return float(GameData.get_ability("siege").get("damage", data.get("damage", 10)))
	return float(data.get("damage", 10))

## 是否具备攻击能力。医疗兵 damage 为 0，用它来把非战斗单位挡在索敌逻辑之外。
func is_combat() -> bool:
	return float(data.get("damage", 0)) > 0.0

## 是否在空中飞行。飞行单位直线移动、不被地面近战锁定、不参与采集与建造。
func is_flying() -> bool:
	return GameData.is_flying(type_id)

## 能否攻击这个目标。
##
## 「攻击方有没有这个能力」和「目标在哪一层」必须**同时**满足 ——
## 这是空 / 地维度的唯一闸门。缺了它，整队跳虫会追着一架飞龙绕地图跑、
## 而且永远追不上，看上去像「AI 变傻了」。
func can_hit(target) -> bool:
	if target == null or not is_combat():
		return false
	# 建筑一律算在地面（建筑没有 flying 标记）
	if target is Unit and target.is_flying():
		return GameData.can_attack_air(type_id)
	return GameData.can_attack_ground(type_id)

func abilities() -> Array:
	return data.get("abilities", [])

func is_worker() -> bool:
	return data.get("role", "") == "worker"

func can_harvest() -> bool:
	return data.get("can_harvest", false)

func alive() -> bool:
	return not dead and hp > 0.0

func total_hp_ratio() -> float:
	var total := max_hp + max_shield
	if total <= 0.0:
		return 0.0
	return (hp + shield) / total

## 承受伤害，返回是否死亡。
##
## 三个加成全部由 World 传入 —— 只有它知道攻守双方的阵营升级等级。
##   护盾和本体**分开算减伤**：护盾吃「等离子护盾」升级，本体吃「护甲」升级。
##   混在一起算的话，神族升护盾会顺带把本体也变硬，这是错的（SC1 里两者独立）。
func take_damage(amount: float, damage_type: String, atk_bonus: int = 0,
		def_bonus: int = 0, shield_bonus: int = 0) -> bool:
	var armor := int(data.get("armor", 0))
	var armor_type := String(data.get("armor_type", "light"))
	var hp_dmg := GameData.compute_damage(amount, damage_type, armor_type,
		armor + def_bonus, atk_bonus)

	if shield > 0.0:
		# ⚠️ 护盾必须吃「基础护甲 + 护甲升级 + 护盾升级」。
		# 只写 shield_bonus 的话，护盾就完全不减伤了 ——
		# 症状是龙骑士突然打不过 2 个陆战队员（护盾每发多掉 2 点）。
		var sh_dmg := GameData.compute_damage(amount, damage_type, armor_type,
			armor + def_bonus + shield_bonus, atk_bonus)
		var absorbed := minf(shield, sh_dmg)
		shield -= absorbed
		shield_regen_delay = 4.0
		if absorbed < sh_dmg:
			# 护盾被打穿：溢出部分按「本体护甲」重算，
			# 而不是拿 sh_dmg 去减（两者减伤不同，直接减会算错）。
			var leak := amount * (1.0 - absorbed / maxf(0.001, sh_dmg))
			hp_dmg = GameData.compute_damage(leak, damage_type, armor_type,
				armor + def_bonus, atk_bonus)
		else:
			hp_dmg = 0.0

	if hp_dmg > 0.0:
		hp -= hp_dmg
	flash = 0.18
	in_combat = true
	if hp <= 0.0:
		hp = 0.0
		dead = true
		# 死掉的单位不该继续带着法术效果 —— 否则「被心灵风暴打死的单位」
		# 会在尸体上继续吃伤害，把击杀归属算到最后一个施法者头上。
		clear_effects()
		return true
	return false

func stop() -> void:
	path = PackedVector2Array()
	path_index = 0
	has_move_order = false
	has_formation_slot = false
	attack_target = null
	attack_ordered = false
	attack_move = false
	forced_target_pos = null
	vel = Vector2.ZERO
	# 「停止」= 放弃一切当前任务。不清理采集目标的话，
	# 被派去建造/移动的农民会在下一帧被采集状态机重新拉回矿点。
	resource_target = null
	harvest_target = null
	harvest_state = 0
	harvest_timer = 0.0
	carry = 0.0
	build_target = null
	heal_target = null

func move_to(target: Vector2) -> void:
	stop()
	# 攻城模式必须先收起来才能动 —— 这是「机动性换火力」的代价所在。
	if mode == "sieged":
		set_mode("normal")
	final_target = target
	has_move_order = true

func attack_to(target: Vector2) -> void:
	stop()
	if mode == "sieged":
		set_mode("normal")
	forced_target_pos = target
	final_target = target
	has_move_order = true
	attack_move = true

func attack(u) -> void:
	stop()
	attack_target = u
	attack_ordered = true

## 切换形态。mode_timer 是展开/收起耗时，期间不能移动也不能开火。
func set_mode(m: String) -> void:
	if m == mode:
		return
	mode = m
	var ab := GameData.get_ability("siege")
	if not ab.is_empty():
		mode_timer = float(ab.get("deploy_time", 0.0))

func has_buff(id: String) -> bool:
	return buffs.has(id)

func apply_buff(id: String, duration: float) -> void:
	buffs[id] = maxf(float(buffs.get(id, 0.0)), duration)

func update_common(delta: float) -> void:
	anim_t += delta
	if flash > 0.0:
		flash = maxf(0.0, flash - delta)
	if cooldown > 0.0:
		cooldown -= delta
	if ability_cd > 0.0:
		ability_cd -= delta
	if mode_timer > 0.0:
		mode_timer = maxf(0.0, mode_timer - delta)
	# 增益计时
	for k in buffs.keys():
		var t := float(buffs[k]) - delta
		if t <= 0.0:
			buffs.erase(k)
		else:
			buffs[k] = t
	# 能量回复（有能量的单位才回）。固定速率，见 GameData.ENERGY_REGEN
	if max_energy > 0.0 and energy < max_energy:
		energy = minf(max_energy, energy + GameData.ENERGY_REGEN * delta)
	# 护盾回复
	if shield_regen_delay > 0.0:
		shield_regen_delay -= delta
	elif max_shield > 0.0 and shield < max_shield:
		shield = minf(max_shield, shield + max_shield * 0.12 * delta)

func weapon_kind() -> String:
	return String(data.get("weapon", "bullet"))

func cooldown_time() -> float:
	var c := float(data.get("cooldown", 1.0))
	if mode == "sieged":
		c = float(GameData.get_ability("siege").get("attack_cooldown", c))
	elif buffs.has("stim"):
		c *= float(GameData.get_ability("stim").get("attack_cooldown_mult", 1.0))
	# 法术降射速（诱捕网）。**放在最后乘** —— 这样攻城模式也吃这一条：
	# 「展开之后就不怕诱捕网」在星际 1 里没有这回事。
	# ⚠️ 原写法是 `if mode == "sieged": return ...` 直接返回，加在后面等于
	#    永远轮不到。这里改成了赋值，行为对 siege 之外的单位**完全不变**。
	c *= atk_cd_mult()
	return c

## 形态切换期间不能开火 —— 否则攻城坦克可以在展开动画里继续输出，
## 「展开要 3 秒且期间毫无还手之力」这个代价就没了。
func can_fire() -> bool:
	return cooldown <= 0.0 and mode_timer <= 0.0
