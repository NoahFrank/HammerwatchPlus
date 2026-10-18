# abyss

Path of Exile's Abyss, scaled down to a HoH2 level.

- **Placement.** Host, once per run level (3 s in), `abyss.chance` (30 %):
  `doodads/hwp/abyss_crack.unit` (vanilla shadow-rift effect, purple light,
  `netsync="position"`) at the position of a random live enemy at least 800 px
  from every player. `hwp abyss here` opens one next to the host.
- **Waves.** `HWPAbyssCrack` (host): dormant until a player is within
  `abyss.trigger` px (130). It then samples up to five enemy producers from the
  live enemies within 1600 px and runs `abyss.waves` (3) waves of
  `abyss.wave_base` (3) + `abyss.wave_per_player` × players + wave index
  enemies. Each wave erupts 70 px further along a random line and leaves a
  smaller fissure behind (`abyss_fissure.unit`). The last wave adds an
  `_elite` variant (two extra normals when none exists). A wave ends when all
  its enemies are dead or after 2 minutes; 1.5 s pause between waves.
- **Payout.** After the last wave the host spawns `hwp_abyss_reward`
  (`tweak/hwp/loot_abyss.sval`: gold, valuables, a rare/epic trinket and
  equipment piece) at the crack for the nearest player and removes the crack
  and fissures.
- **Messages.** `abyss.wave {n,total}` and `abyss.done` are broadcast and shown
  as chat lines on every machine.
- Settings: `abyss.enabled`, `abyss.chance`, `abyss.waves`, `abyss.wave_base`,
  `abyss.wave_per_player`, `abyss.trigger` (host-synced).

## Test checklist

1. `python -m gamelab run mod-abyss --mode lab`: `[HWP:abyss] self-check done`, no missing unit/loot errors.
2. Host a run, `hwp abyss here`, walk onto it: "The ground cracks open! Wave
   1 of 3"; waves advance as you clear them; the third has an elite; loot
   drops and the crack vanishes.
3. `abyss.chance 100`: the log shows `placed a crack at ...` on each level and
   it sits away from the start.
4. Co-op: the client sees the crack, the waves and the chat lines.

Timeout: a wave that is still alive after 2 minutes closes the crack without
a reward (no next wave, no loot). Wave members only spawn on free spots; a
wave with no free spot at all closes the crack too.
