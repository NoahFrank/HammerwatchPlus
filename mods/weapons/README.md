# weapons

Twelve extra endgame weapons, four per slot, merged into the base equipment
tables with the `<loader>` in `tweak/hwp/equipment_weapons_hwp.sval`
(`Equipment::BaseItem::LoadMultiple`). The base drop and shop code treats them
like any other `BaseItem` (ilvl 35, quality rolled on drop). They are original designs, not HoH1 ports, and reuse base
graphics, models and attack skills; what is new is the modifier profile:

| id | slot | profile |
|---|---|---|
| `hwp_mh_warhammer` | mainhand | Dwarven Warhammer: Heavy, slow to love, quick to crush. Critical strikes hit harder. |
| `hwp_mh_frostbrand` | mainhand | Frostbrand: A longsword quenched in glacier water. Half its bite is cold. |
| `hwp_mh_stiletto` | mainhand | Stiletto: Thin, fast and rude. Attacks faster and crits more often. |
| `hwp_mh_stormrod` | mainhand | Stormcaller Rod: Crackles between casts. Spells come out a little quicker. |
| `hwp_oh_bulwark` | offhand | Bulwark: A door with a handle. More armour and a bigger block than any heater shield. Uses the unused base tower shield model. |
| `hwp_oh_grimoire` | offhand | Ember Grimoire: The margins are scorched. Spell criticals burn harder. |
| `hwp_oh_handcannon` | offhand | Hand Cannon: A one-handed crossbow with more crossbow than hand. Likes to crit. |
| `hwp_oh_parrying_dirk` | offhand | Parrying Dirk: Made for turning blades aside, not for stabbing. Parries far more often. |
| `hwp_2h_warbow` | twohand | Warbow: A longbow that scales with dexterity instead of strength and rewards precise shots. |
| `hwp_2h_executioner` | twohand | Executioner's Axe: Built for one clean stroke. Hits very hard and crits a little more. |
| `hwp_2h_tempest` | twohand | Tempest Staff: A storm on a stick. Spells crit more often. |
| `hwp_2h_twinfangs` | twohand | Twin Fangs: Paired daggers with venom grooves. Quick, and the poison lingers. |

Names: `res/language/english/hwp_weapons.lang` (`.equipment.hwp.<id>`).
`hwp weapons` lists the registered ones with their blurbs.

## Test checklist

1. `python -m gamelab run mod-weapons --mode lab`: `[HWP:weapons] self-check done: 12 weapons` and no
   `missing item` errors.
2. In a run, `hwp weapons` lists all twelve.
3. With `e_cheats 1`, get the stats with `hwp statpoints 120` (place them in
   Strength and Dexterity), spawn one with `hwp equip hwp_2h_warbow` and
   equip it: model, swing animation and attack skill match the base weapon
   of that type; the tooltip shows the extra crit / speed / parry line.
