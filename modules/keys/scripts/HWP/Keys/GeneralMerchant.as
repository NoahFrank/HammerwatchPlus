// General Merchant: sells keys in town. Interact class of
// actors/npcs/town/hwp_general_merchant.unit; uses the stock ShopWindow
// (gui/shops/default.gui) with one IShopItem per key tier. The window spends
// the gold itself (AutoSpendCost) and then calls Buy, which hands over the
// key - keys live in the buyer's own PlayerRecord, nothing is networked.

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

	Sprite@ GetBackground()
	{
		if (m_tier == 4)
			return GetQualitySprite(Item::Quality::Legendary);
		if (m_tier == 3)
			return GetQualitySprite(Item::Quality::Rare);
		if (m_tier == 2)
			return GetQualitySprite(Item::Quality::Uncommon);
		return GetQualitySprite(Item::Quality::Common);
	}

	ShopCost@ GetCost() { return m_cost; }
	bool AutoSpendCost() { return true; }
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
		return ret;
	}

	bool Buy(const string &in func, uint hash, IShopItem@ item) override
	{
		if (func != "buy" || m_player is null)
			return false;
		auto keyItem = cast<HWPKeyShopItem>(item);
		if (keyItem is null || !keyItem.IsAvailable(m_player))
			return false;

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
