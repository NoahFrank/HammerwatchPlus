// HWP::SV - type-checked readers for SValue dictionaries (network payloads,
// save data, sval params). Each reader takes the dictionary SValue and a key
// and returns the default when the key is missing or holds another type, so a
// malformed payload degrades to defaults instead of a script exception.
//
//   int count = HWP::SV::Int(data, "count", 0);
//   auto ids = HWP::SV::Ints(data, "ids");
namespace HWP
{
	namespace SV
	{
		SValue@ Field(SValue@ dict, const string &in key)
		{
			if (dict is null || dict.GetType() != SValueType::Dictionary)
				return null;
			auto d = dict.GetDictionary();
			if (d is null)
				return null;
			SValue@ v;
			if (!d.get(key, @v))
				return null;
			return v;
		}

		string Str(SValue@ dict, const string &in key, const string &in def = "")
		{
			auto v = Field(dict, key);
			if (v is null || v.GetType() != SValueType::String)
				return def;
			return v.GetString();
		}

		int Int(SValue@ dict, const string &in key, int def = 0)
		{
			auto v = Field(dict, key);
			if (v is null)
				return def;
			if (v.GetType() == SValueType::Integer)
				return v.GetInteger();
			if (v.GetType() == SValueType::Float)
				return int(v.GetFloat());
			return def;
		}

		float Float(SValue@ dict, const string &in key, float def = 0)
		{
			auto v = Field(dict, key);
			if (v is null)
				return def;
			if (v.GetType() == SValueType::Float)
				return v.GetFloat();
			if (v.GetType() == SValueType::Integer)
				return float(v.GetInteger());
			return def;
		}

		bool Bool(SValue@ dict, const string &in key, bool def = false)
		{
			auto v = Field(dict, key);
			if (v is null)
				return def;
			// 'hwp set x 1' stores an int; any nonzero int reads as true
			if (v.GetType() == SValueType::Integer)
				return v.GetInteger() != 0;
			if (v.GetType() != SValueType::Boolean)
				return def;
			return v.GetBoolean();
		}

		// Integer entries of an array value; anything else is skipped.
		array<int>@ Ints(SValue@ dict, const string &in key)
		{
			array<int> result;
			auto v = Field(dict, key);
			if (v is null || v.GetType() != SValueType::Array)
				return result;
			auto arr = v.GetArray();
			if (arr is null)
				return result;
			for (uint i = 0; i < arr.length(); i++)
			{
				if (arr[i] !is null && arr[i].GetType() == SValueType::Integer)
					result.insertLast(arr[i].GetInteger());
			}
			return result;
		}

		// Text form of a primitive, for chat replies and logs.
		string Text(SValue@ v, const string &in def = "")
		{
			if (v is null)
				return def;
			if (v.GetType() == SValueType::String)
				return v.GetString();
			if (v.GetType() == SValueType::Integer)
				return "" + v.GetInteger();
			if (v.GetType() == SValueType::Float)
				return "" + v.GetFloat();
			if (v.GetType() == SValueType::Boolean)
				return v.GetBoolean() ? "true" : "false";
			return def;
		}
	}
}
