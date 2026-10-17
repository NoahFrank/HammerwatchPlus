#!/usr/bin/env python3
"""
dev_check.py - boot HoH2 with the linked modules and harvest script problems.

The game has no standalone AngelScript compiler, so this launches HWR2.exe,
waits until the town has loaded (or a timeout), kills it, and parses
HWR2.exe.log for:

  * which mods were added (`Adding packed/unpacked mod '<id>'`)
  * script compile errors / warnings (`ERR : file (ln N, col M)`, `WARN : ...`)
  * runtime script exceptions and `[ERR]` lines that mention our files
  * `[HWP:...]` log lines from our own code

Exit status is non-zero when any error touches a HammerwatchPlus file.

    dev_check.py                 # link all modules, boot, report
    dev_check.py --no-link       # do not touch mods/ links first
    dev_check.py --timeout 120   # seconds before the game is killed
    dev_check.py --keep          # leave the game running
    dev_check.py --log-only      # parse the existing log, do not launch
    dev_check.py --no-enable     # do not patch the save's enabled-mod list first
    dev_check.py --level mines_boss battlements_1   # play these floors, report each

--level loads floors of a mission (--mission, default the HoH1 Forsaken
Tower that `import_hoh1.py campaign` generates) instead of stopping in town:
it writes the gitignored lang file DEV_LANG; you click Continue in the main
menu (or --press-continue focuses the game and clicks it), and the
dev-only devtools module starts the floor from town and logs
`[HWP:dev] level ready` a few seconds in. Every engine error and warning
logged after the floor started is listed (deduplicated), whoever's file it is.

The game runs on its own local save slot (--slot, default TEST_SLOT), never
the player's: the slot named in HWR2.exe.cfg is refused. The game picks the
profile from HWR2.exe.cfg before it reads command-line cvars, so for each run
the config is switched to the test slot and put back afterwards (a copy waits
in HWR2.exe.cfg.hwp-dev while the game runs and is restored first thing if a
run was interrupted). A new test profile gets a throwaway "HWP Test"
character from the devtools module; the first run on an empty slot only boots
to create the profile.

Which mods are enabled lives in the save file header (see tools/hps.py). When the
hash of a linked module's id is known (tools/mod_hashes.json) it is switched on
automatically; the core module prints every mod's hash so one run with core
enabled teaches the tool all the others.

Steam must be running (the game uses steam_api).
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from xml.sax.saxutils import escape
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402

READY_MARKERS = ("Resource load time:", "Creating sound engine")
TOWN_MARKER = "StartLoadMenu levels/town.lvl"
OUR_PATTERNS = (r"scripts/HWP/", r"hwp_", r"\[HWP:", r"HammerwatchPlus")
SCRIPT_ISSUE = re.compile(r"\] (ERR|WARN|WRN|ERROR)\s+: (?P<file>[^ ]+) \(ln (?P<line>\d+), col (?P<col>\d+)\)")
MOD_ADDED = re.compile(r"Adding (packed|unpacked) mod '([^']+)'")
MOD_LISTED = re.compile(r"Resource mod: (.+)$", re.M)
DEV_LANG = paths.MODULES / "devtools" / "res" / "language" / "english" / "hwp_devlevel.lang"
DEV_START = "[HWP:dev] starting "
DEV_READY = "[HWP:dev] level ready"
DEV_FAILED = re.compile(r"\[HWP:dev\] (bad |no mission|mission .* has no floor)")
LEVEL_ISSUE = re.compile(r"^\[(ERR|WRN)\] \[[\d:]+\] (.*)$", re.M)


TEST_SLOT = 7
NEW_PROFILE_TOWN = "SHOWING PickCharacterWindow"     # vanilla: in town without a character
CVAR_LINE = re.compile(r"(?m)^(\w+)[ \t]+(.*?)\s*$")


MAX_TEST_CHARACTERS = 20


def test_characters(slot: int) -> int:
    """How many characters the slot's current save holds (0 when it has none)."""
    import struct
    import hps
    if not hps.slot_files(slot):
        return 0
    data, hdr = hps.read_save(hps.current_save(slot))
    pos = hdr.body_offset
    raw, comp = struct.unpack_from("<II", data, pos)
    pos += 4 if raw == 0 else 8 + comp          # skip the town section
    return struct.unpack_from("<I", data, pos)[0]


