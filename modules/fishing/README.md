# fishing

A fishing spot in town and, sometimes, a fishing hole at the start of a run.

- **Town spot.** `doodads/hwp/fishing_spot.unit`, spawned by the host at
  `fishing.spot_x/y` (default -1600,330, meant for the trading-post docks;
  `/hwp fishing here` moves it to where you stand and saves the setting).
  Interacting opens the minigame: Cast, wait 0.8-3 s for a bite, then press
  Reel (button, Enter or gamepad confirm) while the sweeping marker is inside
  the green zone. The zone shrinks and the marker speeds up with the fish tier
  (55 % common, 28 % uncommon, 13 % rare, 4 % epic). The catch is a ware
  (`HWP::Market`, eight fish from Perch 15 g to Abyssal Eel 1000 g) that the
  Gambler's **Sell** button or `/hwp sell` turns into gold.
- **Run holes.** `fishing.run_chance` % of runs (default 30) the host places
  `doodads/hwp/fishing_hole.unit` next to the party at the start. Each player
  gets `fishing.run_casts` (3) casts per level: casting asks the host
  (`fishing.cast`), who counts the cast, rolls the tier and answers
  `fishing.bite` (tier + delay) or `fishing.denied` when the player is out of
  casts. Reeling in sends `fishing.catch` and the host spawns
  `hwp_fishing_run_<tier>` from `tweak/hwp/loot_fishing.sval` (food/mana
  pickups, gold, valuables, rare or epic gear) with the tier it rolled.
- `fishing.*` settings are host-synced. `fishing.debug` enables
  `/hwp fishing hole`.

## Test checklist

1. `dev_check`: `[HWP:fishing] self-check done: 8 fish`, no script issues.
2. Town: a rod + two fish appear at the spot; `/hwp fishing here` moves it.
   Catch a few fish, check `/hwp wares`, sell at the Gambler (button text shows
   the value) and with `/hwp sell`.
3. Miss on purpose: "It got away" and no ware added. Let a bite time out.
4. Run: with `fishing.debug 1`, `/hwp fishing hole`; catch 3 times -> loot
   spawns on the ground, 4th cast is refused. Client in a 2-player lobby: loot
   spawns for the client, refusal arrives as a chat line.
5. `fishing.enabled 0`: no spot spawns, existing spot cannot be used.
