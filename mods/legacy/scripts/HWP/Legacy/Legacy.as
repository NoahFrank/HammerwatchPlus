// Title Bonuses: HoH1's class titles on top of HoH2's hero titles. HoH2
// already gives every character a bonus from the highest-level hero of each
// class (TownRecord.m_heroTitles, scaled by that hero's level, plus the chapel
// donation titles); this module only presents it the HoH1 way:
//  - one "Title Bonuses" buff icon whose description (tooltip with bufftips,
//    and the character menu's Effects tab) lists every bonus. The buff has no
//    modifiers of its own, is added locally (husk, not networked) and has its
//    timer reset every tick so it never runs out.
//  - Guild Hall (G) > Titles lists every class, also those you have no hero
//    for yet (with what their title would give), like HoH1's guild hall did.
//    The vanilla tab only lists classes you have a hero of; it is rebuilt in
//    place when the Guild Hall opens, so no base file is overridden.
// Setting: legacy.enabled (the buff). Command: hwp legacy.
namespace HWP
{
	namespace Legacy
	{
		const string BUFF = "tweak/hwp/buffs_legacy.sval:hwp_legacy";
		const int TICK_MS = 500;

		ActorBuffDef@ g_def;
		GuildHallHeroTitlesTab@ g_doneTab;

		// the stat icon (gui/icons.inc) each class's title is about, shown for
		// the classes without a hero; unknown titles get no icon
		string Icon(HeroTitle@ t)
		{
			uint id = t.m_idHash;
			if (id == HashString("title_ranger")) return "icon-attack-power";
			if (id == HashString("title_wizard")) return "icon-spell-power";
			if (id == HashString("title_warrior")) return "icon-health";
			if (id == HashString("title_sorcerer")) return "icon-manaregen";
			if (id == HashString("title_paladin")) return "icon-armor";
			if (id == HashString("title_warlock")) return "icon-resistance-fire";
			if (id == HashString("title_rogue")) return "icon-evasion";
			if (id == HashString("title_priest")) return "icon-healthregen";
			if (id == HashString("title_hwp_thief")) return "icon-gold";
			if (id == HashString("title_hwp_gladiator")) return "icon-attack-crit-dmg";
			if (id == HashString("title_hwp_witch_hunter")) return "icon-spell-crit-dmg";
			if (id == HashString("title_hwp_firearms")) return "icon-attack-crit-chance";
			return "";
		}

		string Num(float v)
		{
			int whole = int(v >= 0 ? v + 0.5f : v - 0.5f);
			if (abs(v - float(whole)) < 0.005f)
				return "" + whole;
			string s = formatFloat(v, "", 0, 2);
			while (s.length() > 1 && s.substr(s.length() - 1) == "0")
				s = s.substr(0, s.length() - 1);
			return s;
		}

		// the number a title's description shows at that level, the way the
		// Guild Hall computes it
		float Value(HeroTitle@ t, int lvl)
		{
			if (t.m_descNumDivisor != 0)
				return (1.0f - float(t.m_descNumDivisor) / float(t.m_descNumDivisor + lvl)) * 100.0f;
			if (t.m_descExpBase != 1.0f)
				return (1.0f - pow(t.m_descExpBase, lvl)) * 100.0f;
			return t.m_descNumPerLevel * lvl;
		}

		string Desc(HeroTitle@ t, int lvl)
		{
			return Resources::GetString(t.m_description, { { "num", Num(Value(t, lvl)) }, { "num-per", Num(t.m_descNumPerLevel) } });
		}

		// one base class per hero title (sub-classes such as the HoH1
		// Priest/Paladin masteries share their parent's title)
		array<PlayerClass@> Classes()
		{
			array<PlayerClass@> ret;
			array<HeroTitle@> seen;
			for (uint i = 0; i < PlayerClass::Instances.length(); i++)
			{
				auto cls = PlayerClass::Instances[i];
				if (cls.parent != 0 || cls.m_title is null || seen.findByRef(cls.m_title) >= 0)
					continue;
				seen.insertLast(cls.m_title);
				ret.insertLast(cls);
			}
			return ret;
		}

