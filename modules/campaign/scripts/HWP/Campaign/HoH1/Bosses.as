// HoH2 implementations of the HoH1 boss behaviors: the Armory wraiths
// (BossLich), the Chambers vampire lord (BossVampire) and the Archives
// watcher (BossEye) with its wisps, under HoH1-prefixed names
// (tools/import_hoh1.py maps them) and HoH1's unit parameters. Host
// decisions reach the other peers through HWP::Net events ("hoh1.*").
namespace HWP
{
	namespace HoH1
	{
		SValue@ Ints(int a, int b = 0, int c = 0, int count = 1)
		{
			SValueBuilder sv;
			sv.PushArray();
			sv.PushInteger(a);
			if (count > 1)
				sv.PushInteger(b);
			if (count > 2)
				sv.PushInteger(c);
			sv.PopArray();
			return sv.Build();
		}

		int UnitId(WorldScript::BossLichNode@ node)
		{
			auto ws = node is null ? null : WorldScript::GetWorldScript(g_scene, node);
			return ws is null ? 0 : ws.GetUnit().GetId();
		}

		WorldScript::BossLichNode@ NodeOf(int unitId)
		{
			UnitPtr unit = g_scene.GetUnit(unitId);
			return unit.IsValid() ? cast<WorldScript::BossLichNode>(unit.GetScriptBehavior()) : null;
		}

		ref@ BehaviorOf(SValue@ id)
		{
			UnitPtr unit = g_scene.GetUnit(id.GetInteger());
			if (!unit.IsValid())
				return null;
			return unit.GetScriptBehavior();
		}

		WorldScript::BossLichNode@ AnyNode()
		{
			auto nodes = LichNodes();
			if (nodes.length() == 0)
				return null;
			return nodes[randi(nodes.length())];
		}

		// The direction of the closest enemy within 300, else where the actor faces.
		vec2 NearestEnemyDir(CompositeActorBehavior@ actor)
		{
			vec2 me = xy(actor.m_unit.GetPosition());
			auto found = g_scene.FetchActorsWithOtherTeam(actor.Team, me, 300);
			if (found.length() == 0)
				return actor.GetDirection();

			uint best = 0;
			float bestSq = distsq(xy(found[0].GetPosition()), me);
			for (uint i = 1; i < found.length(); i++)
			{
				float d = distsq(xy(found[i].GetPosition()), me);
				if (d < bestSq)
				{
					bestSq = d;
					best = i;
				}
			}
			return normalize(xy(found[best].GetPosition()) - me);
		}

		void RegisterNet()
		{
			HWP::Net::OnEvent("hoh1.lich.node", HWP::Net::EventHandler(OnLichNode));
			HWP::Net::OnEvent("hoh1.vampire.node", HWP::Net::EventHandler(OnVampireNode));
			HWP::Net::OnEvent("hoh1.vampire.arrived", HWP::Net::EventHandler(OnVampireArrived));
			HWP::Net::OnEvent("hoh1.vampire.roaming", HWP::Net::EventHandler(OnVampireRoaming));
			HWP::Net::OnEvent("hoh1.eye.wisps", HWP::Net::EventHandler(OnEyeWisps));
			HWP::Net::OnEvent("hoh1.eye.sync", HWP::Net::EventHandler(OnEyeSync));
		}

		// [boss unit, node unit]
		void OnLichNode(SValue@ data)
		{
			auto arr = data.GetArray();
			auto boss = cast<CompositeActorBehavior>(BehaviorOf(arr[0]));
			auto movement = boss is null ? null : cast<HoH1BossLichMovement>(boss.m_movement);
			if (movement !is null && !Network::IsServer())
				movement.SetTargetNode(NodeOf(arr[1].GetInteger()));
		}

		// [boss unit, node unit, wait ms]
		void OnVampireNode(SValue@ data)
		{
			auto arr = data.GetArray();
			auto boss = cast<HoH1BossVampire>(BehaviorOf(arr[0]));
			auto movement = boss is null ? null : cast<HoH1BossVampireMovement>(boss.m_movement);
			if (movement !is null && !Network::IsServer())
				movement.SetTargetNode(NodeOf(arr[1].GetInteger()), arr[2].GetInteger());
		}

		// [boss unit]
		void OnVampireArrived(SValue@ data)
		{
			auto boss = cast<HoH1BossVampire>(BehaviorOf(data.GetArray()[0]));
			auto movement = boss is null ? null : cast<HoH1BossVampireMovement>(boss.m_movement);
			if (movement !is null && !Network::IsServer())
				movement.NetOnNodeArrived();
		}

