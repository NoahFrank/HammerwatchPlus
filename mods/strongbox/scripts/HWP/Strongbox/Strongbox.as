// Strongboxes (Path of Exile style). The host places one per level with
// strongbox.chance, at the position of a random enemy far from the party.
// Using it arms it: a pack sampled from the enemies of that level (plus a
// chance of an elite) spawns around it and the box only opens, with the
// hwp_strongbox loot table, once every pack member is dead. The unit is
// netsynced, so the host's spawn reaches clients; the armed/cleared state is
// broadcast so clients show the right use icon.
namespace HWP
{
	namespace Strongbox
	{
		const string UNIT = "doodads/hwp/strongbox.unit";
		const string LOOT = "hwp_strongbox";
		const string STATE = "strongbox.state"; // host -> all: { unit, state }

		bool g_enabled = true;
		int g_chance = 40;        // % of levels that get a strongbox
		int g_packBase = 4;
		int g_packPerPlayer = 2;
		int g_eliteChance = 50;   // % chance the pack has an elite
		int g_sampleRadius = 1200;
		int g_placed = 0;
		int g_cleared = 0;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("strongbox.enabled", true);
			g_chance = clamp(HWP::Settings::GetInt("strongbox.chance", 40), 0, 100);
			g_packBase = clamp(HWP::Settings::GetInt("strongbox.pack", 4), 1, 20);
			g_packPerPlayer = clamp(HWP::Settings::GetInt("strongbox.pack_per_player", 2), 0, 10);
			g_eliteChance = clamp(HWP::Settings::GetInt("strongbox.elite_chance", 50), 0, 100);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("strongbox.") == 0)
				RefreshSettings();
		}

		// pos is an enemy's position; the box goes on a free spot next to it.
		UnitPtr Spawn(vec3 pos)
		{
			auto prod = Resources::GetUnitProducer(UNIT);
			if (prod is null)
			{
				HWP::LogError("strongbox", "missing " + UNIT);
				return UnitPtr();
			}
			vec3 at;
			if (HWP::Spawner::FreeSpot(pos, 40.0f, at))
				pos = at;
			auto u = prod.Produce(g_scene, pos);
			if (u.IsValid())
			{
				g_placed++;
				HWP::Log("strongbox", "placed a strongbox at " + int(pos.x) + "," + int(pos.y));
			}
			return u;
		}

		void SendState(UnitPtr unit, int state)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("unit", int(unit.GetId()));
			b.PushInteger("state", state);
			b.PopDictionary();
			HWP::Net::Broadcast(STATE, b.Build());
		}

		void OnState(SValue@ data)
		{
			if (Network::IsServer())
				return; // the host set it itself
			UnitPtr u = g_scene.GetUnit(uint(HWP::SV::Int(data, "unit", 0)));
			if (!u.IsValid())
				return;
			auto box = cast<HWPStrongbox>(u.GetScriptBehavior());
			if (box !is null)
				box.SetRemoteState(HWP::SV::Int(data, "state", 0));
		}

		void CmdStrongbox(array<string>@ args)
		{
			if (args.length() >= 1 && args[0] == "here")
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.strongbox.host_only"));
					return;
				}
				auto rec = GetLocalPlayerRecord();
				if (rec is null || rec.actor is null || g_inTown)
					return;
				Spawn(rec.actor.m_unit.GetPosition() + vec3(48, 0, 0));
				return;
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.strongbox.status", {
				{ "state", g_enabled ? "on" : "off" }, { "chance", g_chance },
				{ "pack", g_packBase }, { "per", g_packPerPlayer }, { "placed", g_placed }, { "cleared", g_cleared } }));
		}

		void SelfCheck()
		{
			HWP::CheckUnits("strongbox", { UNIT });
			HWP::Log("strongbox", "self-check done");
		}
	}
}

class HWPStrongbox : Chest
{
	int m_state = 0;        // 0 closed, 1 armed (pack alive), 2 cleared / opened, 3 expired (pack never died)
	array<uint> m_pack;
	int m_timer = 0;
	int m_armedFor = 0;
	uint8 m_openerPeer = 255;

	HWPStrongbox(UnitPtr unit, SValue& params)
	{
		super(unit, params);
		unit.SetMultiplyColor(vec4(1.0f, 0.62f, 0.35f, 1.0f));
	}

	void SetRemoteState(int state) { m_state = state; }

	bool CanUse(PlayerBase@ player) override
	{
		if (m_state != 0)
			return false;
		return Chest::CanUse(player);
	}

	UsableIcon GetIcon(Player@ player) override
	{
		return m_state == 0 ? UsableIcon::Generic : UsableIcon::Cross;
	}