		ActiveHeroTitle@ Active(HeroTitle@ t)
		{
			if (g_myTownRecord is null)
				return null;
			for (uint i = 0; i < g_myTownRecord.m_heroTitles.length(); i++)
				if (g_myTownRecord.m_heroTitles[i].m_title is t)
					return g_myTownRecord.m_heroTitles[i];
			return null;
		}

		array<ActiveHeroTitle@> BestFirst()
		{
			array<ActiveHeroTitle@> titles = g_myTownRecord.m_heroTitles;
			if (titles.length() > 0)
				titles.sort(function(a, b) { return a.m_level > b.m_level; });
			return titles;
		}

		// The bonus alone: "Grants 60 Spell Power, 3 per level." -> "+60 Spell Power".
		// Every hero title description has that shape; anything else is kept whole.
		string Short(const string &in desc)
		{
			string s = desc;
			int comma = s.findLast(", ");
			if (comma > 0 && s.findFirst("per level", comma) > 0)
				s = s.substr(0, comma);
			if (s.findFirst("Grants ") == 0)
				s = "+" + s.substr(7);
			if (s.length() > 0 && s.substr(s.length() - 1) == ".")
				s = s.substr(0, s.length() - 1);
			return s;
		}

		// the buff tooltip / Effects tab: one bonus per line, best hero first,
		// then the donation titles
		array<string> Bonuses()
		{
			array<string> ret;
			if (g_myTownRecord is null)
				return ret;

			auto titles = BestFirst();
			for (uint i = 0; i < titles.length(); i++)
			{
				auto t = titles[i].m_title;
				if (t !is null && !t.m_name.isEmpty())
					ret.insertLast(Short(Desc(t, titles[i].m_level)));
			}
			for (uint i = 0; i < g_myTownRecord.m_donationTitles.length(); i++)
			{
				auto d = g_myTownRecord.m_donationTitles[i];
				if (d.m_title !is null && d.m_level > 0)
					ret.insertLast(Short(Desc(d.m_title, d.m_level)));
			}
			return ret;
		}

		// "Wizard (level 20): Grants 60 Spell Power, 3 per level." per active
		// title, for `hwp legacy`
		array<string> Lines()
		{
			array<string> ret;
			if (g_myTownRecord is null)
				return ret;

			auto titles = BestFirst();
			for (uint i = 0; i < titles.length(); i++)
			{
				auto t = titles[i].m_title;
				if (t is null || t.m_name.isEmpty())
					continue;
				ret.insertLast(Resources::GetString(".hwp.legacy.line", {
					{ "class", t.m_name }, { "lvl", "" + titles[i].m_level }, { "desc", Desc(t, titles[i].m_level) } }));
			}
			for (uint i = 0; i < g_myTownRecord.m_donationTitles.length(); i++)
			{
				auto d = g_myTownRecord.m_donationTitles[i];
				if (d.m_title is null || d.m_level <= 0)
					continue;
				ret.insertLast(Resources::GetString(".hwp.legacy.donation", {
					{ "name", d.m_title.m_name }, { "desc", Desc(d.m_title, d.m_level) } }));
			}
			return ret;
		}

		string Description()
		{
			auto lines = Bonuses();
			if (lines.length() == 0)
				return "";
			return join(lines, "\n");
		}

		ActorBuff@ Find(PlayerBase@ pb)
		{
			auto buffs = pb.m_buffs.m_buffs;
			for (uint i = 0; i < buffs.length(); i++)
				if (buffs[i].m_def is g_def)
					return buffs[i];
			return null;
		}

