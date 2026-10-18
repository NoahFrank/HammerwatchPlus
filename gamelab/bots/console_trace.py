"""Measurement bot: the console's state after each step of a typed gl line, from shots (top
band brightness vs a closed-console shot). Steps typed by hand here with FAST_TIMING-like
waits, so each key's effect is seen separately."""
import time

from PIL import Image, ImageChops, ImageStat

from gamelab import winproc


def band(png):
    im = Image.open(png).convert("L")
    return im.crop((0, 0, im.width, im.height // 3))


def run(p, wait=0.07, n=4):
    g = p.game
    h = g.window()
    base = band(g.shot("t0"))
    out = {"steps": []}
    k = 0

    def look(label):
        nonlocal k
        k += 1
        png = g.shot(f"t{k} {label}")
        out["steps"].append({"k": k, "step": label, "open": ImageStat.Stat(ImageChops.difference(base, band(png))).mean[0] > 30})

    for i in range(n):
        g._next_id += 1
        line = f"gl c{g._next_id} ping"
        winproc.key(h, winproc.VK["console"], 0)
        time.sleep(wait)
        look(f"{i} after open")
        winproc.text(h, line, 0)
        winproc.key(h, winproc.VK["enter"], 0)
        time.sleep(wait)
        look(f"{i} after enter")
        winproc.key(h, winproc.VK["console"], 0)
        time.sleep(wait)
        look(f"{i} after close")
        time.sleep(0.5)
        g.pump()
        out["steps"][-1]["echoed"] = f"c{g._next_id}" in g.echoed
    out["terminal"] = "measured"
    return out
