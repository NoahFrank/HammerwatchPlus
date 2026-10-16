# core

Shared library every other HammerwatchPlus module depends on. It adds no gameplay.

| File | Provides |
|---|---|
| `scripts/HWP/Core/Log.as` | `HWP::Log(module, msg)` / `HWP::LogError`, `HWP::VERSION` |
| `scripts/HWP/Core/Net.as` | `HWP::Net` request/event bus (`OnRequest`, `OnEvent`, `Request`, `Broadcast`, `Send`) |
| `scripts/HWP/Core/SaveData.as` | `HWP::SaveData::Player/Local/Town/MyTown()` data bags saved under the record's `hwp` key; a bag lives in the record's `userdata`, so it dies with the record |
| `scripts/HWP/Core/Settings.as` | `HWP::Settings::Get*/Set*` local preferences, stored in `g_myTownRecord` (the only town record the game saves; clients only get a copy of the host's `g_currTownRecord`) |
| `scripts/HWP/Core/Commands.as` | `HWP::Commands`: chat commands. `/hwp help`, `/hwp version`, `/hwp settings`, `/hwp get <key>`, `/hwp set <key> <value>`; modules add their own with `Register(name, help, handler)` and listen for setting changes with `OnSettingChanged` |
| `system/messages.net` | base file + `HWPRequest` / `HWPEvent` messages (declared override, see `module.json`) |
| `scripts/GUI/Menus/InGameChat.as` | base file + one line: chat text starting with `/hwp` goes to `HWP::Commands::Handle` instead of the lobby (declared override) |
| `scripts/HWP/Core/CoreModule.as` | boot self-checks; prints every mod id's save hash for `tools/hps.py` |

## Chat commands are the settings UI

There is no settings GUI yet. `/hwp set <key> <value>` writes a
`HWP::Settings` value (`true`/`false` -> bool, number -> int, else string) and
notifies every listener, so modules pick the change up live. Replies are
local chat lines prefixed `[HWP]`.

## Why messages.net and InGameChat.as are overridden

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
