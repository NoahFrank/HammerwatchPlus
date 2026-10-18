#!/usr/bin/env python3
"""game_screenshot.py - capture the game into .screenshots/ (the game-screenshot skill).

    game_screenshot.py                 # boots the `screenshot` scenario (town), one frame
    game_screenshot.py <scenario>      # any scenario: every shot it takes is copied

Runs `python -m gamelab run <scenario> --mode lab`: hidden desktop, muted, never focused,
the user's config and saves untouched. The frames come from the in-process back-buffer
capture (shim), which needs no visible window (capture-passive scenario). Every PNG of
the run is copied to .screenshots/<run>-<shot>.png and its path printed, one per line
after "SHOT ", for the caller to read back. Exit code = the run's.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamepaths  # noqa: E402

RESULTS = gamepaths.GAMELAB / "results"


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    scenario = argv[0] if argv else "screenshot"
    before = set(RESULTS.iterdir()) if RESULTS.is_dir() else set()
    rc = subprocess.run([sys.executable, "-m", "gamelab", "run", scenario, "--mode", "lab"], cwd=gamepaths.REPO).returncode
    runs = sorted(set(RESULTS.iterdir()) - before) if RESULTS.is_dir() else []
    if not runs:
        print("no results directory: the run was refused before it started")
        return rc or 1
    run = runs[-1]
    gamepaths.SCREENSHOTS.mkdir(exist_ok=True)
    shots = sorted((run / "shots").glob("*.png")) if (run / "shots").is_dir() else []
    for png in shots:
        dest = gamepaths.SCREENSHOTS / f"{run.name}-{png.name.replace(' ', '_')}"
        shutil.copy2(png, dest)
        print("SHOT", dest)
    if not shots:
        print(f"the run took no frames ({run.name})")
    return rc


if __name__ == "__main__":
    sys.exit(main())
