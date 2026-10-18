"""Measurement bot: gl round-trip time and reliability for console() timing profiles. For
each profile, n `ping`s (and n `inspect player level`, a longer line), timed end to end;
a lost or wrong reply, and a retyped line (session.gl_cmd), are counted, not raised."""
import time

PROFILES = {
    "old": {"open": 0.15, "gap": 0.004, "pre_enter": 0.05, "post_enter": 0.1, "close": 0.1, "hold": 0.05},
    "frame": {"open": 0.04, "gap": 0.0, "pre_enter": 0.0, "post_enter": 0.0, "close": 0.0, "hold": 0.0},
    "burst": {"open": 0.0, "gap": 0.0, "pre_enter": 0.0, "post_enter": 0.0, "close": 0.0, "hold": 0.0},
    "fast": {"open": 0.07, "gap": 0.0, "pre_enter": 0.0, "post_enter": 0.07, "close": 0.07, "hold": 0.0},
    "close150": {"open": 0.07, "gap": 0.0, "pre_enter": 0.0, "post_enter": 0.07, "close": 0.15, "hold": 0.0},
    "close250": {"open": 0.07, "gap": 0.0, "pre_enter": 0.0, "post_enter": 0.07, "close": 0.25, "hold": 0.0},
    "close350": {"open": 0.07, "gap": 0.0, "pre_enter": 0.0, "post_enter": 0.07, "close": 0.35, "hold": 0.0},
    "adaptive": None,     # session.gl_cmd's own choice (fast, paced after a level load)
}


def reentry(p, profile="adaptive", times=3, mission="dark_citadel"):
    """Level changes typed through the console, each followed at once by a command: the case
    that lost a line in floor-soak 20261017-180322."""
    g = p.game
    g.console_timing = PROFILES[profile]
    out = []
    retyped_before = sum(1 for _ in ())
    for i in range(times):
        old = {id(o) for o in g.gl}
        g.gl_cmd("mission", mission, 0, timeout=30)
        try:
            r = g.gl_cmd("ping", timeout=20)
            ok = bool(r.get("ok"))
        except Exception as e:
            ok = False
        hb = g.wait_gl(lambda o: id(o) not in old and o.get("ev") == "hb" and o.get("phase") == "mission", 60)
        out.append({"ping_after_mission": ok, "mission_hb": hb is not None})
    del g.console_timing
    return out


def line_limit(p, sizes=(100, 200, 400, 800, 1200, 2000)):
    """multi lines of n chars ('ping + ping + ...'): how many sub-replies come back."""
    g = p.game
    out = []
    for size in sizes:
        k = max(1, (size - 20) // 7)          # "ping + " is 7 characters
        args = []
        for i in range(k):
            args += (["+"] if args else []) + ["ping"]
        line_len = len(" ".join(["gl", "c999", "multi", *args]))
        try:
            head = g.gl_cmd("multi", *args, timeout=10)
            out.append({"chars": line_len, "sent": k, "answered": head.get("n")})
        except Exception as e:
            out.append({"chars": line_len, "sent": k, "error": str(e)[:80]})
    return out


def run(p, n=20, profiles=("old", "frame", "burst"), reentries=0, limits=False):
    g = p.game
    out = {}
    retypes = []
    note = g.note

    def counting(ev, **kw):
        if ev == "console_retype":
            retypes.append(kw.get("id"))
        note(ev, **kw)
    g.note = counting
    for name in profiles:
        g.console_timing = PROFILES[name]
        idle_every = 10 if name == "adaptive" else 0
        times, lost, wrong, lost_at = [], 0, 0, []
        retypes.clear()
        for i in range(n):
            if idle_every and i % idle_every == idle_every - 1:
                time.sleep(1.5)       # an idle gap: the next line is the "first after quiet" case
            verb, args, key = (("ping", (), "ok") if i % 2 == 0 else ("inspect", ("player", "level"), "value"))
            t0 = time.perf_counter()
            try:
                r = g.gl_cmd(verb, *args, timeout=5)
                times.append(time.perf_counter() - t0)
                if key not in r:
                    wrong += 1
            except Exception:
                lost += 1
                lost_at.append(i)
        times.sort()
        out[name] = {"n": n, "lost": lost, "wrong": wrong, "retyped": len(retypes), "lost_at": lost_at, "retyped_ids": list(retypes),
                     "median_ms": round(1000 * times[len(times) // 2]) if times else None,
                     "max_ms": round(1000 * times[-1]) if times else None}
    del g.console_timing
    if limits:
        out["line_limit"] = line_limit(p)
    if reentries:
        out["reentry"] = reentry(p, times=reentries)
    g.note = note
    out["terminal"] = "measured"
    return out
