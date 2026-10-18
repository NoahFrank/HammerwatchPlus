// gamelab-probe: GameLab's command channel and read-only state probes.
//
// The harness types "gl <id> <verb> [args]" into the console (focus-free
// PostMessage to the game window, gamelab/winproc.py). Every reply is one
// "[GL] {...}" line in HWR2.exe.log carrying the same id, which the launcher
// tails. Verbs here never change game state, except the fixture verbs
// (char), which call the same functions the game's own windows call.
//
// A heartbeat line ("ev":"hb") goes out every second of gameplay frames with
// the current phase, so a hung or crashed run is detectable from the log.
//
// Module constructors run when the menu level loads, but nothing ticks until a
// gameplay session starts (docs/RE_NOTES.md, mod lifecycle). So the front door
// (main menu -> Singleplayer) is a key press, not a verb. Whether `gl` answers at
// the menu is not measured.
namespace GameLab
{
	const string VERSION = "0.1.0";

	funcdef void Verb(const string &in id, array<string>@ args);

	class Entry
	{
		string name;
		string help;
		Verb@ fn;
		Entry(const string &in n, const string &in h, Verb@ f) { name = n; help = h; @fn = f; }
	}

	array<Entry@> g_verbs;
	uint g_commands = 0;

	// other GameLab mods (gamelab-hands, gamelab-pilot) add verbs through this
	void RegisterVerb(const string &in name, const string &in help, Verb@ fn)
	{
		for (uint i = 0; i < g_verbs.length(); i++)
		{
			if (g_verbs[i].name == name)
			{
				@g_verbs[i] = Entry(name, help, fn);
				return;
			}
		}
		g_verbs.insertLast(Entry(name, help, fn));
	}

	Json@ Reply(const string &in id, bool ok)
	{
		Json j;
		j.Str("id", id).Bool("ok", ok);
		return j;
	}

	void Fail(const string &in id, const string &in error)
	{
		Emit(Reply(id, false).Str("error", error));
	}

	void ConsoleGl(cvar_t@ arg)
	{
		auto line = strTrim(arg.GetString());
		if (line.length() >= 2 && line.substr(0, 1) == "\"" && line.substr(line.length() - 1) == "\"")
			line = strTrim(line.substr(1, line.length() - 2));
		auto raw = line.split(" ");
		array<string> args;
		for (uint i = 0; i < raw.length(); i++)
		{
			if (raw[i].length() > 0)
				args.insertLast(raw[i]);
		}
		if (args.length() < 2)
		{
			Fail(args.length() > 0 ? args[0] : "", "usage: gl <id> <verb> [args]");
			return;
		}
		string id = args[0];
		string verb = args[1];
		args.removeRange(0, 2);
		g_commands++;
		RunVerb(id, verb, args);
	}

	// multi <verb> [args] + <verb> [args] + ...: run each sub-command in this frame, the k-th
	// replying under id "<id>.<k>", then one reply under <id> with the count. One typed line
	// instead of one per probe: a fixture readback is 16 probes (session.gl_multi).
	void VerbMulti(const string &in id, array<string>@ args)
	{
		uint n = 0;
		array<string> cur;
		for (uint i = 0; i <= args.length(); i++)
		{
			if (i < args.length() && args[i] != "+")
			{
				cur.insertLast(args[i]);
				continue;
			}
			if (cur.length() == 0)
				continue;
			string verb = cur[0];
			cur.removeAt(0);
			if (verb == "multi")
				Fail(id + "." + n, "multi does not nest");
			else
				RunVerb(id + "." + n, verb, cur);
			n++;
			cur.resize(0);
		}
		Emit(Reply(id, true).Int("n", n));
	}

