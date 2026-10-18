"""Is this machine ready for GameLab? Every prerequisite a fresh clone lacks, checked in
dependency order, with the safe ones fixed on request.

    python -m gamelab doctor                    # report only, change nothing
    python -m gamelab doctor --fix              # + uv sync, confirm saves when unambiguous, bootstrap.py, env_link.py
    python -m gamelab doctor --confirm-saves    # human override: confirm despite AMBIGUOUS save lines
    python -m gamelab doctor --confirm-saves --no-saves-yet   # this player has never saved
    python -m gamelab doctor --hoh1 "<dir>"     # the user told you where HoH1 is: check it, remember it
    python -m gamelab doctor --no-hoh1          # the user does not have HoH1: stop asking, skip its content
    python -m gamelab doctor --smoke            # boot null-payload now (--fix does it once per machine setup)

--fix never writes the user's saves, config or install: bootstrap writes gamecode/ and
tools/bin/ (the patched PACKAGER is a copy there, not in the install), env_link writes
gamelab/env/userdata/, tools/class_units.py writes the class-swapped base units into
mods/keys/ and mods/pets/, and tools/import_hoh1.py (pets, levels, campaign, classes; only
the ones whose output is missing, never --force) writes the HoH1 content into mods/ and
hoh1_import/, and tools/make_pet_dyes.py the dye-ready pet copies into mods/pets/. All of
those are gitignored.

Last, the smoke boot: once everything it needs is green, --fix runs the null-payload
scenario in lab mode and turns a failure into its plain cause (antivirus blocking the shim,
no OpenGL on the hidden desktop, blank frames, too few cores, a window leaking onto the
real desktop). A pass is stamped in gamelab/smoke.local.json (gitignored) with the build,
shim source, core count and GPUs; a change to any of them asks for a new boot.

HoH1 is optional but never guessed: when Steam and the search next to HoH2 do not find it
and the user has not answered yet, doctor is NOT green and says what to ask. The answer
goes to tools/paths.local.json (gitignored) via --hoh1 or --no-hoh1. Confirming saves only reads the real save dirs, copies them to
saves-backup/<ts>/, re-hashes the copy, runs tools/saves_selftest.py on a sandbox and
writes saves-backup/confirmed.json. The launcher refuses (exit 2) until that stamp exists.

--fix confirms by itself when assess_saves() finds nothing ambiguous: files exist, the dir
the player's config writes (cloud or local) has files, no other Steam account holds HoH2
saves, and no unknown save* dir in the install holds files. Anything else is printed as
AMBIGUOUS and left to a person (--confirm-saves), because only they know the answer.

Exit 0 when everything is green, 2 otherwise. Imports stdlib only, so it runs before
`uv sync` has.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))
import gamepaths  # noqa: E402
import pin_build  # noqa: E402
import saves  # noqa: E402

VENV_PY = REPO / ".venv" / "Scripts" / "python.exe"
PY_DEPS = ("lz4", "pefile", "PIL")        # pyproject.toml dependencies, by import name
BOOTSTRAP_FREE_GB = 3                     # gamecode/ is ~1 GB unpacked, plus PACKAGER scratch


class Report:
    def __init__(self):
        self.rows: list[tuple[str, bool, str]] = []

    def check(self, name: str, ok: bool, detail: str = "", hint: str = "") -> bool:
        """`hint` is printed only when the check fails."""
        detail = detail if ok or not hint else hint
        self.rows.append((name, ok, detail))
        print(f"  [{'ok' if ok else 'NO'}] {name}" + (f"  -- {detail}" if detail else ""), flush=True)
        return ok

    def info(self, text: str) -> None:
        print(f"  [..] {text}", flush=True)

    @property
    def green(self) -> bool:
        return all(ok for _, ok, _ in self.rows)


def python() -> str:
    return str(VENV_PY) if VENV_PY.is_file() else sys.executable


def run_py(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run([python(), *args], cwd=REPO, capture_output=True, text=True)


def deps_missing(py: str) -> list[str]:
    code = f"import importlib.util as u; print(','.join(m for m in {PY_DEPS!r} if not u.find_spec(m)))"
    r = subprocess.run([py, "-c", code], capture_output=True, text=True)
    return [m for m in r.stdout.strip().split(",") if m] if r.returncode == 0 else list(PY_DEPS)


def process_running(image: str) -> bool:
    r = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {image}", "/NH", "/FO", "CSV"],
                       capture_output=True, text=True)
    return f'"{image.lower()}"' in r.stdout.lower()


def gcc_target() -> str | None:
    gcc = shutil.which("gcc")
    if not gcc:
        return None
    return subprocess.run([gcc, "-dumpmachine"], capture_output=True, text=True).stdout.strip() or None


def other_steam_accounts() -> list[str]:
    """Steam userdata accounts other than the install's LastOwner that hold HoH2 saves."""
    root, mine = gamepaths.steam_root(), gamepaths.steam_account_id()
    if root is None or not (root / "userdata").is_dir():
        return []
    out = []
    for acct in (root / "userdata").iterdir():
        d = acct / gamepaths.HOH2_APPID / "remote" / "saves"
        if acct.name != mine and d.is_dir() and any(f.is_file() for f in d.rglob("*")):
            out.append(acct.name)
    return out


