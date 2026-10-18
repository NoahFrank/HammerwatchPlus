"""Where everything is: the repo layout, the HoH2 install, and the player's real user data.

Discovery goes through Steam (registry -> libraryfolders.vdf -> appmanifest), never a
hard-coded list. `HWP_HOH2_DIR` / `HWP_HOH1_DIR` override the install dirs.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODS = REPO / "mods"
DOCS = REPO / "docs"
GAMECODE = REPO / "gamecode"
GAMELAB = REPO / "gamelab"
TOOLS = REPO / "tools"
TOOLS_BIN = TOOLS / "bin"
SAVES_BACKUP = REPO / "saves-backup"
SCREENSHOTS = REPO / ".screenshots"

HOH2_APPID = "619820"
HOH1_APPID = "677120"
STEAMID64_BASE = 76561197960265728


def steam_root() -> Path | None:
    if sys.platform == "win32":
        import winreg
        for hive, key in ((winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam"),
                          (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Valve\Steam")):
            try:
                with winreg.OpenKey(hive, key) as k:
                    for name in ("InstallPath", "SteamPath"):
                        try:
                            p = Path(winreg.QueryValueEx(k, name)[0])
                            if p.is_dir():
                                return p
                        except OSError:
                            pass
            except OSError:
                pass
    for p in (Path.home() / ".steam/steam", Path.home() / ".local/share/Steam"):
        if p.is_dir():
            return p
    return None


def library_folders() -> list[Path]:
    root = steam_root()
    if root is None:
        return []
    libs = [root]
    vdf = root / "steamapps" / "libraryfolders.vdf"
    if vdf.is_file():
        for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(encoding="utf-8", errors="replace")):
            p = Path(m.group(1).replace("\\\\", "\\"))
            if p not in libs:
                libs.append(p)
    return libs


def app_manifest(appid: str) -> Path | None:
    for lib in library_folders():
        p = lib / "steamapps" / f"appmanifest_{appid}.acf"
        if p.is_file():
            return p
    return None


def acf_value(path: Path, key: str) -> str | None:
    m = re.search(rf'"{key}"\s+"([^"]*)"', path.read_text(encoding="utf-8", errors="replace"))
    return m.group(1) if m else None


def _install(appid: str, env: str, exe: str) -> Path | None:
    if os.environ.get(env):
        return Path(os.environ[env])
    acf = app_manifest(appid)
    if acf is None:
        return None
    d = acf.parent / "common" / (acf_value(acf, "installdir") or "")
    return d if (d / exe).is_file() else None


def hoh2_dir(required: bool = True) -> Path | None:
    d = _install(HOH2_APPID, "HWP_HOH2_DIR", "HWR2.exe")
    if d is None and required:
        sys.exit("Heroes of Hammerwatch II install not found (Steam app 619820); set HWP_HOH2_DIR")
    return d


def hoh1_dir(required: bool = True) -> Path | None:
    d = _install(HOH1_APPID, "HWP_HOH1_DIR", "HWR.exe")
    if d is None and required:
        sys.exit("Heroes of Hammerwatch (1) install not found; set HWP_HOH1_DIR")
    return d


def steam_account_id() -> str | None:
    """32-bit account id of the install's last owner: the Steam userdata/<id> folder."""
    acf = app_manifest(HOH2_APPID)
    owner = acf_value(acf, "LastOwner") if acf else None
    return str(int(owner) - STEAMID64_BASE) if owner and owner.isdigit() and int(owner) > STEAMID64_BASE else None


def real_save_dirs() -> dict[str, Path]:
    """Every directory the game keeps the player's saves in, by a stable name.
    cloud: Steam Remote Storage (g_save_slot_cloud 1); local: <install>/saves (cloud 0);
    game_backups: the game's own rotating backups."""
    out: dict[str, Path] = {}
    root, acct = steam_root(), steam_account_id()
    if root and acct:
        out["cloud"] = root / "userdata" / acct / HOH2_APPID / "remote" / "saves"
    game = hoh2_dir(required=False)
    if game:
        out["local"] = game / "saves"
    if os.environ.get("LOCALAPPDATA"):
        out["game_backups"] = Path(os.environ["LOCALAPPDATA"]) / "HeroesofHammerwatch2" / "save_backups"
    return out


def real_config() -> Path:
    return hoh2_dir() / "HWR2.exe.cfg"


# Names the content tools (build.py, import_hoh1.py) use.
MODULES = MODS
DIST = REPO / "dist"
BASE_HOH2 = GAMECODE / "sdk" / "hoh2"
BASE_HOH1 = GAMECODE / "sdk" / "hoh1"


def module_dirs() -> list[Path]:
    """Every mods/<id>/ that has an info.xml and is a HammerwatchPlus content module
    (GameLab's own mods are gamelab-*), sorted by id."""
    return sorted(p for p in MODS.iterdir()
                  if p.is_dir() and (p / "info.xml").is_file() and not p.name.startswith("gamelab-"))
