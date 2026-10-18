# RE notes: Heroes of Hammerwatch II

Dated findings log. Each entry says how it was measured; "assumed" marks anything not yet
measured. Newest entries at the bottom of each date.

NOTE: PATHS/ENV SPECIFIC NOTES ONLY APPLY TO A SINGLE DEVELOPERS SETUP, OTHER DEVS MAY HAVE
DIFFERENT SETUPS OR INSTALL LOCATIONS.

## 2026-10-17: recon (P1)

**Install.** `C:\Program Files (x86)\Steam\steamapps\common\Heroes of Hammerwatch 2`
(found through the Steam registry key and `libraryfolders.vdf`; `tools/gamepaths.py`).

**Ids and version.** Steam app id `619820`. Build id `25509441`
(`steamapps/appmanifest_619820.acf::buildid`). The game logs
`Build 170: ARCH_64 USING_STEAM RELEASE FINAL` as its second line (`HWR2.exe.log`), and the
window title is `Heroes of Hammerwatch II - B170`. `HWR2.exe` sha256 `6ddd9e7d8fe3…`,
PE timestamp 1790265044. Pinned in `gamelab/build_id.json`; `tools/pin_build.py --show`
compares live to pin, and every GameLab launch refuses with exit 3 on mismatch.

**Engine.** Crackshell's own C++ engine: `HWR2.exe`, `PACKAGER.exe`, `EDITOR.exe`,
`HWR2Toolkit.exe`, all game content in `res/assets.bin`, AngelScript game scripts inside the
archive (extracted to `gamecode/sdk/hoh2/scripts/`). Libraries by file version: SDL2
2.30.7, FMOD / FMOD Studio 2.2.11 (build 130436), steam_api64 1.0.0.1, ozz-animation,
libde265, TinyTIFF. Renderer from the log: `Starting BGFX renderer OpenGL 3.2`.

**Anti-cheat.** None. No `EasyAntiCheat/`, `BattlEye/` or other anti-cheat directory or
launcher wrapper in the install; the only third-party runtime is `steam_api64.dll`.
Consequence: in-process DLL injection is usable (GameLab injects
`tools/bin/hwr2_capture.dll`, below), and scripted mods are the game's own supported path.

**Logs.** `<exe dir>/HWR2.exe.log`, rotated into `<exe dir>/logs/HWR2.exe_<date>_<time>.log`
at the next start. Crash dumps: `<exe dir>/HWR2_<build>_crash_<date>_T<time>__<n>.mdmp`.
Script `print()` goes to the same log.

## 2026-10-17: isolation (P6 item 9)

All measured with copies of the game run from a scratch directory, the user's saves backed
up first (`tools/saves.py backup`) and compared after every run.

- **The exe's directory is the user-data root.** HWR2.exe reads `HWR2.exe.cfg`, writes
  `HWR2.exe.log`, and keeps local saves in `saves/` next to the exe it was started from,
  not the working directory and not the install. A copy of `HWR2.exe` and its DLLs in
  another directory, with the install's `res/` linked in, runs as a fully separate
  install. The log line `Launch options: 1: <exe path>` names the exe that ran.
  First probe, launched from the install exe with a different cwd: it read the install's
  cfg and overwrote the install's `HWR2.exe.log` (no save writes, checked by mtime).
- **Launching the exe directly does not relaunch through Steam.** The game stays a direct
  child of the launcher (Steam already running), so the hidden desktop and job object reach it.