	void RunVerb(const string &in id, const string &in verb, array<string>@ args)
	{
		for (uint i = 0; i < g_verbs.length(); i++)
		{
			if (g_verbs[i].name == verb)
			{
				// a probe must not be able to break the game: a throw becomes a failed reply
				// (the engine gives scripts no exception text, so the verb is all we can name)
				try {
					g_verbs[i].fn(id, args);
				} catch {
					g_exceptions++;
					Fail(id, "exception in verb '" + verb + "'");
				}
				return;
			}
		}
		Fail(id, "unknown verb '" + verb + "'");
	}

	uint g_exceptions = 0;
	uint g_boots = 0;        // GameLabProbeModule constructions this process (identity across levels)

	// ---- phase ----------------------------------------------------------------

	// no_record | no_character | dead | town | mission
	string Phase()
	{
		auto record = GetLocalPlayerRecord();
		if (record is null)
			return "no_record";
		if (record.playerClass is null)
			return "no_character";
		if (record.IsDead())
			return "dead";
		return g_inTown ? "town" : "mission";
	}

	string TopWindow()
	{
		auto gm = cast<BaseGameMode>(g_gameMode);
		if (gm is null || gm.m_windowManager is null)
			return "";
		auto w = gm.m_windowManager.GetCurrentWindow();
		return w is null ? "" : Reflect::GetTypeName(w);
	}

	// ---- verbs ----------------------------------------------------------------

	// ping: liveness; the probe version, phase, boot count, level and commands served.
	void VerbPing(const string &in id, array<string>@ args)
	{
		Emit(Reply(id, true).Str("version", VERSION).Str("phase", Phase()).Int("boots", g_boots)
			.Str("level", GetCurrentLevelFilename()).Int("cmds", g_commands));
	}

	// help: every registered verb and its argument signature.
	void VerbHelp(const string &in id, array<string>@ args)
	{
		array<string> names;
		for (uint i = 0; i < g_verbs.length(); i++)
			names.insertLast(g_verbs[i].name + " " + g_verbs[i].help);
		Emit(Reply(id, true).Raw("verbs", StrArray(names)));
	}

	string PlayerJson()
	{
		auto record = GetLocalPlayerRecord();
		if (record is null)
			return "null";
		Json p;
		p.Str("name", record.name);
		p.Str("class", record.playerClass is null ? "" : record.playerClass.m_id);
		int level = record.level;
		int64 xp = record.experience;
		p.Int("level", level).Int("xp", xp);
		p.Int("hp", record.CurrentHealth()).Int("hpMax", record.MaxHealth());
		p.Int("mana", record.CurrentMana()).Int("manaMax", record.MaxMana());
		p.Bool("dead", record.IsDead());
		auto plr = GetLocalPlayer();
		p.Bool("spawned", plr !is null);
		if (plr !is null)
		{
			vec3 pos = plr.m_unit.GetPosition();
			p.Num("x", pos.x).Num("y", pos.y);
		}
		return p.Close();
	}

	// state: phase, level, open window and the local player (class, level, hp, position); fixtures read back through it.
	void VerbState(const string &in id, array<string>@ args)
	{
		auto j = Reply(id, true);
		j.Str("phase", Phase());
		j.Str("level", GetCurrentLevelFilename());
		j.Bool("inTown", g_inTown);
		j.Str("window", TopWindow());
		j.Raw("player", PlayerJson());
		Emit(j);
	}

	// which resource mods the running game sees and has enabled: the live half
	// of the environment check (gamelab/env/environments.json "mods")
	void VerbMods(const string &in id, array<string>@ args)
	{
		auto mods = Platform::GetAllResourceMods();
		array<string> items;
		for (uint i = 0; i < mods.length(); i++)
		{
			Json m;
			m.Str("id", mods[i].ID).Bool("enabled", PersistentSaves::IsModEnabled(mods[i])).Bool("packed", mods[i].Packaged);
			items.insertLast(m.Close());
		}
		Emit(Reply(id, true).Raw("mods", RawArray(items)));
	}

