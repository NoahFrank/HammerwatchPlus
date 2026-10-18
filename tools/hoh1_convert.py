"""
hoh1_convert.py - convert Heroes of Hammerwatch (1) levels for HoH2 (used by
`import_hoh1.py campaign`).

Both games run the same engine family: levels and prefabs are the same binary
SValue container, units/effects/tilesets the same XML. So a level converts by
copying it together with everything it references (its *closure*: units,
includes, textures, effects, prefabs, tilesets, loot tables...) into the mod
under the prefix `hoh1/`, and rewriting every absolute path in the copied files
to the prefixed path. Relative paths (`./base.png`) keep working because the
tree keeps its layout. Nothing HoH1 ships is ever committed: the output goes to
gitignored `mods/campaign/hoh1/`.

What needs more than copying is listed in `CLASS_MAP` (HoH1 class -> HoH2 class
or our port in mods/campaign/scripts/HWP/Campaign/HoH1/) and handled by
`rewrite_text`.
"""
from __future__ import annotations

import posixpath
import re
from dataclasses import dataclass, field
from pathlib import Path

import hwr_archive as hwr

PREFIX = "hoh1/"
LEVEL_HEADER = 8

# file types that are text resources and get their paths rewritten
TEXT_EXT = (".unit", ".inc", ".sval", ".effect", ".tileset", ".env", ".gui", ".fnt", ".mats")
SVALUE_EXT = (".lvl", ".pfb")
RES_EXT = TEXT_EXT + SVALUE_EXT + (".png", ".tif", ".tga")
# never copied: HoH2 has its own (different) shaders and these are engine-bound
NEVER_COPY_EXT = (".fs", ".vs", ".bank", ".as")
# kept on the HoH2 file of the same name when there is one (fonts load their .ttf)
USE_HOH2_EXT = (".fnt",)

VALUE_RE = re.compile(r'"([^"\n]*)"|>([^<>\n]+)<')
INCLUDE_RE = re.compile(r'%include\s+"([^"]+)"')


def split_ref(value: str) -> tuple[str, str]:
    """'actors/loot.sval:tick_1' -> ('actors/loot.sval', ':tick_1'); event:/... is not a file."""
    v = value.strip()
    if v.startswith("event:"):
        return "", ""
    if ":" in v:
        path, _, key = v.partition(":")
        return path, ":" + key
    return v, ""


def looks_like_path(p: str) -> bool:
    return bool(p) and "/" in p and p.lower().endswith(RES_EXT) and " " not in p.strip()


def resolve(owner: str, ref: str) -> str:
    if ref.startswith("./") or ref.startswith("../"):
        return posixpath.normpath(posixpath.join(posixpath.dirname(owner), ref))
    return ref


NEVER_ON_START = {"LevelExit", "LevelExitNext", "LevelExitNextAct"}
# HoH1 actor behaviors that HoH2 builds on StateActorBehavior, which needs at
# least one entry in "states". A single state takes the unit's own movement
# and skills, so the actor behaves as in HoH1 and HoH2's world scripts for the
# class (SetDamageTransfer) still accept it.
NEEDS_STATE = {"TransferDamageActor"}
# HoH1 units that only the host spawns in our ports, so clients must get them
# from the network (a netsync none danger area would also hit remote players'
# husks on the host): HoH1 path -> HoH2 netsync mode
NETSYNC = {"actors/bosses/vampire/fire_area.unit": "position"}
ONE_STATE = '\n\t\t<array name="states"><dict><string name="name">hoh1</string></dict></array>'


@dataclass
class Closure:
    archive: hwr.Archive
    hoh2_has: object = None                                # callable(path) -> bool, for USE_HOH2_EXT
    files: set[str] = field(default_factory=set)          # HoH1 paths to copy
    broken: dict[str, set[str]] = field(default_factory=dict)  # missing path -> referenced by
    _scanned: set[tuple[str, str]] = field(default_factory=set)

    def has(self, path: str) -> bool:
        return self.archive.find(path) is not None

    def add_roots(self, roots) -> None:
        for r in roots:
            self._visit(r, r, "root")

    def _note_broken(self, path: str, by: str) -> None:
        self.broken.setdefault(path, set()).add(by)

    def _visit(self, path: str, owner: str, by: str) -> None:
        if path.lower().endswith(NEVER_COPY_EXT):
            return
        if path.lower().endswith(USE_HOH2_EXT) and self.hoh2_has is not None and self.hoh2_has(path):
            return
        if not self.has(path):
            self._note_broken(path, by)
            return
        key = (path, posixpath.dirname(owner))
        if key in self._scanned:
            return
        self._scanned.add(key)
        self.files.add(path)
        data = self.archive.read_file(path)
        if path.endswith(SVALUE_EXT):
            doc = decode_level(data, path)
            for s in iter_strings(doc):
                p, _ = split_ref(s)
                if looks_like_path(p):
                    self._visit(resolve(path, p), resolve(path, p), path)
        elif path.endswith(TEXT_EXT):
            text = data.decode("utf-8", errors="replace")
            # an included file resolves its relative paths against the file that includes it
            inc_owner = owner if path.endswith(".inc") else path
            for m in INCLUDE_RE.finditer(text):
                self._visit(resolve(inc_owner, m.group(1)), inc_owner, path)
            text = INCLUDE_RE.sub("", text)    # the include lines are not values
            for m in VALUE_RE.finditer(text):
                p, _ = split_ref(m.group(1) if m.group(1) is not None else m.group(2))
                if looks_like_path(p):
                    target = resolve(inc_owner, p)
                    self._visit(target, target, path)


