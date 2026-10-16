#!/usr/bin/env python3
"""
import_hoh1.py - pull Heroes of Hammerwatch (1) content from the player's own
install and convert it for HammerwatchPlus. Nothing it writes is committed
(see the .gitignore files next to the outputs); every player runs it locally.

    import_hoh1.py pets              # HoH1 pet skins -> modules/pets (HoH2 Pet Shop entries)
    import_hoh1.py levels            # HoH1 campaign levels -> hoh1_import/campaign (decoded + gap report)
    import_hoh1.py campaign          # HoH1 boss + Battlements levels converted into modules/campaign/hoh1
    import_hoh1.py pets --force      # overwrite existing output
    import_hoh1.py --list            # what the tool can import

The HoH1 install is found like tools/paths.py does (HWP_HOH1_DIR overrides).

pets: reads HoH1 `tweak/pets.sval` + `players/pets/*.unit/.png` and writes

    modules/pets/players/pets/hwp/<skin>.unit|.png   units rewritten for HoH2 (texture paths,
                                                     pickup ranges, speed) - textures as PNG
    modules/pets/gui/hwp/icons_pets_hoh1.png          the HoH1 pet icon sheet
    modules/pets/doodads/hwp/outlook_props.png        living flame sprite sheet
    modules/pets/tweak/hwp/pets_hoh1.sval             PetDef entries (PetDef::LoadMultiple), so
                                                      the vanilla Pet Shop sells them

Skins HoH2 already ships (maltese cat, blue/red imp, raven, magpie, scarab,
beetle) are skipped. Names/descriptions live in the committed
modules/pets/res/language/english/hwp_pets.lang.

levels: the first step of the real Forsaken Tower import. Decodes the HoH1
boss levels, the hand-made Battlements levels and every act prefab (the HoH1
acts are generated from prefabs like HoH2 themes), and writes

    hoh1_import/campaign/report.md|.json     what each act references and what HoH2 lacks
    hoh1_import/campaign/levels/<name>.json  decoded levels (tile data as lengths)
    hoh1_import/campaign/tilesets/           the referenced HoH1 tilesets, textures as PNG

Needs the HoH2 base extracted to .base/ (tools/extract_base.py) to check
what already exists.

campaign: converts the real HoH1 levels (the five act boss levels, both
Battlements levels and Thundersnow's) with everything they reference into
modules/campaign/hoh1/ (in-game paths hoh1/...), see tools/hoh1_convert.py,
and writes modules/campaign/tweak/hwp/missions/missions_hwp_forsaken_tower_hoh1.sval:
a second Forsaken Tower whose boss and Battlements floors are the HoH1 levels.
Both outputs are gitignored; the conversion log is hoh1_import/campaign/convert.md.
"""
from __future__ import annotations

import argparse
import io
import json
import posixpath
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hoh1_convert as hoh1c  # noqa: E402
import hwr_archive as hwr  # noqa: E402
import paths  # noqa: E402

PETS_MODULE = paths.MODULES / "pets"

# units HoH2 ships itself (players/pets/<name>.unit)
HOH2_SHIPPED = {"cat_maltese", "imp", "imp_red", "raven", "raven_magpie", "scarab", "scarab_beetle"}

# HoH1 pet cost -> HoH2 Pet Shop cost (vanilla HoH2 pets cost 1500-10000)
COST_SCALE = {0: 1000, 25000: 2500, 50000: 5000, 100000: 10000}
LEGACY_MARKUP = 1.5  # skins HoH1 gated behind legacy points cost more

CATEGORY = {"imp": "Magical", "scarab": "Magical", "wyrm": "Magical",
            "cat": "Animals", "dog": "Animals", "raven": "Animals", "squire": "Animals"}

TEXTURE_SUBST = {
    "system/light_L.png": "effects/lights/light2_L.png",
    "doodads/generic/outlook_props.png": "doodads/hwp/outlook_props.png",
}

# behaviour params HoH2 pets use (cat_maltese.unit); HoH1 pets wander in a much
# smaller radius and walk slower, which looks lost on HoH2's bigger maps
PARAM_OVERRIDES = {
    "range-pickup": ("int", "300"),
    "pickup-leash-range": ("int", "400"),
    "leash-range": ("int", "100"),
    "path-timeout": ("int", "2000"),
}
SPEED_MUL = 1.4


