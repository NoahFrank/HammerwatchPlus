#!/usr/bin/env python3
"""
import_hoh1.py - pull Heroes of Hammerwatch (1) content from the player's own
install and convert it for HammerwatchPlus. Nothing it writes is committed
(see the .gitignore files next to the outputs); every player runs it locally.

    import_hoh1.py pets              # HoH1 pet skins -> mods/pets (HoH2 Pet Shop entries)
    import_hoh1.py levels            # HoH1 campaign levels -> hoh1_import/campaign (decoded + gap report)
    import_hoh1.py campaign          # HoH1 boss + Battlements levels converted into mods/campaign/hoh1
    import_hoh1.py classes           # HoH1 Thief/Gladiator/Witch Hunter art -> mods/classes/hoh1art
    import_hoh1.py pets --force      # overwrite existing output
    import_hoh1.py --list            # what the tool can import

The HoH1 install is found like tools/gamepaths.py does (HWP_HOH1_DIR overrides).

pets: reads HoH1 `tweak/pets.sval` + `players/pets/*.unit/.png` and writes

    mods/pets/players/pets/hwp/<skin>.unit|.png   units rewritten for HoH2 (texture paths,
                                                     pickup ranges, speed) - textures as PNG
    mods/pets/gui/hwp/icons_pets_hoh1.png          the HoH1 pet icon sheet
    mods/pets/doodads/hwp/outlook_props.png        living flame sprite sheet
    mods/pets/tweak/hwp/pets_hoh1.sval             PetDef entries (PetDef::LoadMultiple), so
                                                      the vanilla Pet Shop sells them

Skins HoH2 already ships (maltese cat, blue/red imp, raven, magpie, scarab,
beetle) are skipped. Names/descriptions live in the committed
mods/pets/res/language/english/hwp_pets.lang.

levels: the first step of the real Forsaken Tower import. Decodes the HoH1
boss levels, the hand-made Battlements levels and every act prefab (the HoH1
acts are generated from prefabs like HoH2 themes), and writes

    hoh1_import/campaign/report.md|.json     what each act references and what HoH2 lacks
    hoh1_import/campaign/levels/<name>.json  decoded levels (tile data as lengths)
    hoh1_import/campaign/tilesets/           the referenced HoH1 tilesets, textures as PNG

Needs the HoH2 base extracted to gamecode/sdk/hoh2/ (tools/bootstrap.py) to check
what already exists.

campaign: converts the real HoH1 levels (the five act boss levels, both
Battlements levels and Thundersnow's) with everything they reference into
mods/campaign/hoh1/ (in-game paths hoh1/...), see tools/hoh1_convert.py,
and writes mods/campaign/tweak/hwp/missions/missions_hwp_forsaken_tower_hoh1.sval:
a second Forsaken Tower whose boss and Battlements floors are the HoH1 levels,
and mods/campaign/tweak/missions/missions_dark_citadel.sval: the main game's
Dark Citadel with both Battlements floors before the Avatar. All outputs are
gitignored; the conversion log is hoh1_import/campaign/convert.md.

classes: draws the HoH1 Thief, Gladiator and Witch Hunter for the character
creation class icons (players/<class>.tif, the idle frame facing the camera,
in default HoH1 dyes, on the vanilla HoH2 showcase shadow) and copies their
HoH1 skill icons (gui/icons_skills.png) into our skill icon sheet layout:

    mods/classes/hoh1art/players/hwp/<class>/class_showcase.png|icons.png

hoh1art/ is the classes module's `local_overlay`: build.py --with-local packs
these in place of the committed placeholder art at the same paths.
"""
from __future__ import annotations

import argparse
import io
import json
import posixpath
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hoh1_convert as hoh1c  # noqa: E402
import hwr_archive as hwr  # noqa: E402
import gamepaths as paths  # noqa: E402

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


# The shop icon of the living flame is HoH2's candle pet (a wax candle); HoH1's
# unit is only the flame, so it gets our own candle (committed art, 7x10, wick
# at the top) under it: the flame and its lights move up onto the wick.
FLAME_LIFT = 9
CANDLE_SPRITE = ('\t\t\t<sprite origin="3 9" texture="doodads/hwp/living_flame_candle.png" '
                 'material="system/default.mats:default"><frame>0 0 7 10</frame></sprite>\n')