def live_save_dir() -> str | None:
    """Which real save dir the player's own config writes: "cloud" or "local" (None: no cfg)."""
    if gamepaths.hoh2_dir(required=False) is None or not gamepaths.real_config().is_file():
        return None
    from gamelab import env
    cloud = env.cvars(gamepaths.real_config().read_text(encoding="utf-8", errors="replace")).get("g_save_slot_cloud", "1")
    return "cloud" if cloud in ("1", "true") else "local"


def count_files(d: Path) -> int:
    return sum(1 for f in d.rglob("*") if f.is_file()) if d.is_dir() else 0


def assess_saves(no_saves_yet: bool = False) -> tuple[dict[str, int], list[str]]:
    """({save dir name: file count}, ambiguities). No ambiguities means the backup covers
    everything a person could point at, so it is confirmed without asking."""
    dirs = gamepaths.real_save_dirs()
    counts = {name: count_files(d) for name, d in dirs.items()}
    total = sum(counts.values())
    amb = []
    if total == 0 and not no_saves_yet:
        amb.append("no save files in any save dir: either this player has never saved (--no-saves-yet) "
                   "or the dirs resolved wrong (Steam account, HWP_HOH2_DIR)")
    others = other_steam_accounts()
    if others:
        amb.append(f"other Steam accounts on this PC have HoH2 saves and are not backed up: {others} "
                   f"(backing up {gamepaths.steam_account_id()}, the install's LastOwner)")
    live = live_save_dir()
    if live and not (total == 0 and no_saves_yet):
        if live not in dirs:
            amb.append(f"the player's config saves to {live}, but that dir could not be resolved (Steam account unknown?)")
        elif counts[live] == 0:
            amb.append(f"the player's config saves to {live} ({dirs[live]}), which has no files")
    game = gamepaths.hoh2_dir(required=False)
    if game:
        known = {d.resolve() for d in dirs.values()}
        for d in sorted(game.iterdir()):
            if d.is_dir() and d.name.lower().startswith("save") and d.resolve() not in known and count_files(d):
                amb.append(f"{d} holds {count_files(d)} files and is not a save dir GameLab knows about")
    return counts, amb


def save_summary(r: Report) -> tuple[int, list[str]]:
    """Print every real save dir with its file count and the ambiguities; return (total, ambiguities)."""
    counts, amb = assess_saves()
    for name, d in gamepaths.real_save_dirs().items():
        r.info(f"saves {name}: {counts[name]} files in {d}" + ("" if d.is_dir() else " (absent)"))
    r.info(f"Steam account (install LastOwner): {gamepaths.steam_account_id() or 'unknown'}; "
           f"the player's config saves to {live_save_dir() or 'unknown (no config)'}")
    for a in amb:
        r.info(f"AMBIGUOUS: {a}")
    return sum(counts.values()), amb


def confirm_saves(r: Report, no_saves_yet: bool, auto: bool) -> bool:
    """Back up, prove the backup, write the stamp. auto: only when nothing is ambiguous
    (--fix); otherwise the human ran --confirm-saves and the ambiguities are recorded as overridden."""
    counts, amb = assess_saves(no_saves_yet)
    total = sum(counts.values())
    if auto and amb:
        r.check("saves unambiguous (auto-confirm)", False,
                hint="ask the user about the AMBIGUOUS lines above; if the backup is still what they want, "
                     "`python -m gamelab doctor --confirm-saves` (add --no-saves-yet if they never saved)")
        return False
    if not r.check("save files found", total > 0 or no_saves_yet,
                   f"{total} files" if total else "none, --no-saves-yet given",
                   hint="none found: pass --no-saves-yet if this player has never saved"):
        return False
    st = run_py([str(REPO / "tools" / "saves_selftest.py")])
    if not r.check("backup/verify/restore selftest (sandboxed)", st.returncode == 0,
                   (st.stdout.strip().splitlines() or ["no output"])[-1]):
        print(st.stdout + st.stderr)
        return False
    if not r.check("backup taken", saves.backup(quiet=True) == 0, hint="saves-backup/ cap or copy failure"):
        return False
    ref = saves.backups()[-1]
    damaged = saves.intact(ref)
    if not r.check(f"backup copy re-hashed (saves-backup/{ref.name})", not damaged, ", ".join(damaged[:5])):
        return False
    if not r.check("real saves match the backup", saves.verify(ref) == 0):
        return False
    stamp = {"confirmed_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "confirmed_by": "doctor --fix" if auto else "human",
             "backup": ref.name, "sources": {k: str(v) for k, v in gamepaths.real_save_dirs().items()},
             "steam_account": gamepaths.steam_account_id(), "files": counts,
             "no_saves_yet": no_saves_yet, "ambiguities_overridden": amb}
    (gamepaths.SAVES_BACKUP / saves.CONFIRMED).write_text(json.dumps(stamp, indent=1) + "\n", encoding="utf-8")
    r.info(f"saves confirmed ({stamp['confirmed_by']}); restore with "
           f"`python tools/saves.py restore --from {ref.name}`")
    return True


