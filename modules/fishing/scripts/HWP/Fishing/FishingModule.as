// Fishing. Spots along the town's west coast (doodads/hwp/fishing_spot.unit,
// spawned locally on every machine) run a timing minigame on the local
// machine. A cast costs one bait of the kind you picked; the catch is a fish item in your bag (a
// one-handed sword that can be enchanted, tweak/hwp/fishing_items.sval) and
// the lobby hears about it. Fish have 1-3 stars and sell for 1 / 3 / 5 bet
// tokens at the pirate or the Gambler, who rerolls gear for tokens. The town
// only has 1-star fish on worms (tiers 1-2); shrimp bring tiers 2-3 (up to
// 2-star) and glow squid tiers 3-4 (up to 3-star) to the coast. In runs,
// 2-star fish (tier 3) bite only on the second half of a run's floors and
// 3-star fish (tier 4) only in boss rooms.
// Your rod (per character, tier 1 is free) widens the catch zone, slows the
// marker and improves the odds. A pirate fisherman sits on the half-buried
// boat by the trading post and sells bait, rod upgrades and fish traps, and
// buys fish.
//
// Fish traps (up to 3 per character) sit in the sea by the coast. A run fills
// them: every 10 minutes spent on a run gives each trap a 50 % chance of one
// more fish, up to 3 per trap, rolled when you get back to town.
//
// In a run the host places a fishing spot beside a potion-refill well (some
// levels, g_runChance), and always in a boss room (beside its well, or a
// bucket by the entrance). A cast there asks the host (`fishing.cast`): it
// spends one of the player's casts for the level, rolls the tier and the bite
// delay and answers `fishing.bite`; the minigame then runs with that tier and
// a hit sends `fishing.catch`: the host spawns the loot of the tier from
// tweak/hwp/loot_fishing.sval and answers `fishing.landed` with the fish and
// its item level (the floor's drop level, NG+ included). Clients never choose
// what they catch there; run spots need no bait.
namespace HWP
{
	namespace Fishing
	{
		const string SPOT_UNIT = "doodads/hwp/fishing_spot.unit";
		const string HOLE_UNIT = "doodads/hwp/fishing_hole.unit";
		const string WELL_SPOT_UNIT = "doodads/hwp/fishing_hole_well.unit";
		const string BUCKET_UNIT = "doodads/hwp/fishing_bucket.unit";
		const string TRAP_UNIT = "doodads/hwp/fish_trap.unit";
		const string TRAP_FULL_UNIT = "doodads/hwp/fish_trap_full.unit"; // with a fish and the map icon
		// the potion-refill wells a run spot sits beside
		const array<string> WELL_UNITS = {
			"doodads/wells/well_default.unit", "doodads/wells/well_dark_halls.unit",
			"doodads/wells/barrel_refill.unit", "doodads/wells/crypt_refill.unit",
			"doodads/wells/fountain.unit", "doodads/wells/fountain_heaven.unit" };
		const string PIRATE_UNIT = "doodads/hwp/pirate_fisher.unit";
		const string TRADER_UNIT = "actors/npcs/town/npc_material_trader.unit";
		const string CAST = "fishing.cast";         // client -> host: { rod } a cast at a hole
		const string BITE = "fishing.bite";         // host -> peer: { tier, delay }
		const string CATCH = "fishing.catch";       // client -> host: the reel hit
		const string DENIED = "fishing.denied";     // host -> peer: no casts left
		const string CAUGHT = "fishing.caught";     // client -> host: { fish } a coast catch
		const string ANNOUNCE = "fishing.announce"; // host -> all: { peer, name, fish }
		const string LANDED = "fishing.landed";     // host -> peer: { fish, ilvl } a run catch for the bag
		const string KEY_ROD = "fishing.rod";       // per character: rod tier (1 = the free one)
		const string KEY_BAIT = "fishing.bait";     // per character: worms (+ ".shrimp" / ".squid": the others)
		const string KEY_TRAPS = "fishing.traps";   // per character: traps owned (0-3)
		const string KEY_TRAP = "fishing.trap.";    // + index: the fish ids in that trap, comma separated
		const string KEY_RUN_MS = "fishing.run_ms"; // per character: ms spent on the current run
		const int TIERS = 4;
		const int ROD_TIERS = 4;
		const array<int> ROD_PRICE = { 0, 0, 400, 1200, 3000 };
		// bait kinds 1-3: worms, shrimp, glow squid. A kind keeps a coast bite
		// within its tiers; the pirate sells each in packs.
		const array<string> BAIT_IDS = { "worm", "shrimp", "squid" };
		const array<int> BAIT_MIN_TIER = { 1, 2, 3 };
		const array<int> BAIT_MAX_TIER = { 2, 3, 4 };
		const array<int> BAIT_PACK = { 5, 5, 3 };
		const array<int> BAIT_PACK_PRICE = { 50, 400, 900 };
		const int BAIT_BIG = 20;            // the big worm tin
		const int BAIT_BIG_PRICE = 180;
		const string KEY_BAIT_SEL = "fishing.bait_sel"; // per character: the bait kind cast with
		const int BITE_WINDOW = 2500;           // ms to reel after a bite
		const int BAR_WIDTH = 240;              // px, matches gui/hwp_fishing.gui
		const int STATE_IDLE = 0;
		const int STATE_WAIT = 1;
		const int STATE_BITE = 2;
		const int STATE_RESULT = 3;
		const array<int> ZONE_WIDTH = { 64, 44, 28, 16 };          // per fish tier, px of a 240 px bar
		const array<float> MARKER_SPEED = { 0.12f, 0.16f, 0.2f, 0.26f }; // px per ms
		const array<int> FISH_ILVL = { 1, 5, 10, 15 }; // town catches (coast, traps) per tier
		const array<int> STAR_TOKENS = { 1, 3, 5 };     // bet tokens per 1 / 2 / 3-star fish
		const int TOWN_MAX_TIER = 2;                    // the town has 1-star fish only
		const int MAX_TRAPS = 3;
		const array<int> TRAP_PRICE = { 500, 1000, 2000 }; // the 1st, 2nd, 3rd trap
		const int TRAP_MAX_FISH = 3;
		const int TRAP_ROLL_MS = 600000;                // a 50 % roll per trap every 10 minutes of a run
		// a trap per coast spot 1-3, out in the sea west of it
		const array<int> TRAP_SPOT = { 1, 2, 3 };
		const int TRAP_DX = -44;
		const int TRAP_DY = 40;

		// The west coast of the town (prefabs/town/segments/base.lvl, its
		// water_coastline pieces), a little inland so the angler stands on the
		// beach and the fish swim in the water to the west.
		const array<int> COAST_X = { -1180, -1308, -1436, -1476, -1388, -1372 };
		const array<int> COAST_Y = { -184, 56, 272, 424, 680, 960 };
		// Where the pirate goes, from the trading post's prefabs (plot at
		// -1536,256): tiers 0-2 have the half-buried wreck at 320,-112 and he
		// sits on it; tier 3 swaps it for a whole boat a little west (272,-124)
		// and tiers 4-5 leave that beach empty, so from tier 3 he stands on the
		// beach where the wreck was. The prefab boats are statics, which
		// FetchAllUnitsOfType does not see; the material trader (380,-66 in
		// every built tier) is a unit and gives the plot's real position.
		const int PLOT_X = -1536;
		const int PLOT_Y = 256;
		const int TRADER_X = 380;
		const int TRADER_Y = -66;
		const int ON_WRECK_X = 314;
		const int ON_WRECK_Y = -114;
		const int ON_BEACH_X = 334;
		const int ON_BEACH_Y = -110;
		const int NO_POS = -100000; // fishing.pirate_x/y unset
		const int WATCH_MS = 1000;

		// tiers 1-2 are 1-star fish, tier 3 2-star, tier 4 3-star
		int StarOf(int tier) { return tier <= 2 ? 1 : (tier >= 4 ? 3 : 2); }

		class Fish
		{
			string id;
			int tier;
			int price;
			Fish(const string &in id_, int tier_, int price_) { id = id_; tier = tier_; price = price_; }
			string Name() { return Resources::GetString(".hwp.fishing.fish." + id); }
			string ItemId() { return "hwp_fish_" + id; }
			int Star() { return StarOf(tier); }
			int Tokens() { return STAR_TOKENS[Star() - 1]; }
			Item::Quality Quality()
			{
				if (Star() >= 3) return Item::Quality::Rare;
				if (Star() == 2) return Item::Quality::Uncommon;
				return Item::Quality::Common;
			}
		}
		array<Fish@> g_fish;

