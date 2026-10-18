// Keys and ace chests: HoH1-style locked chests (HWPChest.as), key drops from
// enemies, the exit guard's key shop (GeneralMerchant.as), a key counter in
// the HUD and the ace chest's legendary payout.
//
//   keys.drop   client -> host   { x, y, tier }   spawn a key pickup here
//
// Drop rolls happen on the killer's machine (the PlayerKilledActor hook only
// fires for the local Player) and the host spawns the pickup; keys themselves
// are a vanilla PlayerRecord field (GetKeys/AddKeys) that the game saves.
// All keys.* settings are host-authoritative (HWP::Settings::Sync).
namespace HWP
{
	namespace Keys
	{
		const string DROP = "keys.drop";
		const string LOCK_UNIT = "doodads/hwp/chest_lock.unit";
		const string GUARD_UNIT = "actors/npcs/town/npc_misc_guard_exit.unit";
		const string KEY_UNIT_PREFIX = "items/hwp/keys/key_";
		const array<string> LEGENDARIES = {
			"hwp_descending_destruction", "hwp_dragons_tail", "hwp_medusas_charm",
			"hwp_sphere_of_heroes", "hwp_spirit_cloak", "hwp_soul_taker", "hwp_wand_of_chaos" };

		// ---- tiers (index = tier - 1) ------------------------------------------
		const array<string> TIERS = { "bronze", "silver", "gold", "ace" };
		const array<int> DEFAULT_PRICE = { 500, 2000, 8000, 50000 };
		// sprites in items/special/base.png (vanilla items/special/keys.unit)
		const array<vec4> ICON_FRAME = { vec4(0, 0, 16, 16), vec4(16, 0, 16, 16), vec4(32, 0, 16, 16), vec4(112, 16, 16, 16) };
		const array<vec4> TINT = { vec4(0.85f, 0.55f, 0.3f, 1.0f), vec4(0.85f, 0.88f, 0.95f, 1.0f), vec4(1.0f, 0.85f, 0.25f, 1.0f), vec4(1.0f, 0.25f, 0.2f, 1.0f) };
		const array<Item::Quality> QUALITY = { Item::Quality::Common, Item::Quality::Uncommon, Item::Quality::Rare, Item::Quality::Legendary };

		bool ValidTier(int tier) { return tier >= 1 && tier <= int(TIERS.length()); }

		int TierIndex(const string &in name)
		{
			for (uint i = 0; i < TIERS.length(); i++)
				if (TIERS[i] == name)
					return int(i) + 1;
			return 0;
		}

		int KeyPrice(int tier)
		{
			if (!ValidTier(tier))
				return 0;
			return HWP::Settings::GetInt("keys.price_" + TIERS[tier - 1], DEFAULT_PRICE[tier - 1]);
		}
		vec4 KeyIconFrame(int tier) { return ValidTier(tier) ? ICON_FRAME[tier - 1] : vec4(0, 0, 16, 16); }
		vec4 TierColor(int tier) { return ValidTier(tier) ? TINT[tier - 1] : vec4(1, 1, 1, 1); }
		Item::Quality TierQuality(int tier) { return ValidTier(tier) ? QUALITY[tier - 1] : Item::Quality::Common; }

		// ---- settings (host-authoritative, refreshed per level and on change) ----
		bool g_enabled = true;
		bool g_debug = false;
		float g_lockChance = 1.0f;
		float g_dropMult = 2.5f;
		float g_aceChance = 0.15f;
		float g_legendaryChance = 0.5f;

		int g_chestsLocked = 0;     // this level, for hwp keys
		int g_bossKeyLevel = -1;    // level index whose boss already rolled its key (killer side)
		int g_hostBossLevel = -1;   // host: level index of the boss drops below
		int g_hostBossMask = 0;     // host: 1 = the boss key for g_hostBossLevel dropped

		// host: key counts the clients reported (keys.count), 4 per peer
		const string COUNT = "keys.count";
		array<int> g_peerKeys(256 * 4, 0);
		array<int> g_lastSent(4, -1); // client: counts last reported
		int g_countTimer = 0;
		HWPKeysHUD@ g_hud;