		// [boss unit]
		void OnVampireRoaming(SValue@ data)
		{
			auto boss = cast<HoH1BossVampire>(BehaviorOf(data.GetArray()[0]));
			if (boss !is null && !Network::IsServer())
				boss.m_roamingC = boss.m_roaming;
		}

		// [boss unit, wisp unit file ("" = the boss's own), wisp unit ids...]
		void OnEyeWisps(SValue@ data)
		{
			auto arr = data.GetArray();
			auto boss = cast<HoH1BossEye>(BehaviorOf(arr[0]));
			if (boss is null || Network::IsServer())
				return;

			string file = arr[1].GetString();
			UnitProducer@ prod = file.isEmpty() ? boss.m_wispProd : Resources::GetUnitProducer(file);
			if (prod is null)
				return;
			uint num = arr.length() - 2;
			for (uint i = 0; i < num; i++)
			{
				UnitPtr unit = prod.Produce(g_scene, boss.m_unit.GetPosition(), arr[i + 2].GetInteger());
				boss.Attach(cast<HoH1BossEyeWisp>(unit.GetScriptBehavior()), i, num);
			}
		}

		// [boss unit, angle, distance, angle, distance, ...]
		void OnEyeSync(SValue@ data)
		{
			auto arr = data.GetArray();
			auto boss = cast<HoH1BossEye>(BehaviorOf(arr[0]));
			if (boss is null || Network::IsServer())
				return;

			uint n = min(boss.m_wisps.length(), (arr.length() - 1) / 2);
			for (uint i = 0; i < n; i++)
			{
				boss.m_wisps[i].m_currAngle = arr[1 + i * 2].GetFloat();
				boss.m_wisps[i].m_currDistance = arr[2 + i * 2].GetFloat();
			}
		}
	}
}


// The Armory wraiths: they drift between BossLichNode points through walls,
// cannot be targeted while moving, only fight inside the BossLichRoom (and
// not from inside a wall), and their "effects" (a mana leak) tick on players
// touching them every "effects-time" ms.
class HoH1BossLich : CompositeActorBehavior
{
	WorldScript::BossLichRoom@ m_room;
	bool m_roomFetched;
	array<Actor@> m_actorsInside;
	array<UnitPtr> m_insideWalls;
	EffectList@ m_touchEffects;
	int m_touchTime;
	int m_touchTimeC;

	HoH1BossLich(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		@m_touchEffects = LoadEffects(unit, params);
		m_touchTime = max(1, GetParamInt(unit, params, "effects-time", false, 100));
		m_touchTimeC = m_touchTime;
	}

	// it tracks what it overlaps; nothing else asks for collide callbacks
	void RefreshShouldUseCollideCallbacks() override
	{
		m_unit.SetShouldUseCollideCallbacks(true);
	}

	void Update(int dt) override
	{
		if (!m_roomFetched)
		{
			// the room is part of this boss's level: look it up once
			@m_room = HWP::HoH1::LichRoom();
			m_roomFetched = true;
		}
		auto room = m_room;
		if (room !is null && (!room.IsInside(m_unit.GetPosition()) || m_insideWalls.length() > 0))
			@m_target = null;
		else if (m_target is null)
			m_targetSearchCd = 0;

		CompositeActorBehavior::Update(dt);
		if (IsDead())
			return;

		for (uint i = 0; i < m_skills.length(); i++)
		{
			if (m_skills[i].IsCasting())
				return;
		}

		m_touchTimeC -= dt;
		if (m_touchTimeC > 0)
			return;
		m_touchTimeC = m_touchTime;

		for (uint i = 0; i < m_actorsInside.length(); i++)
		{
			auto player = cast<PlayerBase>(m_actorsInside[i]);
			if (player !is null && !player.IsDead())
				ApplyEffects(m_touchEffects, this, player.m_unit, xy(player.m_unit.GetPosition()), vec2(), 1.0f, player.IsHusk());
		}
	}

	void Collide(UnitPtr unit, vec2 pos, vec2 normal, Fixture@ fxSelf, Fixture@ fxOther) override
	{
		ref@ b = unit.GetScriptBehavior();
		auto actor = cast<Actor>(b);
		if (actor !is null)
			m_actorsInside.insertLast(actor);
		else if (b is null && !fxOther.IsSensor())
			m_insideWalls.insertLast(unit);

		CompositeActorBehavior::Collide(unit, pos, normal, fxSelf, fxOther);
	}

