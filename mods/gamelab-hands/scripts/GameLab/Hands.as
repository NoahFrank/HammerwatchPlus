// gamelab-hands: action verbs for the gl channel. Each verb calls the function
// the game's own UI calls for the same action, never a screen coordinate.
namespace GameLab
{
	// mission <missionId> [floorIndex]: what the mission board's start does
	// (MissionManager::SetMission + StartMission); floor 0 when omitted.
	void VerbMission(const string &in id, array<string>@ args)
	{
		if (args.length() < 1)
		{
			Fail(id, "usage: mission <missionId> [floorIndex]");
			return;
		}
		auto def = MissionDef::Get(args[0]);
		if (def is null)
		{
			Fail(id, "no mission '" + args[0] + "'");
			return;
		}
		int floor = args.length() > 1 ? int(parseInt(args[1])) : 0;
		if (floor < 0 || floor >= int(def.m_levels.length()))
		{
			Fail(id, "mission '" + args[0] + "' has " + def.m_levels.length() + " floor(s)");
			return;
		}
		Emit(Reply(id, true).Str("mission", args[0]).Int("floor", floor).Str("level", def.m_levels[floor].m_level));
		MissionManager::SetMission(HashString(args[0]), randi());
		MissionManager::g_module.m_missionLevelIndex = floor;
		MissionManager::g_module.StartMission();
	}
}

namespace GameLab
{
	// pick [index]: play the index-th character of the open PickCharacterWindow,
	// through the window's own handler (OnFunc "play <key>"), like a click on Play.
	void VerbPick(const string &in id, array<string>@ args)
	{
		auto gm = cast<BaseGameMode>(g_gameMode);
		PickCharacterWindow@ win = null;
		if (gm !is null && gm.m_windowManager !is null)
		{
			for (uint i = 0; i < gm.m_windowManager.m_objects.length() && win is null; i++)
				@win = cast<PickCharacterWindow>(gm.m_windowManager.m_objects[i]);
		}
		if (win is null)
		{
			Fail(id, "PickCharacterWindow is not open (window: " + TopWindow() + ")");
			return;
		}
		int index = args.length() > 0 ? int(parseInt(args[0])) : 0;
		if (index < 0 || index >= int(win.m_list.m_children.length()))
		{
			Fail(id, "no character slot " + index + " (" + win.m_list.m_children.length() + " listed)");
			return;
		}
		auto slot = cast<CharacterPickWidget>(win.m_list.m_children[index]);
		if (slot is null)
		{
			Fail(id, "slot " + index + " is not a CharacterPickWidget");
			return;
		}
		uint key = slot.m_idHash;
		// A character saved inside a mission level gets the "run-resume" dialog
		// (PickCharacterWindow "play"). Answer it through the window's own handler instead:
		// "town" (default) = No, back to town; "resume" = Yes, back into the run.
		string choice = args.length() > 1 ? args[1] : "town";
		string run = PersistentSaves::GetCharacterLevelSaveName(key);
		Emit(Reply(id, true).Int("index", index).Int("key", key).Str("run", run).Str("choice", run.isEmpty() ? "" : choice));
		if (run.isEmpty() || !Network::IsServer())
		{
			win.OnFunc(slot, "play " + key);
			return;
		}
		win.m_resumingCharKey = key;
		win.OnFunc(slot, "run-resume " + (choice == "resume" ? "yes" : "no"));
	}
}

namespace GameLab
{
	// spawn <unitFile> <dx> <dy>: produce a unit at the player's position + (dx, dy),
	// the same UnitProducer.Produce call level scripts and actions use
	void VerbSpawn(const string &in id, array<string>@ args)
	{
		if (args.length() < 3)
		{
			Fail(id, "usage: spawn <unitFile> <dx> <dy>");
			return;
		}
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		auto prod = Resources::GetUnitProducer(args[0]);
		if (prod is null)
		{
			Fail(id, "no unit '" + args[0] + "'");
			return;
		}
		vec3 pos = plr.m_unit.GetPosition() + vec3(parseFloat(args[1]), parseFloat(args[2]), 0);
		UnitPtr u = prod.Produce(g_scene, pos);
		if (!u.IsValid())
		{
			Fail(id, "Produce returned an invalid unit");
			return;
		}
		Emit(Reply(id, true).Int("unit", u.GetId()).Str("name", u.GetDebugName()).Num("x", pos.x).Num("y", pos.y));
	}
}