		// host: recent drop requests for the rate limit
		const int DROP_LIMIT = 10;
		const int DROP_WINDOW = 10000;
		array<int> g_dropPeer;
		array<int> g_dropTime;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("keys.enabled", true);
			g_debug = HWP::Settings::GetBool("keys.debug", false);
			g_lockChance = clamp(HWP::Settings::GetFloat("keys.lock_chance", 1.0f), 0.0f, 1.0f);
			g_dropMult = clamp(HWP::Settings::GetFloat("keys.drop_mult", 2.5f), 0.0f, 50.0f);
			g_aceChance = clamp(HWP::Settings::GetFloat("keys.ace_chance", 0.15f), 0.0f, 1.0f);
			g_legendaryChance = clamp(HWP::Settings::GetFloat("keys.legendary_chance", 0.5f), 0.0f, 1.0f);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("keys.") == 0)
				RefreshSettings();
		}

		void RefreshHUD()
		{
			if (g_hud !is null)
				g_hud.Refresh(GetLocalPlayerRecord());
		}

		int CurrentLevel()
		{
			if (MissionManager::g_module is null)
				return -1;
			return int(MissionManager::g_module.m_missionLevelIndex);
		}

		MissionLevel@ CurrentMissionLevel()
		{
			auto def = MissionManager::GetCurrentMission();
			int idx = CurrentLevel();
			if (def is null || idx < 0 || idx >= int(def.m_levels.length()))
				return null;
			return def.m_levels[idx];
		}

		bool IsBossLevel(MissionLevel@ lvl)
		{
			return lvl.m_level.findFirst("levels/boss_") == 0 || lvl.m_id.findFirst("_boss") >= 0;
		}

		// The floor's key tier, scaled by its diff-level (without new game+)
		// the way the imp's own offers scale: the Dark Citadel's floors go
		// 2..22, the side missions 8..15.
		int FloorTier()
		{
			auto lvl = CurrentMissionLevel();
			int diff = lvl is null ? 1 : lvl.m_diffLevel;
			if (diff <= 7)
				return 1;
			if (diff <= 13)
				return 2;
			return 3;
		}

		// Boss key tier: the floor's, but ace from the mission's second-to-last
		// boss on (Bone Serpent and Avatar in the Dark Citadel; single-boss
		// missions never qualify).
		int BossTier()
		{
			auto def = MissionManager::GetCurrentMission();
			auto lvl = CurrentMissionLevel();
			if (def is null || lvl is null)
				return FloorTier();
			int bosses = 0;
			int rank = -1;
			for (uint i = 0; i < def.m_levels.length(); i++)
			{
				if (!IsBossLevel(def.m_levels[i]))
					continue;
				if (def.m_levels[i] is lvl)
					rank = bosses;
				bosses++;
			}
			if (bosses >= 2 && rank >= bosses - 2)
				return 4;
			return FloorTier();
		}

		// ---- key counts on the host -------------------------------------------

		int HostKeyCount(int peer, const string &in key)
		{
			int tier = TierIndex(key);
			if (tier < 1 || peer < 0 || peer >= 256)
				return 0;
			return g_peerKeys[peer * 4 + tier - 1];
		}

		void ResetKeyCounts()
		{
			for (uint i = 0; i < g_peerKeys.length(); i++)
				g_peerKeys[i] = 0;
			for (uint i = 0; i < g_lastSent.length(); i++)
				g_lastSent[i] = -1;
			g_countTimer = 0;
		}

		// Client: report the local key counts to the host when they changed
		// (polled twice a second by the module, forced before a chest use).
		void SendKeyCounts(bool force)
		{
			if (Network::IsServer())
				return;
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
				return;
			bool changed = force;
			array<int> cur(4, 0);
			for (uint t = 0; t < 4; t++)
			{
				cur[t] = rec.GetKeys(TIERS[t]);
				if (cur[t] != g_lastSent[t])
					changed = true;
			}
			if (!changed)
				return;
			SValueBuilder b;
			b.PushDictionary();
			for (uint t = 0; t < 4; t++)
			{
				g_lastSent[t] = cur[t];
				b.PushInteger(TIERS[t], cur[t]);
			}
			b.PopDictionary();
			HWP::Net::Request(COUNT, b.Build());
		}

		void OnCountRequest(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer())
				return;
			for (uint t = 0; t < 4; t++)
			{
				int n = HWP::SV::Int(data, TIERS[t], 0);
				g_peerKeys[int(peer) * 4 + t] = n < 0 ? 0 : n;
			}
		}

		// ---- drops ---------------------------------------------------------------

		bool HasTag(Actor@ actor, const string &in tag)
		{
			return (actor.Tags & ApplyTag(0, g_actorTags.GetTag(tag))) != 0;
		}

		void RequestDrop(vec2 pos, int tier, bool boss = false)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushFloat("x", pos.x);
			b.PushFloat("y", pos.y);
			b.PushInteger("tier", tier);
			b.PushInteger("boss", boss ? 1 : 0);
			b.PopDictionary();
			HWP::Net::Request(DROP, b.Build());
		}

		// Local killer rolls; normal / elite / boss tables. The first boss-tagged
		// kill on a level has a keys.boss_chance (20%) roll for a BossTier() key;
		// later boss-tagged units of the same encounter roll as elites.
		void OnKill(Player@ player, Actor@ killed)
		{
			if (!g_enabled || g_inTown || player is null || killed is null)
				return;
			if (player.m_record is null || !player.m_record.local)
				return;
			if (!killed.m_unit.IsValid())
				return;

			vec2 pos = xy(killed.m_unit.GetPosition());
			bool elite = HasTag(killed, "elite");
			if (HasTag(killed, "boss"))
			{
				int level = CurrentLevel();
				if (g_bossKeyLevel != level)
				{
					g_bossKeyLevel = level;
					if (randf() < clamp(HWP::Settings::GetFloat("keys.boss_chance", 0.2f), 0.0f, 1.0f))
						RequestDrop(pos, BossTier(), true);
					return;
				}
				elite = true;
			}

			// keys.drop_mult scales the base rates below (every chest wants a key)
			float r = randf() / max(g_dropMult, 0.0001f);
			if (elite)
			{
				if (r < 0.03f)
					RequestDrop(pos, 3);
				else if (r < 0.08f)
					RequestDrop(pos, 2);
				else if (r < 0.16f)
					RequestDrop(pos, 1);
				return;
			}
			if (r < 0.001f)
				RequestDrop(pos, 3);
			else if (r < 0.0035f)
				RequestDrop(pos, 2);
			else if (r < 0.0095f)
				RequestDrop(pos, 1);
		}

		// host: a flood guard, not a fairness rule - honest play stays far
		// below DROP_LIMIT requests per DROP_WINDOW even on a boss kill
		bool RateLimited(uint8 peer)
		{
			int now = g_scene.GetTime();
			for (int i = int(g_dropTime.length()) - 1; i >= 0; i--)
			{
				if (now - g_dropTime[i] > DROP_WINDOW)
				{
					g_dropTime.removeAt(i);
					g_dropPeer.removeAt(i);
				}
			}
			int n = 0;
			for (uint i = 0; i < g_dropPeer.length(); i++)
				if (g_dropPeer[i] == int(peer))
					n++;
			if (n >= DROP_LIMIT)
				return true;
			g_dropPeer.insertLast(int(peer));
			g_dropTime.insertLast(now);
			return false;
		}

		void OnDropRequest(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_enabled)
				return;
			int tier = HWP::SV::Int(data, "tier", 0);
			if (!ValidTier(tier))
				return;
			if (RateLimited(peer))
			{
				HWP::Log("keys", "drop request from peer " + peer + " rate limited (" + DROP_LIMIT + " per " + (DROP_WINDOW / 1000) + " s)");
				return;
			}
			// the boss drops are once per level for the whole lobby, whoever
			// landed the killing blow (every killer's machine asks)
			if (HWP::SV::Int(data, "boss", 0) != 0)
			{
				int level = CurrentLevel();
				if (g_hostBossLevel != level)
				{
					g_hostBossLevel = level;
					g_hostBossMask = 0;
				}
				if (g_hostBossMask != 0)
					return;
				g_hostBossMask = 1;
			}
			SpawnKey(vec2(HWP::SV::Float(data, "x"), HWP::SV::Float(data, "y")), tier);
		}

		// Server only. Same pattern as LootDef::Spawn: produce here, tell the
		// clients to produce the same unit (key pickups are not netsynced).
		void SpawnKey(vec2 pos, int tier)
		{
			auto prod = Resources::GetUnitProducer(KEY_UNIT_PREFIX + TIERS[tier - 1] + ".unit");
			if (prod is null)
			{
				HWP::LogError("keys", "missing key unit for tier " + tier);
				return;
			}
			prod.Produce(g_scene, vec3(pos.x, pos.y, 0));
			if (!IsNetsyncedExistance(prod.GetNetSyncMode()))
			{
				SValueBuilder sval;
				sval.PushArray();
				sval.PushInteger(prod.GetResourceHash());
				sval.PushVector2(pos);
				sval.PopArray();
				(Network::Message("SpawnLoot") << sval.Build()).SendToAll();
			}
			HWP::Log("keys", "dropped a " + TIERS[tier - 1] + " key at " + int(pos.x) + "," + int(pos.y));
		}

		// ---- chests --------------------------------------------------------------

		// Runs on every machine (UseUnit broadcast); only the opener's own
		// machine books the stat, like vanilla Chest::Use.
		void OnUnlocked(PlayerBase@ player, int tier)
		{
			if (player is null || player.m_record is null || !player.m_record.local)
				return;
			Stats::Add(HashString("hwp-chest-unlocked-" + TIERS[tier - 1]), 1, player.m_record);
			RefreshHUD();
			HWP::Log("keys", player.m_record.GetName() + " unlocked a " + TIERS[tier - 1] + " chest");
		}

		// Server. Half of the ace chests give every player in the lobby their
		// own (instanced) legendary; the other half an epic piece of equipment
		// from the regular table on top of the chest's own loot.
		void SpawnAceBonus(PlayerBase@ opener, vec3 pos)
		{
			if (randf() >= g_legendaryChance)
			{
				auto table = Item::GetLootTable("hwp_chest_ace_epic");
				if (table !is null)
					table.SpawnLoot(opener, pos);
				return;
			}

			int given = 0;
			for (uint i = 0; i < g_players.length(); i++)
			{
				auto record = g_players[i];
				if (record is null || record.peer == 255)
					continue;
				auto item = Item::Get(LEGENDARIES[randi(LEGENDARIES.length())]);
				if (item is null)
				{
					HWP::LogError("keys", "legendary definitions missing (tweak/hwp/legendaries.sval)");
					return;
				}
				vec3 p = pos + vec3((randf() * 2 - 1) * 12, (randf() * 2 - 1) * 12, 0);
				Item::DropItem(item, p, 1, true, record);
				given++;
			}
			HWP::Log("keys", "ace chest: legendary for " + given + " player(s)");
		}

		// Logged once per gameplay load so dev_check shows whether the loaders
		// picked the loot tables, the legendaries and the units up.
		void SelfCheck()
		{
			if (Item::GetLootTable("hwp_chest_ace") is null || Item::GetLootTable("hwp_chest_ace_epic") is null)
				HWP::LogError("keys", "loot tables missing (tweak/hwp/loot_chests_ace.sval)");
			int legendaries = 0;
			for (uint i = 0; i < LEGENDARIES.length(); i++)
				if (Item::Get(LEGENDARIES[i]) !is null)
					legendaries++;
			if (legendaries != int(LEGENDARIES.length()))
				HWP::LogError("keys", "only " + legendaries + "/" + LEGENDARIES.length() + " legendaries registered (tweak/hwp/legendaries.sval)");
			array<string> units = { LOCK_UNIT, GUARD_UNIT };
			for (uint i = 0; i < TIERS.length(); i++)
				units.insertLast(KEY_UNIT_PREFIX + TIERS[i] + ".unit");
			HWP::CheckUnits("keys", units);
			HWP::Log("keys", "self-check done: " + legendaries + " legendaries");
		}

		// ---- commands ------------------------------------------------------------

		string Counts(PlayerRecord@ rec, const string &in key)
		{
			return Resources::GetString(key, {
				{ "bronze", "" + rec.GetKeys("bronze") }, { "silver", "" + rec.GetKeys("silver") },
				{ "gold", "" + rec.GetKeys("gold") }, { "ace", "" + rec.GetKeys("ace") },
				{ "lock", "" + g_lockChance }, { "acechance", "" + g_aceChance } });
		}

		void CmdKeys(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
				return;
			HWP::Commands::Reply(Counts(rec, ".hwp.keys.status") + "; locked chests this level: " + g_chestsLocked);
		}

		// debug: hwp keygive <tier> [n]  and  hwp keydrop <tier>
		void CmdKeyGive(array<string>@ args)
		{
			if (!g_debug)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.keys.debug_off"));
				return;
			}
			int tier = args.length() > 0 ? TierIndex(args[0]) : 0;
			if (tier == 0)
			{
				HWP::Commands::Reply("usage: hwp keygive bronze|silver|gold|ace [count]");
				return;
			}
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
			{
				HWP::Commands::Reply("no character loaded");
				return;
			}
			int n = args.length() > 1 ? max(1, parseInt(args[1])) : 1;
			rec.AddKeys(TIERS[tier - 1], n);
			RefreshHUD();
			HWP::Commands::Reply("+" + n + " " + TIERS[tier - 1] + " key(s)");
		}

		void CmdKeyDrop(array<string>@ args)
		{
			if (!g_debug)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.keys.debug_off"));
				return;
			}
			int tier = args.length() > 0 ? TierIndex(args[0]) : 1;
			auto rec = GetLocalPlayerRecord();
			if (tier == 0 || rec is null || rec.actor is null)
				return;
			RequestDrop(xy(rec.actor.m_unit.GetPosition()) + vec2(0, 20), tier);
		}
	}
}

