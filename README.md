# HammerwatchPlus

A modular co-op mod for **Heroes of Hammerwatch II**, and **GameLab**, the harness that
boots the game hidden and muted, drives it through its own scripts, and scores what
happened. The project follows the game-modding playbook (P0–P8 below). GameLab
supersedes the old `dev_check` / `dev_link` / `extract_base` tooling.

## Status (2026-10-17, evening)

- **Measured and green:** GameLab runs entirely on a hidden desktop.
  - A sampler checks the foreground window every 50 ms; focus never changed in any run.
  - The user's config, saves and install `res/` are asserted unchanged after every run.
  - Reference scenarios: `null-payload`, `open-chest` (spawn a chest, press Use, the
    materials go up) and `open-chest-minimized`.
- **Datatables:** all 326 `.sval` files exported as the game parses them (`gamecode/datatables/`).
- **Mod load checks:** `gamelab/scenarios/mod-<id>.json`, one per mod, replace `dev_check`. All 27 pass (2026-10-17 19:49-19:55, 20261017-194937 … -195451, about 11 s each). The six that failed earlier today (campaign, maps, weapons, wavemode, gambler, laststats) now pass. Their log lines (for example `[HWP:laststats] spawned the notice board`) were checked in run.json; which change fixed them was not traced.
- **Pilot (P6b), paused** to walk through with the user. `floor_runner` takes a
  dark_citadel floor's exit unattended in lab mode, some of the time.
  - Passing runs: pilot-floor 20261017-191951, and floor-soak 20261017-193859 at 3 of 4.
  - Latest runs: pilot-floor 20261017-193337 FAIL (stuck 118 units from the exit until the
    budget ran out), then 20261017-194552 PASS (107 s) after the debris-first change.
  - Working: the travel graph (`Pilot.travel`), hot-swapping the bot script without a restart
    (`pilot-revision`), engine overlays from the console (`watch-overlays`), and every gl verb
    listed in `docs/verbs.md`.
- **Speed:** a console line takes 291 ms, against 770 ms before. Fixture readback is one
  batched line (~0.5 s, was ~15 s); boot to ready is about 10 s.
- **Open:**
  - **Floor reliability** (P6b, paused). Floor-soak passes 1-3 of 4 floors per run.
    - Some mid-floor nav cuts are breakable debris. The bot now smashes it, and the ranger
      verifiably breaks `castle_debris_pile_wood` (floor-soak 20261017-193859).
    - Other cuts, "stuck" stops near the exit and deaths in swarms remain.
    - Level generation is unseeded, so layouts vary run to run.
  - Watch mode has never run: it needs the user's go-ahead to show a window.
  - The intake defaults are unconfirmed. Multiplayer is out of scope for now.
  - Loot RNG is unseeded.
  - Findings: `docs/RE_NOTES.md`. Logs, paths and the mod stack: `docs/MODDING_NOTES.md`.

## Key facts

| | |
|---|---|
| Game | Heroes of Hammerwatch II, Steam app `619820` |
| Pinned build | Steam build `25509441`; the log reports `Build 170` (`gamelab/build_id.json`) |
| Engine | Crackshell C++ (bgfx OpenGL 3.2, SDL2 2.30.7, FMOD 2.2.11) + AngelScript |
| Anti-cheat | None |
| Mods | The game's own resource mods: unpacked `mods/<id>/` or packed `.bin`, enabled per save |
| `saves-backup/` cap | **200 MB** for the directory. `tools/saves.py backup` refuses past it (exit 4) and the user prunes. |

## Developing

Needs Python 3.10+ with [uv](https://docs.astral.sh/uv/) and HoH2 installed (also HoH1
for the HoH1 importer).

