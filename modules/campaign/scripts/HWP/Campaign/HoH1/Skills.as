// HoH2 implementations of the HoH1 enemy skills that HoH2 has no match for,
// under HoH1-prefixed names (tools/import_hoh1.py maps them) and HoH1's
// parameters ("cooldown" is a plain int, effects use HoH2 effect classes).
// The host decides when a skill starts and tells the peers (stage 0, with the
// aim where it matters); the peers play it out locally.

// turn angle `from` toward `to` by fraction `t`, the short way round
float HoH1LerpRot(float from, float to, float t)
{
	float d = to - from;
	while (d > PI) d -= 2 * PI;
	while (d < -PI) d += 2 * PI;
	return from + d * clamp(t, 0.0f, 1.0f);
}

abstract class HoH1Skill : ACompositeActorSkill
{
	UnitPtr m_unit;
	CompositeActorBehavior@ m_behavior;
	int m_id;
	int m_cooldown;
	int m_cooldownC;

	HoH1Skill(UnitPtr unit, SValue& params, bool randomStart = true)
	{
		super(unit, params);
		m_cooldown = GetParamInt(unit, params, "cooldown", false, 0);
		m_cooldownC = GetParamInt(unit, params, "cooldown-start", false, randomStart ? randi(max(1, m_cooldown)) : m_cooldown);
	}

	void Initialize(UnitPtr unit, CompositeActorBehavior& behavior, int id) override
	{
		ACompositeActorSkill::Initialize(unit, behavior, id);
		m_unit = unit;
		@m_behavior = behavior;
		m_id = id;
	}

	void ClearCooldown(bool reset) override { m_cooldownC = reset ? m_cooldown : 0; }
	void SetCooldown(int cd) override { m_cooldownC = cd; }

	float Intensity() { return m_behavior.m_buffs.DamageMul(); }
	bool Husk() { return !Network::IsServer(); }

	vec2 TargetDir(vec2 from)
	{
		if (m_behavior.m_target is null)
			return m_behavior.GetDirection();
		vec2 d = xy(m_behavior.m_target.m_unit.GetPosition()) - from;
		return (d.x == 0 && d.y == 0) ? m_behavior.GetDirection() : normalize(d);
	}

	vec2 Confused(vec2 dir)
	{
		if (m_behavior.m_buffs.Confuse() && !m_behavior.m_buffs.AntiConfuse())
			return addrot(dir, randfn() * (PI / 4));
		return dir;
	}

	// host: may this skill start now?
	bool Ready(bool isCasting)
	{
		if (!Network::IsServer() || isCasting || IsCasting() || m_behavior.m_target is null)
			return false;
		if (!m_restrictions.IsAvailable())
			return false;
		if (!m_restrictions.CanSee(m_behavior.m_target.m_unit))
		{
			m_cooldownC = m_cooldown;
			return false;
		}
		return true;
	}

	SValue@ DirParam(vec2 dir)
	{
		SValueBuilder b;
		b.PushArray();
		b.PushVector2(dir);
		b.PopArray();
		return b.Build();
	}

	vec2 ParamDir(SValue@ param)
	{
		if (param is null)
			return TargetDir(xy(m_unit.GetPosition()));
		return param.GetArray()[0].GetVector2();
	}
}

// A leap at the target: "pre-cast" ms of wind-up, "air-time" ms flying at
// "speed" (an arc "jump-height" high), holding the anim on "hold-frame";
// its effects hit what it lands on, "finish-" effects play where it lands.
class HoH1JumpStrike : HoH1Skill
{
	AnimString@ m_anim;
	int m_holdFrame;
	int m_preCast;
	int m_preCastC;
	int m_castingC;
	int m_postCastC;
	SoundEvent@ m_sound;
	SoundEvent@ m_soundStart;
	EffectList@ m_effects;
	EffectList@ m_finishEffects;
	vec2 m_dir;
	string m_currAnim;
	float m_speed;
	int m_airTime;
	int m_jumpHeight;
	bool m_glide;
	string m_offset;

