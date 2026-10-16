# Script hook call sites (HoH2 base, build 170)

Generated from `grep -rn 'Hooks::Call' .base/scripts`. A mod defines a free
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

Exact parameter types: open the call site in `.base/` (run `tools/extract_base.py`).
Use the exact call-site type (`Player@` for the hooks in `Player.as`, `PlayerBase@`
for the ones in `PlayerBase.as`). `HUDConstructor` is the place to add a
`HUDComponent` (`hud.m_components.insertLast(...)`), see `modules/deathrecap`
and `modules/weaponswap`.

**Hooks that do not fire for mods** (build 170, verified with `[HWP]` log
lines): `GameModeUpdate` and `GameModeUpdatePaused` are never called, with
`BaseGameMode@`, `BaseGameMode&` or the derived type as the first parameter.
Tick from a `Modules::Module` `UpdateFrame` instead (gameplay modes only).
The main menu is out of reach as well: a `MainMenuGameMode` classmap is
ignored and menu-scene units get no `Update`. What does run in the menu is
module construction and the game mode's widget script hosts, which is how
`--press-continue` in `tools/dev_check.py` clicks Continue from outside
(mouse input) rather than from a script.

## Other extension points

- **Modules** – any `Modules::Module` subclass is instantiated automatically by
  `Modules::MakeModules()` (`scripts/Modules/Module.as`) when a gameplay game
  mode starts. It gets `UpdateFrame`, `PreRenderFrame`, `RenderFrame`,
  `RenderWidgets`, `Save`, `Load`. Give it a unique id in `super("...")`; the
  id is the key of its save data in the game-mode save.
- **classmaps** – `info.xml` `classmaps` replaces an engine-visible class with
  a subclass without overriding the file that defines it. Used on unit
  behaviours (`MiniPetWalking` -> `HWPMiniPetWalking` in `modules/pets`,
  `NewProjectile` etc. in `modules/colors`). `build.py` copies the
  whole `info.xml` into the packed archive's meta, so such keys survive packing.
- **`.sval` `<loader>`** – data files with a loader tag merge into the base
  tables instead of replacing them.
- **Game events** – `Events.mas` declares `interface IEvent<Name>` with
  `OnEvent<Name>(...)`; implement it on a module and call
  `GameEvents::Subscribe(this)`. Used: `IEventPlayerDied`,
  `IEventPlayerLinkedItem`.
- **Chat commands** – register with `HWP::Commands::Register` (core), no
  override needed in the module.

## Script API gotchas (verified by compiling)

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
