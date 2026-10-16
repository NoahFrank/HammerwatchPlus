// Pets wait outside puzzle rooms. info.xml classmaps replace the two base pet
// behaviours with the subclasses below; each owns a Watcher that, a few times a
// second, looks for puzzle units around the owner. While any are near, the pet
// walks back to the last owner position that was clear of puzzles and idles
// there (no pickups, no following); it resumes when the owner moves away.
//
// Puzzle units are plain doodads without behaviours, so they are recognised by
// producer path: doodads/buttons/* (magic / number / lever buttons) and anything
// with "puzzle" in the path (prefabs/puzzles/*, puzzle_brazier, puzzle_chance).
namespace HWP
{
	namespace PetWait
	{
		const int CHECK_MS = 400;

		bool g_loggedWalking = false;
		bool g_loggedFlying = false;
		bool g_enabled = true;
		int g_radius = 120;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("petwait.enabled", true);
			g_radius = HWP::Settings::GetInt("petwait.radius", 120);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("petwait.") == 0)
				RefreshSettings();
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

				if (!m_waiting)
					return false;

				vec2 from = xy(pet.m_unit.GetPosition());
				vec2 delta = m_waitPos - from;
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
					pet.m_unit.SetPosition(m_waitPos.x, m_waitPos.y, 0, false);
					if (m_flying)
						pet.m_unit.SetUnitScene(pet.m_animWalk.GetSceneName(m_angle), false);
					else
						pet.m_unit.SetUnitScene(pet.m_animIdle.GetSceneName(m_angle), false);
				}
				pet.m_stayPos = m_waitPos;
				return true;
			}
		}
	}
}

class HWPMiniPetWalking : MiniPetWalking
{
	HWP::PetWait::Watcher m_wait;

	HWPMiniPetWalking(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		if (!HWP::PetWait::g_loggedWalking)
		{
			HWP::PetWait::g_loggedWalking = true;
			HWP::Log("petwait", "classmap active: MiniPetWalking -> HWPMiniPetWalking");
		}
	}

	void Update(int dt) override
	{
		if (m_wait.Update(dt, this))
			return;
		MiniPetWalking::Update(dt);
	}
}

class HWPMiniPetFlying : MiniPetFlying
{
	HWP::PetWait::Watcher m_wait;

	HWPMiniPetFlying(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_wait.m_flying = true;
		if (!HWP::PetWait::g_loggedFlying)
		{
			HWP::PetWait::g_loggedFlying = true;
			HWP::Log("petwait", "classmap active: MiniPetFlying -> HWPMiniPetFlying");
		}
	}

	void Update(int dt) override
	{
		if (m_wait.Update(dt, this))
		{
			m_dir = m_wait.m_angle;
			m_currentSpeed = 0;
			return;
		}
		MiniPetFlying::Update(dt);
	}
}

namespace Modules
{
	class HWPPetWaitModule : Module
	{
		HWPPetWaitModule()
		{
			super("hwp-petwait");
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::PetWait::OnSettingChanged));
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::PetWait::RefreshSettings();
		}
	}
}
