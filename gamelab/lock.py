"""One GameLab run at a time, and none after a dirty one (playbook P6, per-test isolation).

All runs share one game dir (gamelab/env/userdata/game), so two at once would share
saves, logs and the capture request file. `acquire` takes an exclusive lock file and
refuses when another live run holds it, when a dead run left it behind, or when the last
run reported a dirty teardown (a lab HWR2.exe had to be killed, a pass did not exit 0, or
the runner wrote no inner.json). `python -m gamelab reset` is the one way past a refusal:
it kills lab game processes (only those whose image is inside the lab game dir), wipes the
scratch areas and records a clean teardown.
"""
from __future__ import annotations

import csv
import io
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from gamelab import env
from gamelab.session import process_image

LOCK = env.GAME.parent / "gamelab.lock"
TEARDOWN = env.GAME.parent / "teardown.json"
SCRATCH = ("saves", "appdata")          # wiped before every run; materialize refills saves
EXIT_REFUSED = 4


class Refused(RuntimeError):
    pass


def pid_alive(pid: int) -> bool:
    return bool(process_image(pid))


def lab_processes() -> list[int]:
    """PIDs of HWR2.exe processes whose image lives in the lab game dir (never the user's game)."""
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq HWR2.exe", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    game = str(env.GAME.resolve()).lower()
    pids = []
    for row in csv.reader(io.StringIO(out)):
        if len(row) > 1 and row[1].isdigit():
            image = process_image(int(row[1])).lower()
            if image.startswith(game):
                pids.append(int(row[1]))
    return pids


def kill(pids: list[int]) -> None:
    for pid in pids:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)


def acquire(scenario: str, mode: str) -> None:
    try:
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        held = json.loads(LOCK.read_text(encoding="utf-8") or "{}")
        if pid_alive(held.get("pid", 0)):
            raise Refused(f"another GameLab run holds the lock: {held}")
        raise Refused(f"stale lock from a run that never tore down: {held} (python -m gamelab reset)")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"pid": os.getpid(), "scenario": scenario, "mode": mode,
                   "started": time.strftime("%Y-%m-%dT%H:%M:%S")}, f)
    last = json.loads(TEARDOWN.read_text(encoding="utf-8")) if TEARDOWN.is_file() else {"clean": True}
    leftover = lab_processes()
    if not last.get("clean") or leftover:
        LOCK.unlink()
        raise Refused(f"previous run did not tear down cleanly: {last}"
                      + (f"; lab HWR2.exe still running: {leftover}" if leftover else "")
                      + " (python -m gamelab reset)")
    for name in SCRATCH:
        shutil.rmtree(env.GAME / name, ignore_errors=True)
    (env.GAME / "appdata").mkdir(parents=True, exist_ok=True)


def release(run: str, reasons: list[str]) -> dict:
    """Record the teardown, killing any lab game process the runner left alive."""
    leftover = lab_processes()
    if leftover:
        kill(leftover)
        reasons = reasons + [f"killed leftover lab HWR2.exe {leftover}"]
    record = {"clean": not reasons, "reasons": reasons, "run": run,
              "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    TEARDOWN.write_text(json.dumps(record, indent=1), encoding="utf-8")
    LOCK.unlink(missing_ok=True)
    return record


def reset() -> int:
    held = json.loads(LOCK.read_text(encoding="utf-8") or "{}") if LOCK.is_file() else {}
    if pid_alive(held.get("pid", 0)) and held.get("pid") != os.getpid():
        print(f"refusing: run {held} is still alive")
        return EXIT_REFUSED
    leftover = lab_processes()
    kill(leftover)
    for name in SCRATCH:
        shutil.rmtree(env.GAME / name, ignore_errors=True)
    LOCK.unlink(missing_ok=True)
    TEARDOWN.write_text(json.dumps({"clean": True, "reasons": [], "run": "reset", "killed": leftover,
                                    "at": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=1), encoding="utf-8")
    print(f"reset: killed {leftover or 'nothing'}, wiped {', '.join(SCRATCH)}")
    return 0
