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

- **Why not the real HoH1 levels yet?** They decode fine (see below) but
  reference 608 HoH1 unit types that HoH2 does not have: every wall, trap,
  spawner, enemy and boss. The themes and bosses above stand in until those
  are rebuilt; `tools/import_hoh1.py levels` is the first step and reports
  exactly what is missing.
- **Portal.** `doodads/hwp/forsaken_portal.unit` is an NPC doodad whose
  interact is the vanilla `MissionShopContent` limited to set `hwp_campaign`
  (`num` 1), so the host picks the mission and the normal loadout menu
  opens. Clients see the host's portal (netsynced doodad). The host spawns
  it (`HWP::Town::Placeable` in core) 0.6 s after the town loads at setting `campaign.portal_x/y`
  (default -1700,250, next to the fishing spot); `/hwp campaign here`
  moves it to where you stand. `campaign.enabled` turns it off.
- The mission is conditional on `mission_story_intro_find_npcs` like the
  vanilla boards. Every floor uses `diff-level-ngp` = diff + 8 like the
  vanilla tower chain.

## HoH1 level import (`tools/import_hoh1.py levels`)

HoH1 and HoH2 share the level container: `.lvl` is 8 header bytes plus a
binary SValue dict (`tiles`, `game-mode`, `version`, `lighting`, `units`,
`scripts`, `prefabs`), `.pfb` the same dict at offset 0. The decoder in
`tools/hwr_archive.py` reads both games' files to end-of-file (every HoH2 and
HoH1 level and prefab, 6491 files). HoH1 acts are generated from prefabs
exactly like HoH2 themes; only the boss levels and the two Battlements
levels are hand-made.

The importer decodes the boss level + act prefabs per act, writes
`hoh1_import/campaign/levels/*.json`, `report.md|json` and the referenced
tilesets (textures as PNG), all gitignored. Status on 2026-10-16:

| Act | files | tilesets (in HoH2) | unit types (in HoH2) | script types (unknown to HoH2) |
|---|---|---|---|---|
| Mines | 155 | 5 (0) | 104 (0) | 61 (8) |
| Prison | 140 | 3 (0) | 106 (1) | 60 (8) |
| Armory | 153 | 5 (0) | 141 (2) | 72 (11) |
| Archives | 130 | 2 (0) | 158 (2) | 81 (18) |
| Chambers | 163 | 3 (1) | 151 (1) | 72 (14) |
| Battlements | 55 | 4 (0) | 89 (0) | 50 (5) |

What that means for a real port, in order:

1. **Tilesets** (22 files): same XML format, the textures convert with the
   existing texture tool. Tile layers: HoH1 stores `data` raw, HoH2
   `data-rle`; the RLE still needs decoding (HoH2 `.lvl` files are the
   reference).
2. **Level scripts**: HoH1 levels use 23 script types HoH2 lacks
   (`SpawnEnemyGroup`, `CreateBossBar`, `SetBossKilled`, `ShopArea`,
   boss-specific nodes...). They are AngelScript `WorldScript` classes, so
   they can be written in the mod.
3. **Units** (608 types, the real cost): `doodads/walls/<act>/` wall sets,
   `doodads/generic/` traps and lamps, `actors/` enemies and spawners, the
   six bosses. Each is a HoH1 `.unit` XML whose behaviours only partly exist
   in HoH2; this is a per-enemy rebuild, not a conversion.

## Test checklist

1. `dev_check`: `[HWP:campaign] self-check done: mission ok, N/N schemes`
   and no "missing unit" line for the portal.
2. Town: a glowing portal stands left of the fishing spot; the minimap
   shows a portal pip. Interact opens the mission picker with only
   "The Forsaken Tower" (18 floors, diff 5-22).
3. Start it: Mines floor 1 is a dark cave with goblins; the exit leads to
   floor 2, then the totem boss, then the Prison (cultists, bats)...
4. `/hwp campaign` prints the mission, floors, span and the portal position;
   `/hwp campaign here` moves the portal and the new spot survives a
   restart (town record).
5. Co-op: a client sees the portal and can read the mission; only the host
   can start it (vanilla rule).
