// gamelab-pilot: the player bot's in-engine half. gamelab/pilot.py drives it.
//
// One intent runs at a time, stepped from GameLabPilotModule.UpdateFrame. It steers
// through the emulated controller in gamelab-hands (GameLab::WriteInput: GameInput.MoveDir,
// AimDir, buttons), so the player's own code moves, attacks and uses things. No OS input.
//
//   gl <id> pilot <intent> [args] [until=a,b:50] [timeout=ms]
//     intents: move x y [tol] | path_to x y [tol] | attack <unit|nearest> (actor or Breakable) | kite <unit|nearest> [range]
//              | use [unit] | potion | wait ms | exit
//   gl <id> pilot pause | resume | step [frames] | target <unit> | stop | status
//   gl <id> scan [radius]
//
// The verb replies at once ({"accepted": intent}). The intent's end is one event with the
// same id: {"ev":"pilot","id":...,"result":"done|failed|timeout|interrupted|no_route","reason":...}.
// While an intent runs, {"ev":"ptick","tick":n,...} goes out every PTICK_EVERY frames; the tick
// number is what watch-mode feedback cites.
//
// Interrupts are a closed vocabulary (INTERRUPTS); anything else is refused. level_changed
// cannot fire in here: a level load reloads the script module and this state with it
// (docs/RE_NOTES.md), so gamelab/pilot.py reports it from the probe's boot event.
namespace GameLab
{
	const array<string> INTERRUPTS = { "hp_below", "under_attack", "target_dead", "level_changed", "menu_open", "dead" };
	const array<string> INTENTS = { "move", "path_to", "attack", "kite", "use", "potion", "wait", "exit" };
	const int PTICK_EVERY = 6;
	const int PATH_DIAMETER = 12;
	const float MELEE_RANGE = 22.0f;
	const int ENGAGE = 180;        // attack/kite "nearest" retargets only this close; none left = done

	class PilotIntent
	{
		string id;
		string kind;
		vec2 goal;
		float tol = 10.0f;
		array<vec2>@ path;
		uint wp = 0;
		UnitPtr target;
		bool nearest = false;
		float range = 0;
		int timeoutMs = 30000;
		int elapsed = 0;
		array<string> until;
		float hpBelow = -1;
		int prevHp = -1;
		int pulses = 0;
		int sincePulse = 100000;
		int sincePath = 100000;
		int sinceDash = 100000;
		bool approaching = false;      // attack/kite: closing in on the target this frame
		vec2 lastPos;                  // FollowPath: last frame's position (the slide test)
		bool escaped = false;
		bool partial = false;          // exit: the path ends at the reached point nearest the exit
		int partialHops = 0;          // exit: the route starts at a RouteStart point, not here
		int wiggleMs = 0;              // exit: stepping out of a wedge before routing again
		vec2 wiggleDir;
		array<int> skip;               // attack/kite "nearest": targets given up on (unreachable)
		int potionsUsed0 = 0;
		vec2 stuckFrom;
		int stuckMs = 0;
		int repaths = 0;
		int frames = 0;
		vec2 anchor;                   // exit: where to stand (the area sensor; ExitStandPoint)
		WorldScript@ exitWs;
		bool areaFound = false;
		bool pushing = false;          // exit: at the approach point, steering into the area
		vec2 approach;                 // exit: walkable point nearest the anchor
		bool hasApproach = false;
		bool nav = false;              // exit: the route came from NavRoute
		int navExpanded = 0;
	}

	PilotIntent@ g_intent;
	bool g_pilotPaused = false;
	int g_pilotSteps = 0;          // frames to run while paused (step)
	uint g_tick = 0;               // pilot frames run in this level (a level load resets it)

	Actor@ ActorOf(UnitPtr u)
	{
		if (!u.IsValid() || u.IsDestroyed())
			return null;
		return cast<Actor>(u.GetScriptBehavior());
	}

	// an actor until it dies, or a Breakable until it is destroyed: debris piles are static
	// collision with no nav-block opt-out, so they close passages until smashed (floor-soak
	// 20261017-192513: castle_debris_pile_wood_noloot at 0,904 beside the cut at -125,971)
	bool TargetGone(UnitPtr u)
	{
		if (!u.IsValid() || u.IsDestroyed())
			return true;
		auto a = ActorOf(u);
		if (a !is null)
			return a.IsDead();
		return cast<Breakable>(u.GetScriptBehavior()) is null;
	}

	UnitPtr NearestEnemy(vec2 from, int radius, array<int>@ skip = null)
	{
		auto units = g_scene.FetchActorsWithOtherTeam(g_team_player, from, radius);
		UnitPtr best;
		float bestD = 1e9;
		for (uint i = 0; i < units.length(); i++)
		{
			auto a = ActorOf(units[i]);
			if (a is null || a.IsDead() || !a.IsTargetable())
				continue;
			if (skip !is null && skip.find(units[i].GetId()) >= 0)
				continue;
			float d = dist(from, xy(units[i].GetPosition()));
			if (d < bestD)
			{
				bestD = d;
				best = units[i];
			}
		}
		return best;
	}

	// Where to stand to take an exit. A LevelExitAreaNext fires only for a player inside one
	// of its CollisionAreas, and the area is not at the exit unit: on dark_citadel floor 0 it is
	// a sensor 140 units off (unit + (-72,-120)); standing on the unit is outside it, standing
	// on the sensor is inside, the exit is the top usable and Use loads the next floor
	// (exit-areas 20261017-162406, -162451; pilot-crosslevel 20261017-161523 stood on the unit
	// for 6 minutes). The area exposes no position, so: the centroid of the units it reports
	// inside, then the sensor unit (QueryCircle getSensors) nearest that centroid.
	vec2 ExitStandPoint(WorldScript@ ws, bool &out found)
	{
		vec2 at = xy(ws.GetUnit().GetPosition());
		found = false;
		auto ex = cast<WorldScript::LevelExitAreaNext>(ws.GetUnit().GetScriptBehavior());
		if (ex is null || ex.Areas is null)
			return at;
		vec2 c;
		int n = 0;
		for (uint i = 0; i < ex.Areas.length(); i++)
		{
			if (ex.Areas[i] is null)
				continue;
			auto inside = ex.Areas[i].FetchAllInside(g_scene);
			for (uint k = 0; inside !is null && k < inside.length(); k++)
			{
				if (!inside[k].IsValid() || inside[k].GetId() == 0)
					continue;
				c += xy(inside[k].GetPosition());
				n++;
			}
		}
		if (n == 0)
			return at;
		c = c / float(n);
		auto withS = g_scene.QueryCircle(at, 600, ~0, RaycastType::Any, true);
		auto without = g_scene.QueryCircle(at, 600, ~0, RaycastType::Any, false);
		vec2 best = c;
		float bestD = 1e9;
		for (uint i = 0; i < withS.length(); i++)
		{
			if (withS[i].GetDebugName().findFirst(":Physics") != 0)
				continue;
			bool plain = false;
			for (uint k = 0; k < without.length() && !plain; k++)
				plain = without[k] == withS[i];
			if (plain)
				continue;
			float d = dist(c, xy(withS[i].GetPosition()));
			if (d < bestD)
			{
				bestD = d;
				best = xy(withS[i].GetPosition());
			}
		}
		found = true;
		return best;
	}

	bool InExitArea(WorldScript@ ws, UnitPtr u)
	{
		auto ex = cast<WorldScript::LevelExitAreaNext>(ws.GetUnit().GetScriptBehavior());
		if (ex is null || ex.Areas is null)
			return false;
		for (uint i = 0; i < ex.Areas.length(); i++)
			if (ex.Areas[i] !is null && ex.Areas[i].IsInside(u))
				return true;
		return false;
	}

	WorldScript@ NearestExit(vec2 from)
	{
		WorldScript@ best = null;
		float bestD = 1e9;
		array<string> types = { "LevelExitAreaNext", "LevelExitNext" };
		for (uint t = 0; t < types.length(); t++)
		{
			auto list = g_scene.FetchAllWorldScripts(types[t]);
			for (uint i = 0; i < list.length(); i++)
			{
				if (!list[i].IsEnabled())
					continue;
				float d = dist(from, xy(list[i].GetUnit().GetPosition()));
				if (d < bestD)
				{
					bestD = d;
					@best = list[i];
				}
			}
		}
		return best;
	}

	void PilotEnd(const string &in result, const string &in reason)
	{
		if (g_intent is null)
			return;
		Json j;
		j.Str("ev", "pilot").Str("id", g_intent.id).Str("intent", g_intent.kind).Str("result", result)
			.Str("reason", reason).Int("tick", g_tick).Int("ms", g_intent.elapsed).Int("frames", g_intent.frames);
		auto plr = GetLocalPlayer();
		if (plr !is null)
		{
			vec3 pos = plr.m_unit.GetPosition();
			j.Num("x", pos.x).Num("y", pos.y);
		}
		auto rec = GetLocalPlayerRecord();
		if (rec !is null)
			j.Int("hp", rec.CurrentHealth()).Int("hpMax", rec.MaxHealth());
		@g_intent = null;
		g_releasePending = true;       // gamelab-hands zeroes the controller for RELEASE_FRAMES
		Emit(j);
	}

	// a fresh engine path from the player to the intent's goal; false = no route
	bool Repath(PilotIntent@ it, vec2 from)
	{
		@it.path = g_scene.Pathfind(from, it.goal, PATH_DIAMETER);
		it.wp = 0;
		return it.path !is null && it.path.length() > 0;
	}

