// HWP::Net - a small request/event bus on top of two generic network messages
// (HWPRequest client->host and HWPEvent host->clients, declared in
// system/messages.net), so modules do not each need their own message types.
//
//   // host side, e.g. in a module constructor
//   HWP::Net::OnRequest("gambler.bet", HWP::Net::RequestHandler(OnBet));     // void OnBet(uint8 peer, SValue@ data)
//   // every peer
//   HWP::Net::OnEvent("gambler.result", HWP::Net::EventHandler(OnResult));   // void OnResult(SValue@ data)
//
//   HWP::Net::Request("gambler.bet", data);       // client -> host; on the host the handler runs directly
//   HWP::Net::Broadcast("gambler.result", data);  // host -> every peer, the host included
//   HWP::Net::Send(peer, "gambler.result", data); // host -> one peer
//
// Names travel as HashString ints. Every lobby member runs the same modules, so
// an unknown id only means a version mismatch; it is logged once per id.
namespace HWP
{
	namespace Net
	{
		funcdef void RequestHandler(uint8 peer, SValue@ data);
		funcdef void EventHandler(SValue@ data);

		class RequestEntry
		{
			int id;
			string name;
			RequestHandler@ fn;
			RequestEntry(const string &in n, RequestHandler@ f) { name = n; id = Id(n); @fn = f; }
		}

		class EventEntry
		{
			int id;
			string name;
			EventHandler@ fn;
			EventEntry(const string &in n, EventHandler@ f) { name = n; id = Id(n); @fn = f; }
		}

		array<RequestEntry@> g_requests;
		array<EventEntry@> g_events;
		array<int> g_unknownWarned;

		int Id(const string &in name) { return int(HashString(name)); }

		SValue@ Empty()
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PopDictionary();
			return b.Build();
		}

		void OnRequest(const string &in name, RequestHandler@ handler)
		{
			int id = Id(name);
			for (uint i = 0; i < g_requests.length(); i++)
			{
				if (g_requests[i].id != id)
					continue;
				if (g_requests[i].name != name)
					HWP::LogError("net", "request id collision: '" + name + "' vs '" + g_requests[i].name + "'");
				@g_requests[i].fn = handler;
				return;
			}
			g_requests.insertLast(RequestEntry(name, handler));
		}

		void OnEvent(const string &in name, EventHandler@ handler)
		{
			int id = Id(name);
			for (uint i = 0; i < g_events.length(); i++)
			{
				if (g_events[i].id != id)
					continue;
				if (g_events[i].name != name)
					HWP::LogError("net", "event id collision: '" + name + "' vs '" + g_events[i].name + "'");
				@g_events[i].fn = handler;
				return;
			}
			g_events.insertLast(EventEntry(name, handler));
		}

		// Request, Broadcast and Send take the SValue they are handed (pass a
		// fresh b.Build(), or .Copy() a value you keep or did not build, such as
		// a handler's `data`): SValues are not reference counted, so it is freed
		// here once sent and dispatched.

		// Client -> host. On the host the handler is called right away with the local peer.
		void Request(const string &in name, SValue@ data = null)
		{
			if (data is null)
				@data = Empty();
			int id = Id(name);
			if (Network::IsServer())
			{
				DispatchRequest(uint8(Lobby::GetLocalPeer()), id, data);
				data.Delete();
			}
			else
				(Network::Message("HWPRequest") << id << data).SendToHost(); // << takes the value
		}

		// Host -> everyone (the host's own handler runs too).
		void Broadcast(const string &in name, SValue@ data = null)
		{
			if (!Network::IsServer())
			{
				HWP::LogError("net", "Broadcast('" + name + "') called on a client; ignored");
				if (data !is null)
					data.Delete();
				return;
			}
			if (data is null)
				@data = Empty();
			int id = Id(name);
			(Network::Message("HWPEvent") << id << data.Copy()).SendToAll();
			DispatchEvent(id, data);
			data.Delete();
		}

		// Host -> one peer (runs locally when that peer is the host).
		void Send(uint8 peer, const string &in name, SValue@ data = null)
		{
			if (!Network::IsServer())
			{
				HWP::LogError("net", "Send('" + name + "') called on a client; ignored");
				if (data !is null)
					data.Delete();
				return;
			}
			if (data is null)
				@data = Empty();
			int id = Id(name);
			if (int(peer) == Lobby::GetLocalPeer())
			{
				DispatchEvent(id, data);
				data.Delete();
			}
			else
				(Network::Message("HWPEvent") << id << data).SendToPeer(peer); // << takes the value
		}

		void DispatchRequest(uint8 peer, int id, SValue@ data)
		{
			if (!Network::IsServer())
				return; // requests are only ever meant for the host
			for (uint i = 0; i < g_requests.length(); i++)
			{
				if (g_requests[i].id == id)
				{
					g_requests[i].fn(peer, data);
					return;
				}
			}
			WarnUnknown("request", id);
		}

		void DispatchEvent(int id, SValue@ data)
		{
			for (uint i = 0; i < g_events.length(); i++)
			{
				if (g_events[i].id == id)
				{
					g_events[i].fn(data);
					return;
				}
			}
			WarnUnknown("event", id);
		}

		void WarnUnknown(const string &in kind, int id)
		{
			if (g_unknownWarned.find(id) >= 0)
				return;
			g_unknownWarned.insertLast(id);
			HWP::LogError("net", "no handler for " + kind + " id " + id + " (module version mismatch between players?)");
		}
	}
}

// Network message handlers; the engine looks these up by message namespace + name.
namespace HWPNet
{
	void HWPRequest(uint8 peer, int id, SValue@ data)
	{
		HWP::Net::DispatchRequest(peer, id, data);
	}

	void HWPEvent(int id, SValue@ data)
	{
		HWP::Net::DispatchEvent(id, data);
	}
}
