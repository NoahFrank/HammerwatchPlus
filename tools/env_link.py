#!/usr/bin/env python3
"""env_link.py - create and verify every link the gamelab environment declares.

    env_link.py            # create/repair, then verify
    env_link.py --verify   # same, exit 1 if anything is still wrong (runs in launcher preflight)
    env_link.py --check    # verify only, change nothing

Declared in gamelab/env/environments.json; the implementation is gamelab/env.py.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from gamelab import env  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    problems = env.link(fix=not a.check)
    for p in problems:
        print("PROBLEM", p)
    print(f"env_link: {'green' if not problems else f'{len(problems)} problem(s)'} ({env.GAME})")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
