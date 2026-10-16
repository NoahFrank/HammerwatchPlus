#!/usr/bin/env python3
"""
hps.py - read and patch the HoH2 persistent save header (saves/<slot>.hps).

The game keeps the list of *enabled* resource mods in the save file header as
32-bit hashes of the mod ids (HashString(mod.ID)), so automated testing needs
to patch the save to switch mods on. Layout (little-endian):

    "H2SV" u8 version     3 = no mods enabled, 4 = header carries the mod block below
    u8[3] 0
    f32 counter           play time; the game loads the slot's rotation file
                          (<slot>.hps / <slot>_N.hps) with the highest value
    u32 game build
    [mod block, version 4 only]
        u8 0, u8 (2*n + 1), u8 0, n x u32 modIdHash, u32 0
    town section: u32 raw, u32 comp, lz4 block (just u32 0 in a new profile)
    u32 characterCount, then per character: u32 hash, section, u32 hasRun, [run data]
    ...
    u32 trailer = first 4 bytes of MD5(file[:-4])

The hash algorithm is not public, so known id -> hash pairs are collected in
tools/mod_hashes.json. `hps.py learn` fills it from a game log where the core
module printed `[HWP:core] modhash '<id>' <hash>` lines, or by pairing the save's
hash list with the `Adding ... mod '<id>'` lines of a log in order.

    hps.py show                      # current rotation file, header, enabled mod hashes (+ ids when known)
    hps.py set hwp_core hwp_gambler  # enable exactly these ids (needs known hashes)
    hps.py add <id|0xhash>...        # enable in addition to the current list
    hps.py remove <id|0xhash>...
    hps.py clear
    hps.py learn [--log PATH]
    hps.py restore                   # put back the most recent backup made by this tool (to the file it came from)

Every write first copies the save to %LOCALAPPDATA%/HeroesofHammerwatch2/hwp_save_backups/.
Never run this while the game is open.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402

MAGIC = b"H2SV"
HASHES_FILE = Path(__file__).resolve().parent / "mod_hashes.json"
BACKUP_DIR = Path(os.environ.get("LOCALAPPDATA", "")) / "HeroesofHammerwatch2" / "hwp_save_backups"
MOD_ADDED = re.compile(r"Adding (?:packed|unpacked) mod '([^']+)'")
MODHASH_LINE = re.compile(r"\[HWP:core\] modhash '([^']+)' (\d+)")


class Header:
    def __init__(self, data: bytes):
        if data[:4] != MAGIC:
            raise ValueError("not an H2SV save")
        self.version = data[4]
        self.pad = data[5:8]
        self.unknown, self.build = struct.unpack_from("<II", data, 8)
        pos = 16
        self.mods: list[int] = []
        # version 3 = plain header, version 4 = header followed by the enabled-mod block
        if self.version == 4:
            block = self._parse_mod_block(data, pos)
            if block is None:
                raise ValueError("version 4 save without a readable mod block")
            self.mods, pos = block
        elif self.version != 3:
            raise ValueError(f"unsupported save version {self.version}")
        self.body_offset = pos
        if not self._section_at(data, pos):
            raise ValueError("town section not where expected; header layout changed?")

    @staticmethod
    def _section_at(data: bytes, pos: int) -> bool:
        """A town section starts at pos: u32 raw, u32 comp, block - or a lone u32 0
        when the profile has no town yet (a new profile before its first run)."""
        if pos + 8 > len(data):
            return False
        raw, comp = struct.unpack_from("<II", data, pos)
        if raw == 0:
            return True
        return 0 < comp <= raw < 64 * 1024 * 1024 and pos + 8 + comp <= len(data)

    @classmethod
    def _parse_mod_block(cls, data: bytes, pos: int):
        """Return (hashes, pos after block) when a well-formed mod block sits at pos."""
        if pos + 7 > len(data) or data[pos] != 0 or data[pos + 2] != 0:
            return None
        count_byte = data[pos + 1]
        if count_byte % 2 == 0:
            return None
        n = (count_byte - 1) // 2
        end = pos + 3 + 4 * n + 4
        if end > len(data) or struct.unpack_from("<I", data, end - 4)[0] != 0:
            return None
        if not cls._section_at(data, end):
            return None
        return list(struct.unpack_from("<%dI" % n, data, pos + 3)), end

    def encode(self) -> bytes:
        version = 4 if self.mods else 3
        out = MAGIC + bytes([version]) + self.pad + struct.pack("<II", self.unknown, self.build)
        if self.mods:
            out += bytes([0, 2 * len(self.mods) + 1, 0])
            out += struct.pack("<%dI" % len(self.mods), *self.mods)
            out += b"\0\0\0\0"
        return out


def trailer_ok(data: bytes) -> bool:
    return data[-4:] == hashlib.md5(data[:-4]).digest()[:4]


def read_save(path: Path) -> tuple[bytes, Header]:
    data = path.read_bytes()
    hdr = Header(data)
    if not trailer_ok(data):
        print(f"warning: {path} trailer does not match MD5; file may be damaged or the format changed", file=sys.stderr)
    return data, hdr


def write_save(path: Path, data: bytes, hdr: Header) -> Path:
    body = data[hdr.body_offset:-4]
    new = hdr.encode() + body
    new += hashlib.md5(new).digest()[:4]
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    backup = BACKUP_DIR / f"{path.stem}_{time.strftime('%Y%m%d_%H%M%S')}.hps"
    shutil.copy2(path, backup)
    path.write_bytes(new)
    return backup


def load_known() -> dict[str, int]:
    if HASHES_FILE.is_file():
        return {k: int(v, 16) if isinstance(v, str) else int(v) for k, v in json.loads(HASHES_FILE.read_text()).items()}
    return {}


def save_known(known: dict[str, int]) -> None:
    HASHES_FILE.write_text(json.dumps({k: f"{v:#010x}" for k, v in sorted(known.items())}, indent=1) + "\n")


def resolve(tokens: list[str], known: dict[str, int]) -> list[int]:
    out = []
    for t in tokens:
        if re.fullmatch(r"0x[0-9a-fA-F]{1,8}", t):
            out.append(int(t, 16))
        elif t in known:
            out.append(known[t])
        else:
            sys.exit(f"unknown mod id {t!r}: enable it once in the Resource Mods menu, "
                     f"then run `hps.py learn` (or pass its hash as 0x...)")
    return out


def slot_files(slot: int) -> list[Path]:
    """All rotation files of a slot: <slot>.hps and <slot>_N.hps."""
    d = paths.hoh2_dir() / "saves"
    return sorted(p for p in d.glob(f"{slot}*.hps") if re.fullmatch(rf"{slot}(_\d+)?", p.stem))


def current_save(slot: int) -> Path:
    """The game loads the rotation file with the highest header counter (float at offset 8)."""
    best = None
    for p in slot_files(slot):
        try:
            counter = struct.unpack_from("<f", p.read_bytes(), 8)[0]
        except Exception:
            continue
        key = (counter, p.stat().st_mtime)
        if best is None or key > best[0]:
            best = (key, p)
    if best is None:
        sys.exit(f"no save files for slot {slot} in {paths.hoh2_dir() / 'saves'}")
    return best[1]


def save_path(args) -> Path:
    p = Path(args.save) if args.save else current_save(args.slot)
    if not p.is_file():
        sys.exit(f"save not found: {p}")
    return p


def cmd_show(args):
    path = save_path(args)
    data, hdr = read_save(path)
    known = load_known()
    by_hash = {v: k for k, v in known.items()}
    print(f"{path}: version {hdr.version}, build {hdr.build}, {len(data):,} bytes, trailer {'ok' if trailer_ok(data) else 'BAD'}")
    print(f"enabled mods ({len(hdr.mods)}):")
    for h in hdr.mods:
        print(f"  {h:#010x}  {by_hash.get(h, '?')}")


def _apply(args, new_mods: list[int]):
    path = save_path(args)
    data, hdr = read_save(path)
    hdr.mods = new_mods
    backup = write_save(path, data, hdr)
    print(f"patched {path} (backup {backup}); enabled hashes: {[f'{h:#010x}' for h in new_mods]}")


def cmd_set(args):
    _apply(args, resolve(args.ids, load_known()))


def cmd_add(args):
    data, hdr = read_save(save_path(args))
    mods = list(hdr.mods)
    for h in resolve(args.ids, load_known()):
        if h not in mods:
            mods.append(h)
    _apply(args, mods)


def cmd_remove(args):
    data, hdr = read_save(save_path(args))
    drop = set(resolve(args.ids, load_known()))
    _apply(args, [h for h in hdr.mods if h not in drop])


def cmd_clear(args):
    _apply(args, [])


def cmd_learn(args):
    log = Path(args.log) if args.log else paths.hoh2_dir() / "HWR2.exe.log"
    text = log.read_text(encoding="utf-8", errors="replace")
    known = load_known()
    learned = {}
    for mid, h in MODHASH_LINE.findall(text):
        learned[mid] = int(h)
    if not learned:
        # fall back: pair the save's hash list with the log's enable order
        ids = []
        for mid in MOD_ADDED.findall(text):
            if mid not in ids:
                ids.append(mid)
        _, hdr = read_save(save_path(args))
        if ids and len(ids) == len(hdr.mods):
            learned = dict(zip(ids, hdr.mods))
        else:
            sys.exit(f"cannot pair {len(ids)} log ids with {len(hdr.mods)} save hashes; run the game with the core module once")
    changed = {k: v for k, v in learned.items() if known.get(k) != v}
    known.update(learned)
    save_known(known)
    print(f"known hashes: {len(known)} ({len(changed)} new/updated) -> {HASHES_FILE}")
    for k, v in sorted(changed.items()):
        print(f"  {k:40s} {v:#010x}")


BACKUP_NAME = re.compile(r"^(?P<stem>.+)_(?P<ts>\d{8}_\d{6})\.hps$")


def cmd_restore(args):
    """Copy the newest backup back over the rotation file it was taken from
    (the backup name carries that file's stem), not over whatever file is current now."""
    saves = paths.hoh2_dir() / "saves"
    backups = []
    for p in (BACKUP_DIR.glob("*.hps") if BACKUP_DIR.is_dir() else []):
        m = BACKUP_NAME.match(p.name)
        if not m:
            continue
        # --save names the file outright; otherwise any rotation file of the slot qualifies
        if args.save is not None:
            wanted = Path(args.save).stem == m.group("stem")
        else:
            wanted = re.fullmatch(rf"{args.slot}(_\d+)?", m.group("stem")) is not None
        if wanted:
            backups.append((m.group("ts"), m.group("stem"), p))
    if not backups:
        what = f"{Path(args.save).stem}.hps" if args.save else f"slot {args.slot}"
        sys.exit(f"no backups for {what} in {BACKUP_DIR}")
    ts, stem, src = max(backups)
    dst = saves / f"{stem}.hps"
    shutil.copy2(src, dst)
    print(f"restored {dst} from {src}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--save", help="explicit .hps path (default: the slot's newest rotation file, which is what the game loads)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show").set_defaults(fn=cmd_show)
    p = sub.add_parser("set"); p.add_argument("ids", nargs="*"); p.set_defaults(fn=cmd_set)
    p = sub.add_parser("add"); p.add_argument("ids", nargs="+"); p.set_defaults(fn=cmd_add)
    p = sub.add_parser("remove"); p.add_argument("ids", nargs="+"); p.set_defaults(fn=cmd_remove)
    sub.add_parser("clear").set_defaults(fn=cmd_clear)
    p = sub.add_parser("learn"); p.add_argument("--log"); p.set_defaults(fn=cmd_learn)
    sub.add_parser("restore").set_defaults(fn=cmd_restore)
    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