```
uv sync
python tools/bootstrap.py --verify                 # first thing on a new clone; without --verify it regenerates gamecode/ + tools/bin/
python -m gamelab list                             # scenarios
python -m gamelab run open-chest --mode lab        # hidden, muted, isolated; programmatic runs always --mode lab
python -m gamelab run <scenario>                   # watch mode: visible, for a human
python -m gamelab reset                            # after a refused run (lock / dirty teardown)
python tools/saves.py backup                       # also part of every GameLab preflight
python tools/pin_build.py --show                   # live build vs pin; GameLab exits 3 on mismatch
python tools/export_datatables.py                  # gamecode/datatables/: every .sval, parsed by the game
python tools/build.py                              # pack dist/HWP-<module>.bin + dist/HammerwatchPlus-All.bin
python tools/hwr_archive.py --help                 # HW2R/HWRR archives (docs/archive-format.md)
python tools/patch_packager.py                     # Steam-free PACKAGER.exe into tools/bin/ (docs/packager.md)
python tools/import_hoh1.py pets|levels|campaign   # HoH1 content from your own HoH1 install (never committed)
```

- **Isolation.** GameLab never touches the real keyboard, mouse, focus, config or saves.
  It runs a copy of the game in `gamelab/env/userdata/game/` (`gamelab/env/environments.json`).
- **Mod probes.** The GameLab mods are `mods/gamelab-probe` (state, JSON telemetry),
  `mods/gamelab-hands` (spawn, pick, mission) and `mods/gamelab-pilot`.
- **Imported HoH1 content.** HoH1 assets are never committed. `import_hoh1.py` writes into
  gitignored `hoh1_import/`, and `build.py` leaves them out unless `--with-local`.

## Modules

| Module | What it does |
|---|---|
| `core` | Shared library: settings, save-data extension, networking helper, pet pickup logic. Required by every other module. |
| `gambler` | Higher/Lower card game NPC in the tavern; buys your fish, crops and herbs (Sell button); rerolls equipped gear for 2000 gold x item level. |
| `droptrade` | Drop equipment on the ground for friends: a Drop button / Q key next to Destroy in the inventory. |
| `goldpet` | Pet Vendor in the Hunter's Cabin selling a gold-collecting cat. |
| `laststats` | Last run's stats for the whole party on a notice board by the town fountain. |
| `deathrecap` | Who killed you: top damage sources from the last 10 s, on screen and in chat. |
| `bufftips` | Hover a buff icon to see what it does and how many seconds it has left. |
| `legacy` | HoH1-style class legacy: your best hero of each class buffs every character; one "Title Bonuses" buff lists them, Guild Hall > Titles shows every class. |
| `pets` | Pets level up (kills, pickups, farm crops at the feeding bowl) and learn utility skills; per-pet pickup toggles; all Heroes of Hammerwatch 1 pets in the Pet Shop (imported from your own HoH1 install); pets wait outside puzzle rooms. |
| `architect` | Any player can pick and pay for Architect alterations; the host's picks are split across the party. |
| `chatlinks` | Linked items stay in chat with slot and item level; `hwp link`. |
| `colors` | Colour-blind / high-contrast tints for enemy and friendly projectiles (Options > Game > projectile colors). |
| `groupcombo` | Party-wide combo bonus that scales with how many players are in combo; brief invulnerability when everyone is. |
| `weaponswap` | A second weapon set on a hotkey (default X). |
| `keys` | HoH1-style locked and ace chests, key drops, the General Merchant, seven red legendaries. |
| `firearms` | The Firearms Specialist class: mana is ammo, reload, grenades; Sniper / Demolitions / Assault doctrines. |
| `fishing` | A fishing spot in town (timing minigame, catch sells at the Gambler) and rare fishing holes at the start of runs that pay loot. |
| `farming` | Farm plots in town: food crops and four Holy Herb strains that grow per completed run; smoke a herb for a next-run buff. |
| `weapons` | Twelve new weapons (ilvl 35, all slots/classes) with fresh modifier profiles on the vanilla visuals and skills. |
| `strongbox` | PoE-style strongboxes: open one, a biome-correct pack (elites possible) spawns, clear it for the box's loot. |
| `abyss` | Abyss cracks: step close and waves crawl out, ending in an elite; clear them for a reward and the crack closes. |
| `maps` | Three new layouts for the equipment map drops: Goblin Warrens, Sunken Dungeon, The High Court. |
| `summons` | Priest Crusaders (and optionally all summons) persist through the loading screen between floors. |
| `campaign` | The Forsaken Tower: the HoH1 campaign (Mines to Battlements, 18 floors, 6 bosses) started from a portal in town. With HoH1 installed, a second version plays the real HoH1 boss rooms and Battlements (`tools/import_hoh1.py campaign`). |
| `wavemode` | Wave Arena: a survival arena started from a statue in town; boss kills raise your arena rank. |
| `classes` | The HoH1 classes HoH2 lacks: Thief, Gladiator, Witch Hunter, three masteries each. |