	void EndCollision(UnitPtr unit, Fixture@ fxSelf, Fixture@ fxOther)
	{
		int wall = m_insideWalls.find(unit);
		if (wall >= 0)
			m_insideWalls.removeAt(wall);

		auto actor = cast<Actor>(unit.GetScriptBehavior());
		int index = actor is null ? -1 : m_actorsInside.findByRef(actor);
		if (index >= 0)
			m_actorsInside.removeAt(index);
	}

	vec2 GetCastDirection() override { return HWP::HoH1::NearestEnemyDir(this); }

	bool IsTargetable() override
	{
		auto body = m_unit.GetPhysicsBody();
		if (body !is null && !body.IsStatic())
			return false;
		return CompositeActorBehavior::IsTargetable();
	}

	bool ShootThrough(Actor@ attacker, vec2 pos, vec2 dir) override { return !IsTargetable(); }
}

// Walks node to node ("speed", "anim-walk"), running each node's world
// script on arrival; stands still while casting.
class HoH1BossLichMovement : ActorMovement
{
	AnimString@ m_idleAnim;
	AnimString@ m_walkAnim;
	float m_speed;
	WorldScript::BossLichNode@ m_node;

	HoH1BossLichMovement(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		@m_idleAnim = AnimString(GetParamString(unit, params, "anim-idle"));
		@m_walkAnim = AnimString(GetParamString(unit, params, "anim-walk"));
		m_speed = GetParamFloat(unit, params, "speed");
	}

	void Initialize(UnitPtr unit, CompositeActorBehavior& behavior) override
	{
		ActorMovement::Initialize(unit, behavior);
		m_unit.SetUnitScene(m_idleAnim.GetSceneName(m_dir), false);
	}

	WorldScript::BossLichNode@ FindNewNode()
	{
		auto next = m_node is null ? null : m_node.PickNextNode();
		return next !is null ? next : HWP::HoH1::AnyNode();
	}

	void SetTargetNode(WorldScript::BossLichNode@ node)
	{
		@m_node = node;
		if (Network::IsServer() && node !is null)
			HWP::Net::Broadcast("hoh1.lich.node", HWP::HoH1::Ints(m_unit.GetId(), HWP::HoH1::UnitId(node), 0, 2));
	}

	void Update(int dt, bool isCasting) override
	{
		if (!m_enabled)
			return;

		auto body = m_unit.GetPhysicsBody();
		if (body is null)
			return;

		if (isCasting)
		{
			if (m_behavior.m_target !is null)
				body.SetStatic(true);
			return;
		}

		SetUnitScene(m_walkAnim.GetSceneName(m_dir), false);
		body.SetStatic(false);

		if (Network::IsServer())
		{
			if (m_node is null)
				SetTargetNode(FindNewNode());
			else if (dist(m_unit.GetPosition(), m_node.Position) < 5.0f)
			{
				auto ws = WorldScript::GetWorldScript(g_scene, m_node);
				if (ws !is null)
					ws.Execute();
				SetTargetNode(FindNewNode());
			}
		}

		if (m_node !is null)
		{
			vec2 dir = xy(normalize(m_node.Position - m_unit.GetPosition()));
			body.SetLinearVelocity(dir * m_speed);
			m_dir = atan(dir.y, dir.x);
		}
	}
}

// The wraiths' periodic attack: as CompositeActorPeriodicTriggeredSkill,
// but it waits while no enemy is within "max-range", and with an enemy
// within "melee-range" it may fire early ("melee-chance", at most every
// "melee-cooldown" ms).
class HoH1BossLichRandomSkill : CompositeActorPeriodicTriggeredSkill
{
	int m_maxRange;
	int m_meleeRange;
	float m_meleeChance;
	int m_meleeCooldown;
	int m_meleeCooldownC;

	HoH1BossLichRandomSkill(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_maxRange = GetParamInt(unit, params, "max-range", false, -1);
		m_meleeRange = GetParamInt(unit, params, "melee-range");
		m_meleeChance = GetParamFloat(unit, params, "melee-chance", false, 0.5f);
		m_meleeCooldown = GetParamInt(unit, params, "melee-cooldown", false, 2000);
	}

	void Update(int dt, bool isCasting) override
	{
		vec2 pos = xy(m_unit.GetPosition());
		if (m_maxRange != -1 && !isCasting && g_scene.FetchActorsWithOtherTeam(m_behavior.Team, pos, m_maxRange).length() == 0)
			return;

		CompositeActorPeriodicTriggeredSkill::Update(dt, isCasting);
		if (isCasting)
			return;

		if (m_meleeCooldownC > 0)
		{
			m_meleeCooldownC -= dt;
			if (m_meleeCooldownC > 0)
				return;
		}

		if (g_scene.FetchActorsWithOtherTeam(m_behavior.Team, pos, m_meleeRange).length() == 0)
			return;
		m_meleeCooldownC = m_meleeCooldown;

		if (Network::IsServer() && randf() <= m_meleeChance && m_restrictions.IsAvailable())
		{
			m_periodC = float(m_period + randi(m_periodRandom));
			Trigger(m_unit);
		}
	}

