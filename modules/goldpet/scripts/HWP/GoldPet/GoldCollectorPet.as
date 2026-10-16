// Gold collector pet: a PlayerOwnedActor that walks to nearby pickups and
// collects them for its owner. Tier 1 gold, tier 2 all materials + experience
// scrolls, tier 3 valuables too, with more range and speed.

class HWPGoldCollectorPet : PlayerOwnedActor
{
	// Pet progression (pets module): the cat earns XP and runs the same skills
	// as the MiniPet-based pets, keyed on the external id "hwp_goldpet".
	HWP::Pets::SkillRunner m_petSkills;
	int m_passiveTier = -1;
	// Pickup params
	int m_pickupRadius;
	int m_pickupInterval;
	int m_pickupTimer;

	// Seeking params
	int m_seekRadius;
	int m_scanInterval;
	int m_scanTimer;
	int m_maxSeekDistFromOwner;
	int m_maxSeekDistFromOwnerSq;
	float m_seekSpeed;

	// Target tracking
	bool m_seekingTarget;
	UnitPtr m_currentTarget;

	// Pathfinding
	PathFollower m_pathFollower;

	// Animation direction
	float m_dir;

	// Tier system
	int m_petTier;

	HWPGoldCollectorPet(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_pickupRadius = GetParamInt(unit, params, "pickup-radius", false, 20);
		m_pickupInterval = GetParamInt(unit, params, "pickup-interval", false, 500);
		m_pickupTimer = 0;

		// Seeking params
		m_seekRadius = GetParamInt(unit, params, "seek-radius", false, 200);
		m_scanInterval = GetParamInt(unit, params, "scan-interval", false, 250);
		m_scanTimer = 0;
		m_maxSeekDistFromOwner = GetParamInt(unit, params, "max-seek-dist-from-owner", false, 150);
		m_maxSeekDistFromOwnerSq = m_maxSeekDistFromOwner * m_maxSeekDistFromOwner;
		m_seekSpeed = GetParamFloat(unit, params, "gold-seek-speed", false, 4.0f);

		m_seekingTarget = false;
		m_dir = 0;

		// Default tier (will be set by ConfigureForTier after spawn)
		m_petTier = 1;

		// Initialize pathfinder
		m_pathFollower.Initialize(unit, 500, false);
	}

	// Configure pet stats based on tier level
	void ConfigureForTier(int tier)
	{
		m_petTier = tier;

		// Tier 3 bonuses: +50 range, +25% speed
		if (m_petTier >= 3)
		{
			m_maxSeekDistFromOwner += 50;
			m_maxSeekDistFromOwnerSq = m_maxSeekDistFromOwner * m_maxSeekDistFromOwner;
			m_seekSpeed *= 1.25f;
		}
	}

	// Override to receive pathfinding callbacks for our custom PathFollower
	void QueuedPathfind(array<vec2>@ path) override
	{
		if (m_seekingTarget)
			m_pathFollower.QueuedPathfind(path);
		else
			CompositeActorBehavior::QueuedPathfind(path);
	}

	// Check if the pet's owner is the local player (for UI feedback)
	bool IsOwnerLocal()
	{
		return m_ownerRecord !is null && m_ownerRecord.local;
	}

	void Update(int dt) override
	{
		PlayerOwnedActor::Update(dt);

		if (IsDead())
			return;

		if (m_ownerRecord is null || m_ownerRecord.actor is null)
			return;

		// skills run on the owner's machine, like the MiniPet pets
		if (m_ownerRecord.local)
		{
			auto owner = cast<PlayerBase>(m_ownerRecord.actor);
			if (owner !is null)
			{
				ApplyFetchPassive();
				m_petSkills.Update(dt, owner, m_unit.GetPosition(), HWP::GoldPet::PET_ID);
			}
		}

		// Only server controls collection behavior (clients just see the pet move)
		if (m_netsynced && !Network::IsServer())
			return;

		// Scan for pickups periodically
		m_scanTimer -= dt;
		if (m_scanTimer <= 0)
		{
			m_scanTimer = m_scanInterval;
			ScanForPickups();
		}

		// If seeking target, handle movement ourselves
		if (m_seekingTarget && m_currentTarget.IsValid())
		{
			SeekTargetUpdate(dt);
		}

		// Passive collection check (for items that end up under pet)
		m_pickupTimer -= dt;
		if (m_pickupTimer <= 0)
		{
			m_pickupTimer = m_pickupInterval;
			CollectNearbyItems();
		}
	}