		void AddFish(const string &in id, int tier, int price)
		{
			Fish@ f = Fish(id, tier, price);
			g_fish.insertLast(f);
			HWP::Market::Register(id, ".hwp.fishing.fish." + id, price, "fish", f.ItemId(), f.Tokens());
		}

		void DefineFish()
		{
			if (g_fish.length() > 0)
				return;
			AddFish("perch", 1, 15);
			AddFish("carp", 1, 20);
			AddFish("trout", 2, 60);
			AddFish("pike", 2, 80);
			AddFish("salmon", 3, 200);
			AddFish("sturgeon", 3, 260);
			AddFish("golden_carp", 4, 800);
			AddFish("abyssal_eel", 4, 1000);
		}

		Fish@ GetFish(const string &in id)
		{
			for (uint i = 0; i < g_fish.length(); i++)
				if (g_fish[i].id == id)
					return g_fish[i];
			return null;
		}

		// ---- settings ------------------------------------------------------------

		bool g_enabled = true;
		bool g_coast = true;   // the coast spots and the pirate
		int g_runChance = 30;  // % of runs that get a fishing hole at the start
		int g_runCasts = 3;    // catches per player per level at a hole
		int g_biteMin = 800;
		int g_biteMax = 3000;
		bool g_debug = false;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("fishing.enabled", true);
			g_coast = HWP::Settings::GetBool("fishing.coast", true);
			g_runChance = HWP::Settings::GetInt("fishing.run_chance", 30);
			g_runCasts = HWP::Settings::GetInt("fishing.run_casts", 3);
			g_biteMin = HWP::Settings::GetInt("fishing.bite_min", 800);
			g_biteMax = HWP::Settings::GetInt("fishing.bite_max", 3000);
			g_debug = HWP::Settings::GetBool("fishing.debug", false);
			if (g_biteMin < 100) g_biteMin = 100;
			if (g_biteMax < g_biteMin) g_biteMax = g_biteMin;
		}