	void Trigger(UnitPtr target) override
	{
		m_meleeCooldownC = m_meleeCooldown;
		CompositeActorPeriodicTriggeredSkill::Trigger(target);
	}
}


// The Chambers vampire lord. Between casts it flies node to node as a bat
// swarm (untargetable); every "center-count" hops it returns to the
// VampireCenterNode. With "roam-flag" set it sometimes ("roam-chance")
// roams for "roaming" hops instead, dropping "roam-unit" every
// "roam-unit-interval" ms.
class HoH1BossVampire : CompositeActorBehavior
{
	int m_roaming;
	int m_roamingC = -1;
	float m_roamChance;
	string m_roamFlag;
	UnitProducer@ m_roamProd;
	SoundEvent@ m_roamSnd;
	int m_roamSpawnTime;
	int m_roamSpawnTimeC;

	HoH1BossVampire(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		m_roaming = GetParamInt(unit, params, "roaming", false, 3);
		m_roamChance = GetParamFloat(unit, params, "roam-chance", false, 0.25f);
		m_roamFlag = GetParamString(unit, params, "roam-flag", false, "vampire_roaming");
		@m_roamProd = Resources::GetUnitProducer(GetParamString(unit, params, "roam-unit", false, ""));
		@m_roamSnd = Resources::GetSoundEvent(GetParamString(unit, params, "roam-unit-snd", false));
		m_roamSpawnTime = max(1, GetParamInt(unit, params, "roam-unit-interval", false, 150));
		m_frozen = true;
	}

	void Update(int dt) override
	{
		if (m_target is null)
			m_targetSearchCd = 0;

		// the roam unit (the fire trail) is netsynced (tools/hoh1_convert.py NETSYNC):
		// the host drops it, clients get it from the network
		if (m_roamingC > 0 && m_roamProd !is null && Network::IsServer())
		{
			m_roamSpawnTimeC -= dt;
			if (m_roamSpawnTimeC <= 0)
			{
				m_roamSpawnTimeC = m_roamSpawnTime;
				vec3 pos = m_unit.GetPosition();
				m_roamProd.Produce(g_scene, pos);
				PlaySound3D(m_roamSnd, pos);
			}
		}

		CompositeActorBehavior::Update(dt);
	}

	void NetOnNodeArrived()
	{
		if (m_roamingC >= 0)
			m_roamingC--;
	}

	void OnNodeArrived(WorldScript::BossLichNode@ node)
	{
		if (!g_flags.IsSet(m_roamFlag) || node is HWP::HoH1::CenterNode())
			return;
		if (m_roamingC == -1 && randf() <= m_roamChance)
		{
			m_roamingC = m_roaming;
			HWP::Net::Broadcast("hoh1.vampire.roaming", HWP::HoH1::Ints(m_unit.GetId()));
		}
	}

	vec2 GetCastDirection() override { return HWP::HoH1::NearestEnemyDir(this); }

	bool IsTargetable() override
	{
		auto body = m_unit.GetPhysicsBody();
		if (body !is null && !body.IsStatic())
			return false;
		return CompositeActorBehavior::IsTargetable();
	}

	bool ShootThrough(Actor@ attacker, vec2 pos, vec2 dir) override { return !IsTargetable(); }
}

class HoH1BossVampireMovement : ActorMovement
{
	HoH1BossVampire@ m_vampire;
	AnimString@ m_idleAnim;
	AnimString@ m_walkAnim;
	float m_speed;
	float m_speedRoam;

	WorldScript::BossLichNode@ m_node;
	WorldScript::BossLichNode@ m_lastNode;

	int m_nodeWaitTime;
	int m_nodeWaitTimeRandom;
	int m_nodeWaitTimeC;
	int m_centerCount;
	int m_centerCountC;

	bool m_transformed;
	UnitScene@ m_transformFx;

