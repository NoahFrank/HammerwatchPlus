// GameLab::Json - a minimal JSON object writer for [GL] log lines.
//
//   GameLab::Json j;
//   j.Str("verb", "state").Int("hp", 40).Bool("dead", false);
//   GameLab::Emit(j);          // [GL] {"verb":"state","hp":40,"dead":false}
//
// Values nest through Raw(key, otherJson.Close()) or Arr(...). Every line the
// harness reads starts with "[GL] " and is exactly one JSON object.
namespace GameLab
{
	string Escape(const string &in s)
	{
		string res;
		for (uint i = 0; i < s.length(); i++)
		{
			uint8 c = s[i];
			if (c == 34)
				res += "\\\"";
			else if (c == 92)
				res += "\\\\";
			else if (c == 10)
				res += "\\n";
			else if (c == 13)
				res += "\\r";
			else if (c == 9)
				res += "\\t";
			else if (c < 32)
				res += "?";
			else
				res += s.substr(i, 1);
		}
		return res;
	}

	string Quote(const string &in s)
	{
		return "\"" + Escape(s) + "\"";
	}

	class Json
	{
		string m_body;

		Json@ Raw(const string &in key, const string &in json)
		{
			if (m_body.length() > 0)
				m_body += ",";
			m_body += Quote(key) + ":" + json;
			return this;
		}

		Json@ Str(const string &in key, const string &in v) { return Raw(key, Quote(v)); }
		Json@ Int(const string &in key, int64 v) { return Raw(key, "" + v); }
		Json@ Num(const string &in key, double v) { return Raw(key, formatFloat(v, "", 0, 3)); }
		Json@ Bool(const string &in key, bool v) { return Raw(key, v ? "true" : "false"); }
		Json@ Null(const string &in key) { return Raw(key, "null"); }

		string Close() { return "{" + m_body + "}"; }
	}

	// ["a","b"] from strings, or [x,y] from already-encoded JSON values
	string StrArray(const array<string>@ items)
	{
		string res = "[";
		for (uint i = 0; i < items.length(); i++)
			res += (i > 0 ? "," : "") + Quote(items[i]);
		return res + "]";
	}

	string RawArray(const array<string>@ items)
	{
		string res = "[";
		for (uint i = 0; i < items.length(); i++)
			res += (i > 0 ? "," : "") + items[i];
		return res + "]";
	}

	void Emit(Json@ j)
	{
		print("[GL] " + j.Close());
	}
}
