# droptrade

Lets players trade equipment: the inventory's "Destroy" action becomes
"Drop / Destroy". Pressing it on an inventory item opens a three-button dialog:
**Drop** (default) puts the item on the ground at your feet for anyone to pick
up, **Destroy** (the MenuAdditional key) behaves like vanilla, Cancel closes.

Dropping uses `Item::DropItem`, which on a client sends the item to the host;
the host spawns it and replicates it, exactly like loot. The item is removed
from the dropper's inventory right away.

## Overrides

Two base files are replaced wholesale (declared in `module.json`, pristine
copies next to them as `.orig`; `tools/build.py --check` reports drift):

| File | Change |
|---|---|
| `scripts/GUI/PlayerMenu/Character.as` | `MenuAdditional()` opens the `hwp_dropdestroy` dialog; its `OnFunc` branch drops or destroys |
| `scripts/GUI/Widgets/EquipmentItemWidget.as` | navigation hint text `.menu.nav.destroy` -> `.hwp.droptrade.nav` |

The diff against the base is deliberately small (`diff -u X.orig X`). A
classmap would avoid the override entirely; `Character` is created by the
player menu by class name, so that is worth another look once classmaps are
confirmed to apply to GUI classes.

## Test checklist

1. `python -m gamelab run mod-droptrade --mode lab`: no script errors.
2. Solo: inventory item -> MenuAdditional key -> dialog shows three buttons;
   Drop puts the item on the floor and removes it from the inventory; picking it
   back up works; Destroy removes it; Cancel keeps it and restores the tooltip.
3. Co-op: a client drops an item, the host and other clients see it and can
   pick it up; the host drops, clients see it. Equipped items cannot be dropped
   (inventory only, as before).
