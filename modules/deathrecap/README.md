# deathrecap

League-style death recap. While you are dead a panel under the top of the
screen lists the five biggest damage sources of the last ten seconds, the total
and the physical / elemental split; the party sees a one-line summary in chat.

- `[Hook] PlayerDamageTaken(Player@, DamageInfo@)` (fires after mitigation)
  appends to a ring buffer for the **local** player only: source name,
  post-mitigation amount, and a physical/elemental split derived from the
  pre-mitigation components of `DamageInfo`.
- Source names: a player's name for player damage, otherwise the attacker
  unit's producer path prettified (`actors/undead/lich_king.unit` -> `Lich
  King`); no attacker (traps, lava, DoT without owner) -> "Hazards".
- `HWPDeathRecapModule` implements `IEventPlayerDied`; on the local player's
  death it aggregates, fills `HWPDeathRecapHUD` (added through
  `[Hook] HUDConstructor`, visible while `record.IsDead()`), stores the
  summary in the player record (`deathrecap.last`) and sends
  `deathrecap.announce` to the host, which broadcasts `deathrecap.show`; every
  machine prints "<name> was killed by A 60%, B 30%, C 10%" unless
  `/hwp set deathrecap.chat false`.
- `/hwp recap` reprints your last recap.

## Test checklist

1. `dev_check`: no script errors.
2. Solo: let a few enemy types hit you, die. The panel lists them with
   plausible percentages; log line `[HWP:deathrecap] <name> died: ...`. Panel
   disappears when you are back in town. `/hwp recap` prints the summary.
3. Stand in a trap / poison cloud: the source reads "Hazards".
4. Co-op: the other player sees the chat line in your player colour; their own
   death shows their panel only on their screen.
5. `/hwp set deathrecap.chat false`: no chat line on the next death.
