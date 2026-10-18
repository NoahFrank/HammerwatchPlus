// Spawns the gambler NPC inside the tavern once the tavern is built. The NPC is
// placed by code instead of editing the tavern prefabs, so no base file is
// overridden. Only the server produces the unit (it is netsynced).
namespace Modules
{
	class HWPGamblerModule : Module, HWP::ModuleStart
	{
		bool m_done = false;
		int m_delay = 0;

		HWPGamblerModule()
		{
			super("hwp-gambler");
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused || m_done)
				return;

			// let the scene settle before producing units
			m_delay += ms;
			if (m_delay < 500)
				return;

			if (!g_inTown || !Network::IsServer())
			{
				m_done = true;
				return;
			}
			if (g_currTownRecord is null)
				return;

			m_done = true;
			if (g_currTownRecord.GetVariationOnBuilding(HashString("tavern")) < 0)
			{
				HWP::Log("gambler", "no tavern built yet, no gambler");
				return;
			}

			// tavern segment at (-64, -176) in the town base level, NPC offset (-60, 70)
			vec3 spawnPos = vec3(-124.0f, -106.0f, 0.0f);
			auto prod = Resources::GetUnitProducer("actors/npcs/town/hwp_gambler.unit");
			if (prod is null)
			{
				HWP::LogError("gambler", "missing actors/npcs/town/hwp_gambler.unit");
				return;
			}
			UnitPtr npc = prod.Produce(g_scene, spawnPos);
			if (!npc.IsValid())
			{
				HWP::LogError("gambler", "Produce returned no unit at (-124, -106)");
				return;
			}
			HWP::Log("gambler", "spawned the gambler in the tavern (unit " + npc.GetId() + " at -124,-106)");
		}

		void Start(StartMode sMode)
		{
			m_done = false;
			m_delay = 0;
		}
	}
}
