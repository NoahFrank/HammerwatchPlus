// HWP::SaveData - key/value storage attached to player and town records and
// persisted through the PlayerRecordSave/Load and TownRecordSave/Load hooks.
// Everything lands under one "hwp" dictionary inside the record, so a save
// stays loadable by the vanilla game (which ignores keys it does not know).
//
//   auto bag = HWP::SaveData::Player(record);     // or ::Local(), ::Town()
//   bag.SetInt("goldpet.tier", 2);                // primitives...
//   int tier = bag.GetInt("goldpet.tier", 0);
//   bag.Set("pets.levels", builder.Build());      // ...or any SValue
//
// Keys are "<module>.<name>". Writes are picked up by the next save of that
// record. Player records are also serialised for the network, so the host sees
// the clients' hwp data as soon as they join.
namespace HWP
{
	class DataBag
	{
		dictionary m_values; // key -> SValue@

		SValue@ Get(const string &in key)
		{
			SValue@ v;
			m_values.get(key, @v);
			return v;
		}

		void Set(const string &in key, SValue@ value)
		{
			if (value is null)
				m_values.delete(key);
			else
				m_values.set(key, @value);
		}

		bool Has(const string &in key) { return m_values.exists(key); }
		void Remove(const string &in key) { m_values.delete(key); }
		array<string>@ Keys() { return m_values.getKeys(); }

		int GetInt(const string &in key, int def = 0)
		{
			auto v = Get(key);
			if (v is null)
				return def;
			if (v.GetType() == SValueType::Integer)
				return v.GetInteger();
			if (v.GetType() == SValueType::Float)
				return int(v.GetFloat());
			return def;
		}

		float GetFloat(const string &in key, float def = 0)
		{
			auto v = Get(key);
			if (v is null)
				return def;
			if (v.GetType() == SValueType::Float)
				return v.GetFloat();
			if (v.GetType() == SValueType::Integer)
				return float(v.GetInteger());
			return def;
		}

		bool GetBool(const string &in key, bool def = false)
		{
			auto v = Get(key);
			if (v is null || v.GetType() != SValueType::Boolean)
				return def;
			return v.GetBoolean();
		}

		string GetString(const string &in key, const string &in def = "")
		{
			auto v = Get(key);
			if (v is null || v.GetType() != SValueType::String)
				return def;
			return v.GetString();
		}

		void SetInt(const string &in key, int val) { SValueBuilder b; b.PushInteger(val); Set(key, b.Build()); }
		void SetFloat(const string &in key, float val) { SValueBuilder b; b.PushFloat(val); Set(key, b.Build()); }
		void SetBool(const string &in key, bool val) { SValueBuilder b; b.PushBoolean(val); Set(key, b.Build()); }
		void SetString(const string &in key, const string &in val) { SValueBuilder b; b.PushString(val); Set(key, b.Build()); }

		// Called from inside the record's dictionary.
		void Save(SValueBuilder& builder)
		{
			auto keys = m_values.getKeys();
			if (keys.length() == 0)
				return;
			builder.PushDictionary("hwp");
			for (uint i = 0; i < keys.length(); i++)
			{
				SValue@ v;
				if (m_values.get(keys[i], @v) && v !is null)
					builder.PushSimple(keys[i], v);
			}
			builder.PopDictionary();
		}

		// `data` is the record's dictionary.
		void Load(SValue@ data)
		{
			m_values.deleteAll();
			if (data is null || data.GetType() != SValueType::Dictionary)
				return;
			auto hwp = data.GetDictionaryEntry("hwp");
			if (hwp is null || hwp.GetType() != SValueType::Dictionary)
				return;
			auto dict = hwp.GetDictionary();
			auto keys = dict.getKeys();
			for (uint i = 0; i < keys.length(); i++)
			{
				SValue@ v;
				if (dict.get(keys[i], @v) && v !is null)
					m_values.set(keys[i], @v);
			}
		}
	}

	namespace SaveData
	{
		// A bag hangs on its record's `userdata` dictionary, so it lives exactly as
		// long as the record: LoadTown() builds fresh TownRecords on every level
		// change and the character picker loads records it never activates, and
		// none of those may pin a bag after they are gone.
		const string USERDATA_KEY = "hwp";
		DataBag@ g_scratch; // handed out when there is no record yet, never saved

		DataBag@ Player(PlayerRecord@ record)
		{
			if (record is null)
				return Scratch();
			DataBag@ bag;
			if (record.userdata.get(USERDATA_KEY, @bag) && bag !is null)
				return bag;
			@bag = DataBag();
			record.userdata.set(USERDATA_KEY, @bag);
			return bag;
		}

		DataBag@ Local() { return Player(GetLocalPlayerRecord()); }

		DataBag@ Town(TownRecord@ record)
		{
			if (record is null)
				return Scratch();
			DataBag@ bag;
			if (record.userdata.get(USERDATA_KEY, @bag) && bag !is null)
				return bag;
			@bag = DataBag();
			record.userdata.set(USERDATA_KEY, @bag);
			return bag;
		}

		// The lobby's town (the host's copy on clients): shared, read-only for clients.
		DataBag@ Town() { return Town(g_currTownRecord); }

		// The local player's own town: the only TownRecord that is ever saved.
		DataBag@ MyTown() { return Town(g_myTownRecord); }

		DataBag@ Scratch()
		{
			if (g_scratch is null)
				@g_scratch = DataBag();
			return g_scratch;
		}
	}
}

namespace HWPSaveData
{
	[Hook]
	void PlayerRecordSave(PlayerRecord@ record, SValueBuilder& builder)
	{
		HWP::SaveData::Player(record).Save(builder);
	}

	[Hook]
	void PlayerRecordLoad(PlayerRecord@ record, SValue@ data)
	{
		HWP::SaveData::Player(record).Load(data);
	}

	[Hook]
	void TownRecordSave(TownRecord@ town, SValueBuilder& builder)
	{
		HWP::SaveData::Town(town).Save(builder);
	}

	[Hook]
	void TownRecordLoad(TownRecord@ town, SValue@ data)
	{
		auto bag = HWP::SaveData::Town(town);
		bag.Load(data);
		HWP::Log("core", "town record loaded, " + bag.Keys().length() + " hwp key(s)");
	}
}