class HWPKeysHUD : HUDComponent
{
	TextWidget@ m_text;
	int m_acc = 0;

	HWPKeysHUD(GUIBuilder@ b)
	{
		super(b, "gui/hwp_keys.gui");
		@m_text = cast<TextWidget>(m_widget.GetWidgetById("text"));
		m_visible = false;
	}

	void Refresh(PlayerRecord@ record) override
	{
		if (record is null)
		{
			m_visible = false;
			return;
		}
		int total = record.GetKeys("bronze") + record.GetKeys("silver") + record.GetKeys("gold") + record.GetKeys("ace");
		m_visible = total > 0;
		if (m_visible)
			m_text.SetText(HWP::Keys::Counts(record, ".hwp.keys.hud"));
	}

	void Update(int dt, PlayerRecord@ record) override
	{
		m_acc += dt;
		if (m_acc >= 500)
		{
			m_acc = 0;
			Refresh(record);
		}
		HUDComponent::Update(dt, record);
	}
}

namespace HWPKeys
{
	[Hook]
	void PlayerKilledActor(Player@ player, Actor@ killed, DamageInfo@ di)
	{
		HWP::Keys::OnKill(player, killed);
	}

	[Hook]
	void HUDConstructor(HUD@ hud, GUIBuilder@ b)
	{
		auto comp = HWPKeysHUD(b);
		hud.m_components.insertLast(comp);
		@HWP::Keys::g_hud = comp;
	}
}