	// Exit routing. Measured on dark_citadel forest floors:
	// - Pathfind to the exit unit's own position always answers empty: it sits off the walkable
	//   area, and so do points 48-128 around it (pathfind-probe 20261017-153509). Where to stand
	//   is ExitStandPoint (the exit's area sensor).
	// - A long route can answer empty although both legs of it answer: player -> midpoint and
	//   midpoint -> exit (pathfind-probe 20261017-153509). Whole-floor reachmaps from the spawn
	//   and from beside the exit share cells (gap-walk 20261017-160053), so the floor is one
	//   region that one Pathfind call does not always cross. maxDistance/maxRange change
	//   neither (pathfind-probe 20261017-153815). Greedy waypoint hops dead-ended
	//   (pilot-crosslevel 20261017-162608).
	// So: one Pathfind call when it answers, else NavRoute: A* over a coarse grid whose edges
	// are short Pathfind calls between neighbouring cells, the legs stitched into one path.
	const float SLIDE_PROBE = 18;          // PathFollower: unit radius * 2
	const float WIGGLE_PROBE = 32;
	const int WIGGLE_MS = 400;
	const float NAV_STEP = 96;
	// the grid spans +-NAV_R cells around the start: 9216 at the coarse step. 64 (6144) missed a
	// spawn-to-exit distance of 6850 (pilot-crosslevel 20261017-171409)
	const int NAV_R = 96;
	const int NAV_W = 2 * NAV_R + 1;
	const int NAV_MAX_EXPAND = 4000;
	const float OPEN_REACH = 96;
	int g_navExpanded = 0;

	bool PathOk(vec2 from, vec2 to)
	{
		auto path = g_scene.Pathfind(from, to, PATH_DIAMETER);
		return path !is null && path.length() > 0;
	}

	// a point the pathfinder can stand on: a short path leaves it in some direction
	bool Walkable(vec2 p)
	{
		return PathOk(p, p + vec2(32, 0)) || PathOk(p, p + vec2(-32, 0))
			|| PathOk(p, p + vec2(0, 32)) || PathOk(p, p + vec2(0, -32));
	}

	// Walkable and not a nav island: paths reach OPEN_REACH out in at least two of eight
	// directions. A Walkable point can sit on an island no route leaves (route-sweep
	// 20261017-185821: a point by the exit, walkable, NavRoute expanded 3 cells; floor-soak
	// 20261017-184334: the exit's stand point, stand -> anywhere in 3 expansions).
	bool Open(vec2 p)
	{
		int n = 0;
		for (int k = 0; k < 8 && n < 2; k++)
		{
			float a = k * 3.14159265f / 4;
			if (PathOk(p, p + vec2(cos(a), sin(a)) * OPEN_REACH))
				n++;
		}
		return n >= 2;
	}

	class NavHeap
	{
		array<float> f;
		array<int> k;

		bool Empty() { return f.length() == 0; }

		void Swap(uint a, uint b)
		{
			float tf = f[a]; f[a] = f[b]; f[b] = tf;
			int tk = k[a]; k[a] = k[b]; k[b] = tk;
		}

		void Push(float pf, int pk)
		{
			f.insertLast(pf);
			k.insertLast(pk);
			uint i = f.length() - 1;
			while (i > 0)
			{
				uint p = (i - 1) / 2;
				if (f[p] <= f[i])
					break;
				Swap(p, i);
				i = p;
			}
		}

		int Pop()
		{
			int top = k[0];
			uint last = f.length() - 1;
			Swap(0, last);
			f.removeLast();
			k.removeLast();
			uint n = f.length();
			uint i = 0;
			while (true)
			{
				uint l = 2 * i + 1;
				uint r = l + 1;
				uint m = i;
				if (l < n && f[l] < f[m])
					m = l;
				if (r < n && f[r] < f[m])
					m = r;
				if (m == i)
					break;
				Swap(m, i);
				i = m;
			}
			return top;
		}
	}

	vec2 NavCell(vec2 from, int key, float step)
	{
		return from + vec2(key / NAV_W - NAV_R, key % NAV_W - NAV_R) * step;
	}

	// A* from `from` to `to` over grid cells NAV_STEP apart; null when no route within
	// NAV_MAX_EXPAND expansions. The result is the stitched engine path.
	// partial: when `to` is not reached, the route to the reached cell nearest it instead (if
	// that is at least two cells nearer than `from`), and g_navPartial set
	bool g_navPartial = false;

	array<vec2>@ NavRouteStep(vec2 from, vec2 to, float step, bool partial = false)
	{
		g_navPartial = false;
		int best = -1;
		float bestD = dist(from, to) - step * 2;
		int n = NAV_W * NAV_W;
		array<float> g(n, 1e9);
		array<int> parent(n, -1);
		array<bool> closed(n, false);
		int start = NAV_R * NAV_W + NAV_R;
		g[start] = 0;
		NavHeap open;
		open.Push(dist(from, to), start);
		int goal = -1;
		g_navExpanded = 0;
		while (!open.Empty() && g_navExpanded < NAV_MAX_EXPAND)
		{
			int k = open.Pop();
			if (closed[k])
				continue;
			closed[k] = true;
			g_navExpanded++;
			vec2 c = NavCell(from, k, step);
			if (dist(c, to) < bestD)
			{
				bestD = dist(c, to);
				best = k;
			}
			if (dist(c, to) <= step * 2 && PathOk(c, to))
			{
				goal = k;
				break;
			}
			int ci = k / NAV_W - NAV_R;
			int cj = k % NAV_W - NAV_R;
			for (int di = -1; di <= 1; di++)
				for (int dj = -1; dj <= 1; dj++)
				{
					int ni = ci + di;
					int nj = cj + dj;
					if ((di == 0 && dj == 0) || abs(ni) > NAV_R || abs(nj) > NAV_R)
						continue;
					int nk = (ni + NAV_R) * NAV_W + (nj + NAV_R);
					float ng = g[k] + ((di != 0 && dj != 0) ? step * 1.4142f : step);
					if (closed[nk] || ng >= g[nk])
						continue;
					vec2 nc = NavCell(from, nk, step);
					if (!PathOk(c, nc))
						continue;
					g[nk] = ng;
					parent[nk] = k;
					open.Push(ng + dist(nc, to), nk);
				}
		}
		if (goal < 0 && (!partial || best < 0))
			return null;
		g_navPartial = goal < 0;
		if (g_navPartial)
			goal = best;
		array<vec2> cells;
		for (int k = goal; k >= 0 && k != start; k = parent[k])
			cells.insertLast(NavCell(from, k, step));
		cells.reverse();
		if (!g_navPartial)
			cells.insertLast(to);
		array<vec2> path;
		vec2 prev = from;
		for (uint i = 0; i < cells.length(); i++)
		{
			auto leg = g_scene.Pathfind(prev, cells[i], PATH_DIAMETER);
			if (leg is null || leg.length() == 0)
				path.insertLast(cells[i]);
			else
				for (uint m = 0; m < leg.length(); m++)
					path.insertLast(leg[m]);
			prev = cells[i];
		}
		return path;
	}

	// NavRouteStep on a coarse grid first, then finer ones: a narrow passage between two coarse
	// cells' centres can be missed (pilot-crosslevel 20261017-164521: 381 expansions, no route)
	array<vec2>@ NavRoute(vec2 from, vec2 to, bool partial = false)
	{
		array<float> steps = { NAV_STEP, 64, 48 };
		int total = 0;
		for (uint i = 0; i < steps.length(); i++)
		{
			auto route = NavRouteStep(from, to, steps[i]);
			total += g_navExpanded;
			if (route !is null)
			{
				g_navExpanded = total;
				return route;
			}
		}
		if (partial)
		{
			auto route = NavRouteStep(from, to, NAV_STEP, true);
			g_navExpanded = total;
			return route;
		}
		g_navExpanded = total;
		g_navPartial = false;
		return null;
	}

	bool TryPath(PilotIntent@ it, vec2 from, vec2 to)
	{
		auto path = g_scene.Pathfind(from, to, PATH_DIAMETER);
		if (path is null || path.length() == 0)
			return false;
		@it.path = path;
		it.wp = 0;
		it.goal = to;
		return true;
	}

	// a target standing where the pathfinder cannot (in a tree's footprint): path to the
	// nearest point around it that answers; false (and it.path null) when none does
	bool RouteNear(PilotIntent@ it, vec2 pos, vec2 tp)
	{
		array<float> rings = { 32, 64, 96, 128 };
		for (uint r = 0; r < rings.length(); r++)
			for (int k = 0; k < 8; k++)
			{
				float a = k * 3.14159265f / 4;
				if (TryPath(it, pos, tp + vec2(cos(a), sin(a)) * rings[r]))
				{
					it.goal = tp;      // FollowPath ends on the target, the path leads around it
					return true;
				}
			}
		@it.path = null;
		return false;
	}

	// the approach point: the stand point if the pathfinder can stand there, else the
	// walkable ring point nearest it (the player then walks straight in)
	bool FindApproach(PilotIntent@ it, vec2 pos)
	{
		if (Open(it.anchor))
		{
			it.approach = it.anchor;
			return true;
		}
		array<float> rings = { 48, 96, 160, 224, 320, 448 };
		float base = atan(pos.y - it.anchor.y, pos.x - it.anchor.x);
		for (uint r = 0; r < rings.length(); r++)
			for (int k = 0; k < 16; k++)
			{
				// ring points facing the player first
				float a = base + ((k % 2 == 0) ? 1 : -1) * ((k + 1) / 2) * 3.14159265f / 8;
				vec2 c = it.anchor + vec2(cos(a), sin(a)) * rings[r];
				if (Open(c))
				{
					it.approach = c;
					return true;
				}
			}
		return false;
	}

