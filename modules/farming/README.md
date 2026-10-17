# farming

Farm plots in town. Crops grow while you run the dungeon, twice as fast when
watered.

- **Plots are the field grooves.** In a town with the farm segment, the
  vanilla onion and wheat crops are hidden and every groove they stood on
  becomes a plot: 8 onion columns plus 9 wheat rows (17 plots; farm levels
  with only the wheat field have 9). Every machine reads the grooves from the
  same town prefab (`DetectFields`: crop units grouped by column / row, in a
  fixed order) and spawns its own sensor units along them
  (`doodads/hwp/farm_groove_v/h.unit`, one per 48 px, netsync none). A
  plot's index is the groove nearest to the player who interacts, so no unit
  ids go over the network. Without fields (farm level 0) the plots fall back
  to `farm.plots` (default 4) soil patches in a row from `farm.x/y`;
  `hwp farm here` (host) moves them to you and turns the fields off,
  `hwp farm fields` turns them back on.
- **Apple tree.** The apple tree below the wheat field is moved just above
  the field's top fence (local `SetPosition` on every machine).
- **Interact.** On a plot: empty -> pick one of your seeds; growing -> water
  it (one charge of your watering can, once per run); ready -> harvest. A
  growing plot that cannot be watered now (already watered, no can, empty
  can) opens the plot window instead, with the reason, so herbs can be
  smoked when no plot is empty. In the soil-patch layout the plot unit you
  touch decides the plot, not the nearest patch centre.
- **Farmer.** The vanilla farmer (`npc_misc_farmer_man.unit`, overridden;
  `.orig` kept) stands between the two fields instead of walking through them
  and runs a shop: the watering can (150 g, 4 water), upgrades to 6 / 9 / 12
  water (400 / 1000 / 2500 g) and seeds (15-250 g each).
- **Well.** A well (`doodads/hwp/farm_well.unit`, vanilla well sprites) next
  to the pet feeding bowl (`pets.bowl_x - 48`, `pets.bowl_y`; `hwp farm well`
  moves it to you, saved as `farm.well_x/y`) refills the can.
- **Seeds and growth.** Food crops (cabbage, carrot, onion, potato, wheat)
  need 2 growth, Holy Herb strains (Lucky Leaf, Ember Kush, Saint's Sage,
  Gambler's Gold) 4. A completed run adds 1 growth, 2 if the plot was watered
  since the last run: food takes 2 runs (1 watered), herbs 4 (2 watered).
  Harvest yields 2-8 food or 1-2 herbs as wares (`HWP::Market`, sold at the
  Gambler or with `hwp sell`), plus a 25 % chance of a seed back (5 % of the
  time two).
- **Network.** The host owns the plot state (seed, growth, watered) in its
  own TownRecord (`farm.plots`, `farm.runs`, `farm.pending`) and broadcasts
  every change (`farm.sync`); clients pull it when they load (`farm.pull`).
  Plant / water / harvest are requests to the host (`farm.plant`,
  `farm.water`, `farm.harvest`); the host answers `farm.planted`,
  `farm.watered`, `farm.yield` and only then the requester uses the seed or
  the water, or `farm.refused` (plot taken, already watered, not ready),
  which costs nothing. One plant or water request is in flight at a time
  (until the answer, at most 3 s), so a seed or a charge cannot be spent
  twice before the host answers. Can tier, water and seeds are per character
  (`farm.can`, `farm.water`, `farm.seed.<id>` in the player's HWP data).
- **Gear grid.** The watering can shows in the character screen's 3x3 gear
  grid (bottom right, core `hwp-gear-can` slot): dimmed without a can, the
  tooltip shows its tier and water.
- **Run counting.** A gameplay load outside town sets pending, the next town
  load counts the run. Saves from before watering ("at" = planted on run N)
  convert to growth on load.
- **Herbs.** Smoke one from an empty plot's window or `hwp smoke <strain>`:
  it sets the `hwp_herb` mission buff (`tweak/hwp/buffs_herbs.sval`), which
  lasts exactly one run like tavern food. Lucky Leaf also makes the Gambler
  redraw a losing dealer card once (25 %).
- Visuals, local on every machine: a sprout right after planting, a bigger
  sprout once it grew, the vanilla crop sprite (or a herb sprite) when ready,
  repeated on every spot of the groove; dark wet soil under watered plots.
- `farm.*` settings are host-synced. `farm.debug` enables `hwp farm grow`
  (counts a run).

## Test checklist

1. `dev_check`: `[HWP:farming] self-check done: 9 seeds, 4 herb buffs`, no
   script issues.
2. Town: the onion and wheat crops are gone, the log says
   `fields: 8 onion grooves, 9 wheat grooves` and `spawned N plot units`; the
   apple tree stands above the wheat field's top fence and nothing collides
   where it used to be.
3. Farmer between the fields: buy a can (gold -150, "Watering can: 4/4") and
   a cabbage seed. Interact on an onion groove -> the window lists the seed;
   plant it -> sprouts along the whole groove.
4. Interact again -> watered (can 3/4, wet soil under the sprouts); again ->
   "Already watered". `farm.debug 1`, `hwp farm grow` -> the crop is ready
   (2 growth); interact -> harvested 2-4 cabbages, sometimes +1/+2 seeds.
5. Well near the pet bowl refills the can; without a can it says so.
   `hwp farm well` moves it.
6. Real cycle: plant without watering, run a mission, return -> half grown
   (bigger sprout); run again -> ready.
7. Herbs: plant Lucky Leaf, grow, harvest, smoke from an empty plot's
   window; the buff shows in the loadout screen and is gone after the next
   run.
8. 2-player lobby: both see the same plots, sprouts and wet soil; the client
   plants, waters (its own can) and harvests (yield on the client); two
   players planting the same groove at once leaves one with the seed back.
9. Character screen: the can slot (bottom right of the gear grid) is dimmed
   before you buy a can; afterwards its tooltip shows the tier and water,
   and watering a crop lowers the count.
