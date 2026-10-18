// Extra materials in the character menu's materials tab (gui/playermenu/
// character.gui): a "Supplies" row under the run and town rows for things a
// module keeps per character (fishing bait). Each cell is a hwp-material
// widget inside the hwp-materials section, filled by the provider a module
// registers under the cell's id; a cell without a provider (its module is off)
// is hidden, and the whole row with them.
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
// "count" text child
class HWPMaterialWidget : SpriteWidget
{
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

	// called by the section, also while this cell is hidden
	bool Refresh()
	{
		@m_material = HWP::Materials::Get(m_id);
		m_visible = m_material !is null;
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
		SpriteWidget::DoDraw(sb, pos);
		if (m_icon !is null)
			m_icon.Draw(sb, pos + vec2(int((m_width - m_icon.GetWidth()) / 2), 3), int(g_menuTime), vec4(1.0f));
	}
}

// the row: its children are the "Supplies" header and the cells. It hides
// the header when no cell has a provider and sets the materials tab's height
// (the row doesn't fit the tab's four bag rows of room, so it scrolls in).
class HWPMaterialsWidget : GroupWidget
{
	int m_tabHeight = -1;

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

		bool any = false;
		for (uint i = 0; i < m_children.length(); i++)
		{
			auto cell = cast<HWPMaterialWidget>(m_children[i]);
			if (cell !is null && cell.Refresh())
				any = true;
		}
		for (uint i = 0; i < m_children.length(); i++)
		{
			if (cast<HWPMaterialWidget>(m_children[i]) is null)
				m_children[i].m_visible = any;
		}
		if (m_parent !is null)
		{
			int h = any ? int(m_offset.y + m_parent.m_padding.y) + m_height : m_tabHeight;
			if (m_parent.m_height != h)
				m_parent.m_height = h;
			// Character.as turns the scrollbar off on the materials tab
			auto sb = cast<ScrollbarWidget>(m_parent.m_parent);
			if (sb !is null)
				sb.m_enabled = h > sb.m_height;
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
