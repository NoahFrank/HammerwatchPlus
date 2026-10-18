"""Inner GameLab runner: materialize the scenario's fixture, run its steps, score them.
Started by gamelab/launcher.py on the hidden desktop after preflight; never run directly
on the user's desktop.

    python -m gamelab.runner <scenario.json> <results dir> --mode lab

Writes <results>/inner.json (assertions, fixture, live verification) and gl.jsonl.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import time
import traceback
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))
from gamelab import env, hps, logparse, loot, winproc  # noqa: E402
from gamelab.session import Game, GameError  # noqa: E402
from gamelab import pilot as pilotlib  # noqa: E402
import pin_build  # noqa: E402

FIXTURES = REPO / "gamelab" / "fixtures"
CACHE = FIXTURES / "cache"


class RunTimeout(GameError):
    """The scenario ran past its own deadline: verdict TIMEOUT, not FAIL."""


def dotted(obj, path: str):
    """Resolve "a.b.0.c" through dicts and lists; a KeyError instance when missing."""
    for part in path.split("."):
        if isinstance(obj, list) and part.isdigit() and int(part) < len(obj):
            obj = obj[int(part)]
        elif isinstance(obj, dict) and part in obj:
            obj = obj[part]
        else:
            return KeyError(path)
    return obj


def check(reply: dict, expect: dict) -> list[str]:
    """Mismatches between a [GL] reply and {dotted.path: value}. A value {"between": [lo, hi]}
    matches any number in that closed range (positions of units that move on their own)."""
    bad = []
    for path, want in expect.items():
        got = dotted(reply, path)
        if isinstance(want, dict) and "between" in want:
            lo, hi = want["between"]
            if not isinstance(got, (int, float)) or not lo <= got <= hi:
                bad.append(f"{path}: want {lo}..{hi}, got {'<missing>' if isinstance(got, KeyError) else repr(got)}")
            continue
        if isinstance(got, KeyError) or got != want:
            bad.append(f"{path}: want {want!r}, got {'<missing>' if isinstance(got, KeyError) else repr(got)}")
    return bad


class Run:
    def __init__(self, scenario: dict, results: Path, mode: str):
        self.scenario, self.results, self.mode = scenario, results, mode
        self.assertions: list[dict] = []
        self.passes = 0
        self.live: list[dict] = []
        self.game: Game | None = None        # the running game, finished by run() whatever happens
        self.out: dict = {}                     # inner.json, rewritten after every assertion
        self.menu: dict | None = None           # the probe's reply at the main menu (probe_menu)
        self.recipe: dict = {}
        self.extra: list[str] = []
        # the launcher kills the runner at 3x the scenario timeout; stop ourselves first so a
        # timeout still reports what it collected
        self.deadline = time.time() + scenario.get("timeout", 300) * 3 - 30

    def assert_(self, name: str, ok: bool, detail: str = "") -> bool:
        self.assertions.append({"name": name, "ok": bool(ok), "detail": detail})
        print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}", flush=True)
        self.flush()
        return ok

    def flush(self, final: bool = False) -> None:
        """Write inner.json now, so a killed runner still leaves what it collected."""
        out = dict(self.out, assertions=self.assertions, live=self.live, passes=self.passes,
                   menu=self.menu, partial=not final)
        tmp = self.results / "inner.json.tmp"
        tmp.write_text(json.dumps(out, indent=1, default=repr), encoding="utf-8")
        tmp.replace(self.results / "inner.json")

    # ---- one boot of the game ----------------------------------------------

    def boot(self, expect_mods: bool, probe_menu: bool = False) -> Game:
        self.passes += 1
        game = Game(self.results, self.mode)
        self.game = game
        game.start()
        try:
            if not game.wait_log("Started menu level", 90):
                raise GameError("main menu never loaded")
            live = game.verify_live()
            self.live.append(live)
            if not (live["image_in_gamelab"] and live["known_folder_hooked"]
                    and (self.mode != "lab" or (live["in_job"] and live["child_of_runner"]))):
                raise GameError(f"live process not isolated: {live}")
            time.sleep(1.0)
            if probe_menu:
                # the menu side of the menu -> session boundary: does the probe answer here?
                try:
                    self.menu = game.gl_cmd("ping", timeout=8)
                except GameError as e:
                    self.menu = {"error": str(e)}
                game.note("menu_probe", reply=self.menu)
            # main menu -> Singleplayer / Continue. A posted Enter can be lost in watch mode
            # (20261017-195821 and -200812: no "Starting session" ever followed it while the
            # human was using other windows), so it is confirmed in the log and re-sent
            for attempt in range(3):
                game.key("enter")
                end, started = time.time() + 5, False
                while not started and time.time() < end:
                    started = bool(re.search(r"\] Starting session\s*$", game.read_log(), re.M))
                    time.sleep(0.25)
                if started:
                    break
                game.note("enter_lost", attempt=attempt + 1)
            if expect_mods:
                if game.wait_gl(lambda o: o.get("ev") == "boot", 60) is None:
                    raise GameError("gamelab-probe never booted (mods not enabled, or a script error)")
            elif not game.wait_log("SHOWING PickCharacterWindow", 60):
                raise GameError("session never reached PickCharacterWindow")
        except GameError as e:
            # a mod compile error stops every mod script, the probe included: name it
            errors = logparse.errors_in(game.read_log())
            self.finish(game)                      # stop the game, keep its logs, assert its exit
            raise GameError(f"{e}" + (f"; script errors: {'; '.join(errors[:5])}" if errors else "")) from None
        return game

    def finish(self, game: Game) -> None:
        code = game.stop()
        logs = self.results / "logs"
        logs.mkdir(exist_ok=True)
        shutil.copy2(game.log_path, logs / f"pass{self.passes}.HWR2.exe.log")
        shim = game.game_dir / "gamelab_capture.log"
        if shim.exists():
            shutil.copy2(shim, logs / f"pass{self.passes}.shim.log")
        game.close()
        self.game = None
        self.assert_(f"pass {self.passes} exited cleanly", code == 0, f"exit code {code}")

    # ---- fixtures ------------------------------------------------------------

    def materialize(self, name: str) -> dict:
        recipe = json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))
        build = pin_build.live()["build_id"]
        # a changed recipe is a different fixture
        digest = hashlib.sha256(json.dumps(recipe, sort_keys=True).encode()).hexdigest()[:8]
        cache = CACHE / f"{name}.{build}.{digest}"
        saves = env.GAME / "saves"
        info = {"name": name, "cache_key": cache.name, "recipe": recipe}
        if recipe.get("slot", 0) != 0:
            raise GameError("lab profile uses g_save_slot 0; fixture slots other than 0 are not supported")
        if saves.exists():
            shutil.rmtree(saves)
        if cache.is_dir() and any(cache.glob("*.hps")):
            shutil.copytree(cache, saves)
            info["cache"] = "hit"
            return info
        info["cache"] = "miss"
        # pass 1: the game writes a fresh, empty profile (null-save session, then a clean quit)
        game = self.boot(expect_mods=False)
        self.finish(game)
        save = hps.current_save(0, saves)
        if save is None:
            raise GameError("pass 1 wrote no profile")
        # the one binary edit the game cannot do in-game: enable the GameLab mods
        mods = recipe["binary_edits"]["enable_mods"]
        hps.enable(save, mods)
        # pass 2: create the character with the game's own functions, let it reach town, quit
        game = self.boot(expect_mods=True)
        ch = recipe["character"]
        # the character menu has to be up: `char` sent on the boot line, before the first
        # heartbeat, answered "no local player record" (fixture-ranger 20261017-163135)
        if game.wait_gl(lambda o: o.get("ev") == "hb" and o.get("phase") == "no_character", 60) is None:
            raise GameError("the character menu never came up (no 'no_character' heartbeat)")
        reply = game.gl_cmd("char", ch["class"], ch["name"])
        if not reply.get("ok"):
            raise GameError(f"char failed: {reply}")
        if game.wait_gl(lambda o: o.get("ev") == "hb" and o.get("phase") == "town", 60) is None:
            raise GameError("new character never reached town")
        # recipe "setup": more fixture verbs (gamelab-hands; each mirrors a game path), then
        # the game's own save, so the next session loads this town and not a null one
        for v in recipe.get("setup", []):
            reply = game.gl_cmd(v["verb"], *v.get("args", []))
            bad = check(reply, v.get("expect", {"ok": True}))
            if bad:
                raise GameError(f"fixture setup {v['verb']} failed: {'; '.join(bad)}")
        if recipe.get("setup") or recipe.get("save_town"):
            if not game.gl_cmd("save").get("ok"):
                raise GameError("fixture save failed")
        self.finish(game)
        if cache.exists():
            shutil.rmtree(cache)
        shutil.copytree(saves, cache)
        return info

    def enter_fixture(self, recipe: dict, extra_mods: list[str]) -> Game:
        game = self.boot(expect_mods=True, probe_menu=self.scenario.get("probe_menu", False))
        hb = game.wait_gl(lambda o: o.get("ev") == "hb", 30)
        self.out.setdefault("first_frame_at", time.time())   # watch mode's focus window ends here
        if self.mode == "watch":
            # from here on a human click may activate the game window (WS_EX_NOACTIVATE off)
            game.note("allow_activation", **winproc.allow_activation(game.window()))
        if hb and hb.get("phase") == "no_character":
            reply = game.gl_cmd("pick", 0)
            if not reply.get("ok"):
                raise GameError(f"pick failed: {reply}")
        if game.wait_gl(lambda o: o.get("ev") == "hb" and o.get("phase") == recipe["readback"]["phase"], 60) is None:
            raise GameError(f"never reached phase {recipe['readback']['phase']}")
        # every recipe field is read back through the probes; a mismatch fails the run
        # recipe fields beyond the character (setup verbs) are read back through their own
        # probes; all of them, `state` and `mods` in one or two typed lines (gl_multi)
        probes = recipe.get("readback_probes", [])
        replies = game.gl_multi([["state"]] + [[rb["verb"], *rb.get("args", [])] for rb in probes] + [["mods"]])
        state, mods = replies[0], replies[-1]
        bad = check(state, recipe["readback"])
        for rb, reply in zip(probes, replies[1:-1]):
            bad += [f"{rb['verb']}: {b}" for b in check(reply, rb["expect"])]
        self.assert_("fixture readback", not bad, "; ".join(bad))
        enabled = sorted(m["id"] for m in mods.get("mods", []) if m.get("enabled"))
        want = sorted(recipe["binary_edits"]["enable_mods"] + extra_mods)
        self.assert_("enabled mods are exactly the fixture's + the scenario's", enabled == want, f"enabled={enabled}")
        # preflight assertion 3: the profile actually loaded, read from the running game.
        # Every numeric / boolean cvar of the profile (false/true = 0/1); v_resolution is
        # checked on the captured frame size instead (the shot steps).
        profile = env.cvars((env.SETTINGS / self.mode / "HWR2.exe.cfg").read_text())
        want = {}
        for k, v in profile.items():
            v = {"false": "0", "true": "1"}.get(v.lower(), v)
            try:
                want[k] = float(v)
            except ValueError:
                pass
        loaded = game.gl_cmd("cvars", *want).get("cvars", {})
        wrong = [f"{k}={loaded.get(k)} (profile {want[k]})" for k in want
                 if loaded.get(k) is None or abs(loaded[k] - want[k]) > 1e-3]
        muted = all(loaded.get(k) == 0 for k in want if k.startswith("snd_volume"))
        self.assert_(f"{self.mode} profile loaded ({len(want)} cvars)" + (" (muted, low graphics)" if self.mode == "lab" else ""),
                     not wrong and (self.mode != "lab" or muted), "; ".join(wrong))
        if bad:
            raise GameError("fixture readback failed")
        return game

    # ---- scenario ------------------------------------------------------------

    def step(self, game: Game, s: dict, saved: dict) -> Game:
        """Run one step; returns the game (a new one after "restart")."""
        if time.time() > self.deadline:
            raise RunTimeout(f"scenario deadline passed before step {s}")
        kind = s["do"]
        if kind == "restart":
            # save -> load context boundary: quit (WM_CLOSE, the game saves) and enter again
            self.finish(game)
            return self.enter_fixture(self.recipe, self.extra)
        if kind == "overlays":
            # repro playbook 1.3: everything drawn over the world, required empty or expected
            reply = game.gl_cmd("overlays")
            if "save_as" in s:
                saved[s["save_as"]] = reply
            allow = s.get("allow", {})
            extra = [f"window {w}" for w in reply.get("windows", []) if w not in allow.get("windows", [])]
            if reply.get("tutorial") and reply["tutorial"] not in allow.get("tutorial", []):
                extra.append(f"tutorial {reply['tutorial']}")
            extra += [f"announce {a.get('style')}: {a.get('text')!r}" for a in reply.get("announces", [])
                      if a.get("style") not in allow.get("announce_styles", [])]
            if reply.get("bossBar") and not allow.get("bossBar"):
                extra.append("boss bar")
            seen = json.dumps({k: reply.get(k) for k in ("windows", "tutorial", "announces", "bossBar")})
            self.assert_(s.get("name", "overlays empty or expected"), bool(reply.get("ok")) and not extra,
                         ("; ".join(extra) + " | " if extra else "") + seen)
            return game
        if kind == "loot_check":
            # what the loot is, without a seeded RNG: the gain must be one the table can produce
            before = dotted(saved.get(s["than"], {}), s.get("path", "materials"))
            after = dotted(saved.get(s["now"], {}), s.get("path", "materials"))
            gained = ({k: after[k] - before.get(k, 0) for k in after}
                      if isinstance(after, dict) and isinstance(before, dict) else {})
            ok, why = loot.explain(loot.table(s["file"], s["entry"]), gained) if gained else (False, "no before/after replies")
            shown = {k: v for k, v in gained.items() if v}
            self.assert_(s.get("name", f"loot fits {s['entry']}"), ok, f"gained {shown}; {why}")
            return game
        if kind == "gl":
            reply = game.gl_cmd(s["verb"], *s.get("args", []), timeout=s.get("timeout", 15))
            if "save_as" in s:
                saved[s["save_as"]] = reply
            if "expect" in s:
                bad = check(reply, s["expect"])
                self.assert_(s.get("name", f"gl {s['verb']}"), not bad, "; ".join(bad))
        elif kind == "pilot":
            # one blocking Pilot intent (gamelab/pilot.py); its Result is checked like a reply
            p = pilotlib.Pilot(game, self.results.name, explore=bool(self.scenario.get("explore")))
            fn = getattr(p, s["call"])
            kw = {k: s[k] for k in ("until", "timeout") if k in s}
            r = fn(*s.get("args", []), **kw)
            got = r if isinstance(r, dict) else {"result": r.result, "reason": r.reason, "tick": r.tick,
                                                 "intent": r.intent, "event": r.event}
            if "save_as" in s:
                saved[s["save_as"]] = got
            if "expect" in s:
                bad = check(got, s["expect"])
                self.assert_(s.get("name", f"pilot {s['call']}"), not bad, "; ".join(bad) + f" | {got.get('result')}: {got.get('reason')}")
        elif kind == "bot":
            # a bot script (gamelab/bots/<bot>.py, run(pilot) -> dict), loaded fresh from disk;
            # "name" is the assertion's label
            p = pilotlib.Pilot(game, self.results.name, explore=bool(self.scenario.get("explore")))
            got = pilotlib.load_bot(s["bot"]).run(p, **s.get("kwargs", {}))
            got["intents"] = [{"intent": r.intent, "result": r.result, "reason": r.reason, "tick": r.tick} for r in p.log]
            if "save_as" in s:
                saved[s["save_as"]] = got
            bad = check(got, s.get("expect", {}))
            self.assert_(s.get("name", f"bot {s['bot']}"), not bad, "; ".join(bad) + f" | {got.get('terminal')}")
        elif kind == "write_bot_file":
            # a bot revision while the game runs; restored in run()'s finally like write_mod_file
            f = pilotlib.BOTS / s["path"]
            if f.parent.resolve() != pilotlib.BOTS.resolve():
                raise GameError(f"write_bot_file: {s['path']} is not directly in gamelab/bots/")
            self.written.setdefault(f, f.read_bytes() if f.is_file() else None)
            f.write_text(f.read_text(encoding="utf-8").replace(s["replace"], s["with"]), encoding="utf-8")
            self.assert_(s.get("name", f"edited gamelab/bots/{s['path']}"), s["with"] in f.read_text(encoding="utf-8"))
        elif kind == "same_process":
            # {"mark": m} records the game's pid; {"since": m} asserts it is still that process
            # (a revision taken live, no restart in between)
            if "mark" in s:
                saved[s["mark"]] = {"ok": True, "pid": game.proc.pid, "pass": self.passes}
            else:
                was = saved.get(s["since"], {})
                self.assert_(s.get("name", "same game process, no restart"),
                             was.get("pid") == game.proc.pid and was.get("pass") == self.passes,
                             f"pid {was.get('pid')} -> {game.proc.pid}, pass {was.get('pass')} -> {self.passes}")
        elif kind == "wait_phase":
            hb = game.wait_gl(lambda o: o.get("ev") == "hb" and o.get("phase") == s["phase"], s.get("timeout", 60))
            self.assert_(f"phase {s['phase']}", hb is not None)
        elif kind == "shot":
            png = game.shot(s["name"], settle=s.get("settle", True))
            # a real frame (not blank), at the profile's v_resolution (preflight assertion 3's
            # one non-cvar setting is checked here, on the captured frame)
            res = env.cvars((env.SETTINGS / self.mode / "HWR2.exe.cfg").read_text()).get("v_resolution", "")
            size = frame_size(png) if png else None
            want = tuple(int(v) for v in res.split("x")) if "x" in res else size
            self.assert_(f"shot {s['name']}", png is not None and colours(png) > 64 and size == want,
                         f"{png.name if png else 'none'} colours={colours(png) if png else 0} size={size} want={want}")
        elif kind == "shot_diff":
            # passive capture tracks game state: between two shots of the same view, the pixels
            # that changed sit in `box` (fractions of the frame: x0, y0, x1, y1) far more densely
            # than anywhere else
            from PIL import Image, ImageChops
            shots = self.results / "shots"
            a = Image.open(shots / f"{s['before']}.png").convert("L")
            b = Image.open(shots / f"{s['after']}.png").convert("L")
            from PIL import ImageFilter
            mask = ImageChops.difference(a, b).point(lambda v: 255 if v > s.get("threshold", 40) else 0)
            # ambient animation (foliage sway) changes scattered single pixels; a min filter
            # (erosion) drops those and keeps solid regions such as a new sprite
            if s.get("denoise", 3):
                mask = mask.filter(ImageFilter.MinFilter(s.get("denoise", 3)))
            w, h = mask.size
            x0, y0, x1, y1 = s["box"]
            box = (int(x0 * w), int(y0 * h), int(x1 * w), int(y1 * h))
            inside = sum(1 for v in mask.crop(box).getdata() if v)
            total = sum(1 for v in mask.getdata() if v)
            area_in = (box[2] - box[0]) * (box[3] - box[1])
            dens_in, dens_out = inside / area_in, (total - inside) / max(1, w * h - area_in)
            ok = inside >= s.get("min_px", 50) and dens_in > s.get("ratio", 10) * dens_out
            self.assert_(s.get("name", f"shot diff {s['before']} -> {s['after']}"), ok,
                         f"changed px inside={inside} outside={total - inside}; density in={dens_in:.4f} out={dens_out:.5f}")
        elif kind == "shot_changed":
            # the renderer agrees with telemetry that the view changed (a new level): most of
            # the frame differs between two shots. Named "shot ...", so a failure while every
            # probe passed makes the run INVALID, not FAIL. Calibrated on 41 pilot-crosslevel runs
            # (luminance diff > 10 on a 160x90 thumbnail): 68-82% of the frame changes when the
            # floor changed; 9-14% when the bot never left floor 0; <= 19% between two shots of
            # one floor
            from PIL import Image, ImageChops
            shots = self.results / "shots"
            a = Image.open(shots / f"{s['before']}.png").convert("L").resize((160, 90))
            b = Image.open(shots / f"{s['after']}.png").convert("L").resize((160, 90))
            changed = sum(1 for v in ImageChops.difference(a, b).getdata() if v > s.get("threshold", 10)) / (160 * 90)
            self.assert_(f"shot changed {s['before']} -> {s['after']}", changed >= s.get("min_frac", 0.4),
                         f"{changed:.0%} of the frame changed, want >= {s.get('min_frac', 0.4):.0%}")
        elif kind == "shot_tint":
            # the engine's nav overlay paints a red grid: the share of strongly red pixels
            # (R exceeds G and B by 50, 160x90 thumbnail) is <= 0.007 on plain town and
            # mission frames and 0.116-0.49 with r_draw_nav_data on (watch-overlays
            # 20261017-190809, floor-soak cut-nav). Frame-to-frame change cannot tell: two
            # plain town frames 0.5 s apart differ in 31% of pixels. Named "shot ...": a
            # failure while the cvars read back on is INVALID
            from PIL import Image
            px = list(Image.open(self.results / "shots" / f"{s['shot']}.png").convert("RGB").resize((160, 90)).getdata())
            red = sum(1 for r, g, b in px if r > g + 50 and r > b + 50) / len(px)
            lo, hi = s.get("min", 0.0), s.get("max", 1.0)
            self.assert_(f"shot tint {s['shot']}", lo <= red <= hi, f"red share {red:.3f}, want {lo}-{hi}")
        elif kind == "assert_more":
            # the numeric values under `path` sum higher in reply `now` than in reply `than`
            # ("now_path" reads `now` at a different path, e.g. a pilot Result's end event)
            def total(name, path):
                v = dotted(saved.get(name, {}), path)
                return sum(x for x in v.values() if isinstance(x, (int, float))) if isinstance(v, dict) else v
            before, after = total(s["than"], s["path"]), total(s["now"], s.get("now_path", s["path"]))
            ok = isinstance(before, (int, float)) and isinstance(after, (int, float)) and after > before
            self.assert_(s.get("name", f"{s['path']} grew"), ok, f"{s['than']}={before} {s['now']}={after}")
        elif kind == "assert_dist":
            # distance between the {x, y} under `path` in replies `a` and `b`, within [min, max]
            pa, pb = dotted(saved.get(s["a"], {}), s["path"]), dotted(saved.get(s["b"], {}), s["path"])
            d = (((pa["x"] - pb["x"]) ** 2 + (pa["y"] - pb["y"]) ** 2) ** 0.5
                 if isinstance(pa, dict) and isinstance(pb, dict) else None)
            ok = d is not None and s.get("min", 0) <= d <= s.get("max", float("inf"))
            self.assert_(s.get("name", f"{s['path']} moved {s.get('min', 0)}..{s.get('max')}"), ok,
                         f"distance {None if d is None else round(d, 1)}")
        elif kind == "sval":
            # datatable export: the engine's parse of one .sval, written as sorted, indented JSON.
            # Multi-entry files are one resource per "<file>:<entry>" (tools/export_datatables.py).
            if "entries" in s:
                data, missing = {}, []
                for e in s["entries"]:
                    reply = game.gl_cmd("sval", f"{s['file']}:{e}", timeout=s.get("timeout", 30))
                    if reply.get("ok"):
                        data[e] = json.loads(reply["chunk"])
                    else:
                        missing.append(e)
                ok = bool(data) and not missing
                error = f"entries the engine does not have: {missing}" if missing else "no entries"
            else:
                reply = game.gl_cmd("sval", s["file"], timeout=s.get("timeout", 30))
                ok = bool(reply.get("ok"))
                data = json.loads(reply["chunk"]) if ok else None
                error = reply.get("error")
            if ok:
                out = Path(s["dest"]) / (s["file"] + ".json")
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text(json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
            saved.setdefault("sval", {})[s["file"]] = "ok" if ok else error
        elif kind == "write_mod_file":
            # an edit made while the game runs (the reload-mark scenario). GameLab mods only;
            # the original bytes go back in run()'s finally, whatever happens.
            if not s["mod"].startswith("gamelab-"):
                raise GameError("write_mod_file is limited to gamelab-* mods")
            f = REPO / "mods" / s["mod"] / s["path"]
            if f.resolve().parent != f.parent.resolve() or (REPO / "mods" / s["mod"]) not in f.parents:
                raise GameError(f"write_mod_file: {s['path']} escapes mods/{s['mod']}")
            self.written.setdefault(f, f.read_bytes() if f.is_file() else None)
            f.write_text(f.read_text(encoding="utf-8").replace(s["replace"], s["with"]), encoding="utf-8")
            self.assert_(s.get("name", f"edited mods/{s['mod']}/{s['path']}"), s["with"] in f.read_text(encoding="utf-8"))
        elif kind == "log_has":
            # a regex in this pass's game log (e.g. a mod's self-check line), waited for
            rx = re.compile(s["pattern"])
            end = time.time() + s.get("timeout", 30)
            while not (hit := rx.search(game.read_log())) and time.time() < end:
                time.sleep(0.25)
            self.assert_(s.get("name", f"log has /{s['pattern']}/"), hit is not None, hit.group(0) if hit else "not found")
        elif kind == "log_lacks":
            # a regex that must not appear in this pass's game log (checked when the step runs)
            hits = [m.group(0) for m in re.finditer(s["pattern"], game.read_log())]
            self.assert_(s.get("name", f"log lacks /{s['pattern']}/"), not hits, "; ".join(hits[:5]))
        elif kind == "log_clean":
            # no script errors in files of the mods under test (the game's own baseline ERRs are ignored)
            bad = logparse.errors_in(game.read_log(), s.get("patterns", logparse.OURS))
            self.assert_(s.get("name", "no script errors in our files"), not bad, "; ".join(bad[:10]))
        elif kind == "printwindow":
            # OS-level capture of the hidden window, compared with the in-process frame taken
            # right after it: mean absolute difference per channel (0 = identical)
            from PIL import Image, ImageChops, ImageStat
            ref = game.shot(s.get("name", "printwindow") + "-ref")
            results = {}
            for flags in s.get("flags", [0, 2]):
                im = winproc.print_window(game.window(), flags)
                if im is None:
                    results[flags] = "PrintWindow failed"
                    continue
                im.save(self.results / "shots" / f"{s.get('name', 'printwindow')}-pw{flags}.png")
                r = Image.open(ref).convert("RGB").resize(im.size) if ref else None
                diff = sum(ImageStat.Stat(ImageChops.difference(im, r)).mean) / 3 if r else None
                results[flags] = {"colours": len(im.resize((64, 36)).getcolors(64 * 36)), "diff": diff}
            saved[s.get("save_as", "printwindow")] = results
            ok = any(isinstance(v, dict) and v["colours"] > 64 and v["diff"] is not None and v["diff"] < s.get("max_diff", 12)
                     for v in results.values())
            if s.get("want") == "blank":       # a pinned measurement: PrintWindow sees nothing here
                ok = all(isinstance(v, dict) and v["colours"] <= 4 for v in results.values()) and ref is not None
            self.assert_(s.get("name", "PrintWindow capture of the hidden window matches the frame"), ok, json.dumps(results))
        elif kind == "minimize":
            self.assert_("window minimized", winproc.minimize(game.window()))
        elif kind == "sleep":
            time.sleep(s["seconds"])
        elif kind == "key":
            game.key(s["key"], s.get("hold", 0.05))
        elif kind == "console":
            # a raw console line, as a human would type it in watch mode (cvars, the engine's
            # own debug draws); the effect is asserted by later steps, never assumed
            game.console(s["line"])
        else:
            raise GameError(f"unknown step {kind!r}")
        return game

    # ---- boundaries (repro playbook 3.1 / 3.2) ---------------------------------

    def boundaries(self, saved: dict) -> list[dict]:
        """The scenario's boundary rows, each probed on both sides: "before" and "after"
        name saved replies ("menu" is the main-menu probe). "survives" paths must be equal
        on both sides, "changes" paths must differ."""
        rows = []
        replies = dict(saved, menu=self.menu)
        for b in self.scenario.get("boundaries", []):
            before, after = replies.get(b["before"]), replies.get(b["after"])
            row = {k: b.get(k, "") for k in ("name", "kind", "copies", "reinit")}
            problems, cells = [], []
            for side, rep in (("before", before), ("after", after)):
                if not isinstance(rep, dict) or not rep.get("ok"):
                    problems.append(f"{side} side ({b[side]}) not probed: {rep}")
            for rule in ("survives", "changes"):
                for path in b.get(rule, []):
                    # "p" reads p on both sides; "p|q" reads p before and q after
                    pb, _, pa = path.partition("|")
                    x, y = dotted(before or {}, pb), dotted(after or {}, pa or pb)
                    x = None if isinstance(x, KeyError) else x
                    y = None if isinstance(y, KeyError) else y
                    cells.append({"path": path, "rule": rule, "before": x, "after": y})
                    if rule == "survives" and (x != y or x is None):
                        problems.append(f"{path} did not survive: {x!r} -> {y!r}")
                    if rule == "changes" and x == y:
                        problems.append(f"{path} did not change: {x!r}")
            row.update(cells=cells, ok=not problems)
            rows.append(row)
            self.assert_(f"boundary {b['name']}", not problems, "; ".join(problems))
        return rows

    def run(self) -> dict:
        self.written: dict[Path, bytes | None] = {}
        out = self.out = {"scenario": self.scenario["name"], "mode": self.mode,
                          "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
                          # the travel graph this run planned against (gamelab/travel/)
                          "travel_revision": pilotlib.graph_revision(),
                          "explore": bool(self.scenario.get("explore"))}
        try:
            fixture = self.materialize(self.scenario["fixture"])
            out["fixture"] = {k: fixture[k] for k in ("name", "cache_key", "cache")}
            # mods under test: enabled on top of the fixture's set, in this run's copy of the save
            extra = list(self.scenario.get("mods", []))
            if extra:
                hps.enable(hps.current_save(0, env.GAME / "saves"), fixture["recipe"]["binary_edits"]["enable_mods"] + extra)
                out["mods_under_test"] = extra
            self.recipe, self.extra = fixture["recipe"], extra
            game = self.enter_fixture(fixture["recipe"], extra)
            saved: dict = {}
            out["saved"] = saved
            for s in self.scenario["steps"]:
                game = self.step(game, s, saved)
            out["boundaries"] = self.boundaries(saved)
            out["travel_revision_end"] = pilotlib.graph_revision()
            # the renderer floor (repro playbook 1.2): every run ends on one readable frame. A
            # minimized window presents nothing, so it is restored (not activated) first
            if winproc.restore_noactivate(game.window()):
                out["restored_for_end_shot"] = True
                time.sleep(0.3)
            self.step(game, {"do": "shot", "name": "end"}, saved)
        except Exception as e:                     # noqa: BLE001 - every failure is a result
            out["timeout"] = isinstance(e, RunTimeout)
            out["error"] = f"{type(e).__name__}: {e}"
            out["traceback"] = traceback.format_exc()
            print(out["traceback"], flush=True)
        finally:
            if self.game is not None:
                self.finish(self.game)
            for f, data in self.written.items():
                if data is None:
                    f.unlink(missing_ok=True)
                else:
                    f.write_bytes(data)
        self.flush(final=True)
        return json.loads((self.results / "inner.json").read_text(encoding="utf-8"))


def frame_size(png: Path) -> tuple[int, int]:
    from PIL import Image
    with Image.open(png) as im:
        return im.size


def colours(png: Path) -> int:
    from PIL import Image
    im = Image.open(png).convert("RGB").resize((64, 36))
    return len(im.getcolors(64 * 36))           # 64x36 has at most 2304 colours


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenario")
    ap.add_argument("results")
    ap.add_argument("--mode", choices=("lab", "watch"), required=True)
    a = ap.parse_args(argv)
    results = Path(a.results)
    results.mkdir(parents=True, exist_ok=True)
    scenario = json.loads(Path(a.scenario).read_text(encoding="utf-8"))
    out = Run(scenario, results, a.mode).run()
    return 0 if "error" not in out and all(x["ok"] for x in out["assertions"]) else 1


if __name__ == "__main__":
    sys.exit(main())
