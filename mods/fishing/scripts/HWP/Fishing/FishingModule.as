// Fishing. A fishing spot in town (doodads/hwp/fishing_spot.unit) runs a
// timing minigame on the local machine; the catch goes into the player's wares
// (HWP::Market) and sells at the Gambler. At the start of a run the host
// sometimes spawns a fishing hole next to the players. A cast there asks the
// host (`fishing.cast`): it spends one of the player's casts for the level,
// rolls the tier and the bite delay and answers `fishing.bite`; the minigame
// then runs with that tier and a hit sends `fishing.catch`, which spawns the
// loot of the host-rolled tier from tweak/hwp/loot_fishing.sval. Clients never
// choose what they catch.
namespace HWP
{
	namespace Fishing
	{
		const string SPOT_UNIT = "doodads/hwp/fishing_spot.unit";
		const string HOLE_UNIT = "doodads/hwp/fishing_hole.unit";
		const string CAST = "fishing.cast";     // client -> host: a cast at a hole
		const string BITE = "fishing.bite";     // host -> peer: { tier, delay }
		const string CATCH = "fishing.catch";   // client -> host: the reel hit
		const string DENIED = "fishing.denied"; // host -> peer: no casts left
		const int TIERS = 4;
		const int BITE_WINDOW = 2500;           // ms to reel after a bite
		const int BAR_WIDTH = 240;              // px, matches gui/hwp_fishing.gui
		const int STATE_IDLE = 0;
		const int STATE_WAIT = 1;
		const int STATE_BITE = 2;
		const int STATE_RESULT = 3;
		const array<int> ZONE_WIDTH = { 64, 44, 28, 16 };          // per tier, px of a 240 px bar
		const array<float> MARKER_SPEED = { 0.12f, 0.16f, 0.2f, 0.26f }; // px per ms

		class Fish
		{
			string id;
			int tier;
			int price;
			Fish(const string &in id_, int tier_, int price_) { id = id_; tier = tier_; price = price_; }
			string Name() { return Resources::GetString(".hwp.fishing.fish." + id); }
		}
		array<Fish@> g_fish;

