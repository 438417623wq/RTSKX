extends RefCounted
class_name Grid

## 地图网格与寻路。世界坐标以像素为单位，格边长 CELL。
## 提供：地形通行性、建造占位、A* 寻路、流场（用于大规模单位趋同）。

const CELL := 24.0

enum Terrain { GROUND, ROCK, CHASM, RAMP }

var w: int = 0
var h: int = 0
var cells: PackedInt32Array = PackedInt32Array()          # Terrain
var occupied: PackedInt32Array = PackedInt32Array()        # 0 空 / 1 建筑占位（不阻挡寻路的静态障碍）
var blocks: PackedByteArray = PackedByteArray()            # 是否为不可通行
## 高度层：0 = 低地，1 = 高地。
##
## ⚠️ 高度**不直接**决定通行性 —— 通行性一律走 can_step()：
##    同层随便走，跨层只有坡道能过。这样即使某块高地忘了围障碍，
##    也不会出现「单位顺着悬崖爬上去」这种规则漏洞。
var elev: PackedByteArray = PackedByteArray()
## 坡道：高低地之间**唯一**的连接。坡道本身永远可通行。
var ramp: PackedByteArray = PackedByteArray()
## 菌毯：1 = 该格被虫族菌毯覆盖。
##
## ⚠️ 这里只是**缓存**，真正的来源是 World 里那些虫族建筑的半径并集
##    （见 World._rebuild_creep）。放在网格里是为了让「渲染」和「规则判定」
##    读到同一份数据 —— 两边各自算距离的话，迟早会出现
##    「画面上明明有菌毯、却提示不能建」这种对不上的情况。
var creep: PackedByteArray = PackedByteArray()

func _init(map_w: int, map_h: int) -> void:
	w = map_w
	h = map_h
	var n := w * h
	cells.resize(n)
	occupied.resize(n)
	blocks.resize(n)
	elev.resize(n)
	ramp.resize(n)
	creep.resize(n)
	cells.fill(Terrain.GROUND)
	occupied.fill(0)
	blocks.fill(0)
	elev.fill(0)
	ramp.fill(0)
	creep.fill(0)

func idx(cx: int, cy: int) -> int:
	return cy * w + cx

func in_bounds(cx: int, cy: int) -> bool:
	return cx >= 0 and cy >= 0 and cx < w and cy < h

func world_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / CELL)), int(floor(p.y / CELL)))

func cell_to_world(c: Vector2i) -> Vector2:
	return Vector2(c.x * CELL + CELL * 0.5, c.y * CELL + CELL * 0.5)

func is_walkable_cell(cx: int, cy: int) -> bool:
	if not in_bounds(cx, cy):
		return false
	return blocks[idx(cx, cy)] == 0

func is_walkable_world(p: Vector2) -> bool:
	var c := world_to_cell(p)
	return is_walkable_cell(c.x, c.y)

## 世界坐标点能不能**站在指定层**上。
##
## 单位互相挤开时用这个判，而不是 is_walkable_world：
## 只判「不挡路」的话，一次推挤就能把崖底的兵挤到崖顶上去 ——
## 画面上看起来像瞬移，而且它会因此拿到高地的 30% miss 优势。
func is_walkable_on_layer(p: Vector2, layer: int) -> bool:
	var c := world_to_cell(p)
	if not is_walkable_cell(c.x, c.y):
		return false
	return elev_at_cell(c.x, c.y) == layer

func set_terrain(cx: int, cy: int, t: int) -> void:
	if not in_bounds(cx, cy):
		return
	var i := idx(cx, cy)
	cells[i] = t
	blocks[i] = 1 if (t == Terrain.ROCK or t == Terrain.CHASM) else 0
	ramp[i] = 1 if t == Terrain.RAMP else 0

# ---------------------------------------------------------------- 高低差

func set_elev(cx: int, cy: int, e: int) -> void:
	if in_bounds(cx, cy):
		elev[idx(cx, cy)] = e

func elev_at_cell(cx: int, cy: int) -> int:
	if not in_bounds(cx, cy):
		return 0
	return elev[idx(cx, cy)]

func elev_at(p: Vector2) -> int:
	var c := world_to_cell(p)
	return elev_at_cell(c.x, c.y)

func is_ramp_cell(cx: int, cy: int) -> bool:
	if not in_bounds(cx, cy):
		return false
	return ramp[idx(cx, cy)] != 0

