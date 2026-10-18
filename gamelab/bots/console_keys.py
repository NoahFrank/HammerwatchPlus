"""Measurement bot: does the console key toggle the console when posted with no hold (down
and up in one burst) vs held across a frame? A shot after each press; the top band of the
frame (where the console draws) is compared with the first, closed-console shot."""
import time

from PIL import Image, ImageChops, ImageStat

from gamelab import winproc


def band(png):
    im = Image.open(png).convert("L")
    return im.crop((0, 0, im.width, im.height // 3))


def run(p, settle=0.3):
    g = p.game
    h = g.window()
    base = band(g.shot("k0 closed"))
    out = {"presses": []}
    for i, hold in enumerate((0.0, 0.0, 0.05, 0.05, 0.0, 0.05, 0.02, 0.02)):
        winproc.key(h, winproc.VK["console"], hold)
        time.sleep(settle)
        png = g.shot(f"k{i + 1} hold{int(hold * 1000)}")
        diff = ImageStat.Stat(ImageChops.difference(base, band(png))).mean[0]
        out["presses"].append({"hold_ms": int(hold * 1000), "top_band_diff": round(diff, 1)})
    out["terminal"] = "measured"
    return out
