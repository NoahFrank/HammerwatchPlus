// Death recap: a ring buffer of the damage the local player took (filled by the
// PlayerDamageTaken hook, which fires after mitigation), summarised when the
// PlayerDied event fires for the local player. The summary is shown in a HUD
// panel while dead, kept in the player record ("deathrecap.last") and announced
// to the party through the host.
namespace HWP
{
	namespace DeathRecap
	{
		const string ANNOUNCE = "deathrecap.announce"; // client -> host
		const string SHOW = "deathrecap.show";         // host -> all
		const string KEY_LAST = "deathrecap.last";
		const int WINDOW_MS = 10000;
		const int MAX_HITS = 128;
		const int TOP = 5;

		class Hit
		{
			uint time;
			string source;
			int amount;
			int physical;
			int elemental;
		}

		array<Hit@> g_hits;
		HWPDeathRecapHUD@ g_hud;
		string g_lastSummary;

		// "actors/undead/lich_king_2.unit" -> "Lich King 2"
		string Prettify(const string &in path)
		{
			string name = path;
			int slash = name.findLast("/");
			if (slash >= 0)
				name = name.substr(slash + 1);
			int dot = name.findFirst(".");
			if (dot >= 0)
				name = name.substr(0, dot);

			string result;
			bool up = true;
			for (uint i = 0; i < name.length(); i++)
			{
				auto ch = name.substr(i, 1);
				if (ch == "_" || ch == "-")
				{
					result += " ";
					up = true;
					continue;
				}
				result += up ? ch.toUpper() : ch;
				up = false;
			}
			return result;
		}

		string SourceName(Actor@ attacker)
		{
			if (attacker is null)
				return Resources::GetString(".hwp.deathrecap.environment");

			auto pb = cast<PlayerBase>(attacker);
			if (pb !is null && pb.m_record !is null)
				return pb.m_record.GetName();

			if (!attacker.m_unit.IsValid())
				return Resources::GetString(".hwp.deathrecap.unknown");
			auto prod = attacker.m_unit.GetUnitProducer();
			if (prod is null)
				return Resources::GetString(".hwp.deathrecap.unknown");
			return Prettify(prod.GetResourceName());
		}

		void Record(PlayerBase@ player, DamageInfo@ dmg)
		{
			if (player is null || dmg is null || player.m_record is null || !player.m_record.local)
				return;

			int amount = dmg.DamageDealt > 0 ? dmg.DamageDealt : dmg.Damage;
			if (amount <= 0)
				return;

			Hit h;
			h.time = g_scene.GetTime();
			h.source = SourceName(dmg.Attacker);
			h.amount = amount;
			// the split only says which kind dominated; totals are post-mitigation
			int rawPhys = int(dmg.PhysicalDamage);
			int rawElem = int(dmg.FireDamage + dmg.IceDamage + dmg.LightningDamage + dmg.PoisonDamage + dmg.PureDamage);
			if (rawPhys + rawElem > 0)
			{
				h.physical = int(float(amount) * float(rawPhys) / float(rawPhys + rawElem) + 0.5f);
				h.elemental = amount - h.physical;
			}
			else
			{
				h.physical = amount;
				h.elemental = 0;
			}
			g_hits.insertLast(h);

			Trim(h.time);
		}

		void Trim(uint now)
		{
			while (g_hits.length() > 0 && (now - g_hits[0].time) > uint(WINDOW_MS))
				g_hits.removeAt(0);
			while (g_hits.length() > uint(MAX_HITS))
				g_hits.removeAt(0);
		}

		class Source
		{
			string name;
			int amount;
		}

		// Aggregates the window into sorted sources; returns the total.
		int Aggregate(array<Source@>& result, int &out physical, int &out elemental)
		{
			Trim(g_scene.GetTime());
			int total = 0;
			physical = 0;
			elemental = 0;
			for (uint i = 0; i < g_hits.length(); i++)
			{
				auto h = g_hits[i];
				total += h.amount;
				physical += h.physical;
				elemental += h.elemental;

				bool found = false;
				for (uint j = 0; j < result.length(); j++)
				{
					if (result[j].name == h.source)
					{
						result[j].amount += h.amount;
						found = true;
						break;
					}
				}
				if (!found)
				{
					Source s;
					s.name = h.source;
					s.amount = h.amount;
					result.insertLast(s);
				}
			}

			// selection sort, descending; the list is tiny
			for (uint i = 0; i + 1 < result.length(); i++)
			{
				uint best = i;
				for (uint j = i + 1; j < result.length(); j++)
					if (result[j].amount > result[best].amount)
						best = j;
				if (best != i)
				{
					auto tmp = result[i];
					@result[i] = result[best];
					@result[best] = tmp;
				}
			}
			return total;
		}

