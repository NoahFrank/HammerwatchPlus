// Abyss cracks (Path of Exile's Abyss, scaled down). The host places one per
// level with abyss.chance at the position of a random enemy far from the
// party. When a player comes close the crack "spreads": three waves of the
// level's own enemies erupt along a line, each a little further away, the last
// one with an elite. Clearing the final wave pays the hwp_abyss_reward table
// and closes the crack. Units are netsynced (host spawns, clients receive);
// wave announcements are broadcast as chat lines.
namespace HWP
{
	namespace Abyss
	{
		const string UNIT = "doodads/hwp/abyss_crack.unit";
		const string FISSURE_UNIT = "doodads/hwp/abyss_fissure.unit";
		const string LOOT = "hwp_abyss_reward";
		const string WAVE = "abyss.wave"; // host -> all: { n, total }
		const string DONE = "abyss.done"; // host -> all

		bool g_enabled = true;
		int g_chance = 30;         // % of levels that get a crack
		int g_waves = 3;
		int g_waveBase = 3;
		int g_wavePerPlayer = 1;
		int g_trigger = 130;       // px: a player this close opens the crack
		int g_placed = 0;
		int g_cleared = 0;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("abyss.enabled", true);
			g_chance = clamp(HWP::Settings::GetInt("abyss.chance", 30), 0, 100);
			g_waves = clamp(HWP::Settings::GetInt("abyss.waves", 3), 1, 6);
			g_waveBase = clamp(HWP::Settings::GetInt("abyss.wave_base", 3), 1, 20);
			g_wavePerPlayer = clamp(HWP::Settings::GetInt("abyss.wave_per_player", 1), 0, 10);
			g_trigger = clamp(HWP::Settings::GetInt("abyss.trigger", 130), 40, 600);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("abyss.") == 0)
				RefreshSettings();
		}

		UnitPtr Spawn(const string &in unitPath, vec3 pos)
		{
			auto prod = Resources::GetUnitProducer(unitPath);
			if (prod is null)
			{
				HWP::LogError("abyss", "missing " + unitPath);
				return UnitPtr();
			}
			return prod.Produce(g_scene, pos);
		}

		// pos is an enemy's position; the crack goes on a free spot next to it.
		void Place(vec3 pos)
		{
			vec3 at;
			if (HWP::Spawner::FreeSpot(pos, 40.0f, at))
				pos = at;
			auto u = Spawn(UNIT, pos);
			if (!u.IsValid())
				return;
			g_placed++;
			HWP::Log("abyss", "placed a crack at " + int(pos.x) + "," + int(pos.y));
		}

		void OnWave(SValue@ data)
		{
			HWP::Commands::Reply(Resources::GetString(".hwp.abyss.wave", {
				{ "n", HWP::SV::Int(data, "n", 1) }, { "total", HWP::SV::Int(data, "total", g_waves) } }));
		}

		void OnDone(SValue@ data)
		{
			HWP::Commands::Reply(Resources::GetString(".hwp.abyss.done"));
		}

		void CmdAbyss(array<string>@ args)
		{
			if (args.length() >= 1 && args[0] == "here")
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.abyss.host_only"));
					return;
				}
				auto rec = GetLocalPlayerRecord();
				if (rec is null || rec.actor is null || g_inTown)
					return;
				Place(rec.actor.m_unit.GetPosition() + vec3(0, 60, 0));
				return;
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.abyss.status", {
				{ "state", g_enabled ? "on" : "off" }, { "chance", g_chance }, { "waves", g_waves },
				{ "base", g_waveBase }, { "per", g_wavePerPlayer }, { "placed", g_placed }, { "cleared", g_cleared } }));
		}

		void SelfCheck()
		{
			HWP::CheckUnits("abyss", { UNIT, FISSURE_UNIT });
			HWP::Log("abyss", "self-check done");
		}
	}
}

class HWPAbyssCrack
{
	UnitPtr m_unit;
	int m_state = 0;         // 0 dormant, 1 wave alive, 2 pause before the next wave, 3 finished
	int m_wave = 0;
	int m_timer = 0;
	int m_elapsed = 0;
	vec2 m_dir;
	array<uint> m_pack;
	array<UnitPtr> m_fissures;
	array<UnitProducer@> m_prods;

	HWPAbyssCrack(UnitPtr unit, SValue& params)
	{
		m_unit = unit;
		m_dir = randdir();
	}

