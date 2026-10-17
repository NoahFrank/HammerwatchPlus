// Fishing. Spots along the town's west coast (doodads/hwp/fishing_spot.unit,
// spawned locally on every machine) run a timing minigame on the local
// machine. A cast costs one bait; the catch is a fish item in your bag (a
// weak main-hand weapon, tweak/hwp/fishing_items.sval) that sells at the
// Gambler, and the lobby hears about it. Your rod (per character, tier 1 is
// free) widens the catch zone, slows the marker and improves the odds. A
// pirate fisherman sits on the half-buried boat by the trading post and sells
// bait and rod upgrades.
//
// At the start of a run the host sometimes spawns a fishing hole next to the
// players. A cast there asks the host (`fishing.cast`): it spends one of the
// player's casts for the level, rolls the tier and the bite delay and answers
// `fishing.bite`; the minigame then runs with that tier and a hit sends
// `fishing.catch`, which spawns the loot of the host-rolled tier from
// tweak/hwp/loot_fishing.sval. Clients never choose what they catch there;
// holes need no bait.
namespace HWP
{
	namespace Fishing
	{
		const string SPOT_UNIT = "doodads/hwp/fishing_spot.unit";
		const string HOLE_UNIT = "doodads/hwp/fishing_hole.unit";
		const string PIRATE_UNIT = "doodads/hwp/pirate_fisher.unit";
		const string WRECK_UNIT = "doodads/hwp/pirate_wreck.unit";
		const string VANILLA_WRECK = "doodads/generic/boat_small_wreck.unit";
		const string VANILLA_BOAT = "doodads/generic/boat_small.unit";
		const string CAST = "fishing.cast";         // client -> host: { rod } a cast at a hole
		const string BITE = "fishing.bite";         // host -> peer: { tier, delay }
		const string CATCH = "fishing.catch";       // client -> host: the reel hit
		const string DENIED = "fishing.denied";     // host -> peer: no casts left
		const string CAUGHT = "fishing.caught";     // client -> host: { fish } a coast catch
		const string ANNOUNCE = "fishing.announce"; // host -> all: { peer, name, fish }
		const string KEY_ROD = "fishing.rod";       // per character: rod tier (1 = the free one)
		const string KEY_BAIT = "fishing.bait";     // per character: bait count
		const int TIERS = 4;
		const int ROD_TIERS = 4;
		const array<int> ROD_PRICE = { 0, 0, 400, 1200, 3000 };
		const int BAIT_SMALL = 5;
		const int BAIT_SMALL_PRICE = 50;
		const int BAIT_BIG = 20;
		const int BAIT_BIG_PRICE = 180;
		const int BITE_WINDOW = 2500;           // ms to reel after a bite
		const int BAR_WIDTH = 240;              // px, matches gui/hwp_fishing.gui
		const int STATE_IDLE = 0;
		const int STATE_WAIT = 1;
		const int STATE_BITE = 2;
		const int STATE_RESULT = 3;
		const array<int> ZONE_WIDTH = { 64, 44, 28, 16 };          // per fish tier, px of a 240 px bar
		const array<float> MARKER_SPEED = { 0.12f, 0.16f, 0.2f, 0.26f }; // px per ms
		const array<int> FISH_ILVL = { 1, 5, 10, 15 };

		// The west coast of the town (prefabs/town/segments/base.lvl, its
		// water_coastline pieces), a little inland so the angler stands on the
		// beach and the fish swim in the water to the west.
		const array<int> COAST_X = { -1180, -1308, -1436, -1476, -1388, -1372 };
		const array<int> COAST_Y = { -184, 56, 272, 424, 680, 960 };
		// The half-buried boat of trading post tiers 0-2: the plot at -1536,256
		// plus the wreck's 320,-112 in the prefab.
		const int WRECK_X = -1216;
		const int WRECK_Y = 144;

