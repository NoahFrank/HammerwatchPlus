// The key shop: sells keys and bag slots (core HWP::Bag) in town. First
// interact class of the exit guard by the run start (our copy of
// actors/npcs/town/npc_misc_guard_exit.unit); his vanilla speech bubble is the
// second, so NPCBehavior shows it once the shop window closes. Uses the stock
// ShopWindow (gui/shops/default.gui) with one IShopItem per key tier. The gold is spent
// inside Buy (AutoSpendCost false) so an unavailable purchase cannot cost
// anything - keys live in the buyer's own PlayerRecord, nothing is networked.

class HWPKeyShopItem : IShopItem
{
	string m_key;
	int m_tier;
	ShopCost@ m_cost;

	HWPKeyShopItem(int tier, int price)
	{
		m_tier = tier;
		m_key = HWP::Keys::TIERS[tier - 1];
		@m_cost = ShopCost(MaterialType::Gold, price);
	}

	string GetID() { return m_key; }
	uint GetIDHash() { return HashString(m_key); }
	string GetTitle() { return Resources::GetString(".item.key." + m_key); }
	string GetSubTitle() { return Resources::GetString(".hwp.keys.shop." + m_key); }
	string GetDescription() { return ""; }

	ScriptSprite@ GetIcon()
	{
		return ScriptSprite(Resources::GetTexture2D("items/special/base.png"), HWP::Keys::KeyIconFrame(m_tier));
	}

	Sprite@ GetBackground() { return GetQualitySprite(HWP::Keys::TierQuality(m_tier)); }

	ShopCost@ GetCost() { return m_cost; }
	bool AutoSpendCost() { return false; }
	string OnFunc() { return "buy"; }

	// one ace key at a time: it is the expensive, run-defining one
	bool IsAvailable(PlayerRecord@ player)
	{
		if (player is null)
			return false;
		if (m_tier == 4)
			return player.GetKeys(m_key) < 1;
		return true;
	}

	void ShowTooltip(WindowManager@ manager, bool compare) { }
	Item::Item@ GetItem() { return null; }
}

// One more equipment bag slot for the buyer's character (core HWP::Bag): the
// price climbs with every slot, up to a full extra row.
class HWPBagShopItem : IShopItem
{
	ShopCost@ m_cost;

	HWPBagShopItem(PlayerRecord@ player)
	{
		// sold out at full size: no cost line (the subtitle says the bag is full)
		int price = HWP::Bag::NextPrice(player);
		if (price > 0)
			@m_cost = ShopCost(MaterialType::Gold, price);
	}

	string GetID() { return "hwp_bag_slot"; }
	uint GetIDHash() { return HashString("hwp_bag_slot"); }
	string GetTitle() { return Resources::GetString(".hwp.bag.shop_title"); }

	string GetSubTitle()
	{
		auto rec = GetLocalPlayerRecord();
		dictionary params = { { "cap", HWP::Bag::Capacity(rec) }, { "max", HWP::Bag::BASE + HWP::Bag::MAX_EXTRA } };
		return Resources::GetString(HWP::Bag::NextPrice(rec) > 0 ? ".hwp.bag.shop_sub" : ".hwp.bag.shop_sub_full", params);
	}

	string GetDescription() { return ""; }

	ScriptSprite@ GetIcon()
	{
		return ScriptSprite(Resources::GetTexture2D("gui/gui.png"), vec4(190, 40, 27, 27));
	}

	Sprite@ GetBackground() { return GetQualitySprite(Item::Quality::Uncommon); }

	ShopCost@ GetCost() { return m_cost; }
	bool AutoSpendCost() { return false; }
	string OnFunc() { return "buy"; }
	bool IsAvailable(PlayerRecord@ player) { return HWP::Bag::NextPrice(player) > 0; }
	void ShowTooltip(WindowManager@ manager, bool compare) { }
	Item::Item@ GetItem() { return null; }
}

class HWPGeneralMerchant : AShopContent
{
	HWPGeneralMerchant() {}
	HWPGeneralMerchant(UnitPtr u, SValue& params)
	{
		super(u, params);
	}

	string GetName() override { return ".hwp.keys.merchant.name"; }

	array<IShopItem@> GetItems() override
	{
		array<IShopItem@> ret;
		for (int tier = 1; tier <= 4; tier++)
			ret.insertLast(HWPKeyShopItem(tier, HWP::Keys::KeyPrice(tier)));
		ret.insertLast(HWPBagShopItem(m_player !is null ? m_player : GetLocalPlayerRecord()));
		return ret;
	}

	bool Buy(const string &in func, uint hash, IShopItem@ item) override
	{
		if (func != "buy" || m_player is null)
			return false;
		auto bagItem = cast<HWPBagShopItem>(item);
		if (bagItem !is null)
		{
			if (!HWP::Bag::Buy(m_player))
				return false;
			LootLog::PresentPickup(m_player, Resources::GetString(".hwp.bag.bought", { { "cap", HWP::Bag::Capacity(m_player) } }), 1);
			return true;
		}
		auto keyItem = cast<HWPKeyShopItem>(item);
		if (keyItem is null || !keyItem.IsAvailable(m_player))
			return false;
		if (!keyItem.m_cost.CanAfford(m_player))
			return false;

		keyItem.m_cost.Spend(m_player);
		m_player.AddKeys(keyItem.m_key, 1);
		Stats::Add(HashString("key-bought-" + keyItem.m_key), 1, m_player);
		LootLog::PresentPickup(m_player, Resources::GetString(".item.key." + keyItem.m_key), 1);
		HWP::Keys::RefreshHUD();
		HWP::Log("keys", m_player.GetName() + " bought a " + keyItem.m_key + " key");
		return true;
	}

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}
