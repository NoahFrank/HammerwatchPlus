# classes

The three Heroes of Hammerwatch 1 classes that HoH2 lacks, on the class
pipeline the Firearms Specialist built (`PlayerClass`, `ItemSkillDef`,
`BaseItem`, `PlayerPortraitPiece`, `HeroTitle` loaders) plus a module that
self-checks the loaders and answers `/hwp classes`. All numbers live in the
skill svals' `binds`; generated placeholder icons in
`players/hwp/<class>/icons.png`.

## Thief (`hwp_thief`, rogue panel, starts with twin daggers)
HoH1 stats scaled to HoH2 (90 hp, 40 mana, 2 armor, dex 10).
- Base: **Throwing Knives** (fan of the rogue's knives), **Grappling Hook**
  (the vanilla rogue skill file, reused as-is), **Smoke Bomb** (blind +
  slow area), **Sidestep** (evade).
- Assassin: Vicious Cuts (crit chance + crit damage), Shadow Strike (leap
  with damage + minor stun), Backstab (crits add bleed stacks).
- Trickster: Slice and Dice (6 s +30 % attack speed self-buff), Caltrops
  (damage + slow + bleed area), Quick Hands (attack speed).
- Shadow: Cloak of Shadows (2.5 s 100 % evade + speed), Poisoned Blades
  (hit trigger poison damage), Vanish (hurt trigger cloak, 8 s timeout).

## Gladiator (`hwp_gladiator`, paladin panel, starts with the Arena Trident)
130 hp, 40 mana, 6 armor, str 10. **Arena Trident** (`hwp_trident_01`,
`tweak/hwp/equipment_classes.sval`) is a mainhand on the longsword model
with our copy of the unused vanilla spear thrust (`hwp_attack_trident`,
`players/hwp/gladiator/attacks_gladiator.sval`); it sits in the armory
pool.
- Base: **Net** (immobilize area), **Gladius Throw** (the warrior's
  returning whirling axe projectile), **Pit Fighters** (passive summon of
  the priest's crusader pikeman), **Planned Attack** (weapon damage).
- Champion: Riposte (thorns), Arena Mastery (armor + health), Shield Wall
  (5 s +50 % armor/resist self-buff).
- Beastmaster: Arena Beast (the ranger's wolf as a passive summon), Pack
  Leader (+1/+2 beasts), Bloodlust (kills heal).
- Retiarius: Barbed Net (damage + bleed + immobilize), Trident Whirl
  (melee explode around you, weapon damage), Trident Mastery (flat
  physical damage).

## Witch Hunter (`hwp_witch_hunter`, ranger panel, starts with a crossbow)
100 hp, 60 mana, 3 armor, 10 fire res.
- Base: **Searing Torch** (hit trigger fire damage), **Pyre** (spawns
  `players/hwp/witchhunter/units/pyre.unit`: a stationary player-team
  unit on the decoy template that explodes fire around it every second
  for 8 s), **Hound** (wolf passive summon), **Ward of Branding** (fire +
  vulnerability area).
- Inquisitor: Fanatic Zeal (attack + spell crit), Murder of Crows (damage
  + blind area), Judgement (kills restore mana).
- Pyromancer: Brand (flat fire damage), Immolation (8 s self-buff: fire
  damage add + 10 % damage), Cinders (spell hits break armor).
- Hunter: Pack (+1/+2 hounds), Silver Bolts (flat physical), Tracker
  (move speed).

Self-buffs are `ActorBuffDef` dicts in `tweak/hwp/buffs_classes.sval`,
applied through a radius-8 self `Explode` with `ApplyBuff` (the same
trick the Firearms Reload uses for `GivePercentageMana`).

Morning decisions: all numbers, real icons/portraits (portrait pieces
reuse rogue / paladin / ranger), whether the Gladiator should be two-handed,
HoH1-style Priest/Paladin alternate specs (not built), and which skills
should be spells vs passives.

## Test checklist

1. `dev_check`: `[HWP:classes] self-check done: 3/3 classes`, no "has N
   subclasses" errors, no missing unit/item lines, no sval errors.
2. Character creation lists Thief, Gladiator and Witch Hunter with the
   generated icons; each spawns with its starting weapon.
3. Thief: knives fan out and hit, grappling hook pulls you, smoke bomb
   blinds, the Sidestep tooltip shows the evade chance.
4. Gladiator: the trident thrusts (damage numbers), net roots enemies, the
   gladius returns, a pit fighter follows you after ~20 s.
5. Witch Hunter: the pyre appears and burns enemies next to it for 8 s, a
   hound follows, the ward leaves enemies vulnerable.
6. Reach the subclass pick for each: three masteries each; the self-buff
   skills show the buff icon on the HUD for the listed duration.
7. Co-op: a client sees the host's pyre, hounds and knives and vice versa.