	HoH1JumpStrike(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		@m_anim = AnimString(GetParamString(unit, params, "anim"));
		m_holdFrame = max(1, GetParamInt(unit, params, "hold-frame", false, 1));
		m_preCast = GetParamInt(unit, params, "pre-cast", false, m_holdFrame);
		@m_sound = Resources::GetSoundEvent(GetParamString(unit, params, "snd", false));
		@m_soundStart = Resources::GetSoundEvent(GetParamString(unit, params, "start-snd", false));
		m_speed = GetParamFloat(unit, params, "speed");
		m_airTime = max(1, GetParamInt(unit, params, "air-time"));
		m_jumpHeight = GetParamInt(unit, params, "jump-height", false, 0);
		m_glide = GetParamBool(unit, params, "glide", false, false);
		@m_effects = LoadEffects(unit, params);
		@m_finishEffects = LoadEffects(unit, params, "finish-");
		m_offset = GetParamString(unit, params, "offset", false);
	}

	bool HasOnCollide() override { return true; }
	bool IsCasting() override { return m_preCastC > 0 || m_castingC > 0 || m_postCastC > 0; }
	bool IsMoving() override { return IsCasting(); }

	void Destroyed() override { m_unit.SetPositionZ(0); }
	void OnDeath() override { Reset(false); }

	void Start(vec2 dir)
	{
		m_dir = dir;
		m_currAnim = m_anim.GetSceneName(atan(m_dir.y, m_dir.x));
		int animTime = m_behavior.SetUnitScene(m_currAnim, true);
		m_preCastC = max(1, m_preCast);
		m_castingC = 0;
		m_postCastC = max(0, animTime - m_holdFrame);
		PlaySound3D(m_soundStart, m_unit.GetPosition());
		m_unit.SetShouldCollideWithSame(false);
		m_restrictions.UseCharge();
		Started();
	}

	void Started() {}

	// stop moving and land; with `finished` the finish- effects play
	void Reset(bool finished)
	{
		bool was = IsCasting();
		m_cooldownC = m_cooldown;
		m_preCastC = 0;
		m_castingC = 0;
		m_postCastC = 0;
		m_unit.SetPositionZ(0);
		m_unit.SetShouldCollideWithSame(true);
		if (was && finished)
			ApplyEffects(m_finishEffects, m_behavior, UnitPtr(), FetchOffsetPos(m_unit, m_offset), m_behavior.GetDirection(), Intensity(), Husk());
	}

	void CancelSkill() override
	{
		bool was = IsCasting();
		Reset(true);
		if (was && Network::IsServer())
			UnitHandler::NetSendUnitUseSkill(m_unit, m_id, 1);
	}

	// the flight ended on its own
	void Landed() { CancelSkill(); }

	void NetUseSkill(int stage, SValue@ param) override
	{
		if (stage == 0)
			Start(ParamDir(param));
		else if (stage == 1)
			Reset(true);
	}

	void OnCollide(UnitPtr unit, vec2 normal) override
	{
		if (m_castingC <= 0 || cast<Pickup>(unit.GetScriptBehavior()) !is null)
			return;

		ApplyEffects(m_effects, m_behavior, unit, FetchOffsetPos(m_unit, m_offset), m_behavior.GetDirection(), Intensity(), Husk());
		if (unit.GetUnitProducer() !is m_unit.GetUnitProducer() && Network::IsServer())
			CancelSkill();
	}

	void Update(int dt, bool isCasting) override
	{
		if (m_cooldownC > 0 && !IsCasting())
		{
			m_cooldownC -= dt;
			return;
		}

		if (!IsCasting())
		{
			if (Ready(isCasting))
			{
				vec2 dir = Confused(TargetDir(xy(m_unit.GetPosition())));
				Start(dir);
				UnitHandler::NetSendUnitUseSkill(m_unit, m_id, 0, DirParam(dir));
			}
			return;
		}

		m_behavior.SetUnitScene(m_currAnim, false);

		vec2 vel;
		if (m_preCastC > 0)
		{
			m_preCastC -= dt;
			if (m_preCastC <= 0)
			{
				m_castingC = m_airTime;
				PlaySound3D(m_sound, m_unit.GetPosition());
			}
		}
		else if (m_castingC > 0)
		{
			m_unit.SetUnitSceneTime(m_holdFrame);
			vel = m_dir * m_speed;
			if (Network::IsServer() && m_jumpHeight > 0)
				m_unit.SetPositionZ(sin(m_castingC * PI / m_airTime) * m_jumpHeight, true);
			Flying(dt);

			m_castingC -= dt;
			if (m_castingC <= 0 && m_postCastC <= 0 && Network::IsServer())
				Landed();
		}
		else if (m_postCastC > 0)
		{
			if (m_glide)
			{
				auto scene = m_unit.GetCurrentUnitScene();
				int len = scene is null ? 0 : scene.Length() - m_holdFrame;
				if (len > 0)
					vel = m_dir * m_speed * (m_postCastC / float(len));
			}
			m_postCastC -= dt;
			if (m_postCastC <= 0 && Network::IsServer())
				Landed();
		}

		if (Network::IsServer() && IsCasting())
			m_unit.GetPhysicsBody().SetLinearVelocity(vel);
	}

