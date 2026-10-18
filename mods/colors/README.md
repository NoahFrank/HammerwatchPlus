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
- The preset is picked in **Options > Game > projectile colors** (just above
  the health bar options). It is the cvar `hwp_projectile_colors` (0-4 in the
  order above), registered from `[Hook] BaseGameModeConstructor` and saved in
  `HWR2.exe.cfg` like the vanilla options; `gui/options/game.gui` is a
  declared override with that one line added. Picking a preset there clears
  custom hex colours. An old `colors.preset` setting is moved into the cvar.
- Custom per-team colours (per machine, in your own town record):
  `colors.enemy`, `colors.friendly`. Commands (the preset ones set the cvar):
  `hwp colors` (show), `hwp colors deuteranopia`,
  `hwp colors enemy ff8800`, `hwp colors friendly 44aaff`, `hwp colors off`.

Open question: whether effects/AoE telegraphs should be tinted too (they
are `EffectBehavior` units, not projectiles).

## Test checklist

1. `python -m gamelab run mod-colors --mode lab`: no script errors.
2. `hwp colors contrast`, fire a ranged skill: your projectiles are blue-ish;
   ranged enemies' projectiles are red-ish. Beams (wizard) and ray projectiles
   also tint.
3. `hwp colors enemy 00ff00`: enemy shots go green; `hwp colors off` restores.
4. Options > Game: "projectile colors" sits above "enemy health bars";
   switching it changes projectile tints right away, and `hwp colors` shows the new preset.
5. Restart the game: the choice persists (`[HWP:colors] options cvar ...` in the log).
5. Co-op: a client's choice only changes that client's screen.
