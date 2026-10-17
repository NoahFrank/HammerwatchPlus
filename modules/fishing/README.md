# fishing

Fishing along the town's coast, a pirate who sells bait and rods, and
sometimes a fishing hole at the start of a run.

- **Coast spots.** Six `doodads/hwp/fishing_spot.unit` along the town's west
  coast (the `water_coastline` pieces of `prefabs/town/segments/base.lvl`).
  Every machine spawns its own copies (`netsync="none"`), so each player fishes
  locally. Interacting opens the minigame: **Cast** (costs one bait), wait
  0.8-3 s for a bite, then press **Reel** (button, Enter or gamepad confirm)
  while the sweeping marker is inside the green zone. The zone shrinks and the
  marker speeds up with the fish tier.
- **Fish are items.** The catch goes into your bag (or drops at your feet when
  the bag is full) as `hwp_fish_<id>` from `tweak/hwp/fishing_items.sval`: a
  common main-hand mace-style weapon with weak physical damage (Perch 3-5 up
  to Abyssal Eel 20-25), excluded from random loot. The Gambler's **Sell**
  button and `hwp sell` buy them (`HWP::Market` counts fish items in your bag),
  and other vendors buy them like any item. The host announces each catch to
  the lobby in chat.
- **Rods.** Per character (`fishing.rod` in your HWP save data): Driftwood (free),
  Sturdy (400 g), Sea (1200 g), Captain's (3000 g). Each tier widens the catch
  zone by 20 %, slows the marker by 10 % and raises the odds of rare and epic
  fish. The rod shows in the character screen's gear grid (core
  `hwp-gear-rod` slot) with its bonuses and your bait.
- **The pirate fisherman** (`doodads/hwp/pirate_fisher.unit`, interact class
  `HWPPirateShop`) sits on the half-buried boat next to the trading post's
  "Trade materials" NPC and talks like a pirate. He sells 5 bait for 50 g, 20
  for 180 g and the next rod. When the trading post has no boat (tier 4 and
  up), a copy of the wreck (`pirate_wreck.unit`) is placed for him.
  `fishing.pirate_x/y` move his boat search point.
- **Run holes.** `fishing.run_chance` % of runs (default 30) the host places
  `doodads/hwp/fishing_hole.unit` next to the party at the start. No bait is
  needed. Each player gets `fishing.run_casts` (3) casts per level: casting asks
  the host (`fishing.cast` with the rod tier), who counts the cast, rolls the
  tier and answers `fishing.bite` (tier + delay) or `fishing.denied`. Reeling
  in sends `fishing.catch` and the host spawns `hwp_fishing_run_<tier>` from
  `tweak/hwp/loot_fishing.sval` with the tier it rolled.
- `fishing.*` settings are host-synced; `fishing.coast 0` removes the coast
  spots and the pirate. `hwp fishing buy bait|bait20|rod` buys from the
  console. With `fishing.debug 1`: `hwp fishing hole` (host), `hwp fishing
  catch [tier]`, `hwp fishing bait [n]`.

## Test checklist

1. `dev_check`: `[HWP:fishing] self-check done: 8 fish, 0 missing items`, no
   script issues.
2. Town: six rod + fish spots along the west beach, the pirate on the boat by
   the trading post. `hwp fishing` shows the spot count and his position.
3. Pirate: greeting in pirate speak, buy bait (gold drops, bait rises), buy a
   rod with too little gold (refused), then with enough. Status updates live.
4. Coast cast without bait: refused. With bait: the marker sweeps the bar
   (it moves), a hit puts the fish in your bag, a miss says "It got away"; each
   cast costs one bait. Full bag: the fish drops on the ground.
5. Equip a fish (weak weapon), sell fish at the Gambler and with `hwp sell`;
   the fish items leave the bag.
6. Character screen: the rod slot (bottom left of the 3x3 gear grid) shows the
   rod's name, bonuses and bait in its tooltip.
7. 2-player lobby: both see their own spots and pirate; a catch is announced
   to the other player.
8. Run: with `fishing.debug 1`, `hwp fishing hole`; catch 3 times -> loot
   spawns, the 4th cast is refused. A client gets the refusal as a chat line.
9. `fishing.enabled 0`: spots and pirate cannot be used.
