# farming

Farm plots in town. Crops grow while you run the dungeon.

- **Plots.** The host spawns `farm.plots` (default 4, max 8) plot units
  (`doodads/hwp/farm_plot.unit`) in a row from `farm.x/y` (default
  -560,1040, meant for the farm segment south of the town square;
  `hwp farm here` moves them to where you stand and saves the setting). A
  plot's index comes from its position, so clients need no extra data.
- **Seeds.** Food crops (cabbage, carrot, onion, potato, wheat: 15-30 gold,
  ready after 1 run, 2-8 units) and the four Holy Herb strains (150-250
  gold, 2 runs, 1-2 units): Lucky Leaf, Ember Kush, Saint's Sage, Gambler's
  Gold. Planting is requested from the host (`farm.plant`); the host answers
  `farm.planted` and only then the requester pays the seed, or `farm.refused`
  (plot taken, disabled) which costs nothing. Harvest
  (`farm.harvest`) returns the yield to the requester (`farm.yield`) as
  wares (`HWP::Market`), which sell at the Gambler or with `hwp sell`.
- **Growth.** The host's own TownRecord keeps `farm.plots`, `farm.runs` and
  `farm.pending`: a gameplay load outside town sets pending, the next town
  load counts the run. Clients mirror the state through `farm.sync` (pulled
  with `farm.pull` when they load or open a plot).
- **Herbs.** Smoke one from any plot window or `hwp smoke <strain>`: it sets
  the `hwp_herb` mission buff (`tweak/hwp/buffs_herbs.sval`), which lasts
  exactly one run like tavern food. Lucky Leaf also makes the Gambler redraw a
  losing dealer card once (25 %).
- Visuals: a sprout while growing, the vanilla crop sprite (or a generated
  herb sprite) when ready; spawned locally, never networked.
- `farm.*` settings are host-synced. `farm.debug` enables `hwp farm grow`.

## Test checklist

1. `dev_check`: `[HWP:farming] self-check done: 9 seeds, 4 herb buffs`, no
   script issues.
2. Town: four soil patches appear; `hwp farm here` moves them. Open one,
   plant a cabbage (gold drops by 20), the window says growing (1), a sprout
   appears. `farm.debug 1`, `hwp farm grow` -> the plot shows the cabbage and
   "ready"; harvest -> 2-4 cabbages in `hwp wares`.
3. Real cycle: plant, run a mission (or abort it), return to town -> the plot
   advanced one run.
4. Herbs: plant Lucky Leaf, grow twice, harvest, Smoke it from the window;
   "Active herb: Lucky Leaf" shows, the loadout screen lists the buff, and the
   Gambler redraws sometimes. After the next run the buff is gone.
5. 2-player lobby: the client sees the plots and their state, can plant and
   harvest (yield lands on the client), and two players planting the same plot
   at once leaves one refunded.
