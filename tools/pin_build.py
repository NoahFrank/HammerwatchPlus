#!/usr/bin/env python3
"""pin_build.py - read the installed HoH2 build, and (re)pin gamelab/build_id.json.

    pin_build.py --show                  # live values vs the pin, exit 3 on mismatch
    pin_build.py --reason "<why>"        # rewrite the pin; the reason is required

Re-pinning means the dumps in gamecode/ are stale: re-run `python tools/bootstrap.py
--force` before trusting anything extracted. The pin is GameLab's single source of truth;
`gamelab.launcher` refuses to start a run on mismatch (EXIT_BUILD_MISMATCH = 3).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamepaths  # noqa: E402

PIN = gamepaths.GAMELAB / "build_id.json"
EXIT_BUILD_MISMATCH = 3
COMPARED = ("build_id", "exe_sha256")


def pe_timestamp(exe: Path) -> int:
    data = exe.read_bytes()[:4096]
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    return struct.unpack_from("<I", data, pe + 8)[0]


def live() -> dict:
    game = gamepaths.hoh2_dir()
    acf = gamepaths.app_manifest(gamepaths.HOH2_APPID)
    exe = game / "HWR2.exe"
    return {
        "app_id": gamepaths.HOH2_APPID,
        "build_id": gamepaths.acf_value(acf, "buildid"),
        "exe_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
        "exe_pe_timestamp": pe_timestamp(exe),
    }


def pinned() -> dict | None:
    return json.loads(PIN.read_text(encoding="utf-8")) if PIN.is_file() else None


def mismatch() -> list[str]:
    """Fields where the install differs from the pin ([] when they agree)."""
    pin, now = pinned(), live()
    if pin is None:
        return ["no pin (gamelab/build_id.json missing)"]
    return [f"{k}: pinned {pin.get(k)} installed {now[k]}" for k in COMPARED if pin.get(k) != now[k]]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reason")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args(argv)
    if a.show or not a.reason:
        if not a.show:
            ap.error("--reason is required to re-pin (or use --show)")
        bad = mismatch()
        print(json.dumps(live(), indent=1))
        print("MISMATCH: " + "; ".join(bad) if bad else "matches the pin")
        return EXIT_BUILD_MISMATCH if bad else 0
    now = live()
    pin = {
        **now,
        "game_version": "Build 170",
        "engine": "Crackshell custom C++ (bgfx, SDL2, FMOD, Box2D, ozz) + AngelScript",
        "pinned_at": time.strftime("%Y-%m-%d"),
        "pinned_by": a.reason,
        "probe": {
            "build_id": f"steamapps/appmanifest_{gamepaths.HOH2_APPID}.acf::buildid",
            "exe_sha256": "sha256 of <install>/HWR2.exe",
            "game_version": "HWR2.exe.log line 2 'Build N: ...' (checked by the launcher on the live run)",
        },
    }
    PIN.write_text(json.dumps(pin, indent=1) + "\n", encoding="utf-8")
    print(f"pinned {pin['build_id']} ({pin['exe_sha256'][:12]}) -> {PIN.relative_to(gamepaths.REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
