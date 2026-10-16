// HWP::Commands - chat commands for HammerwatchPlus. A line typed into the
// in-game chat that starts with "/hwp" is routed here (core overrides
// scripts/GUI/Menus/InGameChat.as to do that) instead of being sent to the
// lobby. Modules register sub-commands; "/hwp help" lists them.
//
//   HWP::Commands::Register("swapkey", "<scancode>  set the weapon swap key",
//       HWP::Commands::Handler(OnSwapKey));   // void OnSwapKey(array<string>@ args)
//
// Replies go to the local chat log only (SendSystemMessage "AddChat").
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

		// One line in the local chat log, no network traffic.
		void Reply(const string &in text)
		{
			SValueBuilder b;
			b.PushString("\\c" + "ffd27f" + "[HWP]\\d " + text);
			SendSystemMessage("AddChat", b.Build());
		}

		// Returns true when the text was an HWP command (handled or not), so the
		// caller must not send it as a chat message.
		bool Handle(const string &in text)
		{
			auto trimmed = strTrim(text);
			if (trimmed.findFirst("/hwp") != 0)
				return false;
			if (trimmed.length() > 4 && trimmed.substr(4, 1) != " ")
				return false;

			auto raw = trimmed.split(" ");
			array<string> args;
			for (uint i = 1; i < raw.length(); i++)
			{
				if (!raw[i].isEmpty())
					args.insertLast(raw[i]);
			}

			if (args.length() == 0 || args[0] == "help")
			{
				Reply("commands (" + g_entries.length() + "):");
				for (uint i = 0; i < g_entries.length(); i++)
					Reply("/hwp " + g_entries[i].name + " " + g_entries[i].help);
				return true;
			}

			auto name = args[0];
			args.removeAt(0);
			for (uint i = 0; i < g_entries.length(); i++)
			{
				if (g_entries[i].name != name)
					continue;
				g_entries[i].fn(args);
				return true;
			}

			Reply("unknown command '" + name + "', try /hwp help");
			return true;
		}

		// ---- built-ins -------------------------------------------------------

		void CmdGet(array<string>@ args)
		{
			if (args.length() < 1)
			{
				Reply("usage: /hwp get <setting>");
				return;
			}
			Reply(args[0] + " = " + HWP::Settings::GetString(args[0], "(unset)"));
		}

		void CmdSet(array<string>@ args)
		{
			if (args.length() < 2)
			{
				Reply("usage: /hwp set <setting> <value>   (value: true/false, number or text)");
				return;
			}
			auto key = args[0];
			auto val = args[1];
			if (val == "true" || val == "false")
				HWP::Settings::SetBool(key, val == "true");
			else if (parseInt(val) != 0 || val == "0")
				HWP::Settings::SetInt(key, parseInt(val));
			else
				HWP::Settings::SetString(key, val);
			Reply(key + " = " + val + " (saved with your town)");
			for (uint i = 0; i < g_settingListeners.length(); i++)
				g_settingListeners[i](key);
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
				Reply(key + " = " + HWP::Settings::GetString(key, "?"));
				n++;
			}
			if (n == 0)
				Reply("no settings changed yet; modules use their defaults");
		}

		void CmdVersion(array<string>@ args)
		{
			Reply("HammerwatchPlus " + HWP::VERSION + (Network::IsServer() ? " (host)" : " (client)"));
		}

		// Modules that cache a setting register here to be told when /hwp set changes it.
		funcdef void SettingListener(const string &in key);
		array<SettingListener@> g_settingListeners;
		void OnSettingChanged(SettingListener@ fn) { g_settingListeners.insertLast(fn); }

		void RegisterBuiltins()
		{
			Register("version", " show the mod version", Handler(CmdVersion));
			Register("settings", " list changed settings", Handler(CmdSettings));
			Register("get", "<setting>  show one setting", Handler(CmdGet));
			Register("set", "<setting> <value>  change a setting", Handler(CmdSet));
		}
	}
}
