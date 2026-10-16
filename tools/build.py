#!/usr/bin/env python3
"""
build.py - package HammerwatchPlus modules into HoH2 mod .bin files.

    build.py                 # every module -> dist/HWP-<id>.bin + dist/HammerwatchPlus-All.bin
    build.py gambler core    # only these modules (no all-in-one)
    build.py --check         # compare our wholesale overrides against .base/ (docs/modules.md, rule 1)
    build.py --no-all        # skip the all-in-one package

Each module is `modules/<id>/` with an `info.xml` (author/name/description read
from it) and an optional `module.json`:

    {
      "id": "gambler",                 # defaults to the folder name
      "requires": ["core"],            # modules that must be enabled alongside
      "overrides": ["scripts/GUI/PlayerMenu/Character.as"],  # wholesale base-file overrides
      "exclude": ["notes.md"]          # files not to package
    }
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hwr_archive as hwr  # noqa: E402
import paths  # noqa: E402

ALL_NAME = "HammerwatchPlus-All"
PACKAGE_PREFIX = "HWP-"
NEVER_PACK = {"module.json", "README.md", "_hwr_manifest.json", "info.xml"}  # info.xml becomes the archive meta
# overrides compare these as text (line endings and a BOM do not matter to the engine); anything else byte-exact
TEXT_EXTS = {".as", ".xml", ".sval", ".lang", ".gui", ".inc", ".net", ".unit", ".effect", ".txt", ".md", ".json", ".fnt", ".lvl.xml"}


def load_module(mod_dir: Path) -> dict:
    cfg = {}
    cfg_path = mod_dir / "module.json"
    if cfg_path.is_file():
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    cfg.setdefault("id", mod_dir.name)
    if cfg["id"] != mod_dir.name:
        # dev_link/dev_check name the linked mod after the folder; keep one identity everywhere
        sys.exit(f"{cfg_path}: id {cfg['id']!r} must match the folder name {mod_dir.name!r}")
    cfg.setdefault("requires", [])
    cfg.setdefault("overrides", [])
    cfg.setdefault("exclude", [])
    cfg["dir"] = mod_dir
    try:
        cfg["meta"] = hwr.read_info_xml(mod_dir)
    except ValueError as e:
        sys.exit(str(e))
    if not cfg["meta"].get("name"):
        sys.exit(f"{mod_dir}/info.xml has no <name>")
    return cfg


def module_entries(cfg: dict, store: bool) -> list[hwr.Entry]:
    exclude = NEVER_PACK | set(cfg["exclude"])
    manifest = None
    mpath = cfg["dir"] / hwr.MANIFEST
    if mpath.is_file():
        manifest = json.loads(mpath.read_text(encoding="utf-8"))
    entries = hwr.collect_dir(cfg["dir"], manifest, store, exclude)
    return [e for e in entries if not e.path.endswith(".orig")]  # pristine copies are for --check only


def write_package(name: str, meta: dict, entries: list[hwr.Entry], store: bool) -> Path:
    paths.DIST.mkdir(exist_ok=True)
    out = paths.DIST / f"{name}.bin"
    # author/name/description first (what the Resource Mods menu shows), then everything else
    ordered = {k: meta[k] for k in ("author", "name", "description") if k in meta}
    ordered.update({k: v for k, v in meta.items() if k not in ordered})
    hwr.Archive("hoh2", hwr.GAMES["hoh2"][1], 0, ordered, entries).write(out)
    size = sum(len(e.blob) for e in entries)
    print(f"  {out.name:40s} {len(entries):5d} files  {size:>10,} B")
    return out


def _comparable(rel: str, data: bytes) -> bytes:
    """Text files compare without BOM and line-ending differences (git may rewrite them);
    binary files compare byte-exact."""
    if Path(rel).suffix.lower() not in TEXT_EXTS:
        return data
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def check_overrides(mods: list[dict]) -> int:
    """Report wholesale overrides whose base copy no longer matches .base/."""
    if not paths.BASE_HOH2.is_dir():
        sys.exit("run tools/extract_base.py first (.base/ missing)")
    problems = 0
    owners: dict[str, str] = {}
    for cfg in mods:
        for rel in cfg["overrides"]:
            if rel in owners:
                print(f"CONFLICT {rel}: owned by {owners[rel]} and {cfg['id']}")
                problems += 1
            owners[rel] = cfg["id"]
            base = paths.BASE_HOH2 / rel
            orig = cfg["dir"] / (rel + ".orig")
            if not base.is_file():
                print(f"MISSING  {rel}: not in base game any more ({cfg['id']})")
                problems += 1
                continue
            if not orig.is_file():
                print(f"NO-ORIG  {rel}: add {orig.relative_to(paths.REPO)} (copy of the base file you patched)")
                problems += 1
                continue
            if _comparable(rel, base.read_bytes()) != _comparable(rel, orig.read_bytes()):
                print(f"CHANGED  {rel}: base game updated since {cfg['id']} copied it; re-apply the patch"
                      f"{' (compared ignoring line endings)' if Path(rel).suffix.lower() in TEXT_EXTS else ''}")
                problems += 1
    # Any file in a module that also exists in base but isn't declared is an undeclared override.
    for cfg in mods:
        for fp in cfg["dir"].rglob("*"):
            if not fp.is_file():
                continue
            rel = fp.relative_to(cfg["dir"]).as_posix()
            if rel in NEVER_PACK or rel.endswith(".orig") or rel in cfg["overrides"]:
                continue
            if (paths.BASE_HOH2 / rel).is_file():
                print(f"UNDECLARED {rel}: {cfg['id']} shadows a base file; list it in module.json overrides")
                problems += 1
    print("override check:", "OK" if not problems else f"{problems} problem(s)")
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("modules", nargs="*", help="module ids to build (default: all)")
    ap.add_argument("--check", action="store_true", help="only run the override check")
    ap.add_argument("--no-all", action="store_true", help="skip the all-in-one package")
    ap.add_argument("--store", action="store_true", help="skip LZ4 compression")
    args = ap.parse_args(argv)

    mods = [load_module(d) for d in paths.module_dirs()]
    if args.check:
        sys.exit(1 if check_overrides(mods) else 0)
    known = {m["id"] for m in mods}
    for m in mods:
        for req in m["requires"]:
            if req not in known:
                sys.exit(f"{m['id']} requires unknown module {req!r}")
    if args.modules:
        unknown = set(args.modules) - known
        if unknown:
            sys.exit(f"unknown module(s): {', '.join(sorted(unknown))}; known: {', '.join(sorted(known))}")
        mods = [m for m in mods if m["id"] in args.modules]
        for m in mods:
            for req in m["requires"]:
                if req not in args.modules:
                    print(f"note: {m['id']} requires {req}; players need HWP-{req}.bin enabled as well")

    print("building:")
    all_entries: dict[str, hwr.Entry] = {}
    all_meta: dict = {}
    for cfg in mods:
        entries = module_entries(cfg, args.store)
        write_package(PACKAGE_PREFIX + cfg["id"], cfg["meta"], entries, args.store)
        for e in entries:
            if e.path in all_entries and all_entries[e.path].blob != e.blob:
                sys.exit(f"all-in-one conflict: {e.path} differs between modules")
            all_entries[e.path] = e
        merge_meta(all_meta, cfg["meta"], cfg["id"])
    if not args.no_all and not args.modules:
        all_meta.update({
            "author": "Ryan Bower & contributors",
            "name": "HammerwatchPlus",
            "description": "All HammerwatchPlus modules in one package: " + ", ".join(m["id"] for m in mods),
        })
        write_package(ALL_NAME, all_meta, list(all_entries.values()), args.store)


def merge_meta(into: dict, meta: dict, mod_id: str) -> None:
    """Combine the non-descriptive info.xml keys (classmaps, scripts, ...) of every module
    for the all-in-one package. Lists concatenate; anything else must agree."""
    for k, v in meta.items():
        if k in ("author", "name", "description"):
            continue
        if k not in into:
            into[k] = list(v) if isinstance(v, list) else v
        elif isinstance(v, list) and isinstance(into[k], list):
            into[k] += [x for x in v if x not in into[k]]
        elif into[k] != v:
            sys.exit(f"all-in-one conflict: info.xml key {k!r} differs in {mod_id}")


if __name__ == "__main__":
    main()
