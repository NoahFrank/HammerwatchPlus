# pets

Pet progression, pet skills, per-pet pickup toggles, puzzle-room waiting and
every Heroes of Hammerwatch 1 pet skin in the HoH2 Pet Shop. Replaces the old
`petwait` module (its classmaps live here now).

- **Classmaps.** `info.xml` maps `MiniPetWalking -> HWPMiniPetWalking` and
  `MiniPetFlying -> HWPMiniPetFlying` (`scripts/HWP/Pets/PetClasses.as`), so
  every vanilla and imported pet gets the wait watcher, the owner's pickup
  toggles, the Fetch passives, the skill runner and XP per pickup. Pets are not
  netsynced: like vanilla, only the owner's copy picks up or acts.
- **HoH1 pets.** `python tools/import_hoh1.py pets` reads the player's own HoH1
  install and writes (gitignored) `players/pets/hwp/*.unit|.png`,
  `gui/hwp/icons_pets_hoh1.png` and `tweak/hwp/pets_hoh1.sval` (22 `PetDef`s,
  ids `hwp_pet_<skin>`, costs 2500-15000 like vanilla pets). The vanilla Pet
  Shop lists every `PetDef`, so they are bought and selected there. Units are
  rewritten for HoH2 (texture paths, pickup ranges, 1.4x speed; the living
  flame's missing textures are substituted). Names live in `hwp_pets.lang`.
- **Progress** is per pet definition in the owner's own PlayerRecord
  (`HWP::SaveData::Player`, keys `pets.<petId>.xp|lvl|<skill>`). XP: owner's
  kills (hook `PlayerKilledActor`: 5, elite 25, boss 150), pet pickups (2),
  feeding food crops at the **feeding bowl** (`doodads/hwp/pet_bowl.unit`,
  spawned locally in town at `pets.bowl_x/y`, default -600,980 next to the
  farm; `/hwp pet here` moves it on the host). Level cap 20, one skill point
  per level past 1. Numbers: `tweak/hwp/pet_skills.sval`.
- **Skills** (ranks 1-5, family 1-3): Hazard Clearer (vines), Smash
  (breakables), Stun (normal enemies only; stun_minor/stun/stun_greater),
  Mend (owner heal under 80 %), Fetch (passive ranges + speed, applied on
  respawn), Morale (owner speed buff out of combat,
  `tweak/hwp/buffs_pets.sval`), Family: wyrm fire breath on hazards, raven
  spots chests, scarab bonus gold per gold pickup, imp fire bolt on stunned
  targets, cat stronger Mend, dog stronger Morale, squire more Fetch.
- **Authority.** Effects on shared state go `pets.act` to the host, which
  checks the peer's reported ranks (`pets.level`, sent on load and on every
  change), a per-skill cooldown and a 500 px range to the requester before
  damaging/stunning. Mend and Morale touch only the owner and run locally.
  No skill fires in town or while the pet waits outside a puzzle room.
- **Pickup toggles** set `PlayerRecord.petOptions` (a vanilla field that is
  saved as `pet-options`); `ResetPet()` re-initialises the live pet. Bowl menu
  rows or `/hwp pet gold|valuables|materials|health|caches|cursed|elixirs|xp on|off`.
- **External pets.** `HWP::Pets::RegisterExternal(id, name, check)` lets a
  non-`MiniPet` pet (the Gold Collector) take part; its behaviour ticks a
  `HWP::Pets::SkillRunner` itself.
- Settings: `pets.enabled`, `pets.debug` (`/hwp pet xp <n>`), `pets.bowl_x/y`,
  `petwait.enabled`, `petwait.radius` (all host-synced).

## Test checklist

1. `dev_check`: `self-check done: 7 skills, 5 foods`; after import
   `22 HoH1 pet(s) in the Pet Shop`; `classmap active` lines once a pet spawns.
2. Pet Shop lists the HoH1 pets with icons; buying one spawns it; it follows,
   picks up gold, waits outside puzzle rooms.
3. `/hwp set pets.debug true`, `/hwp pet xp 500`: level-up chat line; the bowl
   menu shows points; spend on Smash: pots near the pet break in a run.
4. Stun on a goblin, never on an elite; Mend heals below 80 %; Morale buff icon
   out of combat only.
5. Feed a cabbage from the farm: ware count drops, XP rises.
6. Toggle Gold off: the pet ignores gold; on again: picks it up.
7. Co-op: client pet's Smash/Stun work (host log with `pets.debug`), client
   cannot spam (host cooldown), ranks survive a reconnect (`pets.level`).
