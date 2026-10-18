"""Where everything is: the repo layout, the HoH2 install, and the player's real user data.

Discovery goes through Steam (registry -> libraryfolders.vdf -> appmanifest), never a
hard-coded list. Overrides: `HWP_HOH2_DIR` / `HWP_HOH1_DIR` (install dirs), `HWP_STEAM_DIR`
(Steam root: userdata/ and steamapps/ under it), `HWP_LOCALAPPDATA` (where the game's
own save_backups/ live) and `HWP_PATHS_LOCAL` (the machine-local answers file, default
tools/paths.local.json). tools/doctor_selftest.py points them at a sandbox.

HoH1 is optional and may live in another Steam library or outside Steam: find_hoh1() also
uses the path the user gave (`python -m gamelab doctor --hoh1 <dir>`) and searches.
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
    if os.environ.get("HWP_STEAM_DIR"):
        return Path(os.environ["HWP_STEAM_DIR"])
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


def local_paths_file() -> Path:
    """Machine-local answers the user gave (gitignored): {"hoh1_dir": str|null, "no_hoh1": bool}.
    HWP_PATHS_LOCAL points it elsewhere (the selftests' sandbox)."""
    return Path(os.environ.get("HWP_PATHS_LOCAL") or TOOLS / "paths.local.json")


def local_paths() -> dict:
    import json
    f = local_paths_file()
    try:
        data = json.loads(f.read_text(encoding="utf-8")) if f.is_file() else {}
    except (OSError, ValueError):
        data = {}
    return data if isinstance(data, dict) else {}


def save_local_paths(**values) -> Path:
    import json
    import time
    data = local_paths()
    data.update(values, updated=time.strftime("%Y-%m-%dT%H:%M:%S"))
    f = local_paths_file()
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    return f


def valid_hoh1(d: Path | None) -> bool:
    return d is not None and (d / "HWR.exe").is_file() and (d / "res" / "assets.bin").is_file()


def find_hoh1() -> tuple[Path | None, str]:
    """(install dir, how it was found). Order: HWP_HOH1_DIR (taken as given), the Steam
    appmanifest in any library, the path the user gave (`doctor --hoh1`, tools/paths.local.json),
    a sibling of the HoH2 install holding HWR.exe, then every library's steamapps/common/.
    Everything but the env override must have HWR.exe and res/assets.bin."""
    if os.environ.get("HWP_HOH1_DIR"):
        return Path(os.environ["HWP_HOH1_DIR"]), "HWP_HOH1_DIR"
    acf = app_manifest(HOH1_APPID)
    if acf is not None:
        d = acf.parent / "common" / (acf_value(acf, "installdir") or "")
        if valid_hoh1(d):
            return d, f"Steam appmanifest ({acf})"
    given = local_paths().get("hoh1_dir")
    if given and valid_hoh1(Path(given)):
        return Path(given), f"path you gave ({local_paths_file().name})"
    commons = []
    game = hoh2_dir(required=False)
    if game is not None:
        commons.append((game.parent, "next to the HoH2 install"))
    commons += [(lib / "steamapps" / "common", f"Steam library {lib}") for lib in library_folders()]
    seen = set()
    for common, how in commons:
        if not common.is_dir() or common in seen:
            continue
        seen.add(common)
        for d in sorted(common.iterdir()):
            if d.is_dir() and d != game and valid_hoh1(d):
                return d, f"search: {how}"
    return None, "not found"


def hoh1_declined() -> bool:
    """The user said they do not have HoH1 (`doctor --no-hoh1`): HoH1 content is skipped."""
    return bool(local_paths().get("no_hoh1"))


def hoh1_dir(required: bool = True) -> Path | None:
    d = find_hoh1()[0]
    if d is None and required:
        sys.exit("Heroes of Hammerwatch (1) install not found; run `python -m gamelab doctor --hoh1 <dir>` "
                 "or set HWP_HOH1_DIR")
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
    appdata = os.environ.get("HWP_LOCALAPPDATA") or os.environ.get("LOCALAPPDATA")
    if appdata:
        out["game_backups"] = Path(appdata) / "HeroesofHammerwatch2" / "save_backups"
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