	// Where routing starts. A player hugging trees or rocks can stand where the nav data is
	// blocked although the physics let it in; no Pathfind leaves such a spot (pilot-crosslevel
	// 20261017-165255: open field to the south, NavRoute expanded 3 cells). Then: the nearest
	// walkable point it can step to in a straight line (no raycast hit), toward `toward` first.
	bool RouteStart(vec2 pos, vec2 toward, vec2 &out start)
	{
		start = pos;
		if (Open(pos))
			return true;
		array<float> rings = { 16, 32, 48, 64, 96 };
		float base = atan(toward.y - pos.y, toward.x - pos.x);
		for (uint r = 0; r < rings.length(); r++)
			for (int k = 0; k < 16; k++)
			{
				float a = base + ((k % 2 == 0) ? 1 : -1) * ((k + 1) / 2) * 3.14159265f / 8;
				vec2 c = pos + vec2(cos(a), sin(a)) * rings[r];
				if (!g_scene.RaycastQuick(pos, c, ~0, RaycastType::Any) && Open(c))
				{
					start = c;
					return true;
				}
			}
		return false;
	}

	const int NAV_POCKET = 16;             // NavRoute total expansions under this: a pocket
	const int POCKET_TRIES = 12;

	array<vec2>@ RouteFromPocket(vec2 pos, vec2 to, vec2 &out start)
	{
		start = pos;
		array<float> rings = { 24, 48, 72, 96, 128 };
		float base = atan(to.y - pos.y, to.x - pos.x);
		int tries = 0;
		for (uint r = 0; r < rings.length() && tries < POCKET_TRIES; r++)
			for (int k = 0; k < 16 && tries < POCKET_TRIES; k++)
			{
				float a = base + ((k % 2 == 0) ? 1 : -1) * ((k + 1) / 2) * 3.14159265f / 8;
				vec2 c = pos + vec2(cos(a), sin(a)) * rings[r];
				if (g_scene.RaycastQuick(pos, c, ~0, RaycastType::Any) || !Walkable(c))
					continue;
				tries++;
				auto route = NavRouteStep(c, to, NAV_STEP);
				if (route !is null && route.length() > 0)
				{
					start = c;
					return route;
				}
			}
		return null;
	}

	const int PARTIAL_HOPS = 6;

	bool RouteExit(PilotIntent@ it, vec2 pos)
	{
		it.pushing = false;
		it.tol = 16.0f;
		if (!it.hasApproach)
		{
			it.hasApproach = FindApproach(it, pos);
			if (!it.hasApproach)
				return false;
		}
		vec2 start;
		if (!RouteStart(pos, it.approach, start))
			start = pos;
		it.escaped = dist(start, pos) > 0.5f;
		array<vec2>@ route = g_scene.Pathfind(start, it.approach, PATH_DIAMETER);
		it.nav = false;
		if (route is null || route.length() == 0)
		{
			@route = NavRoute(start, it.approach);
			it.navExpanded = g_navExpanded;
			it.nav = true;
		}
		if ((route is null || route.length() == 0) && it.navExpanded < NAV_POCKET)
		{
			// a pocket: the nav data around the player is closed off although it is walkable
			// (on a pond's bank between trees: pilot-crosslevel 20261017-171446, 3 expansions).
			// Step to a nearby point in a straight line from which the coarse grid does route.
			@route = RouteFromPocket(pos, it.approach, start);
			it.escaped = route !is null;
		}
		it.partial = false;
		if ((route is null || route.length() == 0) && it.partialHops < PARTIAL_HOPS)
		{
			// no route now (the floor is cut where the player stands: pilot-crosslevel
			// 20261017-172902, spawn -> exit no longer routed after fights, though nav-drift
			// 20261017-173940 found the same layout's answers steady when idle or culled):
			// go to the reached point nearest the exit and route again from there
			@route = NavRoute(start, it.approach, true);
			it.partial = route !is null && route.length() > 0;
		}
		if (route is null || route.length() == 0)
			return false;
		if (it.escaped)
			route.insertAt(0, start);
		@it.path = route;
		it.wp = 0;
		it.goal = it.partial ? route[route.length() - 1] : it.approach;
		if (it.partial)
			it.partialHops++;
		return true;
	}

	// steer along the path; true when within tol of the goal. As the game's own PathFollower
	// (Behaviors/Actors/Enemies/Movements/PathFollower.as:83-127): a node is passed once the
	// player projects past it onto the next leg, and a player that did not move since the last
	// frame slides 45 degrees toward whichever side a short raycast finds free.
	bool FollowPath(PilotIntent@ it, vec2 pos, vec2 &out move)
	{
		move = vec2();
		if (dist(pos, it.goal) <= it.tol)
			return true;
		while (it.path !is null && it.wp < it.path.length() && dist(pos, it.path[it.wp]) < 8.0f)
			it.wp++;
		if (it.path !is null && it.wp + 1 < it.path.length())
		{
			vec2 a = it.path[it.wp] - it.path[it.wp + 1];
			float dt = dot(a, pos - it.path[it.wp + 1]) * 0.95f;
			if (dt > 0 && dt < lengthsq(a))
				it.wp++;
		}
		vec2 to = (it.path !is null && it.wp < it.path.length()) ? it.path[it.wp] : it.goal;
		vec2 dir = to - pos;
		if (length(dir) < 0.01f)
			return false;
		move = normalize(dir);
		if (distsq(it.lastPos, pos) <= 0.1f)
		{
			float ang = atan(dir.y, dir.x);
			float da = 3.14159265f / 4;
			vec2 d1(cos(ang + da), sin(ang + da));
			vec2 d2(cos(ang - da), sin(ang - da));
			bool b1 = g_scene.RaycastQuick(pos, pos + d1 * SLIDE_PROBE, ~0, RaycastType::Any);
			bool b2 = g_scene.RaycastQuick(pos, pos + d2 * SLIDE_PROBE, ~0, RaycastType::Any);
			if (b1 != b2)
				move = b1 ? d2 : d1;
		}
		it.lastPos = pos;
		return false;
	}

	// a direction the player can step in: of 16, the one nearest `want` whose short raycast
	// hits nothing; vec2() when every one is blocked
	vec2 FreeDir(vec2 pos, vec2 want)
	{
		float base = atan(want.y, want.x);
		for (int k = 0; k < 16; k++)
		{
			float a = base + ((k % 2 == 0) ? 1 : -1) * ((k + 1) / 2) * 3.14159265f / 8;
			vec2 d(cos(a), sin(a));
			if (!g_scene.RaycastQuick(pos, pos + d * WIGGLE_PROBE, ~0, RaycastType::Any))
				return d;
		}
		return vec2();
	}

	string CheckInterrupts(PilotIntent@ it, PlayerRecord@ rec)
	{
		for (uint i = 0; i < it.until.length(); i++)
		{
			string u = it.until[i];
			if (u == "dead" && rec.IsDead())
				return u;
			if (u == "hp_below" && it.hpBelow >= 0 && rec.CurrentHealth() * 100.0f < it.hpBelow * rec.MaxHealth())
				return u + ":" + it.hpBelow;
			if (u == "under_attack" && it.prevHp >= 0 && rec.CurrentHealth() < it.prevHp)
				return u;
			if (u == "target_dead" && it.target.IsValid() && TargetGone(it.target))
				return u;
			if (u == "menu_open" && TopWindow() != "")
				return u + ":" + TopWindow();
		}
		return "";
	}

	// ---- reflexes: standing orders the engine runs every frame ----------------
	// A bot reacts through the gl channel, and one round trip (console line + log flush) took
	// 1.7 s in which a swarm took 140 hp off an unsteered player (pilot-crosslevel
	// 20261017-161022). Reflexes close that gap: set once (`pilot reflex`), they run inside
	// every intent and between intents. Off by default.
	float g_reflexPotion = -1;     // drink when hp% < this (and a charge is left)
	float g_reflexFire = 0;        // aim at and fire on the nearest enemy within this radius
	int g_reflexPotionSince = 100000;
	int g_reflexFireSince = 100000;
	int g_reflexPotions = 0;

	class ReflexOut
	{
		bool aimSet = false;
		vec2 aim;
		array<string> buttons;
		bool pressed = false;
	}

	// adds the reflexes' buttons and aim to o; true if any acted
	bool Reflexes(int ms, vec2 pos, PlayerRecord@ rec, const string &in kind, ReflexOut@ o)
	{
		bool acted = false;
		g_reflexPotionSince += ms;
		g_reflexFireSince += ms;
		if (g_reflexPotion > 0 && kind != "potion" && g_reflexPotionSince > 1200
			&& rec.CurrentHealth() * 100.0f < g_reflexPotion * rec.MaxHealth()
			&& rec.potionChargesUsed < rec.currStats.PotionCharges)
		{
			o.buttons.insertLast("potion");
			o.pressed = true;
			g_reflexPotionSince = 0;
			g_reflexPotions++;
			Json j;
			Emit(j.Str("ev", "reflex").Str("what", "potion").Int("hp", rec.CurrentHealth())
				.Int("hpMax", rec.MaxHealth()).Int("used", rec.potionChargesUsed).Int("tick", g_tick));
			acted = true;
		}
		if (g_reflexFire > 0 && !o.aimSet)
		{
			UnitPtr foe = NearestEnemy(pos, int(g_reflexFire));
			if (!TargetGone(foe))
			{
				vec2 d = xy(foe.GetPosition()) - pos;
				o.aimSet = true;
				o.aim = length(d) > 0.01f ? normalize(d) : vec2(1, 0);
				o.buttons.insertLast("main");
				if (g_reflexFireSince > 250)
				{
					o.pressed = true;
					g_reflexFireSince = 0;
				}
				acted = true;
			}
		}
		return acted;
	}

