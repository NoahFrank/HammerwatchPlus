// Firearms Specialist: everything about the class is data (players/hwp/firearms,
// tweak/hwp/equipment_firearms.sval). This module only self-checks that the
// data registered and offers hwp firearms for a status line.
namespace HWP
{
	namespace Firearms
	{
		const string CLASS_ID = "hwp_firearms";
		const array<string> UNITS = {
			"players/hwp/firearms/projectiles/bullet.unit",
			"players/hwp/firearms/projectiles/bullet_epic.unit",
			"players/hwp/firearms/projectiles/bullet_aimed.unit",
			"players/hwp/firearms/projectiles/bullet_aimed_epic.unit",
			"players/hwp/firearms/projectiles/bullet_snipe.unit",
			"players/hwp/firearms/projectiles/grenade_frag.unit",
			"players/hwp/firearms/projectiles/grenade_flash.unit",
			"players/hwp/firearms/projectiles/grenade_stun.unit",
			"players/hwp/firearms/projectiles/tube_shell.unit",
			"players/hwp/firearms/projectiles/rocket.unit",
			"players/hwp/firearms/units/decoy.unit" };

		bool g_checked = false;

		// Logged at boot (module constructor, for dev_check) and once per
		// gameplay load (g_checked is reset in Start): did the loaders pick the
		// class, the subclasses, the rifles and the units up? Items are only
		// registered after the modules are made, so the rifles are checked at
		// gameplay load.
		void SelfCheck(bool items)
		{
			if (g_checked)
				return;
			g_checked = true;

			int subclasses = 0;
			bool found = false;
			uint hash = HashString(CLASS_ID);
			for (uint i = 0; i < PlayerClass::Instances.length(); i++)
			{
				if (PlayerClass::Instances[i].m_id == CLASS_ID)
					found = true;
				if (PlayerClass::Instances[i].parent == hash)
					subclasses++;
			}
			if (!found)
				HWP::LogError("firearms", "class " + CLASS_ID + " not registered (players/hwp/firearms/class_firearms.sval)");
			else
				HWP::Log("firearms", "class registered with " + subclasses + " subclass(es)");

			if (items)
				HWP::CheckEquipment("firearms", { "hwp_rifle_01", "hwp_rifle_02", "hwp_rifle_03" });
			HWP::CheckUnits("firearms", UNITS);
			HWP::Log("firearms", "self-check done");
		}

		void CmdStatus(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.playerClass is null)
			{
				HWP::Commands::Reply("no character loaded");
				return;
			}
			string rifle = "-";
			if (rec.equipped !is null)
			{
				auto item = rec.equipped.GetEquipment(EquippedItemsSlots::MainHand);
				if (item !is null)
					rifle = item.GetName();
			}
			string mana = "" + int(rec.mana * float(rec.MaxMana())); // mana is a 0..1 ratio
			string maxMana = "" + rec.MaxMana();
			HWP::Commands::Reply(Resources::GetString(".hwp.firearms.status", {
				{ "cls", rec.playerClass.m_id }, { "rifle", rifle }, { "mana", mana }, { "max", maxMana } }));
		}
	}
}

namespace Modules
{
	class HWPFirearmsModule : Module, HWP::ModuleStart
	{
		HWPFirearmsModule()
		{
			super("hwp-firearms");
			HWP::Commands::Register("firearms", " Firearms Specialist status", HWP::Commands::Handler(HWP::Firearms::CmdStatus));
			HWP::Firearms::SelfCheck(false);
		}

		void Start(StartMode sMode)
		{
			HWP::Firearms::g_checked = false;
			HWP::Firearms::SelfCheck(true);
		}
	}
}
