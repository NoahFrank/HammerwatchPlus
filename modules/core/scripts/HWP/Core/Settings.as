// HWP::Settings - the local player's HammerwatchPlus preferences.
// Stored in the local player's *own* town record (g_myTownRecord, the only one
// the game saves; on a co-op client g_currTownRecord is a throwaway copy of the
// host's town) as "settings.<name>", so they live in the persistent save and
// follow the save slot. Modules read them with a default; a settings GUI arrives
// with the first module that needs toggles.
//
//   bool split = HWP::Settings::GetBool("architect.split_cost", true);
//   HWP::Settings::SetBool("architect.split_cost", false);
//
// Host-authoritative settings: a module calls HWP::Settings::Sync("keys.") once
// (constructor). Every setting under that prefix is then read from the host's
// values on clients - the core module ships them with the settings.sync event
// (on join, and whenever the host changes one) - so gameplay rules that must
// agree across the lobby cannot drift. The host still reads its own bag.
namespace HWP
{
	namespace Settings
	{
		const string PREFIX = "settings.";

		array<string> g_syncedPrefixes;
		array<string> g_localOnly; // names inside a synced prefix each player keeps for themselves
		SValue@ g_remote; // client: dictionary name -> value, as sent by the host

		HWP::DataBag@ Bag() { return HWP::SaveData::MyTown(); }

		void Sync(const string &in prefix)
		{
			if (g_syncedPrefixes.find(prefix) < 0)
				g_syncedPrefixes.insertLast(prefix);
		}

		// A per-player preference under a synced prefix (legacy.enabled): every
		// machine reads its own value.
		void LocalOnly(const string &in name)
		{
			if (g_localOnly.find(name) < 0)
				g_localOnly.insertLast(name);
		}

		bool IsSynced(const string &in name)
		{
			if (g_localOnly.find(name) >= 0)
				return false;
			for (uint i = 0; i < g_syncedPrefixes.length(); i++)
				if (name.findFirst(g_syncedPrefixes[i]) == 0)
					return true;
			return false;
		}

		bool UseRemote(const string &in name)
		{
			return !Network::IsServer() && IsSynced(name);
		}

		bool GetBool(const string &in name, bool def = false)
		{
			if (UseRemote(name))
				return HWP::SV::Bool(g_remote, name, def);
			return Bag().GetBool(PREFIX + name, def);
		}
		int GetInt(const string &in name, int def = 0)
		{
			if (UseRemote(name))
				return HWP::SV::Int(g_remote, name, def);
			return Bag().GetInt(PREFIX + name, def);
		}
		float GetFloat(const string &in name, float def = 0)
		{
			if (UseRemote(name))
				return HWP::SV::Float(g_remote, name, def);
			return Bag().GetFloat(PREFIX + name, def);
		}
		string GetString(const string &in name, const string &in def = "")
		{
			if (UseRemote(name))
				return HWP::SV::Str(g_remote, name, def);
			return Bag().GetString(PREFIX + name, def);
		}
		string GetText(const string &in name, const string &in def = "")
		{
			if (UseRemote(name))
				return HWP::SV::Text(HWP::SV::Field(g_remote, name), def);
			return Bag().GetText(PREFIX + name, def);
		}

		// Settings persist with g_myTownRecord, which only exists inside a
		// gameplay game mode (town / run). In the main-menu lobby there is nothing
		// to save them to.
		bool CanSave() { return g_myTownRecord !is null && cast<AGameplayGameMode>(g_gameMode) !is null; }

		void SetBool(const string &in name, bool val) { Bag().SetBool(PREFIX + name, val); }
		void SetInt(const string &in name, int val) { Bag().SetInt(PREFIX + name, val); }
		void SetFloat(const string &in name, float val) { Bag().SetFloat(PREFIX + name, val); }
		void SetString(const string &in name, const string &in val) { Bag().SetString(PREFIX + name, val); }
		void Reset(const string &in name) { Bag().Remove(PREFIX + name); }

		// ---- host <-> client ---------------------------------------------------

		// Host: every synced setting it has set, keyed without the prefix.
		SValue@ Pack()
		{
			SValueBuilder b;
			b.PushDictionary();
			auto keys = Bag().Keys();
			for (uint i = 0; i < keys.length(); i++)
			{
				if (keys[i].findFirst(PREFIX) != 0)
					continue;
				string name = keys[i].substr(PREFIX.length());
				if (!IsSynced(name))
					continue;
				auto v = Bag().Get(keys[i]);
				if (v !is null)
					b.PushSimple(name, v.Copy()); // PushSimple takes the value; the bag keeps its own
			}
			b.PopDictionary();
			return b.Build();
		}

		bool g_remoteReady = false; // client: the host's values have arrived this level

		// True when synced settings can be trusted: always on the host, on a
		// client once settings.sync has arrived for the current level. Code that
		// must agree with the host (chest locks) waits for this.
		bool RemoteReady() { return Network::IsServer() || g_remoteReady; }

		// Client: adopt the host's values. Returns the names that arrived so
		// the caller can tell the modules which settings changed.
		array<string>@ Apply(SValue@ data)
		{
			array<string> names;
			if (data is null || data.GetType() != SValueType::Dictionary)
				return names;
			if (g_remote !is null)
				g_remote.Delete();
			@g_remote = data.Copy(); // the message's data is freed after the handler returns
			g_remoteReady = true;
			auto d = data.GetDictionary();
			if (d !is null)
				names = d.getKeys();
			return names;
		}

		void ClearRemote() { @g_remote = null; g_remoteReady = false; }
	}
}
