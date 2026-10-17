// HWP::Commands - console commands for HammerwatchPlus. Typing
// "hwp <command> [args]" in the console runs a registered sub-command;
// "hwp help" lists them. Modules register their own:
//
//   HWP::Commands::Register("swapkey", "<scancode>  set the weapon swap key",
//       HWP::Commands::Handler(OnSwapKey));   // void OnSwapKey(array<string>@ args)
//
// Why the console and not chat: the in-game chat belongs to the main menu's
// script, which runs the unmodded base scripts and has no town or players,
// so a chat override never loads. The console calls "hwp" in the game's
// script (core's module registers it there), and a one-string console
// function gets the whole rest of the line. Replies print to the console and
// also go to the local chat log (SendSystemMessage "AddChat"; the chat only
// shows in a lobby, or after the vanilla show_chat command).
namespace HWP
{
	namespace Commands
	{
		funcdef void Handler(array<string>@ args);

		class Entry
		{
			string name;
			string help;
			Handler@ fn;
			Entry(const string &in n, const string &in h, Handler@ f) { name = n; help = h; @fn = f; }
		}

		array<Entry@> g_entries;

		void Register(const string &in name, const string &in help, Handler@ fn)
		{
			for (uint i = 0; i < g_entries.length(); i++)
			{
				if (g_entries[i].name == name)
				{
					@g_entries[i] = Entry(name, help, fn);
					return;
				}
			}
			g_entries.insertLast(Entry(name, help, fn));
		}

		// text without the \cRRGGBB / \d colour codes, for the console
		string Plain(const string &in text)
		{
			string res;
			uint i = 0;
			while (i < text.length())
			{
				if (text.substr(i, 2) == "\\c")
				{
					i += 2;
					// the game's text renderer reads exactly 6 hex digits (RRGGBB);
					// text right after the code may start with a-f ("\c00ff00Caught")
					uint run = 0;
					while (run < 6 && i + run < text.length() && IsHex(text.substr(i + run, 1)))
						run++;
					i += run;
					continue;
				}
				if (text.substr(i, 2) == "\\d")
				{
					i += 2;
					continue;
				}
				res += text.substr(i, 1);
				i++;
			}
			return res;
		}

