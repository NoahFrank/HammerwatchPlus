// Pets wait outside puzzle rooms. The HWP pet subclasses (PetClasses.as)
// each own a Watcher that, a few times a second, looks for puzzle units around
// the owner. While any are near, the pet walks back to the last owner position
// that was clear of puzzles and idles there (no pickups, no following, no
// skills); it resumes when the owner moves away.
//
// The same parking serves the candle's Secret Sense: the pet sets m_hold and
// m_holdPos (HWP::Pets::SkillRunner.UpdateSecrets) and the pet hovers there.
//
// Puzzle units are plain doodads without behaviours, so they are recognised by
// producer path: doodads/buttons/* (magic / number / lever buttons) and anything
// with "puzzle" in the path (prefabs/puzzles/*, puzzle_brazier, puzzle_chance).
namespace HWP
{
	namespace PetWait
	{
		const int CHECK_MS = 400;

		bool g_enabled = true;
		int g_radius = 120;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("petwait.enabled", true);
			g_radius = HWP::Settings::GetInt("petwait.radius", 120);
		}

		bool IsPuzzleUnit(UnitPtr unit)
		{
			if (!unit.IsValid())
				return false;
			auto prod = unit.GetUnitProducer();
			if (prod is null)
				return false;
			string path = prod.GetResourceName();
			if (path.findFirst("doodads/buttons/") == 0)
				return true;
			if (path.findFirst("puzzle") >= 0)
				return true;
			return false;
		}

		bool NearPuzzle(vec2 pos)
		{
			auto results = g_scene.QueryCircle(pos, g_radius, ~0, RaycastType::Any, true);
			for (uint i = 0; i < results.length(); i++)
			{
				UnitPtr unit = results[i];
				if (IsPuzzleUnit(unit))
					return true;
			}
			return false;
		}

		class Watcher
		{
			int m_timer;
			bool m_waiting;
			bool m_hasFree;
			bool m_flying;
			vec2 m_waitPos;
			vec2 m_lastFree;
			float m_angle;
			bool m_hold;     // set by the pet each frame: park at m_holdPos (before puzzles)
			bool m_wasHold;
			vec2 m_holdPos;

			// true = the pet is parked this frame and the base Update must be skipped
			bool Update(int dt, MiniPet@ pet)
			{
				if (pet.m_owner is null || !pet.m_owner.m_unit.IsValid() || !pet.m_unit.IsValid())
					return false;

				vec2 ownerPos = xy(pet.m_owner.m_unit.GetPosition());
				m_timer -= dt;
				if (m_timer <= 0)
				{
					m_timer = CHECK_MS;
					bool near = g_enabled && NearPuzzle(ownerPos);
					if (near && !m_waiting)
					{
						m_waiting = true;
						m_waitPos = m_hasFree ? m_lastFree : xy(pet.m_unit.GetPosition());
						pet.ClearTarget();
					}
					else if (!near)
					{
						m_lastFree = ownerPos;
						m_hasFree = true;
						if (m_waiting)
						{
							m_waiting = false;
							pet.ClearTarget();
							pet.m_targetingDelay = 0;
						}
					}
				}

				if (m_wasHold && !m_hold)
				{
					pet.ClearTarget();
					pet.m_targetingDelay = 0;
				}
				else if (m_hold && !m_wasHold)
					pet.ClearTarget();
				m_wasHold = m_hold;
				if (!m_waiting && !m_hold)
					return false;

				vec2 target = m_hold ? m_holdPos : m_waitPos;
				vec2 from = xy(pet.m_unit.GetPosition());
				vec2 delta = target - from;
				float len = length(delta);
				float step = pet.m_speed * dt / 33.0f;
				if (len > step && len > 1.0f)
				{
					vec2 dir = delta / len;
					m_angle = atan(dir.y, dir.x);
					vec2 np = from + dir * step;
					pet.m_unit.SetPosition(np.x, np.y, 0, true);
					pet.m_unit.SetUnitScene(pet.m_animWalk.GetSceneName(m_angle), true);
				}
				else
				{
					pet.m_unit.SetPosition(target.x, target.y, 0, false);
					if (m_flying)
						pet.m_unit.SetUnitScene(pet.m_animWalk.GetSceneName(m_angle), false);
					else
						pet.m_unit.SetUnitScene(pet.m_animIdle.GetSceneName(m_angle), false);
				}
				pet.m_stayPos = target;
				return true;
			}
		}
	}
}
