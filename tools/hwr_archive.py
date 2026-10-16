#!/usr/bin/env python3
"""
hwr_archive.py - list / extract / pack Crackshell "HWR" resource archives.

Covers Heroes of Hammerwatch II (`HW2R`, version 4) and Heroes of Hammerwatch
(`HWRR`, version 3). Both `res/assets.bin` and mod `.bin` packages use this
format, so the same tool extracts the base game for reference and builds our
mod packages.

Layout (all integers little-endian):

    magic[4]  u8 version  u32 hash  u32 metaLen  meta[metaLen]
    (HW2R only) u32 reserved=0
    u32 fileCount
    fileCount x entry

    entry: u32 pathLen  path[pathLen]  u8 type  u32 rawSize  u32 compSize  data
           compSize == 0  -> data is rawSize bytes, stored
           compSize  > 0  -> data is compSize bytes of a raw LZ4 block
           type == 0xFF   -> external sound bank: 4 bytes (0xFFFFFFFF), no data

    meta: SValue dict  ->  0x02 u32 count { key\\0 0x06 value\\0 }
          (author / name / description for mods, empty for assets.bin)

Entry type byte: 1 = text/data, 3 = binary (png/tif/lvl/pfb), 7 = some pfb.

Textures: a `.png` entry is NOT a PNG file. The packager converts images to
the engine's own format, which the unpacked-mod loader does not accept:

    u32 width  u32 height  i32 -1  u32 channels(3|4)  LZ4 block of width*height*channels bytes (RGBA)

`pack` converts any real PNG it finds (PNG signature) to that format, so a mod
folder can keep editable PNGs; `extract --png` converts textures back to PNG.
The header hash is not yet understood (not a crc/adler/fnv/xxhash of anything
obvious); `pack` writes a crc32 of the body unless `--hash` is given. The game
has loaded such packages fine so far; see docs/archive-format.md.

Usage:
    hwr_archive.py list    ARCHIVE [-f REGEX]
    hwr_archive.py extract ARCHIVE OUTDIR [-f REGEX]
    hwr_archive.py pack    SRCDIR OUT.bin [--name N --author A --description D]
                           [--game hoh2|hoh1] [--store] [--hash 0xHEX]
    hwr_archive.py info    ARCHIVE
    hwr_archive.py tex2png IN OUT.png      # engine texture -> PNG
    hwr_archive.py png2tex IN.png OUT      # PNG -> engine texture
"""
from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
import zlib
from dataclasses import dataclass, field
from pathlib import Path

try:
    import lz4.block as _lz4
except ImportError:  # pragma: no cover - fallback path
    _lz4 = None

MAGIC_HOH2 = b"HW2R"
MAGIC_HOH1 = b"HWRR"
GAMES = {
    "hoh2": (MAGIC_HOH2, 4, True),   # magic, version, has reserved u32
    "hoh1": (MAGIC_HOH1, 3, False),
}
MAGIC_TO_GAME = {v[0]: k for k, v in GAMES.items()}

TYPE_TEXT = 1
TYPE_BINARY = 3
TYPE_BANK = 0xFF
BINARY_EXTS = {".png", ".tif", ".lvl", ".pfb"}
MANIFEST = "_hwr_manifest.json"

SV_NULL = 0x00
SV_ARRAY = 0x01
SV_DICT = 0x02
SV_BOOL = 0x03
SV_FLOAT = 0x04
SV_INT = 0x05
SV_STRING = 0x06
SV_BLOB = 0x07     # u32 length + bytes (tile layer data)
SV_VEC2 = 0x08     # 2 x f32
SV_VEC3 = 0x09     # 3 x f32
SV_VEC4 = 0x0A     # 4 x f32 (colors)
SV_INT64 = 0x0B    # i64 (save stats)
SV_DOUBLE = 0x10   # f64 (saves)