func set_creep(cx: int, cy: int, v: int) -> void:
	if in_bounds(cx, cy):
		creep[idx(cx, cy)] = v

func creep_at_cell(cx: int, cy: int) -> bool:
	if not in_bounds(cx, cy):
		return false
	return creep[idx(cx, cy)] != 0

func creep_at(p: Vector2) -> bool:
	var c := world_to_cell(p)
	return creep_at_cell(c.x, c.y)

## 从 (ax,ay) 能不能走到**相邻的** (bx,by)。这是高低差唯一的闸门。
##
## 规则：同一层随便走；跨层只有「其中至少一格是坡道」才放行。
##
## 为什么是「其中一格」而不是「两格都」：坡道只要一条窄带就能把两层接起来 ——
## 坡道顶端那格自己站在低地上，再往里一步就是高地，两格都是坡道的要求
## 会把坡道逼成「必须两格宽」，地图上很难摆，也容易把平台封死。
func can_step(ax: int, ay: int, bx: int, by: int) -> bool:
	if not is_walkable_cell(ax, ay) or not is_walkable_cell(bx, by):
		return false
	if elev_at_cell(ax, ay) == elev_at_cell(bx, by):
		return true
	return is_ramp_cell(ax, ay) or is_ramp_cell(bx, by)

## 以格为单位标记一个矩形区域的建筑占位
func mark_area(cell_pos: Vector2i, cells_w: int, cells_h: int, block: bool) -> void:
	for y in range(cell_pos.y, cell_pos.y + cells_h):
		for x in range(cell_pos.x, cell_pos.x + cells_w):
			if in_bounds(x, y):
				occupied[idx(x, y)] = 1 if block else 0
				blocks[idx(x, y)] = 1 if block else 0

