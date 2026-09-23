extends RefCounted
class_name GenSfx

## 程序化音效：全部用代码合成 PCM，零外部音频文件。
##
## 与美术走同一条路线 —— 不引入任何第三方素材，也就不存在授权问题。
## 每个音效在首次取用时合成一次并缓存（和贴图一个套路）。
##
## 采样规格：22050 Hz / 16bit / 单声道。短促的效果音够用，
## 数据量小（1 秒 ≈ 44 KB），生成也快。
##
## 音色设计原则：
##   · 所有波形都带指数衰减包络（`exp(-t * decay)`），否则尾音会「啪」地截断
##   · 低频冲击用正弦，电子感用方波，机械感用三角波，爆炸用低通白噪声
##   · 每个音效尾部留 10ms 淡出，避免 DC 突变造成爆音

const RATE := 22050

static var _cache := {}

## 取一个音效（带缓存）。可用名字见下方 _make()。
static func get_sfx(name: String) -> AudioStreamWAV:
	if _cache.has(name):
		return _cache[name]
	var st := _make(name)
	_cache[name] = st
	return st

## 预热：开局时把所有音效合成一遍，避免首次播放时卡一下
static func prewarm() -> void:
	for n in ["ui_click", "ui_error", "ui_open", "build_start", "build_done",
			"train_done", "shot_bullet", "shot_cannon", "shot_laser", "shot_acid",
			"shot_psionic", "melee_hit", "explosion", "unit_death", "unit_ack",
			"place_ok", "place_bad", "victory", "defeat",
			"stim", "siege_deploy", "heal", "research_done"]:
		get_sfx(n)

# ---------------------------------------------------------------- 合成原语

