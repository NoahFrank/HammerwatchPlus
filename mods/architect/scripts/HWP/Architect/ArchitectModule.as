// Shared architect: the host keeps one merged list of alteration picks with the
// peer that pays for each; the overridden MissionArchitect.as (see the module
// README) sends a player's own picks here and renders the merged list.
//
//   architect.pick   client -> host   { ids: [int] }      my complete pick list
//   architect.query  client -> host   {}                  send me the state
//   architect.sync   host -> all      { ids, payers, split }
namespace HWP
{
	namespace Architect
	{
		const string PICK = "architect.pick";
		const string QUERY = "architect.query";
		const string SYNC = "architect.sync";

		class Pick
		{
			int id;
			uint8 payer;
			Pick(int i, uint8 p) { id = i; payer = p; }
		}

		array<Pick@> g_picks;   // host: merged list
		bool g_split = true;    // host setting, synced to everyone
		array<int> g_ids;       // everyone: last synced state
		array<int> g_payers;

		int ActivePlayers()
		{
			int n = 0;
			for (uint i = 0; i < g_players.length(); i++)
				if (g_players[i] !is null && g_players[i].peer != 255)
					n++;
			return n;
		}

		bool ShowPayer()
		{
			return ActivePlayers() > 1;
		}

		string PayerName(uint8 payer)
		{
			for (uint i = 0; i < g_players.length(); i++)
				if (g_players[i] !is null && g_players[i].peer == payer)
					return g_players[i].GetName();
			return Lobby::GetPlayerName(payer);
		}

		string BuffName(int id)
		{
			auto buff = MissionBuff::Get(uint(id));
			return buff is null ? "?" : Resources::GetString(buff.m_name);
		}

		SValue@ Pack()
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushBoolean("split", g_split);
			b.PushArray("ids");
			for (uint i = 0; i < g_picks.length(); i++)
				b.PushInteger(g_picks[i].id);
			b.PopArray();
			b.PushArray("payers");
			for (uint i = 0; i < g_picks.length(); i++)
				b.PushInteger(int(g_picks[i].payer));
			b.PopArray();
			b.PopDictionary();
			return b.Build();
		}

		void RefreshSplit()
		{
			g_split = HWP::Settings::GetBool("architect.split", true);
		}

		void BroadcastState()
		{
			HWP::Net::Broadcast(SYNC, Pack());
		}

		// ---- host --------------------------------------------------------------

		void OnPick(uint8 peer, SValue@ data)
		{
			auto ids = HWP::SV::Ints(data, "ids");

			// log the difference for the chat/debug trail
			for (uint i = 0; i < ids.length(); i++)
			{
				bool had = false;
				for (uint j = 0; j < g_picks.length(); j++)
					if (g_picks[j].id == ids[i] && g_picks[j].payer == peer)
						had = true;
				if (!had)
					HWP::Log("architect", PayerName(peer) + " picks " + BuffName(ids[i]));
			}

			for (int j = int(g_picks.length()) - 1; j >= 0; j--)
			{
				if (g_picks[j].payer != peer)
					continue;
				if (ids.find(g_picks[j].id) < 0)
					HWP::Log("architect", PayerName(peer) + " drops " + BuffName(g_picks[j].id));
				g_picks.removeAt(j);
			}
			for (uint i = 0; i < ids.length(); i++)
			{
				bool taken = false;
				for (uint j = 0; j < g_picks.length(); j++)
					if (g_picks[j].id == ids[i])
						taken = true;
				if (!taken)
					g_picks.insertLast(Pick(ids[i], peer));
			}

			RefreshSplit();
			BroadcastState();
		}

		void OnQuery(uint8 peer, SValue@ data)
		{
			RefreshSplit();
			if (peer == uint8(Lobby::GetLocalPeer()))
				OnSync(Pack());
			else
				HWP::Net::Send(peer, SYNC, Pack());
		}

		void OnMissionStarted()
		{
			if (!Network::IsServer())
				return;
			g_picks.removeRange(0, g_picks.length());
		}

		bool LoadoutMenuOpen()
		{
			auto gm = cast<BaseGameMode>(g_gameMode);
			if (gm is null || gm.m_windowManager is null)
				return false;
			for (uint i = 0; i < gm.m_windowManager.m_objects.length(); i++)
			{
				if (cast<MissionLoadoutMenu>(gm.m_windowManager.m_objects[i]) !is null)
					return true;
			}
			return false;
		}

