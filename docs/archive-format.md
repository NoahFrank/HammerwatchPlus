# HWR archive format

`res/assets.bin` and every mod `.bin` share one container. HoH2 uses magic
`HW2R`, version 4; HoH1 uses `HWRR`, version 3. All integers are little-endian.

```
magic[4]      "HW2R" | "HWRR"
u8   version  4 | 3
u32  hash     see below
u32  metaLen
u8   meta[metaLen]        SValue (see below); empty for assets.bin
u32  reserved = 0         HW2R only
u32  fileCount
entry[fileCount]

entry:
  u32  pathLen
  u8   path[pathLen]      forward slashes, relative to the resource root (e.g. scripts/Foo.as)
  u8   type               1 = text/data, 3 = png/tif/lvl/pfb, 7 = some pfb, 0xFF = sound bank
  -- type 0xFF: u32 0xFFFFFFFF and nothing else (banks are loose in res/assets/sound)
  u32  rawSize
  u32  compSize           0 = stored; else a raw LZ4 block (no frame header) of compSize bytes
  u8   data[compSize or rawSize]
```

## Meta SValue

A binary SValue: tag byte then payload. The same container is used by `.lvl`
(8 opaque header bytes, then the dict), `.pfb` (the dict at offset 0) and the
save sections, in HoH1 and HoH2 alike. `tools/hwr_archive.py decode_svalue`
reads all of it, verified to end-of-file on 2026-10-16 on every HoH2 and HoH1
level and prefab (6491 files) and on all 60 town/character sections of the 10
local HoH2 saves. A truncated buffer raises instead of decoding short.

| tag | type | payload |
|---|---|---|
| `0x00` | null | – |
| `0x01` | array | `u32 count`, then `count` values |
| `0x02` | dict | `u32 count`, then `count` × (`key\0`, value) |
| `0x03` | bool | `u8` |
| `0x04` | f32 | 4 bytes |
| `0x05` | i32 | 4 bytes |
| `0x06` | string | `utf8\0` |
| `0x07` | blob | `u32 len`, bytes (tile layers: HoH1 `data` raw, HoH2 `data-rle`) |
| `0x08` / `0x09` / `0x0a` | vec2 / vec3 / vec4 | 2 / 3 / 4 × f32 (vec4 = colors) |
| `0x0b` / `0x10` | i64 / f64 | 8 bytes (saves only) |
| `0x65` `0x66` | empty array / empty dict | – |
| `0x67` `0x68` | false / true | – |
| `0x69` | f32 0 | – |
| `0x6e` | i32 0 | – |
| `0x73` | i64 0 | – (saves; sits where other stat entries have `0x0b`) |
| `0x78` | empty string | – |
| `0x7a` `0x7b` | vec2 (0,0) / (x,0) | – / 1 × f32 |
| `0x7c` `0x7d` `0x7e` | vec3 (0,0,0) / (x,0,0) / (x,y,0) | 0 / 1 / 2 × f32 |
| `0x7f`..`0x82` | vec4 with 0 / 1 / 2 / 3 leading components stored, rest 0 | 0..3 × f32 |
| `0x8c` `0x8d` `0x8e` | vec2 / vec3 / vec4 splat (x,x[,x[,x]]) | 1 × f32 |

The writer always uses the compact literal when one applies: no file contains
an explicit `0x05 0`, `0x04 0.0`, `0x06 ""`, `0x03`, or a zero vector in long
form. Null (`0x00`) is written explicitly. The encoder here writes the long
forms, which the engine also reads (ints outside i32 as `0x0b`).

Mods carry `author`, `name`, `description`. HWR2 refuses a package with no
meta: `Mod is too old (missing metadata)`.

## Header hash

Not a CRC-32, Adler-32, FNV-1/1a, DJB2, MurmurHash3, xxHash32/64/3, MD5 or
SHA-1 of the body, the meta, the file table, the paths, or the uncompressed
stream (tested 2026-10-16). Two different builds of the same mod share a hash,
so it is probably not a content hash at all. The executable has no "hash
mismatch" message; `tools/hwr_archive.py pack` writes a CRC-32 of the body.

## Mod discovery

* Packed: `mods/*.bin`. The mod id is the file name without `.bin`
  (`Resource mod: drop_me.bin: Drop Me (drop_me)`).
* Unpacked: `mods/<id>/info.xml`.
* Workshop: `steamapps/workshop/content/619820/<item>/*.bin`.
* Which mods are *enabled* is stored in the persistent save header (below);
  enabled ones log `Adding packed mod '<id>'` / `Adding unpacked mod '<id>'`.

## Persistent save header (`saves/<slot>.hps`, `H2SV`)

The game rotates writes over `<slot>.hps`, `<slot>_1.hps` ... `<slot>_9.hps` and
loads the file with the highest play-time counter. Layout:

```
"H2SV"
u8   version        3 = no mods enabled, 4 = the enabled-mod block follows the build
u8[3] 0
f32  counter        play time; highest wins
u32  build          game build (417 as of 2026-10-16)
[version 4 only]
  u8 0, u8 (2*n + 1), u8 0
  u32 modHash[n]     HashString(mod.ID), e.g. HashString("drop_me") = 0xd545c643
  u32 0
town record         u32 rawSize, u32 lz4Size, raw LZ4 block of a binary SValue
u32 characterCount, then per character: u32 hash, section, u32 hasRun, [run data]
...
u32 trailer         first 4 bytes of MD5(file[:-4])
```

`gamelab/hps.py` reads and patches the mod block (and fixes the trailer); the
core module logs `modhash '<id>' <hash>` for every discovered mod so the tool
can learn ids it has not seen. The sections are binary SValues with the tag
set above (`0x0b` i64 and `0x10` f64 appear only here).

## Textures

`.png` entries are not PNG files. The packager converts images to the engine's
own format and the *unpacked* loader (`mods/<id>/`) only accepts real PNGs
(`Can only load RGB or RGBA textures` otherwise, and the game hangs):

```
u32 width, u32 height, i32 -1, u32 channels (3 or 4), LZ4 block of width*height*channels bytes
```

Pixel order is RGBA. The repo keeps editable PNGs; `tools/hwr_archive.py pack`
(and so `build.py`) converts them when packing, `extract --png` converts the
other way (`gamecode/sdk/hoh2/` is extracted raw; use `tex2png` on single files).

HoH1 also has a small uncompressed variant (tiny textures):
`u32 width, u32 height, u32 channels, raw pixels`, without the `-1` and the
LZ4 block. `hwr_archive.py` recognises it by its exact size and converts it
like the other.

## Loose levels and prefabs (unpacked mods)

The unpacked loader reads loose mod files as **SValue XML**, not binary, so
`.lvl` and `.pfb` under `mods/<id>/` must be XML (`<dict>...</dict>` in the
same form as `.unit`/`.sval`). `tools/hoh1_convert.py` writes them that way.
A `.lvl` keeps its 8 opaque header bytes as a first-line comment,

```
<!-- hwp-level-header 0123456789abcdef -->
```

and `build.py` compiles loose `.lvl`/`.pfb` XML back to binary SValue when
packing, prefixing those 8 bytes again (a level without the comment gets
zeros).

## Language files

Base `.lang` files are loose in `res/language/<lang>/`. A mod file named
`language/english/dialogue.lang` collides with the base file of the same name
(`Resource name hash conflict`). Use a unique file name; existing mods use
`res/language/english/<unique>.lang` and that is what HammerwatchPlus does:
`res/language/english/hwp_<module>.lang`.
