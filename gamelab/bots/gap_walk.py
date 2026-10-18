"""Measurement bot: can the player physically cross the gap between the spawn's pathable
region (A) and the enabled exit's (B)? Whole-floor reachmaps from both sides (teleport:
measurement verb). Cells both maps reach are reported (they would mean one region the
pathfinder answers in pieces). Then from the A cell nearest B, steer straight (move
intent, no pathfinder) at the nearest B cell and see where the player ends up."""


def cells(m, box):
    x0, y0, _, _, st = box
    return [(x0 + i * st, y0 + j * st) for j, r in enumerate(m.get("rows", [])) for i, c in enumerate(r) if c in "#@"]


def run(p, st=128, half=3200):
    sc = p.scan(400)
    px, py = sc["x"], sc["y"]
    ex = next(e for e in sc["exits"] if e["enabled"])
    box = [-half, -half, half, half, st]
    a0 = cells(p.cmd("reachmap", *box, timeout=900), box)
    cull = p.cmd("cull")
    p.wait(1500)
    a = cells(p.cmd("reachmap", *box, timeout=900), box)
    b, side = [], None
    for dx, dy in ((0, -160), (0, 160), (160, 0), (-160, 0), (0, -320), (0, 320), (320, 0), (-320, 0)):
        t = p.cmd("teleport", ex["x"] + dx, ex["y"] + dy)
        if not t.get("ok"):
            return {"terminal": "teleport_failed", "error": t.get("error")}
        b = cells(p.cmd("reachmap", *box, timeout=900), box)
        if len(b) > 3:
            side = [ex["x"] + dx, ex["y"] + dy]
            break
    both = sorted(set(a) & set(b))
    out = {"cull": cull, "na_before_cull": len(a0), "spawn": [px, py], "exit": [ex["x"], ex["y"]], "exit_side": side, "na": len(a), "nb": len(b), "both": both[:20]}
    pairs = sorted((((ax - bx) ** 2 + (ay - by) ** 2) ** 0.5, (ax, ay), (bx, by)) for ax, ay in a for bx, by in b)[:3]
    trials = []
    for d, (ax, ay), (bx, by) in pairs:
        t = p.cmd("teleport", ax, ay)
        if not t.get("ok"):
            trials.append({"teleport_failed": t.get("error")})
            break
        r = p.move(bx, by, 24, timeout=10)
        here = p.scan(50)
        trials.append({"from": [ax, ay], "to": [bx, by], "gap": round(d), "result": r.result, "reason": r.reason,
                       "end": [here.get("x"), here.get("y")], "hp": r.event.get("hp")})
        if r.ok:
            break
    out.update(trials=trials, terminal="walked")
    return out
