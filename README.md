# HammerwatchPlus

A modular co-op mod for **Heroes of Hammerwatch II**: quality-of-life and
co-op systems, a gambler in the tavern, pets that level up, Heroes of
Hammerwatch 1 content (ace chests, legendaries, the Forsaken Tower campaign,
HoH1 classes and pets), new classes, fishing and farming in town.

Every module ships as its own mod package, plus an all-in-one build. Everyone
in a lobby should run the same version of the same modules.

## Modules

| Module | What it does |
|---|---|
| `core` | Shared library: settings, save-data extension, networking helper, pet pickup logic. Required by every other module. |
| `gambler` | Higher/Lower card game NPC in the tavern. Sells fish and herbs later. |
| `droptrade` | Drop equipment on the ground for friends (replaces Destroy; Destroy stays on a modifier key). |
| `goldpet` | Pet Vendor in the Hunter's Cabin selling a gold-collecting cat. |
| `laststats` | Last run's stats for the whole party on a notice board by the town fountain. |
| `deathrecap` | Who killed you: top damage sources from the last 10 s, on screen and in chat. |
| `petwait` | Pets wait outside puzzle rooms instead of trampling the buttons. |
| `architect` | Any player can pick and pay for Architect alterations; the host's picks are split across the party. |
| `chatlinks` | Linked items stay in chat with slot and item level; `/hwp link`. |
| `colors` | Colour-blind / high-contrast tints for enemy and friendly projectiles. |
| `groupcombo` | Party-wide combo bonus that scales with how many players are in combo; brief invulnerability when everyone is. |
| `weaponswap` | A second weapon set on a hotkey (default X). |
| `keys` | HoH1-style locked and ace chests, key drops, the General Merchant, seven red legendaries. |
| `firearms` | The Firearms Specialist class: mana is ammo, reload, grenades; Sniper / Demolitions / Assault doctrines. |
| … | See `docs/` for every module's spec. |

## Installing (players)

1. Download the `.bin` files you want from Releases (or `HammerwatchPlus-All.bin`).
2. Drop them into `<Steam>/steamapps/common/Heroes of Hammerwatch 2/mods/`.
3. Start the game, open **Resource Mods** and enable them. Everyone in the lobby does the same.
4. In game, type `/hwp help` in chat for the commands and settings.

Workshop uploads will follow once the modules stabilise.

## Developing

Requirements: Python 3.10+, `pip install -r tools/requirements.txt`, HoH2
installed (HoH1 too for the HoH1 content importer).

```
python tools/extract_base.py --both   # extract base games -> .base/ and .base-hoh1/ (git-ignored)
python tools/dev_link.py              # junction modules/* into the game's mods/ folder as unpacked mods
python tools/dev_check.py             # enable the linked mods in the save, boot the game, collect script errors from HWR2.exe.log
python tools/hps.py show              # inspect / patch which mods the persistent save has enabled
python tools/build.py                 # pack dist/HWP-<module>.bin + dist/HammerwatchPlus-All.bin
python tools/build.py --check         # verify our wholesale overrides still match the base game
python tools/hwr_archive.py --help    # low-level archive tool (list/extract/pack HW2R and HWRR)
```

Conventions live in `docs/modules.md`; the archive format in
`docs/archive-format.md`; the script hooks in `docs/hooks.md`.

HoH1 assets are never committed. `tools/import_hoh1.py` reads them from your
own HoH1 install.

## License

MIT. Game assets belong to Crackshell.
