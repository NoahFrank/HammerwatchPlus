"""Shared path discovery for the HammerwatchPlus tools."""
from __future__ import annotations

import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODULES = REPO / "modules"
DIST = REPO / "dist"
BASE_HOH2 = REPO / ".base"
BASE_HOH1 = REPO / ".base-hoh1"

STEAM_COMMON_CANDIDATES = [
    r"C:\Program Files (x86)\Steam\steamapps\common",
    r"C:\Program Files\Steam\steamapps\common",
    r"D:\SteamLibrary\steamapps\common",
    r"E:\SteamLibrary\steamapps\common",
    os.path.expanduser("~/.steam/steam/steamapps/common"),
    os.path.expanduser("~/.local/share/Steam/steamapps/common"),
]
HOH2_DIRNAME = "Heroes of Hammerwatch 2"
HOH1_DIRNAME = "Heroes of Hammerwatch"


def _find_game(env_var: str, dirname: str, exe: str) -> Path | None:
    override = os.environ.get(env_var)
    if override:
        return Path(override)
    for common in STEAM_COMMON_CANDIDATES:
        candidate = Path(common) / dirname
        if (candidate / exe).is_file():
            return candidate
    return None


def hoh2_dir(required: bool = True) -> Path | None:
    """Heroes of Hammerwatch II install dir (override with HWP_HOH2_DIR)."""
    d = _find_game("HWP_HOH2_DIR", HOH2_DIRNAME, "HWR2.exe")
    if d is None and required:
        sys.exit("Heroes of Hammerwatch II install not found; set HWP_HOH2_DIR")
    return d


def hoh1_dir(required: bool = True) -> Path | None:
    """Heroes of Hammerwatch (1) install dir (override with HWP_HOH1_DIR)."""
    d = _find_game("HWP_HOH1_DIR", HOH1_DIRNAME, "HWR.exe")
    if d is None and required:
        sys.exit("Heroes of Hammerwatch (1) install not found; set HWP_HOH1_DIR")
    return d


def module_dirs() -> list[Path]:
    """Every modules/<id>/ that has an info.xml, sorted by id."""
    return sorted(p for p in MODULES.iterdir() if p.is_dir() and (p / "info.xml").is_file())
