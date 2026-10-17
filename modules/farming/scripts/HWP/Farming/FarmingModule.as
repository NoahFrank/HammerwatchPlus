// Farming. Plots are the grooves of the town's onion and wheat fields (the
// vanilla crops there are hidden), or a row of soil patches from farm.x/y
// when the town has no fields. Every machine spawns its own plot units
// (netsync none) and works out the grooves from the same town prefab; the
// plot state (seed, growth, watered) lives in the host's own TownRecord (HWP
// data bag, "farm.*") and is mirrored to everyone with `farm.sync`.
// Interacting with a plot: empty -> pick one of your seeds (`farm.plant`),
// growing -> water it (`farm.water`, one charge of your watering can), ready
// -> harvest (`farm.harvest`, 25 % chance of a seed back, 5 % of two). The
// host answers each request and only then the requester pays (seed, water)
// or gets the yield; `farm.refused` costs nothing.
// Growth: every completed run adds 1 growth to each planted plot, 2 if it was
// watered since the last run. A gameplay load that is not the town sets
// "farm.pending", the next town load counts the run.
// The farmer (vanilla npc_misc_farmer_man, overridden) sells the watering
// can, its upgrades and seeds; the farm well refills the can. Can, water and
// seeds are per character (HWP::SaveData::Local).
// Herbs can be smoked (one "hwp_herb" mission buff, lasts the next run).
// Runs: on a floor that is not a boss room, the host places one ripe wild
// plot (farm.run_chance %, default 35) beside a pot, crate or chest. It is
// netsynced, but every player harvests it once for themselves (local yield,
// seed chances doubled: 50 % one back, 10 % two) and it then disappears for
// them; nothing can be planted on it.
namespace HWP
{
	namespace Farming
	{
		const string PLOT_UNIT = "doodads/hwp/farm_plot.unit";
		const string GROOVE_V_UNIT = "doodads/hwp/farm_groove_v.unit";
		const string GROOVE_H_UNIT = "doodads/hwp/farm_groove_h.unit";
		const string WELL_UNIT = "doodads/hwp/farm_well.unit";
		const string SPROUT_UNIT = "doodads/hwp/farm_sprout.unit";
		const string SPROUT2_UNIT = "doodads/hwp/farm_sprout2.unit";
		const string WET_UNIT = "doodads/hwp/farm_wet.unit";
		const string CROP_UNIT_PREFIX = "doodads/hwp/crops/";
		const string ONION_UNIT = "doodads/terrain/crop_onions.unit";
		const string WHEAT_UNIT = "doodads/terrain/crop_wheat.unit";
		const string APPLE_UNIT = "doodads/terrain/tree_oak_apple.unit";
		const string PLANT = "farm.plant";     // client -> host: { plot, seed }
		const string HARVEST = "farm.harvest"; // client -> host: { plot }
		const string WATER = "farm.water";     // client -> host: { plot }
		const string PULL = "farm.pull";       // client -> host: send me the state
		const string SYNC = "farm.sync";       // host -> all: { runs, plots: [ { seed, g, w } ] }
		const string YIELD = "farm.yield";     // host -> peer: { seed, n, seeds }
		const string PLANTED = "farm.planted"; // host -> peer: { seed, plot } use a seed now
		const string WATERED = "farm.watered"; // host -> peer: { seed, plot } use a water charge now
		const string REFUSED = "farm.refused"; // host -> peer: { why } the request failed
		const string KEY_PLOTS = "farm.plots";
		const string KEY_RUNS = "farm.runs";
		const string KEY_PENDING = "farm.pending";
		const string KEY_CAN = "farm.can";     // per character: watering can tier (0 = none)
		const string KEY_WATER = "farm.water"; // per character: water charges in the can
		const string KEY_SEED = "farm.seed.";  // per character: seeds owned, + seed id
		const string HERB_SLOT = "hwp_herb";   // SetMissionBuff slot id
		const int MAX_PLOTS = 24;
		const int SPACING = 40;
		const float SEGMENT = 48.0f;           // length of one groove plot unit
		const float GROOVE_REACH = 14.0f;      // how far from a groove still counts as on it
		const array<int> CAN_SIZE = { 0, 4, 6, 9, 12 };
		const array<int> CAN_PRICE = { 0, 150, 400, 1000, 2500 };

		class Seed
		{
			string id;
			int price;     // at the farmer, per seed
			bool herb;
			int grow;      // growth to be ready: 1 per run, 2 per watered run
			int yieldMin;
			int yieldMax;
			int sell;      // ware price per unit
			Seed(const string &in id_, int price_, bool herb_, int grow_, int ymin, int ymax, int sell_)
			{
				id = id_; price = price_; herb = herb_; grow = grow_; yieldMin = ymin; yieldMax = ymax; sell = sell_;
			}
			string Name() { return Resources::GetString(".hwp.farming.seed." + id); }
			int Runs(bool watered) { return watered ? (grow + 1) / 2 : grow; }
		}
		array<Seed@> g_seeds;

		void AddSeed(const string &in id, int price, bool herb, int grow, int ymin, int ymax, int sell)
		{
			g_seeds.insertLast(Seed(id, price, herb, grow, ymin, ymax, sell));
			HWP::Market::Register(id, ".hwp.farming.seed." + id, sell, herb ? "herb" : "crop");
		}

		void DefineSeeds()
		{
			if (g_seeds.length() > 0)
				return;
			AddSeed("cabbage", 20, false, 2, 2, 4, 15);
			AddSeed("carrot", 20, false, 2, 3, 5, 10);
			AddSeed("onion", 25, false, 2, 2, 4, 15);
			AddSeed("potato", 30, false, 2, 3, 6, 12);
			AddSeed("wheat", 15, false, 2, 4, 8, 6);
			AddSeed("lucky_leaf", 150, true, 4, 1, 2, 120);
			AddSeed("ember_kush", 200, true, 4, 1, 2, 160);
			AddSeed("saints_sage", 200, true, 4, 1, 2, 160);
			AddSeed("gamblers_gold", 250, true, 4, 1, 2, 200);
		}

		Seed@ GetSeed(const string &in id)
		{
			for (uint i = 0; i < g_seeds.length(); i++)
				if (g_seeds[i].id == id)
					return g_seeds[i];
			return null;
		}

		// ---- settings ------------------------------------------------------------

