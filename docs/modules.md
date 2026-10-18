# Module conventions

Each module is a folder `mods/<id>/` that is itself a valid unpacked HoH2
mod (`info.xml` at the root). `tools/build.py` packs it to `dist/HWP-<id>.bin`.

```
mods/<id>/
  info.xml                      name / author / description
  module.json                   build metadata: requires, overrides, exclude
  README.md                     the feature spec: what it does, how to test it
  scripts/HWP/<Feature>/*.as    all code under scripts/HWP/ to avoid base collisions
  res/language/english/hwp_<id>.lang
  gui/hwp_<id>_*.gui
  tweak/hwp/<id>_*.sval
  actors/..., items/..., prefabs/...   new units/data, never same path as a base file
```

## Rules

1. **Never shadow a base file unless declared.** A file at the same path as a
   base-game file replaces it wholesale. If a module must do that, list the
   path under `overrides` in `module.json`, keep a pristine copy next to it as
   `<path>.orig`, and `tools/build.py --check` will flag when a game update
   changes the original. One owner per overridden file across all modules.
2. **Prefer hooks, modules and class swaps** (module.json `class_swaps`; info.xml classmaps are ignored by the engine). See `docs/hooks.md`.
3. **Server authority.** Anything that changes shared state (gold, items,
   spawns) runs on the server (`Network::IsServer()`); clients request.
   Netsynced units can only be produced by the server.
4. **Save data** goes under the `hwp` key of the player or town record via the
   `PlayerRecordSave/Load` and `TownRecordSave/Load` hooks, so vanilla saves
   stay valid with the mod removed.
5. **Namespaces.** Script code lives in `namespace HWP` (or `HWP::<Feature>`);
   hooks live in `namespace HWP<Feature>` because the hook name must match the
   function name, not the namespace.
6. **Logging** goes through `HWP::Log("<module>", msg)` so lines are greppable
   as `[HWP:<module>]`.
