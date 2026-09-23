extends RefCounted
class_name GenTex

## 程序化生成全部贴图。所有图案都由代码逐像素绘制 —— 零外部素材、零版权风险。
##
## 视觉约定：
##   1. 俯视视角，光源固定来自左上 → 顶部/左侧高光，底部/右侧暗边。
##   2. 单位贴图内「正前方」= 上方（-Y）。运行时用 draw_set_transform 旋转到 u.facing。
##   3. 每张贴图生成后统一跑一遍 _outline（深色外描边）。
##      这一步是把「拼贴的几何图元」变成「有造型的立绘」的关键 ——
##      没有描边，单位在深色地面上就是一坨糊掉的色块。
##   4. 形状画多大无所谓：_fit() 会把内容按「最远像素半径」归一化，
##      保证旋转不被裁切，且所有单位在屏幕上的视觉尺寸可控。

const U_SIZE := 64      # 单位贴图边长
const B_SIZE := 96      # 建筑贴图边长

## 最近一次 unit_sprite / building_sprite 调用是否落进了「没写造型」的兜底分支。
##
## 兜底分支画的是一个光秃秃的圆盘 —— 和任何真实单位/建筑都不像，
## 而且**不会报错**：加了新 id 却忘了写造型时，画面只是静默退化成一坨圆球。
## （幽灵战机 / 侦察机就是这么被发现的：造出来是一颗蓝球。）
## 测试靠这个标记断言「每个 id 都有专属造型」——比逐像素比对可靠得多。
static var last_was_fallback := false

# ================================================================ 绘图原语

static func _new(size: int) -> Image:
	return Image.create(size, size, false, Image.FORMAT_RGBA8)

## alpha 混合写点（越界丢弃）。c.a 接近 1 时走快路径。
static func _blend(img: Image, x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	if c.a <= 0.002:
		return
	if c.a >= 0.998:
		img.set_pixel(x, y, c)
		return
	var d := img.get_pixel(x, y)
	var a := c.a + d.a * (1.0 - c.a)
	if a <= 0.002:
		img.set_pixel(x, y, Color(0, 0, 0, 0))
		return
	var inv := 1.0 / a
	img.set_pixel(x, y, Color(
		(c.r * c.a + d.r * d.a * (1.0 - c.a)) * inv,
		(c.g * c.a + d.g * d.a * (1.0 - c.a)) * inv,
		(c.b * c.a + d.b * d.a * (1.0 - c.a)) * inv,
		a))

## 按覆盖率写点（抗锯齿软边）
static func _cov(img: Image, x: int, y: int, c: Color, cov: float) -> void:
	if cov <= 0.002:
		return
	_blend(img, x, y, Color(c.r, c.g, c.b, c.a * minf(cov, 1.0)))

static func _rect(img: Image, x: float, y: float, w: float, h: float, c: Color) -> void:
	var x0 := int(round(x))
	var y0 := int(round(y))
	for j in range(y0, int(round(y + h))):
		for i in range(x0, int(round(x + w))):
			_blend(img, i, j, c)

static func _round_rect(img: Image, x: float, y: float, w: float, h: float, r: float, c: Color) -> void:
	_rect(img, x + r, y, w - r * 2.0, h, c)
	_rect(img, x, y + r, w, h - r * 2.0, c)
	_disc(img, x + r, y + r, r, r, c)
	_disc(img, x + w - r, y + r, r, r, c)
	_disc(img, x + r, y + h - r, r, r, c)
	_disc(img, x + w - r, y + h - r, r, r, c)

static func _frame(img: Image, x: float, y: float, w: float, h: float, c: Color, t: float) -> void:
	var ti := maxi(1, int(round(t)))
	_rect(img, x, y, w, float(ti), c)
	_rect(img, x, y + h - float(ti), w, float(ti), c)
	_rect(img, x, y, float(ti), h, c)
	_rect(img, x + w - float(ti), y, float(ti), h, c)

## 抗锯齿椭圆环。irx/iry 为 0 时是实心椭圆。
static func _ellipse(img: Image, cx: float, cy: float, irx: float, iry: float,
		orx: float, ory: float, c: Color) -> void:
	if orx <= 0.0 or ory <= 0.0:
		return
	var edge := 1.0 / maxf(0.6, minf(orx, ory))
	var x0 := int(floor(cx - orx)) - 1
	var x1 := int(ceil(cx + orx)) + 1
	var y0 := int(floor(cy - ory)) - 1
	var y1 := int(ceil(cy + ory)) + 1
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var px := float(x) + 0.5 - cx
			var py := float(y) + 0.5 - cy
			var d := sqrt(px * px / (orx * orx) + py * py / (ory * ory))
			var cov := clampf((1.0 - d) / edge, 0.0, 1.0)
			if cov <= 0.0:
				continue
			if irx > 0.0 and iry > 0.0:
				var di := sqrt(px * px / (irx * irx) + py * py / (iry * iry))
				cov = maxf(0.0, cov - clampf((1.0 - di) / edge, 0.0, 1.0))
			if cov > 0.0:
				_cov(img, x, y, c, cov)

static func _disc(img: Image, cx: float, cy: float, rx: float, ry: float, c: Color) -> void:
	_ellipse(img, cx, cy, 0.0, 0.0, rx, ry, c)

static func _ring(img: Image, cx: float, cy: float, r: float, t: float, c: Color) -> void:
	var ri := maxf(0.0, r - t * 0.5)
	_ellipse(img, cx, cy, ri, ri, r + t * 0.5, r + t * 0.5, c)

## 多边形填充。只做中心点采样 —— 单位/建筑贴图最后都会走 _fit() 的 LANCZOS
## 缩放，插值本身就会补上抗锯齿；2×2 超采样在这里是纯粹的性能浪费。
static func _poly(img: Image, pts: PackedVector2Array, c: Color) -> void:
	if pts.size() < 3:
		return
	var x0 := INF
	var y0 := INF
	var x1 := -INF
	var y1 := -INF
	for p in pts:
		x0 = minf(x0, p.x)
		y0 = minf(y0, p.y)
		x1 = maxf(x1, p.x)
		y1 = maxf(y1, p.y)
	for y in range(int(floor(y0)) - 1, int(ceil(y1)) + 1):
		for x in range(int(floor(x0)) - 1, int(ceil(x1)) + 1):
			if _in_poly(Vector2(float(x) + 0.5, float(y) + 0.5), pts):
				_blend(img, x, y, c)

## 抗锯齿线段。用「点到线段距离」逐像素算覆盖率 ——
## 早先的版本是沿线段撒圆点，一条 40px 的线要跑 60 次 _disc（≈5000 次像素操作），
## 现在只遍历线段包围盒（≈200 次），快 20 倍以上。
static func _line(img: Image, a: Vector2, b: Vector2, c: Color, t: float) -> void:
	var d := b - a
	var len := d.length()
	var half := t * 0.5
	if len < 0.01:
		_disc(img, a.x, a.y, half, half, c)
		return
	var n := d / len
	var x0 := int(floor(minf(a.x, b.x) - half)) - 1
	var x1 := int(ceil(maxf(a.x, b.x) + half)) + 1
	var y0 := int(floor(minf(a.y, b.y) - half)) - 1
	var y1 := int(ceil(maxf(a.y, b.y) + half)) + 1
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var v := Vector2(float(x) + 0.5, float(y) + 0.5) - a
			var proj := clampf(v.dot(n), 0.0, len)
			var dist := (v - n * proj).length()
			var cov := clampf(half + 0.5 - dist, 0.0, 1.0)
			if cov > 0.0:
				_cov(img, x, y, c, cov)

## 对已绘制像素做「上亮下暗」，制造俯视光照。只作用于矩形范围内的已有像素。
static func _bevel(img: Image, x: float, y: float, w: float, h: float, top: float, bottom: float) -> void:
	var y0 := int(round(y))
	var y1 := int(round(y + h))
	var x0 := int(round(x))
	var x1 := int(round(x + w))
	var hh := maxf(1.0, float(y1 - y0))
	for j in range(y0, y1):
		var t := float(j - y0) / hh
		var amt := 0.0
		if t < 0.32:
			amt = top * (1.0 - t / 0.32)
		elif t > 0.70:
			amt = -bottom * ((t - 0.70) / 0.30)
		if absf(amt) < 0.004:
			continue
		for i in range(x0, x1):
			if i < 0 or j < 0 or i >= img.get_width() or j >= img.get_height():
				continue
			var d := img.get_pixel(i, j)
			if d.a <= 0.02:
				continue
			var col := d.lightened(amt) if amt > 0.0 else d.darkened(-amt)
			img.set_pixel(i, j, Color(col.r, col.g, col.b, d.a))

## 细微颗粒噪声，去掉塑料感。salt 决定噪声图案。
static func _grain(img: Image, x: float, y: float, w: float, h: float, amt: float, salt: int) -> void:
	var iw := img.get_width()
	var ih := img.get_height()
	var x0 := maxi(0, int(round(x)))
	var y0 := maxi(0, int(round(y)))
	var x1 := mini(iw, int(round(x + w)))
	var y1 := mini(ih, int(round(y + h)))
	if x1 <= x0 or y1 <= y0:
		return
	var data := img.get_data()
	for j in range(y0, y1):
		for i in range(x0, x1):
			var k := (j * iw + i) * 4
			if data[k + 3] <= 5:
				continue
			var f := 1.0 + (_hash2(i + salt * 131, j + salt * 977) - 0.5) * 2.0 * amt
			data[k] = int(clampf(float(data[k]) * f, 0.0, 255.0))
			data[k + 1] = int(clampf(float(data[k + 1]) * f, 0.0, 255.0))
			data[k + 2] = int(clampf(float(data[k + 2]) * f, 0.0, 255.0))
	img.set_data(iw, ih, false, Image.FORMAT_RGBA8, data)

## 全局方向光：来自屏幕上方略偏左 → 上部提亮、下部压暗。
## 这是把「平面色块」变成「有体积的模型」的最后一道工序，
## 没有它，无论形状画得多准，看起来都像贴纸。
static func _global_light(img: Image, strength: float = 0.22) -> void:
	var s := img.get_width()
	var h := img.get_height()
	var c := float(s) * 0.5
	var r := maxf(1.0, float(s) * 0.5)
	var data := img.get_data()
	for y in range(h):
		var ny := (float(y) + 0.5 - c) / r
		for x in range(s):
			var k := (y * s + x) * 4
			if data[k + 3] <= 5:
				continue
			var nx := (float(x) + 0.5 - c) / r
			var f := 1.0 - (nx * 0.40 + ny * 0.92) * strength
			data[k] = int(clampf(float(data[k]) * f, 0.0, 255.0))
			data[k + 1] = int(clampf(float(data[k + 1]) * f, 0.0, 255.0))
			data[k + 2] = int(clampf(float(data[k + 2]) * f, 0.0, 255.0))
	img.set_data(s, h, false, Image.FORMAT_RGBA8, data)

## 给所有不透明像素加一圈外描边。用 get_data() 直读 alpha，比逐点 get_pixel 快很多。
static func _outline(img: Image, c: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var solid := PackedByteArray()
	solid.resize(w * h)
	for i in range(w * h):
		solid[i] = 1 if data[i * 4 + 3] >= 90 else 0
	var edge: Array = []
	for y in range(h):
		for x in range(w):
			if solid[y * w + x] == 0:
				continue
			if x == 0 or y == 0 or x == w - 1 or y == h - 1:
				edge.append(Vector2i(x, y))
			elif solid[y * w + x - 1] == 0 or solid[y * w + x + 1] == 0 \
					or solid[(y - 1) * w + x] == 0 or solid[(y + 1) * w + x] == 0:
				edge.append(Vector2i(x, y))
	for p in edge:
		var x: int = p.x
		var y: int = p.y
		if x > 0 and solid[y * w + x - 1] == 0:
			_blend(img, x - 1, y, c)
		if x < w - 1 and solid[y * w + x + 1] == 0:
			_blend(img, x + 1, y, c)
		if y > 0 and solid[(y - 1) * w + x] == 0:
			_blend(img, x, y - 1, c)
		if y < h - 1 and solid[(y + 1) * w + x] == 0:
			_blend(img, x, y + 1, c)

## 内容归一化：裁到中心正方形 → 等比缩放，使「最远像素到中心的距离」
## 恰好等于 fill * size / 2。保证旋转不被贴图边界裁切，且尺寸可控。
static func _fit(img: Image, fill: float) -> Image:
	var s := img.get_width()
	var c := float(s) * 0.5
	# 直接读 alpha 通道，比逐点 get_pixel 构造 Color 快得多
	var data := img.get_data()
	var max_r := 0.0
	for y in range(s):
		for x in range(s):
			if data[(y * s + x) * 4 + 3] > 20:
				var d := Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length()
				if d > max_r:
					max_r = d
	if max_r < 0.5:
		return img
	var half := mini(int(c), int(ceil(max_r)) + 1)
	if half < 2:
		return img
	var cropped := img.get_region(Rect2i(int(c) - half, int(c) - half, half * 2, half * 2))
	var target := maxi(4, int(round(float(s) * fill)))
	var scaled := cropped.duplicate()
	scaled.resize(target, target, Image.INTERPOLATE_LANCZOS)
	var out := _new(s)
	out.blit_rect(scaled, Rect2i(0, 0, target, target),
		Vector2i((s - target) / 2, (s - target) / 2))
	return out

# ================================================================ 地形 / 资源

## 地面 tile。低频用整数倍频率的正弦叠加 —— 天然周期，平铺时不会有接缝。
##
## 卡通化的关键在于「**基底要平**」：
## 瓦片会被平铺几百次，任何一点高频花纹都会变成规则的点阵，看起来像迷彩或脏污。
## 所以这里的正弦振幅压得很低（只够消除色带），大尺度的色块变化交给 ground_patch。
## 明度仍然量化成有限档（steps），保留「平涂」的卡通感。
static func ground_tile(base: Color, alt: Color, size: int = 64, steps: int = 3) -> ImageTexture:
	var img := _new(size)
	var f := TAU / float(size)
	var inv := 1.0 / float(maxi(2, steps) - 1)
	for y in range(size):
		var fy := float(y)
		for x in range(size):
			var fx := float(x)
			var n := 0.50 \
				+ 0.060 * sin(fx * f * 2.0 + 1.1) * sin(fy * f * 3.0 + 0.4) \
				+ 0.040 * sin(fx * f * 5.0 + 2.7) * sin(fy * f * 4.0 + 1.9) \
				+ 0.020 * sin(fx * f * 9.0 + 0.3) * sin(fy * f * 7.0 + 3.1)
			n += (_hash2(x, y) - 0.5) * 0.02
			n = roundf(clampf(n, 0.0, 1.0) * (float(steps) - 1.0)) * inv
			img.set_pixel(x, y, base.lerp(alt, n))
	# 碎石点缀。只提亮、不画暗底 —— 加了暗底会让每块瓦片上出现规则点阵。
	for k in range(3):
		var px := 5.0 + _hash2(k * 71 + 3, 11) * float(size - 10)
		var py := 5.0 + _hash2(k * 53 + 7, 29) * float(size - 10)
		var rr := 1.2 + _hash2(k * 17, 41) * 1.2
		_disc(img, px, py, rr, rr * 0.72, alt.lightened(0.14))
	return ImageTexture.create_from_image(img)

## 大尺度地貌斑块，叠加在 ground_tile 上，让地面不再是均匀一整片。
##
## 两个正弦相乘会产生规则的「圆形斑」，看起来像水渍。
## 再叠两对不同频率/相位的谐波把斑块打散，边界就自然了。
## 所有谐波都是 TAU/size 的整数倍，平铺依然无缝。
## alpha 走连续值而不是量化 —— 量化会在整片地面上留下硬边方框。
static func ground_patch(base: Color, alt: Color, size: int = 128, steps: int = 3) -> ImageTexture:
	var img := _new(size)
	var f := TAU / float(size)
	var inv := 1.0 / float(maxi(2, steps) - 1)
	for y in range(size):
		var fy := float(y)
		for x in range(size):
			var fx := float(x)
			var n := 0.5 \
				+ 0.26 * sin(fx * f * 1.0 + 0.7) * sin(fy * f * 1.0 + 2.1) \
				+ 0.18 * sin(fx * f * 2.0 + 3.3) * sin(fy * f * 2.0 + 0.9) \
				+ 0.13 * sin(fx * f * 3.0 + 1.7) * cos(fy * f * 1.0 + 4.2) \
				+ 0.09 * cos(fx * f * 1.0 + 5.1) * sin(fy * f * 3.0 + 0.3)
			var a := clampf((n - 0.42) * 1.8, 0.0, 1.0) * 0.22
			if a <= 0.004:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var nq := roundf(clampf(n, 0.0, 1.0) * (float(steps) - 1.0)) * inv
			var c := base.lerp(alt, nq)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a))
	return ImageTexture.create_from_image(img)

