# weaponswap

A second weapon set toggled with a hotkey.

- Stash = one main-hand + one off-hand item, serialized with `Item::SaveItem`
  into the player record (`hwp` bag, keys `weaponswap.main` / `weaponswap.off`),
  so it follows the character through saves and can never duplicate an item.
- **X** (SDL scancode 27, polled with `IsKeyDown`) swaps: unequip the worn pair
  into the stash, equip the stashed pair through the vanilla `EquippedItems`
  (which syncs `PlayerEquipmentEquip/Unequip` to the lobby and refreshes
  modifiers/skills). Empty stash -> the key stashes what you hold; equip other
  weapons from the bag; press again to toggle.
- Requirement checks (`MayEquip`) run before anything is unequipped; an item
  you can no longer wield stays in the stash and you are told.
- 1.5 s cooldown, ignored while dead, paused or typing in chat.
- HUD: a one-line reminder under the top of the screen, `[X] Sword / Shield`,
  shown only while a stash exists.
- Commands: `/hwp swap`, `/hwp swapkey` (show), `/hwp swapkey 21 R` (set
  scancode + label), `/hwp swapdrop` (stash back to the inventory if it fits).

Morning decisions: a proper keybinding in the controls menu instead of a
scancode setting; whether swapping should be allowed in town.

## Test checklist

1. `dev_check`: no script errors.
2. Solo, in a run: press X with a sword equipped -> "Weapons stashed", hands
   empty, HUD line shows the sword. Equip a bow from the bag, press X -> sword
   back, bow in the HUD line. Spam X: only one swap per 1.5 s.
3. Save and reload: the HUD line still shows the stash; swap works.
4. Equip a two-handed weapon while an off-hand is stashed, swap: the off-hand
   stays stashed (no loss), message explains.
5. `/hwp swapkey 21 R`: R swaps, X does not. `/hwp swapdrop`: items land in
   the inventory, HUD line disappears.
6. Co-op: the other player sees your weapon model change on swap.
