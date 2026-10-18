// Three extra mission layouts for the equipment-map drops ("pink maps"):
// MissionDef::LoadSingle files under tweak/hwp/missions/. They join the
// vanilla equipment_map set, so MissionMap items roll them like Bandit Keep,
// Ghostly Crypt and Spider Caves. Themes, enemy schemes and boss levels are
// vanilla; the combinations are new.
namespace HWP
{
	namespace Maps
	{
		array<string> IDS = { "hwp_goblin_warrens", "hwp_sunken_dungeon", "hwp_high_court" };
		array<string> SCHEMES = { "bats_white_1", "beetles_black_1", "beetles_black_burrow", "beetles_green_2", "bone_blockade_1", "cult_3", "forest_mix_1", "goblins_1", "goblins_2", "goblins_3", "mandrakes_1", "tower_barracks_1", "tower_courts_1", "tower_crypt_1", "trolls_1", "trolls_2", "undead_court_1", "undead_court_2", "undead_guard_1", "undead_guard_2", "undead_horde_1", "undead_horde_2", "wasps_1", "wolves_1" };
		bool g_checked = false;

		MissionDef@ Find(const string &in id)
		{
			return MissionDef::Get(HashString(id));
		}

		// Missions are loaded with the other tweak data; checked at gameplay load.
		void SelfCheck()
		{
			if (g_checked)
				return;
			g_checked = true;
			int found = 0;
			for (uint i = 0; i < IDS.length(); i++)
			{
				auto def = Find(IDS[i]);
				if (def is null)
					HWP::LogError("maps", "mission " + IDS[i] + " not registered (tweak/hwp/missions/)");
				else
					found++;
			}
			int schemes = 0;
			for (uint i = 0; i < SCHEMES.length(); i++)
			{
				if (EnemyPlacementScheme::Get("actors/enemies.sval:" + SCHEMES[i]) !is null)
					schemes++;
				else
					HWP::LogError("maps", "missing enemy scheme " + SCHEMES[i]);
			}
			HWP::Log("maps", "self-check done: " + found + "/" + IDS.length() + " missions, " + schemes + "/" + SCHEMES.length() + " schemes");
		}

		void CmdMaps(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			int found = 0;
			int eligible = 0;
			for (uint i = 0; i < IDS.length(); i++)
			{
				auto def = Find(IDS[i]);
				if (def is null)
					continue;
				found++;
				bool ok = rec !is null && CheckConditionals(def.m_conditionals, rec);
				if (ok)
					eligible++;
				auto span = def.GetLevelSpan();
				HWP::Commands::Reply(Resources::GetString(".hwp.maps.row", {
					{ "name", Resources::GetString(def.m_name) }, { "floors", int(def.m_levels.length()) },
					{ "span", "" + span.x + "-" + span.y }, { "flag", ok ? "" : Resources::GetString(".hwp.maps.locked") } }));
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.maps.status", { { "found", found }, { "total", int(IDS.length()) }, { "eligible", eligible } }));
		}
	}
}

namespace Modules
{
	class HWPMapsModule : Module, HWP::ModuleStart
	{
		HWPMapsModule()
		{
			super("hwp-maps");
			HWP::Commands::Register("maps", " list the HammerwatchPlus map layouts", HWP::Commands::Handler(HWP::Maps::CmdMaps));
		}

		void Start(StartMode sMode)
		{
			HWP::Maps::g_checked = false;
			HWP::Maps::SelfCheck();
		}

		// the town starts with a null save, so Load never runs there (docs/RE_NOTES.md,
		// mod lifecycle): run the check on the first gameplay frame as well
		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			HWP::Maps::SelfCheck();
		}
	}
}
