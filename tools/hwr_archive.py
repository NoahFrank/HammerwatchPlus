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
The header hash is not yet understood (not a crc/adler/fnv/xxhash of anything
obvious); `pack` writes a crc32 of the body unless `--hash` is given. The game
has loaded such packages fine so far; see docs/archive-format.md.

Usage:
    hwr_archive.py list    ARCHIVE [-f REGEX]
    hwr_archive.py extract ARCHIVE OUTDIR [-f REGEX]
    hwr_archive.py pack    SRCDIR OUT.bin [--name N --author A --description D]
                           [--game hoh2|hoh1] [--store] [--hash 0xHEX]
    hwr_archive.py info    ARCHIVE
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
SV_DICT = 0x02
SV_STRING = 0x06


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
    """Decode the subset of SValue we have seen in archive headers."""
    if pos >= len(buf):
        return {}, pos
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
        for e in self.entries:
            if e.path == path:
                return e
        return None

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


def make_entry(path: str, data: bytes, etype: int | None = None, store: bool = False) -> Entry:
    etype = type_for(path) if etype is None else etype
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
        dest.write_bytes(e.data())
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


def collect_dir(src: Path, manifest: dict | None, store: bool, exclude: set[str]) -> list[Entry]:
    types = (manifest or {}).get("files", {})
    entries = []
    for fp in sorted(src.rglob("*")):
        if not fp.is_file():
            continue
        rel = fp.relative_to(src).as_posix()
        if rel in exclude or rel == MANIFEST or any(part.startswith(".") for part in fp.relative_to(src).parts):
            continue
        etype = types.get(rel, {}).get("type")
        entries.append(make_entry(rel, fp.read_bytes(), etype, store))
    return entries


def read_info_xml(src: Path) -> dict:
    """Pull author/name/description out of an unpacked mod's info.xml (best effort)."""
    info = src / "info.xml"
    if not info.is_file():
        return {}
    text = info.read_text(encoding="utf-8", errors="replace")
    out = {}
    # real format: <dict><string name="name">..</string>...</dict>
    for key in ("author", "name", "description"):
        m = re.search(rf'<string\s+name="{key}"\s*>(.*?)</string>', text, re.S)
        if m is None:  # tolerate the simpler <name>..</name> form too
            m = re.search(rf"<{key}>(.*?)</{key}>", text, re.S)
        if m:
            out[key] = m.group(1).strip()
    return out


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
    p.set_defaults(fn=cmd_extract)

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
