"""快速总览 Tile / Environment 素材。"""

import os
from PIL import Image, ImageDraw, ImageFont

ROOT = "C:/Users/XiaoXin/AppData/Local/Temp/kenney_rts/PNG/Default size"
OUT = "F:/KF/XJ/starcraft-android/shots/kn_zoom_tiles.png"


def font(sz):
    for p in ["C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/arial.ttf"]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, sz)
            except Exception:
                pass
    return ImageFont.load_default()


def sheet(folder, count, prefix, cols, scale, f):
    cell = 64 * scale
    pad = 6
    lab = 20
    cw = cell + pad * 2
    ch = cell + pad * 2 + lab
    rows = (count + cols - 1) // cols
    img = Image.new("RGB", (cw * cols, ch * rows), (26, 33, 48))
    d = ImageDraw.Draw(img)
    for i in range(count):
        p = os.path.join(ROOT, folder, "%s_%02d.png" % (prefix, i + 1))
        if not os.path.exists(p):
            continue
        src = Image.open(p).convert("RGBA")
        big = src.resize((cell, cell), Image.NEAREST)
        cx = (i % cols) * cw + pad
        cy = (i // cols) * ch + pad
        for by in range(0, cell, 16):
            for bx in range(0, cell, 16):
                c = (44, 54, 74) if ((bx // 16 + by // 16) % 2 == 0) else (36, 45, 62)
                d.rectangle([cx + bx, cy + by, cx + bx + 15, cy + by + 15], fill=c)
        img.paste(big, (cx, cy), big)
        t = "%02d" % (i + 1)
        tw = d.textlength(t, font=f)
        d.text((cx + (cell - tw) / 2, cy + cell + 3), t, fill=(180, 210, 255), font=f)
    return img


f = font(20)
a = sheet("Tile", 48, "scifiTile", 8, 2, f)
b = sheet("Environment", 32, "scifiEnvironment", 8, 2, f)
w = max(a.width, b.width)
out = Image.new("RGB", (w, a.height + b.height + 8), (20, 26, 38))
out.paste(a, (0, 0))
out.paste(b, (0, a.height + 8))
out.save(OUT)
print("OK", OUT, out.size, "tiles=", a.size, "env=", b.size)