# Payload-less literals the engine writes instead of the full form (levels,
# prefabs, saves never contain an explicit int 0 / float 0 / "" / bool).
SV_COMPACT = {0x65: [], 0x66: {}, 0x67: False, 0x68: True, 0x69: 0.0, 0x6E: 0, 0x73: 0, 0x78: ""}  # 0x73 = i64 0
# Short vectors: tag -> (dimension, floats stored, splat). Missing trailing
# components are 0; a splat repeats the one stored float.
SV_COMPACT_VEC = {
    0x7A: (2, 0, False), 0x7B: (2, 1, False),
    0x7C: (3, 0, False), 0x7D: (3, 1, False), 0x7E: (3, 2, False),
    0x7F: (4, 0, False), 0x80: (4, 1, False), 0x81: (4, 2, False), 0x82: (4, 3, False),
    0x8C: (2, 1, True), 0x8D: (3, 1, True), 0x8E: (4, 1, True),
}
SV_VEC_TAG = {2: SV_VEC2, 3: SV_VEC3, 4: SV_VEC4}


class Vec(tuple):
    """vec2 / vec3 / vec4 SValue (floats). Plain tuples and lists are arrays."""
    __slots__ = ()


# --------------------------------------------------------------------------- LZ4

def lz4_decompress(src: bytes, raw_size: int) -> bytes:
    if _lz4 is not None:
        return _lz4.decompress(src, uncompressed_size=raw_size)
    # Pure-python raw LZ4 block decoder (slow, but keeps `list`/`extract` working
    # without the lz4 package).
    out = bytearray()
    i, n = 0, len(src)
    while i < n:
        tok = src[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= n:
            break
        off = src[i] | (src[i + 1] << 8)
        i += 2
        mlen = tok & 15
        if mlen == 15:
            while True:
                b = src[i]
                i += 1
                mlen += b
                if b != 255:
                    break
        mlen += 4
        start = len(out) - off
        for k in range(mlen):
            out.append(out[start + k])
    if len(out) != raw_size:
        raise ValueError(f"LZ4 size mismatch: got {len(out)}, expected {raw_size}")
    return bytes(out)


def lz4_compress(data: bytes) -> bytes | None:
    """Return a raw LZ4 block, or None when lz4 is unavailable (caller stores raw)."""
    if _lz4 is None or not data:
        return None
    return _lz4.compress(data, mode="high_compression", compression=12, store_size=False)


# ------------------------------------------------------------------------ SValue

def decode_svalue(buf: bytes, pos: int = 0):
    """Decode a binary SValue (archive meta, .lvl after its 8-byte header, .pfb).

    dict/list/str/bool/int/float/None map to Python; blobs are bytes, vectors
    are Vec. Returns (value, position after it)."""
    if pos >= len(buf):
        raise ValueError(f"SValue truncated: no value at offset {pos}")
    tag = buf[pos]
    pos += 1
    if tag == SV_NULL:
        return None, pos
    if tag == SV_DICT:
        (count,) = struct.unpack_from("<I", buf, pos)
        pos += 4
        out = {}
        for _ in range(count):
            end = buf.index(b"\0", pos)
            key = buf[pos:end].decode("utf-8")
            pos = end + 1
            out[key], pos = decode_svalue(buf, pos)
        return out, pos
    if tag == SV_STRING:
        end = buf.index(b"\0", pos)
        return buf[pos:end].decode("utf-8"), end + 1
    if tag == SV_ARRAY:
        (count,) = struct.unpack_from("<I", buf, pos)
        pos += 4
        items = []
        for _ in range(count):
            item, pos = decode_svalue(buf, pos)
            items.append(item)
        return items, pos
    if tag == SV_BOOL:
        return bool(buf[pos]), pos + 1
    if tag == SV_FLOAT:
        return struct.unpack_from("<f", buf, pos)[0], pos + 4
    if tag == SV_INT:
        return struct.unpack_from("<i", buf, pos)[0], pos + 4
    if tag == SV_INT64:
        return struct.unpack_from("<q", buf, pos)[0], pos + 8
    if tag == SV_DOUBLE:
        return struct.unpack_from("<d", buf, pos)[0], pos + 8
    if tag == SV_BLOB:
        (n,) = struct.unpack_from("<I", buf, pos)
        pos += 4
        if pos + n > len(buf):
            raise ValueError(f"SValue truncated: blob of {n} bytes at offset {pos - 5}")
        return bytes(buf[pos:pos + n]), pos + n
    if tag in (SV_VEC2, SV_VEC3, SV_VEC4):
        n = tag - SV_VEC2 + 2
        return Vec(struct.unpack_from(f"<{n}f", buf, pos)), pos + 4 * n
    if tag in SV_COMPACT:
        v = SV_COMPACT[tag]
        return (v.copy() if isinstance(v, (list, dict)) else v), pos
    if tag in SV_COMPACT_VEC:
        dim, stored, splat = SV_COMPACT_VEC[tag]
        vals = list(struct.unpack_from(f"<{stored}f", buf, pos)) if stored else []
        if splat:
            vals = vals * dim
        return Vec(vals + [0.0] * (dim - len(vals))), pos + 4 * stored
    raise ValueError(f"unsupported SValue tag 0x{tag:02x} at offset {pos - 1}")


def encode_svalue(value) -> bytes:
    if value is None:
        return bytes([SV_NULL])
    if isinstance(value, dict):
        out = bytearray([SV_DICT]) + struct.pack("<I", len(value))
        for k, v in value.items():
            out += k.encode("utf-8") + b"\0" + encode_svalue(v)
        return bytes(out)
    if isinstance(value, str):
        return bytes([SV_STRING]) + value.encode("utf-8") + b"\0"
    if isinstance(value, bool):
        return bytes([SV_BOOL, 1 if value else 0])
    if isinstance(value, int):
        if -2**31 <= value < 2**31:
            return bytes([SV_INT]) + struct.pack("<i", value)
        return bytes([SV_INT64]) + struct.pack("<q", value)
    if isinstance(value, float):
        return bytes([SV_FLOAT]) + struct.pack("<f", value)
    if isinstance(value, (bytes, bytearray)):
        return bytes([SV_BLOB]) + struct.pack("<I", len(value)) + bytes(value)
    if isinstance(value, Vec):
        if len(value) not in SV_VEC_TAG:
            raise TypeError(f"Vec must have 2-4 components, got {len(value)}")
        return bytes([SV_VEC_TAG[len(value)]]) + struct.pack(f"<{len(value)}f", *value)
    if isinstance(value, (list, tuple)):
        out = bytearray([SV_ARRAY]) + struct.pack("<I", len(value))
        for v in value:
            out += encode_svalue(v)
        return bytes(out)
    raise TypeError(f"cannot encode {type(value).__name__} as SValue")


# ----------------------------------------------------------------------- Archive

@dataclass
class Entry:
    path: str
    type: int
    raw_size: int
    comp_size: int
    blob: bytes = b""          # on-disk bytes (compressed or stored)

    @property
    def is_bank(self) -> bool:
        return self.type == TYPE_BANK

    def data(self) -> bytes:
        if self.is_bank:
            return b""
        if self.comp_size == 0:
            return self.blob
        return lz4_decompress(self.blob, self.raw_size)


@dataclass
class Archive:
    game: str
    version: int
    hash: int
    meta: dict
    entries: list[Entry] = field(default_factory=list)
    _index: dict | None = field(default=None, init=False, repr=False, compare=False)
    _index_len: int = field(default=0, init=False, repr=False, compare=False)

    @classmethod
    def read(cls, path: str | os.PathLike) -> "Archive":
        data = Path(path).read_bytes()
        magic = data[:4]
        if magic not in MAGIC_TO_GAME:
            raise ValueError(f"{path}: not an HWR archive (magic {magic!r})")
        game = MAGIC_TO_GAME[magic]
        _, _, has_reserved = GAMES[game]
        version = data[4]
        (hsh, meta_len) = struct.unpack_from("<II", data, 5)
        pos = 13
        meta, _ = decode_svalue(data[pos:pos + meta_len]) if meta_len else ({}, 0)
        pos += meta_len
        if has_reserved:
            pos += 4
        (count,) = struct.unpack_from("<I", data, pos)
        pos += 4
        entries = []
        for _ in range(count):
            (plen,) = struct.unpack_from("<I", data, pos)
            pos += 4
            epath = data[pos:pos + plen].decode("utf-8")
            pos += plen
            etype = data[pos]
            pos += 1
            if etype == TYPE_BANK:
                entries.append(Entry(epath, etype, 0, 0, data[pos:pos + 4]))
                pos += 4
                continue
            raw, comp = struct.unpack_from("<II", data, pos)
            pos += 8
            size = comp or raw
            entries.append(Entry(epath, etype, raw, comp, data[pos:pos + size]))
            pos += size
        if pos != len(data):
            raise ValueError(f"{path}: {len(data) - pos} trailing bytes after last entry")
        return cls(game, version, hsh, meta, entries)

    def find(self, path: str) -> Entry | None:
        # path -> first entry, rebuilt when the entry list changes size
        if self._index is None or self._index_len != len(self.entries):
            self._index = {}
            for e in self.entries:
                self._index.setdefault(e.path, e)
            self._index_len = len(self.entries)
        return self._index.get(path)

    def read_file(self, path: str) -> bytes:
        e = self.find(path)
        if e is None:
            raise KeyError(path)
        return e.data()

    def write(self, out_path: str | os.PathLike, hash_override: int | None = None) -> None:
        magic, version, has_reserved = GAMES[self.game]
        body = bytearray()
        for e in self.entries:
            p = e.path.encode("utf-8")
            body += struct.pack("<I", len(p)) + p + bytes([e.type])
            if e.is_bank:
                body += b"\xff\xff\xff\xff"
            else:
                body += struct.pack("<II", e.raw_size, e.comp_size) + e.blob
        meta = encode_svalue(self.meta) if self.meta else b""
        hsh = hash_override if hash_override is not None else zlib.crc32(bytes(body))
        head = magic + bytes([version]) + struct.pack("<II", hsh, len(meta)) + meta
        if has_reserved:
            head += struct.pack("<I", 0)
        head += struct.pack("<I", len(self.entries))
        Path(out_path).write_bytes(bytes(head) + bytes(body))


def type_for(path: str) -> int:
    return TYPE_BINARY if os.path.splitext(path)[1].lower() in BINARY_EXTS else TYPE_TEXT


# ---------------------------------------------------------------------- textures

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
TEX_HEADER = struct.Struct("<IIiI")


def is_png(data: bytes) -> bool:
    return data[:8] == PNG_SIGNATURE


def is_texture(data: bytes) -> bool:
    """Engine texture header: plausible size, -1, 3 or 4 channels."""
    if len(data) < TEX_HEADER.size:
        return False
    w, h, flag, ch = TEX_HEADER.unpack_from(data, 0)
    return flag == -1 and ch in (3, 4) and 0 < w <= 16384 and 0 < h <= 16384


def _pil():
    try:
        from PIL import Image
    except ImportError:
        sys.exit("texture conversion needs Pillow: pip install pillow")
    return Image


def texture_to_png(data: bytes) -> bytes:
    import io
    Image = _pil()
    w, h, _, ch = TEX_HEADER.unpack_from(data, 0)
    raw = lz4_decompress(data[TEX_HEADER.size:], w * h * ch)
    im = Image.frombytes("RGBA" if ch == 4 else "RGB", (w, h), raw)
    buf = io.BytesIO()
    im.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def png_to_texture(data: bytes) -> bytes:
    import io
    Image = _pil()
    im = Image.open(io.BytesIO(data))
    im = im.convert("RGBA")  # the loader only takes RGB/RGBA; palette and grey images are promoted
    raw = im.tobytes()
    comp = lz4_compress(raw)
    if comp is None:
        sys.exit("texture conversion needs the lz4 package: pip install lz4")
    return TEX_HEADER.pack(im.width, im.height, -1, 4) + comp


def make_entry(path: str, data: bytes, etype: int | None = None, store: bool = False) -> Entry:
    etype = type_for(path) if etype is None else etype
    if path.lower().endswith(".png") and is_png(data):
        data = png_to_texture(data)
    comp = None if store else lz4_compress(data)
    if comp is None or len(comp) >= len(data):
        return Entry(path, etype, len(data), 0, data)
    return Entry(path, etype, len(data), len(comp), comp)


# --------------------------------------------------------------------- commands

def _compile(pattern: str | None):
    return re.compile(pattern, re.I) if pattern else None


def cmd_info(args):
    a = Archive.read(args.archive)
    print(f"game: {a.game}  version: {a.version}  hash: 0x{a.hash:08x}")
    print(f"meta: {json.dumps(a.meta, ensure_ascii=False)}")
    raw = sum(e.raw_size for e in a.entries)
    disk = sum(len(e.blob) for e in a.entries)
    print(f"files: {len(a.entries)}  raw: {raw:,} B  on disk: {disk:,} B")


def cmd_list(args):
    a = Archive.read(args.archive)
    rx = _compile(args.filter)
    for e in a.entries:
        if rx and not rx.search(e.path):
            continue
        print(f"{e.type:3d} {e.raw_size:10d} {e.comp_size:10d}  {e.path}")


def cmd_extract(args):
    a = Archive.read(args.archive)
    rx = _compile(args.filter)
    out = Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)
    files = {}
    banks = []
    n = 0
    for e in a.entries:
        if rx and not rx.search(e.path):
            continue
        if e.is_bank:
            banks.append(e.path)
            continue
        dest = out / e.path
        dest.parent.mkdir(parents=True, exist_ok=True)
        data = e.data()
        if getattr(args, "png", False) and e.path.lower().endswith(".png") and is_texture(data):
            data = texture_to_png(data)
        dest.write_bytes(data)
        files[e.path] = {"type": e.type}
        n += 1
    if not args.no_manifest:
        manifest = {
            "game": a.game,
            "version": a.version,
            "hash": f"0x{a.hash:08x}",
            "meta": a.meta,
            "banks": banks,
            "files": files,
        }
        (out / MANIFEST).write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"extracted {n} files to {out}")