static func _buf(sec: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(maxi(1, int(RATE * sec)))
	a.fill(0.0)
	return a

## 振荡器：频率从 f0 线性扫到 f1，指数衰减包络。
## shape: "sine" | "square" | "saw" | "tri"
static func _tone(a: PackedFloat32Array, f0: float, f1: float, start: float,
		dur: float, vol: float, decay: float, shape: String = "sine") -> void:
	var i0 := int(start * RATE)
	var n := int(dur * RATE)
	var ph := 0.0
	for i in range(n):
		var idx := i0 + i
		if idx >= a.size():
			break
		var t := float(i) / float(RATE)
		var u := float(i) / maxf(1.0, float(n))
		ph = fmod(ph + lerpf(f0, f1, u) / float(RATE), 1.0)
		var v := 0.0
		match shape:
			"square":
				v = 1.0 if ph < 0.5 else -1.0
			"saw":
				v = ph * 2.0 - 1.0
			"tri":
				v = 1.0 - 4.0 * absf(ph - 0.5)
			_:
				v = sin(ph * TAU)
		a[idx] += v * vol * exp(-t * decay)

## 白噪声，可选单极点低通（cut 越小越闷）
static func _noise(a: PackedFloat32Array, start: float, dur: float,
		vol: float, decay: float, cut: float = 1.0) -> void:
	var i0 := int(start * RATE)
	var n := int(dur * RATE)
	var y := 0.0
	var k := clampf(cut, 0.001, 1.0)
	for i in range(n):
		var idx := i0 + i
		if idx >= a.size():
			break
		var t := float(i) / float(RATE)
		var w := randf() * 2.0 - 1.0
		y += k * (w - y)
		a[idx] += y * vol * exp(-t * decay)

## 尾部淡出：最后 fade 秒线性压到 0，消除截断爆音
static func _fade_tail(a: PackedFloat32Array, fade: float = 0.01) -> void:
	var n := mini(a.size(), int(fade * RATE))
	for i in range(n):
		var idx := a.size() - n + i
		a[idx] *= 1.0 - float(i) / float(n)

static func _to_wav(a: PackedFloat32Array) -> AudioStreamWAV:
	_fade_tail(a)
	var n := a.size()
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var s := int(round(clampf(a[i], -1.0, 1.0) * 31000.0))
		if s < 0:
			s += 65536
		data[i * 2] = s & 0xFF
		data[i * 2 + 1] = (s >> 8) & 0xFF
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = RATE
	st.stereo = false
	st.data = data
	return st

# ---------------------------------------------------------------- 音效表

static func _make(name: String) -> AudioStreamWAV:
	var a: PackedFloat32Array
	match name:
		# ---- 界面 ----
		"ui_click":                       # 短促电子哔，确认感
			a = _buf(0.07)
			_tone(a, 900.0, 900.0, 0.0, 0.07, 0.30, 46.0, "square")
		"ui_open":                        # 面板展开，上行
			a = _buf(0.15)
			_tone(a, 520.0, 940.0, 0.0, 0.15, 0.24, 17.0, "tri")
		"ui_error":                       # 拒绝，下行
			a = _buf(0.22)
			_tone(a, 340.0, 165.0, 0.0, 0.22, 0.28, 9.0, "square")
		"place_ok":                       # 落位成功
			a = _buf(0.17)
			_tone(a, 620.0, 1080.0, 0.0, 0.17, 0.26, 13.0, "tri")
		"place_bad":                      # 位置非法
			a = _buf(0.24)
			_tone(a, 420.0, 150.0, 0.0, 0.24, 0.26, 8.0, "square")

		# ---- 建造 / 生产 ----
		"build_start":
			a = _buf(0.34)
			_tone(a, 180.0, 360.0, 0.0, 0.34, 0.24, 7.0, "tri")
			_noise(a, 0.0, 0.16, 0.10, 10.0, 0.35)
		"build_done":                     # 上行三音，完工的正反馈
			a = _buf(0.48)
			_tone(a, 440.0, 440.0, 0.00, 0.13, 0.24, 8.0, "tri")
			_tone(a, 660.0, 660.0, 0.14, 0.13, 0.24, 8.0, "tri")
			_tone(a, 880.0, 880.0, 0.28, 0.18, 0.26, 6.0, "tri")
		"train_done":                     # 出产，两音
			a = _buf(0.28)
			_tone(a, 700.0, 700.0, 0.00, 0.11, 0.24, 13.0, "tri")
			_tone(a, 1050.0, 1050.0, 0.12, 0.14, 0.24, 11.0, "tri")

		# ---- 武器 ----
		"shot_bullet":                    # 实弹：脆、短
			a = _buf(0.07)
			_noise(a, 0.0, 0.07, 0.30, 62.0, 0.85)
			_tone(a, 1100.0, 700.0, 0.0, 0.05, 0.10, 52.0, "square")
		"shot_cannon":                    # 炮：低频冲击 + 噪声
			a = _buf(0.28)
			_tone(a, 115.0, 48.0, 0.0, 0.28, 0.40, 11.0, "sine")
			_noise(a, 0.0, 0.20, 0.22, 15.0, 0.30)
		"shot_laser":                     # 能量：扫频正弦
			a = _buf(0.17)
			_tone(a, 1500.0, 320.0, 0.0, 0.17, 0.24, 13.0, "sine")
			_tone(a, 750.0, 160.0, 0.0, 0.17, 0.08, 13.0, "square")
		"shot_acid":
			a = _buf(0.21)
			_noise(a, 0.0, 0.21, 0.24, 13.0, 0.22)
			_tone(a, 220.0, 120.0, 0.0, 0.21, 0.20, 11.0, "sine")
		"shot_psionic":                   # 幽能：上行三角，空灵感
			a = _buf(0.22)
			_tone(a, 900.0, 1650.0, 0.0, 0.22, 0.22, 11.0, "tri")
			_tone(a, 450.0, 820.0, 0.0, 0.22, 0.10, 11.0, "sine")
		"melee_hit":                      # 近战命中
			a = _buf(0.10)
			_noise(a, 0.0, 0.10, 0.26, 42.0, 0.55)
			_tone(a, 380.0, 190.0, 0.0, 0.09, 0.16, 34.0, "square")

		# ---- 命中 / 死亡 ----
		"hit":                            # 普通命中，很轻（会被限流）
			a = _buf(0.06)
			_noise(a, 0.0, 0.06, 0.18, 55.0, 0.60)
		"explosion":
			a = _buf(0.62)
			_noise(a, 0.0, 0.62, 0.42, 6.0, 0.16)
			_tone(a, 72.0, 34.0, 0.0, 0.55, 0.30, 5.0, "sine")
		"unit_death":
			a = _buf(0.40)
			_tone(a, 430.0, 105.0, 0.0, 0.40, 0.24, 8.0, "saw")
			_noise(a, 0.0, 0.18, 0.12, 18.0, 0.35)

		# ---- 单位应答 ----
		"unit_ack":                       # 选中/下令时的一声「哔」，两段更像通讯
			a = _buf(0.16)
			_tone(a, 1250.0, 1250.0, 0.00, 0.05, 0.18, 24.0, "square")
			_tone(a, 1600.0, 1600.0, 0.07, 0.06, 0.18, 22.0, "square")

		# ---- 技能 ----
		"stim":                           # 兴奋剂：先吸气后上扬，带一点噪声的「注射感」
			a = _buf(0.30)
			_noise(a, 0.00, 0.10, 0.16, 30.0, 0.30)
			_tone(a, 620.0, 1180.0, 0.06, 0.24, 0.22, 12.0, "square")
		"siege_deploy":                   # 攻城模式：液压伺服，低频机械感
			a = _buf(0.46)
			_noise(a, 0.00, 0.46, 0.22, 5.0, 0.22)
			_tone(a, 150.0, 62.0, 0.00, 0.42, 0.20, 7.0, "saw")
			_tone(a, 900.0, 900.0, 0.40, 0.06, 0.14, 30.0, "square")
		"heal":                           # 治疗：柔和正弦，不带噪声
			a = _buf(0.26)
			_tone(a, 880.0, 1320.0, 0.00, 0.24, 0.20, 11.0, "sine")
		"research_done":                  # 研究完成：三音上行，比胜利音短促、更「仪器」
			a = _buf(0.42)
			_tone(a, 784.0, 784.0, 0.00, 0.11, 0.20, 14.0, "square")
			_tone(a, 1047.0, 1047.0, 0.12, 0.11, 0.20, 14.0, "square")
			_tone(a, 1319.0, 1319.0, 0.24, 0.17, 0.22, 10.0, "square")

		# ---- 胜负 ----
		"victory":
			a = _buf(0.76)
			_tone(a, 523.0, 523.0, 0.00, 0.16, 0.24, 5.0, "tri")
			_tone(a, 659.0, 659.0, 0.17, 0.16, 0.24, 5.0, "tri")
			_tone(a, 784.0, 784.0, 0.34, 0.16, 0.24, 5.0, "tri")
			_tone(a, 1047.0, 1047.0, 0.51, 0.25, 0.26, 4.0, "tri")
		"defeat":
			a = _buf(0.88)
			_tone(a, 523.0, 523.0, 0.00, 0.19, 0.24, 4.0, "tri")
			_tone(a, 415.0, 415.0, 0.20, 0.19, 0.24, 4.0, "tri")
			_tone(a, 330.0, 330.0, 0.40, 0.19, 0.24, 4.0, "tri")
			_tone(a, 247.0, 247.0, 0.60, 0.28, 0.26, 3.0, "tri")

		_:                                # 未知名：给个极短的静音，不至于崩
			a = _buf(0.02)
	return _to_wav(a)
