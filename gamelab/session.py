"""One running GameLab game: start, drive, observe, stop. Runs *inside* the hidden desktop
(gamelab/launcher.py starts it there through tools/hidden_desktop.py), so every window
the game makes is born off the user's screen.

Measured on build 25509441 (docs/RE_NOTES.md 2026-10-17):
- HWR2.exe reads HWR2.exe.cfg and writes HWR2.exe.log and saves/ next to the exe it was
  started from, so the GameLab game dir (gamelab/env.py) is a complete sandbox for those.
- The game resolves %LOCALAPPDATA% (its save_backups/) with SHGetKnownFolderPath, not the
  environment, so the exe starts suspended and tools/bin/hwr2_capture.dll is injected
  before its first instruction; the shim answers FOLDERID_LocalAppData with
  GAMELAB_LOCALAPPDATA (= the game dir's appdata/). The same shim does frame capture.
- Main menu -> Singleplayer/Continue is VK_RETURN posted to the SDL window; the console
  opens on VK_OEM_3 (0xC0) and takes WM_CHAR text. Mod modules are
  constructed at the menu but tick only once a session starts.
"""
from __future__ import annotations

import ctypes
import json
import os
import re
import subprocess
import sys
import time
from ctypes import wintypes
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from gamelab import env, winproc  # noqa: E402

SHIM = REPO / "tools" / "bin" / "hwr2_capture.dll"
GL_LINE = re.compile(r"\[GL\] (\{.*\})\s*$")
ECHO_LINE = re.compile(r"> gl (c\d+) ")       # the console echoes every line it executes
WM_CLOSE = 0x0010


class GameError(RuntimeError):
    pass