HOH1_ASK = ("not found through Steam or next to the HoH2 install. ASK THE USER: \"Where is Heroes of "
            "Hammerwatch (1) installed (the folder with HWR.exe)? Or don't you own it?\" Then "
            "`python -m gamelab doctor --hoh1 \"<that folder>\" --fix`, or `python -m gamelab doctor --no-hoh1` "
            "if they don't have it. Never guess a path")


def hoh1_state() -> tuple[str, Path | None, str]:
    """(state, dir, how): found | invalid (HWP_HOH1_DIR points at no install) | declined | pending."""
    d, how = gamepaths.find_hoh1()
    if d is not None:
        return ("found" if gamepaths.valid_hoh1(d) else "invalid"), d, how
    return ("declined" if gamepaths.hoh1_declined() else "pending"), None, how


def hoh1_check(r: Report) -> tuple[str, Path | None, str]:
    """The HoH1 row: green when found or declined; a pending question is NOT green."""
    hoh1 = hoh1_state()
    state, d, how = hoh1
    if state == "found":
        r.check("HoH1 install (optional)", True, f"{d} ({how})")
    elif state == "invalid":
        r.check("HoH1 install (optional)", False,
                hint=f"HWP_HOH1_DIR={d} has no HWR.exe + res/assets.bin: fix or unset it")
    elif state == "declined":
        r.check("HoH1 install (optional)", True, "skipped: the user has no HoH1 (recorded with --no-hoh1)")
    else:
        r.check("HoH1 install (optional)", False, hint=HOH1_ASK)
    return hoh1


def record_hoh1(path: str | None, no_hoh1: bool) -> bool:
    """--hoh1 / --no-hoh1: check the user's answer and write it to tools/paths.local.json."""
    if no_hoh1:
        f = gamepaths.save_local_paths(hoh1_dir=None, no_hoh1=True)
        print(f"  [ok] recorded: no HoH1 on this machine ({f}); HoH1 content is skipped. "
              f"`--hoh1 <dir>` undoes it")
        return True
    p = Path(path.strip().strip('"')).expanduser()
    if p.is_file() and p.name.lower() == "hwr.exe":
        p = p.parent
    p = p.resolve() if p.exists() else p
    if not gamepaths.valid_hoh1(p):
        print(f"  [NO] {p} is not a Heroes of Hammerwatch (1) install: it needs HWR.exe and res/assets.bin. "
              f"Nothing recorded; ask the user again (HoH2's folder, with HWR2.exe, is not it)")
        return False
    f = gamepaths.save_local_paths(hoh1_dir=str(p), no_hoh1=False)
    print(f"  [ok] recorded HoH1 install {p} ({f})")
    used, how = gamepaths.find_hoh1()
    if used is not None and used != p:
        print(f"  [..] note: {used} ({how}) comes first in discovery and is the one used")
    return True


def has_files(d: Path) -> bool:
    return d.is_dir() and any(f.is_file() for f in d.rglob("*"))


def class_units_problems() -> tuple[list[str], int]:
    """(units missing or different from what tools/class_units.py would write, units expected).
    Same rules as class_units.generate, read only."""
    import class_units
    bad, total = [], 0
    for mod in gamepaths.module_dirs():
        mj = mod / "module.json"
        swaps = (json.loads(mj.read_text(encoding="utf-8")).get("class_swaps") or {}) if mj.is_file() else {}
        for rel in class_units.units_for(swaps):
            total += 1
            src = (gamepaths.BASE_HOH2 / rel).read_text(encoding="utf-8", errors="replace")
            want = (f"{class_units.GENERATED} from the base unit, with our script class -->\n"
                    + class_units.swap(src, swaps)).encode("utf-8")
            out = mod / rel
            if not out.is_file() or out.read_bytes() != want:
                bad.append(f"mods/{mod.name}/{rel}")
    return bad, total