## 世界坐标点附近的空闲落点（用于避免单位重叠到建筑里）。
## layer >= 0 时只接受**同一层**的落点 —— 否则站在低地的单位会被分配到高地上，
## 而那块高地可能根本没有坡道下来，单位就此被永久困住。
func nearest_free_world(p: Vector2, max_ring: int = 8, layer: int = -1) -> Vector2:
	var c := world_to_cell(p)
	var want := elev_at_cell(c.x, c.y) if layer < 0 else layer
	if is_walkable_cell(c.x, c.y) and elev_at_cell(c.x, c.y) == want:
		return p
	for r in range(1, max_ring + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				if is_walkable_cell(c.x + dx, c.y + dy) \
						and elev_at_cell(c.x + dx, c.y + dy) == want:
					return cell_to_world(Vector2i(c.x + dx, c.y + dy))
	return p

## 在目标点周围找一个可站立的、且尽量分散的落点。
## 落点固定在 center 所在的层 —— 一个站在低地的单位不该被分配到崖顶。
func scatter_slot(center: Vector2, index: int, radius: float = 30.0) -> Vector2:
	var slots := 8
	var ring := index / slots + 1
	var ang := TAU * float(index % slots) / float(slots) + float(ring) * 0.4
	var off := Vector2(cos(ang), sin(ang)) * (radius * float(ring))
	return nearest_free_world(center + off, 8, elev_at(center))

## A* 寻路：返回世界坐标路径点数组（不含起点，含终点）。失败返回空数组。
func find_path(from: Vector2, to: Vector2, max_nodes: int = 6000) -> PackedVector2Array:
	var start := world_to_cell(from)
	var goal := world_to_cell(to)
	if not in_bounds(goal.x, goal.y):
		return PackedVector2Array()
	if blocks[idx(goal.x, goal.y)] != 0:
		var alt := _nearest_open(goal, 10, elev_at_cell(goal.x, goal.y))
		if alt == Vector2i(-9999, -9999):
			return PackedVector2Array()
		goal = alt
	if not in_bounds(start.x, start.y) or blocks[idx(start.x, start.y)] != 0:
		# 起点用「它自己那一层」：站在高地上的单位不该被拽到低地再出发
		var sl := elev_at_cell(start.x, start.y) if in_bounds(start.x, start.y) else -1
		start = _nearest_open(start, 10, sl)
		if start == Vector2i(-9999, -9999):
			return PackedVector2Array()
	if start == goal:
		return PackedVector2Array([to])

	var open := []                       # 二叉堆式的简单排序列表（地图不大，够用）
	var came := {}
	var gscore := {}
	var closed := {}
	var start_key := start.y * w + start.x
	gscore[start_key] = 0.0
	open.append({"c": start, "f": _h(start, goal)})
	var visited := 0

	while not open.is_empty() and visited < max_nodes:
		open.sort_custom(func(a, b): return a["f"] < b["f"])
		var cur: Dictionary = open.pop_front()
		var cc: Vector2i = cur["c"]
		var ck: int = cc.y * w + cc.x
		if closed.has(ck):
			continue
		closed[ck] = true
		visited += 1
		if cc == goal:
			return _reconstruct(came, cc)
		for d in _DIRS8:
			var nx: int = cc.x + d.x
			var ny: int = cc.y + d.y
			# 高低差的闸门在这里 —— 不能再用 is_walkable_cell，
			# 否则寻路会直接穿过悬崖，单位看上去就是「爬墙上去的」。
			if not can_step(cc.x, cc.y, nx, ny):
				continue
			if d.x != 0 and d.y != 0:
				# 禁止穿越障碍对角
				if not can_step(cc.x, cc.y, cc.x + d.x, cc.y) \
						or not can_step(cc.x, cc.y, cc.x, cc.y + d.y):
					continue
			var nk: int = ny * w + nx
			if closed.has(nk):
				continue
			var step := 1.41421356 if (d.x != 0 and d.y != 0) else 1.0
			var ng: float = gscore[ck] + step
			if not gscore.has(nk) or ng < gscore[nk]:
				gscore[nk] = ng
				came[nk] = cc
				open.append({"c": Vector2i(nx, ny), "f": ng + _h(Vector2i(nx, ny), goal)})
	return PackedVector2Array()

const _DIRS8 := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

func _h(a: Vector2i, b: Vector2i) -> float:
	var dx := absf(float(a.x - b.x))
	var dy := absf(float(a.y - b.y))
	return (dx + dy) + (1.41421356 - 2.0) * minf(dx, dy)

func _nearest_open(c: Vector2i, max_ring: int, layer: int = -1) -> Vector2i:
	var want := elev_at_cell(c.x, c.y) if layer < 0 else layer
	if is_walkable_cell(c.x, c.y) and elev_at_cell(c.x, c.y) == want:
		return c
	for r in range(1, max_ring + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				if is_walkable_cell(c.x + dx, c.y + dy) \
						and elev_at_cell(c.x + dx, c.y + dy) == want:
					return Vector2i(c.x + dx, c.y + dy)
	return Vector2i(-9999, -9999)

func _reconstruct(came: Dictionary, cur: Vector2i) -> PackedVector2Array:
	var out: Array[Vector2] = []
	var c := cur
	while came.has(c.y * w + c.x):
		out.append(cell_to_world(c))
		c = came[c.y * w + c.x]
	out.reverse()
	if out.size() > 0:
		out[out.size() - 1] = cell_to_world(cur)
	return PackedVector2Array(out)

## 路径平滑：去掉被障碍遮挡的中间点（拉绳算法），让移动更自然
func smooth(path: PackedVector2Array, from: Vector2) -> PackedVector2Array:
	if path.size() <= 1:
		return path
	var out := PackedVector2Array()
	var anchor := from
	var i := 0
	while i < path.size():
		var best := i
		for j in range(path.size() - 1, i - 1, -1):
			if _clear_line(anchor, path[j]):
				best = j
				break
		out.append(path[best])
		anchor = path[best]
		i = best + 1
	return out

## 直线是否畅通（供路径平滑用）。
## 必须逐格走 can_step —— 只判「两端可通行」的话，
## 拉绳算法会把一条穿过悬崖的直线当成畅通的，路径就被拉直成「爬墙」。
func _clear_line(a: Vector2, b: Vector2) -> bool:
	var steps := int(a.distance_to(b) / (CELL * 0.4)) + 1
	var prev := world_to_cell(a)
	if not is_walkable_cell(prev.x, prev.y):
		return false
	for s in range(1, steps + 1):
		var p := a.lerp(b, float(s) / float(steps))
		var c := world_to_cell(p)
		if c == prev:
			continue
		if not can_step(prev.x, prev.y, c.x, c.y):
			return false
		prev = c
	return true
