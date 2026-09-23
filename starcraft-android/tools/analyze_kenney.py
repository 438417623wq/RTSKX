"""分析 Kenney Sci-fi RTS 素材：配色分组 + 生成放大对照图。

用法：
    python tools/analyze_kenney.py

输出：
    shots/kn_zoom_units.png    48 个单位 3x 放大带编号
    shots/kn_zoom_structs.png  16 个建筑 3x 放大带编号
    stdout                     每个素材的主色 / 色相 / 明度，用于配色分组
"""

import os
import sys
import colorsys
from collections import defaultdict

from PIL import Image, ImageDraw

# 注意：Windows 版 Python 不认 MSYS 的 /tmp 路径，必须用绝对路径
SRC = "C:/Users/XiaoXin/AppData/Local/Temp/kenney_rts/PNG/Default size"
OUT = "F:/KF/XJ/starcraft-android/shots"

# 用于给放大图找字体（Windows 自带）
FONT_CANDIDATES = [
    "C:/Windows/Fonts/consola.ttf",
    "C:/Windows/Fonts/arial.ttf",
]


def load_font(size):
    from PIL import ImageFont
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def dominant(im):
    """返回不透明像素里，排除近灰像素后的平均色 + 平均饱和度/明度。"""
    px = im.convert("RGBA").getdata()
    n = 0
    rs = gs = bs = 0
    sat_sum = 0.0
    val_sum = 0.0
    vivid = 0
    for r, g, b, a in px:
        if a < 40:
            continue
        n += 1
        rs += r
        gs += g
        bs += b
        h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
        sat_sum += s
        val_sum += v
        if s > 0.25 and v > 0.25:
            vivid += 1
    if n == 0:
        return (0, 0, 0), 0.0, 0.0, 0.0
    avg = (rs // n, gs // n, bs // n)
    return avg, sat_sum / n, val_sum / n, vivid / float(n)


def hue_name(avg):
    r, g, b = [c / 255.0 for c in avg]
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    if s < 0.12:
        return "grey", h, s
    deg = h * 360.0
    if deg < 15 or deg >= 345:
        return "red", h, s
    if deg < 45:
        return "orange", h, s
    if deg < 70:
        return "yellow", h, s
    if deg < 165:
        return "green", h, s
    if deg < 200:
        return "cyan", h, s
    if deg < 255:
        return "blue", h, s
    if deg < 290:
        return "purple", h, s
    return "magenta", h, s


def analyze(kind, folder, count, prefix):
    print("=" * 72)
    print(kind)
    print("=" * 72)
    rows = []
    for i in range(1, count + 1):
        name = "%s_%02d.png" % (prefix, i)
        p = os.path.join(SRC, folder, name)
        if not os.path.exists(p):
            print("  missing", name)
            continue
        im = Image.open(p).convert("RGBA")
        avg, sat, val, vivid = dominant(im)
        hn, hue, hs = hue_name(avg)
        rows.append((i, name, avg, hn, hue, sat, vivid, im.size))
        print("  %-20s size=%-9s avg=#%02x%02x%02x  hue=%-7s(%5.1fdeg) sat=%.2f vivid=%.2f"
              % (name, "%dx%d" % im.size, avg[0], avg[1], avg[2], hn, hue * 360, hs, vivid))
    # 按色相分组统计
    groups = defaultdict(list)
    for i, name, avg, hn, hue, sat, vivid, size in rows:
        groups[hn].append(i)
    print("\n  按主色分组：")
    for k in sorted(groups, key=lambda x: -len(groups[x])):
        print("    %-8s %s" % (k, groups[k]))
    return rows


def zoom_sheet(folder, count, prefix, tag, cols, scale, font_size):
    from PIL import ImageFont
    font = load_font(font_size)
    cell = 64 * scale
    pad = 6
    label_h = font_size + 8
    cw = cell + pad * 2
    ch = cell + pad * 2 + label_h
    rows = (count + cols - 1) // cols
    img = Image.new("RGB", (cw * cols, ch * rows), (26, 33, 48))
    d = ImageDraw.Draw(img)
    for i in range(count):
        name = "%s_%02d.png" % (prefix, i + 1)
        p = os.path.join(SRC, folder, name)
        if not os.path.exists(p):
            continue
        src = Image.open(p).convert("RGBA")
        big = src.resize((cell, cell), Image.NEAREST)
        cx = (i % cols) * cw + pad
        cy = (i // cols) * ch + pad
        # 棋盘底，方便看透明区域
        for by in range(0, cell, 16):
            for bx in range(0, cell, 16):
                c = (44, 54, 74) if ((bx // 16 + by // 16) % 2 == 0) else (36, 45, 62)
                d.rectangle([cx + bx, cy + by, cx + bx + 15, cy + by + 15], fill=c)
        img.paste(big, (cx, cy), big)
        label = "%02d" % (i + 1)
        tw = d.textlength(label, font=font)
        d.text((cx + (cell - tw) / 2, cy + cell + 4), label, fill=(180, 210, 255), font=font)
    out = os.path.join(OUT, tag + ".png")
    img.save(out)
    print("OK %s %s" % (tag + ".png", img.size))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    analyze("单位 Unit（48）", "Unit", 48, "scifiUnit")
    analyze("建筑 Structure（16）", "Structure", 16, "scifiStructure")
    zoom_sheet("Unit", 48, "scifiUnit", "kn_zoom_units", 8, 3, 20)
    zoom_sheet("Structure", 16, "scifiStructure", "kn_zoom_structs", 4, 3, 20)
