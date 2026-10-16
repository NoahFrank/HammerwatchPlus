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

- **Why not the real HoH1 levels?** HoH1 `.lvl` files reference HoH1
  tilesets, doodads and enemies that do not exist in HoH2; converting them
  would mean importing (and never committing) the whole HoH1 asset tree
  and rebuilding every enemy. The themes and bosses above stand in; the
  importer (`tools/import_hoh1.py`) can grow HoH1 tilesets later.
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