	// Clients: the use reaches the host through the vanilla NetUse path; locally
	// only the sound plays. Host: arm the box.
	void Use(PlayerBase@ player) override
	{
		if (m_state != 0 || !m_unit.IsValid() || m_unit.IsDestroyed())
			return;
		if (!Network::IsServer())
		{
			PlaySound3D(m_openSnd, m_unit.GetPosition());
			return;
		}
		Arm(player);
	}

	void Arm(PlayerBase@ player)
	{
		vec3 pos = m_unit.GetPosition();
		auto prods = HWP::Spawner::SampleProducers(xy(pos), HWP::Strongbox::g_sampleRadius, 4);
		if (prods.length() == 0)
		{
			HWP::Log("strongbox", "no enemies left to sample a pack from; opening");
			m_state = 2;
			Chest::Use(player);
			return;
		}
		int count = HWP::Strongbox::g_packBase + HWP::Strongbox::g_packPerPlayer * HWP::Spawner::PlayerCount();
		m_pack = HWP::Spawner::SpawnPack(prods, pos, count, 70.0f, true);
		if (m_pack.length() == 0)
		{
			HWP::Log("strongbox", "no free spot for a pack; opening");
			m_state = 2;
			Chest::Use(player);
			return;
		}
		if (randi(100) < HWP::Strongbox::g_eliteChance)
		{
			auto elite = HWP::Spawner::EliteVariant(prods[randi(prods.length())]);
			if (elite !is null)
			{
				array<UnitProducer@> one = { elite };
				auto ids = HWP::Spawner::SpawnPack(one, pos, 1, 40.0f, true);
				for (uint i = 0; i < ids.length(); i++)
					m_pack.insertLast(ids[i]);
			}
		}
		m_state = 1;
		m_armedFor = 0;
		m_openerPeer = player.m_record !is null ? player.m_record.peer : 255;
		HWP::Strongbox::SendState(m_unit, 1);
		PlaySound3D(m_openSnd, pos);
		HWP::Log("strongbox", "armed: " + m_pack.length() + " enemies from " + prods.length() + " kind(s)");
	}

	void Update(int dt)
	{
		if (!Network::IsServer() || m_state != 1)
			return;
		m_timer += dt;
		if (m_timer < 500)
			return;
		m_armedFor += m_timer;
		m_timer = 0;
		if (!HWP::Spawner::AllDead(m_pack))
		{
			if (m_armedFor < 180000)
				return;
			// The pack was never killed (kited, stuck, left behind): the box
			// closes for good and pays nothing.
			HWP::Log("strongbox", "pack still alive after 3 min; the box seals itself");
			m_state = 3;
			HWP::Strongbox::SendState(m_unit, 3);
			m_unit.Destroy();
			return;
		}
		m_state = 2;
		HWP::Strongbox::g_cleared++;
		HWP::Strongbox::SendState(m_unit, 2);
		PlayerBase@ opener;
		auto rec = GetPlayerRecordByPeer(m_openerPeer);
		if (rec !is null && rec.actor !is null)
			@opener = cast<PlayerBase>(rec.actor);
		if (opener is null)
			@opener = HWP::Spawner::NearestPlayer(m_unit.GetPosition());
		if (opener !is null)
			Chest::Use(opener); // destroys the box and spawns the loot on the host
		else
			m_unit.Destroy();
	}
}

namespace Modules
{
	class HWPStrongboxModule : Module, HWP::ModuleStart
	{
		HWP::Spawner::LevelPlacer m_placer;

		HWPStrongboxModule()
		{
			super("hwp-strongbox");
			HWP::Net::OnEvent(HWP::Strongbox::STATE, HWP::Net::EventHandler(HWP::Strongbox::OnState));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Strongbox::OnSettingChanged));
			HWP::Commands::Register("strongbox", " strongbox status; 'here' places one next to you (host)", HWP::Commands::Handler(HWP::Strongbox::CmdStrongbox));
			HWP::Strongbox::SelfCheck();
		}

		void Start(StartMode sMode)
		{
			HWP::Settings::Sync("strongbox.");
			HWP::Strongbox::RefreshSettings();
			m_placer.Reset();
		}

		// Host, once per level, a little after the enemies exist.
		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (!m_placer.Tick(ms, paused, 2500, HWP::Strongbox::g_enabled))
				return;
			if (randi(100) >= HWP::Strongbox::g_chance)
				return;
			vec3 pos;
			if (HWP::Spawner::PickFarSpot(700.0f, pos))
				HWP::Strongbox::Spawn(pos);
		}
	}
}
