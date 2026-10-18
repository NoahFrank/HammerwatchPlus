"""Measurement bot: what separates the player's pathable region from the enabled exit.
Whole-floor reachmaps from the spawn and from beside the exit (teleport, a measurement
verb), on the same grid, so the two regions can be compared cell by cell."""


def run(p, step=128, half=4000):
    sc = p.scan(400)
    px, py = sc["x"], sc["y"]
    ex = next(e for e in sc["exits"] if e["enabled"])
    box = [-half, -half, half, half, step]
    out = {"spawn": [px, py], "exits": sc["exits"], "box": box}
    out["rows_spawn"] = p.cmd("reachmap", *box, timeout=900)["rows"]
    for dx, dy in ((0, -160), (0, 160), (160, 0), (-160, 0), (0, -320), (0, 320), (320, 0), (-320, 0)):
        p.cmd("teleport", ex["x"] + dx, ex["y"] + dy)
        m1 = p.cmd("reachmap", *box, timeout=900)
        if m1.get("reachable", 0) > 3:
            out.update(exit_side=[ex["x"] + dx, ex["y"] + dy], rows_exit=m1["rows"])
            break
    p.cmd("teleport", px, py)
    out["terminal"] = "looked"
    return out
