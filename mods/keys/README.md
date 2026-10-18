# keys

HoH1-style locked chests, keys, the General Merchant and red legendaries.

- **Locked chests.** `Chest` is swapped for `HWPChest` (module.json `class_swaps`: `tools/class_units.py` copies the chest units with our class). Every reward chest
  (`items/chests/chest_<bronze|silver|gold>_<trinket|equipment>.unit`) rolls a
  lock on its first tick from a hash of its position, the mission reward seed
  and the level index, so host and clients agree without a message. Default
  35 % of chests lock (`keys.lock_chance`); a locked chest shows a padlock
  tinted by tier and pays like the next tier up (`tweak/hwp/loot_chests_locked.sval`).
- **Ace chests.** 15 % of locked gold chests (`keys.ace_chance`) turn red and
  need an ace key. Opening one spawns the chest's own loot plus, 50/50
  (`keys.legendary_chance`), either an epic equipment drop or one red
  legendary **per player in the lobby** (instanced through `Item::DropItem`).
- **Keys.** Vanilla `PlayerRecord.GetKeys/AddKeys` + the dormant `GiveKey`
  effect; pickups `items/hwp/keys/key_<tier>.unit`. Drops roll on the killer's
  machine (`PlayerKilledActor` is local-only) and the host spawns them
  (`keys.drop` request, flood-guarded at 10 per peer per 10 s). Normal enemies
  0.6/0.25/0.1 %, elites 8/5/3 % (bronze/silver/gold), the first boss-tagged kill on a level
  always a gold key and 10 % an ace key.
- **General Merchant.** `actors/npcs/town/hwp_general_merchant.unit`, spawned
  by the host next to the town fountain (`keys.merchant_x/y`, default
  -560,152). Stock `ShopWindow`; prices `keys.price_<tier>` (500 / 2000 /
  8000 / 50000). Only one ace key can be held at a time.
  He also sells **bag slots** (core `HWP::Bag`): one more equipment bag slot
  per purchase for the buyer's character, 1000 g rising to 20000 g, up to a
  full extra row (32 slots).
- **Legendaries.** `tweak/hwp/legendaries.sval` ports the seven HoH1 red items
  with HoH2 modifiers (meteor on hit, gold-scaled damage, slowing gaze,
  nova on attack, invulnerability on hurt, kill-same-type, chaos bolts),
  quality `Legendary`, drop-rate 0 so they only come from ace chests.
- All `keys.*` settings are host-authoritative: clients read the host's
  values (core `settings.sync`), so every machine rolls the same locks.
- HUD: key counts top-right while you hold any key.
- Commands: `hwp keys` (counts + settings), `hwp keygive <tier> [n]` and
  `hwp keydrop <tier>` when `keys.debug` is on.

Morning decisions: drop/lock rates, merchant position, legendary balance and
slots, whether locked chests should also appear in resource caches.

## Test checklist

1. `python -m gamelab run mod-keys --mode lab`: no script errors, `Making Module HWPKeysModule`, lang check OK.
2. Town: the General Merchant stands by the fountain; talking opens a shop
   with four keys; buying a bronze key deducts gold, logs the pickup and the
   HUD line appears top-right.
   The fifth entry, Bag Slot, shows your bag size; buying it adds an empty
   slot (a fourth inventory row appears, the scrollbar reaches it) and the
   price rises; at 32 slots it is greyed out. `hwp bag` shows the same.
3. `hwp set keys.debug 1`, `hwp keygive gold 2`, `hwp keygive ace`: HUD
   updates; `hwp keydrop silver` drops a pickup that adds a key when walked
   over (host and client).
4. Run: `hwp set keys.lock_chance 1`, enter a level: every reward chest has
   a padlock; interacting without the key does nothing; with the key the
   padlock vanishes, the key count drops, loot of the higher tier spawns.
5. `hwp set keys.ace_chance 1`: gold chests are red; opening with an ace key
   gives everyone a legendary or an epic; the legendary tooltip is red.
6. Kill an elite / boss: a key drops (boss: gold, sometimes ace).
7. Co-op: the client sees the same chests locked as the host; client kills
   drop keys the host spawned; the client can open with their own key.
8. Disable the module: vanilla saves still load, keys remain in the record.
