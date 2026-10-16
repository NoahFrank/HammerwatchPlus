# core

Shared library every other HammerwatchPlus module depends on. It adds no gameplay.

| File | Provides |
|---|---|
| `scripts/HWP/Core/Log.as` | `HWP::Log(module, msg)` / `HWP::LogError`, `HWP::VERSION` |
| `scripts/HWP/Core/Net.as` | `HWP::Net` request/event bus (`OnRequest`, `OnEvent`, `Request`, `Broadcast`, `Send`) |
| `scripts/HWP/Core/SaveData.as` | `HWP::SaveData::Player/Local/Town()` data bags saved under the record's `hwp` key |
| `scripts/HWP/Core/Settings.as` | `HWP::Settings::Get*/Set*` local preferences (town record) |
| `system/messages.net` | base file + `HWPRequest` / `HWPEvent` messages (declared override, see `module.json`) |
| `scripts/HWP/Core/CoreModule.as` | boot self-checks; prints every mod id's save hash for `tools/hps.py` |

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
