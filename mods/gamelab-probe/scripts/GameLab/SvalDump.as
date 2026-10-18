// sval <file>: the engine's own parse of an .sval data file (after its %defblock /
// %block / %if / %replace preprocessing), as JSON. Read-only. This is how
// gamecode/datatables/ is produced (tools/export_datatables.py): the engine is the
// parser, so the exports are what the game actually loaded, not a re-implementation.
//
// Script cannot write files, so the JSON goes to the log in chunks:
//   [GL] {"id":..,"ok":true,"file":..,"part":k,"of":n,"chunk":"<escaped JSON text>"}
// and the harness joins the chunks of one id in part order.
namespace GameLab
{
	const uint SVAL_CHUNK = 6000;

	string Vec(uint n, double x, double y, double z = 0, double w = 0)
	{
		string res = "[" + formatFloat(x, "", 0, 6) + "," + formatFloat(y, "", 0, 6);
		if (n > 2)
			res += "," + formatFloat(z, "", 0, 6);
		if (n > 3)
			res += "," + formatFloat(w, "", 0, 6);
		return res + "]";
	}

	string SvalJson(SValue@ sv, uint depth)
	{
		if (sv is null)
			return "null";
		if (depth > 64)
			return "{\"__truncated\":\"depth\"}";
		auto t = sv.GetType();
		if (t == SValueType::Null)
			return "null";
		if (t == SValueType::Boolean)
			return sv.GetBoolean() ? "true" : "false";
		if (t == SValueType::Integer)
			return "" + sv.GetInteger();
		if (t == SValueType::Long)
			return "" + sv.GetLong();
		if (t == SValueType::Float)
			return formatFloat(sv.GetFloat(), "", 0, 6);
		if (t == SValueType::String)
			return Quote(sv.GetString());
		if (t == SValueType::Array)
		{
			auto arr = sv.GetArray();
			string res = "[";
			for (uint i = 0; i < arr.length(); i++)
				res += (i > 0 ? "," : "") + SvalJson(arr[i], depth + 1);
			return res + "]";
		}
		if (t == SValueType::Dictionary)
		{
			auto keys = sv.GetDictionaryKeys();
			keys.sortAsc();
			string res = "{";
			for (uint i = 0; i < keys.length(); i++)
				res += (i > 0 ? "," : "") + Quote(keys[i]) + ":" + SvalJson(sv.GetDictionaryEntry(keys[i]), depth + 1);
			return res + "}";
		}
		if (t == SValueType::Vector2)
		{
			vec2 v = sv.GetVector2();
			return Vec(2, v.x, v.y);
		}
		if (t == SValueType::Vector4)
		{
			vec4 v = sv.GetVector4();
			return Vec(4, v.x, v.y, v.z, v.w);
		}
		if (t == SValueType::IVector2)
		{
			ivec2 v = sv.GetIVector2();
			return "[" + v.x + "," + v.y + "]";
		}
		// members the game's own scripts never name: dispatch on the enum's runtime name
		string name = Reflect::TypeOf(t).GetEnumName(int(t));
		if (name == "Vector3")
		{
			vec3 v = sv.GetVector3();
			return Vec(3, v.x, v.y, v.z);
		}
		if (name == "IVector3")
		{
			ivec3 v = sv.GetIVector3();
			return "[" + v.x + "," + v.y + "," + v.z + "]";
		}
		if (name == "IVector4")
		{
			ivec4 v = sv.GetIVector4();
			return "[" + v.x + "," + v.y + "," + v.z + "," + v.w + "]";
		}
		return "{\"__unsupported\":" + Quote(name) + "}";
	}

	// sval <file.sval>[:entry]: read-only. A datatable as the game parsed it, as JSON, sent in parts when long.
	void VerbSval(const string &in id, array<string>@ args)
	{
		if (args.length() < 1)
		{
			Fail(id, "usage: sval <file.sval>");
			return;
		}
		auto sv = Resources::GetSValue(args[0]);
		if (sv is null)
		{
			Fail(id, "no sval '" + args[0] + "'");
			return;
		}
		string text = SvalJson(sv, 0);
		uint parts = (text.length() + SVAL_CHUNK - 1) / SVAL_CHUNK;
		if (parts == 0)
			parts = 1;
		for (uint k = 0; k < parts; k++)
		{
			Emit(Reply(id, true).Str("file", args[0]).Int("part", k).Int("of", parts)
				.Str("chunk", text.substr(k * SVAL_CHUNK, SVAL_CHUNK)));
		}
	}
}