## Installing (players)

1. Download the `.bin` files you want from Releases (or `HammerwatchPlus-All.bin`).
2. Drop them into `<Steam>/steamapps/common/Heroes of Hammerwatch 2/mods/`.
3. Start the game, open **Resource Mods** and enable them. Everyone in the lobby does the same.
4. In game, open the console (the key left of 1) and type `hwp help` for the commands and settings.

Workshop uploads will follow once the modules stabilise.

## Pilot intake (P6b)

| Capability | Answer |
|---|---|
| Combat verb: kite vs stand and fight | kite (default, unconfirmed) |
| Threat / aggro-radius avoidance | **out** (user, 2026-10-17) |
| Cross-level travel | in (default, unconfirmed) |
| Consumable use with thresholds | in (default, unconfirmed) |
| Looting and inventory management | later (default) |
| Networked multiplayer | yes: HoH2 has online co-op; **out of scope for now** (user, 2026-10-17) |
| Watch-mode overlays | in (default). The engine's own draws, typed at the console: `r_draw_nav_data 1` (the nav data the Pilot plans on), `r_draw_physics 1` (collision shapes), plus `r_draw_pathfinds`, `r_draw_raycasts`, `r_draw_physics_queries`, `r_draw_ranges` (names from the exe's string table, `gamecode/assets/hwr2_api_strings.txt`) |
| Time-scale acceleration | later (default). Also **measured unusable**: `g_timescale` scales game-ms timers but not movement per frame (floor-soak 20261017-175501), so N× results are not 1× results |

Only the avoidance and multiplayer answers came from the user; the other rows are the
playbook defaults, recorded but not confirmed. Reply "defaults" to confirm them.

## Phase checklist

### P0 — Scaffold
- [x] Repo created, standard layout, `git init`
- [x] `.gitignore`: `gamecode/`, `.screenshots/`, `gamelab/results/`,
      `gamelab/env/userdata/`, `gamelab/fixtures/cache/`, `gamelab/manifest.local.json`,
      `tools/bin/`, big mirrors under `docs/community/`
- [x] `README.md` with this checklist pasted in, and the `saves-backup/` size cap
- [ ] `tools/bootstrap.py`: required tier regenerates from the install (build-id checked),
      optional `--with-community` tier downloads from the shared folder in `docs/SOURCES.md`,
      `--verify` against `gamelab/manifest.json`
      *(not ticked: the required tier and `--verify` are done. `gamelab/manifest.json` is
      recorded (44 groups); `--verify` is green, goes red on a one-byte datatable change and
      green again once it is restored (2026-10-17). `--with-community` is implemented, but the user chose on 2026-10-17 to skip the optional
      tier: no cloud folder. The Discord mirror stays in `docs/community/discord/` (gitignored) and is not uploaded. With no folder there is
      nothing to download, so the clause stays unmet.)*
- [x] `tools/hidden_desktop.py` vendored and importable after bootstrap
- [x] `saves.py backup` refuses past the declared cap
- [ ] Second-machine gate: a fresh clone + `bootstrap.py --verify` green on a collaborator's
      machine (required tier identical; optional tier identical where present)
      *(not ticked: needs a collaborator's machine (Ryan's) and a commit to clone. Nothing on
      this machine can stand in for it.)*

### P1 — Recon
- [x] Install located; app id + build id + game version in `docs/RE_NOTES.md`
- [x] Every game/loader log path found and recorded in `docs/MODDING_NOTES.md`
- [x] Anti-cheat checked; finding + consequence recorded in `docs/RE_NOTES.md`
- [x] Engine **and engine version** identified

