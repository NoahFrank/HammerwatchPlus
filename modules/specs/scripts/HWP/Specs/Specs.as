// Spec rework skeleton. Each specialisation that has an entry
// "hwp_spec_<subclass id>" in tweak/hwp/buffs_specs.sval gets that 60 s buff
// kept up on the local player (checked every 2 s, topped up near the end).
// It runs only on the owner's machine, where damage is computed. This is the data-only first step: the numbers are
// placeholders for the user to tune, and real reworks (new skills, changed
// scaling) will replace them spec by spec.
namespace HWP
{
	namespace Specs
	{
		const string BUFFS = "tweak/hwp/buffs_specs.sval";
		const int TICK_MS = 2000;
		const int REFRESH_MS = 3000; // re-apply when less than this is left (duration 60 s)
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

		// remaining ms of that buff on the player, 0 when it is not on them
		int TimeLeft(PlayerBase@ pb, ActorBuffDef@ def)
		{
			auto buffs = pb.m_buffs.m_buffs;
			for (uint i = 0; i < buffs.length(); i++)
				if (buffs[i].m_def is def)
					return buffs[i].m_duration;
			return 0;
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
			// the buff lasts a minute; only top it up when it is missing or nearly
			// out, so the buff bar does not replay its refresh animation every tick
			if (TimeLeft(pb, def) < REFRESH_MS)
				pb.ApplyBuff(ActorBuff(pb, def, 1.0f, false));
			g_active = rec.playerClass.m_id;
		}

		// "Ranger - Warden" from the subclass def and its parent class
		string SpecName(const string &in spec)
		{
			auto cls = PlayerClass::Get(spec);
			if (cls is null)
				return spec;
			string name = Resources::GetString(cls.m_name);
			auto parent = cls.parent != 0 ? PlayerClass::Get(cls.parent) : null;
			if (parent !is null)
				name = Resources::GetString(parent.m_name) + " - " + name;
			return name;
		}

		// One line per reworked spec (every class, not just yours), then your own
		// spec and whether it is boosted right now.
		void CmdSpecs(array<string>@ args)
		{
			string mine = LocalSpec();
			HWP::Commands::Reply(Resources::GetString(".hwp.specs.header", {
				{ "state", g_enabled ? "on" : "off" }, { "n", int(SPECS.length()) } }));
			for (uint i = 0; i < SPECS.length(); i++)
			{
				string line = SpecName(SPECS[i]) + ": " + Resources::GetString(".hwp.specs.effect." + SPECS[i]);
				if (!HasEntry(SPECS[i]))
					line += " " + Resources::GetString(".hwp.specs.missing");
				if (SPECS[i] == mine)
					line += " " + Resources::GetString(".hwp.specs.yours");
				HWP::Commands::Reply(line);
			}
			// why there is no boost: no rework for this spec, off, or in town
			// (the buff is only applied during runs, and specs are picked in town)
			string state;
			if (!g_active.isEmpty())
				state = ".hwp.specs.active";
			else if (mine.isEmpty() || SPECS.find(mine) < 0)
				state = ".hwp.specs.none";
			else if (!g_enabled)
				state = ".hwp.specs.off";
			else if (g_inTown)
				state = ".hwp.specs.town";
			else
				state = ".hwp.specs.pending";
			HWP::Commands::Reply(Resources::GetString(".hwp.specs.status", {
				{ "mine", mine.isEmpty() ? "-" : SpecName(mine) }, { "active", Resources::GetString(state) } }));
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