# import_hoh1.py importers in the order --fix runs them (none reads another's output),
# with the files that show it ran. levels and campaign read gamecode/sdk/hoh2/.
PETS, CAMPAIGN, CLASSES = gamepaths.MODS / "pets", gamepaths.MODS / "campaign", gamepaths.MODS / "classes"
HOH1_IMPORT = REPO / "hoh1_import" / "campaign"
CAMPAIGN_MISSION = CAMPAIGN / "tweak" / "hwp" / "missions" / "missions_hwp_forsaken_tower_hoh1.sval"
HOH1_CLASSES = ("thief", "gladiator", "witchhunter")
IMPORTS = {
    "pets": lambda: [PETS / "tweak" / "hwp" / "pets_hoh1.sval", PETS / "gui" / "hwp" / "icons_pets_hoh1.png",
                     PETS / "players" / "pets" / "hwp" / "living_flame.unit"],
    "levels": lambda: [HOH1_IMPORT / "report.json", HOH1_IMPORT / "report.md",
                       HOH1_IMPORT / "levels" / "boss_mines.json"],
    "campaign": lambda: [CAMPAIGN / "hoh1" / ".hwp-generated", CAMPAIGN_MISSION, HOH1_IMPORT / "convert.md"],
    "classes": lambda: [CLASSES / "hoh1art" / "players" / "hwp" / c / f
                        for c in HOH1_CLASSES for f in ("class_showcase.png", "icons.png")],
}
NEEDS_BASE = {"levels", "campaign"}


def import_missing(name: str) -> list[str]:
    return [str(p.relative_to(REPO)) for p in IMPORTS[name]() if not p.is_file()]


def campaign_foreign() -> bool:
    """mods/campaign/hoh1 exists but import_hoh1.py did not write it: it refuses without --force."""
    out = CAMPAIGN / "hoh1"
    older = CAMPAIGN_MISSION.is_file() and "Generated by tools/import_hoh1.py campaign" in \
        CAMPAIGN_MISSION.read_text(encoding="utf-8", errors="replace")
    return out.exists() and not (out / ".hwp-generated").is_file() and not older


def local_content(r: Report, fix: bool, hoh1: tuple[str, Path | None, str]) -> None:
    base_ok = (gamepaths.BASE_HOH2 / "scripts").is_dir() and (gamepaths.BASE_HOH2 / "system").is_dir()
    if not base_ok:
        r.check("class-swapped base units (class_units.py)", False,
                hint="needs gamecode/sdk/hoh2/ first (bootstrap.py, above)")
    else:
        bad, total = class_units_problems()
        if bad and fix:
            r.info(f"running tools/class_units.py ({len(bad)} of {total} units missing or stale)")
            c = run_py([str(REPO / "tools" / "class_units.py")])
            r.info(f"class_units.py exit {c.returncode}: {' | '.join(c.stdout.strip().splitlines()[-3:])}")
            if c.returncode:
                print(c.stdout[-2000:] + c.stderr[-2000:])
            bad, total = class_units_problems()
        r.check("class-swapped base units (class_units.py)", not bad,
                f"{len(bad)} of {total} missing or stale (first: {bad[:2]}); `python tools/class_units.py`"
                if bad else f"{total} units in mods/keys, mods/pets")

    hoh1_imports(r, fix, hoh1, base_ok)
    pet_dyes(r, fix, base_ok)


def pet_dyes(r: Report, fix: bool, base_ok: bool) -> None:
    """tools/make_pet_dyes.py: the dye-ready pet copies, vanilla pets from gamecode/sdk/hoh2/
    and the HoH1 ones from import_hoh1.py pets, so it runs after both (and again whenever
    either changes: its stamp holds every source's hash)."""
    label = "pet dye copies (make_pet_dyes.py)"
    if not base_ok:
        r.check(label, False, hint="needs gamecode/sdk/hoh2/ first (bootstrap.py, above)")
        return
    script = str(REPO / "tools" / "make_pet_dyes.py")
    v = run_py([script, "--verify"])
    if v.returncode and fix:
        r.info(f"running tools/make_pet_dyes.py ({v.stdout.strip().removeprefix('pet dyes: ')})")
        c = run_py([script])
        r.info(f"make_pet_dyes.py exit {c.returncode}: {' | '.join(c.stdout.strip().splitlines()[:2])}")
        if c.returncode:
            print(c.stdout[-2000:] + c.stderr[-2000:])
        v = run_py([script, "--verify"])
    detail = (v.stdout.strip().splitlines() or [v.stderr.strip()[-300:]])[-1]
    r.check(label, v.returncode == 0, detail, hint=f"{detail.removeprefix('pet dyes: ')}; `python tools/make_pet_dyes.py`")