def packable_files(src: Path, exclude: set[str], skip=None):
    """Yield (relative posix path, file) for everything `collect_dir` would pack: not in
    `exclude`, not the manifest, not under a dot-directory, and not rejected by `skip(rel)`."""
    for fp in sorted(src.rglob("*")):
        if not fp.is_file():
            continue
        rel = fp.relative_to(src).as_posix()
        if rel in exclude or rel == MANIFEST or any(part.startswith(".") for part in fp.relative_to(src).parts):
            continue
        if skip is not None and skip(rel):
            continue
        yield rel, fp


def collect_dir(src: Path, manifest: dict | None, store: bool, exclude: set[str], skip=None) -> list[Entry]:
    types = (manifest or {}).get("files", {})
    entries = []
    for rel, fp in packable_files(src, exclude, skip):
        etype = types.get(rel, {}).get("type")
        entries.append(make_entry(rel, fp.read_bytes(), etype, store))
    return entries


_XML_TAGS = {
    "dict": "dict", "d": "dict", "array": "array", "a": "array", "string": "string", "s": "string",
    "int": "int", "i": "int", "float": "float", "f": "float", "bool": "bool", "b": "bool", "null": "null",
}


def xml_to_svalue(elem):
    """Convert the game's SValue XML (<dict>/<array>/<string>/<int>/<float>/<bool>, or their
    one-letter forms) into Python values that encode_svalue accepts."""
    kind = _XML_TAGS.get(elem.tag)
    if kind is None:
        raise ValueError(f"unsupported info.xml element <{elem.tag}>")
    if kind == "dict":
        out = {}
        for child in elem:
            name = child.get("name")
            if name is None:
                raise ValueError(f"<{child.tag}> inside a <dict> needs a name attribute")
            out[name] = xml_to_svalue(child)
        return out
    if kind == "array":
        return [xml_to_svalue(child) for child in elem]
    text = (elem.text or "").strip()
    if kind == "string":
        return text
    if kind == "int":
        return int(text)
    if kind == "float":
        return float(text)
    if kind == "bool":
        return text.lower() in ("1", "true", "yes")
    return None


