# Sources

One dated row per mirror (playbook P2). Every mirror directory also holds a `_mirror.json`
with the source, date and file count. Refresh with `python tools/mirror_docs.py <name>`.

Mirrors are reference material, never authority: a claim about the game is verified only
against the pinned build (decompiled source in `gamecode/sdk/`, or a GameLab run).

| Mirror | Path | Source | Mirrored | Tracked | Notes |
|---|---|---|---|---|---|
| HoH2 wiki: modding pages | `docs/community/wiki/` | `https://wiki.heroesofhammerwatch2.com` (MediaWiki source) | 2026-10-17 | committed | Two pages: `Modding` (rev 1711, 2025-11-19) and `Modding/Modifiers` (rev 1724, 2025-11-23). Its `Resource mods` / `Scenarios` / `Languages` links are redlinks. The site only answers a real browser, so `mirror_docs.py wiki` uses headless Playwright in `hidden_desktop`. Not to be confused with `wiki.hammerwatch2.com` (Hammerwatch II, a different game). |
| Reference mod source | `docs/community/reference-mods/` | Steam Workshop items installed for app 619820, extracted with `tools/hwr_archive.py` | 2026-10-17 | committed | Item `3620435418` (4 files: `Character.as`, `EquipmentItemWidget.as`, a language file). |
| Discord export (HoH2 channels) | `docs/community/discord/` | Hammerwatch Universe Discord, exported with DiscordChatExporter (originating copy: `C:\FastProjects\MODS\hh2-data-mine\discord_export`) | 2026-10-17 | **gitignored** (236 MB) | Channels `Heroes of Hammerwatch 2` and `Heroes of Hammerwatch 2 Classes`. It is searchable, never authoritative, and contains other people's messages, so it is never committed. |

## Shared folder (optional tier)

`bootstrap.py --with-community` copies gitignored mirrors from the folder named on this
line:

Shared folder: *none: the user skipped the optional tier (2026-10-17).* The Discord mirror stays in `docs/community/discord/` (gitignored) on the originating machine; it is not uploaded to any cloud.
Collaborators without the optional tier are not in violation
(playbook P2), and `--with-community` says the folder is unreachable.
