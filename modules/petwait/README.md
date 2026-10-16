# petwait

Pets wait outside puzzle rooms instead of trotting over the floor buttons.

- `info.xml` **classmaps** `MiniPetWalking -> HWPMiniPetWalking` and
  `MiniPetFlying -> HWPMiniPetFlying` (`scripts/HWP/PetWait/PetWait.as`). The
  subclasses wrap `Update(dt)` with a `Watcher`.
- Every 400 ms the watcher does a `QueryCircle` (radius 120, setting
  `petwait.radius`) around the **owner** and checks producer paths:
  `doodads/buttons/*` or anything containing `puzzle` (`prefabs/puzzles/*`,
  `puzzle_brazier`, `puzzle_chance`). Puzzle doodads have no behaviours, so the
  path is the only handle on them.
- While a puzzle is near, the pet walks to the last owner position that was
  clear and idles there: no pickups, no leash, no teleport. When the owner moves
  away the base behaviour resumes (`ClearTarget`, retarget immediately).
- Every machine computes this from the owner's synced position, so husks park
  in the same spot without extra messages.
- `/hwp set petwait.enabled false` turns it off; `petwait.radius` tunes the
  distance.

Open question for the morning: whether classmaps apply to classes named in
`.unit` files (expected) - the constructor logs
`[HWP:petwait] classmap active: ...` the first time a pet spawns, so the first
run with a pet answers it.

## Test checklist

1. `dev_check`: no script errors.
2. Spawn a pet (goldpet vendor or a vanilla pet), enter any level: log shows
   `classmap active: MiniPetWalking -> HWPMiniPetWalking`.
3. Walk into a puzzle room (floor buttons): the pet stops at the entrance and
   idles; it does not step on buttons. Leave: it follows again.
4. Flying pet (vanilla bat/bird): same behaviour, no animation glitch while
   parked.
5. Co-op: the client's pet parks on the host's screen too and vice versa.
6. `/hwp set petwait.enabled false`: pet follows into the room again.
