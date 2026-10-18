// Accessibility projectile colours. info.xml classmaps swap the three base
// projectile behaviours for the subclasses at the bottom; each tints its unit
// right after Initialize, by team: friendly when the owner is a player or a
// player-owned actor (GetPlayerOwner), enemy otherwise. Colours come from a
// preset plus optional per-team overrides, stored in HWP settings (per machine).
namespace HWP
{
	namespace Colors
	{
		class Preset
		{
			string name;
			vec4 enemy;
			vec4 friendly;
			Preset(const string &in n, vec4 e, vec4 f) { name = n; enemy = e; friendly = f; }
		}

		array<Preset@> g_presets;
		vec4 g_enemy = vec4(1, 1, 1, 1);
		vec4 g_friendly = vec4(1, 1, 1, 1);
		bool g_active = false;
		string g_presetName = "default";
		const string CVAR = "hwp_projectile_colors";

		void InitPresets()
		{
			if (g_presets.length() > 0)
				return;
			g_presets.insertLast(Preset("default", vec4(1, 1, 1, 1), vec4(1, 1, 1, 1)));
			g_presets.insertLast(Preset("contrast", vec4(1.0f, 0.35f, 0.35f, 1), vec4(0.45f, 0.8f, 1.0f, 1)));
			// red/green weakness: orange vs blue
			g_presets.insertLast(Preset("deuteranopia", vec4(1.0f, 0.6f, 0.1f, 1), vec4(0.3f, 0.6f, 1.0f, 1)));
			g_presets.insertLast(Preset("protanopia", vec4(1.0f, 0.85f, 0.2f, 1), vec4(0.35f, 0.55f, 1.0f, 1)));
			// blue/yellow weakness: red vs teal
			g_presets.insertLast(Preset("tritanopia", vec4(1.0f, 0.3f, 0.3f, 1), vec4(0.2f, 0.9f, 0.8f, 1)));
		}

		Preset@ Find(const string &in name)
		{
			for (uint i = 0; i < g_presets.length(); i++)
				if (g_presets[i].name == name)
					return g_presets[i];
			return null;
		}

		bool IsWhite(vec4 c) { return c.x >= 0.999f && c.y >= 0.999f && c.z >= 0.999f; }

		int HexDigit(const string &in s, uint i)
		{
			if (i >= s.length())
				return -1;
			auto ch = s.substr(i, 1).toLower();
			const string digits = "0123456789abcdef";
			return digits.findFirst(ch);
		}

		// "ff8800" -> vec4; white on bad input
		bool ParseHex(const string &in hex, vec4 &out c)
		{
			c = vec4(1, 1, 1, 1);
			string s = hex;
			if (s.findFirst("#") == 0)
				s = s.substr(1);
			if (s.length() != 6)
				return false;
			array<float> ch(3);
			for (uint i = 0; i < 3; i++)
			{
				int hi = HexDigit(s, i * 2);
				int lo = HexDigit(s, i * 2 + 1);
				if (hi < 0 || lo < 0)
					return false;
				ch[i] = float(hi * 16 + lo) / 255.0f;
			}
			c = vec4(ch[0], ch[1], ch[2], 1);
			return true;
		}

		string ToHex(vec4 c)
		{
			const string digits = "0123456789abcdef";
			string result;
			array<float> comps = { c.x, c.y, c.z };
			for (uint i = 0; i < 3; i++)
			{
				int v = int(comps[i] * 255.0f + 0.5f);
				if (v < 0) v = 0;
				if (v > 255) v = 255;
				result += digits.substr(v / 16, 1) + digits.substr(v % 16, 1);
			}
			return result;
		}

		void Refresh()
		{
			InitPresets();
			// the preset is the Game options cvar; older builds kept it in HWP settings
			auto old = HWP::Settings::GetString("colors.preset", "");
			if (!old.isEmpty())
			{
				HWP::Settings::Reset("colors.preset");
				if (old != "default" && GetVarInt(CVAR) == 0 && PresetIndex(old) > 0)
					SetVar(CVAR, PresetIndex(old));
			}
			int idx = GetVarInt(CVAR);
			if (idx < 0 || idx >= int(g_presets.length()))
				idx = 0;
			auto p = g_presets[idx];
			g_presetName = p.name;
			g_enemy = p.enemy;
			g_friendly = p.friendly;

			vec4 c;
			auto e = HWP::Settings::GetString("colors.enemy", "");
			if (!e.isEmpty() && ParseHex(e, c))
				g_enemy = c;
			auto f = HWP::Settings::GetString("colors.friendly", "");
			if (!f.isEmpty() && ParseHex(f, c))
				g_friendly = c;

			g_active = !(IsWhite(g_enemy) && IsWhite(g_friendly));
		}

