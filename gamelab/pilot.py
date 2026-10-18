"""Python client for mods/gamelab-pilot: blocking verbs over the gl channel.

    from gamelab.pilot import Pilot
    p = Pilot(game, run_id="20261017-...")
    r = p.path_to(120, 40, until=["hp_below:40", "under_attack"], timeout=30)
    if r.result == "interrupted": ...

Every intent verb blocks until the in-engine intent ends and returns a Result whose
`result` is one of RESULTS. `until=` takes names from the closed INTERRUPTS vocabulary
(a name with an argument is "name:arg"); anything else raises ValueError before a
command is sent, and the mod refuses it too.

level_changed: a level load reloads the script module, so the intent in the engine is
gone with it. The client sees the probe's next "boot" event instead (not a "[preload]"
one: the game preloads the next floor in a separate script context that constructs the
modules too, session.py tags those): an `exit` intent
ends "done" there, any other intent ends "interrupted" with reason "level_changed".

Travel: gamelab/travel/authored.json (hand-written edges) and learned.json (edges an
exit intent took). An exit that leads somewhere the graph did not know is appended to
learned.json with its run id, in an exploration run only (a scenario with "explore": true,
Pilot(explore=True)); any other run reports it as new_edge and leaves the graph alone, so
its results stay deterministic. graph_revision() is the sha8 of both files, pinned in
scenario results.

Bots (gamelab/bots/<name>.py) define run(pilot) and are loaded fresh by path on every
call (load_bot), so an edited bot runs on the next call without a game restart.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TRAVEL = REPO / "gamelab" / "travel"
BOTS = REPO / "gamelab" / "bots"

INTERRUPTS = ("hp_below", "under_attack", "target_dead", "level_changed", "menu_open", "dead")
RESULTS = ("done", "failed", "timeout", "interrupted", "no_route")


@dataclass
class Result:
    result: str
    reason: str = ""
    intent: str = ""
    id: str = ""
    tick: int | None = None
    event: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.result == "done"


def check_until(until) -> list[str]:
    names = [until] if isinstance(until, str) else list(until or [])
    for u in names:
        if u.split(":", 1)[0] not in INTERRUPTS:
            raise ValueError(f"unknown interrupt {u!r}: the vocabulary is closed ({', '.join(INTERRUPTS)})")
    return names


def graph_revision() -> str:
    h = hashlib.sha256()
    for name in ("authored.json", "learned.json"):
        p = TRAVEL / name
        h.update(name.encode() + b"\0" + (p.read_bytes() if p.exists() else b""))
    return h.hexdigest()[:8]


def load_graph() -> dict:
    edges = []
    for name in ("authored.json", "learned.json"):
        p = TRAVEL / name
        if p.exists():
            edges += [dict(e, source=name) for e in json.loads(p.read_text(encoding="utf-8")).get("edges", [])]
    return {"edges": edges}


def known_edge(frm: str, to: str) -> bool:
    return any(e["from"] == frm and e["to"] == to for e in load_graph()["edges"])


def learn_edge(frm: str, to: str, via: dict, run_id: str) -> bool:
    """Append frm -> to to learned.json unless the graph already has it. True if new."""
    if known_edge(frm, to):
        return False
    p = TRAVEL / "learned.json"
    data = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {
        "about": "Level transitions the Pilot took that authored.json did not list. Written by gamelab/pilot.py.",
        "edges": []}
    data["edges"].append({"from": frm, "to": to, "via": via, "run": run_id,
                          "seen": time.strftime("%Y-%m-%d")})
    p.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    return True


def load_bot(name: str):
    """The bot module, executed fresh from its file (no import cache): a revision runs as is."""
    path = BOTS / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"gamelab_bot_{name}_{time.time_ns()}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Pilot:
    def __init__(self, game, run_id: str = "", explore: bool = False):
        self.game = game
        self.run_id = run_id
        self.explore = explore               # an exploration run: new transitions go to learned.json
        self.log: list[Result] = []          # every intent's result, in order

    # ---- plumbing -----------------------------------------------------------

    def cmd(self, *args, timeout: float = 15) -> dict:
        return self.game.gl_cmd(*args, timeout=timeout)

    def _intent(self, intent: str, *args, until=(), timeout: float = 30) -> Result:
        names = check_until(until)
        extra = [f"until={','.join(names)}"] if names else []
        start = len(self.game.gl)
        reply = self.cmd("pilot", intent, *args, *extra, f"timeout={int(timeout * 1000)}")
        self.last_accept = reply
        if intent == "exit" and reply.get("ok"):
            self.last_exit_accept = reply     # the exit's anchor/stand point, for the bot's probes
        if not reply.get("ok"):
            return self._done(Result("failed", reply.get("error", "refused"), intent, reply.get("id", "")))
        cid = reply["id"]
        end = time.time() + timeout + 10            # the engine times the intent; this is the backstop
        seen = start
        while time.time() < end:
            self.game.pump()
            for obj in self.game.gl[seen:]:
                if obj.get("ev") == "pilot" and obj.get("id") == cid:
                    return self._done(Result(obj["result"], obj.get("reason", ""), intent, cid, obj.get("tick"), obj))
                if obj.get("ev") == "boot" and not obj.get("_preload"):
                    # a level load: the script module (and the intent with it) is gone
                    if intent == "exit":
                        return self._done(Result("done", "level_changed", intent, cid, None, obj))
                    return self._done(Result("interrupted", "level_changed", intent, cid, None, obj))
            seen = len(self.game.gl)
            if not self.game.alive():
                return self._done(Result("failed", "game exited", intent, cid))
            time.sleep(0.05)
        try:
            self.cmd("pilot", "stop")
        except Exception:                            # noqa: BLE001 - best effort
            pass
        return self._done(Result("timeout", "no end event from the engine", intent, cid))

    def _done(self, r: Result) -> Result:
        self.log.append(r)
        self.game.note("pilot_result", intent=r.intent, id=r.id, result=r.result, reason=r.reason, tick=r.tick)
        return r

    # ---- intents (blocking) -------------------------------------------------

    def move(self, x, y, tol=10, **kw) -> Result:
        return self._intent("move", x, y, tol, **kw)

    def path_to(self, x, y, tol=10, **kw) -> Result:
        return self._intent("path_to", x, y, tol, **kw)

    def attack(self, unit="nearest", **kw) -> Result:
        return self._intent("attack", unit, **kw)

    def kite(self, unit="nearest", rng=70, **kw) -> Result:
        return self._intent("kite", unit, rng, **kw)

    def use(self, unit=None, **kw) -> Result:
        return self._intent("use", *([unit] if unit is not None else []), **kw)

    def potion(self, **kw) -> Result:
        return self._intent("potion", **kw)

    def wait(self, ms, **kw) -> Result:
        return self._intent("wait", ms, **kw)

    def exit(self, timeout: float = 60, **kw) -> Result:
        """Take the nearest level exit. On arrival in a new place, learn the edge."""
        here = self.scan(50)
        before = here.get("place", "?")
        r = self._intent("exit", timeout=timeout, **kw)
        if r.ok:
            after = self.arrived(90)
            acc = getattr(self, "last_accept", {}) or {}
            via = {"kind": "exit", "exit_x": round(acc.get("ux", acc.get("gx", 0))), "exit_y": round(acc.get("uy", acc.get("gy", 0))),
                   "stand_x": round(acc.get("ax", 0)), "stand_y": round(acc.get("ay", 0))}
            new = after != "?" and not known_edge(before, after)
            r.event = dict(r.event, place_from=before, place_to=after, new_edge=new,
                           learned=learn_edge(before, after, via, self.run_id) if new and self.explore else False)
            self.game.note("pilot_travel", place_from=before, place_to=after, new_edge=new,
                           learned=r.event["learned"], explore=self.explore, graph=graph_revision())
        return r

    def travel(self, place: str, x=None, y=None, timeout: float = 120, **kw) -> Result:
        """path_to(level, point): reach `place` through the travel graph, then (x, y) on it.
        A transition the graph does not know is no_route, returned at once; the bot never
        wanders in search of one. Exploration runs use exit() to learn new edges."""
        here = self.scan(50).get("place", "?")
        if here != place:
            if not known_edge(here, place):
                r = Result("no_route", f"no known transition {here} -> {place} (travel graph {graph_revision()})",
                           "travel", "")
                return self._done(r)
            r = self.exit(timeout=timeout, **kw)
            if not r.ok:
                return r
            if r.event.get("place_to") != place:
                return self._done(Result("failed", f"the exit led to {r.event.get('place_to')}, not {place}",
                                         "travel", r.id, event=r.event))
            if x is None:
                return r
        if x is None:
            return self._done(Result("done", "already there", "travel", ""))
        return self.path_to(x, y, **kw)

    def arrived(self, timeout: float = 90) -> str:
        """After a level change: wait for the new level's heartbeat, then for the player to
        spawn (scan answers), and return the new place."""
        start = len(self.game.gl)
        end = time.time() + timeout
        while time.time() < end:
            self.game.pump()
            if any(o.get("ev") == "hb" and o.get("phase") in ("mission", "town") for o in self.game.gl[start:]):
                sc = self.scan(50)
                if sc.get("ok"):
                    return sc.get("place", "?")
            time.sleep(0.5)
        return "?"

    # ---- eyes and control (immediate) --------------------------------------

    def scan(self, radius=300) -> dict:
        return self.cmd("scan", radius)

    def status(self) -> dict:
        return self.cmd("pilot", "status")

    def pause(self) -> dict:
        return self.cmd("pilot", "pause")

    def resume(self) -> dict:
        return self.cmd("pilot", "resume")

    def step(self, frames=1) -> dict:
        return self.cmd("pilot", "step", frames)

    def target(self, unit) -> dict:
        return self.cmd("pilot", "target", unit)

    def stop(self) -> dict:
        return self.cmd("pilot", "stop")

    def reflex(self, potion=None, fire=None) -> dict:
        """Standing orders the engine runs every frame, in and between intents (no round trip):
        potion=<hp%> drinks below it, fire=<radius> aims and fires at the nearest enemy.
        "off" (or 0) turns one off; None leaves it as is."""
        args = [f"{k}={'off' if not v or v == 'off' else v}" for k, v in (("potion", potion), ("fire", fire))
                if v is not None]
        return self.cmd("pilot", "reflex", *args)

    def state(self) -> dict:
        return self.cmd("state")

    def start(self, intent: str, *args, until=(), timeout: float = 30) -> dict:
        """Non-blocking: send an intent and return the accept reply (for pause/step/target)."""
        names = check_until(until)
        extra = [f"until={','.join(names)}"] if names else []
        return self.cmd("pilot", intent, *args, *extra, f"timeout={int(timeout * 1000)}")

    def wait_end(self, cid: str, timeout: float = 30) -> Result:
        obj = self.game.wait_gl(lambda o: o.get("ev") == "pilot" and o.get("id") == cid, timeout)
        if obj is None:
            return self._done(Result("timeout", "no end event", "", cid))
        return self._done(Result(obj["result"], obj.get("reason", ""), obj.get("intent", ""), cid, obj.get("tick"), obj))