## 岩石 tile：格内噪声 + 顶部受光边 + 底部背光边 + 裂纹。
## 卡通化：明暗量化 + 顶部受光改成**硬边高光带**（渐变是写实的做法）。
static func rock_tile(dark: Color, darker: Color, size: int = 64, steps: int = 4) -> ImageTexture:
	var img := _new(size)
	var f := TAU / float(size)
	var inv := 1.0 / float(maxi(2, steps) - 1)
	for y in range(size):
		var fy := float(y)
		for x in range(size):
			var fx := float(x)
			var n := 0.5 + 0.42 * sin(fx * f * 2.0 + 0.6) * sin(fy * f * 3.0 + 1.4) \
				+ (_hash2(x * 3, y * 3) - 0.5) * 0.20
			n = roundf(clampf(n, 0.0, 1.0) * (float(steps) - 1.0)) * inv
			img.set_pixel(x, y, dark.lerp(darker, n))
	# 顶部受光：硬边高光带 + 其下一档过渡，而不是一路渐隐
	for y in range(6):
		var a := 0.26 if y < 3 else 0.13
		for x in range(size):
			var d := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(minf(1.0, d.r + a * 0.45), minf(1.0, d.g + a * 0.5),
				minf(1.0, d.b + a * 0.62), 1.0))
	# 底部背光：同样硬边
	for y in range(size - 7, size):
		var a := 0.34 if y > size - 4 else 0.17
		for x in range(size):
			var d := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(maxf(0.0, d.r - a), maxf(0.0, d.g - a), maxf(0.0, d.b - a), 1.0))
	# 裂纹
	for k in range(3):
		var x0 := 6.0 + _hash2(k * 31 + 5, 3) * float(size - 12)
		var y0 := 6.0 + _hash2(k * 47 + 9, 17) * float(size - 12)
		var x1 := clampf(x0 + (_hash2(k * 13, 23) - 0.5) * float(size) * 0.6, 2.0, float(size - 2))
		var y1 := clampf(y0 + (_hash2(k * 19, 31) - 0.5) * float(size) * 0.6, 2.0, float(size - 2))
		_line(img, Vector2(x0, y0), Vector2(x1, y1), darker.darkened(0.42), 1.5)
	return ImageTexture.create_from_image(img)

## 河道 / 深渊格：深水贴图。
##
## ⚠️ 这张贴图会被**平铺满整条河**（几百格），所以刻意不做「上沿受光 / 下沿进影」
##    那种单格立体感 —— 那样每 24px 就会出现一道明暗条纹，整条河看起来像斑马线。
##    水面感只能靠**横向的水波**（纵向频率高、横向几乎不变）来给。
##
## 颜色刻意选「偏青的深蓝」而不是纯黑：纯黑会和未探索的迷雾撞色，
## 玩家分不清「那里是河」还是「那里没去过」。
static func chasm_tile(deep: Color, shallow: Color, size: int = 64) -> ImageTexture:
	var img := _new(size)
	var f := TAU / float(size)
	for y in range(size):
		var fy := float(y)
		for x in range(size):
			var fx := float(x)
			# 两道横波叠加。第二道的相位被一个很慢的横向正弦扰动 ——
			# 完全笔直的波纹看起来像印刷图案，扰一下才有「水面」的松弛感。
			var n := 0.5 + 0.30 * sin(fy * f * 2.0 + 0.9) \
				+ 0.16 * sin(fy * f * 5.0 + 2.4 + sin(fx * f * 0.5) * 1.4) \
				+ (_hash2(x * 5, y * 7) - 0.5) * 0.12
			var t := clampf(n, 0.0, 1.0)
			var c := deep.lerp(shallow, t)
			# 波峰上再点一点青，让「水面」的色相和岩石彻底分开
			if t > 0.62:
				c = c.lerp(Color(0.36, 0.78, 0.86), (t - 0.62) * 0.85)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

## 晶体矿簇：几根高低不一的晶柱 + 地面碎晶。
static func mineral_cluster(main: Color, dark: Color) -> ImageTexture:
	var s := 48
	var img := _new(s)
	var c := float(s) * 0.5
	# 地面碎晶
	for k in range(7):
		var a := TAU * float(k) / 7.0 + 0.4
		var p := Vector2(c, c + 7.0) + Vector2(cos(a), sin(a)) * (12.0 + float((k * 13) % 6))
		_disc(img, p.x, p.y, 2.2, 1.7, dark.lightened(0.22))
	var pillars := [
		{"dx": -9.0, "dy": 5.0, "w": 8.0, "h": 15.0, "lit": 0.0},
		{"dx": 8.0, "dy": 6.0, "w": 7.0, "h": 12.0, "lit": 0.0},
		{"dx": 0.0, "dy": -3.0, "w": 10.0, "h": 20.0, "lit": 0.14},
		{"dx": -5.0, "dy": 10.0, "w": 6.0, "h": 9.0, "lit": 0.0},
	]
	for k in range(pillars.size()):
		var d: Dictionary = pillars[k]
		_crystal_pillar(img, c + float(d["dx"]), c + float(d["dy"]),
			float(d["w"]), float(d["h"]), main.lightened(float(d["lit"])), dark)
	_outline(img, Color(0.02, 0.035, 0.06, 0.88))
	return ImageTexture.create_from_image(img)

static func _crystal_pillar(img: Image, cx: float, cy: float, w: float, h: float,
		main: Color, dark: Color) -> void:
	var pts := PackedVector2Array([
		Vector2(cx, cy - h),
		Vector2(cx + w * 0.5, cy - h * 0.34),
		Vector2(cx + w * 0.42, cy + h * 0.55),
		Vector2(cx, cy + h * 0.78),
		Vector2(cx - w * 0.42, cy + h * 0.55),
		Vector2(cx - w * 0.5, cy - h * 0.34)])
	_poly(img, pts, dark)
	# 受光面（偏左）
	var lit := PackedVector2Array([
		Vector2(cx, cy - h),
		Vector2(cx - w * 0.5, cy - h * 0.34),
		Vector2(cx - w * 0.42, cy + h * 0.55),
		Vector2(cx, cy + h * 0.78),
		Vector2(cx - w * 0.06, cy - h * 0.12)])
	_poly(img, lit, main)
	_line(img, Vector2(cx, cy - h * 0.92), Vector2(cx - w * 0.20, cy + h * 0.44),
		Color(1, 1, 1, 0.40), 1.6)