	void Flying(int dt) {}
}

// A charge in a straight line: like a jump strike, but everything in its
// path ("ray-num" rays "ray-width" apart, reaching "ray-length" ahead) is
// hit once; it stops at a wall or an impenetrable actor, playing
// "anim-stop" when it has one.
class HoH1ChargeStrike : HoH1JumpStrike
{
	array<UnitPtr> m_hitUnits;
	AnimString@ m_animStop;
	int m_stoppingC;
	int m_rayNum;
	int m_rayWidth;
	float m_rayLength;

	HoH1ChargeStrike(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_rayNum = GetParamInt(unit, params, "ray-num", false, 4);
		m_rayWidth = GetParamInt(unit, params, "ray-width", false, 3);
		m_rayLength = GetParamFloat(unit, params, "ray-length", false, 3.0f);
		m_holdFrame = 0;
		string stop = GetParamString(unit, params, "anim-stop", false);
		if (!stop.isEmpty())
			@m_animStop = AnimString(stop);
	}

	bool IsCasting() override { return m_stoppingC > 0 || HoH1JumpStrike::IsCasting(); }

	void Started() override
	{
		m_hitUnits.removeRange(0, m_hitUnits.length());
		m_stoppingC = 0;
	}

	void CancelSkill() override
	{
		m_stoppingC = 0;
		HoH1JumpStrike::CancelSkill();
	}

	void Hit(UnitPtr unit, vec2 pos)
	{
		if (m_hitUnits.find(unit) >= 0)
			return;
		m_hitUnits.insertLast(unit);
		ApplyEffects(m_effects, m_behavior, unit, pos, m_dir, Intensity(), Husk());
	}

	void OnCollide(UnitPtr unit, vec2 normal) override
	{
		if (m_castingC <= 0 || cast<Pickup>(unit.GetScriptBehavior()) !is null)
			return;

		Hit(unit, FetchOffsetPos(m_unit, m_offset));
		if (unit.GetUnitProducer() is m_unit.GetUnitProducer())
			return;
		auto actor = cast<Actor>(unit.GetScriptBehavior());
		if (actor !is null && !actor.Impenetrable())
			return;

		if (Network::IsServer())
			Landed();
	}

	void Landed() override
	{
		if (m_animStop is null)
		{
			CancelSkill();
			return;
		}
		Stop();
		UnitHandler::NetSendUnitUseSkill(m_unit, m_id, 2);
	}

	void Stop()
	{
		Reset(true);
		m_cooldownC = m_cooldown;
		m_stoppingC = max(1, m_behavior.SetUnitScene(m_animStop.GetSceneName(atan(m_dir.y, m_dir.x)), true));
	}

	void NetUseSkill(int stage, SValue@ param) override
	{
		if (stage == 2)
		{
			if (m_animStop !is null)
				Stop();
		}
		else
			HoH1JumpStrike::NetUseSkill(stage, param);
	}

	void Flying(int dt) override
	{
		vec2 from = xy(m_unit.GetPosition());
		vec2 to = from + m_dir * (m_speed * dt / 33.0 + m_rayLength);
		auto results = g_scene.RaycastWide(m_rayNum, m_rayWidth, from, to, ~0, RaycastType::Any);
		for (uint i = 0; i < results.length(); i++)
		{
			UnitPtr unit = results[i].FetchUnit(g_scene);
			auto taker = cast<IDamageTaker>(unit.GetScriptBehavior());
			if (taker !is null && !taker.ShootThrough(m_behavior, from, m_dir))
				Hit(unit, from);
		}
	}

