# Morning notes - decisions made overnight, please flesh out

Everything below was decided by Claude while you slept so the build could keep
moving. Each item says what was built, what was guessed, and what to look at.

## Phase 2 (QoL / co-op batch) - built, boot-verified, needs in-game passes

Console commands are the settings UI for now: type `hwp help` in the console (the in-game chat cannot run mod code, see `mods/core/README.md`). `hwp set
<key> <value>` stores a setting in your own town record (persists per save
slot, per machine). A real settings tab is on the list below.

| Module | Guess to review |
|---|---|
| `laststats` | Notice board position (-440,110) next to the fountain of `town_square_4` is a guess; `hwp set laststats.board_x N` / `board_y` moves it live (re-enter town). Per-skill damage lines are not in the snapshot (no player actor at snapshot time). |
| `deathrecap` | 10 s window, top 5 sources, panel 96 px under the top edge. Source names come from unit paths (`lich_king` -> "Lich King"), no attacker = "Hazards". Chat line goes to everyone (`deathrecap.chat` to disable). |
| `petwait` | Puzzle detection = producer path `doodads/buttons/*` or contains `puzzle`, radius 120 around the **owner**, checked every 400 ms. Classmaps on `MiniPetWalking`/`MiniPetFlying` - the log line `classmap active` on the first pet spawn confirms classmaps work on unit behaviours; if it never appears, the fallback is overriding the two base files. **Update 2026-10-17: it never appeared; the engine ignores classmaps, so `tools/class_units.py` now generates the unit copies.** |
| `architect` | Everyone can pick alterations from their own run-start loadout; sponsors pay their picks in full, the host's picks are split evenly (`architect.split`, default on). **Not done:** the town-fountain entry point and "host approval" mode. Refunds are moot: nothing is charged until the run starts. |
| `chatlinks` | Uses the vanilla hold-context-key linking (nobody knew it existed?) and adds a persistent chat line; `hwp link [slot]`. Typing `[item]` in the chat box and hover tooltips need a custom chat widget - skipped. |
| `colors` | Tints projectile units with `SetMultiplyColor` (multiplies the sprite, so dark sprites stay dark). Presets: contrast, deuteranopia, protanopia, tritanopia; per-team hex overrides. AoE/effect telegraphs are not tinted. |
| `groupcombo` | 2/3/4 players in combo: +5/10/15 % damage and speed, +1/2/3 s combo sustain; everyone in combo: 2 s invulnerability, 30 s cooldown. Numbers in `tweak/hwp/buffs_groupcombo.sval`. |
| `weaponswap` | Hotkey is an SDL scancode setting (X = 27) because scripts cannot add bindings to the controls menu; `hwp swapkey 21 R` changes it. Flow: press to stash, equip other weapons, press to toggle. HUD line under the top edge. |

Decisions that need you:

1. **Settings GUI**: a tab in the options menu vs. a HWP book/NPC in town vs.
   keep console commands. Console commands are built; the rest is not.
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
setting read-back, strict `hwp set` parsing, `hwp set` refused in the lobby,
architect host-sync + stale-pick + negative-gold + free-buff fixes, death
recap hide race, weapon swap gated on text input / open windows, shared
`HWP::SV` readers in core.

## Phase 3 - built, boot-verified, needs in-game passes

Module `mods/keys/` (`Chest` -> `HWPChest`, now a module.json class swap), README has the test
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
- HUD: key counts top-right; `hwp keys`; `hwp keygive` only with
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
`hwp keygive` null-safe; vanilla `item.key.<tier>` strings and the
`items/special/keys.unit` key scenes reused; tier attributes are tables.

## Phase 4 - Firearms Specialist, built, boot-verified, needs in-game passes

Module `mods/firearms/`, all data (README has the test checklist):

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
  `hwp firearms` status command reads `rec.equipped` / `rec.mana`.