def decode_level(data: bytes, path: str):
    skip = LEVEL_HEADER if path.endswith(".lvl") else 0
    doc, end = hwr.decode_svalue(data, skip)
    if end != len(data):
        raise ValueError(f"{path}: {len(data) - end} trailing bytes")
    return doc


def iter_strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield k
            yield from iter_strings(x)
    elif isinstance(v, (list, tuple)) and not isinstance(v, hwr.Vec):
        for x in v:
            yield from iter_strings(x)


@dataclass
class Rewriter:
    copied: set[str]                       # HoH1 paths that exist under PREFIX
    hoh2_materials: dict[str, set[str]]    # HoH2 .mats path -> material names
    class_map: dict[str, str]
    material_map: dict[str, str]
    stats: dict[str, int] = field(default_factory=dict)

    def bump(self, k: str) -> None:
        self.stats[k] = self.stats.get(k, 0) + 1

    def ref(self, value: str, owner: str) -> str:
        """Rewrite one reference value (path or path:key) found in `owner`."""
        path, key = split_ref(value)
        if not looks_like_path(path) or path.startswith(("./", "../")):
            return value
        if path.endswith(".mats") and key:
            name = key[1:]
            name = self.material_map.get(f"{path}:{name}", name)
            if name in self.hoh2_materials.get(path, ()):
                self.bump("material->hoh2")
                lead = value[: len(value) - len(value.lstrip())]
                return f"{lead}{path}:{name}"
        if path in self.copied:
            self.bump("path->hoh1")
            return value.replace(path, PREFIX + path, 1)
        return value

    def text(self, text: str, owner: str) -> str:
        if owner in NETSYNC:
            text, n = re.subn(r'<unit netsync="\w+"', f'<unit netsync="{NETSYNC[owner]}"', text, count=1)
            if not n:
                text = text.replace("<unit", f'<unit netsync="{NETSYNC[owner]}"', 1)
            self.bump("netsync:" + owner.rsplit("/", 1)[-1])
        def inc(m):
            p = m.group(1)
            if p in self.copied:
                self.bump("include->hoh1")
                return f'%include "{PREFIX}{p}"'
            return m.group(0)

        text = INCLUDE_RE.sub(inc, text)

        def val(m):
            if m.group(1) is not None:
                return '"' + self.ref(m.group(1), owner) + '"'
            return ">" + self.ref(m.group(2), owner) + "<"

        text = VALUE_RE.sub(val, text)

        def cls(m):
            old = m.group(2)
            new = self.class_map.get(old)
            if new:
                self.bump("class:" + old)
                return m.group(1) + new + m.group(3)
            return m.group(0)

        def state(m):
            if m.group(2) not in NEEDS_STATE or 'name="states"' in text:
                return m.group(0)
            self.bump("states:" + m.group(2))
            return m.group(0) + ONE_STATE

        text = re.sub(r'(<behavior class=")(\w+)(">)', state, text)
        text = re.sub(r'(<behavior class=")(\w+)(")', cls, text)
        text = re.sub(r'(<string name="class">)(\w+)(</string>)', cls, text)
        return text

    def svalue(self, v, owner: str):
        if isinstance(v, str):
            return self.ref(v, owner)
        if isinstance(v, dict):
            out = {self.ref(k, owner): self.svalue(x, owner) for k, x in v.items()}
            cls = out.get("Class")       # the level's game-mode {Class: ...}
            if isinstance(cls, str) and cls in self.class_map:
                self.bump("gamemode:" + cls)
                out["Class"] = self.class_map[cls]
            return out
        if isinstance(v, hwr.Vec) or not isinstance(v, (list, tuple)):
            return v
        out = [self.svalue(x, owner) for x in v]
        # level script rows: [type, id, pos, ...]; map the WorldScript class too
        if out and isinstance(out[0], str) and len(out) >= 6 and isinstance(out[1], int):
            # rows are [type, id, pos, ExecuteOnStart, TriggerTimes, Enabled, ...]. HoH1
            # flags some level exits to run on start (its engine never did; HoH2 does
            # and the floor would end as it begins), so exits only run when triggered
            if out[0] in NEVER_ON_START and out[3] is True:
                self.bump("no-start:" + out[0])
                out[3] = False
            if out[0] in self.class_map:
                self.bump("worldscript:" + out[0])
                out[0] = self.class_map[out[0]]
        return out


def hoh2_material_names(base: Path) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for f in base.rglob("*.mats"):
        out[f.relative_to(base).as_posix()] = set(re.findall(r'<material\s+name="([^"]+)"', f.read_text(encoding="utf-8", errors="replace")))
    return out


def convert_file(archive: hwr.Archive, path: str, rw: Rewriter, to_png) -> bytes:
    data = archive.read_file(path)
    if path.endswith(SVALUE_EXT):
        # Loose mod files are read as XML (packed archives hold the binary form,
        # which tools/build.py compiles back, reusing the level's header bytes).
        doc = rw.svalue(decode_level(data, path), path)
        head = f"<!-- {hwr.LEVEL_HEADER_TAG} {data[:LEVEL_HEADER].hex()} -->\n" if path.endswith(".lvl") else ""
        return (head + hwr.svalue_to_xml(doc) + "\n").encode("utf-8")
    if path.endswith(TEXT_EXT):
        return rw.text(data.decode("utf-8", errors="replace"), path).encode("utf-8")
    if path.endswith(".png"):
        return to_png(data)
    return data