	// open windows, bottom to top, by script class
	void VerbUi(const string &in id, array<string>@ args)
	{
		auto gm = cast<BaseGameMode>(g_gameMode);
		array<string> names;
		if (gm !is null && gm.m_windowManager !is null)
		{
			for (uint i = 0; i < gm.m_windowManager.m_objects.length(); i++)
				names.insertLast(Reflect::GetTypeName(gm.m_windowManager.m_objects[i]));
		}
		Emit(Reply(id, true).Raw("windows", StrArray(names)));
	}

	// cvars <name>...: values as the running game holds them (the loaded settings,
	// not the file on disk); the launcher's mute check reads snd_volume* here
	void VerbCvars(const string &in id, array<string>@ args)
	{
		// read each by its own type: GetVarFloat on an int cvar returns 0 (v_fps_limit,
		// measured 2026-10-17); bools as 0/1
		Json vals;
		for (uint i = 0; i < args.length(); i++)
		{
			auto t = GetVarType(args[i]);
			if (t == cvar_type::Int)
				vals.Num(args[i], float(GetVarInt(args[i])));
			else if (t == cvar_type::Bool)
				vals.Num(args[i], GetVarBool(args[i]) ? 1.0f : 0.0f);
			else
				vals.Num(args[i], GetVarFloat(args[i]));
		}
		Emit(Reply(id, true).Raw("cvars", vals.Close()));
	}

	// inv: materials as the game reads them (PlayerRecord.GetMaterial: the town's store
	// while in town, the character's own on a mission)
	void VerbInv(const string &in id, array<string>@ args)
	{
		auto record = GetLocalPlayerRecord();
		if (record is null)
		{
			Fail(id, "no local player record");
			return;
		}
		array<string> names = { "gold", "wood", "stone", "iron", "crystals", "dust", "ore" };
		Json mats;
		for (uint i = 0; i < names.length(); i++)
			mats.Int(names[i], record.GetMaterial(MaterialType(i)));
		Emit(Reply(id, true).Str("store", cast<TownGameMode>(g_gameMode) !is null ? "town" : "character")
			.Raw("materials", mats.Close()));
	}

	string UnitJson(UnitPtr u, vec2 from)
	{
		Json e;
		vec3 pos = u.GetPosition();
		e.Int("unit", u.GetId()).Str("name", u.GetDebugName());
		ref@ b = u.GetScriptBehavior();
		e.Str("behavior", b is null ? "" : Reflect::GetTypeName(b));
		e.Bool("usable", cast<IUsable>(b) !is null);
		e.Num("x", pos.x).Num("y", pos.y).Num("dist", dist(from, xy(pos)));
		return e.Close();
	}

	const uint NEAR_CAP = 64;

	// near [radius] [filter]: units within radius (default 200) of the player,
	// nearest first, capped at NEAR_CAP; "truncated" reports how many were left out
	void VerbNear(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		int radius = args.length() > 0 ? int(parseInt(args[0])) : 200;
		string filter = args.length() > 1 ? args[1] : "";
		vec2 center = xy(plr.m_unit.GetPosition());
		auto units = g_scene.FetchAllUnits(~0, center, radius);
		array<UnitPtr> keep;
		array<float> dists;
		for (uint i = 0; i < units.length(); i++)
		{
			if (!units[i].IsValid() || units[i].IsDestroyed() || units[i] == plr.m_unit)
				continue;
			ref@ b = units[i].GetScriptBehavior();
			// the filter matches the behavior's type name or the unit's debug name (its .unit path)
			if (filter != "" && (b is null || Reflect::GetTypeName(b).findFirst(filter) < 0)
				&& units[i].GetDebugName().findFirst(filter) < 0)
				continue;
			float d = dist(center, xy(units[i].GetPosition()));
			uint at = 0;
			while (at < dists.length() && dists[at] <= d)
				at++;
			keep.insertAt(at, units[i]);
			dists.insertAt(at, d);
		}
		array<string> items;
		for (uint i = 0; i < keep.length() && i < NEAR_CAP; i++)
			items.insertLast(UnitJson(keep[i], center));
		int truncated = keep.length() > NEAR_CAP ? int(keep.length() - NEAR_CAP) : 0;
		Emit(Reply(id, true).Int("radius", radius).Int("count", keep.length()).Int("truncated", truncated)
			.Raw("units", RawArray(items)));
	}