	void PilotFrame(int ms, GameInput& gi)
	{
		auto it = g_intent;
		if (it is null)
		{
			// between intents: only the reflexes steer, standing still
			auto rrec = GetLocalPlayerRecord();
			auto rplr = GetLocalPlayer();
			if (!g_pilotPaused && rrec !is null && rplr !is null && !rrec.IsDead()
				&& (g_reflexPotion > 0 || g_reflexFire > 0))
			{
				ReflexOut o;
				if (Reflexes(ms, xy(rplr.m_unit.GetPosition()), rrec, "", o))
				{
					WriteInput(gi, vec2(), o.aimSet, o.aim, o.buttons, o.pressed);
					g_releasePending = true;
					return;
				}
			}
			if (Releasing())
				ReleaseInput(gi);
			return;
		}
		if (g_pilotPaused)
		{
			if (g_pilotSteps <= 0)
			{
				ReleaseInput(gi);      // paused = hands off the controller
				return;
			}
			g_pilotSteps--;
		}
		auto rec = GetLocalPlayerRecord();
		auto plr = GetLocalPlayer();
		if (rec is null)
			return;
		g_tick++;
		it.frames++;
		it.elapsed += ms;

		string why = CheckInterrupts(it, rec);
		it.prevHp = rec.CurrentHealth();
		if (why != "")
		{
			PilotEnd("interrupted", why);
			return;
		}
		if (rec.IsDead() || plr is null)
		{
			PilotEnd("failed", "player dead or not spawned");
			return;
		}
		if (it.elapsed > it.timeoutMs)
		{
			PilotEnd("timeout", "after " + it.timeoutMs + " ms");
			return;
		}

		vec2 pos = xy(plr.m_unit.GetPosition());
		vec2 move;
		bool aimSet = false;
		vec2 aim;
		array<string> buttons;
		bool pressed = false;

		// stuck detection for the moving intents: under 3 units in a second -> repath (3x) then fail
		it.stuckMs += ms;
		if (it.stuckMs >= 1000)
		{
			bool fighting = it.kind == "attack" || it.kind == "kite";
			bool moving = it.kind == "path_to" || it.kind == "exit" || it.kind == "move" || (fighting && it.approaching);
			if (moving && dist(pos, it.stuckFrom) < 3.0f && dist(pos, it.goal) > it.tol)
			{
				it.repaths++;
				bool rerouted = it.kind == "move" || it.pushing || fighting
					|| (it.kind == "exit" ? RouteExit(it, pos) : Repath(it, pos));
				if (!rerouted && it.kind == "exit")
				{
					// wedged so that no Pathfind leaves this spot (pilot-crosslevel
					// 20261017-164137: NavRoute expanded only its start): step out, then route
					it.wiggleDir = FreeDir(pos, it.anchor - pos);
					if (length(it.wiggleDir) > 0)
					{
						it.wiggleMs = WIGGLE_MS;
						rerouted = true;
					}
				}
				if (fighting && it.repaths > 3)
				{
					// cannot close in on this one (both sides wedged in trees: pilot-consumables
					// 20261017-163601): "nearest" moves on to the next, a named target fails
					if (!it.nearest)
					{
						PilotEnd("failed", "target " + it.target.GetId() + " unreachable (stuck at " + int(pos.x) + "," + int(pos.y) + ")");
						return;
					}
					it.skip.insertLast(it.target.GetId());
					it.target = NearestEnemy(pos, ENGAGE, it.skip);
					@it.path = null;
					it.repaths = 0;
					if (TargetGone(it.target))
					{
						PilotEnd("failed", "no reachable enemy within " + ENGAGE + " (" + it.skip.length() + " unreachable)");
						return;
					}
				}
				else if (it.repaths > 3 || !rerouted)
				{
					PilotEnd("failed", "stuck at " + int(pos.x) + "," + int(pos.y));
					return;
				}
				else if (fighting)
					@it.path = null;   // re-plan the approach next frame
			}
			it.stuckFrom = pos;
			it.stuckMs = 0;
		}

		if (it.kind == "wait")
		{
			if (it.elapsed >= it.range)
			{
				PilotEnd("done", "waited");
				return;
			}
		}
		else if (it.kind == "move")
		{
			if (dist(pos, it.goal) <= it.tol)
			{
				PilotEnd("done", "arrived");
				return;
			}
			move = normalize(it.goal - pos);
		}
		else if (it.kind == "path_to")
		{
			if (FollowPath(it, pos, move))
			{
				PilotEnd("done", "arrived");
				return;
			}
		}
		else if (it.kind == "exit")
		{
			// walk into the exit's area, then Use it; the level load ends this script module,
			// so "done" is the client seeing the next level's boot
			if (it.wiggleMs > 0)
			{
				move = it.wiggleDir;
				it.wiggleMs -= ms;
				if (it.wiggleMs <= 0 && !RouteExit(it, pos))
				{
					PilotEnd("no_route", "no route to the exit at " + int(it.anchor.x) + "," + int(it.anchor.y)
						+ " after stepping out of a wedge (NavRoute: " + it.navExpanded + " grid expansions)");
					return;
				}
			}
			else if (it.pushing || InExitArea(it.exitWs, plr.m_unit))
			{
				it.pushing = true;
				move = (dist(pos, it.anchor) > 6.0f && !InExitArea(it.exitWs, plr.m_unit)) ? normalize(it.anchor - pos) : vec2();
			}
			else if (FollowPath(it, pos, move) && it.partial)
			{
				if (!RouteExit(it, pos))
				{
					PilotEnd("no_route", "no route to the exit at " + int(it.anchor.x) + "," + int(it.anchor.y)
						+ " after " + it.partialHops + " partial routes (NavRoute: " + it.navExpanded + " grid expansions)");
					return;
				}
				it.stuckMs = 0;
				it.stuckFrom = pos;
			}
			else if (dist(pos, it.goal) <= it.tol)
			{
				it.pushing = true;     // at the approach point: walk straight into the exit's area
				it.stuckMs = 0;
				it.stuckFrom = pos;
			}
			it.sincePulse += ms;
			auto top = plr.GetTopUsable();
			if (top !is null && cast<WorldScript::LevelExitAreaNext>(top) !is null && it.sincePulse > 500)
			{
				buttons.insertLast("use");
				pressed = true;
				it.sincePulse = 0;
				it.pulses++;
			}
		}
		else if (it.kind == "attack" || it.kind == "kite")
		{
			if (it.nearest && TargetGone(it.target))
				it.target = NearestEnemy(pos, ENGAGE, it.skip);
			if (TargetGone(it.target))
			{
				PilotEnd("done", it.nearest ? "no live enemy within " + ENGAGE : "target dead");
				return;
			}
			vec2 tp = xy(it.target.GetPosition());
			float d = dist(pos, tp);
			vec2 to = d > 0.01f ? normalize(tp - pos) : vec2(1, 0);
			aimSet = true;
			aim = to;
			float closeIn = it.kind == "attack" ? MELEE_RANGE : it.range * 1.2f;
			if (d > closeIn)
			{
				// closing in walks the engine path (a beeline sticks on walls), re-planned as it moves
				it.sincePath += ms;
				if (it.path is null || it.sincePath > 600)
				{
					it.goal = tp;
					if (!Repath(it, pos))
						RouteNear(it, pos, tp);
					it.sincePath = 0;
				}
				FollowPath(it, pos, move);
				it.approaching = true;
			}
			else if (it.kind == "attack")
			{
				move = vec2(0, 0);
				it.approaching = false;
			}
			else if (d < it.range * 0.8f)
			{
				it.approaching = false;
				// back away from the pack, not just the target (a swarm closes from all sides)
				auto foes = g_scene.FetchActorsWithOtherTeam(g_team_player, pos, ENGAGE);
				vec2 c;
				int n = 0;
				for (uint i = 0; i < foes.length(); i++)
				{
					if (TargetGone(foes[i]))
						continue;
					c += xy(foes[i].GetPosition());
					n++;
				}
				vec2 away = n > 0 ? pos - c / float(n) : pos - tp;
				move = length(away) > 0.01f ? normalize(away) : to * -1.0f;
				// dash out when something is in melee reach
				it.sinceDash += ms;
				if (d < MELEE_RANGE * 1.5f && it.sinceDash > 1500)
				{
					buttons.insertLast("dash");
					pressed = true;
					it.sinceDash = 0;
				}
			}
			else
			{
				move = vec2(-to.y, to.x);       // strafe around the target at range
				it.approaching = false;
			}
			// kite fires at anything within ENGAGE: closing in can stall on a wall while the
			// target waits behind it (pilot-consumables 20261017-163406: 60 s at 92 units)
			if (d <= max(it.range, MELEE_RANGE) * 1.3f || (it.kind == "kite" && d <= ENGAGE))
			{
				buttons.insertLast("main");
				it.sincePulse += ms;
				if (it.sincePulse > 250)
				{
					pressed = true;
					it.sincePulse = 0;
				}
			}
		}
		else if (it.kind == "use")
		{
			if (it.target.IsValid() && !it.target.IsDestroyed() && dist(pos, xy(it.target.GetPosition())) > it.tol)
			{
				if (FollowPath(it, pos, move))
					move = vec2();
			}
			else
			{
				auto top = plr.GetTopUsable();
				bool targetUsable = top !is null && (!it.target.IsValid() || top.GetUseUnit() == it.target) && top.CanUse(plr);
				if (it.pulses > 0 && (!targetUsable || (it.target.IsValid() && it.target.IsDestroyed())))
				{
					PilotEnd("done", "used (no longer usable)");
					return;
				}
				it.sincePulse += ms;
				if (it.sincePulse > 400)
				{
					if (!targetUsable)
					{
						PilotEnd("failed", top is null ? "nothing usable here" : "top usable is not the target");
						return;
					}
					if (it.pulses >= 4)
					{
						PilotEnd("failed", "still usable after 4 presses");
						return;
					}
					buttons.insertLast("use");
					pressed = true;
					it.sincePulse = 0;
					it.pulses++;
				}
			}
		}
		else if (it.kind == "potion")
		{
			if (it.pulses == 0)
			{
				buttons.insertLast("potion");
				pressed = true;
				it.pulses++;
				it.potionsUsed0 = rec.potionChargesUsed;
			}
			else if (rec.potionChargesUsed > it.potionsUsed0)
			{
				PilotEnd("done", "drank (charges used " + rec.potionChargesUsed + ")");
				return;
			}
			else if (it.elapsed > 1000)
			{
				PilotEnd("failed", "no charge used (charges " + rec.currStats.PotionCharges + ", used " + rec.potionChargesUsed + ")");
				return;
			}
		}

		ReflexOut ro;
		ro.aimSet = aimSet;
		ro.aim = aim;
		ro.pressed = pressed;
		ro.buttons = buttons;
		Reflexes(ms, pos, rec, it.kind, ro);
		aimSet = ro.aimSet;
		aim = ro.aim;
		pressed = ro.pressed;
		buttons = ro.buttons;
		WriteInput(gi, move, aimSet, aim, buttons, pressed);

		if (it.frames % PTICK_EVERY == 1)
		{
			Json j;
			j.Str("ev", "ptick").Int("tick", g_tick).Str("id", it.id).Str("intent", it.kind)
				.Num("x", pos.x).Num("y", pos.y).Int("hp", rec.CurrentHealth()).Int("hpMax", rec.MaxHealth())
				.Num("mx", move.x).Num("my", move.y).Int("wp", it.wp).Int("pathLen", it.path is null ? 0 : it.path.length());
			if (it.target.IsValid())
				j.Int("target", it.target.GetId()).Num("dist", dist(pos, xy(it.target.GetPosition())));
			if (it.kind == "exit")
				j.Bool("nav", it.nav).Bool("partial", it.partial).Bool("pushing", it.pushing)
					.Num("gx", it.goal.x).Num("gy", it.goal.y);
			Emit(j);
		}
	}

