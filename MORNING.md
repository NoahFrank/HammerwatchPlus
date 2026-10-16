# Morning notes - decisions made overnight, please flesh out

Everything below was decided by Claude while you slept so the build could keep
moving. Each item says what was built, what was guessed, and what to look at.

## Phase 2 (QoL / co-op batch) - built, boot-verified, needs in-game passes

Chat commands are the settings UI for now: type `/hwp help` in chat. `/hwp set
<key> <value>` stores a setting in your own town record (persists per save
slot, per machine). A real settings tab is on the list below.

| Module | Guess to review |
|---|---|
| `laststats` | Notice board position (-440,110) next to the fountain of `town_square_4` is a guess; `/hwp set laststats.board_x N` / `board_y` moves it live (re-enter town). Per-skill damage lines are not in the snapshot (no player actor at snapshot time). |
| `deathrecap` | 10 s window, top 5 sources, panel 96 px under the top edge. Source names come from unit paths (`lich_king` -> "Lich King"), no attacker = "Hazards". Chat line goes to everyone (`deathrecap.chat` to disable). |
| `petwait` | Puzzle detection = producer path `doodads/buttons/*` or contains `puzzle`, radius 120 around the **owner**, checked every 400 ms. Classmaps on `MiniPetWalking`/`MiniPetFlying` - the log line `classmap active` on the first pet spawn confirms classmaps work on unit behaviours; if it never appears, the fallback is overriding the two base files. |
| `architect` | Everyone can pick alterations from their own run-start loadout; sponsors pay their picks in full, the host's picks are split evenly (`architect.split`, default on). **Not done:** the town-fountain entry point and "host approval" mode. Refunds are moot: nothing is charged until the run starts. |
| `chatlinks` | Uses the vanilla hold-context-key linking (nobody knew it existed?) and adds a persistent chat line; `/hwp link [slot]`. Typing `[item]` in the chat box and hover tooltips need a custom chat widget - skipped. |
| `colors` | Tints projectile units with `SetMultiplyColor` (multiplies the sprite, so dark sprites stay dark). Presets: contrast, deuteranopia, protanopia, tritanopia; per-team hex overrides. AoE/effect telegraphs are not tinted. |
| `groupcombo` | 2/3/4 players in combo: +5/10/15 % damage and speed, +1/2/3 s combo sustain; everyone in combo: 2 s invulnerability, 30 s cooldown. Numbers in `tweak/hwp/buffs_groupcombo.sval`. |
| `weaponswap` | Hotkey is an SDL scancode setting (X = 27) because scripts cannot add bindings to the controls menu; `/hwp swapkey 21 R` changes it. Flow: press to stash, equip other weapons, press to toggle. HUD line under the top edge. |

Decisions that need you:

1. **Settings GUI**: a tab in the options menu vs. a HWP book/NPC in town vs.
   keep chat commands. Chat commands are built; the rest is not.
2. **Fountain sponsor entry point** for architect buffs (plan said "fountain or
   loadout"; loadout is done). The well unit is at local (104,16) of every
   `town_square_*` prefab; square 4 sits at world (-608,128). Doing it means an
   interact behaviour on the well (classmap or a spawned invisible NPC next to
   it).
3. Whether the group-combo bonus should also give regen (plan said "regen and
   damage"); currently damage + speed + combo duration.
4. Death recap: keep the chat announce on by default?
5. Weapon swap in town: allowed now; disallow?

## Phase 2 review - applied (commit 315fe37)

All 10 findings of the Phase 2 code review are in and boot-verified: typed
setting read-back, strict `/hwp set` parsing, `/hwp set` refused in the lobby,
architect host-sync + stale-pick + negative-gold + free-buff fixes, death
recap hide race, weapon swap gated on text input / open windows, shared
`HWP::SV` readers in core.

## Phase 3 - built, boot-verified, needs in-game passes

Module `modules/keys/` (classmap `Chest` -> `HWPChest`), README has the test
checklist. Decisions made:

- Locked chests: deterministic roll per chest (hash of rounded position +
  `m_missionRewardSeed` + level index) on the first `Update`; `keys.lock_chance`
  0.35 of bronze/silver/gold reward chests get a key of their own tier and
  loot one tier up; `keys.ace_chance` 0.15 of gold chests become **ace** (red
  tint, `ace` key): 50 % every player gets an instanced red legendary
  (`Item::DropItem(..., record)`), else an epic-heavy table. Caches/platinum/
  cursed untouched. Padlock overlay = local non-netsynced doodad.
- Key drops roll on the killer's machine (`PlayerKilledActor` hook only fires
  there) and are spawned by the host (`keys.drop` request, rate-limited,
  `SpawnLoot` broadcast like `LootDef`). Normal 0.6/0.25/0.1 %, elite 8/5/3 %,
  boss: gold guaranteed + 10 % ace.
- General Merchant NPC (merchant_woman_2 sprites, `AShopContent` + default
  `ShopWindow`, `IShopItem` per key) near the fountain, default world
  (-560,152), `keys.merchant_x/y`. Prices 500 / 2 000 / 8 000 / 50 000 gold,
  one ace key held at a time.
- Legendaries = HoH1's real seven (`items/legendary.sval` read from your HoH1
  install): Descending Destruction (head; 10 % on hit meteor), Dragon's Tail
  (chest; HoH2 has no gold-scaled damage -> +50 % gold, +10 % damage),
  Medusa's Charm (off; AuraCone slow/armor gaze + stun melee attackers),
  Sphere of Heroes (hands; 20 % on attack archon fireball), Spirit Cloak
  (back; 3 s invulnerable on hurt, 10 s cd), Soul Taker (feet; kill same type
  in 200), Wand of Chaos (off; magic missile at a random enemy every 2 s).
  Built as `Equipment::UniqueEquipment`, quality legendary, drop-rate 0, icons
  from the trinket gem sheet until HoH1 icons are imported.
