#!/usr/bin/env python3
"""bootstrap.py - regenerate every gitignored, regenerable path from the local game install.

    bootstrap.py                     # required tier (refuses if the install's build != gamelab/build_id.json)
    bootstrap.py --force             # re-extract even where outputs exist
    bootstrap.py --with-community    # + optional tier from the shared folder (docs/SOURCES.md)
    bootstrap.py --verify            # compare the tree to gamelab/manifest.json, write manifest.local.json
    bootstrap.py --record            # (after a deliberate re-pin) rewrite gamelab/manifest.json from the tree

Required tier, in order:
  1. build-id gate (tools/pin_build.py)
  2. tools/bin/PACKAGER.exe: Steam-free patched copy + the game's DLLs (tools/patch_packager.py)
  3. gamecode/sdk/hoh2/: PACKAGER --unpack of res/assets.bin, plus res/language/
  4. gamecode/sdk/hoh1/: hwr_archive extract of HoH1's assets.bin, when HoH1 is installed
  5. gamecode/assets/hwr2_api_strings.txt: printable strings of HWR2.exe (the registered script API)
  6. gamecode/datatables/: JSON exports (tools/export_datatables.py)
  7. tools/bin/hwr2_capture.dll: GameLab's in-process shim (tools/capture_shim/, gcc)
  8. tools/hidden_desktop.py importable (vendored, committed)

The manifest records, per output tree and top-level subdirectory, a file count, byte
count and a sha256 over the sorted (path, sha256) list. PACKAGER output is deterministic
(measured: two unpacks hash identical), so these are output hashes. The shim DLL is not
(the linker stamps it), so it is recorded by input: hwr2_capture.build.json holds the
source sha256 and the gcc version. Both are left out of the hash (the gcc version differs
per machine); --verify checks the stamp's source sha256 against tools/capture_shim/ instead.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamepaths  # noqa: E402
import pin_build  # noqa: E402

REPO = gamepaths.REPO
MANIFEST = gamepaths.GAMELAB / "manifest.json"
MANIFEST_LOCAL = gamepaths.GAMELAB / "manifest.local.json"
SOURCES = gamepaths.DOCS / "SOURCES.md"
PACKAGER_TIMEOUT = 900
REQUIRED_TREES = ["gamecode/sdk/hoh2", "gamecode/assets", "gamecode/datatables", "tools/bin"]
OPTIONAL_REQUIRED = ["gamecode/sdk/hoh1"]          # required tier, but only where HoH1 is installed
COMMUNITY_TREES = ["docs/community/discord"]


NOT_HASHED = {"_hwr_manifest.json", "hwr2_capture.dll", "hwr2_capture.build.json"}   # recorded by input instead (see above)
SHIM_SRC = gamepaths.TOOLS / "capture_shim" / "hwr2_capture.c"
SHIM_DLL = gamepaths.TOOLS_BIN / "hwr2_capture.dll"


def step(msg: str) -> None:
    print(f"[bootstrap] {msg}", flush=True)


def tree_hash(root: Path) -> dict:
    """{subdir: {files, bytes, sha256}} for the top-level entries of root ('.' = loose files)."""
    groups: dict[str, list[tuple[str, str, int]]] = {}
    for f in sorted(root.rglob("*")):
        if not f.is_file() or f.name in NOT_HASHED:
            continue
        rel = f.relative_to(root).as_posix()
        top = rel.split("/", 1)[0] if "/" in rel else "."
        data = f.read_bytes()
        groups.setdefault(top, []).append((rel, hashlib.sha256(data).hexdigest(), len(data)))
    out = {}
    for top, items in sorted(groups.items()):
        h = hashlib.sha256("".join(f"{p}\0{s}\n" for p, s, _ in items).encode()).hexdigest()
        out[top] = {"files": len(items), "bytes": sum(n for *_, n in items), "sha256": h}
    return out


def packager_unpack(archive: Path, dest: Path) -> None:
    """Unpack with the patched PACKAGER on the hidden desktop. It ends on a modal error box
    (five sound-bank entries without data, docs/packager.md), so the run is expected to hit
    the timeout or exit -1; completeness is checked against the archive's own entry list."""
    import hidden_desktop
    import hwr_archive
    want = [e.path for e in hwr_archive.Archive.read(archive).entries if not e.is_bank]
    dest.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    # The driver runs on the hidden desktop with PACKAGER as its child and returns once
    # every entry is on disk and the tree has stopped growing; the job then kills the box.
    try:
        done = hidden_desktop.run([sys.executable, __file__, "--unpack-driver", str(archive), str(dest), str(len(want))],
                                  cwd=gamepaths.TOOLS_BIN, timeout=PACKAGER_TIMEOUT)
        print(done.stdout.strip())
    except subprocess.TimeoutExpired:
        pass
    missing = [p for p in want if not (dest / p).is_file()]
    if missing:
        sys.exit(f"PACKAGER unpack of {archive} incomplete: {len(missing)} of {len(want)} files missing "
                 f"(first: {missing[:3]})")
    step(f"unpacked {len(want)} files from {archive.name} in {time.time() - t0:.0f}s")


