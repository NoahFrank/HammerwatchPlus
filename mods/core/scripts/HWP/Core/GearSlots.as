// Extra gear slots in the character menu (gui/playermenu/character.gui): the
// fishing rod and watering can corners of the 3x3 gear grid and the other
// weapon set above the character. Each slot is a hwp-gear-slot widget whose
// contents come from a provider a module registers by the widget's id; a slot
// without a provider (its module is off) is hidden.
//
// Providers register in their module ctor (script globals reset every level)
// and call HWP::Gear::Changed() when what they show changes.
//
// hwp-gear-label widgets are text lines next to the slots (the alt weapon
// set's caption and swap key), filled the same way by a registered Label;
// without one they stay empty.
namespace HWP
{
	namespace Gear
	{
		class Slot
		{
			// an item to draw and tooltip like a worn one, or null
			Equipment::Equipment@ Item() { return null; }
			// draw the item flipped and darkened (a two-hander shown in the off-hand)
			bool Mirrored() { return false; }
			// drawn when Item() is null
			ScriptSprite@ Icon() { return null; }
			// darken the icon (nothing owned yet)
			bool Dim() { return false; }
			// tooltip when Item() is null
			string Title() { return ""; }
			string Text() { return ""; }
			array<string>@ Nav() { return {}; }
			void Click() {}
		}

		dictionary g_slots;
		int g_version = 0;

		void Register(const string &in id, Slot@ slot)
		{
			g_slots.set(id, @slot);
			g_version++;
		}

		Slot@ Get(const string &in id)
		{
			Slot@ slot;
			if (g_slots.get(id, @slot))
				return slot;
			return null;
		}

		void Changed() { g_version++; }

		class Label
		{
			string Text() { return ""; }
		}

		dictionary g_labels;

		void RegisterLabel(const string &in id, Label@ label)
		{
			g_labels.set(id, @label);
			g_version++;
		}

		Label@ GetLabel(const string &in id)
		{
			Label@ label;
			if (g_labels.get(id, @label))
				return label;
			return null;
		}
	}
}

class HWPGearSlotWidget : EquipmentItemWidget, IEquipmentWidgetHoster
{
	HWP::Gear::Slot@ m_slot;
	ScriptSprite@ m_icon;
	bool m_dim = false;
	int m_seen = -1;

	HWPGearSlotWidget()
	{
		super();
	}

	Widget@ Clone() override
	{
		HWPGearSlotWidget@ w = HWPGearSlotWidget();
		CloneInto(w);
		return w;
	}

	void Reload()
	{
		m_seen = HWP::Gear::g_version;
		@m_slot = HWP::Gear::Get(m_id);
		bool show = m_slot !is null;
		if (show != m_visible)
			m_visible = show;

		Clear();
		@m_icon = null;
		if (m_slot !is null)
		{
			auto item = m_slot.Item();
			bool mirrored = item !is null && m_slot.Mirrored();
			m_mirroredIcon = mirrored;
			m_color = mirrored ? m_disabledColor : vec4(0.75f, 0.75f, 0.75f, 1.0f);
			Set(item, this);
			@m_icon = m_slot.Icon();
			m_dim = m_slot.Dim();
		}
		Invalidate();
	}

	void Update(int dt) override
	{
		// providers call HWP::Gear::Changed() when what they show changes,
		// and a level load bumps it too (another character's data)
		if (m_seen != HWP::Gear::g_version)
			Reload();
		EquipmentItemWidget::Update(dt);
	}

	void DoDraw(SpriteBatch& sb, vec2 pos) override
	{
		EquipmentItemWidget::DoDraw(sb, pos);
		if (m_item is null && m_icon !is null)
		{
			vec2 at = pos + vec2(int((m_width - m_icon.GetWidth()) / 2), int((m_height - m_icon.GetHeight()) / 2));
			m_icon.Draw(sb, at, int(g_menuTime), m_dim ? vec4(0.35f, 0.35f, 0.35f, 1.0f) : vec4(1.0f));
		}
	}

	void ShowTooltip() override
	{
		auto gm = cast<BaseGameMode>(g_gameMode);
		if (gm is null)
			return;
		if (m_item !is null)
		{
			EquipmentItemWidget::ShowTooltip();
			return;
		}
		if (m_slot is null || m_slot.Title() == "")
		{
			gm.m_windowManager.CloseTooltip();
			return;
		}
		gm.m_windowManager.SetTooltip(CreateTooltip(Resources::GetSValue("gui/variable/itemtooltip_common.sval"), m_slot.Title(), m_slot.Text()), true);
	}

	array<string>@ NavigationBarText() override
	{
		if (m_slot is null)
			return {};
		return m_slot.Nav();
	}

	void OnClick(Equipment::Equipment@ item)
	{
		if (m_slot !is null)
		{
			m_slot.Click();
			HWP::Gear::Changed();
		}
	}
}

ref@ LoadHWPGearSlotWidget(WidgetLoadingContext &ctx)
{
	HWPGearSlotWidget@ w = HWPGearSlotWidget();
	w.Load(ctx);
	return w;
}

// stays visible (a hidden widget gets no Update), empty without a provider
class HWPGearLabelWidget : TextWidget
{
	int m_seen = -1;

	HWPGearLabelWidget()
	{
		super();
	}

	Widget@ Clone() override
	{
		HWPGearLabelWidget@ w = HWPGearLabelWidget();
		CloneInto(w);
		return w;
	}

	void Update(int dt) override
	{
		if (m_seen != HWP::Gear::g_version)
		{
			m_seen = HWP::Gear::g_version;
			auto label = HWP::Gear::GetLabel(m_id);
			SetText(label is null ? "" : label.Text());
		}
		TextWidget::Update(dt);
	}
}

ref@ LoadHWPGearLabelWidget(WidgetLoadingContext &ctx)
{
	HWPGearLabelWidget@ w = HWPGearLabelWidget();
	w.Load(ctx);
	return w;
}

namespace HWPGearSlots
{
	[Hook]
	void LoadWidgetProducers(GUIBuilder@ builder)
	{
		builder.AddWidgetProducer("hwp-gear-slot", LoadHWPGearSlotWidget);
		builder.AddWidgetProducer("hwp-gear-label", LoadHWPGearLabelWidget);
	}
}
