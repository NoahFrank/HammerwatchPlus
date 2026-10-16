// Wares: countable goods (fish, crops, herbs) that live in the owner's own
// PlayerRecord (HWP data bag "market.<id>") and sell for gold. The Gambler has
// a Sell button; `hwp wares` lists them and `hwp sell` sells them without
// him. Modules register their goods from their module constructor.
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

			Good(const string &in id_, const string &in name_, int price_, const string &in kind_)
			{
				id = id_;
				name = name_;
				price = price_;
				kind = kind_;
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

		void Register(const string &in id, const string &in name, int price, const string &in kind)
		{
			auto g = Get(id);
			if (g !is null)
			{
				g.name = name;
				g.price = price;
				g.kind = kind;
				return;
			}
			g_goods.insertLast(Good(id, name, price, kind));
		}

		int Count(PlayerRecord@ rec, const string &in id)
		{
			if (rec is null)
				return 0;
			return HWP::SaveData::Player(rec).GetInt(KEY_PREFIX + id);
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
			int c = Count(rec, id) + n;
			if (c < 0)
				c = 0;
			SetCount(rec, id, c);
			return c;
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
