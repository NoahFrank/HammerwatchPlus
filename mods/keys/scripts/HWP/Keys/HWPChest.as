// Replacement for the vanilla Chest behaviour: the chest and cache units name
// it themselves (module.json class_swaps, tools/class_units.py; the engine
// ignores info.xml classmaps for unit behaviours).
//
// Reward chests (items/chests/chest_<tier>_<kind>.unit, and the treasury
// rooms' chest_platinum) lock on their first tick and want a key of their own
// tier (platinum: gold); without one the chest shows a cross and a tooltip
// naming the key, and does not open. Cursed chests and the resource caches
// stay open. A locked chest pays its own vanilla loot.
//
// keys.lock_chance (default 1: every chest) and the ace roll are deterministic
// - a hash of the chest's position, the mission reward seed and the level
// index - so every machine in the lobby agrees without a network message. A
// share of gold chests become the red ace chest (ace key; loot + a legendary
// for everyone on half of the openings).
namespace HWP { namespace Keys { bool g_chestClassLogged = false; } }

class HWPChest : Chest
{
	bool m_decided = false;
	int m_waited = 0; // ms spent waiting for the host's settings (clients)
	int m_tier = 0; // 0 = plain chest, 1..4 = bronze/silver/gold/ace lock
	UnitPtr m_lockUnit;
	ITooltip@ m_lockTooltip;

	HWPChest(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		if (!HWP::Keys::g_chestClassLogged)
		{
			HWP::Keys::g_chestClassLogged = true;
			HWP::Log("keys", "chest class active: HWPChest");
		}
	}

	// The roll's inputs (keys.* settings) must be the host's: a client waits
	// for settings.sync (up to 10 s, then it rolls with what it has and logs).
	void Update(int dt)
	{
		if (m_decided)
			return;
		if (!HWP::Settings::RemoteReady())
		{
			m_waited += dt;
			if (m_waited < 10000)
				return;
			HWP::LogError("keys", "host settings never arrived; rolling chest locks with local values");
		}
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
			return; // caches (the material crates) never lock, nor anything else that uses the Chest class

		string rest = name.substr(prefix.length());
		int dot = rest.findLast(".");
		if (dot > 0)
			rest = rest.substr(0, dot);
		auto parts = rest.split("_");
		int baseTier = parts[0] == "platinum" ? 3 : HWP::Keys::TierIndex(parts[0]);
		if (baseTier < 1 || baseTier > 3)
			return; // cursed

		vec3 pos = m_unit.GetPosition();
		string seed = "";
		if (MissionManager::g_module !is null)
			seed = "" + MissionManager::g_module.m_missionRewardSeed + ":" + MissionManager::g_module.m_missionLevelIndex;
		string salt = name + ":" + (int(pos.x) / 8) + ":" + (int(pos.y) / 8) + ":" + seed;

		if (Roll(salt + ":lock") >= HWP::Keys::g_lockChance)
			return;
		bool ace = parts.length() == 2 && baseTier == 3 && Roll(salt + ":ace") < HWP::Keys::g_aceChance;

		m_tier = ace ? 4 : baseTier;
		m_key = HWP::Keys::TIERS[m_tier - 1];
		if (ace)
		{
			auto table = Item::GetLootTable("hwp_chest_ace");
			if (table !is null)
				@m_lootTable = table;
			else
				HWP::LogError("keys", "missing loot table hwp_chest_ace");
		}

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

	// standing at a locked chest without its key: which key it wants
	ITooltip@ GetTooltip() override
	{
		if (m_key.isEmpty() || !m_unit.IsValid() || m_unit.IsDestroyed())
			return null;
		auto rec = GetLocalPlayerRecord();
		if (rec is null || rec.GetKeys(m_key) > 0)
			return null;
		if (m_lockTooltip is null)
		{
			string key = Resources::GetString(".item.key." + m_key);
			@m_lockTooltip = CreateTooltip(Resources::GetSValue("gui/variable/itemtooltip_common.sval"),
				Resources::GetString(".hwp.keys.locked"), Resources::GetString(".hwp.keys.locked_need", { { "key", key } }));
		}
		return m_lockTooltip;
	}

	// Keys live in each player's own PlayerRecord and are never networked, so
	// the host's copy of a remote player (PlayerHusk) always reports 0 keys.
	// Clients report their counts (keys.count, HWP::Keys::SendKeyCounts) and
	// the host checks a husk against those; a client standing at a locked
	// chest re-sends its counts the moment they differ so the host is never
	// behind.
	bool CanUse(PlayerBase@ player) override
	{
		auto husk = cast<PlayerHusk>(player);
		if (husk !is null)
		{
			if (!m_unit.IsValid() || m_unit.IsDestroyed())
				return false;
			if (m_key.isEmpty())
				return true;
			if (husk.m_record is null)
				return false;
			return HWP::Keys::HostKeyCount(husk.m_record.peer, m_key) > 0;
		}
		// CanUse is polled every frame (HUD + use prompt): only send when the
		// counts differ from what the host already has
		bool ok = Chest::CanUse(player);
		if (ok && !m_key.isEmpty() && !Network::IsServer())
			HWP::Keys::SendKeyCounts(false);
		return ok;
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
