# fishing

Fishing along the town's coast, a pirate who sells bait, rods and fish traps,
fishing spots at the potion wells of run floors (always one in a boss room),
and fish that sell for the Gambler's bet tokens or fight as swords.

- **Coast spots.** Six `doodads/hwp/fishing_spot.unit` along the town's west
  coast (the `water_coastline` pieces of `prefabs/town/segments/base.lvl`).
  Every machine spawns its own copies (`netsync="none"`), so each player fishes
  locally. Interacting opens the minigame: **Cast** (costs one of the bait on
  your hook; the **Bait** button cycles the kinds you have), wait
  0.8-3 s for a bite, then press **Reel** (button, Enter or gamepad confirm)
  while the sweeping marker is inside the green zone. The zone shrinks and the
  marker speeds up with the fish tier.
- **Fish are swords.** The catch goes into your bag (or drops at your feet when
  the bag is full) as `hwp_fish_<id>` from `tweak/hwp/fishing_items.sval`: a
  main-hand weapon that swings like the longsword (`attack_swing_longsword`,
  Perch 28-34 up to Abyssal Eel 50-60 physical), excluded from random loot.
  It carries the `mods_weapon_mainhand(_melee)` tags, so the enchanter can
  upgrade it (commons) and enchant it (uncommon and rare fish) like any
  weapon. Its **item level** is set where it was caught: town fish are ilvl
  1-6 by tier; a run catch uses the floor's drop level (`g_diffLevel`, which
  includes NG+, +-1, capped at your drop level cap), like gear.
- **Stars and bet tokens.** Fish are 1, 2 or 3 star (tiers 1-2, 3, 4) and sell
  for 1 / 3 / 5 **bet tokens** (`HWP::Market` token price; the pirate's Sell
  button, `hwp fishing sell`, the Gambler's Sell button or `hwp sell`). The
  Gambler rerolls gear for 1 token per 5 item levels. Town water only has
  1-star fish; star fish (2+) bite only in the second half of a run's floors,
  and boss rooms have only 3-star fish. The host announces each catch.
- **Fish traps.** The pirate sells up to 3 (500 / 1000 / 2000 g). They sit in
  the water off three of the coast spots (`fish_trap.unit`, `fish_trap_full.unit` with a fish
  and a map icon once something is inside). The time you spend on a run is
  counted (`fishing.run_ms`, flushed every 5 s); back in town every 10 minutes
  of it gives each trap a 50 % chance of +1 fish, up to 3 per trap. Walk up
  to a trap to empty it into your bag. `hwp fishing traps` lists them.
- **Rods.** Per character (`fishing.rod` in your HWP save data): Driftwood (free),
  Sturdy (400 g), Sea (1200 g), Captain's (3000 g). Each tier widens the catch
  zone by 20 %, slows the marker by 10 % and raises the odds of rare and epic
  fish. The rod shows in the character screen's gear grid (core
  `hwp-gear-rod` slot) with its bonuses and your bait.
- **The pirate fisherman** (`doodads/hwp/pirate_fisher.unit`, interact class
  `HWPPirateShop`) sits on the half-buried boat next to the trading post's
  "Trade materials" NPC and talks like a pirate. He sells worms (5 for 50 g,
  20 for 180 g), shrimp (5 for 400 g), glow squid (3 for 900 g) and the next
  rod. The bait decides the coast's star range: worms 1-2, shrimp 2-3, squid
  3-4 (`BAIT_MIN_TIER`/`BAIT_MAX_TIER`); the rod's bonuses roll within it.
  Each kind is a cell in the materials tab's Supplies section with a tooltip.
  From trading post tier 3 the wreck becomes a whole boat and he stands on the
  beach beside it, where the wreck was (tiers 4-5: the same spot). His spot is
  taken from the material trader's position; a building upgrade rebuilds the
  town and removes him, so the coast is placed again within a second.
  `hwp set fishing.pirate_x/y` put him anywhere. He has an anchor merchant
  icon on the map (`gui/hwp/map_pirate.png`).
- **Run spots.** On `fishing.run_chance` % of floors (default 30) the host
  places `fishing_hole_well.unit` beside one of the floor's potion-refill
  wells (levels have no reachable open water). A boss room always gets one:
  at its well, or a fishing bucket (`fishing_bucket.unit`) beside the host
  when it has none. No bait is needed. Each player gets `fishing.run_casts`
  (3) casts per floor: casting asks the host (`fishing.cast` with the rod
  tier), who counts the cast, rolls the tier within the floor's star range and
  answers `fishing.bite` or `fishing.denied`. Reeling in sends
  `fishing.catch`: the host spawns `hwp_fishing_run_<tier>` loot and sends the
  catcher `fishing.landed` (fish + item level) for the fish itself.
- Fishing spots, holes and full traps show a fish icon on the minimap
  (`gui/hwp/map_icons.png` from core, made by `tools/make_map_icons.py`).
- `fishing.*` settings are host-synced; `fishing.coast 0` removes the coast
  spots and the pirate. `hwp fishing buy bait|bait20|shrimp|squid|rod|trap` buys from the
  console. With `fishing.debug 1`: `hwp fishing hole` (host), `hwp fishing
  catch [tier]`, `hwp fishing bait <worm|shrimp|squid> [n]`, `hwp fishing traps <minutes>` (fill
  the traps as if back from a run that long).

## Test checklist

1. `python -m gamelab run mod-fishing --mode lab`: `[HWP:fishing] self-check done: 8 fish, 0 missing items`, no
   script issues.
2. Town: six rod + fish spots along the west beach, the pirate on the boat by
   the trading post. `hwp fishing` shows the spot count and his position.
3. Pirate: greeting in pirate speak, buy bait (gold drops, bait rises), buy a
   rod with too little gold (refused), then with enough. Status updates live.
4. Coast cast without bait: refused. The Bait button cycles worms / shrimp /
   squid (only kinds you have); squid catches only 3-4 star fish. With bait: the marker sweeps the bar
   (it moves), a hit puts the fish in your bag, a miss says "It got away"; each
   cast costs one bait. Full bag: the fish drops on the ground.
5. Equip a fish: it swings like a sword; its tooltip shows the item level.
   Take an uncommon fish to the enchanter: upgrade and enchant work. Sell fish
   at the pirate, the Gambler and with `hwp sell`: they leave the bag and the
   bet tokens rise by 1 / 3 / 5 per star.
6. Character screen: the rod slot (bottom left of the 3x3 gear grid) shows the
   rod's name, bonuses and bait in its tooltip.
7. 2-player lobby: both see their own spots and pirate; a catch is announced
   to the other player.
8. Run: a fishing spot by a well on some floors (fish icon on the map);
   catch 3 times -> loot and a fish of the floor's item level, the 4th cast is
   refused. First-half floors give 1-star fish only, boss rooms 3-star only
   (at the well or a bucket). A client gets the refusal as a chat line.
9. Traps: buy 1-3 at the pirate (prices rise, 4th refused); after a run of
   20+ minutes some traps show a fish; walk up to one: its fish go to the bag.
   `fishing.debug 1`, `hwp fishing traps 60` fills them without a run.
10. `fishing.enabled 0`: spots and pirate cannot be used.
