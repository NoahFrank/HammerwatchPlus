# groupcombo

Combo together, get stronger together.

| Players in combo | Buff | Effect |
|---|---|---|
| 2 | Group Combo | +5% damage, +5% move speed, combo sustain +1 s |
| 3 | Group Combo II | +10% / +10% / +2 s |
| 4+ | Group Combo III | +15% / +15% / +3 s |
| everyone alive (2+) | **Group Unity** | 2 s of no damage taken, 30 s cooldown, chat announce |

- Host-only logic in `HWPGroupComboModule`: every 500 ms it counts living
  players with `PlayerBase.m_comboActive` (synced by the game) and re-applies
  the matching buff (`tweak/hwp/buffs_groupcombo.sval`, 1.5 s duration so it is
  continuous while the condition holds).
- Delivery: the host's own actor gets a real `ActorBuff`; remote players are
  husks on the host, so they get the vanilla `UnitBuffed` message and apply it
  themselves (same path as server-side shrine/effect buffs).
- `hwp groupcombo` prints the current count; `hwp set groupcombo.enabled
  false` turns it off (host setting).
- Numbers are a first guess for the morning: `tweak/hwp/buffs_groupcombo.sval`
  and the constants at the top of `GroupComboModule.as`.

## Test checklist

1. `python -m gamelab run mod-groupcombo --mode lab`: no script errors, no `[HWP:groupcombo] cannot load` line.
2. Co-op (2 players, host + client): both build a combo. Both see the "Group
   Combo" buff icon; the host log says `2/2 players in combo`; the chat shows
   the GROUP UNITY line and both take no damage for ~2 s. No second unity for
   30 s.
3. One player drops combo: the buff fades within ~1.5 s on both.
4. Solo: nothing happens (needs 2).
5. `hwp set groupcombo.enabled false` on the host: no buffs.