def test_marker(slot: int) -> Path:
    """Written next to a slot's saves when dev_check created that profile."""
    return paths.hoh2_dir() / "saves" / f"{slot}.hwp-test"


def config_vars(game: Path) -> dict[str, str]:
    cfg = game / "HWR2.exe.cfg"
    text = cfg.read_text(encoding="utf-8", errors="replace") if cfg.is_file() else ""
    return dict(CVAR_LINE.findall(text))


def cfg_backup(game: Path) -> Path:
    return game / "HWR2.exe.cfg.hwp-dev"


def restore_config(game: Path) -> None:
    """Put the player's HWR2.exe.cfg back if a test run left it switched."""
    backup = cfg_backup(game)
    if backup.is_file():
        (game / "HWR2.exe.cfg").write_bytes(backup.read_bytes())
        backup.unlink()


def switch_config(game: Path, slot: int) -> None:
    """Point HWR2.exe.cfg at the test slot (local), keeping the original in cfg_backup."""
    cfg = game / "HWR2.exe.cfg"
    text = cfg.read_text(encoding="utf-8", errors="replace") if cfg.is_file() else ""
    if not cfg_backup(game).is_file():
        # a backup already there is the player's config, saved by an earlier
        # launch of this run (a --keep run launches again without restoring in
        # between; main() restores before the first launch); never replace it
        # with the switched one
        cfg_backup(game).write_bytes(cfg.read_bytes() if cfg.is_file() else b"")
    for var, value in (("g_save_slot", str(slot)), ("g_save_slot_cloud", "0")):
        line = f"{var} {value}"
        text, n = re.subn(rf"(?m)^{var}[ \t].*$", line, text)
        if not n:
            text = text.rstrip("\n") + ("\n" if text else "") + line + "\n"
    cfg.write_text(text, encoding="utf-8", newline="\n")


def player_slot(game: Path) -> tuple[int, bool]:
    """The profile the player uses (from HWR2.exe.cfg): (slot, cloud)."""
    cv = config_vars(game)
    try:
        return int(cv.get("g_save_slot", "0")), cv.get("g_save_slot_cloud", "0") not in ("0", "false")
    except ValueError:
        return 0, False


def launch(game: Path, slot: int) -> subprocess.Popen:
    exe = game / "HWR2.exe"
    if not exe.is_file():
        sys.exit(f"missing {exe}")
    switch_config(game, slot)
    try:
        return subprocess.Popen([str(exe)], cwd=str(game))
    except OSError:
        restore_config(game)
        raise


def town_ready(text: str) -> bool:
    return TOWN_MARKER in text and any(m in text for m in READY_MARKERS)


def level_ready(text: str) -> bool:
    return DEV_READY in text or bool(DEV_FAILED.search(text))


def wait_for_town(proc: subprocess.Popen, log: Path, stale: tuple | None, timeout: float, settle: float,
                  ready=town_ready, poll=None) -> str:
    """Block until the town (menu) level has been running for `settle` seconds, or `timeout`.
    `stale` is the (mtime, size) of the previous run's log; the game rotates the log on start,
    so nothing is believed until it changes. Returns "settled", "exited" (the game quit on its
    own) or "timeout" (still running but the town never settled: a hang, a stuck load)."""
    deadline = time.time() + timeout
    seen_town_at = None
    while time.time() < deadline:
        time.sleep(1.0)
        if proc.poll() is not None:
            return "exited"
        if not log.is_file() or log_stamp(log) == stale:
            continue
        text = log.read_text(encoding="utf-8", errors="replace")
        if poll is not None:
            poll(proc, text)
        if seen_town_at is None and ready(text):
            seen_town_at = time.time()
        # scripts compile right after the resources load; modules print on their first frames
        if seen_town_at and time.time() - seen_town_at > settle:
            return "settled"
    return "exited" if proc.poll() is not None else "timeout"


IN_TOWN = re.compile(r"\[HWP:core\] gameplay started;.* town=yes")