	HoH1BossVampireMovement(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		@m_idleAnim = AnimString(GetParamString(unit, params, "anim-idle"));
		@m_walkAnim = AnimString(GetParamString(unit, params, "anim-walk"));
		m_speed = GetParamFloat(unit, params, "speed");
		m_speedRoam = GetParamFloat(unit, params, "speed-roam", false, m_speed);
		m_nodeWaitTime = GetParamInt(unit, params, "node-wait-time", false, 2000);
		m_nodeWaitTimeRandom = GetParamInt(unit, params, "node-wait-time-random", false, 2000);
		m_centerCount = GetParamInt(unit, params, "center-count", false, 4);
		@m_transformFx = Resources::GetEffect(GetParamString(unit, params, "transform-fx", false));
	}

	void Initialize(UnitPtr unit, CompositeActorBehavior& behavior) override
	{
		ActorMovement::Initialize(unit, behavior);
		@m_vampire = cast<HoH1BossVampire>(behavior);
		m_unit.SetUnitScene(m_idleAnim.GetSceneName(m_dir), false);
	}

	WorldScript::BossLichNode@ FindNewNode()
	{
		auto center = HWP::HoH1::CenterNode();
		if (center !is null && (m_vampire is null || m_vampire.m_roamingC <= 0) && ++m_centerCountC >= m_centerCount)
		{
			m_centerCountC = 0;
			return center;
		}

		if (m_node !is null)
		{
			WorldScript::BossLichNode@ next;
			for (int picks = 0; picks < 4; picks++)
			{
				@next = m_node.PickNextNode();
				if (next !is m_lastNode)
					break;
			}
			if (next !is null)
				return next;
		}
		return HWP::HoH1::AnyNode();
	}

	void SetTargetNode(WorldScript::BossLichNode@ node, int waitTime = -1)
	{
		@m_lastNode = m_node;
		@m_node = node;

		if (node !is null && node is HWP::HoH1::CenterNode())
			g_flags.Delete("thrall_res");

		m_nodeWaitTimeC = waitTime >= 0 ? waitTime : m_nodeWaitTime + randi(m_nodeWaitTimeRandom);

		if (Network::IsServer() && node !is null)
			HWP::Net::Broadcast("hoh1.vampire.node", HWP::HoH1::Ints(m_unit.GetId(), HWP::HoH1::UnitId(node), m_nodeWaitTimeC, 3));
	}

	void NetOnNodeArrived()
	{
		float dir = m_dir;
		if (m_behavior.m_target !is null)
		{
			vec2 v = xy(m_behavior.m_target.m_unit.GetPosition() - m_unit.GetPosition());
			if (v.x != 0 || v.y != 0)
				dir = atan(v.y, v.x);
		}
		m_unit.SetUnitScene(m_idleAnim.GetSceneName(dir), false);
		m_unit.GetPhysicsBody().SetLinearVelocity(vec2());

		if (m_vampire !is null)
			m_vampire.NetOnNodeArrived();
	}

	void OnNodeArrived()
	{
		HWP::Net::Broadcast("hoh1.vampire.arrived", HWP::HoH1::Ints(m_unit.GetId()));
		NetOnNodeArrived();

		if (m_vampire !is null)
		{
			m_vampire.OnNodeArrived(m_node);
			if (m_vampire.m_roamingC <= 0)
			{
				if (m_node is HWP::HoH1::CenterNode())
					g_flags.Set("vampire_middle", FlagState::Level);
				else
					g_flags.Delete("vampire_middle");
			}
		}

		auto ws = WorldScript::GetWorldScript(g_scene, m_node);
		if (ws !is null)
			ws.Execute();

		SetTargetNode(FindNewNode());
	}

	bool Roaming() { return m_vampire !is null && m_vampire.m_roamingC > 0; }

	void Update(int dt, bool isCasting) override
	{
		if (!m_enabled)
			return;

		auto body = m_unit.GetPhysicsBody();
		if (body is null)
			return;

		if (m_nodeWaitTimeC > 0)
			m_nodeWaitTimeC -= dt;

		// standing: casting or resting at a node
		if ((isCasting || m_nodeWaitTimeC > 0) && !Roaming())
		{
			if (m_behavior.m_target is null)
				return;
			if (m_transformed)
			{
				PlayEffect(m_transformFx, m_unit.GetPosition());
				m_transformed = false;
			}
			body.SetStatic(true);
			m_behavior.m_frozen = false;
			return;
		}

		// flying to the next node
		SetUnitScene((length(body.GetLinearVelocity()) > 0.5f ? m_walkAnim : m_idleAnim).GetSceneName(m_dir), false);
		if (!m_transformed)
		{
			PlayEffect(m_transformFx, m_unit.GetPosition());
			m_transformed = true;
		}
		body.SetStatic(false);
		m_behavior.m_frozen = true;

		if (Network::IsServer())
		{
			if (m_node is null)
				SetTargetNode(FindNewNode());
			else
			{
				vec3 toNode = m_node.Position - m_unit.GetPosition();
				float distance = length(toNode);
				float moveDot = dot(normalize(toNode), vec3(cos(m_dir), sin(m_dir), 0));
				if (distance < 5.0f || (distance < 32.0f && moveDot < 0.0f))
					OnNodeArrived();
			}
		}

		if (m_node !is null)
		{
			vec2 dir = xy(normalize(m_node.Position - m_unit.GetPosition()));
			body.SetLinearVelocity(dir * (Roaming() ? m_speedRoam : m_speed));
			m_dir = atan(dir.y, dir.x);
		}
	}
}