		// Hides every Title Bonuses icon on the HUD except keep's. The HUD matches
		// icons to buff objects, and a town upgrade (or anything else that
		// respawns the player) drops the old actor without clearing its buffs,
		// so its icon would stay forever next to the new actor's. With this the
		// HUD never shows more than one.
		void PruneHUD(ActorBuff@ keep)
		{
			auto hud = GetHUD();
			if (hud is null)
				return;
			for (uint c = 0; c < hud.m_components.length(); c++)
			{
				auto comp = cast<HUDBuffs>(hud.m_components[c]);
				if (comp is null || comp.m_wBuffList is null)
					continue;
				bool kept = false;
				auto list = comp.m_wBuffList.m_children;
				for (uint i = 0; i < list.length(); i++)
				{
					auto w = cast<BuffWidget>(list[i]);
					if (w is null || !w.m_visible)
						continue;
					auto b = cast<ActorBuff>(w.m_buff);
					if (b is null || b.m_def !is g_def)
						continue;
					if (b is keep && !kept)
					{
						kept = true;
						continue;
					}
					// HUDBuffs.Update removes hidden icons
					w.m_visible = false;
					@w.m_buff = null;
				}
			}
		}

		void Tick()
		{
			if (g_def is null)
				return;
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.IsDead())
				return;
			auto pb = cast<PlayerBase>(rec.actor);
			if (pb is null)
				return;

			auto buff = Find(pb);
			string desc = HWP::Settings::GetBool("legacy.enabled", true) ? Description() : "";
			if (desc.isEmpty())
			{
				if (buff !is null)
					buff.m_duration = 0;
				PruneHUD(null);
				return;
			}

			g_def.m_description = desc;
			if (buff is null)
			{
				@buff = ActorBuff(pb, g_def, 1.0f, true);
				pb.m_buffs.Add(buff);
			}
			else
				buff.m_duration = g_def.m_duration;
			PruneHUD(buff);
		}

		// Guild Hall > Titles, HoH1 style: heroes (best first, as vanilla
		// shows them), then every class without a hero, then the donations
		void Rebuild(GuildHallHeroTitlesTab@ tab)
		{
			tab.Clear();

			auto titles = BestFirst();
			for (uint i = 0; i < titles.length(); i++)
			{
				auto active = titles[i];
				SValue@ plrData = PersistentSaves::GetCharacter(active.m_uniqueKey);
				if (plrData is null)
					continue;
				PlayerRecord plrRecord;
				plrRecord.Load(plrData, StartMode::StartGame);
				if (plrRecord.playerClass is null)
					continue;

				auto entry = tab.m_heroEntryTemplate.Clone();
				entry.m_id = "";
				entry.m_visible = true;
				string charName = plrRecord.name;
				if (!charName.isEmpty())
					charName += " - ";
				cast<TextWidget>(entry.GetWidgetById("name")).SetText(charName + active.m_title.m_name);
				cast<TextWidget>(entry.GetWidgetById("desc")).SetText(Resources::GetString(".htitle.format", {
					{ "lvl", "" + active.m_level }, { "desc", Desc(active.m_title, active.m_level) } }));

				auto portraitW = cast<PortraitWidget>(entry.GetWidgetById("portrait"));
				if (portraitW !is null)
				{
					array<PlayerColors@> col;
					PlayerColors::GetPlayerColors(col, plrRecord);
					portraitW.SetPortrait(plrRecord.portrait);
					portraitW.SetColors(col);
				}
				tab.m_listHeroTitles.AddChild(entry);
			}

			auto classes = Classes();
			vec4 grey(0.6f, 0.6f, 0.6f, 1.0f);
			for (uint i = 0; i < classes.length(); i++)
			{
				auto t = classes[i].m_title;
				if (Active(t) !is null)
					continue;

				auto entry = tab.m_materialEntryTemplate.Clone();
				entry.m_id = "";
				entry.m_visible = true;
				auto nameW = cast<TextWidget>(entry.GetWidgetById("name"));
				auto descW = cast<TextWidget>(entry.GetWidgetById("desc"));
				nameW.SetText(t.m_name);
				descW.SetText(Resources::GetString(".hwp.legacy.nohero", {
					{ "lvl", "" + Tweak::LevelCap }, { "desc", Desc(t, Tweak::LevelCap) } }));
				nameW.SetColor(grey);
				descW.SetColor(grey);
				auto iconW = cast<SpriteWidget>(entry.GetWidgetById("icon"));
				string icon = Icon(t);
				if (iconW !is null)
				{
					if (icon.isEmpty())
						iconW.m_visible = false;
					else
						iconW.SetSprite(tab.m_def.GetSprite(icon));
				}
				tab.m_listHeroTitles.AddChild(entry);
			}

			tab.AddDonationTitle(HeroTitle::Get("title_mat_gold"), "gold");
			tab.AddDonationTitle(HeroTitle::Get("title_mat_wood"), "wood");
			tab.AddDonationTitle(HeroTitle::Get("title_mat_stone"), "stone");
			tab.AddDonationTitle(HeroTitle::Get("title_mat_iron"), "iron");
		}

