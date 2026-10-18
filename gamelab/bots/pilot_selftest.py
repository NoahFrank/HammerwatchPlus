"""Pilot self-test: the control surface and the result vocabulary, in town.

Checks pause / step / resume / stop / target refusal, a closed-vocabulary refusal on both
sides (client and mod), path_to arriving, no_route and timeout. Returns booleans the
scenario asserts on.
"""
import time

from gamelab.pilot import check_until


def run(p):
    out = {}
    s0 = p.state()["player"]
    x, y = s0["x"], s0["y"]

    # client refuses an interrupt outside the vocabulary before sending anything
    try:
        check_until(["hp_below:40", "bored"])
        out["client_rejects_unknown"] = False
    except ValueError:
        out["client_rejects_unknown"] = True
    # and so does the mod
    r = p.cmd("pilot", "wait", 100, "until=bored")
    out["mod_rejects_unknown"] = r.get("ok") is False and "closed vocabulary" in r.get("error", "")

    # pause holds the intent's clock; step advances it by frames; resume finishes it
    a = p.start("wait", 1500, until=["menu_open"], timeout=20)
    p.pause()
    time.sleep(0.3)
    s1 = p.status()
    time.sleep(1.0)
    s2 = p.status()
    out["pause_holds"] = s1.get("intent") == "wait" and s1.get("ms") == s2.get("ms")
    p.step(5)
    time.sleep(0.6)
    s3 = p.status()
    out["step_advances"] = s3.get("ms", 0) > s2.get("ms", 0) and s3.get("paused") is True
    out["step_ms"] = [s2.get("ms"), s3.get("ms")]
    p.resume()
    out["wait_done"] = p.wait_end(a["id"], 10).result == "done"

    # stop interrupts; target needs an attack/kite intent
    b = p.start("wait", 5000)
    out["stop"] = p.stop().get("stopped") is True and p.wait_end(b["id"], 5).reason == "stop"
    out["target_refused_idle"] = p.target(1).get("ok") is False

    # path_to arrives (engine pathfinder), and telemetry ticks were sent on the way
    r = p.path_to(x + 120, y + 80, tol=12, timeout=20)
    out["path_to"] = r.result
    time.sleep(0.5)
    after = p.state()["player"]
    out["path_to_dist"] = round(((after["x"] - x - 120) ** 2 + (after["y"] - y - 80) ** 2) ** 0.5, 1)
    # the controller is released when the intent ends: the player does not drift on
    time.sleep(0.7)
    later = p.state()["player"]
    out["controller_after_end"] = p.cmd("controller")
    out["drift_after_end"] = round(((later["x"] - after["x"]) ** 2 + (later["y"] - after["y"]) ** 2) ** 0.5, 1)
    out["pticks"] = sum(1 for o in p.game.gl if o.get("ev") == "ptick" and o.get("id") == r.id)

    # a target far off the map: the engine pathfinder has no route
    out["no_route"] = p.path_to(x + 90000, y + 90000, timeout=10).result

    # the engine times the intent
    out["timeout"] = p.wait(5000, timeout=1).result

    # a level exit in town: there is none
    out["exit_in_town"] = p.exit(timeout=5).result
    out["terminal"] = "selftest complete"
    return out
