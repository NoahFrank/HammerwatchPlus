// Wares: countable goods (fish, crops, herbs) that live in the owner's own
// PlayerRecord (HWP data bag "market.<id>") and sell for gold. A good can also
// be an equipment item (fish are weak weapons): then every copy of that base
// item in the inventory bag counts too (worn ones do not) and selling removes
// them. The Gambler has a Sell button; `hwp wares` lists them and `hwp sell`
// sells them without him. Modules register their goods from their module
// constructor.
namespace HWP
{
	namespace Market
	{
		const string KEY_PREFIX = "market.";

		class Good
		{
			string id;
			string name;  // lang key (".hwp...") or literal text
			int price;
			string kind;  // "fish", "crop", "herb"
			string itemId; // Equipment::BaseItem id whose bag copies are this good too, or ""

			Good(const string &in id_, const string &in name_, int price_, const string &in kind_, const string &in itemId_)
			{
				id = id_;
				name = name_;
				price = price_;
				kind = kind_;
				itemId = itemId_;
			}

			string Name()
			{
				if (name.findFirst(".") == 0)
					return Resources::GetString(name);
				return name;
			}
		}

		array<Good@> g_goods;

		Good@ Get(const string &in id)
		{
			for (uint i = 0; i < g_goods.length(); i++)
				if (g_goods[i].id == id)
					return g_goods[i];
			return null;
		}

		void Register(const string &in id, const string &in name, int price, const string &in kind, const string &in itemId = "")
		{
			auto g = Get(id);
			if (g !is null)
			{
				g.name = name;
				g.price = price;
				g.kind = kind;
				g.itemId = itemId;
				return;
			}
			g_goods.insertLast(Good(id, name, price, kind, itemId));
		}

		// the bag's copies of an item good
		array<Equipment::Equipment@>@ Items(PlayerRecord@ rec, Good@ g)
		{
			array<Equipment::Equipment@> found;
			if (rec is null || g is null || g.itemId.isEmpty() || rec.equipInventory is null)
				return found;
			for (uint i = 0; i < rec.equipInventory.m_items.length(); i++)
			{
				auto item = cast<Equipment::Item>(rec.equipInventory.m_items[i]);
				if (item !is null && item.baseItem !is null && item.baseItem.m_id == g.itemId)
					found.insertLast(rec.equipInventory.m_items[i]);
			}
			return found;
		}

		// the bag-key count only (what Add/SetCount change)
		int StoredCount(PlayerRecord@ rec, const string &in id)
		{
			if (rec is null)
				return 0;
			return HWP::SaveData::Player(rec).GetInt(KEY_PREFIX + id);
		}

		// stored count plus the bag's item copies
		int Count(PlayerRecord@ rec, const string &in id)
		{
			return StoredCount(rec, id) + Items(rec, Get(id)).length();
		}

		void SetCount(PlayerRecord@ rec, const string &in id, int n)
		{
			if (rec is null)
				return;
			auto bag = HWP::SaveData::Player(rec);
			if (n <= 0)
				bag.Remove(KEY_PREFIX + id);
			else
				bag.SetInt(KEY_PREFIX + id, n);
		}

		// Returns the new count (never below zero).
		int Add(PlayerRecord@ rec, const string &in id, int n)
		{
			int c = StoredCount(rec, id) + n;
			if (c < 0)
				c = 0;
			SetCount(rec, id, c);
			return c;
		}

		// Uses up n of a good: stored count first, then bag item copies. Returns
		// how many were taken (less than n when the player has fewer).
		int Take(PlayerRecord@ rec, const string &in id, int n)
		{
			int taken = 0;
			int stored = StoredCount(rec, id);
			int fromStore = stored < n ? stored : n;
			if (fromStore > 0)
			{
				SetCount(rec, id, stored - fromStore);
				taken += fromStore;
			}
			if (taken < n)
			{
				auto items = Items(rec, Get(id));
				for (uint i = 0; i < items.length() && taken < n; i++)
					if (rec.equipInventory.Remove(items[i]))
						taken++;
			}
			return taken;
		}

		int TotalCount(PlayerRecord@ rec)
		{
			int n = 0;
			for (uint i = 0; i < g_goods.length(); i++)
				n += Count(rec, g_goods[i].id);
			return n;
		}

		int TotalValue(PlayerRecord@ rec)
		{
			int v = 0;
			for (uint i = 0; i < g_goods.length(); i++)
				v += Count(rec, g_goods[i].id) * g_goods[i].price;
			return v;
		}

		// Sells every registered good the player holds; returns the gold given.
		int SellAll(PlayerRecord@ rec)
		{
			if (rec is null)
				return 0;
			int gold = 0;
			for (uint i = 0; i < g_goods.length(); i++)
			{
				int c = Count(rec, g_goods[i].id);
				if (c <= 0)
					continue;
				gold += c * g_goods[i].price;
				SetCount(rec, g_goods[i].id, 0);
				auto items = Items(rec, g_goods[i]);
				for (uint j = 0; j < items.length(); j++)
					rec.equipInventory.Remove(items[j]);
			}
			if (gold > 0)
				rec.GiveMaterial(MaterialType::Gold, gold, true);
			return gold;
		}

		// "3x Perch, 2x Lucky Leaf" (empty string when nothing is held).
		string Summary(PlayerRecord@ rec, const string &in kind = "")
		{
			string s = "";
			for (uint i = 0; i < g_goods.length(); i++)
			{
				if (!kind.isEmpty() && g_goods[i].kind != kind)
					continue;
				int c = Count(rec, g_goods[i].id);
				if (c <= 0)
					continue;
				if (!s.isEmpty())
					s += ", ";
				s += c + "x " + g_goods[i].Name();
			}
			return s;
		}

		void CmdWares(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
			{
				HWP::Commands::Reply("no character loaded");
				return;
			}
			auto s = Summary(rec);
			if (s.isEmpty())
				HWP::Commands::Reply(Resources::GetString(".hwp.market.none"));
			else
				HWP::Commands::Reply(Resources::GetString(".hwp.market.list", {
					{ "list", s }, { "gold", TotalValue(rec) } }));
		}

		void CmdSell(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
			{
				HWP::Commands::Reply("no character loaded");
				return;
			}
			int gold = SellAll(rec);
			if (gold <= 0)
				HWP::Commands::Reply(Resources::GetString(".hwp.market.none"));
			else
				HWP::Commands::Reply(Resources::GetString(".hwp.market.sold", { { "gold", gold } }));
		}

		void Init()
		{
			HWP::Commands::Register("wares", " list the fish, crops and herbs you carry", HWP::Commands::Handler(CmdWares));
			HWP::Commands::Register("sell", " sell all your wares for gold (the Gambler does this too)", HWP::Commands::Handler(CmdSell));
		}
	}
}