		bool g_enabled = true;
		bool g_debug = false;
		int g_runChance = 35; // % of run floors (not boss rooms) with a wild plot

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("farm.enabled", true);
			g_debug = HWP::Settings::GetBool("farm.debug", false);
			g_runChance = clamp(HWP::Settings::GetInt("farm.run_chance", 35), 0, 100);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("farm.") != 0)
				return;
			RefreshSettings();
			if (!g_inTown || !g_visualsReady)
				return;
			if (key == "farm.fields" || key == "farm.x" || key == "farm.y")
			{
				DetectFields();
				SpawnPlots();
				RefreshVisuals();
			}
			else if (key == "farm.well_x" || key == "farm.well_y")
				SpawnWell();
		}

		// ---- the plots: field grooves, or the fallback patch row --------------

		class Groove
		{
			bool vertical;   // an onion column (true) or a wheat row
			float fixed;     // its x (vertical) or y
			float lo;        // extent along the groove
			float hi;
			array<vec3> spots; // where the vanilla crops stood

			vec3 Pos(float along) { return vertical ? vec3(fixed, along, 0) : vec3(along, fixed, 0); }
			vec3 Center() { return Pos((lo + hi) * 0.5f); }

			float Dist(vec3 p)
			{
				float a = vertical ? p.y : p.x;
				float c = vertical ? p.x : p.y;
				float along = a < lo ? lo - a : (a > hi ? a - hi : 0.0f);
				float perp = c > fixed ? c - fixed : fixed - c;
				return along > perp ? along : perp;
			}
		}
		array<Groove@> g_grooves;
		array<UnitPtr> g_hiddenCrops;
		bool g_treeMoved = false;

		float Key(vec3 p, bool vertical) { return vertical ? p.x : p.y; }

		// the crop units of one field -> one groove per column (vertical) or row
		void AddGrooves(array<UnitPtr>@ units, bool vertical)
		{
			array<vec3> pos;
			for (uint i = 0; i < units.length(); i++)
			{
				vec3 p = units[i].GetPosition();
				// insertion sort by the cross coordinate
				uint j = pos.length();
				pos.insertLast(p);
				while (j > 0 && Key(pos[j - 1], vertical) > Key(p, vertical))
				{
					pos[j] = pos[j - 1];
					j--;
				}
				pos[j] = p;
			}

			Groove@ g = null;
			float last = 0;
			float sum = 0;
			for (uint i = 0; i <= pos.length(); i++)
			{
				bool split = i == pos.length() || g is null || Key(pos[i], vertical) - last > 6.0f;
				if (split && g !is null)
				{
					g.fixed = sum / float(g.spots.length());
					if (g.spots.length() >= 3)
						g_grooves.insertLast(g);
					@g = null;
				}
				if (i == pos.length())
					break;
				if (g is null)
				{
					@g = Groove();
					g.vertical = vertical;
					g.lo = 1e9f;
					g.hi = -1e9f;
					sum = 0;
				}
				vec3 p = pos[i];
				last = Key(p, vertical);
				float a = vertical ? p.y : p.x;
				bool dup = false;
				for (uint k = 0; k < g.spots.length(); k++)
					if (dist(xy(g.spots[k]), xy(p)) < 2.0f)
						dup = true;
				if (dup)
					continue;
				g.spots.insertLast(p);
				sum += last;
				if (a < g.lo) g.lo = a;
				if (a > g.hi) g.hi = a;
			}
		}

		array<UnitPtr>@ FetchUnits(const string &in path)
		{
			auto prod = Resources::GetUnitProducer(path);
			if (prod is null)
				return array<UnitPtr>();
			return g_scene.FetchAllUnitsOfType(prod);
		}

		void SetCropsHidden(bool hidden)
		{
			for (uint i = 0; i < g_hiddenCrops.length(); i++)
			{
				if (!g_hiddenCrops[i].IsValid())
					continue;
				g_hiddenCrops[i].SetHidden(hidden);
				g_hiddenCrops[i].SetShouldCollide(!hidden);
			}
		}

		// the apple tree below the wheat field goes just above its top fence
		void MoveAppleTree(uint firstRow)
		{
			if (g_treeMoved)
				return;
			float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
			for (uint i = firstRow; i < g_grooves.length(); i++)
			{
				auto g = g_grooves[i];
				if (g.lo < minX) minX = g.lo;
				if (g.hi > maxX) maxX = g.hi;
				if (g.fixed < minY) minY = g.fixed;
				if (g.fixed > maxY) maxY = g.fixed;
			}
			auto trees = FetchUnits(APPLE_UNIT);
			for (uint i = 0; i < trees.length(); i++)
			{
				vec3 p = trees[i].GetPosition();
				if (p.x < minX - 30 || p.x > maxX + 30 || p.y < maxY || p.y > maxY + 50)
					continue;
				// the fence is 21 px above the top row; the trunk stands clear of it
				trees[i].SetPosition(vec3(p.x, minY - 39, p.z));
				g_treeMoved = true;
				HWP::Log("farming", "moved the apple tree from " + int(p.x) + "," + int(p.y) + " to " + int(p.x) + "," + int(minY - 39));
			}
		}

		void DetectFields()
		{
			g_grooves.removeRange(0, g_grooves.length());
			SetCropsHidden(false);
			g_hiddenCrops.removeRange(0, g_hiddenCrops.length());
			if (!HWP::Settings::GetBool("farm.fields", true))
				return;

			auto onions = FetchUnits(ONION_UNIT);
			auto wheat = FetchUnits(WHEAT_UNIT);
			AddGrooves(onions, true);
			uint firstRow = g_grooves.length();
			AddGrooves(wheat, false);
			if (g_grooves.length() > uint(MAX_PLOTS))
				g_grooves.removeRange(MAX_PLOTS, g_grooves.length() - MAX_PLOTS);
			if (g_grooves.length() == 0)
				return;

			for (uint i = 0; i < onions.length(); i++)
				g_hiddenCrops.insertLast(onions[i]);
			for (uint i = 0; i < wheat.length(); i++)
				g_hiddenCrops.insertLast(wheat[i]);
			SetCropsHidden(true);
			if (g_grooves.length() > firstRow)
				MoveAppleTree(firstRow);
			HWP::Log("farming", "fields: " + firstRow + " onion grooves, " + (g_grooves.length() - firstRow) + " wheat grooves");
		}

		bool UseFields() { return g_grooves.length() > 0; }

		int PlotCount()
		{
			if (UseFields())
				return int(g_grooves.length());
			int n = HWP::Settings::GetInt("farm.plots", 4);
			if (n < 1) n = 1;
			if (n > MAX_PLOTS) n = MAX_PLOTS;
			return n;
		}

		vec3 BasePos()
		{
			return vec3(float(HWP::Settings::GetInt("farm.x", -560)),
				float(HWP::Settings::GetInt("farm.y", 1040)), 0.0f);
		}

		vec3 PlotPos(int i)
		{
			if (UseFields() && i >= 0 && i < int(g_grooves.length()))
				return g_grooves[i].Center();
			return BasePos() + vec3(float(i * SPACING), 0, 0);
		}

		int PlotIndexAt(vec3 pos)
		{
			if (UseFields())
			{
				int best = -1;
				float bestD = GROOVE_REACH;
				for (uint i = 0; i < g_grooves.length(); i++)
				{
					float d = g_grooves[i].Dist(pos);
					if (d <= bestD)
					{
						bestD = d;
						best = int(i);
					}
				}
				return best;
			}
			float dx = pos.x - BasePos().x;
			int i = int((dx + float(SPACING) * 0.5f) / float(SPACING));
			if (dx < -float(SPACING) * 0.5f) i = -1;
			if (i < 0 || i >= PlotCount())
				return -1;
			return i;
		}

		array<vec3> Spots(int i)
		{
			if (UseFields() && i >= 0 && i < int(g_grooves.length()))
				return g_grooves[i].spots;
			array<vec3> one = { PlotPos(i) + vec3(0, -2, 0) };
			return one;
		}

		// the farm well: next to the pet feeding bowl unless farm.well_x/y are set
		vec3 WellPos()
		{
			int x = HWP::Settings::GetInt("farm.well_x", -99999);
			int y = HWP::Settings::GetInt("farm.well_y", -99999);
			if (x != -99999 && y != -99999)
				return vec3(float(x), float(y), 0);
			return vec3(float(HWP::Settings::GetInt("pets.bowl_x", -600) - 48),
				float(HWP::Settings::GetInt("pets.bowl_y", 980)), 0);
		}

		// ---- state mirror (every machine) -------------------------------------

		array<string> g_plotSeed(MAX_PLOTS, "");
		array<int> g_plotGrowth(MAX_PLOTS, 0);
		array<bool> g_plotWet(MAX_PLOTS, false);
		int g_runs = 0;
		int g_version = 0;        // bumps on every state change (windows refresh)
		bool g_haveState = false; // clients: false until the first sync
		bool g_visualsReady = false; // set by the module once the scene settled
		array<UnitPtr> g_visual;
		array<UnitPtr> g_plotUnits;
		UnitPtr g_wellUnit;

		bool IsReady(int i)
		{
			auto s = GetSeed(g_plotSeed[i]);
			return s !is null && g_plotGrowth[i] >= s.grow;
		}

		// runs left without watering
		int RunsLeft(int i)
		{
			auto s = GetSeed(g_plotSeed[i]);
			if (s is null)
				return 0;
			int left = s.grow - g_plotGrowth[i];
			return left < 0 ? 0 : left;
		}

		SValue@ PackState()
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("runs", g_runs);
			b.PushArray("plots");
			for (int i = 0; i < MAX_PLOTS; i++)
			{
				b.PushDictionary();
				b.PushString("seed", g_plotSeed[i]);
				b.PushInteger("g", g_plotGrowth[i]);
				b.PushBoolean("w", g_plotWet[i]);
				b.PopDictionary();
			}
			b.PopArray();
			b.PopDictionary();
			return b.Build();
		}

		void ApplyState(SValue@ data)
		{
			g_runs = HWP::SV::Int(data, "runs", 0);
			for (int i = 0; i < MAX_PLOTS; i++)
			{
				g_plotSeed[i] = "";
				g_plotGrowth[i] = 0;
				g_plotWet[i] = false;
			}
			auto plotsV = HWP::SV::Field(data, "plots");
			if (plotsV !is null && plotsV.GetType() == SValueType::Array)
			{
				auto plots = plotsV.GetArray();
				for (uint i = 0; i < plots.length() && i < uint(MAX_PLOTS); i++)
				{
					g_plotSeed[i] = HWP::SV::Str(plots[i], "seed");
					if (HWP::SV::Field(plots[i], "g") !is null)
						g_plotGrowth[i] = HWP::SV::Int(plots[i], "g", 0);
					else if (!g_plotSeed[i].isEmpty()) // saved before watering: "at" was the run it was planted
						g_plotGrowth[i] = g_runs - HWP::SV::Int(plots[i], "at", g_runs);
					g_plotWet[i] = HWP::SV::Bool(plots[i], "w", false);
				}
			}
			g_haveState = true;
			g_version++;
			RefreshVisuals();
		}

		// host: persist in the host's own town record
		void SaveState()
		{
			if (!Network::IsServer())
				return;
			auto bag = HWP::SaveData::MyTown();
			bag.SetInt(KEY_RUNS, g_runs);
			bag.Set(KEY_PLOTS, PackState());
		}

		void LoadState()
		{
			auto bag = HWP::SaveData::MyTown();
			auto st = bag.Get(KEY_PLOTS);
			if (st !is null)
				ApplyState(st);
			else
			{
				g_runs = bag.GetInt(KEY_RUNS, 0);
				g_haveState = true;
				g_version++;
			}
		}

		// host: a run was completed; watered plots grow twice as fast
		void CountRun()
		{
			g_runs++;
			for (int i = 0; i < MAX_PLOTS; i++)
			{
				if (g_plotSeed[i].isEmpty())
					continue;
				g_plotGrowth[i] += g_plotWet[i] ? 2 : 1;
				g_plotWet[i] = false;
			}
		}

		void Changed()
		{
			g_version++;
			SaveState();
			if (Network::IsServer())
				HWP::Net::Broadcast(SYNC, PackState());
		}

		// ---- per character: watering can and seeds ----------------------------

		int CanTier()
		{
			int t = HWP::SaveData::Local().GetInt(KEY_CAN, 0);
			if (t < 0)
				return 0;
			if (t >= int(CAN_SIZE.length()))
				return int(CAN_SIZE.length()) - 1;
			return t;
		}
		int CanSize() { return CAN_SIZE[CanTier()]; }
		int Water() { return HWP::SaveData::Local().GetInt(KEY_WATER, 0); }
		void SetWater(int n) { HWP::SaveData::Local().SetInt(KEY_WATER, n); HWP::Gear::Changed(); }
		int SeedCount(const string &in id) { return HWP::SaveData::Local().GetInt(KEY_SEED + id, 0); }
		void AddSeeds(const string &in id, int n)
		{
			int have = SeedCount(id) + n;
			HWP::SaveData::Local().SetInt(KEY_SEED + id, have < 0 ? 0 : have);
		}

		string CanText()
		{
			if (CanTier() <= 0)
				return Resources::GetString(".hwp.farming.can_none");
			return Resources::GetString(".hwp.farming.can", { { "n", Water() }, { "max", CanSize() } });
		}

		string SeedsText()
		{
			string s = "";
			for (uint i = 0; i < g_seeds.length(); i++)
			{
				int n = SeedCount(g_seeds[i].id);
				if (n <= 0)
					continue;
				if (!s.isEmpty())
					s += ", ";
				s += g_seeds[i].Name() + " " + n;
			}
			return s.isEmpty() ? Resources::GetString(".hwp.farming.seeds_none")
				: Resources::GetString(".hwp.farming.seeds", { { "list", s } });
		}

		string g_lastMessage = "";

		void Float(const string &in text)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.actor is null)
				return;
			AddFloatingText(FloatingTextType::Pickup, text, rec.actor.m_unit.GetPosition() + vec3(0, -24, 0));
		}

		// ms left until we stop waiting for the host's answer to a plant or
		// water request (the seed / water is used only when it arrives)
		int g_waitMs = 0;
		const int WAIT_MS = 3000;

		bool Waiting()
		{
			if (g_waitMs <= 0)
				return false;
			Say(Resources::GetString(".hwp.farming.waiting"));
			return true;
		}

		void Say(const string &in text)
		{
			g_lastMessage = text;
			Float(text);
			g_version++;
		}

		bool Pay(int price)
		{
			if (HWP::Town::PayGold(price))
				return true;
			Say(Resources::GetString(".hwp.farming.no_gold"));
			return false;
		}

		// the farmer: a can (tier 1) or the next bigger one; a new can comes full
		void BuyCan()
		{
			int next = CanTier() + 1;
			if (next >= int(CAN_SIZE.length()))
				return;
			if (!Pay(CAN_PRICE[next]))
				return;
			HWP::SaveData::Local().SetInt(KEY_CAN, next);
			SetWater(CAN_SIZE[next]);
			Say(Resources::GetString(next == 1 ? ".hwp.farming.can_bought" : ".hwp.farming.can_upgraded", { { "max", CAN_SIZE[next] } }));
		}

		void BuySeed(Seed@ seed)
		{
			if (seed is null || !Pay(seed.price))
				return;
			AddSeeds(seed.id, 1);
			Say(Resources::GetString(".hwp.farming.seed_bought", { { "name", seed.Name() }, { "n", SeedCount(seed.id) } }));
		}

		// the well
		void Refill()
		{
			if (CanTier() <= 0)
			{
				Say(Resources::GetString(".hwp.farming.need_can"));
				return;
			}
			SetWater(CanSize());
			Say(Resources::GetString(".hwp.farming.refilled", { { "n", CanSize() } }));
		}

		// ---- visuals (local) ----------------------------------------------------

		void ClearVisuals()
		{
			for (uint i = 0; i < g_visual.length(); i++)
				if (g_visual[i].IsValid())
					g_visual[i].Destroy();
			g_visual.removeRange(0, g_visual.length());
		}

		void Produce(const string &in path, vec3 pos)
		{
			auto prod = Resources::GetUnitProducer(path);
			if (prod is null)
			{
				HWP::LogError("farming", "missing " + path);
				return;
			}
			g_visual.insertLast(prod.Produce(g_scene, pos));
		}

		void RefreshVisuals()
		{
			if (!g_inTown || !g_visualsReady)
				return;
			ClearVisuals();
			for (int i = 0; i < PlotCount(); i++)
			{
				auto s = GetSeed(g_plotSeed[i]);
				if (s is null)
					continue;
				string path = IsReady(i) ? CROP_UNIT_PREFIX + s.id + ".unit"
					: (g_plotGrowth[i] > 0 ? SPROUT2_UNIT : SPROUT_UNIT);
				auto spots = Spots(i);
				for (uint k = 0; k < spots.length(); k++)
				{
					if (g_plotWet[i])
						Produce(WET_UNIT, spots[k]);
					Produce(path, spots[k]);
				}
			}
		}

		// ---- requests (host) ---------------------------------------------------

		void Refuse(uint8 peer, const string &in why)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("why", why);
			b.PopDictionary();
			HWP::Net::Send(peer, REFUSED, b.Build());
		}

		void Answer(uint8 peer, const string &in name, const string &in seed, int plot)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("seed", seed);
			b.PushInteger("plot", plot);
			b.PopDictionary();
			HWP::Net::Send(peer, name, b.Build());
		}

		void OnPull(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer())
				return;
			HWP::Net::Send(peer, SYNC, PackState());
		}

		void OnPlant(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_inTown)
				return;
			int plot = HWP::SV::Int(data, "plot", -1);
			auto seed = GetSeed(HWP::SV::Str(data, "seed"));
			bool ok = g_enabled && seed !is null && plot >= 0 && plot < PlotCount() && g_plotSeed[plot].isEmpty();
			if (!ok)
			{
				Refuse(peer, "taken");
				return;
			}
			g_plotSeed[plot] = seed.id;
			g_plotGrowth[plot] = 0;
			g_plotWet[plot] = false;
			HWP::Log("farming", "peer " + peer + " planted " + seed.id + " on plot " + plot);
			Answer(peer, PLANTED, seed.id, plot);
			Changed();
		}

		void OnWater(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_inTown)
				return;
			int plot = HWP::SV::Int(data, "plot", -1);
			if (plot < 0 || plot >= PlotCount() || g_plotSeed[plot].isEmpty() || IsReady(plot))
			{
				Refuse(peer, "not_growing");
				return;
			}
			if (g_plotWet[plot])
			{
				Refuse(peer, "already_watered");
				return;
			}
			g_plotWet[plot] = true;
			HWP::Log("farming", "peer " + peer + " watered plot " + plot);
			Answer(peer, WATERED, g_plotSeed[plot], plot);
			Changed();
		}

		void OnHarvest(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_inTown)
				return;
			int plot = HWP::SV::Int(data, "plot", -1);
			if (plot < 0 || plot >= PlotCount() || !IsReady(plot))
			{
				Refuse(peer, "not_ready");
				return;
			}
			auto seed = GetSeed(g_plotSeed[plot]);
			if (seed is null)
				return;
			int n = seed.yieldMin + randi(seed.yieldMax - seed.yieldMin + 1);
			int roll = randi(100);
			int seeds = roll < 5 ? 2 : (roll < 25 ? 1 : 0);
			g_plotSeed[plot] = "";
			g_plotGrowth[plot] = 0;
			g_plotWet[plot] = false;
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("seed", seed.id);
			b.PushInteger("n", n);
			b.PushInteger("seeds", seeds);
			b.PopDictionary();
			HWP::Net::Send(peer, YIELD, b.Build());
			HWP::Log("farming", "peer " + peer + " harvested " + n + "x " + seed.id + " (+" + seeds + " seeds) from plot " + plot);
			Changed();
		}

		// ---- events (local) ----------------------------------------------------

		void OnSync(SValue@ data) { ApplyState(data); }

		void OnYield(SValue@ data)
		{
			auto seed = GetSeed(HWP::SV::Str(data, "seed"));
			int n = HWP::SV::Int(data, "n", 0);
			int seeds = HWP::SV::Int(data, "seeds", 0);
			if (seed is null || n <= 0)
				return;
			HWP::Market::Add(GetLocalPlayerRecord(), seed.id, n);
			if (seeds > 0)
				AddSeeds(seed.id, seeds);
			string text = Resources::GetString(".hwp.farming.harvested", { { "n", n }, { "name", seed.Name() } });
			if (seeds > 0)
				text += " " + Resources::GetString(seeds > 1 ? ".hwp.farming.seed_back2" : ".hwp.farming.seed_back", { { "n", seeds } });
			Say(text);
			HWP::Commands::Reply(text); // a harvest also goes to the chat
			g_lastMessage = "";         // (so the debug echo skips it)
		}

		// the host accepted our plant request: use the seed now
		void OnPlanted(SValue@ data)
		{
			g_waitMs = 0;
			auto seed = GetSeed(HWP::SV::Str(data, "seed"));
			if (seed is null)
				return;
			AddSeeds(seed.id, -1);
			Say(Resources::GetString(".hwp.farming.planted", { { "name", seed.Name() }, { "runs", seed.Runs(false) }, { "wet", seed.Runs(true) } }));
		}

		void OnWatered(SValue@ data)
		{
			g_waitMs = 0;
			auto seed = GetSeed(HWP::SV::Str(data, "seed"));
			int left = Water() - 1;
			SetWater(left < 0 ? 0 : left);
			Say(Resources::GetString(".hwp.farming.watered", { { "name", seed is null ? "" : seed.Name() }, { "n", Water() }, { "max", CanSize() } }));
		}

		void OnRefused(SValue@ data)
		{
			g_waitMs = 0;
			string why = HWP::SV::Str(data, "why", "taken");
			Say(Resources::GetString(".hwp.farming.refused." + why));
		}

		// ---- actions (any machine) ----------------------------------------------

		void RequestPlot(const string &in name, int plot, const string &in seed = "")
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("plot", plot);
			if (!seed.isEmpty())
				b.PushString("seed", seed);
			b.PopDictionary();
			HWP::Net::Request(name, b.Build());
		}

		bool RequestPlant(int plot, Seed@ seed)
		{
			if (seed is null || plot < 0)
				return false;
			if (Waiting())
				return false;
			if (SeedCount(seed.id) <= 0)
			{
				Say(Resources::GetString(".hwp.farming.no_seeds"));
				return false;
			}
			g_waitMs = WAIT_MS;
			RequestPlot(PLANT, plot, seed.id); // the seed is used in OnPlanted
			return true;
		}

		void RequestHarvest(int plot) { RequestPlot(HARVEST, plot); }

		// false (and says why) when the plot cannot be watered now
		bool CanWater(int plot)
		{
			if (g_plotWet[plot])
				Say(Resources::GetString(".hwp.farming.refused.already_watered"));
			else if (CanTier() <= 0)
				Say(Resources::GetString(".hwp.farming.need_can"));
			else if (Water() <= 0)
				Say(Resources::GetString(".hwp.farming.can_empty"));
			else
				return true;
			return false;
		}

		void RequestWater(int plot)
		{
			if (Waiting() || !CanWater(plot))
				return;
			g_waitMs = WAIT_MS;
			RequestPlot(WATER, plot); // the water is used in OnWatered
		}

		string ActiveHerbName(PlayerRecord@ rec)
		{
			if (rec is null)
				return "";
			uint slot = HashString(HERB_SLOT);
			for (uint i = 0; i < rec.missionBuffs.length(); i++)
				if (rec.missionBuffs[i].m_id == slot && rec.missionBuffs[i].m_buff !is null)
					return rec.missionBuffs[i].m_buff.m_name;
			return "";
		}

		bool Smoke(const string &in herbId)
		{
			auto rec = GetLocalPlayerRecord();
			auto seed = GetSeed(herbId);
			if (rec is null || seed is null || !seed.herb)
				return false;
			if (HWP::Market::Count(rec, herbId) <= 0)
			{
				g_lastMessage = Resources::GetString(".hwp.farming.no_herb", { { "name", seed.Name() } });
				return false;
			}
			auto buff = MissionBuff::Get(HashString("hwp_herb_" + herbId));
			if (buff is null)
			{
				HWP::LogError("farming", "mission buff hwp_herb_" + herbId + " missing (tweak/hwp/buffs_herbs.sval)");
				return false;
			}
			HWP::Market::Take(rec, herbId, 1);
			rec.SetMissionBuff(HashString(HERB_SLOT), buff);
			g_lastMessage = Resources::GetString(".hwp.farming.smoked", { { "name", buff.m_name }, { "desc", buff.m_description } });
			HWP::Commands::Reply(g_lastMessage);
			g_version++;
			return true;
		}

		// ---- spawning (local, every machine) + run counting (host) -------------

		void ClearPlots()
		{
			for (uint i = 0; i < g_plotUnits.length(); i++)
				if (g_plotUnits[i].IsValid())
					g_plotUnits[i].Destroy();
			g_plotUnits.removeRange(0, g_plotUnits.length());
		}

		void SpawnPlots()
		{
			ClearPlots();
			if (UseFields())
			{
				auto prodV = Resources::GetUnitProducer(GROOVE_V_UNIT);
				auto prodH = Resources::GetUnitProducer(GROOVE_H_UNIT);
				if (prodV is null || prodH is null)
				{
					HWP::LogError("farming", "missing the groove units");
					return;
				}
				for (uint i = 0; i < g_grooves.length(); i++)
				{
					auto g = g_grooves[i];
					float len = g.hi - g.lo;
					int n = int((len + SEGMENT - 1.0f) / SEGMENT);
					if (n < 1)
						n = 1;
					for (int k = 0; k < n; k++)
					{
						float along = g.lo + (float(k) + 0.5f) * len / float(n);
						g_plotUnits.insertLast((g.vertical ? prodV : prodH).Produce(g_scene, g.Pos(along)));
					}
				}
				HWP::Log("farming", "spawned " + g_plotUnits.length() + " plot units on " + g_grooves.length() + " field grooves");
				return;
			}
			auto prod = Resources::GetUnitProducer(PLOT_UNIT);
			if (prod is null)
			{
				HWP::LogError("farming", "missing " + PLOT_UNIT);
				return;
			}
			for (int i = 0; i < PlotCount(); i++)
				g_plotUnits.insertLast(prod.Produce(g_scene, PlotPos(i)));
			auto p = BasePos();
			HWP::Log("farming", "spawned " + PlotCount() + " farm plots from " + p.x + "," + p.y);
		}

		void SpawnWell()
		{
			if (g_wellUnit.IsValid())
				g_wellUnit.Destroy();
			g_wellUnit = UnitPtr();
			auto prod = Resources::GetUnitProducer(WELL_UNIT);
			if (prod is null)
			{
				HWP::LogError("farming", "missing " + WELL_UNIT);
				return;
			}
			auto p = WellPos();
			g_wellUnit = prod.Produce(g_scene, p);
			HWP::Log("farming", "spawned the farm well at " + int(p.x) + "," + int(p.y));
		}

		// once the town scene settled (module UpdateFrame), on every machine
		void SetupTown()
		{
			g_visualsReady = true;
			g_treeMoved = false;
			DetectFields();
			SpawnPlots();
			SpawnWell();
			if (Network::IsServer())
				RefreshVisuals();
			else
				HWP::Net::Request(PULL); // the sync refreshes the visuals
		}

		void OnGameplayLoad()
		{
			// state only; units are spawned from the module's UpdateFrame once the
			// scene settled (SetupTown)
			g_visualsReady = false;
			g_visual.removeRange(0, g_visual.length());
			g_plotUnits.removeRange(0, g_plotUnits.length());
			g_grooves.removeRange(0, g_grooves.length());
			g_hiddenCrops.removeRange(0, g_hiddenCrops.length());
			g_wellUnit = UnitPtr();
			g_lastMessage = "";
			g_picked.removeRange(0, g_picked.length());
			if (!Network::IsServer())
			{
				g_haveState = false;
				return;
			}
			auto bag = HWP::SaveData::MyTown();
			if (!g_inTown)
			{
				bag.SetBool(KEY_PENDING, true);
				return;
			}
			LoadState();
			if (bag.GetBool(KEY_PENDING, false))
			{
				bag.SetBool(KEY_PENDING, false);
				CountRun();
				HWP::Log("farming", "a run finished: " + g_runs + " counted");
				SaveState();
				g_version++;
			}
		}

		void SelfCheck()
		{
			int buffs = 0;
			for (uint i = 0; i < g_seeds.length(); i++)
			{
				if (!g_seeds[i].herb)
					continue;
				if (MissionBuff::Get(HashString("hwp_herb_" + g_seeds[i].id)) !is null)
					buffs++;
				else
					HWP::LogError("farming", "mission buff hwp_herb_" + g_seeds[i].id + " missing");
			}
			array<string> units = { PLOT_UNIT, GROOVE_V_UNIT, GROOVE_H_UNIT, WELL_UNIT, SPROUT_UNIT, SPROUT2_UNIT, WET_UNIT };
			// (the vanilla crop/tree units are not checked: loading their producers
			// in the main menu logs a WeatherEffect behaviour error; DetectFields
			// just finds nothing if they ever go away)
			for (uint i = 0; i < g_seeds.length(); i++)
			{
				units.insertLast(CROP_UNIT_PREFIX + g_seeds[i].id + ".unit");
				units.insertLast(WILD_UNIT_PREFIX + g_seeds[i].id + ".unit");
			}
			HWP::CheckUnits("farming", units);
			HWP::Log("farming", "self-check done: " + g_seeds.length() + " seeds, " + buffs + " herb buffs");
		}

		// ---- wild plots (runs) ----------------------------------------------------------

		const string WILD_UNIT_PREFIX = "doodads/hwp/wild/"; // + seed id + ".unit"
		const int WILD_HERB_CHANCE = 15; // % of wild plots that grow a Holy Herb
		array<int> g_picked; // wild plot units this machine's player has harvested
		UnitPtr g_lastWild;  // the last one this machine placed (debug 'farm wild pick')

		Seed@ RollWildSeed()
		{
			bool herb = randi(100) < WILD_HERB_CHANCE;
			array<Seed@> pool;
			for (uint i = 0; i < g_seeds.length(); i++)
				if (g_seeds[i].herb == herb)
					pool.insertLast(g_seeds[i]);
			return pool.length() == 0 ? null : pool[randi(pool.length())];
		}

		// a free floor spot (HWP::Spawner::FreeSpot) a little way from a random
		// pot, crate or chest: they only stand where players can walk
		bool FindWildSpot(vec3 &out pos)
		{
			array<UnitPtr> anchors;
			auto breakables = g_scene.FetchAllUnitsWithBehavior("Breakable");
			for (uint i = 0; i < breakables.length(); i++)
				anchors.insertLast(breakables[i]);
			auto chests = g_scene.FetchAllUnitsWithBehavior("Chest");
			for (uint i = 0; i < chests.length(); i++)
				anchors.insertLast(chests[i]);
			if (anchors.length() == 0)
				return false;
			for (int t = 0; t < 12; t++)
				if (HWP::Spawner::FreeSpot(anchors[randi(anchors.length())].GetPosition(), 56.0f, pos))
					return true;
			return false;
		}

		bool SpawnWild(Seed@ seed, vec3 pos)
		{
			if (seed is null)
				return false;
			auto prod = Resources::GetUnitProducer(WILD_UNIT_PREFIX + seed.id + ".unit");
			if (prod is null)
			{
				HWP::LogError("farming", "missing " + WILD_UNIT_PREFIX + seed.id + ".unit");
				return false;
			}
			g_lastWild = prod.Produce(g_scene, pos);
			HWP::Log("farming", "wild " + seed.id + " plot at " + int(pos.x) + "," + int(pos.y));
			return true;
		}

		// host, a run floor settled: maybe place this floor's wild plot
		void SetupRun()
		{
			if (!Network::IsServer() || g_inTown || cast<BossLevel>(g_gameMode) !is null)
				return;
			if (randi(100) >= g_runChance)
				return;
			vec3 pos;
			if (!FindWildSpot(pos))
			{
				HWP::Log("farming", "no spot for a wild plot on this floor");
				return;
			}
			SpawnWild(RollWildSeed(), pos);
		}

		bool Picked(UnitPtr u)
		{
			return u.IsValid() && g_picked.find(u.GetId()) >= 0;
		}

		// local: the player harvests a wild plot for themselves
		void HarvestWild(UnitPtr u, const string &in seedId)
		{
			auto seed = GetSeed(seedId);
			auto rec = GetLocalPlayerRecord();
			if (seed is null || rec is null || !u.IsValid() || Picked(u))
				return;
			g_picked.insertLast(u.GetId());
			int n = seed.yieldMin + randi(seed.yieldMax - seed.yieldMin + 1);
			int roll = randi(100);
			int seeds = roll < 10 ? 2 : (roll < 50 ? 1 : 0); // twice the farm's 5 % / 25 %
			HWP::Market::Add(rec, seed.id, n);
			if (seeds > 0)
				AddSeeds(seed.id, seeds);
			string text = Resources::GetString(".hwp.farming.harvested", { { "n", n }, { "name", seed.Name() } });
			if (seeds > 0)
				text += " " + Resources::GetString(seeds > 1 ? ".hwp.farming.seed_back2" : ".hwp.farming.seed_back", { { "n", seeds } });
			Say(text);
			HWP::Commands::Reply(text);
			g_lastMessage = "";
			HWP::Log("farming", "harvested a wild " + seed.id + " plot: " + n + " (+" + seeds + " seeds)");
			u.SetHidden(true); // gone for this player; the others still have theirs
		}

		// ---- commands -----------------------------------------------------------------

		string SeedList(bool herbsOnly)
		{
			string s = "";
			for (uint i = 0; i < g_seeds.length(); i++)
			{
				if (herbsOnly && !g_seeds[i].herb)
					continue;
				if (!s.isEmpty())
					s += ", ";
				s += g_seeds[i].id;
			}
			return s;
		}

		void MoveSetting(const string &in xKey, const string &in yKey, vec3 p)
		{
			HWP::Settings::SetInt(xKey, int(p.x));
			HWP::Settings::SetInt(yKey, int(p.y));
			HWP::Commands::NotifySettingChanged(xKey);
			HWP::Commands::NotifySettingChanged(yKey);
		}

		void CmdFarm(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			string a = args.length() >= 1 ? args[0] : "";
			if (a == "here" || a == "well" || a == "fields")
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.host_only"));
					return;
				}
				if (a == "fields")
				{
					HWP::Settings::SetBool("farm.fields", true);
					HWP::Commands::NotifySettingChanged("farm.fields");
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.fields_on"));
					return;
				}
				if (rec is null || rec.actor is null)
					return;
				auto p = rec.actor.m_unit.GetPosition();
				if (a == "well")
				{
					MoveSetting("farm.well_x", "farm.well_y", p);
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.well_moved", { { "x", int(p.x) }, { "y", int(p.y) } }));
					return;
				}
				HWP::Settings::SetBool("farm.fields", false);
				MoveSetting("farm.x", "farm.y", p);
				HWP::Commands::NotifySettingChanged("farm.fields");
				HWP::Commands::Reply(Resources::GetString(".hwp.farming.moved", { { "x", int(p.x) }, { "y", int(p.y) } }));
				return;
			}
			if (a == "wild")
			{
				// debug 'wild [seed]': a wild plot beside you (any floor)
				if (!Network::IsServer() || !g_debug)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.debug_off"));
					return;
				}
				if (rec is null || rec.actor is null)
					return;
				if (args.length() >= 2 && args[1] == "pick")
				{
					HWPWildPlot@ content;
					HWPLocalNPC@ plot;
					if (g_lastWild.IsValid())
						@plot = cast<HWPLocalNPC>(g_lastWild.GetScriptBehavior());
					ActorPropertiesNPC@ props;
					if (plot !is null)
						@props = cast<ActorPropertiesNPC>(plot.m_props);
					if (props !is null && props.m_interact.length() > 0)
						@content = cast<HWPWildPlot>(props.m_interact[0]);
					if (content is null)
						HWP::Commands::Reply("no wild plot placed");
					else if (!content.CanInteract(rec))
						HWP::Commands::Reply("already harvested");
					else
						content.Interact(rec, 0);
					return;
				}
				auto seed = args.length() >= 2 ? GetSeed(args[1]) : RollWildSeed();
				if (SpawnWild(seed, rec.actor.m_unit.GetPosition() + vec3(40, 0, 0)))
					HWP::Commands::Reply("wild " + seed.id + " plot placed");
				return;
			}
			if (a == "grow")
			{
				if (!Network::IsServer() || !g_debug)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.debug_off"));
					return;
				}
				CountRun();
				Changed();
				RefreshVisuals();
				HWP::Commands::Reply("runs counted: " + g_runs);
				return;
			}
			// debug: what a player does at the farm, without walking there
			if (a == "plant" || a == "use" || a == "buy" || a == "refill" || a == "units")
			{
				if (!g_debug)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.debug_off"));
					return;
				}
				g_lastMessage = "";
				int plot = args.length() >= 2 ? parseInt(args[1]) - 1 : -1; // 1-based like the status list
				if (a == "plant" && args.length() >= 3 && plot >= 0 && plot < PlotCount())
					RequestPlant(plot, GetSeed(args[2]));
				else if (a == "use" && plot >= 0 && plot < PlotCount())
				{
					if (g_plotSeed[plot].isEmpty())
						HWP::Commands::Reply("plot " + (plot + 1) + " is empty");
					else if (IsReady(plot))
						RequestHarvest(plot);
					else
						RequestWater(plot);
				}
				else if (a == "buy" && args.length() >= 2)
				{
					if (args[1] == "can")
						BuyCan();
					else
						BuySeed(GetSeed(args[1]));
				}
				else if (a == "refill")
					Refill();
				else if (a == "units")
					HWP::Commands::Reply("plots " + PlotCount() + " (" + (UseFields() ? "fields" : "patches") + "), plot units "
						+ g_plotUnits.length() + ", visuals " + g_visual.length() + ", well " + (g_wellUnit.IsValid() ? "yes" : "no")
						+ ", hidden crops " + g_hiddenCrops.length() + ", tree moved " + (g_treeMoved ? "yes" : "no"));
				else
					HWP::Commands::Reply("usage: hwp farm plant <plot> <seed> | use <plot> | buy can|<seed> | refill | units");
				if (!g_lastMessage.isEmpty())
					HWP::Commands::Reply(g_lastMessage);
				return;
			}
			string list = "";
			for (int i = 0; i < PlotCount(); i++)
			{
				auto s = GetSeed(g_plotSeed[i]);
				if (s is null)
					continue;
				if (!list.isEmpty())
					list += " | ";
				list += (i + 1) + ": " + s.Name() + (IsReady(i) ? " ready" : " (" + g_plotGrowth[i] + "/" + s.grow + (g_plotWet[i] ? ", watered" : "") + ")");
			}
			if (list.isEmpty())
				list = "-";
			auto p = UseFields() ? PlotPos(0) : BasePos();
			HWP::Commands::Reply(Resources::GetString(".hwp.farming.status", {
				{ "state", g_enabled ? "on" : "off" }, { "plots", PlotCount() }, { "where", UseFields() ? "fields" : "patches" },
				{ "x", int(p.x) }, { "y", int(p.y) }, { "runs", g_runs }, { "list", list } }));
			HWP::Commands::Reply(CanText() + ". " + SeedsText());
			auto wares = HWP::Market::Summary(rec, "crop");
			auto herbs = HWP::Market::Summary(rec, "herb");
			if (!herbs.isEmpty())
				wares += (wares.isEmpty() ? "" : ", ") + herbs;
			HWP::Commands::Reply(wares.isEmpty() ? Resources::GetString(".hwp.farming.wares_none")
				: Resources::GetString(".hwp.farming.wares", { { "list", wares } }));
		}

		void CmdSmoke(array<string>@ args)
		{
			if (args.length() < 1 || GetSeed(args[0]) is null || !GetSeed(args[0]).herb)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.farming.unknown_herb", { { "list", SeedList(true) } }));
				return;
			}
			if (!Smoke(args[0]))
				HWP::Commands::Reply(g_lastMessage);
		}
	}
}

