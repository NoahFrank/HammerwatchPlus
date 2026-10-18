// Extra materials in the character menu's materials tab (gui/playermenu/
// character.gui): a "Supplies" section under the run and town rows for things
// a module keeps per character (fishing bait, farm seeds). Each cell is a
// hwp-material widget in the section's wrapping grid, filled by the provider a
// module registers under the cell's id; a cell without a provider (its module
// is off) is hidden and the grid closes the gap, and without any the whole
// section hides. Hovering a cell shows the provider's Title() / Text().
//
// Providers register in their module ctor (script globals reset every level).
// Counts are read every frame while the tab is open, so no change calls.
namespace HWP
{
	namespace Materials
	{
		class Material
		{
			// 13x13, like the vanilla material icons
			ScriptSprite@ Icon() { return null; }
			int Count() { return 0; }
			// the hover tooltip
			string Title() { return ""; }
			string Text() { return ""; }
		}

		dictionary g_materials;

		void Register(const string &in id, Material@ material)
		{
			g_materials.set(id, @material);
		}

		Material@ Get(const string &in id)
		{
			Material@ material;
			if (g_materials.get(id, @material))
				return material;
			return null;
		}
	}
}

// one cell: the material background sprite, the provider's icon, and a
// "count" text child. Interactable (mouse only) for its tooltip; it has to be
// visible when the menu collects its interactables, so the gui leaves it
// visible and Refresh hides it once it knows there is no provider.
class HWPMaterialWidget : AInteractableWidget
{
	Sprite@ m_background;
	HWP::Materials::Material@ m_material;
	ScriptSprite@ m_icon;
	TextWidget@ m_count;
	int m_shown = -1;

	HWPMaterialWidget()
	{
		super();
	}

	Widget@ Clone() override
	{
		HWPMaterialWidget@ w = HWPMaterialWidget();
		CloneInto(w);
		return w;
	}

	void Load(WidgetLoadingContext &ctx) override
	{
		AInteractableWidget::Load(ctx);
		string src = ctx.GetString("src", false);
		if (src != "")
			@m_background = ctx.GetGUIDef().GetSprite(src);
	}

	// called by the section, also while this cell is hidden
	bool Refresh()
	{
		@m_material = HWP::Materials::Get(m_id);
		bool show = m_material !is null;
		if (m_visible != show)
			m_visible = show;
		if (m_material is null)
			return false;
		if (m_icon is null)
			@m_icon = m_material.Icon();
		if (m_count is null)
			@m_count = cast<TextWidget>(GetWidgetById("count"));
		int n = m_material.Count();
		if (m_count !is null && n != m_shown)
		{
			m_shown = n;
			m_count.SetText("" + n);
		}
		return true;
	}

	void DoDraw(SpriteBatch& sb, vec2 pos) override
	{
		if (m_background !is null)
			sb.DrawSprite(pos, m_background, g_menuTime, vec4(1.0f));
		if (m_icon !is null)
			m_icon.Draw(sb, pos + vec2(int((m_width - m_icon.GetWidth()) / 2), 3), int(g_menuTime), vec4(1.0f));
	}

	void ShowTooltip() override
	{
		auto gm = cast<BaseGameMode>(g_gameMode);
		if (gm is null)
			return;
		if (m_material is null || m_material.Title() == "")
		{
			gm.m_windowManager.CloseTooltip();
			return;
		}
		gm.m_windowManager.SetTooltip(CreateTooltip(Resources::GetSValue("gui/variable/itemtooltip_common.sval"), m_material.Title(), m_material.Text()), true);
	}

	void Hover() override
	{
		ShowTooltip();
		AInteractableWidget::Hover();
	}

	void Leave() override
	{
		auto gm = cast<BaseGameMode>(g_gameMode);
		if (gm !is null)
			gm.m_windowManager.CloseTooltip();
		AInteractableWidget::Leave();
	}
}

// the section: the "Supplies" header and a "cells" group (flow hboxwrapped)
// with the hwp-material cells. It hides the header when no cell has a
// provider, sizes the grid to its rows and sets the materials tab's height
// (the section doesn't fit the tab's four bag rows of room, so it scrolls in).
class HWPMaterialsWidget : GroupWidget
{
	int m_tabHeight = -1;
	Widget@ m_cells;
	int m_gridTop = -1;

	HWPMaterialsWidget()
	{
		super();
	}

	Widget@ Clone() override
	{
		HWPMaterialsWidget@ w = HWPMaterialsWidget();
		CloneInto(w);
		return w;
	}

	void Update(int dt) override
	{
		if (m_parent !is null && m_tabHeight < 0)
			m_tabHeight = m_parent.m_height;
		if (m_cells is null)
		{
			@m_cells = GetWidgetById("cells");
			if (m_cells !is null)
				m_gridTop = int(m_cells.m_offset.y);
		}

		int shown = 0;
		int cellW = 0;
		int cellH = 0;
		if (m_cells !is null)
		{
			for (uint i = 0; i < m_cells.m_children.length(); i++)
			{
				auto cell = cast<HWPMaterialWidget>(m_cells.m_children[i]);
				if (cell !is null && cell.Refresh())
				{
					shown++;
					cellW = cell.m_width;
					cellH = cell.m_height;
				}
			}
		}
		bool any = shown > 0;
		for (uint i = 0; i < m_children.length(); i++)
		{
			if (m_children[i] !is m_cells && m_children[i].m_visible != any)
				m_children[i].m_visible = any;
		}

		int h = m_height;
		if (any && m_cells !is null)
		{
			int step = max(1, cellW + m_cells.m_spacing);
			int perRow = max(1, (m_cells.m_width - cellW) / step + 1);
			int rows = (shown + perRow - 1) / perRow;
			int gridH = rows * cellH + (rows - 1) * m_cells.m_spacingLine;
			if (m_cells.m_height != gridH)
				m_cells.m_height = gridH;
			h = m_gridTop + gridH;
			if (m_height != h)
				m_height = h;
		}
		if (m_parent !is null)
		{
			int tab = any ? int(m_offset.y + m_parent.m_padding.y) + h : m_tabHeight;
			if (m_parent.m_height != tab)
				m_parent.m_height = tab;
			// Character.as turns the scrollbar off on the materials tab
			auto sb = cast<ScrollbarWidget>(m_parent.m_parent);
			if (sb !is null)
				sb.m_enabled = tab > sb.m_height;
		}
		GroupWidget::Update(dt);
	}
}

ref@ LoadHWPMaterialWidget(WidgetLoadingContext &ctx)
{
	HWPMaterialWidget@ w = HWPMaterialWidget();
	w.Load(ctx);
	return w;
}

ref@ LoadHWPMaterialsWidget(WidgetLoadingContext &ctx)
{
	HWPMaterialsWidget@ w = HWPMaterialsWidget();
	w.Load(ctx);
	return w;
}

namespace HWPMaterials
{
	[Hook]
	void LoadWidgetProducers(GUIBuilder@ builder)
	{
		builder.AddWidgetProducer("hwp-material", LoadHWPMaterialWidget);
		builder.AddWidgetProducer("hwp-materials", LoadHWPMaterialsWidget);
	}
}