def candle_body(unit_text: str) -> str:
    m = re.search(r'(\t*)<sprite origin="(-?\d+) (-?\d+)"([^>]*outlook_props[^>]*)>', unit_text)
    if m is None:
        print("  ! living_flame.unit: flame sprite not found, no candle body")
        return unit_text
    # the flame's base is its 4th column: origin x - 1 puts it right over the wick
    flame = '%s<sprite origin="%d %d"%s>' % (m.group(1), int(m.group(2)) - 1, int(m.group(3)) + FLAME_LIFT, m.group(4))
    unit_text = unit_text[:m.start()] + CANDLE_SPRITE + flame + unit_text[m.end():]
    return re.sub(r'<light pos="(-?\d+) (-?\d+)">',
                  lambda l: '<light pos="%s %d">' % (l.group(1), int(l.group(2)) - FLAME_LIFT), unit_text)


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
        unit_text = candle_body(rewrite_unit(flame.data().decode("utf-8", "replace"), textures))
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
    """HoH1's archive holds binary levels; the PACKAGER unpack in gamecode/sdk/hoh2/ (bootstrap.py)
    writes them as SValue XML, which is what the HoH2 probe level reads."""
    if data.lstrip(b"\xef\xbb\xbf \t\r\n")[:1] == b"<":
        return hwr.parse_svalue_xml(data.decode("utf-8-sig"))
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
        sys.exit(f"{paths.BASE_HOH2} has no (complete) extracted HoH2 base; run tools/bootstrap.py first")
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
# The main game's Dark Citadel with both HoH1 Battlements floors (clouds, glass
# walkways, ice trolls) spliced in before the Avatar: a wholesale override of
# the vanilla mission file, declared in the campaign module.json with its .orig.
CITADEL_REL = "tweak/missions/missions_dark_citadel.sval"
CITADEL_OUT = CAMPAIGN_MODULE / CITADEL_REL
CITADEL_BEFORE = "dark_halls_boss"
# (floor id, level, diff-level, diff-level-ngp, level-name key)
CITADEL_FLOORS = [
    ("hwp_battlements_1", "levels/battlements_1.lvl", 21, 21, ".hwp.campaign.h1.battlements_1"),
    ("hwp_battlements_2", "levels/battlements_2.lvl", 22, 22, ".hwp.campaign.h1.battlements_2"),
]

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


def citadel_mission(src: str) -> str:
    """The vanilla Dark Citadel with the Battlements floors before its last boss."""
    m = re.search(r'(?m)^\t\t<dict>\s*\n\t\t\t<string name="id">%s</string>' % CITADEL_BEFORE, src)
    if m is None:
        sys.exit(f"{CITADEL_REL}: floor {CITADEL_BEFORE} not found (game update?)")
    nl = "\r\n" if "\r\n" in src else "\n"
    floors = ["\t\t%// Battlements (HoH1, tools/import_hoh1.py campaign)"]
    for fid, level, diff, ngp, name_key in CITADEL_FLOORS:
        floors += ["\t\t<dict>",
                   f'\t\t\t<string name="id">{fid}</string>',
                   f'\t\t\t<string name="level">{hoh1c.PREFIX}{level}</string>',
                   f'\t\t\t<int name="diff-level">{diff}</int>',
                   f'\t\t\t<int name="diff-level-ngp">{ngp}</int>',
                   "",
                   '\t\t\t<string name="act-name">.hwp.campaign.act.battlements</string>',
                   f'\t\t\t<string name="level-name">{name_key}</string>',
                   "\t\t</dict>",
                   ""]
    head = ("<!-- Generated by tools/import_hoh1.py campaign from the vanilla " + CITADEL_REL +
            " (Battlements floors before the Avatar). Do not edit; not committed. -->" + nl)
    return head + src[:m.start()] + nl.join(floors) + nl + src[m.start():]


