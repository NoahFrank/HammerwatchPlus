#!/usr/bin/env python3
"""saves.py - back up, restore and verify the player's real HoH2 saves.

    saves.py backup                 # copy every real save dir to saves-backup/<ts>/ if anything changed
    saves.py restore [--from TS]    # put the newest (or named) backup back, backing up the current state first
    saves.py verify                 # exit 1 unless the real saves hash-match the newest backup
    saves.py list

The real save dirs come from tools/gamepaths.real_save_dirs() (Steam cloud, the
install's local saves/, the game's own save_backups/). saves-backup/ is gitignored
(personal data) and capped at CAP_MB: past the cap `backup` refuses and says so, and the
user prunes.

saves-backup/confirmed.json is written by `python -m gamelab doctor --fix` (or --confirm-saves)
once a backup of this machine's saves is taken, re-hashed and restorable. The launcher
and `deploy.py modded-prod` refuse while confirmation_problems() is non-empty.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamepaths  # noqa: E402

CAP_MB = 200          # declared in README.md; change both together
MANIFEST = "manifest.json"
CONFIRMED = "confirmed.json"
EXIT_CAP = 4


def snapshot() -> dict[str, dict[str, str]]:
    """{dir name: {relative file: sha256}} of the real save dirs as they are now."""
    out: dict[str, dict[str, str]] = {}
    for name, d in gamepaths.real_save_dirs().items():
        files = {}
        if d.is_dir():
            for f in sorted(d.rglob("*")):
                if f.is_file():
                    files[f.relative_to(d).as_posix()] = hashlib.sha256(f.read_bytes()).hexdigest()
        out[name] = files
    return out


def backups() -> list[Path]:
    root = gamepaths.SAVES_BACKUP
    return sorted(p for p in root.iterdir() if p.is_dir() and (p / MANIFEST).is_file()) if root.is_dir() else []


def dir_bytes(d: Path) -> int:
    return sum(f.stat().st_size for f in d.rglob("*") if f.is_file()) if d.is_dir() else 0


def backup(quiet: bool = False) -> int:
    snap = snapshot()
    prev = backups()
    if prev and json.loads((prev[-1] / MANIFEST).read_text())["files"] == snap:
        if not quiet:
            print(f"unchanged since {prev[-1].name}; no backup needed")
        return 0
    dirs = gamepaths.real_save_dirs()
    need = sum(dir_bytes(d) for d in dirs.values())
    have = dir_bytes(gamepaths.SAVES_BACKUP)
    if have + need > CAP_MB * 1024 * 1024:
        print(f"REFUSED: saves-backup/ is {have / 2**20:.1f} MB and this backup adds {need / 2**20:.1f} MB, "
              f"over the {CAP_MB} MB cap declared in README.md. Prune old backups, then run again.")
        return EXIT_CAP
    ts = time.strftime("%Y-%m-%dT%H-%M-%S")
    dest = gamepaths.SAVES_BACKUP / ts
    for name, d in dirs.items():
        if d.is_dir():
            shutil.copytree(d, dest / name)
    (dest / MANIFEST).parent.mkdir(parents=True, exist_ok=True)
    (dest / MANIFEST).write_text(json.dumps({"taken": ts, "sources": {k: str(v) for k, v in dirs.items()},
                                             "files": snap}, indent=1), encoding="utf-8")
    print(f"backed up {sum(len(v) for v in snap.values())} files to saves-backup/{ts}")
    return 0


def diff(a: dict, b: dict) -> list[str]:
    """Files added, removed or changed between two snapshot() results."""
    return sorted(f"{d}/{f}" for d in set(a) | set(b)
                  for f in set(a.get(d, {})) | set(b.get(d, {})) if a.get(d, {}).get(f) != b.get(d, {}).get(f))


def verify(against: Path | None = None) -> int:
    """Real saves vs a backup: the newest by default, or `against` (restore checks its source)."""
    prev = backups()
    ref = against or (prev[-1] if prev else None)
    if ref is None:
        print("no backup to verify against")
        return 1
    want = json.loads((ref / MANIFEST).read_text())["files"]
    bad = diff(want, snapshot())
    if bad:
        print(f"real saves differ from {ref.name}: {sorted(bad)[:20]}")
        return 1
    print(f"real saves match {ref.name}")
    return 0


def intact(ref: Path) -> list[str]:
    """Files in a backup whose copy is missing or no longer hashes to its manifest entry.
    verify() compares the real saves to the manifest; this checks the copies themselves."""
    want = json.loads((ref / MANIFEST).read_text())["files"]
    bad = []
    for name, files in want.items():
        for rel, h in files.items():
            f = ref / name / rel
            if not f.is_file() or hashlib.sha256(f.read_bytes()).hexdigest() != h:
                bad.append(f"{name}/{rel}")
    return sorted(bad)


def confirmation_problems() -> list[str]:
    """[] when this machine's save backups are confirmed and the confirmed backup is intact."""
    stamp = gamepaths.SAVES_BACKUP / CONFIRMED
    if not stamp.is_file():
        return ["save backups not confirmed on this machine: run `python -m gamelab doctor --fix` "
                "(it confirms by itself unless something is ambiguous)"]
    c = json.loads(stamp.read_text(encoding="utf-8"))
    now = {k: str(v) for k, v in gamepaths.real_save_dirs().items()}
    out = []
    if c.get("sources") != now:
        out.append(f"the real save dirs changed since confirmation ({c.get('sources')} -> {now}); re-confirm")
    ref = gamepaths.SAVES_BACKUP / str(c.get("backup"))
    if not (ref / MANIFEST).is_file():
        out.append(f"the confirmed backup saves-backup/{c.get('backup')} is gone; re-confirm")
    else:
        out += [f"confirmed backup copy damaged: {b}" for b in intact(ref)[:10]]
    return out


def restore(ts: str | None) -> int:
    prev = backups()
    src = next((p for p in prev if p.name == ts), None) if ts else (prev[-1] if prev else None)
    if src is None:
        print(f"no backup {ts or ''}")
        return 1
    damaged = intact(src)
    if damaged:
        print(f"REFUSED: backup {src.name} is damaged, restoring it would lose data: {damaged[:20]}")
        return 1
    rc = backup()
    if rc:
        return rc
    meta = json.loads((src / MANIFEST).read_text())
    for name, d in gamepaths.real_save_dirs().items():
        if name not in meta["files"]:
            continue
        d.mkdir(parents=True, exist_ok=True)
        for f in d.rglob("*"):
            if f.is_file() and f.relative_to(d).as_posix() not in meta["files"][name]:
                f.unlink()
        for rel in meta["files"][name]:
            (d / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src / name / rel, d / rel)
    print(f"restored {src.name}")
    return verify(src)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("backup")
    sub.add_parser("verify")
    sub.add_parser("list")
    r = sub.add_parser("restore")
    r.add_argument("--from", dest="ts")
    a = ap.parse_args(argv)
    if a.cmd == "backup":
        return backup()
    if a.cmd == "verify":
        return verify()
    if a.cmd == "restore":
        return restore(a.ts)
    for p in backups():
        print(p.name, f"{dir_bytes(p) / 2**20:.2f} MB")
    print(f"total {dir_bytes(gamepaths.SAVES_BACKUP) / 2**20:.2f} MB of {CAP_MB} MB cap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
