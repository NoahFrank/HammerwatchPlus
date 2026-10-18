# firearms

A new class, the **Firearms Specialist**. Pure data (`PlayerClass`,
`ItemSkillDef`, `BaseItem`, `PlayerPortraitPiece`, `HeroTitle` loaders) plus a
tiny module that self-checks the loaders and answers `hwp firearms`.

- **Mana is ammo.** Base mana 30 (+1 per level), mana regen 0.5/s. The rifle's
  shot costs 1 mana, the aimed shot 2; grenades, rockets and bursts cost ammo
  too (see each skill). **Reload** (starting skill, 0.55 s cast, 2 s cooldown)
  restores 50-100 % of the magazine. Scavenger refunds rounds on kills.
- **Rifles** `hwp_rifle_01/02/03` (`tweak/hwp/equipment_firearms.sval`):
  two-handed, dex-gated, crossbow anim set and model, tag `hwp_firearm`.
  The t1 rifle is the starting weapon and sits in the armory pool.
- **Base skills:** Reload, Frag Grenade (targeted lob, `GroundBouncing` +
  `Explode` on landing), Scavenger (passive), Steady Hands (passive).
- **Sniper:** Snipe (aimed piercing round, 300-500 % weapon damage),
  Flashbang (blind + short stun), Decoy (an 8 s target dummy on the player
  team that taunts with `AlertActors`).
- **Demolitions:** Grenade Launcher (explosive shell, costs ammo), Rocket
  (fire burst, 80 radius), Jetpack (`PlayerSkillLeap` with a fire landing).
- **Assault:** Burst Fire (3-5 round fan), Stun Grenade (1.5 s stun),
  Adrenaline (damage taken down, kills refill ammo).
- Portrait piece and hero title reuse the ranger assets. Skill icons are
  generated placeholders in `players/hwp/firearms/icons.png`.

Morning decisions: numbers (all in the skill svals' `binds`), whether rifles
should drop for other classes, real icons and a class portrait, the subclass
names, and whether grenades should cost ammo at all.

## Test checklist

1. `python -m gamelab run mod-firearms --mode lab`: `[HWP:firearms] class registered with 3 subclass(es)`, no
   "missing item/unit" lines, no script or sval errors.
2. Create a character: Firearms Specialist is in the class list with the
   round icon; the character spawns with the Flintlock Rifle equipped.
3. Shooting spends 1 mana per round; at 0 mana the rifle will not fire;
   Reload refills; the aimed shot costs 2 and pierces.
4. Frag grenade lands where aimed and explodes; damage numbers appear.
5. Reach the subclass pick: three doctrines offered; each mastery skill
   casts, costs what the tooltip says and its upgrades change the numbers.
6. Decoy: enemies turn to the dummy; it vanishes after 8 s or when killed.
7. Jetpack: leap lands at the cursor with a fire burst.
8. Co-op: a client sees the host's bullets, grenades and decoy, and the
   other way round.
