#!/usr/bin/env python3
"""Penny Goblin's desktop application icon (icon.png) from the transparent
mark: the mascot on the forest-green rounded tile Android's adaptive icon
uses, with its outline thickened so it stays legible at 32-48 px launcher
sizes, where the bare 1024 px monoline mark shrinks to a faint 1 px line.

    python3 -I scripts/desktop-icon.py frontend/logo.png icon.png /tmp/icon-preview.png
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
BG = (24, 61, 43, 255)          # forest green #183D2B, as res/values
src = Image.open(sys.argv[1]).convert("RGBA")
art = src.crop(src.getbbox())
# Fit the mark inside the tile's safe area, centred.
scale = 0.70 * S / max(art.size)
art = art.resize((round(art.width * scale), round(art.height * scale)), Image.LANCZOS)
# Thicken every stroke by dilating each colour plane with the alpha: the
# coral check and green outline keep their own colour.
grow = 13
premul = Image.new("RGBA", art.size)
premul.paste(art, (0, 0), art)
rgb = premul.convert("RGB").filter(ImageFilter.MaxFilter(grow))
alpha = art.getchannel("A").filter(ImageFilter.MaxFilter(grow))
art = Image.merge("RGBA", (*rgb.split(), alpha))
tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
margin = 40                     # freedesktop icons leave a little air
ImageDraw.Draw(tile).rounded_rectangle((margin, margin, S - margin, S - margin), radius=220, fill=BG)
tile.alpha_composite(art, ((S - art.width) // 2, (S - art.height) // 2 + 10))
tile.save(sys.argv[2], optimize=True)

# Preview at launcher sizes on dark and light panels.
sizes = [256, 128, 64, 48, 32, 24]
sheet = Image.new("RGBA", (sum(sizes) + 20 * (len(sizes) + 1), 2 * 276), (30, 30, 40, 255))
ImageDraw.Draw(sheet).rectangle((0, 276, sheet.width, sheet.height), fill=(240, 240, 240, 255))
for row in range(2):
    x = 20
    for size in sizes:
        sheet.alpha_composite(tile.resize((size, size), Image.LANCZOS), (x, row * 276 + 10))
        x += size + 20
sheet.save(sys.argv[3])