def game_window(pid: int):
    """The visible top-level window of process pid, or None."""
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def each(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True

    user32.EnumWindows(each, 0)
    return found[0] if found else None


def click_window(pid: int, fx: float, fy: float) -> bool:
    """Left-click at (fx, fy), fractions of the game window's client area, by
    posting the mouse messages to that window. The real mouse and the focus are
    left alone, so it also works on a locked or remote-controlled desktop
    (where Windows refuses foreground switches and drops injected input)."""
    hwnd = game_window(pid)
    if hwnd is None:
        return False
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    rect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    x, y = int(rect.right * fx), int(rect.bottom * fy)
    lp = (y << 16) | x
    for _ in range(3):                          # let the button see the hover
        user32.PostMessageW(hwnd, 0x0200, 0, lp)    # WM_MOUSEMOVE
        time.sleep(0.15)
    user32.PostMessageW(hwnd, 0x0201, 1, lp)    # WM_LBUTTONDOWN (MK_LBUTTON)
    time.sleep(0.08)
    return bool(user32.PostMessageW(hwnd, 0x0202, 0, lp))   # WM_LBUTTONUP


# Where the main menu's first button (Continue / Singleplayer) sits, from
# gui/main_menu/main.gui on the 640x361 virtual screen: the banner spans
# x 112..342 and its button column (logo 113, 6 buttons of 19, 2 spacers of 10,
# spacing 2) is centred vertically.
CONTINUE_AT = (227 / 640, 175 / 361)


class MenuContinue:
    """Gets the game from the main menu into the town. Nothing script-side
    ticks in the main menu (see modules/devtools), so either the player clicks
    Continue or, with --press-continue, the button is clicked."""

    def __init__(self, press: bool, every: float = 5.0, tries: int = 6, need_dev: bool = True):
        self.press, self.every, self.tries, self.last, self.told = press, every, tries, 0.0, False
        self.need_dev = need_dev

    def __call__(self, proc: subprocess.Popen, text: str) -> None:
        if not town_ready(text) or IN_TOWN.search(text) or NEW_PROFILE_TOWN in text:
            return
        if self.need_dev and "[HWP:dev] level loader on" not in text:
            return
        if not self.press:
            if not self.told:
                self.told = True
                print("  >>> click Continue in the game window (or run with --press-continue)")
            return
        if self.tries <= 0 or time.time() - self.last < self.every:
            return
        self.last = time.time()
        self.tries -= 1
        fy = CONTINUE_AT[1] + (6 - self.tries - 3) * 4 / 361    # nudge a little each try
        if click_window(proc.pid, CONTINUE_AT[0], fy):
            print(f"  clicked Continue in the main menu (y {fy:.3f})")


def log_stamp(log: Path) -> tuple | None:
    try:
        st = log.stat()
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size)


