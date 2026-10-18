#!/usr/bin/env python3
"""deploy.py - put mods into one of the environments declared in gamelab/env/environments.json.

    deploy.py gamelab [mod ...]          # junction repo mods into the GameLab game dir, verify
    deploy.py modded-prod [mod ...]      # pack (tools/build.py) and copy .bin files to <install>/mods
    deploy.py modded-prod --dry-run      # list what would be written, write nothing
    deploy.py vanilla                    # refuses: vanilla declares no mods

gamelab: mods are directory junctions into mods/<id>/, so an edit in the repo *is* the
deployed copy. Nothing is copied; this only creates/repairs the junctions and verifies
them (gamelab/env.py link()). GameLab scenarios enable a mod per save, so a mod also
needs a scenario's "mods" list (or a fixture) to load.

modded-prod: the player's real install. Only the modules the environment lists, never a
`forbidden_mods` pattern (gamelab-*). Each goes through build.py to dist/HWP-<id>.bin and
is copied to <install>/mods/. Existing HWP-*.bin files there are replaced; nothing else
in that folder is touched.

Reload trigger (measured, gamelab/scenarios/reload-mark.json, run 20261017-144317):
a script edit is NOT picked up on a level load inside a running game (the next level's
module constructor still runs the old code); it is picked up after a restart. So the
trigger is a game restart. Every GameLab run boots a fresh process, so for GameLab the
next `python -m gamelab run ...` is the reload. For modded-prod the player restarts the game.
"""
from __future__ import annotations

import argparse
import fnmatch
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import gamepaths  # noqa: E402
import saves  # noqa: E402
from gamelab import env  # noqa: E402

RELOAD = "reload trigger: restart the game (a level load does not recompile scripts; reload-mark scenario)"


def deploy_gamelab(mods: list[str]) -> int:
    problems = env.link(fix=True, mods=mods)
    for p in problems:
        print("PROBLEM", p)
    linked = sorted(p.name for p in (env.GAME / "mods").iterdir())
    print(f"gamelab: {'green' if not problems else 'NOT green'}; linked {linked}")
    print(RELOAD + "; the next `python -m gamelab run` boots fresh")
    return 1 if problems else 0


def deploy_prod(mods: list[str], dry_run: bool) -> int:
    decl = env.environments()["modded-prod"]
    forbidden = decl.get("forbidden_mods", [])
    wanted = mods or decl["mods"]
    bad = [m for m in wanted if m not in decl["mods"] or any(fnmatch.fnmatch(m, f) for f in forbidden)]
    if bad:
        print(f"REFUSED: not declared for modded-prod (or forbidden): {bad}")
        return 2
    target = Path(env.install()) / "mods"
    plan = [(gamepaths.DIST / f"HWP-{m}.bin", target / f"HWP-{m}.bin") for m in wanted]
    if dry_run:
        for src, dst in plan:
            print(f"would build {src.relative_to(gamepaths.REPO)} and copy it to {dst}")
        print(RELOAD)
        return 0
    unconfirmed = saves.confirmation_problems()
    if unconfirmed:
        print("REFUSED: modded-prod runs on the player's real saves; " + "; ".join(unconfirmed))
        return 2
    r = subprocess.run([sys.executable, str(gamepaths.TOOLS / "build.py"), "--no-all", *wanted])
    if r.returncode:
        return r.returncode
    target.mkdir(exist_ok=True)
    for src, dst in plan:
        shutil.copy2(src, dst)
        print(f"deployed {dst}")
    print(RELOAD)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("env", choices=["gamelab", "modded-prod", "vanilla"])
    ap.add_argument("mods", nargs="*")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if a.env == "vanilla":
        print("REFUSED: the vanilla environment declares no mods")
        return 2
    if a.env == "gamelab":
        return deploy_gamelab(a.mods)
    return deploy_prod(a.mods, a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