## 气矿：喷口 + 三簇气囊 + 上升气流。
static func gas_cluster(main: Color, dark: Color) -> ImageTexture:
	var s := 48
	var img := _new(s)
	var c := float(s) * 0.5
	_disc(img, c, c + 4.0, 16.0, 13.0, Color(0.13, 0.19, 0.16))
	_disc(img, c, c + 4.0, 12.0, 9.5, Color(0.07, 0.13, 0.10))
	var bubbles := [
		{"dx": -6.0, "dy": -1.0, "r": 7.0},
		{"dx": 7.0, "dy": 1.0, "r": 6.0},
		{"dx": 0.0, "dy": -8.0, "r": 8.5},
	]
	for b in bubbles:
		var p := Vector2(c + float(b["dx"]), c + float(b["dy"]))
		var rr := float(b["r"])
		_disc(img, p.x, p.y, rr, rr * 0.9, dark)
		_disc(img, p.x - rr * 0.20, p.y - rr * 0.26, rr * 0.62, rr * 0.54, main)
		_disc(img, p.x - rr * 0.34, p.y - rr * 0.42, rr * 0.26, rr * 0.22, Color(1, 1, 1, 0.55))
	for k in range(4):
		var x := c - 8.0 + float(k) * 5.5
		_line(img, Vector2(x, c - 14.0), Vector2(x + 2.0, c - 23.0),
			Color(main.r, main.g, main.b, 0.34), 2.0)
	_outline(img, Color(0.02, 0.035, 0.06, 0.88))
	return ImageTexture.create_from_image(img)

## 柔和圆盘（阴影 / 光晕）
static func soft_disc(size: int, color: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(float(size) * 0.5, float(size) * 0.5)
	var r := float(size) * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(float(x) + 0.5, float(y) + 0.5).distance_to(c) / r
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * a))
	return ImageTexture.create_from_image(img)

## 柔和圆环（能量场 / 选中光环）
static func soft_ring(size: int, color: Color, radius: float = 0.74, thick: float = 0.10) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(float(size) * 0.5, float(size) * 0.5)
	var r := float(size) * 0.5
	var rr := radius * r
	var tt := maxf(1.0, thick * r)
	for y in range(size):
		for x in range(size):
			var d := absf(Vector2(float(x) + 0.5, float(y) + 0.5).distance_to(c) - rr)
			var a := clampf(1.0 - d / tt, 0.0, 1.0)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * a * a))
	return ImageTexture.create_from_image(img)

## 菌毯的单个「斑点」贴图。
##
## 为什么用贴图而不是逐格 draw_circle：菌毯要铺几百格，draw_texture_rect
## 每格只是 4 个顶点 + 一次贴图绑定，而 draw_circle 每格都要现场三角化成 32 段 ——
## 手机上这个差别很实在。
##
## 边缘刻意做成**不规则**的：规规矩矩的圆铺出来是一张「圆点网格」，
## 看着像在铺地砖；带随机凸起的边缘互相重叠之后才像生物质在蔓延。
##
## ⚠️ 随机起伏用「角度下标的哈希」而不是 randf()。GenTex 在启动时被调用，
##    而全局 RNG 是地图生成与 AI 决策共用的 —— 在这里抽一次随机数，
##    整局的随机序列就会平移，固定种子的集成测试可能因此偶发失败。
##
## phase 用来生成**轮廓不同**的多个变体。只做一张的话，每格图案完全相同，
## 整片菌毯铺出来会看到非常明显的重复纹理（像壁纸）。
static func creep_blob(size: int, color: Color, phase: int = 0) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	var r_max := c * 0.96
	var lobes := 14
	var radii: PackedFloat32Array = PackedFloat32Array()
	for i in range(lobes):
		var h := fmod(sin(float(i) * 12.9898 + float(phase) * 3.7) * 43758.5453, 1.0)
		# 起伏给得比较足（0.62~1.0）：起伏小的话斑点接近正圆，
		# 一堆圆叠出来还是能看出「一格一格」的排列感。
		radii.append(r_max * (0.62 + 0.38 * absf(h)))
	for y in range(size):
		for x in range(size):
			var dx := float(x) + 0.5 - c
			var dy := float(y) + 0.5 - c
			var d := sqrt(dx * dx + dy * dy)
			if d >= r_max:
				continue
			var ang := atan2(dy, dx)
			if ang < 0.0:
				ang += TAU
			var t := ang / TAU * float(lobes)
			var i0 := int(t) % lobes
			var i1 := (i0 + 1) % lobes
			var fr: float = t - floor(t)
			var k: float = fr * fr * (3.0 - 2.0 * fr)     # 平滑插值，否则边界出现折角
			var lim := lerpf(radii[i0], radii[i1], k)
			if d > lim:
				continue
			# 中心实、边缘柔（三次曲线，比线性更「厚」）
			var a: float = clampf(1.0 - pow(d / maxf(lim, 0.001), 3.0), 0.0, 1.0)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * a))
	return ImageTexture.create_from_image(img)

# ================================================================ 单位贴图

## 按 id 生成单位俯视贴图。贴图内「正前方」= 上方（-Y）。
static func unit_sprite(id: String, col: Color, dim: Color, accent: Color) -> ImageTexture:
	var img := _new(U_SIZE)
	var c := float(U_SIZE) * 0.5
	var hi := col.lightened(0.24)
	var lo := col.darkened(0.34)
	last_was_fallback = false
	match id:
		"scv":         _sp_worker_terran(img, c, col, dim, hi, lo, accent)
		"drone":       _sp_worker_zerg(img, c, col, dim, hi, lo, accent)
		"probe":       _sp_worker_protoss(img, c, col, dim, hi, lo, accent)
		"marine":      _sp_marine(img, c, col, dim, hi, lo, accent)
		"medic":       _sp_medic(img, c, col, dim, hi, lo, accent)
		"marauder":    _sp_marauder(img, c, col, dim, hi, lo, accent)
		"siege_tank":  _sp_tank(img, c, col, dim, hi, lo, accent)
		"vulture":     _sp_vulture(img, c, col, dim, hi, lo, accent)
		"zergling":    _sp_zergling(img, c, col, dim, hi, lo, accent)
		"hydralisk":   _sp_hydralisk(img, c, col, dim, hi, lo, accent)
		"roach":       _sp_roach(img, c, col, dim, hi, lo, accent)
		"mutalisk":    _sp_mutalisk(img, c, col, dim, hi, lo, accent)
		"wraith":      _sp_wraith(img, c, col, dim, hi, lo, accent)
		"scout":       _sp_scout(img, c, col, dim, hi, lo, accent)
		"zealot":      _sp_zealot(img, c, col, dim, hi, lo, accent)
		"dragoon":     _sp_dragoon(img, c, col, dim, hi, lo, accent)
		"archon":      _sp_archon(img, c, col, dim, hi, lo, accent)
		_:
			last_was_fallback = true
			_disc(img, c, c, 20.0, 20.0, col)
			_disc(img, c, c, 11.0, 11.0, hi)
	img = _fit(img, 0.94)
	_global_light(img, 0.34)
	_outline(img, Color(0.02, 0.035, 0.06, 0.95))
	return ImageTexture.create_from_image(img)

