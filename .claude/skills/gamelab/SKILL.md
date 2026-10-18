---
name: gamelab
description: Run, write and debug GameLab scenarios - the only sanctioned way to auto boot Heroes of Hammerwatch II. Use to smoke-test a mod in the live game, measure an engine fact on the pinned build, drive the player with a Pilot bot, or read a run's run.json and exit code. Also use to set up a fresh clone or new machine (missing gamecode/, decompiled scripts, tools/bin, save backups) via `python -m gamelab doctor`. For a one-off screenshot, use game-screenshot instead.
---

# gamelab

GameLab boots HoH2 on a hidden desktop, muted, with its own profile and saves, builds a
known character (a fixture), runs a JSON scenario against the live game and writes a
verdict. Purpose: claims about the game are measured on the pinned build and cited by
run dir, never assumed.

## First: is this machine ready? (`doctor`)

A fresh clone lacks everything gitignored: `.venv`, `gamecode/` (the game's scripts and
datatables), `tools/bin/` (patched PACKAGER, capture shim), the GameLab game dir and any
save backup. Run this before anything else in a session, and before every run on a
clone you haven't checked:

```
python -m gamelab doctor         # report only; exit 0 green, 2 not ready
python -m gamelab doctor --fix   # uv sync, confirm saves (when unambiguous), bootstrap.py, env_link.py,
                                 # class_units.py, the HoH1 imports once HoH1 is known,
                                 # make_pet_dyes.py, then one smoke boot
python -m gamelab doctor --hoh1 "<dir>" --fix   # the user told you where HoH1 is
python -m gamelab doctor --no-hoh1               # the user does not own HoH1
python -m gamelab doctor --smoke                 # boot null-payload again now, whatever the stamp says
```

**HoH1: ask, never guess.** doctor finds Heroes of Hammerwatch (1) through Steam (any
library), a path the user gave earlier (`tools/paths.local.json`, gitignored), or a search
next to the HoH2 install and in every library's `steamapps/common/`. When none of that
works and nobody has answered yet, the `HoH1 install (optional)` row is `[NO]` and
says `ASK THE USER`. doctor stays NOT green until they answer, so ask them:

> Where is Heroes of Hammerwatch (1) installed (the folder with HWR.exe)? Or don't you own it?

- They give a folder: `python -m gamelab doctor --hoh1 "<folder>" --fix`. The folder must
  have `HWR.exe` and `res/assets.bin`, or nothing is recorded and doctor exits 2; ask again.
  HoH2's folder (HWR2.exe) is not it. Never pass a path they did not give you.
- They don't own it: `python -m gamelab doctor --no-hoh1`. HoH1 content is then reported
  as skipped, not failed. A later `--hoh1` undoes it.

Once HoH1 is known, `--fix` also runs bootstrap for `gamecode/sdk/hoh1/`, then
`tools/import_hoh1.py pets|levels|campaign|classes`. It runs each importer only when its
output is missing and never with `--force`, so a second `--fix` writes nothing. If
`mods/campaign/hoh1/` exists without the importer's `.hwp-generated` marker, doctor
reports it and leaves it alone. Ask the user before moving it.

- `--fix` only writes inside the repo. bootstrap copies the install's `PACKAGER.exe` to
  `tools/bin/`, patches out its Steam check, and unpacks `res/assets.bin` into
  `gamecode/sdk/hoh2/` on a hidden desktop (~1 GB, a few minutes), then exports
  `gamecode/datatables/`. Nothing is written to the install.
- That unpack is the "decompiled source". Every HoH2 binary is native C++, so ILSpy
  does not apply. The game's logic is the AngelScript in `gamecode/sdk/hoh2/scripts/`.
  The native engine API is only the strings in `gamecode/assets/hwr2_api_strings.txt`.
- No auto-fix for these; tell the user what to do:
  - **Steam not running**: start Steam.
  - **Build not pinned**: Steam updated the game. Re-pinning is a team decision
    (exit 3 row below), never a quick fix.
  - **No gcc mingw-w64 x86_64**: needed to build the capture shim. Example:
    `choco install mingw`, then a new shell.
  - **Repo on a different drive from the install**: `res/assets.bin` is hard-linked,
    so clone onto the Steam library's drive.
  - **Low disk space.**
