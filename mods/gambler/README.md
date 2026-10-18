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

His **Sell** button buys your wares (`HWP::Market`): crops and herbs for gold,
fish for bet tokens (1 / 3 / 5 per 1 / 2 / 3-star fish). The tokens line
under the reroll row shows how many you have.

## Test checklist

1. `python -m gamelab run mod-gambler --mode lab`: no script errors; `[HWP:gambler] spawned the gambler in the tavern`
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
exactly what the item could have dropped as. Legendary, unique, quest and
cursed gear can't be rerolled (the row shows them as "can't be rerolled"). The new item is sent to the other players with the vanilla
`PlayerEquipmentEquip` message, same as equipping it.

Test: equip a rare, note its mods, reroll at the Gambler (gold drops by
2000 x ilvl, name/mods change, character sheet updates); try it with no gold
(refused with the price). **Token reroll:** the second button pays 1 bet token
per 5 item levels (ilvl 1-5 = 1, 6-10 = 2, ...) instead of gold; with too few
tokens it is refused with the price. In co-op the other player sees the new item in your
character inspect.