Open for you: every number (all in `binds`), whether grenades/rockets should
cost ammo (they do now, except frag/flash/stun/decoy/jetpack), whether rifles
should drop for other classes (they are in the common pool), real art, and
the three doctrine names. Unverified until an in-game pass: the `*-bind`
parameters on `GivePercentageMana`/`GiveMana`/`ShootProjectileFan` (if a bind
is not honoured the effect logs a missing-param error - check the log) and
whether the decoy's taunt skill fires without a target.

## Phase 4 review - applied

Ten findings; nine applied, one skipped. Applied: chest locks on clients
now wait for the host's `keys.*` settings before rolling
(`HWP::Settings::RemoteReady()`, 10 s timeout then a logged local roll);
the host checks a remote opener against the key counts that client reports
(`keys.count`, polled every 0.5 s and sent right before a locked-chest use)
instead of trusting any husk; the boss key gate is enforced on the host per
level (whoever got the kill, one gold key and one ace roll); `hwp firearms`
shows real mana (`PlayerRecord.mana` is a 0..1 ratio); the settings cache
is cleared on every load, so a client never keeps the previous host's
values; `hwp set` on a client tells you the host controls synced keys;
settings-sync notifies listeners once per prefix; shared
`HWP::CheckUnits/CheckItems/CheckLootTables` self-check helpers; the
firearms self-check runs at boot and once per gameplay load. Skipped: the
finding that `.skills.desc.params.damage.weapon` is missing - it exists in
vanilla `skills.lang`.

## Phase 5 - Fishing + Farming, built, boot-verified, needs in-game passes

Modules `mods/fishing/` and `mods/farming/` (READMEs have the test
checklists), plus two small additions elsewhere:

- **Core `HWP::Market`** ("wares"): countable goods in the player's own
  record (`market.<id>`), registered by modules with a price. `hwp wares`,
  `hwp sell`. The **Gambler got a Sell button** that shows what your wares
  are worth; that is where fish, crops and herbs turn into gold.
- **Fishing.** A rod + fish doodad in town (host-spawned at
  `fishing.spot_x/y`; I guessed -1600,330 for the trading-post docks - stand
  where you want it and `hwp fishing here` saves the spot). Minigame: Cast,
  wait for the bite, Reel while the sweeping marker is in the green; zone and
  speed scale with the rolled tier (55/28/13/4 %). Eight fish, 15-1000 gold.
  30 % of runs (`fishing.run_chance`) the host drops a fishing hole next to
  the party at the start; 3 catches per player per level, loot from
  `tweak/hwp/loot_fishing.sval` (food/mana pickups, gold, valuables, rare/epic
  gear). The plan's "placed as prefabs in levels" and "new drinks/foods" are
  not done: there is no in-run consumable item type to hand out, so the hole
  pays vanilla pickups + gear instead.
- **Farming.** Four soil plots in a row (`farm.x/y`, default -560,1040 near
  the farm segment; `hwp farm here`). Five food crops (1 run, 2-8 units,
  6-15 g each) and the four Holy Herb strains (2 runs, 1-2 units, 120-200 g):
  Lucky Leaf (Gambler redraws a losing dealer card once at 25 % + 5 % gold),
  Ember Kush (+20 % fire), Saint's Sage (+1 HP/+0.5 MP regen), Gambler's Gold
  (+25 % gold). Smoking sets a `MissionBuff` in a single `hwp_herb` slot, so
  it lasts exactly one run like tavern food. Growth counts completed (or
  aborted) runs of the host's town. State is host-owned and synced; planting
  is paid by the planter, the harvester keeps the yield.
- Food crops have no use yet besides selling; Phase 6 pet feeding is their
  intended sink.