def strip_preprocessor(text: str) -> str:
    """Drop %if/%endif/%// lines; the HoH1 pets.sval wraps the squire in %if HARDCORE."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("%"))


def parse_pets_sval(text: str) -> list[dict]:
    root = ET.fromstring("<root>" + strip_preprocessor(text).split("</loader>", 1)[-1] + "</root>")
    pets = []
    for pet in root.iter("dict"):
        pid = pet.find("string[@name='id']")
        if pid is None or pet.find("array[@name='skins']") is None:
            continue
        cost = int(pet.find("int[@name='cost']").text)
        skins = []
        for skin in pet.find("array[@name='skins']").findall("dict"):
            unit = skin.find("string[@name='unit']").text.strip()
            icon = skin.find("array[@name='icon']")
            rect = icon.find("vec4").text.split()
            legacy = skin.find("int[@name='legacy-points']")
            skins.append({
                "unit": unit,
                "base": Path(unit).stem,
                "rect": " ".join(rect),
                "legacy": int(legacy.text) if legacy is not None else 0,
            })
        pets.append({"id": pid.text.strip(), "cost": cost, "skins": skins})
    return pets


MATERIAL_SUBST = {"glow-both-bright": "bright-glow", "glow-both": "glow"}


def rewrite_unit(text: str, textures: set[str]) -> str:
    """Point the unit at the imported textures and bring its ranges to HoH2 scale."""
    def tex(m):
        path = m.group(1)
        textures.add(path)
        new = TEXTURE_SUBST.get(path)
        if new is None and path.startswith("players/pets/"):
            new = "players/pets/hwp/" + path[len("players/pets/"):]
        return 'texture="%s"' % (new or path)

    text = re.sub(r'texture="([^"]+)"', tex, text)
    # HoH1 material names that HoH2's system/default.mats no longer has
    for old_mat, new_mat in MATERIAL_SUBST.items():
        text = text.replace("system/default.mats:" + old_mat, "system/default.mats:" + new_mat)

    head, sep, tail = text.partition("</behavior>")
    if sep:
        for name, (typ, val) in PARAM_OVERRIDES.items():
            pat = re.compile(r'<%s name="%s">[^<]*</%s>' % (typ, name, typ))
            line = '<%s name="%s">%s</%s>' % (typ, name, val, typ)
            if pat.search(head):
                head = pat.sub(line, head)
            else:
                head = head.rstrip() + "\n\t\t" + line + "\n\t"
        for name in ("speed", "idle-speed"):
            pat = re.compile(r'(<float name="%s">)([0-9.]+)(</float>)' % name)
            head = pat.sub(lambda m: "%s%.2f%s" % (m.group(1), float(m.group(2)) * SPEED_MUL, m.group(3)), head)
        text = head + sep + tail
    return text


def to_png_pot(data: bytes) -> bytes:
    """Engine texture or PNG -> PNG with power-of-two dimensions (frames stay valid: padding is bottom/right)."""
    if hwr.is_texture(data):
        data = hwr.texture_to_png(data)
    from PIL import Image
    im = Image.open(io.BytesIO(data)).convert("RGBA")
    w, h = im.size
    pw, ph = 1, 1
    while pw < w:
        pw *= 2
    while ph < h:
        ph *= 2
    if (pw, ph) != (w, h):
        canvas = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
        canvas.paste(im, (0, 0))
        im = canvas
    out = io.BytesIO()
    im.save(out, "PNG")
    return out.getvalue()


def write(path: Path, data: bytes | str, force: bool, written: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not force:
        return
    if isinstance(data, str):
        path.write_text(data, encoding="utf-8", newline="\n")
    else:
        path.write_bytes(data)
    written.append(str(path.relative_to(paths.REPO)))


def import_pets(archive: hwr.Archive, force: bool) -> None:
    pets = parse_pets_sval(archive.read_file("tweak/pets.sval").decode("utf-8", "replace"))
    written: list[str] = []
    defs: list[str] = []
    textures: set[str] = set()
    skipped = []

    for pet in pets:
        base_cost = COST_SCALE.get(pet["cost"], max(1000, pet["cost"] // 10))
        for skin in pet["skins"]:
            if skin["base"] in HOH2_SHIPPED:
                skipped.append(skin["base"])
                continue
            entry = archive.find(skin["unit"])
            if entry is None:
                print(f"  ! {skin['unit']} missing in the HoH1 archive, skipped")
                continue
            unit_text = rewrite_unit(entry.data().decode("utf-8", "replace"), textures)
            write(PETS_MODULE / "players/pets/hwp" / (skin["base"] + ".unit"), unit_text, force, written)
            cost = int(base_cost * (LEGACY_MARKUP if skin["legacy"] else 1.0))
            defs.append(pet_def(skin["base"], cost, CATEGORY.get(pet["id"], "Animals"),
                                "gui/hwp/icons_pets_hoh1.png", skin["rect"]))

    # the living flame has no shop entry in HoH1 (it was a special unlock)
    flame = archive.find("players/pets/living_flame.unit")
    if flame is not None:
        unit_text = rewrite_unit(flame.data().decode("utf-8", "replace"), textures)
        write(PETS_MODULE / "players/pets/hwp/living_flame.unit", unit_text, force, written)
        defs.append(pet_def("living_flame", 7500, "Magical", "gui/pet_icons.png", "104 0 9 21"))

    for tex in sorted(textures):
        src = archive.find(tex)
        if src is None:
            if tex not in TEXTURE_SUBST:
                print(f"  ! texture {tex} missing in the HoH1 archive")
            continue
        if tex == "system/light_L.png":
            continue  # HoH2's effects/lights/light2_L.png stands in
        if tex.startswith("players/pets/"):
            out = PETS_MODULE / "players/pets/hwp" / Path(tex).name
        else:
            out = PETS_MODULE / TEXTURE_SUBST.get(tex, tex)
        write(out, to_png_pot(src.data()), force, written)

    icons = archive.find("gui/icons_pets.png")
    if icons is not None:
        write(PETS_MODULE / "gui/hwp/icons_pets_hoh1.png", to_png_pot(icons.data()), force, written)

    sval = ("<!-- GENERATED by tools/import_hoh1.py from your Heroes of Hammerwatch (1) install.\n"
            "     Not committed; names live in res/language/english/hwp_pets.lang. -->\n"
            "<loader>PetDef::LoadMultiple</loader>\n<array>\n" + "".join(defs) + "</array>\n")
    write(PETS_MODULE / "tweak/hwp/pets_hoh1.sval", sval, True, written)

    print(f"pets: {len(defs)} pet definitions, {len(skipped)} skins HoH2 already has ({', '.join(skipped)})")
    for w in written:
        print("  wrote", w)
    if not written:
        print("  nothing written (outputs exist; use --force to overwrite)")


def pet_def(base: str, cost: int, category: str, icon: str, rect: str) -> str:
    return ("\t<dict>\n"
            f"\t\t<string name=\"id\">hwp_pet_{base}</string>\n"
            f"\t\t<string name=\"name\">.hwp.pets.{base}.name</string>\n"
            f"\t\t<string name=\"description\">.hwp.pets.{base}.desc</string>\n"
            f"\t\t<int name=\"cost\">{cost}</int>\n"
            f"\t\t<array name=\"icon\"><s>{icon}</s><i>100</i><vec4>{rect}</vec4></array>\n"
            f"\t\t<string name=\"category\">{category}</string>\n"
            f"\t\t<string name=\"unit\">players/pets/hwp/{base}.unit</string>\n"
            "\t</dict>\n")


# ------------------------------------------------------------------- levels

LEVEL_HEADER = 8  # .lvl = 8 opaque bytes then the SValue dict; .pfb = the dict
IMPORT_DIR = paths.REPO / "hoh1_import" / "campaign"
PROBE_LEVEL = "levels/boss_arista.lvl"  # HoH2 level used to sanity-check the method

# (act id, HoH1 name, prefab folder, hand-made levels) in campaign order
ACTS = [
    ("mines", "Mines", "mine_granite", ["levels/boss_mines.lvl"]),
    ("prison", "Prison", "prison", ["levels/boss_prison.lvl"]),
    ("armory", "Armory", "armory", ["levels/boss_armory.lvl"]),
    ("archives", "Archives", "archives", ["levels/boss_archives.lvl"]),
    ("chambers", "Chambers", "chambers", ["levels/boss_chambers.lvl"]),
    ("battlements", "Battlements", "battlements", ["levels/battlements_1.lvl", "levels/battlements_2.lvl"]),
]
RES_EXT = (".unit", ".pfb", ".sval", ".env", ".png", ".tileset", ".fx", ".mats", ".bank", ".gui", ".lvl")
WORLDSCRIPT_DIR = paths.BASE_HOH2 / "scripts" / "WorldScript"
REF_SETS = ("tilesets", "units", "sprites", "prefabs", "scripts", "resources")
REF_COUNTS = ("layers", "placed", "script_count")


def empty_refs() -> dict:
    refs: dict = {k: set() for k in REF_SETS}
    refs.update({k: 0 for k in REF_COUNTS})
    return refs


def merge_refs(into: dict, refs: dict) -> None:
    for k in REF_SETS:
        into[k] |= refs[k]
    for k in REF_COUNTS:
        into[k] += refs[k]


def decode_level(data: bytes, path: str) -> dict:
    skip = LEVEL_HEADER if path.endswith(".lvl") else 0
    doc, end = hwr.decode_svalue(data, skip)
    if end != len(data):
        raise ValueError(f"{path}: {len(data) - end} trailing bytes")
    return doc


def walk_strings(value, out: set[str]) -> None:
    """Collect every string that names a resource file."""
    if isinstance(value, str):
        name = value.split(":")[0] if ":" in value and not value.startswith("event:") else value
        if "/" in name and name.endswith(RES_EXT):
            out.add(name)
    elif isinstance(value, dict):
        for v in value.values():
            walk_strings(v, out)
    elif isinstance(value, (list, tuple)) and not isinstance(value, hwr.Vec):
        for v in value:
            walk_strings(v, out)


def count_placements(placements) -> int:
    """`units` values are either flat [pos, id, pos, id, ...] or [[pos, id, params], ...]."""
    if not isinstance(placements, list) or not placements:
        return 0
    if isinstance(placements[0], list):
        return len(placements)
    return len(placements) // 2


def level_refs(doc: dict) -> dict:
    """What one level / prefab references, split by kind."""
    refs = empty_refs()
    for layer in doc.get("tiles") or []:
        for ds in layer.get("datasets") or []:
            if ds.get("tileset"):
                refs["tilesets"].add(ds["tileset"])
            refs["layers"] += 1
    for unit, placements in (doc.get("units") or {}).items():
        refs["placed"] += count_placements(placements)
        if unit.startswith(":"):              # :Physics_* are editor shapes
            continue
        refs["units" if unit.endswith(".unit") else "sprites"].add(unit)
    found: set[str] = set()
    for script in doc.get("scripts") or []:
        if isinstance(script, list) and script and isinstance(script[0], str):
            refs["scripts"].add(script[0])
            refs["script_count"] += 1
            walk_strings(script[6:], found)   # 0-5: type, id, pos, flags; then name, params, links
    walk_strings(doc.get("prefabs"), found)
    env = (doc.get("lighting") or {}).get("environment")
    if env:
        found.add(env)
    for name in found:
        if name.endswith(".unit"):
            refs["units"].add(name)           # spawned by scripts (UnitType, spawners)
        elif name.endswith(".pfb"):
            refs["prefabs"].add(name)
        elif name.endswith(".tileset"):
            refs["tilesets"].add(name)
        else:
            refs["resources"].add(name)
    return refs


def hoh2_has(path: str) -> bool:
    return (paths.BASE_HOH2 / path).is_file()


def hoh2_world_scripts() -> set[str]:
    names = set()
    for f in WORLDSCRIPT_DIR.rglob("*.as"):
        text = f.read_text(encoding="utf-8", errors="replace")
        names.update(re.findall(r"^\s*(?:abstract\s+|final\s+|shared\s+)*class\s+(\w+)", text, re.M))
    return names


def json_default(v):
    if isinstance(v, (bytes, bytearray)):     # tile data; Vec serialises as a list already
        return {"blob_bytes": len(v)}
    raise TypeError(type(v).__name__)


def resolve_relative(owner: str, ref: str) -> str:
    """HoH1 data sometimes names files relative to the referencing file (./x.png)."""
    if ref.startswith("./") or ref.startswith("../"):
        return posixpath.normpath(posixpath.join(posixpath.dirname(owner), ref))
    return ref


def import_levels(archive: hwr.Archive, force: bool) -> None:
    probe_path = paths.BASE_HOH2 / PROBE_LEVEL
    if not probe_path.is_file() or not WORLDSCRIPT_DIR.is_dir():
        sys.exit(f"{paths.BASE_HOH2} has no (complete) extracted HoH2 base; run tools/extract_base.py first")
    written: list[str] = []
    scripts2 = hoh2_world_scripts()
    probe = level_refs(decode_level(probe_path.read_bytes(), PROBE_LEVEL))
    report = {"hoh2_probe": {"level": PROBE_LEVEL, "scripts": len(probe["scripts"]),
                             "unresolved": sorted(probe["scripts"] - scripts2)}, "acts": []}
    by_folder: dict[str, list[str]] = {}
    for e in archive.entries:
        parts = e.path.split("/")
        if parts[0] == "prefabs" and len(parts) >= 3 and e.path.endswith(".pfb"):
            by_folder.setdefault(parts[1], []).append(e.path)
    all_tilesets: set[str] = set()
    for act_id, act_name, folder, levels in ACTS:
        roots = list(levels) + sorted(by_folder.get(folder, []))
        total = empty_refs()
        decoded: set[str] = set()
        broken_prefabs: set[str] = set()
        queue = list(roots)
        while queue:                          # follow prefab references into other folders
            path = queue.pop()
            if path in decoded or path in broken_prefabs:
                continue
            if archive.find(path) is None:
                broken_prefabs.add(path)
                continue
            doc = decode_level(archive.read_file(path), path)
            decoded.add(path)
            refs = level_refs(doc)
            merge_refs(total, refs)
            queue.extend(p for p in refs["prefabs"] if p not in decoded)
            if path.endswith(".lvl"):
                write(IMPORT_DIR / "levels" / (Path(path).stem + ".json"),
                      json.dumps(doc, default=json_default, indent=1), force, written)
        broken_tilesets = sorted(t for t in total["tilesets"] if archive.find(t) is None)
        for t in broken_tilesets:
            print(f"  warning: {act_name} references tileset {t!r}, which is not in the HoH1 archive")
        for p in sorted(broken_prefabs):
            print(f"  warning: {act_name} references prefab {p!r}, which is not in the HoH1 archive")
        all_tilesets |= total["tilesets"] - set(broken_tilesets)
        outside = sorted(p for p in decoded if p not in roots)
        act = {
            "id": act_id, "name": act_name, "levels": levels,
            "files": len(decoded), "act_prefabs": len(roots) - len(levels), "other_prefabs": outside,
            "tile_layers": total["layers"], "placed_units": total["placed"], "script_nodes": total["script_count"],
            "tilesets": sorted(total["tilesets"]),
            "tilesets_in_hoh2": sorted(t for t in total["tilesets"] if hoh2_has(t)),
            "tilesets_broken": broken_tilesets,
            "prefabs_broken": sorted(broken_prefabs),
            "units": sorted(total["units"]),
            "units_in_hoh2": sorted(u for u in total["units"] if hoh2_has(u)),
            "sprites": sorted(total["sprites"]),
            "scripts": sorted(total["scripts"]),
            "scripts_not_in_hoh2": sorted(total["scripts"] - scripts2),
            "resources": sorted(total["resources"]),
            "resources_in_hoh2": sorted(r for r in total["resources"] if hoh2_has(r)),
        }
        report["acts"].append(act)
        print("%-12s %4d files  tilesets %2d (%d in HoH2)  units %4d (%d in HoH2)  scripts %3d (%d unknown)" % (
            act_name, len(decoded), len(act["tilesets"]), len(act["tilesets_in_hoh2"]),
            len(act["units"]), len(act["units_in_hoh2"]), len(act["scripts"]), len(act["scripts_not_in_hoh2"])))
    units_all = set().union(*(a["units"] for a in report["acts"]))
    units_hoh2 = set().union(*(a["units_in_hoh2"] for a in report["acts"]))
    scripts_all = set().union(*(a["scripts_not_in_hoh2"] for a in report["acts"]))
    report["totals"] = {"tilesets": len(all_tilesets), "tilesets_in_hoh2": sum(1 for t in all_tilesets if hoh2_has(t)),
                        "unit_types": len(units_all), "unit_types_missing": len(units_all - units_hoh2),
                        "script_types_missing": len(scripts_all)}
    # the referenced tilesets, textures converted to PNG
    for ts in sorted(all_tilesets):
        text = archive.read_file(ts).decode("utf-8", errors="replace")
        write(IMPORT_DIR / ts, text, force, written)
        m = re.search(r'texture="([^"]+)"', text)
        if not m:
            continue
        tex = resolve_relative(ts, m.group(1))
        if archive.find(tex) is None:
            print(f"  warning: tileset {ts} names texture {m.group(1)!r}, which is not in the HoH1 archive")
            continue
        write(IMPORT_DIR / tex, to_png_pot(archive.read_file(tex)), force, written)
    write(IMPORT_DIR / "report.json", json.dumps(report, indent=1), True, written)
    write(IMPORT_DIR / "report.md", levels_report_md(report), True, written)
    t = report["totals"]
    print("totals: %d tilesets (%d in HoH2), %d unit types (%d missing in HoH2), %d script types missing" % (
        t["tilesets"], t["tilesets_in_hoh2"], t["unit_types"], t["unit_types_missing"], t["script_types_missing"]))
    print("wrote %d files under %s (report.md has the gaps)" % (len(written), IMPORT_DIR.relative_to(paths.REPO)))


def levels_report_md(report: dict) -> str:
    probe = report["hoh2_probe"]
    t = report["totals"]
    out = ["# HoH1 campaign import report", "",
           "Generated by `tools/import_hoh1.py levels`. Nothing here is committed.", "",
           "Method check: HoH2 `%s` uses %d script types, unresolved against `scripts/WorldScript`: %s." % (
               probe["level"], probe["scripts"], ", ".join(probe["unresolved"]) or "none"), "",
           "All acts: %d tilesets (%d in HoH2), %d unit types (%d missing in HoH2), %d script types missing in HoH2." % (
               t["tilesets"], t["tilesets_in_hoh2"], t["unit_types"], t["unit_types_missing"], t["script_types_missing"]), "",
           "| Act | files | tile layers | placed units | tilesets (in HoH2) | unit types (in HoH2) | script types (unknown to HoH2) |",
           "|---|---|---|---|---|---|---|"]
    for a in report["acts"]:
        out.append("| %s | %d | %d | %d | %d (%d) | %d (%d) | %d (%d) |" % (
            a["name"], a["files"], a["tile_layers"], a["placed_units"], len(a["tilesets"]), len(a["tilesets_in_hoh2"]),
            len(a["units"]), len(a["units_in_hoh2"]), len(a["scripts"]), len(a["scripts_not_in_hoh2"])))
    out.append("")
    for a in report["acts"]:
        out += ["## " + a["name"], "",
                "Levels: %s; act prefabs: %d; prefabs followed from other folders: %d." % (
                    ", ".join(a["levels"]), a["act_prefabs"], len(a["other_prefabs"])), ""]
        out.append("Tilesets: " + ", ".join("`%s`%s" % (ts, " (HoH2 has it)" if ts in a["tilesets_in_hoh2"] else "")
                                            for ts in a["tilesets"]))
        out.append("")
        if a["tilesets_broken"] or a["prefabs_broken"]:
            out.append("Broken references (not in the HoH1 archive either): " +
                       ", ".join("`%s`" % x for x in a["tilesets_broken"] + a["prefabs_broken"]))
            out.append("")
        out.append("Script types not in HoH2 (%d of %d): %s" % (
            len(a["scripts_not_in_hoh2"]), len(a["scripts"]), ", ".join(a["scripts_not_in_hoh2"]) or "none"))
        out.append("")
        missing_units = [u for u in a["units"] if u not in a["units_in_hoh2"]]
        groups: dict[str, int] = {}
        for u in missing_units:
            g = u.rsplit("/", 1)[0]
            groups[g] = groups.get(g, 0) + 1
        out += ["Unit types missing in HoH2 (%d of %d, placed or spawned by scripts), by folder:" % (
            len(missing_units), len(a["units"])), ""]
        out += ["- `%s/` %d" % (g, n) for g, n in sorted(groups.items(), key=lambda kv: -kv[1])]
        if a["sprites"]:
            out += ["", "Light sprites placed directly: " + ", ".join("`%s`" % x for x in a["sprites"])]
        missing_res = [r for r in a["resources"] if r not in a["resources_in_hoh2"]]
        out += ["", "Other referenced files missing in HoH2 (%d of %d):" % (len(missing_res), len(a["resources"])), ""]
        out += ["- `%s`" % r for r in missing_res[:60]]
        if len(missing_res) > 60:
            out.append("- ... %d more (report.json)" % (len(missing_res) - 60))
        out.append("")
    return "\n".join(out) + "\n"


# ----------------------------------------------------------------- campaign

CAMPAIGN_MODULE = paths.MODULES / "campaign"
CAMPAIGN_OUT = CAMPAIGN_MODULE / "hoh1"
CAMPAIGN_MISSION_SRC = CAMPAIGN_MODULE / "tweak" / "hwp" / "missions" / "missions_hwp_forsaken_tower.sval"
CAMPAIGN_MISSION_OUT = CAMPAIGN_MODULE / "tweak" / "hwp" / "missions" / "missions_hwp_forsaken_tower_hoh1.sval"
CAMPAIGN_MISSION_ID = "hwp_forsaken_tower_hoh1"

# floor id in the committed mission -> (HoH1 level, lang key of the floor name)
CAMPAIGN_FLOORS = {
    "mines_boss": ("levels/boss_mines.lvl", ".hwp.campaign.h1.golem"),
    "prison_boss": ("levels/boss_prison.lvl", ".hwp.campaign.h1.warden"),
    "armory_boss": ("levels/boss_armory.lvl", ".hwp.campaign.h1.councilors"),
    "archives_boss": ("levels/boss_archives.lvl", ".hwp.campaign.h1.watcher"),
    "chambers_boss": ("levels/boss_chambers.lvl", ".hwp.campaign.h1.vampire"),
    "battlements_1": ("levels/battlements_1.lvl", ".hwp.campaign.h1.battlements_1"),
    "battlements_2": ("levels/battlements_2.lvl", ".hwp.campaign.h1.battlements_2"),
    "battlements_boss": ("levels/boss_dragon.lvl", ".hwp.campaign.h1.dragon"),
}

# HoH1 class -> HoH2 class (or our port, scripts/HWP/Campaign/HoH1/). Filled in
# as the in-game checks find them; anything not listed keeps its HoH1 name.
CLASS_MAP: dict[str, str] = {
    "StaticLevel": "BossLevel",        # the Battlements game mode; HoH2's mission levels are BossLevel
    # effects (HoH1/Effects.as)
    "GiveGold": "HoH1GiveGold",
    "GiveOre": "HoH1GiveOre",
    "Decimate": "HoH1Decimate",
    "AddCurse": "HoH1AddCurse",
    "AddMtBlock": "HoH1InertEffect",          # HoH1 Lunar Shield block; no HoH2 match yet
    "ApplySoulDaggerBuff": "HoH1InertEffect",
    "CombustionDamage": "HoH1InertEffect",
    # projectiles (HoH1/Projectiles.as)
    "Projectile": "HoH1Projectile",
    "TossProjectile": "HoH1TossProjectile",
    "LurkerProjectile": "HoH1LurkerProjectile",
    # bosses (HoH1/Bosses.as)
    "BossLich": "HoH1BossLich",
    "BossLichMovement": "HoH1BossLichMovement",
    "BossLichRandomSkill": "HoH1BossLichRandomSkill",
    "BossVampire": "HoH1BossVampire",
    "BossVampireMovement": "HoH1BossVampireMovement",
    "BossEye": "HoH1BossEye",
    "BossEyeWisp": "HoH1BossEyeWisp",
    "Miniboss": "CompositeActorBehavior",    # drops HoH1's overhead miniboss bar
    "CompositeActorBehaviorNoNGPScale": "CompositeActorBehavior",
    # enemy skills (HoH1/Skills.as)
    "ChargeStrike": "HoH1ChargeStrike",
    "JumpStrike": "HoH1JumpStrike",
    "SpewSkill": "HoH1SpewSkill",
    "WhirlwindSkill": "HoH1WhirlwindSkill",
    "WhirlNovaSkill": "HoH1WhirlNovaSkill",
    # world scripts: HoH2 has these rooms under other names, with the same fields
    "RandomTemporaryBuff": "Shrine",
    "RandomBuff": "Shrine",                  # the blood altar; HoH2 has no blood altar rewards
    "RandomStuff": "Imp",
}

# "<mats path>:<HoH1 material>" -> HoH2 material name in the same file
MATERIAL_MAP = {
    "system/default.mats:glow-both-bright": "bright-glow",
}


def campaign_mission(src: str) -> str:
    """The committed mission, re-pointed at the converted HoH1 levels."""
    head, sep, rest = src.partition('<array name="levels">')
    if not sep:
        sys.exit(f"{CAMPAIGN_MISSION_SRC}: no levels array")
    head = head.replace('<string name="id">hwp_forsaken_tower</string>',
                        f'<string name="id">{CAMPAIGN_MISSION_ID}</string>', 1)
    head = head.replace('.mission.hwp_forsaken_tower.name', f'.mission.{CAMPAIGN_MISSION_ID}.name', 1)
    head = head.replace('.mission.hwp_forsaken_tower.desc', f'.mission.{CAMPAIGN_MISSION_ID}.desc', 1)
    head = re.sub(r"<!--.*?-->", "<!-- Generated by tools/import_hoh1.py campaign from "
                  "missions_hwp_forsaken_tower.sval. Do not edit; not committed. -->", head, count=1, flags=re.S)
    blocks = re.split(r"(?m)^(?=\t\t<dict>)", rest)
    out = []
    done = set()
    for b in blocks:
        m = re.search(r'<string name="id">(\w+)</string>', b)
        fid = m.group(1) if m else None
        if fid in CAMPAIGN_FLOORS and b.lstrip().startswith("<dict>"):
            level, name_key = CAMPAIGN_FLOORS[fid]
            diff = re.search(r'<int name="diff-level">(\d+)</int>', b).group(1)
            ngp = re.search(r'<int name="diff-level-ngp">(\d+)</int>', b).group(1)
            act = re.search(r'<string name="act-name">([^<]+)</string>', b)
            # the floor ends at its own (two-tab) </dict>; the last floor's block
            # also carries the closing </array></dict> of the mission
            end = re.search(r"(?m)^\t\t</dict>", b)
            tail = b[end.end():]
            floor = ["\t\t<dict>",
                     f'\t\t\t<string name="id">{fid}</string>',
                     f'\t\t\t<string name="level">{hoh1c.PREFIX}{level}</string>',
                     f'\t\t\t<int name="diff-level">{diff}</int>',
                     f'\t\t\t<int name="diff-level-ngp">{ngp}</int>',
                     ""]
            if act:
                floor.append(f'\t\t\t<string name="act-name">{act.group(1)}</string>')
            floor.append(f'\t\t\t<string name="level-name">{name_key}</string>')
            floor.append("\t\t</dict>")
            out.append("\n".join(floor) + tail)
            done.add(fid)
        else:
            out.append(b)
    missing = set(CAMPAIGN_FLOORS) - done
    if missing:
        sys.exit(f"{CAMPAIGN_MISSION_SRC}: floors {sorted(missing)} not found")
    return head + sep + "".join(out)


def import_campaign(archive: hwr.Archive, force: bool) -> None:
    import shutil
    if not (paths.BASE_HOH2 / "system").is_dir():
        sys.exit(f"{paths.BASE_HOH2} has no extracted HoH2 base; run tools/extract_base.py first")
    roots = [lv for lv, _ in CAMPAIGN_FLOORS.values()]
    closure = hoh1c.Closure(archive, hoh2_has=lambda p: (paths.BASE_HOH2 / p).is_file())
    closure.add_roots(roots)
    rw = hoh1c.Rewriter(copied=closure.files, hoh2_materials=hoh1c.hoh2_material_names(paths.BASE_HOH2),
                        class_map=CLASS_MAP, material_map=MATERIAL_MAP)
    if CAMPAIGN_OUT.exists():
        shutil.rmtree(CAMPAIGN_OUT)          # generated, gitignored: always rebuilt from scratch
    written: list[str] = []
    for path in sorted(closure.files):
        write(CAMPAIGN_OUT / path, hoh1c.convert_file(archive, path, rw, to_png_pot), True, written)
    write(CAMPAIGN_MISSION_OUT, campaign_mission(CAMPAIGN_MISSION_SRC.read_text(encoding="utf-8")), True, written)
    exts: dict[str, int] = {}
    for f in closure.files:
        e = f.rsplit(".", 1)[-1]
        exts[e] = exts.get(e, 0) + 1
    log = ["# HoH1 campaign conversion", "",
           "Generated by `tools/import_hoh1.py campaign`. Nothing here is committed.", "",
           "Levels: " + ", ".join(f"`{r}`" for r in roots), "",
           "Copied %d files under `modules/campaign/hoh1/`: %s." % (
               len(closure.files), ", ".join(f"{n} .{e}" for e, n in sorted(exts.items(), key=lambda kv: -kv[1]))), "",
           "Rewrites: " + ", ".join(f"{k} {v}" for k, v in sorted(rw.stats.items())), "",
           "References HoH1 itself does not ship (left as they are):", ""]
    log += ["- `%s` (from %s)" % (b, ", ".join(sorted(by)[:3])) for b, by in sorted(closure.broken.items())]
    write(IMPORT_DIR / "convert.md", "\n".join(log) + "\n", True, written)
    print("campaign: %d HoH1 files converted into %s, %d broken references (see %s)" % (
        len(closure.files), CAMPAIGN_OUT.relative_to(paths.REPO), len(closure.broken),
        (IMPORT_DIR / "convert.md").relative_to(paths.REPO)))
    print("  mission %s -> %s" % (CAMPAIGN_MISSION_ID, CAMPAIGN_MISSION_OUT.relative_to(paths.REPO)))


IMPORTERS = {"pets": import_pets, "levels": import_levels, "campaign": import_campaign}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", nargs="?", choices=sorted(IMPORTERS), help="what to import")
    ap.add_argument("--hoh1", help="Heroes of Hammerwatch (1) install dir (default: auto / HWP_HOH1_DIR)")
    ap.add_argument("--force", action="store_true", help="overwrite existing output files")
    ap.add_argument("--list", action="store_true", help="list importers")
    args = ap.parse_args(argv)
    if args.list or not args.what:
        for k in sorted(IMPORTERS):
            print(k)
        return
    hoh1 = Path(args.hoh1) if args.hoh1 else paths.hoh1_dir()
    bin_path = hoh1 / "res" / "assets.bin"
    if not bin_path.is_file():
        sys.exit(f"{bin_path} not found")
    print("reading", bin_path)
    archive = hwr.Archive.read(bin_path)
    IMPORTERS[args.what](archive, args.force)


if __name__ == "__main__":
    main()
