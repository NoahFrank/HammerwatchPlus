# The Game Modding Playbook

The standard operating procedure for standing up a modding project for any game. The goal
of every phase is the same: replace guesswork with **ground truth** (decompiled code,
extracted data, screenshots) and replace human-in-the-loop testing with **GameLab**
automation, so mods can be developed and validated end-to-end programmatically.

**Three core principles:**

1. **Ground truth or it didn't happen.** Claims about game behavior come from decompiled
   code, extracted data tables, or observed screenshots/logs — never from memory of
   "how games like this usually work."
2. **Everything searchable, in one place.** Game code, official docs, and notes all live
   in the project root so a string search reaches everything.
3. **Automate the loop.** The measure of project maturity is how much of
   *edit → deploy → run scenario → observe → score* runs without a human.

**How to read the phases:** every phase ends with a **Deliverables** block — path, what
it holds, what gates on it. If a rule in this playbook has no row in a Deliverables
block, it is a suggestion. If it has a row, it is required and the phase is not done
without it.

#### Companion: `game-state-repro-playbook.md`

**Read it, unprompted, the moment a task means "put the game into state X and observe
it."** Concretely: constructing a character/save/world the user hasn't earned; testing a
build or item without the grind; reproducing a bug that only appears after a world/scene
transition, on load, or in a subworld; diagnosing a hang, a silent no-op, or a load
failure; writing or extending a harness that drives the game to a state and asserts on
it. *This* playbook stands a project up — that one drives it to a point in state space
and proves it got there.

It exists because a task doing exactly that shipped fifteen defects while reporting
19/19 green, four of which the user found by asking casual questions afterwards. Its
premises: **until the smoke run is green, every failure is a harness failure by
default**, and **a setter that returns without throwing has told you nothing**. It
carries a required compliance manifest (`gamelab/compliance/<task-slug>.md`) whose boxes
may only be ticked against pasted evidence, and which must appear in the final response.

#### IMPORTANT NOTE
All references to ILSpy should be interpreted to instead of downloading it, use
the custom version of it we built here: C:\FastProjects\ilspy-llmified

Example of how to run the ilspy fork:
`C:\FastProjects\ilspy-llmified\ICSharpCode.ILSpyCmd\bin\Release\net10.0\ilspycmd.exe C:\path\to\obfuscated.dll --ai-rename-methods`

More flags like `--ai-model` let you specify an OpenRouter model to use.  Or you can specify
`--ai-deobfuscate` instead of `--ai-rename-methods` to do a complete fuzzy decompile+deobfuscation.

#### Scripting language
Every script this playbook requires is **Python**, invoked as `python tools/<name>.py`.
No PowerShell program logic, in `tools/` or anywhere else.

## Phase 0 — Project setup

Create a root repo per game: `<game>-mods`, with this standard layout:

```
<game>-mods/
├── README.md            # project status, key facts, phase checklist  (root: only this and CLAUDE.md)
├── CLAUDE.md            # agent instructions for this project
├── docs/                # every other document lives here, nothing else at the root
│   ├── PLAYBOOK.md      # this file (see P8 — the last deliverable)
│   ├── MECHANICS.md     # game mechanics documentation (Phase 5)
│   ├── official/        # first-party modding docs, full mirror (httrack / git clone)
│   ├── community/       # community wiki + tool docs + reference mod source, full mirror (big exports GITIGNORED)
│   ├── SOURCES.md       # every mirror: URL, method, date pulled, what it covers
│   ├── MODDING_NOTES.md # modding ecosystem: loaders, tools, install paths, log paths
│   └── RE_NOTES.md      # reverse-engineering findings log (dated entries)
├── gamecode/            # decompiled code + extracted data  (GITIGNORED)
│   ├── sdk/             # dumped headers / decompiled source
│   ├── datatables/      # data exports (JSON/CSV): stats, drops, prices…
│   └── assets/          # extracted blueprints, maps, configs
├── gamelab/             # GameLab test harness (Phase 6)
│   ├── build_id.json    # pinned game build — the runner refuses to run on mismatch
│   ├── env/             # environment manifest + GameLab-only game settings
│   │   ├── environments.json   # the three environments, machine-readable
│   │   ├── settings/           # GameLab's own game config: windowed, low, MUTED
│   │   └── userdata/           # GameLab's saves/config/logs  (GITIGNORED)
│   ├── fixtures/        # fixture RECIPES (committed) + materialized saves (ignored)
│   │   └── cache/       # built .sav files, keyed by build id  (GITIGNORED)
│   ├── scenarios/       # declarative scenario definitions
│   ├── bots/            # Pilot scripts (Phase 6b): Python against the bot API
│   ├── travel/          # Pilot transition graph: authored.json + learned.json (committed)
│   ├── manifest.json    # hashes of everything bootstrap.py regenerates or downloads
│   ├── manifest.local.json # which bootstrap tier this machine has  (GITIGNORED)
│   └── results/         # run outputs (GITIGNORED)
├── saves-backup/        # timestamped backups of the player's real saves (committed, capped)
├── mods/                # one folder per mod (incl. gamelab-probe, gamelab-hands, gamelab-pilot)
├── tools/               # helper scripts (Python): bootstrap, deploy, saves, env_link, pin_build, screenshot, extract, hidden_desktop
│   └── bin/             # patched game tools built by bootstrap  (GITIGNORED)
├── .screenshots/        # game screenshots  (GITIGNORED)
└── .claude/skills/      # project skills (game-screenshot, run skill for dev env, …)
```

- Creating inferred offline copies of any kind of documentation is forbidden.  You will use httrack to mirror docs and other artifacts without poisoning them with LLM summarization/distilled/interpretation.  If github/gitlab has all the docs, then great you can `git clone` but otherwise you will likely need to use httrack.
- `git init` immediately; gitignore `gamecode/`, `.screenshots/`, `gamelab/results/`,
  `gamelab/env/userdata/`, `gamelab/fixtures/cache/`, `gamelab/manifest.local.json`,
  `tools/bin/`, and the non-regenerable mirrors under `docs/community/`.
  Game dumps are regenerable and enormous — they live *in* the tree for searching but
  never in git.
- `saves-backup/` **is** committed and shared with collaborators through the repo; the
  player's save history is worth more than the repo size — **up to a cap** declared in
  the README (default 200 MB for the directory). `saves.py backup` enforces it: past the
  cap it refuses to add a backup and says so, and the user decides what to prune. Save
  files are personal; they never go to the shared artifact folder unless the user opts in.
- **The repo is reproducible on a collaborator's machine by one command.** Every
  gitignored path is one of three kinds: **regenerable** from a game install,
  **downloadable** from a shared artifact folder, or **machine-local scratch**
  (`gamelab/results/`, `.screenshots/`, `gamelab/env/userdata/`, `gamelab/fixtures/cache/`,
  `gamelab/manifest.local.json`). `python tools/bootstrap.py` handles the first two:

  | Tier | What | Source | Gate |
  |---|---|---|---|
  | required (default) | `gamecode/` dump, patched tools in `tools/bin/`, `tools/hidden_desktop.py` present | the local game install | refuses if the install's build id ≠ `gamelab/build_id.json` |
  | optional (`--with-community`) | non-regenerable mirrors: chat exports, old-build snapshots, anything that needed a token or a moment in time | a shared cloud folder named in `docs/SOURCES.md` | hash-verified against `gamelab/manifest.json` |

  `gamelab/manifest.json` (committed) records the hash of every **deterministic**
  regenerated or downloaded file. Nondeterministic outputs — anything an LLM-assisted
  decompiler renamed, for instance — are recorded by input hash plus tool version, not
  output hash. The fixture cache is not bootstrap's job: it is built on first use (item
  3). `gamelab/manifest.local.json` (gitignored) records which tier this machine has, so
  an agent can tell "the search covered Discord" from "Discord is not on this machine".
  `bootstrap.py --verify` compares the tree to the manifest and is the first thing a new
  machine runs after cloning. **The gate:** on a second machine the required tier is
  manifest-identical; the optional tier is manifest-identical where present.
- **Big mirrors are gitignored, not committed.** `docs/community/` may hold gigabytes
  of chat export; it gets a SOURCES.md row (with the shared-folder location) and a
  manifest entry, never a git blob. Phase 2's "not tickable while empty" gate for
  `docs/community/` is checked on the originating machine; a collaborator without the
  optional tier is not in violation. Git LFS is not used: it slows the clone and the
  history grows forever.

### Deliverables — Phase 0

| Path | Contents | Gate |
|---|---|---|
| `<game>-mods/` | Standard layout above, `git init` done | Every directory exists, even if empty |
| `.gitignore` | `gamecode/`, `.screenshots/`, `gamelab/results/`, `gamelab/env/userdata/`, `gamelab/fixtures/cache/`, `gamelab/manifest.local.json`, `tools/bin/`, non-regenerable mirrors under `docs/community/` | `git status` clean after a full dump |
| `README.md` | Project status, key facts, the P0–P8 checklist, the saves-backup cap | Checklist pasted verbatim from the end of this file |
| `tools/bootstrap.py` | Required tier regenerates from the install; optional tier downloads from the shared folder; `--verify` | A fresh clone on a **second machine** plus `bootstrap.py --verify` is green: required tier identical, optional tier identical where present |
| `gamelab/manifest.json` | Hash (or input hash + tool version) per regenerated/downloaded file | `bootstrap.py --verify` green on both machines |
| `tools/hidden_desktop.py` | Vendored copy of the hidden-desktop launcher, so lab mode works on every collaborator's machine | Present and importable after bootstrap |
| `saves-backup/` cap | Declared in README, enforced by `saves.py backup` | `backup` refuses past the cap with a message |

## Phase 1 — Recon

Establish what you're working with before touching any tools.

- **Locate the install.** Steam: registry `HKLM:\SOFTWARE\WOW6432Node\Valve\Steam` →
  `steamapps\libraryfolders.vdf` → `steamapps\common\<Game>`.
- **Pin the version.** Record app id, build id (`steamapps/appmanifest_<appid>.acf`),
  and game patch version in `docs/RE_NOTES.md`. Re-check every session: **game updates
  silently break mods and invalidate dumps.** If an update lands mid-project, re-dump
  before trusting old extractions.
- **Find the log files.** Locate every log the game and its loaders write (Unreal:
  `%LOCALAPPDATA%\<Proj>\Saved\Logs\<Proj>.log`; Unity:
  `...\LocalLow\<Company>\<Game>\Player.log`; loader logs like `UE4SS.log`,
  `BepInEx/LogOutput.log`) and record the paths in `docs/MODDING_NOTES.md`. Verify the game
  version/build id is printed at startup — if the game doesn't log it, the first mod
  must (see Logging discipline, Phase 6). A log that names its build is how silent
  updates get caught.
- **Check anti-cheat.** EAC/BattlEye kills DLL-injection loaders
  outright — look for `EasyAntiCheat/`/`BattlEye/` dirs and launcher wrappers before
  investing in a stack. **Record the finding in `docs/RE_NOTES.md` with its consequence**:
  which loaders this rules out, and whether the project proceeds, proceeds on an
  anti-cheat-free launch path, or stops here.
- **Identify the engine** from the file layout:

| Engine | Fingerprint |
|---|---|
| Unreal | `Engine/` dir, `<Proj>/Content/Paks/*.pak`, `<Proj>-Win64-Shipping.exe` |
| Unity (Mono) | `<Game>_Data/Managed/Assembly-CSharp.dll` |
| Unity (IL2CPP) | `GameAssembly.dll`, `<Game>_Data/il2cpp_data/` |
| Godot | `.pck` file (or embedded in exe), "godot" strings in the exe |
| GameMaker | `data.win` |
| Hammerwatch (Crackshell) | `HWR2.exe`, `PACKAGER.exe`, `res/assets.bin` (`HW2R` magic), `.as` scripts inside the archive |
| Custom | strings/imports in the exe; check the game's credits/licenses screen |

- Record engine **and version** (Unreal: `Engine\Binaries\...` dll versions or exe
  properties; Unity: `<Game>_Data/globalgamemanagers` header) — tooling is
  version-sensitive.

### Deliverables — Phase 1

| Path | Contents | Gate |
|---|---|---|
| `docs/RE_NOTES.md` | Install path, app id, build id, game version, engine + engine version, anti-cheat finding + consequence | Dated entry; build id matches what P6 will pin |
| `docs/MODDING_NOTES.md` | Every game/loader log path found | The harness can tail every path listed |

## Phase 2 — Modding support survey