def import_campaign(archive: hwr.Archive, force: bool) -> None:
    import shutil
    if not (paths.BASE_HOH2 / "system").is_dir():
        sys.exit(f"{paths.BASE_HOH2} has no extracted HoH2 base; run tools/bootstrap.py first")
    roots = [lv for lv, _ in CAMPAIGN_FLOORS.values()]
    closure = hoh1c.Closure(archive, hoh2_has=lambda p: (paths.BASE_HOH2 / p).is_file())
    closure.add_roots(roots)
    rw = hoh1c.Rewriter(copied=closure.files, hoh2_materials=hoh1c.hoh2_material_names(paths.BASE_HOH2),
                        class_map=CLASS_MAP, material_map=MATERIAL_MAP)
    # convert everything first: a file that fails leaves the previous output intact
    converted = [(path, hoh1c.convert_file(archive, path, rw, to_png_pot)) for path in sorted(closure.files)]
    marker = CAMPAIGN_OUT / ".hwp-generated"     # dot files are never packed
    if CAMPAIGN_OUT.exists():
        # generated and gitignored, so it is rebuilt from scratch; but only delete
        # a folder this tool wrote: its marker, or (versions before the marker)
        # the mission file it generates alongside
        older = (CAMPAIGN_MISSION_OUT.is_file()
                 and "Generated by tools/import_hoh1.py campaign" in CAMPAIGN_MISSION_OUT.read_text(encoding="utf-8"))
        if not (marker.is_file() or older or force):
            sys.exit(f"{CAMPAIGN_OUT} exists but was not written by this tool; move it away or pass --force")
        shutil.rmtree(CAMPAIGN_OUT)
    CAMPAIGN_OUT.mkdir(parents=True)
    marker.write_text("written by tools/import_hoh1.py campaign; deleted and rebuilt on every run" + chr(10), encoding="utf-8")
    written: list[str] = []
    for path, data in converted:
        write(CAMPAIGN_OUT / path, data, True, written)
    write(CAMPAIGN_MISSION_OUT, campaign_mission(CAMPAIGN_MISSION_SRC.read_text(encoding="utf-8")), True, written)
    citadel = (paths.BASE_HOH2 / CITADEL_REL).read_bytes().decode("utf-8")
    write(CITADEL_OUT, citadel_mission(citadel), True, written)
    exts: dict[str, int] = {}
    for f in closure.files:
        e = f.rsplit(".", 1)[-1]
        exts[e] = exts.get(e, 0) + 1
    log = ["# HoH1 campaign conversion", "",
           "Generated by `tools/import_hoh1.py campaign`. Nothing here is committed.", "",
           "Levels: " + ", ".join(f"`{r}`" for r in roots), "",
           "Copied %d files under `mods/campaign/hoh1/`: %s." % (
               len(closure.files), ", ".join(f"{n} .{e}" for e, n in sorted(exts.items(), key=lambda kv: -kv[1]))), "",
           "Rewrites: " + ", ".join(f"{k} {v}" for k, v in sorted(rw.stats.items())), "",
           "References HoH1 itself does not ship (left as they are):", ""]
    log += ["- `%s` (from %s)" % (b, ", ".join(sorted(by)[:3])) for b, by in sorted(closure.broken.items())]
    write(IMPORT_DIR / "convert.md", "\n".join(log) + "\n", True, written)
    print("campaign: %d HoH1 files converted into %s, %d broken references (see %s)" % (
        len(closure.files), CAMPAIGN_OUT.relative_to(paths.REPO), len(closure.broken),
        (IMPORT_DIR / "convert.md").relative_to(paths.REPO)))
    print("  mission %s -> %s" % (CAMPAIGN_MISSION_ID, CAMPAIGN_MISSION_OUT.relative_to(paths.REPO)))
    print("  Dark Citadel with the Battlements before the Avatar -> %s" % CITADEL_OUT.relative_to(paths.REPO))


# ------------------------------------------------------------------ classes

CLASSES_MODULE = paths.MODULES / "classes"
CLASS_ART = CLASSES_MODULE / "hoh1art"  # the classes module.json "local_overlay"

# our class folder -> (HoH1 class, default dye per colour channel). The channels
# follow tweak/playermaterials.sval "mapping" order (skin, hair, then the class's
# four categories); each pick is (category, dye id) from the same file.
HOH1_CLASS_ART = {
    "thief": ("thief", [("skin", "shade2"), ("hair", "black"), ("cloth", "green"),
                        ("cloth", "brown"), ("leather", "brown"), ("leather", "red")]),
    "gladiator": ("gladiator", [("skin", "shade2"), ("hair", "brown"), ("leather", "brown"),
                                ("metal", "gray"), ("cloth", "red"), ("metal", "gray")]),
    "witchhunter": ("witch_hunter", [("skin", "shade2"), ("hair", "brown"), ("leather", "brown"),
                                     ("leather", "red"), ("metal", "gray"), ("metal", "light_blue")]),
}
SHOWCASE_SCENE = "idle-2"  # the idle frame facing the camera
# HoH1 figures are 24 px sprites, HoH2's 32 px: drawn at 1.5x on a 48x48 icon (the class
# svals' icon rect), feet where vanilla's 32x32 showcase figures stand (7 px below centre).
# Textures must be power-of-two sized, so the icon is the top-left of a 64x64 texture.
SHOWCASE_SIZE, SHOWCASE_TEXTURE, SHOWCASE_SCALE, SHOWCASE_FEET = 48, 64, 1.5, (24, 31)

