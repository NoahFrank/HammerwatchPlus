// HoH1 classes. Everything about them is data (players/hwp/<class>/,
// tweak/hwp/*_classes.sval); this module self-checks the loaders and answers
// hwp classes.
namespace HWP
{
	namespace Classes
	{
		const array<string> IDS = { "hwp_thief", "hwp_gladiator", "hwp_witch_hunter" };
		// HoH1-style 4th masteries of vanilla classes: { subclass id, parent id }
		const array<array<string>> SPECS = { { "hwp_priest_hoh1", "priest" }, { "hwp_paladin_hoh1", "paladin" } };
		const array<string> UNITS = {
			"players/hwp/witchhunter/units/pyre.unit",
			"players/rogue/projectiles/rog_throwing_knife.unit",
			"players/warrior/projectiles/whirling_axe_right.unit",
			"players/ranger/units/wolf.unit",
			"players/priest/units/crusader_pikeman.unit" };
		bool g_checked = false;
		bool g_itemsChecked = false;

		int Subclasses(uint parentHash)
		{
			int n = 0;
			for (uint i = 0; i < PlayerClass::Instances.length(); i++)
				if (PlayerClass::Instances[i].parent == parentHash)
					n++;
			return n;
		}

		bool Registered(const string &in id)
		{
			for (uint i = 0; i < PlayerClass::Instances.length(); i++)
				if (PlayerClass::Instances[i].m_id == id)
					return true;
			return false;
		}

		// Classes load at boot, so the constructor checks them once (that is
		// what dev_check sees).
		void SelfCheck()
		{
			if (g_checked)
				return;
			g_checked = true;
			int found = 0;
			for (uint i = 0; i < IDS.length(); i++)
			{
				if (!Registered(IDS[i]))
				{
					HWP::LogError("classes", "class " + IDS[i] + " not registered (players/hwp/)");
					continue;
				}
				found++;
				int subs = Subclasses(HashString(IDS[i]));
				if (subs != 3)
					HWP::LogError("classes", IDS[i] + " has " + subs + " subclasses, expected 3");
			}
			int specs = 0;
			for (uint i = 0; i < SPECS.length(); i++)
			{
				auto spec = PlayerClass::Get(HashString(SPECS[i][0]));
				if (spec is null)
					HWP::LogError("classes", "mastery " + SPECS[i][0] + " not registered (players/hwp/hoh1specs/)");
				else if (spec.parent != HashString(SPECS[i][1]))
					HWP::LogError("classes", "mastery " + SPECS[i][0] + " is not a subclass of " + SPECS[i][1]);
				else
					specs++;
			}
			HWP::CheckUnits("classes", UNITS);
			HWP::Log("classes", "self-check done: " + found + "/" + IDS.length() + " classes, " + specs + "/" + SPECS.length() + " HoH1 masteries");
		}

		// The trident is an item and only resolves at gameplay load; once.
		void CheckTrident()
		{
			if (g_itemsChecked)
				return;
			g_itemsChecked = true;
			HWP::CheckEquipment("classes", { "hwp_trident_01" });
		}

		void CmdClasses(array<string>@ args)
		{
			int found = 0;
			int subs = 0;
			for (uint i = 0; i < IDS.length(); i++)
			{
				if (!Registered(IDS[i]))
					continue;
				found++;
				subs += Subclasses(HashString(IDS[i]));
			}
			auto rec = GetLocalPlayerRecord();
			string cls = (rec is null || rec.playerClass is null) ? "-" : rec.playerClass.m_id;
			HWP::Commands::Reply(Resources::GetString(".hwp.classes.status", { { "found", found }, { "subs", subs }, { "cls", cls } }));
		}
	}
}

namespace Modules
{
	class HWPClassesModule : Module, HWP::ModuleStart
	{
		HWPClassesModule()
		{
			super("hwp-classes");
			HWP::Commands::Register("classes", " HoH1 classes status", HWP::Commands::Handler(HWP::Classes::CmdClasses));
			HWP::Classes::SelfCheck();
		}

		void Start(StartMode sMode)
		{
			HWP::Classes::CheckTrident();
		}
	}
}
