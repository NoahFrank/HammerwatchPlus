// Farming. The host spawns farm plots in town (doodads/hwp/farm_plot.unit);
// the plot state lives in the host's own TownRecord (HWP data bag, "farm.*")
// and is mirrored to clients with `farm.sync`. Planting is requested from the
// host (`farm.plant`); the host answers `farm.planted` and only then the
// requester pays the seed (or `farm.refused`, which costs nothing). Harvest
// (`farm.harvest`) comes back as `farm.yield` and lands in the requester's
// wares (HWP::Market). Crops grow one step per completed run: a gameplay load that
// is not the town sets "farm.pending", the next town load counts the run.
// Herbs can be smoked (one "hwp_herb" mission buff, lasts the next run).
namespace HWP
{
	namespace Farming
	{
		const string PLOT_UNIT = "doodads/hwp/farm_plot.unit";
		const string SPROUT_UNIT = "doodads/hwp/farm_sprout.unit";
		const string CROP_UNIT_PREFIX = "doodads/hwp/crops/";
		const string PLANT = "farm.plant";     // client -> host: { plot, seed }
		const string HARVEST = "farm.harvest"; // client -> host: { plot }
		const string PULL = "farm.pull";       // client -> host: send me the state
		const string SYNC = "farm.sync";       // host -> all: { runs, plots: [ { seed, at } ] }
		const string YIELD = "farm.yield";     // host -> peer: { seed, n }
		const string PLANTED = "farm.planted"; // host -> peer: { seed, plot } pay now
		const string REFUSED = "farm.refused"; // host -> peer: the plant request failed
		const string KEY_PLOTS = "farm.plots";
		const string KEY_RUNS = "farm.runs";
		const string KEY_PENDING = "farm.pending";
		const string HERB_SLOT = "hwp_herb";   // SetMissionBuff slot id
		const int MAX_PLOTS = 8;
		const int SPACING = 40;

		class Seed
		{
			string id;
			int price;
			bool herb;
			int grow;      // runs until ready
			int yieldMin;
			int yieldMax;
			int sell;      // ware price per unit
			Seed(const string &in id_, int price_, bool herb_, int grow_, int ymin, int ymax, int sell_)
			{
				id = id_; price = price_; herb = herb_; grow = grow_; yieldMin = ymin; yieldMax = ymax; sell = sell_;
			}
			string Name() { return Resources::GetString(".hwp.farming.seed." + id); }
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
			AddSeed("cabbage", 20, false, 1, 2, 4, 15);
			AddSeed("carrot", 20, false, 1, 3, 5, 10);
			AddSeed("onion", 25, false, 1, 2, 4, 15);
			AddSeed("potato", 30, false, 1, 3, 6, 12);
			AddSeed("wheat", 15, false, 1, 4, 8, 6);
			AddSeed("lucky_leaf", 150, true, 2, 1, 2, 120);
			AddSeed("ember_kush", 200, true, 2, 1, 2, 160);
			AddSeed("saints_sage", 200, true, 2, 1, 2, 160);
			AddSeed("gamblers_gold", 250, true, 2, 1, 2, 200);
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

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("farm.enabled", true);
			g_debug = HWP::Settings::GetBool("farm.debug", false);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("farm.") == 0)
				RefreshSettings();
		}

