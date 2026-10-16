// Gambler NPC Module
// Spawns the gambler NPC in the tavern without needing to override prefab files

namespace Modules
{
	class GamblerNPCModule : Module
	{
		bool m_spawned = false;
		int m_delay = 0;

		GamblerNPCModule()
		{
			super("gambler-npc");
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused || m_spawned)
				return;

			// Wait for scene to fully load
			m_delay += ms;
			if (m_delay < 500)
				return;

			// Only spawn in town
			if (!g_inTown)
			{
				m_spawned = true;
				return;
			}

			if (g_currTownRecord is null)
				return;

			// Check if tavern exists (has been built)
			int tavernLevel = g_currTownRecord.GetVariationOnBuilding(HashString("tavern"));
			if (tavernLevel < 0)
			{
				m_spawned = true;
				return;
			}

			// Tavern is placed at fixed position (-64, -176) in town base segment
			// NPC offset from prefab: (-60, 70)
			// Final position: (-124, -106)
			vec3 spawnPos = vec3(-64.0f + (-60.0f), -176.0f + 70.0f, 0.0f);

			auto prod = Resources::GetUnitProducer("actors/npcs/town/npc_gambler.unit");
			if (prod !is null)
			{
				prod.Produce(g_scene, spawnPos);
				m_spawned = true;
			}
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			// Reset when loading a new level
			m_spawned = false;
			m_delay = 0;
		}
	}
}