# our players/hwp/<class>/icons.png cell -> HoH1 gui/icons_skills.png cell (24x24 each).
# HoH1 skills we kept use their own icon; the new ones borrow a fitting HoH1 icon.
HOH1_SKILL_ICONS = {
    "thief": {
        (0, 0): (24, 72),       # knives: throwing knives
        (48, 0): (120, 72),     # smoke: smoke bomb
        (72, 0): (48, 72),      # sidestep
        (96, 0): (168, 72),     # vicious cuts (+ Assassin mastery)
        (120, 0): (48, 216),    # shadow strike
        (144, 0): (0, 72),      # backstab: twin daggers
        (0, 24): (72, 72),      # slice and dice (+ Trickster mastery)
        (24, 24): (96, 72),     # caltrops: grappling hook
        (48, 24): (144, 72),    # quick hands: gold fever
        (72, 24): (216, 144),   # cloak of shadows (+ Shadow mastery)
        (96, 24): (0, 144),     # poisoned blades
        (120, 24): (192, 144),  # vanish
    },
    "gladiator": {
        (0, 0): (24, 168),      # net
        (24, 0): (48, 168),     # gladius
        (48, 0): (72, 168),     # pit fighters
        (72, 0): (96, 168),     # planned attack
        (96, 0): (120, 168),    # riposte (+ Champion mastery)
        (120, 0): (144, 168),   # arena mastery
        (144, 0): (144, 0),     # shield wall
        (0, 24): (144, 192),    # arena beast: the witch hunter's hound (+ Beastmaster mastery)
        (24, 24): (48, 24),     # pack leader
        (48, 24): (48, 144),    # bloodlust
        (72, 24): (72, 24),     # barbed net (+ Retiarius mastery)
        (96, 24): (120, 144),   # trident whirl
        (120, 24): (0, 168),    # trident mastery: trident
        (144, 24): (0, 168),    # trident thrust (attacks_gladiator.sval)
    },
    "witchhunter": {
        (0, 0): (72, 192),      # searing torch
        (24, 0): (24, 192),     # pyre
        (48, 0): (144, 192),    # hound
        (72, 0): (96, 192),     # ward of branding
        (96, 0): (120, 192),    # fanatic zeal (+ Inquisitor mastery)
        (120, 0): (48, 192),    # murder of crows
        (144, 0): (144, 96),    # judgement
        (0, 24): (96, 120),     # brand (+ Pyromancer mastery)
        (24, 24): (48, 96),     # immolation
        (48, 24): (144, 120),   # cinders
        (72, 24): (48, 24),     # pack (+ Hunter mastery)
        (96, 24): (0, 192),     # silver bolts: repeater crossbow
        (120, 24): (168, 24),   # tracker
    },
}

# the shadow under vanilla's showcase figures (row widths, top row 8 px above the feet);
# the class list's selection ring sits around it, so a bigger one would hide the ring
SHOWCASE_SHADOW = [4, 8, 10, 12, 14, 14, 16, 16, 16, 16, 14, 14, 12, 10, 8, 4]


def hoh1_dyes(archive: hwr.Archive) -> dict:
    """(category, id) -> [dark, mid, bright] RGB from HoH1 tweak/playermaterials.sval"""
    text = archive.read_file("tweak/playermaterials.sval").decode("utf-8", "replace")
    dyes = {}
    for cat in re.finditer(r'\n\t<array name="(\w+)">(.*?)\n\t</array>', text, re.S):
        for d in re.finditer(r"<dict>(.*?)</dict>", cat.group(2), re.S):
            m = re.search(r'name="id">([^<]+)<', d.group(1))
            shades = re.findall(r"<string>#([0-9a-fA-F]{6})</string>", d.group(1))
            if m and len(shades) >= 3:
                dyes[(cat.group(1), m.group(1))] = [tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))
                                                    for c in shades[:3]]
    return dyes


