// Last-run statistics for the whole party.
//
// The snapshot is taken in the module constructor: modules are rebuilt inside
// the town game mode's constructor, before PostStart shows the MissionEndMenu
// whose constructor resets PlayerRecord.statsRun. (Module::Load is no good: the
// engine skips it whenever the level starts without a save.) Each machine
// snapshots its own player, keeps it in the player record (HWP data bag, key
// "laststats.mine") and reports it to the host, which rebroadcasts every
// snapshot it knows; the notice board in town pages through them.
namespace HWP
{
	namespace LastStats
	{
		const string KEY_MINE = "laststats.mine";
		const string REPORT = "laststats.report"; // client -> host: one snapshot
		const string SYNC = "laststats.sync";     // host -> all: every snapshot
		const string BOARD_UNIT = "doodads/hwp/laststats_board.unit";

		array<SValue@> g_party; // newest first, one per player name

		string StateName(int state)
		{
			if (state == int(MissionManager::MissionState::Succeeded))
				return Resources::GetString(".hwp.laststats.state.succeeded");
			if (state == int(MissionManager::MissionState::Failed))
				return Resources::GetString(".hwp.laststats.state.failed");
			if (state == int(MissionManager::MissionState::Aborted))
				return Resources::GetString(".hwp.laststats.state.aborted");
			return Resources::GetString(".hwp.laststats.state.unknown");
		}

		bool IsFinishedState(MissionManager::MissionState st)
		{
			return st == MissionManager::MissionState::Succeeded
				|| st == MissionManager::MissionState::Failed
				|| st == MissionManager::MissionState::Aborted;
		}

		// ---- snapshot ---------------------------------------------------------

		// Same selection as MissionEndMenu: every visible, categorised stat that
		// is not zero. Lines are stored pre-formatted so the receiver needs no
		// StatDef lookup. Per-skill damage lines need the player actor, which
		// does not exist yet at Load time, so they are not part of the snapshot.
		SValue@ Snapshot(PlayerRecord@ plr)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("player", plr.GetName());
			b.PushInteger("peer", plr.peer);

			string missionName = "?";
			auto def = MissionDef::Get(plr.currMission);
			if (def !is null)
				missionName = def.m_name;
			if (missionName.findFirst(".") == 0)
				missionName = Resources::GetString(missionName);
			b.PushString("mission", missionName);
			b.PushInteger("state", int(plr.currMissionState));

			int n = 0;
			b.PushArray("lines");
			for (uint i = 0; i < Stats::StatDef::Instances.length(); i++)
			{
				auto stat = Stats::StatDef::Instances[i];
				if (stat.m_hidden || stat.m_category.isEmpty())
					continue;
				auto val = plr.statsRun.GetStatCurr(stat.m_idHash);
				if (val == 0)
					continue;

				b.PushDictionary();
				b.PushString("cat", stat.m_category);
				b.PushString("title", Resources::GetString(stat.m_name));
				b.PushString("text", stat.GetStatFormatted(val));
				b.PopDictionary();
				n++;
			}
			b.PopArray();
			b.PushInteger("count", n);
			b.PopDictionary();
			return b.Build();
		}

		SValue@ Mine()
		{
			return HWP::SaveData::Local().Get(KEY_MINE);
		}

		// ---- party list -------------------------------------------------------

		void Remember(SValue@ snap)
		{
			if (snap is null)
				return;
			auto name = HWP::SV::Str(snap, "player");
			for (int i = int(g_party.length()) - 1; i >= 0; i--)
			{
				if (HWP::SV::Str(g_party[i], "player") == name)
					g_party.removeAt(i);
			}
			g_party.insertAt(0, snap.Copy()); // snap may be a received message, freed after the handler
		}