7. **Language strings** use keys prefixed `hwp.<module>.`.
8. **IDs.** HashString ids, char flags and material keys are prefixed `hwp_`.
9. **Per-level setup** goes in `Start(StartMode)` of `HWP::ModuleStart`
   (`class X : Module, HWP::ModuleStart`), never in `Module::Load`: the engine
   skips `Load` whenever a level starts without a save (StartMode StartGame,
   e.g. a new profile's first town). Core's `GameModeStart` hook calls `Start`
   on every gameplay level, after the host spawned its players. Script
   globals reset with every level; what must happen before `PostStart` (or
   while the scene loads) goes in the module constructor, which runs once per
   level. State that must survive a level change lives in the player / town
   record (`HWP::SaveData`) or `GlobalCache`.

## Testing a module

GameLab replaced `dev_link.py` / `dev_check.py` (see README.md and `docs/MODDING_NOTES.md`).
A module is tested by a scenario under `gamelab/scenarios/`, run hidden and muted:

```
python -m gamelab run <scenario> --mode lab
```

- The fixture recipe (`gamelab/fixtures/<name>.json`) lists the mods to enable in
  `binary_edits.enable_mods`.
  - `gamelab/hps.py` writes them into the lab save as `HashString(id)`. No first-boot
    learning is needed: the hash is computed (`python gamelab/hps.py hash <id>`).
  - The lab game dir links every mod in `environments.json` `gamelab.mods`. A module
    joins by being added there and to a fixture.
- The run fails on a non-zero game exit or a failed assertion.
  - Scenario steps can assert on `[GL]` probe replies.
  - Script errors stay in `logs/pass<n>.HWR2.exe.log`; asserting on them is not
    automated yet.
- The old `dev_check --level` floor loader is replaced by the `gamelab-hands` verb
  `mission <id> [floor]`. `mods/devtools` was deleted at P7 (2026-10-17).
- Multiplayer behaviour still needs the manual checklist in the module's README, solo
  and in a 2-player lobby.

**Local content.** A module may hold files generated from the player's own
HoH1 install (`tools/import_hoh1.py`): they are listed under `local` in
`module.json`, gitignored, and `build.py` skips them unless `--with-local`
(for a personal build; never upload one). `import_hoh1.py campaign` deletes
and rebuilds its output folder on every run, but only when the folder carries
its `.hwp-generated` marker (or with `--force`).

A `local_overlay` prefix (`module.json`, e.g. the classes module's
`hoh1art/`) is local content that replaces committed placeholder files:
with `--with-local`, `hoh1art/players/hwp/thief/icons.png` is packed as
`players/hwp/thief/icons.png` instead of the committed placeholder. Without
it (and in unpacked dev links) the placeholders are used.

The main menu loads the town level and constructs every `Modules::Module` subclass,
but only gameplay modes tick `UpdateFrame` (measured 2026-10-17, `docs/RE_NOTES.md`).
Put boot-time self-checks in the module constructor; a `log_has` step sees them.
Anything that needs a player needs the manual checklist in the module's README, solo and
in a 2-player lobby for anything networked.

## Modules

| id | Feature | Notes |
|---|---|---|
| `core` | shared library, the `hwp` console command (and `hwp` copies of the vanilla cheats), host-synced settings (`HWP::Settings::Sync(prefix)`), wares registry (`HWP::Market`, `hwp wares`, `hwp sell`), settings-backed town doodads (`HWP::Town::Placeable`), pack spawner (`HWP::Spawner`), level generation safety net (`HWPOutdoorGenerator`) | overrides `system/messages.net` and the five outdoor `tweak/missions/themes_*` files (one line each: `gen-class`) |
| `gambler` | Higher/Lower card game NPC, wares buyer, gear reroll (2000 g x ilvl, `Equipment::Generator::ModifyItem`) | |
| `droptrade` | drop equipment for friends (Drop hint/button + raw Q key next to vanilla Destroy) | overrides `GUI/PlayerMenu/Character.as`, `GUI/Widgets/EquipmentItemWidget.as` |
| `goldpet` | gold-collecting cat pet + vendor | requires `pets` (XP + skills as the external pet `hwp_goldpet`) |
| `laststats` | last run's stats on a town notice board | `hwp laststats` |
| `deathrecap` | death recap panel + chat line | hooks `PlayerDamageTaken`, `HUDConstructor` |
| `bufftips` | hover tooltips on the HUD buff icons (name, description, seconds left) | hooks `HUDConstructor`; hit-tests `HUDBuffs` icons itself |
| `legacy` | Title Bonuses: one buff listing every hero title bonus; Guild Hall > Titles lists every class | local husk buff kept up by script; rebuilds `GuildHallHeroTitlesTab` in place; `hwp legacy` |
| `pets` | pet XP + skill tree, feeding bowl, per-pet pickup toggles, HoH1 pets in the Pet Shop, pets wait outside puzzle rooms | class swaps `MiniPetWalking`/`MiniPetFlying`/`EquipmentDyerShopContent`; `tools/import_hoh1.py pets`, `tools/make_pet_dyes.py`; `hwp pet` |
| `architect` | everyone can pick + pay architect buffs, host share split | overrides `Missions/MissionArchitect.as` |
| `chatlinks` | linked items as persistent chat lines, `hwp link` | |
| `colors` | accessibility projectile tints; preset picker in Options > Game (cvar `hwp_projectile_colors`) | classmaps the projectile classes (**ignored by the engine: tints do not apply yet**); overrides `gui/options/game.gui` |
| `groupcombo` | party-wide combo bonus + unity invulnerability | `tweak/hwp/buffs_groupcombo.sval` |
| `weaponswap` | second weapon set on a hotkey | `hwp swap`, `hwp swapkey` |
| `keys` | every chest locked (key per tier), ace chests, key drops, exit guard key shop, legendaries | class swap `Chest` -> `HWPChest`; `tweak/hwp/legendaries.sval`; `hwp keys` |
| `firearms` | Firearms Specialist class (3 subclasses, rifles) | pure data via `PlayerClass`/`ItemSkillDef`/`BaseItem` loaders; `hwp firearms` |
| `fishing` | town fishing minigame, in-run fishing holes | `tweak/hwp/loot_fishing.sval`; wares via core `HWP::Market`; `hwp fishing` |
| `farming` | plots on the town's onion / wheat field grooves, watering can + farm well (watered = 2x growth), farmer shop (can, upgrades, seeds), seeds back on harvest, Holy Herb strains + next-run buffs | host-owned state in the TownRecord, `farm.sync`; overrides `npc_misc_farmer_man.unit`; `tweak/hwp/buffs_herbs.sval`; `hwp farm`, `hwp smoke` |
| `weapons` | 12 new weapons via `Equipment::BaseItem::LoadMultiple` | `tweak/hwp/equipment_weapons_hwp.sval`; `hwp weapons` |
| `strongbox` | strongbox chests: pack spawns on open, loot on clear | `HWPStrongbox : Chest`, `HWP::Spawner` (core); `tweak/hwp/loot_strongbox.sval`; `hwp strongbox` |
| `abyss` | abyss cracks: waves + elite, reward on clear | `HWP::Spawner`; `tweak/hwp/loot_abyss.sval`; `hwp abyss` |
| `maps` | 3 extra `equipment_map` missions | `tweak/hwp/missions/*.sval` (`MissionDef::LoadSingle`); `hwp maps` |
| `summons` | Crusaders persist across floors (snapshot `SaveUnit()`, re-produce on `GameModeSpawnPlayer`) | hooks `GameModeSpawnPlayer`; settings `summons.enabled/all`; `hwp summons` |
| `campaign` | Forsaken Tower mission (set `hwp_campaign`, 18 levels) + town portal doodad | `tweak/hwp/missions/missions_hwp_forsaken_tower.sval`; portal interact = vanilla `MissionShopContent`; settings `campaign.enabled/portal_x/portal_y`; `hwp campaign`; `tools/import_hoh1.py levels` (HoH1 level decode + gap report); `tools/import_hoh1.py campaign` (optional second mission on the real HoH1 boss / Battlements levels, local content; HoH1 classes in `scripts/HWP/Campaign/HoH1/`) |
| `devtools` | dev only, never packaged: the old floor loader | superseded by `gamelab-hands` `mission` (`mission-enter` run 20261017-140945); deleted 2026-10-17 |
| `wavemode` | Wave Arena survival mission (vanilla `SurvivalMission` module) + town statue, arena rank | `HWPWaveShopContent : MissionSurvivalShopContent`; hooks `PlayerKilledActor`; net `wave.bosskill`/`wave.start`/`wave.awarded`; settings `wave.enabled/rank/statue_x/statue_y`; `hwp wave` |
| `classes` | Thief / Gladiator / Witch Hunter (3 subclasses each, 39 skills), Arena Trident, pyre unit; HoH1-style 4th masteries for the vanilla Priest (Smiter) and Paladin (Holy Storm) | pure data via `PlayerClass`/`ItemSkillDef`/`BaseItem` loaders; `tweak/hwp/buffs_classes.sval`; `hwp classes` |
