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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402

READY_MARKERS = ("Resource load time:", "Creating sound engine")
TOWN_MARKER = "StartLoadMenu levels/town.lvl"
OUR_PATTERNS = (r"scripts/HWP/", r"hwp_", r"\[HWP:", r"HammerwatchPlus")
SCRIPT_ISSUE = re.compile(r"\] (ERR|WARN|WRN|ERROR) : (?P<file>[^ ]+) \(ln (?P<line>\d+), col (?P<col>\d+)\)")
MOD_ADDED = re.compile(r"Adding (packed|unpacked) mod '([^']+)'")
MOD_LISTED = re.compile(r"Resource mod: (.+)$", re.M)


def launch(game: Path) -> subprocess.Popen:
    exe = game / "HWR2.exe"
    if not exe.is_file():
        sys.exit(f"missing {exe}")
    return subprocess.Popen([str(exe)], cwd=str(game))


def wait_for_town(proc: subprocess.Popen, log: Path, stale: tuple | None, timeout: float, settle: float) -> str:
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
        if seen_town_at is None and TOWN_MARKER in text and any(m in text for m in READY_MARKERS):
            seen_town_at = time.time()
        # scripts compile right after the resources load; modules print on their first frames
        if seen_town_at and time.time() - seen_town_at > settle:
            return "settled"
    return "exited" if proc.poll() is not None else "timeout"


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
    ap.add_argument("--slot", type=int, default=0, help="save slot to enable the modules in")
    args = ap.parse_args(argv)

    game = paths.hoh2_dir()
    log = game / "HWR2.exe.log"
    if args.log_only:
        text = log.read_text(encoding="utf-8", errors="replace")
        sys.exit(1 if analyse(text, not args.all_issues) else 0)

    if not args.no_link:
        import dev_link
        dev_link.main([])

    missing = enable_linked_modules(game, args.slot) if not args.no_enable else []
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


def run_game(game: Path, log: Path, args) -> str:
    # The game rotates the log on start, so the whole file belongs to this run.
    stale = log_stamp(log)
    proc = launch(game)
    print(f"launched HWR2.exe (pid {proc.pid}); waiting for the town to load...")
    try:
        state = wait_for_town(proc, log, stale, args.timeout, args.settle)
    finally:
        if not args.keep:
            close_game(proc)
            print("game closed")
    if log_stamp(log) == stale:
        sys.exit(f"HWR2.exe wrote no log (exit code {proc.poll()}); is Steam running?")
    text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
    if not text:
        sys.exit("no log output captured")
    if state == "exited":
        print(f"warning: the game exited on its own (code {proc.poll()}) before the town had settled")
    elif state == "timeout":
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
