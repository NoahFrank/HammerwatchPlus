"""Measurement bot: does the engine pathfinder's answer between two fixed points change during
play? NavRoute spawn -> exit stand point (exitprobe with the spawn as reference) at the start,
after idling, after cull (no enemies), after the player is teleported partway (measurement
verbs), and back at the spawn."""


def keep(r):
    return {k: r.get(k) for k in ("px", "py", "sx", "sy", "navFwd", "navFwdExp", "navRef",
                                   "navRefExp", "navToRef", "navToRefExp", "error")}


def run(p, idle_ms=30000):
    p.reflex(potion=50, fire=160)
    s = p.status()
    sx, sy = int(s["x"]), int(s["y"])
    out = {"spawn": [sx, sy], "probes": []}

    def probe(label):
        r = keep(p.cmd("exitprobe", sx, sy, timeout=90))
        r["label"] = label
        out["probes"].append(r)
        return r

    first = probe("start")
    p.wait(idle_ms)
    probe("idle")
    p.cmd("cull")
    p.wait(1000)
    probe("culled")
    for f in (0.25, 0.5, 0.75):
        x = sx + (first["sx"] - sx) * f
        y = sy + (first["sy"] - sy) * f
        p.cmd("teleport", int(x), int(y))
        p.wait(3000)
        probe(f"at {f}")
    p.cmd("teleport", sx, sy)
    p.wait(3000)
    probe("back at spawn")
    out["terminal"] = "looked"
    return out
