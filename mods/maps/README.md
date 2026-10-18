# maps

More variety for the equipment-map drops ("pink maps"). Each file in
`tweak/hwp/missions/` is a `MissionDef::LoadSingle` in the `equipment_map`
set, so `MissionMap` items roll them next to Bandit Keep, Ghostly Crypt and
Spider Caves. Themes, enemy schemes, flags and boss levels are all vanilla;
the combinations are new. Names: `res/language/english/hwp_maps.lang`.

| id | floors | difficulty | boss | spawn chance |
|---|---|---|---|---|
| `hwp_goblin_warrens` | forest, dark cave x2 | 5-9 | Totem Pole (cave) | 1.0 |
| `hwp_sunken_dungeon` | dungeon x2, crypt | 12-15 | Arista | 0.8 |
| `hwp_high_court` | barracks, courts x2 | 17-21 | Serpents of Demise | 0.6 |

All three unlock with the same flag as the vanilla maps
(`mission_story_intro_find_npcs`). `hwp maps` lists them with their span and
whether your character is eligible. The self-check verifies that every
mission and every enemy scheme they reference is registered.

## Test checklist

1. `python -m gamelab run mod-maps --mode lab`: `[HWP:maps] self-check done: 3/3 missions, N/N schemes`.
2. `hwp maps` in town lists all three.
3. Use a few map drops (or the console's mission commands): the new names
   show up on the map item; each layout generates, has enemies and ends in
   its boss.