		bool g_townReady = false; // the coast of this town level is set up

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("fishing.") != 0)
				return;
			RefreshSettings();
			// a client got the host's values: re-place the coast to match
			if (key == "fishing." && g_inTown && g_townReady)
				SpawnCoast();
		}

		// ---- per character: rod and bait ------------------------------------------

		int g_version = 0;          // bumped when rod, bait or the last message change
		string g_lastMessage = "";

		int ClampRod(int t)
		{
			if (t < 1) return 1;
			if (t > ROD_TIERS) return ROD_TIERS;
			return t;
		}

		int RodTier() { return ClampRod(HWP::SaveData::Local().GetInt(KEY_ROD, 1)); }
		string RodName(int tier) { return Resources::GetString(".hwp.fishing.rod." + ClampRod(tier)); }
		int ClampBait(int kind)
		{
			if (kind < 1) return 1;
			if (kind > int(BAIT_IDS.length())) return int(BAIT_IDS.length());
			return kind;
		}
		string BaitKey(int kind) { return ClampBait(kind) == 1 ? KEY_BAIT : KEY_BAIT + "." + BAIT_IDS[ClampBait(kind) - 1]; }
		int Bait(int kind = 1) { return HWP::SaveData::Local().GetInt(BaitKey(kind), 0); }
		string BaitName(int kind) { return Resources::GetString(".hwp.fishing.bait." + BAIT_IDS[ClampBait(kind) - 1]); }
		int SelectedBait() { return ClampBait(HWP::SaveData::Local().GetInt(KEY_BAIT_SEL, 1)); }

		int BaitKind(const string &in id)
		{
			for (uint i = 0; i < BAIT_IDS.length(); i++)
				if (BAIT_IDS[i] == id)
					return int(i) + 1;
			return 0;
		}

		// the stars a coast bite on this bait can have, e.g. "1-2"
		string BaitStars(int kind)
		{
			int a = StarOf(BAIT_MIN_TIER[ClampBait(kind) - 1]);
			int b = StarOf(BAIT_MAX_TIER[ClampBait(kind) - 1]);
			return a == b ? "" + a : a + "-" + b;
		}

		void Changed()
		{
			g_version++;
			HWP::Gear::Changed();
		}

		void SetBait(int n, int kind = 1)
		{
			HWP::SaveData::Local().SetInt(BaitKey(kind), n < 0 ? 0 : n);
			Changed();
		}

		void SelectBait(int kind)
		{
			HWP::SaveData::Local().SetInt(KEY_BAIT_SEL, ClampBait(kind));
			Changed();
		}

		// the next kind you have any of after the selected one (or the
		// selected one when you have no other)
		void CycleBait()
		{
			int cur = SelectedBait();
			int n = int(BAIT_IDS.length());
			for (int i = 1; i <= n; i++)
			{
				int k = (cur - 1 + i) % n + 1;
				if (Bait(k) > 0 || i == n)
				{
					SelectBait(k);
					return;
				}
			}
		}

		// the rod: a wider catch zone, a slower marker, better odds
		float ZoneScale(int rod) { return 1.0f + 0.2f * float(ClampRod(rod) - 1); }
		float SpeedScale(int rod) { return 1.0f - 0.1f * float(ClampRod(rod) - 1); }

		void Say(const string &in text)
		{
			g_lastMessage = text;
			auto rec = GetLocalPlayerRecord();
			if (rec !is null && rec.actor !is null)
				AddFloatingText(FloatingTextType::Pickup, text, rec.actor.m_unit.GetPosition() + vec3(0, -24, 0));
			Changed();
		}

		bool Pay(int price)
		{
			if (HWP::Town::PayGold(price))
				return true;
			Say(Resources::GetString(".hwp.fishing.pirate.no_gold"));
			return false;
		}

		void BuyBait(int kind, int n, int price)
		{
			if (!Pay(price))
				return;
			SetBait(Bait(kind) + n, kind);
			if (Bait(SelectedBait()) <= 0)
				SelectBait(kind);
			Say(Resources::GetString(".hwp.fishing.pirate.bait_bought." + BAIT_IDS[ClampBait(kind) - 1], { { "n", n }, { "total", Bait(kind) } }));
		}

		// every kind with its count, e.g. "Worms 12, Shrimp 3, Glow Squid 0"
		string BaitSummary()
		{
			string list = "";
			for (uint i = 0; i < BAIT_IDS.length(); i++)
				list += (i > 0 ? ", " : "") + BaitName(i + 1) + " " + Bait(i + 1);
			return list;
		}

		void BuyRod()
		{
			int next = RodTier() + 1;
			if (next > ROD_TIERS)
			{
				Say(Resources::GetString(".hwp.fishing.pirate.rod_max"));
				return;
			}
			if (!Pay(ROD_PRICE[next]))
				return;
			HWP::SaveData::Local().SetInt(KEY_ROD, next);
			Changed();
			Say(Resources::GetString(".hwp.fishing.pirate.rod_bought", { { "rod", RodName(next) } }));
		}

		// ---- fish traps ---------------------------------------------------------------

		int Traps()
		{
			int n = HWP::SaveData::Local().GetInt(KEY_TRAPS, 0);
			return n < 0 ? 0 : (n > MAX_TRAPS ? MAX_TRAPS : n);
		}

		array<string>@ TrapFish(int i)
		{
			array<string> ids;
			string list = HWP::SaveData::Local().GetString(KEY_TRAP + i, "");
			if (list.isEmpty())
				return ids;
			auto parts = list.split(",");
			for (uint j = 0; j < parts.length(); j++)
				if (GetFish(parts[j]) !is null)
					ids.insertLast(parts[j]);
			return ids;
		}

		void SetTrapFish(int i, array<string>@ ids)
		{
			auto bag = HWP::SaveData::Local();
			if (ids.length() == 0)
				bag.Remove(KEY_TRAP + i);
			else
				bag.SetString(KEY_TRAP + i, join(ids, ","));
			g_trapsDirty = true;
			Changed();
		}

		void BuyTrap()
		{
			int have = Traps();
			if (have >= MAX_TRAPS)
			{
				Say(Resources::GetString(".hwp.fishing.pirate.trap_max", { { "n", MAX_TRAPS } }));
				return;
			}
			if (!Pay(TRAP_PRICE[have]))
				return;
			HWP::SaveData::Local().SetInt(KEY_TRAPS, have + 1);
			g_trapsDirty = true;
			Changed();
			Say(Resources::GetString(".hwp.fishing.pirate.trap_bought", { { "n", have + 1 }, { "max", MAX_TRAPS } }));
		}

		// the pirate buys your fish for bet tokens
		void SellFish()
		{
			auto sale = HWP::Market::Sell(GetLocalPlayerRecord(), "fish");
			if (sale.count <= 0)
				Say(Resources::GetString(".hwp.fishing.pirate.no_fish"));
			else
				Say(Resources::GetString(".hwp.fishing.pirate.sold", { { "n", sale.count }, { "tokens", sale.tokens } }));
		}

		// ms on the current run not yet written to the save (written every few s)
		int g_runMs = 0;
		int g_runFlush = 0;

		// every frame of a run (only while you own a trap)
		void TickRun(int ms)
		{
			if (!g_coast || Traps() <= 0)
				return;
			g_runMs += ms;
			g_runFlush += ms;
			if (g_runFlush < 5000)
				return;
			g_runFlush = 0;
			FlushRunTime();
		}

		void FlushRunTime()
		{
			if (g_runMs <= 0)
				return;
			auto bag = HWP::SaveData::Local();
			bag.SetInt(KEY_RUN_MS, bag.GetInt(KEY_RUN_MS, 0) + g_runMs);
			g_runMs = 0;
		}

		// back in town: the run's time fills the traps
		void ResolveTraps()
		{
			FlushRunTime();
			auto bag = HWP::SaveData::Local();
			int runMs = bag.GetInt(KEY_RUN_MS, 0);
			bag.Remove(KEY_RUN_MS);
			int rolls = runMs / TRAP_ROLL_MS;
			int traps = Traps();
			if (rolls <= 0 || traps <= 0)
				return;
			int caught = 0;
			for (int i = 0; i < traps; i++)
			{
				auto ids = TrapFish(i);
				for (int r = 0; r < rolls && int(ids.length()) < TRAP_MAX_FISH; r++)
				{
					if (randi(2) != 0)
						continue;
					auto fish = RandomFish(RollTier(RodTier(), 1, TOWN_MAX_TIER));
					if (fish is null)
						continue;
					ids.insertLast(fish.id);
					caught++;
				}
				SetTrapFish(i, ids);
			}
			HWP::Log("fishing", "traps: " + (runMs / 60000) + " min run, " + rolls + " rolls, " + caught + " fish");
			if (caught > 0)
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.trap.filled", { { "n", caught }, { "min", runMs / 60000 } }));
		}

		// empties trap i into your bag
		void CollectTrap(int i)
		{
			if (i < 0 || i >= Traps())
				return;
			auto ids = TrapFish(i);
			if (ids.length() == 0)
			{
				Say(Resources::GetString(".hwp.fishing.trap.empty", { { "max", TRAP_MAX_FISH } }));
				return;
			}
			string names = "";
			for (uint j = 0; j < ids.length(); j++)
			{
				auto fish = GetFish(ids[j]);
				GiveFish(fish, -1, false);
				names += (names.isEmpty() ? "" : ", ") + fish.Name();
			}
			SetTrapFish(i, array<string>());
			Say(Resources::GetString(".hwp.fishing.trap.collected", { { "list", names } }));
		}

		vec3 TrapPos(int i)
		{
			int spot = TRAP_SPOT[i];
			return vec3(float(COAST_X[spot] + TRAP_DX), float(COAST_Y[spot] + TRAP_DY), 0);
		}

		// the trap nearest a position (a trap unit knows its index this way)
		int TrapIndexAt(vec3 pos)
		{
			int best = -1;
			float bestDist = 64.0f;
			for (int i = 0; i < Traps(); i++)
			{
				float d = dist(xy(pos), xy(TrapPos(i)));
				if (d < bestDist)
				{
					bestDist = d;
					best = i;
				}
			}
			return best;
		}

		// the rod's bonuses and your bait; one line for chat, two for tooltips
		string RodText(bool lines = true)
		{
			int rod = RodTier();
			string text = rod <= 1 ? Resources::GetString(".hwp.fishing.rod_text_base", { { "rod", RodName(rod) } })
				: Resources::GetString(".hwp.fishing.rod_text", { { "rod", RodName(rod) }, { "tier", rod },
				{ "zone", int(ZoneScale(rod) * 100.0f + 0.5f) - 100 }, { "speed", 100 - int(SpeedScale(rod) * 100.0f + 0.5f) } });
			return text + (lines ? "\n" : " ") + Resources::GetString(".hwp.fishing.rod_bait", { { "list", BaitSummary() } });
		}

		// ---- rolls ------------------------------------------------------------------

		// per mille: the tier 4 / 3 / 2 thresholds grow with the rod; the result
		// is kept within what the place has (minTier-maxTier)
		int RollTier(int rod = 1, int minTier = 1, int maxTier = TIERS)
		{
			int r = ClampRod(rod) - 1;
			int roll = randi(1000);
			int tier = 1;
			if (roll < 40 + 15 * r) tier = 4;
			else if (roll < 170 + 40 * r) tier = 3;
			else if (roll < 450 + 30 * r) tier = 2;
			if (tier > maxTier) tier = maxTier;
			if (tier < minTier) tier = minTier;
			return tier;
		}

		bool IsBossLevel()
		{
			return cast<BossLevel>(g_gameMode) !is null;
		}

		// the current floor is in the second half of the run's floors
		bool SecondHalf()
		{
			auto gm = cast<MissionGameModeBase>(g_gameMode);
			if (gm is null || gm.m_missionLevel is null || gm.m_missionLevel.m_mission is null)
				return false;
			auto@ levels = gm.m_missionLevel.m_mission.m_levels;
			int i = levels.findByRef(gm.m_missionLevel);
			return i >= 0 && i * 2 >= int(levels.length());
		}

		// what can bite on this floor: 1-star fish, 2-star in the second half,
		// only 3-star in a boss room
		void RunTiers(int &out minTier, int &out maxTier)
		{
			minTier = 1;
			maxTier = TOWN_MAX_TIER;
			if (IsBossLevel())
			{
				minTier = TIERS;
				maxTier = TIERS;
			}
			else if (SecondHalf())
				maxTier = 3;
		}

		// the item level a fish caught here gets, like gear dropped on the floor
		// (g_diffLevel includes NG+); town catches go by the fish's tier
		int CatchItemLevel(PlayerRecord@ rec, Fish@ fish)
		{
			int ilvl = g_inTown ? FISH_ILVL[ClampTier(fish.tier) - 1] : max(1, int(g_diffLevel + 0.5f) + randi(3) - 1);
			if (rec !is null)
				ilvl = min(rec.GetEquipmentDropLevelCap(), ilvl);
			return max(1, ilvl);
		}

		Fish@ RandomFish(int tier)
		{
			array<Fish@> pool;
			for (uint i = 0; i < g_fish.length(); i++)
				if (g_fish[i].tier == tier)
					pool.insertLast(g_fish[i]);
			if (pool.length() == 0)
				return null;
			return pool[randi(pool.length())];
		}

		int ClampTier(int tier)
		{
			if (tier < 1) return 1;
			if (tier > TIERS) return TIERS;
			return tier;
		}

		// ---- coast catches (local) --------------------------------------------------

		Equipment::Item@ MakeFishItem(Fish@ fish, int ilvl)
		{
			auto base = Equipment::BaseItem::Get(fish.ItemId());
			if (base is null)
			{
				HWP::LogError("fishing", "missing BaseItem " + fish.ItemId() + " (tweak/hwp/fishing_items.sval)");
				return null;
			}
			// built directly: the generator would refuse the item's false conditional
			Equipment::Item item;
			item.quality = fish.Quality();
			@item.baseItem = base;
			item.Finalize(randf(), ilvl, 0, null, null);
			return item;
		}

		// the fish goes into the bag, or at your feet when the bag is full;
		// ilvl <= 0: the item level of a catch here. announce: tell the lobby
		void GiveFish(Fish@ fish, int ilvl = -1, bool announce = true)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || fish is null)
				return;
			auto item = MakeFishItem(fish, ilvl > 0 ? ilvl : CatchItemLevel(rec, fish));
			if (item is null)
				HWP::Market::Add(rec, fish.id, 1);
			else if (rec.equipInventory !is null && rec.equipInventory.CanAdd())
				rec.equipInventory.Add(item);
			else
			{
				if (rec.actor !is null)
					Item::DropItem(item, rec.actor.m_unit.GetPosition(), 1, true, rec); // yours alone to pick up
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.bag_full", { { "fish", fish.Name() } }));
			}
			if (!announce)
				return;
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("fish", fish.id);
			b.PopDictionary();
			HWP::Net::Request(CAUGHT, b.Build());
			HWP::Log("fishing", "caught " + fish.id + " (rod " + RodTier() + ", bait " + BaitSummary() + ")");
		}

		// host: tell the lobby
		void OnCaught(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer())
				return;
			auto fish = GetFish(HWP::SV::Str(data, "fish", ""));
			auto rec = GetPlayerRecordByPeer(peer);
			if (fish is null || rec is null)
				return;
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("peer", peer);
			b.PushString("name", rec.GetName());
			b.PushString("fish", fish.id);
			b.PopDictionary();
			HWP::Net::Broadcast(ANNOUNCE, b.Build());
		}

		void OnAnnounce(SValue@ data)
		{
			auto fish = GetFish(HWP::SV::Str(data, "fish", ""));
			if (fish is null || HWP::SV::Int(data, "peer", -1) == int(Lobby::GetLocalPeer()))
				return;
			HWP::Commands::Reply(Resources::GetString(".hwp.fishing.announce", {
				{ "name", HWP::SV::Str(data, "name", "?") }, { "fish", fish.Name() } }));
		}

		// ---- in-run catches (host) --------------------------------------------------

		array<int> g_castsUsed(256, 0);   // host: per peer, reset every level
		array<int> g_pendingTier(256, 0); // host: tier rolled for the peer's current cast
		bool g_lastDenied = false;        // local: the host said no
		int g_biteTier = 0;               // local: tier the host rolled (0 = none pending)
		int g_biteDelay = 0;              // local: ms until that bite

		int CastsLeft(uint8 peer)
		{
			return g_runCasts - g_castsUsed[peer];
		}

		// host: a cast at a hole spends a cast and rolls what is on the line
		void OnCastRequest(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || g_inTown || !g_enabled)
				return;
			if (g_castsUsed[peer] >= g_runCasts)
			{
				HWP::Net::Send(peer, DENIED);
				return;
			}
			g_castsUsed[peer]++;
			// the rod tier is the client's word: the host has no copy of a
			// client's HWP save data. ClampRod caps it, and every tier only
			// moves the odds a little (co-op, everyone runs the mod)
			int minTier, maxTier;
			RunTiers(minTier, maxTier);
			g_pendingTier[peer] = RollTier(HWP::SV::Int(data, "rod", 1), minTier, maxTier);
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("tier", g_pendingTier[peer]);
			b.PushInteger("delay", g_biteMin + randi(g_biteMax - g_biteMin + 1));
			b.PopDictionary();
			HWP::Net::Send(peer, BITE, b.Build());
		}

		// host: the reel hit; the loot is the tier rolled at cast time
		void OnCatch(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || g_inTown || !g_enabled)
				return;
			int tier = g_pendingTier[peer];
			g_pendingTier[peer] = 0;
			if (tier <= 0)
			{
				HWP::Log("fishing", "catch from peer " + peer + " without a cast, ignored");
				return;
			}
			auto rec = GetPlayerRecordByPeer(peer);
			if (rec is null || rec.actor is null)
				return;
			auto table = Item::GetLootTable("hwp_fishing_run_" + tier);
			if (table is null)
			{
				HWP::LogError("fishing", "missing loot table hwp_fishing_run_" + tier);
				return;
			}
			table.SpawnLoot(rec.actor, rec.actor.m_unit.GetPosition());
			// the fish itself goes into the catcher's own bag (bags are local)
			auto fish = RandomFish(tier);
			if (fish !is null)
			{
				SValueBuilder b;
				b.PushDictionary();
				b.PushString("fish", fish.id);
				b.PushInteger("ilvl", CatchItemLevel(rec, fish));
				b.PopDictionary();
				HWP::Net::Send(peer, LANDED, b.Build());
			}
			HWP::Log("fishing", rec.GetName() + " caught tier " + tier + " (" + CastsLeft(peer) + " casts left)");
		}

		// local: the host's fish for our bag
		void OnLanded(SValue@ data)
		{
			auto fish = GetFish(HWP::SV::Str(data, "fish", ""));
			if (fish is null)
				return;
			GiveFish(fish, HWP::SV::Int(data, "ilvl", 1));
			Say(Resources::GetString(".hwp.fishing.caught", { { "fish", fish.Name() } }));
		}

		// local: the host rolled our bite
		void OnBite(SValue@ data)
		{
			g_biteTier = ClampTier(HWP::SV::Int(data, "tier", 1));
			g_biteDelay = HWP::SV::Int(data, "delay", g_biteMin);
			if (g_biteDelay < 100)
				g_biteDelay = 100;
		}

		void OnDenied(SValue@ data)
		{
			g_lastDenied = true;
			HWP::Commands::Reply(Resources::GetString(".hwp.fishing.denied"));
		}

		void ResetCasts()
		{
			for (uint i = 0; i < g_castsUsed.length(); i++)
			{
				g_castsUsed[i] = 0;
				g_pendingTier[i] = 0;
			}
			g_lastDenied = false;
			g_biteTier = 0;
		}

		// ---- spawning ---------------------------------------------------------------

		array<UnitPtr> g_local;  // this machine's coast spots, pirate and wreck
		array<UnitPtr> g_traps;  // this machine's own traps (index = trap)
		bool g_trapsDirty = false; // respawn the trap units next frame (a trap may be mid-interact now)
		vec3 g_piratePos;
		UnitPtr g_pirate;
		int g_pirateTier = -1;
		bool g_pirateWanted = false; // he spawned, so keep him there

		UnitPtr SpawnAt(const string &in unitPath, vec3 pos)
		{
			auto prod = Resources::GetUnitProducer(unitPath);
			if (prod is null)
			{
				HWP::LogError("fishing", "missing " + unitPath);
				return UnitPtr();
			}
			return prod.Produce(g_scene, pos);
		}

		void ClearLocal()
		{
			for (uint i = 0; i < g_local.length(); i++)
				if (g_local[i].IsValid())
					g_local[i].Destroy();
			g_local.removeRange(0, g_local.length());
		}

		// the trading post's tier in the town being shown (0: not built yet)
		int TradingPostTier()
		{
			if (g_currTownRecord is null)
				return 0;
			return g_currTownRecord.GetVariationOnBuilding(HashString("trading_post")) + 1;
		}

		// fishing.pirate_x/y when set, else by the trading post's boat
		vec3 PiratePos()
		{
			g_pirateTier = TradingPostTier();
			int sx = HWP::Settings::GetInt("fishing.pirate_x", NO_POS);
			int sy = HWP::Settings::GetInt("fishing.pirate_y", NO_POS);
			if (sx != NO_POS && sy != NO_POS)
				return vec3(float(sx), float(sy), 0);
			vec2 origin(PLOT_X, PLOT_Y);
			auto prod = Resources::GetUnitProducer(TRADER_UNIT);
			if (prod !is null)
			{
				auto units = g_scene.FetchAllUnitsOfType(prod);
				for (uint i = 0; i < units.length(); i++)
				{
					vec2 o = xy(units[i].GetPosition()) - vec2(TRADER_X, TRADER_Y);
					if (dist(o, vec2(PLOT_X, PLOT_Y)) < 400.0f)
					{
						origin = o;
						break;
					}
				}
			}
			if (g_pirateTier >= 3)
				return vec3(origin.x + ON_BEACH_X, origin.y + ON_BEACH_Y, 0);
			return vec3(origin.x + ON_WRECK_X, origin.y + ON_WRECK_Y, 0);
		}

		// town, every frame: a building upgrade rebuilds the town and takes our
		// units on the trading post's plot with it (the pirate), and a new
		// trading post tier moves his spot; put the coast back either way
		int g_watchTimer = 0;
		void WatchCoast(int ms)
		{
			if (!g_townReady || !g_enabled || !g_coast || !g_pirateWanted)
				return;
			g_watchTimer += ms;
			if (g_watchTimer < WATCH_MS)
				return;
			g_watchTimer = 0;
			if (g_pirate.IsValid() && TradingPostTier() == g_pirateTier)
				return;
			HWP::Log("fishing", "the town changed (trading post tier " + TradingPostTier() + "); placing the coast again");
			SpawnCoast();
		}

		// every machine: the coast spots and the pirate are local units
		void SetupTown()
		{
			// settle the run's trap time even with the coast off, so it never piles up
			ResolveTraps();
			g_townReady = true;
			SpawnCoast();
		}

		void SpawnCoast()
		{
			ClearLocal();
			g_pirateWanted = false;
			if (!g_enabled || !g_coast)
			{
				ClearTraps();
				return;
			}
			for (uint i = 0; i < COAST_X.length(); i++)
			{
				auto u = SpawnAt(SPOT_UNIT, vec3(float(COAST_X[i]), float(COAST_Y[i]), 0));
				if (u.IsValid())
					g_local.insertLast(u);
			}
			SpawnTraps();
			g_piratePos = PiratePos();
			g_pirate = SpawnAt(PIRATE_UNIT, g_piratePos);
			if (g_pirate.IsValid())
			{
				g_local.insertLast(g_pirate);
				g_pirateWanted = true;
			}
			HWP::Log("fishing", "coast: " + COAST_X.length() + " spots; pirate at " + int(g_piratePos.x) + "," + int(g_piratePos.y)
				+ " (trading post tier " + g_pirateTier + ")");
		}

		void ClearTraps()
		{
			for (uint i = 0; i < g_traps.length(); i++)
				if (g_traps[i].IsValid())
					g_traps[i].Destroy();
			g_traps.removeRange(0, g_traps.length());
		}

		// town, every machine: the local player's own traps; a trap with fish
		// shows it (and the map icon)
		void SpawnTraps()
		{
			g_trapsDirty = false;
			ClearTraps();
			if (!g_coast || !g_inTown)
				return;
			for (int i = 0; i < Traps(); i++)
				g_traps.insertLast(SpawnAt(TrapFish(i).length() > 0 ? TRAP_FULL_UNIT : TRAP_UNIT, TrapPos(i)));
		}

		// host, a run: a spot beside a potion-refill well; a boss room always
		// gets one (beside its well, else a bucket by the players)
		void SetupRun(PlayerRecord@ host)
		{
			bool boss = IsBossLevel();
			if (!boss && randi(100) >= g_runChance)
				return;
			array<UnitPtr> wells;
			for (uint k = 0; k < WELL_UNITS.length(); k++)
			{
				auto prod = Resources::GetUnitProducer(WELL_UNITS[k]);
				if (prod is null)
					continue;
				auto units = g_scene.FetchAllUnitsOfType(prod);
				for (uint i = 0; i < units.length(); i++)
					wells.insertLast(units[i]);
			}
			// a free, reachable spot beside a well (wells in random order)
			vec3 p;
			while (wells.length() > 0)
			{
				int k = randi(wells.length());
				if (HWP::Spawner::FreeSpot(wells[k].GetPosition(), 80.0f, p, 40.0f)) // wells are up to 32 wide
				{
					SpawnAt(WELL_SPOT_UNIT, p);
					HWP::Log("fishing", "run spot by a well at " + int(p.x) + "," + int(p.y) + (boss ? " (boss room)" : ""));
					return;
				}
				wells.removeAt(k);
			}
			// a boss room always gets one: a bucket beside the host
			if (boss && host !is null && host.actor !is null)
			{
				vec3 at = host.actor.m_unit.GetPosition();
				if (!HWP::Spawner::FreeSpot(at, 72.0f, p))
					p = at + vec3(32, 0, 0);
				SpawnAt(BUCKET_UNIT, p);
				HWP::Log("fishing", "boss room without a free well spot: placed a fishing bucket at " + int(p.x) + "," + int(p.y));
			}
		}

		void SelfCheck()
		{
			array<string> tables;
			for (int t = 1; t <= TIERS; t++)
				tables.insertLast("hwp_fishing_run_" + t);
			HWP::CheckLootTables("fishing", tables);
			HWP::CheckUnits("fishing", { SPOT_UNIT, HOLE_UNIT, WELL_SPOT_UNIT, BUCKET_UNIT, TRAP_UNIT, TRAP_FULL_UNIT, PIRATE_UNIT });
			int missing = 0;
			for (uint i = 0; i < g_fish.length(); i++)
			{
				if (Equipment::BaseItem::Get(g_fish[i].ItemId()) is null)
				{
					HWP::LogError("fishing", "missing BaseItem " + g_fish[i].ItemId());
					missing++;
				}
			}
			HWP::Log("fishing", "self-check done: " + g_fish.length() + " fish, " + missing + " missing items");
		}

		// ---- commands -----------------------------------------------------------------

		void CmdFishing(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			string sub = args.length() >= 1 ? args[0] : "";
			if (sub == "hole")
			{
				if (!Network::IsServer() || !g_debug)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.fishing.debug_off"));
					return;
				}
				if (rec is null || rec.actor is null)
					return;
				SpawnAt(HOLE_UNIT, rec.actor.m_unit.GetPosition() + vec3(40, 0, 0));
				return;
			}
			if (sub == "buy")
			{
				g_lastMessage = "";
				string what = args.length() >= 2 ? args[1] : "";
				if (what == "bait" || what == "worm")
					BuyBait(1, BAIT_PACK[0], BAIT_PACK_PRICE[0]);
				else if (what == "bait20")
					BuyBait(1, BAIT_BIG, BAIT_BIG_PRICE);
				else if (BaitKind(what) > 1)
					BuyBait(BaitKind(what), BAIT_PACK[BaitKind(what) - 1], BAIT_PACK_PRICE[BaitKind(what) - 1]);
				else if (what == "rod")
					BuyRod();
				else if (what == "trap")
					BuyTrap();
				else
				{
					HWP::Commands::Reply("usage: hwp fishing buy bait|bait20|shrimp|squid|rod|trap");
					return;
				}
				if (!g_lastMessage.isEmpty())
					HWP::Commands::Reply(g_lastMessage);
				return;
			}
			if (sub == "catch")
			{
				// debug: land a fish of a tier without the minigame
				if (!g_debug)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.fishing.debug_off"));
					return;
				}
				int tier = args.length() >= 2 ? ClampTier(parseInt(args[1])) : RollTier(RodTier(), BAIT_MIN_TIER[SelectedBait() - 1], BAIT_MAX_TIER[SelectedBait() - 1]);
				auto fish = RandomFish(tier);
				GiveFish(fish);
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.caught", { { "fish", fish.Name() } }));
				return;
			}
			if (sub == "bait")
			{
				// 'bait <kind>': cast with that bait; debug 'bait <kind> <n>': set your bait
				int kind = args.length() >= 2 ? BaitKind(args[1]) : 0;
				if (kind == 0)
				{
					HWP::Commands::Reply("usage: hwp fishing bait worm|shrimp|squid [n]; you have " + BaitSummary());
					return;
				}
				if (args.length() >= 3)
				{
					if (!g_debug)
					{
						HWP::Commands::Reply(Resources::GetString(".hwp.fishing.debug_off"));
						return;
					}
					SetBait(parseInt(args[2]), kind);
				}
				SelectBait(kind);
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.bait_selected", { { "bait", BaitName(kind) }, { "n", Bait(kind) }, { "stars", BaitStars(kind) } }));
				return;
			}
			if (sub == "sell")
			{
				g_lastMessage = "";
				SellFish();
				HWP::Commands::Reply(g_lastMessage);
				return;
			}
			if (sub == "traps")
			{
				// debug 'traps <minutes>': fill the traps as if back from a run that long
				if (args.length() >= 2)
				{
					if (!g_debug)
					{
						HWP::Commands::Reply(Resources::GetString(".hwp.fishing.debug_off"));
						return;
					}
					HWP::SaveData::Local().SetInt(KEY_RUN_MS, parseInt(args[1]) * 60000);
					ResolveTraps();
				}
				string list = "";
				for (int i = 0; i < Traps(); i++)
				{
					auto ids = TrapFish(i);
					list += (i > 0 ? "; " : "") + (i + 1) + ": " + (ids.length() == 0 ? "-" : join(ids, ","));
				}
				int runMin = (HWP::SaveData::Local().GetInt(KEY_RUN_MS, 0) + g_runMs) / 60000;
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.trap.status", {
					{ "n", Traps() }, { "max", MAX_TRAPS }, { "list", list.isEmpty() ? "-" : list }, { "min", runMin } }));
				return;
			}
			auto s = HWP::Market::Summary(rec, "fish");
			int minTier, maxTier;
			RunTiers(minTier, maxTier);
			if (g_inTown)
			{
				minTier = BAIT_MIN_TIER[SelectedBait() - 1];
				maxTier = BAIT_MAX_TIER[SelectedBait() - 1];
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.fishing.stars_here", {
				{ "min", StarOf(minTier) }, { "max", StarOf(maxTier) }, { "tokens", HWP::Market::Tokens(rec) } }));
			HWP::Commands::Reply(Resources::GetString(".hwp.fishing.status", {
				{ "state", g_enabled ? "on" : "off" }, { "spots", g_coast ? int(COAST_X.length()) : 0 },
				{ "x", int(g_piratePos.x) }, { "y", int(g_piratePos.y) }, { "rod", RodText(false) },
				{ "chance", g_runChance }, { "casts", g_runCasts }, { "catch", s.isEmpty() ? "-" : s } }));
		}
	}
}

