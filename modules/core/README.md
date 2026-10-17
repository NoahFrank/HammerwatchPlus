# core

Shared library every other HammerwatchPlus module depends on. It adds no gameplay.

| File | Provides |
|---|---|
| `scripts/HWP/Core/Log.as` | `HWP::Log(module, msg)` / `HWP::LogError`, `HWP::VERSION` |
| `scripts/HWP/Core/Net.as` | `HWP::Net` request/event bus (`OnRequest`, `OnEvent`, `Request`, `Broadcast`, `Send`) |
| `scripts/HWP/Core/SaveData.as` | `HWP::SaveData::Player/Local/Town/MyTown()` data bags saved under the record's `hwp` key; a bag lives in the record's `userdata`, so it dies with the record |
| `scripts/HWP/Core/Settings.as` | `HWP::Settings::Get*/Set*` local preferences, stored in `g_myTownRecord` (the only town record the game saves; clients only get a copy of the host's `g_currTownRecord`) |
| `scripts/HWP/Core/Commands.as` | `HWP::Commands`: the `hwp` console command. `hwp help`, `hwp version`, `hwp settings`, `hwp get <key>`, `hwp set <key> <value>`; modules add their own with `Register(name, help, handler)` and listen for setting changes with `OnSettingChanged` |
| `scripts/HWP/Core/GearSlots.as` + `gui/playermenu/character.gui` | `HWP::Gear`: extra gear slots in the character screen. The vanilla equipment is a 3x3 grid (main hand, head, off hand / hands, chest, back / rod, feet, can), with the bottom corners and the alt-weapon pair as `hwp-gear-slot` widgets; a module registers a `HWP::Gear::Slot` provider by widget id (`Register`), slots without a provider are hidden. Providers call `Changed()` when what they show changes (a level load does too); the slots reload only then |
| `scripts/HWP/Core/Town.as` | `HWP::Town::Placeable` (a settings-backed town doodad the host spawns), `HWP::Town::PayGold`, and `HWPLocalNPC`, the behaviour of town units every machine spawns for itself (fishing spots, the pirate, farm plots, the well) |
| `scripts/HWP/Core/BagSlots.as` | `HWP::Bag`: bought equipment bag slots, 24 + up to 8 per character (`bag.extra` in the HWP data; 1000 g rising to 20000 g, sold by the keys module's General Merchant or `hwp bag buy`). The character screen's `<hwp-equipmentinventory>` draws every slot you can fill |
| `system/messages.net` | base file + `HWPRequest` / `HWPEvent` messages (declared override, see `module.json`) |
| `scripts/HWP/Core/Cheats.as` | `hwp unlockflags`, `material`, `levelup`, `xp`, `statpoints`, `skillpoints`, `equip`, `spawnmaps`, `finishlevel`, `boss`, `killall`, `god`: copies of the vanilla `cht_*` cheats that work in a level (need `e_cheats 1`) |
| `scripts/HWP/Core/Generator.as` | `HWPOutdoorGenerator`: vanilla `OutdoorGenerator` that picks its base level again on every retry and sets aside a base that failed 10 times in a row (see below) |
| `scripts/HWP/Core/CoreModule.as` | boot self-checks; prints every mod id's save hash for `tools/hps.py` |

## Why character.gui is overridden

The gear grid needs new widgets in the character screen, and a gui file cannot
be merged. Core owns `gui/playermenu/character.gui` (declared in
`module.json`): the vanilla file with the equipment moved into a 3x3 grid and
four `hwp-gear-slot` widgets added (`hwp-gear-rod`, `hwp-gear-can` below the
gloves and the cape, `hwp-alt-main`/`hwp-alt-off` for the other weapon set).
They sit outside `<equipment>` because `EquipmentWidget.DoLayout` fills every
item slot inside it by id. Providers: fishing (rod), farming (watering can),
weaponswap (the other set). Each module still works without the others; its
slot just stays hidden.

## Console commands are the settings UI

There is no settings GUI yet. `hwp set <key> <value>` writes a
`HWP::Settings` value (`true`/`false` -> bool, number -> int, else string) and
notifies every listener, so modules pick the change up live. Replies print
to the console prefixed `[HWP]` (and to the chat log, which shows in a lobby).

Why the console and not `/hwp` in chat: the in-game chat and the pause menu
run in the main menu's script, which loads only the unmodded base scripts and
has no town or players. The console calls `hwp` in the game's script, and a
one-string console function receives the whole rest of the line. The vanilla
`cht_*` cheats are registered by both scripts and the console runs the menu's
copy, which is why `cht_give_material` and friends fail with a null pointer in
a level; `Cheats.as` has working copies.

## Why the outdoor themes are overridden

Vanilla `OutdoorGenerator` picks the base level prefab once and keeps it across
"Failed generation commands, retrying from scratch". When a required prefab set
can never fit on that base (seen: `forest_2` on `base_levels/level_6.pfb` with
`forest_skill`), the game retries the same layout forever until the lobby times
out. `gen-class` is created with `InstantiateClass`, which ignores info.xml
classmaps, so `tweak/missions/themes_{forest,heaven,keep,prison}.sval` and
`themes_heaven.inc` are copied with only `gen-class` changed to
`HWPOutdoorGenerator` (the `.orig` copies are the base files for `build.py --check`).
The boot log shows `generator safety net: HWPOutdoorGenerator`.

## Why messages.net is overridden

HoH2 declares all network messages in one file. There is no merge mechanism, so
the core module ships a copy with two generic messages appended. `tools/build.py
--check` flags the day a game update changes the original.

## Testing

`python tools/dev_check.py` must show, in the HWP log lines:

- `[HWP:core] module created, version ...`
- `[HWP:core] lang check: HammerwatchPlus language file loaded` (not the raw key)
- `[HWP:core] modhash '<id>' <n> ...` for every installed mod
- `[HWP:core] town record loaded, N hwp key(s)` (proves the save hooks fire)

In a run (needs a player): `gameplay started; server=yes town=...`.
