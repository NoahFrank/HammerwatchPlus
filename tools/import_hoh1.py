#!/usr/bin/env python3
"""
import_hoh1.py - pull Heroes of Hammerwatch (1) content from the player's own
install and convert it for HammerwatchPlus. Nothing it writes is committed
(see the .gitignore files next to the outputs); every player runs it locally.

    import_hoh1.py pets              # HoH1 pet skins -> modules/pets (HoH2 Pet Shop entries)
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
"""
from __future__ import annotations

import argparse
import io
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


IMPORTERS = {"pets": import_pets}


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
