#!/usr/bin/env python3
"""
build.py - package HammerwatchPlus modules into HoH2 mod .bin files.

    build.py                 # every module -> dist/HWP-<id>.bin + dist/HammerwatchPlus-All.bin
    build.py gambler core    # only these modules (no all-in-one)
    build.py --check         # compare our wholesale overrides against gamecode/sdk/hoh2/ (docs/modules.md, rule 1)
    build.py --no-all        # skip the all-in-one package
    build.py --with-local    # also pack `local` content (your own install only)

Each module is `mods/<id>/` with an `info.xml` (author/name/description read
from it) and an optional `module.json`:

    {
      "id": "gambler",                 # defaults to the folder name
      "requires": ["core"],            # modules that must be enabled alongside
      "overrides": ["scripts/GUI/PlayerMenu/Character.as"],  # wholesale base-file overrides
      "class_swaps": {"Chest": "HWPChest"},  # base units using Chest are copied with HWPChest (tools/class_units.py)
      "exclude": ["notes.md"],         # files not to package
      "local": ["hoh1/"],              # generated from the player's own HoH1 install:
                                       # packed only with --with-local, never released
      "local_overlay": "hoh1art/",     # local too, but packed in place of the committed file
                                       # at the same path without the prefix (hoh1art/x.png -> x.png)
      "dev": false                     # true: development harness, never packaged
    }
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import class_units  # noqa: E402
import hwr_archive as hwr  # noqa: E402
import gamepaths as paths  # noqa: E402

ALL_NAME = "HammerwatchPlus-All"
PACKAGE_PREFIX = "HWP-"
NEVER_PACK = {"module.json", "README.md", "_hwr_manifest.json", "info.xml"}  # info.xml becomes the archive meta
# overrides compare these as text (line endings and a BOM do not matter to the engine); anything else byte-exact
TEXT_EXTS = {".as", ".xml", ".sval", ".lang", ".gui", ".inc", ".net", ".unit", ".effect", ".txt", ".md", ".json", ".fnt"}


def load_module(mod_dir: Path) -> dict:
    cfg = {}
    cfg_path = mod_dir / "module.json"
    if cfg_path.is_file():
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    cfg.setdefault("id", mod_dir.name)
    if cfg["id"] != mod_dir.name:
        # deploy.py names the deployed mod after the folder; keep one identity everywhere
        sys.exit(f"{cfg_path}: id {cfg['id']!r} must match the folder name {mod_dir.name!r}")
    cfg.setdefault("requires", [])
    cfg.setdefault("overrides", [])
    cfg.setdefault("class_swaps", {})
    cfg.setdefault("exclude", [])
    cfg.setdefault("local", [])
    cfg.setdefault("local_overlay", "")
    if cfg["local_overlay"]:
        cfg["local_overlay"] = cfg["local_overlay"].rstrip("/") + "/"
        cfg["local"].append(cfg["local_overlay"])
    cfg.setdefault("dev", False)
    cfg["dir"] = mod_dir
    # overrides tools/class_units.py remakes from gamecode/sdk/hoh2/ on every build (no .orig needed)
    cfg["generated"] = class_units.units_for(cfg["class_swaps"]) if paths.BASE_HOH2.is_dir() else []
    try:
        cfg["meta"] = hwr.read_info_xml(mod_dir)
    except ValueError as e:
        sys.exit(str(e))
    if not cfg["meta"].get("name"):
        sys.exit(f"{mod_dir}/info.xml has no <name>")
    return cfg


def is_pristine_copy(rel: str) -> bool:
    """`<override>.orig` files are the untouched base copies that --check compares against."""
    return rel.endswith(".orig")


def is_local(cfg: dict, rel: str) -> bool:
    """Content the player generated from their own copy of another game (module.json
    `local`: path prefixes, e.g. the converted HoH1 levels). Never part of a release."""
    return any(rel == p or rel.startswith(p.rstrip("/") + "/") for p in cfg["local"])


def _skipper(cfg: dict, with_local: bool):
    return lambda rel: is_pristine_copy(rel) or (not with_local and is_local(cfg, rel))


def module_files(cfg: dict, with_local: bool = False):
    """(rel, path) of every file the module packs; the one rule build and --check share."""
    return hwr.packable_files(cfg["dir"], NEVER_PACK | set(cfg["exclude"]), _skipper(cfg, with_local))


def module_entries(cfg: dict, store: bool, with_local: bool = False) -> list[hwr.Entry]:
    manifest = None
    mpath = cfg["dir"] / hwr.MANIFEST
    if mpath.is_file():
        manifest = json.loads(mpath.read_text(encoding="utf-8"))
    entries = hwr.collect_dir(cfg["dir"], manifest, store, NEVER_PACK | set(cfg["exclude"]), _skipper(cfg, with_local))
    overlay = cfg["local_overlay"]
    if not (with_local and overlay):
        return entries
    # local_overlay: hoh1art/<path> stands in for the committed <path> (e.g. a placeholder)
    over = {e.path[len(overlay):]: e for e in entries if e.path.startswith(overlay)}
    for path, e in over.items():
        e.path = path
    return [e for e in entries if e.path not in over or over[e.path] is e]


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
    """Report wholesale overrides whose base copy no longer matches gamecode/sdk/hoh2/."""
    if not paths.BASE_HOH2.is_dir():
        sys.exit("run tools/bootstrap.py first (gamecode/sdk/hoh2 missing)")
    problems = 0
    owners: dict[str, str] = {}
    for cfg in mods:
        for rel in cfg["overrides"] + cfg["generated"]:
            if rel in owners:
                print(f"CONFLICT {rel}: owned by {owners[rel]} and {cfg['id']}")
                problems += 1
            owners[rel] = cfg["id"]
            base = paths.BASE_HOH2 / rel
            if rel in cfg["generated"]:
                if not base.is_file():
                    print(f"MISSING  {rel}: not in base game any more ({cfg['id']}, generated)")
                    problems += 1
                continue
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
    # Any packed file that also exists in base but isn't declared is an undeclared override.
    for cfg in mods:
        for rel, _fp in module_files(cfg):
            if rel in cfg["overrides"] or rel in cfg["generated"]:
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
    ap.add_argument("--with-local", action="store_true",
                    help="also pack module.json `local` content (converted HoH1 levels); for your own "
                         "install only, never publish such a package")
    args = ap.parse_args(argv)

    mods = [load_module(d) for d in paths.module_dirs()]
    if args.check:
        sys.exit(1 if check_overrides(mods) else 0)
    mods = [m for m in mods if not m["dev"]]     # dev harnesses are only ever linked (deploy.py --env gamelab)
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

    if paths.BASE_HOH2.is_dir():
        for m in mods:
            if m["class_swaps"]:
                print(f"class units: {m['id']} {len(class_units.generate(m))}")
    if any(m["id"] == "pets" for m in mods) and paths.BASE_HOH2.exists():
        import make_pet_dyes  # the two-section pet dye copies (gitignored, made from your installs)
        make_pet_dyes.main([])

    print("building:")
    all_entries: dict[str, hwr.Entry] = {}
    all_meta: dict = {}
    for cfg in mods:
        entries = module_entries(cfg, args.store, args.with_local)
        if args.with_local and any(is_local(cfg, rel) for rel, _fp in module_files(cfg, True)):
            print(f"  note: HWP-{cfg['id']}.bin contains locally generated content; do not publish it")
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
