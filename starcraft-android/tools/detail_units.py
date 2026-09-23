"""放大若干个关键单位，用于确认「正前方」朝向与造型细节。"""

import os
from PIL import Image, ImageDraw, ImageFont

SRC = "C:/Users/XiaoXin/AppData/Local/Temp/kenney_rts/PNG/Default size/Unit"
OUT = "F:/KF/XJ/starcraft-android/shots/detail_units.png"

PICK = [1, 2, 4, 5, 6, 9, 11, 27]
SCALE = 6
CELL = 64 * SCALE
PAD = 8
LABEL = 26


def font(sz):
    for p in ["C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/arial.ttf"]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, sz)
            except Exception:
                pass
    return ImageFont.load_default()


f = font(LABEL)
cols = 4
rows = (len(PICK) + cols - 1) // cols
cw = CELL + PAD * 2
ch = CELL + PAD * 2 + LABEL
img = Image.new("RGB", (cw * cols, ch * rows), (26, 33, 48))
d = ImageDraw.Draw(img)

# 参考线：十字 + 上方箭头，用于判断素材朝向
for i, n in enumerate(PICK):
    p = os.path.join(SRC, "scifiUnit_%02d.png" % n)
    src = Image.open(p).convert("RGBA")
    big = src.resize((CELL, CELL), Image.NEAREST)
    cx = (i % cols) * cw + PAD
    cy = (i // cols) * ch + PAD
    for by in range(0, CELL, 24):
        for bx in range(0, CELL, 24):
            c = (44, 54, 74) if ((bx // 24 + by // 24) % 2 == 0) else (36, 45, 62)
            d.rectangle([cx + bx, cy + by, cx + bx + 23, cy + by + 23], fill=c)
    img.paste(big, (cx, cy), big)
    mx = cx + CELL // 2
    my = cy + CELL // 2
    d.line([(mx, cy), (mx, cy + CELL)], fill=(120, 90, 90), width=1)
    d.line([(cx, my), (cx + CELL, my)], fill=(120, 90, 90), width=1)
    # 上方箭头
    d.polygon([(mx, cy + 4), (mx - 10, cy + 22), (mx + 10, cy + 22)], fill=(255, 120, 120))
    lab = "%02d" % n
    tw = d.textlength(lab, font=f)
    d.text((cx + (CELL - tw) / 2, cy + CELL + 4), lab, fill=(180, 210, 255), font=f)

img.save(OUT)
print("OK", OUT, img.size)