		int PlotCount()
		{
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

		vec3 PlotPos(int i) { return BasePos() + vec3(float(i * SPACING), 0, 0); }

		int PlotIndexAt(vec3 pos)
		{
			float dx = pos.x - BasePos().x;
			int i = int((dx + float(SPACING) * 0.5f) / float(SPACING));
			if (dx < -float(SPACING) * 0.5f) i = -1;
			if (i < 0 || i >= PlotCount())
				return -1;
			return i;
		}

		// ---- state mirror (every machine) -------------------------------------

		array<string> g_plotSeed(MAX_PLOTS, "");
		array<int> g_plotAt(MAX_PLOTS, 0);
		int g_runs = 0;
		int g_version = 0;        // bumps on every state change (windows refresh)
		bool g_haveState = false; // clients: false until the first sync
		bool g_visualsReady = false; // set by the module once the scene settled
		array<UnitPtr> g_visual(MAX_PLOTS);
		array<UnitPtr> g_plotUnits(MAX_PLOTS); // host: the plot interactables

		bool IsReady(int i)
		{
			auto s = GetSeed(g_plotSeed[i]);
			return s !is null && g_runs - g_plotAt[i] >= s.grow;
		}

		int RunsLeft(int i)
		{
			auto s = GetSeed(g_plotSeed[i]);
			if (s is null)
				return 0;
			int left = s.grow - (g_runs - g_plotAt[i]);
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
				b.PushInteger("at", g_plotAt[i]);
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
				g_plotAt[i] = 0;
			}
			auto plotsV = HWP::SV::Field(data, "plots");
			if (plotsV !is null && plotsV.GetType() == SValueType::Array)
			{
				auto plots = plotsV.GetArray();
				for (uint i = 0; i < plots.length() && i < uint(MAX_PLOTS); i++)
				{
					g_plotSeed[i] = HWP::SV::Str(plots[i], "seed");
					g_plotAt[i] = HWP::SV::Int(plots[i], "at", 0);
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

		void Changed()
		{
			g_version++;
			SaveState();
			if (Network::IsServer())
				HWP::Net::Broadcast(SYNC, PackState());
		}

		// ---- visuals (local) ----------------------------------------------------

		void ClearVisuals()
		{
			for (int i = 0; i < MAX_PLOTS; i++)
			{
				if (g_visual[i].IsValid())
					g_visual[i].Destroy();
				g_visual[i] = UnitPtr();
			}
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
				string path = IsReady(i) ? CROP_UNIT_PREFIX + s.id + ".unit" : SPROUT_UNIT;
				auto prod = Resources::GetUnitProducer(path);
				if (prod is null)
				{
					HWP::LogError("farming", "missing " + path);
					continue;
				}
				g_visual[i] = prod.Produce(g_scene, PlotPos(i) + vec3(0, -2, 0));
			}
		}

		// ---- requests (host) ---------------------------------------------------

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
				HWP::Net::Send(peer, REFUSED);
				return;
			}
			g_plotSeed[plot] = seed.id;
			g_plotAt[plot] = g_runs;
			HWP::Log("farming", "peer " + peer + " planted " + seed.id + " on plot " + plot);
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("seed", seed.id);
			b.PushInteger("plot", plot);
			b.PopDictionary();
			HWP::Net::Send(peer, PLANTED, b.Build());
			Changed();
		}

