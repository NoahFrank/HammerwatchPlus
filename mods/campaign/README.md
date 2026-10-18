# campaign

**The Forsaken Tower**: the Heroes of Hammerwatch 1 campaign as a HoH2
mission, started from a portal in town. One `MissionDef` in its own set
(`hwp_campaign`), 18 floors from difficulty 5 to 22: each HoH1 act is two
generated floors in the closest HoH2 theme plus a vanilla boss level.

| HoH1 act | HoH2 theme | Boss level |
|---|---|---|
| Mines | theme_cave_dark | boss_totem_cave |
| Prison | theme_prison | boss_arista |
| Armory | theme_barracks | boss_harbingers |
| Archives | theme_crypt | boss_wraith |
| Chambers | theme_courts | boss_bone_serpent |
| Battlements | theme_keep | boss_avatar |

- **The real HoH1 levels** are a second, optional mission in the same set,
  "The Forsaken Tower (HoH1 levels)": the same 18 floors, with the five act
  boss rooms, both Battlements levels and Thundersnow taken from the
  player's own HoH1 install by `tools/import_hoh1.py campaign` (see below).
  Without the import only the mission above exists. The generated act
  floors stay HoH2 themes: HoH1 builds those from 755 unit types HoH2 lacks
  (`tools/import_hoh1.py levels` reports them).
- **Portal.** `doodads/hwp/forsaken_portal.unit` is an NPC doodad whose
  interact is the vanilla `MissionShopContent` limited to set `hwp_campaign`
  (`num` 2: both missions when the HoH1 one is imported), so the host picks the mission and the normal loadout menu
  opens. Clients see the host's portal (netsynced doodad). The host spawns
  it (`HWP::Town::Placeable` in core) 0.6 s after the town loads at setting `campaign.portal_x/y`
  (default -1700,250, next to the fishing spot); `hwp campaign here`
  moves it to where you stand. `campaign.enabled` turns it off.
- The mission is conditional on `mission_story_intro_find_npcs` like the
  vanilla boards. Every floor uses `diff-level-ngp` = diff + 8 like the
  vanilla tower chain.

## Real HoH1 boss levels (`tools/import_hoh1.py campaign`)

Converts `levels/boss_{mines,prison,armory,archives,chambers,dragon}.lvl` and
`battlements_1|2.lvl` with everything they reference (1410 files: units,
textures, effects, prefabs, tilesets) into `mods/campaign/hoh1/` (in-game
paths `hoh1/...`) and writes
`tweak/hwp/missions/missions_hwp_forsaken_tower_hoh1.sval`, plus
`tweak/missions/missions_dark_citadel.sval`: the main game's Dark Citadel with
both Battlements floors (clouds, glass walkways, giants; diff 21 and 22) before
the Avatar, a declared override (`.orig` committed) that only the import
generates. A save in the middle of a Dark Citadel run shifts by two floors
when it appears or goes away. All of them are
gitignored and only exist on a machine with HoH1 installed; `build.py`
leaves them out unless `--with-local`. The log is
`hoh1_import/campaign/convert.md` (every rewrite counted, plus the 14
references HoH1 itself does not ship).

The converter (`tools/hoh1_convert.py`) rewrites paths, materials, fonts and
classes; loose `.lvl`/`.pfb` are written as SValue XML (the engine reads loose
mod files as XML) and `build.py` compiles them back to binary when packing.
HoH1 classes HoH2 lacks are mapped by `CLASS_MAP` in `tools/import_hoh1.py`
to our own implementations under `scripts/HWP/Campaign/HoH1/`, written
against HoH2's base classes with HoH1's unit parameters:

| File | Classes |
|---|---|
| `Effects.as` | `HoH1GiveGold`, `HoH1GiveOre`, `HoH1Decimate` (the wraiths' % HP / mana drain), `HoH1AddCurse`, `HoH1InertEffect` |
| `Projectiles.as` | `HoH1Projectile`, `HoH1TossProjectile` (vampire bats), `HoH1LurkerProjectile` (golem / dragon / warden ground spikes) |
| `Skills.as` | `HoH1JumpStrike`, `HoH1ChargeStrike`, `HoH1SpewSkill`, `HoH1WhirlwindSkill`, `HoH1WhirlNovaSkill` |
| `Bosses.as` | `HoH1BossLich` (+ movement, random skill: the Three Councilors), `HoH1BossVampire` (+ movement), `HoH1BossEye` + `HoH1BossEyeWisp` (the Watcher) |
| `WorldScripts.as` | HoH1 level scripts by their HoH1 names: environment, boss bar, wind, lich / vampire nodes and room, eye wisp scripts, elevators, shops... |

Boss state the host decides (which node the councilors go to, vampire
roaming, eye wisps) goes to the clients over the core `HWP::Net` bus
(`hoh1.lich.node`, `hoh1.vampire.*`, `hoh1.eye.*`); skills use the usual
`NetSendUnitUseSkill` stages.

Design calls to look at:

- **Gold and ore** pickups credit the player who picks them up (HoH2
  materials). HoH1 shared gold across the party.
- **Elevators** (`StoreOre`) are scenery: HoH1 banked run gold and ore at
  home for a tax; HoH2 keeps what a run earns anyway.
- **Item forge** (`ShopArea`) is inert: HoH2 has none of HoH1's shop menus.
- **Shrine, blood altar, imp** rooms use HoH2's `Shrine` (random shrine
  buff; the blood altar too, HoH2 has no blood altar rewards) and `Imp`.