def close_game(proc: subprocess.Popen) -> None:
    """Ask the window to close so the engine flushes its log; force-kill as a last resort."""
    if proc.poll() is not None:
        return
    if sys.platform == "win32":
        subprocess.run(["taskkill", "/PID", str(proc.pid)], capture_output=True)
    else:
        proc.terminate()
    try:
        proc.wait(15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(10)
        print("warning: the game had to be force-killed; the end of the log may be missing")


def split_mod_line(rest: str) -> tuple[str, str, str | None]:
    """'<file>: <name>' for unpacked mods, '<file>.bin: <name> (<id>)' for packed ones.
    Ids may contain spaces and parentheses ('GamblerNPC (2)')."""
    fname, _, name = rest.partition(": ")
    mid = None
    if fname.endswith(".bin") and name.endswith(")"):
        depth = 0
        for i in range(len(name) - 1, -1, -1):  # find the '(' that balances the final ')'
            if name[i] == ")":
                depth += 1
            elif name[i] == "(":
                depth -= 1
                if depth == 0:
                    if i > 0 and name[i - 1] == " ":
                        mid, name = name[i + 1:-1], name[:i - 1]
                    break
    return fname, name, mid


def analyse(text: str, strict_ours: bool) -> int:
    ours = re.compile("|".join(OUR_PATTERNS))
    listed = [split_mod_line(rest) for rest in MOD_LISTED.findall(text)]
    added = MOD_ADDED.findall(text)
    issues = []
    for m in SCRIPT_ISSUE.finditer(text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        line_end = text.find("\n", m.end())
        # the message itself is on the following line(s) in the log
        msg = text[line_end + 1: text.find("\n", line_end + 1)].strip()
        issues.append((m.group(1), m.group("file"), int(m.group("line")), int(m.group("col")), msg))
    exceptions = [ln for ln in text.splitlines() if ("Script exception" in ln or "[ERR]" in ln) and ours.search(ln)]
    hwp_lines = [ln for ln in text.splitlines() if "[HWP:" in ln]

    print("Mods listed by the game:")
    for fname, name, mid in listed:
        print(f"  {(mid or fname):30s} {name}  ({'packed ' + fname if mid else 'unpacked'})")
    print("Mods enabled this session:")
    for kind, mid in dict.fromkeys(added):  # the engine logs each mod twice (boot + menu level)
        print(f"  {kind:8s} {mid}")
    if not added:
        print("  (none - the save enables mods by id hash; see tools/hps.py)")

    errors = 0
    print("Script issues:")
    for kind, f, ln, col, msg in issues:
        mine = bool(ours.search(f))
        if strict_ours and not mine:
            continue
        flag = "*" if mine else " "
        print(f" {flag}{kind:5s} {f}:{ln}:{col}  {msg}")
        if kind.startswith("ERR") and mine:
            errors += 1
    if exceptions:
        print("Runtime errors mentioning our files:")
        for ln in exceptions[:40]:
            print("  " + ln.strip())
        errors += len(exceptions)
    if hwp_lines:
        print("HWP log lines:")
        for ln in hwp_lines[:200]:
            print("  " + ln.strip())
    return errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-link", action="store_true")
    ap.add_argument("--timeout", type=float, default=90)
    ap.add_argument("--keep", action="store_true", help="leave the game running")
    ap.add_argument("--log-only", action="store_true", help="parse the current log without launching")
    ap.add_argument("--all-issues", action="store_true", help="also print base-game script warnings")
    ap.add_argument("--settle", type=float, default=12, help="seconds to let the town run before closing the game")
    ap.add_argument("--no-enable", action="store_true", help="do not patch the save to enable the linked modules")
    ap.add_argument("--slot", type=int, default=TEST_SLOT,
                    help=f"local save slot to test on (default {TEST_SLOT}; the player's own slot is refused)")
    ap.add_argument("--restore-config", action="store_true",
                    help="put the player's HWR2.exe.cfg back (after --keep or an interrupted run)")
    ap.add_argument("--level", nargs="+", metavar="FLOOR", help="load these floors of --mission and report each")
    ap.add_argument("--mission", default="hwp_forsaken_tower_hoh1", help="mission whose floors --level loads")
    ap.add_argument("--town", metavar="CMDS",
                    help="enter the town (Continue) and run these hwp commands there, separated by ';' "
                         "('wait' pauses a step); reports once the dev module logs 'town script done'")
    ap.add_argument("--press-continue", action="store_true",
                    help="with --level: focus the game window and click Continue in the main menu "
                         "(posts the click to the game window; for unattended runs)")
    args = ap.parse_args(argv)

    game = paths.hoh2_dir()
    if args.restore_config:
        restore_config(game)
        sys.exit(0)
    log = game / "HWR2.exe.log"
    if args.log_only:
        text = log.read_text(encoding="utf-8", errors="replace")
        sys.exit(1 if analyse(text, not args.all_issues) else 0)

    restore_config(game)
    own, own_cloud = player_slot(game)
    if args.slot == own and not own_cloud:
        sys.exit(f"slot {args.slot} is the player's profile (HWR2.exe.cfg); test on another --slot")

    if not args.no_link:
        import dev_link
        dev_link.main([])

    import hps
    if hps.slot_files(args.slot) and not test_marker(args.slot).is_file():
        # a profile dev_check did not create may be a real one: never patch or delete it
        sys.exit(f"slot {args.slot} holds a profile dev_check did not create; pick an empty --slot "
                 f"(or, if it really is a throwaway test profile, create {test_marker(args.slot)})")
    if test_characters(args.slot) > MAX_TEST_CHARACTERS:
        # every --level run adds an "HWP Test" character; start the slot over
        print(f"test slot {args.slot} has over {MAX_TEST_CHARACTERS} characters; recreating it")
        for f in hps.slot_files(args.slot):
            f.unlink()
    if not hps.slot_files(args.slot):
        # a fresh profile is only written once the town has been entered (and has
        # no mods enabled yet, so the dev module cannot help with this run)
        print(f"test slot {args.slot} has no profile yet; booting once into its town to create it")
        run_game(game, log, args, lambda t: NEW_PROFILE_TOWN in t, "the new profile's town",
                 MenuContinue(args.press_continue, need_dev=False))
        if not hps.slot_files(args.slot):
            sys.exit(f"the game did not create a save in slot {args.slot}")
        test_marker(args.slot).write_text("created by tools/dev_check.py for test runs\n", encoding="utf-8")
    missing = enable_linked_modules(game, args.slot) if not args.no_enable else []
    if args.level:
        sys.exit(check_levels(game, log, args))
    if args.town is not None:
        sys.exit(check_town(game, log, args))
    text = run_game(game, log, args)
    errors = analyse(text, not args.all_issues)
    learned = learn_hashes(text)
    if missing and any(m in learned for m in missing) and not args.keep:
        # the core module just told us the hashes of the newly linked modules: enable and go again
        print("re-running with the newly learned modules enabled...")
        enable_linked_modules(game, args.slot)
        text = run_game(game, log, args)
        errors = analyse(text, not args.all_issues)
    sys.exit(1 if errors else 0)


TOWN_DONE = "[HWP:dev] town script done"


def check_town(game: Path, log: Path, args) -> int:
    """One game run: Continue into the town, run the --town commands, report."""
    DEV_LANG.write_text('<lang name="English" official="false">\n'
                        f'\t<string name="hwp.dev.town">{escape(args.town)}</string>\n</lang>\n',
                        encoding="utf-8")
    try:
        text = run_game(game, log, args, lambda t: TOWN_DONE in t, "the town script to finish",
                        MenuContinue(args.press_continue, need_dev=False))
    finally:
        DEV_LANG.unlink(missing_ok=True)
    errors = analyse(text, True)
    if TOWN_DONE not in text:
        print("town script did not finish")
        return 1
    return 1 if errors else 0


def check_levels(game: Path, log: Path, args) -> int:
    """One game run per floor; returns the number of floors that failed to load or
    logged errors in our files."""
    failed = 0
    for floor in args.level:
        print(f"=== {args.mission} {floor}")
        DEV_LANG.write_text('<lang name="English" official="false">\n'
                            f'\t<string name="hwp.dev.level">{escape(args.mission)} {floor}</string>\n</lang>\n',
                            encoding="utf-8")
        try:
            text = run_game(game, log, args, level_ready, "the floor to load", MenuContinue(args.press_continue))
            if DEV_START not in text and learn_hashes(text) and not args.no_enable:
                # e.g. hwp_devtools was linked for the first time: the core module
                # just printed its save hash, so enable it and go again
                print("re-running with the newly learned modules enabled...")
                enable_linked_modules(game, args.slot)
                text = run_game(game, log, args, level_ready, "the floor to load", MenuContinue(args.press_continue))
        finally:
            DEV_LANG.unlink(missing_ok=True)
        errors = analyse(text, True)
        if not report_level(text) or errors:
            failed += 1
    return failed


def report_level(text: str) -> bool:
    """Print what the engine complained about after the floor started; False if it never got there."""
    for ln in text.splitlines():
        if DEV_FAILED.search(ln):
            print("  " + ln.strip())
            return False
    start = text.find(DEV_START)
    if start < 0:
        print("  the floor never started (no '[HWP:dev] starting' line; is hwp_devtools linked and enabled?)")
        return False
    counts: dict[str, int] = {}
    for m in LEVEL_ISSUE.finditer(text, start):
        key = f"{m.group(1)} {m.group(2).strip()}"
        counts[key] = counts.get(key, 0) + 1
    ready = DEV_READY in text
    print(f"Level issues after the floor started ({len(counts)} distinct):")
    for key, n in sorted(counts.items(), key=lambda kv: (not kv[0].startswith("ERR"), -kv[1], kv[0])):
        print(f"  {n:4d}x {key}")
    print("  floor " + ("loaded: " + text[text.find(DEV_READY):].split("\n", 1)[0] if ready
                        else "did not report ready (crash or hang while loading?)"))
    return ready


def game_running() -> bool:
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq HWR2.exe"], capture_output=True, text=True).stdout
    return "HWR2.exe" in out


def run_game(game: Path, log: Path, args, ready=town_ready, what="the town to load", poll=None) -> str:
    # A copy that is already running is the player's own session: a second
    # one would share (and rotate) its log and fight it for the config.
    if game_running():
        sys.exit("HWR2.exe is already running - close the game first (not launching a second copy)")
    # The game rotates the log on start, so the whole file belongs to this run.
    stale = log_stamp(log)
    proc = launch(game, args.slot)
    print(f"launched HWR2.exe on save slot {args.slot} (pid {proc.pid}); waiting for {what}...")
    try:
        state = wait_for_town(proc, log, stale, args.timeout, args.settle if ready is town_ready else 2, ready, poll)
    finally:
        if not args.keep:
            close_game(proc)
            print("game closed")
            restore_config(game)    # the player's next launch uses their own profile
        else:
            print(f"left running on test slot {args.slot}; run `dev_check.py --restore-config` "
                  f"after closing it so the next launch uses your own profile")
    if log_stamp(log) == stale:
        sys.exit(f"HWR2.exe wrote no log (exit code {proc.poll()}); is Steam running?")
    text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
    if not text:
        sys.exit("no log output captured")
    if state == "exited":
        print(f"warning: the game exited on its own (code {proc.poll()}) before {what} finished")
    elif state == "timeout":
        if ready is not town_ready:
            print(f"warning: timed out after {args.timeout:.0f}s waiting for {what}")
            return text
        # a partial log cannot clear a module: fail instead of reporting a clean boot
        sys.exit(f"the town never settled within {args.timeout:.0f}s (hang or stuck resource load?); "
                 f"the log is incomplete, see {log}")
    return text


def enable_linked_modules(game: Path, slot: int = 0) -> list[str]:
    """Switch every linked HammerwatchPlus mod on in the slot's current save.
    Returns the linked mod ids whose hash is not known yet."""
    import dev_link
    import hps
    known = hps.load_known()
    ours = [p.name for p in sorted((game / "mods").iterdir()) if dev_link.is_ours(p)]
    if not ours:
        return []
    save = hps.current_save(slot)
    data, hdr = hps.read_save(save)
    missing = [m for m in ours if m not in known]
    if missing:
        if "hwp_core" in known or any(known.get(m) in hdr.mods for m in ours):
            print(f"hash of {missing} not known yet; the core module will print it on this run")
        else:
            print(f"no known save hash for {missing}; enable hwp_core once in the Resource Mods menu, "
                  f"then run again (the core module prints every mod's hash)")
    wanted = [known[m] for m in ours if m in known and known[m] not in hdr.mods]
    if wanted:
        hdr.mods = list(hdr.mods) + wanted
        backup = hps.write_save(save, data, hdr)
        print(f"enabled {[m for m in ours if m in known and known[m] in wanted]} in {save.name} (backup {backup.name})")
    return missing


def learn_hashes(text: str) -> dict[str, int]:
    """Record `[HWP:core] modhash '<id>' <hash>` lines so future runs can enable mods by id."""
    import hps
    found = {mid: int(h) for mid, h in hps.MODHASH_LINE.findall(text)}
    if not found:
        return {}
    known = hps.load_known()
    new = {k: v for k, v in found.items() if known.get(k) != v}
    if new:
        known.update(new)
        hps.save_known(known)
        print(f"learned {len(new)} mod hash(es): {', '.join(sorted(new))}")
    return new


if __name__ == "__main__":
    main()