	// usables: what the player could interact with right now, top (the one Use acts on) first
	void VerbUsables(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		vec2 center = xy(plr.m_unit.GetPosition());
		auto top = plr.GetTopUsable();
		array<string> items;
		for (uint i = 0; i < plr.m_usables.length(); i++)
		{
			auto usable = plr.m_usables[i].m_usable;
			Json u;
			u.Raw("unit", UnitJson(usable.GetUseUnit(), center)).Bool("canUse", usable.CanUse(plr)).Bool("top", usable is top);
			items.insertLast(u.Close());
		}
		Emit(Reply(id, true).Raw("usables", RawArray(items)));
	}

	// overlays: everything drawn over the world at this moment, so a scenario can require
	// the set to be empty or expected (repro playbook 1.3). Windows (bottom to top), the
	// tutorial panel (Tutorials::TutorialModule.m_showing, drawn by HUDTutorials), live
	// announce / loot-log entries (HUDAnnounce subclasses, style id + text) and the
	// boss bar. HUD notifications are not listed: HoH2's AddNotification is a stub
	// ("TODO: Add notifications", WorldScript/GUI/AddNotification.as).
	void VerbOverlays(const string &in id, array<string>@ args)
	{
		auto j = Reply(id, true);
		auto gm = cast<BaseGameMode>(g_gameMode);
		array<string> windows;
		if (gm !is null && gm.m_windowManager !is null)
		{
			for (uint i = 0; i < gm.m_windowManager.m_objects.length(); i++)
				windows.insertLast(Reflect::GetTypeName(gm.m_windowManager.m_objects[i]));
		}
		j.Raw("windows", StrArray(windows));
		string tutorial = "";
		auto agm = cast<AGameplayGameMode>(g_gameMode);
		if (agm !is null)
		{
			for (uint i = 0; i < agm.m_modules.length(); i++)
			{
				auto tutMod = cast<Tutorials::TutorialModule>(agm.m_modules[i]);
				if (tutMod !is null && tutMod.m_showing !is null)
					tutorial = tutMod.m_showing.m_id;
			}
		}
		j.Str("tutorial", tutorial);
		array<string> announces;
		bool bossBar = false;
		auto hud = GetHUD();
		if (hud !is null)
		{
			for (uint i = 0; i < hud.m_components.length(); i++)
			{
				auto comp = hud.m_components[i];
				auto ann = cast<HUDAnnounce>(comp);
				if (ann !is null && comp.m_visible)
				{
					for (uint k = 0; k < ann.m_announceObjects.length(); k++)
					{
						auto obj = ann.m_announceObjects[k];
						if (obj is null)
							continue;
						Json a;
						a.Str("hud", Reflect::GetTypeName(comp)).Str("style", obj.m_style is null ? "" : obj.m_style.m_id);
						auto txt = cast<HUDAnnounceText>(obj);
						a.Str("text", txt is null ? "" : txt.m_textStr);
						announces.insertLast(a.Close());
					}
				}
				auto boss = cast<HUDBossBar>(comp);
				if (boss !is null && comp.m_visible && boss.m_barList !is null && boss.m_barList.m_children.length() > 0)
					bossBar = true;
			}
		}
		j.Raw("announces", RawArray(announces));
		j.Bool("bossBar", bossBar);
		Emit(j);
	}

	// buildings: the current town record's buildings (id -> variation), as the town
	// builder and the gambler read them (TownRecord.GetVariationOnBuilding)
	void VerbBuildings(const string &in id, array<string>@ args)
	{
		if (g_currTownRecord is null)
		{
			Fail(id, "no town record");
			return;
		}
		Json b;
		for (uint i = 0; i < g_currTownRecord.m_buildings.length(); i++)
		{
			auto def = g_currTownRecord.m_buildings[i].buildingDef;
			if (def !is null)
				b.Int(def.m_id, g_currTownRecord.m_buildings[i].variation);
		}
		Emit(Reply(id, true).Int("count", g_currTownRecord.m_buildings.length()).Raw("buildings", b.Close()));
	}

