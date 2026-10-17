// Spawns the pet vendor in the Hunter's Lodge (server only) and re-summons each
// player's pet when a level starts.
//
// Clients cannot read other players' char flags, so a client re-sets its own
// pet flags once per level; that sync reaches the server, which then spawns the
// pet for that peer. Waiting is logged once per player, not every tick.
namespace Modules
{
	class HWPGoldPetModule : Module, HWP::ModuleStart
	{
		dictionary m_petsSpawned;    // peer -> done
		dictionary m_syncChecks;     // peer -> polls spent waiting for the tier sync
		dictionary m_waitLogged;     // peer -> "waiting for actor" already logged
		bool m_vendorSpawned = false;
		bool m_localTierSynced = false;
		int m_checkDelay = 0;
		int m_startupDelay = 0;

		HWPGoldPetModule()
		{
			super("hwp-goldpet");
			HWP::Net::OnRequest(HWP::GoldPet::SPAWN_REQUEST, HWP::GoldPet::OnSpawnRequest);
			HWP::Pets::RegisterExternal(HWP::GoldPet::PET_ID, ".hwp.goldpet.pet_name", HWP::Pets::ExternalCheck(HWP::GoldPet::HasGoldPet));
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused)
				return;

			// no network traffic during the level transition
			m_startupDelay += ms;
			if (m_startupDelay < 2000)
				return;

			m_checkDelay += ms;
			if (m_checkDelay < 500)
				return;
			m_checkDelay = 0;

			if (!m_vendorSpawned)
			{
				m_vendorSpawned = true;
				if (Network::IsServer())
					SpawnVendor();
			}

			if (!Network::IsServer() && !m_localTierSynced)
				SyncLocalTierToServer();

			if (Network::IsServer())
			{
				for (uint i = 0; i < g_players.length(); i++)
					TrySpawnPetForPlayer(g_players[i]);
			}
		}

		void SyncLocalTierToServer()
		{
			auto local = GetLocalPlayerRecord();
			if (local is null || local.actor is null)
				return;

			m_localTierSynced = true;
			int tier = HWP::GoldPet::GetPlayerPetTier(local);
			if (tier <= 0)
				return;
			HWP::Log("goldpet", "syncing pet tier " + tier + " to the host");
			if (tier >= 1)
				local.SetCharFlag(HashString("has_gold_pet"), true);
			if (tier >= 2)
				local.SetCharFlag(HashString("has_gold_pet_tier_2"), true);
			if (tier >= 3)
				local.SetCharFlag(HashString("has_gold_pet_tier_3"), true);
		}

		void TrySpawnPetForPlayer(PlayerRecord@ player)
		{
			if (player is null || player.peer > 3) // 255 = unassigned
				return;

			string key = "" + player.peer;
			bool done = false;
			m_petsSpawned.get(key, done);
			if (done)
				return;

			if (player.actor is null)
			{
				if (!m_waitLogged.exists(key))
				{
					m_waitLogged.set(key, true);
					HWP::Log("goldpet", "waiting for the actor of " + player.GetName() + " (peer " + player.peer + ")");
				}
				return;
			}

			int tier = HWP::GoldPet::GetPlayerPetTier(player);
			if (tier <= 0)
			{
				if (!player.local)
				{
					// remote players: give the tier sync up to 10 s (20 polls) to arrive
					int checks = 0;
					m_syncChecks.get(key, checks);
					checks++;
					m_syncChecks.set(key, checks);
					if (checks < 20)
						return;
				}
				m_petsSpawned.set(key, true);
				return;
			}

			m_petsSpawned.set(key, true);
			if (HWP::GoldPet::IsPetAliveForPlayer(player))
				return;
			HWP::GoldPet::SpawnPetForPlayer(player, tier);
			HWP::Log("goldpet", "spawned tier " + tier + " pet for " + player.GetName());
		}

		void Start(StartMode sMode)
		{
			m_petsSpawned.deleteAll();
			m_syncChecks.deleteAll();
			m_waitLogged.deleteAll();
			m_vendorSpawned = false;
			m_localTierSynced = false;
			m_checkDelay = 0;
			m_startupDelay = 0;
		}

		void SpawnVendor()
		{
			if (!g_inTown || g_currTownRecord is null)
				return;
			if (g_currTownRecord.GetVariationOnBuilding(HashString("hunters_cabin")) < 0)
				return;

			// Hunter's Lodge at (1056, 768); vendor offset (-20, -40), next to the hunter NPC
			vec3 spawnPos = vec3(1036.0f, 728.0f, 0.0f);
			auto prod = Resources::GetUnitProducer("actors/npcs/town/hwp_pet_vendor.unit");
			if (prod is null)
			{
				HWP::LogError("goldpet", "missing actors/npcs/town/hwp_pet_vendor.unit");
				return;
			}
			prod.Produce(g_scene, spawnPos);
			HWP::Log("goldpet", "spawned the pet vendor in the Hunter's Lodge");
		}
	}
}
