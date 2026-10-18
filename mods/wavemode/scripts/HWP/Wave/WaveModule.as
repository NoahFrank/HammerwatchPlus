// Wave mode. The arena is a vanilla SurvivalMission level (data in
// tweak/hwp/missions/missions_hwp_wave_arena.sval). This module:
//  - spawns the wave statue in town (host) and moves it with hwp wave here;
//  - HWPWaveShopContent: the statue's shop, a MissionSurvivalShopContent whose
//    rank is the HWP arena rank (setting wave.rank, host-synced) instead of
//    the heaven stat, and whose boon has no skill. A client asks the host to
//    start (wave.start); the host confirms in a dialog like the DLC statues;
//  - raises the rank when the arena boss dies: the killer's machine sees the
//    PlayerKilledActor hook; the host awards directly, a client asks the host
//    (wave.bosskill), once per floor.
namespace HWP
{
	namespace Wave
	{
		const string MISSION_ID = "hwp_wave_arena";
		const string BOON_ID = "hwp_wave_boon";
		const string STATUE_UNIT = "doodads/hwp/wave_statue.unit";
		const string BOSS_UNIT = "actors/hwp/wave_boss.unit"; // the valor spirit without its valor stat reward
		const string BOSSKILL = "wave.bosskill"; // client -> host: the arena boss died
		const string START = "wave.start";       // client -> host: start the arena for me
		const string AWARDED = "wave.awarded";   // host -> all: { rank, gain }
		const array<string> ACTIONS = { "heaven_spawn_event_action_spawn_shades", "heaven_spawn_event_action_spawn_phantoms", "heaven_spawn_event_action_spawn_cult", "heaven_spawn_event_action_spawn_wisps" };

		bool g_enabled = true;
		int g_rank = 0;
		bool g_checked = false;
		bool g_awarded = false; // this floor's boss already counted
		HWP::Town::Placeable@ g_statue;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("wave.enabled", true);
			g_rank = HWP::Settings::GetInt("wave.rank", 0);
			if (g_rank < 0)
				g_rank = 0;
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("wave.") == 0)
				RefreshSettings();
		}

		int Rank() { return g_rank; }

		MissionDef@ FindMission()
		{
			return MissionDef::Get(HashString(MISSION_ID));
		}

		// no MissionBuff::Get in vanilla
		MissionBuff@ FindBoon()
		{
			for (uint i = 0; i < MissionBuff::Instances.length(); i++)
				if (MissionBuff::Instances[i].m_id == BOON_ID)
					return MissionBuff::Instances[i];
			return null;
		}

		bool Ready()
		{
			return g_enabled && FindMission() !is null && FindBoon() !is null;
		}

		bool IsWaveMission()
		{
			if (g_inTown)
				return false;
			auto def = MissionManager::GetCurrentMission();
			return def !is null && def.m_id == MISSION_ID;
		}

		bool IsBoss(Actor@ a)
		{
			if (a is null)
				return false;
			return (a.Tags & ApplyTag(0, g_actorTags.GetTag("boss"))) != 0;
		}

		// host: rank += 1..max-rank-reward (g_survivalReward is set by the
		// SurvivalMission module from how fast the XP goal was reached)
		void Award()
		{
			if (!Network::IsServer() || g_awarded)
				return;
			g_awarded = true;
			int gain = g_survivalReward > 0 ? g_survivalReward : 1;
			g_rank += gain;
			if (HWP::Settings::CanSave())
			{
				HWP::Settings::SetInt("wave.rank", g_rank);
				HWP::Commands::NotifySettingChanged("wave.rank");
			}
			else
				HWP::LogError("wave", "cannot save wave.rank (no town record)");
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("rank", g_rank);
			b.PushInteger("gain", gain);
			b.PopDictionary();
			HWP::Net::Broadcast(AWARDED, b.Build()); // also runs OnAwarded here
			HWP::Log("wave", "arena boss down, rank " + g_rank + " (+" + gain + ")");
		}

		void OnBossKill(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_enabled || !IsWaveMission())
				return;
			Award();
		}

		void OnAwarded(SValue@ data)
		{
			g_rank = HWP::SV::Int(data, "rank", g_rank);
			HWP::Commands::Reply(Resources::GetString(".hwp.wave.awarded", {
				{ "rank", g_rank }, { "gain", HWP::SV::Int(data, "gain", 1) } }));
		}

		// host: a client pressed Start on the statue. Ask the host like the
		// DLC statues do; yes opens the loadout menu at the host's rank.
		void OnStartRequest(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_inTown || !Ready())
				return;
			auto sender = GetPlayerRecordByPeer(peer);
			auto def = FindMission();
			if (sender is null || def is null)
				return;
			g_gameMode.ShowDialog("hwpwave", Resources::GetString(".menu.survival.multiplayer_request_got", {
				{ "name", sender.GetName() }, { "mission", def.m_name }, { "rnk", g_rank } }),
				Resources::GetString(".menu.yes"), Resources::GetString(".menu.no"), HWPWaveClientStarter(sender, def, g_rank));
		}

		[Hook]
		void PlayerKilledActor(Player@ player, Actor@ killed, DamageInfo@ di)
		{
			if (!g_enabled || !IsWaveMission() || !IsBoss(killed))
				return;
			if (Network::IsServer())
				Award();
			else
				HWP::Net::Request(BOSSKILL);
		}

		void SelfCheck()
		{
			if (g_checked)
				return;
			g_checked = true;
			auto mission = FindMission();
			auto boon = FindBoon();
			if (mission is null)
				HWP::LogError("wave", "mission " + MISSION_ID + " not registered (tweak/hwp/missions/)");
			if (boon is null)
				HWP::LogError("wave", "boon " + BOON_ID + " not registered (tweak/hwp/buffs_wave_boon.sval)");
			int actions = 0;
			for (uint i = 0; i < ACTIONS.length(); i++)
			{
				if (FloatingAction::Get("tweak/missions/missions_heaven_actions.sval:" + ACTIONS[i]) !is null)
					actions++;
				else
					HWP::LogError("wave", "missing spawn action " + ACTIONS[i]);
			}
			HWP::Log("wave", "self-check done: mission " + (mission is null ? "missing" : "ok") + ", boon " + (boon is null ? "missing" : "ok") + ", " + actions + "/" + ACTIONS.length() + " spawn actions, rank " + g_rank);
		}

		void CmdWave(array<string>@ args)
		{
			if (args.length() >= 1 && args[0] == "here")
			{
				g_statue.MoveHere();
				return;
			}
			if (args.length() >= 1 && args[0] == "rank")
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.wave.host_only"));
					return;
				}
				if (args.length() < 2 || !HWP::Commands::IsInteger(args[1]))
				{
					HWP::Commands::Reply("usage: hwp wave rank <n>");
					return;
				}
				g_rank = parseInt(args[1]);
				if (g_rank < 0)
					g_rank = 0;
				HWP::Settings::SetInt("wave.rank", g_rank);
				HWP::Commands::NotifySettingChanged("wave.rank");
				HWP::Commands::Reply(Resources::GetString(".hwp.wave.rank_set", { { "rank", g_rank } }));
				return;
			}
			auto pos = g_statue.Pos();
			HWP::Commands::Reply(Resources::GetString(".hwp.wave.status", {
				{ "state", g_enabled ? "on" : "off" }, { "rank", g_rank },
				{ "mission", FindMission() is null ? "missing" : "ok" }, { "boon", FindBoon() is null ? "missing" : "ok" },
				{ "x", int(pos.x) }, { "y", int(pos.y) } }));
		}
	}
}

