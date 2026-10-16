// Classmap replacement for the vanilla Chest behaviour (info.xml maps
// Chest -> HWPChest, so every chest and resource cache gets this class).
//
// Reward chests (items/chests/chest_<tier>_<kind>.unit) roll a lock on their
// first tick. The roll is deterministic - a hash of the chest's position, the
// mission reward seed and the level index - so every machine in the lobby
// agrees without a network message. Locked chests want a key of their own
// tier and pay like the next tier up; a share of gold chests become the red
// ace chest (loot + a legendary for everyone on half of the openings).
class HWPChest : Chest
{
	bool m_decided = false;
	int m_tier = 0; // 0 = plain chest, 1..4 = bronze/silver/gold/ace lock
	UnitPtr m_lockUnit;

	HWPChest(UnitPtr unit, SValue& params)
	{
		super(unit, params);
	}

	void Update(int dt)
	{
		if (m_decided)
			return;
		m_decided = true;
		Decide();
	}

	float Roll(const string &in salt)
	{
		return float(HashString(salt) % 10000) / 10000.0f;
	}

	void Decide()
	{
		if (!HWP::Keys::g_enabled || !m_key.isEmpty() || !m_unit.IsValid())
			return;

		auto prod = m_unit.GetUnitProducer();
		if (prod is null)
			return;
		string name = prod.GetResourceName();
		const string prefix = "items/chests/chest_";
		if (name.findFirst(prefix) != 0)
			return; // caches and anything else that uses the Chest class

		string rest = name.substr(prefix.length());
		int dot = rest.findLast(".");
		if (dot > 0)
			rest = rest.substr(0, dot);
		auto parts = rest.split("_");
		if (parts.length() != 2)
			return; // platinum, cursed
		int baseTier = HWP::Keys::TierIndex(parts[0]);
		if (baseTier < 1 || baseTier > 3)
			return;

		vec3 pos = m_unit.GetPosition();
		string seed = "";
		if (MissionManager::g_module !is null)
			seed = "" + MissionManager::g_module.m_missionRewardSeed + ":" + MissionManager::g_module.m_missionLevelIndex;
		string salt = name + ":" + (int(pos.x) / 8) + ":" + (int(pos.y) / 8) + ":" + seed;

		if (Roll(salt + ":lock") >= HWP::Keys::g_lockChance)
			return;
		bool ace = baseTier == 3 && Roll(salt + ":ace") < HWP::Keys::g_aceChance;

		m_tier = ace ? 4 : baseTier;
		m_key = HWP::Keys::TIERS[m_tier - 1];
		string lootId = ace ? "hwp_chest_ace" : "hwp_chest_locked_" + parts[0] + "_" + parts[1];
		auto table = Item::GetLootTable(lootId);
		if (table !is null)
			@m_lootTable = table;
		else
			HWP::LogError("keys", "missing loot table " + lootId);

		if (ace)
			m_unit.SetMultiplyColor(vec4(1.0f, 0.45f, 0.45f, 1.0f));
		SpawnLock(pos);
		HWP::Keys::g_chestsLocked++;
	}

	void SpawnLock(vec3 pos)
	{
		auto prod = Resources::GetUnitProducer(HWP::Keys::LOCK_UNIT);
		if (prod is null)
			return;
		m_lockUnit = prod.Produce(g_scene, vec3(pos.x, pos.y - 6, pos.z));
		if (m_lockUnit.IsValid())
			m_lockUnit.SetMultiplyColor(HWP::Keys::TierColor(m_tier));
	}

	// Keys live in each player's own PlayerRecord and are never networked, so
	// the host's copy of a remote player (PlayerHusk) always reports 0 keys.
	// The client already ran the real check against its own record before it
	// sent UseUnitSecure; on the host, trust it and only check the chest.
	bool CanUse(PlayerBase@ player) override
	{
		if (cast<PlayerHusk>(player) !is null)
			return m_unit.IsValid() && !m_unit.IsDestroyed();
		return Chest::CanUse(player);
	}

	void Use(PlayerBase@ player) override
	{
		if (m_unit.IsDestroyed() || !m_unit.IsValid())
			return;

		// The ace bonus goes first so its drops land before the chest unit is
		// gone; Chest::Use then spends the key, destroys the chest and spawns
		// the regular table on the server.
		if (m_tier == 4 && Network::IsServer())
			HWP::Keys::SpawnAceBonus(player, m_unit.GetPosition());
		if (m_lockUnit.IsValid())
			m_lockUnit.Destroy();
		if (m_tier > 0)
			HWP::Keys::OnUnlocked(player, m_tier);

		Chest::Use(player);
	}
}
