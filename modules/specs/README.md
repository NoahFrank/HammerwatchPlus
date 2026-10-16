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
  `hwp_spec_<subclass id>`. Every 2 s the module re-applies the buff of the
  local player's current subclass (`PlayerRecord.playerClass.m_id`) on that
  player's own machine, where damage is computed. No entry, no buff, so adding
  a spec is adding a dict. Buff keys are the vanilla `ActorBuffDef` ones
  (`dmg-mul`, `dmg-taken-mul`, `speed-mul`, `armor-mul`, `resistance-mul`,
  `attack-speed`, `cast-speed`, `experience-mul`, ...).
- Placeholder numbers: Warden +10 % damage, +4 % speed; Summoning +8 % damage,
  +15 % armour and resistance; Conjuration +10 % cast speed, +6 % damage;
  Transmutation +10 % damage, -8 % damage taken.
- `hwp specs` shows the entries and whether your spec is boosted. Setting
  `specs.enabled` (host-synced).

## Test checklist

1. `dev_check`: `[HWP:specs] self-check done: 4/4 spec buffs`.
2. Play a Warden in a run: `hwp specs` says `boosted`; the buff shows in the
   buff bar as "Warden's Resolve"; damage numbers are ~10 % higher than
   without the module. Switch to a Marksman: `no boost`.