namespace GameLab
{
	// build <buildingId>: what the town builder's "new" does (BuildingBuilderContent.Buy,
	// Town/BuildingBuilder.as) minus the cost and the cutscene: AddBuilding on a
	// buildable plot of the building's plot type (the first, where the game picks one
	// at random), then SavePlayerAndTown
	void VerbBuild(const string &in id, array<string>@ args)
	{
		if (args.length() < 1)
		{
			Fail(id, "usage: build <buildingId>");
			return;
		}
		auto gm = cast<AGameplayGameMode>(g_gameMode);
		if (gm is null || g_myTownRecord is null || !g_inTown)
		{
			Fail(id, "not in town");
			return;
		}
		auto def = BuildingManagement::BuildingDef::Get(HashString(args[0]));
		if (def is null)
		{
			Fail(id, "no building '" + args[0] + "'");
			return;
		}
		if (g_myTownRecord.GetVariationOnBuilding(def.m_idHash) >= 0)
		{
			Emit(Reply(id, true).Str("building", args[0]).Bool("existed", true));
			return;
		}
		WorldScript::BuildingPlot@ plot = null;
		if (def.m_plotHash != 0)
		{
			for (uint i = 0; i < g_myTownRecord.m_plots.length() && plot is null; i++)
			{
				if (def.m_plotHash == g_myTownRecord.m_plots[i].m_plotDefHash && g_myTownRecord.m_plots[i].IsBuildable())
					@plot = g_myTownRecord.m_plots[i];
			}
			if (plot is null)
			{
				Fail(id, "no buildable plot for '" + args[0] + "'");
				return;
			}
		}
		g_myTownRecord.AddBuilding(def, plot);
		gm.SavePlayerAndTown();
		Emit(Reply(id, true).Str("building", args[0]).Bool("existed", false)
			.Int("variation", g_myTownRecord.GetVariationOnBuilding(def.m_idHash)));
	}

	// save: the game's own SavePlayerAndTown (what the builder, the shops and leaving
	// town call), so the next session loads this town instead of a null one
	void VerbSave(const string &in id, array<string>@ args)
	{
		auto gm = cast<AGameplayGameMode>(g_gameMode);
		if (gm is null)
		{
			Fail(id, "not in a gameplay game mode");
			return;
		}
		gm.SavePlayerAndTown();
		Emit(Reply(id, true));
	}
}

namespace Modules
{
	class GameLabHandsModule : Module
	{
		GameLabHandsModule()
		{
			super("gamelab-hands");
			GameLab::RegisterVerb("spawn", "<unitFile> <dx> <dy>", GameLab::Verb(GameLab::VerbSpawn));
			GameLab::RegisterVerb("pick", "[index] [town|resume]", GameLab::Verb(GameLab::VerbPick));
			GameLab::RegisterVerb("mission", "<missionId> [floorIndex]", GameLab::Verb(GameLab::VerbMission));
			GameLab::RegisterVerb("build", "<buildingId>", GameLab::Verb(GameLab::VerbBuild));
			GameLab::RegisterVerb("save", "", GameLab::Verb(GameLab::VerbSave));
			GameLab::RegisterVerb("xp", "<amount>", GameLab::Verb(GameLab::VerbXp));
			GameLab::RegisterVerb("material", "<type> <n>", GameLab::Verb(GameLab::VerbMaterial));
			GameLab::RegisterVerb("charflag", "<name>", GameLab::Verb(GameLab::VerbCharFlag));
			GameLab::RegisterVerb("assign", "<str|dex|int|foc|vit> <n|all>", GameLab::Verb(GameLab::VerbAssign));
			GameLab::RegisterVerb("upgrade", "<shopId> <upgradeId> <step>", GameLab::Verb(GameLab::VerbUpgrade));
			GameLab::RegisterVerb("equip", "<baseItemId> <quality> [ilvl]", GameLab::Verb(GameLab::VerbEquip));
			GameLab::RegisterVerb("timescale", "<x>", GameLab::Verb(GameLab::VerbTimescale));
			GameLab::RegisterVerb("cull", "", GameLab::Verb(GameLab::VerbCull));
			GameLab::RegisterVerb("teleport", "<x> <y>", GameLab::Verb(GameLab::VerbTeleport));
			GameLab::RegisterVerb("controller", "", GameLab::Verb(GameLab::VerbController));
			GameLab::RegisterVerb("input", "<ms> <mx> <my> [aimX aimY] [button,button]", GameLab::Verb(GameLab::VerbInput));
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			GameLab::SeeInput(gameInput);
			if (!paused)
				GameLab::ApplyHeld(ms, gameInput);
		}
	}
}
