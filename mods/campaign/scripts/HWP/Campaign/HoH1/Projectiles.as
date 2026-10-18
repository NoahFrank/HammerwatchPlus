// HoH2 implementations of the projectile classes HoH1 boss and enemy units
// use, with HoH1's unit parameters. HoH2 projectiles read their parameters
// in Initialize (they are pooled before an owner is known), so these do too.

// A physics-driven projectile: flies straight at "speed" until it hits
// something it can affect, "ttl" runs out or it has flown "range"; the
// effects apply at whatever ends it (on the spot when it fizzles).
class HoH1Projectile : ProjectileBase
{
	uint m_team;
	uint Team { get override { return m_team; } }
	Actor@ GetOwner() override { return m_owner; }

	Actor@ m_owner;
	int m_ttl;
	float m_rangeSq;
	vec2 m_startPos;
	vec2 m_dir;
	float m_selfDmg;
	float m_teamDmg;
	AnimString@ m_anim;
	EffectList@ m_effects;

	HoH1Projectile(UnitPtr unit, SValue& params)
	{
		super(unit, params);
	}

	void Initialize(Actor@ owner, ProjectileTarget@ target, float intensity, bool husk, uint weapon) override
	{
		ProjectileBase::Initialize(owner, target, intensity, husk, weapon);

		auto params = m_params;
		auto unit = m_unit;
		m_ttl = GetParamInt(unit, params, "ttl", false, 5000);
		float range = GetParamInt(unit, params, "range", false, -1);
		m_rangeSq = range > 0 ? range * range : -1;
		m_selfDmg = GetParamFloat(unit, params, "self-dmg", false, 0);
		m_teamDmg = GetParamFloat(unit, params, "team-dmg", false, 0);
		@m_anim = AnimString(GetParamString(unit, params, "anim"));
		@m_effects = LoadEffects(unit, params, "", m_selfDmg, m_teamDmg);
		PropagateWeaponInformation(m_effects, weapon);

		auto teamOverride = GetParamString(unit, params, "team-override", false, "");
		m_team = teamOverride.isEmpty() ? (owner !is null ? owner.Team : 1) : HashString(teamOverride);

		@m_owner = owner;
		m_intensity = intensity;
		m_husk = husk;
		m_startPos = xy(m_unit.GetPosition());

		Launched(target);
		SetDirection(target.GetDir(m_startPos));
		if (target.unitTarget.IsValid())
			SetSeekTarget(cast<Actor>(target.unitTarget.GetScriptBehavior()));
		PlaySound3D(m_soundShoot, m_unit.GetPosition());
	}

	// for subclasses, before the projectile starts moving
	void Launched(ProjectileTarget@ target) {}

	string SceneName(float ang) { return m_anim.GetSceneName(ang); }

	bool HasShieldBlockableDamage() override { return m_effects !is null && m_effects.HasShieldBlockableDamage(); }
	vec2 GetDirection() override { return m_dir; }

	void SetDirection(vec2 dir) override
	{
		m_dir = dir;
		float ang = atan(dir.y, dir.x);
		m_unit.SetUnitScene(SceneName(ang), false);
		SetScriptParams(ang, m_speed);
		m_unit.GetPhysicsBody().SetLinearVelocity(dir * m_speed);
	}

	void Collide(UnitPtr unit, vec2 pos, vec2 normal)
	{
		if (m_unit.IsDestroyed() || m_effects is null)
			return;
		if (!ShouldCollide(unit, pos, m_dir, m_owner, m_selfDmg, m_teamDmg))
			return;

		Hit(unit, pos);
	}

	void Hit(UnitPtr unit, vec2 pos)
	{
		ApplyEffects(m_effects, m_owner, unit, pos, m_dir, m_intensity, m_husk);
		PlaySound3D(m_soundHit, xyz(pos));
		m_unit.Destroy();
	}

	void Update(int dt) override
	{
		if (m_effects is null)
			return;

		m_ttl -= dt;
		vec2 pos = xy(m_unit.GetPosition());
		if (m_ttl <= 0 || (m_rangeSq > 0 && distsq(m_startPos, pos) >= m_rangeSq))
		{
			ApplyEffects(m_effects, m_owner, UnitPtr(), pos, m_dir, m_intensity, m_husk);
			m_unit.Destroy();
			return;
		}

		UpdateSeeking(m_dir, dt);
		UpdateSpeed(m_dir, dt);
		ProjectileBase::Update(dt);
	}
}

// A lobbed projectile (the vampire's bats): flies in an arc "arc-height"
// high over its lifetime, so it passes over what is between. "on-target"
// slows it to come down on the aimed spot; "penetration" lets it hit that
// many actors before it lands. Scenes are "<anim>-<n>" for "anim-num"
// charge frames; enemies always throw at full charge.
class HoH1TossProjectile : HoH1Projectile
{
	int m_animNum;
	int m_maxTtl;
	float m_arcHeight;
	int m_penetration;
	bool m_onTarget;
	array<UnitPtr> m_hitUnits;

	HoH1TossProjectile(UnitPtr unit, SValue& params)
	{
		super(unit, params);
	}

	void Launched(ProjectileTarget@ target) override
	{
		auto params = m_params;
		auto unit = m_unit;
		m_animNum = max(1, GetParamInt(unit, params, "anim-num", false, 1));
		m_arcHeight = GetParamFloat(unit, params, "arc-height", false, 12.0);
		m_penetration = GetParamInt(unit, params, "penetration", false, 0);
		m_onTarget = GetParamBool(unit, params, "on-target", false, false);
		m_maxTtl = max(1, m_ttl);
		m_hitUnits.removeRange(0, m_hitUnits.length());   // pooled: forget the last flight's hits

		if (m_onTarget && m_speed > 0 && (target.unitTarget.IsValid() || target.dirTarget == -9999))
		{
			vec2 aim = target.unitTarget.IsValid() ? xy(target.unitTarget.GetPosition()) : target.posTarget;
			m_speed = min(m_speed, dist(m_startPos, aim) * 33.0 / m_maxTtl);
		}
	}