namespace Modules
{
	class HWPKeysModule : Module, HWP::ModuleStart
	{
		HWPKeysModule()
		{
			super("hwp-keys");
			// per level, before the scene's chests count themselves (they lock
			// while the level loads, ahead of ModuleStart::Start)
			HWP::Keys::g_chestsLocked = 0;
			HWP::Settings::Sync("keys.");
			HWP::Keys::RefreshSettings();
			HWP::Net::OnRequest(HWP::Keys::DROP, HWP::Net::RequestHandler(HWP::Keys::OnDropRequest));
			HWP::Net::OnRequest(HWP::Keys::COUNT, HWP::Net::RequestHandler(HWP::Keys::OnCountRequest));
			HWP::Commands::Register("keys", " show your keys and the chest lock settings", HWP::Commands::Handler(HWP::Keys::CmdKeys));
			HWP::Commands::Register("keygive", "<tier> [n]  (debug) give yourself keys", HWP::Commands::Handler(HWP::Keys::CmdKeyGive));
			HWP::Commands::Register("keydrop", "<tier>  (debug) drop a key at your feet", HWP::Commands::Handler(HWP::Keys::CmdKeyDrop));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Keys::OnSettingChanged));
		}

		void Start(StartMode sMode)
		{
			HWP::Keys::RefreshSettings();
			HWP::Keys::g_bossKeyLevel = -1;
			HWP::Keys::g_hostBossLevel = -1;
			HWP::Keys::g_hostBossMask = 0;
			HWP::Keys::ResetKeyCounts();
			HWP::Keys::g_dropPeer.removeRange(0, HWP::Keys::g_dropPeer.length());
			HWP::Keys::g_dropTime.removeRange(0, HWP::Keys::g_dropTime.length());
			HWP::Keys::SelfCheck();
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			// clients keep the host's copy of their key counts fresh
			if (!Network::IsServer())
			{
				HWP::Keys::g_countTimer += ms;
				if (HWP::Keys::g_countTimer >= 500)
				{
					HWP::Keys::g_countTimer = 0;
					HWP::Keys::SendKeyCounts(false);
				}
			}
		}
	}
}

// One of the imp's random offers (WorldScript/Imp.as reflects over every
// ImpEffect): a key of the floor's tier. Imp::Use runs on the user's own
// machine, so the key goes straight into the local record; the count reaches
// the host with the next keys.count poll.
class HWPImpKeyEffect : ImpEffect
{
	bool IsAllowed(Player@ plr, float diffLvl)
	{
		return HWP::Keys::g_enabled && !g_inTown && plr !is null && plr.m_record !is null;
	}

	string Apply(Player@ plr, float diffLvl, UnitPtr impUnit)
	{
		int tier = HWP::Keys::FloorTier();
		string key = HWP::Keys::TIERS[tier - 1];
		plr.m_record.AddKeys(key, 1);
		string name = Resources::GetString(".item.key." + key);
		LootLog::PresentPickup(plr.m_record, name, 1);
		HWP::Keys::RefreshHUD();
		HWP::Log("keys", "imp gave a " + key + " key");
		return Resources::GetString(".menu.imp.givemats", { { "mats", name } });
	}
}