		int PresetIndex(const string &in name)
		{
			for (uint i = 0; i < g_presets.length(); i++)
				if (g_presets[i].name == name)
					return i;
			return -1;
		}

		// picked in Options > Game: a preset there replaces custom colours
		void OnCvarChanged(int val)
		{
			InitPresets();
			if (val >= 0 && val < int(g_presets.length()) && g_presets[val].name != g_presetName)
			{
				HWP::Settings::Reset("colors.enemy");
				HWP::Settings::Reset("colors.friendly");
			}
			Refresh();
		}

		[Hook]
		void BaseGameModeConstructor(BaseGameMode@ gm)
		{
			AddVar(CVAR, 0, OnCvarChanged, cvar_flags::TriggerChanged);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("colors.") == 0)
				Refresh();
		}

		void Tint(UnitPtr unit, Actor@ owner)
		{
			if (!g_active || !unit.IsValid())
				return;
			bool friendly = owner !is null && GetPlayerOwner(owner) !is null;
			vec4 c = friendly ? g_friendly : g_enemy;
			if (IsWhite(c))
				return;
			unit.SetMultiplyColor(c);
		}

		void ReplyCurrent()
		{
			HWP::Commands::Reply(Resources::GetString(".hwp.colors.current", {
				{ "preset", g_presetName }, { "enemy", ToHex(g_enemy) }, { "friendly", ToHex(g_friendly) } }));
		}

		void CmdColors(array<string>@ args)
		{
			InitPresets();
			if (args.length() == 0)
			{
				ReplyCurrent();
				HWP::Commands::Reply(Resources::GetString(".hwp.colors.usage"));
				return;
			}

			auto what = args[0].toLower();
			if (what == "off")
			{
				SetVar(CVAR, 0);
				HWP::Settings::Reset("colors.enemy");
				HWP::Settings::Reset("colors.friendly");
			}
			else if ((what == "enemy" || what == "friendly") && args.length() >= 2)
			{
				vec4 c;
				if (!ParseHex(args[1], c))
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.colors.usage"));
					return;
				}
				HWP::Settings::SetString("colors." + what, ToHex(c));
			}
			else if (Find(what) !is null)
			{
				SetVar(CVAR, PresetIndex(what));
				HWP::Settings::Reset("colors.enemy");
				HWP::Settings::Reset("colors.friendly");
			}
			else
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.colors.usage"));
				return;
			}
			Refresh();
			ReplyCurrent();
		}
	}
}

class HWPNewProjectile : NewProjectile
{
	HWPNewProjectile(UnitPtr unit, SValue& params) { super(unit, params); }

	void Initialize(Actor@ owner, ProjectileTarget@ target, float intensity, bool husk, uint weapon) override
	{
		NewProjectile::Initialize(owner, target, intensity, husk, weapon);
		HWP::Colors::Tint(m_unit, owner);
	}
}

class HWPRayProjectile : RayProjectile
{
	HWPRayProjectile(UnitPtr unit, SValue& params) { super(unit, params); }

	void Initialize(Actor@ owner, ProjectileTarget@ target, float intensity, bool husk, uint weapon) override
	{
		RayProjectile::Initialize(owner, target, intensity, husk, weapon);
		HWP::Colors::Tint(m_unit, owner);
	}
}

class HWPBeamProjectile : BeamProjectile
{
	HWPBeamProjectile(UnitPtr unit, SValue& params) { super(unit, params); }

	void Initialize(Actor@ owner, ProjectileTarget@ target, float intensity, bool husk, uint weapon) override
	{
		BeamProjectile::Initialize(owner, target, intensity, husk, weapon);
		HWP::Colors::Tint(m_unit, owner);
	}
}

namespace Modules
{
	class HWPColorsModule : Module, HWP::ModuleStart
	{
		HWPColorsModule()
		{
			super("hwp-colors");
			HWP::Colors::InitPresets();
			HWP::Commands::Register("colors", "[preset|enemy RRGGBB|friendly RRGGBB|off]  projectile colours", HWP::Commands::Handler(HWP::Colors::CmdColors));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Colors::OnSettingChanged));
		}

		void Start(StartMode sMode)
		{
			HWP::Colors::Refresh();
			HWP::Log("colors", "options cvar " + HWP::Colors::CVAR + " = " + GetVarInt(HWP::Colors::CVAR) + " (" + HWP::Colors::g_presetName + ")");
			if (HWP::Colors::g_active)
				HWP::Log("colors", "preset " + HWP::Colors::g_presetName + " enemy #" + HWP::Colors::ToHex(HWP::Colors::g_enemy)
					+ " friendly #" + HWP::Colors::ToHex(HWP::Colors::g_friendly));
		}
	}
}
