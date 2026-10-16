// Spec rework skeleton. Each specialisation that has an entry
// "hwp_spec_<subclass id>" in tweak/hwp/buffs_specs.sval gets that buff
// re-applied to the local player every 2 s (runs only on the owner's machine,
// where damage is computed). This is the data-only first step: the numbers are
// placeholders for the user to tune, and real reworks (new skills, changed
// scaling) will replace them spec by spec.
namespace HWP
{
	namespace Specs
	{
		const string BUFFS = "tweak/hwp/buffs_specs.sval";
		const int TICK_MS = 2000;
		array<string> SPECS = { "ranger_nature", "warlock_summoning", "wizard_conjuration", "wizard_transmutation" };

		bool g_enabled = true;
		dictionary g_defs; // subclass id -> ActorBuffDef@ (null when no entry)
		string g_active;   // the spec the local player currently gets a buff for

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("specs.enabled", true);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("specs.") == 0)
				RefreshSettings();
		}

		// buffs_specs.sval has no <loader>, so its entries are plain resources
		bool HasEntry(const string &in spec)
		{
			return Resources::GetSValue(HashString(BUFFS + ":hwp_spec_" + spec)) !is null;
		}

		ActorBuffDef@ Def(const string &in spec)
		{
			if (g_defs.exists(spec))
				return cast<ActorBuffDef>(g_defs[spec]);
			ActorBuffDef@ def;
			if (HasEntry(spec))
				@def = LoadActorBuff(BUFFS + ":hwp_spec_" + spec);
			@g_defs[spec] = def;
			return def;
		}

		string LocalSpec()
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.playerClass is null)
				return "";
			return rec.playerClass.m_id;
		}

		void Tick()
		{
			g_active = "";
			if (!g_enabled || g_inTown)
				return;
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.actor is null || rec.playerClass is null || rec.IsDead())
				return;
			auto def = Def(rec.playerClass.m_id);
			if (def is null)
				return;
			auto pb = cast<PlayerBase>(rec.actor);
			if (pb is null)
				return;
			pb.ApplyBuff(ActorBuff(pb, def, 1.0f, false));
			g_active = rec.playerClass.m_id;
		}

		void CmdSpecs(array<string>@ args)
		{
			string list = "";
			for (uint i = 0; i < SPECS.length(); i++)
			{
				if (!list.isEmpty())
					list += ", ";
				list += SPECS[i] + (HasEntry(SPECS[i]) ? "" : " (no entry)");
			}
			string mine = LocalSpec();
			HWP::Commands::Reply(Resources::GetString(".hwp.specs.status", {
				{ "state", g_enabled ? "on" : "off" }, { "list", list },
				{ "mine", mine.isEmpty() ? "-" : mine },
				{ "active", g_active.isEmpty() ? Resources::GetString(".hwp.specs.inactive") : Resources::GetString(".hwp.specs.active") } }));
		}

		void SelfCheck()
		{
			int found = 0;
			for (uint i = 0; i < SPECS.length(); i++)
			{
				if (HasEntry(SPECS[i]))
					found++;
				else
					HWP::LogError("specs", "missing " + BUFFS + ":hwp_spec_" + SPECS[i]);
			}
			HWP::Log("specs", "self-check done: " + found + "/" + SPECS.length() + " spec buffs");
		}
	}
}

namespace Modules
{
	class HWPSpecsModule : Module
	{
		int m_timer = 0;

		HWPSpecsModule()
		{
			super("hwp-specs");
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Specs::OnSettingChanged));
			HWP::Commands::Register("specs", " spec rework status", HWP::Commands::Handler(HWP::Specs::CmdSpecs));
			HWP::Specs::SelfCheck();
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::Settings::Sync("specs.");
			HWP::Specs::RefreshSettings();
			HWP::Specs::g_active = "";
			m_timer = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused)
				return;
			m_timer += ms;
			if (m_timer < HWP::Specs::TICK_MS)
				return;
			m_timer = 0;
			HWP::Specs::Tick();
		}
	}
}