// The Archives watcher. World scripts add a ring of wisps ("wisp-unit")
// that circle it and reach out toward the players, suspend it
// ("scene-disappear", untargetable) and bring it back ("scene-appear").
class HoH1BossEye : CompositeActorBehavior
{
	UnitScene@ m_sceneDisappear;
	UnitScene@ m_sceneAppear;
	UnitProducer@ m_wispProd;
	int m_appearTimeC;
	int m_wispSyncC;
	array<HoH1BossEyeWisp@> m_wisps;

	HoH1BossEye(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		@m_sceneDisappear = m_unit.GetUnitScene(GetParamString(unit, params, "scene-disappear"));
		@m_sceneAppear = m_unit.GetUnitScene(GetParamString(unit, params, "scene-appear"));
		@m_wispProd = Resources::GetUnitProducer(GetParamString(unit, params, "wisp-unit"));
	}

	void Attach(HoH1BossEyeWisp@ wisp, uint i, uint num)
	{
		if (wisp is null)
			return;
		wisp.Set(i / float(num) * PI * 2, this);
		m_wisps.insertLast(wisp);
	}

	// host only; the peers spawn the same wisps from the event
	void AddWisps(int num, UnitProducer@ prod)
	{
		if (prod is null)
			@prod = m_wispProd;
		if (prod is null || num <= 0)
			return;

		SValueBuilder b;
		b.PushArray();
		b.PushInteger(m_unit.GetId());
		b.PushString(prod is m_wispProd ? "" : prod.GetResourceName());
		for (int i = 0; i < num; i++)
		{
			UnitPtr unit = prod.Produce(g_scene, m_unit.GetPosition());
			Attach(cast<HoH1BossEyeWisp>(unit.GetScriptBehavior()), i, num);
			b.PushInteger(unit.GetId());
		}
		b.PopArray();
		HWP::Net::Broadcast("hoh1.eye.wisps", b.Build());
	}

	void ClearWisps()
	{
		for (uint i = 0; i < m_wisps.length(); i++)
			m_wisps[i].Disappear();
		m_wisps.removeRange(0, m_wisps.length());
	}

	void Freeze(bool freeze)
	{
		m_frozen = freeze;
		m_movement.m_enabled = !freeze;
		auto body = m_unit.GetPhysicsBody();
		if (body !is null)
			body.SetStatic(freeze);
	}

	void Suspend()
	{
		if (m_frozen)
			return;
		Freeze(true);
		m_unit.SetUnitScene(m_sceneDisappear, true);
	}

	void Unsuspend()
	{
		if (!m_frozen)
			return;
		m_unit.SetUnitScene(m_sceneAppear, true);
		m_appearTimeC = max(1, m_sceneAppear.Length());
	}

	bool IsTargetable() override
	{
		return !m_frozen && CompositeActorBehavior::IsTargetable();
	}

	// spread the wisps over the living players, in player-slot order on every peer
	void FindWispTargets()
	{
		array<Actor@> players;
		for (uint i = 0; i < g_players.length(); i++)
		{
			if (g_players[i].peer != 255 && !g_players[i].IsDead() && g_players[i].actor !is null)
				players.insertLast(g_players[i].actor);
		}
		if (players.length() == 0)
			return;
		for (uint i = 0; i < m_wisps.length(); i++)
			@m_wisps[i].m_target = players[i % players.length()];
	}

