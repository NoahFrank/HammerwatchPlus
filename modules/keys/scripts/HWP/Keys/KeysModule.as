// Keys and ace chests: HoH1-style locked chests (HWPChest.as), key drops from
// enemies, the General Merchant (GeneralMerchant.as), a key counter in the HUD
// and the ace chest's legendary payout.
//
//   keys.drop   client -> host   { x, y, tier }   spawn a key pickup here
//
// Drop rolls happen on the killer's machine (the PlayerKilledActor hook only
// fires for the local Player) and the host spawns the pickup; keys themselves
// are a vanilla PlayerRecord field (GetKeys/AddKeys) that the game saves.
namespace HWP
{
	namespace Keys
	{
		const string DROP = "keys.drop";
		const string LOCK_UNIT = "doodads/hwp/chest_lock.unit";
		const string MERCHANT_UNIT = "actors/npcs/town/hwp_general_merchant.unit";
		const string KEY_UNIT_PREFIX = "items/hwp/keys/key_";
		const array<string> TIERS = { "bronze", "silver", "gold", "ace" };
		const array<string> LEGENDARIES = {
			"hwp_descending_destruction", "hwp_dragons_tail", "hwp_medusas_charm",
			"hwp_sphere_of_heroes", "hwp_spirit_cloak", "hwp_soul_taker", "hwp_wand_of_chaos" };

		// settings (refreshed by the module on Load and on /hwp set)
		bool g_enabled = true;
		bool g_debug = false;
		float g_lockChance = 0.35f;
		float g_aceChance = 0.15f;
		float g_legendaryChance = 0.5f;

		int g_chestsLocked = 0; // this level, for /hwp keys
		HWPKeysHUD@ g_hud;

		// host: recent drop requests for the rate limit
		array<int> g_dropPeer;
		array<int> g_dropTime;

		int TierIndex(const string &in name)
		{
			for (uint i = 0; i < TIERS.length(); i++)
				if (TIERS[i] == name)
					return int(i) + 1;
			return 0;
		}

		int KeyPrice(int tier)
		{
			if (tier == 4)
				return HWP::Settings::GetInt("keys.price_ace", 50000);
			if (tier == 3)
				return HWP::Settings::GetInt("keys.price_gold", 8000);
			if (tier == 2)
				return HWP::Settings::GetInt("keys.price_silver", 2000);
			return HWP::Settings::GetInt("keys.price_bronze", 500);
		}

		// sprites in items/special/base.png (vanilla items/special/keys.unit)
		vec4 KeyIconFrame(int tier)
		{
			if (tier == 4)
				return vec4(112, 16, 16, 16);
			if (tier == 3)
				return vec4(32, 0, 16, 16);
			if (tier == 2)
				return vec4(16, 0, 16, 16);
			return vec4(0, 0, 16, 16);
		}

		vec4 TierColor(int tier)
		{
			if (tier == 4)
				return vec4(1.0f, 0.25f, 0.2f, 1.0f);
			if (tier == 3)
				return vec4(1.0f, 0.85f, 0.25f, 1.0f);
			if (tier == 2)
				return vec4(0.85f, 0.88f, 0.95f, 1.0f);
			return vec4(0.85f, 0.55f, 0.3f, 1.0f);
		}

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("keys.enabled", true);
			g_debug = HWP::Settings::GetBool("keys.debug", false);
			g_lockChance = clamp(HWP::Settings::GetFloat("keys.lock_chance", 0.35f), 0.0f, 1.0f);
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

		// ---- drops ---------------------------------------------------------------

		bool HasTag(Actor@ actor, const string &in tag)
		{
			return (actor.Tags & ApplyTag(0, g_actorTags.GetTag(tag))) != 0;
		}

		void RequestDrop(vec2 pos, int tier)
		{
			SValueBuilder b;
			b.PushDictionary();
			b.PushFloat("x", pos.x);
			b.PushFloat("y", pos.y);
			b.PushInteger("tier", tier);
			b.PopDictionary();
			HWP::Net::Request(DROP, b.Build());
		}

