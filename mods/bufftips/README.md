# bufftips

Hover a buff or debuff icon in the HUD's buff bar to get a tooltip: the time
left in seconds on top (counting down), then the effect's name (red for
debuffs, "x N" for stacks) and its description.

- HUD components get no mouse input, so `HWPBuffTipsHUD` (added through
  `[Hook] HUDConstructor`, drawn on top) hit-tests the cursor against the
  `HUDBuffs` icon widgets every frame, scaled by the buff bar's own
  `ui_hud_scale_buffs`, and draws a vanilla `CreateTooltip` box with the time
  as its header. The box is rebuilt only when the hovered buff, the whole
  seconds left or the stack count change.
- Name and description come from the buff's def (`ActorBuff`), its stack def
  or buff def (`ActorBuffStacked`), or the skill (`Skills::StackSkill`).
- Hidden while a menu is open. Setting `bufftips.enabled` (default on).
- Buffs without a `hud` icon never reach the buff bar, so they get no tooltip;
  the Effects tab of the character menu still lists them by name and
  description. HWP buffs given descriptions (and icons where they are
  one-shot) for this: spec reworks, HoH1 class skills, pet Morale (no icon:
  re-applied every 2 s), Spirit Cloak.

## Test checklist

1. `python -m gamelab run mod-bufftips --mode lab`: `[HWP:bufftips] ready`, no script errors.
2. In a run, get a timed buff (a shrine, a potion, a class skill). Hover its
   icon: the tooltip shows "Ns left" counting down, the name and what it does.
3. A debuff's title is red; a stacking buff shows "x N".
4. Open the character menu: no buff tooltip over the menu.
5. Effects tab: Warden's Resolve (and the other HWP buffs) show a description.