		void WatchGuildHall()
		{
			auto gm = cast<BaseGameMode>(g_gameMode);
			if (gm is null || gm.m_windowManager is null || g_myTownRecord is null)
				return;
			for (uint i = 0; i < gm.m_windowManager.m_objects.length(); i++)
			{
				auto hall = cast<GuildHall>(gm.m_windowManager.m_objects[i]);
				if (hall is null || hall.m_tabSystem is null)
					continue;
				for (uint t = 0; t < hall.m_tabSystem.m_tabs.length(); t++)
				{
					auto tab = cast<GuildHallHeroTitlesTab>(hall.m_tabSystem.m_tabs[t]);
					if (tab is null || tab is g_doneTab)
						continue;
					@g_doneTab = tab;
					Rebuild(tab);
					hall.Invalidate();
				}
			}
		}

		void CmdLegacy(array<string>@ args)
		{
			HWP::Commands::Reply(Resources::GetString(".hwp.legacy.header"));
			auto lines = Lines();
			for (uint i = 0; i < lines.length(); i++)
				HWP::Commands::Reply(lines[i]);
			auto classes = Classes();
			for (uint i = 0; i < classes.length(); i++)
				if (Active(classes[i].m_title) is null)
					HWP::Commands::Reply(Resources::GetString(".hwp.legacy.cmd.missing", { { "class", classes[i].m_title.m_name } }));
		}
	}
}

namespace Modules
{
	class HWPLegacyModule : Module, HWP::ModuleStart
	{
		int m_timer = 0;

		HWPLegacyModule()
		{
			super("hwp-legacy");
			@HWP::Legacy::g_def = LoadActorBuff(HWP::Legacy::BUFF);
			HWP::Commands::Register("legacy", " list the Title Bonuses of every class", HWP::Commands::Handler(HWP::Legacy::CmdLegacy));
			HWP::Log("legacy", "ready: " + HWP::Legacy::Classes().length() + " classes with a hero title"
				+ (HWP::Legacy::g_def is null ? ", BUFF MISSING" : ""));
			// how GetString treats plain text (the Effects tab passes the buff's
			// description through it)
			HWP::Log("legacy", "getstring check: [" + Resources::GetString("Plain 20% text") + "] [" + Resources::GetString("Plain 20%% text") + "]");
		}

		void Start(StartMode sMode)
		{
			HWP::Settings::Sync("legacy.");
			HWP::Settings::LocalOnly("legacy.enabled"); // your own Title Bonuses on/off
			@HWP::Legacy::g_doneTab = null;
			m_timer = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			HWP::Legacy::WatchGuildHall();
			if (paused)
				return;
			m_timer += ms;
			if (m_timer < HWP::Legacy::TICK_MS)
				return;
			m_timer = 0;
			HWP::Legacy::Tick();
		}
	}
}
