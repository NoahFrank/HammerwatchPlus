// Town script for tools/dev_check.py --town (dev-only module, never
// packaged). Inert unless the gitignored lang file
// res/language/english/hwp_devlevel.lang defines .hwp.dev.town as hwp
// commands separated by ";" ("wait" pauses one step). Once in town (with a
// character, see DevLevel::EnsureCharacter) it runs one command every
// STEP_MS and prints "[HWP:dev] town script done" after the last one.
namespace HWP
{
	namespace DevTown
	{
		const string KEY = ".hwp.dev.town";
		const int START_MS = 4000;
		const int STEP_MS = 1500;

		const string STEP = "hwp_dev_town_step"; // GlobalCache: script globals reset every level

		int g_ms = 0;
		int g_next = -1;   // -1: not started
		array<string> g_cmds;

		void SaveStep() { GlobalCache::Set(STEP, "" + g_next); }

		bool Active() { return Resources::HasString(KEY); }

		// 'hwp devtown build' (host, test slot): every building at its top tier,
		// then reload the town so the segments that grow with the building
		// count (the farm fields) are placed. The script carries on in the new
		// town level. Nothing on the test slot outlives the run.
		void CmdDevTown(array<string>@ args)
		{
			// 'hwp devtown level <mission> <floor>': start a floor; the script carries on there
			if (args.length() == 3 && args[0] == "level" && Network::IsServer())
			{
				HWP::DevLevel::Start(args[1] + " " + args[2]);
				return;
			}
			if (args.length() < 1 || args[0] != "build" || !Network::IsServer() || !g_inTown)
			{
				HWP::Commands::Reply("usage (host, in town): hwp devtown build");
				return;
			}
			auto tr = g_myTownRecord;
			auto defs = BuildingManagement::BuildingDef::Instances;
			int added = 0;
			for (uint i = 0; i < defs.length(); i++)
			{
				auto def = defs[i];
				if (def.m_variations.length() == 0)
					continue;
				uint top = def.m_variations.length() - 1;
				bool have = false;
				for (uint j = 0; j < tr.m_buildings.length(); j++)
				{
					if (tr.m_buildings[j].buildingDef is def)
					{
						tr.m_buildings[j].variation = top;
						have = true;
					}
				}
				if (have)
					continue;
				auto plot = tr.GetPlot(def.m_plotHash);
				if (plot !is null && !tr.IsPlotEmpty(plot))
					continue;
				tr.AddBuilding(def, plot, top);
				added++;
			}
			Log("dev", "devtown: " + added + " building(s) added, " + tr.m_buildings.length() + " at top tier; reloading town");
			ChangeLevel("levels/town.lvl");
		}

		void Tick(int ms)
		{
			// in town, or on a floor a 'devtown level' step started (the step is saved)
			if (!Active() || (!g_inTown && GlobalCache::Get(STEP).isEmpty()) || (g_next >= 0 && g_next >= int(g_cmds.length())))
				return;
			g_ms += ms;
			if (g_next < 0)
			{
				if (g_ms < START_MS || !HWP::DevLevel::EnsureCharacter())
					return;
				auto raw = Resources::GetString(KEY).split(";");
				for (uint i = 0; i < raw.length(); i++)
				{
					auto c = strTrim(raw[i]);
					if (!c.isEmpty())
						g_cmds.insertLast(c);
				}
				// resume after a level change ('devtown build' reloads the town)
				auto saved = GlobalCache::Get(STEP);
				g_next = saved.isEmpty() ? 0 : parseInt(saved);
				g_ms = STEP_MS;
				// test slot only: the debug commands (hwp material, ...) need it
				SetVar("e_cheats", true);
				Log("dev", "town script: e_cheats on, step " + g_next + "/" + g_cmds.length());
			}
			if (g_ms < STEP_MS)
				return;
			g_ms = 0;
			if (g_next < int(g_cmds.length()))
			{
				auto c = g_cmds[g_next++];
				SaveStep(); // before Handle: the command may change the level
				if (c != "wait")
				{
					Log("dev", "town> hwp " + c);
					HWP::Commands::Handle(c);
				}
			}
			if (g_next >= int(g_cmds.length()))
				Log("dev", "town script done");
		}
	}
}
