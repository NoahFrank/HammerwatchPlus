# core

Shared library every other HammerwatchPlus module depends on. It adds no gameplay.

| File | Provides |
|---|---|
| `scripts/HWP/Core/Log.as` | `HWP::Log(module, msg)` / `HWP::LogError`, `HWP::VERSION` |
| `scripts/HWP/Core/Net.as` | `HWP::Net` request/event bus (`OnRequest`, `OnEvent`, `Request`, `Broadcast`, `Send`) |
| `scripts/HWP/Core/SaveData.as` | `HWP::SaveData::Player/Local/Town/MyTown()` data bags saved under the record's `hwp` key; a bag lives in the record's `userdata`, so it dies with the record |
| `scripts/HWP/Core/Settings.as` | `HWP::Settings::Get*/Set*` local preferences, stored in `g_myTownRecord` (the only town record the game saves; clients only get a copy of the host's `g_currTownRecord`) |
| `scripts/HWP/Core/Commands.as` | `HWP::Commands`: the `hwp` console command. `hwp help`, `hwp version`, `hwp settings`, `hwp get <key>`, `hwp set <key> <value>`; modules add their own with `Register(name, help, handler)` and listen for setting changes with `OnSettingChanged` |
| `system/messages.net` | base file + `HWPRequest` / `HWPEvent` messages (declared override, see `module.json`) |
| `scripts/HWP/Core/Cheats.as` | `hwp unlockflags`, `material`, `levelup`, `xp`, `statpoints`, `skillpoints`, `equip`, `spawnmaps`, `finishlevel`, `killall`, `god`: copies of the vanilla `cht_*` cheats that work in a level (need `e_cheats 1`) |
| `scripts/HWP/Core/CoreModule.as` | boot self-checks; prints every mod id's save hash for `tools/hps.py` |

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