	// ---- verbs ---------------------------------------------------------------

	UnitPtr UnitArg(const string &in s, vec2 from, bool &out nearest)
	{
		nearest = s == "nearest";
		if (nearest)
			return NearestEnemy(from, 400);
		return g_scene.GetUnit(int(parseInt(s)));
	}

	void PilotStatus(const string &in id)
	{
		auto j = Reply(id, true);
		j.Bool("paused", g_pilotPaused).Int("tick", g_tick).Num("reflexPotion", g_reflexPotion)
			.Num("reflexFire", g_reflexFire).Int("reflexPotions", g_reflexPotions);
		auto plr = GetLocalPlayer();
		if (plr !is null)
			j.Num("x", plr.m_unit.GetPosition().x).Num("y", plr.m_unit.GetPosition().y);
		if (g_intent !is null)
			j.Str("intent", g_intent.kind).Str("intentId", g_intent.id).Int("ms", g_intent.elapsed)
				.Int("target", g_intent.target.IsValid() ? g_intent.target.GetId() : 0);
		else
			j.Str("intent", "");
		Emit(j);
	}

	// pilot <intent|pause|resume|step|target|stop|status|reflex> [args] [until=..] [timeout=ms]:
	// start an intent (path_to, move, exit, attack, kite, use, potion, wait) that runs in-engine
	// until done or an `until` interrupt, ending in a "pilot" event; or control the running one;
	// `reflex potion=<hp%> fire=<radius>` sets standing orders. Python client: gamelab/pilot.py.
	void VerbPilot(const string &in id, array<string>@ argsIn)
	{
		string sub = argsIn.length() > 0 ? argsIn[0] : "status";
		// positional args and key=value options
		array<string> args;
		string untilArg = "";
		int timeoutMs = 30000;
		for (uint i = 1; i < argsIn.length(); i++)
		{
			if (argsIn[i].findFirst("until=") == 0)
				untilArg = argsIn[i].substr(6);
			else if (argsIn[i].findFirst("timeout=") == 0)
				timeoutMs = int(parseInt(argsIn[i].substr(8)));
			else
				args.insertLast(argsIn[i]);
		}

		if (sub == "status")
		{
			PilotStatus(id);
			return;
		}
		if (sub == "pause" || sub == "resume")
		{
			g_pilotPaused = sub == "pause";
			g_pilotSteps = 0;
			PilotStatus(id);
			return;
		}
		if (sub == "reflex")
		{
			// reflex [potion=<hp%>|off] [fire=<radius>|off]
			for (uint i = 0; i < args.length(); i++)
			{
				auto kv = args[i].split("=");
				float v = kv.length() > 1 && kv[1] != "off" ? parseFloat(kv[1]) : 0;
				if (kv[0] == "potion" && kv.length() > 1)
					g_reflexPotion = v > 0 ? v : -1;
				else if (kv[0] == "fire" && kv.length() > 1)
					g_reflexFire = v;
				else
				{
					Fail(id, "unknown reflex '" + args[i] + "': potion=<hp%>|off, fire=<radius>|off");
					return;
				}
			}
			PilotStatus(id);
			return;
		}
		if (sub == "step")
		{
			g_pilotPaused = true;
			g_pilotSteps = args.length() > 0 ? int(parseInt(args[0])) : 1;
			PilotStatus(id);
			return;
		}
		if (sub == "stop")
		{
			bool had = g_intent !is null;
			PilotEnd("interrupted", "stop");
			Emit(Reply(id, true).Bool("stopped", had));
			return;
		}
		if (sub == "target")
		{
			if (g_intent is null || (g_intent.kind != "attack" && g_intent.kind != "kite"))
			{
				Fail(id, "no attack/kite intent to retarget");
				return;
			}
			UnitPtr u = args.length() > 0 ? g_scene.GetUnit(int(parseInt(args[0]))) : UnitPtr();
			if (TargetGone(u))
			{
				Fail(id, "unit is not a live actor");
				return;
			}
			g_intent.target = u;
			g_intent.nearest = false;
			Emit(Reply(id, true).Int("target", u.GetId()));
			return;
		}

		if (INTENTS.find(sub) < 0)
		{
			Fail(id, "unknown pilot verb '" + sub + "' (intents: " + join(INTENTS, ",") + "; control: pause,resume,step,target,stop,status)");
			return;
		}
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		vec2 pos = xy(plr.m_unit.GetPosition());

		PilotIntent it;
		it.id = id;
		it.kind = sub;
		it.timeoutMs = timeoutMs;
		it.stuckFrom = pos;
		if (untilArg != "")
		{
			auto parts = untilArg.split(",");
			for (uint i = 0; i < parts.length(); i++)
			{
				auto kv = parts[i].split(":");
				if (INTERRUPTS.find(kv[0]) < 0)
				{
					Fail(id, "unknown interrupt '" + kv[0] + "' (closed vocabulary: " + join(INTERRUPTS, ",") + ")");
					return;
				}
				if (kv[0] == "hp_below")
					it.hpBelow = kv.length() > 1 ? parseFloat(kv[1]) : 50.0f;
				it.until.insertLast(kv[0]);
			}
		}

		string err = "";
		if (sub == "move" || sub == "path_to")
		{
			if (args.length() < 2)
				err = "usage: pilot " + sub + " x y [tol]";
			else
			{
				it.goal = vec2(parseFloat(args[0]), parseFloat(args[1]));
				if (args.length() > 2)
					it.tol = parseFloat(args[2]);
			}
		}
		else if (sub == "attack" || sub == "kite")
		{
			it.target = UnitArg(args.length() > 0 ? args[0] : "nearest", pos, it.nearest);
			if (!TargetGone(it.target))
				it.goal = xy(it.target.GetPosition());
			it.range = sub == "kite" ? (args.length() > 1 ? parseFloat(args[1]) : 70.0f) : MELEE_RANGE;
			if (TargetGone(it.target))
				err = "no live target";
		}
		else if (sub == "use")
		{
			it.tol = 14.0f;
			if (args.length() > 0)
			{
				bool unused;
				it.target = UnitArg(args[0], pos, unused);
				if (!it.target.IsValid())
					err = "no unit " + args[0];
				else
					it.goal = xy(it.target.GetPosition());
			}
		}
		else if (sub == "wait")
			it.range = args.length() > 0 ? parseFloat(args[0]) : 1000.0f;
		else if (sub == "exit")
		{
			auto ws = NearestExit(pos);
			if (ws is null)
			{
				if (g_intent !is null)
					PilotEnd("interrupted", "replaced by " + id);
				Emit(Reply(id, true).Str("accepted", sub));
				@g_intent = it;
				PilotEnd("no_route", "no enabled level exit in this level");
				return;
			}
			@it.exitWs = ws;
			it.anchor = ExitStandPoint(ws, it.areaFound);
			it.goal = it.anchor;
			it.tol = 6.0f;
		}
		if (err != "")
		{
			Fail(id, err);
			return;
		}

		// a new intent replaces the running one
		if (g_intent !is null)
			PilotEnd("interrupted", "replaced by " + id);
		auto reply = Reply(id, true).Str("accepted", sub).Int("tick", g_tick);
		bool routed = true;
		if (sub == "path_to" || sub == "exit" || (sub == "use" && it.target.IsValid()))
		{
			routed = sub == "exit" ? RouteExit(it, pos) : Repath(it, pos);
			if (sub == "exit")
				reply.Num("ux", it.exitWs.GetUnit().GetPosition().x).Num("uy", it.exitWs.GetUnit().GetPosition().y)
					.Bool("area", it.areaFound).Num("ax", it.anchor.x).Num("ay", it.anchor.y).Bool("nav", it.nav).Int("navExpanded", it.navExpanded).Bool("escaped", it.escaped).Bool("partial", it.partial)
					.Num("apx", it.approach.x).Num("apy", it.approach.y);
			reply.Int("pathLen", it.path is null ? 0 : it.path.length()).Num("gx", it.goal.x).Num("gy", it.goal.y);
		}
		if (it.target.IsValid())
			reply.Int("target", it.target.GetId());
		Emit(reply);
		@g_intent = it;
		if (!routed)
			PilotEnd("no_route", "engine pathfinder found no path to " + int(it.goal.x) + "," + int(it.goal.y)
				+ (sub == "exit" ? " (NavRoute: none within " + it.navExpanded + " grid expansions)" : ""));
	}