	void Update(int dt, bool isCasting) override
	{
		if (m_stoppingC > 0)
		{
			m_stoppingC -= dt;
			m_cooldownC = m_cooldown;
			m_behavior.SetUnitScene(m_animStop.GetSceneName(atan(m_dir.y, m_dir.x)), false);
			if (Network::IsServer())
				m_unit.GetPhysicsBody().SetLinearVelocity(vec2());
			return;
		}
		HoH1JumpStrike::Update(dt, isCasting);
	}
}

// A stream of "projectile" for "duration" ms after "castpoint", one every
// "rate" ms within "spread" degrees, turning after the target unless
// "hold-dir". "start-" actions run when it starts, the plain actions with
// the first shot.
class HoH1SpewSkill : HoH1Skill
{
	AnimString@ m_anim;
	int m_castpoint;
	int m_duration;
	int m_durationC;
	float m_spread;
	int m_rate;
	int m_rateC;
	SoundEvent@ m_loopSnd;
	SoundInstance@ m_loopI;
	SoundEvent@ m_startSnd;
	SoundEvent@ m_stopSnd;
	SoundEvent@ m_fireSnd;
	SoundEvent@ m_firstFireSnd;
	bool m_firstShot;
	UnitProducer@ m_projProd;
	string m_offset;
	bool m_holdDir;
	bool m_ignoreIsCasting;
	float m_interceptSpeed;
	vec2 m_dir;
	ActionList@ m_actions;
	ActionList@ m_startActions;

	HoH1SpewSkill(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		@m_anim = AnimString(GetParamString(unit, params, "anim"));
		m_castpoint = GetParamInt(unit, params, "castpoint", false, 0);
		m_duration = GetParamInt(unit, params, "duration");
		@m_projProd = Resources::GetUnitProducer(GetParamString(unit, params, "projectile"));
		m_offset = GetParamString(unit, params, "offset", false);
		@m_loopSnd = Resources::GetSoundEvent(GetParamString(unit, params, "snd", false));
		@m_startSnd = Resources::GetSoundEvent(GetParamString(unit, params, "start-snd", false));
		@m_stopSnd = Resources::GetSoundEvent(GetParamString(unit, params, "stop-snd", false));
		@m_fireSnd = Resources::GetSoundEvent(GetParamString(unit, params, "fire-snd", false));
		@m_firstFireSnd = Resources::GetSoundEvent(GetParamString(unit, params, "first-fire-snd", false));
		m_spread = GetParamInt(unit, params, "spread", false, 0) * PI / 180.0;
		m_rate = max(1, GetParamInt(unit, params, "rate", false, 33));
		m_holdDir = GetParamBool(unit, params, "hold-dir", false, false);
		m_ignoreIsCasting = GetParamBool(unit, params, "ignore-is-casting", false, false);
		m_interceptSpeed = GetParamFloat(unit, params, "aim-interception", false, -1);
		@m_actions = LoadActions(unit, params);
		@m_startActions = LoadActions(unit, params, "start-");
	}

	bool IsCasting() override { return !m_ignoreIsCasting && m_durationC > 0; }

	void PropagateSkillWeaponInformation(uint weaponInfo) override
	{
		PropagateWeaponInformation(m_actions, weaponInfo);
		PropagateWeaponInformation(m_startActions, weaponInfo);
	}

	void StopLoop(bool withSound)
	{
		if (m_loopI is null)
			return;
		m_loopI.Stop();
		@m_loopI = null;
		if (withSound)
			PlaySound3D(m_stopSnd, m_unit.GetPosition());
	}

	void Destroyed() override { StopLoop(false); }
	void OnDeath() override { CancelSkill(); }

	void CancelSkill() override
	{
		if (m_durationC > 0)
			m_cooldownC = m_cooldown;
		m_durationC = 0;
		StopLoop(true);
	}

	vec2 Aim(vec2 from)
	{
		auto target = m_behavior.m_target;
		if (target is null)
			return m_dir;
		vec2 tpos = xy(target.m_unit.GetPosition());
		if (m_interceptSpeed > 0)
			tpos = intercept(from, tpos, target.m_unit.GetMoveDir(), m_interceptSpeed);
		vec2 d = tpos - from;
		return (d.x == 0 && d.y == 0) ? m_dir : normalize(d);
	}