def hoh1_imports(r: Report, fix: bool, hoh1: tuple[str, Path | None, str], base_ok: bool) -> None:
    state, d, _ = hoh1
    if state == "declined":
        r.info("HoH1 content (import_hoh1.py pets/levels/campaign/classes): skipped, no HoH1 recorded")
        return
    if state != "found":
        r.info("HoH1 content (import_hoh1.py pets/levels/campaign/classes): waits for the HoH1 answer above")
        return
    for name in IMPORTS:
        missing = import_missing(name)
        label = f"HoH1 {name} imported (import_hoh1.py {name})"
        if name == "campaign" and missing and campaign_foreign():
            r.check(label, False, hint=f"{CAMPAIGN / 'hoh1'} exists but import_hoh1.py did not write it (no "
                                       ".hwp-generated marker): ask the user whether it can be moved away; "
                                       "doctor does not --force over it")
            continue
        if missing and fix and (base_ok or name not in NEEDS_BASE):
            r.info(f"running tools/import_hoh1.py {name}")
            t0 = time.time()
            c = run_py([str(REPO / "tools" / "import_hoh1.py"), name, "--hoh1", str(d)])
            r.info(f"import_hoh1.py {name} exit {c.returncode} in {time.time() - t0:.0f}s")
            if c.returncode:
                print(c.stdout[-2000:] + c.stderr[-2000:])
            missing = import_missing(name)
        hint = (f"missing {missing[:2]}" + ("; needs gamecode/sdk/hoh2/ (bootstrap.py)" if name in NEEDS_BASE
                                             and not base_ok else f"; `python tools/import_hoh1.py {name}`"))
        r.check(label, not missing, "present", hint=hint)


SMOKE_STAMP = REPO / "gamelab" / "smoke.local.json"
SMOKE_TIMEOUT = 900
# rows the smoke boot does not need: content the null-payload scenario never loads
NOT_SMOKE_PREREQS = ("HoH1", "pet dye", "class-swapped", "gamecode/sdk/hoh1", "smoke boot")


def gpus() -> list[str]:
    """Display adapters (the display device class in the registry), as Windows names them."""
    import winreg
    out = []
    cls = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, cls) as k:
            for i in range(winreg.QueryInfoKey(k)[0]):
                sub = winreg.EnumKey(k, i)
                if not sub.isdigit():
                    continue
                try:
                    with winreg.OpenKey(k, sub) as s:
                        out.append(str(winreg.QueryValueEx(s, "DriverDesc")[0]))
                except OSError:
                    pass
    except OSError:
        pass
    return sorted(set(out))


def remote_session() -> bool:
    import ctypes
    return bool(ctypes.windll.user32.GetSystemMetrics(0x1000))    # SM_REMOTESESSION


def lab_cores() -> tuple[int, int]:
    """(cores the GameLab job gets, cores the machine has): tools/hidden_desktop.py keeps two back."""
    total = os.cpu_count() or 4
    return max(1, total - 2), total


def smoke_key() -> dict:
    """What a smoke result depends on; any change means the machine has to prove itself again."""
    shim = REPO / "tools" / "capture_shim" / "hwr2_capture.c"
    import hashlib
    return {"build": (pin_build.pinned() or {}).get("build_id"), "cores": os.cpu_count(), "gpus": gpus(),
            "shim_source_sha256": hashlib.sha256(shim.read_bytes()).hexdigest() if shim.is_file() else None}


