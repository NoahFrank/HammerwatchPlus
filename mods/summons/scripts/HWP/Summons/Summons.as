// Persistent summons: the Priest's Crusaders (pikemen, crossbowmen, boon
// pikemen) survive the loading screen between floors instead of dying with
// the old level. Optionally every saveable summon does (summons.all).
//
// How: while in a run, the local player's tracked summons are snapshotted
// twice a second with the same SaveUnit() data the game uses for save games,
// into the record's HWP bag (summons.saved): script globals reset with every
// level, the record and its bag do not.
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

		const string KEY_SAVED = "summons.saved"; // { n, p<i>: unit path, d<i>: SaveUnit data }
		int g_savedCount = 0;     // summons in the last snapshot (status line)
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
			SValueBuilder sb;
			sb.PushDictionary();
			int n = 0;
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
					sb.PushString("p" + n, s.m_prod.GetResourceName());
					sb.PushDictionary("d" + n);
					s.m_units[j].SaveUnit(sb);
					sb.PopDictionary();
					n++;
				}
			}
			sb.PushInteger("n", n);
			sb.PopDictionary();
			auto snap = sb.Build();
			HWP::SaveData::Player(rec).Set(KEY_SAVED, snap); // the bag keeps a copy
			snap.Delete();
			g_savedCount = n;
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
			if (rec is null)
				return;
			auto bag = HWP::SaveData::Player(rec);
			if (g_inTown || !g_enabled || !rec.local || rec.actor is null)
			{
				bag.Remove(KEY_SAVED);
				return;
			}
			auto saved = bag.Get(KEY_SAVED);
			int count = HWP::SV::Int(saved, "n", 0);
			if (count <= 0)
				return;

			dictionary spawned; // prod name -> count produced this restore
			vec2 pos = xy(rec.actor.m_unit.GetPosition());
			for (int i = 0; i < count; i++)
			{
				string prodName = HWP::SV::Str(saved, "p" + i);
				auto data = saved.GetDictionaryEntry("d" + i);
				auto prod = prodName.isEmpty() ? null : Resources::GetUnitProducer(prodName);
				if (prod is null || data is null)
					continue;

				// If the game already restored some of this kind (save game load), don't double up.
				int already = 0;
				if (spawned.exists(prodName))
					spawned.get(prodName, already);
				if (already == 0 && LiveCount(rec, prodName) > 0)
				{
					spawned.set(prodName, LiveCount(rec, prodName));
					continue;
				}
				spawned.set(prodName, already + 1);

				vec2 p = pos + randdir() * (12.0f + randf() * 16.0f);
				bool remote = (!Network::IsServer() && IsNetsyncedExistance(prod.GetNetSyncMode()));
				if (remote)
					(Network::Message("SpawnPlayerSummon") << prod.GetResourceHash() << p << data.Copy()).SendToHost();
				else
				{
					auto unit = prod.Produce(g_scene, xyz(p));
					auto owned = cast<IOwnedUnit>(unit.GetScriptBehavior());
					if (owned !is null)
						owned.LoadUnit(data);
				}
				g_lastRestored++;
			}
			if (g_lastRestored > 0)
				HWP::Log("summons", "restored " + g_lastRestored + " summon(s) on the new floor");
			bag.Remove(KEY_SAVED); // after the loop: `data` points into it
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
				{ "saved", g_savedCount }, { "last", g_lastRestored } }));
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
	class HWPSummonsModule : Module, HWP::ModuleStart
	{
		int m_timer = 0;

		HWPSummonsModule()
		{
			super("hwp-summons");
			// modules are rebuilt per level before anyone spawns; the host spawns
			// its local players in PostStart, before ModuleStart::Start runs
			HWP::Summons::g_restored = false; // the next GameModeSpawnPlayer of the local player restores
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Summons::OnSettingChanged));
			HWP::Commands::Register("summons", " persistent summons status", HWP::Commands::Handler(HWP::Summons::CmdSummons));
			HWP::Summons::SelfCheck();
		}

		void Start(StartMode sMode)
		{
			HWP::Settings::Sync("summons.");
			HWP::Summons::RefreshSettings();
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