// The statue's shop: vanilla survival shop with the HWP rank and a skill-less boon.
class HWPWaveShopContent : MissionSurvivalShopContent
{
	HWPWaveShopContent(UnitPtr u, SValue& params)
	{
		super(u, params);
	}

	bool CanInteract(PlayerRecord@ player) override
	{
		return HWP::Wave::Ready();
	}

	array<IShopItem@> GetItems() override
	{
		array<IShopItem@> ret;
		m_statValue = HWP::Wave::Rank();
		auto defs = GetMissionDefs();
		auto buffs = GetMissionBuff();
		if (defs.length() == 0 || buffs.length() == 0)
		{
			HWP::LogError("wave", "statue shop: mission or boon missing");
			return ret;
		}
		@m_mission = defs[0];
		@m_boon = buffs[0];
		ret.insertLast(HWPWaveShopItem(defs[0], buffs[0], m_statValue));
		return ret;
	}

	bool Buy(const string &in func, uint hash, IShopItem@ item) override
	{
		auto cItem = cast<SurvivalMissionShopContentItem>(item);
		if (cItem is null)
			return false;
		int rank = HWP::Wave::Rank();

		if (Network::IsServer())
		{
			MissionManager::SetMission(cItem.m_mapDef.m_idHash, randi(), Equipment::Slot::None, 0);
			auto gm = cast<BaseGameMode>(g_gameMode);
			gm.m_windowManager.AddWindowObject(MissionLoadoutMenu(gm.m_guiBuilder, null, MissionSpecSurvival(rank)));
		}
		else
		{
			// not the vanilla RequestStartingMap: its host side only reads the
			// rank as NG+ for the heaven set, ours would be rescaled from ilvl
			auto hostRecord = GetPlayerRecordByPeer(0);
			if (hostRecord is null)
				return false;
			g_gameMode.ShowDialog("", Resources::GetString(".hwp.wave.request_sent", {
				{ "host-name", hostRecord.GetName() }, { "rnk", rank } }), Resources::GetString(".menu.ok"), null);
			HWP::Net::Request(HWP::Wave::START);
		}
		return true;
	}

