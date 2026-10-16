namespace Modules
{
	// Smoke-test module: proves scripts, modules and language files load.
	// Modules are only ticked by gameplay game modes (AGameplayGameMode), not by
	// the main menu, so anything that must run on every boot goes in the constructor.
	class HWPCoreModule : Module
	{
		bool m_announced = false;

		HWPCoreModule()
		{
			super("hwp-core");
			HWP::Log("core", "module created, version " + HWP::VERSION);

			// Print every discovered mod with the hash the save file stores for it, so
			// tools/hps.py can enable mods without the menu.
			auto mods = Platform::GetAllResourceMods();
			for (uint i = 0; i < mods.length(); i++)
			{
				HWP::Log("core", "modhash '" + mods[i].ID + "' " + HashString(mods[i].ID)
					+ (PersistentSaves::IsModEnabled(mods[i]) ? " enabled" : "")
					+ (mods[i].Packaged ? " packed" : " unpacked"));
			}
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (m_announced)
				return;
			m_announced = true;
			HWP::Log("core", "version " + HWP::VERSION + " active; server=" + Network::IsServer() + " town=" + g_inTown);
			HWP::Log("core", "lang check: " + Resources::GetString(".hwp.core.hello"));
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			m_announced = false;
		}
	}
}