		bool IsHex(const string &in c)
		{
			return (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F");
		}

		// One line in the console and the local chat log, no network traffic.
		void Reply(const string &in text)
		{
			print("[HWP] " + Plain(text));
			SValueBuilder b;
			b.PushString("\\c" + "ffd27f" + "[HWP]\\d " + text);
			SendSystemMessage("AddChat", b.Build());
		}

		// the console's "hwp <rest of the line>"
		void ConsoleHwp(cvar_t@ arg)
		{
			auto line = strTrim(arg.GetString());
			// hwp "material all 5" arrives with its quotes
			if (line.length() >= 2 && line.substr(0, 1) == "\"" && line.substr(line.length() - 1) == "\"")
				line = strTrim(line.substr(1, line.length() - 2));
			Handle(line);
		}

		void Handle(const string &in line)
		{
			auto raw = strTrim(line).split(" ");
			array<string> args;
			for (uint i = 0; i < raw.length(); i++)
			{
				if (!raw[i].isEmpty())
					args.insertLast(raw[i]);
			}

			if (args.length() == 0 || args[0] == "help")
			{
				Reply("commands (" + g_entries.length() + "):");
				for (uint i = 0; i < g_entries.length(); i++)
					Reply("hwp " + g_entries[i].name + " " + g_entries[i].help);
				return;
			}

			auto name = args[0];
			args.removeAt(0);
			for (uint i = 0; i < g_entries.length(); i++)
			{
				if (g_entries[i].name != name)
					continue;
				g_entries[i].fn(args);
				return;
			}

			Reply("unknown command '" + name + "', try hwp help");
		}

		// ---- value parsing ---------------------------------------------------
		// Whole-string checks: "12" is an int, "1.5" a float, "112233ff" and
		// "10s" stay text (parseInt would happily eat a prefix of them).

		bool IsDigits(const string &in s, uint from, uint to)
		{
			if (to <= from)
				return false;
			for (uint i = from; i < to; i++)
			{
				auto c = s.substr(i, 1);
				if (c < "0" || c > "9")
					return false;
			}
			return true;
		}

		uint SignLength(const string &in s)
		{
			if (s.length() > 0 && (s.substr(0, 1) == "-" || s.substr(0, 1) == "+"))
				return 1;
			return 0;
		}

		bool IsInteger(const string &in s)
		{
			return IsDigits(s, SignLength(s), s.length());
		}

		bool IsDecimal(const string &in s)
		{
			int dot = s.findFirst(".");
			if (dot < 0)
				return false;
			uint start = SignLength(s);
			bool before = IsDigits(s, start, uint(dot));
			bool after = IsDigits(s, uint(dot) + 1, s.length());
			if (!before && !after)
				return false;
			if (!before && uint(dot) != start)
				return false;
			if (!after && uint(dot) + 1 != s.length())
				return false;
			return true;
		}

		// ---- built-ins -------------------------------------------------------

		void CmdGet(array<string>@ args)
		{
			if (args.length() < 1)
			{
				Reply("usage: hwp get <setting>");
				return;
			}
			Reply(args[0] + " = " + HWP::Settings::GetText(args[0], "(unset)"));
		}

		void CmdSet(array<string>@ args)
		{
			if (args.length() < 2)
			{
				Reply("usage: hwp set <setting> <value>   (value: true/false, number or text)");
				return;
			}
			if (!HWP::Settings::CanSave())
			{
				Reply("settings are saved with your town - load a character first");
				return;
			}
			auto key = args[0];
			auto val = args[1];
			if (val == "true" || val == "false")
				HWP::Settings::SetBool(key, val == "true");
			else if (IsInteger(val))
				HWP::Settings::SetInt(key, parseInt(val));
			else if (IsDecimal(val))
				HWP::Settings::SetFloat(key, parseFloat(val));
			else
				HWP::Settings::SetString(key, val);
			if (!Network::IsServer() && HWP::Settings::IsSynced(key))
			{
				Reply(key + " = " + val + " (saved with your town, but the host controls this setting in a lobby - it applies when you host)");
				return;
			}
			Reply(key + " = " + val + " (saved with your town)");
			NotifySettingChanged(key);
		}

		void CmdSettings(array<string>@ args)
		{
			auto keys = HWP::Settings::Bag().Keys();
			int n = 0;
			for (uint i = 0; i < keys.length(); i++)
			{
				if (keys[i].findFirst(HWP::Settings::PREFIX) != 0)
					continue;
				auto key = keys[i].substr(HWP::Settings::PREFIX.length());
				Reply(key + " = " + HWP::Settings::GetText(key, "?"));
				n++;
			}
			if (n == 0)
				Reply("no settings changed yet; modules use their defaults");
		}

		void CmdVersion(array<string>@ args)
		{
			Reply("HammerwatchPlus " + HWP::VERSION + (Network::IsServer() ? " (host)" : " (client)"));
		}

		// Modules that cache a setting register here to be told when hwp set changes it.
		funcdef void SettingListener(const string &in key);
		array<SettingListener@> g_settingListeners;
		// Modules are remade for every level, so the same listener registers again
		// and again; keep one copy per function.
		void OnSettingChanged(SettingListener@ fn)
		{
			for (uint i = 0; i < g_settingListeners.length(); i++)
				if (g_settingListeners[i] is fn)
					return;
			g_settingListeners.insertLast(fn);
		}
		void NotifySettingChanged(const string &in key)
		{
			for (uint i = 0; i < g_settingListeners.length(); i++)
				g_settingListeners[i](key);
		}

		void RegisterBuiltins()
		{
			// modules are made in the game's script only, so this never meets
			// the main menu's copy of the console (see the top of this file)
			AddFunction("hwp", { cvar_type::String }, ConsoleHwp, 0,
				"HammerwatchPlus commands: hwp help");
			Register("version", " show the mod version", Handler(CmdVersion));
			Register("settings", " list changed settings", Handler(CmdSettings));
			Register("get", "<setting>  show one setting", Handler(CmdGet));
			Register("set", "<setting> <value>  change a setting", Handler(CmdSet));
			HWP::Cheats::Register();
		}
	}
}
