"""临时调参脚本：对比「重着色」与「卡通化」两版皮肤。用完即删。

同时按 64px（源尺寸）和 22px（游戏内实际屏幕尺寸）两种尺寸渲染，
后者再放大 4 倍用最近邻显示 —— 游戏里单位就这么小，描边够不够粗只有这样才看得出来。
"""

import os
import sys
import colorsys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_skins as bs
from PIL import Image, ImageDraw, ImageFont

SHOTS = bs.SHOTS

# 代表性样本：小单位（最吃亏）/ 中单位 / 大单位 / 建筑
SAMPLES = [
    ("u_marine", "Unit", 2, "terran", 7.0),
    ("u_zergling", "Unit", 26, "zerg", 6.0),
    ("u_zealot", "Unit", 14, "protoss", 9.0),
    ("u_siege_tank", "Unit", 9, "terran", 12.0),
    ("b_barracks", "Structure", 5, "terran", 14.0),
    ("b_nexus", "Structure", 7, "protoss", 17.0),
]


# ---------------------------------------------------------------- 卡通化
def cartoonize(img, hue_deg, outline_w=3, levels=7, sat_boost=1.30,
               contrast=1.16, lift=-0.01, inner=0.30, inner_thr=0.115,
               outline_sat=0.42, outline_val=0.14):
    """把贴图推向卡通风格。

    卡通感来自四件事，按视觉重要性排序：
      1. 外描边 —— 最强的卡通线索。没有它，再高的饱和度也像写实贴图。
      2. 高饱和 —— 卡通用色比写实更纯。
      3. 平涂   —— 明度量化成有限级数，消除柔和渐变。
      4. 内描边 —— 用明度梯度画结构线，产生「线稿」感。

    内描边必须先对明度做 3x3 平滑再求梯度。Kenney 源图带颗粒噪点，
    直接求梯度会把噪点全判成结构线，画出来是一片脏斑。
    """
    w, h = img.size
    px = img.load()

    # ---- 1/2/3. 颜色：提饱和 + 提对比 + 明度量化
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

    # ---- 4. 内描边：先 3x3 平滑去噪，再按梯度压暗
    oh, os_, ov = hue_deg / 360.0, outline_sat, outline_val
    orr, og, ob = colorsys.hsv_to_rgb(oh, os_, ov)
    outline_rgb = (orr * 255.0, og * 255.0, ob * 255.0)
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
    inner_pts = []
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if px[x, y][3] == 0:
                continue
            # 只处理「四周都是实体」的像素，边缘交给外描边
            if px[x - 1, y][3] == 0 or px[x + 1, y][3] == 0:
                continue
            if px[x, y - 1][3] == 0 or px[x, y + 1][3] == 0:
                continue
            gx = abs(blur[y][x + 1] - blur[y][x - 1])
            gy = abs(blur[y + 1][x] - blur[y - 1][x])
            if (gx * gx + gy * gy) ** 0.5 > inner_thr * 255.0:
                inner_pts.append((x, y))
    for x, y in inner_pts:
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


# ---------------------------------------------------------------- 对照图
def sheet():
    def font(sz):
        for p in ["C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/arial.ttf"]:
            if os.path.exists(p):
                try:
                    return ImageFont.truetype(p, sz)
                except Exception:
                    pass
        return ImageFont.load_default()

    f14 = font(14)
    f12 = font(12)
    src_zoom = 2       # 64px 源图放大倍数
    game = 22          # 游戏内实际屏幕尺寸
    game_zoom = 8      # 游戏尺寸放大倍数（最近邻，看清像素结构）
    s = 64 * src_zoom
    gz = game * game_zoom
    pad = 14
    rowh = max(s, gz) + 34

    colw = 10 + s + pad + s + pad * 2 + gz + pad + gz + 10
    img = Image.new("RGB", (colw, 34 + rowh * len(SAMPLES) + 10), (24, 30, 44))
    d = ImageDraw.Draw(img)
    d.text((10, 8), "左二: 源图 %dpx 放大%d倍   右二: 游戏内 %dpx 放大%d倍"
           % (s // src_zoom, src_zoom, game, game_zoom),
           fill=(255, 214, 120), font=f14)

    for i, (name, folder, num, fac, rad) in enumerate(SAMPLES):
        fn = "scifiUnit_%02d.png" % num if folder == "Unit" else "scifiStructure_%02d.png" % num
        src = Image.open(os.path.join(bs.SRC, folder, fn)).convert("RGBA")
        hue = bs.FACTION_HUE[fac]
        grey_w = bs.GREY_TINT_UNIT if folder == "Unit" else bs.GREY_TINT_BUILD

        old = bs.recolor(bs.fit(src), hue, grey_w)
        ow = 3 if folder == "Unit" else 2
        new = cartoonize(bs.recolor(bs.fit(src), hue, grey_w), hue, outline_w=ow)

        y0 = 34 + i * rowh
        x = 10
        for im in (old, new):
            d.rectangle([x, y0, x + s, y0 + s], fill=(38, 46, 62))
            big = im.resize((s, s), Image.LANCZOS)
            img.paste(big, (x, y0), big)
            x += s + pad
        x += pad
        for im in (old, new):
            d.rectangle([x, y0, x + gz, y0 + gz], fill=(38, 46, 62))
            small = im.resize((game, game), Image.LANCZOS)
            img.paste(small.resize((gz, gz), Image.NEAREST), (x, y0), small.resize((gz, gz), Image.NEAREST))
            x += gz + pad
        d.text((10, y0 + rowh - 20), "%s   (旧 | 新)" % name, fill=(170, 200, 240), font=f12)

    out = os.path.join(SHOTS, "_tune_cartoon.png")
    img.save(out)
    print("对照图 ->", out, img.size)


if __name__ == "__main__":
    sheet()