- HUD: key counts top-right; `/hwp keys`; `/hwp keygive` only with
  `keys.debug true`.

Open for you: slot assignments above, whether a HoH2 off-hand unique without
a skill renders/works, whether locked chests should also appear on the
minimap differently, and exact drop rates. Settings: `keys.enabled`,
`keys.lock_chance`, `keys.ace_chance`, `keys.legendary_chance`,
`keys.boss_ace_chance`, `keys.price_<tier>`, `keys.merchant_x/y`, `keys.debug`.
Known risk: the lock roll hashes the chest position at its first tick; if a
client ever sees a chest at a slightly different position the lock could
differ per machine (the host's `Chest::Use` is still authoritative for loot).

## Phase 3 review - applied

Nine findings, all applied: clients could never open locked chests (the
host checks `CanUse` against a husk record with 0 keys -> `HWPChest::CanUse`
trusts husks); `keys.*` settings now host-authoritative through a new core
mechanism (`HWP::Settings::Sync("keys.")`, core `settings.pull/sync`
messages, clients read the host's values); merchant spends gold inside
`Buy` (no auto-spend, so an unavailable row can't eat gold); unlock stat only
on the opener's machine; only the first boss-tagged kill per level pays the
guaranteed gold key; flood guard raised to 10/10 s and logged as info;
`/hwp keygive` null-safe; vanilla `item.key.<tier>` strings and the
`items/special/keys.unit` key scenes reused; tier attributes are tables.

## Phase 4 - Firearms Specialist, built, boot-verified, needs in-game passes

Module `modules/firearms/`, all data (README has the test checklist):

- Class `hwp_firearms` (dex-based, `players/hwp/firearms/class_firearms.sval`)
  with subclasses Sniper / Demolitions / Assault (`parent` dicts, offered by
  the vanilla subclass pick). **Mana = ammo**: base mana 30 (+1/level), regen
  0.5/s; the rifle shot costs 1, aimed shot 2; **Reload** restores 50-100 %.
- Rifles `hwp_rifle_01..03` (`tweak/hwp/equipment_firearms.sval`), crossbow
  anim set + model, tag `hwp_firearm`; attack skills in
  `players/hwp/firearms/attacks_firearms.sval` (ItemSkillDef loader).
- Skills per your table: Sniper = Snipe (aimed piercing round), Flashbang
  (blind + short stun), Decoy (taunting target dummy, `AlertActors`);
  Demolitions = Grenade Launcher, Rocket, Jetpack (`PlayerSkillLeap`);
  Assault = Burst Fire, Stun Grenade, Adrenaline. Base: Reload, Frag
  Grenade, Scavenger (ammo on kills), Steady Hands.
- Portrait piece + hero title reuse the ranger's; skill icons and the class
  icon are generated placeholders (`players/hwp/firearms/icons.png`).
- Boot lessons (fixed): mod textures must be power-of-two (the first icon
  sheet was 168x48 and the engine refused it, hanging the boot); the
  `/hwp firearms` status command reads `rec.equipped` / `rec.mana`.

Open for you: every number (all in `binds`), whether grenades/rockets should
cost ammo (they do now, except frag/flash/stun/decoy/jetpack), whether rifles
should drop for other classes (they are in the common pool), real art, and
the three doctrine names. Unverified until an in-game pass: the `*-bind`
parameters on `GivePercentageMana`/`GiveMana`/`ShootProjectileFan` (if a bind
is not honoured the effect logs a missing-param error - check the log) and
whether the decoy's taunt skill fires without a target.

## Still to build (Phases 5-7)

Phase 5 fishing/farming, Phase 6 pets + progression + spec reworks
+ strongboxes/abyss, Phase 7 HoH1 campaign/classes/wave mode. See
`docs/` and the plan file for details; progress notes get appended here.