		int Percent(int part, int total)
		{
			if (total <= 0)
				return 0;
			return int(float(part) * 100.0f / float(total) + 0.5f);
		}

		void OnLocalPlayerDied(PlayerBase@ player)
		{
			array<Source@> sources;
			int physical, elemental;
			int total = Aggregate(sources, physical, elemental);

			array<string> lines;
			string summary;
			for (uint i = 0; i < sources.length() && i < uint(TOP); i++)
			{
				auto s = sources[i];
				lines.insertLast(s.name + "  " + formatThousands(s.amount) + "  (" + Percent(s.amount, total) + "%)");
				if (i < 3)
					summary += (i > 0 ? ", " : "") + s.name + " " + Percent(s.amount, total) + "%";
			}

			string totalText;
			if (total > 0)
				totalText = Resources::GetString(".hwp.deathrecap.total", {
					{ "total", formatThousands(total) }, { "seconds", "" + (WINDOW_MS / 1000) },
					{ "phys", "" + Percent(physical, total) }, { "elem", "" + Percent(elemental, total) } });
			else
				totalText = Resources::GetString(".hwp.deathrecap.none", { { "seconds", "" + (WINDOW_MS / 1000) } });

			if (summary.isEmpty())
				summary = Resources::GetString(".hwp.deathrecap.unknown");
			g_lastSummary = summary;
			HWP::SaveData::Local().SetString(KEY_LAST, summary + " | " + totalText);
			HWP::Log("deathrecap", player.m_record.GetName() + " died: " + summary + " | " + totalText);

			if (g_hud !is null)
				g_hud.Show(lines, totalText);

			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("peer", player.m_record.peer);
			b.PushString("name", player.m_record.GetName());
			b.PushString("sources", summary);
			b.PopDictionary();
			HWP::Net::Request(ANNOUNCE, b.Build());

			g_hits.removeRange(0, g_hits.length());
		}

		void OnAnnounce(uint8 peer, SValue@ data)
		{
			HWP::Net::Broadcast(SHOW, data.Copy()); // the request's data is not ours to hand on
		}

		void OnShow(SValue@ data)
		{
			if (!HWP::Settings::GetBool("deathrecap.chat", true))
				return;
			auto name = HWP::SV::Str(data, "name");
			auto sources = HWP::SV::Str(data, "sources");
			if (name.isEmpty() || sources.isEmpty())
				return;
			int peer = HWP::SV::Int(data, "peer", 0);

			SValueBuilder b;
			b.PushString("\\c" + GetPlayerColor(peer) + name + "\\d "
				+ Resources::GetString(".hwp.deathrecap.chat", { { "sources", sources } }));
			SendSystemMessage("AddChat", b.Build());
		}

		void CmdRecap(array<string>@ args)
		{
			auto last = HWP::SaveData::Local().GetString(KEY_LAST, "");
			if (last.isEmpty())
				HWP::Commands::Reply(Resources::GetString(".hwp.deathrecap.none", { { "seconds", "" + (WINDOW_MS / 1000) } }));
			else
				HWP::Commands::Reply(Resources::GetString(".hwp.deathrecap.last", { { "sources", last } }));
		}
	}
}

class HWPDeathRecapHUD : HUDComponent
{
	array<TextWidget@> m_lines;
	TextWidget@ m_total;
	TextWidget@ m_toggle;
	Widget@ m_panel;
	int m_sinceShow = 0;
	bool m_collapsed = false;
	bool m_hover = false;
	HUD@ m_hud;
	float m_y = 4;

	// top middle, moved down below the boss bar while one is up
	void Place()
	{
		bool boss = false;
		for (uint i = 0; m_hud !is null && i < m_hud.m_components.length(); i++)
		{
			auto bar = cast<HUDBossBar>(m_hud.m_components[i]);
			if (bar !is null && bar.m_mainFrame !is null && bar.m_mainFrame.m_visible)
				boss = true;
		}
		float y = boss ? 40 : 4;
		if (y != m_y)
		{
			m_y = y;
			m_widget.GetWidgetById("root").m_offset = vec2(0, y);
			Invalidate();
		}
	}

