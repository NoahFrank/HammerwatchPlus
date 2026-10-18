"""Builds mods/core/gui/hwp/map_icons.png: small minimap / map icons.

    x=0  12x9  fish (fishing spots, holes, full fish traps)
    x=12 11x11 dye pot (dye buckets in a level)
    x=24 9x11  crop (wild crop plots in runs)

Every icon gets a 1 px dark outline so it reads on any floor colour.

    python tools/make_map_icons.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

# '#' body, 'o' eye/highlight, letters: palette below
FISH = [
    "..........",
    "...####..#",
    ".#o#####.#",
    "#########.",
    ".#######.#",
    "...####..#",
    "..........",
]
DYE = [
    ".........",
    "..#####..",
    "...###...",
    ".#######.",
    "#rrryybb#",
    "#rryybbg#",
    "#ryybbgg#",
    ".#######.",
    ".........",
]
CROP = [
    "...g...",
    ".g.g.g.",
    "..ggg..",
    "g..g..g",
    ".g.g.g.",
    "..ggg..",
    "...g...",
    "wwwwwww",
    ".wwwww.",
]
COLORS = {
    "w": (140, 90, 45, 255),
    "#": (120, 200, 255, 255),
    "o": (20, 30, 60, 255),
    "r": (230, 60, 60, 255),
    "y": (240, 210, 60, 255),
    "b": (70, 120, 240, 255),
    "g": (110, 210, 80, 255),
}
DYE_BODY = (200, 150, 110, 255)
OUTLINE = (16, 16, 24, 255)


def draw(rows, body=None):
    w, h = len(rows[0]) + 2, len(rows) + 2
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(rows):
        for x, c in enumerate(row):
            if c == ".":
                continue
            col = COLORS[c]
            if c == "#" and body is not None:
                col = body
            px[x + 1, y + 1] = col
    out = im.copy()
    po = out.load()
    for y in range(h):
        for x in range(w):
            if px[x, y][3]:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] and px[nx, ny] != OUTLINE:
                    po[x, y] = OUTLINE
                    break
    return out


def main():
    fish = draw(FISH)
    dye = draw(DYE, DYE_BODY)
    crop = draw(CROP)
    sheet = Image.new("RGBA", (64, 16), (0, 0, 0, 0))
    sheet.paste(fish, (0, 0), fish)
    sheet.paste(dye, (12, 0), dye)
    sheet.paste(crop, (24, 0), crop)
    dst = ROOT / "mods" / "core" / "gui" / "hwp" / "map_icons.png"
    dst.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(dst)
    print("wrote", dst, "fish", fish.size, "dye", dye.size, "crop", crop.size)


if __name__ == "__main__":
    main()
