# goldpet

A pet vendor in the Hunter's Lodge sells the Gold Collector cat and two upgrades:

| Tier | Cost | Needs | Collects |
|---|---|---|---|
| 1 | 10,000 gold | Hunter's Lodge | gold |
| 2 | 50,000 gold | Lodge tier 2 | all materials, experience scrolls |
| 3 | 150,000 gold | Lodge tier 3 | valuables too; +50 range, +25% speed |

- `HWPGoldPetModule` spawns the vendor (server) and re-summons every player's
  pet at level start. Ownership is in the char flags `has_gold_pet`,
  `has_gold_pet_tier_2`, `has_gold_pet_tier_3` (names kept from the standalone
  mod so existing characters keep their pet).
- `HWPGoldCollectorPet` (`scripts/HWP/GoldPet/GoldCollectorPet.as`) is the pet
  behaviour; pickups are server-authoritative, floating text and sounds only
  for the owner.
- `HWPPetVendorShop` / `HWPPetVendorMenu`, GUI `gui/hwp_goldpet_vendor.gui`.

Planned (Phase 6): the pickup logic moves into core and applies to every pet,
the vendor sells the HoH1 pets, and pets gain levels and skills.

## Test checklist

1. `python -m gamelab run mod-goldpet --mode lab`: no script errors; in town with a Hunter's Lodge:
   `[HWP:goldpet] spawned the pet vendor in the Hunter's Lodge`.
2. Solo: buy tier 1, the cat appears and picks up dropped gold; upgrade gates
   match the table; Summon re-creates a despawned pet; the pet is back after a
   level change and after reloading the character.
3. Co-op: the client's pet appears on both screens; the log shows one
   `waiting for the actor` line per player at most, never per tick.

## Networking

- The pet unit is netsynced, so only the host produces it. Buying or summoning sends the `goldpet.spawn` request (`HWP::Net`) with the tier; the host despawns a live pet and spawns the new one for that peer.
- A remote owner's pet pays its owner through the vanilla paths (`PickedMaterial` to the owner's peer, `UnitPicked` broadcast for scrolls) because the host's copy of a client's record is never saved or synced back.