Open for you: positions of the spot and the plots (both commands save the
setting), prices/yields/grow times (all in the script tables, data file was
skipped because the engine's sval loaders need an SVO class per table), the
herb effects, whether a hole should also appear mid-level (needs level-gen
hooks), and whether harvest should be shared across the party.

## Phase 5 review - applied

Nine findings, all applied. Four were duplicate blocks (Gambler gui/lang
sell button, core lang, `GamblerShop.as` sell handler) that the old
non-idempotent generator had stamped four times: files restored and
regenerated once, generators retired (edit module files directly now).
The rest: locked-chest `CanUse` only re-sends key counts when they changed
(it is polled every frame); run fishing is host-rolled - the cast asks the
host (`fishing.cast`), the host spends the cast, rolls the tier and answers
`fishing.bite`, the reel-in (`fishing.catch`) spawns that tier, so a client
cannot pick its own loot; `hwp fishing here` and `hwp farm here` notify
the settings listeners and replace the spawned unit immediately; farm plot
visuals refresh only after the scene has settled (first UpdateFrame), not
during the load; planting is confirm-then-pay (`farm.planted` / 
`farm.refused`) so a lost race never costs gold.

## Phase 6 - pets, weapons, strongboxes, abyss, maps, specs, summons, gear reroll - built, boot-verified, needs in-game passes

Modules: `pets` (merged petwait), `weapons`, `strongbox`, `abyss`, `maps`,
`specs`, `summons`; `goldpet` now requires `pets`; `gambler` got gear reroll;
core got `HWP::Spawner`. Decisions you may want to change:

- **HoH1 pets** are sold in the vanilla Pet Shop (`PetDef::LoadMultiple`
  merge of `tweak/hwp/pets_hoh1.sval`, generated by `tools/import_hoh1.py
  pets`, gitignored). Skins cost HoH1 price / 6.67 in HoH2 gold; no legacy
  point gate, every skin is simply buyable. The living flame is a 7500 g
  "Magical" pet.
- **Pickup toggles** reuse vanilla `PlayerRecord.petOptions` bits (gold,
  valuables, materials, health, caches, cursed, elixirs, xp) so vanilla pets
  honour them too. Default: everything but health/cursed.
- **Progression** lives in the player DataBag under `pets.<petId>.*` (level,
  xp, ranks). XP: 5 per kill, 25 elite, 150 boss, 2 per pet pickup, crops at
  the feeding bowl (`tweak/hwp/pet_skills.sval` feed table). Cap level 20, one
  skill point per level, 7 skills (Hazard, Smash, Stun, Mend, Fetch, Morale,
  Family). Effects are host-validated (`pets.act` request, rank + cooldown
  checked on the host). Gold Collector is the external pet `hwp_goldpet`.
- **Weapons**: 12 items at ilvl 35 reusing vanilla graphics/models/skills with
  new modifier profiles; `hwp weapons` lists them. Sprites of their own are a
  later art pass.
- **Strongbox**: 40 % of floors (host, not town) get one, placed on a live
  enemy at least 700 px from everyone. Opening it samples 4 enemy kinds within
  1200 px (biome-correct), spawns 4 + 2 x players, 50 % with an elite variant;
  loot `hwp_strongbox` on clear or after 180 s. Orange-tinted chest, red X
  icon while armed. `hwp strongbox here` to test.
- **Abyss crack**: 30 % of floors, 800 px from players; 3 waves (3 + players
  + wave index), last wave adds an elite; `hwp_abyss_reward` loot; `hwp abyss
  here` to test. Side rooms were cut (no runtime room placement API).
- **Maps**: Goblin Warrens (5-9), Sunken Dungeon (12-15), The High Court
  (17-21), same unlock flag as the vanilla pink maps, spawn chances 1.0 / 0.8
  / 0.6 against the vanilla three.
- **Specs**: data-only placeholder buffs for the four specs every tier list
  puts last (Warden, Summoning, Conjuration, Transmutation), re-applied every
  2 s on the owner's machine. Numbers in `modules/specs/tweak/hwp/buffs_specs.sval`.
  Real reworks and the "healer ability" item need your design input.
- **Summons (your morning request)**: Crusaders are snapshotted with
  `SaveUnit()` every 500 ms and re-produced on the next floor's
  `GameModeSpawnPlayer`; `summons.all` extends it to every saveable summon.
- **Gear reroll (your morning request)**: Gambler row `< slot > [Reroll Ng]`,
  2000 g x item level, keeps base/quality/ilvl/upgrades, rerolls mods via
  vanilla `Generator::ModifyItem(clearMods=true)`. Legendaries/uniques refused.
- **Fixed on launch**: `living_flame.unit` used a HoH1-only material
  (`glow-both-bright`); the importer now remaps it to `bright-glow`.

## Phase 6 review - applied

`/code-review high` on Phase 6 found 10 things; all applied:

- Strongbox: the 3-minute armed timeout used to open the box with loot even
  with the pack alive; now it seals the box (state 3) and pays nothing.
- Abyss: a wave alive after 2 minutes used to count as cleared (next wave
  stacked on top, final wave paid out); now the crack closes with no reward.
- Gambler reroll: uniques are `Equipment::UniqueEquipment`, so the slot read
  as "nothing equipped"; the row now says "can't be rerolled" and legendary,
  quest, unique and cursed qualities are all refused. Dead `m_ilvl` /
  `m_forcePrimary` lines dropped.
- Core Spawner: sampled producers are resolved back to the plain unit
  resource (a `Loot=false` placement variant no longer makes the whole pack
  lootless) and de-duplicated by name; the elite lookup uses a static table of
  the 29 vanilla `*_elite.unit` enemies instead of probing the resource system
  (which logged an error per miss); packs spawn only on free spots (collision
  query + line of sight, like vanilla `safe-spawn`), members with no spot are
  skipped; `PlayerCount()` and a `LevelPlacer` helper replace the copy-pasted
  per-level placement code in strongbox and abyss; boxes/cracks are nudged
  onto a free spot next to the sampled enemy.
- Specs: the 2.6 s spec buffs set `ignore-buff-scaling` so a buff-duration
  penalty can't make them lapse between 2 s ticks.
- Core Commands: `OnSettingChanged` de-duplicates listeners (modules are
  remade every level, so the list grew by four entries per floor).

## Phase 7 - Forsaken Tower, Wave Arena, HoH1 classes - built, boot-verified, needs in-game passes

Modules: `campaign`, `wavemode`, `classes`. Everything is on the pipelines
earlier phases built (MissionDef svals like `maps`, town doodads like
`fishing`, classes like `firearms`). Decisions you may want to change:

- **HoH1 level import: step one is built, the levels are not playable yet.**
  `tools/hwr_archive.py` now decodes the full binary SValue format (blobs,
  vectors, the compact literals; verified on every HoH1 and HoH2 level and
  prefab) and `python tools/import_hoh1.py levels` decodes the six HoH1 acts
  (boss levels, Battlements 1-2, the act prefabs and every prefab they
  pull in) into gitignored `hoh1_import/campaign/` with `report.md`:
  tilesets extracted as PNG, and per act which units / scripts / files HoH2
  lacks. The numbers: 22 tilesets (1 exists in HoH2), 27 level-script types
  to write as `WorldScript` classes, and 755 of 759 unit types (walls,
  traps, enemies, the six bosses) with no HoH2 counterpart; that last list
  is the actual port, enemy by enemy. Until
  then the Forsaken Tower is 6 acts x (2 generated floors in the closest
  HoH2 theme + a vanilla boss): Mines = dark cave / totems, Prison = prison
  theme / Arista, Armory = barracks / harbingers, Archives = crypt / wraith,
  Chambers = courts / bone serpents, Battlements = keep / avatar. Diff 5 to
  22, `diff-level-ngp` = diff + 8. Details in `mods/campaign/README.md`.
- **Portal** in town at -1700,250 (left of the fishing spot); `hwp campaign
  here` moves it. It is the vanilla mission board content limited to the
  `hwp_campaign` set, so only the host can start it (vanilla rule) and the
  usual loadout menu opens. Same story-intro unlock flag as the pink maps.
- **Wave Arena** is the Celestial Ruins survival rule set
  (`SurvivalMission` level module) on a generated keep floor: 10 min clock,
  XP goal 15000 (+25 % per rank), 4 spawn events using the vanilla heaven
  spawn actions (shades, phantoms, cult, wisps - heaven enemies in a keep,
  the assets exist for everyone, only the heaven missions are DLC-gated), boss
  = the valor spirit warrior. Rank = the arena's NG+ level, stored in the
  town record as setting `wave.rank`, +1..3 per boss kill (the module's own
  speed reward), no cap. `hwp wave rank <n>` sets it for testing. A statue
  (the vanilla valor statue sprite) at -1500,250 starts it; clients ask the
  host like the DLC statues do.
- **Classes**: Thief (knives / grappling hook / smoke bomb / sidestep;
  Assassin, Trickster, Shadow), Gladiator (net / gladius throw / pit
  fighters / planned attack; Champion, Beastmaster, Retiarius; starts with an
  Arena Trident = longsword model + the unused vanilla spear thrust), Witch
  Hunter (searing torch / pyre / hound / ward of branding; Inquisitor,
  Pyromancer, Hunter). 39 skills, all numbers in the svals' binds, HoH1 base
  stats scaled to HoH2 (90/130/100 hp). Summons reuse the wolf and crusader
  units; projectiles reuse the rogue knife and warrior whirling axe. Icons
  and portraits are placeholders (rogue / paladin / ranger portrait pieces).
  HoH1-style Priest/Paladin alternate specs: built as 4th masteries of the
  vanilla classes (`players/hwp/hoh1specs/`): Priest **Smiter** (Smite,
  Divine Hammer, Last Rites) and Paladin **Holy Storm** (Holy Storm, Shield
  of Faith, Zealous Charge). HoH2 already has Celestial Orbs / Lay on Hands
  / Consecrated Ground, so these fill the HoH1 gaps; rename or reshuffle
  freely (`gen_hoh1specs.py` in the scratchpad, committed files are truth).
- Generators live in the session scratchpad (`gen_campaign.py`, `gen_wave.py`,
  `gen_classes.py`); the committed files are the source of truth from here on.

## Phase 7 review - applied

`/code-review high` on e01206c, all 10 findings applied:

- Wave boss check used the raw tag index instead of the `ApplyTag(0, ...)`
  bitmask every other module uses; a normal kill could have taken the rank.
- Campaign: `diff-level-ngp` (= diff + 8) is now on all 18 floors, not only
  the boss floors, so NG+ no longer jumps by 8 at every boss; the self-check
  also verifies the six boss `.lvl` files per act.
- Wave: a client's Start no longer goes through the vanilla
  `RequestStartingMap` (the host rescales that number from an item level for
  non-heaven sets, dropping the rank). New HWP request `wave.start`: the host
  gets the vanilla "X wants to start" dialog, yes opens the loadout menu at
  the host's rank (`HWPWaveClientStarter`).
- Wave: the award broadcast already ran the host's handler; the duplicate
  chat line is gone.
- Wave boss is now `actors/hwp/wave_boss.unit`, the valor spirit copied with
  its `stat-reward valor` removed, so arena clears no longer also raise the
  heaven DLC valor rank. Keep it in sync with the vanilla unit after patches.
- Gladiator Gladius Throw / Planned Attack / Whirl tooltips used a lang key
  that does not exist (`...damage.weapon`); now `.skills.desc.params.damage`.
- Classes self-check runs once (constructor); the trident item check once at
  the first gameplay load, not every floor.
- Mission lookups use vanilla `MissionDef::Get(hash)` (campaign, wave, maps).
- New core helper `HWP::Town::Placeable` (settings-backed town doodad: spawn
  after town load, `here` command, host-only replies via `hwp.town.*` lang
  keys); campaign and wave use it. Fishing / pets / keys / laststats still
  carry their own copies; moving them over is a safe follow-up.

## Phase 7 - the real HoH1 boss levels - built, all floors load, needs play passes

`python tools/import_hoh1.py campaign` (needs HoH1 installed) converts the
five act boss rooms, Battlements 1-2 and Thundersnow, with the 1410 files they
use, into the campaign module and adds a second mission, "The Forsaken Tower
(HoH1 levels)", next to the original at the town portal. It is local content:
gitignored, and only packed by `build.py --with-local`. Details and the class
table are in `mods/campaign/README.md`.

The HoH1 classes HoH2 lacks are our own implementations under
`mods/campaign/scripts/HWP/Campaign/HoH1/`, not copies of the HoH1 scripts:
effects (gold, ore, the wraiths' Decimate, curses), projectiles (plain, bat
toss, ground spikes), five enemy skills (jump / charge strike, spew,
whirlwind, whirl nova), the bosses (the Three Councilors, the Vampire Lord, the
Watcher and its wisps) and the HoH1 level scripts. Boss decisions the host makes
go to clients over `HWP::Net` (`hoh1.lich.node`, `hoh1.vampire.*`, `hoh1.eye.*`).

Decisions to look at:

- Gold and ore pickups go to whoever picks them up (HoH1 shared them).
- HoH1 elevators are scenery (HoH2 keeps what a run earns anyway); the item
  forge room is inert (no HoH2 shop for it yet).
- Shrine, blood altar and imp rooms run HoH2's `Shrine` / `Imp` scripts; the
  blood altar acts as a shrine.
- Lunar Shield block, Soul Dagger and Combustion effects are inert stand-ins.
- Minibosses lose HoH1's overhead bar; the dragon's ice block scales with NG+.
- The bat toss "on-target" speed is our own formula.
- The act floors between bosses stay generated HoH2 themes. HoH1's own act
  floors need 755 unit types (walls, traps, every enemy) rebuilt;
  `import_hoh1.py levels` lists them.

Your installed `mods/HWP-campaign.bin` is the release build, so it has only
the original mission. To play the HoH1 floors online, each player runs
`python tools/import_hoh1.py campaign` and `python tools/build.py campaign
--with-local --no-all` and installs that `dist/HWP-campaign.bin` (never upload
a `--with-local` build: it holds HoH1 assets).

How it was checked: `dev_check.py --level` loads every HoH1 floor on test save
slot 7 (a throwaway "HWP Test" character; your characters and slot 0 are never
touched, and your saves were backed up first to
`Documents/HoH2 save backups/2026-10-16_144404/`). Floors load without script
errors from our files. Nobody has fought the bosses yet, so play each one
solo and in co-op (checklist items 6-7 in the campaign README).

## HoH1 boss port review - applied

`/code-review high` on ffd7be0..9e43216 found 10 issues; 9 fixed, 1 was not a bug.
The re-review of the fixes (9e43216..74d9817) sharpened several of them; the
list below is the final state:

- dev_check: the HWR2.exe.cfg backup is written only once per run, so a
  second launch (`--keep`, a profile-creation boot, a re-run) can no longer
  save the already-switched config as "the original".
- dev_check `--level` now fails when a floor logs errors from our files,
  not only when it does not load.
- dev_check only touches a save slot it created (marker
  `saves/<slot>.hwp-test`); any other profile on the slot is refused instead
  of patched or recreated. Slot 7 got the marker (it only holds "HWP Test"
  characters).
- import_hoh1 campaign converts everything before touching the old output,
  and only deletes a folder it wrote (`.hwp-generated` marker, or the
  generated mission file of older versions; `--force` otherwise).
- Boss nodes and the councilors' room are looked up in the loaded scene
  (`g_scene.FetchAllWorldScripts`) instead of a global list filled by
  world-script Initialize and cleared by a GameModeStart hook, so a previous
  level can never leak in; the room is cached per boss. The hoh1.* boss sync
  events are registered in the campaign module's constructor.
- Vampire fire trail: the converter makes `fire_area.unit` netsynced
  (`NETSYNC` in tools/hoh1_convert.py) and only the host drops it, so clients
  see it and each peer's own player is the one it burns (a netsync none
  danger area on the host would also hit remote players' husks).
- Spew no longer freezes mid-cast when its target disappears; a cancelled
  whirl nova goes on cooldown and stops reading as casting; bat projectiles
  remember every unit they hit (pooled ones start clean).
- hwr_archive keeps i64 / f64 SValues as such through decode, XML and
  encode (`Long` / `Double`); XML has no f64 element, so one raises instead
  of being narrowed.
- Not a bug: `Resources::GetSValue(HashString("file.sval:key"))` in pets and
  specs. The lookup only fails for svals with a `<loader>` (which the earlier
  fixes were about); those two files have none. Rule added to docs/hooks.md.