		void OnHarvest(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_inTown)
				return;
			int plot = HWP::SV::Int(data, "plot", -1);
			if (plot < 0 || plot >= PlotCount() || !IsReady(plot))
				return;
			auto seed = GetSeed(g_plotSeed[plot]);
			if (seed is null)
				return;
			int n = seed.yieldMin + randi(seed.yieldMax - seed.yieldMin + 1);
			g_plotSeed[plot] = "";
			g_plotAt[plot] = 0;
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("seed", seed.id);
			b.PushInteger("n", n);
			b.PopDictionary();
			HWP::Net::Send(peer, YIELD, b.Build());
			HWP::Log("farming", "peer " + peer + " harvested " + n + "x " + seed.id + " from plot " + plot);
			Changed();
		}

		// ---- events (local) ----------------------------------------------------

		string g_lastMessage = "";

		void OnSync(SValue@ data) { ApplyState(data); }

		void OnYield(SValue@ data)
		{
			auto seed = GetSeed(HWP::SV::Str(data, "seed"));
			int n = HWP::SV::Int(data, "n", 0);
			if (seed is null || n <= 0)
				return;
			HWP::Market::Add(GetLocalPlayerRecord(), seed.id, n);
			g_lastMessage = Resources::GetString(".hwp.farming.harvested", { { "n", n }, { "name", seed.Name() } });
			HWP::Commands::Reply(g_lastMessage);
			g_version++;
		}

		// the host accepted our plant request: pay the seed now
		void OnPlanted(SValue@ data)
		{
			auto seed = GetSeed(HWP::SV::Str(data, "seed"));
			auto rec = GetLocalPlayerRecord();
			if (rec is null || seed is null)
				return;
			rec.GiveMaterial(MaterialType::Gold, -seed.price, true);
			g_lastMessage = Resources::GetString(".hwp.farming.planted", { { "name", seed.Name() }, { "price", seed.price } });
			HWP::Commands::Reply(g_lastMessage);
			g_version++;
		}

		void OnRefused(SValue@ data)
		{
			g_lastMessage = Resources::GetString(".hwp.farming.taken");
			HWP::Commands::Reply(g_lastMessage);
			g_version++;
		}

		// ---- actions from the window (any machine) ----------------------------

		bool RequestPlant(int plot, Seed@ seed)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || seed is null)
				return false;
			if (rec.GetMaterial(MaterialType::Gold) < seed.price)
			{
				g_lastMessage = Resources::GetString(".hwp.farming.no_gold");
				return false;
			}
			// paid in OnPlanted, once the host confirmed the plot
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("plot", plot);
			b.PushString("seed", seed.id);
			b.PopDictionary();
			HWP::Net::Request(PLANT, b.Build());
			g_lastMessage = Network::IsServer() ? "" : Resources::GetString(".hwp.farming.waiting");
			return true;
		}

		void RequestHarvest(int plot)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("plot", plot);
			b.PopDictionary();
			HWP::Net::Request(HARVEST, b.Build());
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
			HWP::Market::Add(rec, herbId, -1);
			rec.SetMissionBuff(HashString(HERB_SLOT), buff);
			g_lastMessage = Resources::GetString(".hwp.farming.smoked", { { "name", buff.m_name }, { "desc", buff.m_description } });
			HWP::Commands::Reply(g_lastMessage);
			g_version++;
			return true;
		}

		// ---- spawning + run counting (host) ----------------------------------

		void ClearPlots()
		{
			for (int i = 0; i < MAX_PLOTS; i++)
			{
				if (g_plotUnits[i].IsValid())
					g_plotUnits[i].Destroy();
				g_plotUnits[i] = UnitPtr();
			}
		}

		void SpawnPlots()
		{
			auto prod = Resources::GetUnitProducer(PLOT_UNIT);
			if (prod is null)
			{
				HWP::LogError("farming", "missing " + PLOT_UNIT);
				return;
			}
			ClearPlots();
			for (int i = 0; i < PlotCount(); i++)
				g_plotUnits[i] = prod.Produce(g_scene, PlotPos(i));
			auto p = BasePos();
			HWP::Log("farming", "spawned " + PlotCount() + " farm plots from " + p.x + "," + p.y);
		}

		void OnGameplayLoad()
		{
			// state only; units are spawned from the module's UpdateFrame once the
			// scene settled (g_visualsReady)
			g_visualsReady = false;
			ClearVisuals();
			for (int i = 0; i < MAX_PLOTS; i++)
				g_plotUnits[i] = UnitPtr();
			g_lastMessage = "";
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
				g_runs++;
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
			array<string> units = { PLOT_UNIT, SPROUT_UNIT };
			for (uint i = 0; i < g_seeds.length(); i++)
				units.insertLast(CROP_UNIT_PREFIX + g_seeds[i].id + ".unit");
			HWP::CheckUnits("farming", units);
			HWP::Log("farming", "self-check done: " + g_seeds.length() + " seeds, " + buffs + " herb buffs");
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

		void CmdFarm(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (args.length() >= 1 && args[0] == "here")
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.host_only"));
					return;
				}
				if (rec is null || rec.actor is null)
					return;
				auto p = rec.actor.m_unit.GetPosition();
				HWP::Settings::SetInt("farm.x", int(p.x));
				HWP::Settings::SetInt("farm.y", int(p.y));
				HWP::Commands::NotifySettingChanged("farm.x");
				HWP::Commands::NotifySettingChanged("farm.y");
				if (g_inTown)
				{
					SpawnPlots();
					RefreshVisuals();
				}
				HWP::Commands::Reply(Resources::GetString(".hwp.farming.moved", { { "x", int(p.x) }, { "y", int(p.y) } }));
				return;
			}
			if (args.length() >= 1 && args[0] == "grow")
			{
				if (!Network::IsServer() || !g_debug)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.farming.debug_off"));
					return;
				}
				g_runs++;
				Changed();
				RefreshVisuals();
				HWP::Commands::Reply("runs counted: " + g_runs);
				return;
			}
			string list = "";
			for (int i = 0; i < PlotCount(); i++)
			{
				if (!list.isEmpty())
					list += " | ";
				auto s = GetSeed(g_plotSeed[i]);
				if (s is null)
					list += (i + 1) + ": -";
				else
					list += (i + 1) + ": " + s.Name() + (IsReady(i) ? " ready" : " (" + RunsLeft(i) + ")");
			}
			auto p = BasePos();
			HWP::Commands::Reply(Resources::GetString(".hwp.farming.status", {
				{ "state", g_enabled ? "on" : "off" }, { "plots", PlotCount() }, { "x", int(p.x) }, { "y", int(p.y) },
				{ "runs", g_runs }, { "list", list } }));
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