	// clock: scene time (g_scene.GetTime(), what behaviours time themselves with), the
	// probe's own frame count, and the time-scale / hour cvars
	uint g_frames = 0;
	void VerbClock(const string &in id, array<string>@ args)
	{
		Emit(Reply(id, true).Int("sceneMs", g_scene is null ? -1 : int(g_scene.GetTime())).Int("frames", g_frames)
			.Num("timescale", GetVarFloat("g_timescale")).Int("hour", GetVarInt("g_time_hour")));
	}

	const uint WIDGET_CAP = 400;

	// widgets [depth]: the UI widget tree of every open window (top last) and the HUD,
	// depth-first, capped at WIDGET_CAP nodes and `depth` levels (default 6); reports
	// truncation. Per node: depth, script class, id, visible, size, text (TextWidget).
	int g_widgetCut = 0;    // nodes left out by the current widgets call

	void WidgetNodes(Widget@ w, int depth, int maxDepth, array<string>@ acc)
	{
		if (w is null)
			return;
		if (acc.length() >= WIDGET_CAP)
		{
			g_widgetCut++;
			return;
		}
		Json n;
		n.Int("d", depth).Str("type", Reflect::GetTypeName(w)).Str("id", w.m_id).Bool("visible", w.m_visible)
			.Int("w", w.m_width).Int("h", w.m_height);
		auto t = cast<TextWidget>(w);
		if (t !is null)
			n.Str("text", t.m_str);
		acc.insertLast(n.Close());
		if (w.m_children is null)
			return;
		if (depth >= maxDepth)
		{
			g_widgetCut += w.m_children.length();
			return;
		}
		for (uint i = 0; i < w.m_children.length(); i++)
			WidgetNodes(w.m_children[i], depth + 1, maxDepth, acc);
	}

	// widgets [depth]: the UI widget tree of every open window and the HUD, capped, with truncation reported.
	void VerbWidgets(const string &in id, array<string>@ args)
	{
		int maxDepth = args.length() > 0 ? int(parseInt(args[0])) : 6;
		array<string> roots;
		g_widgetCut = 0;
		auto gm = cast<BaseGameMode>(g_gameMode);
		if (gm !is null && gm.m_windowManager !is null)
		{
			for (uint i = 0; i < gm.m_windowManager.m_objects.length(); i++)
			{
				auto win = cast<IWidgetHoster>(gm.m_windowManager.m_objects[i]);
				array<string> nodes;
				if (win !is null)
					WidgetNodes(win.m_widget, 0, maxDepth, nodes);
				Json r;
				r.Str("root", Reflect::GetTypeName(gm.m_windowManager.m_objects[i])).Raw("nodes", RawArray(nodes));
				roots.insertLast(r.Close());
			}
		}
		auto hud = GetHUD();
		if (hud !is null)
		{
			array<string> nodes;
			WidgetNodes(hud.m_widget, 0, maxDepth, nodes);
			Json r;
			r.Str("root", "HUD").Raw("nodes", RawArray(nodes));
			roots.insertLast(r.Close());
			// each HUD component hosts its own tree (HUD.m_components, GUI/HUD/HUD.as)
			for (uint i = 0; i < hud.m_components.length(); i++)
			{
				array<string> cnodes;
				WidgetNodes(hud.m_components[i].m_widget, 0, maxDepth, cnodes);
				Json cr;
				cr.Str("root", "HUD:" + Reflect::GetTypeName(hud.m_components[i])).Bool("visible", hud.m_components[i].m_visible)
					.Raw("nodes", RawArray(cnodes));
				roots.insertLast(cr.Close());
			}
		}
		Emit(Reply(id, true).Int("depth", maxDepth).Int("truncated", g_widgetCut).Raw("roots", RawArray(roots)));
	}