- `--fix` also runs `tools/class_units.py` when its gitignored unit copies in
  `mods/keys/` and `mods/pets/` are missing or stale (made from `gamecode/sdk/hoh2/`).
- `--fix` runs `tools/make_pet_dyes.py` (the dye-ready pet copies in
  `mods/pets/players/pets/hwp/dye/`) last among the content steps, because it needs the
  HoH1 pet import too. Its stamp (`.hwp-generated.json`) holds the generator's and every
  source's hash, so a new HoH1 import, an edited pet unit or a changed generator marks it
  stale and the next `--fix` remakes it (`python tools/make_pet_dyes.py --verify` checks).

**Smoke boot.** Once every row it needs is green (HoH1 and content rows don't count),
`--fix` boots `null-payload` in lab mode once. It proves this machine's GPU, antivirus
and core count let GameLab work at all. A pass is stamped in `gamelab/smoke.local.json`
(gitignored) with the build, shim source, core count and GPUs; change any of those and
it boots again. A failure is reported as its plain cause, and recorded, so plain
`doctor` keeps repeating it. A failed boot often leaves the lock dirty (exit 4). The next
`--fix`/`--smoke` clears that with `python -m gamelab reset` only when the dirty
teardown is doctor's own failed smoke run; any other dirty teardown still needs you to
find out why. Pass the cause on to the user, because the fix is on their machine:

| cause doctor prints | what it means / what the user does |
|---|---|
| Windows refused to load the capture shim | antivirus/EDR blocks DLL injection: allow-list `tools/bin/hwr2_capture.dll` and the GameLab `HWR2.exe` |
| renderer did not start on the hidden desktop | no OpenGL 3.2 context: update the GPU driver, pick the dedicated GPU, avoid remote desktop |
| captured frames were blank or missing | the driver doesn't render on a non-interactive desktop (remote desktop, hybrid GPUs) |
| too slow: the deadline passed (N of M cores) | GameLab gets all cores but two at idle priority: close heavy programs; ≤4 cores is marginal |
| game window reached the real desktop | remote desktop or overlay/recording software: close it |
| game exited before writing its log | Steam not running / not the owning account, or antivirus killed it |
| changed the user's config, saves or install | stop and report: must never happen |
- The Discord mirror is out of scope.

**Saves gate.** The launcher (exit 2) and `deploy.py modded-prod` refuse until
`saves-backup/confirmed.json` exists and its backup still re-hashes. bootstrap's
datatables step boots the game through GameLab, so `--fix` confirms saves before it
bootstraps.

- **Unambiguous: `--fix` confirms by itself.** Unambiguous means all of these hold:
  - save files exist;
  - the dir the player's config writes (cloud or local) has files;
  - no other Steam account on the PC has HoH2 saves;
  - no unknown `save*` dir in the install holds files.

  In that case `--fix` does the following, then prints the restore command:
  - runs `tools/saves_selftest.py` (backup, verify and restore, on a sandbox);
  - copies the real saves to `saves-backup/<ts>/`;
  - re-hashes the copy and checks it against the real saves;
  - writes the stamp.

  Pass that restore command on to the user.
- **Anything else prints `AMBIGUOUS:` lines and stops. Ask the user.** Only they know
  whether another account's saves matter, or whether they have never saved. If they
  still want the backup as listed, run `python -m gamelab doctor --confirm-saves`
  (plus `--no-saves-yet` if they never saved). The stamp records what they overrode.

Never write the stamp by hand. Never run `saves.py restore` without the user asking:
it overwrites their real saves (it backs up the current state first).

The first scenario run on a new machine also builds the fixtures (cache is per build
and recipe), so it does two extra boots. A slow first run is normal.

## Hard rules

- `--mode lab`, always. The default is `watch`, which puts the game window on the
  user's desktop.
- Never start `HWR2.exe` directly unless the user specifically asks. Never touch the
  user's `HWR2.exe.cfg`, Steam or local saves, `%LOCALAPPDATA%/HeroesofHammerwatch2` or
  install `res/`; the launcher checks these and a change makes the run INVALID.
- No real input (`SendInput`, `keybd_event`, `mouse_event`, `SetCursorPos`,
  `SetForegroundWindow`, `bring_to_front`). Input is the `key` step (PostMessage) or
  `gl input`. Never PrintWindow: it is blank on the hidden desktop.
- One run at a time, machine-wide (one shared game dir, `gamelab/lock.py`).

## Running and exit codes

```
python -m gamelab list
python -m gamelab run <scenario> --mode lab
```

| exit | verdict | do |
|---|---|---|
| 0 | PASS | |
| 1 | FAIL | a result, not a refusal: read `run.json` assertions and `error` |
| 2 | preflight | read the failed preflight assertion. `saves: ... not confirmed` means run the doctor and the saves gate above |
| 3 | build changed | `python tools/pin_build.py --show`, then `python tools/pin_build.py --reason "<why>"`, then `python tools/bootstrap.py --force` (the dumps are stale). `--accept-build-drift` overrides for one run and stamps it `build_drift` |
| 4 | lock / dirty teardown | read the `REFUSED` line. "another GameLab run holds the lock": another agent is running, wait. Stale lock or dirty teardown: find the cause in the last run's `run.json` `teardown`, then `python -m gamelab reset` |
| 5 | INVALID | the run can't be trusted: user config, saves or `res/` changed, focus left the user's window, or only `shot ...` assertions failed (the frame disagrees with probes that passed) |
| 6 | TIMEOUT | what was collected is kept |

Results in `gamelab/results/<YYYYmmdd-HHMMSS>-<scenario>-lab/`:
- `run.json`: verdict, assertions, `error`, `teardown`.
- `runner.out.txt`: runner stdout and traceback.
- `gl.jsonl`: telemetry.
- `logs/pass<N>.HWR2.exe.log`: game log; the scenario is the last pass.
- `shots/*.png`: Read them; never describe one unread.
- `boundaries.md`: when the scenario has `boundaries`.

Cite a result as `<scenario> <YYYYmmdd-HHMMSS>`.

## Scenario file (`gamelab/scenarios/<name>.json`)

```json
{"name": "mod-x", "about": "what this proves", "fixture": "town-paladin",
 "mods": ["core", "x"], "timeout": 120,
 "steps": [
  {"do": "log_has", "pattern": "\\[HWP:x\\] self-check done", "timeout": 20},
  {"do": "gl", "verb": "state", "expect": {"phase": "town", "player.level": {"between": [1, 5]}}},
  {"do": "shot", "name": "town"},
  {"do": "log_clean"}]}
```

- Top-level keys:
  - `name`, `about`, `fixture`, `steps`.
  - `mods`: `mods/` folder ids, enabled on top of the fixture's; the enabled set is asserted exactly.
  - `timeout` (default 300): the step budget; the whole run gets 3x, to cover fixture builds.
  - `boundaries`, `probe_menu` (below).
  - `explore: true`: the only way an `exit` writes new edges to `gamelab/travel/learned.json`.
- `expect` is `{dotted.path: value}` against the reply, or `{"between": [lo, hi]}`.
- `save_as` names a reply for `assert_more`, `assert_dist`, `loot_check` and `boundaries`.
- Templates: `mod-fishing.json` (mod smoke test), `pilot-floor.json` (bot, shots, `shot_changed`).

## Step kinds (`do`)

| step | fields | what |
|---|---|---|
| `gl` | `verb`, `args`, `expect`, `save_as` | one in-engine command |
| `wait_phase` | `phase`, `timeout` | wait for `town` / `mission` / ... |
| `pilot` | `call`, `args`, `until`, `timeout`, `expect` | one Pilot intent |
| `bot` | `bot`, `kwargs`, `expect` | run `gamelab/bots/<bot>.py` |
| `shot` | `name` | a real frame at the profile resolution; an `end` shot is automatic |
| `shot_changed` / `shot_diff` / `shot_tint` | `before`, `after`, ... | pixels must agree with what the probes say |
| `log_has` / `log_lacks` | `pattern`, `timeout` | regex in this pass's game log |
| `log_clean` | | no script errors in our mods' files |
| `overlays` | `allow` | nothing unexpected drawn over the world |
| `assert_more` | `than`, `now`, `path` | the values under `path` grew |
| `assert_dist` | `a`, `b`, `path`, `min`, `max` | distance between two saved `{x, y}` |
| `loot_check` | `than`, `now`, `file`, `entry` | the gain is one the loot table can produce |
| `restart` | | quit (the game saves) and re-enter the fixture |
| `write_mod_file` / `write_bot_file` | `mod`/`path`, `replace`, `with` | edit a file mid-run, restored at the end |
| `same_process` | `mark` / `since` | assert no restart in between |
| `sval` | `file`, `dest` | export a datatable as the game parsed it |
| `key`, `console`, `sleep`, `minimize` | | posted key, raw console line, wait, minimize |

## Fixtures (`gamelab/fixtures/`)

- `town-paladin`: level 1, in town.
- `town-tavern`: town-paladin plus a built tavern.
- `mission-ranger`: level 20 full build, for combat floors.

Recipe keys: `slot` (0), `binary_edits.enable_mods`, `character`, `setup` (gl verbs),
`save_town`, `readback`, `readback_probes`. Only `readback` and `readback_probes` are
checked, so give every `setup` effect a probe. A fixture is cached per build and recipe
hash; the first run after a change does two extra boots.

## gl verbs

48 verbs across the three gamelab-* mods: `docs/generated/verbs.md`, or `gl help` at runtime.

- Read: `state`, `scan`, `near`, `usables`, `ui`, `overlays`, `widgets`, `inv`,
  `buildings`, `cvars`, `mods`, `clock`, `terrain`, `pathfind`, `reachmap`.
- Read the game's own data:
  - `inspect player|town <dotted.path>`: the save record.
  - `sval <file>`: a datatable as parsed.
  - `members <Type>`: script reflection.
- Act through the game's own code path: `mission`, `build`, `equip`, `xp`, `material`,
  `upgrade`, `assign`, `charflag`, `spawn`, `save`, `pick`, `char`, `input`.
- `multi a + b + c` runs many verbs in one frame.

## Measurement-only verbs

`teleport`, `cull` and `timescale` measure engine facts. A scenario that uses them is
not evidence of play. `timescale` speeds up timers but not per-frame movement.

## Pilot intents and bots

- Intents run in-engine until done or interrupted:
  - `move`, `path_to`, `attack`, `kite`, `use`, `potion`, `wait`, `exit`.
  - `travel <place>`, through the travel graph; an edge the graph doesn't know gives `no_route`.
- Results: `done`, `failed`, `timeout`, `interrupted`, `no_route`.
- `until=` is a closed vocabulary; anything else raises ValueError:
  `hp_below:N`, `under_attack`, `target_dead`, `level_changed`, `menu_open`, `dead`.
- `reflex(potion=<hp%>, fire=<radius>)` sets standing orders the engine runs itself.
  A Python round trip is too slow to survive a swarm.
- A bot is `gamelab/bots/<name>.py` defining `run(pilot, **kwargs) -> dict`; the step's
  `kwargs` are passed in. Client API: `gamelab/pilot.py`.

## Editing files mid-run

- `write_bot_file` edits a bot, and the next `bot` step runs the new code: bots are
  reloaded from disk on every call. `same_process` asserts no restart happened in between.
- `write_mod_file` (gamelab-* mods only) edits a script, but a level load does not
  recompile it. Only `restart` does (reload-mark 20261017-144040).

## Boundary assertions

Top-level `boundaries: [{"name", "before", "after", "survives": [...], "changes": [...]}]`.
- `before` and `after` are `save_as` names, or `menu` (needs `"probe_menu": true`).
- `"p|q"` reads path p before and path q after.
- The rows are checked after the steps run and written to `boundaries.md`.
- Pair with `{"do": "restart"}` for save to load, or a `mission` step for a level load.

## Adding a verb

1. Register it:
   - A read-only verb goes in `mods/gamelab-probe/scripts/GameLab/Probe.as`. It must be
     capped and report truncation.
   - A verb that acts goes in `mods/gamelab-hands/scripts/GameLab/Hands.as`, and its doc
     comment cites the game function it mirrors.
   - Pilot verbs go in `mods/gamelab-pilot/scripts/GameLab/Pilot.as`.
2. Then run `python tools/list_verbs.py`; `--check` fails while `docs/generated/verbs.md` is stale.
