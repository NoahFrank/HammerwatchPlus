# gambler

A gambler NPC in the tavern. Talk to him to play higher-or-lower: pick a bet
(100 to 1M gold), flip; a higher card than the dealer wins the bet, lower loses
it, a tie returns it.

- Spawned by `HWPGamblerModule` at the tavern's table once the tavern is built
  (server only; the unit is netsynced and replicated to clients).
- Game logic in `scripts/HWP/Gambler/GamblerShop.as` (`HWPGamblerShop` /
  `HWPGamblerMenu`), GUI `gui/hwp_gambler.gui`, card sprites under
  `gui/hwp_gambler/cards/` (53 generated 32x64 PNGs).
- Bets are settled locally for the betting player (`GiveMaterial`), like any
  town shop.

Planned: move into the tavern prefabs as a "Gambler in Tavern" feature, and a
sell-to-gambler API for fish and herbs (Phase 5).

## Test checklist

1. `dev_check`: no script errors; `[HWP:gambler] spawned the gambler in the tavern`
   once a town with a tavern is entered (not in the main menu).
2. Solo: interact, every bet button only selectable when affordable, flip
   animates, gold changes match the result text, Reshuffle resets.
3. Co-op (2 players): the client sees one gambler (no duplicate), can play, and
   only the client's gold changes.