	// vanilla appends the boon skill's description; ours has no skill
	string GetBoonDetails() override
	{
		if (m_boon is null)
			return "";
		return m_boon.m_description + "\n" + Resources::GetString(".hwp.wave.rank_line", { { "rank", HWP::Wave::Rank() } });
	}
}

// the rank is ours, not gated by the town's NG+
class HWPWaveShopItem : SurvivalMissionShopContentItem
{
	HWPWaveShopItem(MissionDef@ mapDef, MissionBuff@ boon, int rank)
	{
		super(mapDef, boon, rank);
	}

	bool IsAvailable(PlayerRecord@ player) override { return true; }
}

// Host side of a client's start request: the yes/no dialog's host, then the
// loadout menu's start callback and spec (NG+ = the arena rank). Modelled on
// the vanilla MissionMapFromClientLoadoutStarter minus the map item handling.
class HWPWaveClientStarter : IWidgetHoster, IMissionLoadoutMenuStartCallback, IMissionSpec
{
	PlayerRecord@ m_sender;
	MissionDef@ m_mission;
	int m_rank;

	HWPWaveClientStarter(PlayerRecord@ sender, MissionDef@ mission, int rank)
	{
		@m_sender = sender;
		@m_mission = mission;
		m_rank = rank;
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "hwpwave yes")
		{
			MissionManager::SetMission(m_mission.m_idHash, randi(), Equipment::Slot::None, 0);
			auto gm = cast<BaseGameMode>(g_gameMode);
			gm.m_windowManager.AddWindowObject(MissionLoadoutMenu(gm.m_guiBuilder, this, this));
		}
	}

	void OnStart() {}

	// the requester left: close the loadout menu like vanilla does
	void OnUpdate(int ms)
	{
		if (m_sender.peer != 255)
			return;
		auto gm = cast<BaseGameMode>(g_gameMode);
		for (uint i = 0; i < gm.m_windowManager.m_objects.length(); i++)
		{
			auto wnd = cast<MissionLoadoutMenu>(gm.m_windowManager.m_objects[i]);
			if (wnd is null)
				continue;
			gm.m_windowManager.CloseWindow(wnd);
			return;
		}
	}

	bool ConfigurableNGP() { return false; }
	float GetNGP() { return float(m_rank); }

	string GetLoadoutTitle()
	{
		return Resources::GetString(".menu.loadout.starting_mission_from", {
			{ "name", m_sender.GetName() },
			{ "mission", m_mission.m_name + "  (" + Resources::GetString(".hwp.wave.rank_line", { { "rank", m_rank } }) + ")" } });
	}
}

namespace Modules
{
	class HWPWaveModule : Module, HWP::ModuleStart
	{
		HWPWaveModule()
		{
			super("hwp-wavemode");
			HWP::Settings::Sync("wave.");
			HWP::Wave::RefreshSettings();
			@HWP::Wave::g_statue = HWP::Town::Placeable("wave", "wave.statue", HWP::Wave::STATUE_UNIT, -1500, 250);
			HWP::Net::OnRequest(HWP::Wave::BOSSKILL, HWP::Net::RequestHandler(HWP::Wave::OnBossKill));
			HWP::Net::OnRequest(HWP::Wave::START, HWP::Net::RequestHandler(HWP::Wave::OnStartRequest));
			HWP::Net::OnEvent(HWP::Wave::AWARDED, HWP::Net::EventHandler(HWP::Wave::OnAwarded));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Wave::OnSettingChanged));
			HWP::Commands::Register("wave", " wave arena status; 'here' moves the statue, 'rank <n>' sets the rank (host)", HWP::Commands::Handler(HWP::Wave::CmdWave));
			HWP::CheckUnits("wavemode", { HWP::Wave::STATUE_UNIT, HWP::Wave::BOSS_UNIT });
		}

		void Start(StartMode sMode)
		{
			HWP::Wave::RefreshSettings();
			HWP::Wave::g_checked = false;
			HWP::Wave::SelfCheck();
			HWP::Wave::g_awarded = false;
			HWP::Wave::g_statue.OnLoad();
		}

		// the town starts with a null save, so Load never runs there (docs/RE_NOTES.md,
		// mod lifecycle): run the check on the first gameplay frame as well
		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			HWP::Wave::SelfCheck();
			HWP::Wave::g_statue.Update(ms, HWP::Wave::g_enabled);
		}
	}
}