	const int TERRAIN_CELLS = 48;

	// terrain [radius] [step]: occupancy grid around the player from the game's own point
	// query (g_scene.QueryRect(pos, 1, 1, ~0, RaycastType::Any), the test SpawnPrefab uses
	// for "can something stand here"). Rows north to south: '.' free, '#' blocked,
	// '@' the player. At most TERRAIN_CELLS x TERRAIN_CELLS; "truncated" when clipped.
	void VerbTerrain(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		int radius = args.length() > 0 ? int(parseInt(args[0])) : 160;
		int step = args.length() > 1 ? max(4, int(parseInt(args[1]))) : 16;
		int n = radius * 2 / step + 1;
		bool truncated = n > TERRAIN_CELLS;
		if (truncated)
			n = TERRAIN_CELLS;
		vec2 c = xy(plr.m_unit.GetPosition());
		array<string> rows;
		int blocked = 0;
		for (int y = 0; y < n; y++)
		{
			string row = "";
			for (int x = 0; x < n; x++)
			{
				vec2 p = c + vec2(float((x - n / 2) * step), float((y - n / 2) * step));
				if (x == n / 2 && y == n / 2)
				{
					row += "@";
					continue;
				}
				auto hits = g_scene.QueryRect(p, 1, 1, ~0, RaycastType::Any);
				bool solid = false;
				for (uint i = 0; i < hits.length() && !solid; i++)
					solid = hits[i] != plr.m_unit;
				if (solid)
					blocked++;
				row += solid ? "#" : ".";
			}
			rows.insertLast(row);
		}
		Emit(Reply(id, true).Num("x", c.x).Num("y", c.y).Int("step", step).Int("size", n).Int("blocked", blocked)
			.Bool("truncated", truncated).Raw("rows", StrArray(rows)));
	}

	const uint MEMBERS_CAP = 200;

	// members <TypeName>: the script type's properties (name + type) through the engine's
	// reflection (Reflect::GetType / TypeInfo.GetProperties). Read-only by construction:
	// it never touches an instance. Capped at MEMBERS_CAP; reports truncation.
	void VerbMembers(const string &in id, array<string>@ args)
	{
		if (args.length() < 1)
		{
			Fail(id, "usage: members <TypeName>");
			return;
		}
		auto t = Reflect::GetType(args[0]);
		if (t is null)
		{
			Fail(id, "no script type '" + args[0] + "'");
			return;
		}
		auto props = t.GetProperties();
		array<string> items;
		for (uint i = 0; i < props.length() && i < MEMBERS_CAP; i++)
		{
			Json p;
			auto pt = props[i].GetType();
			p.Str("name", props[i].GetName()).Str("type", pt is null ? "primitive" : pt.GetName());
			items.insertLast(p.Close());
		}
		auto base = t.GetBaseType();
		Emit(Reply(id, true).Str("type", t.GetName()).Str("base", base is null ? "" : base.GetName())
			.Int("count", props.length()).Int("truncated", props.length() > MEMBERS_CAP ? int(props.length() - MEMBERS_CAP) : 0)
			.Raw("members", RawArray(items)));
	}

	// inspect <root> [dotted.path]: a live record as the game itself serializes it.
	// Reflection has no value getter (members lists names only), so the value side goes
	// through the record's own Save(SValueBuilder), the same call SavePlayerAndTown makes:
	//   player -> GetLocalPlayerRecord().Save   (only reads fields and prints a log line)
	//   town   -> g_currTownRecord.Save         (also runs the TownRecordSave hook)
	// Nothing is written: the built SValue is never handed to PersistentSaves.
	// Path segments are dictionary keys or array indices ("inventory.0.id"). Output is
	// capped at INSPECT_CAP characters; past that only the keys / length come back.
	const uint INSPECT_CAP = 4000;