// Interact class of the fishing units: opens the minigame.
class HWPFishingSpot : AShopContent
{
	bool m_inRun = false;

	HWPFishingSpot() {}
	HWPFishingSpot(UnitPtr u, SValue& params)
	{
		super(u, params);
		m_inRun = GetParamBool(u, params, "in-run", false, false);
	}

	bool CanInteract(PlayerRecord@ player) override { return HWP::Fishing::g_enabled; }

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPFishingMenu(guiBuilder, this);
		return m_window;
	}

	string GetName() override { return m_inRun ? "hwp_fishing_hole" : "hwp_fishing_spot"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class HWPFishingMenu : AWindowObject
{
	HWPFishingSpot@ m_spot;
	TextWidget@ m_status;
	TextWidget@ m_log;
	TextWidget@ m_casts;
	TextWidget@ m_wares;
	Widget@ m_zone;
	Widget@ m_marker;
	ScalableSpriteButtonWidget@ m_castButton;
	ScalableSpriteButtonWidget@ m_baitButton;
	int m_baitUsed = 1; // the bait kind of the current coast cast

	int m_state = 0;
	int m_timer = 0;
	int m_tier = 1;
	int m_rod = 1;
	float m_markerPos = 0;
	int m_markerDir = 1;
	int m_zoneX = 0;
	int m_zoneW = 60;

	HWPFishingMenu(GUIBuilder@ b, HWPFishingSpot@ spot)
	{
		super(b, "gui/hwp_fishing.gui");
		PauseGame(true, true);
		@m_spot = spot;

		@m_status = cast<TextWidget>(m_widget.GetWidgetById("status"));
		@m_log = cast<TextWidget>(m_widget.GetWidgetById("log"));
		@m_casts = cast<TextWidget>(m_widget.GetWidgetById("casts"));
		@m_wares = cast<TextWidget>(m_widget.GetWidgetById("wares"));
		@m_zone = m_widget.GetWidgetById("zone");
		@m_marker = m_widget.GetWidgetById("marker");
		@m_castButton = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("cast-btn"));
		@m_baitButton = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("bait-btn"));
		if (m_baitButton !is null && m_spot.m_inRun)
			m_baitButton.m_visible = false; // run holes need no bait

		auto title = cast<TextWidget>(m_widget.GetWidgetById("title"));
		if (title !is null)
			title.SetText(Resources::GetString(m_spot.m_inRun ? ".hwp.fishing.hole" : ".hwp.fishing.spot"));

		m_rod = HWP::Fishing::RodTier();
		HWP::Fishing::g_lastDenied = false;
		HWP::Fishing::g_biteTier = 0;
		SetState(HWP::Fishing::STATE_IDLE);
		RefreshInfo();
	}

	void RefreshInfo()
	{
		auto rec = GetLocalPlayerRecord();
		if (m_spot.m_inRun)
		{
			int left = HWP::Fishing::CastsLeft(uint8(Lobby::GetLocalPeer()));
			if (!Network::IsServer())
				left = HWP::Fishing::g_lastDenied ? 0 : -1;
			m_casts.SetText(left >= 0 ? Resources::GetString(".hwp.fishing.casts_left", { { "n", left } }) : "");
			m_wares.SetText(HWP::Fishing::RodName(m_rod));
			return;
		}
		int kind = HWP::Fishing::SelectedBait();
		m_casts.SetText(Resources::GetString(".hwp.fishing.bait_left", { { "bait", HWP::Fishing::BaitName(kind) }, { "n", HWP::Fishing::Bait(kind) }, { "rod", HWP::Fishing::RodName(m_rod) } }));
		if (m_baitButton !is null)
			m_baitButton.SetText(Resources::GetString(".hwp.fishing.bait_button", { { "bait", HWP::Fishing::BaitName(kind) }, { "stars", HWP::Fishing::BaitStars(kind) } }));
		auto s = HWP::Market::Summary(rec, "fish");
		m_wares.SetText(s.isEmpty() ? Resources::GetString(".hwp.fishing.wares_none")
			: Resources::GetString(".hwp.fishing.wares", { { "list", s } }));
	}

	// a widget's offset only takes effect after an Invalidate (its origin is
	// computed in DoLayout)
	void Place(Widget@ w, float x)
	{
		w.m_offset = vec2(x, 0);
		w.Invalidate();
	}

	void SetState(int state)
	{
		m_state = state;
		if (state == HWP::Fishing::STATE_IDLE)
		{
			m_status.SetText(Resources::GetString(".hwp.fishing.idle"));
			m_castButton.SetText(Resources::GetString(".hwp.fishing.cast"));
			m_zone.m_visible = false;
			m_marker.m_visible = false;
		}
		else if (state == HWP::Fishing::STATE_WAIT)
		{
			// the coast: roll the bite here; a hole: the host answers fishing.bite
			m_timer = m_spot.m_inRun ? -1 : HWP::Fishing::g_biteMin + randi(HWP::Fishing::g_biteMax - HWP::Fishing::g_biteMin + 1);
			m_status.SetText(Resources::GetString(".hwp.fishing.waiting"));
			m_castButton.SetText(Resources::GetString(".hwp.fishing.waiting"));
			m_log.SetText("");
			m_zone.m_visible = false;
			m_marker.m_visible = false;
		}
		else if (state == HWP::Fishing::STATE_BITE)
		{
			if (!m_spot.m_inRun)
				m_tier = HWP::Fishing::RollTier(m_rod, HWP::Fishing::BAIT_MIN_TIER[m_baitUsed - 1], HWP::Fishing::BAIT_MAX_TIER[m_baitUsed - 1]); // a run spot: m_tier came from the host
			m_zoneW = int(float(HWP::Fishing::ZONE_WIDTH[m_tier - 1]) * HWP::Fishing::ZoneScale(m_rod));
			if (m_zoneW > HWP::Fishing::BAR_WIDTH / 2)
				m_zoneW = HWP::Fishing::BAR_WIDTH / 2;
			m_zoneX = randi(HWP::Fishing::BAR_WIDTH - m_zoneW + 1);
			m_markerPos = 0;
			m_markerDir = 1;
			m_timer = HWP::Fishing::BITE_WINDOW;
			m_zone.m_width = m_zoneW;
			Place(m_zone, float(m_zoneX));
			m_zone.m_visible = true;
			Place(m_marker, 0);
			m_marker.m_visible = true;
			m_status.SetText(Resources::GetString(".hwp.fishing.bite"));
			m_castButton.SetText(Resources::GetString(".hwp.fishing.reel"));
		}
		else if (state == HWP::Fishing::STATE_RESULT)
		{
			m_castButton.SetText(Resources::GetString(".hwp.fishing.cast_again"));
			m_status.SetText(Resources::GetString(".hwp.fishing.idle"));
		}
		m_widget.Invalidate();
	}

	void Reel()
	{
		float center = m_markerPos + 1.5f;
		bool hit = center >= float(m_zoneX) && center <= float(m_zoneX + m_zoneW);
		m_marker.m_visible = false;
		m_zone.m_visible = false;
		if (!hit)
		{
			m_log.SetText(Resources::GetString(".hwp.fishing.escaped"));
			SetState(HWP::Fishing::STATE_RESULT);
			return;
		}
		if (m_spot.m_inRun)
		{
			HWP::Net::Request(HWP::Fishing::CATCH);
			m_log.SetText(Resources::GetString(".hwp.fishing.caught_run"));
		}
		else
		{
			auto fish = HWP::Fishing::RandomFish(m_tier);
			if (fish !is null)
			{
				HWP::Fishing::GiveFish(fish);
				m_log.SetText(Resources::GetString(".hwp.fishing.caught", { { "fish", fish.Name() } }));
			}
		}
		SetState(HWP::Fishing::STATE_RESULT);
		RefreshInfo();
	}

	float MarkerSpeed()
	{
		return HWP::Fishing::MARKER_SPEED[m_tier - 1] * HWP::Fishing::SpeedScale(m_rod);
	}

	bool Update(int ms, GameInput& gameInput, MenuInput& menuInput) override
	{
		bool result = AWindowObject::Update(ms, gameInput, menuInput);

		if (m_state == HWP::Fishing::STATE_WAIT)
		{
			if (m_spot.m_inRun && m_timer < 0)
			{
				// waiting for the host's roll
				if (HWP::Fishing::g_biteTier > 0)
				{
					m_tier = HWP::Fishing::g_biteTier;
					m_timer = HWP::Fishing::g_biteDelay;
					HWP::Fishing::g_biteTier = 0;
				}
				else if (HWP::Fishing::g_lastDenied)
				{
					m_log.SetText(Resources::GetString(".hwp.fishing.denied"));
					SetState(HWP::Fishing::STATE_RESULT);
					RefreshInfo();
				}
			}
			else
			{
				m_timer -= ms;
				if (m_timer <= 0)
					SetState(HWP::Fishing::STATE_BITE);
			}
		}
		else if (m_state == HWP::Fishing::STATE_BITE)
		{
			m_markerPos += MarkerSpeed() * float(ms) * float(m_markerDir);
			if (m_markerPos >= float(HWP::Fishing::BAR_WIDTH - 3))
			{
				m_markerPos = float(HWP::Fishing::BAR_WIDTH - 3);
				m_markerDir = -1;
			}
			else if (m_markerPos <= 0)
			{
				m_markerPos = 0;
				m_markerDir = 1;
			}
			Place(m_marker, float(int(m_markerPos)));
			m_timer -= ms;
			if (menuInput.Forward.Pressed)
				Reel();
			else if (m_timer <= 0)
			{
				m_log.SetText(Resources::GetString(".hwp.fishing.escaped"));
				SetState(HWP::Fishing::STATE_RESULT);
			}
		}
		else if (HWP::Fishing::g_lastDenied && m_spot.m_inRun)
			RefreshInfo();

		return result;
	}

	void OnClose() override
	{
		PauseGame(false, true);
	}

	void Cast()
	{
		if (m_spot.m_inRun)
		{
			if ((Network::IsServer() && HWP::Fishing::CastsLeft(uint8(Lobby::GetLocalPeer())) <= 0) || HWP::Fishing::g_lastDenied)
			{
				m_log.SetText(Resources::GetString(".hwp.fishing.denied"));
				return;
			}
			HWP::Fishing::g_biteTier = 0;
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("rod", m_rod);
			b.PopDictionary();
			HWP::Net::Request(HWP::Fishing::CAST, b.Build());
		}
		else
		{
			// the coast: a cast takes a bait of the selected kind, bite or not
			int kind = HWP::Fishing::SelectedBait();
			if (HWP::Fishing::Bait(kind) <= 0)
			{
				m_log.SetText(Resources::GetString(".hwp.fishing.no_bait", { { "bait", HWP::Fishing::BaitName(kind) } }));
				return;
			}
			m_baitUsed = kind;
			HWP::Fishing::SetBait(HWP::Fishing::Bait(kind) - 1, kind);
			RefreshInfo();
		}
		SetState(HWP::Fishing::STATE_WAIT);
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
		{
			m_manager.CloseWindow(this);
			return;
		}
		if (name == "bait")
		{
			// not mid-cast: the bite is rolled for the bait already on the hook
			if (m_state == HWP::Fishing::STATE_IDLE || m_state == HWP::Fishing::STATE_RESULT)
			{
				HWP::Fishing::CycleBait();
				RefreshInfo();
			}
			return;
		}
		if (name == "cast")
		{
			if (m_state == HWP::Fishing::STATE_BITE)
				Reel();
			else if (m_state == HWP::Fishing::STATE_IDLE || m_state == HWP::Fishing::STATE_RESULT)
				Cast();
		}
	}
}