	// where the player is, as a travel-graph node: "town", or "<missionId>/<floorId>"
	// (every generated floor is levels/generated.lvl, so the level file cannot be the key)
	string Place()
	{
		if (g_inTown)
			return "town";
		auto def = MissionManager::GetCurrentMission();
		if (def is null)
			return GetCurrentLevelFilename();
		uint i = MissionManager::g_module.m_missionLevelIndex;
		return def.m_id + "/" + (i < def.m_levels.length() ? def.m_levels[i].m_id : ("" + i));
	}

	// pathfind x y [diameter] [maxDistance] [maxRange]: the engine pathfinder's answer from the
	// player, read-only (nodes, length, first and last node)
	void VerbPathfind(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null || args.length() < 2)
		{
			Fail(id, plr is null ? "no spawned local player" : "usage: pathfind x y [diameter] [maxDistance] [maxRange] [fromX fromY]");
			return;
		}
		vec2 from = xy(plr.m_unit.GetPosition());
		vec2 to(parseFloat(args[0]), parseFloat(args[1]));
		int diameter = args.length() > 2 ? int(parseInt(args[2])) : PATH_DIAMETER;
		float maxDistance = args.length() > 3 ? parseFloat(args[3]) : -1.0f;
		float maxRange = args.length() > 4 ? parseFloat(args[4]) : -1.0f;
		if (args.length() > 6)
			from = vec2(parseFloat(args[5]), parseFloat(args[6]));
		auto path = g_scene.Pathfind(from, to, diameter, maxDistance, maxRange);
		auto j = Reply(id, true).Num("fx", from.x).Num("fy", from.y).Num("tx", to.x).Num("ty", to.y)
			.Num("straight", dist(from, to)).Int("nodes", path is null ? -1 : int(path.length()));
		if (path !is null && path.length() > 0)
		{
			float len = dist(from, path[0]);
			for (uint i = 1; i < path.length(); i++)
				len += dist(path[i - 1], path[i]);
			j.Num("length", len).Num("lastX", path[path.length() - 1].x).Num("lastY", path[path.length() - 1].y);
		}
		Emit(j);
	}

	// reachmap x0 y0 x1 y1 step: read-only grid of Pathfind answers from the player, one row
	// string per y ("#" a path, "." none, "@" the player's cell). Capped at REACHMAP_CAP cells.
	const int REACHMAP_CAP = 4096;

	void VerbReachmap(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null || args.length() < 5)
		{
			Fail(id, plr is null ? "no spawned local player" : "usage: reachmap x0 y0 x1 y1 step");
			return;
		}
		vec2 from = xy(plr.m_unit.GetPosition());
		float x0 = parseFloat(args[0]), y0 = parseFloat(args[1]), x1 = parseFloat(args[2]), y1 = parseFloat(args[3]);
		float st = max(16.0f, parseFloat(args[4]));
		int nx = int((x1 - x0) / st) + 1, ny = int((y1 - y0) / st) + 1;
		if (nx <= 0 || ny <= 0 || nx * ny > REACHMAP_CAP)
		{
			Fail(id, "grid " + nx + "x" + ny + " is empty or over the cap of " + REACHMAP_CAP + " cells");
			return;
		}
		array<string> rows;
		int reach = 0;
		for (int j = 0; j < ny; j++)
		{
			string row = "";
			for (int i = 0; i < nx; i++)
			{
				vec2 c(x0 + i * st, y0 + j * st);
				if (abs(c.x - from.x) <= st / 2 && abs(c.y - from.y) <= st / 2)
				{
					row += "@";
					continue;
				}
				auto path = g_scene.Pathfind(from, c, PATH_DIAMETER);
				bool ok = path !is null && path.length() > 0;
				row += ok ? "#" : ".";
				if (ok)
					reach++;
			}
			rows.insertLast(row);
		}
		Emit(Reply(id, true).Num("x0", x0).Num("y0", y0).Num("step", st).Int("nx", nx).Int("ny", ny)
			.Int("reachable", reach).Raw("rows", StrArray(rows)));
	}

	// exitareas [radius]: read-only. The nearest enabled exit's script object (its Areas: a
	// LevelExitAreaNext fires only for a player inside one), whether the player is inside each,
	// and the sensor units around the exit unit (QueryCircle getSensors), capped at SCAN_CAP.
	void VerbExitAreas(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		vec2 pos = xy(plr.m_unit.GetPosition());
		auto ws = NearestExit(pos);
		if (ws is null)
		{
			Fail(id, "no enabled level exit");
			return;
		}
		uint radius = args.length() > 0 ? uint(parseInt(args[0])) : 600;
		vec2 at = xy(ws.GetUnit().GetPosition());
		auto j = Reply(id, true).Int("unit", ws.GetUnit().GetId()).Num("x", at.x).Num("y", at.y);
		auto ex = cast<WorldScript::LevelExitAreaNext>(ws.GetUnit().GetScriptBehavior());
		j.Bool("scriptObject", ex !is null);
		if (ex !is null && ex.Areas !is null)
		{
			array<string> areas;
			for (uint i = 0; i < ex.Areas.length(); i++)
			{
				Json a;
				a.Int("i", i).Bool("null", ex.Areas[i] is null);
				if (ex.Areas[i] !is null)
				{
					auto inside = ex.Areas[i].FetchAllInside(g_scene);
					a.Bool("playerInside", ex.Areas[i].IsInside(plr.m_unit)).Int("unitsInside", inside is null ? -1 : int(inside.length()));
					array<string> ins;
					for (uint k = 0; inside !is null && k < inside.length() && k < 8; k++)
						ins.insertLast(ScanUnit(inside[k], at));
					a.Raw("inside", RawArray(ins));
				}
				areas.insertLast(a.Close());
			}
			j.Raw("areas", RawArray(areas));
		}
		auto withS = g_scene.QueryCircle(at, radius, ~0, RaycastType::Any, true);
		auto without = g_scene.QueryCircle(at, radius, ~0, RaycastType::Any, false);
		array<string> sensors;
		uint n = 0;
		for (uint i = 0; i < withS.length(); i++)
		{
			bool plain = false;
			for (uint k = 0; k < without.length() && !plain; k++)
				plain = without[k] == withS[i];
			if (plain)
				continue;
			n++;
			if (sensors.length() < SCAN_CAP)
				sensors.insertLast(ScanUnit(withS[i], at));
		}
		j.Int("sensorCount", n).Bool("truncated", n > SCAN_CAP).Raw("sensors", RawArray(sensors));
		Emit(j);
	}

	// routesweep [spacing] [offset]: read-only. The exit route from the player (RouteExit, as the
	// exit intent plans it), then RouteExit again from points spaced along that route and
	// offset to both sides of it: where a player might be after a fight or a knock-back. Per
	// point: answered, partial, escaped, NavRoute expansions. Points a solid body covers
	// (blocked) or the player's floor does not reach (offFloor) are counted, not routed. No
	// walking: every route is planned in this one call.
	const float PLAYER_R = 8;

	void VerbRouteSweep(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		vec2 pos = xy(plr.m_unit.GetPosition());
		auto ws = NearestExit(pos);
		if (ws is null)
		{
			Fail(id, "no enabled level exit");
			return;
		}
		float spacing = args.length() > 0 ? parseFloat(args[0]) : 400;
		float off = args.length() > 1 ? parseFloat(args[1]) : 128;
		PilotIntent it;
		@it.exitWs = ws;
		it.anchor = ExitStandPoint(ws, it.areaFound);
		bool ok = RouteExit(it, pos);
		auto j = Reply(id, true).Num("x", pos.x).Num("y", pos.y).Num("ax", it.anchor.x).Num("ay", it.anchor.y)
			.Bool("spawnOk", ok).Bool("spawnPartial", it.partial).Int("spawnExp", it.navExpanded);
		if (!ok)
		{
			Emit(j);
			return;
		}
		array<vec2> base = it.path;
		array<string> pts;
		int answered = 0, partial = 0, failed = 0, total = 0, blocked = 0, offFloor = 0;
		array<string> blockedBy;
		float acc = 0;
		for (uint i = 1; i < base.length() && total < 96; i++)
		{
			acc += dist(base[i - 1], base[i]);
			if (acc < spacing)
				continue;
			acc = 0;
			vec2 d = base[i] - base[i - 1];
			vec2 n = length(d) > 0.01f ? normalize(vec2(-d.y, d.x)) : vec2(0, 1);
			array<float> offs = { 0, off, -off };
			for (uint k = 0; k < offs.length(); k++)
			{
				vec2 q = base[i] + n * offs[k];
				PilotIntent t;
				@t.exitWs = ws;
				t.anchor = it.anchor;
				t.approach = it.approach;
				t.hasApproach = true;
				// a player can only be where no solid body overlaps its circle: the others are
				// not samples (inside a tree)
				// solid bodies other than actors (an enemy standing there does not make it a wall);
				// unit 0 hits are level collision without a unit (route-sweep 20261017-180225)
				auto hits = g_scene.QueryCircle(q, PLAYER_R, ~0, RaycastType::Any, false);
				int solid = -1;
				for (uint h = 0; h < hits.length() && solid < 0; h++)
					if (ActorOf(hits[h]) is null)
						solid = h;
				if (solid >= 0)
				{
					blocked++;
					if (blockedBy.length() < 12)
						blockedBy.insertLast(ScanUnit(hits[solid], q));
					continue;
				}
				// an off-route point the player's floor does not reach (behind the exit, across
				// a cliff: route-sweep 20261017-190749) is no sample of the planner either
				if (offs[k] != 0 && !PathOk(pos, q) && NavRoute(pos, q) is null)
				{
					offFloor++;
					continue;
				}
				bool r = RouteExit(t, q);
				total++;
				if (r && !t.partial) answered++;
				else if (r) partial++;
				else failed++;
				Json e;
				e.Num("x", q.x).Num("y", q.y).Num("off", offs[k]).Bool("walkable", Walkable(q)).Bool("ok", r)
					.Bool("partial", t.partial).Bool("escaped", t.escaped).Int("exp", t.navExpanded);
				pts.insertLast(e.Close());
			}
		}
		j.Int("points", total).Int("blocked", blocked).Int("offFloor", offFloor).Raw("blockedBy", RawArray(blockedBy)).Int("answered", answered).Int("partial", partial).Int("failed", failed).Raw("sweep", RawArray(pts));
		Emit(j);
	}

	// bodies <x> <y> [step]: read-only. Every 'step' units (default 16) from the player to x,y:
	// the collision bodies a player-sized circle overlaps (QueryCircle, sensors excluded),
	// actors flagged; Walkable (nav) and PathOk (raycast) per point. Unit ids deduplicated,
	// capped at SCAN_CAP. What stands in a passage the nav graph says is closed.
	void VerbBodies(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null || args.length() < 2)
		{
			Fail(id, plr is null ? "no spawned local player" : "usage: bodies <x> <y> [step]");
			return;
		}
		vec2 pos = xy(plr.m_unit.GetPosition());
		vec2 to(parseFloat(args[0]), parseFloat(args[1]));
		float step = args.length() > 2 ? max(4.0f, parseFloat(args[2])) : 16.0f;
		int n = int(dist(pos, to) / step) + 1;
		array<int> seen;
		array<string> bodies;
		string walk = "";
		string ray = "";
		int total = 0;
		for (int i = 0; i <= n && i <= 200; i++)
		{
			vec2 q = pos + (to - pos) * (float(i) / n);
			walk += Walkable(q) ? "1" : "0";
			ray += PathOk(pos, q) ? "1" : "0";
			auto hits = g_scene.QueryCircle(q, PLAYER_R, ~0, RaycastType::Any, false);
			for (uint h = 0; h < hits.length(); h++)
			{
				int uid = hits[h].GetId();
				if (seen.find(uid) >= 0)
					continue;
				seen.insertLast(uid);
				total++;
				if (bodies.length() < SCAN_CAP)
				{
					Json e;
					vec3 up = hits[h].GetPosition();
					e.Int("unit", uid).Str("name", hits[h].GetDebugName()).Num("x", up.x).Num("y", up.y)
						.Bool("actor", ActorOf(hits[h]) !is null).Num("atX", q.x).Num("atY", q.y);
					bodies.insertLast(e.Close());
				}
			}
		}
		auto j = Reply(id, true).Num("fx", pos.x).Num("fy", pos.y).Num("tx", to.x).Num("ty", to.y).Num("step", step)
			.Str("walkable", walk).Str("raycastFree", ray).Int("bodyCount", total).Bool("truncated", total > int(SCAN_CAP))
			.Raw("bodies", RawArray(bodies));
		Emit(j);
	}

	// breakables [radius]: read-only. Breakable units within radius (default 400) of the
	// player, nearest first: unit, name, x, y, d. Capped at SCAN_CAP, truncation reported.
	void VerbBreakables(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		vec2 pos = xy(plr.m_unit.GetPosition());
		int radius = args.length() > 0 ? int(parseInt(args[0])) : 400;
		auto all = g_scene.FetchAllUnits(~0, pos, radius);
		array<UnitPtr> found;
		array<float> ds;
		for (uint i = 0; i < all.length(); i++)
		{
			if (!all[i].IsValid() || all[i].IsDestroyed() || cast<Breakable>(all[i].GetScriptBehavior()) is null)
				continue;
			float d = dist(pos, xy(all[i].GetPosition()));
			uint at = 0;
			while (at < ds.length() && ds[at] <= d)
				at++;
			found.insertAt(at, all[i]);
			ds.insertAt(at, d);
		}
		array<string> list;
		for (uint i = 0; i < found.length() && i < SCAN_CAP; i++)
		{
			Json e;
			vec3 up = found[i].GetPosition();
			e.Int("unit", found[i].GetId()).Str("name", found[i].GetDebugName()).Num("x", up.x).Num("y", up.y).Num("d", ds[i]);
			list.insertLast(e.Close());
		}
		Emit(Reply(id, true).Int("radius", radius).Int("count", int(found.length()))
			.Bool("truncated", found.length() > SCAN_CAP).Raw("breakables", RawArray(list)));
	}

	// exitprobe [refX refY]: read-only. Whether the nearest exit's stand point is joined to the floor the
	// player is on: Walkable(stand); per ring radius, a 16-bit string of PathOk(stand -> ring
	// point) and of PathOk(player -> ring point); NavRoute both ways (expansions, answered).
	void VerbExitProbe(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		vec2 pos = xy(plr.m_unit.GetPosition());
		auto ws = NearestExit(pos);
		if (ws is null)
		{
			Fail(id, "no enabled level exit");
			return;
		}
		bool found;
		vec2 st = ExitStandPoint(ws, found);
		auto j = Reply(id, true).Num("px", pos.x).Num("py", pos.y).Num("sx", st.x).Num("sy", st.y)
			.Bool("area", found).Bool("walkable", Walkable(st)).Bool("direct", PathOk(pos, st));
		array<float> rings = { 64, 128, 256, 512 };
		for (uint r = 0; r < rings.length(); r++)
		{
			string fromS = "", fromP = "";
			for (int k = 0; k < 16; k++)
			{
				float ang = k * 3.14159265f / 8;
				vec2 c = st + vec2(cos(ang), sin(ang)) * rings[r];
				fromS += PathOk(st, c) ? "1" : "0";
				fromP += PathOk(pos, c) ? "1" : "0";
			}
			j.Str("s" + int(rings[r]), fromS).Str("p" + int(rings[r]), fromP);
		}
		auto fwd = NavRoute(pos, st);
		j.Bool("navFwd", fwd !is null).Int("navFwdExp", g_navExpanded);
		auto back = NavRoute(st, pos);
		j.Bool("navBack", back !is null).Int("navBackExp", g_navExpanded);
		if (args.length() >= 2)
		{
			// a reference point (the spawn): does it still route to the stand point, and here to it?
			vec2 ref(parseFloat(args[0]), parseFloat(args[1]));
			auto rs = NavRoute(ref, st);
			j.Num("rx", ref.x).Num("ry", ref.y).Bool("navRef", rs !is null).Int("navRefExp", g_navExpanded);
			auto pr = NavRoute(pos, ref);
			j.Bool("navToRef", pr !is null).Int("navToRefExp", g_navExpanded);
		}
		// every exit: enabled or not, where, and whether NavRoute reaches its stand point
		array<string> all;
		array<string> types = { "LevelExitAreaNext", "LevelExitNext" };
		for (uint t = 0; t < types.length(); t++)
		{
			auto list = g_scene.FetchAllWorldScripts(types[t]);
			for (uint i = 0; i < list.length() && all.length() < 16; i++)
			{
				bool f;
				vec2 sp = ExitStandPoint(list[i], f);
				auto r = NavRoute(pos, sp);
				Json e;
				e.Str("type", types[t]).Bool("enabled", list[i].IsEnabled())
					.Num("ux", list[i].GetUnit().GetPosition().x).Num("uy", list[i].GetUnit().GetPosition().y)
					.Num("sx", sp.x).Num("sy", sp.y).Bool("nav", r !is null).Int("exp", g_navExpanded);
				all.insertLast(e.Close());
			}
		}
		j.Raw("exits", RawArray(all));
		Emit(j);
	}

	// pfsweep <dx> <dy> <steps> [diam...]: read-only. For each diameter (default 12), whether
	// Pathfind from the player to player + k/steps * (dx,dy) answers, k = 1..steps; one bit
	// string per diameter ("1" answered). Separates "too far" from "blocked" from "too wide".
	void VerbPfSweep(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null || args.length() < 3)
		{
			Fail(id, plr is null ? "no spawned local player" : "usage: pfsweep <dx> <dy> <steps> [diam...]");
			return;
		}
		vec2 from = xy(plr.m_unit.GetPosition());
		vec2 d(parseFloat(args[0]), parseFloat(args[1]));
		int steps = max(1, min(64, int(parseInt(args[2]))));
		array<int> diams;
		for (uint i = 3; i < args.length() && diams.length() < 8; i++)
			diams.insertLast(int(parseInt(args[i])));
		if (diams.length() == 0)
			diams.insertLast(PATH_DIAMETER);
		auto reply = Reply(id, true).Num("x", from.x).Num("y", from.y).Int("steps", steps);
		for (uint j = 0; j < diams.length(); j++)
		{
			string bits = "";
			for (int k = 1; k <= steps; k++)
			{
				auto path = g_scene.Pathfind(from, from + d * (float(k) / steps), diams[j]);
				bits += (path !is null && path.length() > 0) ? "1" : "0";
			}
			reply.Str("d" + diams[j], bits);
		}
		Emit(reply);
	}

	// pfbench <n> <dx> <dy> [preN preDx preDy]: read-only. n identical Pathfind calls in one
	// frame, from the player to player + (dx,dy), after preN calls to another offset; how many
	// answered and the first that did not (a per-frame budget shows as answers stopping partway).
	void VerbPfBench(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null || args.length() < 3)
		{
			Fail(id, plr is null ? "no spawned local player" : "usage: pfbench <n> <dx> <dy> [preN preDx preDy]");
			return;
		}
		vec2 from = xy(plr.m_unit.GetPosition());
		// optional warm-up: preN calls to another target in the same frame first
		int pre = args.length() > 5 ? min(5000, int(parseInt(args[3]))) : 0;
		int preOk = 0;
		for (int i = 0; i < pre; i++)
			if (PathOk(from, from + vec2(parseFloat(args[4]), parseFloat(args[5]))))
				preOk++;
		int n = min(5000, int(parseInt(args[0])));
		vec2 to = from + vec2(parseFloat(args[1]), parseFloat(args[2]));
		int answered = 0, firstFail = -1;
		for (int i = 0; i < n; i++)
		{
			if (PathOk(from, to))
				answered++;
			else if (firstFail < 0)
				firstFail = i;
		}
		Emit(Reply(id, true).Int("n", n).Int("answered", answered).Int("firstFail", firstFail)
			.Int("pre", pre).Int("preAnswered", preOk).Num("dist", dist(from, to)));
	}

	// ---- eyes: semantic scan --------------------------------------------------

	const uint SCAN_CAP = 32;

	string ScanUnit(UnitPtr u, vec2 from)
	{
		Json e;
		vec3 p = u.GetPosition();
		e.Int("unit", u.GetId()).Str("name", u.GetDebugName()).Num("x", p.x).Num("y", p.y).Num("dist", dist(from, xy(p)));
		return e.Close();
	}

	// scan [radius]: the scene sorted into what a player acts on. Every category names the
	// field it comes from, and "raw" is the unfiltered unit list (count + first SCAN_CAP).
	void VerbScan(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null)
		{
			Fail(id, "no spawned local player");
			return;
		}
		int radius = args.length() > 0 ? int(parseInt(args[0])) : 300;
		vec2 c = xy(plr.m_unit.GetPosition());

		array<string> enemies;
		auto foes = g_scene.FetchActorsWithOtherTeam(g_team_player, c, radius);
		for (uint i = 0; i < foes.length() && enemies.length() < SCAN_CAP; i++)
		{
			auto a = ActorOf(foes[i]);
			if (a is null || a.IsDead() || !a.IsTargetable())
				continue;
			Json e;
			vec3 p = foes[i].GetPosition();
			e.Int("unit", foes[i].GetId()).Str("name", foes[i].GetDebugName()).Num("x", p.x).Num("y", p.y)
				.Num("dist", dist(c, xy(p))).Num("hp", a.GetHealth());
			enemies.insertLast(e.Close());
		}

		array<string> usables;
		array<string> raw;
		auto all = g_scene.FetchAllUnits(~0, c, radius);
		for (uint i = 0; i < all.length(); i++)
		{
			if (!all[i].IsValid() || all[i].IsDestroyed() || all[i] == plr.m_unit)
				continue;
			if (raw.length() < SCAN_CAP)
				raw.insertLast(ScanUnit(all[i], c));
			auto u = cast<IUsable>(all[i].GetScriptBehavior());
			if (u !is null && usables.length() < SCAN_CAP)
			{
				Json e;
				vec3 p = all[i].GetPosition();
				e.Int("unit", all[i].GetId()).Str("name", all[i].GetDebugName()).Str("type", Reflect::GetTypeName(u))
					.Num("x", p.x).Num("y", p.y).Num("dist", dist(c, xy(p))).Bool("canUse", u.CanUse(plr));
				usables.insertLast(e.Close());
			}
		}

		array<string> exits;
		array<string> types = { "LevelExitAreaNext", "LevelExitNext" };
		for (uint t = 0; t < types.length(); t++)
		{
			auto list = g_scene.FetchAllWorldScripts(types[t]);
			for (uint i = 0; i < list.length(); i++)
			{
				Json e;
				vec3 p = list[i].GetUnit().GetPosition();
				e.Int("unit", list[i].GetUnit().GetId()).Str("type", types[t]).Bool("enabled", list[i].IsEnabled())
					.Num("x", p.x).Num("y", p.y).Num("dist", dist(c, xy(p)));
				exits.insertLast(e.Close());
			}
		}

		Json src;
		src.Str("enemies", "Scene.FetchActorsWithOtherTeam(g_team_player): Actor.Team (Actor.as:3) != HashString(player) (Actor.as:184), alive and IsTargetable")
			.Str("usables", "unit script behavior implements IUsable (IUsable.as:33); canUse = IUsable.CanUse(player)")
			.Str("exits", "Scene.FetchAllWorldScripts(LevelExitAreaNext|LevelExitNext), whole level; enabled = WorldScript.IsEnabled")
			.Str("raw", "Scene.FetchAllUnits(~0, player, radius), first " + SCAN_CAP);
		Emit(Reply(id, true).Int("radius", radius).Num("x", c.x).Num("y", c.y).Str("level", GetCurrentLevelFilename())
			.Str("place", Place()).Int("enemyCount", enemies.length()).Int("usableCount", usables.length()).Int("exitCount", exits.length())
			.Raw("enemies", RawArray(enemies)).Raw("usables", RawArray(usables)).Raw("exits", RawArray(exits))
			.Int("rawCount", all.length()).Raw("raw", RawArray(raw)).Raw("sources", src.Close()));
	}
}