	// HUD components get no mouse input of their own, so the title row is a
	// hand-rolled button: a click (menu Forward) with the cursor over it
	// collapses / expands the panel. The choice is kept in the settings.
	HWPDeathRecapHUD(GUIBuilder@ b)
	{
		super(b, "gui/hwp_deathrecap.gui");
		for (int i = 0; i < HWP::DeathRecap::TOP; i++)
			m_lines.insertLast(cast<TextWidget>(m_widget.GetWidgetById("line" + i)));
		@m_total = cast<TextWidget>(m_widget.GetWidgetById("total"));
		@m_toggle = cast<TextWidget>(m_widget.GetWidgetById("toggle"));
		@m_panel = m_widget.GetWidgetById("panel");
		m_visible = false;
		m_drawOnTop = true;
	}

	void Show(array<string>@ lines, const string &in total)
	{
		for (uint i = 0; i < m_lines.length(); i++)
			m_lines[i].SetText(i < lines.length() ? lines[i] : "");
		m_total.SetText(total);
		SetCollapsed(HWP::Settings::GetBool("deathrecap.collapsed", false));
		m_visible = true;
		m_sinceShow = 0;
	}

	void SetCollapsed(bool collapsed)
	{
		m_collapsed = collapsed;
		for (uint i = 0; i < m_lines.length(); i++)
			m_lines[i].m_visible = !collapsed;
		m_toggle.SetText(collapsed ? "[+]" : "[-]");
		m_panel.m_height = collapsed ? 34 : 116;   // collapsed still shows the total line
		Invalidate();
	}

	bool OverTitle()
	{
		vec2 mouse = GetGameModeMousePosition() / g_gameMode.m_wndScale;
		vec2 o = m_panel.m_origin;
		return mouse.x >= o.x && mouse.x < o.x + m_panel.m_width && mouse.y >= o.y && mouse.y < o.y + 20;
	}

	void Update(int dt, PlayerRecord@ record) override
	{
		// Stays up while dead, goes away on revive / back in town. The show
		// happens from PlayerDied, which fires before the record's deadTime and
		// actor are updated, so the hide test looks at "alive again" (deadTime
		// reset by the revive) and only after a grace period, never at IsDead().
		m_sinceShow += dt;
		if (m_visible && m_sinceShow > 1000 && (record is null || record.deadTime == 0))
			m_visible = false;

		if (m_visible)
		{
			Place();
			bool hover = OverTitle();
			if (hover != m_hover)
			{
				m_hover = hover;
				m_toggle.SetColor(ParseColorRGBA(hover ? "#ffffffff" : "#c0c0c0ff"));
			}
			if (hover && GetMenuInput().Forward.Pressed)
			{
				SetCollapsed(!m_collapsed);
				HWP::Settings::SetBool("deathrecap.collapsed", m_collapsed);
			}
		}
		HUDComponent::Update(dt, record);
	}
}

namespace HWPDeathRecap
{
	[Hook]
	void PlayerDamageTaken(Player@ player, DamageInfo@ dmg)
	{
		HWP::DeathRecap::Record(player, dmg);
	}

	[Hook]
	void HUDConstructor(HUD@ hud, GUIBuilder@ b)
	{
		auto comp = HWPDeathRecapHUD(b);
		@comp.m_hud = hud;
		hud.m_components.insertLast(comp);
		@HWP::DeathRecap::g_hud = comp;
	}
}

namespace Modules
{
	class HWPDeathRecapModule : Module, HWP::ModuleStart, IEventPlayerDied
	{
		HWPDeathRecapModule()
		{
			super("hwp-deathrecap");
			GameEvents::Subscribe(this);
			HWP::Net::OnRequest(HWP::DeathRecap::ANNOUNCE, HWP::Net::RequestHandler(HWP::DeathRecap::OnAnnounce));
			HWP::Net::OnEvent(HWP::DeathRecap::SHOW, HWP::Net::EventHandler(HWP::DeathRecap::OnShow));
			HWP::Commands::Register("recap", " show your last death recap", HWP::Commands::Handler(HWP::DeathRecap::CmdRecap));
		}

		void OnEventPlayerDied(PlayerBase@ player)
		{
			if (player is null || player.m_record is null || !player.m_record.local)
				return;
			HWP::DeathRecap::OnLocalPlayerDied(player);
		}

		void Start(StartMode sMode)
		{
			HWP::DeathRecap::g_hits.removeRange(0, HWP::DeathRecap::g_hits.length());
		}
	}
}
