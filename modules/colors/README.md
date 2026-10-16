# colors

Accessibility colours for projectiles.

- `info.xml` **classmaps** `NewProjectile`, `RayProjectile` and
  `BeamProjectile` to `HWP*` subclasses that call
  `HWP::Colors::Tint(m_unit, owner)` after the base `Initialize`. Friendly =
  the owner resolves through `GetPlayerOwner` (players, summons, turrets);
  everything else is enemy. The tint is `UnitPtr.SetMultiplyColor`, so it
  multiplies the sprite: dark sprites get darker, white/pale ones take the
  colour best.
- Presets: `default` (no tint), `contrast` (red vs light blue),
  `deuteranopia` (orange vs blue), `protanopia` (yellow vs blue),
  `tritanopia` (red vs teal). Per-team overrides as hex.
- Settings (per machine, in your own town record): `colors.preset`,
  `colors.enemy`, `colors.friendly`. Commands:
  `hwp colors` (show), `hwp colors deuteranopia`,
  `hwp colors enemy ff8800`, `hwp colors friendly 44aaff`, `hwp colors off`.

Morning decisions: whether effects/AoE telegraphs should be tinted too (they
are `EffectBehavior` units, not projectiles) and a GUI picker.

## Test checklist

1. `dev_check`: no script errors.
2. `hwp colors contrast`, fire a ranged skill: your projectiles are blue-ish;
   ranged enemies' projectiles are red-ish. Beams (wizard) and ray projectiles
   also tint.
3. `hwp colors enemy 00ff00`: enemy shots go green; `hwp colors off` restores.
4. Reload the save: the choice persists (`[HWP:colors] preset ...` in the log).
5. Co-op: a client's choice only changes that client's screen.