// Interact class of doodads/hwp/farm_plot.unit.
class HWPFarmPlot : AShopContent
{
	HWPFarmPlot() {}
	HWPFarmPlot(UnitPtr u, SValue& params) { super(u, params); }

	int Index() { return HWP::Farming::PlotIndexAt(m_unit.GetPosition()); }

	bool CanInteract(PlayerRecord@ player) override { return HWP::Farming::g_enabled && Index() >= 0; }

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPFarmMenu(guiBuilder, this);
		return m_window;
	}

	string GetName() override { return "hwp_farm_plot"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class HWPFarmMenu : AWindowObject
{
	HWPFarmPlot@ m_plot;
	int m_index;
	int m_seenVersion = -1;

	TextWidget@ m_state;
	TextWidget@ m_message;
	TextWidget@ m_active;
	TextWidget@ m_wares;
	Widget@ m_list;
	Widget@ m_rowTemplate;
	TextWidget@ m_headerTemplate;

	array<Widget@> m_rows;
	array<string> m_rowActions; // "plant:<seed>", "harvest", "smoke:<seed>"

	HWPFarmMenu(GUIBuilder@ b, HWPFarmPlot@ plot)
	{
		super(b, "gui/hwp_farm.gui");
		PauseGame(true, true);
		@m_plot = plot;
		m_index = plot.Index();

		@m_state = cast<TextWidget>(m_widget.GetWidgetById("state"));
		@m_message = cast<TextWidget>(m_widget.GetWidgetById("message"));
		@m_active = cast<TextWidget>(m_widget.GetWidgetById("active"));
		@m_wares = cast<TextWidget>(m_widget.GetWidgetById("wares"));
		@m_list = m_widget.GetWidgetById("list");
		@m_rowTemplate = m_widget.GetWidgetById("row-template");
		@m_headerTemplate = cast<TextWidget>(m_widget.GetWidgetById("header-template"));

		auto title = cast<TextWidget>(m_widget.GetWidgetById("title"));
		if (title !is null)
			title.SetText(Resources::GetString(".hwp.farming.title", { { "n", m_index + 1 } }));

		if (!Network::IsServer())
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

	void Refresh()
	{
		m_seenVersion = HWP::Farming::g_version;
		m_list.ClearChildren();
		m_rows.removeRange(0, m_rows.length());
		m_rowActions.removeRange(0, m_rowActions.length());

		auto rec = GetLocalPlayerRecord();
		m_message.SetText(HWP::Farming::g_lastMessage);

		if (m_index < 0 || (!Network::IsServer() && !HWP::Farming::g_haveState))
		{
			m_state.SetText(Resources::GetString(".hwp.farming.waiting"));
		}
		else
		{
			auto seed = HWP::Farming::GetSeed(HWP::Farming::g_plotSeed[m_index]);
			if (seed is null)
			{
				m_state.SetText(Resources::GetString(".hwp.farming.empty"));
				for (uint i = 0; i < HWP::Farming::g_seeds.length(); i++)
				{
					auto s = HWP::Farming::g_seeds[i];
					AddRow(Resources::GetString(".hwp.farming.plant", {
						{ "name", s.Name() }, { "price", s.price }, { "runs", s.grow } }), "plant:" + s.id);
				}
			}
			else if (HWP::Farming::IsReady(m_index))
			{
				m_state.SetText(Resources::GetString(".hwp.farming.ready", { { "name", seed.Name() } }));
				AddRow(Resources::GetString(".hwp.farming.harvest", { { "name", seed.Name() } }), "harvest");
			}
			else
			{
				m_state.SetText(Resources::GetString(".hwp.farming.growing", {
					{ "name", seed.Name() }, { "runs", HWP::Farming::RunsLeft(m_index) } }));
			}
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
		m_active.SetText(active.isEmpty() ? Resources::GetString(".hwp.farming.active_none")
			: Resources::GetString(".hwp.farming.active", { { "name", active } }));
		auto wares = HWP::Market::Summary(rec, "crop");
		auto herbs = HWP::Market::Summary(rec, "herb");
		if (!herbs.isEmpty())
			wares += (wares.isEmpty() ? "" : ", ") + herbs;
		m_wares.SetText(wares.isEmpty() ? Resources::GetString(".hwp.farming.wares_none")
			: Resources::GetString(".hwp.farming.wares", { { "list", wares } }));
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
			if (action == "harvest")
				HWP::Farming::RequestHarvest(m_index);
			else if (action.findFirst("plant:") == 0)
				HWP::Farming::RequestPlant(m_index, HWP::Farming::GetSeed(action.substr(6)));
			else if (action.findFirst("smoke:") == 0)
				HWP::Farming::Smoke(action.substr(6));
			HWP::Farming::g_version++;
			return;
		}
	}
}

namespace Modules
{
	class HWPFarmingModule : Module
	{
		bool m_spawnDone = true;
		int m_delay = 0;

		HWPFarmingModule()
		{
			super("hwp-farming");
			HWP::Farming::DefineSeeds();
			HWP::Settings::Sync("farm.");
			HWP::Farming::RefreshSettings();
			HWP::Net::OnRequest(HWP::Farming::PLANT, HWP::Net::RequestHandler(HWP::Farming::OnPlant));
			HWP::Net::OnRequest(HWP::Farming::HARVEST, HWP::Net::RequestHandler(HWP::Farming::OnHarvest));
			HWP::Net::OnRequest(HWP::Farming::PULL, HWP::Net::RequestHandler(HWP::Farming::OnPull));
			HWP::Net::OnEvent(HWP::Farming::SYNC, HWP::Net::EventHandler(HWP::Farming::OnSync));
			HWP::Net::OnEvent(HWP::Farming::YIELD, HWP::Net::EventHandler(HWP::Farming::OnYield));
			HWP::Net::OnEvent(HWP::Farming::PLANTED, HWP::Net::EventHandler(HWP::Farming::OnPlanted));
			HWP::Net::OnEvent(HWP::Farming::REFUSED, HWP::Net::EventHandler(HWP::Farming::OnRefused));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Farming::OnSettingChanged));
			HWP::Commands::Register("farm", " farm status; 'here' moves the plots (host), 'grow' counts a run (debug)", HWP::Commands::Handler(HWP::Farming::CmdFarm));
			HWP::Commands::Register("smoke", " <herb> smoke a Holy Herb strain for a buff on your next run", HWP::Commands::Handler(HWP::Farming::CmdSmoke));
			HWP::Farming::SelfCheck();
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::Farming::RefreshSettings();
			HWP::Farming::OnGameplayLoad();
			m_spawnDone = false;
			m_delay = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (m_spawnDone)
				return;
			m_delay += ms;
			if (m_delay < 700)
				return;
			m_spawnDone = true;
			if (!g_inTown || !HWP::Farming::g_enabled)
				return;
			HWP::Farming::g_visualsReady = true;
			if (Network::IsServer())
			{
				HWP::Farming::SpawnPlots();
				HWP::Farming::RefreshVisuals();
			}
			else
				HWP::Net::Request(HWP::Farming::PULL); // the sync refreshes the visuals
		}
	}
}
