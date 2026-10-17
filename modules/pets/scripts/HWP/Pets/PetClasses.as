// info.xml classmaps MiniPetWalking -> HWPMiniPetWalking and
// MiniPetFlying -> HWPMiniPetFlying, so every vanilla and imported pet gets:
//   - puzzle-room waiting (HWP::PetWait::Watcher),
//   - the owner's pickup toggles (PlayerRecord.petOptions instead of the
//     hardcoded 319 the base ResetPet passes),
//   - the Fetch passives and the skill runner (HWP::Pets::SkillRunner),
//   - pet XP for every pickup,
//   - the owner's pet dye from the tailor (HWP::PetDye).
// Pets are not netsynced: each machine simulates its copy and only the owner's
// (non-husk) pet picks up or fires skills, exactly like the base behaviour.

class HWPMiniPetWalking : MiniPetWalking
{
	HWP::PetWait::Watcher m_wait;
	HWP::Pets::SkillRunner m_skills;
	string m_petId;

	HWPMiniPetWalking(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		HWP::Pets::LogClassmap(false);
	}

	void Initialize(PlayerBase@ owner, MiniPetOption options) override
	{
		m_petId = HWP::Pets::ActivePetId(owner.m_record);
		m_skills.m_family = HWP::Pets::FamilyOf(m_unit);
		HWP::Pets::ApplyPassives(this, owner, m_petId, m_skills.m_family);
		MiniPetWalking::Initialize(owner, HWP::Pets::OptionsFor(owner, options));
		HWP::PetDye::Apply(this, owner.m_record, m_petId);
	}

	void Update(int dt) override
	{
		if (m_wait.Update(dt, this))
			return;
		MiniPetWalking::Update(dt);
		if (m_unit.IsValid())
			m_skills.Update(dt, m_owner, m_unit.GetPosition(), m_petId);
	}

	bool PickUp(UnitPtr pickup, vec2 pos, vec2 normal) override
	{
		auto kind = IsPickupOkay(pickup);
		bool ok = MiniPet::PickUp(pickup, pos, normal);
		if (ok && !IsHusk())
			HWP::Pets::OnPetPickup(m_owner.m_record, m_petId, kind, m_skills.m_family);
		return ok;
	}
}

class HWPMiniPetFlying : MiniPetFlying
{
	HWP::PetWait::Watcher m_wait;
	HWP::Pets::SkillRunner m_skills;
	string m_petId;

	HWPMiniPetFlying(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_wait.m_flying = true;
		HWP::Pets::LogClassmap(true);
	}

	void Initialize(PlayerBase@ owner, MiniPetOption options) override
	{
		m_petId = HWP::Pets::ActivePetId(owner.m_record);
		m_skills.m_family = HWP::Pets::FamilyOf(m_unit);
		HWP::Pets::ApplyPassives(this, owner, m_petId, m_skills.m_family);
		MiniPet::Initialize(owner, HWP::Pets::OptionsFor(owner, options));
		HWP::PetDye::Apply(this, owner.m_record, m_petId);
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
		if (m_unit.IsValid())
			m_skills.Update(dt, m_owner, m_unit.GetPosition(), m_petId);
	}

	bool PickUp(UnitPtr pickup, vec2 pos, vec2 normal) override
	{
		auto kind = IsPickupOkay(pickup);
		bool ok = MiniPet::PickUp(pickup, pos, normal);
		if (ok && !IsHusk())
			HWP::Pets::OnPetPickup(m_owner.m_record, m_petId, kind, m_skills.m_family);
		return ok;
	}
}