class Game:
    def __init__(self, results: Path, mode: str = "lab"):
        self.results = results
        self.mode = mode
        self.game_dir = env.GAME
        self.log_path = self.game_dir / "HWR2.exe.log"
        self.proc: subprocess.Popen | None = None
        self.hwnd = None
        self.t0 = time.time()
        self._log_pos = 0
        self._log_tail = ""
        self.gl: list[dict] = []          # every [GL] object seen, in order
        self.echoed: set[str] = set()     # gl ids the console echoed (it received the line)
        self._gl_seen_at_cmd = 0          # len(self.gl) then (a "boot" since = a level load)
        self.events = open(results / "gl.jsonl", "a", encoding="utf-8")
        self._next_id = 0

    # ---- lifecycle --------------------------------------------------------

    def start(self) -> None:
        env.write_profile(self.mode)
        for f in (self.log_path, self.game_dir / "gamelab_capture.log", self.game_dir / "gamelab_capture.req"):
            f.unlink(missing_ok=True)
        appdata = self.game_dir / "appdata"
        appdata.mkdir(exist_ok=True)
        child_env = dict(os.environ, GAMELAB_LOCALAPPDATA=str(appdata))
        if self.mode == "watch":
            # the shim makes SDL's window non-activating until the first frame, and refuses
            # SDL's activating calls whenever another process owns the foreground (focus gate:
            # docs/RE_NOTES.md 2026-10-17 "watch-mode focus")
            child_env["GAMELAB_NO_ACTIVATE"] = "1"
        self.proc = subprocess.Popen([str(self.game_dir / "HWR2.exe")], cwd=str(self.game_dir),
                                     env=child_env, creationflags=winproc.CREATE_SUSPENDED)
        injected = winproc.inject(self.proc, str(SHIM))
        winproc.resume(self.proc)
        self.note("start", pid=self.proc.pid, injected=injected)
        if not injected:
            raise GameError("could not inject tools/bin/hwr2_capture.dll")

    def verify_live(self) -> dict:
        """Preflight 4, read off the running process rather than the intent: the image it
        runs, the shim's hooks, and the cvars the game reports it loaded."""
        image = process_image(self.proc.pid)
        shim = self.shim_log()
        out = {"image": image,
               "image_in_gamelab": Path(image).resolve() == (self.game_dir / "HWR2.exe").resolve(),
               "known_folder_hooked": "SHGetKnownFolderPath hooked" in shim,
               "swap_hooked": "SwapBuffers hooked" in shim,
               # lab mode: the game is inside the hidden-desktop job (tools/hidden_desktop.py) and a
               # child of this runner, so closing the job kills it whatever happens
               "in_job": in_job(self.proc.pid),
               "child_of_runner": os.getpid() in winproc.ancestors(self.proc.pid)}
        launch = re.search(r"Launch options: 1: (.+)", self.read_log())
        out["log_launch_path"] = launch.group(1).strip() if launch else None
        self.note("verify_live", **out)
        return out

    def stop(self, timeout: float = 30) -> int | None:
        """Graceful quit (WM_CLOSE: the game saves and exits 0), kill as the fallback."""
        if self.proc is None or self.proc.poll() is not None:
            return self.proc.returncode if self.proc else None
        if self.hwnd:
            winproc.u32.PostMessageW(self.hwnd, WM_CLOSE, 0, 0)
        try:
            code = self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            code = self.proc.wait(10)
            self.note("killed", after=timeout)
        self.pump()
        self.note("exit", code=code)
        return code

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    # ---- log --------------------------------------------------------------

    def read_log(self) -> str:
        return self.log_path.read_text(encoding="utf-8", errors="replace") if self.log_path.exists() else ""

    def shim_log(self) -> str:
        p = self.game_dir / "gamelab_capture.log"
        return p.read_text(errors="replace") if p.exists() else ""

    def pump(self) -> None:
        """Read new log lines; collect [GL] objects into gl.jsonl."""
        if not self.log_path.exists():
            return
        with open(self.log_path, "rb") as f:
            f.seek(self._log_pos)
            chunk = f.read()
        if not chunk:
            return
        text = self._log_tail + chunk.decode("utf-8", errors="replace")
        lines = text.split("\n")
        self._log_tail = lines.pop()          # partial last line, finished next pump
        self._log_pos += len(chunk)
        for line in lines:
            e = ECHO_LINE.search(line)
            if e:
                self.echoed.add(e.group(1))
                continue
            m = GL_LINE.search(line)
            if not m:
                continue
            try:
                obj = json.loads(m.group(1))
            except json.JSONDecodeError:
                obj = {"ev": "bad_json", "raw": m.group(1)}
            obj["_t"] = round(time.time() - self.t0, 3)
            # the next floor is preloaded in its own script context, which constructs every
            # mod module again; its lines carry "[preload]" (pilot-consumables 20261017-152746)
            if "[preload]" in line[:m.start()]:
                obj["_preload"] = True
            self.gl.append(obj)
            self.events.write(json.dumps(obj) + "\n")
        self.events.flush()

    def wait_log(self, text: str, timeout: float = 60) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            if text in self.read_log():
                return True
            if not self.alive():
                raise GameError(f"game exited (code {self.proc.returncode}) while waiting for {text!r}")
            time.sleep(0.25)
        return False

    def wait_gl(self, pred, timeout: float = 30, echo: str | None = None, beats: int = 0) -> dict | None:
        """The first [GL] object matching pred, or None after timeout. With echo=<id> and
        beats=n, also None once n heartbeats arrived and <id> was never echoed (the line did
        not reach the console), or once it was echoed (received; the reply may follow)."""
        end = time.time() + timeout
        seen = len(self.gl) if beats else 0
        start = seen
        while time.time() < end:
            self.pump()
            for obj in self.gl[seen:]:
                if pred(obj):
                    return obj
            seen = len(self.gl)
            if echo is not None and echo in self.echoed:
                return None
            if beats and sum(o.get("ev") == "hb" for o in self.gl[start:]) >= beats:
                return None
            if not self.alive():
                raise GameError(f"game exited (code {self.proc.returncode})")
            time.sleep(0.02)
        return None

    # ---- hands ------------------------------------------------------------

    def window(self, timeout: float = 30) -> int:
        end = time.time() + timeout
        while time.time() < end:
            self.hwnd = winproc.game_window(self.proc.pid)
            if self.hwnd:
                return self.hwnd
            time.sleep(0.2)
        raise GameError("no SDL_app window")

    def key(self, name: str, hold: float = 0.05) -> None:
        winproc.key(self.window(), winproc.VK[name], hold)
        self.note("key", key=name, hold=hold)

    # console() pauses, seconds: after opening the console, typing gap per char, before Enter,
    # after Enter, after closing; and key hold. The old fixed values (0.15/0.004/0.05/0.1/0.1,
    # hold 0.05 + 0.03 after each key) cost ~0.83 s per gl command; console-bench measures
    # what the game needs.
    CONSOLE_TIMING = {"open": 0.15, "gap": 0.004, "pre_enter": 0.05, "post_enter": 0.1,
                      "close": 0.1, "hold": 0.05}

    # The console key is read once per frame (~33 ms): opening, typing and closing inside one
    # frame cancel out and the line goes nowhere (console-bench 20261017-181238: every
    # zero-sleep first attempt left no trace in the log, not even the console's own open/close
    # lines, while a lone zero-hold press does toggle it: console-keys 20261017-181906). So
    # two frames after opening and after Enter. The console also slides shut over more than
    # 70 ms (console-trace 20261017-183130, shot mid-slide), and an opening key during the
    # slide is lost: with 70 ms after closing every second line vanished (console-bench
    # 20261017-182056/-182614), with 150 ms none of 90 did (-183226). That wait is kept
    # before the next opening key (CLOSE_SETTLE), not slept after every line.
    FAST_TIMING = {"open": 0.07, "gap": 0.0, "pre_enter": 0.0, "post_enter": 0.07,
                   "close": 0.0, "hold": 0.0}
    CLOSE_SETTLE = 0.15
    # the closed console keeps sliding out of view after CLOSE_SETTLE; a screenshot inside
    # this window shows the panel (blind observer, open-chest 20261017-190827). Measured by
    # console-slide 20261017-191646: in the frame right after the reply, gone 100 ms later
    SHOT_SETTLE = 0.25

    def console(self, line: str, already_open: bool = False, timing: dict | None = None) -> None:
        t = timing or getattr(self, "console_timing", None) or self.CONSOLE_TIMING
        h = self.window()
        settle = getattr(self, "_closed_at", 0.0) + self.CLOSE_SETTLE - time.time()
        if settle > 0:
            time.sleep(settle)
        if not already_open:
            winproc.key(h, winproc.VK["console"], t["hold"])
            time.sleep(t["open"])
        winproc.text(h, line, t["gap"])
        time.sleep(t["pre_enter"])
        winproc.key(h, winproc.VK["enter"], t["hold"])
        time.sleep(t["post_enter"])
        winproc.key(h, winproc.VK["console"], t["hold"])
        self._closed_at = time.time()
        time.sleep(t["close"])

    def gl_cmd(self, verb: str, *args, timeout: float = 15) -> dict:
        """Send `gl <id> <verb> args` and return its [GL] reply (raises on timeout)."""
        self._next_id += 1
        cid = f"c{self._next_id}"
        line = " ".join(["gl", cid, verb, *map(str, args)])
        # FAST_TIMING, except the first line after a level load, whose frames run long: the old
        # paced timing (770 ms) for that one
        loaded = any(o.get("ev") == "boot" for o in self.gl[self._gl_seen_at_cmd:])
        timing = getattr(self, "console_timing", None) or (self.CONSOLE_TIMING if loaded else self.FAST_TIMING)
        # a line the console never echoed although the game kept running (two heartbeats) did
        # not reach it: retype it paced, then once more without the opening key (in case the
        # console was left open, as by the level change in floor-soak 20261017-180322). Waiting
        # on heartbeats, not a fixed time, keeps a line whose echo is stuck behind a level
        # load's log flush from running twice.
        reply = None
        for attempt, already_open in enumerate((False, False, True)):
            if attempt:
                self.note("console_retype", id=cid, attempt=attempt, already_open=already_open)
            self.console(line, already_open=already_open, timing=timing if not attempt else self.CONSOLE_TIMING)
            reply = self.wait_gl(lambda o: o.get("id") == cid, timeout, echo=cid, beats=2)
            if reply is not None or cid in self.echoed:
                break
        if reply is None:
            reply = self.wait_gl(lambda o: o.get("id") == cid, timeout)
        self._gl_seen_at_cmd = len(self.gl)
        if reply is None:
            raise GameError(f"no reply to {line!r} within {timeout}s")
        if "of" in reply and reply.get("of", 1) > 1:
            # multipart (sval): collect every part, join the chunks in order
            end = time.time() + timeout
            while time.time() < end:
                self.pump()
                parts = {o["part"]: o for o in self.gl if o.get("id") == cid and "part" in o}
                if len(parts) == reply["of"]:
                    joined = dict(parts[0])
                    joined["chunk"] = "".join(parts[k]["chunk"] for k in range(reply["of"]))
                    return joined
                time.sleep(0.05)
            raise GameError(f"multipart reply to {line!r} incomplete within {timeout}s")
        return reply

    MULTI_LINE_MAX = 1500    # characters per typed line; 1985 answered whole (console-bench 20261017-183645)

    def gl_multi(self, cmds: list, timeout: float = 15) -> list[dict]:
        """Several commands in as few typed lines as fit: `gl <id> multi a + b + ...`, the
        probe answering each as <id>.<k>. Returns the replies in order. A sub-command may not
        change level (the rest of its line would run on the old one)."""
        out: list[dict] = []
        batch: list[list[str]] = []

        def flush():
            if not batch:
                return
            args: list[str] = []
            for c in batch:
                args += (["+"] if args else []) + c
            head = self.gl_cmd("multi", *args, timeout=timeout)
            cid = head["id"]
            for k in range(head.get("n", 0)):
                r = self.wait_gl(lambda o, i=f"{cid}.{k}": o.get("id") == i, timeout)
                if r is None:
                    raise GameError(f"multi {cid}: no reply {cid}.{k}")
                out.append(r)
            batch.clear()

        for verb, *args in cmds:
            c = [str(verb), *map(str, args)]
            if batch and len(" ".join(" ".join(b) for b in batch)) + len(" ".join(c)) + 3 * len(batch) > self.MULTI_LINE_MAX:
                flush()
            batch.append(c)
        flush()
        return out

    # ---- eyes -------------------------------------------------------------

    def shot(self, name: str, timeout: float = 10, settle: bool = True) -> Path | None:
        """In-process capture of the back buffer (the shim); PNG in results/shots/."""
        wait = getattr(self, "_closed_at", 0.0) + self.SHOT_SETTLE - time.time()
        if settle and wait > 0:
            time.sleep(wait)
        shots = self.results / "shots"
        shots.mkdir(exist_ok=True)
        bmp = shots / f"{name}.bmp"
        bmp.unlink(missing_ok=True)
        (self.game_dir / "gamelab_capture.req").write_text(str(bmp))
        end = time.time() + timeout
        while time.time() < end:
            if bmp.exists():
                from PIL import Image
                time.sleep(0.05)
                png = bmp.with_suffix(".png")
                Image.open(bmp).convert("RGB").save(png)
                bmp.unlink()
                self.note("shot", name=name, path=str(png.relative_to(self.results)))
                return png
            time.sleep(0.05)
        self.note("shot_failed", name=name)
        return None

    # ---- bookkeeping ------------------------------------------------------

    def note(self, ev: str, **kw) -> None:
        obj = {"ev": "harness." + ev, "_t": round(time.time() - self.t0, 3), **kw}
        self.events.write(json.dumps(obj) + "\n")
        self.events.flush()
        print(json.dumps(obj), flush=True)

    def close(self) -> None:
        self.events.close()


def in_job(pid: int) -> bool:
    """IsProcessInJob(process, NULL): is the process in any job object?"""
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    h = k32.OpenProcess(0x1000, False, pid)        # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    res = wintypes.BOOL()
    ok = k32.IsProcessInJob(h, None, ctypes.byref(res))
    k32.CloseHandle(h)
    return bool(ok and res.value)


def process_image(pid: int) -> str:
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    h = k32.OpenProcess(0x1000, False, pid)        # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return ""
    buf = ctypes.create_unicode_buffer(1024)
    size = wintypes.DWORD(1024)
    k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
    k32.CloseHandle(h)
    return buf.value