- **First-party support.** Find official modding docs, devkits, Workshop/mod.io
  integration, sanctioned mod folders. **Download the full docs into `docs/official/`**
  (clone the docs repo if it's on GitHub, else mirror the site with httrack) so they're
  string-searchable offline.
- **Community ecosystem.** Identify the de-facto mod loader(s) (UE4SS, BepInEx,
  MelonLoader, game-specific loaders), the modding Discord/wiki, and Nexus/mod.io hubs.
  **Mirror the community wiki and the loader/tool docs into `docs/community/`** on the
  same terms as `docs/official/` — `git clone` if it's a repo, else httrack. Existing
  mods are documentation: clone the source of the two or three most-installed mods for
  this game into `docs/community/` as well. Principle 2 does not distinguish between
  first-party and community docs — one string search reaches both or the survey is not
  done.
- **Record every mirror in `docs/SOURCES.md`**: source URL, method (`httrack` / `git
  clone` + commit SHA), date pulled, one line on what it covers. A mirror with no date
  is indistinguishable from a stale one, and community wikis rot faster than the game.
- **Decide the mod stack** and record it in `docs/MODDING_NOTES.md`: which loader(s),
  which asset pipeline, how mods are installed/loaded, and how the two coexist
  (official loader + community loader often both apply).

### Deliverables — Phase 2

| Path | Contents | Gate |
|---|---|---|
| `docs/official/` | Full first-party doc mirror | Not tickable while empty |
| `docs/community/` | Wiki + tool doc mirrors, reference mod source | Not tickable while empty |
| `docs/SOURCES.md` | One row per mirror: URL, method, SHA/date, coverage | Every dir above has ≥1 row |
| `docs/MODDING_NOTES.md` | Chosen mod stack, install/load mechanics, coexistence | Names the loader(s) and the asset pipeline |

## Phase 3 — Extract & decompile game code

Store all output under `gamecode/` for easy string searching.

| Engine | Tooling |
|---|---|
| Unity (Mono) | [ILSpy](https://github.com/icsharpcode/ilspy) — `ilspycmd` for batch decompile to `gamecode/sdk/` |
| Unity (IL2CPP) | [Il2CppDumper](https://github.com/perfare/il2cppdumper) (structure/names); Cpp2IL for pseudo-source |
| Unreal (4.12–5.x) | [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) — live object dumper, CXX header dump, Lua API. Plus: **FModel/CUE4Parse** for pak/asset extraction (needs the right UE version + `.usmap` mappings; check for AES keys and IoStore `.utoc/.ucas`), **Dumper-7** for a C++ SDK, **repak/UnrealPak/retoc** for repacking |
| Godot | [gdsdecomp](https://github.com/GDRETools/gdsdecomp) — `gdre_tools` CLI |
| GameMaker | [UndertaleModTool](https://github.com/UnderminersTeam/UndertaleModTool) — has CLI |
| Custom Java | FernFlower (IntelliJ) https://github.com/jetBrains/fernflower or fallback to [JADX](https://github.com/skylot/jadx)
| Custom C#   | [ILSpy](https://github.com/icsharpcode/ilspy)
| Hammerwatch | The game's own `PACKAGER.exe --unpack` (Steam-patched, see Per-engine notes) — the logic is AngelScript source inside the archive, no decompiler needed; Ghidra only for the native engine |
| Custom C++/Rust | [Ghidra](https://github.com/nationalsecurityagency/ghidra)

- **Export data tables to JSON/CSV** into `gamecode/datatables/` — stats, drop rates,
  prices, XP curves. These are the raw material for `MECHANICS.md` and for data mods.
- Engine-specific extraction extras (what else to grab beyond code + tables) are in
  the Per-engine notes.

### Code accessibility

Not everything "decompiles", and that's normal. Every engine has an **accessibility
profile**: some content extracts to clean data at full fidelity, some yields structure
only (class layouts and signatures, no function bodies), some sits in-between as
bytecode with PoC-quality decompilers — and the boundaries fall differently per engine
(Unity Mono C# decompiles to full source; Unreal's C++ gives structure only). Look up
the engine's profile in the **Per-engine notes** and plan the work around what each
tier gives you instead of fighting the opaque parts.

**In practice, don't decompile the opaque tiers — observe them at runtime.** Read
behavior with the mod loader's live inspector, hook the functions you care about and
log their inputs/outputs, or answer the question empirically with a GameLab probe
scenario. Runtime hooking sidesteps decompilation entirely and is almost always
cheaper than static reverse engineering.

If the engine has no subsection in the Per-engine notes yet, **you are the one seeding
it** — write the accessibility profile you discover into
`~/.claude/playbooks/game-modding-playbook.md`, not into the project's local copy.

### First modded launch checklist

- **Back up saves before the first injected boot** (`python tools/saves.py backup`) —
  loaders can corrupt them, and publishers warn about it for a reason.
- Expect an official mods-detected dialog on boot; automation has to dismiss it.
- Verify injection from the loader's log markers, not from the game seeming fine.
- Map the window topology: loader consoles are often separate windows of the same
  process, and the game viewport may not be `MainWindowHandle` (concrete case in
  the Per-engine notes). Record the topology in `docs/RE_NOTES.md` — Phase 6's
  screenshot capture and any focus-free input path both depend on the right handle.

### Deliverables — Phase 3

| Path | Contents | Gate |
|---|---|---|
| `gamecode/sdk/` | Decompiled source / dumped headers | String-searchable; covers the studio's own gameplay module, not just the engine |
| `gamecode/datatables/` | JSON/CSV exports: stats, drops, prices, curves | MECHANICS.md can cite a table name for its claims |
| `gamecode/assets/` | Extracted blueprints, maps, configs | Per the engine's extraction extras |
| Per-engine notes | Accessibility profile for this engine | Written to the **global** playbook if this engine is unseeded |
| `docs/RE_NOTES.md` | Window topology, injection markers, first-boot findings | Dated entry |

## Phase 4 — Eyes: the screenshot skill

Set up a project Claude skill (`.claude/skills/game-screenshot/`) that captures the game
window to `.screenshots/` (gitignored) and reads the image back.

Use it constantly to stay grounded: verify what the game is actually showing — menus, UI
state, test outcomes — instead of assuming. Screenshots are the check that requirements
and test results are accurate, and they're GameLab's observer component (Phase 6).

Capture must be **passive**: it works while the window is occluded or minimized and it
steals no focus (Win32 `PrintWindow`). A capture path that requires raising the window
is not a capture path — it breaks the moment a run goes unattended.

### Deliverables — Phase 4

| Path | Contents | Gate |
|---|---|---|
| `.claude/skills/game-screenshot/` | Capture-to-`.screenshots/` + read-back skill | Verified end to end: capture, then read the image |
| — | Passive capture proof | Produces a correct image with the window occluded and unfocused |

## Phase 5 — Brain: MECHANICS.md

Document how the game actually works, **citing decompiled sources** (table/class names)
for every claim. Required coverage:

- **Progression:** how XP is gained, level curves, skill/tech trees.
- **Loot & drops:** drop tables and rates, rarity systems, loot sources.
- **Movement tech:** the full movement model — can you airstrafe? bhop? does
  jump-then-dodge give extra distance? wall running? double jump? sprint mechanics,
  stamina. This defines what "skilled play" looks like and what tests can exploit.
- **Economy:** how money/valuable currency is earned, sinks, vendor behavior, prices.
- **Top-level gameplay loops:** e.g. a space game might offer explore / salvage wrecks /
  trade / dogfight / mine. Enumerate them — each loop is a GameLab scenario family.
- **UI interaction model:** how the player uses menus, inventory, map, crafting. You
  cannot write correct tests without knowing how actions are actually performed.
- **Inventory & logistics:** weight limits, "inventory tetris", stash/base storage,
  vendor fencing — the friction systems players play around.
- **Run-state variables:** the complete list of what a real run carries — class, level,
  gear, skills, run modifiers, consumables, buffs, difficulty, location — each with the
  game function or data path that sets it. This list is the schema of a fixture recipe
  (Phase 6) and the definition of "fully materialized" (Phase 6b).

**Self-start on unknowns.** You've never played the game — build understanding
proactively: examine map data for monster spawns, find trader NPCs, trace the inventory
code, work out how much a player can bank at base vs. carry. If the game even lets you have
a home base. Where code reading leaves ambiguity, design a GameLab probe scenario to answer
the question empirically.

**P5 and P6 interleave.** Everything answerable from `gamecode/` is written first; the
questions that need a probe stay in MECHANICS.md as explicit open items and get answered
once P6's state probes exist. Do not stall P5 waiting for the harness, and do not close
P5 with unmarked guesses standing in for probe results.

### Deliverables — Phase 5

| Path | Contents | Gate |
|---|---|---|
| `docs/MECHANICS.md` | All eight coverage areas above | Every claim cites a `gamecode/` table/class name **or** a `gamelab/results/` run |
| `docs/MECHANICS.md` — run-state variables | The full list with a setter per variable | Every variable names the function or data path that sets it, or is an open item for a probe |
| `docs/MECHANICS.md` — open items | Questions deferred to a probe scenario | Each names the scenario that will answer it; none survive P6 |

## Phase 6 — Hands: GameLab

**GameLab** is the standardized name for the test-harness system, in every project.
Its job: programmatically construct, run, observe, and score test scenarios — no human
in the loop.

**GameLab is how the game is interacted with during development.** If you find yourself
reaching for the real mouse to make something happen in the game, that is a missing
GameLab verb, not a workaround — build the verb.

### Architecture (adapt per game, keep the shape)

1. **Launcher** — in lab mode starts the game **windowed, low graphics, fixed small
   resolution** so runs are cheap and can sit in the background. Skip intro movies. Where possible, boot
   directly into a scenario via launch args, autoexec, or a fixture save. On Steam, **which
   launch path you use decides whether args arrive**: launching the game exe directly makes
   the Steam API relaunch it *through Steam*, and that relaunch discards argv — but
   `steam.exe -applaunch <appid> <args>` **does** deliver them (measured on Palworld: the
   live process command line carried `-UserDir=`, and the whole sandbox depends on it). So
   prefer `-applaunch` for args; fall back to the engine's config file for
   resolution/quality only if the game truly ignores flags (file paths per engine: see
   Per-engine notes). The launcher never grabs OS focus, in any mode; there is no
   attempt budget after which that rule lapses.

   **`-applaunch` and the hidden desktop are incompatible.** When Steam spawns the game,
   the game is not a descendant of the launcher, so the desktop object and job from
   `tools/hidden_desktop.py` do not reach it. Lab mode therefore needs a launch path in
   which the game exe is a **direct child** of the launcher (Steam already running and
   no relaunch, or args through the engine's config file), and asserts in preflight
   that the live game process is inside the launcher's job tree. Which path a given
   game allows is a Phase 6 probe recorded in the Per-engine notes.

   **Two launch modes, one launcher, one mod set.** The only thing that differs is the
   launch profile; scenarios, verbs, and telemetry are identical in both.

   | Mode | Window | Sound | Profile | Who watches | Gate |
   |---|---|---|---|---|---|
   | `--mode watch` (**default for a human at the keyboard**) | visible, real resolution, **never focus-stolen**; the user alt-tabs to it | on | `gamelab/env/settings/watch/` | the human, giving feedback | the foreground window, sampled from launch until the game's first rendered frame, never belongs to the launched process tree; telemetry written exactly as in lab mode, so feedback maps to tick numbers |
   | `--mode lab` | on the hidden desktop (`tools/hidden_desktop.py`), small, low | **muted** | `gamelab/env/settings/lab/` | nobody | **verified end to end offscreen and muted**: a scenario passes while no top-level window of the launched tree exists on the input desktop, the foreground window never belongs to that tree (sampled for the whole run), mute is confirmed in the loaded settings, and a `PrintWindow` capture of the hidden window is a correct image |

   Watch mode exists because a human watching the bot play gives faster, better feedback
   than reading a results folder. It is only ever started by a human. **Programmatic
   runners — the scenario runner, promotion, CI, any agent-invoked run — always pass
   `--mode lab` explicitly**; the watch default is for a person typing the command. Lab
   mode is the only mode a test may be promoted from (Phase 6b).

   **Preflight, in this order, before the game process starts** — any failure aborts the
   launch:
   1. `python tools/saves.py backup` (Phase 7)
   2. build-id gate against `gamelab/build_id.json` (Logging discipline, below)
   3. `python tools/env_link.py --verify` (item 7)
   4. environment resolution + redirect verification (item 9)

2. **Command channel** — how the harness drives the running game: console commands
   exposed by a mod, a file-based command queue the mod polls, or a TCP/named-pipe
   server inside a mod. Pick the simplest one the engine allows. The front door (boot
   dialogs, main menu, quit confirms) is *also* driven through the channel: loaders
   inject before the front-end menu exists, so invoke the menu widgets' own click
   handlers from the mod (see **Input emulation** below) — never OS-level clicks at
   screen coordinates.
3. **Scenario system** — declarative scenario definitions in `gamelab/scenarios/`: spawn
   these entities, place the player here, set this inventory/loadout, then run behavior X.
   Complex world state comes from **fixture saves**, and fixtures are **recipes, not
   binaries**:

   - `gamelab/fixtures/<name>.json` — **committed.** A declarative recipe naming every
     variable of the world state: seed, player placement, entities, loadout, and the
     run-state variables MECHANICS.md lists (Phase 5). The fixture builder materializes
     it from a fresh save through the command channel, using the game's **own
     functions** (create character, equip by id, pick skills, apply buffs, start the
     level). Binary save editing is limited to an enumerated list in the recipe schema
     of things the game cannot do in-game (typically: enabling the mod itself).
   - `gamelab/fixtures/cache/<name>.<build_id>.sav` — **gitignored.** The materialized
     save. Built on first use, reused after, and **keyed by build id so a game update
     invalidates it automatically** rather than silently feeding a stale world into a
     run. It is an optimization, never the source of truth.

   A recipe survives patches and save-format changes; a checked-in `.sav` does not, and
   binary saves in git are permanent weight. **After materialization every recipe field
   is read back through the state probes (item 5); any mismatch fails the run.** A
   recipe that cannot be fully materialized is a failing recipe, not a partial fixture
   and not a committed `.sav`.

   The harness must be generic across the game's modes — a game with racing + open-world
   sandbox + rock climbing needs scenario primitives for each mode, discovered in Phase 5.
   The player's real save is never touched by a scenario (item 9); the backup in Phase 7
   is insurance, not the mechanism.
4. **Instrumentation** — a mod emits structured events (JSON lines): damage, deaths,
   timings, positions, loot acquired. Telemetry beats screen-reading.
5. **Observer** — two layers, and you need both.
   **(a) State probes — build these, and build them early.** A mod-side, read-only,
   *pull* API that renders live game state as structured data: player vitals/position,
   inventory, nearby entities with distances, the current level/biome/clock, the **UI
   widget tree** (classes, labels, hitboxes — the game's DOM), and an ASCII grid of the
   terrain around the player. Pair it with a **generic reflective inspector**: resolve an
   arbitrary dotted path through the live object graph (`player.buffManager`,
   `level.entityManager.mobs[0]`, `world.quests`), plus a `members` call listing an
   object's fields with value previews and its no-arg accessors. That is a debugger, and
   it is what you need when a scenario fails for a reason nobody anticipated.
   Two hard rules for the inspector: **read-only by construction** (allowlist accessor
   name prefixes — `get/is/has/can/count/size/stream/to` — so it can never invoke a
   mutator; an observer that can change what it observes is not an observer) and
   **bounded by construction** (depth, per-collection item caps, a total node budget,
   identity cycle detection — the object graph of a running game is effectively infinite;
   report what you truncated rather than silently dropping it).
   Add a harness-side **adapter** that renders the JSON as compact text: assert against
   the dicts, read the text.
   *Why this matters:* measured on Necesse, one screen was 3.2 KB as a UI tree versus
   929 KB as a PNG — ~290x cheaper, exact instead of approximate, and only the tree
   carried button labels and hitboxes. Probes also see state the game never draws (a
   mob's exact remaining health, a container's loot seed, whether the server thread has
   the level loaded at all). The UI-tree probe is what makes the front door
   (component 2) discoverable without OCR, and it is what gives component 8 a target to
   click that isn't a screen coordinate.
   **(b) Screenshots and log tailing** — the Phase 4 skill fired at key moments. Not
   obsolete: probes read the *model*, screenshots read the *renderer*. They are the
   independent cross-check, and when the two disagree the run is invalid. Assert on
   probes; screenshot to confirm the game is really drawing what the numbers claim.
6. **Scoring** — assertions (pass/fail) and metrics per run, written to
   `gamelab/results/<run>/` so iterations are comparable over time. **The probe-versus-
   screenshot agreement check is itself an assertion**, not a habit — a run where the two
   disagree is reported `INVALID`, distinct from `FAIL`, and never averaged into a metric.
   Each run directory records the environment name, the build id it ran against, the
   fixture recipe and its cache key, and the mod versions deployed.
7. **Game Settings — the user's install is untouchable.**
   The user must be able to launch and play their game normally — their graphics,
   controller, keybinds, audio and gameplay settings — at any moment, including while a
   GameLab run is in progress. GameLab therefore never writes to the game's real config
   or user-data directory. It runs against its own, and reaches the shared read-only
   parts of the install through filesystem links.

   GameLab's own profiles live in **`gamelab/env/settings/`** (committed), one per launch
   mode. `settings/lab/` is: windowed, smallest viable resolution, lowest graphics
   preset, intro movies skipped, and **master plus every audio bus muted to zero** — the
   user must never hear the harness testing. `settings/watch/` is: windowed at a real
   resolution, sound on, intro movies skipped. Both are GameLab's own, never the user's.
   The mute assertion below applies to lab mode; watch mode asserts the watch profile
   loaded instead.

   Every link between the project and the real install is declared in the environment
   manifest (item 9) and created/verified idempotently by **`python tools/env_link.py
   --verify`**, which runs in launcher preflight. Never hand-create links; an undeclared
   link is how a "sandboxed" run ends up writing to the player's save directory.

   **Preflight assertions, all three, every launch:**
   1. The live process's user-data dir resolves **inside** `gamelab/env/` — read it off
      the running process, not off the args you *intended* to pass. If a redirect flag is
      ignored, the harness is running against production; abort.
   2. The real user config dir's hash is unchanged after the run (recorded before,
      checked after). A changed hash is a run-invalidating defect, reported as such.
   3. In lab mode, audio is muted in the settings actually loaded, not merely in the
      file on disk. In watch mode, the watch profile is the one loaded.
8. **Programmatic Hands — emulated clicks and presses.**
   In order to run tests using your 'hands', build a bulletproof custom API for
   interacting with the game via **emulated** mouse clicks and keyboard presses. One
   sentence governs the whole component:

   > **GameLab never touches the real keyboard, mouse, or window focus.**

   Everything else is implementation, and more than one implementation is valid. Pick the
   simplest that works on this engine; combine them where useful:

   | Approach | What it does | Notes |
   |---|---|---|
   | **Widget / action layer** | Invoke the widget's own `OnClicked` delegate, or the model-layer function behind a screen | Highest level, most reliable. The default for UI. |
   | **Engine input pipeline** | Inject synthetic key/button/axis events into the engine's own input handler from inside a mod | Exercises the real input path below keybinds — catches binding and input-context bugs the widget layer masks |
   | **Focus-free OS message emulation** | `PostMessage`/`SendMessage` addressed to the game's window handle | Legitimate: it never moves the real cursor and never raises the window. Needs the right HWND (see window topology, Phase 3). |

   **Banned, regardless of layer:** `SendInput`, `keybd_event`, `mouse_event`,
   `SetCursorPos`, `SetForegroundWindow`, and anything else that moves the physical
   cursor, types into whatever happens to be focused, or raises the window. The test is
   not which layer you chose — it is whether a user typing in another window would notice
   the run happening.

   In the past you have falsely 'declared' simulating mouse clicks or keyboard events
   isn't possible, whether that's because it's a custom game engine or a more advanced
   one. I have never observed in the wild a video game you cannot send synthetic inputs
   to. Be cautious to provide hard facts to back your claim if you decide you cannot
   fulfill the *hands* requirement — and those facts go in a dated `docs/RE_NOTES.md`
   entry naming every approach in the table above, what was tried, and how it failed.
9. **Fully Isolated — three environments, declared in one file.**
   This is a test environment; treat it as such. Three environments exist, permanently
   and separately:

   | Env | What it is | Mods | User data |
   |---|---|---|---|
   | `vanilla` | The player's clean install | none | the player's real saves/config |
   | `modded-prod` | The player's *modded* play install | the curated play mod set, **no GameLab mods** | the player's real saves/config |
   | `gamelab` | The dev/test environment | GameLab mods only | `gamelab/env/userdata/`, fixtures only |

   They are declared once, machine-readably, in **`gamelab/env/environments.json`** — the
   launcher's source of truth, not prose:

   ```json
   {
     "vanilla":     { "game_dir": "<install>", "user_data": "<default>", "mods": [] },
     "modded-prod": { "game_dir": "<install>", "user_data": "<default>", "mods": ["..."] },
     "gamelab": {
       "game_dir": "<install>",
       "user_data": "gamelab/env/userdata",
       "isolation": { "mechanism": "arg", "detail": "-UserDir=<abs>", "verify": "live process command line" },
       "mods": ["gamelab-probe", "gamelab-hands", "gamelab-pilot"],
       "links": [
         { "type": "junction", "from": "gamelab/env/settings", "to": "<userdata>/Config" }
       ]
     }
   }
   ```

   `isolation.mechanism` is one of — pick the first that works on the engine:
   1. **`arg`** — the game relocates its whole user-data tree on a flag
      (Unreal: `-UserDir=`). Cheapest, preferred.
   2. **`env`** — an environment variable redirects the profile dir.
   3. **`link`** — junction/symlink the user-data dir at launch and restore it after.
      Requires the swap be crash-safe: restore on exit *and* on next preflight.
   4. **`copy`** — a frozen copy of the game dir, modded independently. Expensive; the
      fallback when nothing else isolates.

   `isolation.verify` names how the redirect is confirmed **on the live process**, and the
   launcher aborts when it can't confirm it. An isolation mechanism with no verify string
   is not an isolation mechanism.

   **Per-test isolation** is separate from per-environment isolation and equally required:
   each scenario starts from a declared fixture and a wiped scratch area, and the runner
   refuses to start a scenario whose predecessor did not report a clean teardown. Each
   test carrying over state from another test is a recipe for disaster, and state carried
   in from the real production game environment is worse.

### Input emulation — never the real keyboard, mouse, or focus

**Hard rule: GameLab never touches the real keyboard, mouse, or window focus.** No
forcing the game window to the foreground; synthetic input for testing is entirely fine
(component 8 defines the legitimate paths). The entire point of the harness is unattended
automation — real input hijacks the user's machine, breaks the moment the window loses
focus or is minimized, and turns "automated" runs into runs that need a babysitter.
Everything the player could do must instead be *emulated*, preferring the in-game path:

- **Movement** — feed the engine's per-tick movement-input API directly, on a
  self-rescheduling timer chain (≈ a held movement key). This produces exactly what
  the input system would have.
- **Aim / steer** — set the camera/control rotation through the game's own API, not
  mouse deltas.
- **UI** — call the widget's own handlers: button `OnClicked` delegates, the
  model-layer functions behind a screen (e.g. "select recipe + start production"
  instead of clicking through the crafting menu). Menus, boot dialogs, and quit
  confirms are all reachable this way because the loader is in before the front end.
- **Actions & state** — prefer the game's real action entry points (interact/mount/
  respawn functions, state setters) over pixel-hunting for prompts.
- **Screenshots are fine** — capture must be passive/focus-free (Win32 `PrintWindow`
  works occluded and steals no focus). Observation is allowed; *real* input is not.

Two hazards discovered the hard way: emulated input runs *in the mod's script VM*, so
a too-tight per-frame loop can deadlock every script the loader runs — prefer
self-rescheduling timers over raw per-frame loops. And script-language clocks may
measure CPU-time, not wall-time — count ticks for deadlines. Concrete APIs and
loader-specific hazards live in the Per-engine notes below.

If a path can't be reached in-engine, drop to the engine's input pipeline or to
focus-free window messages (component 8) — in that order. What is never acceptable is
real device input: `SendInput` and friends stay banned no matter how stuck the path is,
and "I couldn't reach it in-engine" is a reverse-engineering TODO plus a dated
`RE_NOTES.md` entry, not a license. OS-input tools may exist in `tools/` strictly as
manual, human-invoked recovery aids — never called by scenarios or the harness.

### Logging discipline

In-depth logging is required from every component — logs are the primary evidence when
a scenario fails silently or the game crashes.

- **One known file per component.** Each mod and the harness log to a fixed, documented
  path (harness → `gamelab/results/<run>/`; mods → the loader's log dir). List every
  path in `docs/MODDING_NOTES.md`; the harness tails them all.
- **Version header first, and the build id must GATE, not just print.** Every log opens
  with game version + build id + mod version at startup. Untagged logs can't be compared
  across runs.

  A build id that is only *printed* is not an update detector — it is a number in a log
  nobody diffs. The pin is a file, and the runner enforces it.

  **`gamelab/build_id.json`** — committed, the single source of truth:

  ```json
  {
    "app_id": "1623730",
    "build_id": "19284736",
    "game_version": "0.6.3.51730",
    "engine_version": "UE5.1.1",
    "pinned_at": "2026-07-15",
    "pinned_by": "re-dump after 0.6.3 patch; datatables + SDK regenerated",
    "probe": {
      "build_id": "steamapps/appmanifest_1623730.acf::buildid",
      "game_version": "process file version: Pal-Win64-Shipping.exe"
    }
  }
  ```

  **Preflight, every GameLab launch, before the game starts:** read the live values via
  the `probe` paths and compare to the pin. On mismatch the runner **exits non-zero with
  a dedicated code (`EXIT_BUILD_MISMATCH = 3`) and does not launch the game.** Not a
  warning, not a log line — a refusal. `--accept-build-drift` may override it for one run
  and must stamp `"build_drift": true` into that run's results so the run is never
  mistaken for a clean one.

  **Re-pinning is deliberate:** `python tools/pin_build.py --reason "<why>"` rewrites the
  file and requires a reason string, which is the prompt to actually re-dump. An
  unnoticed update silently invalidates every dump, offset and measured fact in the
  project, and the runs keep looking clean the whole time. Failing loudly on mismatch is
  the only version of this rule that does any work.
- **Log the edges:** every command received, hook fired (with inputs/outputs), and
  state transition, timestamped. Cheap to write, decisive after a crash.
- **Structured for scoring, prose for debugging:** JSON-lines telemetry feeds the
  scorer (Instrumentation, above); everything else stays human-readable.

### Reference scenarios

- **Bot-vs-bot (Star Valor):** the enemy AI was applied to the player's own ship, so a
  dogfight test could spawn enemies of chosen difficulty and the player ship fought back
  automatically. That closed loop — spawn, fight, collect effectiveness data — drove AI
  improvement with zero human piloting.
- **Simple interaction (Vein):** the player opens one container in the environment (a
  bedside table) and loots it. Minimal scenario, validates the whole
  spawn→act→observe→assert pipeline before anything ambitious.

Build the *simple interaction* scenario first for any new game — it's the smoke test for
the entire GameLab stack.

### Design rules

- **Deterministic:** fixed seeds, fixed spawns, fixture recipes. A flaky harness is worse
  than none.
- **Fast:** smallest viable map/arena, auto-skip menus. Time-scale acceleration only
  after the Pilot intake's rule is met: the same scenario produces the same result at
  1× and at N×, measured, before N× is used for anything.
- **Unattended:** scenarios end themselves (win/lose/timeout), report results, and quit
  or reset. Include a hard timeout + crash detection (process exit code, log heartbeat).
- **Hands-off:** never the real keyboard, mouse, or focus (see Input emulation above) —
  the run must work with the game backgrounded or minimized while the user does something
  else on the same machine.
- **Honest:** when telemetry and screenshots disagree, the run is `INVALID` — investigate,
  don't average.
- **Isolated environments:** the three environments of item 9, declared in
  `gamelab/env/environments.json` and verified on the live process every launch.

### Deliverables — Phase 6

| Path | Contents | Gate |
|---|---|---|
| `gamelab/` launcher | `--mode watch` (default, visible, focus-free) and `--mode lab` (hidden, muted); intro-skipped; runs the 4-step preflight | Aborts on any preflight failure; lab mode proven offscreen + muted with foreground sampled for the whole run |
| Command channel | Harness → running game, front door included | Drives boot dialog, menu, quit without real input |
| `gamelab/scenarios/` | Declarative scenarios, generic across the game's modes | Smoke scenario present and green |
| `gamelab/fixtures/<name>.json` | Declarative fixture **recipes** (committed); binary edits limited to the schema's enumerated list | Rebuild the same world from a fresh save, deterministically; every field read back through the probes, any mismatch fails the run |
| `gamelab/fixtures/cache/` | Materialized `.sav`, keyed by build id (gitignored) | Invalidates automatically on build change |
| Instrumentation mod | JSON-lines telemetry | Damage, deaths, timings, positions, loot |
| State probe mod | Vitals, position, inventory, entities, clock, **UI widget tree**, terrain grid | Read-only allowlist + depth/caps/budget + truncation reporting |
| Reflective inspector | Dotted-path resolve, `members` | Cannot invoke a mutator, by construction |
| `gamelab/results/<run>/` | Assertions, metrics, env name, build id, fixture key, mod versions | Probe-vs-screenshot disagreement recorded as `INVALID` |
| `gamelab/env/settings/lab/`, `settings/watch/` | Lab: windowed, low, **muted**. Watch: real resolution, sound on | Lab mute verified in loaded settings, not just on disk; the mode's profile is the one loaded |
| `gamelab/env/environments.json` | All three envs, isolation mechanism + verify string, link list | Redirect confirmed on the live process or abort |
| `gamelab/build_id.json` | Pinned build + probe paths | Runner exits `3` on mismatch |
| `mods/gamelab-hands` | Emulated key/mouse verb set | Proven by a scenario with the window minimized and unfocused |

## Phase 6b — Pilot: the player bot

**Pilot** is the standardized name for the scriptable player bot, in every project. It is
the completion of Phase 6: the hands, eyes, and command channel exist so that a script
can play the game, and a bot that completes a gameplay loop unattended is the only
convincing proof that they work. It is also the human feedback loop: the user watches
the bot play in watch mode, says what it did wrong, the agent revises the script, and
the loop repeats without a game restart. Once the user is happy, the same script
becomes an automated test. Think Screeps for the API surface and PowerBot's webwalker
for travel.

`mods/gamelab-pilot` **builds on `mods/gamelab-hands`**: hands owns the primitive
emulated inputs (press, move axis, click a widget handler); pilot owns the verbs that
compose them over many ticks (kite, path_to, use) and the eyes. Pilot never bypasses
hands to reach the input layer, so the hands gate still proves the primitives.

### Intake interview — first, with defaults

Before any Pilot code, answer the capability list below for this game and record it in
the README. Each item is **in**, **out**, or **later**. The defaults are sane; the user
may accept them wholesale in one line ("defaults") instead of answering item by item.
The agent never builds a capability the user did not ask for and never skips one the
user did because it assumed the game did not need it.

| Capability | Default | Gate when **in** |
|---|---|---|
| Combat verb: kite (hold distance while attacking) vs. stand and fight | kite | the chosen verb exists and the first bot uses it |
| Threat / aggro-radius avoidance in pathing | in | a scenario where the straight path crosses an aggro circle and the bot's path does not |
| Cross-level travel (transition graph) | in | a scenario that starts in one level and ends in another via `path_to(level, point)` |
| Consumable use (potions, food, buffs) with thresholds | in | a `use` verb and one interrupt (`hp_below`) that triggers it, exercised in a scenario |
| Looting and inventory management | later | — |
| Does the game have networked multiplayer? | yes | the networked tier exists (see Multiplayer tiers); **"no" removes it** |
| Watch-mode overlays: which of the engine's own debug draws to enable | in | listed in the README; zero code, the game draws them |
| Time-scale acceleration | later | the same scenario gives the same result at 1× and N×, measured, before N× is used |

An item marked **out** or **later** gets no code, and its Deliverables row and checklist
box are ticked **N/A per intake** — that is a legitimate tick for P8. Revise this list
the first time a game needs a question that is not on it. The control surface is not
on the list: it is part of watch mode and always built.

### Architecture — reflex in the mod, strategy outside

The split is **latency**. Anything that must react within a tick or two lives in the
mod, in the game's script language. Anything that decides what to do next over seconds
lives in Python, outside the game. The test: if it would still work correctly when
issued once per second, it is strategy; if not, it is reflex.

**`mods/gamelab-pilot` — the reflex layer, in-engine, focus-free:**

- Per-tick input through `gamelab-hands`: move direction, aim, attack and skill press
  (Input emulation rules apply unchanged).
- The combat verb the intake chose. Kiting cannot live in Python: a round trip over
  the channel is several frames late.
- Pathfinding and path following: the engine's own pathfinder where it exposes one
  (most do, because enemies use it); doors, stairs, and portals handled per game.
- **Eyes**: entity enumeration via the engine's spatial queries and raycasts.
- Safety interrupts: stop if dead, if a menu opened, if the level is loading.
- Each verb is a **long-running intent** the mod carries out on its own ticks until it
  completes, fails, times out, or an interrupt fires.

**`gamelab/bots/<name>.py` — the strategy layer, in Python, restart-free:**

- The script the agent writes: "clear this floor", "go to the boss door", "farm until
  full". Composition of verbs plus the conditions that interrupt them.
- Scenario selection: which fixture recipe, which build, which level. Already GameLab's.
- Assertions and scoring once promoted to a test.
- Coordination of several bots across game instances for multiplayer tests, which
  cannot live inside one game process anyway.

Python issues intents at a few Hz and reads state snapshots back. **Python never sends
raw inputs.**

### Eyes — semantic by default, raw underneath

`scan()` returns typed lists built from the game's **own data** (team, slot, behavior
class as declared in its unit definitions), never from name heuristics: enemies with
threat and aggro radius, allies, loot, interactables (doors, chests, shrines), hazards
with their areas, exits. Each category's source field is written next to it in the
mod. The raw entity list sits underneath for when a category is missing or wrong; the
agent uses raw to discover a new category and then promotes it into the semantic
layer, once, in the mod.

### Travel — two layers, honest about unknown routes

- **In-level**: the engine pathfinder, wrapped as `path_to(point)`.
- **Cross-level**: a transition graph, `path_to(level, point)`, merged from two committed
  files under `gamelab/travel/`: `authored.json`, generated by a tool from extracted
  level data for fixed levels (town, hubs), and `learned.json`, which the mod appends
  to when the player or bot takes a transition it did not know (exit position,
  destination). Generated levels are keyed by **level template**, not by the instance
  id a seed produced, so an edge learned on one seed applies to the next.
- A scenario **pins** the graph revision it ran against in its results, and a scenario
  run never writes to `learned.json` — learning is a watch-mode or dedicated
  exploration-run activity, so results stay deterministic.
- "No known route" is a **returned result** (`no_route`) the script handles, never a
  silent wander.
- If threat avoidance is in: the semantic scan feeds aggro circles into a cost map and
  the mod re-paths when one intersects the path. The engine's nav graph does not know
  about enemies; that layer is ours.

### The script API — blocking verbs with declared interrupts

Scripts read top to bottom. A verb blocks until done, failed, or timed out, and takes
the conditions that should interrupt it. **Interrupts are a closed vocabulary defined
in the mod** (`under_attack`, `hp_below(x)`, `target_dead`, `level_changed`,
`inventory_full`, … grown per game); the Python client rejects anything else, so every
condition is checked **in the mod every tick**, never by a Python callback. Every verb
returns one of `done | failed | timeout | interrupted(<condition>) | no_route`, and the
script branches on it:

```python
r = bot.path_to(exit, until=[bot.under_attack, bot.hp_below(0.3)])
if r.interrupted == bot.under_attack:
    bot.kite(bot.scan().enemies.nearest, until=[bot.target_dead, bot.hp_below(0.3)])
```

A simple script first, then complexity by naming more interrupts. The interrupt set
doubles as the assertion vocabulary when the script becomes a test. Do **not** build a
per-tick callback model (Screeps-style `on_tick`): every script then re-implements its
own state machine and a kiting script becomes forty lines of bookkeeping.

### Watch mode and the control surface

In watch mode the bot runs visibly with the engine's own debug overlays the intake
listed (nav data, collision, line of sight — whatever draws what the bot sees; no code
of ours) and a minimal **control surface** in the mod: **pause**, **single-step**, and
**click-to-override the target**. Nothing more in the first version; parameter editing
waits until a script has needed it. Telemetry is written exactly as in lab mode, so
"it got stuck at the door" becomes a tick number the agent can look up.

### Fixtures for a full build — materialized in-game, fail closed

A scenario the bot loads into carries **every run-state variable MECHANICS.md lists**
(Phase 5, "Run-state variables") — that list is the recipe schema. The recipe is the
committed declarative file of Phase 6 item 3, materialized through the game's **own
functions**, binary save editing limited to the schema's enumerated list, every field
read back through the probes, any mismatch failing the run. A silent partial fixture
is how a test passes against a state nobody intended.

### Promotion — the same script, plus assertions

A scenario file is: the fixture recipe + the bot script + a list of assertions over
telemetry ("floor cleared", "no deaths", "under 90 s"). Watch mode and lab mode run the
**identical** script; promotion is adding the assertions and committing under
`gamelab/scenarios/`. **A scenario is promotable only after it has passed once in lab
mode, hidden and muted** — a script that only ever ran in watch mode may depend on
something watch mode provides (a real resolution, the sound engine, a human nudge).

### Multiplayer tiers

| Tier | How | Covers | Does not cover |
|---|---|---|---|
| **Local sessions** | several bots as local players in one process | the fast loop, runs on every change, one machine, deterministic | **network sync at all** — server-authority bugs stay invisible |
| **Networked** | host on one machine, client on another, each with its own bot, Python coordinating over the LAN, one shared results format | **the gate for every change that touches shared state** (Phase 7) | unattended runs on one PC |

Results record which tier a scenario ran in. Only the networked tier tests netsync.

### Deliverables — Phase 6b

| Path | Contents | Gate |
|---|---|---|
| `README.md` — Pilot intake | Every capability answered in / out / later, or "defaults" | Recorded before any Pilot code |
| `mods/gamelab-pilot` | Verbs (move, attack, the combat verb, path_to, scan, use), closed interrupt vocabulary, control surface, telemetry | Every verb is in-engine and focus-free; a verb that cannot be reached in-engine is a dated `RE_NOTES.md` entry, not real input |
| Eyes | Semantic `scan()` from unit data + raw list | Each category names the unit-definition field it comes from |
| Travel | In-level `path_to`; `gamelab/travel/authored.json` + `learned.json` | `no_route` returned, never a wander; after an exploration run that took a new transition, that edge is in `learned.json`; scenario results pin the graph revision |
| Intake capabilities marked in | Avoidance, cross-level, consumables, time-scale | Each passes the gate in the intake table, or is ticked N/A per intake |
| Python client | Blocking verbs with `until=` from the closed vocabulary; results `done / failed / timeout / interrupted / no_route` | A script revision needs **no game restart**; an unknown interrupt is rejected client-side |
| `gamelab/bots/<name>.py` | The first bot: one gameplay loop from MECHANICS.md, named in the scenario, using the intake's combat verb if the loop has combat | Reaches the loop's **terminal telemetry event** unattended in **lab mode** |
| Watch-mode feedback loop | One recorded session: user watched, gave feedback, agent revised | The revision ran without a game restart, telemetry tick cited in the feedback |
| Fixture recipe | A full-build recipe for this game over the MECHANICS.md run-state schema | Every field read back through the probes or the run fails; cache keyed by build id |
| Promoted scenario | The bot script + assertions under `gamelab/scenarios/` | Green in lab mode, hidden and muted, telemetry and screenshots agreeing |
| Multiplayer | Local-sessions scenario; networked scenario when the intake says the game has multiplayer | Local green; networked green across two machines; tier recorded in results |

## Phase 7 — The dev loop

- Write **`tools/deploy.py`**: build/copy mod artifacts into the game's mod location in
  one command, targeting a named environment (`python tools/deploy.py --env gamelab`).
  It refuses to deploy GameLab mods into `modded-prod` or `vanilla`. Document the reload
  trigger honestly (full restart? hot reload? map reload?).
- The loop: **edit → deploy → GameLab scenario → results + screenshots → refine.**
- **Saves are backed up by a tool, not by intention.** `python tools/saves.py` is a
  required deliverable with three subcommands:

  | Command | Does |
  |---|---|
  | `backup` | Copies the player's real saves to `saves-backup/<ISO-timestamp>/` if their hash differs from the newest existing backup. No-op when unchanged. |
  | `restore [--from <ts>]` | Restores the newest (or named) backup over the real save dir, after backing up whatever is currently there. |
  | `verify` | Asserts the real save dir's hash matches the newest backup — the post-run check. |

  `saves-backup/` is committed: the player's save history is worth more than the repo
  size, up to the cap declared in the README (Phase 0). `backup` enforces the cap.

  **`backup` runs in launcher preflight on every GameLab launch**, immediately before the
  game process starts — that is the only moment at which the save about to be loaded is
  knowable. A failed backup aborts the launch.

  **When the dev loop is done, `restore` runs** so the user resumes play as if the loop
  never happened. Better still: with the `gamelab` environment isolating user data (Phase
  6 item 9), scenarios load fixture saves out of the GameLab user-data dir and the real
  save is never opened at all — at which point `backup` is insurance rather than the
  primary defence. That is the target state.
- Every work session ends by updating `docs/RE_NOTES.md` (new findings) and the README
  status checklist.
- **Shared-state changes gate on the networked tier.** A change that touches replicated
  or shared state — anything the host and a client must agree on — is not done until
  its networked Pilot scenario (Phase 6b, Multiplayer tiers) is green. Local sessions
  do not count for this; they never exercise netsync.

### Deliverables — Phase 7

| Path | Contents | Gate |
|---|---|---|
| `tools/deploy.py` | One-command build + install, env-targeted | Refuses cross-env deploys; reload trigger documented |
| Shared-state rule | Every mod change touching shared state names its networked scenario | That scenario green before the change is called done |
| `tools/saves.py` | `backup` / `restore` / `verify` | `backup` wired into launcher preflight |
| `tools/env_link.py` | Creates + verifies declared links idempotently | `--verify` wired into launcher preflight |
| `tools/pin_build.py` | Re-pins `build_id.json`, requires `--reason` | — |
| `docs/RE_NOTES.md`, `README.md` | Session findings + status | Updated at the end of every work session |

---

## Per-engine notes

Generic modding knowledge specific to one engine — reusable across every game on that
engine. Measurements are cited by the game and build they were taken on, because a
measurement without its provenance is a rumor; the rule itself stays engine-level.
The phases above stay engine-neutral and point here.
A new engine's subsection gets seeded the first time we mod a game on it (unseeded
engines are listed under Future work). **Seeding is written to
`~/.claude/playbooks/game-modding-playbook.md`** — the global playbook, not the project's
`PLAYBOOK.md` copy, which is a snapshot and does not flow back.

### Unreal (UE 4.12–5.x · loader: UE4SS)

- **Launch config:** CLI args reach the engine **via `steam.exe -applaunch <appid> <args>`**;
  they are dropped only on the direct-exe path, where `SteamAPI_RestartAppIfNecessary`
  relaunches through Steam and discards argv. `-UserDir=<dir>` is the one that matters
  most: it relocates `Saved\Config`, `Saved\SaveGames` and `Saved\Logs` together, which is
  how a dev session gets its own windowed/muted profile, its own fixture saves and its own
  keybinds without ever touching the player's (Phase 6 items 7 and 9). This is the
  canonical `isolation.mechanism: "arg"`. Confirm the redirect on the **live process
  command line** and abort if it is absent — an ignored `-UserDir` means the harness is
  running against production.
- **Window topology:** the game viewport may not be the process's
  `MainWindowHandle` — e.g. Palworld's game window is titled `Pal` while the UE4SS
  console owns the main handle. This is also the HWND that focus-free window-message
  input (Phase 6 item 8) must target; the wrong handle silently swallows every message.
- **Code accessibility profile** (the Phase 3 tiers as they land on UE):
  1. *Data (full fidelity)* — assets, data tables, configs extract to clean JSON;
     feeds MECHANICS.md and data mods directly.
  2. *Native C++ (structure only)* — and that includes the **studio's own gameplay
     module**, not just the engine (Palworld ships 2,000+ `Pal` classes in the exe
     alongside UE). Reflection/SDK dumps give exact class layouts, property offsets,
     and function *signatures* — never bodies. The actual formula math lives here.
  3. *Blueprints (partially opaque)* — properties and signatures dump fine; Kismet
     bytecode decompilers are PoC-quality. Observe tiers 2–3 at runtime instead:
     UE4SS Live View, Lua `RegisterHook` + logging, GameLab probes.
- **Extraction extras** (beyond the Phase 3 tooling table): blueprint dumps (FModel
  exports blueprint assets as JSON), map/level object lists, `Config/*.ini` defaults.
- **Input emulation** (the Phase 6 rule, UE implementation, driven from UE4SS Lua):
  movement = `pawn:AddMovementInput(dir, scale)` per tick (≈ a held movement key);
  aim/steer = `pc:ClientSetRotation`; UI = invoke the widget's `OnClicked` delegates
  and the model-layer UFunctions behind a screen.
- **UE4SS Lua hazards:** never drive per-frame work with `LoopAsync(16ms)` +
  `ExecuteInGameThread` — one runaway loop can freeze *all* Lua mods at once, while the
  game keeps rendering happily (game-restart-only recovery). Same trap from the other end:
  no filesystem I/O on the game thread; queue in memory and flush from the async side.
  And the subtle third form: **slow polls are still felt.** An `ExecuteInGameThread` poll
  at even 1–4 Hz (a `FindFirstOf` + some reflected reads) produces micro-hitches that a
  player on G-Sync/VRR perceives as sluggish, juddery play while average FPS stays
  "decent" — confirmed by blind A/B on Palworld 2026-07-15 (docs/RE_NOTES.md), where
  bare UE4SS with every `[Hooks]` key on was indistinguishable from vanilla but two
  1–2 Hz polling mods were not. The rule: **a mod's steady-state game-thread footprint
  must be zero while its feature is disengaged.** Hooks are event-driven and free —
  prefer them; where a poll is unavoidable, gate it on the async side so skipped ticks
  never enter `ExecuteInGameThread` at all (check a flag, `T.flush()`, return), back off
  the cadence once a one-shot fix lands (CDO patch, option set), and dedupe telemetry
  snapshots so an idle mod does zero disk writes.
  The **Delayed Actions API** (UE4SS 4.x: `LoopInGameThreadWithDelay` /
  `ExecuteInGameThreadWithDelay` + `CancelDelayedAction`) is the supported fix — a
  cancellable, per-mod-owned loop; upstream deprecates `ExecuteAsync`/`LoopAsync` in its
  favour. A self-rescheduling `ExecuteWithDelay` chain still works where it isn't available.
  Lua `os.clock()` is CPU-time, not wall-time — count ticks for deadlines. `_G`
  persists across script executions within a mod's Lua state (per-mod isolated).
- **Don't trust the loader's version string.** Check what the build actually ships (its
  bundled Lua type definitions, the commit its SHA resolves to) before concluding an API
  doesn't exist — a fork can carry a stale version constant over a recent binary. (Palworld's
  UE4SS reports `v3.0.1 Beta` and is built from a 2026-07 commit with the current 4.0.0 API.)
- **Still to document** (Future work): pak/IoStore formats & encryption checks,
  usmap mappings workflow, BPModLoader & LogicMods, cooking with a devkit, `_P`
  patch-pak priority rules.

### Unity (IL2CPP · loader: BepInEx 6)

- **The loader version is not a choice.** BepInEx 5 is Mono-only; BepInEx 6 has no
  stable release. IL2CPP means a **bleeding-edge build** (`6.0.0-be.<n>`) from
  `builds.bepinex.dev`, pinned by URL and zip SHA-256 in the install script. MelonLoader
  is the credible alternative; BepInEx wins on ecosystem size and on supporting two
  independent roots in one install (below).
- **BepInEx derives its entire root from the assembly Doorstop invokes.** Not from a
  config key, not from the working directory — from `--doorstop-target-assembly`. This
  is the single most useful fact about the stack: installing a **second complete BepInEx
  root** beside the first (`BepInEx/` and `BepInEx-GameLab/`) gives the harness its own
  `plugins/`, `config/`, `interop/`, `cache/` and log, selected per launch by one
  argument. The player-facing mod set and the test harness then coexist in one install
  and cannot contaminate each other. Enforce it at the deploy tool: each mod declares
  which environments it may be installed into.
  - `dotnet/` must stay **shared at the game root**: `doorstop_config.ini` resolves
    `coreclr_path` relative to the *exe*, not to the BepInEx root, so a per-root copy is
    never found.
  - Leave the shipped `doorstop_config.ini` at `enabled = false`. A bare double-click is
    then an unmodded run, and every modded run passed the flag explicitly.
- **Save isolation has no engine-level flag.** Unity's `persistentDataPath` derives from
  company/product and cannot be moved by argument or environment variable — there is no
  `-UserDir` equivalent. The reliable mechanism is a **Harmony postfix on whatever single
  method the game funnels persistent writes through**; find it first, because many Unity
  games have one (a `GetSaveRootPath()`-shaped thing), and patching it usually relocates
  the settings profile along with the saves. `isolation.mechanism: "harmony-postfix"`.
  Make it fail closed: throw when a redirect is requested with an empty root rather than
  falling through to the player's directory.
  - **The gap to check every time: `PlayerPrefs` on Windows is the registry**, at
    `HKCU\Software\<Company>\<Product>`, and no save-root redirect reaches it. Unity
    keeps `Screenmanager *` (resolution, window mode) there. Snapshot and restore those
    values around each run; a whole-key restore would clobber a concurrent player
    session's live values, so narrow it.
- **Screen/window arguments are standard and worth using**: `-screen-width`,
  `-screen-height`, `-screen-fullscreen 0`, `-popupwindow`, and `-logFile <path>` to
  capture each run's engine log beside its report instead of letting the next launch
  overwrite it.
- **Code accessibility profile** (the Phase 3 tiers as they land on Unity IL2CPP):
  1. *Check for shipped managed assemblies first.* Many Unity IL2CPP builds still
     include the **pre-IL2CPP managed DLLs** under
     `<Game>_BackUpThisFolder_ButDontShipItWithYourGame/Managed/`. When present, ILSpy
     decompiles them to **full-fidelity C#** and the whole "IL2CPP is opaque" problem
     evaporates. Look before reaching for Il2CppDumper/Cpp2IL.
  2. *No managed backup* — Il2CppDumper recovers structure, names and method addresses
     from `global-metadata.dat`; Cpp2IL gives pseudo-source. Structure only; bodies are
     unreliable.
  3. *Data* — design tables are often **compiled into `Assembly-CSharp`** rather than
     shipped as assets (one class per table with a static `create()` that news up every
     row). Extract by parsing the decompiled source, not by opening bundles. Where they
     *are* assets, UnityPy or AssetRipper reads them.
  4. *Localisation is a separate step.* Table text columns commonly hold **template
     keys**, not display text, resolved at runtime through a language table. Extracted
     tables full of untranslated keys are not corrupt — render an English view.
- **Il2CppInterop changes what reflection sees**, and this breaks every naive probe:
  - il2cpp **fields are emitted as C# properties**. `Type.GetFields()` on a game type
    returns essentially nothing; enumerate **properties first**.
  - Il2Cpp collections implement **no managed `IEnumerable`/`IDictionary`**. They expose
    `Count`/`Keys`/`Values` and a `GetEnumerator()` returning a nested struct enumerator,
    so enumeration must be **duck-typed** rather than cast-based. Cap the item count so a
    cyclic or huge structure cannot hang the game thread.
- **Input emulation** (the Phase 6 rule, Unity implementation): dispatch through
  `ExecuteEvents.Execute(go, pointerEventData, ExecuteEvents.pointerClickHandler)` —
  literally the call `StandaloneInputModule` makes, so it needs no real cursor, no focus
  and no window. Send `pointerDown`/`pointerUp`/`pointerClick` and report which one the
  target accepted.
  - **Do not assume `IPointerClickHandler`.** Inventory and list cells very often
    implement `IPointerDownHandler`/`IPointerUpHandler` only, and a widget probe that
    collects `Button`/`IPointerClickHandler` alone is blind to them.
  - **Send the right mouse button.** `PointerEventData.button` matters: a game whose
    consumables are used on right-click will accept a left click, report "handled", and
    do nothing — because the left handler is an empty override.
  - Fall back to `Button.onClick`/`Toggle.isOn` only for left clicks, and never silently:
    report the route taken so a regression from the pointer pipeline to the fallback is
    visible in the run.
- **Transform paths are ambiguous by construction.** Unity UIs are built from prefab
  clones, so sibling `GameObject`s legitimately share a name and one path can match
  several widgets. Dedupe the walk on `GetInstanceID()` and suffix repeated sibling names
  with `[i]`. Also match the **last path segment exactly** when counting things: a cell
  prefab usually contains child images carrying their own `Selectable`, which double
  every count taken by path fragment.
- **Panels animate (DOTween is near-universal in Unity UI).** A widget rect read the
  instant a panel opens is a point on an animation, not a position. Any check that
  compares a reported rect against captured pixels must wait for the rect to stop moving,
  and must be able to report "the widget moved across the capture" as **distinct from**
  "the renderer disagrees" — otherwise the check measures its own race.
- **Screenshots: use the engine, not the OS.** `ScreenCapture.CaptureScreenshot` (or a
  render-texture readback) from inside the process is passive, needs no focus, and works
  when the game is on a hidden desktop object. The Win32 `PrintWindow` path returns a
  uniformly **black** bitmap for a window on a non-default desktop, because desktop
  objects other than the default have no DWM compositor — however correct the capture
  code is. Keep both paths but default to the in-engine one.
- **Operational hazards:**
  - **No hot reload.** Every plugin change needs a redeploy *and* a full game restart.
  - **A running game holds its plugin DLLs open** — deploying over one fails with
    `PermissionError [WinError 32]`. Name the holding pid in the error; a generic copy
    failure costs an hour.
  - **A stale deploy is indistinguishable from a broken feature.** Have the verify step
    compare mod source mtimes against the deployed artifact and refuse to call the
    environment launchable when the DLL is behind.
  - **The plugin's channel comes up long before the UI does.** Probing on connect
    returns zero widgets and looks like a broken game. Wait on a predicate, never a sleep.
  - Each BepInEx root writes `LogOutput.log` at a fixed path **inside that root**, so a
    run's loader log is not in the run directory. When a plugin fails to load at all,
    that file — and `ErrorLog.log` beside it — is what to read.
- **Still to document:** AssetBundle/Addressables repacking, Mono (non-IL2CPP) Unity
  differences, IL2CPP metadata recovery when no managed backup ships, MelonLoader
  equivalents.

### Unity (Mono · loader: the game's own first, BepInEx 5 otherwise)

*Seeded from RimWorld 1.6.4630 (Unity 2022.3.35f1), 2026-09.*

- **Confirm Mono before choosing any tooling.** `<Game>_Data/Managed/Assembly-CSharp.dll`
  present **and** `GameAssembly.dll` absent is the positive test; the corroborating
  fingerprint is a **`MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll` beside the exe**
  (note: at the *game root*, not under `_Data`). Getting this wrong costs a day, because
  the IL2CPP notes above prescribe a completely different loader, a different decompiler
  and a different reflection strategy.
- **Look for a first-party loader before installing one.** Mono is the friendly half of
  Unity and a lot of moddable Mono games load managed mod assemblies themselves — at which
  point BepInEx/MelonLoader/Doorstop are all unnecessary weight in the stack, and skipping
  them removes an entire class of "did injection happen?" failure. RimWorld's
  `Verse.ModAssemblyHandler` walks `<Mod>/Assemblies/*.dll` and calls
  `Assembly.LoadFrom` on each, **in filename order** (which is why every RimWorld mod
  ships Harmony as `0Harmony.dll` — it sorts first, so it is loaded before the code that
  patches with it). Grep the decompiled game for `Assembly.LoadFrom` / `Assembly.Load(byte[])`
  before reaching for a loader. If there is none, BepInEx **5** is the right choice here —
  5.x is Mono-only and *stable*, the inverse of the IL2CPP situation.
- **Code accessibility profile** (the Phase 3 tiers as they land on Unity Mono) —
  **this is the easiest engine in this document, and the profile is basically flat:**
  1. *Game C# (full fidelity, tier 1)* — `Assembly-CSharp.dll` is a stock managed
     assembly. `ilspycmd <dll> -p -o gamecode/sdk/Assembly-CSharp` yields complete C#
     **with method bodies** plus a `.csproj`. No `--ai-rename-methods`, no
     `--ai-deobfuscate`, no metadata recovery, no pseudo-source. Measured on RimWorld:
     **9,217 `.cs` files, 48 MB**. The practical consequence is that MECHANICS.md can
     cite *formulas from method bodies* instead of inferring them from runtime
     observation — the fallback that dominates the Unreal and IL2CPP sections is simply
     not needed. Don't spend a runtime probe on a question that `grep gamecode/sdk`
     answers.
     Also decompile `Assembly-CSharp-firstpass.dll` and any non-Unity vendor assemblies
     in `Managed/` — they hold plugin/interop code that is easy to overlook.
  2. *Data (full fidelity, but inheritance is the whole job)* — see the next bullet.
  3. *Assets* — AssetRipper or UnityPy over `resources.assets` / `sharedassets*.assets` /
     `*.bundle`. Only needed for textures, audio and scene objects; on a Mono game the
     numbers you actually want are usually in tier 1 or 2.
- **Data extraction: resolve the inheritance, or the export is worse than useless.**
  Mono games routinely ship design data as loose XML/JSON with a **prototype-inheritance
  layer applied at load time**. A naive dump captures the leaf nodes only, and those are
  nearly empty — the leaf declares an id and a parent, and every stat lives upstream.
  Find the game's own resolver in tier-1 source and mirror its exact semantics; the rules
  are always subtler than "merge the dicts". RimWorld's `Verse.XmlInheritance`
  (`Name=` / `ParentName=`, resolved at the **XML-node** level) is representative:
  child nodes win by tag name, `Inherit="False"` on a child *suppresses* the inherited
  node, and **lists are replaced wholesale, never element-merged**.
  Prove the resolver on one leaf that inherits almost everything, and check a field you
  know must be non-empty — on RimWorld, `Gun_Revolver` declares almost nothing and must
  come out carrying `statBases`, `verbs` and `costList` from `BaseHumanMakeableGun`.
  Report **parse errors and unresolved parents as counts in the extractor output**; both
  must be zero, and a silent zero-error run that produced 200 defs where the game has
  13,000 is the failure this catches.
- **Reflection behaves normally — unlearn the IL2CPP workarounds.** Fields are fields
  (`Type.GetFields()` works), collections implement real `IEnumerable`/`IDictionary`,
  generics are real generics, and `Traverse`/plain reflection reach private state
  directly. A probe or inspector written for Il2CppInterop is over-engineered here; a
  probe written against Mono habits and then moved to IL2CPP is broken. Keep the *other*
  two constraints from the IL2CPP notes regardless, because they are about the object
  graph and not the runtime: **cap item counts** and **detect identity cycles**.
- **Save isolation: no engine flag, but check for a game one first.** As with IL2CPP,
  Unity's `persistentDataPath` derives from company/product and no argument or
  environment variable moves it. The difference is that a moddable Mono game has often
  implemented the redirect *itself*, in game code, and that is strictly better than a
  Harmony postfix: it is supported, it moves the whole user-data tree at once, and it
  usually **logs that it did**, which gives `isolation.verify` a second channel
  independent of the process command line. RimWorld's `Verse.GenFilePaths` reads
  `-savedatafolder=<abs>` and relocates `Config/` (prefs, keybinds, **the active mod
  list**), `Saves/`, `Scenarios/`, `Screenshots/` and `DevOutput/` together, logging
  `Save data folder overridden to <path>`. So: **grep tier-1 source for the persistent
  path property and read its callers before writing any patch.** Only if there is none
  does `isolation.mechanism: "harmony-postfix"` apply, with the IL2CPP section's
  fail-closed rule (throw on an empty root rather than falling through to the player's
  directory).
  Three hazards, all found the hard way:
  - **Read the game's argument parser, not the game's documentation.** RimWorld's
    `GenCommandLine.TryGetCommandLineArg` splits the argv token on `'='` and requires
    `array.Length == 2`, so a redirect path **containing a second `=` silently fails to
    parse and the game writes to the player's real save folder** — no error, no log line.
    The launcher must reject such a path in preflight. Space-separated forms are likewise
    not recognised. Whatever the game's parser is, its failure mode is the one that
    matters, and the failure mode is usually "fall through to production".
  - **The mods folder usually does *not* follow the redirect.** RimWorld's
    `GenFilePaths.ModsFolderPath` builds from `new DirectoryInfo(UnityData.dataPath).Parent`
    — always `<install>\Mods`, whatever `-savedatafolder` says. So the three environments
    of Phase 6 item 9 **share one physical mods directory** and cannot be separated by
    relocating it. What *is* per-environment is the **active mod list**, because that
    config file does follow the redirect. Design the deploy gate around "which
    environments may activate this mod", not around which files exist on disk.
  - **`PlayerPrefs` is still the registry** (`HKCU\Software\<Company>\<Product>`) and no
    save-root redirect reaches it — carry that IL2CPP note over verbatim.
- **The "real user data changed" assertion needs a discriminator, or it will lie.**
  Phase 6 item 7 promises the player can *play their game while a run is in progress*.
  That promise makes the post-run hash check ambiguous: a changed hash means either
  GameLab wrote to production (a run-invalidating defect) or the player played (expected,
  and none of GameLab's doing). Resolve it from the **real** `Player.log`: a
  GameLab-launched process leaves fingerprints there — the redirect log line above and
  the mod's own startup banner. A real `Player.log` carrying **neither** was written by
  an ordinary play session, and the run is clean. Without this test the harness reports a
  false isolation defect the first time the user launches their own game, which trains
  everyone to ignore the assertion that matters most.
- **Screen/window arguments** are the standard Unity set and work the same as on IL2CPP:
  `-screen-width`, `-screen-height`, `-screen-fullscreen 0`, `-popupwindow`, and
  `-logFile <path>` so each run's engine log lands beside its report. `Player.log` itself
  is **not** moved by a game-level save-data redirect — it is Unity's, at
  `%USERPROFILE%\AppData\LocalLow\<Company>\<Product>\`. (Old readmes pointing at
  `<Game>_Data/output_log.txt` are pre-2018 Unity and stale; note the discrepancy in
  RE_NOTES rather than rediscovering it.)
- **IMGUI games have no widget tree — record one.** This is the big structural surprise
  of the Mono era: many Unity games (and essentially every one with a dense
  strategy/management UI) draw their interface in `OnGUI` with **immediate-mode**
  `UnityEngine.GUI`/game-specific `Widgets` calls. There is no retained widget graph, no
  `Canvas` hierarchy, no `IPointerClickHandler`, and **nothing for a uGUI-style probe to
  walk** — a transform walk returns an empty UI. The Phase 6 item 5a "UI widget tree" is
  still entirely deliverable; you build it instead of reading it:
  - **Probe:** Harmony-patch the handful of drawing primitives the game funnels through
    (button, image-button, label) and **record every call for the current frame** —
    label, rect, enabled state. Double-buffer: accumulate into a back frame, swap on
    end-of-frame, serve the completed front frame to the harness. That *is* the DOM, it
    is exact, and it carries hitboxes and labels the renderer only implies. Bound it with
    a max-widgets-per-frame cap.
  - **Hands:** deliver a click by **prefixing the button primitive to return `true` once**
    for a single armed rect. The game's own handler then runs on its own thread and its
    own frame, with no cursor, no focus and no window message — the cleanest possible
    instance of Phase 6 item 8's widget layer. Arm one rect, fire once, disarm, and
    report whether it actually fired: an armed click that never fires means the widget
    stopped being drawn, which is a *different* failure from a handler that did nothing.
  - **Match rects with an epsilon (~0.75 px).** Immediate-mode layout recomputes rects
    every frame and they wobble sub-pixel; exact float equality between the rect you
    recorded and the rect drawn next frame will miss.
  - Immediate-mode UI does not animate the way DOTween'd uGUI does, so the IL2CPP
    "wait for the rect to stop moving" hazard mostly evaporates — but scrolling lists
    still move, so keep the arm→fire→confirm handshake rather than assuming.
- **Screenshots: use the engine, not the OS** — identical to the IL2CPP note and for the
  identical reason. `UnityEngine.ScreenCapture.CaptureScreenshot` from inside the process
  is passive, focus-free, and **works when the game runs on a hidden Windows desktop
  object**; Win32 `PrintWindow` returns a uniformly **black** bitmap there, because a
  non-default desktop has no DWM compositor. `CaptureScreenshot` is also *asynchronous* —
  it writes at end of frame, so the harness must poll for the file rather than assume it
  exists on return.
- **Deterministic boot into a scenario.** Look for a first-party autoload hook before
  building menu navigation; management games often have one for their own QA. RimWorld
  boots straight into `Saves/autostart.rws` if that file exists **and** dev mode is on
  (`Verse.SaveGameFilesUtility.GetAutostartSaveFile`), which turns fixture loading into a
  file copy and skips the entire front end. Conversely, **verify any "quick test" flag is
  actually deterministic before building on it** — RimWorld's `-quicktest` seeds world
  generation from `GenText.RandomSeedString()`, i.e. a different world every launch, so
  fixture recipes must drive generation with an explicit seed instead.
- **Operational hazards** (the IL2CPP list applies unchanged; these are the Mono-specific
  additions):
  - **No hot reload, and it is worse than IL2CPP's.** `Assembly.LoadFrom` cannot be
    undone — the assembly is in the AppDomain for the life of the process. Every code
    change is a redeploy plus a full game restart. Say this plainly in MODDING_NOTES.md;
    "Mono, so surely hot reload" is a recurring wrong assumption.
  - **The running game holds the mod DLL open** → `PermissionError [WinError 32]` on
    deploy. Name the holding pid in the error message.
  - **A stale deploy is indistinguishable from a broken feature** — compare source mtimes
    against the deployed artifact and refuse to call the environment launchable when the
    DLL is behind.
  - **The command channel comes up long before the game is loaded.** Wait on a predicate
    over a state probe (game loaded, map non-null, no long-event pending), never a sleep.
  - **Harmony patches on `Update`-shaped methods run on the game thread**, which is what
    makes them the right pump for a command queue — but it also means anything slow in
    there is a frame hitch. Keep the game-thread footprint zero while idle: queue on the
    socket thread, execute in the pump, flush I/O from a background thread. This is the
    same "steady-state footprint must be zero" rule as the UE4SS section, arrived at from
    the other direction.
- **The BepInEx 5 + Doorstop sub-case** *(added from Valheim 1.0.7, Unity 6000.0.75f1,
  2026-09 — the branch RimWorld does not exercise, because Valheim has no first-party
  loader and its UI is uGUI, not IMGUI).*
  - **The gameplay assembly is not always `Assembly-CSharp.dll`.** Valheim's game code is
    `assembly_valheim.dll` (with `assembly_utils.dll` beside it); `Assembly-CSharp.dll`
    exists but is nearly empty. Every `AccessTools.TypeByName` lookup, patch target and
    decompile step must name the real one. Confirm by *size and content*, not by the
    conventional name — the Mono positive test above still holds, but "which DLL holds the
    game" is a separate question from "is this Mono".
  - **BepInEx 5 scans `plugins/` recursively and ignores directory names.** Renaming a
    mod's *folder* does not disable it. A bisect built on folder renames produces a clean,
    confident, entirely invalid result — measured: four consecutive bisect rounds wasted
    before the "disabled" plugin was caught still logging its version. Disable by renaming
    the **`.dll`** (`x.dll` → `x.dll.old`), and verify by asking the running game which
    plugins loaded, not by looking at the disk.
  - **Ship `doorstop_config.ini` with `enabled = false` and pass `--doorstop-enabled true`
    per launch.** Mod managers copy `winhttp.dll` into the game root, where it mods
    *every* launch — including the one the user believes is vanilla. Making injection an
    explicit per-launch argument is what makes a genuine vanilla environment possible at
    all, and BepInEx derives its whole root (`plugins/`, `config/`, `LogOutput.log`) from
    the assembly Doorstop is pointed at, so the same switch is what makes two profiles
    independent.
  - **Steam Cloud is a second save root.** Redirecting the save path is not sufficient:
    Valheim's `FileHelpers.CloudStorageSupportedAndEnabled` short-circuits
    `Utils.GetSaveDataPath` for `FileSource.Auto`/`Cloud`, so an isolated run still reads
    and writes the player's cloud saves. Force cloud off in the same patch set as the
    redirect, and treat `steam_autocloud.vdf` mtimes as isolation evidence.
  - **A third-party mod ecosystem fails in three recurring shapes, and all three are
    silent.** Over nine broken-mod findings in one Valheim mod set, every failure was one
    of: (1) a shared helper compiled against a removed engine/game symbol — `ServerSync`
    referencing `ZRoutedRpc.Everybody` threw `TypeLoadException` in five different mods;
    (2) `Harmony.PatchAll()` throwing part-way through `Awake`, which leaves *some*
    patches applied and the mod's own static state uninitialised, so it then NREs from
    inside a patch on every frame; (3) **a call site against a method the game has since
    given another optional parameter.** C# bakes optional arguments in at the call site at
    compile time, so `Create(a,b,c,1f,-1)` compiled against a five-parameter overload emits
    a `call` to a five-parameter method — and when the game adds a sixth defaulted
    parameter the old assembly throws `MissingMethodException` *at JIT time*, long after
    BepInEx has reported the mod as loaded. From source the change looks
    backwards-compatible; at the assembly level it is not. Read the arity in the exception
    against the current declaration before concluding a method was removed.
    Shapes (2) and (3) are the dangerous ones: the mod is neither loaded nor absent.
    **Read the loader log for `TypeLoadException`/`MissingMethodException` at startup
    before debugging any gameplay symptom**, and expect to disable mods to get a green
    harness — record the deviation rather than pretending the profile is fully modded.
  - **Launch and drive the *play* profile too, not just the harness profile.** The harness
    environment is built to be deterministic, which usually means it creates its state
    fresh every run — so it never exercises the *load an existing save* path at all. The
    single worst mod defect in this project (an existing character silently losing its
    equipment on load) was invisible to a fully green 20-check smoke suite and appeared on
    the first boot of the play profile. A declared-and-statically-verified environment is
    not a measured one; boot it once, read its loader log, and audit what it wrote.
  - **Harmony-generated stack frames hide the owning mod.** A trace through
    `DMD<Type::Method>` names no assembly. `Harmony.GetPatchInfo(method)` does — expose it
    as a probe command that, given a method, lists every patch and its owner. That command
    turned two "the game is broken" dead ends into named mods in minutes.
  - **uGUI panels animate open, so "the game says it is open" is not a safe moment to read
    geometry.** Valheim's `InventoryGui.Show` only sets an Animator bool; the panel slides
    in over the following frames while the "is open" flag reads true throughout. A widget
    dump taken at the flag records rects the panel is passing through — measured 129px and
    then 50px above where the same frame drew them, x correct to the pixel, the offset
    shrinking as the clip advanced. Poll a widget's own screen rect until the value repeats
    before dumping or capturing. (The IL2CPP section's "wait for the rect to stop moving"
    hazard, which the IMGUI notes above say mostly evaporates, is back in full force on a
    uGUI Mono game.)
  - **uGUI hides widgets three different ways, and only one of them looks like hiding.**
    A widget-tree probe that reports only `activeInHierarchy` will contradict the
    screenshot. Valheim uses all three: moving the root off screen
    (`Hud.SetVisible` parks it at local x=10000), fading to alpha 0 via a `CanvasGroup`
    (the stamina bar at full stamina), and **disabling the `Graphic` component while the
    GameObject stays active** (empty inventory slots). The third leaves *stale text* — an
    emptied slot still reports the last stack count that occupied it — so a naive probe
    does not merely over-report, it over-reports with plausible numbers. Emit a computed
    `drawn` = has an enabled Graphic **and** activeInHierarchy **and** effective alpha > 0
    **and** on screen, OR-ed with any drawn descendant; and report which mechanism was used.
  - **A truncated widget tree is not an absent panel.** Node-capped walks return `null`
    roots for the canvases they never reached, which reads exactly like "that panel is not
    showing". Any absence assertion (Phase 1.3) must first assert the tree was not
    truncated.

- **Still to document:** AssetBundle/Addressables repacking on Mono, Mono soft-debugger
  attach (`wait-for-native-debugger` in `boot.config` is the visible hook), MelonLoader
  as a BepInEx 5 alternative, publicizer workflows for internal/private API access at
  compile time.

### Minecraft Java (26.x · loader: Fabric · launcher: ATLauncher)

Seeded from Hypixel SkyBlock Enhanced (2026-09, MC 26.2, Fabric Loader 0.19.5, Java 25).

- **Code accessibility profile:**
  1. *Game code (full fidelity)* — from 26.x Mojang ships the client **unobfuscated**
     (Loom logs "Mappings not present!"; Loom 1.17 no-remap). Vineflower on the client
     jar gives readable Mojang-named source: formula bodies, not just signatures.
  2. *Mods (full fidelity)* — Fabric mods are plain jars; decompile or clone upstream.
     Scanning every pack jar's bytecode for a string (`glfwSetCursorPos`, a packet name)
     is a one-minute Python job and finds cross-mod hazards the source search misses.
  3. *Server logic (opaque)* — on a server network (Hypixel) the rules live server-side.
     Mechanics come from the community wiki mirror, public API data tables, and probes.
- **Launch ground truth:** don't reconstruct the classpath. ATLauncher writes the full
  command to `logs/atlauncher.log` ("Launching Minecraft with the following
  arguments"); parse the newest line for the instance, swap `javaw` for `java`, drop
  `-Xm*`/agents, and launch directly.
- **Isolation:** `--gameDir <dir>` is the canonical `isolation.mechanism: "arg"`: options,
  config, saves, logs, screenshots, and mod caches all move with it. Hard-link the
  pack's mod jars into `<dir>/mods`. Verify the live `gameDirectory` from inside the
  game. The account token is shared, so allow one client per account at a time.
- **Settings that ignore options.txt:** window/fullscreen mods (Cubes Without Borders
  `config/cwb.json` `fullscreenMode`) override `fullscreen:false`. Check the status
  probe's real window size on the first run, not the file.
- **Mod caches hold git repos with read-only pack files.** Reset with
  `shutil.rmtree(onexc=chmod-and-retry)`; `ignore_errors=True` silently leaves a
  half-deleted tree.
- **Channel/probes:** a client mod is the harness. Loopback TCP plus NDJSON, gated on a
  system property and the gameDir path. Mojang names in 26.2: `Minecraft.gui.screen()`
  (current screen), `Gui.setScreen` releases all key mappings (`KeyMapping.releaseAll`),
  `MouseHandler.grabMouse` re-reads OS key state (`KeyMapping.setAll`). Keep held keys
  with a `KeyMapping.release`/`setDown` mixin. Container clicks go through
  `MultiPlayerGameMode.handleContainerInput`.
- **Screenshots:** `Screenshot.grab` (render-target readback) works on a hidden desktop,
  unfocused. Rendering stops while minimized (`Minecraft.java:1254`), so restore first.
  The first ~3 s is `GenericMessageScreen` "Loading Minecraft", and captures then are black.
  Wait for the title screen (packs replace `TitleScreen`; SkyBlock Enhanced uses
  `SBETitleScreen`) and `fps > 0`. `LevelLoadingScreen` ("Loading terrain...") also
  shows over a connected world. "In world" isn't "loaded", so gate on that screen too.
- **REAL CURSOR HAZARD (hidden desktop does not contain it):** the cursor belongs to the
  window station, and a client on a hidden desktop reports itself focused. On world
  entry, `MouseHandler.grabMouse` calls `InputConstants.grabOrReleaseMouse`, which calls
  `glfwSetCursorPos` (SetCursorPos) and `GLFW_CURSOR_DISABLED` (ClipCursor to the client
  rect, plus re-centring). This moves and confines the user's mouse. Mods call
  `glfwSetCursorPos` directly too, and Ixeris' buffered raw mouse calls Win32
  `SetCursorPos` every poll. Required:
  - a harness mixin on `org.lwjgl.glfw.GLFW` (`remap=false`) cancelling
    `glfwSetCursorPos` and non-NORMAL `glfwSetInputMode(GLFW_CURSOR, …)`, with counters;
  - pack mods that touch Win32 directly configured off in the harness env;
  - an external watcher sampling `GetClipCursor`/`GetCursorPos` against the game's client
    rect (found via `EnumDesktopWindows` on the hidden desktop).
  Focus sampling alone misses this. Move the hidden window off the monitor centre
  (`glfwSetWindowPos`), because fullscreen games centre the user's cursor there. User
  games' mouselook clips a 1×1 rect, so only a clip equal to the client rect counts as a
  hit.
- **Input emulation:** keys through `KeyMapping` state plus `clickCount`; GUI input through
  the Screen's own event methods, as `MouseHandler`/`KeyboardHandler` dispatch them. Hotbar
  through `Inventory.setSelectedSlot`. Chat and commands through a rate-limited queue. All of
  these work with the window iconified (`glfwIconifyWindow`).
- **Server networks (Hypixel):** location comes from the Hypixel Mod API packet
  (`serverType`, `mode`). A fresh login lands in a lobby; `/skyblock` transfers. Hypixel
  refuses a reconnect ~25 s after a disconnect, so keep a 60 s cooldown. Menu item names
  change between seasons, so match on stable entries.
- **Build pin:** MC version, client jar sha1, loader version, modpack version, and a sha256
  over all mod jars.
- **Hot reload:** none in practice. Jars load once, and a running client holds them open.
  Deploy means a restart.
- **Still to document:** Forge/NeoForge equivalents, Prism/MultiMC/official-launcher
  launch-line sources, dev-env `runClient` with Loom for mods that need it, singleplayer
  fixtures (world templates) for non-server games, and Linux/macOS cursor behaviour.

### Electron (wrapper: none · mod stack: direct source or ASAR patch)

- **Code accessibility profile** (the Phase 3 tiers as they land on Electron):
  1. *Electron wrapper JS (full fidelity)* — the `resources/app/` source is typically
     plain JavaScript (or packed into `app.asar`, extractable with `npx asar extract`).
     The wrapper includes `main.js` (main process), `preload.js` (context bridge),
     shared modules, and `package.json`. Full source, no decompilation needed.
  2. *Web application JS (varies)* — if the game loads a remote URL, the web app
     source is only available via browser DevTools or network interception. If the
     game bundles a local web app, it is full-fidelity JS in `resources/app/`.
  3. *Data* — if the game is server-authoritative, data tables live server-side and
     are not extractable. Client-side data (configs, settings) may be in JS files or
     localStorage. Mechanics must be learned from in-game help pages, network traffic
     observation, or runtime probing.
- **Extraction:** for packed apps, `npx @electron/asar extract app.asar gamecode/sdk/`.
  For unpacked apps, copy `resources/app/` directly. The `package.json` `main` field
  tells you the entry point.
- **Launch config:** Electron apps accept standard Chromium flags:
  `--window-size=W,H`, `--window-position=X,Y`, `--disable-gpu`,
  `--disable-software-rasterizer`, `--user-data-dir=<path>` (the most important one
  for isolation — it relocates the entire Chromium profile including localStorage,
  IndexedDB, cookies, and cache). Pass them on the command line when invoking the exe.
- **Window topology:** the Electron `BrowserWindow` is the only window. Its title is
  set by the app — find it in `main.js` (search for `new BrowserWindow(` or `setTitle`).
  `process.MainWindowHandle` is the right HWND for focus-free window messages.
- **Isolation:** `isolation.mechanism: "arg"`, detail: `--user-data-dir=<abs>`.
  Verify by reading the live process command line.
- **Input emulation** (the Phase 6 rule, Electron implementation):
  - **Widget/action layer:** `webContents.executeJavaScript()` to invoke functions
    in the web page's JS scope. This is the primary path — dispatch click handlers,
    call model-layer functions, set form values.
  - **Engine input pipeline:** `webContents.sendInputEvent()` for keyboard/mouse
    events injected at the Chromium level. Prefer `executeJavaScript` for UI;
    use this for testing keybind handling.
  - **Focus-free OS messages:** `PostMessage` to `MainWindowHandle`. Least preferred;
    the two above are in-process and more reliable.
- **Screenshots:** `webContents.capturePage()` returns a `NativeImage` — in-process,
  passive, works occluded and on a hidden desktop. Better than Win32 `PrintWindow`
  because it doesn't need the DWM compositor.
- **Front door:** the game boots to a login page. Drive it through
  `webContents.executeJavaScript()` — fill forms, click submit buttons by calling
  their handlers. No OS-level clicks needed.
- **Saves/user data:** in server-authoritative web games there is no local save file.
  State is in localStorage/IndexedDB for settings, and the server holds game state.
  Back up the user data directory (`--user-data-dir` target) as the closest
  equivalent to a save backup.
- **Anti-cheat:** Electron games typically don't bundle kernel anti-cheat. Trust is
  server-side. Modifying the wrapper or injecting into the page is detectable by the
  server if it checks for tampering.
- **Hot reload:** editing the wrapper requires a full app restart. No hot reload.
  The running process holds JS files open on Windows — stop before deploying.
- **ASAR packing check:** look for `resources/app.asar` (packed) vs
  `resources/app/` with `package.json` inside (unpacked). Unpacked means direct
  file modification with no extraction step. Idle Hacking (2026-08) is unpacked.
- **Steam launch path:** `steam.exe -applaunch <appid>` delivers Chromium flags to
  the process. Direct exe launch may also work since Electron reads `process.argv`
  directly (unlike Unreal's `SteamAPI_RestartAppIfNecessary` relaunch). Test both;
  prefer `-applaunch` for certainty.
- **Debug workflow:** `--remote-debugging-port=9222` enables CDP; connect with
  Playwright via `browserType.connectOverCDP()`. The `--inspect` / `--inspect-brk`
  Node.js flags work on the main process. For the renderer, use
  `webContents.openDevTools()`.
- **Operational hazards:**
  - The wrapper may override Chromium flags programmatically (e.g. `app.commandLine.appendSwitch`).
    Check `main.js` for flag manipulation — some flags set in code cannot be overridden
    from the command line.
  - `webContents.executeJavaScript()` runs in the page context, not the preload
    context. Preload-exposed APIs are available via `window.IdleHackClient` (or
    whatever name the preload uses).
  - `contextIsolation: true` (default in modern Electron) means the page JS cannot
    access Node.js or Electron APIs — only what the preload explicitly exposes.
    This is a security boundary but also a modding boundary; you control what's
    exposed by modifying the preload.
- **Still to document:** ASAR integrity checks, code signing, Steam DRM interaction,
  CDP automation workflow, localStorage snapshot/restore tools.

### Godot (4.x · loader: none needed, an `-s` SceneTree script)

*Seeded from COMPACTORS (Godot 4.6.2, an unreleased game run from its source project),
2026-09. The project's `gamelab/docs/RE_NOTES.md` carries the measurements.*

- **Fingerprint and pin.** A shipped game is an exe plus a `.pck` (or the pck embedded in
  the exe). A source project is `project.godot` plus `.godot/`. `<engine>_console.exe
  --version` prints the exact build (`4.6.2.stable.official.71f334935`). Pin that string
  and the exe's sha256. Games often leave `application/config/version` unset. For a
  source run, the game's own build is the commit, so gate on what actually breaks the
  harness instead: the engine binary and the save-format constants (`const
  FORMAT_VERSION`). Record the content hash per run and key fixtures on it.
- **Code accessibility profile** (the Phase 3 tiers as they land on Godot). It is close
  to Unity Mono: nearly everything comes back readable.
  1. *GDScript (effectively full fidelity).* A source project, or
     `script_export_mode=0`, ships plain text. Modes 1 and 2 ship binary tokens:
     `<name>.gdc` plus `<name>.gd.remap`. Mode 2 also zstd-compresses them.
     - The `.gdc` format: `GDSC` magic, then token version (101 on 4.6), then the
       decompressed size, then a zstd frame.
     - Identifiers are stored as UTF-32LE XOR 0xB6, so a string search of the pack
       finds no names.
     - GDRE Tools (gdsdecomp) `--recover` rebuilt all 343 of 343 scripts:
       - 342 came back token for token;
       - 338 kept their line count;
       - 610,413 of 610,414 tokens stayed on their original line;
       - declaration counts matched exactly (`func` 7110/7110, `class_name` 330/330,
         `@export` 1685/1685);
       - one literal changed value by one ulp: `1.0e30` became
         `9.999999999999999e+29`.
     - **What is lost is every comment**, including `##` doc comments: 35k lines,
       2.2 MB, each turned into a blank line. Literal spelling is also normalised: hex
       becomes decimal, quote style and float form change, `:=` becomes `: =`.
     - Read and grep the recovered code as source. The only thing you lose is the
       design commentary.
  2. *Resources and scenes (lossless as data, lossy as text).*
     - The exporter converts `.tres`/`.tscn` to binary `.res`/`.scn` behind `.remap`
       files.
     - GDRE writes text back with default-equal properties dropped (3,393 property
       lines became 1,738), `load_steps` dropped, and uids and `unique_id`s added.
     - So don't diff that text. Dump the values through the engine instead (below).
       Those dumps matched 121 of 121 datatables between source and recovery, and
       matched the input map exactly. 4 of 6 scenes were identical; the other two only
       gained `layout_mode=3, anchors_preset=0` on their root Control.
  3. *Imported assets (sources not shipped).* Only `.import` files and
     `.godot/imported/*` ship.
     - Only mp3 came back byte for byte.
     - Textures come back re-encoded at the same dimensions. wav becomes 16-bit PCM.
       gltf is re-exported with renamed `.bin` files. An svg comes back as a trace of
       its raster.
     - Good for looking at, not for rebuilding.
  4. *GDExtensions (native, opaque).* The DLLs ship, e.g. GodotSteam. Their behaviour
     is the upstream project's, so read that project's source.
- **Extraction extras:**
  - **Getting a pack from a source project:** `godot --headless --path <proj>
    --export-pack "<preset>" <out.pck>`.
    - It needs **no export templates**: 4.6.2 with only 4.6.3 templates installed
      still exited 0 with a complete 780 MB pack.
    - But it runs the editor. That touches the editor profile and copies GDExtension
      libraries beside the project (`~libgodotsteam.*.dll`). So export once, then
      reuse the pack.
    - Don't trust exit 0: parse the header. Check for GDPC v3, the engine version,
      `project.binary` present, and the `.gdc` count.
  - **Recovery:** `gdre_tools --headless --recover=<pck> --output=<dir>`. Pin it by
    release tag and zip sha256. A failed conversion is expected for a plugin that the
    preset excludes but `project.godot` still enables.
  - **Data tables:** a headless `-s` SceneTree dumper.
    - It `load()`s every shipped `.tres`/`.res` and writes JSON of every exported
      property, taking the file value or the script default.
    - It also dumps scene node trees and the `InputMap`.
    - Cross-check its count against an independent Python walk that honours the
      preset's `exclude_filter`.
  - **Check `exclude_filter` against what actually shipped.** `tests/*, docs/*,
    addons/gut/*, *.md` still let the build dir, `tools/` and `.gutconfig.json` into
    the pack.
- **Every engine process: headless, boxed, own APPDATA.** Three traps, all hit here:
  - **`OS::alert` shows a native MessageBox even with `--headless`.** For example,
    "Can't run project: no main scene defined" for an empty project. It lands on the
    user's desktop unless the process was born on a hidden desktop.
  - **Every run with file logging writes `user://logs/godot*.log` into the real
    `app_userdata/<name>/`.** Rotation then evicts the player's own logs. Six
    extraction runs replaced a player's whole log history this way, so give every
    child an isolated `APPDATA`.
  - **Every `-s` and editor run on 4.6.2 prints the same harmless error:**
    `ERROR: Condition "!parser->has_attribute("value")" is true … doc_tools.cpp:1497`.
    Filter it; don't gate on it.
- **Isolation: `isolation.mechanism: "env"`.** On Windows, `user://` is
  `%APPDATA%\Godot\app_userdata\<config/name>`, and the engine reads `APPDATA` at
  runtime.
  - Set it in the **child's environment block only**. Settings, saves, logs,
    `shader_cache/` and `vulkan/` all move together.
  - Verify it on the live process three ways:
    - the loader refuses to run unless `OS.get_user_data_dir()` is inside the
      isolated root;
    - the probe reports the same path;
    - `psutil.Process(pid).environ()["APPDATA"]` matches.
  - Junction the shader and pipeline caches to a harness-owned directory, so a
    per-run wipe does not recompile shaders.
  - Launch with `--windowed --resolution WxH --position X,Y --audio-driver Dummy
    --log-file <run>/godot.log`. All of these work on 4.6.2, and `--log-file` puts each
    run's engine log in its own run directory.
  - Unmeasured: `use_custom_user_dir`, which drops the `Godot\app_userdata` segment,
    and the Linux `XDG_DATA_HOME` equivalent.
- **Loader: none needed.** Run `godot --path <proj> -s <abs>/loader.gd -- <user
  args>`, where `loader.gd` is `extends SceneTree`.
  - That script becomes the main loop. Autoloads are already in the tree when its
    `_initialize` runs.
  - It adds each mod node under `root` (deferred), then calls
    `change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))`.
    The game's front door comes up exactly as usual.
  - Verify every deployed mod file's sha256 against a manifest inside the loader. A
    stale deploy then becomes a hard exit code instead of a confusing run.
  - Put the harness folder behind a **`.gdignore`**. That hides it from import,
    export and the global class cache.
  - Declare no `class_name` in mods, and write them to the project's own warning
    settings: a project with `untyped_declaration=2` makes an untyped mod a compile
    error.
  - `.gdignore` does not hide the folder from a game's own `DirAccess` walks of
    `res://`. One of this game's tests needed a skip.
  - Unmeasured alternative for shipped games: an `override.cfg` beside the exe with
    an `[autoload]` entry.
  - **No hot reload.** Scripts compile when the loader loads them, so a redeploy takes
    effect on the next launch.
- **Mouse capture is the user's cursor.** `Input.mouse_mode = MOUSE_MODE_CAPTURED`
  calls `ClipCursor` and re-centres the cursor. That cursor belongs to the window
  station, so a hidden desktop does not contain it (same as the Minecraft note).
  - Games set CAPTURED in the player controller's `_ready`. Hook `node_added` and
    switch the controller off *before* its `_ready`, then back on from its `ready`
    signal.
  - Add a per-frame guard that forces `MOUSE_MODE_VISIBLE` and counts each time it
    had to. A non-zero count is a finding.
  - Aim through the game's own view API, not mouse motion. Never call `warp_mouse`:
    it is `SetCursorPos`.
- **Input emulation.** Feed `Input.parse_input_event()` synthetic
  `InputEventMouseButton`/`InputEventKey`/`InputEventAction` at a Control's centre.
  - Compute the centre in window pixels as `get_viewport().get_final_transform() *
    get_global_transform_with_canvas()`.
  - Listen for `pressed`, and fall back to `pressed.emit()` only while reporting which
    route fired.
  - For typing, `grab_focus()` then send unicode key events.
  - Measured: clicks and typing land through the pipeline **with the window
    minimized** on a hidden desktop. Physics and the game's own intent setters keep
    ticking while minimized.
- **`Window.has_focus()` is focus within its own desktop.** On a hidden desktop where
  the game is the only window, it reads `true` even while minimized. It says nothing
  about the user's foreground; only an external `GetForegroundWindow` sample does.
- **UI tree: gather natively, never walk the scene in GDScript.** A 3D world has tens of
  thousands of nodes (about 42.7k at one District load).
  - A budgeted GDScript walk from `root` spent its 20,000-visit budget on 3D nodes. It
    returned **0 controls while the HUD was drawn**, and an absence assertion passed on
    that truncated tree.
  - Use `root.find_children("*", "Control", true, false)`, which runs in C++. Keep the
    roots: parent not a Control, not under a SubViewport, and not on a hidden
    CanvasLayer. Walk from those.
  - `drawn` = `is_visible_in_tree()`, effective alpha above zero, and on screen.
  - A truncated tree must make the run INVALID.
- **The inspector needs a curated reader allowlist.**
  - `"name" in obj` is true for methods, and `obj.get("method")` returns a
    `Callable`. A naive dotted-path inspector silently returns Callables.
  - Route methods through the prefix allowlist and a blocked-word list.
  - Game readers rarely use getter prefixes (`remaining()`, `fraction()`, `amount()`),
    so add a per-class table of plain readers. Put a reader in it only after reading
    its body and finding no side effect: `bay_count()` looks pure but calls
    `_settle_bay()`.
- **Screenshots: in-engine.** `await RenderingServer.frame_post_draw`, then
  `get_viewport().get_texture().get_image().save_png(path)`.
  - It is passive, needs no focus, and works on a hidden desktop, where `PrintWindow`
    returns black (see the Unity notes).
  - Take the UI tree and state in the same frame, so the probe-versus-pixels check
    compares like with like.
  - Unmeasured: whether a **minimized** window still draws. The harness restores the
    window first, which takes no focus on a hidden desktop, and waits 10 frames.
- **Telemetry without game hooks.** Connect every script-declared signal from
  `node_added` through arity-matched trampolines, rate-limited per signal. That was
  about 304k connections in one District. It costs something; the cost against vanilla
  was not measured.
- **Still to document:**
  - a *released* game's pack: embedded-in-exe pcks, and encrypted scripts (the key is
    in the exe);
  - whether `-s` and `override.cfg` autoload injection work against an export template
    build;
  - C#/.NET Godot games (decompile with ILSpy);
  - Godot 3.x differences;
  - Linux paths;
  - a `use_custom_user_dir` game.

### Hammerwatch engine (Crackshell custom C++ + AngelScript · loader: none, the game loads mods natively)

Seeded 2026-10-17 from Heroes of Hammerwatch II (app 619820, build 25509441). Every
claim carries a tag: **[verified]** = measured on that build, with the measurement
stated; **[assumed]** = read in code, strings, or docs, not yet exercised. Promote an
assumption only with the measurement that did it.

**Accessibility profile**

| Tier | What | Fidelity |
|---|---|---|
| Scripts | `scripts/**/*.as` (AngelScript) — **the game logic is the script layer** | full source **[verified]**: 880 `.as` files extract byte-identical from PACKAGER and `hwr_archive.py` |
| Data | `.unit`, `.inc`, `.sval`, `.gui`, `.effect`, `.tileset`, `.lang` (XML with a `%include`/`%define` preprocessor) | full, text **[verified]**: 10,617 text/data files byte-identical from both extractors; preprocessor directives **[assumed]** from hh2-data-mine `ARCHITECTURE.md` |
| Levels / prefabs | `.lvl`, `.pfb` | binary SValue trees in the archive; PACKAGER emits them as XML **[verified]** (3,571 files, `<dict>` text from PACKAGER vs `0x02` SValue bytes from `hwr_archive.py`) |
| Art | `.png`, `.tif` | engine-native texture blobs in the archive; PACKAGER emits real PNG/TIFF **[verified]** (1,467 files, PNG/`II*` signatures from PACKAGER vs width/height/channel headers from `hwr_archive.py`) |
| Engine | `HWR2.exe` | native, opaque; links bgfx, SDL2, FMOD, Box2D, ozz **[verified]** by `strings` on the exe; the registered script API is readable as plain strings (`strings -n 8`) and is the fastest map of what scripts can call **[verified]**: 12,711 strings, signatures like `void QueuePathfind(UnitPtr owner, ...)` |

**Extraction**

- `res/assets.bin` and mod `.bin` packages are `HW2R` archives (LZ4 blocks) **[verified]**;
  format spec in the project's `docs/archive-format.md`.
- The official tool is `PACKAGER.exe` (`--unpack`/`--destination`, `--resources`,
  `--level`, `--sval`). It is a GUI app that initialises Steam on startup and **exits
  without Steam running** **[verified]**. A signature-found binary patch that skips the
  Steam init makes it a Steam-free pack/unpack tool, verified identical to the original
  for those two functions; `--level` and GUI fall-through crash on the patched copy. The
  patcher, the full verification table, the CLI quirks (dialogs block unattended runs;
  success exits -1) and the open items live in the project's `docs/packager.md` and
  `tools/patch_packager.py`. Patched copies are game binaries: gitignored `tools/bin/`,
  rebuilt by `bootstrap.py`.
- A pure-Python reader/writer for the format exists in the project (`tools/hwr_archive.py`);
  its extract side is verified against PACKAGER for text and data, its pack side is
  **[assumed]** until a full round trip passes. Details in `docs/packager.md`.

**Mod loading**

- `mods/<id>/info.xml` folders load unpacked and `.bin` files load packed **[verified]**
  by HammerwatchPlus's 27 modules loading both ways, per its `HWR2.exe.log` lines
  `Adding packed/unpacked mod '<id>'`; not yet exercised under GameLab. A file at a
  base path replaces the base file wholesale **[verified]** the same way (its
  `overrides` mechanism). Hooks (`[Hook]` free functions in a namespace named after
  the hook; call sites listed in HammerwatchPlus `docs/hooks.md`) and classmaps in
  `info.xml` **[verified]** in that project's use.
- Which mods are **enabled** is stored as 32-bit `HashString(mod id)` values inside the
  persistent save header (`saves/<slot>.hps`, `H2SV` v3/v4) **[verified]**:
  HammerwatchPlus `gamelab/hps.py` patches it and the game honours the result.
  `HashString` is **MurmurHash3_x86_32 with seed `0xf808409c`** **[verified]**: traced
  from the script declaration to the native body in `HWR2.exe`, and it matches 57/57
  known id→hash pairs. No learned table is needed. A mod's id is its folder name
  **[verified]** (`Adding unpacked mod 'gamelab-probe'`). That this is the only state a
  fixture must patch in a binary save **[assumed]** until the full-build recipe is
  attempted. The `town-paladin` fixture needs nothing else: the character is made
  in-game by script.
- **Mod lifecycle** **[verified]** (HammerwatchPlus `docs/RE_NOTES.md`, 2026-10-17):
  - enabled mods load at boot;
  - module constructors run when the menu level loads (the main menu is
    `levels/town.lvl`);
  - `UpdateFrame` ticks only after a session starts.

  A mod compile error stops every mod script, not only the broken mod's.
- The game logs to `HWR2.exe.log` in the install dir **[verified]**: script compile
  errors as `ERR : <file> (ln N, col M)`, mod loads as `Adding packed/unpacked mod
  '<id>'`, town ready as `StartLoadMenu levels/town.lvl`. The regexes are now
  HammerwatchPlus `gamelab/logparse.py`, checked against a deliberately broken mod: the run
  names `Broken.as:5:11 No matching symbol`. The game logs baseline `[ERR]` lines with or
  without mods, so checks are scoped to the mods under test. Scripts `print()` there too
  **[verified]** by the `[HWP:...]` lines. It is the output channel.
- **User-data isolation** **[verified]**: HWR2 reads `HWR2.exe.cfg` and writes
  `HWR2.exe.log` and local `saves/` next to the exe it was started from, not the cwd.
  - **Game dir.** A GameLab game dir therefore holds:
    - copies of `HWR2.exe` and its DLLs;
    - its own `res/`: `assets.bin` hard-linked, small files copied, subdirectories
      junctioned. The game may write `res/controls.cfg`.
    - a fresh cfg per run with `g_save_slot_cloud 0`.
  - **save_backups.** The one escape is `%LOCALAPPDATA%/HeroesofHammerwatch2/save_backups`.
    The game resolves it with `SHGetKnownFolderPath`, so an env var does not move it.
    - Fix: start the exe `CREATE_SUSPENDED`, inject a shim whose IAT hook answers
      `FOLDERID_LocalAppData` with a lab path, then resume. Verified: the backup lands in
      the lab dir.
    - One lab file leaked to the real dir before the fix.
  - **Launch.** Starting the copied exe directly runs with no Steam relaunch.
  - **Retired.** The old `dev_check.py` config-swap workaround is gone.

**Script API** — the names below are **[verified]** present in the exe's registered
function strings; every statement about their **behavior is [assumed]** until probed.

- Pathfinding: `QueuePathfind(owner, from, to, diameter, maxDistance, maxRange)` →
  `QueuedPathfind(array<vec2>@ path)` callback; `DirtyNavGraph`, `IsNavDataUpdating`.
  That enemies use it **[assumed]**: inferred from the names; the script that calls it
  has not been read. Pilot's `path_to` wraps it.
- Eyes: `QueryCircle`, `QueryRect`, `Raycast`, `RaycastClosest`, `RaycastQuick`,
  `RaycastQuickWithoutUnit` over unit slots and `RaycastType`.
- Time: `g_timescale` cvar, `SetUnitTimeScale(float)`.
- Input: the player's update calls `GetInput()` **[verified]** at
  `scripts/Behaviors/Actors/Player/Player.as:1098` (Feb-2026 extraction; re-check on
  the current build); the `GameModeUpdate` hook receives `GameInput&` **[verified]**
  in `docs/hooks.md`. Whether writing to the hook's GameInput reaches the player
  **[assumed either way]** — the first Pilot probe; the fallback is injecting one
  level down (the player's move direction and `PlayerTargetingHelper` skill
  activation).
- **Command channel** **[verified]**: it is the in-game console, driven focus-free.
  - Post `WM_KEYDOWN` VK `0xC0` to the `SDL_app` window, `WM_CHAR` the text, then Enter.
    This works on a hidden desktop and with the window minimized.
  - A mod registers the verb with `AddFunction("gl", {cvar_type::String}, cb)`.
  - Replies are `print()`ed as `[GL] {json}` lines in `HWR2.exe.log`, which the harness tails.
  - Enter at the main menu starts Singleplayer/Continue: the front door.
  - No socket or file-write API appears in the registered strings **[assumed absent]**,
    so the log is the only way out. Large replies, such as a datatable, go out in
    6000-char chunks.
- **Data tables** **[verified]**: `Resources::GetSValue(path)` returns the engine's parse
  of an `.sval` after preprocessing.
  - Multi-entry files (root `<svals>`: buffs, sprite sets) are one resource per
    `<file>:<entry>`, as the game's own `LoadActorBuff` uses. Asking for the bare file
    returns null.
  - All 326 `.sval` files export this way.
- Cvars present **[verified]** as strings: `g_disable_saving`, `g_save_slot`,
  `g_intro_logos`, `g_debug_scripts`, `g_debug_mods`, `g_start_sessions`,
  `r_draw_nav_data`, `r_draw_collision`, `r_draw_line_of_sight`. That `g_start_sessions`
  starts local multiplayer sessions and that the `r_draw_*` cvars work in the release
  build **[assumed]** from the names.
- Multiplayer: `Lobby::` (Steam lobbies) is the only join path found in the scripts
  **[assumed]**: no direct-connect string found, absence not proven. Two networked
  instances therefore need two Steam accounts **[assumed]**; in practice two machines,
  since one Steam client runs one account at a time. Local sessions
  (`SpawnLocalPlayers`, `Platform::GetSessionCount`) give several players in one process
  with no netsync **[assumed]** from the script names.

**Probes still open** (each becomes a dated `RE_NOTES.md` entry when answered):

- The GameInput injection probe. Real-key `PostMessage` input works meanwhile
  **[verified]**: `F` = Use opened a chest.
- Answered 2026-10-17:
  - **Command channel:** the console.
  - **User-data redirect:** exe-copy game dir plus the known-folder shim.
  - **Steam relaunch:** none.
  - **Hidden-desktop rendering:** bgfx renders there, but `PrintWindow` returns blank
    (no compositor). Capture is an IAT hook on `gdi32!SwapBuffers` that reads `GL_BACK`
    with `glReadPixels`.
  - **Mute:** `snd_volume*` cvars in the lab cfg, read back from the running game.
- Loot RNG is unseeded **[verified]**: the same chest rolled different loot on two runs.
  It needs a seed hook before loot assertions can be exact.
- Whether to add the second patch point so `--level` and GUI fall-through stop crashing
  on the patched `PACKAGER`;
  `hwr_archive.py pack` round trip (its output decodes identically to PACKAGER's for the
  three modules tried, header hash aside — close to verified, not there).
- `g_timescale` safety (same result at 1× and N×).
- Whether `PersistentSaves::Load` reads arbitrary files.
- `g_start_sessions` / `SpawnLocalPlayers` behavior; `QueuePathfind` behavior; whether
  the `r_draw_*` overlays work in release.
- Which unit-definition fields back each `scan()` category.
- Which level data carries transitions, for the authored travel graph.
- HoH1 (`HWRR` v3) differences.

### Future work

- **Update handling:** the build-id gate now *stops* runs on an update; we still need a
  plan for surviving them. Options: pin the depot version (SteamCMD/DepotDownloader), or
  copy the game dir to a frozen location and mod the copy while the live install updates
  freely (`isolation.mechanism: "copy"`). Plus a re-dump procedure for when we *accept*
  an update: re-run extractors, refresh mappings, rebuild fixture caches, diff the
  datatables to see what the patch changed (that diff is free patch-notes intel).
- **Tier 2 static decompilation:** when data tables and runtime hooks still don't
  reveal a formula, the native binary can be thrown into **Ghidra** (or IDA) to
  decompile the specific function bodies — the SDK dump's class layouts, offsets, and
  signatures make targeted decompilation much easier than going in blind. Unobfuscated
  shipping binaries (like Palworld's) decompile well. Treat it as a scalpel for
  individual formulas, not a bulk pass over a 150 MB exe.
- **Per-engine playbook sections:** grow the "Per-engine notes" section above —
  **Unreal is seeded** (Palworld, 2026-07; its "still to document" list is the open
  TODO), **Custom Java + LWJGL is seeded** (Necesse, 2026-08), **Unity IL2CPP is
  seeded** (Path of Idle, 2026-08), **Unity Mono is seeded** (RimWorld 1.6, 2026-09),
  **Minecraft Java + Fabric is seeded** (Hypixel SkyBlock Enhanced, 2026-09), and
  **Godot 4 is seeded** (COMPACTORS, source run, 2026-09; pck repack and released-game
  packs still open), and **Hammerwatch (custom C++ + AngelScript) is seeded** (Heroes of
  Hammerwatch II, 2026-10; command channel and input probe still open)
  — each carries its own "still to document" list as the open TODO;
  still unseeded:
  - **GameMaker:** data.win patching via UndertaleModTool CLI, GML decompilation.
  Seed each the first time we mod a game on that engine, then fold lessons back in.
- **Fast GameLab Fixtures** — time-scale acceleration is now governed by the Pilot
intake (Phase 6b, default "later") and the Design rules: it is allowed only after the
same scenario is measured to give the same result at 1× and at N×. What remains future
work is a shared measurement procedure for that equivalence (which telemetry fields to
compare, how many runs), so each game does not reinvent it.

## Phase checklist (copy into README.md)

One box per deliverable. A phase is done when every box under it is checked.

```markdown
### P0 — Scaffold
- [ ] Repo created, standard layout, `git init`
- [ ] `.gitignore`: `gamecode/`, `.screenshots/`, `gamelab/results/`,
      `gamelab/env/userdata/`, `gamelab/fixtures/cache/`, `gamelab/manifest.local.json`,
      `tools/bin/`, big mirrors under `docs/community/`
- [ ] `README.md` with this checklist pasted in, and the `saves-backup/` size cap
- [ ] `tools/bootstrap.py`: required tier regenerates from the install (build-id checked),
      optional `--with-community` tier downloads from the shared folder in `docs/SOURCES.md`,
      `--verify` against `gamelab/manifest.json`
- [ ] `tools/hidden_desktop.py` vendored and importable after bootstrap
- [ ] `saves.py backup` refuses past the declared cap
- [ ] Second-machine gate: a fresh clone + `bootstrap.py --verify` green on a collaborator's
      machine (required tier identical; optional tier identical where present)

### P1 — Recon
- [ ] Install located; app id + build id + game version in `docs/RE_NOTES.md`
- [ ] Every game/loader log path found and recorded in `docs/MODDING_NOTES.md`
- [ ] Anti-cheat checked; finding + consequence recorded in `docs/RE_NOTES.md`
- [ ] Engine **and engine version** identified

### P2 — Modding support survey
- [ ] Official docs mirrored to `docs/official/`
- [ ] Community wiki/tool docs + reference mod source mirrored to `docs/community/`
      (originating machine; collaborators without the optional tier are not in violation)
- [ ] `docs/SOURCES.md` has a dated row per mirror, and names the shared folder for
      every gitignored mirror
- [ ] Mod stack chosen and written up in `docs/MODDING_NOTES.md`

### P3 — Extract & decompile
- [ ] Code decompiled/dumped into `gamecode/sdk/`
- [ ] Data tables exported to `gamecode/datatables/` (JSON/CSV)
- [ ] Engine's accessibility profile written into the **global** playbook's Per-engine notes
- [ ] First modded launch: saves backed up, injection confirmed **from loader log
      markers**, window topology recorded

### P4 — Eyes
- [ ] `game-screenshot` skill captures to `.screenshots/` and reads the image back
- [ ] Capture verified passive: correct image while occluded and unfocused

### P5 — Brain
- [ ] `MECHANICS.md` covers progression, loot, movement tech, economy, gameplay loops,
      UI interaction model, inventory/logistics, run-state variables
- [ ] Run-state variables: every variable names the function or data path that sets it
- [ ] Every claim cites a decompiled source or a probe run
- [ ] No open items left standing as guesses

### P6 — Hands: GameLab  *(one box per architecture component)*
- [ ] **1 Launcher** — lab mode windowed, low graphics, fixed small res; intros skipped;
      focus-free in every mode; runs the 4-step preflight and aborts on any failure;
      lab mode asserts the live game process is in the launcher's job tree
- [ ] **1′ Two modes** — `--mode watch` (human default: visible, foreground sampled from
      launch to first frame never belongs to the game tree) and `--mode lab` (hidden
      desktop, muted; no game-tree window on the input desktop, foreground never the
      game tree for the whole run, mute confirmed in loaded settings, `PrintWindow`
      capture of the hidden window correct); programmatic runners always pass `--mode lab`
- [ ] **2 Command channel** — drives the running game, front door included
- [ ] **3 Scenario system** — `gamelab/scenarios/` + declarative fixture **recipes**
      (`fixtures/<name>.json`), every field read back through the probes, cache keyed by
      build id, generic across the game's modes
- [ ] **4 Instrumentation** — mod emits JSON-lines telemetry
- [ ] **5a Observer: state probes** — vitals/position, inventory, nearby entities, clock,
      **UI widget tree**, terrain grid
- [ ] **5a′ Reflective inspector** — dotted-path resolve + `members`; read-only by
      allowlist, bounded by depth/caps/budget, reports truncation
- [ ] **5b Observer: screenshots + log tailing** — fired at key moments
- [ ] **6 Scoring** — assertions + metrics into `gamelab/results/`, probe-vs-screenshot
      agreement asserted, disagreement reported `INVALID`
- [ ] **7 Game settings** — `gamelab/env/settings/lab/` (muted) and `settings/watch/`
      profiles, links declared, `env_link.py --verify` green, all three preflight
      assertions passing for the mode in use
- [ ] **8 Programmatic hands** — emulated click/press API, proven by a scenario run with
      the window minimized while the user typed elsewhere
- [ ] **9 Isolation** — `environments.json` declares all three envs; redirect verified on
      the live process; per-test teardown enforced
- [ ] **Build-id gate** — `gamelab/build_id.json` pinned; runner exits `3` on mismatch
- [ ] **Smoke scenario green** — *simple interaction* (open a container, loot it) passes
      end to end

### P6b — Pilot: the player bot  *(boxes for capabilities the intake marked out/later are ticked "N/A per intake")*
- [ ] Intake interview answered in the README (or "defaults" accepted), before any Pilot code
- [ ] `mods/gamelab-pilot` builds on `gamelab-hands`: verbs, closed interrupt vocabulary,
      control surface (pause / step / target override), telemetry — every verb in-engine
      and focus-free; any verb unreachable in-engine is a dated `RE_NOTES.md` entry
- [ ] Eyes: semantic `scan()` from unit data, raw list underneath, each category names
      its source field
- [ ] Travel: in-level `path_to` on the engine pathfinder; `gamelab/travel/authored.json`
      + `learned.json`; `no_route` is a returned result; a new transition taken in an
      exploration run appears in `learned.json`; scenario results pin the graph revision
- [ ] Intake capabilities marked in — avoidance, cross-level, consumables, time-scale —
      each passes its gate from the intake table (or N/A per intake)
- [ ] Python client: blocking verbs, `until=` from the closed vocabulary (unknown
      interrupts rejected), results `done / failed / timeout / interrupted / no_route`;
      a script revision needs no game restart
- [ ] Full-build fixture recipe over the MECHANICS.md run-state schema; every field read
      back or the run fails; cache keyed by build id
- [ ] First bot (`gamelab/bots/`): one named MECHANICS.md gameplay loop, using the
      intake's combat verb if the loop has combat, reaches its terminal telemetry event
      unattended in **lab mode**
- [ ] Watch-mode feedback loop recorded once: user watched, feedback cites a telemetry
      tick, agent revised, no restart
- [ ] Promoted scenario: same script + assertions, green in lab mode, hidden and muted,
      telemetry and screenshots agreeing
- [ ] Multiplayer: local-sessions scenario green; networked scenario green across two
      machines when the intake says the game has multiplayer; tier recorded in results

### P7 — Dev loop
- [ ] `tools/deploy.py` working, env-targeted, reload trigger documented honestly
- [ ] `tools/saves.py backup` in launcher preflight; `restore` exercised
- [ ] `tools/env_link.py` and `tools/pin_build.py` working
- [ ] Shared-state rule: every mod change touching shared state names its networked
      scenario, green before the change is called done
- [ ] Full loop run end-to-end: edit → deploy → scenario → results + screenshots → refine
- [ ] Session close ritual: `docs/RE_NOTES.md` updated, README status refreshed

### P8 — Handoff  *(the last deliverable)*
- [ ] This document is pasted into `docs/PLAYBOOK.md`, and every
      deliverable box in this checklist is marked with a checkmark or "N/A per intake"
      (P6b only). Only stop once every deliverable has one, then finally checkmark this
      last task.
```
