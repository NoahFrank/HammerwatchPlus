// HWP::Spawner - host-side helpers for modules that spawn enemy packs at
// runtime (strongbox, abyss). Enemies are sampled from what the level already
// placed near a point, so a pack always fits the biome and the difficulty.
// Enemy units are netsynced, so producing them on the host is enough.
namespace HWP
{
	namespace Spawner
	{
		// Enemies that are not sensible as a summoned pack member.
		bool IsSpawnable(UnitPtr u, CompositeActorBehavior@ &out beh)
		{
			@beh = null;
			if (!u.IsValid() || u.IsDestroyed())
				return false;
			@beh = cast<CompositeActorBehavior>(u.GetScriptBehavior());
			if (beh is null || beh.IsDead())
				return false;
			if ((beh.Tags & ApplyTag(0, g_actorTags.GetTag("boss"))) != 0)
				return false;
			auto prod = u.GetUnitProducer();
			if (prod is null)
				return false;
			string p = prod.GetResourceName();
			if (p.findFirst("/bosses/") >= 0 || p.findFirst("spawner") >= 0 || p.findFirst("nest") >= 0
				|| p.findFirst("blockade") >= 0 || p.findFirst("/plants/") >= 0 || p.findFirst("burrow") >= 0
				|| p.findFirst("_elite") >= 0 || p.findFirst("ballista") >= 0 || p.findFirst("tower") >= 0)
				return false;
			return true;
		}

		// Distinct base producers of the live enemies within radius of pos (at most
		// maxN). A placed enemy may come from a WithProperties("Loot=false") variant
		// of its unit, so the producer is resolved back to the plain resource and
		// de-duplicated by name; SpawnPack then applies its own loot flag.
		array<UnitProducer@>@ SampleProducers(vec2 pos, int radius, int maxN)
		{
			array<UnitProducer@> ret;
			array<string> names;
			auto units = g_scene.FetchActorsWithOtherTeam(g_team_player, pos, radius);
			for (uint i = 0; i < units.length() && int(ret.length()) < maxN; i++)
			{
				CompositeActorBehavior@ beh;
				if (!IsSpawnable(units[i], beh))
					continue;
				string name = units[i].GetUnitProducer().GetResourceName();
				if (names.find(name) >= 0)
					continue;
				auto prod = Resources::GetUnitProducer(name);
				if (prod is null)
					continue;
				names.insertLast(name);
				ret.insertLast(prod);
			}
			return ret;
		}

		// The vanilla enemies that have an _elite.unit twin (resource lookups of
		// missing units are logged by the engine, so the table is static).
		const array<string> ELITES = {
			"actors/beasts/goblins/goblin_berserker", "actors/beasts/goblins/goblin_redcap",
			"actors/beasts/goblins/goblin_shaman", "actors/beasts/goblins/goblin_skulker",
			"actors/beasts/wasps/black_jacket", "actors/beasts/wasps/red_jacket", "actors/beasts/wasps/yellow_jacket",
			"actors/beasts/wolves/wolf_black", "actors/beasts/wolves/wolf_grey",
			"actors/humans/bandits/bandit_brute", "actors/humans/bandits/bandit_hunter",
			"actors/humans/bandits/bandit_mage", "actors/humans/bandits/bandit_rogue",
			"actors/humans/cult/cult_acolyte", "actors/humans/cult/cult_assassin",
			"actors/undead/court/court_doomsayer", "actors/undead/court/court_executioner",
			"actors/undead/court/court_sniper", "actors/undead/court/court_wizard",
			"actors/undead/guard/guard_defender", "actors/undead/guard/guard_footman",
			"actors/undead/guard/guard_mage", "actors/undead/guard/guard_mage_shadow", "actors/undead/guard/guard_sentry",
			"actors/undead/horde/horde_necromancer", "actors/undead/horde/horde_ranger",
			"actors/undead/horde/horde_soldier", "actors/undead/horde/horde_sorcerer", "actors/undead/horde/horde_warrior" };

		// actors/x/foo.unit -> actors/x/foo_elite.unit when that unit exists, else null.
		UnitProducer@ EliteVariant(UnitProducer@ prod)
		{
			if (prod is null)
				return null;
			string p = prod.GetResourceName();
			if (p.findFirst("_elite") >= 0)
				return prod;
			if (p.findLast(".unit") != int(p.length()) - 5)
				return null;
			string stem = p.substr(0, p.length() - 5);
			if (ELITES.find(stem) < 0)
				return null;
			return Resources::GetUnitProducer(stem + "_elite.unit");
		}

		// Players with an actor in the level (at least 1, for pack sizing).
		int PlayerCount()
		{
			int n = 0;
			for (uint i = 0; i < g_players.length(); i++)
				if (g_players[i] !is null && g_players[i].actor !is null)
					n++;
			return max(1, n);
		}