def smoke_stamp_problems() -> list[str]:
    try:
        st = json.loads(SMOKE_STAMP.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ["never passed on this machine"]
    if "failed" in st:
        f = st["failed"]
        return [f"the last smoke boot failed ({f.get('at')}, {f.get('run')}): {f.get('cause')}"]
    key = smoke_key()
    changed = [k for k in key if st.get("key", {}).get(k) != key[k]]
    return [f"passed before, but {', '.join(changed)} changed since"] if changed else []


def explain_smoke(code: int, run: dict | None, game_log: str, out: str) -> tuple[str, str]:
    """A failed smoke boot as (plain cause, what to do). ("", "") for a pass. Pure, so
    tools/doctor_selftest.py covers every branch without needing a broken machine."""
    if code == 0:
        return "", ""
    lab, total = lab_cores()
    tail = " | ".join(out.strip().splitlines()[-3:])
    if code == 2:
        pre = [ln.strip() for ln in out.splitlines() if ln.startswith("PREFLIGHT")]
        return "preflight refused", "; ".join(pre[:4]) or tail
    if code == 3:
        return "build mismatch", "Steam updated the game since the pin (see the pinned-build row above)"
    if code == 4:
        return ("another GameLab run holds the lock, or the last one left a dirty teardown",
                "find out why (gamelab/results/, the lock's reasons), then `python -m gamelab reset`")
    if run is None:
        return "the launcher stopped before writing run.json", tail
    err = run.get("error") or ""
    failed = [a for a in run.get("assertions", []) if not a["ok"]]
    names = {a["name"] for a in failed}
    if "could not inject" in err:
        return ("Windows refused to load the capture shim into the game",
                "almost always antivirus or EDR blocking DLL injection (CreateRemoteThread + LoadLibraryW): "
                f"allow-list {REPO / 'tools' / 'bin' / 'hwr2_capture.dll'} and "
                f"{REPO / 'gamelab' / 'env' / 'userdata' / 'game' / 'HWR2.exe'}; if no antivirus is involved, "
                "rebuild the shim with the 64-bit gcc (`python tools/bootstrap.py --force`)")
    if {"user config unchanged", "user saves unchanged", "install res/ unchanged"} & names:
        return ("the run changed the user's config, saves or install",
                "stop and report it: GameLab must never do this. The saves backup is in saves-backup/")
    if {"focus never left the user's window", "no game-tree window on the input desktop"} & names:
        return ("a game window reached the real desktop: the hidden desktop was not honoured",
                "remote desktop, or overlay / screen-recording software that moves windows between desktops; "
                "close it and retry")
    if err and not game_log.strip():
        return ("the game exited before writing its log",
                "Steam must be running and logged into an account that owns HoH2; antivirus can also kill a "
                f"process that was started suspended and injected. Runner said: {err[:200]}")
    if "Opening SDL window" in game_log and "BGFX initialized" not in game_log:
        return ("the renderer did not start on the hidden desktop (no OpenGL 3.2 context)",
                "update the GPU driver; on a laptop with two GPUs set HWR2.exe and python.exe to the dedicated "
                "one (Windows Settings > Display > Graphics); remote desktop sessions often have no OpenGL 3.2")
    if any(n.startswith("shot ") for n in names):
        return ("the game ran but its captured frames were blank or missing",
                "the GPU driver does not render on a non-interactive desktop (seen with remote desktop and some "
                "hybrid-GPU laptops); update the driver or select the dedicated GPU for HWR2.exe")
    if run.get("verdict") == "TIMEOUT" or code == 6 or "never loaded" in err:
        return (f"too slow: the deadline passed (the GameLab job gets {lab} of {total} cores, at idle priority)",
                "close heavy programs and retry; idle priority yields to everything else, so a busy "
                "machine starves the game" + ("; with this few cores GameLab is marginal" if lab < 2 else ""))
    if "probe never booted" in err:
        return "the GameLab probe mods did not load", err[:300]
    if "not isolated" in err:
        return ("the game started but the isolation checks failed (shim hooks or job object)",
                f"{err[:300]}; antivirus that hooks processes can stop the shim's hooks")
    detail = err or "; ".join(f"{a['name']}: {str(a.get('detail', ''))[:80]}" for a in failed[:3])
    return f"{run.get('verdict', 'FAIL')} for another reason", detail or tail


def own_dirty_teardown(r: Report) -> None:
    """A failed smoke boot can leave the GameLab lock refusing (exit 4: the game exited
    non-zero). When the dirty teardown is that same doctor run, whose cause was already
    reported, clear it with `python -m gamelab reset`; any other dirty teardown is left
    for a person to look at, as exit 4 demands."""
    from gamelab import lock
    try:
        st = json.loads(SMOKE_STAMP.read_text(encoding="utf-8"))
        td = json.loads(lock.TEARDOWN.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return
    failed = st.get("failed", {}).get("run")
    if failed and not td.get("clean", True) and td.get("run") == failed and not lock.LOCK.exists():
        r.info(f"clearing the dirty teardown left by doctor's own failed smoke boot {failed} "
               f"({'; '.join(td.get('reasons', []))}): `python -m gamelab reset`")
        c = run_py(["-m", "gamelab", "reset"])
        r.info(c.stdout.strip().splitlines()[-1] if c.stdout.strip() else f"reset exit {c.returncode}")


def smoke(r: Report, fix: bool, force: bool) -> None:
    """Boot the null-payload scenario once on the hidden desktop: the one check that proves
    this machine's GPU, antivirus and core count let GameLab work at all."""
    lab, total = lab_cores()
    adapters = gpus()
    r.info(f"{total} cores (GameLab gets {lab}); GPU: {', '.join(adapters) or 'unknown'}")
    if remote_session():
        r.info("this is a remote desktop session: OpenGL on a hidden desktop often fails here")
    label = "smoke boot: null-payload in lab mode"
    stale = smoke_stamp_problems()
    blockers = [n for n, ok, _ in r.rows if not ok and not n.startswith(NOT_SMOKE_PREREQS)]
    if not force and not (fix and stale):
        if stale:
            r.check(label, False, hint=f"{stale[0]}: --fix boots it once (~15-60 s)")
        else:
            st = json.loads(SMOKE_STAMP.read_text(encoding="utf-8"))
            r.check(label, True, f"passed {st.get('at', '')} ({st.get('run')})")
        return
    if blockers and not force:   # --smoke boots anyway: the launcher's own preflight still refuses unsafe runs
        r.check(label, False, hint=f"not run until these are green: {', '.join(blockers)} (or --smoke)")
        return
    own_dirty_teardown(r)
    scen = os.environ.get("HWP_SMOKE_SCENARIO", "null-payload")    # test hook: a scenario path
    stem = Path(scen).stem
    results = REPO / "gamelab" / "results"
    before = set(results.glob(f"*-{stem}-lab")) if results.is_dir() else set()
    r.info(f"running `python -m gamelab run {scen} --mode lab` (hidden, muted)")
    t0 = time.time()
    try:
        c = subprocess.run([python(), "-m", "gamelab", "run", scen, "--mode", "lab"], cwd=REPO,
                           capture_output=True, text=True, timeout=SMOKE_TIMEOUT)
        code, out = c.returncode, c.stdout + c.stderr
    except subprocess.TimeoutExpired as e:
        code, out = 6, f"{e.stdout or ''}\ndoctor gave up after {SMOKE_TIMEOUT}s"
    new = sorted(set(results.glob(f"*-{stem}-lab")) - before) if results.is_dir() else []
    run_json = new[-1] / "run.json" if new else None
    run = json.loads(run_json.read_text(encoding="utf-8")) if run_json and run_json.is_file() else None
    logs = sorted(new[-1].glob("logs/pass*.HWR2.exe.log")) if new else []
    game_log = logs[-1].read_text(encoding="utf-8", errors="replace") if logs else ""
    cause, hint = explain_smoke(code, run, game_log, out)
    where = f" ({new[-1].relative_to(REPO)})" if new else ""
    if cause:
        # remembered, so plain doctor repeats the cause and the next boot can clear the dirty
        # teardown this run may leave (own_dirty_teardown); never a pass
        SMOKE_STAMP.write_text(json.dumps({"failed": {"run": new[-1].name if new else None, "cause": cause,
                                                      "exit": code, "at": time.strftime("%Y-%m-%d %H:%M")}},
                                          indent=1) + "\n", encoding="utf-8")
        r.check(label, False, hint=f"exit {code}: {cause}{where}. {hint}")
        return
    SMOKE_STAMP.write_text(json.dumps({"key": smoke_key(), "at": time.strftime("%Y-%m-%d %H:%M"),
                                       "run": new[-1].name if new else None,
                                       "seconds": round(time.time() - t0, 1)}, indent=1) + "\n", encoding="utf-8")
    r.check(label, True, f"PASS in {time.time() - t0:.0f}s{where}")


def diagnose(fix: bool, force_smoke: bool = False) -> Report:
    r = Report()
    print("machine:")
    if not r.check("Windows", sys.platform == "win32", sys.platform):
        return r

    missing = deps_missing(python())
    if (missing or not VENV_PY.is_file()) and fix and shutil.which("uv"):
        subprocess.run(["uv", "sync"], cwd=REPO)
        missing = deps_missing(python())
    r.check("python deps (uv sync)", not missing,
            f"missing {missing}; {'run `uv sync`' if shutil.which('uv') else 'install uv, then `uv sync`'}"
            if missing else python())
    if VENV_PY.is_file() and Path(sys.executable).resolve() != VENV_PY.resolve():
        r.info(f"this doctor runs on {sys.executable}; GameLab and the tools should run on {VENV_PY} (or `uv run`)")

    game = gamepaths.hoh2_dir(required=False)
    r.check("Steam found", gamepaths.steam_root() is not None)
    if not r.check("HoH2 install found", game is not None, str(game) if game else "set HWP_HOH2_DIR"):
        return r
    r.check("Steam running", process_running("steam.exe"),
            hint="start Steam: the game is launched directly and needs a running Steam client (docs/RE_NOTES.md)")
    hoh1 = hoh1_check(r)
    state = hoh1[0]

    bad = pin_build.mismatch()
    pinned = r.check("install is the pinned build", not bad,
                     "; ".join(bad) + ". Steam updated the game: re-pinning is a deliberate team decision "
                     "(tools/pin_build.py --reason, then bootstrap.py --force), never a fix"
                     if bad else str(pin_build.pinned()["build_id"]))

    tgt = gcc_target()
    gcc_ok = r.check("gcc mingw-w64 x86_64 (builds the capture shim)", bool(tgt) and "x86_64" in tgt and "mingw" in tgt,
                     tgt or "not on PATH: install mingw-w64 (e.g. `choco install mingw`), then reopen the shell")
    same_vol = os.stat(REPO).st_dev == os.stat(game).st_dev
    r.check("repo on the same volume as the install", same_vol,
            hint="GameLab hard-links res/assets.bin from the install; clone the repo onto the Steam library's drive")
    free_gb = shutil.disk_usage(REPO).free / 2**30
    have_tree = (gamepaths.BASE_HOH2 / "scripts").is_dir()
    r.check("disk space for gamecode/", have_tree or free_gb >= BOOTSTRAP_FREE_GB, f"{free_gb:.1f} GB free")

    print("saves:")
    sp = saves.confirmation_problems()
    if sp:
        _, amb = save_summary(r)
        if fix:
            confirm_saves(r, no_saves_yet=False, auto=True)
            sp = saves.confirmation_problems()
        elif not amb:
            r.info("nothing ambiguous: --fix will confirm the save backup itself")
    saves_ok = r.check("save backups confirmed", not sp, "; ".join(sp))

    print("generated (gitignored) trees:")
    v = run_py([str(REPO / "tools" / "bootstrap.py"), "--verify"])
    # gamecode/sdk/hoh1 is optional to --verify, so a HoH1 found after the first bootstrap
    # (e.g. --hoh1) needs its own trigger; bootstrap skips every output that already exists
    need_hoh1_tree = state == "found" and not has_files(gamepaths.BASE_HOH1)
    if (v.returncode or need_hoh1_tree) and fix:
        if not saves_ok:
            r.info("not running bootstrap.py until saves are confirmed: its datatables step boots the "
                   "game through the GameLab launcher, which refuses before that (--confirm-saves)")
        elif pinned and gcc_ok and (have_tree or free_gb >= BOOTSTRAP_FREE_GB):
            r.info("running tools/bootstrap.py (PACKAGER unpack on a hidden desktop, a few minutes)")
            b = subprocess.run([python(), str(REPO / "tools" / "bootstrap.py")], cwd=REPO)
            r.info(f"bootstrap.py exit {b.returncode}")
            v = run_py([str(REPO / "tools" / "bootstrap.py"), "--verify"])
            if v.returncode:
                r.info("an output that exists but differs is not redone without --force: "
                       "`python tools/bootstrap.py --force`")
        else:
            r.info("not running bootstrap.py until the build pin, gcc and disk checks above are green")
    lines = v.stdout.strip().splitlines()
    r.check("gamecode/ + tools/bin/ match gamelab/manifest.json (bootstrap.py)", v.returncode == 0,
            "; ".join(lines[-4:]) if v.returncode else (lines[-1] if lines else ""))
    if state == "found":
        r.check("gamecode/sdk/hoh1/ extracted (bootstrap.py)", has_files(gamepaths.BASE_HOH1),
                str(gamepaths.BASE_HOH1.relative_to(REPO)), hint="missing: `python tools/bootstrap.py` extracts it")

    print("gamelab environment:")
    from gamelab import env
    problems = env.link(fix=fix)
    r.check("gamelab game dir linked (env_link.py)", not problems, "; ".join(problems[:4]))

    print("local content (gitignored, made from your own installs):")
    local_content(r, fix, hoh1)

    print("smoke boot (this machine's GPU, antivirus and cores):")
    smoke(r, fix, force_smoke)
    return r


def main(argv=None) -> int:
    import argparse
    ap = argparse.ArgumentParser(prog="python -m gamelab doctor", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fix", action="store_true")
    ap.add_argument("--confirm-saves", action="store_true")
    ap.add_argument("--no-saves-yet", action="store_true")
    ap.add_argument("--smoke", action="store_true", help="boot null-payload now, even if it passed before")
    hg = ap.add_mutually_exclusive_group()
    hg.add_argument("--hoh1", metavar="DIR", help="the HoH1 install dir the user named: validated, then "
                    "remembered in tools/paths.local.json (gitignored)")
    hg.add_argument("--no-hoh1", action="store_true", help="the user has no HoH1: remember it, skip HoH1 content")
    a = ap.parse_args(argv)
    if a.hoh1 is not None or a.no_hoh1:
        print("HoH1 answer:")
        if not record_hoh1(a.hoh1, a.no_hoh1):
            print("doctor: NOT ready: HoH1 path rejected")
            return 2
    if a.confirm_saves:
        r = Report()
        print("confirm saves (human override):")
        save_summary(r)
        confirm_saves(r, a.no_saves_yet, auto=False)
        print(f"doctor: saves {'confirmed' if r.green else 'NOT confirmed'}")
        return 0 if r.green else 2
    r = diagnose(a.fix, a.smoke)
    bad = [n for n, ok, _ in r.rows if not ok]
    print(f"doctor: {'green' if not bad else 'NOT ready: ' + ', '.join(bad)}")
    return 0 if not bad else 2


if __name__ == "__main__":
    sys.exit(main())
