# legacy - Title Bonuses

HoH1's class titles, the HoH2 way. In HoH1 each class had titles (earned by
beating each act's boss and NG+); the best title among your characters of each
class gave **every** character that class's bonus (Wizard spell power, Sorcerer
mana regen, Thief gold, ...). HoH2 kept the idea as **hero titles**: the
highest-level hero of each class grants its bonus to all characters, scaled
per level (`tweak/town/hero_titles.sval`, `TownRecord.m_heroTitles`). This
module presents them the way HoH1 did; the bonuses themselves stay vanilla.

- **One buff.** A "Title Bonuses" crown icon in the buff bar (`gui/hwp_legacy.png`,
  the vanilla crown from `gui/icons.png` moved 1 px right so it sits centred).
  Its description is just the bonuses, one per line ("+60 Spell Power",
  "+20% more Gold", plus the chapel donation titles), without the classes
  they come from (`hwp legacy` has the per-class detail), shown in the hover tooltip (with
  `bufftips`, no countdown) and in the character menu's Effects tab. The buff
  has no modifiers, is added locally (husk, not networked) and its timer is
  reset every 0.5 s. Off with `hwp set legacy.enabled false`. The HUD only
  ever shows one: anything that respawns the player without clearing the old
  actor's buffs (a town upgrade) left its icon behind, so every tick hides
  any Title Bonuses icon that is not the current actor's buff.
- **Every class in Guild Hall (G) > Titles.** Vanilla lists only classes you
  have a hero of. The tab is rebuilt in place when the Guild Hall opens:
  heroes first (as vanilla), then each class with no hero yet, greyed, with
  its stat icon and what its title gives at level 20, then the donations.
- **Titles for the HoH1 classes** (data in `classes` / `firearms`): each keeps
  its HoH1 title stat at HoH2's per-level scale. Placeholder balance:

  | Class | HoH1 title stat | Here, per level (level 20) |
  |---|---|---|
  | Thief | gold gain (+55% at title 8) | +1% gold (+20%) |
  | Gladiator | attack crit damage (+120%) | +1.5% (+30%) |
  | Witch Hunter | spell crit damage (+120%) | +1.5% (+30%) |
  | Firearms Specialist | (new class) | +0.25% crit chance (+5%) |

- `hwp legacy` prints the bonuses and the classes without a hero.

## Test checklist

1. `python -m gamelab run mod-legacy --mode lab`: `[HWP:legacy] ready: 12 classes with a hero title`.
2. With at least one hero above level 1: the crown icon is in the buff bar,
   in town and in runs; hovering lists the bonuses, no "s left" line.
3. Character menu > Effects: one "Title Bonuses" entry with the same list.
4. G > Titles: your heroes, then every other class greyed with "No hero yet".
5. Die and respawn / change floors: the icon comes back within a second.
6. Upgrade a town building (twice): still exactly one crown icon.