// Interact class of a fish trap (doodads/hwp/fish_trap.unit): empties it
// into your bag. Each machine only spawns its own player's traps.
class HWPFishTrap : AShopContent
{
	HWPFishTrap() {}
	HWPFishTrap(UnitPtr u, SValue& params) { super(u, params); }

	bool CanInteract(PlayerRecord@ player) override
	{
		return HWP::Fishing::g_enabled && player.local && HWP::Fishing::TrapIndexAt(m_unit.GetPosition()) >= 0;
	}

	void Interact(PlayerRecord@ player, int interactLevel) override
	{
		HWP::Fishing::CollectTrap(HWP::Fishing::TrapIndexAt(m_unit.GetPosition()));
	}

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override { return null; }
	string GetName() override { return "hwp_fish_trap"; }
	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

// Interact class of the pirate fisherman: bait, rod upgrades and fish traps;
// he buys fish for bet tokens.
class HWPPirateShop : AShopContent
{
	HWPPirateShop() {}
	HWPPirateShop(UnitPtr u, SValue& params) { super(u, params); }

	bool CanInteract(PlayerRecord@ player) override { return HWP::Fishing::g_enabled; }

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPPirateMenu(guiBuilder);
		return m_window;
	}

	string GetName() override { return "hwp_pirate"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class HWPPirateMenu : AWindowObject
{
	TextWidget@ m_greeting;
	TextWidget@ m_message;
	TextWidget@ m_status;
	TextWidget@ m_gold;
	ScalableSpriteButtonWidget@ m_bait;
	ScalableSpriteButtonWidget@ m_baitBig;
	ScalableSpriteButtonWidget@ m_shrimp;
	ScalableSpriteButtonWidget@ m_squid;
	ScalableSpriteButtonWidget@ m_rod;
	ScalableSpriteButtonWidget@ m_trap;
	ScalableSpriteButtonWidget@ m_sell;
	int m_seen = -1;

	HWPPirateMenu(GUIBuilder@ b)
	{
		super(b, "gui/hwp_pirate.gui");
		PauseGame(true, true);
		@m_greeting = cast<TextWidget>(m_widget.GetWidgetById("greeting"));
		@m_message = cast<TextWidget>(m_widget.GetWidgetById("message"));
		@m_status = cast<TextWidget>(m_widget.GetWidgetById("status"));
		@m_gold = cast<TextWidget>(m_widget.GetWidgetById("gold"));
		@m_bait = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("bait-btn"));
		@m_baitBig = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("bait20-btn"));
		@m_shrimp = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("shrimp-btn"));
		@m_squid = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("squid-btn"));
		@m_rod = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("rod-btn"));
		@m_trap = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("trap-btn"));
		@m_sell = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("sell-btn"));
		m_greeting.SetText(Resources::GetString(".hwp.fishing.pirate.hello" + (1 + randi(5))));
		HWP::Fishing::g_lastMessage = "";
		Refresh();
	}

	void Refresh()
	{
		m_seen = HWP::Fishing::g_version;
		auto rec = GetLocalPlayerRecord();
		m_message.SetText(HWP::Fishing::g_lastMessage);
		m_status.SetText(HWP::Fishing::RodText());
		m_gold.SetText(Resources::GetString(".hwp.fishing.pirate.gold", { { "n", rec is null ? 0 : rec.GetMaterial(MaterialType::Gold) }, { "tokens", HWP::Market::Tokens(rec) } }));
		m_bait.SetText(BuyText(1, HWP::Fishing::BAIT_PACK[0], HWP::Fishing::BAIT_PACK_PRICE[0]));
		m_baitBig.SetText(BuyText(1, HWP::Fishing::BAIT_BIG, HWP::Fishing::BAIT_BIG_PRICE));
		m_shrimp.SetText(BuyText(2, HWP::Fishing::BAIT_PACK[1], HWP::Fishing::BAIT_PACK_PRICE[1]));
		m_squid.SetText(BuyText(3, HWP::Fishing::BAIT_PACK[2], HWP::Fishing::BAIT_PACK_PRICE[2]));
		int next = HWP::Fishing::RodTier() + 1;
		if (next > HWP::Fishing::ROD_TIERS)
			m_rod.SetText(Resources::GetString(".hwp.fishing.pirate.rod_none"));
		else
			m_rod.SetText(Resources::GetString(".hwp.fishing.pirate.buy_rod", { { "rod", HWP::Fishing::RodName(next) }, { "price", HWP::Fishing::ROD_PRICE[next] } }));
		int traps = HWP::Fishing::Traps();
		if (traps >= HWP::Fishing::MAX_TRAPS)
			m_trap.SetText(Resources::GetString(".hwp.fishing.pirate.trap_none", { { "max", HWP::Fishing::MAX_TRAPS } }));
		else
			m_trap.SetText(Resources::GetString(".hwp.fishing.pirate.buy_trap", { { "n", traps + 1 }, { "max", HWP::Fishing::MAX_TRAPS }, { "price", HWP::Fishing::TRAP_PRICE[traps] } }));
		auto fish = HWP::Market::Worth(rec, "fish");
		if (fish.count <= 0)
			m_sell.SetText(Resources::GetString(".hwp.fishing.pirate.sell_none"));
		else
			m_sell.SetText(Resources::GetString(".hwp.fishing.pirate.sell", { { "n", fish.count }, { "tokens", fish.tokens } }));
		m_widget.Invalidate();
	}

	string BuyText(int kind, int n, int price)
	{
		return Resources::GetString(".hwp.fishing.pirate.buy_bait", { { "n", n }, { "bait", HWP::Fishing::BaitName(kind) }, { "price", price } });
	}

	bool Update(int ms, GameInput& gameInput, MenuInput& menuInput) override
	{
		bool result = AWindowObject::Update(ms, gameInput, menuInput);
		if (m_seen != HWP::Fishing::g_version)
			Refresh();
		return result;
	}

	void OnClose() override
	{
		PauseGame(false, true);
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
			m_manager.CloseWindow(this);
		else if (name == "bait")
			HWP::Fishing::BuyBait(1, HWP::Fishing::BAIT_PACK[0], HWP::Fishing::BAIT_PACK_PRICE[0]);
		else if (name == "bait20")
			HWP::Fishing::BuyBait(1, HWP::Fishing::BAIT_BIG, HWP::Fishing::BAIT_BIG_PRICE);
		else if (name == "shrimp")
			HWP::Fishing::BuyBait(2, HWP::Fishing::BAIT_PACK[1], HWP::Fishing::BAIT_PACK_PRICE[1]);
		else if (name == "squid")
			HWP::Fishing::BuyBait(3, HWP::Fishing::BAIT_PACK[2], HWP::Fishing::BAIT_PACK_PRICE[2]);
		else if (name == "rod")
			HWP::Fishing::BuyRod();
		else if (name == "trap")
			HWP::Fishing::BuyTrap();
		else if (name == "sell")
			HWP::Fishing::SellFish();
	}
}