### P2 — Modding support survey
- [x] Official docs mirrored to `docs/official/`
      *(`docs/official/hoh2doc/`: Crackshell's Doxygen script reference. The site now redirects
      to team17.com, so these are the 60 files the Wayback Machine holds (partial, stated in
      `docs/SOURCES.md`). `tools/mirror_docs.py official`.)*
- [x] Community wiki/tool docs + reference mod source mirrored to `docs/community/`
      (originating machine; collaborators without the optional tier are not in violation)
      *(`docs/community/wiki/` (HoH2 wiki modding pages, MediaWiki source),
      `docs/community/reference-mods/` (installed Workshop mod, extracted),
      `docs/community/discord/` (gitignored, HoH2 channels). `tools/mirror_docs.py`.)*
- [ ] `docs/SOURCES.md` has a dated row per mirror, and names the shared folder for
      every gitignored mirror
      *(not ticked: every mirror has a dated row. The one gitignored mirror (Discord) names no
      shared folder, because the user skipped the optional tier on 2026-10-17. SOURCES.md says
      so.)*
- [x] Mod stack chosen and written up in `docs/MODDING_NOTES.md`

### P3 — Extract & decompile
- [x] Code decompiled/dumped into `gamecode/sdk/`
- [x] Data tables exported to `gamecode/datatables/` (JSON/CSV)
- [x] Engine's accessibility profile written into the **global** playbook's Per-engine notes
- [x] First modded launch: saves backed up, injection confirmed **from loader log
      markers**, window topology recorded

### P4 — Eyes
- [x] `game-screenshot` skill captures to `.screenshots/` and reads the image back
      *(`.claude/skills/game-screenshot/SKILL.md` → `tools/game_screenshot.py`: run
      20261017-144810 wrote `.screenshots/20261017-144810-screenshot-lab-view.png`, read back:
      paladin at the town entrance, `intro_move` tutorial, HUD)*
- [x] Capture verified passive: correct image while occluded and unfocused
      *(`capture-passive` 20261017-144729: hidden desktop (no game-tree window on the input
      desktop), foreground never the game. Frames at the profile's 640×360, and a chest
      spawned at the player's feet changes 19 px in the centre box vs 1 px elsewhere after
      denoising)*

### P5 — Brain
- [x] `MECHANICS.md` covers progression, loot, movement tech, economy, gameplay loops,
      UI interaction model, inventory/logistics, run-state variables  *(`docs/MECHANICS.md` §1-8)*
- [x] Run-state variables: every variable names the function or data path that sets it
      *(`docs/MECHANICS.md` §8: every `PlayerRecord.Save` key with its setter and run reset)*
- [x] Every claim cites a decompiled source or a probe run
      *(`python tools/cite_check.py`: 125 cited lines, 0 bad; run ids for the measured rows)*
- [x] No open items left standing as guesses
      *(the "Open items" section lists only what is not covered yet, labelled as such)*

### P6 — Hands: GameLab  *(one box per architecture component)*
- [x] **1 Launcher** — lab mode windowed, low graphics, fixed small res; intros skipped;
      focus-free in every mode; runs the 4-step preflight and aborts on any failure;
      lab mode asserts the live game process is in the launcher's job tree
      *(evidence: lab mode in every run (job tree `in_job`, preflight, 640x360 low profile,
      intros off, foreground sampled at 50 ms with no unexplained switch): null-payload lab
      20261017-201253, open-chest lab 20261017-201305, both PASS. Watch mode is focus-free
      since the fix in 1′: null-payload watch 20261017-201214 and -201234 PASS, with zero
      foreground switches for the whole run.)*
