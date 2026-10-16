# Script hook call sites (HoH2 base, build 170)

Generated from `grep -rn 'Hooks::Call' .base/scripts`. A mod defines a free
function marked `[Hook]` inside a namespace whose name matches the hook; the
parameter list must match the call site (the engine logs
`Unexpected type for parameter %u in hook %s` otherwise).

```angelscript
namespace HWPDeathRecap
{
	[Hook]
	void PlayerDamageTaken(PlayerBase@ player, DamageInfo@ dmg)
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

## Other extension points

- **Modules** – any `Modules::Module` subclass is instantiated automatically by
  `Modules::MakeModules()` (`scripts/Modules/Module.as`) when a gameplay game
  mode starts. It gets `UpdateFrame`, `PreRenderFrame`, `RenderFrame`,
  `RenderWidgets`, `Save`, `Load`. Give it a unique id in `super("...")`; the
  id is the key of its save data in the game-mode save.
- **classmaps** – `info.xml` `classmaps` replaces an engine-visible class with
  a subclass without overriding the file that defines it.
- **`.sval` `<loader>`** – data files with a loader tag merge into the base
  tables instead of replacing them.
