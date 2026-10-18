// Wares: countable goods (fish, crops, herbs) that live in the owner's own
// PlayerRecord (HWP data bag "market.<id>") and sell for gold. A good can also
// be an equipment item (fish are weak weapons): then every copy of that base
// item in the inventory bag counts too (worn ones do not) and selling removes
// them. A good with a token price (fish) sells for bet tokens instead of gold;
// the Gambler takes tokens for gear rerolls. The Gambler has a Sell button;
// `hwp wares` lists them and `hwp sell` sells them without him. Modules
// register their goods from their module constructor.
namespace HWP
{
	namespace Market
	{
		const string KEY_PREFIX = "market.";
		const string KEY_TOKENS = "bet_tokens"; // per character: bet tokens

		class Good
		{
			string id;
			string name;  // lang key (".hwp...") or literal text
			int price;
			string kind;  // "fish", "crop", "herb"
			string itemId; // Equipment::BaseItem id whose bag copies are this good too, or ""
			int tokens;    // > 0: sells for this many bet tokens instead of gold

			Good(const string &in id_, const string &in name_, int price_, const string &in kind_, const string &in itemId_, int tokens_)
			{
				id = id_;
				name = name_;
				price = price_;
				kind = kind_;
				itemId = itemId_;
				tokens = tokens_;
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

		void Register(const string &in id, const string &in name, int price, const string &in kind, const string &in itemId = "", int tokens = 0)
		{
			auto g = Get(id);
			if (g !is null)
			{
				g.name = name;
				g.price = price;
				g.kind = kind;
				g.itemId = itemId;
				g.tokens = tokens;
				return;
			}
			g_goods.insertLast(Good(id, name, price, kind, itemId, tokens));
		}

		// ---- bet tokens ---------------------------------------------------------

		int Tokens(PlayerRecord@ rec)
		{
			if (rec is null)
				return 0;
			return HWP::SaveData::Player(rec).GetInt(KEY_TOKENS);
		}

		void AddTokens(PlayerRecord@ rec, int n)
		{
			if (rec is null)
				return;
			int t = Tokens(rec) + n;
			auto bag = HWP::SaveData::Player(rec);
			if (t <= 0)
				bag.Remove(KEY_TOKENS);
			else
				bag.SetInt(KEY_TOKENS, t);
		}

		// false (and nothing spent) when the player has fewer than n
		bool SpendTokens(PlayerRecord@ rec, int n)
		{
			if (rec is null || n < 0 || Tokens(rec) < n)
				return false;
			AddTokens(rec, -n);
			return true;
		}

		// the bag's copies of an item good
		// A bag copy of a good's item counts as the ware only while nobody worked
		// on it: an enchanted, rerolled or upgraded fish is gear and is never
		// sold by Sell.
		bool IsWare(Equipment::Item@ item, Good@ g)
		{
			return item !is null && item.baseItem !is null && item.baseItem.m_id == g.itemId
				&& item.mods.length() == 0 && item.upgradeLevel <= 0;
		}

		array<Equipment::Equipment@>@ Items(PlayerRecord@ rec, Good@ g)
		{
			array<Equipment::Equipment@> found;
			if (rec is null || g is null || g.itemId.isEmpty() || rec.equipInventory is null)
				return found;
			for (uint i = 0; i < rec.equipInventory.m_items.length(); i++)
				if (IsWare(cast<Equipment::Item>(rec.equipInventory.m_items[i]), g))
					found.insertLast(rec.equipInventory.m_items[i]);
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

		bool KindMatches(Good@ g, const string &in kind)
		{
			return kind.isEmpty() || g.kind == kind;
		}

		class Sale
		{
			int count = 0;
			int gold = 0;
			int tokens = 0;
		}

		// what the player's wares of a kind ("" = all) would sell for, in one pass
		Sale@ Worth(PlayerRecord@ rec, const string &in kind = "")
		{
			Sale w;
			for (uint i = 0; i < g_goods.length(); i++)
			{
				auto g = g_goods[i];
				if (!KindMatches(g, kind))
					continue;
				int c = Count(rec, g.id);
				w.count += c;
				if (g.tokens > 0)
					w.tokens += c * g.tokens;
				else
					w.gold += c * g.price;
			}
			return w;
		}

		// Sells every registered good of a kind ("" = all) the player holds:
		// gold-priced goods for gold, token-priced ones (fish) for bet tokens.
		Sale@ Sell(PlayerRecord@ rec, const string &in kind = "")
		{
			Sale sale;
			if (rec is null)
				return sale;
			for (uint i = 0; i < g_goods.length(); i++)
			{
				auto g = g_goods[i];
				if (!KindMatches(g, kind))
					continue;
				int c = Count(rec, g.id);
				if (c <= 0)
					continue;
				SetCount(rec, g.id, 0);
				auto items = Items(rec, g);
				for (uint j = 0; j < items.length(); j++)
					if (!rec.equipInventory.Remove(items[j]))
						c--; // not in the bag after all: not sold
				sale.count += c;
				if (g.tokens > 0)
					sale.tokens += c * g.tokens;
				else
					sale.gold += c * g.price;
			}
			if (sale.gold > 0)
				rec.GiveMaterial(MaterialType::Gold, sale.gold, true);
			if (sale.tokens > 0)
				AddTokens(rec, sale.tokens);
			return sale;
		}

		// "120 gold and 3 bet tokens", "120 gold", "3 bet tokens";
		// brief (buttons): "120 g, 3 tok"
		string Price(int gold, int tokens, bool brief = false)
		{
			string sfx = brief ? "_short" : "";
			string g = Resources::GetString(".hwp.market.gold" + sfx, { { "n", gold } });
			string t = Resources::GetString(".hwp.market.tokens" + sfx, { { "n", tokens } });
			if (gold > 0 && tokens > 0)
				return Resources::GetString(".hwp.market.and" + sfx, { { "a", g }, { "b", t } });
			return tokens > 0 ? t : g;
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
			{
				auto worth = Worth(rec);
				HWP::Commands::Reply(Resources::GetString(".hwp.market.list", {
					{ "list", s }, { "price", Price(worth.gold, worth.tokens) } }));
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.market.token_count", { { "n", Tokens(rec) } }));
		}

		void CmdSell(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
			{
				HWP::Commands::Reply("no character loaded");
				return;
			}
			auto sale = Sell(rec);
			if (sale.count <= 0)
				HWP::Commands::Reply(Resources::GetString(".hwp.market.none"));
			else
				HWP::Commands::Reply(Resources::GetString(".hwp.market.sold", { { "price", Price(sale.gold, sale.tokens) } }));
		}

		void Init()
		{
			HWP::Commands::Register("wares", " list the fish, crops and herbs you carry and your bet tokens", HWP::Commands::Handler(CmdWares));
			HWP::Commands::Register("sell", " sell your wares: crops and herbs for gold, fish for bet tokens (the Gambler does this too)", HWP::Commands::Handler(CmdSell));
		}
	}
}