- [x] **1′ Two modes** — `--mode watch` (human default: visible, foreground sampled from
      launch to first frame never belongs to the game tree) and `--mode lab` (hidden
      desktop, muted; no game-tree window on the input desktop, foreground never the
      game tree for the whole run, mute confirmed in loaded settings, `PrintWindow`
      capture of the hidden window correct); programmatic runners always pass `--mode lab`
      *(evidence: watch-mode null-payload 20261017-201214 and 20261017-201234 PASS back to
      back. The gate held, every switch list was empty, and the game window was shown
      `SW_SHOWNOACTIVATE` per the shim log. Lab regressions null-payload 20261017-201253 and
      open-chest 20261017-201305 PASS.
      - Fix: until the first frame the window is `WS_EX_NOACTIVATE` and has no taskbar button,
        and SDL's activating calls are refused while another process owns the foreground.
        Cause and runs: `docs/RE_NOTES.md` "watch-mode focus".
      - Assumed, not measured: a real human click on the loading window no longer activates
        it. That is the documented `WS_EX_NOACTIVATE` behaviour, but no click has been tested,
        because GameLab sends no real input. It needs a human-in-the-loop watch run.)*
- [x] **2 Command channel** — drives the running game, front door included
- [x] **3 Scenario system** — `gamelab/scenarios/` + declarative fixture **recipes**
      (`fixtures/<name>.json`), every field read back through the probes, cache keyed by
      build id, generic across the game's modes
      *(evidence: `town-paladin` / `town-tavern` recipes, `readback` + `readback_probes`
      fail the run on any mismatch, cache `<name>.<build>.<sha8(recipe)>`; town modes in
      `probes-5a` 20261017-141949, mission mode in `mission-enter` 20261017-140945)*
- [x] **4 Instrumentation** — mod emits JSON-lines telemetry
- [x] **5a Observer: state probes** — vitals/position, inventory, nearby entities, clock,
      **UI widget tree**, terrain grid
      *(evidence: `probes-5a` 20261017-141949: `state`, `inv`, `near`, `clock` advancing,
      `widgets` bounded by depth, `terrain` 21×21 and capped at 48)*
- [x] **5a′ Reflective inspector** — dotted-path resolve + `members`; read-only by
      allowlist, bounded by depth/caps/budget, reports truncation
      *(evidence: `probes-5a` 20261017-141949: `inspect player level` = 1, whole record
      truncated to keys at 4000 chars, `inspect town buildings` = the fixture's tavern,
      missing path and non-allowlisted root fail cleanly; `members PlayerRecord`, capped at 200)*
- [x] **5b Observer: screenshots + log tailing** — fired at key moments
- [x] **6 Scoring** — assertions + metrics into `gamelab/results/`, probe-vs-screenshot
      agreement asserted, disagreement reported `INVALID`
- [x] **7 Game settings** — `gamelab/env/settings/lab/` (muted) and `settings/watch/`
      profiles, links declared, `env_link.py --verify` green, all three preflight
      assertions passing for the mode in use
- [x] **8 Programmatic hands** — emulated click/press API, proven by a scenario run with
      the window minimized while the user typed elsewhere
- [x] **9 Isolation** — `environments.json` declares all three envs; redirect verified on
      the live process; per-test teardown enforced
- [x] **Build-id gate** — `gamelab/build_id.json` pinned; runner exits `3` on mismatch
- [x] **Smoke scenario green** — *simple interaction* (open a container, loot it) passes
      end to end

### P6b — Pilot: the player bot  *(boxes for capabilities the intake marked out/later are ticked "N/A per intake")*
- [ ] Intake interview answered in the README (or "defaults" accepted), before any Pilot code
      *(not ticked: the table above is recorded, but only two rows are the user's
      (avoidance out; multiplayer out of scope for now). The rest are playbook defaults the
      user has not confirmed. One word from the user, "defaults", ticks it.)*
- [x] `mods/gamelab-pilot` builds on `gamelab-hands`: verbs, closed interrupt vocabulary,
      control surface (pause / step / target override), telemetry — every verb in-engine
      and focus-free; any verb unreachable in-engine is a dated `RE_NOTES.md` entry
      *(The verbs are move, path_to, attack, kite, use, potion, exit and wait, plus the
      reflexes; the interrupts are hp_below, under_attack, target_dead, level_changed,
      menu_open and dead; telemetry is `ptick` and `pilot` events.
      - pilot-selftest 20261017-185357: pause holds, step advances, target is refused when
        idle, stop, an unknown interrupt is refused by both client and mod, and path_to,
        no_route and timeout come back as results.
      - Every run is focus-free (foreground sampled at 50 ms).
      - No verb needed real input, so there is no RE_NOTES entry for one.)*