	// Fetch ranks widen the pickup and seek radius; applied once per rank change.
	void ApplyFetchPassive()
	{
		int rank = HWP::Pets::Rank(m_ownerRecord, HWP::GoldPet::PET_ID, HWP::Pets::Skill::Fetch);
		if (rank == m_passiveTier)
			return;
		auto def = HWP::Pets::Def(HWP::Pets::Skill::Fetch);
		int prev = (m_passiveTier > 0 && def !is null) ? def.Value(m_passiveTier) : 0;
		int next = (rank > 0 && def !is null) ? def.Value(rank) : 0;
		m_passiveTier = rank;
		m_pickupRadius += (next - prev) / 4;
		m_seekRadius += next - prev;
		m_maxSeekDistFromOwner += next - prev;
		m_maxSeekDistFromOwnerSq = m_maxSeekDistFromOwner * m_maxSeekDistFromOwner;
	}

	void ScanForPickups()
	{
		vec2 petPos = xy(m_unit.GetPosition());

		// Don't seek if too far from owner
		vec2 ownerPos = xy(m_ownerRecord.actor.m_unit.GetPosition());
		if (distsq(petPos, ownerPos) > m_maxSeekDistFromOwnerSq)
		{
			SetSeekingTarget(false);
			m_currentTarget = UnitPtr();
			return;
		}

		// Find nearest valid pickup
		auto results = g_scene.QueryCircle(petPos, m_seekRadius, ~0, RaycastType::Any, true);

		float nearestDistSq = 999999.0f;
		UnitPtr nearestTarget;

		for (uint i = 0; i < results.length(); i++)
		{
			UnitPtr unit = results[i];
			if (!unit.IsValid())
				continue;

			if (!IsValidPickupTarget(unit))
				continue;

			float dSq = distsq(petPos, xy(unit.GetPosition()));
			if (dSq < nearestDistSq)
			{
				nearestDistSq = dSq;
				nearestTarget = unit;
			}
		}

		m_currentTarget = nearestTarget;
		SetSeekingTarget(nearestTarget.IsValid());
	}

	// Check if a unit is a valid pickup target based on pet tier
	bool IsValidPickupTarget(UnitPtr unit)
	{
		ref@ behavior = unit.GetScriptBehavior();

		// Check for Material pickups (gold, wood, stone, iron, etc.)
		auto matPickup = cast<Material::MaterialPickup>(behavior);
		if (matPickup !is null)
		{
			if (matPickup.m_picked)
				return false;

			// Tier 1: Gold only
			if (matPickup.m_type == MaterialType::Gold)
				return true;

			// Tier 2+: All materials
			if (m_petTier >= 2)
				return true;

			return false;
		}

		// Check for generic Pickups (exp scrolls, valuables)
		auto pickup = cast<Pickup>(behavior);
		if (pickup !is null)
		{
			if (!pickup.m_visible)
				return false;

			// Tier 2+: Experience scrolls (identified by pickup-stat)
			if (m_petTier >= 2 && pickup.m_pickupStat == HashString("pickup-exp"))
				return true;

			// Tier 3: Valuables (tradeware items)
			if (m_petTier >= 3)
			{
				auto prod = unit.GetUnitProducer();
				if (prod !is null)
				{
					string path = prod.GetResourceName();
					if (path.findFirst("tradeware") >= 0 || path.findFirst("valuables") >= 0)
						return true;
				}
			}
		}

		return false;
	}

	// Enable/disable target seeking and toggle base movement accordingly
	void SetSeekingTarget(bool seeking)
	{
		if (m_seekingTarget == seeking)
			return;

		m_seekingTarget = seeking;
		// Disable base movement when seeking to prevent stutter-stepping
		m_movement.m_enabled = !seeking;
	}

	void SeekTargetUpdate(int dt)
	{
		vec2 petPos = xy(m_unit.GetPosition());
		vec2 targetPos = xy(m_currentTarget.GetPosition());
		float distToTargetSq = distsq(petPos, targetPos);

		// Check if reached target
		if (distToTargetSq <= m_pickupRadius * m_pickupRadius)
		{
			CollectPickup(m_currentTarget);
			m_currentTarget = UnitPtr();
			SetSeekingTarget(false);
			m_scanTimer = 100; // Quick rescan after collection
			return;
		}

		// Move toward target using pathfinding
		auto body = m_unit.GetPhysicsBody();
		body.SetStatic(false);

		vec2 dir = m_pathFollower.FollowPath(petPos, targetPos);
		dir *= m_seekSpeed;

		m_dir = m_pathFollower.m_visualDir;
		body.SetLinearVelocity(dir);

		// Set walking animation based on direction (using game's formula from AnimString)
		int dirIndex = int((m_dir / (2 * PI) * 8 + 8.5)) % 8;
		m_unit.SetUnitScene("walk-" + dirIndex, false);
	}

