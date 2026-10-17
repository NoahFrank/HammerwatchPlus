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
| `gambler` | Higher/Lower card game NPC in the tavern; buys your fish, crops and herbs (Sell button); rerolls equipped gear for 2000 gold x item level. |
| `droptrade` | Drop equipment on the ground for friends (replaces Destroy; Destroy stays on a modifier key). |
| `goldpet` | Pet Vendor in the Hunter's Cabin selling a gold-collecting cat. |
| `laststats` | Last run's stats for the whole party on a notice board by the town fountain. |
| `deathrecap` | Who killed you: top damage sources from the last 10 s, on screen and in chat. |
| `bufftips` | Hover a buff icon to see what it does and how many seconds it has left. |
| `legacy` | HoH1-style class legacy: your best hero of each class buffs every character; one "Heroic Legacy" buff lists them, Guild Hall > Titles shows every class. |
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
| … | See `docs/` for every module's spec. |

## Installing (players)

1. Download the `.bin` files you want from Releases (or `HammerwatchPlus-All.bin`).
2. Drop them into `<Steam>/steamapps/common/Heroes of Hammerwatch 2/mods/`.
3. Start the game, open **Resource Mods** and enable them. Everyone in the lobby does the same.
4. In game, open the console (the key left of 1) and type `hwp help` for the commands and settings.

Workshop uploads will follow once the modules stabilise.

## Developing

Requirements: Python 3.10+, `pip install -r tools/requirements.txt`, HoH2
installed (HoH1 too for the HoH1 content importer).

```
python tools/extract_base.py --both   # extract base games -> .base/ and .base-hoh1/ (git-ignored)
python tools/dev_link.py              # junction modules/* into the game's mods/ folder as unpacked mods
python tools/dev_check.py             # enable the linked mods in the save, boot the game, collect script errors from HWR2.exe.log
python tools/dev_check.py --level mines_boss --press-continue   # load mission floors on test save slot 7 and report each
python tools/hps.py show              # inspect / patch which mods the persistent save has enabled
python tools/build.py                 # pack dist/HWP-<module>.bin + dist/HammerwatchPlus-All.bin
python tools/build.py --check         # verify our wholesale overrides still match the base game
python tools/hwr_archive.py --help    # low-level archive tool (list/extract/pack HW2R and HWRR)
```

### PACKAGER.exe without Steam

The game's `PACKAGER.exe` needs Steam running. `tools/patch_packager.py` builds a
Steam-free copy into the gitignored `tools/bin/` that is verified identical to the
original for `--unpack` and `--resources`; `--level` and argument-less runs crash on
it. Everything measured, the command line, and the quirks: `docs/packager.md`.

Conventions live in `docs/modules.md`; the archive format in
`docs/archive-format.md`; the script hooks in `docs/hooks.md`.

HoH1 assets are never committed. `tools/import_hoh1.py` reads them from your
own HoH1 install (`pets` = pet skins into the pets module, `levels` = the
Forsaken Tower levels decoded into `hoh1_import/` with a report of what HoH2
still lacks, `campaign` = the HoH1 boss and Battlements levels converted into
the campaign module as a second mission). The output is gitignored and
`build.py` leaves it out of packages unless `--with-local`, so each player
imports it themselves.

## License

MIT. Game assets belong to Crackshell.