// The fishing rod corner of the character menu's gear grid (core
// hwp-gear-slot widget hwp-gear-rod): rod tier, its bonuses and your bait.
class HWPFishingRodSlot : HWP::Gear::Slot
{
	ScriptSprite@ Icon() override
	{
		return ScriptSprite(Resources::GetTexture2D("items/tradeware/base.png"), vec4(64, 0, 16, 16));
	}

	string Title() override
	{
		return HWP::Fishing::RodName(HWP::Fishing::RodTier());
	}

	string Text() override
	{
		return HWP::Fishing::RodText();
	}
}

// a bait kind's count in the materials tab's Supplies section (core
// Materials.as); gui/hwp/bait.png has a 16x16 cell per kind
class HWPBaitMaterial : HWP::Materials::Material
{
	int m_kind;
	HWPBaitMaterial(int kind) { m_kind = kind; }

	ScriptSprite@ Icon() override
	{
		return ScriptSprite(Resources::GetTexture2D("gui/hwp/bait.png"), vec4((m_kind - 1) * 16, 0, 13, 13));
	}

	int Count() override
	{
		return HWP::Fishing::Bait(m_kind);
	}

	string Title() override
	{
		return HWP::Fishing::BaitName(m_kind);
	}

	string Text() override
	{
		string id = HWP::Fishing::BAIT_IDS[m_kind - 1];
		string text = Resources::GetString(".hwp.fishing.bait." + id + ".desc", { { "stars", HWP::Fishing::BaitStars(m_kind) } });
		if (HWP::Fishing::SelectedBait() == m_kind)
			text += "\n" + Resources::GetString(".hwp.fishing.bait.on_hook");
		return text;
	}
}

