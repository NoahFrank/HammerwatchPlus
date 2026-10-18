# Script hook call sites (HoH2 base, build 170)

Generated from `grep -rn 'Hooks::Call' gamecode/sdk/hoh2/scripts`. A mod defines a free
function marked `[Hook]` inside a namespace whose name matches the hook; the
parameter list must match the call site (the engine logs
`Unexpected type for parameter %u in hook %s` otherwise).

```angelscript
namespace HWPDeathRecap
{
	[Hook]
	void PlayerDamageTaken(Player@ player, DamageInfo@ dmg)
	{
		// ...
	}
}
```

| Hook | Arguments | Call site |
|---|---|---|
| `BaseGameModeConstructor` | `@this` (BaseGameMode) | `GameModes/BaseGameMode.as:279` |
| `GameModeUpdate` | `@this, int ms, GameInput&, MenuInput&` | `GameModes/BaseGameMode.as:680` |
| `GameModeUpdatePaused` | `@this, int ms, GameInput&, MenuInput&` | `GameModes/BaseGameMode.as:639` |
| `GameModeStart` | `@this, SValue@ save` | `GameModes/AGameplayGameMode.as:226` |
| `GameModePostStart` | `@this` | `GameModes/AGameplayGameMode.as:263` |
| `GameModePreRenderFrame` | `@this, int idt` | `GameModes/AGameplayGameMode.as:558` |
| `GameModeRenderFrame` | `@this, int idt, SpriteBatch& sb` | `GameModes/AGameplayGameMode.as:664` |
| `GameModeSpawnPlayer` | `@this, PlayerRecord@` | `GameModes/AGameplayGameMode.as:1079` |
| `GameModeSpawnPlayerCorpse` | `@this, PlayerRecord@` | `GameModes/AGameplayGameMode.as:1104` |
| `PlayerInitialize` | `@this` (PlayerBase) | `Behaviors/Actors/Player/PlayerBase.as:509` |
| `PlayerRefreshScene` | `@this` (PlayerBase) | `Behaviors/Actors/Player/PlayerBase.as:698` |
| `PlayerDamageActor` | `@this, Actor@, DamageInfo@, Weapon@` | `Behaviors/Actors/Player/PlayerBase.as:794` |
| `PlayerDamageActorNoWeapon` | `@this, Actor@, DamageInfo@` | `Behaviors/Actors/Player/PlayerBase.as:796` |
| `PlayerDamagedActor` | `@this, Actor@, DamageInfo@` | `Behaviors/Actors/Player/Player.as:205` |
| `PlayerKilledActor` | `@this, Actor@ killed, DamageInfo@` | `Behaviors/Actors/Player/Player.as:271` |
| `PlayerDamage` | `@this, DamageInfo@` (before mitigation) | `Behaviors/Actors/Player/Player.as:426` |
| `PlayerDamageTaken` | `@this, DamageInfo@` (after mitigation) | `Behaviors/Actors/Player/Player.as:628` |
| `PlayerRecordConstructor` | `@this` (PlayerRecord) | `Behaviors/Actors/Player/PlayerRecord.as:298` |
| `PickedCharacter` | `@this` | `Behaviors/Actors/Player/PlayerRecord.as:335` |
| `CreateCharacter` | `@this` | `Behaviors/Actors/Player/PlayerRecord.as:490` |
| `PlayerRecordSave` | `@this, SValueBuilder& builder` | `Behaviors/Actors/Player/PlayerRecord.as:875` |
| `PlayerRecordLoad` | `@this, SValue@ data` | `Behaviors/Actors/Player/PlayerRecord.as:1299` |
| `PlayerRecordRefreshModifiers` | `@this` | `Behaviors/Actors/Player/PlayerRecord.as:1898` |
| `LevelupCharacter` | `@this` | `Behaviors/Actors/Player/PlayerRecord.as:2380` |
| `HUDConstructor` | `@this (HUD), GUIBuilder@ b` | `GUI/HUD/HUD.as:91` |
| `LoadWidgetProducers` | `GUIBuilder@ builder` | `GUI/WidgetProducers.as:67` |
| `TownRecordConstructor` | `@this` (TownRecord) | `Town/TownRecord.as:86` |
| `TownRecordSave` | `@this, SValueBuilder& builder` | `Town/TownRecord.as:380` |
| `TownRecordLoad` | `@this, SValue@ save` | `Town/TownRecord.as:446` |
| `TownRecordSpawnTown` | `@this` | `Town/TownRecord.as:672` |
| `TownRecordRefreshHeroTitles` | `@this` | `Town/TownRecord.as:729` |
| `TownRecordRefreshDonationTitles` | `@this` | `Town/TownRecord.as:743` |

Exact parameter types: open the call site in `gamecode/sdk/hoh2/scripts/` (`tools/bootstrap.py` regenerates it).
Use the exact call-site type (`Player@` for the hooks in `Player.as`, `PlayerBase@`
for the ones in `PlayerBase.as`). `HUDConstructor` is the place to add a
`HUDComponent` (`hud.m_components.insertLast(...)`), see `mods/deathrecap`
and `mods/weaponswap`.

