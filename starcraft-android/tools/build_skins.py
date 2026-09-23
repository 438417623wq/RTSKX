"""把 Kenney「Sci-fi RTS」(CC0) 素材烘焙成本项目的皮肤。

做四件事：
  1. 按映射表把 Kenney 的通用编号挑成本游戏的单位/建筑
  2. 归一化尺寸（裁掉透明边、等比缩放居中），让贴图尺寸与游戏逻辑无关
  3. 按阵营色重着色 —— Kenney 是固定配色，重着色后三族才有明确的阵营识别度
  4. 卡通化 —— 描边 + 高饱和 + 平涂 + 内结构线

输出到 assets/art/skins/，命名遵循 GenTex 的皮肤约定：
    u_<unit_id>.png   b_<building_id>.png   mineral.png   gas.png

素材源：tools/kenney_rts/PNG/Default size（已固化进仓库，不依赖系统临时目录）

用法：
    python tools/build_skins.py
"""

import os
import colorsys
from PIL import Image, ImageDraw, ImageFont

_HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(_HERE)
# 优先用项目内固化的素材副本；找不到再退回系统临时目录（老环境）
_LOCAL_SRC = os.path.join(_HERE, "kenney_rts", "PNG", "Default size")
_TMP_SRC = "C:/Users/XiaoXin/AppData/Local/Temp/kenney_rts/PNG/Default size"
SRC = _LOCAL_SRC if os.path.isdir(_LOCAL_SRC) else _TMP_SRC
DST = os.path.join(PROJ, "assets", "art", "skins")
SHOTS = os.path.join(PROJ, "shots")

SIZE = 64          # 输出贴图边长
FILL = 0.96        # 内容占满比例

# 阵营色（与 GameData.FACTIONS 保持一致）
FACTION_HUE = {
    "terran": 210.6,   # #4a90d9
    "zerg": 282.6,     # #9b59b6
    "protoss": 45.9,   # #d4af37
}
# 灰色（金属）部分往阵营色染色的强度。
# Kenney 的建筑几乎全是高明度灰，不重染就完全看不出阵营（三族建筑会长得一模一样）。
# 但也不能过头 —— 高明度灰 + 高饱和 = 粉彩玩具色，那就俗了。
GREY_TINT_UNIT = 0.44
GREY_TINT_BUILD = 0.64
GREY_SAT = 0.48        # 染色时使用的饱和度
GREY_CUT = 0.13        # 低于此饱和度视为「灰」

# 彩色像素的饱和度下限。Kenney 的配色偏灰（大量 20~40% 饱和度的区域），
# 只换色相的话重着色完还是灰扑扑的，卡通感起不来。
# 抬到 0.42 再交给 cartoonize() 的 sat_boost，阵营色才会「正」。
SAT_FLOOR_UNIT = 0.42
SAT_FLOOR_BUILD = 0.38

# ---------------------------------------------------------------- 映射表
# 单位：id -> (Kenney 编号, 阵营)
UNIT_MAP = {
    # 人族（蓝军 01-12）：方正机械
    "scv":        (1,  "terran"),   # 小型双足工程机
    "marine":     (2,  "terran"),   # 标准步兵
    "marauder":   (4,  "terran"),   # 重甲步兵
    "siege_tank": (9,  "terran"),   # 带炮管履带车
    "vulture":    (11, "terran"),   # 三轮快速载具
    "medic":      (3,  "terran"),   # 背药箱的步兵（与陆战队员轮廓可区分）
    "medic":      (3,  "terran"),   # 背装备箱的士兵（和 #02 步兵有区分度）
    # 虫族（绿军 25-36）：紧凑、低矮
    "drone":      (29, "zerg"),     # 小型采集体
    "zergling":   (26, "zerg"),     # 最小型近战
    "hydralisk":  (28, "zerg"),     # 中型远程
    "roach":      (27, "zerg"),     # 四足重甲
    "mutalisk":   (35, "zerg"),     # 紧凑飞行体
    # 神族（橙军 13-24）：对称、金饰
    "probe":      (13, "protoss"),  # 小型机械体
    "zealot":     (14, "protoss"),  # 重甲近战
    "dragoon":    (23, "protoss"),  # 四足行走机甲
    "archon":     (16, "protoss"),  # 能量体
}