// The watering can corner of the character menu's gear grid (core hwp-gear-slot
// widget hwp-gear-can): its size and water, dimmed while you have none.
class HWPFarmCanSlot : HWP::Gear::Slot
{
	ScriptSprite@ Icon() override
	{
		return ScriptSprite(Resources::GetTexture2D("doodads/hwp/farm.png"), vec4(64, 0, 16, 16));
	}

	bool Dim() override { return HWP::Farming::CanTier() <= 0; }

	string Title() override
	{
		int tier = HWP::Farming::CanTier();
		if (tier <= 0)
			return Resources::GetString(".hwp.farming.slot_title");
		return Resources::GetString(".hwp.farming.slot_title_tier", { { "tier", tier } });
	}

	string Text() override
	{
		if (HWP::Farming::CanTier() <= 0)
			return Resources::GetString(".hwp.farming.slot_none");
		return Resources::GetString(".hwp.farming.slot_text", { { "n", HWP::Farming::Water() }, { "max", HWP::Farming::CanSize() } });
	}
}

// Interact class of the plot units. Works on the plot the player stands at:
// empty -> seed window, growing -> water, ready -> harvest.
class HWPFarmPlot : AShopContent
{
	int m_index = -1;

	HWPFarmPlot() {}
	HWPFarmPlot(UnitPtr u, SValue& params) { super(u, params); }