def render_multicolor(tex: bytes, palette: list):
    """A HoH1 multicolour .tif drawn the way the sprite_mcol shader does: texels with
    alpha >= 128 are (shade, channel) indices into palette[channel] = [dark, mid, bright]."""
    from PIL import Image
    w, h, _channels = struct.unpack("<III", tex[:12])
    src = Image.frombytes("RGBA", (w, h), tex[12:12 + w * h * 4])
    out = Image.new("RGBA", (w, h))
    sp, op = src.load(), out.load()

    def mix(a, b, t):
        return tuple(int(a[i] + (b[i] - a[i]) * t + 0.5) for i in range(3))

    for y in range(h):
        for x in range(w):
            r, g, b, a = sp[x, y]
            if a == 0:
                continue
            if a < 128:
                op[x, y] = (r, g, b, min(255, a * 2))
                continue
            dark, mid, bright = palette[min(g, len(palette) - 1)]
            t = r / 255
            op[x, y] = mix(mix(dark, mid, min(1.0, t * 2)), bright, max(0.0, min(1.0, (t - 0.5) * 2))) + (255,)
    return out


def png_bytes(im) -> bytes:
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return buf.getvalue()


def class_showcase(archive: hwr.Archive, hoh1_class: str, palette: list):
    """Class icon like vanilla players/class_showcase.png: the HoH1 figure, scaled up
    (SHOWCASE_*), on vanilla's shadow"""
    from PIL import Image
    unit = archive.read_file(f"players/{hoh1_class}.unit").decode("utf-8", "replace")
    m = re.search(r'<scene name="%s">.*?origin="(\d+) (\d+)".*?texture="\./([^"]+)".*?'
                  r"<frame>(\d+) (\d+) (\d+) (\d+)</frame>" % SHOWCASE_SCENE, unit, re.S)
    if m is None:
        raise SystemExit(f"players/{hoh1_class}.unit: no {SHOWCASE_SCENE} frame")
    ox, oy, fx, fy, fw, fh = (int(v) for v in (m.group(1), m.group(2), *m.groups()[3:]))
    sheet = render_multicolor(archive.read_file(f"players/{m.group(3)}"), palette)
    k, (feet_x, feet_y) = SHOWCASE_SCALE, SHOWCASE_FEET
    figure = sheet.crop((fx, fy, fx + fw, fy + fh)).resize((round(fw * k), round(fh * k)), Image.NEAREST)
    out = Image.new("RGBA", (SHOWCASE_TEXTURE, SHOWCASE_TEXTURE), (0, 0, 0, 0))
    for i, width in enumerate(SHOWCASE_SHADOW):
        for x in range(feet_x - width // 2, feet_x + width // 2):
            out.putpixel((x, feet_y - 8 + i), (0, 0, 0, 126))
    out.alpha_composite(figure, (feet_x - round(ox * k), feet_y - round(oy * k)))
    return out


def import_classes(archive: hwr.Archive, force: bool) -> None:
    from PIL import Image
    written: list[str] = []
    dyes = hoh1_dyes(archive)
    icons = archive.read_file("gui/icons_skills.png")
    if hwr.is_texture(icons):
        icons = hwr.texture_to_png(icons)
    hoh1_icons = Image.open(io.BytesIO(icons)).convert("RGBA")
    for ours, (hoh1_class, picks) in HOH1_CLASS_ART.items():
        missing = [p for p in picks if p not in dyes]
        if missing:
            raise SystemExit(f"{hoh1_class}: dyes {missing} not in tweak/playermaterials.sval")
        out_dir = CLASS_ART / "players/hwp" / ours
        showcase = class_showcase(archive, hoh1_class, [dyes[p] for p in picks])
        write(out_dir / "class_showcase.png", png_bytes(showcase), force, written)

        # same size and cells as the committed placeholder sheet it stands in for
        placeholder = Image.open(CLASSES_MODULE / "players/hwp" / ours / "icons.png")
        sheet = Image.new("RGBA", placeholder.size, (0, 0, 0, 0))
        for (x, y), (sx, sy) in HOH1_SKILL_ICONS[ours].items():
            sheet.paste(hoh1_icons.crop((sx, sy, sx + 24, sy + 24)), (x, y))
        write(out_dir / "icons.png", png_bytes(sheet), force, written)

    print(f"classes: HoH1 class and skill icons for {', '.join(HOH1_CLASS_ART)}")
    print("  (build.py --with-local packs them over the placeholders; unpacked dev links show the placeholders)")
    for w in written:
        print("  wrote", w)
    if not written:
        print("  nothing written (outputs exist; use --force to overwrite)")


IMPORTERS = {"pets": import_pets, "levels": import_levels, "campaign": import_campaign,
             "classes": import_classes}


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