	SValue@ InspectRoot(const string &in root, string &out err)
	{
		SValueBuilder builder;
		if (root == "player")
		{
			auto plr = GetLocalPlayerRecord();
			if (plr is null)
			{
				err = "no local player record";
				return null;
			}
			builder.PushDictionary();
			plr.Save(builder);
			builder.PopDictionary();
			return builder.Build();
		}
		if (root == "town")
		{
			if (g_currTownRecord is null)
			{
				err = "no town record";
				return null;
			}
			if (!g_currTownRecord.Save(builder))
			{
				err = "town record is empty (Save returned false)";
				return null;
			}
			return builder.Build();
		}
		err = "unknown root '" + root + "' (player, town)";
		return null;
	}

	// inspect <player|town> [dotted.path]: read-only. A field of the player or town save record by dotted path, JSON-encoded, capped.
	void VerbInspect(const string &in id, array<string>@ args)
	{
		if (args.length() < 1)
		{
			Fail(id, "usage: inspect <player|town> [dotted.path]");
			return;
		}
		string err;
		SValue@ sv = InspectRoot(args[0], err);
		if (sv is null)
		{
			Fail(id, err);
			return;
		}
		string path = args.length() > 1 ? args[1] : "";
		array<string>@ segs = path.length() > 0 ? path.split(".") : array<string>();
		for (uint i = 0; i < segs.length(); i++)
		{
			auto t = sv.GetType();
			SValue@ next = null;
			if (t == SValueType::Dictionary)
				@next = sv.GetDictionaryEntry(segs[i]);
			else if (t == SValueType::Array)
			{
				int k = parseInt(segs[i]);
				auto arr = sv.GetArray();
				if (k >= 0 && uint(k) < arr.length())
					@next = arr[k];
			}
			if (next is null)
			{
				Fail(id, "no '" + segs[i] + "' at path segment " + i + " of '" + path + "'");
				return;
			}
			@sv = next;
		}
		string text = SvalJson(sv, 0);
		auto j = Reply(id, true).Str("root", args[0]).Str("path", path).Int("chars", text.length());
		auto t = sv.GetType();
		if (t == SValueType::Dictionary)
		{
			auto keys = sv.GetDictionaryKeys();
			keys.sortAsc();
			j.Raw("keys", StrArray(keys));
		}
		else if (t == SValueType::Array)
			j.Int("length", sv.GetArray().length());
		if (text.length() <= INSPECT_CAP)
			j.Raw("value", text).Bool("truncated", false);
		else
			j.Bool("truncated", true);
		Emit(j);
	}

	// selftest-throw: dereferences null on purpose; proves ConsoleGl's catch (playbook 1.4)
	void VerbSelftestThrow(const string &in id, array<string>@ args)
	{
		PlayerRecord@ none = null;
		Emit(Reply(id, true).Str("name", none.name));
	}

	// player classes the fixture recipes can name
	void VerbClasses(const string &in id, array<string>@ args)
	{
		array<string> names;
		for (uint i = 0; i < PlayerClass::Instances.length(); i++)
		{
			if (PlayerClass::Instances[i].parent == 0)
				names.insertLast(PlayerClass::Instances[i].m_id);
		}
		Emit(Reply(id, true).Raw("classes", StrArray(names)));
	}

