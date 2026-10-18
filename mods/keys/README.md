# keys

HoH1-style locked chests, keys, the exit guard's key shop and red legendaries.

- **Locked chests.** `Chest` is swapped for `HWPChest` (module.json `class_swaps`: `tools/class_units.py` copies the chest units with our class). Every reward chest
  (`items/chests/chest_<bronze|silver|gold>_<trinket|equipment>.unit`, and the
  treasury rooms' `chest_platinum`, which takes a gold key) locks on its first
  tick and needs a key of its own tier; without one it shows a cross and a
  "Needs a Bronze Key" tooltip and does not open. Cursed chests and resource
  caches need no key. A locked chest shows a padlock tinted by tier and pays
  its own vanilla loot. `keys.lock_chance` (default 1) can make it a share;
  the roll is a hash of the chest's position, the mission reward seed and the
  level index, so host and clients agree without a message.
- **Ace chests.** 15 % of gold chests (`keys.ace_chance`) turn red and
  need an ace key. Opening one spawns the chest's own loot plus, 50/50
  (`keys.legendary_chance`), either an epic equipment drop or one red
  legendary **per player in the lobby** (instanced through `Item::DropItem`;
  tables in `tweak/hwp/loot_chests_ace.sval`).
- **Keys.** Vanilla `PlayerRecord.GetKeys/AddKeys` + the dormant `GiveKey`
  effect; pickups `items/hwp/keys/key_<tier>.unit`. Drops roll on the killer's
  machine (`PlayerKilledActor` is local-only) and the host spawns them
  (`keys.drop` request, flood-guarded at 10 per peer per 10 s). Normal enemies
  0.6/0.25/0.1 %, elites 8/5/3 % (bronze/silver/gold), times `keys.drop_mult`
  (default 2.5, since every chest wants a key). The first boss-tagged kill on a
  level has a 20 % (`keys.boss_chance`) key drop; its tier follows the floor's
  diff-level (up to 7 bronze, up to 13 silver, then gold), and from the
  mission's second-to-last boss on it is an ace key (Bone Serpent and Avatar in
  the Dark Citadel).
- **Imp offer.** `HWPImpKeyEffect` adds "a key" to the vanilla imp's random
  offers (`ImpEffect`), the tier scaled by the floor the same way.
- **Key shop.** The exit guard by the run start (our copy of
  `actors/npcs/town/npc_misc_guard_exit.unit`, a declared override) opens the
  shop first (`HWPGeneralMerchant`, stock `ShopWindow`); when it closes,
  NPCBehavior moves on to his vanilla speech bubble. Each key lists the loot
  quality of its chests. Prices `keys.price_<tier>` (500 / 2000 / 8000 /
  50000); only one ace key can be held at a time.
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

Open decisions: drop rates (`keys.drop_mult`), legendary balance and slots,
whether resource caches should want keys too.

## Test checklist

1. `python -m gamelab run mod-keys --mode lab`: no script errors, `Making Module hwp-keys`, lang check OK.
2. Town: talking to the exit guard by the run start opens the key shop: four
   keys, each subtitled with its loot quality; buying a bronze key deducts
   gold, logs the pickup and the HUD line appears top-right. Closing the shop
   shows his speech bubble.
   The fifth entry, Bag Slot, shows your bag size; buying it adds an empty
   slot (the fourth inventory row fills) and the price rises; at 32 slots it
   is greyed out. `hwp bag` shows the same.
3. `hwp set keys.debug 1`, `hwp keygive gold 2`, `hwp keygive ace`: HUD
   updates; `hwp keydrop silver` drops a pickup that adds a key when walked
   over (host and client).
4. Run: every reward chest has a padlock; without the key the use icon is a
   cross, the tooltip names the key and the chest does not open; with the key
   the padlock vanishes, the key count drops, the chest's own loot spawns.
   Cursed chests and caches open without a key.
5. `hwp set keys.ace_chance 1`: gold chests are red; opening with an ace key
   gives everyone a legendary or an epic; the legendary tooltip is red.
6. Kill an elite: sometimes a key drops. `hwp set keys.boss_chance 1`, kill a
   boss: one key of the floor's tier (ace on the Bone Serpent / Avatar).
   Talk to imps until one hands over a key of the floor's tier.
7. Co-op: the client sees the same chests locked as the host; client kills
   drop keys the host spawned; the client can open with their own key.
8. Disable the module: vanilla saves still load, keys remain in the record.
