#!/usr/bin/env python3
"""
import_hoh1.py - pull Heroes of Hammerwatch (1) content from the player's own
install and convert it for HammerwatchPlus. Nothing it writes is committed
(see the .gitignore files next to the outputs); every player runs it locally.

    import_hoh1.py pets              # HoH1 pet skins -> modules/pets (HoH2 Pet Shop entries)
    import_hoh1.py levels            # HoH1 campaign levels -> hoh1_import/campaign (decoded + gap report)
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
what already exists. Nothing in HoH2 loads these yet; see modules/campaign/README.md.
"""
from __future__ import annotations

import argparse
import io
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
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


def level_refs(doc: dict) -> dict:
    """What one level / prefab references: tilesets, placed units, scripts, other files."""
    refs = {"tilesets": set(), "units": set(), "scripts": set(), "resources": set(),
            "layers": 0, "placed": 0, "script_count": 0}
    for layer in doc.get("tiles") or []:
        for ds in layer.get("datasets") or []:
            refs["tilesets"].add(ds.get("tileset", ""))
            refs["layers"] += 1
    for unit, placements in (doc.get("units") or {}).items():
        if not unit.startswith(":"):          # :Physics_* are editor shapes
            refs["units"].add(unit)
        refs["placed"] += len(placements) // 2 if isinstance(placements, list) else 0
    for script in doc.get("scripts") or []:
        if isinstance(script, list) and script and isinstance(script[0], str):
            refs["scripts"].add(script[0])
            refs["script_count"] += 1
            walk_strings(script[6:], refs["resources"])
    env = (doc.get("lighting") or {}).get("environment")
    if env:
        refs["resources"].add(env)
    walk_strings(doc.get("prefabs"), refs["resources"])
    refs["resources"] -= refs["units"] | refs["tilesets"]
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
    if isinstance(v, hwr.Vec):
        return list(v)
    if isinstance(v, (bytes, bytearray)):
        return {"blob_bytes": len(v)}
    raise TypeError(type(v).__name__)


def import_levels(archive: hwr.Archive, force: bool) -> None:
    if not (paths.BASE_HOH2 / "levels").is_dir():
        sys.exit(f"{paths.BASE_HOH2} has no extracted HoH2 base; run tools/extract_base.py first")
    written: list[str] = []
    scripts2 = hoh2_world_scripts()
    # sanity check of the script-name method on a HoH2 level
    probe_path = paths.BASE_HOH2 / "levels" / "boss_arista.lvl"
    probe = level_refs(decode_level(probe_path.read_bytes(), str(probe_path)))
    report = {"hoh2_probe": {"level": "levels/boss_arista.lvl", "scripts": len(probe["scripts"]),
                             "unresolved": sorted(probe["scripts"] - scripts2)}, "acts": []}
    all_tilesets: set[str] = set()
    by_folder: dict[str, list[str]] = {}
    for e in archive.entries:
        parts = e.path.split("/")
        if parts[0] == "prefabs" and len(parts) >= 3 and e.path.endswith(".pfb"):
            by_folder.setdefault(parts[1], []).append(e.path)
    for act_id, act_name, folder, levels in ACTS:
        files = list(levels) + sorted(by_folder.get(folder, []))
        total = {"tilesets": set(), "units": set(), "scripts": set(), "resources": set(),
                 "layers": 0, "placed": 0, "script_count": 0}
        for path in files:
            doc = decode_level(archive.read_file(path), path)
            refs = level_refs(doc)
            for k in ("tilesets", "units", "scripts", "resources"):
                total[k] |= refs[k]
            for k in ("layers", "placed", "script_count"):
                total[k] += refs[k]
            if path.endswith(".lvl"):
                write(IMPORT_DIR / "levels" / (Path(path).stem + ".json"),
                      json.dumps(doc, default=json_default, indent=1), force, written)
        total["tilesets"].discard("")
        all_tilesets |= total["tilesets"]
        act = {
            "id": act_id, "name": act_name, "files": len(files), "levels": levels,
            "prefabs": len(files) - len(levels),
            "tile_layers": total["layers"], "placed_units": total["placed"], "script_nodes": total["script_count"],
            "tilesets": sorted(total["tilesets"]),
            "tilesets_in_hoh2": sorted(t for t in total["tilesets"] if hoh2_has(t)),
            "units": sorted(total["units"]),
            "units_in_hoh2": sorted(u for u in total["units"] if hoh2_has(u)),
            "scripts": sorted(total["scripts"]),
            "scripts_not_in_hoh2": sorted(total["scripts"] - scripts2),
            "resources": sorted(total["resources"]),
            "resources_in_hoh2": sorted(r for r in total["resources"] if hoh2_has(r)),
        }
        report["acts"].append(act)
        print("%-12s %4d files  tilesets %3d (%d in HoH2)  units %4d (%d in HoH2)  scripts %3d (%d unknown)" % (
            act_name, len(files), len(act["tilesets"]), len(act["tilesets_in_hoh2"]),
            len(act["units"]), len(act["units_in_hoh2"]), len(act["scripts"]), len(act["scripts_not_in_hoh2"])))
    # the referenced tilesets, textures converted to PNG
    for ts in sorted(all_tilesets):
        if archive.find(ts) is None:
            continue
        text = archive.read_file(ts).decode("utf-8", errors="replace")
        write(IMPORT_DIR / ts, text, force, written)
        m = re.search(r'texture="([^"]+)"', text)
        if m and archive.find(m.group(1)) is not None:
            write(IMPORT_DIR / m.group(1), to_png_pot(archive.read_file(m.group(1))), force, written)
    write(IMPORT_DIR / "report.json", json.dumps(report, indent=1), True, written)
    write(IMPORT_DIR / "report.md", levels_report_md(report), True, written)
    print("wrote %d files under %s (report.md has the gaps)" % (len(written), IMPORT_DIR.relative_to(paths.REPO)))