- **`g_save_slot_cloud 0`** keeps saves off Steam Remote Storage. The real cloud saves are
  `Steam\userdata\<account>\619820\remote\saves\`.
- **Save backups leak to the user's profile.** On each save the game also writes
  `%LOCALAPPDATA%\HeroesofHammerwatch2\save_backups\slot_<n>_<date>.hps` (throttled: not on
  every save). It resolves the folder with `shell32!SHGetKnownFolderPath`
  (FOLDERID_LocalAppData), not the `LOCALAPPDATA` environment variable: the exe imports
  `SHGetKnownFolderPath` and contains no `LOCALAPPDATA` string, and a run with
  `LOCALAPPDATA` overridden still wrote to the real folder. One probe file leaked there:
  `slot_7_2026_10_17_T05_58_31.hps` (a lab profile, never the user's data; the user
  decides whether to delete it). Fix: `hwr2_capture.dll` replaces the exe's
  `SHGetKnownFolderPath` import and answers FOLDERID_LocalAppData with
  `GAMELAB_LOCALAPPDATA`. The exe starts suspended, the DLL is injected through
  `CreateRemoteThread(LoadLibraryW)`, and then the process resumes (`NtResumeProcess`).
  Verified: the backup then landed in `<game dir>/appdata/HeroesofHammerwatch2/save_backups/`
  and the real folder was unchanged.
- **`res/controls.cfg` is written into `res/`.** The exe has `res/controls.cfg` and
  `res/controls_default.cfg` strings and a "Saved controls config" message; the log shows
  `Loading control bindings from 'res/controls_default.cfg'`. The install has no
  `controls.cfg`, so nothing has been written there yet. Because a junctioned `res/`
  would carry that write into the install, the GameLab `res/` is a real directory:
  `assets.bin` is hard-linked (`os.path.samefile`), small files are sha256-verified
  copies, and subdirectories are junctions. Every run asserts the install's `res/` is
  unchanged.
- **Workshop subscriptions are still listed** in GameLab runs (`Workshop: Subscribed
  items: 1`, `Resource mod: drop_me.bin`). They are listed but never enabled: mods are
  enabled per save, and the GameLab profile enables exactly the GameLab set (asserted by
  the `mods` probe every run).

## 2026-10-17: windows, input, capture (P3 topology, P6 items 2 and 8)

- **Window topology.** One visible top-level `SDL_app` window titled
  `Heroes of Hammerwatch II - B170`, plus `__wglDummyWindowFodder` and IME windows.
  `v_fullscreen false` opens it windowed at the configured size.
- **`v_resolution` is `WxH`** (`GUI/Options/ResolutionsWindow.as`). `v_resolution 800 450`
  crashed the game with 0xC0000005; `640x360` works (GameLab lab profile).
- **Focus-free input works.** `PostMessage` of `WM_KEYDOWN`/`WM_KEYUP` to the `SDL_app`
  window on a hidden desktop:
  - **Enter** at the main menu starts Singleplayer/Continue;
  - **VK 0xC0** opens the console, `WM_CHAR` types into it, and Enter runs the line (the log echoes `> <line>`);
  - **F** (the default `Use` binding, `res/controls_default.cfg`) opens a chest.

  All of it also works with the window minimized (`ShowWindow(SW_SHOWMINNOACTIVE)`):
  scenario `open-chest-minimized` passed. The real foreground window was sampled every
  50 ms through every run and never changed.
- **PrintWindow returns a blank image** for the OpenGL window on a hidden desktop (no
  compositor). Frame capture is in-process instead: `hwr2_capture.dll` replaces the exe's
  `gdi32!SwapBuffers` import, and on a request file reads `GL_BACK` with `glReadPixels`
  just before the swap (`tools/capture_shim/hwr2_capture.c`). It produced correct 640x360
  and 1024x768 frames.
- ~~Mods do not run in the main menu.~~ **Corrected the same day, see "mod lifecycle"
  below.** Mod modules are constructed at the menu, but nothing ticks there. The front door
  (main menu to session) is still the Enter key, and everything after it goes through the
  `gl` console command.

## 2026-10-17: saves and mods (P6 item 3)

- **`HashString` is MurmurHash3_x86_32, seed `0xf808409c`.** It was read from HWR2.exe build
  25509441 as follows:
  1. The script declaration `uint HashString(const string &in str)` is registered next to a
     function pointer `0x1401b4560`.
  2. That native gets the string and calls `0x1400176f0`.
  3. `0x1400176f0` is the MurmurHash3 x86_32 body with `r8d = 0xf808409c` as the seed
     (`C:\tmp\claude\re\find_hashstring.py` and `disasm_at.py` were the scratch scripts).

  Checked against 57 mod-id/hash pairs the game printed: 57/57. `gamelab/hps.py hash <id>`
  computes it.
- **Mods are enabled per save.** The save header holds a list of `HashString(mod id)`
  (`gamelab/hps.py` documents the layout). The id of an unpacked mod is its folder name:
  the log shows `Adding unpacked mod 'gamelab-probe'`, and `PersistentSaves::IsModEnabled`
  is true after enabling that hash.
- **A graceful quit saves.** `WM_CLOSE` to the game window writes the profile
  (`Saving persistent data for profile <n> to file 'saves/<n>.hps'`) and the process exits 0.
  A brand-new profile after a null-save session is 1714 bytes, version 3, no characters.

## 2026-10-17: script API facts used by GameLab

- **Console commands from a module:** `AddFunction("gl", { cvar_type::String }, fn, 0, help)`.
  A one-string function receives the rest of the line.
- **Materials:** `PlayerRecord.GetMaterial(type)` reads the **town's** store
  (`g_myTownRecord`) while in town, and the character's own `materials[]` on a mission
  (`Behaviors/Actors/Player/PlayerRecord.as` `GiveMaterial`/`GetMaterial`). A probe
  reading `record.materials[]` in town sees zeros after looting (measured, open-chest run 1).
- **No generic reflective getter:** `Reflect::` has types, properties and
  `PropertyInfo.Set`, but no way to read an arbitrary property's value. The inspector must
  be code-generated from the class sources (P6, open).
- **Loot table `cache_wood` does not exist** in this build (`items/chests/cache_wood.unit`
  names it; no `tweak/loot/*.sval` defines it). GameLab uses `cache_bronze`.

## 2026-10-17: mod lifecycle (correction) and town saves

- **When mod code runs.** Measured on run `20261017-063419-mod-core-lab`, with a profile
  that enables `core` and the GameLab mods.
  - The engine logs `Adding unpacked mod '<id>'` at boot and again at `StartLoadMenu
    levels/town.lvl`. The main menu is the town level.
  - The module constructors run while the menu level loads (`Making Module ...`). The probe's
    `boot` event and `[HWP:core] module created` were both logged before `Started menu level`.
  - `UpdateFrame` ticks only once the gameplay session starts. The probe's first heartbeat
    follows `Starting session` (after the posted Enter).
  - An earlier note said mods do not run in the menu. That came from a profile with no mods
    enabled, and it is wrong: constructors run there, frames do not.
- **A fresh character's town has no save data.** On the `town-paladin` fixture the session
  logs `Started with null save`. `TownRecord.Load` returns before `Hooks::Call("TownRecordLoad")`
  when the save is null (`gamecode/sdk/hoh2/scripts/Town/TownRecord.as`). So core's
  `town record loaded` line cannot appear on that fixture. Assumed: it appears once a town
  save exists (after a run or a town save point); not measured yet.

- **`Modules::Module.Load` is gated on a session save.** `AGameplayGameMode.Start` calls
  `m_modules[i].Load(modData, sMode)` only when the session save is non-null and holds a
  dictionary under that module's `m_id` (`gamecode/sdk/hoh2/scripts/GameModes/AGameplayGameMode.as`,
  lines 143-154). A fresh town session logs `Started with null save`, so `Load` never runs.
  Consequence measured on `mod-campaign` (run `20261017-064110-mod-campaign-lab`):
  `mods/campaign` runs its self-check from `Load`, so on a fresh town it never logs
  `self-check done`. The same holds for any HWP self-check placed in `Load`.

## 2026-10-17: mod load checks (`gamelab/scenarios/mod-<id>.json`)

These replace `dev_check`. Each one boots one mod plus its `requires` on the
`town-paladin` fixture and asserts:
- the self-check lines its README names;
- still in town;
- no script errors in our files (`gamelab/logparse.py`).

The checks were validated against a deliberately broken mod: the run fails and names
`Broken.as:5:11 No matching symbol`.

- **PASS (20 of 26):** abyss, architect, bufftips, chatlinks, classes, colors, core, deathrecap,
  droptrade, farming, firearms, fishing, goldpet, groupcombo, keys, legacy, pets,
  strongbox, summons, weaponswap. The keys README named `Making Module hwp-keys`; the
  engine logs `Making Module HWPKeysModule`. README and scenario are fixed.
- **FAIL, self-check never fires on a fresh town (verified gate, see above):**
  - campaign, maps, weapons and wavemode run their self-check from `Module.Load`.
  - None of the 24 scenarios logged a script error. These four mods may well be fine,
    but they cannot report it on this fixture.
  - Fix options, the user's call: move the checks to the constructor, or add a fixture
    with a saved session.
- **FAIL, fixture content:** gambler spawns only when the town has a tavern
  (`GetVariationOnBuilding(HashString("tavern")) >= 0`). Assumed: the fresh fixture town
  has none, and that branch returns without a log line.
- **FAIL, unexplained:** laststats. `SpawnBoard` logs `spawned the notice board` 500 ms of
  frames after start when `g_inTown && Network::IsServer()`, and the line never appeared.
  Not diagnosed. Next step: probe `g_inTown` per heartbeat from tick one, rather than
  guess. Candidate: the first frames tick on `PickCharacterWindow` before town is set up.

## 2026-10-17: the Pilot, the pathfinder, the console channel

Verified means measured on the pinned build (run id or source line). Assumed is labelled.

**Input and the run loop**
- **The engine hands out more than one `GameInput`.** Measured `buffers: 2` with the
  `controller` verb. A hold written into one object kept moving the player whenever the
  other became current again (hands-release 20261017-150922..151323). gamelab-hands writes
  every object it has seen (`mods/gamelab-hands/scripts/GameLab/Input.as:55-60`).
- **The next floor is preloaded in its own script context, which constructs every mod
  module again.** Those log lines carry `[preload]` (pilot-consumables 20261017-152746),
  and `session.py` tags them so a preload `boot` is not read as the level change.
- **The game steps a fixed ~33 ms of scene time per frame, at ~30 frames a second in the
  lab box** (timescale 20261017-175222: 3663 scene ms over 111 frames), although
  `v_fps_limit` is 60.
- **`g_timescale` only changes with `e_cheats` on**, which the engine allows in modded
  games (timescale 20261017-175329: 4x gave 14.8 s of scene time in 3.7 s).
  - It is not a test accelerator. At 4x, game-ms timers ran 4x but the player moved no
    farther per frame (0.6-3.6 units, against ~3.2 at 1x): the exit intent timed out four
    times (floor-soak 20261017-175501).
  - The `timescale` verb stays, labelled measurement-only.
- **Setting `CVars::ChtGodmode` from a mod did not stop damage** (20261017-155134).
  Cause not diagnosed. Assumed: the mod's `CVars` namespace is a separate copy of the
  game's.

**Character facts used by the fixtures**
- **The level cap is 20**, reached at 1301032 xp (fixture-ranger 20261017-163304 reads
  back level 20).
- **Enemies scale with NG+ only, not with player level**
  (`Behaviors/Actors/Enemies/CompositeActorBehavior.as:335-337, 718-719`).
- **Potion charges come from the apothecary's `potion-charges` upgrade.** Steps 0-4 take
  the player from 1 charge to 5 (`Town/UpgradeShop.as:139-150`; fixture readback
  `potionCharges 5`).
- **`RollQuality` never rolls a quality on a mask without the Common bit.** It tests
  `mask & Common != 0`, which binds as `mask & (Common != 0)`
  (`EquipmentGenerator.as:15`). Measured: rare asked, quality 2 given
  (fixture-ranger 20261017-151727).
- **A refused `Equip` returns the item itself** (`MayEquip`: level or attribute
  requirements). The `equip` verb treats that as failure.

**Exits**
- **`LevelExitAreaNext` triggers only for a player inside one of its `Areas`.** Each area
  is a sensor (`:Physics_Circle`) offset from the exit unit. Measured offsets:
  - (-72,-120) on one exit (exit-areas 20261017-162406, -162451);
  - (+134,-74) on another (exit-probe 20261017-170654).

  So the offset depends on the exit's orientation. The unit's own position is not
  walkable. Standing in the sensor makes the exit the top usable, and Use loads the next
  floor.
- **Every floor sampled had exactly one enabled exit**, plus one disabled one
  (exit-probe 20261017-170654, -170727).

**The engine pathfinder (`g_scene.Pathfind`), synchronous**
- **No per-frame budget.** 2000 identical calls in one frame all answered, also after
  2000 failing far calls in the same frame (pathfind-budget 20261017-170150).
- **The diameter argument (0, 4, 8, 12, 24) changed no answer** (pathfind-budget
  20261017-170356). Neither did maxDistance or maxRange (pathfind-probe 20261017-153815).
- **Answers are geometric.** A target inside trees or water fails at any distance. A long
  route can fail although both of its halves answer (pathfind-probe 20261017-153509).
  The Pilot's `NavRoute` (A* over short Pathfind legs) covers that case.
- **The Pilot's planner routes from every physically free point it samples.** Measured
  on four layouts (route-sweep 20261017-180034, -180109, -180142, -180225). Points that
  overlap a solid body are skipped, since a player cannot stand there; unit-0 hits are
  level collision without a unit.
- **Two planner bugs were found and fixed:**
  - The search grid was too small for a 6850-unit spawn-to-exit distance
    (pilot-crosslevel 20261017-171409).
  - A player on a pond bank sat in a nav pocket (3 expansions), and stepped out of it
    (pilot-crosslevel 20261017-171446).
- **Mid-floor routing can fail after fights where it worked from the spawn.** In
  pilot-crosslevel 20261017-172902, spawn -> exit no longer routed and neither did
  here -> spawn. The same layout's answers held steady when idle for 30 s and after
  cull (nav-drift 20261017-173940).
  - Assumed cause: units standing in passages. Not verified.
  - Seen again in floor-soak 20261017-184334 sample 1. At (2042,617), 200 units south of
    the exit's stand point, nothing routed:
    - stand → anywhere: 3 expansions;
    - spawn → stand: failed;
    - here → spawn: failed, along the way the player had just walked.
    No enemy was within kite range.
  - **What can change the graph (verified from data, not yet tied to a run):** a unit's
    `<collision static="true">` blocks nav unless it says `nav-block="false"`. In the
    hoh2 units, 1408 static collisions carry no nav-block attribute, 18 say false and 2
    say true. The exe also has a `dirty_nav_graph` string (`hwr2_api_strings.txt`).
  - Assumed: static-collision units that spawn or die mid-floor rebuild the graph. Not
    yet measured; floor_runner now records the units near the cut and waits 5 s
    between retries, to tell a pending rebuild from a lasting blocker.
  - The exit intent now walks to the reached point nearest the exit and plans again
    (partial routes).

**The console channel**
- **Every gl line goes through the console: open, type, Enter, close.**
  - The console key is read per frame. Opening, typing and closing inside one frame does
    nothing at all (console-bench 20261017-181238).
  - The console also slides shut over more than 70 ms (console-trace 20261017-183130).
    An opening key during the slide is lost: every second line vanished at 70 ms
    (console-bench 20261017-182614), none of 90 at 150 ms (-183226).
- **Timing now used:** two frames after opening and after Enter, and 150 ms before the
  next opening. That is 291 ms per line, against 770 ms with the old fixed sleeps.
- **The faster timing put the console into the screenshots.** The blind observer of
  open-chest 20261017-190827 read a console panel over the top fifth of `end.png`, which
  no probe reports.
  - Measured on top-band luminance: about 25 in every shot of that run, against 73-77 in
    the older runs (20261017-140030, -064949).
  - Two plain town frames 0.5 s apart "differed by 31%" in watch-overlays 20261017-190809
    for the same reason. That was the console, not the scene.
  - Fix: `Session.shot` waits 0.25 s after the last console close.
    - console-slide 20261017-191646: the panel is in a shot taken as the reply arrives
      (top band 26.5) and gone 100 ms later (77.6).
  200 lines, 0 lost (console-bench 20261017-183348).
- **A line typed while a level loads can vanish.** The game echoes every line it runs
  (`> gl <id> ...`), so `gl_cmd` retypes a line that went unechoed for two heartbeats.
  This happened once per mission re-entry and was recovered each time (-183348).
- **One typed line of 1985 characters ran whole** (console-bench 20261017-183645).
  The fixture readback now goes out as one `multi` line: 0.5 s, down from ~15 s.

## 2026-10-17 (evening): breakables, travel, death
- **Breakable debris closes passages.** Verified from source and telemetry:
  - `doodads/terrain/castle_debris_pile_wood_noloot.unit` has a `Breakable` behaviour. Each of its
    scenes has `<collision static="true">` with no `nav-block` opt-out, so it blocks nav.
  - `m_health` defaults to -1 (`Breakable.as:31`): one hit breaks it.
  - floor-soak 20261017-192513 sample 0: every route ended near -125,971. The `bodies` probe
    toward the exit found that debris pile at 0,904. Four 20 s kites and a far-enemy kite later the
    passage was still cut.
  - Change: `TargetGone` counts a live Breakable as a target, so `attack <unit>` smashes it. A new
    read-only verb `breakables [radius]` lists them, and floor_runner attacks the nearest three
    within 250 before kiting.
  - **Assumed, not yet verified:** that the ranger's projectile hits the debris (its circles are
    `aim-through="true"`). The next soak measures it (`retries[].broke`).
- **Idle packs cutting the graph: not supported.** The far-enemy kite killed its target
  (boar, sample 0) and the route stayed cut. Sample 3 of the same run: every far enemy was
  "unreachable (stuck at 290,329)". The beetle-pack hypothesis from floor-soak 20261017-191104
  is unconfirmed; the far kite remains as a fallback.
- **Travel graph.** `learned.json` is written only by `"explore": true` runs. pilot-explore
  20261017-191702 learned forest_1 -> forest_2 (graph 1511afe5 -> 199da2bc). Scenario runs
  report `new_edge` without writing (pilot-crosslevel 20261017-191834). An unknown transition
  is `no_route` in 19 s (20261017-190905).
- **Death.** `DeadMenu`'s MenuAccept (Return) calls `Revive`: ResetPlayerHealthMana, SpawnPlayer,
  AbortMission -> town (decompiled). floor-soak 20261017-192111 stopped with "no mission
  heartbeat" after a death because nothing pressed it. `floor_soak.enter()` now presses Return
  on DeadMenu. Not yet exercised: 192513 had no deaths.
- **Ruled out:** the loot toast missing from end frames. The probe reports two `loot_log`
  announces at the end of open-chest 20261017-192415, and the blind observer saw none. A crop
  shows a faint grey "Got" at the style's anchor (bottom-right, grey 0.5, 11 px). Low contrast,
  not absence.
- **Debris breaking verified** (supersedes "assumed" above). In floor-soak 20261017-193859 the
  ranger broke `castle_debris_pile_wood` and the route moved on (sample 1, 476,-1651 -> 730,-1722).
  The soak passed 3 of 4. Crates and chairs were mostly "unreachable", so debris is now tried
  first and failed units are skipped. pilot-floor 20261017-194552 PASS. The next soak
  (20261017-194740) was interrupted by the user, leaving a stale lock: no process was alive, so
  `gamelab reset`.
- **Mod load checks: 27 of 27 pass** (20261017-194937 … -195451). The six earlier failures pass
  with their self-check log lines present. Cause not traced.
- **P6b paused** at the user's request (2026-10-17), to be walked through together.

## 2026-10-17 (night): watch-mode focus (P6 items 1 and 1′)
- **Who took the foreground in 20261017-195821.** pid 25096 was `HWR2.exe` itself, the
  `harness.start` pid. The empty image name was a sampler bug: it resolved names at
  `report()` time, after the game had exited. `ForegroundSampler` now records at each switch
  the image, window class and title, wall-clock time, the window under the cursor and which
  mouse buttons are down.
- **The game makes no activating call after its window is shown.** HWR2.exe imports none of
  ShowWindow, SetWindowPos, SetForegroundWindow, SetActiveWindow, SetFocus or CreateWindowExW.
  SDL2.dll (2.30.7) imports all of them (`objdump -p`). The shim now hooks them in SDL2.dll's
  import table and logs each call with the foreground before and after.
  - In 20261017-200502 (logging only, old behaviour) SDL made exactly one activating-capable
    call: `ShowWindow(hwnd, SW_SHOW)` 0.5 s after injection. The foreground did not change,
    because this launcher (a non-foreground agent shell) has no foreground rights.
  - The only other call was `ShowWindow(0)` at exit.
  - In 195821 the two switches to the game came 15 ms and 31 ms after real input, at about
    +3 s and +12 s after injection. That is not when SDL's call happens.
  - The game log of 195821 shows the human drove the menu: `MainMenuGameMode::MenuBack` at
    19:58:37 and :45, then `Starting session` at :46. So the foreground went to the game
    through the user's own input to its window or taskbar button. Which input it was is
    inferred, not measured: the sampler did not record the cursor then.
- **Measured once the cursor was recorded: 20261017-200812.** At 20:08:27.323 there was a
  left click on `explorer.exe` (the taskbar) and the foreground went to 0. At 27.579 it became
  the game's `SDL_app`. No hooked call took the foreground. So the shell activated the
  window on a taskbar click, even though the window was already `WS_EX_NOACTIVATE`
  (with `WS_EX_APPWINDOW` added, which gave it a taskbar button).
- **Fix** (`tools/capture_shim/hwr2_capture.c`, `gamelab/session.py`, `gamelab/runner.py`,
  `gamelab/winproc.py`). Watch mode sets `GAMELAB_NO_ACTIVATE=1` for the game.
  - The shim gives SDL's top-level windows `WS_EX_NOACTIVATE`. With no `WS_EX_APPWINDOW`
    they get no taskbar button, so there is nothing for the shell to activate.
  - SDL then shows the window `SW_SHOWNOACTIVATE`: the shim log shows `ShowWindow(..., 4)`,
    where it was 5 before.
  - Whenever another process owns the foreground, the shim rewrites activating
    ShowWindow commands to their NOACTIVATE/NA forms, adds `SWP_NOACTIVATE` to SetWindowPos,
    and refuses SetForegroundWindow and SetActiveWindow. This covers foreground rights
    inherited from a console launch, and SDL raise calls later in the run.
  - At the first frame (the first heartbeat) the runner clears `WS_EX_NOACTIVATE` and adds the
    taskbar button with `ITaskbarList::AddTab`. Nothing is activated or raised
    (`harness.allow_activation`: `ex 0x8000110 -> 0x110`, `taskbar_button: true`).
  - Lab mode is unchanged (`no_activate=0`); the hooks only log there.
- **Runs.**
  - null-payload watch 20261017-201214 and -201234: PASS, zero foreground switches for the
    whole run, first frame at 9.8 s and 9.3 s.
  - null-payload lab 20261017-201253: PASS.
  - open-chest lab 20261017-201305: PASS.
- **Assumed:** a real click on the loading window does not activate it. That is the documented
  `WS_EX_NOACTIVATE` behaviour, untested here because GameLab sends no real input. Also
  assumed: the taskbar button appears after AddTab (it returned S_OK).
- **Posted Enter lost at the main menu.** Seen in 195821 and 200812, the two runs where the
  human was using other windows: no `Starting session` followed it, and 200812 failed
  "never reached phase town". Cause not established; assumed to be long frames while the
  window is occluded. `Runner.boot` now waits up to 5 s for `] Starting session` and re-sends
  Enter up to 3 times (`harness.enter_lost`). The retry has not fired in a run yet.

## 2026-10-17 (night): fresh-clone readiness (`python -m gamelab doctor`)

- **No managed code to decompile.** All 12 PE files in the install root (HWR2.exe,
  EDITOR.exe, HWR2Toolkit.exe, PACKAGER.exe and the DLLs) have an empty CLR data
  directory (pefile, `DATA_DIRECTORY[14]`), so they are native and ILSpy does not apply.
  The readable game logic is the AngelScript that `bootstrap.py` unpacks with the
  patched PACKAGER copy in `tools/bin/`.
- **The manifest no longer hashes the shim stamp.** `tools/bin/hwr2_capture.build.json`
  records the gcc version, so `bootstrap.py --verify` failed on any machine with a
  different gcc. It is now excluded from the hash, like the DLL. `--verify` instead checks
  that the stamp's `source_sha256` matches `tools/capture_shim/hwr2_capture.c`.
  `gamelab/manifest.json` was re-recorded: only the `tools/bin/.` group changed
  (10 to 9 files), build 25509441.
- **Save backups are confirmed per machine.** `saves.verify()` compares the real saves
  against the manifest and never re-reads the copies. The new `saves.intact()` re-hashes
  the copies; `restore` refuses a damaged backup. Confirming runs the following, then
  writes `saves-backup/confirmed.json`:
  - the sandboxed selftest;
  - a backup;
  - `intact` on that backup;
  - `verify` against the real saves.

  The launcher preflight and `deploy.py modded-prod` refuse until the stamp exists, the
  save dirs still resolve to the same paths and the stamped backup re-hashes.
  `tools/saves_selftest.py` covers all three cases. It also creates `C:\tmp\claude`,
  which it used to assume existed.
- **Confirmation is automatic unless it is ambiguous.** `doctor --fix` confirms by itself
  when `assess_saves()` finds nothing ambiguous:
  - files exist;
  - the dir the player's config writes (`g_save_slot_cloud`) has files;
  - no other Steam account holds HoH2 saves;
  - no unknown `save*` dir in the install holds files.

  Anything else prints `AMBIGUOUS:` and needs a person (`--confirm-saves`). A person
  asked on an unambiguous machine adds nothing and learns to click yes.
  - `tools/doctor_selftest.py` covers seven cases on a sandbox Steam root (20 checks,
    green). The new overrides `HWP_STEAM_DIR` and `HWP_LOCALAPPDATA` exist for it.
  - The install's empty `save/` dir is not ambiguous; it would be if it held files.
    Which dir the game uses with `g_save_slot_cloud 0` is still measured only for
    GameLab's own copy (`saves/`).
- **Hazards on a new machine, checked by doctor, assumed and not hit here.**
  - A repo on another drive from the Steam library: `os.link` of `res/assets.bin`
    fails across volumes.
  - Steam not running: the directly launched exe needs the client (see above).
  - Saves under a second Steam account on the same PC: only the install's LastOwner
    account is backed up. doctor lists the others as uncovered.

## 2026-10-17 (night): doctor makes the local content too (HoH1, class units)

- **HoH1 discovery goes further, then asks.** `gamepaths.find_hoh1()` order:
  `HWP_HOH1_DIR`, then the Steam appmanifest 677120 in any library, then the path the
  user gave (`tools/paths.local.json`, gitignored), then a sibling of the HoH2 install,
  then every library's `steamapps/common/`. Every candidate except the env override must
  have `HWR.exe` + `res/assets.bin`. bootstrap and import_hoh1 use the same function.
  On this PC HoH1 is in another library (`G:\SteamLibrary`) and is found by its
  appmanifest (verified: `python -m gamelab doctor`, real repo).
- **Not found and no answer means doctor is NOT green.** The HoH1 row says `ASK THE USER`
  and names the two answers: `doctor --hoh1 "<dir>"` (validated, persisted) or
  `doctor --no-hoh1` (persisted; HoH1 content is then reported as skipped).
- **`--fix` makes the gitignored content a fresh clone lacks.** It reruns bootstrap when
  HoH1 is known but `gamecode/sdk/hoh1/` is missing (`--verify` treats that tree as
  optional). It runs `tools/class_units.py` when a copy differs from what it would write.
  It runs `import_hoh1.py pets|levels|campaign|classes`, each only when its output files
  are missing and never with `--force`. The importers do not read each other's output.
  A `mods/campaign/hoh1/` without the `.hwp-generated` marker is reported and left alone.
- **Fixed: `import_hoh1.py levels` crashed on the PACKAGER base.** Its HoH2 probe level
  (`levels/boss_arista.lvl`) is SValue XML in the PACKAGER unpack, not binary
  (`unsupported SValue tag 0x3c at offset 8`). `decode_level` now parses XML when the
  data starts with `<`. Verified: 32 probe script types, 0 unresolved; the import writes
  48 files.
- **Verified on a fresh clone** (`C:\tmp\claude\doctor_e2e\run_e2e_hoh1.py`, 30/30
  checks). Setup: a sandbox Steam with no HoH1 appmanifest and no library list, the real
  HoH2 install, and copies of the saves.
  - `--fix` exits 2 with only the HoH1 question open (bootstrap and class_units ran).
  - `--hoh1 G:\...\Heroes of Hammerwatch` persists the path. `--hoh1 <HoH2 dir>` is
    rejected.
  - `--fix` exits 0 in 55 s: hoh1 extraction (10990 files, matches the manifest) and all
    four imports.
  - A second `--fix` changes none of the 29257 files.
  - Real saves, the real `tools/paths.local.json` and the HoH1 install are unchanged.
- `tools/doctor_selftest.py`: 40 checks, green (21 new HoH1 discovery checks, sandboxed
  through `HWP_PATHS_LOCAL`).
- **Independently re-verified, in the game** (`C:\tmp\claude\doctor_e2e\validate_hoh1.py`,
  34/34 checks). It used another fresh clone with the same sandbox setup and repeated the
  flow above. It then went further:
  - `--hoh1` with a missing dir or the HoH2 dir saves nothing.
  - The generated files are all gitignored.
  - The imported content loads in the game. mod-pets 20261017-215458, mod-campaign
    20261017-215510 and mod-classes 20261017-215522 all PASS in lab mode with the HoH1
    files in the mod folders. Their game logs have no error lines on `hoh1` or `hwp`
    paths. The runs were in the clone, which is deleted.
  - `build.py --with-local` packs `hoh1/` into HWP-campaign.bin,
    `players/pets/hwp/` into HWP-pets.bin and the class art into HWP-classes.bin.
  - The levels fix is equivalent to the binary path: `level_refs` of `boss_arista.lvl`
    decoded from the install's binary archive equals the result from the XML unpack
    (1441 placed, 112 scripts).
  - **Assumed:** the game *uses* each imported item. No scenario opens the Pet Shop or
    plays a HoH1 floor; the scenarios prove a clean load only.
- **Assumed, not tested:** the sibling and library searches against a real Steam layout
  (only sandboxed); a HoH1 version other than this machine's. Its `gamecode/sdk/hoh1`
  hash would differ from `gamelab/manifest.json`, so `bootstrap.py --verify` would fail
  there.
- ~~**Not covered:** `tools/make_pet_dyes.py` output~~: covered since, see the next section.

## 2026-10-17 (night): doctor makes the pet dyes and smoke-boots the machine

- **Pet dyes.** `tools/make_pet_dyes.py` now writes `dye/.hwp-generated.json` with its own
  sha256, the pets it made and the sha256 of every source unit and sheet. `--verify` (and
  `problems()`) reports missing copies, a changed generator, a changed source or a pet
  whose source appeared since (the HoH1 import adds 21). The dotfile never packs
  (`packable_files` skips dot-parts). doctor runs it after class_units and the HoH1
  imports, also when HoH1 is declined (the 7 vanilla pets only need `gamecode/sdk/hoh2`).
- **Smoke boot.** Once every non-content row is green, `doctor --fix` runs `null-payload`
  in lab mode (`--smoke` forces it). A pass goes to `gamelab/smoke.local.json` (gitignored)
  keyed by build id, shim source hash, `os.cpu_count()` and the display adapters
  (registry display class `DriverDesc`). A change to any of them asks for a new boot.
  `explain_smoke()` maps a failure to a plain cause: a refused shim (antivirus), the
  renderer not starting (log has `Opening SDL window`, no `BGFX initialized`), blank
  shots, a deadline (shown with "N of M cores"), a window leaking to the input desktop,
  no game log, the probe not booting, isolation checks, or user files changed.
- **A failed boot leaves the lock dirty.** Verified: with a garbage shim the game is
  killed and `teardown.json` records `pass 1 exited cleanly: exit code 1`, so the next run
  is refused with exit 4. doctor records the failed run in the smoke stamp. Before its
  next boot it runs `python -m gamelab reset` only if the dirty teardown is that same run
  and no lock is held. Any other dirty teardown is still left for a person.
- **Verified on a fresh clone** (`C:\tmp\claude\doctor_e2e\run_e2e_smoke_dyes.py`, 28/28;
  sandbox Steam with copies of the saves; the first attempt, 23/27, found the two bugs
  fixed above: the dye row hid its reason, and the dirty teardown blocked every later boot):
  - `--fix` with HoH1 unanswered: dyes for 7 pets, smoke PASS in 14 s on the hidden desktop
    (run 20261017-222209: focus and no-leak assertions and `shot town` pass).
  - `--hoh1` + `--fix`: dyes regenerated for 28 pets, no second boot; a second `--fix`
    rewrites nothing and boots nothing; generated files all gitignored.
  - An edited HoH1 pet unit: plain doctor says `1 sources changed`, `--fix` remakes them.
  - A garbage `hwr2_capture.dll`: `--smoke` reports the refused shim and names antivirus
    and the dll. Shim restored, `--fix` resets its own dirty teardown and passes.
  - A scenario with an already-passed deadline: reported as too slow, "gets 14 of 16 cores".
  - Real saves byte-identical, HoH1 install and the real repo's stamp unchanged.
- `tools/doctor_selftest.py`: 78 checks, green (every `explain_smoke` branch, the stamp,
  the gating, the reset rule, the dye staleness cases on a sandbox).
- **Assumed, not tested:** the GPU branches (no-GL, blank frames) and the window-leak
  branch on a machine that actually fails them. The causes are mapped from the log lines
  and assertions a passing run shows, plus the selftest. The real antivirus case
  (a refused LoadLibraryW) was reproduced only through a broken dll.

## Merge of main into gamelab-pilot (2026-10-17): what GameLab caught

- **A non-power-of-two GUI texture is fatal at boot.** Verified (run
  20261017-225009-mod-fishing-lab, `pass1.HWR2.exe.log`): `gui/hwp/bait.png (class
  TextureLoader): Texture sizes (48x16) should be power of two`, then `main menu never
  loaded`. Fixed by padding right/bottom with transparency so sprite rects are unchanged:
  `mods/fishing/gui/hwp/bait.png` 48x16 -> 64x16, `mods/farming/gui/hwp_seeds.png`
  117x13 -> 128x16. Both PASS afterwards (225242 fishing, 225254 farming).
- **Malformed `.gui` XML is fatal too.** Verified (run 20261017-224728-mod-fishing-lab):
  `gui/hwp_pirate.gui (class GUILoader): XML error! invalid closing tag name`. main had a
  stale copy of the old button layout plus an extra `</panel>` after the new one; removed.
- `mods/colors/gui/options/game.gui` has a duplicate attribute on one `entry-selector`
  (a strict XML parser rejects it); the game's loader accepts it (mod-colors PASS, 225344).
- New `mod-all` scenario: all 26 content mods together in town, clean log. PASS
  (20261017-225415-mod-all-lab). Run it before merging to main.
- **Second merge (ddf944c, pirate follows trading post).** Checked against the pinned
  prefabs: `trading_post.sval` uses `tier_0.pfb` as `unbuilt-prefab` (variation -1) and
  `tier_N.pfb` for variation N-1, so `GetVariationOnBuilding + 1` is the prefab tier.
  `tier_0`-`tier_2` have `boat_small_wreck` at 320,-112; `tier_3`+ have none. The
  material trader is at ~380,-66.8 in `tier_1`-`tier_5` (absent from `tier_0`, where the
  code falls back to the plot origin). In run 20261017-230737-mod-fishing-lab the
  unbuilt fixture town puts the pirate at -1222,142 = plot + (314,-114), on the wreck.
  **Assumed, not tested:** the re-place after an upgrade (`WatchCoast`), since no fixture builds
  the trading post. `import_hoh1.py pets --force` produced the candle body
  (flame origin y +9, lights -9); mod-pets and mod-all PASS (230749, 230812).
