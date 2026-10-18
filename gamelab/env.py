"""The three environments of gamelab/env/environments.json, resolved to real paths, and
the idempotent create/verify of every link the gamelab environment declares.

The gamelab environment is a game dir of its own (isolation mechanism "link"): copies of
HWR2.exe and its DLLs, res/ junctioned to the install, a fresh HWR2.exe.cfg from the mode's
settings profile, mods/ junctions into this repo, and its own saves/ and logs. Measured on
build 25509441 (docs/RE_NOTES.md 2026-10-17): the game reads its cfg and writes its log and
local saves next to the exe it was started from, not in the cwd or the install.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
import gamepaths  # noqa: E402

ENV_DIR = REPO / "gamelab" / "env"
ENVIRONMENTS = ENV_DIR / "environments.json"
SETTINGS = ENV_DIR / "settings"
GAME = ENV_DIR / "userdata" / "game"
COPIED = ("HWR2.exe",)          # plus every *.dll in the install root
HARDLINK_OVER = 8 * 1024 * 1024  # res/ files this big are hard links (assets.bin), smaller ones copies


def environments() -> dict:
    return json.loads(ENVIRONMENTS.read_text(encoding="utf-8"))


def install() -> Path:
    return gamepaths.hoh2_dir()


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def link_target(p: Path) -> Path | None:
    try:
        st = os.lstat(p)
    except OSError:
        return None
    if not (p.is_symlink() or bool(getattr(st, "st_file_attributes", 0) & 0x400)):
        return None
    return Path(os.path.normpath(os.readlink(p).removeprefix("\\\\?\\")))


def make_junction(link: Path, target: Path) -> None:
    link.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True, text=True)
    if r.returncode:
        raise OSError(f"mklink /J {link} {target}: {(r.stderr or r.stdout).strip()}")


def remove_junction(link: Path) -> None:
    subprocess.run(["cmd", "/c", "rmdir", str(link)], check=True, capture_output=True)


def copied_files() -> list[str]:
    return list(COPIED) + sorted(p.name for p in install().glob("*.dll"))


def ensure_junction(link: Path, target: Path, problems: list[str], fix: bool) -> None:
    have = link_target(link)
    if have is not None and have.resolve() == target.resolve():
        return
    if not fix:
        problems.append(f"{link} -> {have} (want {target})")
        return
    if have is not None:
        remove_junction(link)
    elif link.exists():
        problems.append(f"{link} is a real directory, not a junction; refusing to delete it")
        return
    make_junction(link, target)


def ensure_res(src: Path, dst: Path, problems: list[str], fix: bool) -> None:
    """res/ is a real directory of GameLab's own, not a junction: the game writes
    res/controls.cfg when bindings are saved, and through a junction that write would land
    in the user's install. Big archives are hard links (the same file, so nothing to
    re-verify while os.path.samefile holds); small files are sha256-verified copies;
    subdirectories are junctions."""
    if link_target(dst) is not None:
        if not fix:
            problems.append(f"{dst} is a junction into the install (the game could write through it)")
            return
        remove_junction(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        d = dst / f.name
        if f.is_dir():
            # read-only trees (assets/, language/, ...): junctions; the known write is a root file
            ensure_junction(d, f, problems, fix)
            continue
        if f.stat().st_size >= HARDLINK_OVER:
            if d.exists() and os.path.samefile(d, f):
                continue
            if fix:
                d.unlink(missing_ok=True)
                os.link(f, d)
            if not (d.exists() and os.path.samefile(d, f)):
                problems.append(f"res/{f.name} is not a hard link to the install's copy")
        else:
            if d.is_file() and sha256(d) == sha256(f):
                continue
            if fix:
                shutil.copy2(f, d)
            if not d.is_file() or sha256(d) != sha256(f):
                problems.append(f"res/{f.name} differs from the install's copy")
    for d in dst.iterdir():
        if not (src / d.name).exists() and d.name not in RES_OWN:
            problems.append(f"res/{d.name} exists only in GameLab (the game wrote it, or it is stale)")


RES_OWN = ("controls.cfg",)     # files the game may write into res/; GameLab's own, never the user's


def install_res_snapshot() -> dict[str, tuple[int, int]]:
    """{name: (size, mtime_ns)} of the install's res/: checked unchanged after every run."""
    return {f.name: (f.stat().st_size, f.stat().st_mtime_ns) for f in (install() / "res").iterdir()}


def link(fix: bool = True, mods: list[str] | None = None) -> list[str]:
    """Create (fix=True) and verify the gamelab game dir. Returns the problems left ([] = green).
    `mods` = extra repo mods to junction in besides the environment's own GameLab mods."""
    problems: list[str] = []
    env = environments()["gamelab"]
    game_install = install()
    GAME.mkdir(parents=True, exist_ok=True)
    ensure_res(game_install / "res", GAME / "res", problems, fix)
    for name in copied_files():
        src, dst = game_install / name, GAME / name
        if dst.is_file() and sha256(dst) == sha256(src):
            continue
        if fix:
            shutil.copy2(src, dst)
        if not dst.is_file() or sha256(dst) != sha256(src):
            problems.append(f"{dst.name} differs from the install's copy")
    wanted = list(env["mods"]) + list(mods or [])
    mods_dir = GAME / "mods"
    mods_dir.mkdir(exist_ok=True)
    for m in wanted:
        src = REPO / "mods" / m
        if not (src / "info.xml").is_file():
            problems.append(f"mods/{m} has no info.xml")
            continue
        ensure_junction(mods_dir / m, src, problems, fix)
    for p in list(mods_dir.iterdir()):
        t = link_target(p)
        if fix and p.name not in wanted and t is not None and (REPO / "mods") in t.parents:
            remove_junction(p)              # a previous scenario's mod under test: undeclared now
            continue
        if t is None:
            problems.append(f"{p} is not a junction into the repo (undeclared content in the GameLab mods dir)")
        elif (REPO / "mods") not in t.parents:
            problems.append(f"{p} points outside the repo: {t}")
    # The real install must not have been turned into a GameLab target by mistake.
    real_mods = game_install / "mods"
    if real_mods.is_dir():
        for p in real_mods.iterdir():
            if p.name.startswith("gamelab-"):
                problems.append(f"GameLab mod {p.name} found in the real install's mods/ (forbidden in vanilla/modded-prod)")
    return problems


def write_profile(mode: str) -> Path:
    """Fresh copy of the mode's settings profile into the game dir (copy_fresh link)."""
    src = SETTINGS / mode / "HWR2.exe.cfg"
    dst = GAME / "HWR2.exe.cfg"
    shutil.copy2(src, dst)
    return dst


def cvars(text: str) -> dict[str, str]:
    out = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if parts:
            out[parts[0]] = parts[1] if len(parts) > 1 else ""
    return out
