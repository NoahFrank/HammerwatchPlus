#!/usr/bin/env python3
"""
extract_base.py - extract the base game archives for reference and diffing.

    extract_base.py            # HoH2 -> .base/     (needed by build.py --check)
    extract_base.py --hoh1     # HoH1 -> .base-hoh1/ (needed by import_hoh1.py)
    extract_base.py --both

Both output folders are git-ignored: they hold Crackshell's assets.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hwr_archive as hwr  # noqa: E402
import paths  # noqa: E402


def extract(game_dir: Path, out: Path, force: bool) -> None:
    archive = game_dir / "res" / "assets.bin"
    if not archive.is_file():
        sys.exit(f"missing {archive}")
    if out.is_dir():
        if not force:
            print(f"{out} exists; use --force to re-extract")
            return
        shutil.rmtree(out)
    print(f"extracting {archive} -> {out}")
    hwr.main(["extract", str(archive), str(out)])
    # The .lang files live loose next to assets.bin; copy them in so .base/ is complete.
    lang_src = game_dir / "res" / "language"
    if lang_src.is_dir():
        shutil.copytree(lang_src, out / "language", dirs_exist_ok=True)
        print(f"copied {lang_src} -> {out / 'language'}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hoh1", action="store_true")
    ap.add_argument("--both", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args(argv)
    if not args.hoh1 or args.both:
        extract(paths.hoh2_dir(), paths.BASE_HOH2, args.force)
    if args.hoh1 or args.both:
        extract(paths.hoh1_dir(), paths.BASE_HOH1, args.force)


if __name__ == "__main__":
    main()
