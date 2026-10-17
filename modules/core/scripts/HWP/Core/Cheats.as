// HWP::Cheats - chat copies of the vanilla cheats the test plan uses.
// The main menu registers the cht_* console commands too, and the console
// can run them in the menu's script, where there is no town or character:
// cht_give_material, cht_levelup and friends then fail with a null pointer.
// The console's "hwp <cheat>" runs in the game's script (see Commands.as).
// Each needs e_cheats 1.
namespace HWP
{
	namespace Cheats
	{
		void Reply(const string &in text) { HWP::Commands::Reply(text); }

		bool On()
		{
			if (GetVarBool("e_cheats"))
				return true;
			Reply("cheats are off - type e_cheats 1 in the console first");
			return false;
		}

		// the local record, with an actor when asked; replies when missing
		PlayerRecord@ Me(bool needActor = false)
		{
			auto plr = GetLocalPlayerRecord();
			if (plr is null || (needActor && plr.actor is null))
			{
				Reply("no character in the world - load one first");
				return null;
			}
			return plr;
		}

		vec3 NearMe(PlayerRecord@ plr)
		{
			return plr.actor.m_unit.GetPosition() + xyz(randdir() * (randf() + 1.0f) * 25);
		}

		int IntArg(array<string>@ args, uint i, int def)
		{
			if (i < args.length() && HWP::Commands::IsInteger(args[i]))
				return parseInt(args[i]);
			return def;
		}

		void CmdUnlockFlags(array<string>@ args)
		{
			if (!On())
				return;
			if (g_myTownRecord is null)
			{
				Reply("no town loaded - load a character first");
				return;
			}
			Console::Cheats::UnlockTownFlagsCFunc();
			Reply("unlocked the story town flags");
		}

		void CmdMaterial(array<string>@ args)
		{
			if (!On())
				return;
			if (args.length() < 2 || !HWP::Commands::IsInteger(args[1]))
			{
				Reply("usage: hwp material <gold|wood|stone|iron|crystals|dust|ore|all> <amount>");
				return;
			}
			auto plr = Me();
			if (plr is null)
				return;
			int amount = parseInt(args[1]);
			if (args[0] == "all")
			{
				for (uint i = 0; i < uint(MaterialType::Num); i++)
					plr.GiveMaterial(MaterialType(i), amount, true);
			}
			else
			{
				auto type = ParseMaterialType(args[0]);
				if (type == MaterialType::Num)
				{
					Reply("unknown material '" + args[0] + "'");
					return;
				}
				plr.GiveMaterial(type, amount, true);
			}
			Reply("gave " + amount + " " + args[0]);
		}

		void CmdLevelup(array<string>@ args)
		{
			if (!On())
				return;
			auto plr = Me();
			if (plr is null)
				return;
			int levels = max(1, IntArg(args, 0, 1));
			for (int i = 0; i < levels; i++)
			{
				int level = plr.level;
				plr.GiveExperience(plr.LevelExperience(level) - plr.LevelExperience(level - 1));
			}
			Reply("now level " + plr.level);
		}

		void CmdXp(array<string>@ args)
		{
			if (!On())
				return;
			auto plr = Me();
			if (plr is null)
				return;
			int amount = max(1, IntArg(args, 0, 100000));
			plr.GiveExperience(amount);
			Reply("gave " + amount + " xp, now level " + plr.level);
		}

		// bonus points stack on top of the per-level ones and are saved with
		// the character, like the vanilla stat/skill point pickups
		void CmdStatPoints(array<string>@ args)
		{
			if (!On())
				return;
			auto plr = Me();
			if (plr is null)
				return;
			int amount = IntArg(args, 0, 50);
			plr.bonusStatPts += amount;
			plr.SyncStatPoints();
			auto actor = cast<PlayerBase>(plr.actor);
			if (actor !is null)
				actor.RefreshModifiers();
			Reply("gave " + amount + " attribute points (" + plr.GetPlaceableStatPoints() + " to place)");
		}

		void CmdSkillPoints(array<string>@ args)
		{
			if (!On())
				return;
			auto plr = Me();
			if (plr is null)
				return;
			int amount = IntArg(args, 0, 20);
			plr.bonusSkillPts += amount;
			plr.SyncStatPoints();
			Reply("gave " + amount + " skill points (" + plr.GetFreeSkillPoints() + " free)");
		}

		void CmdEquip(array<string>@ args)
		{
			if (!On())
				return;
			if (args.length() < 1)
			{
				Reply("usage: hwp equip <equipment id>");
				return;
			}
			auto plr = Me(true);
			if (plr is null)
				return;
			auto baseItem = Equipment::BaseItem::Get(args[0]);
			if (baseItem is null)
			{
				Reply("no equipment '" + args[0] + "'");
				return;
			}
			if (!CheckGlobalConditionals(baseItem.m_conditionals))
			{
				Reply("'" + args[0] + "' is locked by its conditions");
				return;
			}
			Equipment::Generator gen;
			gen.m_ilvl = plr.level;
			gen.m_qualities = Item::Quality(int(pow(2, randi(4))));
			Item::DropItem(gen.GenerateItem(baseItem), NearMe(plr), 1, true, null);
			Reply("dropped " + args[0]);
		}

