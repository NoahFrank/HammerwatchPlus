# weaponswap

Two weapon sets per character, toggled with a hotkey.

- The set in your hands is equipped normally; the other set (one main-hand +
  one off-hand item) is serialized with `Item::SaveItem` into your HWP save
  data (keys `weaponswap.main` / `weaponswap.off`, the active set number in
  `weaponswap.set`), so it follows the character through saves and can never
  duplicate an item.
- **X** (SDL scancode 27, polled with `IsKeyDown`) swaps: the held pair goes
  into the store, the stored pair is equipped through the vanilla
  `EquippedItems` (which syncs `PlayerEquipmentEquip/Unequip` to the lobby and
  refreshes modifiers and skills). Set 2 starts empty, so the first swap leaves
  your hands empty; equip the second set from your bag, then X flips between
  the two.
- Requirement checks (`MayEquip`) run before anything is unequipped; an item
  you can no longer wield stays in the store and you are told. Equip checks
  again without the pair just taken off (its stats may have been what made
  the other weapon wieldable); a refused item stays stored, and a weapon that
  cannot go back into your hands goes to the bag, so nothing is ever lost.
  With both sets empty a swap does nothing ("Both weapon sets are empty").
- 1 s cooldown (the hotkey and clicking an alt slot); ignored while dead,
  paused, typing in chat or in a menu.
- **Character screen:** the other set shows in two `hwp-gear-slot` widgets
  (core `HWP::Gear`, ids `hwp-alt-main` / `hwp-alt-off`) next to the 3x3 gear
  grid. A two-hander's off-hand slot mirrors the main hand, dimmed. Click a
  slot (or press X) to swap; the tooltip shows the stored item or how to use it.
- **HUD tip:** while you are empty-handed with weapons in the other set, an
  on-screen line says to press X.
- Commands: `hwp swap`, `hwp swapkey` (show), `hwp swapkey 21 R` (set
  scancode + label), `hwp swapdrop` (other set back to the inventory if it
  fits).

## Test checklist

1. `python -m gamelab run mod-weaponswap --mode lab`: no script errors; `hwp swap` twice logs `set 2 in hand` /
   `set 1 in hand`.
2. Solo: press X with a sword -> hands empty, the sword shows in the alt slot
   of the character screen, the HUD tip appears. Equip a bow, press X -> sword
   back, bow in the alt slot. Spam X: one swap per second.
3. Click the alt main-hand slot in the character screen: the sets swap.
4. Save and reload: the alt slots still show the other set; swap works.
5. A two-hander in the other set: the alt off-hand slot mirrors it, dimmed.
6. `hwp swapkey 21 R`: R swaps, X does not. `hwp swapdrop`: items land in
   the inventory, the alt slots empty.
7. Co-op: the other player sees your weapon change on swap.