# 建筑：id -> (Kenney 编号, 阵营)
BUILDING_MAP = {
    "command_center":  (1,  "terran"),   # 多窗大型主基地
    "supply_depot":    (11, "terran"),   # 方形储物箱
    "barracks":        (5,  "terran"),   # 带旗帜的营房
    "factory":         (6,  "terran"),   # 带台阶的厂房
    "refinery":        (8,  "terran"),   # 双气罐（天然气厂）
    "engineering_bay": (11, "terran"),   # 带面板的工坊（科技升级前置）
    "hive":            (2,  "zerg"),     # 圆顶巢穴
    "spawning_pool":   (14, "zerg"),     # 圆形池
    "spire":           (9,  "zerg"),     # 高塔尖刺
    "extractor":       (16, "zerg"),     # 机械提取装置
    "evolution_chamber": (15, "zerg"),   # 拱顶建筑（科技升级前置）
    "nexus":           (7,  "protoss"),  # 穹顶神殿
    "pylon":           (13, "protoss"),  # 带天线的小型能量节点
    "gateway":         (15, "protoss"),  # 带门洞的传送门
    "cybernetics_core":(4,  "protoss"),  # 立柱科技楼
    "templar_archives":(3,  "protoss"),  # 带饰板的档案馆
    "assimilator":     (12, "protoss"),  # 方形采集器
    "forge":           (10, "protoss"),  # 带竖管的结构（科技升级前置）
    # ---- 第七轮新增（升级前置建筑）----
    # 选型说明：#11 带面板的厂房 → 工程湾；#15 圆顶小楼 → 进化腔（重着色成紫色很「虫族」）；
    # #14 基座圆盘 → 熔炉（金色像祭坛）。#14 与虫族孵化池同形状，但阵营色不同、
    # 且两族不会在同一局出现，不会混淆。#10 是细管状，太弱，不用。
    "engineering_bay":   (11, "terran"),
    "evolution_chamber": (15, "zerg"),
    "forge":             (14, "protoss"),
}

# 资源：输出名 -> (Environment 编号, 目标色)
# 11 = 小型晶柱、12 = 高晶柱 —— 这两张才是「矿」该有的形状；
# 15/16 是圆钝的块状物，缩放后像水母，不要用。
RES_MAP = {
    "mineral": (12, (0x59, 0xC8, 0xFF)),   # 蓝色高晶柱
    "gas":     (11, (0x7D, 0xE0, 0x8A)),   # 绿色气泉晶簇
}


