// Per-level start for HWP modules.
//
// The engine only calls Module::Load when the level starts from a save that
// holds data for that module id. A StartMode StartGame level (a new profile's
// first town, a fresh character) passes a null save and skips Load entirely,
// so whatever a module sets up per level would silently not happen there. A
// module implements HWP::ModuleStart instead and the GameModeStart hook below
// calls Start on every gameplay level, after the scene and the local players
// are in (the host spawns them in PostStart) and before the first
// UpdateFrame. Anything that must run before PostStart (the town's
// MissionEndMenu, chests locking while the level loads) belongs in the module
// constructor, which runs once per level inside the game mode's constructor.
// (The main menu runs MainMenuGameMode: no modules, no GameModeStart.)
namespace HWP
{
	interface ModuleStart
	{
		void Start(StartMode sMode);
	}
}

namespace HWPModuleStart
{
	[Hook]
	void GameModeStart(AGameplayGameMode@ gm, SValue@ save)
	{
		HWP::Gear::Changed(); // gear slots read the (maybe new) local character's data
		if (gm is null)
			return;
		// core first: the others may depend on its per-level state
		for (int pass = 0; pass < 2; pass++)
		{
			for (uint i = 0; i < gm.m_modules.length(); i++)
			{
				auto m = gm.m_modules[i];
				if (m is null || (m.m_id == "hwp-core") != (pass == 0))
					continue;
				auto s = cast<HWP::ModuleStart>(m);
				if (s is null)
					continue;
				try { s.Start(gm.m_startMode); }
				catch { PrintError("[HWP] exception starting module " + m.m_id); }
			}
		}
	}
}
