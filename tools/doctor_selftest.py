#!/usr/bin/env python3
"""doctor_selftest.py - when does `python -m gamelab doctor --fix` confirm saves by itself?

Every case builds a sandbox under C:\\tmp\\claude: a fake Steam root (userdata/, an
appmanifest naming its LastOwner), a fake install (HWR2.exe.cfg, saves dirs) and a fake
LOCALAPPDATA, and points HWP_STEAM_DIR, HWP_HOH2_DIR and HWP_LOCALAPPDATA at it.
gamepaths.SAVES_BACKUP goes to the sandbox too. The run aborts if a save dir resolves
outside the sandbox, so the real saves are never read for writing, let alone written.

Cases (auto = doctor --fix, human = doctor --confirm-saves):
  clean cloud           -> nothing ambiguous, auto confirms, gate opens
  clean local           -> config saves locally and <install>/saves has files: auto confirms
  second account        -> ambiguous: auto refuses; human confirms, the override is recorded
  config local, empty   -> ambiguous (the dir the game writes holds nothing)
  unknown save* dir     -> ambiguous (<install>/save with files)
  no saves at all       -> ambiguous: human refuses without --no-saves-yet, confirms with it
  account changed later -> a confirmed stamp stops opening the gate

HoH1 discovery (HWP_PATHS_LOCAL points the answers file into the sandbox; the real
tools/paths.local.json is compared before/after):
  not found             -> pending: the row is NOT green and its hint says ASK THE USER
  library / sibling     -> found in another library's common/, or next to HoH2 first
  --hoh1 answers        -> HoH2's dir, a missing dir, HWR.exe without assets.bin: rejected;
                           a folder outside Steam (or its HWR.exe): persisted and used
  appmanifest / env     -> appmanifest beats the persisted path, HWP_HOH1_DIR beats all
  --no-hoh1             -> declined: green, HoH1 content skipped; a later --hoh1 clears it

Smoke boot (gamelab/doctor.py explain_smoke / smoke; subprocess.run is stubbed so nothing boots):
  every failure shape   -> its plain cause (antivirus, no GL, blank frames, slow, leak, ...)
  stamp                 -> none / current / core count changed; a red prerequisite blocks --fix

Pet dyes (tools/make_pet_dyes.py problems(), the real generator on two pets in a sandbox):
  missing, deleted copy, generator changed, source unit changed, new pet source -> stale

Exit 0 only if every case held.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))
import gamepaths  # noqa: E402
import saves  # noqa: E402
from gamelab import doctor  # noqa: E402

ME, OTHER = 1111, 2222
REAL_BACKUP = gamepaths.SAVES_BACKUP
REAL_PATHS_LOCAL = gamepaths.TOOLS / "paths.local.json"
SCRATCH = Path(r"C:\tmp\claude")
ENV_KEYS = ("HWP_STEAM_DIR", "HWP_HOH2_DIR", "HWP_LOCALAPPDATA", "HWP_PATHS_LOCAL", "HWP_HOH1_DIR")


def fake_hoh1(d: Path, assets: bool = True) -> Path:
    """A HoH1-shaped dir: HWR.exe (+ res/assets.bin unless assets=False)."""
    (d / "res").mkdir(parents=True, exist_ok=True)
    (d / "HWR.exe").write_bytes(b"MZ")
    if assets:
        (d / "res" / "assets.bin").write_bytes(b"HWRR")
    return d


def file_state(p: Path):
    return p.read_bytes() if p.is_file() else None


def hoh1_cases(check) -> None:
    """HoH1 discovery and the --hoh1 / --no-hoh1 answers, all inside a sandbox."""
    import contextlib
    import io

    def quiet(fn, *a):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            res = fn(*a)
        return res, out.getvalue()

    def row():
        r = doctor.Report()
        res, out = quiet(doctor.hoh1_check, r)
        return res[0], res[1], r.green, out

    real_before = file_state(REAL_PATHS_LOCAL)
    sb = Sandbox()
    lib2 = sb.root / "Lib2"                                   # a second Steam library, like G:\SteamLibrary
    (lib2 / "steamapps" / "common").mkdir(parents=True)
    vdf = f'"libraryfolders"\n{{\n\t"1"\n\t{{\n\t\t"path"\t\t"{str(lib2).replace(chr(92), chr(92) * 2)}"\n\t}}\n}}\n'
    (sb.steam / "steamapps" / "libraryfolders.vdf").write_text(vdf)
    check("hoh1 sandbox: the second library is listed", lib2 in gamepaths.library_folders())

    print("--- hoh1: not found")
    fake_hoh1(sb.install.parent / "HalfHoH1", assets=False)  # HWR.exe without res/assets.bin: not an install
    state, d, green, out = row()
    check("hoh1 not found: pending, row NOT green", state == "pending" and d is None and not green)
    check("hoh1 not found: hint tells the agent to ask the user", "ASK THE USER" in out and "--hoh1" in out
          and "--no-hoh1" in out)
    check("hoh1 not found: hoh1_dir() is None", gamepaths.hoh1_dir(required=False) is None)

    print("--- hoh1: library common/ search")
    lib_hoh1 = fake_hoh1(lib2 / "steamapps" / "common" / "Heroes of Hammerwatch")
    d, how = gamepaths.find_hoh1()
    check("hoh1 library search: found in the other library", d == lib_hoh1 and "Steam library" in how)

    print("--- hoh1: sibling of the HoH2 install")
    sib = fake_hoh1(sb.install.parent / "Heroes of Hammerwatch")
    d, how = gamepaths.find_hoh1()
    check("hoh1 sibling: found next to HoH2, before other libraries", d == sib and "next to the HoH2" in how)
    shutil.rmtree(sib)
    shutil.rmtree(lib_hoh1)

    print("--- hoh1: --hoh1 answers")
    paths_file = gamepaths.local_paths_file()
    ok, out = quiet(doctor.record_hoh1, str(sb.install), False)
    check("hoh1 --hoh1 <HoH2 dir> rejected, nothing written", not ok and not paths_file.exists())
    ok, _ = quiet(doctor.record_hoh1, str(sb.root / "nope"), False)
    check("hoh1 --hoh1 <missing dir> rejected, nothing written", not ok and not paths_file.exists())
    rc, _ = quiet(doctor.main, ["--hoh1", str(sb.install.parent / "HalfHoH1")])
    check("hoh1 doctor --hoh1 <no assets.bin> exits 2, nothing written", rc == 2 and not paths_file.exists())
    elsewhere = fake_hoh1(sb.root / "Games" / "HoH1 not in Steam")
    ok, _ = quiet(doctor.record_hoh1, f'"{elsewhere / "HWR.exe"}"', False)   # quoted, and the exe itself
    check("hoh1 --hoh1 <path to HWR.exe> accepted, persisted as its folder",
          ok and gamepaths.local_paths().get("hoh1_dir") == str(elsewhere.resolve()))
    state, d, green, _ = row()
    check("hoh1 persisted: found, row green", state == "found" and d == elsewhere.resolve() and green)
    check("hoh1 persisted: hoh1_dir() (bootstrap, import_hoh1) uses it",
          gamepaths.hoh1_dir(required=False) == elsewhere.resolve())

    print("--- hoh1: appmanifest beats the persisted path")
    acf_hoh1 = fake_hoh1(lib2 / "steamapps" / "common" / "HoH1 Steam")
    (lib2 / "steamapps" / f"appmanifest_{gamepaths.HOH1_APPID}.acf").write_text(
        f'"AppState"\n{{\n\t"appid"\t\t"{gamepaths.HOH1_APPID}"\n\t"installdir"\t\t"HoH1 Steam"\n}}\n')
    d, how = gamepaths.find_hoh1()
    check("hoh1 appmanifest: found in the second library", d == acf_hoh1 and "appmanifest" in how)

    print("--- hoh1: HWP_HOH1_DIR beats everything")
    os.environ["HWP_HOH1_DIR"] = str(elsewhere)
    check("hoh1 env override: used", gamepaths.find_hoh1() == (elsewhere, "HWP_HOH1_DIR"))
    os.environ["HWP_HOH1_DIR"] = str(sb.root / "nope")
    state, _, green, out = row()
    check("hoh1 env override, invalid: reported, NOT green", state == "invalid" and not green and "HWP_HOH1_DIR" in out)
    os.environ.pop("HWP_HOH1_DIR")
    (lib2 / "steamapps" / f"appmanifest_{gamepaths.HOH1_APPID}.acf").unlink()
    shutil.rmtree(acf_hoh1)
    shutil.rmtree(elsewhere)
    later = fake_hoh1(sb.root / "Games" / "HoH1 bought later")

    print("--- hoh1: --no-hoh1")
    state, _, green, _ = row()
    check("hoh1 persisted dir gone: back to pending", state == "pending" and not green)
    ok, _ = quiet(doctor.record_hoh1, None, True)
    state, _, green, out = row()
    check("hoh1 --no-hoh1: declined, row green, says skipped", ok and state == "declined" and green and "skipped" in out)
    local = doctor.Report()
    quiet(doctor.local_content, local, False, (state, None, ""))
    check("hoh1 --no-hoh1: no HoH1 import rows", not any(n.startswith("HoH1 ") for n, _, _ in local.rows))
    ok, _ = quiet(doctor.record_hoh1, str(later), False)
    check("hoh1 --hoh1 after --no-hoh1: found again, flag cleared",
          ok and not gamepaths.hoh1_declined() and gamepaths.find_hoh1()[0] == later.resolve())
    sb.close()
    check("hoh1: the real tools/paths.local.json untouched", file_state(REAL_PATHS_LOCAL) == real_before)


class Sandbox:
    def __init__(self, cloud_cfg: bool = True, owner: int = ME):
        scratch = Path(r"C:\tmp\claude")
        scratch.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix="hwp-doctor-selftest-", dir=scratch))
        self.steam = self.root / "Steam"
        self.install = self.steam / "steamapps" / "common" / "HoH2"
        self.appdata = self.root / "AppData"
        self.install.mkdir(parents=True)
        self.set_owner(owner)
        (self.install / "HWR2.exe.cfg").write_text(f"g_save_slot 0\ng_save_slot_cloud {1 if cloud_cfg else 0}\n")
        os.environ.update(HWP_STEAM_DIR=str(self.steam), HWP_HOH2_DIR=str(self.install),
                          HWP_LOCALAPPDATA=str(self.appdata), HWP_PATHS_LOCAL=str(self.root / "paths.local.json"))
        os.environ.pop("HWP_HOH1_DIR", None)
        assert gamepaths.local_paths_file() != REAL_PATHS_LOCAL
        gamepaths.SAVES_BACKUP = saves_root = self.root / "saves-backup"
        assert saves_root != REAL_BACKUP
        for d in gamepaths.real_save_dirs().values():
            assert self.root in d.parents, f"save dir outside the sandbox: {d}"

    def set_owner(self, account: int) -> None:
        (self.steam / "steamapps" / f"appmanifest_{gamepaths.HOH2_APPID}.acf").write_text(
            f'"AppState"\n{{\n\t"appid"\t\t"{gamepaths.HOH2_APPID}"\n\t"installdir"\t\t"HoH2"\n'
            f'\t"LastOwner"\t\t"{gamepaths.STEAMID64_BASE + account}"\n}}\n')

    def cloud(self, account: int = ME) -> Path:
        return self.steam / "userdata" / str(account) / gamepaths.HOH2_APPID / "remote" / "saves"

    def put(self, d: Path, n: int = 2) -> None:
        d.mkdir(parents=True, exist_ok=True)
        for i in range(n):
            (d / f"slot_{i}.hps").write_bytes(b"HPS\x01" + bytes([i]) * 64)

    def close(self) -> None:
        shutil.rmtree(self.root)


def assess(sb: Sandbox, **kw) -> list[str]:
    return doctor.assess_saves(**kw)[1]


def confirm(auto: bool, no_saves_yet: bool = False) -> tuple[bool, dict | None]:
    r = doctor.Report()
    ok = doctor.confirm_saves(r, no_saves_yet, auto)
    stamp = gamepaths.SAVES_BACKUP / saves.CONFIRMED
    return ok, json.loads(stamp.read_text()) if stamp.is_file() else None


def detailed(check):
    """check(name, ok, detail): the detail printed only on a failure."""
    def chk(name, ok, detail=""):
        check(name, ok)
        if not ok and detail != "":
            print(f"     {str(detail)[:600]}")
    return chk


def smoke_cases(check) -> None:
    """explain_smoke() on every failure shape, and when smoke() boots at all (it never does here)."""
    check = detailed(check)
    from gamelab import doctor
    print("--- smoke boot: causes")
    ok_log = "Opening SDL window\nStarting BGFX renderer OpenGL 3.2\nBGFX initialized\n"

    def run(error=None, verdict="FAIL", failed=()):
        return {"verdict": verdict, "error": error, "assertions": [{"name": n, "ok": False, "detail": ""} for n in failed]}

    cases = [
        ("pass", (0, run(verdict="PASS"), ok_log, ""), ""),
        ("preflight", (2, None, "", "PREFLIGHT saves: not confirmed\n"), "preflight"),
        ("build", (3, None, "", ""), "build mismatch"),
        ("lock", (4, None, "", "REFUSED lock"), "lock"),
        ("no run.json", (1, None, "", "Traceback"), "before writing run.json"),
        ("injection", (1, run("GameError: could not inject tools/bin/hwr2_capture.dll"), "", ""), "capture shim"),
        ("user files", (5, run(verdict="INVALID", failed=["user saves unchanged"]), ok_log, ""), "user's config"),
        ("window leak", (5, run(verdict="INVALID", failed=["no game-tree window on the input desktop"]), ok_log, ""),
         "hidden desktop was not honoured"),
        ("no game log", (1, run("GameError: main menu never loaded"), "", ""), "before writing its log"),
        ("no GL", (1, run("GameError: main menu never loaded"), "Opening SDL window\nStarting BGFX renderer\n", ""),
         "renderer did not start"),
        ("blank frames", (5, run(verdict="INVALID", failed=["shot town"]), ok_log, ""), "blank or missing"),
        ("timeout", (6, run(verdict="TIMEOUT"), ok_log, ""), "too slow"),
        ("menu never loaded, renderer fine", (1, run("GameError: main menu never loaded"), ok_log, ""), "too slow"),
        ("probe", (1, run("GameError: gamelab-probe never booted (mods not enabled)"), ok_log, ""), "probe mods"),
        ("isolation", (1, run("GameError: live process not isolated: {}"), ok_log, ""), "isolation checks"),
        ("other", (1, run(failed=["gl state"]), ok_log, ""), "another reason"),
    ]
    for name, args, want in cases:
        cause, hint = doctor.explain_smoke(*args)
        check(f"smoke cause: {name}", (cause == "" and hint == "") if not want else (want in cause and bool(hint)),
              f"{cause!r} / {hint!r}")
    cause, hint = doctor.explain_smoke(1, run("GameError: could not inject x"), "", "")
    check("smoke cause: injection hint names antivirus and the dll", "antivirus" in hint and "hwr2_capture.dll" in hint)
    cause, _ = doctor.explain_smoke(6, run(verdict="TIMEOUT"), ok_log, "")
    lab, total = doctor.lab_cores()
    check("smoke cause: timeout reports the core counts", f"{lab} of {total} cores" in cause, cause)

    print("--- smoke boot: stamp and gating")
    real_stamp = doctor.SMOKE_STAMP
    sb = Path(tempfile.mkdtemp(prefix="smoke-", dir=SCRATCH))
    doctor.SMOKE_STAMP = sb / "smoke.local.json"
    booted = []
    real_run = doctor.subprocess.run

    def no_boot(args, *a, **kw):
        if "run" in args and "gamelab" in args:
            booted.append(args)
            raise AssertionError("selftest must not boot the game")
        return real_run(args, *a, **kw)
    doctor.subprocess.run = no_boot
    try:
        check("smoke stamp: none -> never passed", doctor.smoke_stamp_problems() == ["never passed on this machine"])
        doctor.SMOKE_STAMP.write_text(json.dumps({"key": doctor.smoke_key(), "at": "2026-10-17 12:00"}), encoding="utf-8")
        check("smoke stamp: current key -> fine", doctor.smoke_stamp_problems() == [])
        key = doctor.smoke_key()
        key["cores"] = (key["cores"] or 0) + 2
        doctor.SMOKE_STAMP.write_text(json.dumps({"key": key, "at": "x"}), encoding="utf-8")
        probs = doctor.smoke_stamp_problems()
        check("smoke stamp: core count changed -> boot again", probs and "cores" in probs[0], probs)

        r = doctor.Report()
        r.check("save backups confirmed", False)
        doctor.smoke(r, fix=True, force=False)
        check("smoke gating: a failed prerequisite blocks the boot", not booted and not r.rows[-1][1]
              and "save backups confirmed" in r.rows[-1][2], r.rows[-1])
        r = doctor.Report()
        r.check("HoH1 pets imported (import_hoh1.py pets)", False)
        doctor.SMOKE_STAMP.write_text(json.dumps({"key": doctor.smoke_key(), "at": "2026-10-17 12:00"}), encoding="utf-8")
        doctor.smoke(r, fix=True, force=False)
        check("smoke gating: a current stamp is not re-booted by --fix", not booted and r.rows[-1][1], r.rows[-1])
        r = doctor.Report()
        doctor.smoke(r, fix=False, force=False)
        check("smoke report: plain doctor shows when it passed", r.rows[-1][1] and "2026-10-17" in r.rows[-1][2])
        doctor.SMOKE_STAMP.write_text(json.dumps({"failed": {"run": "R1", "cause": "too slow", "at": "x"}}),
                                      encoding="utf-8")
        probs = doctor.smoke_stamp_problems()
        check("smoke stamp: a recorded failure repeats its cause", probs and "too slow" in probs[0], probs)

        from gamelab import lock
        real_lock = (lock.LOCK, lock.TEARDOWN)
        real_run_py = doctor.run_py
        resets = []
        doctor.run_py = lambda args: resets.append(args) or doctor.subprocess.CompletedProcess(args, 0, "reset: ok", "")
        lock.LOCK, lock.TEARDOWN = sb / "gamelab.lock", sb / "teardown.json"
        try:
            lock.TEARDOWN.write_text(json.dumps({"clean": False, "run": "R1", "reasons": ["pass 1 exited cleanly"]}),
                                     encoding="utf-8")
            doctor.own_dirty_teardown(doctor.Report())
            check("smoke teardown: doctor's own failed run -> gamelab reset", resets == [["-m", "gamelab", "reset"]], resets)
            resets.clear()
            lock.TEARDOWN.write_text(json.dumps({"clean": False, "run": "someone-else", "reasons": ["x"]}),
                                     encoding="utf-8")
            doctor.own_dirty_teardown(doctor.Report())
            check("smoke teardown: another run's dirty teardown is left alone", resets == [], resets)
            lock.TEARDOWN.write_text(json.dumps({"clean": False, "run": "R1", "reasons": ["x"]}), encoding="utf-8")
            lock.LOCK.write_text("{}", encoding="utf-8")
            doctor.own_dirty_teardown(doctor.Report())
            check("smoke teardown: a held lock is left alone", resets == [], resets)
        finally:
            lock.LOCK, lock.TEARDOWN = real_lock
            doctor.run_py = real_run_py

        doctor.SMOKE_STAMP.unlink()
        r = doctor.Report()
        doctor.smoke(r, fix=False, force=False)
        check("smoke report: never passed -> NO, says --fix boots it", not booted and not r.rows[-1][1]
              and "--fix" in r.rows[-1][2], r.rows[-1])
    finally:
        doctor.subprocess.run = real_run
        doctor.SMOKE_STAMP = real_stamp
        shutil.rmtree(sb, ignore_errors=True)


def pet_dye_cases(check) -> None:
    """make_pet_dyes.problems(): complete, missing, script changed, source changed, new pet.
    Runs the real generator on two vanilla pets into a sandbox mods/pets."""
    check = detailed(check)
    import make_pet_dyes as mpd
    print("--- pet dyes")
    if not mpd.BASE.is_dir():
        check("pet dyes: gamecode/sdk/hoh2 present (run bootstrap.py first)", False)
        return
    saved = {k: getattr(mpd, k) for k in ("PETS_DIR", "OUT", "STAMP", "PARTS_AS", "PETS")}
    sb = Path(tempfile.mkdtemp(prefix="dyes-", dir=SCRATCH))
    real_parts = file_state(saved["PARTS_AS"])
    try:
        mpd.PETS_DIR = sb / "pets"
        mpd.OUT = mpd.PETS_DIR / "players/pets/hwp/dye"
        mpd.STAMP = mpd.OUT / ".hwp-generated.json"
        mpd.PARTS_AS = sb / "PetDyeParts.as"
        mpd.PETS = {k: saved["PETS"][k] for k in ("tiny_maltese", "pet_beetle")}
        check("pet dyes: nothing made -> missing", "missing" in " ".join(mpd.problems()), mpd.problems())
        mpd.main([])
        check("pet dyes: after main -> complete and current", mpd.problems() == [], mpd.problems())
        check("pet dyes: the stamp never packs (dotfile)", mpd.STAMP.name.startswith("."))
        victim = sorted(mpd.OUT.glob("*.tif"))[0]
        victim.unlink()
        check("pet dyes: a copy deleted -> missing", "missing" in " ".join(mpd.problems()))
        mpd.main([])
        st = json.loads(mpd.STAMP.read_text(encoding="utf-8"))
        mpd.STAMP.write_text(json.dumps(dict(st, script_sha256="0" * 64)), encoding="utf-8")
        check("pet dyes: generator changed -> stale", any("changed since" in p for p in mpd.problems()), mpd.problems())
        mpd.main([])
        unit = mpd.PETS_DIR / "players/pets/cat_maltese.unit"
        unit.parent.mkdir(parents=True, exist_ok=True)
        unit.write_bytes((mpd.BASE / "players/pets/cat_maltese.unit").read_bytes() + b"\n<!-- selftest -->\n")
        check("pet dyes: a source unit changed -> stale", any("sources changed" in p for p in mpd.problems()),
              mpd.problems())
        mpd.main([])
        mpd.PETS = dict(mpd.PETS, pet_imp_1=saved["PETS"]["pet_imp_1"])
        check("pet dyes: a new pet's source appeared (HoH1 import) -> stale",
              any("sources now exist for 3" in p or "missing" in p for p in mpd.problems()), mpd.problems())
        mpd.main([])
        check("pet dyes: regenerated -> current again", mpd.problems() == [], mpd.problems())
    finally:
        for k, v in saved.items():
            setattr(mpd, k, v)
        shutil.rmtree(sb, ignore_errors=True)
    check("pet dyes: the real PetDyeParts.as untouched", file_state(saved["PARTS_AS"]) == real_parts)


def main() -> int:
    saved_env = {k: os.environ.get(k) for k in ENV_KEYS}
    checks: list[tuple[str, bool]] = []

    def check(name: str, ok: bool) -> None:
        checks.append((name, ok))
        print(("PASS " if ok else "FAIL ") + name, flush=True)

    try:
        print("--- clean cloud")
        sb = Sandbox()
        sb.put(sb.cloud())
        sb.put(sb.appdata / "HeroesofHammerwatch2" / "save_backups", 1)
        check("clean cloud: nothing ambiguous", assess(sb) == [])
        check("clean cloud: gate closed before confirming", saves.confirmation_problems() != [])
        ok, stamp = confirm(auto=True)
        check("clean cloud: auto confirms", ok and stamp and stamp["confirmed_by"] == "doctor --fix")
        check("clean cloud: gate open", saves.confirmation_problems() == [])
        check("clean cloud: stamp counts every dir", stamp and stamp["files"] == {"cloud": 2, "local": 0, "game_backups": 1})
        print("--- account changed later")
        sb.set_owner(OTHER)
        check("account changed: gate closes again", any("changed" in p for p in saves.confirmation_problems()))
        sb.close()

        print("--- clean local")
        sb = Sandbox(cloud_cfg=False)
        sb.put(sb.install / "saves")
        check("clean local: nothing ambiguous", assess(sb) == [])
        check("clean local: auto confirms", confirm(auto=True)[0])
        sb.close()

        print("--- second account")
        sb = Sandbox()
        sb.put(sb.cloud())
        sb.put(sb.cloud(OTHER))
        amb = assess(sb)
        check("second account: ambiguous", len(amb) == 1 and str(OTHER) in amb[0])
        ok, stamp = confirm(auto=True)
        check("second account: auto refuses, no stamp", not ok and stamp is None)
        ok, stamp = confirm(auto=False)
        check("second account: human confirms, override recorded",
              ok and stamp["confirmed_by"] == "human" and str(OTHER) in stamp["ambiguities_overridden"][0])
        sb.close()

        print("--- config local, empty")
        sb = Sandbox(cloud_cfg=False)
        sb.put(sb.cloud())
        amb = assess(sb)
        check("config local, empty: ambiguous", len(amb) == 1 and "saves to local" in amb[0])
        check("config local, empty: auto refuses", not confirm(auto=True)[0])
        sb.close()

        print("--- unknown save* dir")
        sb = Sandbox()
        sb.put(sb.cloud())
        sb.put(sb.install / "save", 1)
        amb = assess(sb)
        check("unknown save dir: ambiguous", len(amb) == 1 and "not a save dir GameLab knows" in amb[0])
        (sb.install / "save" / "slot_0.hps").unlink()
        check("unknown save dir: empty one is fine", assess(sb) == [])
        sb.close()

        print("--- no saves at all")
        sb = Sandbox()
        check("no saves: ambiguous", any("no save files" in a for a in assess(sb)))
        check("no saves: auto refuses", not confirm(auto=True)[0])
        check("no saves: human refuses without --no-saves-yet", not confirm(auto=False)[0])
        check("no saves: --no-saves-yet clears it", assess(sb, no_saves_yet=True) == [])
        ok, stamp = confirm(auto=False, no_saves_yet=True)
        check("no saves: human confirms with --no-saves-yet", ok and stamp["no_saves_yet"] is True)
        sb.close()

        hoh1_cases(check)
        smoke_cases(check)
        pet_dye_cases(check)
    finally:
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        gamepaths.SAVES_BACKUP = REAL_BACKUP
    bad = [n for n, ok in checks if not ok]
    print(f"doctor selftest: {'green' if not bad else 'FAILED: ' + ', '.join(bad)} ({len(checks)} checks)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