def levels_report_md(report: dict) -> str:
    probe = report["hoh2_probe"]
    out = ["# HoH1 campaign import report", "",
           "Generated by `tools/import_hoh1.py levels`. Nothing here is committed.", "",
           "Method check: HoH2 `%s` uses %d script types, unresolved against `scripts/WorldScript`: %s." % (
               probe["level"], probe["scripts"], ", ".join(probe["unresolved"]) or "none"), "",
           "| Act | files | tile layers | placed units | tilesets (in HoH2) | unit types (in HoH2) | script types (unknown to HoH2) |",
           "|---|---|---|---|---|---|---|"]
    for a in report["acts"]:
        out.append("| %s | %d | %d | %d | %d (%d) | %d (%d) | %d (%d) |" % (
            a["name"], a["files"], a["tile_layers"], a["placed_units"], len(a["tilesets"]), len(a["tilesets_in_hoh2"]),
            len(a["units"]), len(a["units_in_hoh2"]), len(a["scripts"]), len(a["scripts_not_in_hoh2"])))
    out.append("")
    for a in report["acts"]:
        out += ["## " + a["name"], "", "Levels: %s; prefabs: %d." % (", ".join(a["levels"]), a["prefabs"]), ""]
        out.append("Tilesets: " + ", ".join("`%s`%s" % (t, " (HoH2 has it)" if t in a["tilesets_in_hoh2"] else "") for t in a["tilesets"]))
        out.append("")
        out.append("Script types not in HoH2 (%d of %d): %s" % (len(a["scripts_not_in_hoh2"]), len(a["scripts"]), ", ".join(a["scripts_not_in_hoh2"]) or "none"))
        out.append("")
        missing_units = [u for u in a["units"] if u not in a["units_in_hoh2"]]
        groups: dict[str, int] = {}
        for u in missing_units:
            g = u.rsplit("/", 1)[0]
            groups[g] = groups.get(g, 0) + 1
        out += ["Unit types missing in HoH2 (%d of %d), by folder:" % (len(missing_units), len(a["units"])), ""]
        out += ["- `%s/` %d" % (g, n) for g, n in sorted(groups.items(), key=lambda kv: -kv[1])]
        missing_res = [r for r in a["resources"] if r not in a["resources_in_hoh2"]]
        out += ["", "Other referenced files missing in HoH2 (%d of %d):" % (len(missing_res), len(a["resources"])), ""]
        out += ["- `%s`" % r for r in missing_res[:60]]
        if len(missing_res) > 60:
            out.append("- ... %d more (report.json)" % (len(missing_res) - 60))
        out.append("")
    return "\n".join(out) + "\n"


IMPORTERS = {"pets": import_pets, "levels": import_levels}


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
