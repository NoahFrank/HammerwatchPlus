// Gold Collector Pet Module
// Spawns the pet vendor NPC in hunter's cabin and auto-respawns pet when player enters a level

namespace Modules
{
	class GoldPetModule : Module
	{
		dictionary m_petsSpawned;  // Track spawned pets per player (by peer ID)
		dictionary m_syncedTiers;  // Pet tiers synced from clients (server-side)
		bool m_vendorSpawned = false;
		bool m_localTierSynced = false;  // Has local client synced their tier to server?
		int m_checkDelay = 0;
		int m_startupDelay = 0;  // Delay after level load before doing anything

		GoldPetModule()
		{
			super("gold-pet");
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused)
				return;

			// Wait 2 seconds after level load before doing anything
			// This prevents network messages during level transitions
			m_startupDelay += ms;
			if (m_startupDelay < 2000)
				return;

			// Small delay between checks
			m_checkDelay += ms;
			if (m_checkDelay < 500)
				return;
			m_checkDelay = 0;

			// Spawn vendor NPC in town (one-time, server only)
			if (!m_vendorSpawned)
			{
				m_vendorSpawned = true;
				if (Network::IsServer())
					SpawnVendor();
			}

			// Client: Sync local pet tier to server (once per level)
			if (!Network::IsServer() && !m_localTierSynced)
			{
				SyncLocalTierToServer();
			}

			// Server: Spawn pets for players
			if (Network::IsServer())
			{
				TrySpawnPets();
			}
		}

		// Client sends their pet tier to the server by re-setting their CharFlags
		void SyncLocalTierToServer()
		{
			auto local = GetLocalPlayerRecord();
			if (local is null || local.actor is null)
				return;

			m_localTierSynced = true;

			// Get local tier from our own CharFlags (which we CAN read)
			int tier = GoldPet::GetPlayerPetTier(local);
			print("[GoldPet] Client syncing tier " + tier + " to server (peer " + local.peer + ")");

			// Re-send CharFlags to server so it knows our tier
			if (tier >= 1)
				local.SetCharFlag(HashString("has_gold_pet"), true);
			if (tier >= 2)
				local.SetCharFlag(HashString("has_gold_pet_tier_2"), true);
			if (tier >= 3)
				local.SetCharFlag(HashString("has_gold_pet_tier_3"), true);
		}

		void TrySpawnPets()
		{
			// Iterate over ALL players in the game
			for (uint i = 0; i < g_players.length(); i++)
			{
				auto player = g_players[i];
				TrySpawnPetForPlayer(player);
			}
		}

		void TrySpawnPetForPlayer(PlayerRecord@ player)
		{
			if (player is null)
				return;

			// Skip invalid peer IDs (valid peers are 0-3 for 4-player game)
			// Peer 255 is often used as an uninitialized/invalid value
			if (player.peer > 3)
				return;

			// Use peer ID as key to track per-player spawn state
			string playerKey = "" + player.peer;

			// Already processed this player?
			bool alreadySpawned = false;
			m_petsSpawned.get(playerKey, alreadySpawned);
			if (alreadySpawned)
				return;

			if (player.actor is null)
			{
				print("[GoldPet] Waiting for actor for player " + player.GetName() + " (peer " + player.peer + ")...");
				return;
			}

			// Check player's pet tier
			int tier = GoldPet::GetPlayerPetTier(player);

			if (tier <= 0)
			{
				// For remote players (clients), wait for them to sync their tier
				// Don't mark as "done" yet - they might just not have synced
				if (!player.local)
				{
					// Track how many times we've checked this player
					int checks = 0;
					m_syncedTiers.get(playerKey, checks);
					checks++;
					m_syncedTiers.set(playerKey, checks);

					// Wait up to 10 seconds (20 checks at 500ms) for sync
					if (checks < 20)
					{
						if (checks == 1)
							print("[GoldPet] Waiting for tier sync from " + player.GetName() + " (peer " + player.peer + ")...");
						return;
					}
					// Timeout - they really don't have a pet
					print("[GoldPet] Timeout waiting for sync, player " + player.GetName() + " does not own pet");
				}
				else
				{
					print("[GoldPet] Local player " + player.GetName() + " does not own pet (tier=" + tier + ")");
				}

				m_petsSpawned.set(playerKey, true);
				return;
			}

			print("[GoldPet] Player " + player.GetName() + " (peer " + player.peer + ") has tier " + tier);

			// Check if pet already exists in scene
			if (GoldPet::IsPetAliveForPlayer(player))
			{
				m_petsSpawned.set(playerKey, true);
				print("[GoldPet] Pet already exists for " + player.GetName());
				return;
			}

			// Spawn the pet at the correct tier
			GoldPet::SpawnPetForPlayer(player, tier);
			m_petsSpawned.set(playerKey, true);
			print("[GoldPet] Auto-spawned tier " + tier + " pet for " + player.GetName());
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			// Reset flags when loading a new level
			m_petsSpawned.deleteAll();
			m_syncedTiers.deleteAll();
			m_vendorSpawned = false;
			m_localTierSynced = false;
			m_checkDelay = 0;
			m_startupDelay = 0;
		}

		void SpawnVendor()
		{
			// Only spawn in town
			if (!g_inTown)
				return;

			if (g_currTownRecord is null)
				return;

			// Check if hunter's cabin exists (has been built)
			int cabinLevel = g_currTownRecord.GetVariationOnBuilding(HashString("hunters_cabin"));
			if (cabinLevel < 0)
				return;

			// Hunter's cabin base position: (1056, 768)
			// Vendor offset: (-20, -40) - inside cabin, near the hunter NPC at (6, -40)
			vec3 spawnPos = vec3(1056.0f + (-20.0f), 768.0f + (-40.0f), 0.0f);

			auto prod = Resources::GetUnitProducer("actors/npcs/town/npc_pet_vendor.unit");
			if (prod !is null)
			{
				prod.Produce(g_scene, spawnPos);
				print("[GoldPet] Spawned pet vendor in hunter's cabin");
			}
		}
	}
}
