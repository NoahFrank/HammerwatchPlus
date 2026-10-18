# PACKAGER.exe: the official archive tool, and the Steam-free patched copy

Build measured: Heroes of Hammerwatch II, Steam build 25509441 (2026-10-15 update).
Everything here is **verified** on that build unless marked **assumed**.

## Command line

```
PACKAGER [/h] [/r <dir>] [/l <scenario>] [/u <bin>] [/d <dir>] [--sval]
```

| Option | Does |
|---|---|
| `-h`, `--help` | usage in a message box (blocks until OK) |
| `-r`, `--resources=<dir>` | pack a folder into `<dir>.bin` beside it; `info.xml` becomes the archive metadata, not a file |
| `-l`, `--level=<scenario>` | pack a scenario by name or number (lists subscribed Workshop items first) |
| `-u`, `--unpack=<bin>` | unpack an archive; needs `-d` |
| `-d`, `--destination=<dir>` | unpack destination (created if the parent exists) |
| `--sval` | with unpack of a mod `.bin`: also write the metadata back as `info.xml`. Despite the help text, no `info.sval` is written for mod archives; the `info.sval` branch is **assumed** to be for level packages |

Behaviour of the tool itself (not patch effects):

- Successful command-line runs exit **-1** (wxWidgets "nothing more to do"). Not an error.
- Any command line that is not a complete action (no args, `-u` without `-d`, `-d` alone,
  `--sval` alone) prints its complaint and then **opens the GUI**.
- `--resources` on a missing folder quietly writes a valid empty 21-byte archive and prints `Done!`.
- Every pack prints `[ERR] Failed to parse XML tree ... resources.xml` when the folder has
  no `resources.xml`. Harmless.
- Unpacking the full `res/assets.bin` writes all 15,655 files and then stops on a modal
  "Packager Error" box, caused by the five sound-bank entries (type `0xFF`, no data). The
  box must be dismissed or the process killed; the files are complete either way.
- It is a GUI app: dialogs block forever in an unattended run. Always run it with a timeout.

## Steam requirement

`PACKAGER.exe` initialises Steam on startup and exits 1 with
`[ERR] Failed to initialize Steam!` and zero files written when Steam is not running.
Measured twice, including with no `steam.exe` process at all.

## The patched copy

`tools/patch_packager.py <pristine PACKAGER.exe> <out>` builds a copy that skips the Steam
init. Build it into the gitignored `tools/bin/` and copy the game's DLLs beside it:

```
python tools/patch_packager.py "<game dir>/PACKAGER.exe" tools/bin/PACKAGER.exe
cp "<game dir>"/*.dll tools/bin/
tools/bin/PACKAGER.exe --unpack="<game dir>/res/assets.bin" --destination=<out>
```

What the patch is: one 6-byte change in `SteamService::Initialize`. The
`call [SteamAPI_Init]` becomes a `jmp` to the function's non-Steam tail (the part that
allocates the cloud-save service and returns), so `SteamAPI_Init`,
`RestartAppIfNecessary`, the null check that calls `exit(1)`, and the Steam ID log are
all skipped. The site is found by instruction signature plus import-table resolution,
never by fixed offset, and the script refuses to patch if the match is not unique. On
build 25509441 it patches file offset `0x251324`: `FF 15 DE 9C 25 00` → `E9 C0 00 00 00 90`.

Needs `pefile` (in `pyproject.toml`; `uv sync`). Never commit the patched exe; it is a game binary.

### Verified identical to the original (Steam up, side by side, 23 cases)

| Function | Result |
|---|---|
| `--unpack` of `res/assets.bin` | 15,655 files, 816,568,639 bytes, byte-identical |
| `--unpack` of four mod archives | output trees identical |
| `--resources` on four module folders | `.bin` files byte-identical; deterministic across runs; `-r` and `--resources` identical |
| Round trip pack → unpack | every text file byte-identical; every PNG (54/54) comes back pixel-identical as a real PNG (the archive stores engine textures) |
| `--sval` on a mod archive | `info.xml` written back byte-identical to the source |
| `--help`, unknown option | same usage box |
| `--unpack` of a missing file | same `... does not exist!`, exit -1 |
| Logs | identical except the original's `Steam ID:` line and two breakpad lines |

### Where the patched copy is worse than the original

All three come from one unpatched call: the Workshop subscribed-item listing
(`SteamService` vtable slot 8), which dereferences a Steam interface the patch left null.

| Case | Original | Patched |
|---|---|---|
| `--level=<anything>` | lists Workshop items, then reports the scenario cleanly, exit -1 | **access violation** before the scenario lookup |
| no args, `-u` without `-d`, `-d` alone, `--sval` alone | opens the GUI | **access violation** |
| `--unpack` with extraction of PNGs | no window | a stray "Packager Error" window; files still identical, exit -1 |

So: **use the patched copy for `--unpack`, `--resources`, `--sval` and `--help` only.**
Workshop upload is Steam-only by nature and uses the original.

Open: a second patch point that returns early from the Workshop listing would remove all
three differences. Not applied; needs a decision.

## Steam calls the patched copy still makes

Traced with a breakpoint on every `steam_api64` import. Pack and unpack make exactly one
Steam call, `SteamAPI_RegisterCallback` from the service constructor, which runs before
the patched code on the original too and is harmless without Steam. No `SteamAPI_Init`,
no UGC, no Cloud calls. The patched startup still allocates the cloud-save object and
sets the service's initialised flag, so the program believes Steam is up.

## Harness

`C:\tmp\claude\packager-verify\` (scratch, not in the repo): `scripts/suite.py` is the
23-case matrix, `scripts/run_pk.py` runs one case boxed on the hidden desktop with dialog
capture, `scripts/steam_compare.py` runs the original against the recorded patched
results (refuses to start unless `steam.exe` is running), `scripts/trace_steam.py` is the
Steam-import tracer. Re-run after any game update or patcher change.

## Relation to `tools/hwr_archive.py`

The pure-Python tool reads the same format. `extract` matches PACKAGER byte-for-byte on
every text and data file (10,617) and leaves levels, prefabs and textures (5,038) in the
engine's binary form, where PACKAGER decodes them to XML and real images. Its `pack`
output decodes identically to PACKAGER's for the four modules compared (same paths,
types, metadata, pixels); only the inner LZ4 bytes and the header hash differ, and the
hash algorithm is still unknown. The gate for calling `pack` verified is a pack → PACKAGER
unpack round trip over every file type including a level or prefab, which has not been run.