		// Local killer rolls; normal / elite / boss tables. Bosses always drop a
		// gold key and sometimes an ace key on top.
		void OnKill(Player@ player, Actor@ killed)
		{
			if (!g_enabled || g_inTown || player is null || killed is null)
				return;
			if (player.m_record is null || !player.m_record.local)
				return;
			if (!killed.m_unit.IsValid())
				return;

			vec2 pos = xy(killed.m_unit.GetPosition());
			if (HasTag(killed, "boss"))
			{
				RequestDrop(pos, 3);
				if (randf() < HWP::Settings::GetFloat("keys.boss_ace_chance", 0.10f))
					RequestDrop(pos + vec2(12, 0), 4);
				return;
			}

			float r = randf();
			if (HasTag(killed, "elite"))
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

		// host: at most 4 key drops per peer per 10 s; the roll itself is trusted
		bool RateLimited(uint8 peer)
		{
			int now = g_scene.GetTime();
			for (int i = int(g_dropTime.length()) - 1; i >= 0; i--)
			{
				if (now - g_dropTime[i] > 10000)
				{
					g_dropTime.removeAt(i);
					g_dropPeer.removeAt(i);
				}
			}
			int n = 0;
			for (uint i = 0; i < g_dropPeer.length(); i++)
				if (g_dropPeer[i] == int(peer))
					n++;
			if (n >= 4)
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
			if (tier < 1 || tier > 4)
				return;
			if (RateLimited(peer))
			{
				HWP::LogError("keys", "drop request from peer " + peer + " rate limited");
				return;
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

		void OnUnlocked(PlayerBase@ player, int tier)
		{
			if (player is null || player.m_record is null)
				return;
			Stats::Add(HashString("hwp-chest-unlocked-" + TIERS[tier - 1]), 1, player.m_record);
			if (player.m_record.local)
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

		// ---- town ----------------------------------------------------------------

		// Next to the town-square fountain (world -504,144; notice board at
		// -440,110); "/hwp set keys.merchant_x <n>" / merchant_y to move.
		vec3 MerchantPos()
		{
			return vec3(float(HWP::Settings::GetInt("keys.merchant_x", -560)),
				float(HWP::Settings::GetInt("keys.merchant_y", 152)), 0.0f);
		}

		void SpawnMerchant()
		{
			auto prod = Resources::GetUnitProducer(MERCHANT_UNIT);
			if (prod is null)
			{
				HWP::LogError("keys", "missing " + MERCHANT_UNIT);
				return;
			}
			auto pos = MerchantPos();
			prod.Produce(g_scene, pos);
			HWP::Log("keys", "spawned the General Merchant at " + pos.x + "," + pos.y);
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

		// debug: /hwp keygive <tier> [n]  and  /hwp keydrop <tier>
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
				HWP::Commands::Reply("usage: /hwp keygive bronze|silver|gold|ace [count]");
				return;
			}
			int n = args.length() > 1 ? max(1, parseInt(args[1])) : 1;
			auto rec = GetLocalPlayerRecord();
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

	void Refresh(PlayerRecord@ record)
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
	class HWPKeysModule : Module
	{
		bool m_merchantDone = false;
		int m_merchantDelay = 0;

		HWPKeysModule()
		{
			super("hwp-keys");
			HWP::Net::OnRequest(HWP::Keys::DROP, HWP::Net::RequestHandler(HWP::Keys::OnDropRequest));
			HWP::Commands::Register("keys", " show your keys and the chest lock settings", HWP::Commands::Handler(HWP::Keys::CmdKeys));
			HWP::Commands::Register("keygive", "<tier> [n]  (debug) give yourself keys", HWP::Commands::Handler(HWP::Keys::CmdKeyGive));
			HWP::Commands::Register("keydrop", "<tier>  (debug) drop a key at your feet", HWP::Commands::Handler(HWP::Keys::CmdKeyDrop));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Keys::OnSettingChanged));
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::Keys::RefreshSettings();
			HWP::Keys::g_chestsLocked = 0;
			HWP::Keys::g_dropPeer.removeRange(0, HWP::Keys::g_dropPeer.length());
			HWP::Keys::g_dropTime.removeRange(0, HWP::Keys::g_dropTime.length());
			m_merchantDone = false;
			m_merchantDelay = 0;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (m_merchantDone)
				return;
			m_merchantDelay += ms;
			if (m_merchantDelay < 500)
				return;
			m_merchantDone = true;
			if (g_inTown && Network::IsServer() && HWP::Keys::g_enabled)
				HWP::Keys::SpawnMerchant();
		}
	}
}