- [x] Eyes: semantic `scan()` from unit data, raw list underneath, each category names
      its source field
      *(`scan` returns its categories plus a `sources` object naming the field behind each:
      - enemies: `Actor.Team` != player;
      - usables: `IUsable` behaviour and `CanUse`;
      - exits: `LevelExitAreaNext` world scripts;
      - raw: `FetchAllUnits`, capped.

      Allies and loot are not separate categories: loot is "later" per intake, and allies
      are a multiplayer concern. The probe agreed with the place on both floors in
      pilot-floor 20261017-191951.)*
- [x] Travel: in-level `path_to` on the engine pathfinder; `gamelab/travel/authored.json`
      + `learned.json`; `no_route` is a returned result; a new transition taken in an
      exploration run appears in `learned.json`; scenario results pin the graph revision
      *(Evidence by run:
      - pilot-explore 20261017-191702 (`"explore": true`): forest_1 -> forest_2 was absent
        and is now in learned.json with that run id (`new_edge`, `learned` true; graph
        1511afe5 -> 199da2bc).
      - Scenario runs do not write: pilot-crosslevel 20261017-191834 has `learned: false`.
      - An unknown transition is `no_route` at once, never a wander: pilot-crosslevel
        20261017-190905, "no known transition ... (travel graph 1511afe5)", 19 s.
      - `run.json` carries `travel_revision`.)*
- [x] Intake capabilities marked in — avoidance, cross-level, consumables, time-scale —
      each passes its gate from the intake table (or N/A per intake)
      *(Per capability:
      - avoidance: N/A per intake (out).
      - cross-level: `Pilot.travel(place, x, y)`, i.e. path_to(level, point), takes
        forest_1 -> forest_2 in pilot-crosslevel 20261017-191834 and pilot-floor
        20261017-191951.
      - consumables: pilot-consumables 20261017-185454; `hp_below:80` interrupts a wait,
        then the potion intent drinks.
      - time-scale: N/A per intake (later); also measured invalid, see the intake table.)*
- [x] Python client: blocking verbs, `until=` from the closed vocabulary (unknown
      interrupts rejected), results `done / failed / timeout / interrupted / no_route`;
      a script revision needs no game restart
      *(pilot-selftest 20261017-185357 covers the vocabulary and the results. pilot-revision
      20261017-184206 covers the restart: town_step walked east, `write_bot_file` changed
      its STEP, and the next run walked south in the same pid and pass.)*
- [x] Full-build fixture recipe over the MECHANICS.md run-state schema; every field read
      back or the run fails; cache keyed by build id
      *(`gamelab/fixtures/mission-ranger.json`; fixture-ranger 20261017-185517 reads every
      field back, 15 probes in one batched console line.)*
- [x] First bot (`gamelab/bots/`): one named MECHANICS.md gameplay loop, using the
      intake's combat verb if the loop has combat, reaches its terminal telemetry event
      unattended in **lab mode**
      *(`floor_runner`: the "Next floor" step of the gameplay loop, with kite as the combat
      verb. It reaches `bot_terminal` with `next_floor` in pilot-floor 20261017-191951.
      Reliability is open: floor-soak passes 1-3 of 4 floors per run (see Status).
      It reached `next_floor` unattended again in pilot-floor 20261017-194552 (107 s). The box asks
      for the terminal event, not reliability. Reliability work is paused for a walkthrough with the
      user. Example failure: 20261017-193337, stuck by the exit until the budget ran out.)*
- [ ] Watch-mode feedback loop recorded once: user watched, feedback cites a telemetry
      tick, agent revised, no restart
      *(not ticked: it needs the user to watch. The parts are ready:
      - watch mode (`python -m gamelab run pilot-floor`);
      - ticks in `ptick`;
      - restart-free revision, proven by pilot-revision;
      - the engine overlays, `e_cheats 1` then `r_draw_nav_data 1` (watch-overlays).)*
