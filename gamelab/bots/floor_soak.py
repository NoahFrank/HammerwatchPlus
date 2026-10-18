"""floor_soak: many floor_runner samples in one game process. Each sample re-enters the
mission's first floor (a fresh generated layout) and runs floor_runner from its spawn, so a
reliability figure costs one boot, not one per sample. timescale > 1 sets g_timescale
(gamelab-hands `timescale`; the game ticks a fixed ~30 frames a second, a larger timescale
makes each frame step more game time: timescale 20261017-175329)."""
import time

from gamelab import pilot as pilotlib


def enter(p, mission, floor, timeout=60):
    st = p.state()
    if st.get("phase") == "dead" or st.get("window") == "DeadMenu":
        # a dead player stays dead through a mission restart (floor-soak 20261017-192111:
        # phase "dead" for 60 s on the new floor). Leave the way a player does: MenuAccept on
        # the DeadMenu (DeadMenu.as:65-90: ResetPlayerHealthMana, SpawnPlayer, AbortMission)
        before = {id(o) for o in p.game.gl}
        p.game.key("enter")
        hb = p.game.wait_gl(lambda o: id(o) not in before and o.get("ev") == "hb" and o.get("phase") == "town", timeout)
        if hb is None:
            raise RuntimeError("dead: no town heartbeat after MenuAccept on the DeadMenu")
    old = {id(o) for o in p.game.gl}
    p.cmd("mission", mission, floor, timeout=30)
    hb = p.game.wait_gl(lambda o: id(o) not in old and o.get("ev") == "hb" and o.get("phase") == "mission"
                        and o.get("n", 0) >= 2, timeout)
    if hb is None:
        raise RuntimeError(f"mission {mission} {floor}: no mission heartbeat within {timeout}s")


def run(p, n=6, timescale=1, mission="dark_citadel", budget_s=300):
    fr = pilotlib.load_bot("floor_runner")
    samples = []
    for i in range(n):
        if i:
            enter(p, mission, 0)
        if timescale != 1:
            p.cmd("timescale", timescale)
        t0 = time.time()
        r = fr.run(p, budget_s=budget_s)
        s = {k: r.get(k) for k in ("terminal", "reason", "exit_attempts", "fights", "reflex_potions", "probes", "retries")}
        s.update(seconds=round(time.time() - t0, 1),
                 place_to=r.get("place_to"))
        samples.append(s)
        p.game.note("soak_sample", i=i, **{k: v for k, v in s.items() if k != "probes"},
                    probe_routes=[{k: v for k, v in (pr or {}).items() if k.startswith("nav")} for pr in s.get("probes") or []])
    passes = sum(s["terminal"] == "next_floor" for s in samples)
    if timescale != 1:
        p.cmd("timescale", 1)
    return {"terminal": "soaked", "n": n, "passes": passes, "timescale": timescale, "samples": samples}
