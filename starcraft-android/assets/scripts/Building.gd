extends RefCounted
class_name Building

## 建筑实例。占地以格为单位，建造中/已完成两种状态。

var id: int = -1
var type_id: String = ""
var faction: String = ""
var owner_id: int = 0
var data: Dictionary = {}

var pos: Vector2 = Vector2.ZERO
var cell_pos: Vector2i = Vector2i.ZERO
var cells_w: int = 2
var cells_h: int = 2

var hp: float = 1.0
var max_hp: float = 1.0
var armor: int = 2
var armor_type: String = "building"

var complete: bool = false
var build_progress: float = 0.0
var build_time: float = 1.0

# 生产队列
var queue: Array = []              # [{type_id, time_left, total}]
var train_slots: int = 1
var active_trains: int = 0

# 采集点
var resource_held: float = 0.0

# 集结点
var rally: Vector2 = Vector2.ZERO
var has_rally: bool = false

# 气矿建筑（精炼厂/萃取房/吸收塔）所占据的气矿节点
var gas_geyser = null

var dead: bool = false
var flash: float = 0.0
var anim_t: float = 0.0
var selected: bool = false

# 攻击型建筑（导弹塔 / 孢子菌落 / 光子炮台）的开火状态。
# 非攻击建筑这两个字段永远是 0 / null —— 索敌循环用 is_combat() 把它们挡在外面。
var cooldown: float = 0.0
var attack_target = null

func setup(p_type_id: String, p_faction: String, p_pos: Vector2, p_owner: int, p_id: int, instant: bool = false) -> void:
	type_id = p_type_id
	faction = p_faction
	owner_id = p_owner
	id = p_id
	data = GameData.get_building(p_type_id)
	pos = p_pos
	max_hp = float(data.get("hp", 800))
	hp = max_hp
	armor = int(data.get("armor", 2))
	armor_type = String(data.get("armor_type", "building"))
	build_time = float(data.get("build_time", 20.0))
	var sz := float(data.get("size", 28.0))
	cells_w = maxi(1, int(ceil(sz / Grid.CELL)))
	cells_h = cells_w
	complete = instant
	build_progress = build_time if instant else 0.0
	rally = p_pos + Vector2(0, sz + 30.0)
	train_slots = 1

func radius() -> float:
	return float(data.get("size", 28.0)) * 0.5

func provides_supply() -> int:
	if not complete:
		return 0
	return int(data.get("provides_supply", 0))

func trains() -> Array:
	return data.get("trains", [])

## 攻击型建筑（导弹塔 / 孢子菌落 / 光子炮台）才带 damage。
## 非攻击建筑必须被挡在索敌之外 —— 和「医疗兵 damage 为 0」是同一个道理。
func is_combat() -> bool:
	return float(data.get("damage", 0)) > 0.0

func attack_range() -> float:
	return float(data.get("range", 0.0))

func attack_damage() -> float:
	return float(data.get("damage", 0.0))

func weapon_kind() -> String:
	return String(data.get("weapon", "missile"))

## 能否攻击这个目标。和 Unit.can_hit 是同一套规则 ——
## 「攻击方有没有这个能力」×「目标在哪一层」，两者都满足才能打。
func can_hit(target) -> bool:
	if target == null or not is_combat():
		return false
	if target is Unit and target.is_flying():
		return GameData.can_attack_air(type_id)
	return GameData.can_attack_ground(type_id)

## 两次开火之间的间隔（秒）。数据表里叫 cooldown，这里换个名字避免和状态字段混淆。
func attack_interval() -> float:
	return float(data.get("cooldown", 1.0))

## 没完工的防御塔不能开火 —— 否则「边造边打」会让塔变得无法拆除。
func can_fire() -> bool:
	return complete and is_combat() and cooldown <= 0.0

func alive() -> bool:
	return not dead and hp > 0.0

func take_damage(amount: float, damage_type: String) -> bool:
	var dmg := GameData.compute_damage(amount, damage_type, armor_type, armor)
	hp -= dmg
	flash = 0.18
	if hp <= 0.0:
		hp = 0.0
		dead = true
		return true
	return false

func update(delta: float, builders: int = 0) -> void:
	anim_t += delta
	if flash > 0.0:
		flash = maxf(0.0, flash - delta)
	# 开火冷却必须在「建造中提前 return」**之前**递减 ——
	# 否则一座造了 16 秒的导弹塔刚完工时会带着一整个建造期的冷却，
	# 完工后还要傻站着等一次冷却才开第一枪。
	if cooldown > 0.0:
		cooldown -= delta
	if not complete:
		# 只有工兵在场时才会推进（builders 由 World 按半径统计后传入）
		if builders > 0:
			build_progress += delta * minf(2.0, float(builders))
			hp = max_hp * clampf(build_progress / build_time, 0.08, 1.0)
			if build_progress >= build_time:
				complete = true
				hp = max_hp
		return
	_tick_queue(delta)

## 推进队列。注意：完成的条目不会在这里出队——必须先由 World 结算
## （扣资源 + 生成单位）后再调用 pop_head()，否则单位会被静默丢弃。
func _tick_queue(delta: float) -> void:
	if queue.is_empty():
		return
	if ready_to_spawn():
		return
	queue[0]["time_left"] -= delta

## 队首是否已完工（等待 World 结算出产）
func ready_to_spawn() -> bool:
	return complete and queue.size() > 0 and float(queue[0]["time_left"]) <= 0.0

func pop_head() -> void:
	if queue.size() > 0:
		queue.pop_front()

## 兼容旧接口
func take_ready() -> Array:
	return []

## 生产队列上限。研究和训练**共用这个队列** —— 这样天然实现了 SC1 的
## 「一个建筑同一时间只能做一件事」（研究与训练互斥），比另开研究槽更保真。
const QUEUE_MAX := 5

## 入队。kind 为 "unit" 或 "upgrade"。
## 条目里 id 与 type_id 同时写 —— 旧代码有读 type_id 的地方，保留兼容。
func queue_item(kind: String, id: String, time: float) -> bool:
	if queue.size() >= QUEUE_MAX:
		return false
	queue.append({
		"kind": kind, "id": id, "type_id": id,
		"time_left": time, "total": time,
	})
	return true

func queue_unit(type_id: String) -> bool:
	var u := GameData.get_unit(type_id)
	if u.is_empty():
		return false
	return queue_item("unit", type_id, float(u.get("build_time", 10.0)))

## 队首条目的 kind（"unit" / "upgrade"），空队列返回 ""
func head_kind() -> String:
	if queue.is_empty():
		return ""
	return String(queue[0].get("kind", "unit"))

## 已完成且可出产的单位（每次调用弹出队首）
func pop_finished() -> String:
	if not complete:
		return ""
	if queue.is_empty():
		return ""
	# 队列推进：只有队首完成才出产
	return ""

func progress_ratio() -> float:
	if complete:
		return 1.0
	return clampf(build_progress / build_time, 0.0, 1.0)