	void NetUseSkill(int stage, SValue@ param) override
	{
		vec2 pos = FetchOffsetPos(m_unit, m_offset);
		if (stage == 0)
		{
			m_cooldownC = 0;
			m_durationC = m_duration + m_castpoint;
			m_rateC = m_castpoint;
			m_dir = Aim(xy(m_unit.GetPosition()));
			m_firstShot = true;
			m_restrictions.UseCharge();
			PlaySound3D(m_startSnd, m_unit.GetPosition());
			if (!Network::IsServer())
				NetDoActions(m_startActions, param, m_behavior, pos, Aim(pos));
			m_behavior.SetUnitScene(m_anim.GetSceneName(atan(m_dir.y, m_dir.x)), true);
		}
		else if (stage == 1)
			NetDoActions(m_actions, param, m_behavior, pos, Aim(pos));
	}

	void Update(int dt, bool isCasting) override
	{
		if (m_durationC <= 0)
		{
			if (m_cooldownC > 0)
			{
				m_cooldownC -= dt;
				return;
			}
			// a target is only needed to start; a running spew plays out (Aim keeps
			// the last direction when the target is gone)
			if (m_behavior.m_target !is null && Network::IsServer() && !isCasting && m_restrictions.IsAvailable() && m_restrictions.CanSee(m_behavior.m_target.m_unit))
			{
				vec2 pos = FetchOffsetPos(m_unit, m_offset);
				SValue@ param = DoActions(m_startActions, m_behavior, m_behavior.m_target, pos, Aim(pos));
				NetUseSkill(0, param);
				UnitHandler::NetSendUnitUseSkill(m_unit, m_id, 0, param);
			}
			return;
		}

		if (!m_holdDir)
			m_dir = Aim(xy(m_unit.GetPosition()));
		float ang = atan(m_dir.y, m_dir.x);
		m_behavior.m_movement.m_dir = ang;
		m_behavior.SetUnitScene(m_anim.GetSceneName(ang), false);

		auto body = m_unit.GetPhysicsBody();
		if (body !is null)
			body.SetLinearVelocity(0, 0);

		for (m_rateC -= dt; m_rateC <= 0; m_rateC += m_rate)
			Shoot();

		UpdateActions(m_actions, dt, m_cooldownC);

		m_durationC -= dt;
		if (m_durationC <= 0)
		{
			m_cooldownC = m_cooldown;
			StopLoop(true);
		}
	}

	void Shoot()
	{
		if (m_loopI is null && m_loopSnd !is null)
			@m_loopI = m_loopSnd.PlayTracked(m_unit.GetPosition());

		vec2 pos = FetchOffsetPos(m_unit, m_offset);
		if (m_firstShot)
		{
			m_firstShot = false;
			PlaySound3D(m_firstFireSnd, m_unit.GetPosition());
			if (Network::IsServer() && !m_actions.isEmpty())
				UnitHandler::NetSendUnitUseSkill(m_unit, m_id, 1, DoActions(m_actions, m_behavior, m_behavior.m_target, pos, Aim(pos)));
		}
		else
			PlaySound3D(m_fireSnd, m_unit.GetPosition());

		if (m_projProd is null)
			return;

		vec2 dir = addrot(m_dir, randfn() * m_spread);
		UnitPtr proj = m_projProd.Produce(g_scene, xyz(pos + dir * 3.0));
		auto p = proj.IsValid() ? cast<IProjectile>(proj.GetScriptBehavior()) : null;
		if (p !is null)
			p.Initialize(m_behavior, ProjectileTarget(atan(dir.y, dir.x), m_behavior.m_target), 1.0, Husk(), 0);
	}
}

// A spin toward the target for "duration" ms: from "castpoint" on its
// effects hit around it every "freq" ms, and it speeds up ("acceleration"
// per second up to "speed") while turning after the target ("turnspeed").
class HoH1WhirlwindSkill : HoH1Skill
{
	AnimString@ m_anim;
	int m_castpoint;
	int m_duration;
	int m_freq;
	int m_castingC;
	int m_freqC;
	float m_currSpeed;
	float m_speed;
	float m_acceleration;
	bool m_accelerate;
	float m_turnSpeed;
	float m_dir;
	SoundEvent@ m_sound;
	SoundInstance@ m_soundI;
	EffectList@ m_effects;

