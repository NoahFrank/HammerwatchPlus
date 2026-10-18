// HWP core module: boot-time self checks and the host -> client settings sync.
// Modules are constructed in the main menu too (the menu runs the town level),
// so everything that can be verified without a player happens in the
// constructor and shows up in HWR2.exe.log.
//
//   settings.pull   client -> host   {}            send me your synced settings
//   settings.sync   host -> client   { name: v }   HWP::Settings::Pack()
namespace HWP
{
	namespace Core
	{
		const string SETTINGS_PULL = "settings.pull";
		const string SETTINGS_SYNC = "settings.sync";

		void OnPull(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer())
				return;
			HWP::Net::Send(peer, SETTINGS_SYNC, HWP::Settings::Pack());
		}

		void OnSync(SValue@ data)
		{
			if (Network::IsServer())
				return;
			auto names = HWP::Settings::Apply(data);
			HWP::Log("core", "settings from host: " + names.length() + " value(s)");
			// once per synced prefix: listeners match on the prefix and re-read
			// every setting under it (names the host never set fall back to
			// defaults through the same Get* calls)
			for (uint i = 0; i < HWP::Settings::g_syncedPrefixes.length(); i++)
				HWP::Commands::NotifySettingChanged(HWP::Settings::g_syncedPrefixes[i]);
		}

		void OnSettingChanged(const string &in key)
		{
			if (Network::IsServer() && HWP::Settings::IsSynced(key))
				HWP::Net::Broadcast(SETTINGS_SYNC, HWP::Settings::Pack());
		}
	}
}

namespace Modules
{
	class HWPCoreModule : Module, HWP::ModuleStart
	{
		bool m_announced = false;

		HWPCoreModule()
		{
			super("hwp-core");
			HWP::Log("core", "module created, version " + HWP::VERSION);
			HWP::Log("core", "lang check: " + Resources::GetString(".hwp.core.hello"));
			HWP::Commands::RegisterBuiltins();
			HWP::Market::Init();
			HWP::Net::OnRequest(HWP::Core::SETTINGS_PULL, HWP::Net::RequestHandler(HWP::Core::OnPull));
			HWP::Net::OnEvent(HWP::Core::SETTINGS_SYNC, HWP::Net::EventHandler(HWP::Core::OnSync));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Core::OnSettingChanged));

			auto forest = MissionThemeDef::Get("theme_forest");
			HWP::Log("core", "generator safety net: " + (forest is null ? "themes not loaded" : GetParamString(UnitPtr(), forest.m_baseData, "gen-class", false)));

			// the save-file hash of every mod id (gamelab/hps.py computes the same values)
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
			// first gameplay tick: the connection is up, ask the host for the
			// lobby-wide settings (the host answers with settings.sync)
			if (!Network::IsServer())
				HWP::Net::Request(HWP::Core::SETTINGS_PULL, HWP::Net::Empty());
		}

		void Start(StartMode sMode)
		{
			// every level: the first gameplay tick re-pulls the host's values
			// (script globals, the received ones included, reset per level)
			m_announced = false;
		}
	}
}
