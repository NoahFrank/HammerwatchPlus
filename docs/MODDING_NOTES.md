# Modding notes: Heroes of Hammerwatch II

The modding ecosystem as it stands on build 25509441 (`gamelab/build_id.json`): how mods
load, which tools exist, where everything is installed, and every log path. Measured facts
cite `docs/RE_NOTES.md`; anything unmeasured says "assumed".

## Mod stack

There is no third-party loader. Mods are the game's own **resource mods**:

| Form | Where | Id |
|---|---|---|
| Unpacked folder | `<exe dir>/mods/<id>/` with `info.xml` (name/author/description) and any `scripts/`, `tweak/`, units, language files | the folder name (measured: `Adding unpacked mod 'gamelab-probe'`) |
| Packed `.bin` | `<exe dir>/mods/<name>.bin` (HWRR archive; `tools/build.py`, `tools/hwr_archive.py`, `docs/archive-format.md`) | the id in the archive's meta |
| Steam Workshop | `Steam/steamapps/workshop/content/619820/<item>/` | listed at startup as `Resource mod: <file>: <name> (<id>)` |

- **Enabled per save, not globally.** The profile save's header lists `HashString(id)`
  for each enabled mod (`gamelab/hps.py`; the hash is MurmurHash3_x86_32, seed
  `0xf808409c`, see RE_NOTES). Players toggle mods in Resource Mods (`ModlistWindow`).
  GameLab writes the list into the lab save with `hps.py` (the one binary edit in the
  fixture schema).
- **Scripts are AngelScript.** Mod scripts compile into the same module as the base
  scripts, so a mod can call base functions and other mods' namespaces. Mods can add
  classes, override base script files by path, and register console commands
  (`AddFunction`). Hooks and API quirks: `docs/hooks.md`.
- **Lifecycle.** Enabled mods load at boot.
  - `Modules::Module` subclasses are created by reflection when the menu level loads. The
    main menu is `levels/town.lvl`.
  - `UpdateFrame` ticks only once a gameplay session starts (RE_NOTES 2026-10-17, mod
    lifecycle).

## Tools

| Tool | What | Notes |
|---|---|---|
| `PACKAGER.exe` (game) | Unpacks `res/assets.bin`, builds resources | Needs Steam; `tools/patch_packager.py` builds a Steam-free copy into `tools/bin/` (`docs/packager.md`) |
| `EDITOR.exe`, `HWR2Toolkit.exe` (game) | Level editor, effect/unit toolkits | Not used by this project yet |
| `tools/hwr_archive.py` | Read/write HW2R and HWRR archives | Packing goes through a round-trip gate (`docs/archive-format.md`) |
| `tools/build.py` | Packs `mods/<module>` into `dist/HWP-<module>.bin` | Skips the `gamelab-*` mods |
| `tools/bootstrap.py` | Regenerates `gamecode/` and `tools/bin/` from the install | `--verify` against `gamelab/manifest.json` |
| `tools/export_datatables.py` | `.sval` → JSON, parsed by the running game | Through a GameLab lab run |
| `python -m gamelab` | The GameLab harness | `gamelab/launcher.py` |
| `python -m gamelab run mod-<id> --mode lab` | Load check for one mod: its README's self-check lines, no script errors in our files | `gamelab/logparse.py` holds the log regexes salvaged from `dev_check` |
| `python -m gamelab.observe <run>` | Frame paths + `sha256[:12]`; exit 1 when no readable frame | For the blind-observer check |

## Install and user-data paths

| What | Path |
|---|---|
| Install | `C:\Program Files (x86)\Steam\steamapps\common\Heroes of Hammerwatch 2` (`tools/gamepaths.py hoh2_dir()`) |
| Game config | `<install>/HWR2.exe.cfg` (cvars, one per line) |
| Key bindings | `<install>/res/controls_default.cfg`; once rebound, `<install>/res/controls.cfg` (assumed from exe strings; no rebind measured) |
| Cloud saves | `Steam/userdata/<account>/619820/remote/saves/<slot>[_n].hps` |
| Local saves | `<install>/saves/<slot>[_n].hps` (when `g_save_slot_cloud 0`) |
| Game's own save backups | `%LOCALAPPDATA%/HeroesofHammerwatch2/save_backups/slot_<n>_<date>.hps` |
| Unpacked mods | `<install>/mods/<id>/` |
| GameLab's game dir | `gamelab/env/userdata/game/` (exe copy, own `res/`, cfg, saves, logs, `appdata/`) |

## Logs (all tailed or collected by GameLab)

| Log | Path | Written by | Collected as |
|---|---|---|---|
| Game log | `<exe dir>/HWR2.exe.log` | the engine and script `print()`, including every `[GL]` line and `[HWP:<module>]` line | tailed live (`gamelab/session.py`), copied to `results/<run>/logs/pass<n>.HWR2.exe.log` |
| Rotated game logs | `<exe dir>/logs/HWR2.exe_<date>_<time>.log` | the engine, at the next start | not collected (the per-pass copy covers each run) |
| Crash dumps | `<exe dir>/HWR2_<build>_crash_<date>_T<time>__<n>.mdmp` | the engine | a non-zero exit fails the pass; dumps stay in the game dir |
| Shim log | `<exe dir>/gamelab_capture.log` | `tools/bin/hwr2_capture.dll` (hooks, captures, folder redirects) | read for live verification; copied to `results/<run>/logs/pass<n>.shim.log` |
| GameLab telemetry | `gamelab/results/<run>/gl.jsonl` | the harness (`harness.*` events) and every `[GL]` object from the game log | written live |
| Run record | `gamelab/results/<run>/run.json`, `inner.json`, `runner.out.txt` | launcher / runner | per run |

The game log names its build on line 2 (`Build 170: ARCH_64 USING_STEAM RELEASE FINAL`)
and the exe that ran (`Launch options: 1: <exe>`). `gamelab-probe` prints its version in
its `boot` event. The build gate is `gamelab/build_id.json`; a mismatch makes the
launcher exit 3.