namespace Modules
{
	class HWPFishingModule : Module, HWP::ModuleStart
	{
		bool m_spawnDone = true;
		int m_delay = 0;

		HWPFishingModule()
		{
			super("hwp-fishing");
			HWP::Fishing::DefineFish();
			HWP::Settings::Sync("fishing.");
			HWP::Fishing::RefreshSettings();
			HWP::Gear::Register("hwp-gear-rod", HWPFishingRodSlot());
			for (uint i = 0; i < HWP::Fishing::BAIT_IDS.length(); i++)
				HWP::Materials::Register("hwp-mat-bait-" + HWP::Fishing::BAIT_IDS[i], HWPBaitMaterial(i + 1));
			HWP::Net::OnRequest(HWP::Fishing::CAST, HWP::Net::RequestHandler(HWP::Fishing::OnCastRequest));
			HWP::Net::OnRequest(HWP::Fishing::CATCH, HWP::Net::RequestHandler(HWP::Fishing::OnCatch));
			HWP::Net::OnRequest(HWP::Fishing::CAUGHT, HWP::Net::RequestHandler(HWP::Fishing::OnCaught));
			HWP::Net::OnEvent(HWP::Fishing::BITE, HWP::Net::EventHandler(HWP::Fishing::OnBite));
			HWP::Net::OnEvent(HWP::Fishing::DENIED, HWP::Net::EventHandler(HWP::Fishing::OnDenied));
			HWP::Net::OnEvent(HWP::Fishing::ANNOUNCE, HWP::Net::EventHandler(HWP::Fishing::OnAnnounce));
			HWP::Net::OnEvent(HWP::Fishing::LANDED, HWP::Net::EventHandler(HWP::Fishing::OnLanded));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Fishing::OnSettingChanged));
			HWP::Commands::Register("fishing", " fishing status; 'buy bait|bait20|shrimp|squid|rod|trap', 'bait worm|shrimp|squid' (cast with it), 'sell' (fish for bet tokens), 'traps'; debug: 'hole', 'catch [tier]', 'bait <kind> <n>', 'traps <minutes>'", HWP::Commands::Handler(HWP::Fishing::CmdFishing));
			HWP::Fishing::SelfCheck();
		}

		void Start(StartMode sMode)
		{
			HWP::Fishing::RefreshSettings();
			HWP::Fishing::ResetCasts();
			HWP::Fishing::g_local.removeRange(0, HWP::Fishing::g_local.length());
			HWP::Fishing::g_traps.removeRange(0, HWP::Fishing::g_traps.length());
			HWP::Fishing::Changed();
			HWP::Fishing::g_townReady = false;
			HWP::Fishing::g_pirateWanted = false;
			m_spawnDone = false;
			m_delay = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (!g_inTown && !paused && HWP::Fishing::g_enabled)
				HWP::Fishing::TickRun(ms);
			if (g_inTown && HWP::Fishing::g_trapsDirty && m_spawnDone)
				HWP::Fishing::SpawnTraps();
			if (g_inTown && m_spawnDone)
				HWP::Fishing::WatchCoast(ms);
			if (m_spawnDone)
				return;
			m_delay += ms;
			if (m_delay < 600)
				return;
			// a client sets the coast up from the host's fishing.* settings
			if (g_inTown && !HWP::Settings::RemoteReady() && m_delay < 8000)
				return;
			if (!HWP::Fishing::g_enabled)
			{
				m_spawnDone = true;
				return;
			}
			if (g_inTown && GetLocalPlayerRecord() is null && m_delay < 8000)
				return; // the traps are the local character's
			if (g_inTown)
			{
				// every machine places its own coast spots and pirate
				m_spawnDone = true;
				HWP::Fishing::SetupTown();
				return;
			}
			if (!Network::IsServer())
			{
				m_spawnDone = true;
				return;
			}
			// a run: wait for the host's player to exist, then maybe place a hole
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.actor is null)
			{
				if (m_delay > 8000)
					m_spawnDone = true;
				return;
			}
			m_spawnDone = true;
			HWP::Fishing::SetupRun(rec);
		}
	}
}