	string SceneName(float ang) override { return m_anim.GetSceneName(ang) + "-" + (m_animNum - 1); }

	void Collide(UnitPtr unit, vec2 pos, vec2 normal) override
	{
		if (m_unit.IsDestroyed() || m_effects is null)
			return;
		if (!ShouldCollide(unit, pos, m_dir, m_owner, m_selfDmg, m_teamDmg))
			return;

		if (m_penetration > 0 && cast<IDamageTaker>(unit.GetScriptBehavior()) !is null)
		{
			if (m_hitUnits.find(unit) >= 0)
				return;
			m_hitUnits.insertLast(unit);
			ApplyEffects(m_effects, m_owner, unit, pos, m_dir, m_intensity, m_husk);
			if (--m_penetration <= 0)
				m_unit.Destroy();
			return;
		}

		Hit(unit, pos);
	}

	void Update(int dt) override
	{
		HoH1Projectile::Update(dt);
		if (!m_unit.IsDestroyed())
			m_unit.SetPositionZ(sin((1.0 - float(m_ttl) / float(m_maxTtl)) * PI) * m_arcHeight, true);
	}

	void Destroyed() override
	{
		PlaySound3D(m_soundHit, m_unit.GetPosition());
		ProjectileBase::Destroyed();
	}
}

// A projectile that travels along the ground (golem, dragon and warden
// ground spikes): every "spawn-freq" ms it leaves its anim's effect behind
// on the floor. Over tiles harder than "ignore-at-hardness" it passes
// without hitting anything; over tiles harder than "destroy-at-hardness" it
// stops. "miss-fx" also plays each tile's own hit effect along the way.
class HoH1LurkerProjectile : RayProjectile
{
	int m_hardnessIgnore;
	int m_hardnessDestroy;
	int m_spawnFreq;
	int m_spawnC;
	bool m_tileFx;

	HoH1LurkerProjectile(UnitPtr unit, SValue& params)
	{
		super(unit, params);
	}

	void Initialize(Actor@ owner, ProjectileTarget@ target, float intensity, bool husk, uint weapon) override
	{
		auto params = m_params;
		auto unit = m_unit;
		m_hardnessIgnore = GetParamInt(unit, params, "ignore-at-hardness", false, -1);
		m_hardnessDestroy = GetParamInt(unit, params, "destroy-at-hardness", false, -1);
		m_spawnFreq = max(1, GetParamInt(unit, params, "spawn-freq", false, 100));
		m_spawnC = m_spawnFreq;
		m_tileFx = GetParamBool(unit, params, "miss-fx", false, false);

		RayProjectile::Initialize(owner, target, intensity, husk, weapon);
	}

	// the unit has no scene of its own to show; its anim's scenes are the trail
	void SetDirection(vec2 dir) override
	{
		m_dir = dir;
		SetScriptParams(atan(dir.y, dir.x), m_speed);
	}

	// -1: tiles here don't matter, 0: pass over, 1: stop
	int TileRule(vec2 pos)
	{
		if (m_hardnessIgnore == -1 && m_hardnessDestroy == -1)
			return -1;

		int rule = -1;
		auto tilesets = g_scene.FetchTilesets(pos);
		for (uint i = 0; i < tilesets.length(); i++)
		{
			SValue@ data = tilesets[i].GetData();
			SValue@ hardness = data is null ? null : data.GetDictionaryEntry("hardness");
			if (hardness is null || hardness.GetType() != SValueType::Integer)
				continue;

			int h = hardness.GetInteger();
			if (m_hardnessDestroy != -1 && h > m_hardnessDestroy)
				return 1;
			if (m_hardnessIgnore != -1 && h > m_hardnessIgnore)
				rule = 0;
		}
		return rule;
	}

	void LeaveTrail(vec2 pos)
	{
		PlayEffect(m_unit.GetUnitScene(m_anim.GetSceneName(atan(m_dir.y, m_dir.x))), pos);
		if (!m_tileFx)
			return;

		auto tilesets = g_scene.FetchTilesets(pos);
		for (int i = tilesets.length() - 1; i >= 0; i--)
		{
			SValue@ data = tilesets[i].GetData();
			SValue@ fx = data is null ? null : data.GetDictionaryEntry("hit-effect");
			if (fx !is null && fx.GetType() == SValueType::String)
			{
				PlayEffect(fx.GetString(), pos);
				return;
			}
		}
	}

	void Update(int dt) override
	{
		if (m_anim is null)
			return;

		int rule = TileRule(xy(m_unit.GetPosition()));
		if (rule == 1)
		{
			m_unit.Destroy();
			return;
		}

		if (rule == 0)
		{
			m_ttl -= dt;
			if (m_ttl <= 0)
			{
				m_unit.Destroy();
				return;
			}
			m_pos += m_dir * m_speed * dt / 33.0;
			m_unit.SetPosition(m_pos.x, m_pos.y, 0, true);
			return;
		}

		for (m_spawnC -= dt; m_spawnC < 0; m_spawnC += m_spawnFreq)
			LeaveTrail(xy(m_unit.GetPosition()));

		RayProjectile::Update(dt);
	}
}