## SCV：履带底盘 + 前铲 + 驾驶舱
static func _sp_worker_terran(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_round_rect(img, c - 15, c - 13, 30, 26, 6, dim.darkened(0.38))
	# 前铲
	_poly(img, PackedVector2Array([
		Vector2(c - 12, c - 12), Vector2(c + 12, c - 12),
		Vector2(c + 9, c - 24), Vector2(c - 9, c - 24)]), col.lightened(0.12))
	# 车身
	_round_rect(img, c - 12, c - 10, 24, 23, 5, col)
	_bevel(img, c - 12, c - 10, 24, 23, 0.28, 0.32)
	_grain(img, c - 12, c - 10, 24, 23, 0.05, 11)
	# 两侧警示条
	_rect(img, c - 14, c - 8, 3, 18, accent.darkened(0.30))
	_rect(img, c + 11, c - 8, 3, 18, accent.darkened(0.30))
	# 驾驶舱
	_disc(img, c, c + 1, 6.5, 6.5, lo)
	_disc(img, c - 1, c - 0.5, 4.4, 4.4, accent)
	_disc(img, c - 2, c - 1.5, 2.0, 2.0, Color(1, 1, 1, 0.78))
	# 尾部排气
	_rect(img, c - 6, c + 10, 12, 5, dim.darkened(0.52))

## 工蜂：软体躯干 + 四足 + 前螯
static func _sp_worker_zerg(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	for s: float in [-1.0, 1.0]:
		_line(img, Vector2(c + s * 8, c - 3), Vector2(c + s * 19, c - 12), dim.darkened(0.34), 4.0)
		_line(img, Vector2(c + s * 8, c + 6), Vector2(c + s * 19, c + 14), dim.darkened(0.34), 4.0)
	_disc(img, c, c, 14.0, 15.0, col)
	_bevel(img, c - 14, c - 15, 28, 30, 0.26, 0.32)
	_grain(img, c - 14, c - 15, 28, 30, 0.06, 23)
	for k in range(3):
		var yy := c - 5.0 + float(k) * 5.5
		_line(img, Vector2(c - 10.0, yy), Vector2(c + 10.0, yy), lo, 1.8)
	_disc(img, c, c - 11.0, 8.0, 7.0, col.lightened(0.16))
	_poly(img, PackedVector2Array([
		Vector2(c - 7, c - 14), Vector2(c - 16, c - 24), Vector2(c - 4, c - 18)]), accent)
	_poly(img, PackedVector2Array([
		Vector2(c + 7, c - 14), Vector2(c + 16, c - 24), Vector2(c + 4, c - 18)]), accent)
	_disc(img, c, c + 7, 4.5, 4.5, Color(0.35, 0.78, 1.0, 0.85))

## 探机：三根对称支架 + 悬浮核心
static func _sp_worker_protoss(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	for k in range(3):
		var a := -PI * 0.5 + TAU * float(k) / 3.0
		var tip := Vector2(c, c) + Vector2(cos(a), sin(a)) * 20.0
		_line(img, Vector2(c, c), tip, dim.lightened(0.14), 3.6)
		_disc(img, tip.x, tip.y, 3.6, 3.6, accent)
	_disc(img, c, c, 12.0, 12.0, dim)
	_ring(img, c, c, 11.0, 2.8, col)
	_disc(img, c, c, 7.5, 7.5, col.lightened(0.18))
	_disc(img, c - 1.5, c - 1.5, 4.0, 4.0, accent)
	_disc(img, c - 2.2, c - 2.2, 1.8, 1.8, Color(1, 1, 1, 0.88))

## 陆战队员：方形肩甲 + 头盔 + 步枪
static func _sp_marine(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_disc(img, c - 6, c + 11, 4.5, 5.5, lo)
	_disc(img, c + 6, c + 11, 4.5, 5.5, lo)
	# 肩甲：俯视下是躯干两侧的方形护甲。做成大圆会像米老鼠耳朵。
	_round_rect(img, c - 16, c - 7, 7.5, 15, 2.5, col.lightened(0.12))
	_round_rect(img, c + 8.5, c - 7, 7.5, 15, 2.5, col.lightened(0.12))
	_round_rect(img, c - 9, c - 8, 18, 22, 7, col)
	_bevel(img, c - 9, c - 8, 18, 22, 0.28, 0.30)
	_grain(img, c - 9, c - 8, 18, 22, 0.05, 31)
	_disc(img, c, c - 10, 6.2, 6.2, lo)
	_disc(img, c, c - 11, 4.2, 4.2, accent)
	_rect(img, c - 4.5, c - 14, 9, 2.4, Color(0.86, 0.95, 1.0, 0.92))
	# 步枪：粗一点，不然看着像根天线
	_rect(img, c + 2.0, c - 23, 4.8, 15, Color(0.19, 0.22, 0.27))
	_rect(img, c + 1.0, c - 26, 6.8, 3.6, Color(0.30, 0.34, 0.40))

## 医疗兵：全场唯一不拿枪的人族单位，靠「白底红十字的药箱」一眼认出。
## 肩甲刻意比陆战队员窄一圈 —— 他穿的不是重甲。
static func _sp_medic(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_disc(img, c - 6, c + 12, 4.2, 5.0, lo)
	_disc(img, c + 6, c + 12, 4.2, 5.0, lo)
	_round_rect(img, c - 14, c - 6, 6.0, 12, 2.2, col.lightened(0.10))
	_round_rect(img, c + 8, c - 6, 6.0, 12, 2.2, col.lightened(0.10))
	_round_rect(img, c - 8, c - 9, 16, 21, 6, col)
	_bevel(img, c - 8, c - 9, 16, 21, 0.28, 0.30)
	_grain(img, c - 8, c - 9, 16, 21, 0.05, 53)
	# 药箱：俯视下背包压在背上，所以画在躯干**之上**
	_round_rect(img, c - 6.5, c - 1, 13, 12, 2.6, Color(0.92, 0.94, 0.97))
	_rect(img, c - 5.0, c + 3.8, 10.0, 2.8, Color(0.83, 0.19, 0.17))
	_rect(img, c - 1.4, c + 0.6, 2.8, 9.2, Color(0.83, 0.19, 0.17))
	# 头 + 浅青面罩（和陆战队员的深蓝面罩区分）
	_disc(img, c, c - 12, 5.6, 5.6, lo)
	_disc(img, c, c - 13, 3.9, 3.9, Color(0.55, 0.90, 0.95))
	_rect(img, c - 3.8, c - 15.6, 7.6, 2.2, Color(0.88, 0.97, 1.0, 0.92))

## 劫掠者：加宽躯干 + 双联榴弹炮
static func _sp_marauder(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_disc(img, c - 7, c + 12, 5.0, 6.0, lo)
	_disc(img, c + 7, c + 12, 5.0, 6.0, lo)
	_round_rect(img, c - 18, c - 8, 8.5, 17, 3, col.lightened(0.10))
	_round_rect(img, c + 9.5, c - 8, 8.5, 17, 3, col.lightened(0.10))
	_round_rect(img, c - 11, c - 9, 22, 24, 8, col)
	_bevel(img, c - 11, c - 9, 22, 24, 0.26, 0.30)
	_grain(img, c - 11, c - 9, 22, 24, 0.05, 47)
	_disc(img, c, c - 11, 6.6, 6.6, lo)
	_disc(img, c, c - 12, 4.4, 4.4, accent)
	_rect(img, c - 4.5, c - 15, 9, 2.4, Color(0.86, 0.95, 1.0, 0.75))
	for s: float in [-1.0, 1.0]:
		_rect(img, c + s * 6.0 - 2.9, c - 22, 5.8, 14, Color(0.21, 0.24, 0.29))
		_disc(img, c + s * 6.0, c - 22, 3.4, 3.4, accent.darkened(0.18))

## 攻城坦克：履带 + 车体 + 炮塔 + 主炮
static func _sp_tank(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_round_rect(img, c - 19, c - 14, 10, 30, 3, Color(0.15, 0.17, 0.21))
	_round_rect(img, c + 9, c - 14, 10, 30, 3, Color(0.15, 0.17, 0.21))
	for k in range(6):
		var yy := c - 13.0 + float(k) * 4.8
		_rect(img, c - 19, yy, 10, 1.8, Color(0.28, 0.31, 0.37))
		_rect(img, c + 9, yy, 10, 1.8, Color(0.28, 0.31, 0.37))
	_round_rect(img, c - 10, c - 14, 20, 30, 4, col)
	_bevel(img, c - 10, c - 14, 20, 30, 0.26, 0.32)
	_grain(img, c - 10, c - 14, 20, 30, 0.05, 59)
	_disc(img, c, c + 1, 10.0, 10.0, col.lightened(0.14))
	_ring(img, c, c + 1, 9.6, 2.0, lo)
	_rect(img, c - 2.8, c - 26, 5.6, 26, Color(0.21, 0.24, 0.29))
	_rect(img, c - 4.6, c - 29, 9.2, 4.4, Color(0.30, 0.34, 0.41))
	_disc(img, c, c + 1, 3.8, 3.8, accent)

## 秃鹫：菱形车身 + 前叉 + 气垫
static func _sp_vulture(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_disc(img, c, c + 3, 15.0, 13.0, Color(dim.r, dim.g, dim.b, 0.55))
	_poly(img, PackedVector2Array([
		Vector2(c, c - 21), Vector2(c + 13, c + 5),
		Vector2(c, c + 20), Vector2(c - 13, c + 5)]), col)
	_bevel(img, c - 13, c - 21, 26, 41, 0.26, 0.30)
	_grain(img, c - 13, c - 21, 26, 41, 0.05, 71)
	_line(img, Vector2(c - 6, c - 13), Vector2(c - 11, c - 25), lo, 3.4)
	_line(img, Vector2(c + 6, c - 13), Vector2(c + 11, c - 25), lo, 3.4)
	_disc(img, c, c - 3, 7.0, 9.0, lo)
	_disc(img, c - 1, c - 4, 4.6, 6.0, accent)
	_disc(img, c - 1.6, c - 5.5, 2.2, 2.8, Color(1, 1, 1, 0.72))
	_disc(img, c, c + 17, 4.0, 4.0, Color(0.35, 0.72, 1.0, 0.78))

## 跳虫：水滴躯干 + 双镰刀爪 + 脊刺
static func _sp_zergling(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_line(img, Vector2(c - 5, c + 5), Vector2(c - 16, c + 15), lo, 3.4)
	_line(img, Vector2(c + 5, c + 5), Vector2(c + 16, c + 15), lo, 3.4)
	_poly(img, PackedVector2Array([
		Vector2(c - 6, c - 7), Vector2(c - 22, c - 19), Vector2(c - 4, c - 14)]), accent.darkened(0.08))
	_poly(img, PackedVector2Array([
		Vector2(c + 6, c - 7), Vector2(c + 22, c - 19), Vector2(c + 4, c - 14)]), accent.darkened(0.08))
	_poly(img, PackedVector2Array([
		Vector2(c, c - 16), Vector2(c + 10, c + 2),
		Vector2(c, c + 16), Vector2(c - 10, c + 2)]), col)
	_bevel(img, c - 10, c - 16, 20, 32, 0.26, 0.32)
	_grain(img, c - 10, c - 16, 20, 32, 0.06, 83)
	_disc(img, c, c - 10, 7.0, 6.0, col.lightened(0.18))
	_disc(img, c, c - 11, 3.2, 3.2, accent)
	for k in range(3):
		var yy := c - 2.0 + float(k) * 5.5
		_poly(img, PackedVector2Array([
			Vector2(c, yy - 3.4), Vector2(c + 3.4, yy), Vector2(c, yy + 3.4)]), lo)

## 刺蛇：蛇形躯干 + 双镰臂 + 六足
static func _sp_hydralisk(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_line(img, Vector2(c, c + 9), Vector2(c, c + 26), col, 8.5)
	_line(img, Vector2(c, c + 21), Vector2(c, c + 29), lo, 4.5)
	for s: float in [-1.0, 1.0]:
		_line(img, Vector2(c + s * 5, c - 2), Vector2(c + s * 18, c - 10), lo, 3.2)
		_line(img, Vector2(c + s * 5, c + 4), Vector2(c + s * 18, c + 8), lo, 3.2)
		_line(img, Vector2(c + s * 4, c + 9), Vector2(c + s * 15, c + 18), lo, 3.2)
	_round_rect(img, c - 8, c - 14, 16, 29, 7, col)
	_bevel(img, c - 8, c - 14, 16, 29, 0.26, 0.32)
	_grain(img, c - 8, c - 14, 16, 29, 0.06, 97)
	_disc(img, c, c - 15, 7.5, 7.0, col.lightened(0.16))
	# 双镰臂：向前弯的刀锋（不是向外张开的三角，那样像花瓣）
	_poly(img, PackedVector2Array([
		Vector2(c - 6, c - 11), Vector2(c - 12, c - 26), Vector2(c - 2, c - 20)]), accent)
	_poly(img, PackedVector2Array([
		Vector2(c + 6, c - 11), Vector2(c + 12, c - 26), Vector2(c + 2, c - 20)]), accent)
	_rect(img, c - 4.0, c - 23, 8, 3.6, Color(0.72, 0.95, 0.55, 0.9))

## 蟑螂：宽扁甲壳 + 六足 + 分节
static func _sp_roach(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	for s: float in [-1.0, 1.0]:
		_line(img, Vector2(c + s * 10, c - 6), Vector2(c + s * 21, c - 14), lo, 3.6)
		_line(img, Vector2(c + s * 11, c + 1), Vector2(c + s * 22, c + 1), lo, 3.6)
		_line(img, Vector2(c + s * 10, c + 8), Vector2(c + s * 20, c + 16), lo, 3.6)
	_disc(img, c, c, 16.0, 14.0, col)
	_bevel(img, c - 16, c - 14, 32, 28, 0.26, 0.32)
	_grain(img, c - 16, c - 14, 32, 28, 0.06, 109)
	for k in range(3):
		var yy := c - 6.0 + float(k) * 6.5
		_line(img, Vector2(c - 13.0, yy), Vector2(c + 13.0, yy), lo, 2.0)
	_disc(img, c, c - 11, 9.0, 7.0, col.darkened(0.14))
	_disc(img, c, c - 12, 5.5, 4.0, accent)
	_disc(img, c - 6, c + 2, 4.6, 3.8, col.lightened(0.12))
	_disc(img, c + 6, c + 2, 4.6, 3.8, col.lightened(0.12))

## 飞龙：菱形身体 + 双翼 + 尾刺
static func _sp_mutalisk(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_poly(img, PackedVector2Array([
		Vector2(c - 3, c - 5), Vector2(c - 27, c - 19),
		Vector2(c - 29, c + 2), Vector2(c - 5, c + 5)]), col.darkened(0.24))
	_poly(img, PackedVector2Array([
		Vector2(c + 3, c - 5), Vector2(c + 27, c - 19),
		Vector2(c + 29, c + 2), Vector2(c + 5, c + 5)]), col.darkened(0.24))
	_line(img, Vector2(c - 4, c - 3), Vector2(c - 26, c - 16), lo, 2.0)
	_line(img, Vector2(c + 4, c - 3), Vector2(c + 26, c - 16), lo, 2.0)
	_line(img, Vector2(c, c + 8), Vector2(c, c + 27), col, 4.5)
	_poly(img, PackedVector2Array([
		Vector2(c, c + 24), Vector2(c - 7, c + 31), Vector2(c, c + 29), Vector2(c + 7, c + 31)]), accent)
	_round_rect(img, c - 8, c - 11, 16, 23, 7, col)
	_bevel(img, c - 8, c - 11, 16, 23, 0.28, 0.32)
	_disc(img, c, c - 12, 6.6, 6.0, col.lightened(0.18))
	_disc(img, c, c - 13, 3.4, 3.4, accent)

## 幽灵战机：细长三角机身 + 大后掠翼 + 双垂尾。
## 俯视角，贴图内「上 = 机头」（Main 用 facing + PI/2 旋转，与其它单位一致）。
## 机身刻意做得比狂热者窄 —— 一眼能看出这是「薄薄一片」的飞行器。
static func _sp_wraith(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	# 机翼：画在机身之前，翼根被机身压住
	for s: float in [-1.0, 1.0]:
		_poly(img, PackedVector2Array([
			Vector2(c + s * 3, c - 6), Vector2(c + s * 27, c + 10),
			Vector2(c + s * 25, c + 18), Vector2(c + s * 4, c + 8)]), col.darkened(0.22))
		_line(img, Vector2(c + s * 5, c - 4), Vector2(c + s * 26, c + 11), lo, 1.8)
	# 双垂尾
	for s2: float in [-1.0, 1.0]:
		_poly(img, PackedVector2Array([
			Vector2(c + s2 * 2, c + 14), Vector2(c + s2 * 11, c + 26),
			Vector2(c + s2 * 9, c + 29), Vector2(c + s2 * 2, c + 24)]), dim.darkened(0.30))
	# 机身：细长菱形，机头尖
	_poly(img, PackedVector2Array([
		Vector2(c, c - 27), Vector2(c + 7, c - 4), Vector2(c + 6, c + 18),
		Vector2(c, c + 23), Vector2(c - 6, c + 18), Vector2(c - 7, c - 4)]), col)
	_bevel(img, c - 7, c - 20, 14, 40, 0.30, 0.30)
	_grain(img, c - 7, c - 14, 14, 34, 0.05, 43)
	# 座舱
	_disc(img, c, c - 12, 4.2, 6.0, accent.darkened(0.10))
	_disc(img, c - 1, c - 14, 2.2, 3.0, Color(1, 1, 1, 0.70))
	# 尾焰
	_disc(img, c, c + 26, 4.5, 3.0, accent)

## 侦察机：宽机身 + 两侧引擎舱 + 尖机头。
## 和幽灵战机刻意做出体量差 —— 神族空军是「贵而重」，人族是「快而薄」。
static func _sp_scout(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	# 两侧引擎舱
	for s: float in [-1.0, 1.0]:
		_round_rect(img, c + s * 15.0 - 5.0, c - 14, 10, 30, 4, dim.darkened(0.34))
		_disc(img, c + s * 15, c + 16, 4.2, 3.4, accent.darkened(0.24))
	# 机翼：连接机身与引擎舱
	for s2: float in [-1.0, 1.0]:
		_poly(img, PackedVector2Array([
			Vector2(c + s2 * 4, c - 10), Vector2(c + s2 * 17, c - 6),
			Vector2(c + s2 * 17, c + 8), Vector2(c + s2 * 4, c + 10)]), col.darkened(0.16))
	# 机身：比幽灵战机宽一圈
	_poly(img, PackedVector2Array([
		Vector2(c, c - 25), Vector2(c + 9, c - 6), Vector2(c + 9, c + 16),
		Vector2(c, c + 22), Vector2(c - 9, c + 16), Vector2(c - 9, c - 6)]), col)
	_bevel(img, c - 9, c - 18, 18, 36, 0.30, 0.30)
	_grain(img, c - 9, c - 12, 18, 30, 0.05, 71)
	# 座舱
	_disc(img, c, c - 10, 5.0, 7.0, accent.darkened(0.06))
	_disc(img, c - 1, c - 13, 2.6, 3.4, Color(1, 1, 1, 0.72))

## 狂热者：神族标志性大肩甲 + 光刃握柄
static func _sp_zealot(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	_disc(img, c - 6, c + 12, 4.5, 5.5, lo)
	_disc(img, c + 6, c + 12, 4.5, 5.5, lo)
	_round_rect(img, c - 9, c - 8, 18, 22, 7, col)
	_bevel(img, c - 9, c - 8, 18, 22, 0.28, 0.30)
	_grain(img, c - 9, c - 8, 18, 22, 0.05, 127)
	_poly(img, PackedVector2Array([
		Vector2(c - 18, c - 13), Vector2(c - 6, c - 11),
		Vector2(c - 7, c + 3), Vector2(c - 17, c + 2)]), col.lightened(0.14))
	_poly(img, PackedVector2Array([
		Vector2(c + 18, c - 13), Vector2(c + 6, c - 11),
		Vector2(c + 7, c + 3), Vector2(c + 17, c + 2)]), col.lightened(0.14))
	_ring(img, c - 12, c - 5, 5.2, 1.8, accent.darkened(0.24))
	_ring(img, c + 12, c - 5, 5.2, 1.8, accent.darkened(0.24))
	_disc(img, c, c - 10, 5.8, 5.8, lo)
	_disc(img, c, c - 11, 3.6, 3.6, accent)
	_line(img, Vector2(c - 8, c - 4), Vector2(c - 12, c - 20), accent.darkened(0.32), 3.4)
	_line(img, Vector2(c + 8, c - 4), Vector2(c + 12, c - 20), accent.darkened(0.32), 3.4)

## 龙骑士：四足机械 + 炮塔 + 相位炮
static func _sp_dragoon(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	for k in range(4):
		var a := PI * 0.25 + PI * 0.5 * float(k)
		var d := Vector2(cos(a), sin(a))
		var base := Vector2(c, c + 2) + d * 8.0
		var tip := Vector2(c, c + 2) + d * 23.0
		_line(img, base, tip, dim.lightened(0.12), 4.0)
		_disc(img, tip.x, tip.y, 3.4, 3.4, lo)
	_disc(img, c, c + 1, 15.0, 14.0, dim)
	_ring(img, c, c + 1, 14.4, 2.2, col)
	_disc(img, c, c + 1, 11.0, 10.5, col.lightened(0.12))
	_disc(img, c, c - 1, 8.0, 8.0, col.lightened(0.22))
	_rect(img, c - 2.8, c - 25, 5.6, 21, Color(0.29, 0.33, 0.41))
	_disc(img, c, c - 25, 4.2, 4.2, accent)
	_disc(img, c, c - 25, 2.0, 2.0, Color(0.78, 0.96, 1.0))

## 执政官：能量体 + 放射光芒
static func _sp_archon(img: Image, c: float, col: Color, dim: Color,
		hi: Color, lo: Color, accent: Color) -> void:
	for k in range(8):
		var a := TAU * float(k) / 8.0
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 13.0, Vector2(c, c) + d * 23.0,
			Color(accent.r, accent.g, accent.b, 0.60), 2.6)
	_disc(img, c, c, 21.0, 21.0, Color(col.r, col.g, col.b, 0.28))
	_disc(img, c, c, 17.0, 17.0, Color(col.r, col.g, col.b, 0.42))
	_ring(img, c, c, 19.5, 2.2, Color(accent.r, accent.g, accent.b, 0.58))
	_disc(img, c, c, 12.0, 12.0, col.lightened(0.12))
	_disc(img, c, c, 8.0, 8.0, accent)
	_disc(img, c - 1.2, c - 1.2, 4.2, 4.2, Color(1, 1, 1, 0.94))

# ================================================================ 建筑贴图

## 按 id 生成建筑俯视贴图。建筑不旋转。
static func building_sprite(id: String, col: Color, dim: Color, accent: Color) -> ImageTexture:
	var img := _new(B_SIZE)
	var c := float(B_SIZE) * 0.5
	# ⚠️ 底盘阵营必须从 GameData 查，**不要**硬编码 id 列表。
	# 硬编码的话，每加一个建筑都会悄悄落进 else 分支被画成神族底盘 ——
	# 而且不会有任何报错。第七轮加工程湾 / 进化腔 / 熔炉时就踩过一次，
	# 本轮的导弹塔 / 孢子菌落又踩了一次（人族的塔画着神族的底盘）。
	var race := String(GameData.get_building(id).get("faction", "protoss"))
	match race:
		"terran": _bg_terran(img, c, col, dim, accent)
		"zerg":   _bg_zerg(img, c, col, dim, accent)
		_:        _bg_protoss(img, c, col, dim, accent)
	last_was_fallback = false
	match id:
		"command_center":   _bb_command_center(img, c, col, dim, accent)
		"supply_depot":     _bb_supply_depot(img, c, col, dim, accent)
		"barracks":         _bb_barracks(img, c, col, dim, accent)
		"engineering_bay":  _bb_engineering_bay(img, c, col, dim, accent)
		"factory":          _bb_factory(img, c, col, dim, accent)
		"refinery":         _bb_refinery(img, c, col, dim, accent)
		"hive":             _bb_hive(img, c, col, dim, accent)
		"spawning_pool":    _bb_spawning_pool(img, c, col, dim, accent)
		"evolution_chamber": _bb_evolution_chamber(img, c, col, dim, accent)
		"spire":            _bb_spire(img, c, col, dim, accent)
		"extractor":        _bb_extractor(img, c, col, dim, accent)
		"nexus":            _bb_nexus(img, c, col, dim, accent)
		"pylon":            _bb_pylon(img, c, col, dim, accent)
		"gateway":          _bb_gateway(img, c, col, dim, accent)
		"cybernetics_core": _bb_cybernetics_core(img, c, col, dim, accent)
		"forge":            _bb_forge(img, c, col, dim, accent)
		"templar_archives": _bb_templar_archives(img, c, col, dim, accent)
		"assimilator":      _bb_assimilator(img, c, col, dim, accent)
		"missile_turret":   _bb_missile_turret(img, c, col, dim, accent)
		"spore_colony":     _bb_spore_colony(img, c, col, dim, accent)
		"photon_cannon":    _bb_photon_cannon(img, c, col, dim, accent)
		"stargate":         _bb_stargate(img, c, col, dim, accent)
		_:
			last_was_fallback = true
			_disc(img, c, c, 34.0, 32.0, dim)
			_ring(img, c, c, 33.0, 3.0, col)
			_disc(img, c, c, 16.0, 16.0, accent)
	img = _fit(img, 0.94)
	_global_light(img, 0.26)
	_outline(img, Color(0.02, 0.035, 0.06, 0.95))
	return ImageTexture.create_from_image(img)

## 导弹塔：方形基座 + 旋转炮塔 + 两根朝上的发射管。
## 造型刻意做得「方正、有棱角」，和神族光子炮台的几何感区分开。
static func _bb_missile_turret(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_round_rect(img, c - 24, c - 20, 48, 44, 6, dim.darkened(0.30))
	_round_rect(img, c - 21, c - 17, 42, 38, 5, col)
	_bevel(img, c - 21, c - 17, 42, 38, 0.30, 0.32)
	_grain(img, c - 21, c - 17, 42, 38, 0.05, 19)
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			_disc(img, c + sx * 17, c + sy * 14, 2.6, 2.6, dim.darkened(0.48))
	# 炮塔
	_disc(img, c, c - 2, 15.0, 15.0, dim.darkened(0.18))
	_disc(img, c, c - 3, 12.0, 12.0, col.lightened(0.10))
	# 两根朝上的发射管 —— 塔的朝向不随目标变，所以做成对称的
	for s: float in [-1.0, 1.0]:
		_round_rect(img, c + s * 8.0 - 4.0, c - 30, 8, 22, 3, dim.darkened(0.44))
		_round_rect(img, c + s * 8.0 - 2.6, c - 32, 5.2, 20, 2, accent.darkened(0.20))
	_disc(img, c, c - 2, 5.0, 5.0, accent)
	_disc(img, c - 1, c - 4, 2.2, 2.2, Color(1, 1, 1, 0.75))

## 孢子菌落：虫族的**对空**防御 —— 一圈根刺 + 细高的杆 + 顶上一颗孢子囊。
##
## ⚠️ 必须做得「高」。两个理由：
##   1. 它是打飞机的塔，矮胖的轮廓会让玩家下意识以为它够不到天上；
##   2. 矮胖版和进化腔（矮而宽的腔体）都是「紫色带刺的圆球」，
##      在手机上缩到 0.6 倍时几乎分不出来 —— 而这两个建筑一个管防空、一个管升级，
##      认错代价不小。
static func _bb_spore_colony(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	# 根部：贴地撑开的一圈骨刺
	for i in range(6):
		var a := TAU * float(i) / 6.0 + 0.3
		var d := Vector2(cos(a), sin(a))
		var b0 := Vector2(c, c + 15.0)
		_line(img, b0, b0 + d * 18.0, dim.darkened(0.46), 4.8)
		_disc(img, b0.x + d.x * 18.0, b0.y + d.y * 18.0, 2.6, 2.6, col.darkened(0.16))
	# 主干：细高的杆（先画深色再叠亮色，得到一根有明暗的圆柱）
	_line(img, Vector2(c, c + 17.0), Vector2(c, c - 12.0), col.darkened(0.30), 11.0)
	_line(img, Vector2(c - 1.0, c + 17.0), Vector2(c - 1.0, c - 12.0), col.lightened(0.06), 5.6)
	# 囊托
	_disc(img, c, c - 13.0, 14.0, 11.0, col.darkened(0.18))
	# 顶部的孢子囊
	_disc(img, c, c - 21.0, 16.0, 15.0, col)
	_bevel(img, c - 16, c - 36, 32, 30, 0.30, 0.30)
	_disc(img, c, c - 23.0, 10.0, 9.0, accent.darkened(0.10))
	_disc(img, c - 3.0, c - 27.0, 4.4, 4.4, Color(1, 1, 1, 0.66))
	# 囊体外甩的孢子刺
	for i in range(5):
		var a2 := PI * (0.14 + 0.18 * float(i))
		var d2 := Vector2(cos(a2), sin(a2))
		var p0 := Vector2(c, c - 21.0)
		_line(img, p0 + d2 * 14.0, p0 + d2 * 22.0, accent.darkened(0.30), 3.0)

## 光子炮台：三足基座 + 悬浮晶体 + 光环。
## ⚠️ 三条腿必须画得**比底盘明显深**。神族的底盘本身就是金色，
##    第一版把腿画成 dim.darkened(0.36)（还是金色），整组腿都融进底盘里，
##    放大图上只剩一个金色圆盘 —— 看不出这是「架在三脚架上的炮」。
##    凡是画在底盘范围内的部件，都要先问一句「它和底盘差几个明度」。
static func _bb_photon_cannon(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	var leg := Color(0.16, 0.13, 0.10)   # 深青铜：靠明度差从金色底盘里跳出来
	for i in range(3):
		var a := -PI * 0.5 + TAU * float(i) / 3.0
		var tp := Vector2(c + cos(a) * 31.0, c + 9 + sin(a) * 27.0)
		_line(img, Vector2(c, c + 3), tp, leg, 8.0)
		_disc(img, tp.x, tp.y, 5.2, 4.6, leg.lightened(0.20))
		_disc(img, tp.x, tp.y, 2.4, 2.2, accent.darkened(0.24))
	# 基座：深色圆盘，让上面的晶体有依托
	_disc(img, c, c + 5, 19.0, 13.0, leg.lightened(0.08))
	_disc(img, c, c + 4, 15.0, 10.0, col.darkened(0.18))
	# 悬浮晶体
	_poly(img, PackedVector2Array([
		Vector2(c, c - 29), Vector2(c + 13, c - 8),
		Vector2(c, c + 7), Vector2(c - 13, c - 8)]), col.lightened(0.20))
	_ring(img, c, c - 10, 20.0, 2.6, accent)
	_disc(img, c, c - 10, 7.0, 9.0, accent)
	_disc(img, c - 2, c - 13, 3.0, 4.0, Color(1, 1, 1, 0.80))

## 星际之门：巨大的环形门框 + 内部能量漩涡 + 四个门齿。
## 体量做得最大 —— 它是神族空军的生产建筑，应该一眼看出「这是个大家伙」。
static func _bb_stargate(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for i in range(4):
		var a := TAU * float(i) / 4.0 + PI * 0.25
		var p1 := Vector2(c + cos(a) * 30.0, c + sin(a) * 29.0)
		var p2 := Vector2(c + cos(a) * 42.0, c + sin(a) * 41.0)
		_line(img, p1, p2, col.lightened(0.10), 5.0)
	_disc(img, c, c, 38.0, 36.0, dim.darkened(0.34))
	_ring(img, c, c, 36.0, 7.0, col)
	_ring(img, c, c, 28.0, 3.0, col.lightened(0.14))
	# 门内的能量
	_disc(img, c, c, 26.0, 24.0, Color(0.10, 0.16, 0.30, 1.0))
	_disc(img, c, c, 18.0, 17.0, accent.darkened(0.34))
	_disc(img, c, c, 10.0, 9.5, accent)
	_disc(img, c - 3, c - 3, 4.5, 4.5, Color(1, 1, 1, 0.72))

## 人族底盘：方正金属 + 四角铆钉 + 警示斜纹
static func _bg_terran(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	var r := 40.0
	_round_rect(img, c - r + 1.5, c - r + 3.5, r * 2.0, r * 2.0, 8.0, Color(0, 0, 0, 0.26))
	_round_rect(img, c - r, c - r, r * 2.0, r * 2.0, 7.0, dim.darkened(0.20))
	_round_rect(img, c - r + 4, c - r + 4, r * 2.0 - 8, r * 2.0 - 8, 5.0, dim)
	_bevel(img, c - r + 4, c - r + 4, r * 2.0 - 8, r * 2.0 - 8, 0.24, 0.30)
	_grain(img, c - r + 4, c - r + 4, r * 2.0 - 8, r * 2.0 - 8, 0.05, 7)
	_frame(img, c - r, c - r, r * 2.0, r * 2.0, col, 3.0)
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			var p := Vector2(c + sx * (r - 6.0), c + sy * (r - 6.0))
			_disc(img, p.x, p.y, 3.2, 3.2, col.darkened(0.28))
			_disc(img, p.x - 0.7, p.y - 0.7, 1.7, 1.7, accent)
	for k in range(3):
		var x := c - r + 7.0 + float(k) * 6.0
		_line(img, Vector2(x, c + r - 6.0), Vector2(x + 5.0, c + r - 11.0),
			Color(0.95, 0.78, 0.25, 0.50), 2.2)

## 虫族底盘：有机甲壳 + 外缘尖刺 + 生长纹
static func _bg_zerg(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	var r := 40.0
	_disc(img, c + 1.5, c + 3.5, r, r * 0.94, Color(0, 0, 0, 0.26))
	_disc(img, c, c, r, r * 0.94, dim.darkened(0.18))
	_disc(img, c, c, r - 4.0, r * 0.94 - 4.0, dim)
	_bevel(img, c - r + 4, c - r * 0.94 + 4, (r - 4.0) * 2.0, (r * 0.94 - 4.0) * 2.0, 0.24, 0.30)
	_grain(img, c - r + 4, c - r * 0.94 + 4, (r - 4.0) * 2.0, (r * 0.94 - 4.0) * 2.0, 0.06, 13)
	_ring(img, c, c, r - 1.5, 3.0, col)
	for k in range(14):
		var a := TAU * float(k) / 14.0 + 0.2
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * (r - 7.0), Vector2(c, c) + d * (r + 5.0), col.darkened(0.24), 3.4)
		_disc(img, c + d.x * (r + 5.0), c + d.y * (r + 5.0), 2.2, 2.2, accent.darkened(0.32))
	for k in range(3):
		_ring(img, c, c, 11.0 + float(k) * 8.0, 1.8, Color(col.r, col.g, col.b, 0.40))

## 神族底盘：八边形 + 金色边框 + 四向宝石
static func _bg_protoss(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	var r := 40.0
	var oct := PackedVector2Array()
	var oct2 := PackedVector2Array()
	var shadow := PackedVector2Array()
	for k in range(8):
		var a := TAU * float(k) / 8.0 + PI / 8.0
		var d := Vector2(cos(a), sin(a))
		oct.append(Vector2(c, c) + d * r)
		oct2.append(Vector2(c, c) + d * (r - 5.0))
		shadow.append(Vector2(c, c) + d * r + Vector2(1.5, 3.5))
	_poly(img, shadow, Color(0, 0, 0, 0.26))
	_poly(img, oct, dim.darkened(0.18))
	_poly(img, oct2, dim)
	_bevel(img, c - r + 5, c - r + 5, (r - 5.0) * 2.0, (r - 5.0) * 2.0, 0.24, 0.30)
	_grain(img, c - r + 5, c - r + 5, (r - 5.0) * 2.0, (r - 5.0) * 2.0, 0.05, 19)
	_ring(img, c, c, r - 1.0, 3.0, col)
	_ring(img, c, c, r - 12.0, 1.6, Color(col.r, col.g, col.b, 0.38))
	for k in range(4):
		var a := PI * 0.5 * float(k)
		var p := Vector2(c, c) + Vector2(cos(a), sin(a)) * (r - 6.0)
		_disc(img, p.x, p.y, 3.4, 3.4, accent.darkened(0.12))
		_disc(img, p.x - 0.8, p.y - 0.8, 1.7, 1.7, Color(1, 1, 1, 0.78))

# ---------------------------------------------------------------- 人族建筑特征

static func _bb_command_center(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_disc(img, c, c, 17.0, 17.0, dim.lightened(0.12))
	_ring(img, c, c, 16.4, 2.6, col)
	_disc(img, c, c, 12.0, 12.0, Color(0.20, 0.32, 0.46))
	_disc(img, c, c, 8.5, 8.5, Color(0.34, 0.54, 0.74))
	_line(img, Vector2(c, c), Vector2(c + 15.0, c - 9.0), Color(0.64, 0.91, 1.0, 0.88), 2.6)
	_disc(img, c - 2.0, c - 2.0, 4.0, 4.0, Color(0.80, 0.94, 1.0, 0.55))
	for sx: float in [-1.0, 1.0]:
		for sy: float in [-1.0, 1.0]:
			var p := Vector2(c + sx * 26.0, c + sy * 26.0)
			_disc(img, p.x, p.y, 7.0, 7.0, col)
			_disc(img, p.x, p.y, 4.0, 4.0, accent.darkened(0.22))

static func _bb_supply_depot(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(3):
		var y := c - 17.0 + float(k) * 17.0
		_round_rect(img, c - 25, y - 6.5, 50, 13, 4, col.darkened(0.10))
		_bevel(img, c - 25, y - 6.5, 50, 13, 0.22, 0.26)
		_rect(img, c - 23, y - 1.0, 46, 2.0, Color(0, 0, 0, 0.30))
	_disc(img, c - 15, c, 3.6, 3.6, accent.darkened(0.18))
	_disc(img, c + 15, c, 3.6, 3.6, accent.darkened(0.18))

static func _bb_barracks(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_round_rect(img, c - 27, c - 23, 54, 46, 5, col.darkened(0.12))
	_bevel(img, c - 27, c - 23, 54, 46, 0.24, 0.28)
	_grain(img, c - 27, c - 23, 54, 46, 0.05, 37)
	_frame(img, c - 27, c - 23, 54, 46, col, 2.6)
	_round_rect(img, c - 12, c - 21, 24, 17, 3, Color(0.11, 0.14, 0.19))
	for k in range(4):
		_rect(img, c - 11, c - 20.0 + float(k) * 4.2, 22, 2.2, Color(0.26, 0.30, 0.37))
	_disc(img, c, c + 13, 8.5, 6.5, Color(0.19, 0.25, 0.33))
	_ring(img, c, c + 13, 7.4, 1.8, accent.darkened(0.22))
	_line(img, Vector2(c - 4.5, c + 13), Vector2(c + 4.5, c + 13), accent, 2.2)
	_rect(img, c - 31, c - 9, 5, 20, col)
	_rect(img, c + 26, c - 9, 5, 20, col)

## 工程湾：人族的工业车间 —— 宽底座 + 龙门吊 + 齿轮。
## 它管攻防升级，造型上要「一看就在搞制造」，和兵营（纯方盒子）分开。
static func _bb_engineering_bay(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_round_rect(img, c - 29, c - 24, 58, 48, 5, col.darkened(0.16))
	_bevel(img, c - 29, c - 24, 58, 48, 0.24, 0.28)
	_grain(img, c - 29, c - 24, 58, 48, 0.05, 61)
	_frame(img, c - 29, c - 24, 58, 48, col, 2.4)
	# 龙门吊：横梁 + 两根立柱
	_rect(img, c - 25, c - 9, 50, 5.0, col.lightened(0.16))
	_rect(img, c - 25, c - 9, 4.4, 22, col.lightened(0.06))
	_rect(img, c + 20.6, c - 9, 4.4, 22, col.lightened(0.06))
	_rect(img, c - 1.6, c - 6, 3.2, 9.0, Color(0.24, 0.27, 0.33))
	_disc(img, c, c + 4.5, 3.4, 3.0, accent)
	# 齿轮：右下角
	var gx := c + 15.0
	var gy := c + 12.0
	_disc(img, gx, gy, 9.0, 9.0, dim.darkened(0.34))
	for k in range(8):
		var a := TAU * float(k) / 8.0
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(gx, gy) + d * 8.0, Vector2(gx, gy) + d * 11.6, dim.darkened(0.40), 3.0)
	_disc(img, gx, gy, 3.4, 3.4, Color(0.10, 0.13, 0.18))
	# 左侧通风口
	for k in range(3):
		_rect(img, c - 24, c + 8 + float(k) * 4.4, 14, 2.6, Color(0, 0, 0, 0.28))

static func _bb_factory(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_round_rect(img, c - 28, c - 23, 56, 46, 5, col.darkened(0.14))
	_bevel(img, c - 28, c - 23, 56, 46, 0.24, 0.28)
	_grain(img, c - 28, c - 23, 56, 46, 0.05, 43)
	_frame(img, c - 28, c - 23, 56, 46, col, 2.6)
	_disc(img, c, c + 2, 16.0, 16.0, Color(0.13, 0.16, 0.21))
	_ring(img, c, c + 2, 15.0, 2.8, col.lightened(0.12))
	_disc(img, c, c + 2, 8.5, 8.5, Color(0.24, 0.28, 0.35))
	_line(img, Vector2(c - 13, c + 2), Vector2(c + 13, c + 2), accent.darkened(0.18), 3.2)
	_line(img, Vector2(c, c - 11), Vector2(c, c + 15), accent.darkened(0.18), 3.2)
	for s: float in [-1.0, 1.0]:
		var p := Vector2(c + s * 21.0, c - 16.0)
		_disc(img, p.x, p.y, 6.0, 6.0, col.darkened(0.22))
		_disc(img, p.x, p.y, 3.4, 3.4, Color(0.09, 0.11, 0.15))

static func _bb_refinery(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_disc(img, c - 12, c, 14.0, 14.0, col.darkened(0.12))
	_disc(img, c + 12, c, 14.0, 14.0, col.darkened(0.12))
	_ring(img, c - 12, c, 13.4, 2.6, col)
	_ring(img, c + 12, c, 13.4, 2.6, col)
	_disc(img, c - 12, c, 6.5, 6.5, accent.darkened(0.28))
	_disc(img, c + 12, c, 6.5, 6.5, accent.darkened(0.28))
	_rect(img, c - 7, c - 3.5, 14, 7, Color(0.30, 0.34, 0.41))
	for k in range(2):
		var x := c - 4.5 + float(k) * 9.0
		_line(img, Vector2(x, c - 15.0), Vector2(x, c - 26.0), Color(0.55, 0.85, 0.62, 0.45), 2.6)

# ---------------------------------------------------------------- 虫族建筑特征

static func _bb_hive(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(8):
		var a := TAU * float(k) / 8.0 + 0.3
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 21.0, Vector2(c, c) + d * 35.0, col.darkened(0.12), 4.4)
		_disc(img, c + d.x * 35.0, c + d.y * 35.0, 3.6, 3.6, accent.darkened(0.36))
	_disc(img, c, c, 23.0, 22.0, col.darkened(0.26))
	_ring(img, c, c, 22.0, 3.2, col)
	_disc(img, c, c, 15.5, 14.5, Color(col.r * 0.55, col.g * 0.48, col.b * 0.60))
	_disc(img, c, c, 9.5, 9.0, Color(0.07, 0.045, 0.09))
	_ring(img, c, c, 6.4, 2.2, Color(accent.r, accent.g, accent.b, 0.58))
	for k in range(6):
		var a := TAU * float(k) / 6.0 + 0.5
		var p := Vector2(c, c) + Vector2(cos(a), sin(a)) * 26.0
		_disc(img, p.x, p.y, 4.8, 4.8, Color(0.62, 0.42, 0.72, 0.88))

static func _bb_spawning_pool(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(12):
		var a := TAU * float(k) / 12.0
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 23.0, Vector2(c, c) + d * 32.0, col.darkened(0.16), 3.6)
	_disc(img, c, c, 25.0, 21.0, col.darkened(0.28))
	_ring(img, c, c, 24.0, 3.2, col)
	_disc(img, c, c, 18.0, 15.0, Color(0.34, 0.16, 0.42))
	_disc(img, c, c, 12.5, 10.0, Color(0.54, 0.29, 0.64))
	for k in range(7):
		var a := TAU * float(k) / 7.0 + 0.9
		var rr := 5.0 + float((k * 37) % 9)
		var p := Vector2(c, c) + Vector2(cos(a), sin(a)) * rr
		_disc(img, p.x, p.y, 2.8, 2.4, Color(0.78, 0.60, 0.92, 0.78))

## 进化腔：虫族的变异腔体 —— 一圈骨刺围着一颗**立起来**的肉囊。
## 和孵化池（中间是液体池）刻意做区分：这里的中心是个有体积的球，不是坑。
static func _bb_evolution_chamber(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(10):
		var a := TAU * float(k) / 10.0 + 0.15
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 20.0, Vector2(c, c) + d * 33.0, col.darkened(0.18), 3.8)
		_disc(img, c + d.x * 33.0, c + d.y * 33.0, 2.6, 2.6, accent.darkened(0.34))
	_disc(img, c, c, 24.0, 20.0, col.darkened(0.30))
	_ring(img, c, c, 22.0, 3.0, col)
	# 中央肉囊：靠 bevel + 高光点出体积
	_disc(img, c, c - 2, 15.0, 14.0, col.darkened(0.06))
	_bevel(img, c - 15, c - 16, 30, 28, 0.30, 0.30)
	_disc(img, c, c - 4, 9.5, 9.0, Color(0.62, 0.30, 0.72))
	_disc(img, c - 3.5, c - 8, 4.2, 4.2, Color(0.92, 0.78, 1.0, 0.72))
	# 三条脉管
	for k in range(3):
		var a2 := TAU * float(k) / 3.0 + 0.6
		var d2 := Vector2(cos(a2), sin(a2))
		_line(img, Vector2(c, c) + d2 * 13.0, Vector2(c, c) + d2 * 22.0, accent.darkened(0.10), 4.2)

static func _bb_spire(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_poly(img, PackedVector2Array([
		Vector2(c - 13, c - 5), Vector2(c - 32, c - 16),
		Vector2(c - 30, c + 9), Vector2(c - 13, c + 11)]), Color(col.r, col.g, col.b, 0.74))
	_poly(img, PackedVector2Array([
		Vector2(c + 13, c - 5), Vector2(c + 32, c - 16),
		Vector2(c + 30, c + 9), Vector2(c + 13, c + 11)]), Color(col.r, col.g, col.b, 0.74))
	_line(img, Vector2(c - 13, c + 3), Vector2(c - 30, c + 3), col.darkened(0.28), 2.2)
	_line(img, Vector2(c + 13, c + 3), Vector2(c + 30, c + 3), col.darkened(0.28), 2.2)
	_poly(img, PackedVector2Array([
		Vector2(c, c - 33), Vector2(c + 14, c + 7),
		Vector2(c, c + 22), Vector2(c - 14, c + 7)]), col.darkened(0.12))
	_bevel(img, c - 14, c - 33, 28, 55, 0.26, 0.32)
	_grain(img, c - 14, c - 33, 28, 55, 0.06, 53)
	_poly(img, PackedVector2Array([
		Vector2(c, c - 35), Vector2(c + 6, c - 19),
		Vector2(c, c - 13), Vector2(c - 6, c - 19)]), accent.darkened(0.22))
	_disc(img, c, c - 28, 3.4, 3.4, accent)

static func _bb_extractor(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(4):
		var a := PI * 0.5 * float(k) + PI / 4.0
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 18.0, Vector2(c, c) + d * 33.0, Color(0.29, 0.25, 0.33), 5.0)
		_disc(img, c + d.x * 33.0, c + d.y * 33.0, 4.6, 4.6, col.darkened(0.12))
	_disc(img, c, c, 21.0, 21.0, col.darkened(0.24))
	_ring(img, c, c, 20.0, 3.2, col)
	_disc(img, c, c, 13.5, 13.5, Color(0.05, 0.13, 0.08))
	_disc(img, c, c, 8.5, 8.5, Color(0.13, 0.33, 0.19))
	for k in range(6):
		var a2 := TAU * float(k) / 6.0 + 0.4
		var p := Vector2(c, c) + Vector2(cos(a2), sin(a2)) * (5.0 + float((k * 29) % 7))
		_disc(img, p.x, p.y, 2.6, 2.6, Color(0.60, 0.95, 0.70, 0.72))

# ---------------------------------------------------------------- 神族建筑特征

static func _bb_nexus(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_disc(img, c, c, 28.0, 28.0, col.darkened(0.18))
	_ring(img, c, c, 27.4, 2.8, col)
	_disc(img, c, c, 22.0, 22.0, Color(0.15, 0.13, 0.085))
	_ring(img, c, c, 21.4, 2.2, Color(col.r, col.g, col.b, 0.55))
	for k in range(4):
		var a := PI * 0.5 * float(k) + PI / 4.0
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 15.0, Vector2(c, c) + d * 21.0,
			Color(accent.r, accent.g, accent.b, 0.62), 2.8)
	_disc(img, c, c, 14.0, 14.0, Color(0.28, 0.24, 0.13))
	_disc(img, c, c, 9.5, 9.5, accent.darkened(0.18))
	_disc(img, c - 1.5, c - 1.5, 5.2, 5.2, Color(1.0, 0.96, 0.78, 0.96))
	for k in range(4):
		var a2 := PI * 0.5 * float(k) + PI / 4.0
		var p := Vector2(c, c) + Vector2(cos(a2), sin(a2)) * 24.0
		_disc(img, p.x, p.y, 5.8, 5.8, col.lightened(0.12))
		_disc(img, p.x, p.y, 3.2, 3.2, accent)

static func _bb_pylon(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(3):
		var a := -PI * 0.5 + TAU * float(k) / 3.0
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c), Vector2(c, c) + d * 32.0, col.darkened(0.22), 5.0)
		_disc(img, c + d.x * 32.0, c + d.y * 32.0, 4.4, 4.4, col)
	_disc(img, c, c - 3, 20.0, 20.0, Color(0.30, 0.70, 0.95, 0.20))
	_poly(img, PackedVector2Array([
		Vector2(c, c - 22), Vector2(c + 10, c - 4),
		Vector2(c, c + 16), Vector2(c - 10, c - 4)]), Color(0.20, 0.55, 0.85))
	_poly(img, PackedVector2Array([
		Vector2(c, c - 22), Vector2(c + 10, c - 4), Vector2(c, c + 16)]), Color(0.42, 0.82, 1.0))
	_ring(img, c, c - 3, 19.0, 1.8, Color(0.62, 0.90, 1.0, 0.60))
	_disc(img, c, c - 3, 6.5, 6.5, Color(0.75, 0.95, 1.0, 0.55))
	_disc(img, c, c - 3, 3.2, 3.2, Color(1, 1, 1, 0.92))

static func _bb_gateway(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	_round_rect(img, c - 31, c - 27, 13, 54, 4, col.darkened(0.20))
	_round_rect(img, c + 18, c - 27, 13, 54, 4, col.darkened(0.20))
	_bevel(img, c - 31, c - 27, 13, 54, 0.26, 0.30)
	_bevel(img, c + 18, c - 27, 13, 54, 0.26, 0.30)
	_disc(img, c - 24.5, c - 20, 3.8, 3.8, accent)
	_disc(img, c + 24.5, c - 20, 3.8, 3.8, accent)
	_disc(img, c, c, 18.0, 23.0, Color(0.09, 0.15, 0.23))
	_ellipse(img, c, c, 0.0, 0.0, 17.0, 22.0, Color(0.28, 0.60, 0.94, 0.34))
	_ellipse(img, c, c, 12.5, 17.0, 16.0, 21.0, Color(0.48, 0.80, 1.0, 0.58))
	_disc(img, c, c, 7.5, 9.5, Color(0.75, 0.92, 1.0, 0.62))
	_round_rect(img, c - 23, c - 27, 46, 9, 3, col)
	_bevel(img, c - 23, c - 27, 46, 9, 0.24, 0.28)

static func _bb_cybernetics_core(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(4):
		var a := PI * 0.5 * float(k) + PI / 4.0
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 20.0, Vector2(c, c) + d * 31.0, col.darkened(0.24), 4.4)
	_ring(img, c, c, 25.0, 2.4, Color(col.r, col.g, col.b, 0.62))
	for k in range(4):
		var a2 := PI * 0.5 * float(k) + 0.4
		var p := Vector2(c, c) + Vector2(cos(a2), sin(a2)) * 25.0
		_disc(img, p.x, p.y, 3.0, 3.0, accent)
	_disc(img, c, c, 21.0, 21.0, col.darkened(0.22))
	_ring(img, c, c, 20.4, 2.8, col)
	_disc(img, c, c, 14.5, 14.5, Color(0.13, 0.16, 0.23))
	_disc(img, c, c, 10.0, 10.0, Color(0.26, 0.53, 0.80))
	_disc(img, c - 2.5, c - 2.5, 4.8, 4.8, Color(0.70, 0.92, 1.0, 0.88))

## 熔炉：神族的锻造台 —— 八边形底座 + 中央铁砧 + 一圈悬浮锤头。
## 炉火用橙色，是全场唯一一个暖色核心的神族建筑，扫一眼就能认出来。
static func _bb_forge(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	var oct := PackedVector2Array()
	for k in range(8):
		var a := TAU * float(k) / 8.0 + PI / 8.0
		var d := Vector2(cos(a), sin(a))
		oct.append(Vector2(c, c) + d * 30.0)
	_poly(img, oct, col.darkened(0.20))
	_ring(img, c, c, 28.0, 3.0, col)
	# 铁砧：俯视下是一个「工」字
	_round_rect(img, c - 13, c - 6, 26, 13, 2.5, col.lightened(0.10))
	_rect(img, c - 7, c - 14, 14, 9, col.lightened(0.04))
	_rect(img, c - 4, c + 6, 8, 7, col.darkened(0.06))
	_bevel(img, c - 13, c - 6, 26, 13, 0.28, 0.30)
	# 炉火
	_disc(img, c, c + 0.5, 6.0, 4.6, Color(0.98, 0.62, 0.18))
	_disc(img, c, c + 0.5, 3.4, 2.6, Color(1.0, 0.88, 0.55))
	# 四角锤头
	for k in range(4):
		var a2 := PI * 0.5 * float(k) + PI / 4.0
		var d2 := Vector2(cos(a2), sin(a2))
		_disc(img, c + d2.x * 25.0, c + d2.y * 23.0, 4.4, 4.0, dim.darkened(0.40))
		_disc(img, c + d2.x * 25.0, c + d2.y * 23.0, 2.2, 2.0, accent)

static func _bb_templar_archives(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for s: float in [-1.0, 1.0]:
		var px := c + s * 27.0
		_round_rect(img, px - 9.0, c - 17.0, 18, 38, 4, col.darkened(0.24))
		_bevel(img, px - 9.0, c - 17.0, 18, 38, 0.26, 0.30)
		_line(img, Vector2(px, c - 11.0), Vector2(px, c + 13.0),
			Color(accent.r, accent.g, accent.b, 0.62), 2.4)
	_round_rect(img, c - 21, c + 17, 42, 11, 3, col)
	_bevel(img, c - 21, c + 17, 42, 11, 0.22, 0.28)
	_poly(img, PackedVector2Array([
		Vector2(c, c - 32), Vector2(c + 12, c - 6),
		Vector2(c, c + 21), Vector2(c - 12, c - 6)]), col.darkened(0.16))
	_bevel(img, c - 12, c - 32, 24, 53, 0.26, 0.32)
	_grain(img, c - 12, c - 32, 24, 53, 0.05, 67)
	_poly(img, PackedVector2Array([
		Vector2(c, c - 24), Vector2(c + 6, c - 11),
		Vector2(c, c + 3), Vector2(c - 6, c - 11)]), accent)
	_disc(img, c, c - 11, 3.6, 3.6, Color(1, 1, 1, 0.86))

static func _bb_assimilator(img: Image, c: float, col: Color, dim: Color, accent: Color) -> void:
	for k in range(4):
		var a := PI * 0.5 * float(k)
		var d := Vector2(cos(a), sin(a))
		_line(img, Vector2(c, c) + d * 20.0, Vector2(c, c) + d * 33.0, col.darkened(0.26), 4.8)
		_disc(img, c + d.x * 33.0, c + d.y * 33.0, 4.2, 4.2, accent.darkened(0.22))
	_ring(img, c, c, 25.0, 1.8, Color(col.r, col.g, col.b, 0.50))
	_disc(img, c, c, 22.0, 22.0, col.darkened(0.20))
	_ring(img, c, c, 21.4, 3.2, col)
	_disc(img, c, c, 14.5, 14.5, Color(0.09, 0.17, 0.13))
	_disc(img, c, c, 9.5, 9.5, Color(0.21, 0.51, 0.31))
	_disc(img, c - 2.0, c - 2.0, 4.6, 4.6, Color(0.70, 1.0, 0.80, 0.82))

# ================================================================ 外部素材（皮肤）

## 外部素材目录。把 PNG 放进这里就能覆盖程序化贴图，不需要改任何一行代码。
##
## 命名规则（全部小写）：
##   地形   ground.png  ground_patch.png  rock.png  mineral.png  gas.png
##   单位   u_<单位id>.png   例：u_marine.png、u_zergling.png
##   建筑   b_<建筑id>.png   例：b_command_center.png、b_nexus.png
##
## 没放的文件会自动回退到程序化贴图 —— 放几张就换几张。
## 这是任何支持 mod 的游戏都会做的事：把「表现」和「逻辑」解耦。
const SKIN_DIR := "user://skins"

## 建立素材目录并写入说明文件，返回可读的绝对路径（方便用户找到它）。
##
## ⚠️⚠️ **`DirAccess.open("user://…")` 在本引擎下恒定返回 `null`** ——
##   必须 `globalize_path()` 之后再 open。见 `Mods.open_dir()` 的完整说明。
##
##   这里**踩过**，而且是玩家可见的：`d` 恒为 null ⇒ `skins` 子目录
##   **从来没有被创建过**（实测 `user://skins/` 不存在），
##   而本函数照样返回一个路径、README 里还写着「把 PNG 放进这个文件夹」——
##   那个文件夹根本不存在，放进去也没用。**全程不报错。**
static func ensure_skin_dir() -> String:
	var d := DirAccess.open(ProjectSettings.globalize_path("user://"))
	if d != null and not d.dir_exists("skins"):
		d.make_dir("skins")
	var abs_path := ProjectSettings.globalize_path(SKIN_DIR)
	if not FileAccess.file_exists(SKIN_DIR + "/README.txt"):
		var f := FileAccess.open(SKIN_DIR + "/README.txt", FileAccess.WRITE)
		if f != null:
			f.store_string(_skin_readme())
			f.close()
	return abs_path

static func _skin_readme() -> String:
	return """星海战火 · 外部素材目录
================================

把 PNG 文件放进这个文件夹，游戏启动时会自动用它覆盖内置贴图。
没有对应文件的项目会回退到内置贴图 —— 放几张就换几张。

注意：游戏本身已经自带一套皮肤（assets/art/skins/，源自 Kenney 的
CC0 素材）。本目录里的同名文件会覆盖它，所以想改哪个就放哪个。

命名规则（全部小写）
--------------------
地形   ground.png   ground_patch.png   rock.png
资源   mineral.png  gas.png
单位   u_<单位id>.png
建筑   b_<建筑id>.png

单位 id
  人族 : scv  marine  marauder  siege_tank  vulture
  虫族 : drone  zergling  hydralisk  roach  mutalisk
  神族 : probe  zealot  dragoon  archon

建筑 id
  人族 : command_center  supply_depot  barracks  factory  refinery
  虫族 : hive  spawning_pool  spire  extractor
  神族 : nexus  pylon  gateway  cybernetics_core  templar_archives  assimilator

贴图约定
--------
- 正方形 PNG，带透明通道。建议 64x64（单位）/ 96x96（建筑）。
- 透明边会被自动裁掉，内容会等比缩放填满画面，
  所以不必自己对齐 —— 但要保证四周没有多余的杂色像素，
  否则会被算进包围盒、把主体缩小。
- 任意尺寸都行，运行时会按最长边等比缩放到单位 / 建筑的视觉尺寸。
- 贴图默认「正立」，运行时只按朝向左右翻转（经典 2D RTS 的做法，
  侧视精灵图必须这样，否则坦克朝上开时会立起来）。
  如果你的素材是真正的俯视图、希望跟着朝向旋转，把 Main.gd 里的
  SKIN_ORIENTATION 改成 "rotate"；旋转模式下的朝向基准由
  SKIN_FACING_OFFSET 调整（本项目程序化贴图约定「正前方 = 上方」，
  所以内置贴图用 0；若素材是「正前方 = 右方」，用 -PI/2）。

提示
----
只放自己有权使用的素材。
"""

## 是否启用**随项目打包**的那套皮肤（res://assets/art/skins/，Kenney CC0 烘焙而来）。
##
## 关掉它 → 全套美术回到「纯程序化自绘」：
##   1. 风格统一：阵营底盘 + 俯视剪影 + 深色描边，更贴近星际重制版那种卡通感；
##   2. 回到项目「自研引擎 + 全程序化美术 + 零外部素材」的合规策略，
##      仓库与 APK 里不再有任何第三方图片。
## 打开它 → 老单位/建筑会换成 Kenney 图标，和自绘的新建筑（导弹塔 / 光子炮台 /
##   星际之门…）风格直接打架 —— 一局里会同时出现「小蓝盒子」和「有造型的塔」。
##
## ⚠️ 这个开关**只管打包进来的那一套**。
##    `user://skins/` 里的同名 PNG 永远优先 —— 那是留给「玩家自己换皮」的口子，
##    不受这里影响（见 ensure_skin_dir() 生成的 README）。
const USE_BUNDLED_SKINS := false

## 模组皮肤覆盖表：`名字 -> user://mods/<id>/skins/<file>.png`，由 `Mods.reload()` 填。
##
## **优先于 `user://skins/`**：模组是「玩家显式启用的整套皮肤」，
## 比散放在 skins/ 里的单张图更明确 —— 玩家关掉模组就该回到默认外观，
## 而不是被 skins/ 里的残留盖住。
static var skin_overrides: Dictionary = {}

## 读取外部素材。没有可用文件时返回 null，调用方回退到程序化贴图。
##
## 查找顺序：
##   0. 模组皮肤表（M3）                   —— 玩家在模组页显式启用的
##   1. res://assets/art/skins/<name>.png  —— 项目内置素材（受 USE_BUNDLED_SKINS 控制）
##   2. user://skins/<name>.png            —— 用户自备素材，可覆盖内置
##
## 内置素材走 ResourceLoader（编辑器里读原文件、导出后读 .import 结果，
## 两边都能用）；用户素材走 Image.load_from_file（因为 user:// 不参与导入）。
static func load_skin(name: String) -> Texture2D:
	if skin_overrides.has(name):
		var mp := String(skin_overrides[name])
		var mt := _load_png(mp)
		if mt != null:
			return mt
		push_warning("[Skin] 模组皮肤读取失败，已回退：" + mp)
	if USE_BUNDLED_SKINS:
		var res_path := "res://assets/art/skins/" + name + ".png"
		if ResourceLoader.exists(res_path):
			var t := load(res_path)
			if t is Texture2D:
				return t
	var p := SKIN_DIR + "/" + name + ".png"
	if not FileAccess.file_exists(p):
		return null
	var img := Image.load_from_file(p)
	if img == null:
		push_warning("[Skin] 读取失败，已回退到内置贴图：" + p)
		return null
	return ImageTexture.create_from_image(img)

## 从任意路径读一张 PNG。`user://` 不参与导入，只能走 `Image.load_from_file`。
static func _load_png(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

# ================================================================ 工具

static func _in_poly(p: Vector2, poly: PackedVector2Array, scale: float = 1.0) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	var c := Vector2.ZERO
	for v in poly:
		c += v
	c /= float(n)
	var inside := false
	var j := n - 1
	for i in range(n):
		var a := c + (poly[i] - c) * scale
		var b := c + (poly[j] - c) * scale
		if ((a.y > p.y) != (b.y > p.y)) and (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x):
			inside = not inside
		j = i
	return inside

static func _hash2(x: int, y: int) -> float:
	var n := x * 374761393 + y * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(absi(n) % 10000) / 10000.0
