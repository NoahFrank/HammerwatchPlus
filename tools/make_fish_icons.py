"""Builds mods/fishing/items/hwp/fish.png from the vanilla HoH2 fish sprites
(items/consumables/base.png in gamecode/sdk/hoh2/), tinted per fish.

Row 0: 24x24 inventory icons (the 16x16 sprite centred), x = index * 24.
Row 1: 16x16 sprites for the dropped item (items/hwp/fish.unit), x = index * 16, y = 24.
The order matches FISH in mods/fishing/scripts/HWP/Fishing/FishingModule.as.

    python tools/make_fish_icons.py
"""
import io
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from hwr_archive import texture_to_png  # noqa: E402

# id, source frame (x, y) in consumables/base.png, RGB multiplier
FISH = [
    ("perch", (16, 48), (1.0, 1.05, 0.8)),
    ("carp", (16, 32), (1.0, 1.0, 1.0)),
    ("trout", (16, 16), (1.0, 1.0, 1.0)),
    ("pike", (16, 48), (0.75, 1.1, 0.7)),
    ("salmon", (0, 32), (1.15, 0.85, 0.8)),
    ("sturgeon", (128, 0), (0.95, 0.85, 0.7)),
    ("golden_carp", (16, 32), (1.35, 1.1, 0.35)),
    ("abyssal_eel", (128, 0), (0.75, 0.45, 1.2)),
]


def tint(im: Image.Image, mul) -> Image.Image:
    px = im.load()
    out = im.copy()
    po = out.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            po[x, y] = (min(255, int(r * mul[0])), min(255, int(g * mul[1])), min(255, int(b * mul[2])), a)
    return out


def main():
    src = ROOT / "gamecode" / "sdk" / "hoh2" / "items" / "consumables" / "base.png"
    sheet = Image.open(io.BytesIO(texture_to_png(src.read_bytes()))).convert("RGBA")
    out = Image.new("RGBA", (256, 64), (0, 0, 0, 0))
    for i, (fid, (sx, sy), mul) in enumerate(FISH):
        spr = tint(sheet.crop((sx, sy, sx + 16, sy + 16)), mul)
        out.paste(spr, (i * 24 + 4, 4), spr)
        out.paste(spr, (i * 16, 24), spr)
    dst = ROOT / "mods" / "fishing" / "items" / "hwp" / "fish.png"
    dst.parent.mkdir(parents=True, exist_ok=True)
    out.save(dst)
    print("wrote", dst)


if __name__ == "__main__":
    main()