		void AddFish(const string &in id, int tier, int price)
		{
			g_fish.insertLast(Fish(id, tier, price));
			HWP::Market::Register(id, ".hwp.fishing.fish." + id, price, "fish");
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

		// ---- settings ------------------------------------------------------------

		bool g_enabled = true;
		int g_runChance = 30;  // % of runs that get a fishing hole at the start
		int g_runCasts = 3;    // catches per player per level at a hole
		int g_biteMin = 800;
		int g_biteMax = 3000;
		bool g_debug = false;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("fishing.enabled", true);
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

		vec3 SpotPos()
		{
			return vec3(float(HWP::Settings::GetInt("fishing.spot_x", -1600)),
				float(HWP::Settings::GetInt("fishing.spot_y", 330)), 0.0f);
		}

		// ---- rolls ------------------------------------------------------------------

		int RollTier()
		{
			int r = randi(1000);
			if (r < 40) return 4;
			if (r < 170) return 3;
			if (r < 450) return 2;
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
			g_pendingTier[peer] = RollTier();
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

		UnitPtr g_spotUnit; // host: the town spot spawned this level

		UnitPtr SpawnAt(const string &in unitPath, vec3 pos)
		{
			auto prod = Resources::GetUnitProducer(unitPath);
			if (prod is null)
			{
				HWP::LogError("fishing", "missing " + unitPath);
				return UnitPtr();
			}
			auto u = prod.Produce(g_scene, pos);
			HWP::Log("fishing", "spawned " + unitPath + " at " + pos.x + "," + pos.y);
			return u;
		}

		void SpawnSpot(vec3 pos)
		{
			if (g_spotUnit.IsValid())
				g_spotUnit.Destroy();
			g_spotUnit = SpawnAt(SPOT_UNIT, pos);
		}

		void SelfCheck()
		{
			array<string> tables;
			for (int t = 1; t <= TIERS; t++)
				tables.insertLast("hwp_fishing_run_" + t);
			HWP::CheckLootTables("fishing", tables);
			HWP::CheckUnits("fishing", { SPOT_UNIT, HOLE_UNIT });
			HWP::Log("fishing", "self-check done: " + g_fish.length() + " fish");
		}

		// ---- commands -----------------------------------------------------------------

		void CmdFishing(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (args.length() >= 1 && args[0] == "here")
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.fishing.host_only"));
					return;
				}
				if (rec is null || rec.actor is null)
				{
					HWP::Commands::Reply("no player actor");
					return;
				}
				auto p = rec.actor.m_unit.GetPosition();
				HWP::Settings::SetInt("fishing.spot_x", int(p.x));
				HWP::Settings::SetInt("fishing.spot_y", int(p.y));
				HWP::Commands::NotifySettingChanged("fishing.spot_x");
				HWP::Commands::NotifySettingChanged("fishing.spot_y");
				if (g_inTown)
					SpawnSpot(vec3(float(int(p.x)), float(int(p.y)), 0.0f));
				HWP::Commands::Reply(Resources::GetString(".hwp.fishing.moved", { { "x", int(p.x) }, { "y", int(p.y) } }));
				return;
			}
			if (args.length() >= 1 && args[0] == "hole")
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
			auto pos = SpotPos();
			auto s = HWP::Market::Summary(rec, "fish");
			HWP::Commands::Reply(Resources::GetString(".hwp.fishing.status", {
				{ "state", g_enabled ? "on" : "off" }, { "x", int(pos.x) }, { "y", int(pos.y) },
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
			m_wares.SetText("");
			return;
		}
		m_casts.SetText("");
		auto s = HWP::Market::Summary(rec, "fish");
		m_wares.SetText(s.isEmpty() ? Resources::GetString(".hwp.fishing.wares_none")
			: Resources::GetString(".hwp.fishing.wares", { { "list", s } }));
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
			// town: roll the bite here; a hole: the host answers fishing.bite
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
				m_tier = HWP::Fishing::RollTier(); // a hole: m_tier came from the host
			m_zoneW = HWP::Fishing::ZONE_WIDTH[m_tier - 1];
			m_zoneX = randi(HWP::Fishing::BAR_WIDTH - m_zoneW + 1);
			m_markerPos = 0;
			m_markerDir = 1;
			m_timer = HWP::Fishing::BITE_WINDOW;
			m_zone.m_width = m_zoneW;
			m_zone.m_offset = vec2(float(m_zoneX), 0);
			m_zone.m_visible = true;
			m_marker.m_offset = vec2(0, 0);
			m_marker.m_visible = true;
			m_status.SetText(Resources::GetString(".hwp.fishing.bite"));
			m_castButton.SetText(Resources::GetString(".hwp.fishing.reel"));
		}
		else if (state == HWP::Fishing::STATE_RESULT)
		{
			m_castButton.SetText(Resources::GetString(".hwp.fishing.cast_again"));
			m_status.SetText(Resources::GetString(".hwp.fishing.idle"));
		}
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
				HWP::Market::Add(GetLocalPlayerRecord(), fish.id, 1);
				m_log.SetText(Resources::GetString(".hwp.fishing.caught", { { "fish", fish.Name() } }));
			}
		}
		SetState(HWP::Fishing::STATE_RESULT);
		RefreshInfo();
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
			m_markerPos += HWP::Fishing::MARKER_SPEED[m_tier - 1] * float(ms) * float(m_markerDir);
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
			m_marker.m_offset = vec2(m_markerPos, 0);
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
			{
				if (m_spot.m_inRun && Network::IsServer() && HWP::Fishing::CastsLeft(uint8(Lobby::GetLocalPeer())) <= 0)
				{
					m_log.SetText(Resources::GetString(".hwp.fishing.denied"));
					return;
				}
				if (m_spot.m_inRun && HWP::Fishing::g_lastDenied)
				{
					m_log.SetText(Resources::GetString(".hwp.fishing.denied"));
					return;
				}
				if (m_spot.m_inRun)
				{
					HWP::Fishing::g_biteTier = 0;
					HWP::Net::Request(HWP::Fishing::CAST);
				}
				SetState(HWP::Fishing::STATE_WAIT);
			}
		}
	}
}

namespace Modules
{
	class HWPFishingModule : Module
	{
		bool m_spawnDone = true;
		int m_delay = 0;

		HWPFishingModule()
		{
			super("hwp-fishing");
			HWP::Fishing::DefineFish();
			HWP::Settings::Sync("fishing.");
			HWP::Fishing::RefreshSettings();
			HWP::Net::OnRequest(HWP::Fishing::CAST, HWP::Net::RequestHandler(HWP::Fishing::OnCastRequest));
			HWP::Net::OnRequest(HWP::Fishing::CATCH, HWP::Net::RequestHandler(HWP::Fishing::OnCatch));
			HWP::Net::OnEvent(HWP::Fishing::BITE, HWP::Net::EventHandler(HWP::Fishing::OnBite));
			HWP::Net::OnEvent(HWP::Fishing::DENIED, HWP::Net::EventHandler(HWP::Fishing::OnDenied));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Fishing::OnSettingChanged));
			HWP::Commands::Register("fishing", " fishing status; 'here' moves the town spot (host), 'hole' spawns a run hole (debug)", HWP::Commands::Handler(HWP::Fishing::CmdFishing));
			HWP::Fishing::SelfCheck();
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::Fishing::RefreshSettings();
			HWP::Fishing::ResetCasts();
			HWP::Fishing::g_spotUnit = UnitPtr();
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
			if (!Network::IsServer() || !HWP::Fishing::g_enabled)
			{
				m_spawnDone = true;
				return;
			}
			if (g_inTown)
			{
				m_spawnDone = true;
				HWP::Fishing::SpawnSpot(HWP::Fishing::SpotPos());
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
