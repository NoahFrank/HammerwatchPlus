# Module conventions

Each module is a folder `modules/<id>/` that is itself a valid unpacked HoH2
mod (`info.xml` at the root). `tools/build.py` packs it to `dist/HWP-<id>.bin`.

```
modules/<id>/
  info.xml                      name / author / description (+ classmaps when needed)
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
2. **Prefer hooks, modules and classmaps.** See `docs/hooks.md`.
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

## Testing a module

```
python tools/dev_link.py <id>      # link into the game's mods/ folder
python tools/dev_check.py          # enable the linked mods in the save, boot the game,
                                   # fail on script errors in our files
```

`dev_check.py` patches the enabled-mod list in the persistent save (see
`tools/hps.py`), so no menu clicking is needed. The hash of a brand-new module
id is learned from the core module's log output on the first boot; the tool then
boots a second time with the module enabled.

The main menu already runs the town level and constructs all `Modules::Module`
subclasses, but only gameplay game modes tick `UpdateFrame`. Put boot-time
self-checks in the module constructor; anything that needs a player needs the
manual checklist in the module's README, solo and in a 2-player lobby for
anything networked.

## Modules

| id | Feature | Notes |
|---|---|---|
| `core` | shared library, `/hwp` chat commands, host-synced settings (`HWP::Settings::Sync(prefix)`), wares registry (`HWP::Market`, `/hwp wares`, `/hwp sell`) | overrides `system/messages.net`, `GUI/Menus/InGameChat.as` |
| `gambler` | Higher/Lower card game NPC, wares buyer, gear reroll (2000 g x ilvl, `Equipment::Generator::ModifyItem`) | |
| `droptrade` | drop equipment for friends | |
| `goldpet` | gold-collecting cat pet + vendor | requires `pets` (XP + skills as the external pet `hwp_goldpet`) |
| `laststats` | last run's stats on a town notice board | `/hwp laststats` |
| `deathrecap` | death recap panel + chat line | hooks `PlayerDamageTaken`, `HUDConstructor` |
| `pets` | pet XP + skill tree, feeding bowl, per-pet pickup toggles, HoH1 pets in the Pet Shop, pets wait outside puzzle rooms | classmaps `MiniPetWalking`/`MiniPetFlying`; `tools/import_hoh1.py pets`; `/hwp pet` |
| `architect` | everyone can pick + pay architect buffs, host share split | overrides `Missions/MissionArchitect.as` |
| `chatlinks` | linked items as persistent chat lines, `/hwp link` | |
| `colors` | accessibility projectile tints | classmaps the projectile classes |
| `groupcombo` | party-wide combo bonus + unity invulnerability | `tweak/hwp/buffs_groupcombo.sval` |
| `weaponswap` | second weapon set on a hotkey | `/hwp swap`, `/hwp swapkey` |
| `keys` | locked/ace chests, key drops, General Merchant, legendaries | classmaps `Chest`; `tweak/hwp/legendaries.sval`; `/hwp keys` |
| `firearms` | Firearms Specialist class (3 subclasses, rifles) | pure data via `PlayerClass`/`ItemSkillDef`/`BaseItem` loaders; `/hwp firearms` |
| `fishing` | town fishing minigame, in-run fishing holes | `tweak/hwp/loot_fishing.sval`; wares via core `HWP::Market`; `/hwp fishing` |
| `farming` | farm plots, crops, Holy Herb strains + next-run buffs | host-owned state in the TownRecord, `farm.sync`; `tweak/hwp/buffs_herbs.sval`; `/hwp farm`, `/hwp smoke` |
| `weapons` | 12 new weapons via `Equipment::BaseItem::LoadMultiple` | `tweak/hwp/equipment_weapons_hwp.sval`; `/hwp weapons` |
| `strongbox` | strongbox chests: pack spawns on open, loot on clear | `HWPStrongbox : Chest`, `HWP::Spawner` (core); `tweak/hwp/loot_strongbox.sval`; `/hwp strongbox` |
| `abyss` | abyss cracks: waves + elite, reward on clear | `HWP::Spawner`; `tweak/hwp/loot_abyss.sval`; `/hwp abyss` |
| `maps` | 3 extra `equipment_map` missions | `tweak/hwp/missions/*.sval` (`MissionDef::LoadSingle`); `/hwp maps` |
| `specs` | buffs for the 4 weakest specs, re-applied every 2 s locally | `tweak/hwp/buffs_specs.sval`; `/hwp specs` |
| `summons` | Crusaders persist across floors (snapshot `SaveUnit()`, re-produce on `GameModeSpawnPlayer`) | hooks `GameModeSpawnPlayer`; settings `summons.enabled/all`; `/hwp summons` |
