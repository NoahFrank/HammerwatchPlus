# summons

Priest improvement: **Crusader summons persist between floors**. Vanilla
destroys every summon with the old level and the Crusader has to re-summon
them one by one (15 s each) on the new floor. With this module the pikemen,
crossbowmen and boon pikemen that were alive when you took the exit are
produced again next to you on the next floor, with the HP they had.

- **How.** Every 500 ms during a run, the local player's tracked summons are
  snapshotted with the game's own `SaveUnit()` (the same data a save game
  stores). On the next floor's `GameModeSpawnPlayer` for the local player,
  the snapshot is produced again next to the player the same way `Player`'s
  constructor restores summons from a save game: the host produces directly,
  a client sends the vanilla `SpawnPlayerSummon` message to the host. The
  skill's `max-summoned` cap is still enforced by `Player::Update`.
- Town clears the snapshot (nothing follows you home). Summons that died
  before the exit are not restored.
- Tracked units: `players/priest/units/crusader_pikeman.unit`,
  `crusader_crossbowman.unit`, `crusader_pikeman_boon.unit`. Setting
  `summons.all` (default off) tracks every saveable summon instead (wolves,
  Warlock minions, ...). `summons.enabled` turns it off. Both host-synced.
- `hwp summons` shows the state, snapshot size and how many were restored on
  this floor.

## Test checklist

1. `python -m gamelab run mod-summons --mode lab`: `[HWP:summons] self-check done: 3/3 tracked units`.
2. Priest with Call Crusaders: summon 2-3 crusaders, take the exit. On the
   next floor they appear next to you within a second; the log has
   `[HWP:summons] restored N summon(s)`. `hwp summons` agrees.
3. Let them all die before the exit: nothing is restored.
4. Return to town: no crusaders in town.
5. Co-op: a client Priest's crusaders also come through (host produces them).
