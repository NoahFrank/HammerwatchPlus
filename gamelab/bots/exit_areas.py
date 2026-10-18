"""Measurement bot: where a LevelExitAreaNext's Areas are, and whether standing in one and
pressing Use takes the exit. exitareas from the spawn, then (cull + teleport: measurement
verbs) standing on the sensor nearest the area's inside-unit centroid."""
import math


def run(p):
    out = {"spawn": p.cmd("exitareas", 600)}
    ex = out["spawn"]
    ins = [u for a in ex.get("areas", []) for u in a.get("inside", []) if u["unit"]]
    cx = sum(u["x"] for u in ins) / len(ins)
    cy = sum(u["y"] for u in ins) / len(ins)
    sensor = min((s for s in ex["sensors"] if s["name"].startswith(":Physics")),
                 key=lambda s: math.hypot(s["x"] - cx, s["y"] - cy))
    out.update(centroid=[cx, cy], sensor=sensor)
    p.cmd("cull")
    out["tp"] = p.cmd("teleport", sensor["x"], sensor["y"])
    p.wait(500)
    out["in_area"] = p.cmd("exitareas", 600)
    out["usables"] = p.cmd("usables")
    r = p.use(timeout=5)
    out["use"] = {"result": r.result, "reason": r.reason}
    out["terminal"] = "looked"
    return out