def unpack_driver(archive: str, dest: str, count: int) -> int:
    """Runs on the hidden desktop: start PACKAGER, wait for `count` files to settle."""
    proc = subprocess.Popen([str(gamepaths.TOOLS_BIN / "PACKAGER.exe"), f"--unpack={archive}",
                             f"--destination={dest}"], cwd=str(gamepaths.TOOLS_BIN))
    last, stable_since = -1, time.time()
    while True:
        time.sleep(2)
        n = sum(1 for f in Path(dest).rglob("*") if f.is_file()) if Path(dest).is_dir() else 0
        if n != last:
            last, stable_since = n, time.time()
        exited = proc.poll() is not None
        if (n >= count and time.time() - stable_since > 4) or (exited and time.time() - stable_since > 4):
            print(f"driver: {n}/{count} files, PACKAGER {'exited ' + str(proc.returncode) if exited else 'blocked on its dialog'}")
            return 0


def ensure_packager(force: bool) -> None:
    exe = gamepaths.TOOLS_BIN / "PACKAGER.exe"
    if exe.is_file() and not force:
        return
    game = gamepaths.hoh2_dir()
    gamepaths.TOOLS_BIN.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([sys.executable, str(gamepaths.TOOLS / "patch_packager.py"), str(game / "PACKAGER.exe"), str(exe)])
    if r.returncode:
        sys.exit("patch_packager.py failed")
    for dll in game.glob("*.dll"):
        shutil.copy2(dll, gamepaths.TOOLS_BIN / dll.name)
    step("built tools/bin/PACKAGER.exe")


def build_shim(force: bool) -> None:
    """gcc (mingw-w64) builds the injected capture / known-folder shim; recorded by input."""
    stamp = gamepaths.TOOLS_BIN / "hwr2_capture.build.json"
    src_sha = hashlib.sha256(SHIM_SRC.read_bytes()).hexdigest()
    if not force and SHIM_DLL.is_file() and stamp.is_file() and json.loads(stamp.read_text())["source_sha256"] == src_sha:
        return
    gcc = shutil.which("gcc")
    if not gcc:
        sys.exit("gcc (mingw-w64, x86_64) is required to build tools/bin/hwr2_capture.dll")
    gamepaths.TOOLS_BIN.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([gcc, "-shared", "-O2", "-Wall", "-o", str(SHIM_DLL), str(SHIM_SRC),
                        "-lgdi32", "-lopengl32", "-lole32"])
    if r.returncode:
        sys.exit("building hwr2_capture.dll failed")
    version = subprocess.run([gcc, "-dumpfullversion"], capture_output=True, text=True).stdout.strip()
    stamp.write_text(json.dumps({"source_sha256": src_sha, "gcc": version}, indent=1) + "\n")
    step(f"built tools/bin/hwr2_capture.dll (gcc {version})")


def extract_hoh2(force: bool) -> None:
    out = gamepaths.BASE_HOH2
    if out.is_dir() and any(out.iterdir()) and not force:
        step(f"{out.relative_to(REPO)} exists (use --force to redo)")
        return
    if out.is_dir():
        shutil.rmtree(out)
    game = gamepaths.hoh2_dir()
    packager_unpack(game / "res" / "assets.bin", out)
    shutil.copytree(game / "res" / "language", out / "language", dirs_exist_ok=True)


def extract_hoh1(force: bool) -> None:
    game = gamepaths.hoh1_dir(required=False)
    if game is None:
        step("HoH1 not installed: skipping gamecode/sdk/hoh1 (import_hoh1.py needs it)")
        return
    out = gamepaths.BASE_HOH1
    if out.is_dir() and any(out.iterdir()) and not force:
        return
    import hwr_archive
    hwr_archive.main(["extract", str(game / "res" / "assets.bin"), str(out)])
    if (game / "res" / "language").is_dir():
        shutil.copytree(game / "res" / "language", out / "language", dirs_exist_ok=True)


def api_strings(force: bool) -> None:
    out = gamepaths.GAMECODE / "assets" / "hwr2_api_strings.txt"
    if out.is_file() and not force:
        return
    out.parent.mkdir(parents=True, exist_ok=True)
    data = (gamepaths.hoh2_dir() / "HWR2.exe").read_bytes()
    strings = sorted({m.group().decode() for m in re.finditer(rb"[\x20-\x7e]{6,}", data)})
    out.write_text("\n".join(strings) + "\n", encoding="utf-8", newline="\n")
    step(f"wrote {len(strings)} strings to {out.relative_to(REPO)}")


