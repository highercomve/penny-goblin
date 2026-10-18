#!/usr/bin/env python3
"""Penny Goblin's Android adaptive icon from icon.png: the mascot centred in
Android's safe zone on a forest-green background (res/values), plus the
monochrome layer for themed icons, at every density.

    python3 -I scripts/android-icon.py icon.png android/app/src/main/res /tmp/icon-preview.png
"""
import sys, math
from PIL import Image, ImageDraw
src = Image.open(sys.argv[1]).convert("RGBA")
res = sys.argv[2]; out_preview = sys.argv[3]
BG = (24, 61, 43)          # forest green #183D2B
# The mascot's farthest visible pixel from its centre: scale so it sits inside
# Android's 66dp safe circle (radius 33/108 of the 108dp canvas), with margin.
bbox = src.getbbox(); crop = src.crop(bbox)
cx, cy = crop.width / 2, crop.height / 2
a = crop.getchannel("A"); px = a.load(); far = 0
for y in range(0, crop.height, 2):
    for x in range(0, crop.width, 2):
        if px[x, y] > 40: far = max(far, math.hypot(x - cx, y - cy))
def layer(size, mono=False):
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    scale = (0.30 * size) / far
    art = crop.resize((max(1, round(crop.width * scale)), max(1, round(crop.height * scale))), Image.LANCZOS)
    if mono:
        white = Image.new("RGBA", art.size, (255, 255, 255, 255)); white.putalpha(art.getchannel("A")); art = white
    canvas.alpha_composite(art, ((size - art.width) // 2, (size - art.height) // 2))
    return canvas
for name, size in [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]:
    import os; d = f"{res}/mipmap-{name}"; os.makedirs(d, exist_ok=True)
    layer(size).save(f"{d}/ic_launcher_foreground.png", optimize=True)
    layer(size, True).save(f"{d}/ic_launcher_monochrome.png", optimize=True)
# Preview: what a circular launcher shows (the middle 72dp, masked to a circle).
S = 432; full = Image.new("RGBA", (S, S), BG + (255,)); full.alpha_composite(layer(S))
vis = full.crop((int(S * 18 / 108), int(S * 18 / 108), int(S * 90 / 108), int(S * 90 / 108)))
mask = Image.new("L", vis.size, 0); ImageDraw.Draw(mask).ellipse((0, 0, vis.width - 1, vis.height - 1), fill=255)
circ = Image.new("RGBA", vis.size, (0, 0, 0, 0)); circ.paste(vis, (0, 0), mask)
# Squircle too, and the old look for comparison.
sq = Image.new("RGBA", vis.size, (0, 0, 0, 0)); m2 = Image.new("L", vis.size, 0); ImageDraw.Draw(m2).rounded_rectangle((0, 0, vis.width - 1, vis.height - 1), radius=vis.width // 3, fill=255); sq.paste(vis, (0, 0), m2)
old = Image.new("RGBA", vis.size, (0, 0, 0, 0)); ow = Image.new("RGBA", vis.size, (255, 255, 255, 255)); small = src.resize((int(vis.width * 0.55), int(vis.width * 0.55)), Image.LANCZOS); ow.alpha_composite(small, ((vis.width - small.width) // 2, (vis.height - small.height) // 2)); old.paste(ow, (0, 0), mask)
sheet = Image.new("RGBA", (vis.width * 3 + 80, vis.height + 40), (60, 60, 60, 255))
for i, im in enumerate([old, circ, sq]): sheet.alpha_composite(im, (20 + i * (vis.width + 20), 20))
sheet.save(out_preview)
print("far radius", round(far), "of", crop.size)