	void Update(int dt) override
	{
		if (m_appearTimeC > 0)
		{
			m_appearTimeC -= dt;
			if (m_appearTimeC <= 0)
			{
				Freeze(false);
				m_wispSyncC = 2000;
			}
		}

		for (int i = int(m_wisps.length()) - 1; i >= 0; i--)
		{
			if (m_wisps[i].m_unit.IsDestroyed())
				m_wisps.removeAt(i);
		}
		FindWispTargets();

		if (m_wispSyncC > 0 && Network::IsServer())
		{
			m_wispSyncC -= dt;
			if (m_wispSyncC <= 0)
			{
				m_wispSyncC = 2000;
				SValueBuilder b;
				b.PushArray();
				b.PushInteger(m_unit.GetId());
				for (uint i = 0; i < m_wisps.length(); i++)
				{
					b.PushFloat(m_wisps[i].m_currAngle);
					b.PushFloat(m_wisps[i].m_currDistance);
				}
				b.PopArray();
				HWP::Net::Broadcast("hoh1.eye.sync", b.Build());
			}
		}

		CompositeActorBehavior::Update(dt);
	}

	void Destroyed() override
	{
		ClearWisps();
		CompositeActorBehavior::Destroyed();
	}
}

// A wisp of the watcher: circles its eye at "speed-rotate", between
// "min-distance" and "max-distance" (following its player's distance at
// "speed-distance"), and applies its effects to enemies of the eye it touches.
class HoH1BossEyeWisp : IPreRenderable
{
	UnitPtr m_unit;
	HoH1BossEye@ m_owner;
	Actor@ m_target;

	float m_minDistance;
	float m_maxDistance;
	float m_rotateMul;
	float m_distanceMul;
	float m_rotateFrom;
	float m_rotateTo;
	int m_rotateTime;
	int m_rotateTimeC;

	UnitScene@ m_sceneIntro;
	UnitScene@ m_sceneIdle;
	UnitScene@ m_sceneOutro;
	int m_introC;
	int m_outroC;

	EffectList@ m_effects;
	vec2 m_offset;

	float m_currAngle;
	float m_currDistance;
	float m_prevAngle;
	float m_prevDistance;

	HoH1BossEyeWisp(UnitPtr unit, SValue& params)
	{
		m_unit = unit;
		m_minDistance = GetParamFloat(unit, params, "min-distance");
		m_maxDistance = GetParamFloat(unit, params, "max-distance");
		m_rotateMul = GetParamFloat(unit, params, "speed-rotate", false, 1.0f);
		m_distanceMul = GetParamFloat(unit, params, "speed-distance", false, 1.0f);
		@m_sceneIntro = m_unit.GetUnitScene(GetParamString(unit, params, "scene-intro"));
		@m_sceneIdle = m_unit.GetUnitScene(GetParamString(unit, params, "scene-idle"));
		@m_sceneOutro = m_unit.GetUnitScene(GetParamString(unit, params, "scene-outro"));
		@m_effects = LoadEffects(unit, params);
		m_offset = GetParamVec2(unit, params, "offset", false);
	}

	void Set(float angle, HoH1BossEye@ owner)
	{
		@m_owner = owner;
		m_prevAngle = m_currAngle = angle;
		m_prevDistance = m_currDistance = 50.0f;
		m_unit.SetPosition(m_unit.GetPosition() + xyz(Offset(0)));
		m_unit.SetUnitScene(m_sceneIntro, true);
		m_introC = m_sceneIntro.Length();
		if (m_preRenderables.findByRef(this) < 0)
			m_preRenderables.insertLast(this);
	}

	void SetRotateSpeedTarget(float target, int overTime)
	{
		if (m_rotateTime > 0)
			m_rotateMul = m_rotateTo;
		m_rotateFrom = m_rotateMul;
		m_rotateTo = target;
		m_rotateTime = max(0, overTime);
		m_rotateTimeC = 0;
		if (m_rotateTime == 0)
			m_rotateMul = target;
	}

	void Disappear()
	{
		m_unit.SetUnitScene(m_sceneOutro, true);
		m_outroC = max(1, m_sceneOutro.Length());
	}

	vec2 Offset(int idt)
	{
		float t = idt / 33.0f;
		float angle = lerp(m_prevAngle, m_currAngle, t);
		float d = lerp(m_prevDistance, m_currDistance, t);
		return vec2(cos(angle), sin(angle)) * d + m_offset;
	}

	void Update(int dt)
	{
		if (m_introC > 0)
		{
			m_introC -= dt;
			if (m_introC <= 0)
				m_unit.SetUnitScene(m_sceneIdle, true);
		}

		if (m_rotateTime > 0)
		{
			m_rotateTimeC += dt;
			if (m_rotateTimeC >= m_rotateTime)
			{
				m_rotateMul = m_rotateTo;
				m_rotateTime = 0;
			}
			else
				m_rotateMul = lerp(m_rotateFrom, m_rotateTo, m_rotateTimeC / float(m_rotateTime));
		}

		m_prevAngle = m_currAngle;
		m_currAngle += dt / 500.0f * m_rotateMul;

		m_prevDistance = m_currDistance;
		if (m_target !is null && m_owner !is null)
		{
			float want = dist(m_target.m_unit.GetPosition(), m_owner.m_unit.GetPosition());
			m_currDistance = clamp(lerp(m_currDistance, want, 0.05f * m_distanceMul), m_minDistance, m_maxDistance);
		}

		if (m_outroC > 0)
		{
			m_outroC -= dt;
			if (m_outroC <= 0)
				m_unit.Destroy();
		}
	}