def datatables(force: bool) -> None:
    exporter = gamepaths.TOOLS / "export_datatables.py"
    r = subprocess.run([sys.executable, str(exporter)] + (["--force"] if force else []))
    if r.returncode:
        sys.exit("export_datatables.py failed")


def current_manifest(trees: list[str]) -> dict:
    return {t: tree_hash(REPO / t) for t in trees if (REPO / t).is_dir()}


def verify() -> int:
    if not MANIFEST.is_file():
        print("no gamelab/manifest.json; run bootstrap.py --record on the originating machine")
        return 1
    want = json.loads(MANIFEST.read_text(encoding="utf-8"))
    bad, have_optional = [], {}
    for tier, trees in want["tiers"].items():
        for tree, groups in trees.items():
            root = REPO / tree
            present = root.is_dir() and any(root.iterdir())
            if tier != "required" or tree in OPTIONAL_REQUIRED:
                have_optional[tree] = present
                if not present:
                    continue
            elif not present:
                bad.append(f"{tree}: missing")
                continue
            got = tree_hash(root)
            for g in sorted(set(groups) | set(got)):
                if groups.get(g) != got.get(g):
                    bad.append(f"{tree}/{g}: want {groups.get(g, {}).get('files')} files "
                               f"{str(groups.get(g, {}).get('sha256'))[:12]}, have {got.get(g, {}).get('files')} "
                               f"{str(got.get(g, {}).get('sha256'))[:12]}")
    stamp = gamepaths.TOOLS_BIN / "hwr2_capture.build.json"
    if not (SHIM_DLL.is_file() and stamp.is_file()):
        bad.append("tools/bin/hwr2_capture.dll: not built")
    elif json.loads(stamp.read_text())["source_sha256"] != hashlib.sha256(SHIM_SRC.read_bytes()).hexdigest():
        bad.append("tools/bin/hwr2_capture.dll: built from other source than tools/capture_shim/ (bootstrap.py rebuilds it)")
    MANIFEST_LOCAL.write_text(json.dumps({"checked": time.strftime("%Y-%m-%dT%H:%M:%S"),
                                          "optional_present": have_optional, "ok": not bad}, indent=1) + "\n")
    for b in bad:
        print("DIFF", b)
    print(f"verify: {'green' if not bad else f'{len(bad)} difference(s)'}; optional present: "
          f"{[t for t, p in have_optional.items() if p] or 'none'}")
    return 1 if bad else 0


def record() -> int:
    tiers = {"required": current_manifest(REQUIRED_TREES + OPTIONAL_REQUIRED),
             "optional": current_manifest(COMMUNITY_TREES)}
    pin = pin_build.pinned()
    MANIFEST.write_text(json.dumps({"build_id": pin and pin["build_id"], "recorded": time.strftime("%Y-%m-%d"),
                                    "tiers": tiers}, indent=1) + "\n", encoding="utf-8")
    print(f"recorded {sum(len(v) for t in tiers.values() for v in t.values())} groups -> {MANIFEST.relative_to(REPO)}")
    return 0


def community() -> None:
    """Optional tier: copy the non-regenerable mirrors from the shared folder named in SOURCES.md."""
    text = SOURCES.read_text(encoding="utf-8") if SOURCES.is_file() else ""
    m = re.search(r"Shared folder:\s*`([^`]+)`", text)
    if not m or not Path(m.group(1)).is_dir():
        sys.exit("--with-community: the shared folder in docs/SOURCES.md is not reachable from this machine")
    src = Path(m.group(1))
    for tree in COMMUNITY_TREES:
        name = Path(tree).name
        if (src / name).is_dir():
            shutil.copytree(src / name, REPO / tree, dirs_exist_ok=True)
            step(f"copied {name} from the shared folder")


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["--unpack-driver"]:
        return unpack_driver(argv[1], argv[2], int(argv[3]))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--with-community", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--record", action="store_true")
    a = ap.parse_args(argv)
    if a.verify:
        return verify()
    if a.record:
        return record()
    bad = pin_build.mismatch()
    if bad:
        print("REFUSED: the install is not the pinned build: " + "; ".join(bad))
        print("If the update is deliberate: python tools/pin_build.py --reason '...' then bootstrap.py --force")
        return pin_build.EXIT_BUILD_MISMATCH
    ensure_packager(a.force)
    build_shim(a.force)
    extract_hoh2(a.force)
    extract_hoh1(a.force)
    api_strings(a.force)
    datatables(a.force)
    import hidden_desktop  # noqa: F401  (step 8: vendored copy importable)
    step("tools/hidden_desktop.py importable")
    if a.with_community:
        community()
    return verify() if MANIFEST.is_file() else 0


if __name__ == "__main__":
    sys.exit(main())