		// A spot up to spread px from center that is free of collision and in
		// line of sight of the center (so it is not inside a wall or behind one).
		// Mirrors the vanilla Skills::SpawnUnit "safe-spawn" checks. The sight
		// line starts `inner` px out: pass more than the radius of whatever
		// stands at center (a fountain is 32), or every ray starts inside it.
		bool FreeSpot(vec3 center, float spread, vec3 &out pos, float inner = 14.0f)
		{
			vec2 c = xy(center);
			float lo = max(spread * 0.4f, inner + 8.0f);
			if (lo > spread)
				spread = lo;
			for (int t = 0; t < 8; t++)
			{
				vec2 dir = randdir();
				vec2 p = c + dir * (lo + (spread - lo) * randf());
				if (g_scene.QueryRect(p, 6, 6, ~0, RaycastType::Any).length() > 0)
					continue;
				if (g_scene.RaycastQuick(c + dir * inner, p, ~0, RaycastType::Any))
					continue;
				pos = vec3(p.x, p.y, center.z);
				return true;
			}
			return false;
		}

		// Host only. Spawns up to count units on free spots around center and
		// returns their ids; members with no free spot are skipped rather than
		// put inside a wall.
		array<uint>@ SpawnPack(array<UnitProducer@>@ prods, vec3 center, int count, float spread, bool loot)
		{
			array<uint> ids;
			if (!Network::IsServer() || prods is null || prods.length() == 0)
				return ids;
			int skipped = 0;
			for (int i = 0; i < count; i++)
			{
				auto prod = prods[randi(prods.length())];
				if (!loot)
					@prod = prod.WithProperties("Loot=false");
				vec3 at;
				if (!FreeSpot(center, spread, at))
				{
					skipped++;
					continue;
				}
				auto u = prod.Produce(g_scene, at);
				if (u.IsValid())
					ids.insertLast(u.GetId());
			}
			if (skipped > 0)
				HWP::Log("spawner", "skipped " + skipped + " pack member(s): no free spot within " + int(spread) + " px");
			return ids;
		}

		// Shared once-per-level placement timing for the modules that drop one
		// object per level (strongbox, abyss): host only, not in town, after the
		// level's enemies and the host's player exist. Tick returns true exactly
		// once per level, when the module should roll its chance and place.
		class LevelPlacer
		{
			int m_delay = 0;
			bool m_done = false;

			void Reset() { m_delay = 0; m_done = false; }

			bool Tick(int ms, bool paused, int delayMs, bool enabled)
			{
				if (m_done || paused)
					return false;
				m_delay += ms;
				if (m_delay < delayMs)
					return false;
				if (!Network::IsServer() || g_inTown || !enabled)
				{
					m_done = true;
					return false;
				}
				auto rec = GetLocalPlayerRecord();
				if (rec is null || rec.actor is null)
				{
					if (m_delay > 10000)
						m_done = true;
					return false;
				}
				m_done = true;
				return true;
			}
		}

		int Alive(array<uint>@ ids)
		{
			int n = 0;
			for (uint i = 0; i < ids.length(); i++)
			{
				UnitPtr u = g_scene.GetUnit(ids[i]);
				if (!u.IsValid() || u.IsDestroyed())
					continue;
				auto actor = cast<Actor>(u.GetScriptBehavior());
				if (actor is null || actor.IsDead())
					continue;
				n++;
			}
			return n;
		}

		bool AllDead(array<uint>@ ids) { return Alive(ids) == 0; }

		float DistToNearestPlayer(vec3 pos)
		{
			float best = 1e12f;
			for (uint i = 0; i < g_players.length(); i++)
			{
				auto rec = g_players[i];
				if (rec is null || rec.actor is null || !rec.actor.m_unit.IsValid())
					continue;
				float d = distsq(xy(pos), xy(rec.actor.m_unit.GetPosition()));
				if (d < best)
					best = d;
			}
			return best >= 1e12f ? -1.0f : sqrt(best);
		}

		// The position of a random live enemy at least minDist from every player:
		// a spot that is reachable, in the level and not in the players' faces.
		bool PickFarSpot(float minDist, vec3 &out pos)
		{
			auto enemies = g_scene.FetchAllActorsWithOtherTeam(g_team_player);
			if (enemies.length() == 0)
				return false;
			uint start = randi(enemies.length());
			for (uint k = 0; k < enemies.length(); k++)
			{
				UnitPtr u = enemies[(start + k) % enemies.length()];
				CompositeActorBehavior@ beh;
				if (!IsSpawnable(u, beh))
					continue;
				vec3 p = u.GetPosition();
				float d = DistToNearestPlayer(p);
				if (d >= 0 && d < minDist)
					continue;
				pos = p;
				return true;
			}
			return false;
		}

		PlayerBase@ NearestPlayer(vec3 pos)
		{
			PlayerBase@ best;
			float bestD = 1e12f;
			for (uint i = 0; i < g_players.length(); i++)
			{
				auto rec = g_players[i];
				if (rec is null || rec.actor is null || !rec.actor.m_unit.IsValid())
					continue;
				auto pb = cast<PlayerBase>(rec.actor);
				if (pb is null)
					continue;
				float d = distsq(xy(pos), xy(rec.actor.m_unit.GetPosition()));
				if (d < bestD)
				{
					bestD = d;
					@best = pb;
				}
			}
			return best;
		}
	}
}