def read_info_xml(src: Path) -> dict:
    """Parse an unpacked mod's info.xml into the dict the packed archive stores as its meta.
    The whole document is kept (name/author/description plus classmaps, scripts, ...),
    so packed and unpacked mods behave the same."""
    info = src / "info.xml"
    if not info.is_file():
        return {}
    import xml.etree.ElementTree as ET
    try:
        root = ET.fromstring(info.read_text(encoding="utf-8", errors="replace"))
    except ET.ParseError as e:
        raise ValueError(f"{info}: {e}") from None
    if _XML_TAGS.get(root.tag) == "dict":
        return xml_to_svalue(root)
    # tolerate the simpler <mod><name>..</name></mod> form too
    return {child.tag: (child.text or "").strip() for child in root}


def cmd_tex2png(args):
    data = Path(args.src).read_bytes()
    if not is_texture(data):
        sys.exit(f"{args.src} is not an engine texture")
    Path(args.dst).write_bytes(texture_to_png(data))


def cmd_png2tex(args):
    data = Path(args.src).read_bytes()
    if not is_png(data):
        sys.exit(f"{args.src} is not a PNG file")
    Path(args.dst).write_bytes(png_to_texture(data))


def cmd_pack(args):
    src = Path(args.srcdir)
    if not src.is_dir():
        sys.exit(f"not a directory: {src}")
    manifest = None
    mpath = src / MANIFEST
    if mpath.is_file():
        manifest = json.loads(mpath.read_text(encoding="utf-8"))
    game = args.game or (manifest or {}).get("game") or "hoh2"
    meta = dict((manifest or {}).get("meta") or {})
    meta.update(read_info_xml(src))
    for key in ("author", "name", "description"):
        val = getattr(args, key)
        if val is not None:
            meta[key] = val
    if game == "hoh2" and not meta.get("name"):
        sys.exit("HoH2 packages need at least --name (the game rejects mods without metadata)")
    # Keep key order the packager uses.
    ordered = {k: meta[k] for k in ("author", "name", "description") if k in meta}
    ordered.update({k: v for k, v in meta.items() if k not in ordered})
    entries = collect_dir(src, manifest, args.store, set(args.exclude or []))
    a = Archive(game, GAMES[game][1], 0, ordered, entries)
    hsh = int(args.hash, 0) if args.hash else None
    a.write(args.out, hsh)
    disk = sum(len(e.blob) for e in entries)
    print(f"packed {len(entries)} files -> {args.out} ({disk:,} B payload, meta={json.dumps(ordered, ensure_ascii=False)})")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info", help="print header information")
    p.add_argument("archive")
    p.set_defaults(fn=cmd_info)

    p = sub.add_parser("list", help="list entries (type, raw size, compressed size, path)")
    p.add_argument("archive")
    p.add_argument("-f", "--filter", help="regex on the entry path")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("extract", help="extract entries to a directory")
    p.add_argument("archive")
    p.add_argument("outdir")
    p.add_argument("-f", "--filter", help="regex on the entry path")
    p.add_argument("--no-manifest", action="store_true", help=f"do not write {MANIFEST}")
    p.add_argument("--png", action="store_true", help="convert engine textures to real PNG files")
    p.set_defaults(fn=cmd_extract)

    p = sub.add_parser("tex2png", help="convert an engine texture to a PNG file")
    p.add_argument("src")
    p.add_argument("dst")
    p.set_defaults(fn=cmd_tex2png)

    p = sub.add_parser("png2tex", help="convert a PNG file to an engine texture")
    p.add_argument("src")
    p.add_argument("dst")
    p.set_defaults(fn=cmd_png2tex)

    p = sub.add_parser("pack", help="pack a directory into an archive")
    p.add_argument("srcdir")
    p.add_argument("out")
    p.add_argument("--game", choices=sorted(GAMES))
    p.add_argument("--name")
    p.add_argument("--author")
    p.add_argument("--description")
    p.add_argument("--store", action="store_true", help="do not LZ4-compress entries")
    p.add_argument("--hash", help="header hash override, e.g. 0xd7d0422d")
    p.add_argument("--exclude", action="append", metavar="RELPATH", help="skip this file (repeatable)")
    p.set_defaults(fn=cmd_pack)

    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
