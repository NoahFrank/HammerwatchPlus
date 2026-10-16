// Forsaken Tower campaign. The mission itself is data
// (tweak/hwp/missions/missions_hwp_forsaken_tower.sval, set hwp_campaign); this
// module spawns the town portal (doodads/hwp/forsaken_portal.unit) on the host,
// self-checks the data and answers /hwp campaign.
namespace HWP
{
	namespace Campaign
	{
		const string MISSION_ID = "hwp_forsaken_tower";
		const string PORTAL_UNIT = "doodads/hwp/forsaken_portal.unit";
		const array<string> SCHEMES = { "bandits_1", "bandits_2", "bats_black_1", "bats_white_1", "beetles_black_1", "beetles_black_burrow", "cult_2", "cult_3", "goblins_2", "goblins_3", "tower_barracks_1", "tower_courts_1", "tower_crypt_1", "trolls_1", "trolls_2", "undead_court_1", "undead_court_2", "undead_guard_1", "undead_guard_2", "undead_horde_1" };
		// every third floor is a boss floor, in act order
		const array<string> BOSS_LEVELS = { "levels/boss_totem_cave.lvl", "levels/boss_arista.lvl", "levels/boss_harbingers.lvl", "levels/boss_wraith.lvl", "levels/boss_bone_serpent.lvl", "levels/boss_avatar.lvl" };
		const int FLOORS_PER_ACT = 3;
		const int FLOORS = 18;

		bool g_enabled = true;
		bool g_checked = false;
		HWP::Town::Placeable@ g_portal;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("campaign.enabled", true);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("campaign.") == 0)
				RefreshSettings();
		}

		MissionDef@ Find()
		{
			return MissionDef::Get(HashString(MISSION_ID));
		}

		// Missions load with the tweak data; checked once per gameplay load.
		void SelfCheck()
		{
			if (g_checked)
				return;
			g_checked = true;
			auto def = Find();
			if (def is null)
				HWP::LogError("campaign", "mission " + MISSION_ID + " not registered (tweak/hwp/missions/)");
			else if (int(def.m_levels.length()) != FLOORS)
				HWP::LogError("campaign", "mission has " + def.m_levels.length() + " levels, expected " + FLOORS);
			else
			{
				for (uint i = 0; i < BOSS_LEVELS.length(); i++)
				{
					uint floor = i * FLOORS_PER_ACT + FLOORS_PER_ACT - 1;
					if (def.m_levels[floor].m_level != BOSS_LEVELS[i])
						HWP::LogError("campaign", "floor " + (floor + 1) + " is " + def.m_levels[floor].m_level + ", expected " + BOSS_LEVELS[i]);
				}
			}
			int schemes = 0;
			for (uint i = 0; i < SCHEMES.length(); i++)
			{
				if (Resources::GetSValue(HashString("actors/enemies.sval:" + SCHEMES[i])) !is null)
					schemes++;
				else
					HWP::LogError("campaign", "missing enemy scheme " + SCHEMES[i]);
			}
			HWP::Log("campaign", "self-check done: mission " + (def is null ? "missing" : "ok") + ", " + schemes + "/" + SCHEMES.length() + " schemes");
		}

		void CmdCampaign(array<string>@ args)
		{
			if (args.length() >= 1 && args[0] == "here")
			{
				g_portal.MoveHere();
				return;
			}
			auto rec = GetLocalPlayerRecord();
			auto def = Find();
			auto pos = g_portal.Pos();
			if (def is null)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.campaign.missing"));
				return;
			}
			bool ok = rec !is null && CheckConditionals(def.m_conditionals, rec);
			auto span = def.GetLevelSpan();
			HWP::Commands::Reply(Resources::GetString(".hwp.campaign.status", {
				{ "state", g_enabled ? "on" : "off" }, { "found", Resources::GetString(def.m_name) },
				{ "floors", int(def.m_levels.length()) }, { "span", "" + span.x + "-" + span.y },
				{ "flag", ok ? "" : Resources::GetString(".hwp.campaign.locked") },
				{ "x", int(pos.x) }, { "y", int(pos.y) } }));
		}
	}
}

namespace Modules
{
	class HWPCampaignModule : Module
	{
		HWPCampaignModule()
		{
			super("hwp-campaign");
			HWP::Settings::Sync("campaign.");
			HWP::Campaign::RefreshSettings();
			@HWP::Campaign::g_portal = HWP::Town::Placeable("campaign", "campaign.portal", HWP::Campaign::PORTAL_UNIT, -1700, 250);
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Campaign::OnSettingChanged));
			HWP::Commands::Register("campaign", " Forsaken Tower status; 'here' moves the town portal (host)", HWP::Commands::Handler(HWP::Campaign::CmdCampaign));
			HWP::CheckUnits("campaign", { HWP::Campaign::PORTAL_UNIT });
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::Campaign::RefreshSettings();
			HWP::Campaign::g_checked = false;
			HWP::Campaign::SelfCheck();
			HWP::Campaign::g_portal.OnLoad();
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			HWP::Campaign::g_portal.Update(ms, HWP::Campaign::g_enabled);
		}
	}
}