	HoH1WhirlwindSkill(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		@m_anim = AnimString(GetParamString(unit, params, "anim"));
		m_speed = GetParamFloat(unit, params, "speed");
		m_acceleration = GetParamFloat(unit, params, "acceleration", false, m_speed);
		m_turnSpeed = GetParamFloat(unit, params, "turnspeed", false, 1.0f);
		m_duration = GetParamInt(unit, params, "duration");
		m_freq = max(1, GetParamInt(unit, params, "freq"));
		m_castpoint = GetParamInt(unit, params, "castpoint", false, 0);
		@m_sound = Resources::GetSoundEvent(GetParamString(unit, params, "snd", false));
		@m_effects = LoadEffects(unit, params, "", 1, 1, 1);
	}

	bool IsCasting() override { return m_castingC > 0; }
	bool IsMoving() override { return m_castingC > 0; }
	void OnDeath() override { CancelSkill(); }
	void Destroyed() override { Stop(); }

	void Stop()
	{
		m_castingC = 0;
		if (m_soundI !is null)
		{
			m_soundI.Stop();
			@m_soundI = null;
		}
	}

	void CancelSkill() override
	{
		bool was = m_castingC > 0;
		Stop();
		if (was && Network::IsServer())
			UnitHandler::NetSendUnitUseSkill(m_unit, m_id, 1);
	}

	void NetUseSkill(int stage, SValue@ param) override
	{
		if (stage != 0)
		{
			Stop();
			return;
		}

		m_restrictions.UseCharge();
		m_currSpeed = 0;
		m_cooldownC = m_cooldown;
		m_castingC = max(1, m_duration);
		m_freqC = m_castpoint;
		m_accelerate = false;
		vec2 dir = TargetDir(xy(m_unit.GetPosition()));
		m_dir = atan(dir.y, dir.x);
		m_behavior.SetUnitScene(m_anim.GetSceneName(m_behavior.m_movement.m_dir), true);
		if (m_sound !is null)
			@m_soundI = m_sound.PlayTracked(m_unit.GetPosition());
	}

	void Update(int dt, bool isCasting) override
	{
		if (m_soundI !is null)
			m_soundI.SetPosition(m_unit.GetPosition());

		if (m_castingC > 0)
		{
			if (m_accelerate)
				m_currSpeed = min(m_speed, m_currSpeed + m_acceleration * dt / 1000.0f);

			vec2 toTarget = Confused(TargetDir(xy(m_unit.GetPosition())));
			vec2 moveDir = vec2(cos(m_dir), sin(m_dir));
			m_dir = HoH1LerpRot(m_dir, atan(toTarget.y, toTarget.x), m_turnSpeed);

			if (Network::IsServer())
			{
				auto body = m_unit.GetPhysicsBody();
				if (m_currSpeed > 0)
					body.SetStatic(false);
				body.SetLinearVelocity(moveDir * m_currSpeed);
			}

			m_freqC -= dt;
			if (m_freqC <= 0)
			{
				m_freqC += m_freq;
				m_accelerate = true;
				ApplyEffects(m_effects, m_behavior, m_unit, xy(m_unit.GetPosition()), moveDir, Intensity(), Husk());
			}

			m_castingC -= dt;
			if (m_castingC <= 0 && Network::IsServer())
				CancelSkill();
			return;
		}

		if (m_cooldownC > 0)
		{
			m_cooldownC -= dt;
			return;
		}

		if (Ready(isCasting))
		{
			NetUseSkill(0, null);
			UnitHandler::NetSendUnitUseSkill(m_unit, m_id);
		}
	}
}

// A spinning nova: after "castpoint", one "projectile" every "proj-delay"
// ms for "duration" ms, each "per-revolution"-th of a turn further round,
// starting "angle-offset" degrees from the target ("targeted") or from east,
// "proj-dist" out from the caster.
class HoH1WhirlNovaSkill : HoH1Skill
{
	AnimString@ m_anim;
	int m_castpoint;
	int m_castpointC;
	int m_duration;
	int m_durationC;
	int m_animationC;
	UnitProducer@ m_projProd;
	SoundEvent@ m_startSnd;
	SoundEvent@ m_fireSnd;
	string m_offset;
	float m_projDist;
	int m_projDelay;
	int m_perRev;
	bool m_targeted;
	float m_angleOffset;