	void Collide(UnitPtr unit, vec2 pos, vec2 normal)
	{
		if (m_owner is null || m_outroC > 0)
			return;
		auto actor = cast<Actor>(unit.GetScriptBehavior());
		if (actor is null || actor.Team == m_owner.Team)
			return;
		ApplyEffects(m_effects, m_owner, unit, pos, normal, 1.0f, !Network::IsServer());
	}

	bool PreRender(int idt)
	{
		if (m_unit.IsDestroyed())
			return true;
		if (m_owner is null || m_owner.m_unit.IsDestroyed())
		{
			m_unit.Destroy();
			return true;
		}
		m_unit.SetPosition(m_owner.m_unit.GetPosition() + xyz(Offset(idt)));
		return false;
	}
}


namespace WorldScript
{
	bool IsHoH1BossEye(UnitPtr unit) { return cast<HoH1BossEye>(unit.GetScriptBehavior()) !is null; }

	[WorldScript color="100 255 100" icon="system/icons.png;96;32;32;32"]
	class BossEyeWispsAdd
	{
		[Editable validation=IsBossEye]
		UnitFeed Boss;

		[Editable]
		int Count;

		[Editable]
		UnitProducer@ WispUnit;

		bool IsBossEye(UnitPtr unit) { return IsHoH1BossEye(unit); }

		SValue@ ServerExecute()
		{
			auto units = Boss.FetchAll();
			for (uint i = 0; i < units.length(); i++)
			{
				auto boss = cast<HoH1BossEye>(units[i].GetScriptBehavior());
				if (boss !is null)
					boss.AddWisps(Count, WispUnit);
			}
			return null;
		}
	}

	[WorldScript color="100 255 100" icon="system/icons.png;96;32;32;32"]
	class BossEyeSuspend
	{
		[Editable validation=IsBossEye]
		UnitFeed Boss;

		[Editable]
		bool Suspend;

		bool IsBossEye(UnitPtr unit) { return IsHoH1BossEye(unit); }

		SValue@ ServerExecute()
		{
			auto units = Boss.FetchAll();
			for (uint i = 0; i < units.length(); i++)
			{
				auto boss = cast<HoH1BossEye>(units[i].GetScriptBehavior());
				if (boss is null)
					continue;
				if (Suspend)
					boss.Suspend();
				else
					boss.Unsuspend();
			}
			return null;
		}

		void ClientExecute(SValue@ val) { ServerExecute(); }
	}

	[WorldScript color="100 255 100" icon="system/icons.png;96;32;32;32"]
	class BossEyeWispsClear
	{
		[Editable validation=IsBossEye]
		UnitFeed Boss;

		bool IsBossEye(UnitPtr unit) { return IsHoH1BossEye(unit); }

		SValue@ ServerExecute()
		{
			auto units = Boss.FetchAll();
			for (uint i = 0; i < units.length(); i++)
			{
				auto boss = cast<HoH1BossEye>(units[i].GetScriptBehavior());
				if (boss !is null)
					boss.ClearWisps();
			}
			return null;
		}

		void ClientExecute(SValue@ val) { ServerExecute(); }
	}

	[WorldScript color="100 255 100" icon="system/icons.png;96;32;32;32"]
	class BossEyeWispsSpeed
	{
		[Editable validation=IsBossEye]
		UnitFeed Boss;

		[Editable]
		float NewMultiplier;

		[Editable]
		int OverTime;

		bool IsBossEye(UnitPtr unit) { return IsHoH1BossEye(unit); }

		SValue@ ServerExecute()
		{
			auto units = Boss.FetchAll();
			for (uint i = 0; i < units.length(); i++)
			{
				auto boss = cast<HoH1BossEye>(units[i].GetScriptBehavior());
				if (boss is null)
					continue;
				for (uint j = 0; j < boss.m_wisps.length(); j++)
					boss.m_wisps[j].SetRotateSpeedTarget(NewMultiplier, OverTime);
			}
			return null;
		}

		void ClientExecute(SValue@ val) { ServerExecute(); }
	}
}
