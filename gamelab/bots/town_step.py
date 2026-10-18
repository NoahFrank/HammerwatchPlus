"""Town step: path_to one STEP from where the player stands, report how far it actually went.

The revision-without-restart gate (pilot-revision): the scenario runs this bot, edits STEP
with write_bot_file while the game keeps running, runs it again and checks the second walk
followed the edited STEP, in the same game process.
"""
import time

STEP = (100, 0)


def run(p):
    s0 = p.state()["player"]
    r = p.path_to(s0["x"] + STEP[0], s0["y"] + STEP[1], tol=12, timeout=20)
    time.sleep(0.3)
    s1 = p.state()["player"]
    return {"terminal": r.result, "reason": r.reason, "step": list(STEP),
            "dx": round(s1["x"] - s0["x"], 1), "dy": round(s1["y"] - s0["y"], 1)}