		class Fish
		{
			string id;
			int tier;
			int price;
			Fish(const string &in id_, int tier_, int price_) { id = id_; tier = tier_; price = price_; }
			string Name() { return Resources::GetString(".hwp.fishing.fish." + id); }
			string ItemId() { return "hwp_fish_" + id; }
		}
		array<Fish@> g_fish;

		void AddFish(const string &in id, int tier, int price)
		{
			Fish@ f = Fish(id, tier, price);
			g_fish.insertLast(f);
			HWP::Market::Register(id, ".hwp.fishing.fish." + id, price, "fish", f.ItemId());
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

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("fishing.") == 0)
				RefreshSettings();
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
		int Bait() { return HWP::SaveData::Local().GetInt(KEY_BAIT, 0); }

		void Changed()
		{
			g_version++;
			HWP::Gear::Changed();
		}

		void SetBait(int n)
		{
			HWP::SaveData::Local().SetInt(KEY_BAIT, n < 0 ? 0 : n);
			Changed();
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

		void BuyBait(int n, int price)
		{
			if (!Pay(price))
				return;
			SetBait(Bait() + n);
			Say(Resources::GetString(".hwp.fishing.pirate.bait_bought", { { "n", n }, { "total", Bait() } }));
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

		// the rod's bonuses and your bait; one line for chat, two for tooltips
		string RodText(bool lines = true)
		{
			int rod = RodTier();
			string text = rod <= 1 ? Resources::GetString(".hwp.fishing.rod_text_base", { { "rod", RodName(rod) } })
				: Resources::GetString(".hwp.fishing.rod_text", { { "rod", RodName(rod) }, { "tier", rod },
				{ "zone", int(ZoneScale(rod) * 100.0f + 0.5f) - 100 }, { "speed", 100 - int(SpeedScale(rod) * 100.0f + 0.5f) } });
			return text + (lines ? "\n" : " ") + Resources::GetString(".hwp.fishing.rod_bait", { { "n", Bait() } });
		}

		// ---- rolls ------------------------------------------------------------------

		// per mille: the tier 4 / 3 / 2 thresholds grow with the rod
		int RollTier(int rod = 1)
		{
			int r = ClampRod(rod) - 1;
			int roll = randi(1000);
			if (roll < 40 + 15 * r) return 4;
			if (roll < 170 + 40 * r) return 3;
			if (roll < 450 + 30 * r) return 2;
			return 1;
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

		Equipment::Item@ MakeFishItem(Fish@ fish)
		{
			auto base = Equipment::BaseItem::Get(fish.ItemId());
			if (base is null)
			{
				HWP::LogError("fishing", "missing BaseItem " + fish.ItemId() + " (tweak/hwp/fishing_items.sval)");
				return null;
			}
			// built directly: the generator would refuse the item's false conditional
			Equipment::Item item;
			item.quality = Item::Quality::Common;
			@item.baseItem = base;
			item.Finalize(randf(), FISH_ILVL[ClampTier(fish.tier) - 1], 0, null, null);
			return item;
		}

		// the fish goes into the bag, or at your feet when the bag is full
		void GiveFish(Fish@ fish)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || fish is null)
				return;
			auto item = MakeFishItem(fish);
			if (item is null)
				HWP::Market::Add(rec, fish.id, 1);
			else if (rec.equipInventory !is null && rec.equipInventory.CanAdd())
				rec.equipInventory.Add(item);
			else
			{
				if (rec.actor !is null)
					Item::DropItem(item, rec.actor.m_unit.GetPosition(), 1, true, null);
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.bag_full", { { "fish", fish.Name() } }));
			}
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("fish", fish.id);
			b.PopDictionary();
			HWP::Net::Request(CAUGHT, b.Build());
			HWP::Log("fishing", "caught " + fish.id + " (rod " + RodTier() + ", " + Bait() + " bait left)");
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
			g_pendingTier[peer] = RollTier(HWP::SV::Int(data, "rod", 1));
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
			HWP::Log("fishing", rec.GetName() + " caught tier " + tier + " (" + CastsLeft(peer) + " casts left)");
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
		vec3 g_piratePos;

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

		// The vanilla wreck (or the small boat of a bigger trading post) near
		// the expected spot; none: our own copy of the wreck goes there.
		vec3 FindBoat()
		{
			vec3 want = vec3(float(HWP::Settings::GetInt("fishing.pirate_x", WRECK_X)), float(HWP::Settings::GetInt("fishing.pirate_y", WRECK_Y)), 0);
			array<string> kinds = { VANILLA_WRECK, VANILLA_BOAT };
			float best = 140.0f;
			vec3 found = want;
			bool any = false;
			for (uint k = 0; k < kinds.length(); k++)
			{
				auto prod = Resources::GetUnitProducer(kinds[k]);
				if (prod is null)
					continue;
				auto units = g_scene.FetchAllUnitsOfType(prod);
				for (uint i = 0; i < units.length(); i++)
				{
					vec3 p = units[i].GetPosition();
					float d = dist(xy(p), xy(want));
					if (d < best)
					{
						best = d;
						found = p;
						any = true;
					}
				}
			}
			if (!any)
			{
				auto u = SpawnAt(WRECK_UNIT, want);
				if (u.IsValid())
					g_local.insertLast(u);
				HWP::Log("fishing", "no boat by the trading post; placed a wreck at " + int(want.x) + "," + int(want.y));
			}
			return found;
		}

		// every machine: the coast spots and the pirate are local units
		void SetupTown()
		{
			ClearLocal();
			if (!g_coast)
				return;
			for (uint i = 0; i < COAST_X.length(); i++)
			{
				auto u = SpawnAt(SPOT_UNIT, vec3(float(COAST_X[i]), float(COAST_Y[i]), 0));
				if (u.IsValid())
					g_local.insertLast(u);
			}
			vec3 boat = FindBoat();
			g_piratePos = boat + vec3(-6, -2, 0);
			auto p = SpawnAt(PIRATE_UNIT, g_piratePos);
			if (p.IsValid())
				g_local.insertLast(p);
			HWP::Log("fishing", "coast: " + COAST_X.length() + " spots; pirate at " + int(g_piratePos.x) + "," + int(g_piratePos.y));
		}

		void SelfCheck()
		{
			array<string> tables;
			for (int t = 1; t <= TIERS; t++)
				tables.insertLast("hwp_fishing_run_" + t);
			HWP::CheckLootTables("fishing", tables);
			HWP::CheckUnits("fishing", { SPOT_UNIT, HOLE_UNIT, PIRATE_UNIT, WRECK_UNIT });
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
				if (what == "bait")
					BuyBait(BAIT_SMALL, BAIT_SMALL_PRICE);
				else if (what == "bait20")
					BuyBait(BAIT_BIG, BAIT_BIG_PRICE);
				else if (what == "rod")
					BuyRod();
				else
				{
					HWP::Commands::Reply("usage: hwp fishing buy bait|bait20|rod");
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
				int tier = args.length() >= 2 ? ClampTier(parseInt(args[1])) : RollTier(RodTier());
				auto fish = RandomFish(tier);
				GiveFish(fish);
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.caught", { { "fish", fish.Name() } }));
				return;
			}
			if (sub == "bait")
			{
				// debug: set your bait
				if (!g_debug)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.fishing.debug_off"));
					return;
				}
				SetBait(args.length() >= 2 ? parseInt(args[1]) : 20);
			}
			auto s = HWP::Market::Summary(rec, "fish");
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
		m_casts.SetText(Resources::GetString(".hwp.fishing.bait_left", { { "n", HWP::Fishing::Bait() }, { "rod", HWP::Fishing::RodName(m_rod) } }));
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
				m_tier = HWP::Fishing::RollTier(m_rod); // a hole: m_tier came from the host
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
			// the coast: a cast takes a bait, bite or not
			if (HWP::Fishing::Bait() <= 0)
			{
				m_log.SetText(Resources::GetString(".hwp.fishing.no_bait"));
				return;
			}
			HWP::Fishing::SetBait(HWP::Fishing::Bait() - 1);
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
		if (name == "cast")
		{
			if (m_state == HWP::Fishing::STATE_BITE)
				Reel();
			else if (m_state == HWP::Fishing::STATE_IDLE || m_state == HWP::Fishing::STATE_RESULT)
				Cast();
		}
	}
}

// Interact class of the pirate fisherman: bait and rod upgrades.
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
	ScalableSpriteButtonWidget@ m_rod;
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
		@m_rod = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("rod-btn"));
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
		m_gold.SetText(Resources::GetString(".hwp.fishing.pirate.gold", { { "n", rec is null ? 0 : rec.GetMaterial(MaterialType::Gold) } }));
		m_bait.SetText(Resources::GetString(".hwp.fishing.pirate.buy_bait", { { "n", HWP::Fishing::BAIT_SMALL }, { "price", HWP::Fishing::BAIT_SMALL_PRICE } }));
		m_baitBig.SetText(Resources::GetString(".hwp.fishing.pirate.buy_bait", { { "n", HWP::Fishing::BAIT_BIG }, { "price", HWP::Fishing::BAIT_BIG_PRICE } }));
		int next = HWP::Fishing::RodTier() + 1;
		if (next > HWP::Fishing::ROD_TIERS)
			m_rod.SetText(Resources::GetString(".hwp.fishing.pirate.rod_none"));
		else
			m_rod.SetText(Resources::GetString(".hwp.fishing.pirate.buy_rod", { { "rod", HWP::Fishing::RodName(next) }, { "price", HWP::Fishing::ROD_PRICE[next] } }));
		m_widget.Invalidate();
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
			HWP::Fishing::BuyBait(HWP::Fishing::BAIT_SMALL, HWP::Fishing::BAIT_SMALL_PRICE);
		else if (name == "bait20")
			HWP::Fishing::BuyBait(HWP::Fishing::BAIT_BIG, HWP::Fishing::BAIT_BIG_PRICE);
		else if (name == "rod")
			HWP::Fishing::BuyRod();
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
			HWP::Net::OnRequest(HWP::Fishing::CAST, HWP::Net::RequestHandler(HWP::Fishing::OnCastRequest));
			HWP::Net::OnRequest(HWP::Fishing::CATCH, HWP::Net::RequestHandler(HWP::Fishing::OnCatch));
			HWP::Net::OnRequest(HWP::Fishing::CAUGHT, HWP::Net::RequestHandler(HWP::Fishing::OnCaught));
			HWP::Net::OnEvent(HWP::Fishing::BITE, HWP::Net::EventHandler(HWP::Fishing::OnBite));
			HWP::Net::OnEvent(HWP::Fishing::DENIED, HWP::Net::EventHandler(HWP::Fishing::OnDenied));
			HWP::Net::OnEvent(HWP::Fishing::ANNOUNCE, HWP::Net::EventHandler(HWP::Fishing::OnAnnounce));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Fishing::OnSettingChanged));
			HWP::Commands::Register("fishing", " fishing status; 'buy bait|bait20|rod'; debug: 'hole', 'catch [tier]', 'bait [n]'", HWP::Commands::Handler(HWP::Fishing::CmdFishing));
			HWP::Fishing::SelfCheck();
		}

		void Start(StartMode sMode)
		{
			HWP::Fishing::RefreshSettings();
			HWP::Fishing::ResetCasts();
			HWP::Fishing::g_local.removeRange(0, HWP::Fishing::g_local.length());
			HWP::Fishing::Changed();
			m_spawnDone = false;
			m_delay = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (m_spawnDone)
				return;
			m_delay += ms;
			if (m_delay < 600)
				return;
			if (!HWP::Fishing::g_enabled)
			{
				m_spawnDone = true;
				return;
			}
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
			if (randi(100) < HWP::Fishing::g_runChance)
				HWP::Fishing::SpawnAt(HWP::Fishing::HOLE_UNIT, rec.actor.m_unit.GetPosition() + vec3(56, -8, 0));
		}
	}
}
