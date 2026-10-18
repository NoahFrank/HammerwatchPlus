// Twelve extra endgame weapons (ilvl 35, four per slot) merged into the base
// equipment tables through the <loader> in tweak/hwp/equipment_weapons_hwp.sval.
// They reuse base graphics, models and attack skills and differ in their
// modifier profiles (hybrid damage types, crit, speed, parry, block). The
// base drop and shop code picks them up like any other BaseItem.
namespace HWP
{
	namespace Weapons
	{
		array<string> IDS = { "hwp_mh_warhammer", "hwp_mh_frostbrand", "hwp_mh_stiletto", "hwp_mh_stormrod", "hwp_oh_bulwark", "hwp_oh_grimoire", "hwp_oh_handcannon", "hwp_oh_parrying_dirk", "hwp_2h_warbow", "hwp_2h_executioner", "hwp_2h_tempest", "hwp_2h_twinfangs" };
		bool g_checked = false;

		// Items are registered after the modules are made, so the check runs at
		// gameplay load (g_checked is reset in Start).
		void SelfCheck()
		{
			if (g_checked)
				return;
			g_checked = true;
			HWP::CheckEquipment("weapons", IDS);
			HWP::Log("weapons", "self-check done: " + IDS.length() + " weapons");
		}

		void CmdWeapons(array<string>@ args)
		{
			int found = 0;
			for (uint i = 0; i < IDS.length(); i++)
			{
				auto item = Equipment::BaseItem::Get(IDS[i]);
				if (item is null)
					continue;
				found++;
				HWP::Commands::Reply(item.name + " - " + Resources::GetString(".hwp.weapons." + IDS[i] + ".desc"));
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.weapons.count", { { "n", found }, { "total", int(IDS.length()) } }));
		}
	}
}

namespace Modules
{
	class HWPWeaponsModule : Module, HWP::ModuleStart
	{
		HWPWeaponsModule()
		{
			super("hwp-weapons");
			HWP::Commands::Register("weapons", " list the HammerwatchPlus weapons", HWP::Commands::Handler(HWP::Weapons::CmdWeapons));
		}

		void Start(StartMode sMode)
		{
			HWP::Weapons::g_checked = false;
			HWP::Weapons::SelfCheck();
		}

		// the town starts with a null save, so Load never runs there (docs/RE_NOTES.md,
		// mod lifecycle): run the check on the first gameplay frame as well
		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			HWP::Weapons::SelfCheck();
		}
	}
}
