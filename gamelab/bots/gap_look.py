"""Measurement bot: stand in the gap between the spawn's pathable region and the enabled
exit's (teleport, a measurement verb) and list what is there by name filter. The scenario
takes the screenshot after it."""

FILTERS = ["Door", "Gate", "Barr", "Bridge", "Toggle", "Area", "Destr", "Break", "thorn", "log",
           "prefab", "bush", "wall", "rock", "cliff", "water", "river", "fence", "Enable", "Block",
           "Collision", "Physics", "Spawn", "Trigger", "Script"]


def run(p, gx=544, gy=-544, radius=320):
    tp = p.cmd("teleport", gx, gy)
    found = {}
    for f in FILTERS:
        r = p.cmd("near", radius, f)
        if r.get("count"):
            found[f] = {"count": r["count"], "units": [(u["name"], u["behavior"], round(u["x"]), round(u["y"]))
                                                       for u in r["units"][:12]]}
    return {"tp": tp, "found": found, "terrain": p.cmd("terrain", 320, 64), "terminal": "looked"}
