# strongbox

Path of Exile style strongboxes.

- **Placement.** The host, once per run level and about 2.5 s after the level
  starts, rolls `strongbox.chance` (40 %) and puts
  `doodads/hwp/strongbox.unit` at the position of a random live enemy that is
  at least 700 px from every player (`HWP::Spawner::PickFarSpot`). The unit is
  `netsync="position"`, so clients receive it. `hwp strongbox here` places one
  next to the host for testing.
- **Arming.** `HWPStrongbox : Chest`. Using it on the host samples up to four
  distinct enemy producers from the live enemies within 1200 px
  (`HWP::Spawner::SampleProducers`, bosses / spawners / nests / plants / towers
  excluded) and spawns `strongbox.pack` + `strongbox.pack_per_player` × players
  of them around the box, plus one `_elite` variant with
  `strongbox.elite_chance` when that unit exists. A client's use arrives on
  the host through the vanilla NetUse path. If there is nothing left to sample
  the box just opens.
- **Payout.** The host polls the pack every 0.5 s; when all are dead (or after
  3 minutes) it calls `Chest::Use` for the player who armed it (nearest player
  as fallback), which destroys the box and spawns `hwp_strongbox`
  (`tweak/hwp/loot_strongbox.sval`: gold, a valuable, a rare/epic trinket, a
  rare/epic equipment piece, maybe ore).
- **State sync.** `strongbox.state {unit, state}` is broadcast on arm and on
  clear so clients show the cross icon while the pack is alive.
- Settings: `strongbox.enabled`, `strongbox.chance`, `strongbox.pack`,
  `strongbox.pack_per_player`, `strongbox.elite_chance` (host-synced).

## Test checklist

1. `python -m gamelab run mod-strongbox --mode lab`: `[HWP:strongbox] self-check done`, no missing unit/loot errors.
2. Host a run, `hwp strongbox here`: an orange chest appears; use it: a pack
   spawns, the use icon turns into a cross, the chest opens when they are dead.
3. Run a few levels with `strongbox.chance 100`: the log shows `placed a
   strongbox at ...` each level, far from the party.
4. Co-op: the client sees the box, can arm it, and gets the loot when cleared.

Timeout: if the pack is still alive 3 minutes after arming (kited, stuck,
left behind) the box seals itself and disappears without loot. Pack members
are only spawned on free spots (collision query + line of sight from the box,
like the vanilla `safe-spawn`); members with no free spot are skipped and
logged.