# ---------------------------------------------------------------- 图像处理
def fit(img, size=SIZE, fill=FILL):
    """裁掉透明边，等比缩放到内容占满 fill，居中放进正方形画布。"""
    bbox = img.getchannel("A").getbbox()
    if bbox is None:
        return Image.new("RGBA", (size, size), (0, 0, 0, 0))
    crop = img.crop(bbox)
    w, h = crop.size
    target = size * fill
    sc = target / float(max(w, h))
    nw = max(1, int(round(w * sc)))
    nh = max(1, int(round(h * sc)))
    resized = crop.resize((nw, nh), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(resized, ((size - nw) // 2, (size - nh) // 2), resized)
    return out


def recolor(img, hue_deg, grey_w, sat_floor=SAT_FLOOR_UNIT):
    """把贴图整体归到指定色相。

    彩色像素：保留原有明度、换色相，并把饱和度抬到 sat_floor 以上 ——
              只换色相的话，原图里偏灰的区域重着色后还是灰的，阵营色出不来。
    灰色像素（金属底盘）：保持明度，按 grey_w 往阵营色上染。
    两者结合就是经典的「阵营色」做法：金属结构染上阵营色，同时保留体积感。
    """
    H = hue_deg / 360.0
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            hh, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            if s < GREY_CUT:
                tr, tg, tb = colorsys.hsv_to_rgb(H, GREY_SAT, v)
                tr *= 255.0
                tg *= 255.0
                tb *= 255.0
                nr = r + (tr - r) * grey_w
                ng = g + (tg - g) * grey_w
                nb = b + (tb - b) * grey_w
            else:
                nr, ng, nb = colorsys.hsv_to_rgb(H, max(s, sat_floor), v)
                nr *= 255.0
                ng *= 255.0
                nb *= 255.0
            px[x, y] = (int(round(nr)), int(round(ng)), int(round(nb)), a)
    return img


def force_color(img, rgb):
    """把素材整体压到某个具体颜色上（用于资源晶簇）。"""
    H, S, _ = colorsys.rgb_to_hsv(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            hh, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            if s < GREY_CUT:
                nr, ng, nb = colorsys.hsv_to_rgb(H, 0.30, v)
            else:
                nr, ng, nb = colorsys.hsv_to_rgb(H, max(0.45, min(1.0, s * 1.15)), v)
            px[x, y] = (int(round(nr * 255)), int(round(ng * 255)), int(round(nb * 255)), a)
    return img


def cartoonize(img, hue_deg, outline_w=3, levels=7, sat_boost=1.30,
               contrast=1.16, lift=-0.01, inner=0.30, inner_thr=0.115,
               outline_sat=0.42, outline_val=0.14):
    """把重着色后的贴图推向卡通风格。

    卡通感来自四件事，按视觉重要性排序：

      1. **外描边** —— 最强的卡通线索。没有描边，再高的饱和度也只像写实贴图。
         做法是 alpha 形态学膨胀，膨胀环减去原实心区就是描边带。
         描边色不是纯黑，而是「阵营色压暗」——纯黑描边会很硬，带色相的暗线才耐看。
      2. **高饱和** —— 卡通用色比写实更纯。
      3. **平涂** —— 明度量化成有限级数（levels），消除柔和渐变，产生「色块」感。
         只量化明度、保留色相和饱和度，这样明暗关系变成台阶而颜色不失真。
      4. **内描边** —— 用明度梯度画结构线，产生「线稿」感。

    ⚠️ 内描边必须先对明度做 3x3 平滑再求梯度。
    Kenney 源图带颗粒噪点，直接求梯度会把噪点全判成结构线，画出来是一片脏斑。

    描边宽度按用途区分：单位 3px、建筑 2px。
    单位在游戏里只有 21~37 屏幕像素（`sc = r*3.1/64`），描边细了就完全看不见；
    建筑显示得大，同样的宽度会显得像贴了一圈黑边。
    """
    w, h = img.size
    px = img.load()

    # ---- 2/3. 提饱和 + 提对比 + 明度量化
    lum = [[0.0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            hh, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            s = min(1.0, s * sat_boost)
            v = (v - 0.5) * contrast + 0.5 + lift
            v = max(0.0, min(1.0, v))
            n = max(2, levels)
            v = round(v * (n - 1)) / float(n - 1)
            nr, ng, nb = colorsys.hsv_to_rgb(hh, s, v)
            px[x, y] = (int(round(nr * 255)), int(round(ng * 255)), int(round(nb * 255)), a)
            lum[y][x] = 0.299 * nr + 0.587 * ng + 0.114 * nb

    orr, og, ob = colorsys.hsv_to_rgb(hue_deg / 360.0, outline_sat, outline_val)
    outline_rgb = (orr * 255.0, og * 255.0, ob * 255.0)

    # ---- 4. 内描边：先 3x3 平滑去噪，再按梯度压暗
    blur = [[0.0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            if px[x, y][3] == 0:
                continue
            tot, cnt = 0.0, 0
            for dy in (-1, 0, 1):
                yy = y + dy
                if yy < 0 or yy >= h:
                    continue
                for dx in (-1, 0, 1):
                    xx = x + dx
                    if xx < 0 or xx >= w or px[xx, yy][3] == 0:
                        continue
                    tot += lum[yy][xx]
                    cnt += 1
            blur[y][x] = tot / cnt if cnt else 0.0
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if px[x, y][3] == 0:
                continue
            # 只处理「四周都是实体」的像素 —— 轮廓交给外描边，避免重复加深
            if px[x - 1, y][3] == 0 or px[x + 1, y][3] == 0:
                continue
            if px[x, y - 1][3] == 0 or px[x, y + 1][3] == 0:
                continue
            gx = abs(blur[y][x + 1] - blur[y][x - 1])
            gy = abs(blur[y + 1][x] - blur[y - 1][x])
            if (gx * gx + gy * gy) ** 0.5 <= inner_thr * 255.0:
                continue
            r, g, b, a = px[x, y]
            px[x, y] = (
                int(r + (outline_rgb[0] - r) * inner),
                int(g + (outline_rgb[1] - g) * inner),
                int(b + (outline_rgb[2] - b) * inner),
                a,
            )

    # ---- 1. 外描边：alpha 形态学膨胀，环带填描边色
    solid = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            if px[x, y][3] >= 90:
                solid[y * w + x] = 1
    grown = bytearray(solid)
    for _ in range(outline_w):
        nxt = bytearray(grown)
        for y in range(h):
            for x in range(w):
                if grown[y * w + x]:
                    continue
                if (x > 0 and grown[y * w + x - 1]) or (x < w - 1 and grown[y * w + x + 1]) \
                        or (y > 0 and grown[(y - 1) * w + x]) or (y < h - 1 and grown[(y + 1) * w + x]):
                    nxt[y * w + x] = 1
        grown = nxt
    for y in range(h):
        for x in range(w):
            if grown[y * w + x] and not solid[y * w + x]:
                px[x, y] = (int(outline_rgb[0]), int(outline_rgb[1]), int(outline_rgb[2]), 255)
    return img


def cluster(src, size=SIZE, fill=FILL):
    """把单株晶柱合成一簇。

    Kenney 的晶体是单株的，直接放到矿点上会像一片叶子 ——
    矿簇需要「高低错落 + 前后遮挡」才像矿。这里用同一株做三份，
    按不同缩放与横向偏移叠加，底部对齐。
    """
    big = 256
    bbox = src.getchannel("A").getbbox()
    if bbox is None:
        return Image.new("RGBA", (size, size), (0, 0, 0, 0))
    crop = src.crop(bbox)
    target_h = int(big * 0.60)
    sc0 = target_h / float(crop.height)
    unit = crop.resize((max(1, int(round(crop.width * sc0))), target_h), Image.LANCZOS)

    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    baseline = int(big * 0.82)
    # 后排两株矮一些、往两侧偏，前排一株最高居中 —— 形成前后层次
    for k, ox in ((0.72, -0.21), (0.86, 0.20), (1.0, 0.0)):
        w = max(1, int(round(unit.width * k)))
        h = max(1, int(round(unit.height * k)))
        piece = unit.resize((w, h), Image.LANCZOS)
        x = int(big * 0.5 + ox * big - w * 0.5)
        canvas.alpha_composite(piece, (x, baseline - h))
    return fit(canvas, size, fill)


# ---------------------------------------------------------------- 主流程
def build():
    os.makedirs(DST, exist_ok=True)
    made = []

    for uid, (num, fac) in UNIT_MAP.items():
        src = Image.open(os.path.join(SRC, "Unit", "scifiUnit_%02d.png" % num)).convert("RGBA")
        out = recolor(fit(src), FACTION_HUE[fac], GREY_TINT_UNIT, SAT_FLOOR_UNIT)
        out = cartoonize(out, FACTION_HUE[fac], outline_w=3)
        p = os.path.join(DST, "u_%s.png" % uid)
        out.save(p)
        made.append(("u_" + uid, fac, num))

    for bid, (num, fac) in BUILDING_MAP.items():
        src = Image.open(os.path.join(SRC, "Structure", "scifiStructure_%02d.png" % num)).convert("RGBA")
        out = recolor(fit(src), FACTION_HUE[fac], GREY_TINT_BUILD, SAT_FLOOR_BUILD)
        out = cartoonize(out, FACTION_HUE[fac], outline_w=2)
        p = os.path.join(DST, "b_%s.png" % bid)
        out.save(p)
        made.append(("b_" + bid, fac, num))

    for name, (num, rgb) in RES_MAP.items():
        src = Image.open(os.path.join(SRC, "Environment", "scifiEnvironment_%02d.png" % num)).convert("RGBA")
        out = force_color(cluster(src), rgb)
        # 资源点也要描边，否则摆在卡通化的地面和单位中间会显得「糊」
        out = cartoonize(out, colorsys.rgb_to_hsv(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)[0] * 360.0,
                         outline_w=2, sat_boost=1.15, contrast=1.10, inner=0.22, inner_thr=0.14,
                         outline_sat=0.55, outline_val=0.20)
        p = os.path.join(DST, "%s.png" % name)
        out.save(p)
        made.append((name, "res", num))

    print("已生成 %d 张贴图 -> %s" % (len(made), DST))
    for n, f, num in made:
        print("   %-22s %-8s <- Kenney #%02d" % (n, f, num))
    return made


def preview(made):
    """把烘焙结果拼成一张对照图，方便一眼评估配色与造型。"""
    def font(sz):
        for p in ["C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/arial.ttf"]:
            if os.path.exists(p):
                try:
                    return ImageFont.truetype(p, sz)
                except Exception:
                    pass
        return ImageFont.load_default()

    f = font(15)
    cell = 72
    pad = 8
    lab = 18
    groups = [
        ("人族 单位", [m for m in made if m[0].startswith("u_") and m[1] == "terran"]),
        ("虫族 单位", [m for m in made if m[0].startswith("u_") and m[1] == "zerg"]),
        ("神族 单位", [m for m in made if m[0].startswith("u_") and m[1] == "protoss"]),
        ("人族 建筑", [m for m in made if m[0].startswith("b_") and m[1] == "terran"]),
        ("虫族 建筑", [m for m in made if m[0].startswith("b_") and m[1] == "zerg"]),
        ("神族 建筑", [m for m in made if m[0].startswith("b_") and m[1] == "protoss"]),
        ("资源", [m for m in made if m[1] == "res"]),
    ]
    cols = 5
    cw = cell + pad * 2
    ch = cell + pad * 2 + lab
    row_h = ch
    total_h = 0
    for _, items in groups:
        rows = (len(items) + cols - 1) // cols
        total_h += rows * row_h + 22
    img = Image.new("RGB", (cw * cols, total_h + 10), (26, 33, 48))
    d = ImageDraw.Draw(img)
    y0 = 6
    for title, items in groups:
        d.text((10, y0), title, fill=(255, 214, 120), font=font(18))
        y0 += 22
        for i, (name, fac, num) in enumerate(items):
            p = os.path.join(DST, name + ".png")
            if not os.path.exists(p):
                continue
            src = Image.open(p).convert("RGBA")
            big = src.resize((cell, cell), Image.LANCZOS)
            cx = (i % cols) * cw + pad
            cy = y0 + (i // cols) * row_h
            d.rectangle([cx, cy, cx + cell, cy + cell], fill=(38, 46, 62))
            img.paste(big, (cx, cy), big)
            t = name[:13]
            tw = d.textlength(t, font=f)
            d.text((cx + (cell - tw) / 2, cy + cell + 2), t, fill=(170, 200, 240), font=f)
        rows = (len(items) + cols - 1) // cols
        y0 += rows * row_h
    out = os.path.join(SHOTS, "30_skin_preview.png")
    img.save(out)
    print("预览图 ->", out, img.size)


if __name__ == "__main__":
    os.makedirs(SHOTS, exist_ok=True)
    preview(build())