	HoH1WhirlNovaSkill(UnitPtr unit, SValue& params)
	{
		super(unit, params, false);
		@m_anim = AnimString(GetParamString(unit, params, "anim"));
		m_castpoint = GetParamInt(unit, params, "castpoint");
		m_duration = GetParamInt(unit, params, "duration", false, 1000);
		@m_projProd = Resources::GetUnitProducer(GetParamString(unit, params, "projectile"));
		@m_startSnd = Resources::GetSoundEvent(GetParamString(unit, params, "start-snd", false));
		@m_fireSnd = Resources::GetSoundEvent(GetParamString(unit, params, "fire-snd", false));
		m_projDist = GetParamFloat(unit, params, "proj-dist", false, 0);
		m_projDelay = max(1, GetParamInt(unit, params, "proj-delay", false, 33));
		m_perRev = max(1, GetParamInt(unit, params, "per-revolution", false, 1));
		m_targeted = GetParamBool(unit, params, "targeted", false, false);
		m_angleOffset = GetParamInt(unit, params, "angle-offset", false, 0) * PI / 180.0f;
		m_offset = GetParamString(unit, params, "offset", false, "");
	}

	bool IsCasting() override { return m_durationC > 0 || m_castpointC > 0 || m_animationC > 0; }

	void CancelSkill() override
	{
		// an interrupted nova still waits out its cooldown, like a finished one
		if (m_durationC > 0 || m_castpointC > 0)
			m_cooldownC = m_cooldown;
		m_durationC = 0;
		m_castpointC = 0;
		m_animationC = 0;
	}

	void NetUseSkill(int stage, SValue@ param) override
	{
		if (m_castpoint > 0)
			m_castpointC = m_castpoint;
		else
			m_durationC = m_duration;
		m_cooldownC = 0;
		m_animationC = m_behavior.SetUnitScene(m_anim.GetSceneName(m_behavior.m_movement.m_dir), true);
		PlaySound3D(m_startSnd, m_unit.GetPosition());
		m_restrictions.UseCharge();
	}

	void Update(int dt, bool isCasting) override
	{
		if (IsCasting() && Network::IsServer())
			m_unit.GetPhysicsBody().SetLinearVelocity(0, 0);
		if (m_animationC > 0)
			m_animationC -= dt;

		if (!IsCasting())
		{
			if (m_cooldownC > 0)
			{
				m_cooldownC -= dt;
				return;
			}
			if (Ready(isCasting))
			{
				NetUseSkill(0, null);
				UnitHandler::NetSendUnitUseSkill(m_unit, m_id);
			}
			return;
		}

		if (m_castpointC > 0)
		{
			m_castpointC -= dt;
			if (m_castpointC <= 0)
				m_durationC = m_duration;
			return;
		}

		if (m_durationC <= 0)
			return;

		float start = m_angleOffset;
		if (m_targeted && m_behavior.m_target !is null)
		{
			vec2 d = TargetDir(xy(m_unit.GetPosition()));
			start += atan(d.y, d.x);
		}

		if (m_durationC % m_projDelay < dt && m_projProd !is null)
		{
			float angle = start + (2 * PI / m_perRev) * (m_durationC / m_projDelay);
			vec2 dir = vec2(cos(angle), sin(angle));
			vec3 pos = xyz(FetchOffsetPos(m_unit, m_offset) + dir * m_projDist);
			UnitPtr proj = m_projProd.Produce(g_scene, pos);
			auto p = proj.IsValid() ? cast<IProjectile>(proj.GetScriptBehavior()) : null;
			if (p !is null)
			{
				p.Initialize(m_behavior, ProjectileTarget(angle), 1.0, Husk(), 0);
				PlaySound3D(m_fireSnd, pos);
			}
		}

		m_durationC -= dt;
		if (m_durationC <= 0)
			m_cooldownC = m_cooldown;
	}
}
