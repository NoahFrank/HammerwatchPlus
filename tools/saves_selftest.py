#!/usr/bin/env python3
"""saves_selftest.py - exercise saves.py backup / verify / restore end to end, on a sandbox.

The real save dirs are never touched: gamepaths.real_save_dirs() and SAVES_BACKUP are
pointed at a fresh temp tree first, and the run aborts if any path it is about to write
lies outside that tree. The sandbox is seeded with the shapes the real dirs hold
(cloud / local / game_backups, .hps slots), then:

  1. backup                    -> one backup, verify green
  2. change a slot, add a file  -> verify red
  3. restore                   -> the change is undone, the extra file gone, verify green,
                                  and the pre-restore state was itself backed up first
  4. intact                     -> a damaged backup copy is reported, and restore refuses it
  5. confirm                    -> no stamp, a good stamp, a stamp whose backup is damaged
  6. cap                        -> with CAP_MB shrunk below the next backup, backup refuses (exit 4)

Exit 0 only if every step held.
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamepaths  # noqa: E402
import saves  # noqa: E402


def main() -> int:
    real = {k: v.resolve() for k, v in gamepaths.real_save_dirs().items()}
    real_backup = gamepaths.SAVES_BACKUP.resolve()
    scratch = Path(r"C:\tmp\claude")
    scratch.mkdir(parents=True, exist_ok=True)       # absent on a fresh machine
    root = Path(tempfile.mkdtemp(prefix="hwp-saves-selftest-", dir=scratch))
    dirs = {"cloud": root / "cloud", "local": root / "local", "game_backups": root / "game_backups"}
    for d in dirs.values():
        assert not any(d == r or r in d.parents for r in real.values()), d
    gamepaths.real_save_dirs = lambda: dict(dirs)
    gamepaths.SAVES_BACKUP = root / "saves-backup"
    assert gamepaths.SAVES_BACKUP != real_backup

    (dirs["cloud"] / "slot_0.hps").parent.mkdir(parents=True)
    (dirs["cloud"] / "slot_0.hps").write_bytes(b"HPS\x01slot zero")
    (dirs["cloud"] / "town.hps").write_bytes(b"HPS\x01town")
    (dirs["game_backups"] / "slot_0_old.hps").parent.mkdir(parents=True)
    (dirs["game_backups"] / "slot_0_old.hps").write_bytes(b"HPS\x01older")

    checks = []

    def check(name, ok):
        checks.append((name, ok))
        print(("PASS " if ok else "FAIL ") + name)

    check("backup writes one backup", saves.backup() == 0 and len(saves.backups()) == 1)
    check("verify green right after backup", saves.verify() == 0)
    (dirs["cloud"] / "slot_0.hps").write_bytes(b"HPS\x01slot zero, played on")
    (dirs["cloud"] / "slot_1.hps").write_bytes(b"HPS\x01new slot")
    check("verify red after a slot changed", saves.verify() == 1)
    first = saves.backups()[0].name
    time.sleep(1.1)      # backup dirs are named to the second
    check("restore returns green", saves.restore(first) == 0)
    check("restored slot has the backed-up bytes", (dirs["cloud"] / "slot_0.hps").read_bytes() == b"HPS\x01slot zero")
    check("file absent from the backup is removed", not (dirs["cloud"] / "slot_1.hps").exists())
    check("pre-restore state was backed up first", len(saves.backups()) == 2)
    good = saves.backups()[-1]
    check("intact backup reports nothing", saves.intact(good) == [])
    check("unconfirmed machine is reported", len(saves.confirmation_problems()) == 1)
    (gamepaths.SAVES_BACKUP / saves.CONFIRMED).write_text(json.dumps(
        {"sources": {k: str(v) for k, v in dirs.items()}, "backup": good.name}))
    check("confirmed machine reports nothing", saves.confirmation_problems() == [])
    (good / "cloud" / "slot_0.hps").write_bytes(b"bit rot")
    check("damaged backup copy is reported", saves.intact(good) == ["cloud/slot_0.hps"])
    check("damaged confirmed backup is reported", any("damaged" in p for p in saves.confirmation_problems()))
    before = (dirs["cloud"] / "slot_0.hps").read_bytes()
    check("restore refuses a damaged backup", saves.restore(good.name) == 1
          and (dirs["cloud"] / "slot_0.hps").read_bytes() == before)
    (dirs["local"] / "slot_2.hps").parent.mkdir(parents=True, exist_ok=True)
    (dirs["local"] / "slot_2.hps").write_bytes(b"x" * 4096)
    saves.CAP_MB = 0
    check("backup refuses past the cap (exit 4)", saves.backup() == saves.EXIT_CAP)
    shutil.rmtree(root)
    bad = [n for n, ok in checks if not ok]
    print(f"saves selftest: {'green' if not bad else 'FAILED: ' + ', '.join(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
