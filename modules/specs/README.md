# specs

The spec-rework skeleton ("elite specs"). Real reworks will be designed spec
by spec with the user; this module is the data-only first step so the weakest
specialisations are playable now and the numbers can be tuned without code.

- **Which specs.** The community tier lists (ProGameGuides, AMK Station,
  UrGameTips, GrindNStrat, TheGamer, Steam discussions, all mid 2025) agree on
  the bottom of the table: Ranger **Warden** (`ranger_nature`), Warlock
  **Summoning** (`warlock_summoning`), Wizard **Conjuration**
  (`wizard_conjuration`) and Wizard **Transmutation** (`wizard_transmutation`).
- **How.** `tweak/hwp/buffs_specs.sval` holds one actor buff per spec,
  `hwp_spec_<subclass id>`. Every 2 s the module checks the buff of the
  local player's current subclass (`PlayerRecord.playerClass.m_id`) on that
  player's own machine, where damage is computed, and re-applies the 60 s buff
  only when it is missing or under 3 s from running out (so the buff bar does
  not replay its refresh animation). No entry, no buff, so adding
  a spec is adding a dict. Buff keys are the vanilla `ActorBuffDef` ones
  (`dmg-mul`, `dmg-taken-mul`, `speed-mul`, `armor-mul`, `resistance-mul`,
  `attack-speed`, `cast-speed`, `experience-mul`, ...).
- Placeholder numbers: Warden +10 % damage, +4 % speed; Summoning +8 % damage,
  +15 % armour and resistance; Conjuration +10 % cast speed, +6 % damage;
  Transmutation +10 % damage, -8 % damage taken.
- `hwp specs` prints one line per reworked spec (all classes, with class and
  spec names and the bonus), marks yours, and says why yours is or is not
  boosted (no rework, turned off, in town - the buff only runs during runs).
  Setting `specs.enabled` (host-synced).
- Each buff has a shrine-buff `hud` icon; the HUD drops buffs without one.

## Test checklist

1. `dev_check`: `[HWP:specs] self-check done: 4/4 spec buffs`.
2. Play a Warden in a run: `hwp specs` says `boosted now`; the buff shows in
   the buff bar (speed icon, "Warden's Resolve"); damage numbers are ~10 %
   higher than without the module. In town it says the boost applies during
   runs. Switch to a Marksman: `no rework for this spec`.
