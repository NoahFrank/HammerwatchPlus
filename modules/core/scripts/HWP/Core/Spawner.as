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

		// Distinct producers of the live enemies within radius of pos (at most maxN).
		array<UnitProducer@>@ SampleProducers(vec2 pos, int radius, int maxN)
		{
			array<UnitProducer@> ret;
			auto units = g_scene.FetchActorsWithOtherTeam(g_team_player, pos, radius);
			for (uint i = 0; i < units.length() && int(ret.length()) < maxN; i++)
			{
				CompositeActorBehavior@ beh;
				if (!IsSpawnable(units[i], beh))
					continue;
				auto prod = units[i].GetUnitProducer();
				bool dup = false;
				for (uint j = 0; j < ret.length(); j++)
					if (ret[j] is prod)
						dup = true;
				if (!dup)
					ret.insertLast(prod);
			}
			return ret;
		}

		// actors/x/foo.unit -> actors/x/foo_elite.unit when that unit exists.
		UnitProducer@ EliteVariant(UnitProducer@ prod)
		{
			if (prod is null)
				return null;
			string p = prod.GetResourceName();
			if (p.findFirst("_elite") >= 0)
				return prod;
			if (p.findLast(".unit") != int(p.length()) - 5)
				return null;
			string elite = p.substr(0, p.length() - 5) + "_elite.unit";
			return Resources::GetUnitProducer(elite);
		}

		// Host only. Spawns count units around center and returns their ids.
		array<uint>@ SpawnPack(array<UnitProducer@>@ prods, vec3 center, int count, float spread, bool loot)
		{
			array<uint> ids;
			if (!Network::IsServer() || prods is null || prods.length() == 0)
				return ids;
			for (int i = 0; i < count; i++)
			{
				auto prod = prods[randi(prods.length())];
				if (!loot)
					@prod = prod.WithProperties("Loot=false");
				vec2 off = randdir() * spread * (0.4f + 0.6f * randf());
				auto u = prod.Produce(g_scene, center + vec3(off.x, off.y, 0));
				if (u.IsValid())
					ids.insertLast(u.GetId());
			}
			return ids;
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