namespace Modules
{
	class GameLabPilotModule : Module
	{
		GameLabPilotModule()
		{
			super("gamelab-pilot");
			GameLab::RegisterVerb("pilot", "<intent|pause|resume|step|target|stop|status|reflex> [args] [until=..] [timeout=ms]", GameLab::Verb(GameLab::VerbPilot));
			GameLab::RegisterVerb("scan", "[radius]", GameLab::Verb(GameLab::VerbScan));
			GameLab::RegisterVerb("pathfind", "x y [diameter] [maxDistance] [maxRange] [fromX fromY]", GameLab::Verb(GameLab::VerbPathfind));
			GameLab::RegisterVerb("reachmap", "x0 y0 x1 y1 step", GameLab::Verb(GameLab::VerbReachmap));
			GameLab::RegisterVerb("exitareas", "[radius]", GameLab::Verb(GameLab::VerbExitAreas));
			GameLab::RegisterVerb("routesweep", "[spacing] [offset]", GameLab::Verb(GameLab::VerbRouteSweep));
			GameLab::RegisterVerb("bodies", "<x> <y> [step]", GameLab::Verb(GameLab::VerbBodies));
			GameLab::RegisterVerb("breakables", "[radius]", GameLab::Verb(GameLab::VerbBreakables));
			GameLab::RegisterVerb("exitprobe", "[refX refY]", GameLab::Verb(GameLab::VerbExitProbe));
			GameLab::RegisterVerb("pfsweep", "<dx> <dy> <steps> [diam...]", GameLab::Verb(GameLab::VerbPfSweep));
			GameLab::RegisterVerb("pfbench", "<n> <dx> <dy> [preN preDx preDy]", GameLab::Verb(GameLab::VerbPfBench));
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused)
				return;
			try {
				GameLab::PilotFrame(ms, gameInput);
			} catch {
				GameLab::g_exceptions++;
				GameLab::PilotEnd("failed", "exception in the pilot frame");
			}
		}
	}
}
