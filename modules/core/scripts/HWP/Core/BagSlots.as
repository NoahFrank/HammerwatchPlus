// HWP::Bag: bought inventory slots. Each character's equipment bag holds 24
// items (vanilla); every bought slot adds one, up to a full extra row of 8.
// The count lives in the character's HWP save data (bag.extra) and is put
// on the record's EquipmentInventory.m_maxItems after a load and once a
// second (a record built without a load starts at 24 again). Slots are
// sold by the exit guard's shop (keys module) through Buy().
//
// The character screen (core gui/playermenu/character.gui) uses
// <hwp-equipmentinventory>: the vanilla bag widget, but it draws as many
// slots as you can carry (vanilla always draws 24); the screen shows four
// rows, so a full bag fits without scrolling.
namespace HWP
{
	namespace Bag
	{
		const string KEY_EXTRA = "bag.extra";
		const int BASE = 24;
		const int MAX_EXTRA = 8;
		const array<int> PRICE = { 1000, 2000, 3500, 5500, 8000, 11000, 15000, 20000 };

		int Extra(PlayerRecord@ rec)
		{
			if (rec is null)
				return 0;
			return clamp(HWP::SaveData::Player(rec).GetInt(KEY_EXTRA, 0), 0, MAX_EXTRA);
		}

		int Capacity(PlayerRecord@ rec) { return BASE + Extra(rec); }

		// gold for the next slot; 0 when the bag is full size
		int NextPrice(PlayerRecord@ rec)
		{
			int extra = Extra(rec);
			return extra >= MAX_EXTRA ? 0 : PRICE[extra];
		}

		void Apply(PlayerRecord@ rec)
		{
			if (rec is null || rec.equipInventory is null)
				return;
			int cap = Capacity(rec);
			if (rec.equipInventory.m_maxItems == cap)
				return;
			rec.equipInventory.m_maxItems = cap;
			rec.equipInventory.m_isDirty = true;
		}

		// the local player buys one slot; false when full size or short of gold
		bool Buy(PlayerRecord@ rec)
		{
			int price = NextPrice(rec);
			if (price <= 0 || rec.GetMaterial(MaterialType::Gold) < price)
				return false;
			rec.GiveMaterial(MaterialType::Gold, -price, true);
			HWP::SaveData::Player(rec).SetInt(KEY_EXTRA, Extra(rec) + 1);
			Apply(rec);
			HWP::Log("core", rec.GetName() + " bought bag slot " + Capacity(rec) + " for " + price + " gold");
			return true;
		}

		void CmdBag(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
				return;
			if (args.length() >= 1 && args[0] == "buy")
			{
				int cost = NextPrice(rec);
				if (!Buy(rec))
				{
					HWP::Commands::Reply(Resources::GetString(cost <= 0 ? ".hwp.bag.status_full" : ".hwp.bag.no_gold", {
						{ "items", int(rec.equipInventory.m_items.length()) }, { "cap", Capacity(rec) }, { "price", cost } }));
					return;
				}
			}
			int price = NextPrice(rec);
			HWP::Commands::Reply(Resources::GetString(price > 0 ? ".hwp.bag.status" : ".hwp.bag.status_full", {
				{ "items", int(rec.equipInventory.m_items.length()) }, { "cap", Capacity(rec) },
				{ "max", BASE + MAX_EXTRA }, { "price", price } }));
		}
	}
}

class HWPEquipmentInventoryWidget : EquipmentInventoryWidget
{
	int m_check = 0;

	HWPEquipmentInventoryWidget() { super(); }

	// the vanilla bag keeps m_maxItems (set by HWP::Bag::Apply) current
	int SlotCount()
	{
		return max(int(m_owner.equipInventory.m_items.length()), m_owner.equipInventory.m_maxItems);
	}

	// vanilla Refresh with the slot count above, and a height that counts a
	// part-filled last row
	void Refresh() override
	{
		ClearChildren();
		if (m_owner is null)
			return;

		vec2 offset = vec2(0);
		ivec2 navOffset = ivec2(0);
		int count = SlotCount();
		for (int i = 0; i < count; i++)
		{
			auto item = cast<EquipmentItemWidget>(m_itemTemplate.Clone());
			item.SetID("");
			item.m_offset = offset;
			if (uint(i) < m_owner.equipInventory.m_items.length())
				item.Set(m_owner.equipInventory.m_items[i], this);
			item.m_visible = true;
			item.m_navPos += navOffset;
			@item.m_inventory = this;
			AddChild(item);

			navOffset.x += 1;
			offset.x += item.m_width;
			if ((offset.x + item.m_width) > m_width)
			{
				offset.x = 0;
				offset.y += item.m_height;
				navOffset.x = 0;
				navOffset.y += 1;
			}
		}
		m_height = (navOffset.y + (navOffset.x > 0 ? 1 : 0)) * m_itemTemplate.m_height;
		UpdateScroll();
	}

	// the vanilla tab code enables the scrollbar only past 24 items; ours
	// scrolls when the slots outgrow the view
	void UpdateScroll()
	{
		auto sb = cast<ScrollbarWidget>(m_parent);
		if (m_visible && sb !is null && m_owner !is null)
			sb.m_enabled = m_height > sb.m_height;
	}

	void Update(int dt) override
	{
		// a few times a second is plenty: the size changes only when a slot
		// is bought (and Apply also runs once a second from the module)
		m_check -= dt;
		if (m_visible && m_owner !is null && m_check <= 0)
		{
			m_check = 250;
			HWP::Bag::Apply(m_owner);
			if (m_children.length() != uint(SlotCount()))
				m_owner.equipInventory.m_isDirty = true;
			UpdateScroll();
		}
		EquipmentInventoryWidget::Update(dt);
	}
}

ref@ LoadHWPEquipmentInventoryWidget(WidgetLoadingContext &ctx)
{
	HWPEquipmentInventoryWidget@ w = HWPEquipmentInventoryWidget();
	w.Load(ctx);
	return w;
}

namespace HWPBagSlots
{
	[Hook]
	void LoadWidgetProducers(GUIBuilder@ builder)
	{
		builder.AddWidgetProducer("hwp-equipmentinventory", LoadHWPEquipmentInventoryWidget);
	}

	[Hook]
	void PlayerRecordLoad(PlayerRecord@ record, SValue@ data)
	{
		// should this run before the core hook has read the HWP data, the
		// module's once-a-second Apply catches up
		HWP::Bag::Apply(record);
	}
}

namespace Modules
{
	class HWPBagModule : Module
	{
		int m_timer = 0;

		HWPBagModule()
		{
			super("hwp-bag");
			HWP::Commands::Register("bag", " your bag size and the next slot's price; 'buy' buys it (or at the exit guard)", HWP::Commands::Handler(HWP::Bag::CmdBag));
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			m_timer -= ms;
			if (m_timer > 0)
				return;
			m_timer = 1000;
			HWP::Bag::Apply(GetLocalPlayerRecord());
		}
	}
}
