// Persistent summons: the Priest's Crusaders (pikemen, crossbowmen, boon
// pikemen) survive the loading screen between floors instead of dying with
// the old level. Optionally every saveable summon does (summons.all).
//
// How: while in a run, the local player's tracked summons are snapshotted
// twice a second with the same SaveUnit() data the game uses for save games.
// When the next floor spawns the player (GameModeSpawnPlayer), the snapshot
// is produced again next to the player, exactly like Player's constructor
// does for summons loaded from a save: the host produces directly, a client
// asks the host with the vanilla SpawnPlayerSummon message. The vanilla cap
// (max-summoned) is still enforced by Player::Update, so nothing can exceed
// the skill's limit.
namespace HWP
{
	namespace Summons
	{
		const int TICK_MS = 500;
		array<string> UNITS = {
			"players/priest/units/crusader_pikeman.unit",
			"players/priest/units/crusader_crossbowman.unit",
			"players/priest/units/crusader_pikeman_boon.unit"
		};

		bool g_enabled = true;
		bool g_all = false;

		class Saved
		{
			string prod;
			SValue@ data;
		}

		array<Saved@> g_saved;    // live tracked summons of the local player, refreshed every tick
		bool g_restored = false;  // this level already ran the restore (snapshotting may start)
		int g_lastRestored = 0;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("summons.enabled", true);
			g_all = HWP::Settings::GetBool("summons.all", false);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("summons.") == 0)
				RefreshSettings();
		}

		bool Tracked(UnitProducer@ prod)
		{
			if (prod is null)
				return false;
			if (g_all)
				return true;
			return UNITS.find(prod.GetResourceName()) >= 0;
		}

		bool IsLive(IOwnedUnit@ owned)
		{
			if (owned is null)
				return false;
			auto u = owned.GetUnit();
			if (!u.IsValid() || u.IsDestroyed())
				return false;
			auto actor = cast<Actor>(u.GetScriptBehavior());
			return actor is null || !actor.IsDead();
		}

		// Refresh the snapshot from the local player's current summons.
		void Snapshot(PlayerRecord@ rec)
		{
			array<Saved@> fresh;
			for (uint i = 0; i < rec.summons.length(); i++)
			{
				auto s = rec.summons[i];
				if (!Tracked(s.m_prod))
					continue;
				for (uint j = 0; j < s.m_units.length(); j++)
				{
					if (!IsLive(s.m_units[j]))
						continue;
					if (j < s.m_save.length() && !s.m_save[j])
						continue;
					SValueBuilder sb;
					sb.PushDictionary();
					s.m_units[j].SaveUnit(sb);
					Saved sv;
					sv.prod = s.m_prod.GetResourceName();
					@sv.data = sb.Build();
					fresh.insertLast(sv);
				}
			}
			g_saved = fresh;
		}

		int LiveCount(PlayerRecord@ rec, const string &in prodName)
		{
			int n = 0;
			for (uint i = 0; i < rec.summons.length(); i++)
			{
				auto s = rec.summons[i];
				if (s.m_prod is null || s.m_prod.GetResourceName() != prodName)
					continue;
				for (uint j = 0; j < s.m_units.length(); j++)
					if (IsLive(s.m_units[j]))
						n++;
			}
			return n;
		}

		// Produce the snapshot next to the freshly spawned local player.
		void Restore(PlayerRecord@ rec)
		{
			g_restored = true;
			g_lastRestored = 0;
			if (g_inTown || !g_enabled || rec is null || !rec.local || rec.actor is null)
			{
				g_saved.removeRange(0, g_saved.length());
				return;
			}
			if (g_saved.length() == 0)
				return;

			dictionary spawned; // prod name -> count produced this restore
			vec2 pos = xy(rec.actor.m_unit.GetPosition());
			for (uint i = 0; i < g_saved.length(); i++)
			{
				auto sv = g_saved[i];
				auto prod = Resources::GetUnitProducer(sv.prod);
				if (prod is null || sv.data is null)
					continue;

				// If the game already restored some of this kind (save game load), don't double up.
				int already = 0;
				if (spawned.exists(sv.prod))
					spawned.get(sv.prod, already);
				if (already == 0 && LiveCount(rec, sv.prod) > 0)
				{
					spawned.set(sv.prod, LiveCount(rec, sv.prod));
					continue;
				}
				spawned.set(sv.prod, already + 1);

				vec2 p = pos + randdir() * (12.0f + randf() * 16.0f);
				bool remote = (!Network::IsServer() && IsNetsyncedExistance(prod.GetNetSyncMode()));
				if (remote)
					(Network::Message("SpawnPlayerSummon") << prod.GetResourceHash() << p << sv.data.Copy()).SendToHost();
				else
				{
					auto unit = prod.Produce(g_scene, xyz(p));
					auto owned = cast<IOwnedUnit>(unit.GetScriptBehavior());
					if (owned !is null)
						owned.LoadUnit(sv.data);
				}
				g_lastRestored++;
			}
			if (g_lastRestored > 0)
				HWP::Log("summons", "restored " + g_lastRestored + " summon(s) on the new floor");
			g_saved.removeRange(0, g_saved.length());
		}

		void Tick()
		{
			if (!g_enabled || g_inTown || !g_restored)
				return;
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.actor is null)
				return;
			Snapshot(rec);
		}

		void CmdSummons(array<string>@ args)
		{
			HWP::Commands::Reply(Resources::GetString(".hwp.summons.status", {
				{ "state", g_enabled ? "on" : "off" }, { "all", g_all ? "on" : "off" },
				{ "saved", int(g_saved.length()) }, { "last", g_lastRestored } }));
		}

		void SelfCheck()
		{
			int ok = 0;
			for (uint i = 0; i < UNITS.length(); i++)
			{
				if (Resources::GetUnitProducer(UNITS[i]) !is null)
					ok++;
				else
					HWP::LogError("summons", "missing unit " + UNITS[i]);
			}
			HWP::Log("summons", "self-check done: " + ok + "/" + UNITS.length() + " tracked units");
		}
	}
}

namespace HWPSummons
{
	[Hook]
	void GameModeSpawnPlayer(AGameplayGameMode@ gm, PlayerRecord@ rec)
	{
		if (rec !is null && rec.local && !HWP::Summons::g_restored)
			HWP::Summons::Restore(rec);
	}
}

namespace Modules
{
	class HWPSummonsModule : Module
	{
		int m_timer = 0;

		HWPSummonsModule()
		{
			super("hwp-summons");
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Summons::OnSettingChanged));
			HWP::Commands::Register("summons", " persistent summons status", HWP::Commands::Handler(HWP::Summons::CmdSummons));
			HWP::Summons::SelfCheck();
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::Settings::Sync("summons.");
			HWP::Summons::RefreshSettings();
			HWP::Summons::g_restored = false; // the next GameModeSpawnPlayer of the local player restores
			m_timer = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused)
				return;
			m_timer += ms;
			if (m_timer < HWP::Summons::TICK_MS)
				return;
			m_timer = 0;
			HWP::Summons::Tick();
		}
	}
}
