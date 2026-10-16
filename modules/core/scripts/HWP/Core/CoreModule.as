// HWP core module: boot-time self checks. Modules are constructed in the main
// menu too (the menu runs the town level), so everything that can be verified
// without a player happens in the constructor and shows up in HWR2.exe.log.
namespace Modules
{
	class HWPCoreModule : Module
	{
		bool m_announced = false;

		HWPCoreModule()
		{
			super("hwp-core");
			HWP::Log("core", "module created, version " + HWP::VERSION);
			HWP::Log("core", "lang check: " + Resources::GetString(".hwp.core.hello"));

			// tools/hps.py learns the save-file hash of every mod id from these lines
			auto mods = Platform::GetAllResourceMods();
			for (uint i = 0; i < mods.length(); i++)
				HWP::Log("core", "modhash '" + mods[i].ID + "' " + HashString(mods[i].ID)
					+ (PersistentSaves::IsModEnabled(mods[i]) ? " enabled" : "")
					+ (mods[i].Packaged ? " packed" : " unpacked"));
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (m_announced)
				return;
			m_announced = true;
			HWP::Log("core", "gameplay started; server=" + (Network::IsServer() ? "yes" : "no")
				+ " town=" + (g_inTown ? "yes" : "no")
				+ " peer=" + Lobby::GetLocalPeer()
				+ " hwpTownKeys=" + HWP::SaveData::Town().Keys().length());
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			m_announced = false;
		}
	}
}