**Hooks that do not fire for mods** (build 170, verified with `[HWP]` log
lines): `GameModeUpdate` and `GameModeUpdatePaused` are never called, with
`BaseGameMode@`, `BaseGameMode&` or the derived type as the first parameter.
Tick from a `Modules::Module` `UpdateFrame` instead (gameplay modes only).
The main menu is out of reach as well: a `MainMenuGameMode` classmap is
ignored (as are all classmaps, see below) and menu-scene units get no `Update`. Module constructors do run at the menu
(measured 2026-10-17, `docs/RE_NOTES.md`), but nothing ticks. GameLab leaves the menu with
a posted Enter key, which starts Singleplayer/Continue. It never uses the real mouse.

## Other extension points

- **Modules** – any `Modules::Module` subclass is instantiated automatically by
  `Modules::MakeModules()` (`scripts/Modules/Module.as`) when a gameplay game
  mode starts. It gets `UpdateFrame`, `PreRenderFrame`, `RenderFrame`,
  `RenderWidgets`, `Save`, `Load`. Give it a unique id in `super("...")`; the
  id is the key of its save data in the game-mode save.
- **classmaps do not work.** `info.xml` `classmaps` look like a way to swap a
  class for a subclass, but the engine ignores them for unit behaviours and
  for `InstantiateClass` (checked in game, 2026-10-17, packed and unpacked).
  Instead a module lists `"class_swaps": {"Chest": "HWPChest"}` in its
  `module.json`, and `tools/class_units.py` (run by `build.py`) copies every
  base unit that names one of those classes into the module with ours in its
  place. The copies are generated overrides: remade from `gamecode/sdk/hoh2/` on every
  build and gitignored. Used by `mods/pets` (`MiniPetWalking`,
  `MiniPetFlying`, `EquipmentDyerShopContent`) and `mods/keys` (`Chest`).
  `mods/colors` still lists projectile classmaps, so its tints do nothing.
- **`.sval` `<loader>`** – data files with a loader tag merge into the base
  tables instead of replacing them.
- **Game events** – `Events.mas` declares `interface IEvent<Name>` with
  `OnEvent<Name>(...)`; implement it on a module and call
  `GameEvents::Subscribe(this)`. Used: `IEventPlayerDied`,
  `IEventPlayerLinkedItem`.
- **Console commands** – register an `hwp <name>` sub-command with
  `HWP::Commands::Register` (core), no override needed in the module.

## Script API gotchas (verified by compiling)

- **The menu has its own script, without mods.** The in-game chat
  (`MainMenuGameMode.m_ingameChat`) and the pause menu run in the main menu's
  script (log lines prefixed `[menu]`), which loads only the base scripts:
  an override of `GUI/Menus/InGameChat.as` never runs there, and it has no
  town or players. Console commands registered by both scripts (the vanilla
  `cht_*`) run the menu's copy, so `cht_give_material` and friends fail with a
  null pointer in a level. A command registered only from the game's script
  (a module) runs there: core's `hwp` console command. A console function
  with one `cvar_type::String` parameter receives the whole rest of the line
  (`hwp material all 5` -> `"material all 5"`).
- **SValues are not reference counted.** The `SValue@` a load hook or a
  network handler receives is freed by the engine once the call returns, and
  `SValueBuilder.PushSimple` / `Network::Message <<` take ownership of the
  value they are given. Keeping such a handle, or pushing a value you still
  hold, ends in a double free (heap corruption, `0xc0000374`, typically on the
  next save). Call `.Copy()` on anything you keep past the call and on anything
  you push or send while still holding it; `.Delete()` only your own values.
  Vanilla does the same (`m_staticSave = ...Copy()`, `<< m_saveData[j].Copy()`).
  `HWP::DataBag` copies on `Set`/`Load`/`Save` and `HWP::Net` copies before
  sending, so a value from `bag.Get()` is fine to read but must be copied
  before it is kept elsewhere.
- `out` is a reserved word (`&out`), do not name a variable `out`.
- A unit's data path is `unit.GetUnitProducer().GetResourceName()`.
- Raw keyboard polling is `Platform::IsKeyDown(ControllerType::Keyboard, 0, sdlScancode)`;
  `IsActionDown("name")` reads a bound action.
- `g_scene.QueryCircle(vec2, int radius, ...)` takes an int radius.
- A ternary cannot yield `ref@` (`cond ? unit.GetScriptBehavior() : null`
  fails with "No appropriate opAssign method found in 'ref'"); use an `if`.
- `Resources::GetSValue(HashString("file.sval:key"))` only works for svals
  *without* a `<loader>` tag (plain data files like `pet_skills.sval`). A
  loader file is consumed by its loader and is not a resource: look its
  entries up through the loader's getter (`EnemyPlacementScheme::Get`,
  `FloatingAction::Get`, `MissionDef::Get`, `LoadActorBuff`...).
- There is no `lerprot` (HoH1 had one) and no `GetInterpolatedPosition`;
  `rottowards(from, to, maxStep)` and `GetPosition()` exist.
- `StateActorBehavior` (and so `TransferDamageActor`) needs a non-empty
  `states` array; a state without movement or skills uses the base ones.
