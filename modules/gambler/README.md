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

## Gear reroll

The Gambler also rerolls equipment: pick one of your seven equipped slots with
the `<` / `>` buttons and pay **2000 gold x item level** (ilvl 20 = 40,000) to
regenerate the item's modifiers. The base item, quality, item level, upgrade
level and colours stay; the modifiers (and so the name) are rolled fresh by the
vanilla `Equipment::Generator::ModifyItem(..., clearMods=true)`, so the result is
exactly what the item could have dropped as. Legendaries and uniques can't be
rerolled. The new item is sent to the other players with the vanilla
`PlayerEquipmentEquip` message, same as equipping it.

Test: equip a rare, note its mods, reroll at the Gambler (gold drops by
2000 x ilvl, name/mods change, character sheet updates); try it with no gold
(refused with the price); in co-op the other player sees the new item in your
character inspect.