	void StartWave(int n)
	{
		m_wave = n;
		vec3 pos = m_unit.GetPosition();
		vec2 off = m_dir * float(70 * (n - 1));
		vec3 at = pos + vec3(off.x, off.y, 0);
		if (n > 1)
		{
			auto f = HWP::Abyss::Spawn(HWP::Abyss::FISSURE_UNIT, at);
			if (f.IsValid())
				m_fissures.insertLast(f);
		}
		int count = HWP::Abyss::g_waveBase + HWP::Abyss::g_wavePerPlayer * HWP::Spawner::PlayerCount() + (n - 1);
		m_pack = HWP::Spawner::SpawnPack(m_prods, at, count, 60.0f, true);
		if (m_pack.length() == 0)
		{
			HWP::Log("abyss", "no free spot for wave " + n + "; the crack closes");
			Finish(false);
			return;
		}
		if (n >= HWP::Abyss::g_waves)
		{
			auto elite = HWP::Spawner::EliteVariant(m_prods[randi(m_prods.length())]);
			array<UnitProducer@> extra;
			int extraCount = 1;
			if (elite !is null)
				extra.insertLast(elite);
			else
			{
				extra = m_prods;
				extraCount = 2;
			}
			auto ids = HWP::Spawner::SpawnPack(extra, at, extraCount, 30.0f, true);
			for (uint i = 0; i < ids.length(); i++)
				m_pack.insertLast(ids[i]);
		}
		m_state = 1;
		m_elapsed = 0;
		SValueBuilder b;
		b.PushDictionary();
		b.PushInteger("n", n);
		b.PushInteger("total", HWP::Abyss::g_waves);
		b.PopDictionary();
		HWP::Net::Broadcast(HWP::Abyss::WAVE, b.Build());
		HWP::Log("abyss", "wave " + n + "/" + HWP::Abyss::g_waves + ": " + m_pack.length() + " enemies");
	}

	void Finish(bool reward)
	{
		m_state = 3;
		vec3 pos = m_unit.GetPosition();
		if (reward)
		{
			HWP::Abyss::g_cleared++;
			auto table = Item::GetLootTable(HWP::Abyss::LOOT);
			auto looter = HWP::Spawner::NearestPlayer(pos);
			if (table is null)
				HWP::LogError("abyss", "missing loot table " + HWP::Abyss::LOOT);
			else if (looter !is null)
				table.SpawnLoot(looter, pos);
			HWP::Net::Broadcast(HWP::Abyss::DONE);
		}
		for (uint i = 0; i < m_fissures.length(); i++)
			if (m_fissures[i].IsValid())
				m_fissures[i].Destroy();
		m_fissures.removeRange(0, m_fissures.length());
		if (m_unit.IsValid())
			m_unit.Destroy();
	}

	void Update(int dt)
	{
		if (!Network::IsServer() || m_state == 3 || !m_unit.IsValid() || m_unit.IsDestroyed())
			return;
		m_timer += dt;
		if (m_timer < 400)
			return;
		int step = m_timer;
		m_timer = 0;

		if (m_state == 0)
		{
			float d = HWP::Spawner::DistToNearestPlayer(m_unit.GetPosition());
			if (d < 0 || d > float(HWP::Abyss::g_trigger))
				return;
			m_prods = HWP::Spawner::SampleProducers(xy(m_unit.GetPosition()), 1600, 5);
			if (m_prods.length() == 0)
			{
				HWP::Log("abyss", "no enemies to sample from; the crack closes");
				Finish(false);
				return;
			}
			StartWave(1);
			return;
		}
		if (m_state == 2)
		{
			m_elapsed += step;
			if (m_elapsed >= 1500)
				StartWave(m_wave + 1);
			return;
		}
		// a wave is alive
		m_elapsed += step;
		if (!HWP::Spawner::AllDead(m_pack))
		{
			if (m_elapsed < 120000)
				return;
			// The wave was never killed: the crack closes without a reward.
			HWP::Log("abyss", "wave " + m_wave + " still alive after 2 min; the crack closes");
			Finish(false);
			return;
		}
		if (m_wave >= HWP::Abyss::g_waves)
		{
			Finish(true);
			return;
		}
		m_state = 2;
		m_elapsed = 0;
	}
}

namespace Modules
{
	class HWPAbyssModule : Module, HWP::ModuleStart
	{
		HWP::Spawner::LevelPlacer m_placer;

		HWPAbyssModule()
		{
			super("hwp-abyss");
			HWP::Net::OnEvent(HWP::Abyss::WAVE, HWP::Net::EventHandler(HWP::Abyss::OnWave));
			HWP::Net::OnEvent(HWP::Abyss::DONE, HWP::Net::EventHandler(HWP::Abyss::OnDone));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Abyss::OnSettingChanged));
			HWP::Commands::Register("abyss", " abyss crack status; 'here' opens one next to you (host)", HWP::Commands::Handler(HWP::Abyss::CmdAbyss));
			HWP::Abyss::SelfCheck();
		}

		void Start(StartMode sMode)
		{
			HWP::Settings::Sync("abyss.");
			HWP::Abyss::RefreshSettings();
			m_placer.Reset();
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (!m_placer.Tick(ms, paused, 3000, HWP::Abyss::g_enabled))
				return;
			if (randi(100) >= HWP::Abyss::g_chance)
				return;
			vec3 pos;
			if (HWP::Spawner::PickFarSpot(800.0f, pos))
				HWP::Abyss::Place(pos);
		}
	}
}
