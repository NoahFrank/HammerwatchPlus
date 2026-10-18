"""Measurement bot: a reachability map of this floor from the player (the engine
pathfinder's answers on a grid), with the exits marked."""


def run(p, step=96, pad=600):
    sc = p.scan(400)
    px, py = sc["x"], sc["y"]
    xs = [px] + [e["x"] for e in sc["exits"]]
    ys = [py] + [e["y"] for e in sc["exits"]]
    x0, y0, x1, y1 = min(xs) - pad, min(ys) - pad, max(xs) + pad, max(ys) + pad
    m = p.cmd("reachmap", round(x0), round(y0), round(x1), round(y1), step, timeout=600)
    rows = [list(r) for r in m.get("rows", [])]
    for n, e in enumerate(sc["exits"]):
        i, j = round((e["x"] - x0) / step), round((e["y"] - y0) / step)
        if 0 <= j < len(rows) and 0 <= i < len(rows[j]):
            rows[j][i] = "E" if e["enabled"] else "e"
    return {"from": [px, py], "exits": sc["exits"], "map": {k: v for k, v in m.items() if k != "rows"},
            "rows": ["".join(r) for r in rows], "terminal": "surveyed"}
