#!/usr/bin/env python3
"""
dev_link.py - link repo modules into the game's mods/ folder as *unpacked* mods.

HWR2 loads `mods/<id>/info.xml` folders directly, so a linked module can be
edited in the repo and re-tested with a game restart, no packing needed.

    dev_link.py                # link every module
    dev_link.py gambler core   # link only these
    dev_link.py --unlink       # remove all HammerwatchPlus links
    dev_link.py --status       # show what is linked

Links are directory junctions on Windows (no admin rights needed) and symlinks
elsewhere. Only links we created (pointing into this repo) are ever removed.
Enable the mods once in the game's Resource Mods menu; the choice is stored in
the persistent save.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402


def mods_dir() -> Path:
    d = paths.hoh2_dir() / "mods"
    d.mkdir(exist_ok=True)
    return d


def link_target(p: Path) -> Path | None:
    """Target of a junction/symlink (even a dangling one); None for a plain dir or a missing path."""
    try:
        st = os.lstat(p)
    except OSError:
        return None
    is_link = p.is_symlink() or (os.name == "nt" and bool(getattr(st, "st_file_attributes", 0) & 0x400))
    if not is_link:
        return None
    try:
        target = os.readlink(p)  # works for junctions too; no need for the target to exist
    except OSError:
        return None
    return Path(os.path.normpath(target.removeprefix("\\\\?\\")))


def is_ours(p: Path) -> bool:
    t = link_target(p)
    return t is not None and paths.MODULES in t.parents


def make_link(src: Path, dst: Path) -> None:
    if os.name == "nt":
        r = subprocess.run(["cmd", "/c", "mklink", "/J", str(dst), str(src)], capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"mklink {dst} failed: {(r.stderr or r.stdout).strip()}")
    else:
        dst.symlink_to(src, target_is_directory=True)


def remove_link(dst: Path) -> None:
    if os.name == "nt":
        subprocess.run(["cmd", "/c", "rmdir", str(dst)], check=True, capture_output=True)
    else:
        dst.unlink()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("modules", nargs="*")
    ap.add_argument("--unlink", action="store_true")
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args(argv)

    mdir = mods_dir()
    if args.status:
        for p in sorted(mdir.iterdir()):
            tag = "link -> " + str(link_target(p)) if link_target(p) else ("dir" if p.is_dir() else "file")
            print(f"{'*' if is_ours(p) else ' '} {p.name:40s} {tag}")
        return

    if args.unlink:
        for p in sorted(mdir.iterdir()):
            if is_ours(p):
                remove_link(p)
                print(f"unlinked {p.name}")
        return

    wanted = paths.module_dirs()
    if args.modules:
        wanted = [d for d in wanted if d.name in args.modules]
        missing = set(args.modules) - {d.name for d in wanted}
        if missing:
            sys.exit(f"unknown module(s): {', '.join(sorted(missing))}")
    for src in wanted:
        dst = mdir / ("hwp_" + src.name)
        if dst.exists() or link_target(dst) is not None:  # a dangling junction does not "exist"
            if is_ours(dst) and link_target(dst) == src.resolve():
                print(f"ok       {dst.name}")
                continue
            if not is_ours(dst):
                print(f"SKIP     {dst.name}: exists and is not a HammerwatchPlus link")
                continue
            remove_link(dst)
        make_link(src.resolve(), dst)
        print(f"linked   {dst.name} -> {src}")


if __name__ == "__main__":
    main()