		SValue@ PackParty()
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("count", int(g_party.length()));
			for (uint i = 0; i < g_party.length(); i++)
				b.PushSimple("" + i, g_party[i].Copy());
			b.PopDictionary();
			return b.Build();
		}

		// host: a peer reported its snapshot
		void OnReport(uint8 peer, SValue@ data)
		{
			if (data is null)
				return;
			Remember(data);
			HWP::Log("laststats", "got snapshot of " + HWP::SV::Str(data, "player") + " from peer " + peer
				+ " (" + HWP::SV::Int(data, "count") + " stats); party size " + g_party.length());
			HWP::Net::Broadcast(SYNC, PackParty());
		}

		// everyone: the host's full list
		void OnSync(SValue@ data)
		{
			int count = HWP::SV::Int(data, "count");
			array<SValue@> list;
			for (int i = 0; i < count; i++)
			{
				auto snap = HWP::SV::Field(data, "" + i);
				if (snap !is null)
					list.insertLast(snap.Copy());
			}
			g_party = list;
		}

		// ---- notice board -----------------------------------------------------

		// Next to the fountain of town_square_4 (prefab at grid -38,8 -> world
		// -608,128; the well sits at local offset 104,16). Overridable with
		// "hwp set laststats.board_x <n>" / board_y while the spot is tuned.
		vec3 BoardPos()
		{
			return vec3(float(HWP::Settings::GetInt("laststats.board_x", -440)),
				float(HWP::Settings::GetInt("laststats.board_y", 110)), 0.0f);
		}

		void SpawnBoard()
		{
			auto prod = Resources::GetUnitProducer(BOARD_UNIT);
			if (prod is null)
			{
				HWP::LogError("laststats", "missing " + BOARD_UNIT);
				return;
			}
			auto pos = BoardPos();
			prod.Produce(g_scene, pos);
			HWP::Log("laststats", "spawned the notice board at " + pos.x + "," + pos.y);
		}

		void CmdLastStats(array<string>@ args)
		{
			auto mine = Mine();
			if (mine is null)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.laststats.empty"));
				return;
			}
			HWP::Commands::Reply(HWP::SV::Str(mine, "mission") + " - " + StateName(HWP::SV::Int(mine, "state"))
				+ ": " + HWP::SV::Int(mine, "count") + " stats; party snapshots known: " + g_party.length());
		}
	}
}

namespace Modules
{
	class HWPLastStatsModule : Module, HWP::ModuleStart
	{
		int m_reportDelay = -1;
		// false: the town starts with a null save, so Load never runs there and the
		// board must spawn from the constructor's state (docs/RE_NOTES.md, mod lifecycle)
		bool m_boardDone = false;
		int m_boardDelay = 0;

		HWPLastStatsModule()
		{
			super("hwp-laststats");
			HWP::Net::OnRequest(HWP::LastStats::REPORT, HWP::Net::RequestHandler(HWP::LastStats::OnReport));
			HWP::Net::OnEvent(HWP::LastStats::SYNC, HWP::Net::EventHandler(HWP::LastStats::OnSync));
			HWP::Commands::Register("laststats", " show what the notice board knows", HWP::Commands::Handler(HWP::LastStats::CmdLastStats));
			TakeSnapshot();
		}

		void Start(StartMode sMode)
		{
			m_boardDone = false;
			m_boardDelay = 0;
			m_reportDelay = 2000; // (re)send whatever we have so late joiners get it too
		}

		// Modules are rebuilt for every level inside the game mode's
		// constructor, ahead of Start/PostStart. The player records outlive the
		// level, and only the town after a run sees a finished mission state
		// (the MissionEndMenu clears it), so this is the one point that still
		// sees the run's stats.
		void TakeSnapshot()
		{
			auto plr = GetLocalPlayerRecord();
			if (plr is null || plr.statsRun is null)
				return;
			if (!HWP::LastStats::IsFinishedState(plr.currMissionState))
				return;

			auto snap = HWP::LastStats::Snapshot(plr);
			HWP::SaveData::Local().Set(HWP::LastStats::KEY_MINE, snap);
			HWP::LastStats::Remember(snap);
			snap.Delete(); // the bag and the party list keep copies
			HWP::Log("laststats", "snapshot of " + plr.GetName() + ": " + HWP::SV::Int(snap, "count")
				+ " stats, " + HWP::LastStats::StateName(int(plr.currMissionState)));
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (m_reportDelay >= 0)
			{
				m_reportDelay -= ms;
				if (m_reportDelay < 0)
				{
					m_reportDelay = -1;
					auto mine = HWP::LastStats::Mine();
					if (mine !is null)
						HWP::Net::Request(HWP::LastStats::REPORT, mine.Copy()); // the bag keeps its own
				}
			}

			if (!m_boardDone)
			{
				m_boardDelay += ms;
				if (m_boardDelay >= 500)
				{
					m_boardDone = true;
					if (g_inTown && Network::IsServer())
						HWP::LastStats::SpawnBoard();
				}
			}
		}
	}
}