		void CmdMaps(array<string>@ args)
		{
			if (!On())
				return;
			auto plr = Me(true);
			if (plr is null)
				return;
			int count = max(1, IntArg(args, 0, 5));
			int maxDiff = IntArg(args, 1, 25);
			int dropped = 0;
			for (int i = 0; i < count; i++)
			{
				auto missions = MissionDef::FetchMissionsFromSet(plr, HashString("equipment_map"), 1, false);
				if (missions.length() <= 0)
					continue;
				auto mission = missions[randi(missions.length())];
				if (mission.m_baseDiffLevel > maxDiff)
					continue;

				Item::MissionMapDef def;
				@def.m_mission = mission;
				def.m_quality = Item::Quality::Epic;
				def.m_level = maxDiff + randi(3) - 1;
				switch (randi(8))
				{
				case 0: def.m_slot = Equipment::Slot::Hands; break;
				case 1: def.m_slot = Equipment::Slot::Back; break;
				case 2: def.m_slot = Equipment::Slot::Feet; break;
				case 3: def.m_slot = Equipment::Slot::Head; break;
				case 4: def.m_slot = Equipment::Slot::Chest; break;
				case 5: def.m_slot = Equipment::Slot::MainHand; break;
				case 6: def.m_slot = Equipment::Slot::OffHand; break;
				case 7: def.m_slot = Equipment::Slot::TwoHanded; break;
				}
				Item::DropItem(Item::MissionMap(def), NearMe(plr), 1, true, plr);
				dropped++;
			}
			Reply("dropped " + dropped + " map(s)");
		}

		void CmdFinishLevel(array<string>@ args)
		{
			if (!On())
				return;
			if (Me(true) is null)
				return;
			if (cast<MissionGameModeBase>(g_gameMode) is null)
			{
				Reply("finishlevel only works in a run");
				return;
			}
			Console::Cheats::FinishLevelCFunc();
		}

		// the next floor of this mission whose id or level file says "boss"
		// (crypt_boss, mines_boss, ...); vanilla cht_goto_level by name
		void CmdBoss(array<string>@ args)
		{
			if (!On())
				return;
			if (Me(true) is null)
				return;
			if (cast<MissionGameModeBase>(g_gameMode) is null || MissionManager::g_module is null)
			{
				Reply("boss only works in a run");
				return;
			}
			if (!Network::IsServer())
			{
				Reply("only the host can skip floors");
				return;
			}
			auto def = MissionDef::Get(MissionManager::g_module.m_missionDefHash);
			if (def is null)
				return;
			for (uint i = MissionManager::g_module.m_missionLevelIndex + 1; i < def.m_levels.length(); i++)
			{
				auto level = def.m_levels[i];
				if (level.m_id.findFirst("boss") >= 0 || level.m_level.findFirst("boss") >= 0)
				{
					Reply("going to " + level.m_id);
					MissionManager::NextLevel(level.m_id);
					return;
				}
			}
			Reply("no boss floor ahead in this mission");
		}

		void CmdKillAll(array<string>@ args)
		{
			if (!On())
				return;
			Console::Cheats::KillAllCFunc();
			Reply("killed every targetable enemy");
		}

		void CmdGod(array<string>@ args)
		{
			if (!On())
				return;
			CVars::ChtGodmode = !CVars::ChtGodmode;
			Reply("god mode " + (CVars::ChtGodmode ? "on" : "off"));
		}

		void Register()
		{
			HWP::Commands::Register("unlockflags", " (cheat) unlock the story town flags", HWP::Commands::Handler(CmdUnlockFlags));
			HWP::Commands::Register("material", "<type|all> <amount>  (cheat) give materials", HWP::Commands::Handler(CmdMaterial));
			HWP::Commands::Register("levelup", "[levels]  (cheat) gain levels", HWP::Commands::Handler(CmdLevelup));
			HWP::Commands::Register("xp", "[amount]  (cheat) gain experience, default 100000", HWP::Commands::Handler(CmdXp));
			HWP::Commands::Register("statpoints", "[n]  (cheat) gain attribute points to place, default 50", HWP::Commands::Handler(CmdStatPoints));
			HWP::Commands::Register("skillpoints", "[n]  (cheat) gain skill points, default 20", HWP::Commands::Handler(CmdSkillPoints));
			HWP::Commands::Register("equip", "<id>  (cheat) drop that equipment", HWP::Commands::Handler(CmdEquip));
			HWP::Commands::Register("spawnmaps", "[count] [level]  (cheat) drop map items", HWP::Commands::Handler(CmdMaps));
			HWP::Commands::Register("finishlevel", " (cheat) loot the floor and go to the next", HWP::Commands::Handler(CmdFinishLevel));
			HWP::Commands::Register("boss", " (cheat) skip ahead to this mission's boss floor", HWP::Commands::Handler(CmdBoss));
			HWP::Commands::Register("killall", " (cheat) kill every enemy", HWP::Commands::Handler(CmdKillAll));
			HWP::Commands::Register("god", " (cheat) toggle god mode", HWP::Commands::Handler(CmdGod));
		}
	}
}