	int IndexFor(PlayerRecord@ player)
	{
		if (!HWP::Farming::UseFields())
		{
			int own = HWP::Farming::PlotIndexAt(m_unit.GetPosition());
			if (own >= 0)
				return own;
		}
		if (player !is null && player.actor !is null)
		{
			int i = HWP::Farming::PlotIndexAt(player.actor.m_unit.GetPosition());
			if (i >= 0)
				return i;
		}
		return HWP::Farming::PlotIndexAt(m_unit.GetPosition());
	}

	bool CanInteract(PlayerRecord@ player) override { return HWP::Farming::g_enabled && IndexFor(player) >= 0; }

	void Interact(PlayerRecord@ player, int interactLevel) override
	{
		m_index = IndexFor(player);
		if (m_index < 0)
			return;
		if (!Network::IsServer() && !HWP::Farming::g_haveState)
		{
			HWP::Net::Request(HWP::Farming::PULL);
			HWP::Farming::Say(Resources::GetString(".hwp.farming.waiting"));
			return;
		}
		if (HWP::Farming::g_plotSeed[m_index].isEmpty())
		{
			AShopContent::Interact(player, interactLevel);
			return;
		}
		if (HWP::Farming::IsReady(m_index))
			HWP::Farming::RequestHarvest(m_index);
		else if (HWP::Farming::Waiting())
			return;
		else if (HWP::Farming::CanWater(m_index))
			HWP::Farming::RequestWater(m_index);
		else
		{
			string why = HWP::Farming::g_lastMessage;
			AShopContent::Interact(player, interactLevel);
			HWP::Farming::Say(why); // the window opened with an empty message line
		}
	}

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPFarmMenu(guiBuilder, m_index);
		return m_window;
	}

	string GetName() override { return "hwp_farm_plot"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

// Interact class of the in-run wild plots (doodads/hwp/wild/*.unit): harvest
// for yourself, once; no planting.
class HWPWildPlot : AShopContent
{
	string m_seed;

	HWPWildPlot() {}
	HWPWildPlot(UnitPtr u, SValue& params)
	{
		super(u, params);
		m_seed = GetParamString(u, params, "seed", false, "");
	}

	bool CanInteract(PlayerRecord@ player) override
	{
		return player !is null && player.local && HWP::Farming::g_enabled && !HWP::Farming::Picked(m_unit);
	}

	void Interact(PlayerRecord@ player, int interactLevel) override
	{
		if (player !is null && player.local)
			HWP::Farming::HarvestWild(m_unit, m_seed);
	}

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override { return null; }

	string GetName() override { return "hwp_wild_plot"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

// Interact class of the farm well: refills the watering can.
class HWPFarmWell : AShopContent
{
	HWPFarmWell() {}
	HWPFarmWell(UnitPtr u, SValue& params) { super(u, params); }

	bool CanInteract(PlayerRecord@ player) override { return HWP::Farming::g_enabled; }

	void Interact(PlayerRecord@ player, int interactLevel) override
	{
		HWP::Farming::Refill();
	}

	string GetName() override { return "hwp_farm_well"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

// Interact class of the farmer: sells the watering can, its upgrades and seeds.
class HWPFarmerShop : AShopContent
{
	HWPFarmerShop() {}
	HWPFarmerShop(UnitPtr u, SValue& params) { super(u, params); }

	bool CanInteract(PlayerRecord@ player) override { return HWP::Farming::g_enabled; }

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPFarmMenu(guiBuilder, -1, true);
		return m_window;
	}

	string GetName() override { return "hwp_farmer"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

// The plot window (plant one of your seeds, smoke herbs) and the farmer's
// shop (watering can, seeds) share gui/hwp_farm.gui.
class HWPFarmMenu : AWindowObject
{
	int m_index;
	bool m_shop;
	int m_seenVersion = -1;

	TextWidget@ m_state;
	TextWidget@ m_message;
	TextWidget@ m_active;
	TextWidget@ m_wares;
	Widget@ m_list;
	Widget@ m_rowTemplate;
	TextWidget@ m_headerTemplate;

	array<Widget@> m_rows;
	array<string> m_rowActions; // "plant:<seed>", "smoke:<seed>", "can", "buy:<seed>"

	HWPFarmMenu(GUIBuilder@ b, int index, bool shop = false)
	{
		super(b, "gui/hwp_farm.gui");
		PauseGame(true, true);
		m_index = index;
		m_shop = shop;

		@m_state = cast<TextWidget>(m_widget.GetWidgetById("state"));
		@m_message = cast<TextWidget>(m_widget.GetWidgetById("message"));
		@m_active = cast<TextWidget>(m_widget.GetWidgetById("active"));
		@m_wares = cast<TextWidget>(m_widget.GetWidgetById("wares"));
		@m_list = m_widget.GetWidgetById("list");
		@m_rowTemplate = m_widget.GetWidgetById("row-template");
		@m_headerTemplate = cast<TextWidget>(m_widget.GetWidgetById("header-template"));

		auto title = cast<TextWidget>(m_widget.GetWidgetById("title"));
		if (title !is null)
			title.SetText(m_shop ? Resources::GetString(".hwp.farming.farmer")
				: Resources::GetString(".hwp.farming.title", { { "n", m_index + 1 } }));

		HWP::Farming::g_lastMessage = "";
		if (!m_shop && !Network::IsServer())
			HWP::Net::Request(HWP::Farming::PULL);
		Refresh();
	}

	void AddHeader(const string &in text)
	{
		auto h = cast<TextWidget>(m_headerTemplate.Clone());
		h.SetID("");
		h.m_visible = true;
		h.SetText(text);
		m_list.AddChild(h);
	}

	void AddRow(const string &in text, const string &in action)
	{
		auto row = m_rowTemplate.Clone();
		row.SetID("");
		row.m_visible = true;
		auto btn = cast<ScalableSpriteButtonWidget>(row);
		if (btn !is null)
			btn.SetText(text);
		m_list.AddChild(row);
		m_rows.insertLast(row);
		m_rowActions.insertLast(action);
	}

	void RefreshShop(PlayerRecord@ rec)
	{
		int tier = HWP::Farming::CanTier();
		m_state.SetText(HWP::Farming::CanText());
		if (tier + 1 < int(HWP::Farming::CAN_SIZE.length()))
		{
			int next = tier + 1;
			AddRow(Resources::GetString(next == 1 ? ".hwp.farming.buy_can" : ".hwp.farming.upgrade_can", {
				{ "max", HWP::Farming::CAN_SIZE[next] }, { "price", HWP::Farming::CAN_PRICE[next] } }), "can");
		}
		AddHeader(Resources::GetString(".hwp.farming.seed_header"));
		for (uint i = 0; i < HWP::Farming::g_seeds.length(); i++)
		{
			auto s = HWP::Farming::g_seeds[i];
			AddRow(Resources::GetString(".hwp.farming.buy_seed", {
				{ "name", s.Name() }, { "price", s.price }, { "runs", s.Runs(false) }, { "wet", s.Runs(true) },
				{ "n", HWP::Farming::SeedCount(s.id) } }), "buy:" + s.id);
		}
		m_active.SetText(Resources::GetString(".hwp.farming.gold", { { "n", rec is null ? 0 : rec.GetMaterial(MaterialType::Gold) } }));
		m_wares.SetText(HWP::Farming::SeedsText());
	}

	void RefreshPlot(PlayerRecord@ rec)
	{
		if (m_index < 0 || (!Network::IsServer() && !HWP::Farming::g_haveState))
		{
			m_state.SetText(Resources::GetString(".hwp.farming.waiting"));
		}
		else
		{
			auto seed = HWP::Farming::GetSeed(HWP::Farming::g_plotSeed[m_index]);
			if (seed is null)
			{
				bool any = false;
				for (uint i = 0; i < HWP::Farming::g_seeds.length(); i++)
				{
					auto s = HWP::Farming::g_seeds[i];
					int n = HWP::Farming::SeedCount(s.id);
					if (n <= 0)
						continue;
					any = true;
					AddRow(Resources::GetString(".hwp.farming.plant", {
						{ "name", s.Name() }, { "n", n }, { "runs", s.Runs(false) }, { "wet", s.Runs(true) } }), "plant:" + s.id);
				}
				m_state.SetText(Resources::GetString(any ? ".hwp.farming.empty" : ".hwp.farming.empty_noseeds"));
			}
			else if (HWP::Farming::IsReady(m_index))
				m_state.SetText(Resources::GetString(".hwp.farming.ready", { { "name", seed.Name() } }));
			else
				m_state.SetText(Resources::GetString(HWP::Farming::g_plotWet[m_index] ? ".hwp.farming.growing_wet" : ".hwp.farming.growing", {
					{ "name", seed.Name() }, { "runs", HWP::Farming::RunsLeft(m_index) } }));
		}

		// herbs in the bag can be smoked from any plot
		bool header = false;
		for (uint i = 0; i < HWP::Farming::g_seeds.length(); i++)
		{
			auto s = HWP::Farming::g_seeds[i];
			if (!s.herb)
				continue;
			int n = HWP::Market::Count(rec, s.id);
			if (n <= 0)
				continue;
			if (!header)
			{
				AddHeader(Resources::GetString(".hwp.farming.herbs"));
				header = true;
			}
			AddRow(Resources::GetString(".hwp.farming.smoke", { { "name", s.Name() }, { "n", n } }), "smoke:" + s.id);
		}

		auto active = HWP::Farming::ActiveHerbName(rec);
		m_active.SetText(HWP::Farming::CanText() + ". " + (active.isEmpty() ? Resources::GetString(".hwp.farming.active_none")
			: Resources::GetString(".hwp.farming.active", { { "name", active } })));
		auto wares = HWP::Market::Summary(rec, "crop");
		auto herbs = HWP::Market::Summary(rec, "herb");
		if (!herbs.isEmpty())
			wares += (wares.isEmpty() ? "" : ", ") + herbs;
		m_wares.SetText(wares.isEmpty() ? Resources::GetString(".hwp.farming.wares_none")
			: Resources::GetString(".hwp.farming.wares", { { "list", wares } }));
	}

	void Refresh()
	{
		m_seenVersion = HWP::Farming::g_version;
		m_list.ClearChildren();
		m_rows.removeRange(0, m_rows.length());
		m_rowActions.removeRange(0, m_rowActions.length());
		m_message.SetText(HWP::Farming::g_lastMessage);
		auto rec = GetLocalPlayerRecord();
		if (m_shop)
			RefreshShop(rec);
		else
			RefreshPlot(rec);
	}

	bool Update(int ms, GameInput& gameInput, MenuInput& menuInput) override
	{
		bool result = AWindowObject::Update(ms, gameInput, menuInput);
		if (m_seenVersion != HWP::Farming::g_version)
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
		{
			m_manager.CloseWindow(this);
			return;
		}
		if (name != "row")
			return;
		for (uint i = 0; i < m_rows.length(); i++)
		{
			if (m_rows[i] !is sender)
				continue;
			auto action = m_rowActions[i];
			if (action == "can")
				HWP::Farming::BuyCan();
			else if (action.findFirst("buy:") == 0)
				HWP::Farming::BuySeed(HWP::Farming::GetSeed(action.substr(4)));
			else if (action.findFirst("plant:") == 0)
			{
				if (HWP::Farming::RequestPlant(m_index, HWP::Farming::GetSeed(action.substr(6))))
					m_manager.CloseWindow(this);
			}
			else if (action.findFirst("smoke:") == 0)
				HWP::Farming::Smoke(action.substr(6));
			HWP::Farming::g_version++;
			return;
		}
	}
}

namespace Modules
{
	class HWPFarmingModule : Module, HWP::ModuleStart
	{
		bool m_spawnDone = true;
		int m_delay = 0;

		HWPFarmingModule()
		{
			super("hwp-farming");
			HWP::Farming::DefineSeeds();
			HWP::Gear::Register("hwp-gear-can", HWPFarmCanSlot());
			HWP::Settings::Sync("farm.");
			HWP::Farming::RefreshSettings();
			HWP::Net::OnRequest(HWP::Farming::PLANT, HWP::Net::RequestHandler(HWP::Farming::OnPlant));
			HWP::Net::OnRequest(HWP::Farming::HARVEST, HWP::Net::RequestHandler(HWP::Farming::OnHarvest));
			HWP::Net::OnRequest(HWP::Farming::WATER, HWP::Net::RequestHandler(HWP::Farming::OnWater));
			HWP::Net::OnRequest(HWP::Farming::PULL, HWP::Net::RequestHandler(HWP::Farming::OnPull));
			HWP::Net::OnEvent(HWP::Farming::SYNC, HWP::Net::EventHandler(HWP::Farming::OnSync));
			HWP::Net::OnEvent(HWP::Farming::YIELD, HWP::Net::EventHandler(HWP::Farming::OnYield));
			HWP::Net::OnEvent(HWP::Farming::PLANTED, HWP::Net::EventHandler(HWP::Farming::OnPlanted));
			HWP::Net::OnEvent(HWP::Farming::WATERED, HWP::Net::EventHandler(HWP::Farming::OnWatered));
			HWP::Net::OnEvent(HWP::Farming::REFUSED, HWP::Net::EventHandler(HWP::Farming::OnRefused));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Farming::OnSettingChanged));
			HWP::Commands::Register("farm", " farm status; host: 'here' moves the plots off the fields to you, 'fields' puts them back, 'well' moves the well to you, 'grow' counts a run, 'wild [seed]' places a wild plot (debug)", HWP::Commands::Handler(HWP::Farming::CmdFarm));
			HWP::Commands::Register("smoke", " <herb> smoke a Holy Herb strain for a buff on your next run", HWP::Commands::Handler(HWP::Farming::CmdSmoke));
			HWP::Farming::SelfCheck();
		}

		void Start(StartMode sMode)
		{
			HWP::Farming::RefreshSettings();
			HWP::Farming::OnGameplayLoad();
			m_spawnDone = false;
			m_delay = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (HWP::Farming::g_waitMs > 0)
				HWP::Farming::g_waitMs -= ms;
			if (m_spawnDone)
				return;
			m_delay += ms;
			if (m_delay < 700)
				return;
			m_spawnDone = true;
			if (!HWP::Farming::g_enabled)
				return;
			if (g_inTown)
				HWP::Farming::SetupTown();
			else
				HWP::Farming::SetupRun();
		}
	}
}
