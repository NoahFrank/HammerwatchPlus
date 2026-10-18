# droptrade

Lets players trade equipment. Hovering an inventory item, the key hints at the
bottom read `Equip`, `Compare`, `Destroy`, **`[Q] Drop`**: Drop puts the item on
the ground at your feet for anyone to pick up, with no dialog; Destroy is
vanilla (asks first). The Destroy and Drop hints are also clickable buttons.

Dropping uses `Item::DropItem`, which on a client sends the item to the host;
the host spawns it and replicates it, exactly like loot. The item is removed
from the dropper's inventory right away.

The player menu has no free action binding, so the drop key is polled raw
(SDL scancode, default 20 = Q) by `scripts/HWP/DropTrade/DropTrade.as`, only
while the inventory tab is open and on top (not behind the destroy confirm)
and no text input or chat has the keyboard. The item leaves the bag before it
is dropped, so a stale hover can never spawn a copy. `hwp dropkey` shows it, `hwp dropkey 10 G`
changes it (per machine).

## Overrides

Two base files are replaced wholesale (declared in `module.json`, pristine
copies next to them as `.orig`; `tools/build.py --check` reports drift):

| File | Change |
|---|---|
| `scripts/GUI/PlayerMenu/Character.as` | `HWPDrop()` and `HWPHoveredItem()`; `OnInteractableIndexChanged` gives the Destroy / Drop hints click handlers; the constructor registers the tab for the drop key |
| `scripts/GUI/Widgets/EquipmentItemWidget.as` | a fourth navigation hint, `[Q] Drop` |

The diff against the base is deliberately small (`diff -u X.orig X`).
`Character` is created by the player menu by class name, so a classmap does
not reach it.

## Test checklist

1. `python -m gamelab run mod-droptrade --mode lab`: no script errors; the log names the menu's destroy key
   (`[HWP:droptrade] menu destroy key ...`), which must not be Q.
2. Solo: hover an inventory item: hints read Equip / Compare / Destroy / [Q] Drop.
   Q drops it at your feet at once; picking it back up works. Clicking "Drop"
   in the hint bar does the same; clicking "Destroy" opens the vanilla confirm.
3. Co-op: a client drops an item, the host and other clients see it and can
   pick it up; the host drops, clients see it. Equipped items cannot be dropped
   (inventory only, as before).
4. `hwp dropkey 10 G`: the hint reads [G] Drop and G drops.
