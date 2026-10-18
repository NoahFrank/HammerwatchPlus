// Interact class of doodads/hwp/laststats_board.unit and its window.
class HWPLastStatsBoard : AShopContent
{
	HWPLastStatsBoard() {}
	HWPLastStatsBoard(UnitPtr u, SValue& params)
	{
		super(u, params);
	}

	bool CanInteract(PlayerRecord@ player) override { return true; }

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPLastStatsMenu(guiBuilder, this);
		return m_window;
	}

	string GetName() override { return "hwp_laststats_board"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class HWPLastStatsMenu : AWindowObject
{
	int m_index;
	int m_rows;

	Widget@ m_statGroup;
	Widget@ m_empty;
	TextWidget@ m_player;
	TextWidget@ m_playerIndex;
	TextWidget@ m_subtitle;
	TextWidget@ m_categoryTemplate;
	Widget@ m_separatorTemplate;
	Widget@ m_valueTemplate;

	HWPLastStatsMenu(GUIBuilder@ b, HWPLastStatsBoard@ board)
	{
		super(b, "gui/hwp_laststats.gui");
		PauseGame(true, true);

		@m_statGroup = m_widget.GetWidgetById("stat-group");
		@m_empty = m_widget.GetWidgetById("empty");
		@m_player = cast<TextWidget>(m_widget.GetWidgetById("player"));
		@m_playerIndex = cast<TextWidget>(m_widget.GetWidgetById("player-index"));
		@m_subtitle = cast<TextWidget>(m_widget.GetWidgetById("subtitle"));
		@m_categoryTemplate = cast<TextWidget>(m_widget.GetWidgetById("stat-category-template"));
		@m_separatorTemplate = m_widget.GetWidgetById("stat-separator");
		@m_valueTemplate = m_widget.GetWidgetById("stat-value-template");

		// open on the local player's own run when it is known
		m_index = 0;
		auto local = GetLocalPlayerRecord();
		if (local !is null)
		{
			for (uint i = 0; i < HWP::LastStats::g_party.length(); i++)
			{
				if (HWP::SV::Str(HWP::LastStats::g_party[i], "player") == local.GetName())
				{
					m_index = int(i);
					break;
				}
			}
		}

		Refresh();
	}

	void Refresh()
	{
		m_statGroup.ClearChildren();
		m_rows = 0;

		auto@ party = HWP::LastStats::g_party;
		bool has = party.length() > 0;
		m_empty.m_visible = !has;
		if (!has)
		{
			m_player.SetText("");
			m_playerIndex.SetText("");
			m_subtitle.SetText("");
			return;
		}

		if (m_index < 0)
			m_index = int(party.length()) - 1;
		if (m_index >= int(party.length()))
			m_index = 0;

		auto snap = party[m_index];
		m_player.SetText(HWP::SV::Str(snap, "player"));
		m_playerIndex.SetText(Resources::GetString(".hwp.laststats.player_of", {
			{ "index", "" + (m_index + 1) }, { "count", "" + party.length() } }));
		m_subtitle.SetText(Resources::GetString(".hwp.laststats.subtitle", {
			{ "mission", HWP::SV::Str(snap, "mission") },
			{ "state", HWP::LastStats::StateName(HWP::SV::Int(snap, "state")) } }));

		auto linesV = HWP::SV::Field(snap, "lines");
		if (linesV is null)
			return;
		auto lines = linesV.GetArray();
		if (lines is null)
			return;

		string lastCat = "";
		for (uint i = 0; i < lines.length(); i++)
		{
			auto line = lines[i];
			auto cat = HWP::SV::Str(line, "cat");
			if (cat != lastCat)
			{
				AddCategory(cat);
				lastCat = cat;
			}
			AddValue(HWP::SV::Str(line, "title"), HWP::SV::Str(line, "text"));
		}
	}

	void AddCategory(const string &in cat)
	{
		if (m_statGroup.m_children.length() > 0)
		{
			auto sep = m_separatorTemplate.Clone();
			sep.m_visible = true;
			m_statGroup.AddChild(sep);
		}
		auto header = cast<TextWidget>(m_categoryTemplate.Clone());
		header.m_visible = true;
		string key = cat == "skill_dmg" ? ".hwp.laststats.category.skill_dmg" : ".menu.stats.cat." + cat;
		header.SetText(Resources::GetString(key));
		m_statGroup.AddChild(header);
		m_rows = 0;
	}

	void AddValue(const string &in title, const string &in text)
	{
		auto pair = m_valueTemplate.Clone();
		pair.SetID("");
		pair.m_visible = true;
		cast<TextWidget>(pair.GetWidgetById("stat-title")).SetText(title);
		cast<TextWidget>(pair.GetWidgetById("stat-text")).SetText(text);
		pair.GetWidgetById("stat-bg").m_visible = (m_rows % 2) == 1;
		m_rows++;
		m_statGroup.AddChild(pair);
	}

	void OnClose() override
	{
		PauseGame(false, true);
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
			m_manager.CloseWindow(this);
		else if (name == "prev")
		{
			m_index--;
			Refresh();
		}
		else if (name == "next")
		{
			m_index++;
			Refresh();
		}
	}
}