	// Collect any valid pickup
	void CollectPickup(UnitPtr unit)
	{
		if (!unit.IsValid())
			return;

		ref@ behavior = unit.GetScriptBehavior();

		// Handle material pickups
		auto matPickup = cast<Material::MaterialPickup>(behavior);
		if (matPickup !is null)
		{
			CollectMaterial(unit, matPickup);
			return;
		}

		// Handle generic pickups (exp scrolls, valuables)
		auto pickup = cast<Pickup>(behavior);
		if (pickup !is null)
		{
			CollectGenericPickup(unit, pickup);
			return;
		}
	}

	void CollectMaterial(UnitPtr unit, Material::MaterialPickup@ pickup)
	{
		if (pickup.m_picked)
			return;

		int amount = pickup.m_amount;

		// Apply the player's material modifier
		float mul = m_ownerRecord.GetMaterialModifier(pickup.m_type);
		int given = max(0, roll_round(amount * mul));

		// Server authoritative. Only the owner's own machine may credit the owner:
		// the host's copy of a client's record is never saved or synced back, so a
		// remote owner is paid through the vanilla PickedMaterial path, which runs
		// NetPick() (GiveMaterial on GetLocalPlayerRecord) on the receiving peer.
		if (Network::IsServer())
		{
			if (pickup.m_shared)
			{
				(Network::Message("PickedMaterial") << unit).SendToAll();
				pickup.NetPick();
			}
			else if (m_ownerRecord.local)
				m_ownerRecord.GiveMaterial(pickup.m_type, given, true);
			else
				(Network::Message("PickedMaterial") << unit).SendToPeer(m_ownerRecord.peer);
			// pet XP (only credited on the owner's own machine, see OnPetPickup)
			HWP::Pets::OnPetPickup(m_ownerRecord, HWP::GoldPet::PET_ID,
				pickup.m_type == MaterialType::Gold ? MiniPetOption::Gold : MiniPetOption::Materials, "cat");
			unit.Destroy();
		}

		// Local feedback for the owning player only
		if (IsOwnerLocal())
		{
			string pickupKey = GetMaterialPickupKey(pickup.m_type);
			AddFloatingText(FloatingTextType::Pickup,
				Resources::GetString(pickupKey, {{ "amount", given }}),
				m_unit.GetPosition());

			PlaySound3D(GetMaterialSound(pickup.m_type), unit.GetPosition(), {{ "amount", amount }});
			LootLog::PresentMaterial(m_ownerRecord, pickup.m_type, given);
		}
	}

	string GetMaterialPickupKey(MaterialType type)
	{
		switch (type)
		{
			case MaterialType::Gold: return ".hud.pickup.gold";
			case MaterialType::Wood: return ".hud.pickup.wood";
			case MaterialType::Stone: return ".hud.pickup.stone";
			case MaterialType::Iron: return ".hud.pickup.iron";
			case MaterialType::Crystals: return ".hud.pickup.crystals";
			case MaterialType::Dust: return ".hud.pickup.dust";
			case MaterialType::Ore: return ".hud.pickup.ore";
		}
		return ".hud.pickup.gold";
	}

	SoundEvent@ GetMaterialSound(MaterialType type)
	{
		switch (type)
		{
			case MaterialType::Gold: return Material::g_baseGoldSound;
			case MaterialType::Wood: return Resources::GetSoundEvent("event:/sfx/items/item_wood_small");
			case MaterialType::Stone: return Resources::GetSoundEvent("event:/sfx/items/item_stone");
			case MaterialType::Iron: return Resources::GetSoundEvent("event:/sfx/items/item_metal_small");
			case MaterialType::Crystals: return Resources::GetSoundEvent("event:/sfx/items/item_metal_small");
			case MaterialType::Dust: return Resources::GetSoundEvent("event:/sfx/items/item_metal_small");
			case MaterialType::Ore: return Resources::GetSoundEvent("event:/sfx/items/item_metal_small");
		}
		return Material::g_baseGoldSound;
	}

	void CollectGenericPickup(UnitPtr unit, Pickup@ pickup)
	{
		if (!pickup.m_visible)
			return;

		// Only server triggers pickup collection
		if (!Network::IsServer())
			return;

		// Use the game's pickup system - simulate the owner picking it up. Effects
		// (experience, health...) only apply where the picker is not a husk, so a
		// remote owner gets the vanilla UnitPicked message instead: their client
		// runs Picked() on their real player, everyone else just hides the unit.
		if (m_ownerRecord.local)
			pickup.Picked(m_ownerRecord.actor.m_unit, true);
		else
		{
			(Network::Message("UnitPicked") << unit << m_ownerRecord.actor.m_unit).SendToAll();
			unit.Destroy();
		}
	}

	void CollectNearbyItems()
	{
		vec2 petPos = xy(m_unit.GetPosition());

		auto results = g_scene.QueryCircle(petPos, m_pickupRadius, ~0, RaycastType::Any, true);

		for (uint i = 0; i < results.length(); i++)
		{
			if (IsValidPickupTarget(results[i]))
				CollectPickup(results[i]);
		}
	}
}