	// fixture verb: char <classId> <name>
	// The same steps as CreateCharacterWindow's "create" (GUI/CreateCharacterWindow.as),
	// minus the portrait/colour pickers, which CreateCharacter defaults.
	void VerbChar(const string &in id, array<string>@ args)
	{
		if (args.length() < 2)
		{
			Fail(id, "usage: char <classId> <name>");
			return;
		}
		auto gm = cast<AGameplayGameMode>(g_gameMode);
		if (gm is null)
		{
			Fail(id, "not in a gameplay game mode");
			return;
		}
		auto pClass = PlayerClass::Get(HashString(args[0]));
		if (pClass is null)
		{
			Fail(id, "no player class '" + args[0] + "' (gl <id> classes)");
			return;
		}
		if (PlayerVoice::Instances.length() == 0)
		{
			Fail(id, "no player voices loaded");
			return;
		}
		gm.SavePlayerAndTown();
		PlayerRecord@ plr = null;
		for (uint i = 0; i < g_players.length(); i++)
		{
			if (g_players[i].peer == 255 || !g_players[i].local)
				continue;
			@g_players[i] = PlayerRecord(g_players[i]);
			@plr = g_players[i];
			break;
		}
		if (plr is null)
		{
			Fail(id, "no local player record");
			return;
		}
		plr.CreateCharacter(pClass, args[1], PlayerVoice::Instances[0]);
		gm.SpawnLocalPlayers();
		gm.m_windowManager.QueueClear();
		GetHUD().RefreshPortrait(plr);
		Emit(Reply(id, true).Str("class", pClass.m_id).Str("name", args[1]));
	}

	void RegisterBuiltins()
	{
		AddFunction("gl", { cvar_type::String }, ConsoleGl, 0, "GameLab command channel: gl <id> <verb> [args]");
		RegisterVerb("ping", "", Verb(VerbPing));
		RegisterVerb("multi", "<verb> [args] + <verb> [args] ...", Verb(VerbMulti));
		RegisterVerb("help", "", Verb(VerbHelp));
		RegisterVerb("state", "", Verb(VerbState));
		RegisterVerb("mods", "", Verb(VerbMods));
		RegisterVerb("ui", "", Verb(VerbUi));
		RegisterVerb("overlays", "", Verb(VerbOverlays));
		RegisterVerb("buildings", "", Verb(VerbBuildings));
		RegisterVerb("clock", "", Verb(VerbClock));
		RegisterVerb("widgets", "[depth]", Verb(VerbWidgets));
		RegisterVerb("terrain", "[radius] [step]", Verb(VerbTerrain));
		RegisterVerb("members", "<TypeName>", Verb(VerbMembers));
		RegisterVerb("inspect", "<player|town> [dotted.path]", Verb(VerbInspect));
		RegisterVerb("selftest-throw", "", Verb(VerbSelftestThrow));
		RegisterVerb("classes", "", Verb(VerbClasses));
		RegisterVerb("cvars", "<name>...", Verb(VerbCvars));
		RegisterVerb("inv", "", Verb(VerbInv));
		RegisterVerb("near", "[radius] [behaviorOrUnitName]", Verb(VerbNear));
		RegisterVerb("usables", "", Verb(VerbUsables));
		RegisterVerb("sval", "<file.sval>", Verb(VerbSval));
		RegisterVerb("char", "<classId> <name>", Verb(VerbChar));
	}
}

namespace Modules
{
	class GameLabProbeModule : Module
	{
		int m_sinceBeat = 0;
		uint m_frames = 0;
		uint m_beats = 0;

		GameLabProbeModule()
		{
			super("gamelab-probe");
			GameLab::RegisterBuiltins();
			GameLab::g_boots++;
			GameLab::Json j;
			j.Str("ev", "boot").Int("n", GameLab::g_boots).Str("version", GameLab::VERSION).Str("level", GetCurrentLevelFilename());
			GameLab::Emit(j);
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			m_frames++;
			GameLab::g_frames++;
			m_sinceBeat += ms;
			if (m_sinceBeat < 1000)
				return;
			m_sinceBeat = 0;
			m_beats++;
			// the heartbeat must not be able to break the frame (repro playbook 1.4)
			try {
				GameLab::Json j;
				j.Str("ev", "hb").Int("n", m_beats).Int("frames", m_frames).Str("phase", GameLab::Phase())
					.Str("window", GameLab::TopWindow()).Bool("paused", paused).Int("cmds", GameLab::g_commands)
					.Int("exceptions", GameLab::g_exceptions);
				GameLab::Emit(j);
			} catch {
				GameLab::g_exceptions++;
			}
		}
	}
}
