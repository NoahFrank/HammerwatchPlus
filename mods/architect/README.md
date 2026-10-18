# architect

Architect alterations for the whole party.

- **Everyone can pick.** The Architect row in the run-start loadout is enabled
  for every player (vanilla: host only). Picks go to the host
  (`architect.pick`), which keeps one merged list with the payer of each pick
  and syncs it to everyone (`architect.sync`); the list shows `- name (payer)`
  and only the payer can remove their own pick.
- **Who pays what** (`SelectArchitectLoadout.CalcMyCost`): a sponsor pays the
  full price of their picks; the host's picks are **split evenly** (rounded
  up) across all players when the host setting `architect.split` is on
  (default). The vanilla cost multiplier counts every pick regardless of payer.
  `GetCost()` now returns the local share on clients too, so a player who
  cannot afford their share cannot ready up, and the share is deducted on each
  machine when the host starts (`OnPlay`).
- Override: `scripts/Missions/MissionArchitect.as` (declared in
  `module.json`, pristine `.orig` next to it, every change marked `HWP`).
  Vanilla's `SyncMissionLoadoutArchitect` message keeps working (host pays).
- Commands: `hwp architect` (list picks + payers), `hwp set architect.split
  false` (host only; rebroadcast immediately).

Morning decisions:
- The **town fountain** as a second entry point for sponsoring (open the
  picker in town, outside the loadout screen). The well/fountain unit sits at
  local offset (104,16) of the `town_square_*` prefabs (square 4 is at world
  -608,128); it needs an interact behaviour added by code or a classmap on the
  well unit. Not done yet.
- "Host approval required" mode and refunds on cancel (currently nothing is
  charged until the run actually starts, so cancel costs nothing).

## Test checklist

1. `python -m gamelab run mod-architect --mode lab`: no script errors; `python tools/build.py --check` reports the
   override as `OK`.
2. Solo (Dark Citadel / Mega Dungeon board): architect row is clickable, picks
   work, cost and multiplier match vanilla, gold is deducted on start.
3. Co-op: client opens its loadout, sees the architect row enabled, picks an
   alteration; both see `- name (client)` in the list. Host picks one; both
   see `(host)` and the client's cost shows half of the host's pick plus the
   client's full pick. Start: each pays their share (check gold before/after).
4. Client tries to unselect the host's pick: nothing happens; unselecting its
   own pick works and the host's list updates.
5. `hwp set architect.split false` on the host: the client's cost drops to its
   own picks only.