		// The loadout menu went away without a start (Back, or the host closed
		// it for everyone): no pick survives it. The host drops the whole list
		// when its own menu closes; a client that backs out alone tells the host
		// to drop just its picks, otherwise the party would get them for free
		// (its OnPlay never runs, so it never pays).
		void OnLoadoutClosed()
		{
			if (Network::IsServer())
			{
				if (g_picks.length() == 0)
					return;
				g_picks.removeRange(0, g_picks.length());
				BroadcastState();
				return;
			}
			uint8 me = uint8(Lobby::GetLocalPeer());
			for (uint i = 0; i < g_payers.length(); i++)
			{
				if (g_payers[i] == int(me))
				{
					array<int> none;
					SendPicks(none);
					return;
				}
			}
		}


		// ---- everyone ------------------------------------------------------------

		void OnSync(SValue@ data)
		{
			g_ids = HWP::SV::Ints(data, "ids");
			g_payers = HWP::SV::Ints(data, "payers");
			g_split = HWP::SV::Bool(data, "split", g_split);

			auto gm = cast<BaseGameMode>(g_gameMode);
			if (gm is null || gm.m_windowManager is null)
				return;
			for (uint i = 0; i < gm.m_windowManager.m_objects.length(); i++)
			{
				auto menu = cast<MissionLoadoutMenu>(gm.m_windowManager.m_objects[i]);
				if (menu !is null)
				{
					for (uint j = 0; j < menu.m_loadouts.length(); j++)
					{
						auto arch = cast<SelectArchitectLoadout>(menu.m_loadouts[j]);
						if (arch !is null)
							arch.HWPSync(g_ids, g_payers);
					}
				}
				auto picker = cast<SelectArchitectSelector>(gm.m_windowManager.m_objects[i]);
				if (picker !is null)
					picker.RefreshFromHost();
			}
		}

		void SendPicks(array<int>@ ids)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushArray("ids");
			for (uint i = 0; i < ids.length(); i++)
				b.PushInteger(ids[i]);
			b.PopArray();
			b.PopDictionary();
			HWP::Net::Request(PICK, b.Build());
		}

		void RequestState()
		{
			HWP::Net::Request(QUERY, HWP::Net::Empty());
		}

		void OnSettingChanged(const string &in key)
		{
			if (key != "architect.split" || !Network::IsServer())
				return;
			RefreshSplit();
			BroadcastState();
		}

		void CmdStatus(array<string>@ args)
		{
			HWP::Commands::Reply(Resources::GetString(".hwp.architect.status", {
				{ "count", "" + g_ids.length() }, { "split", g_split ? "on" : "off" }, { "players", "" + ActivePlayers() } }));
			for (uint i = 0; i < g_ids.length(); i++)
				HWP::Commands::Reply("- " + BuffName(g_ids[i]) + " (" + PayerName(uint8(i < g_payers.length() ? g_payers[i] : 0)) + ")");
		}
	}
}

namespace Modules
{
	class HWPArchitectModule : Module, HWP::ModuleStart
	{
		HWPArchitectModule()
		{
			super("hwp-architect");
			HWP::Net::OnRequest(HWP::Architect::PICK, HWP::Net::RequestHandler(HWP::Architect::OnPick));
			HWP::Net::OnRequest(HWP::Architect::QUERY, HWP::Net::RequestHandler(HWP::Architect::OnQuery));
			HWP::Net::OnEvent(HWP::Architect::SYNC, HWP::Net::EventHandler(HWP::Architect::OnSync));
			HWP::Commands::Register("architect", " show the party's architect picks", HWP::Commands::Handler(HWP::Architect::CmdStatus));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Architect::OnSettingChanged));
		}

		bool m_menuOpen = false;

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			bool open = HWP::Architect::LoadoutMenuOpen();
			if (m_menuOpen && !open)
				HWP::Architect::OnLoadoutClosed();
			m_menuOpen = open;
		}

		void Start(StartMode sMode)
		{
			m_menuOpen = false;
			HWP::Architect::g_picks.removeRange(0, HWP::Architect::g_picks.length());
			HWP::Architect::g_ids.removeRange(0, HWP::Architect::g_ids.length());
			HWP::Architect::g_payers.removeRange(0, HWP::Architect::g_payers.length());
			if (Network::IsServer())
				HWP::Architect::RefreshSplit();
		}
	}
}