- [ ] Promoted scenario: same script + assertions, green in lab mode, hidden and muted,
      telemetry and screenshots agreeing
      *(`gamelab/scenarios/pilot-floor.json` is floor_runner plus four assertions: next
      floor, alive, under 120 s, at most 6 exit attempts.
      - Runs: 20261017-184221 PASS; 20261017-191951 PASS, travelling through the graph.
      - Hidden and muted: the foreground never changed; the lab profile loaded with
        `snd_volume 0`.
      - Telemetry and screenshots agree: both floor frames are real 640x360 frames, and
        `shot_changed` is 80%, where the bar is 40%. That bar is calibrated on 41 runs:
        68-82% when the floor changed, 9-14% when it did not. A disagreement makes the run
        INVALID.
      **Unticked:** 20261017-193337 failed and 194552 passed; the scenario is not reliably green.
      P6b is paused to walk through with the user.)*
- [ ] Multiplayer: local-sessions scenario green; networked scenario green across two
      machines when the intake says the game has multiplayer; tier recorded in results
      *(not ticked: the user put multiplayer out of scope for now ("all checks except
      multiplayer"), and the networked tier needs two machines.)*

### P7 — Dev loop
- [x] `tools/deploy.py` working, env-targeted, reload trigger documented honestly
      *(gamelab target creates and verifies junctions. modded-prod builds `dist/HWP-<id>.bin` and
      copies it to `<install>/mods`; it was exercised `--dry-run` plus a real `build.py`,
      because a real copy writes into the player's install. Undeclared, forbidden and vanilla
      targets are refused. Reload trigger **measured** by `reload-mark` 20261017-144317: a level
      load does not pick up an edited script, a restart does.)*
- [x] `tools/saves.py backup` in launcher preflight; `restore` exercised
      *(preflight step 1 in `gamelab/launcher.py`. `restore` exercised by
      `tools/saves_selftest.py` on a sandbox (never the real saves): backup, verify red after
      an edit, restore, bytes back, stray file removed, pre-restore backup taken, cap
      refusal. The test caught `restore` verifying against the wrong backup, now fixed.)*
- [x] `tools/env_link.py` and `tools/pin_build.py` working
      *(`env_link.py --verify` green; `pin_build.py --show` matches the pin; both run in
      every preflight, and exit 3 on drift was proven earlier)*
- [ ] Shared-state rule: every mod change touching shared state names its networked
      scenario, green before the change is called done
      *(not ticked: the networked tier is multiplayer, which the user put out of scope for
      now. It needs two machines.)*
- [x] Full loop run end-to-end: edit → deploy → scenario → results + screenshots → refine
      *(gambler, 2026-10-17. The edit made the spawn check the produced unit and log its
      id; `deploy.py gamelab core gambler`; `mod-gambler` now also asks `near` for the NPC.
      Run 20261017-144446 FAILED: the NPC was at (-66,-159), not its spawn point, because
      its `idle_tavern` movement walks it. The screenshot showed the town entrance, 2185
      units away. Refined to a tavern-area assertion (new `between` matcher); run
      20261017-144525 PASS.)*
- [x] Session close ritual: `docs/RE_NOTES.md` updated, README status refreshed
      *(2026-10-17 evening: RE_NOTES "breakables, travel, death"; Status above.)*

### P8 — Handoff  *(the last deliverable)*
- [ ] This document is pasted into `docs/PLAYBOOK.md`, and every
      deliverable box in this checklist is marked with a checkmark or "N/A per intake"
      (P6b only). Only stop once every deliverable has one, then finally checkmark this
      last task.
      *(not ticked: the copy is done. `docs/PLAYBOOK.md` is the playbook verbatim, 1997 lines.
      But not every box has a mark, and each open box has its reason written beside it:
      - **Needs the user:** the intake ("defaults") and the watch-mode feedback loop (P6/P6b).
      - **Out of scope for now:** multiplayer and the shared-state rule.

      Ticking this box would claim otherwise.)*

## License

MIT. Game assets belong to Crackshell.