- **Lunar Shield block, Soul Dagger, Combustion** effects are inert
  (`HoH1InertEffect`) until there is a HoH2 equivalent.
- **Minibosses** are plain `CompositeActorBehavior`: HoH1's overhead
  miniboss bar is gone. `CompositeActorBehaviorNoNGPScale` (the dragon's ice
  block) scales with NG+ like everything else.
- **Bat toss** "on-target" speed is our own formula (slow enough to land on
  the aimed spot within its time to live).
- Wraith statues (`TransferDamageActor`) get one empty state injected; HoH2
  requires a "states" list.

## HoH1 level import (`tools/import_hoh1.py levels`)

HoH1 and HoH2 share the level container: `.lvl` is 8 header bytes plus a
binary SValue dict (`tiles`, `game-mode`, `version`, `lighting`, `units`,
`scripts`, `prefabs`), `.pfb` the same dict at offset 0. The decoder in
`tools/hwr_archive.py` reads both games' files to end-of-file (every HoH2 and
HoH1 level and prefab, 6491 files). HoH1 acts are generated from prefabs
exactly like HoH2 themes; only the boss levels and the two Battlements
levels are hand-made.

The importer decodes the boss level + act prefabs per act and follows every
prefab they reference in other folders (chests, loot, boss rooms). It
writes `hoh1_import/campaign/levels/*.json`, `report.md|json` and the
referenced tilesets (textures as PNG), all gitignored, and warns about
references HoH1 itself does not ship. Unit types count both placed units and
the ones scripts spawn (`UnitType` params, spawners). Status on 2026-10-16:

| Act | files | tilesets (in HoH2) | unit types (in HoH2) | script types (unknown to HoH2) |
|---|---|---|---|---|
| Mines | 205 | 6 (1) | 154 (3) | 71 (14) |
| Prison | 195 | 4 (1) | 159 (3) | 72 (13) |
| Armory | 210 | 6 (1) | 225 (4) | 80 (16) |
| Archives | 198 | 4 (1) | 218 (4) | 90 (23) |
| Chambers | 209 | 5 (1) | 208 (3) | 78 (18) |
| Battlements | 82 | 5 (1) | 127 (3) | 58 (10) |

All acts together: 22 tilesets (1 in HoH2), 759 unit types (755 missing),
27 script types missing. HoH1 itself has broken references the port can
skip: Mines names `tilesets/anatolia_tile_inside_16 .tileset` (stray
space), Archives `prefabs/archives/maze_path_s_tele.pfb`, Chambers three
`prefabs/chambers/exit_*.pfb`.

What that means for a real port, in order:

1. **Tilesets** (22): same XML format, the textures convert with the
   existing texture tool. Tile layers: HoH1 stores `data` raw, HoH2
   `data-rle`; the RLE still needs decoding (HoH2 `.lvl` files are the
   reference).
2. **Level scripts**: HoH1 levels use 27 script types HoH2 lacks
   (`SpawnEnemyGroup`, `CreateBossBar`, `SetBossKilled`, `ShopArea`,
   `RandomLoot`, boss-specific nodes...). They are AngelScript `WorldScript` classes, so
   they can be written in the mod.
3. **Units** (755 types, the real cost): `doodads/walls/<act>/` wall sets,
   `doodads/generic/` traps and lamps, `actors/` enemies and spawners, the
   six bosses. Each is a HoH1 `.unit` XML whose behaviours only partly exist
   in HoH2; this is a per-enemy rebuild, not a conversion.

## Test checklist

1. `python -m gamelab run mod-campaign --mode lab`: `[HWP:campaign] self-check done: mission ok, N/N schemes`
   and no "missing unit" line for the portal.
2. Town: a glowing portal stands left of the fishing spot; the minimap
   shows a portal pip. Interact opens the mission picker with only
   "The Forsaken Tower" (18 floors, diff 5-22).
3. Start it: Mines floor 1 is a dark cave with goblins; the exit leads to
   floor 2, then the totem boss, then the Prison (cultists, bats)...
4. `hwp campaign` prints the mission, floors, span and the portal position;
   `hwp campaign here` moves the portal and the new spot survives a
   restart (town record).
5. Co-op: a client sees the portal and can read the mission; only the host
   can start it (vanilla rule).
6. With HoH1 installed: `python tools/import_hoh1.py campaign`, then the
   portal offers both missions and the self-check line ends in
   "HoH1 floors installed". Loading each HoH1 floor (mines_boss, prison_boss,
   armory_boss, archives_boss, chambers_boss, battlements_1, battlements_2,
   battlements_boss) is a GameLab scenario still to write. It will use the `gamelab-hands`
   verb `mission <id> [floor]`, which replaces the retired `dev_check.py --level`.
7. Play each HoH1 boss once, solo and in co-op: the Stone Guardian's ground
   spikes, the Warden's whirlwind and bombs, the councilors teleporting
   between nodes (client sees the same node), the Watcher's wisps circling
   each player, the Vampire Lord roaming / transforming and his bats,
   Thundersnow on top of the Battlements.
