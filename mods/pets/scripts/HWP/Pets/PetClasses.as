// The pet units name these classes themselves (tools/make_pet_dyes.py writes
// copies of the vanilla pet units and rewrites the HoH1 imports; the engine
// ignores info.xml classmaps for unit behaviours), so every pet gets:
//   - puzzle-room waiting (HWP::PetWait::Watcher; also the candle's Secret Sense hover),
//   - the owner's pickup toggles (PlayerRecord.petOptions instead of the
//     hardcoded 319 the base ResetPet passes),
//   - the Fetch passives and the skill runner (HWP::Pets::SkillRunner),
//   - pet XP for every pickup,
//   - the owner's pet dyes from the tailor (HWP::PetDye; a dyed pet may swap
//     itself for its dye-ready copy).
// Pets are not netsynced: each machine simulates its copy and only the owner's
// (non-husk) pet picks up or fires skills, exactly like the base behaviour.

class HWPMiniPetWalking : MiniPetWalking
{
	HWP::PetWait::Watcher m_wait;
	HWP::Pets::SkillRunner m_skills;
	string m_petId;
	string m_dyeVariant; // "p" / "s" / "ps" on a dye-ready copy (tools/make_pet_dyes.py)

	HWPMiniPetWalking(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_dyeVariant = GetParamString(unit, params, "hwp-dye-variant", false, "");
		HWP::Pets::LogPetClass(false);
	}

	void Initialize(PlayerBase@ owner, MiniPetOption options) override
	{
		m_petId = HWP::Pets::ActivePetId(owner.m_record);
		m_skills.m_family = HWP::Pets::FamilyOf(m_unit);
		HWP::Pets::ApplyPassives(this, owner, m_petId, m_skills.m_family);
		MiniPetWalking::Initialize(owner, HWP::Pets::OptionsFor(owner, options));
		HWP::PetDye::Apply(this, owner, m_petId, m_dyeVariant, options);
	}

	void Update(int dt) override
	{
		if (m_unit.IsValid())
			m_skills.UpdateSecrets(dt, m_owner, m_unit.GetPosition(), m_petId);
		m_wait.m_hold = m_skills.m_secretHold;
		m_wait.m_holdPos = m_skills.m_secretPos;
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
	string m_dyeVariant; // "p" / "s" / "ps" on a dye-ready copy (tools/make_pet_dyes.py)

	HWPMiniPetFlying(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_dyeVariant = GetParamString(unit, params, "hwp-dye-variant", false, "");
		m_wait.m_flying = true;
		HWP::Pets::LogPetClass(true);
	}

	void Initialize(PlayerBase@ owner, MiniPetOption options) override
	{
		m_petId = HWP::Pets::ActivePetId(owner.m_record);
		m_skills.m_family = HWP::Pets::FamilyOf(m_unit);
		HWP::Pets::ApplyPassives(this, owner, m_petId, m_skills.m_family);
		MiniPet::Initialize(owner, HWP::Pets::OptionsFor(owner, options));
		HWP::PetDye::Apply(this, owner, m_petId, m_dyeVariant, options);
	}

	void Update(int dt) override
	{
		if (m_unit.IsValid())
			m_skills.UpdateSecrets(dt, m_owner, m_unit.GetPosition(), m_petId);
		m_wait.m_hold = m_skills.m_secretHold;
		m_wait.m_holdPos = m_skills.m_secretPos;
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
