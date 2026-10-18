// Pet progression and skills. Every pet (vanilla HoH2, the imported HoH1
// skins, and external pets such as the Gold Collector that register with
// RegisterExternal) earns XP from its owner's kills, from its own pickups and
// from farm crops fed at the feeding bowl in town. Each level past 1 is a
// skill point for a small utility tree; the numbers live in
// tweak/hwp/pet_skills.sval.
//
// Progress is per pet definition and lives in the owner's own PlayerRecord
// (HWP data bag "pets.<petId>.*"), so it never needs the network. Skill
// *effects* that touch shared state (damaging breakables and hazards, stunning
// enemies) are requested from the host (`pets.act`); the host checks the
// requester's reported ranks (`pets.level`), a per-skill cooldown and the
// distance to the target before applying anything. Owner-only effects (Mend,
// Morale) run locally on the owner.
namespace HWP
{
	namespace Pets
	{
		const string BOWL_UNIT = "doodads/hwp/pet_bowl.unit";
		const string SKILLS_SVAL = "tweak/hwp/pet_skills.sval";
		const string BUFFS_SVAL = "tweak/hwp/buffs_pets.sval";
		const string ACT = "pets.act";     // peer -> host: { kind, units [ids] }
		const string LEVEL = "pets.level"; // peer -> host: { lvl, ranks [..], family }

		const int NUM_SKILLS = 7;
		enum Skill { Hazard = 0, Smash, Stun, Mend, Fetch, Morale, Family }
		array<string> SKILL_IDS = { "hazard", "smash", "stun", "mend", "fetch", "morale", "family" };

		// pickup toggles (MiniPetOption bits; Mana is left out: the vanilla enum
		// value 10 overlaps Valuable|HP)
		array<string> OPTION_IDS = { "gold", "valuables", "materials", "health", "caches", "cursed", "elixirs", "xp" };
		array<int> OPTION_BITS = { 1, 2, 4, 8, 32, 64, 128, 256 };
		const int DEFAULT_OPTIONS = 319; // what the base ResetPet passes

		// ---- data -----------------------------------------------------------------

		class SkillDef
		{
			string id;
			int maxRank = 5;
			int radius = 100;
			array<int> cooldown;
			array<int> value;

			int Cooldown(int rank)
			{
				if (rank <= 0 || cooldown.length() == 0)
					return 0;
				return cooldown[uint(min(rank, int(cooldown.length()))) - 1];
			}

			int Value(int rank)
			{
				if (rank <= 0 || value.length() == 0)
					return 0;
				return value[uint(min(rank, int(value.length()))) - 1];
			}
		}

		array<SkillDef@> g_skills;
		int g_xpBase = 100;
		int g_xpPerLevel = 60;
		int g_maxLevel = 20;
		int g_xpKill = 5;
		int g_xpElite = 25;
		int g_xpBoss = 150;
		int g_xpPickup = 2;
		array<string> g_feedIds;
		array<int> g_feedXp;

		bool g_enabled = true;
		bool g_debug = false;
		int g_version = 0; // bumps when anything the menu shows changed
		bool g_loggedWalking = false;
		bool g_loggedFlying = false;

		void ReadIntArray(SValue@ dict, const string &in key, array<int>@ into)
		{
			into.removeRange(0, into.length());
			auto v = HWP::SV::Field(dict, key);
			if (v is null || v.GetType() != SValueType::Array)
				return;
			auto arr = v.GetArray();
			for (uint i = 0; i < arr.length(); i++)
			{
				if (arr[i].GetType() == SValueType::Integer)
					into.insertLast(arr[i].GetInteger());
				else if (arr[i].GetType() == SValueType::Float)
					into.insertLast(int(arr[i].GetFloat()));
			}
		}

		// pet_skills.sval has no <loader>, so its entries are plain resources
		SValue@ Tweak(const string &in key)
		{
			return Resources::GetSValue(HashString(SKILLS_SVAL + ":" + key));
		}

		void LoadDefs()
		{
			g_skills.removeRange(0, g_skills.length());
			for (int s = 0; s < NUM_SKILLS; s++)
			{
				SkillDef def;
				def.id = SKILL_IDS[s];
				auto sv = Tweak(def.id);
				if (sv is null)
					HWP::LogError("pets", "missing " + SKILLS_SVAL + ":" + def.id + ", using defaults");
				def.maxRank = HWP::SV::Int(sv, "max", s == Skill::Family ? 3 : 5);
				def.radius = HWP::SV::Int(sv, "radius", 100);
				ReadIntArray(sv, "cooldown", def.cooldown);
				ReadIntArray(sv, "value", def.value);
				g_skills.insertLast(def);
			}
			auto xp = Tweak("xp");
			g_xpBase = HWP::SV::Int(xp, "base", 100);
			g_xpPerLevel = HWP::SV::Int(xp, "per-level", 60);
			g_maxLevel = clamp(HWP::SV::Int(xp, "max-level", 20), 2, 99);
			g_xpKill = HWP::SV::Int(xp, "kill", 5);
			g_xpElite = HWP::SV::Int(xp, "elite", 25);
			g_xpBoss = HWP::SV::Int(xp, "boss", 150);
			g_xpPickup = HWP::SV::Int(xp, "pickup", 2);

			g_feedIds.removeRange(0, g_feedIds.length());
			g_feedXp.removeRange(0, g_feedXp.length());
			auto feed = Tweak("feed");
			if (feed !is null && feed.GetType() == SValueType::Dictionary)
			{
				auto dict = feed.GetDictionary();
				auto keys = dict.getKeys();
				for (uint i = 0; i < keys.length(); i++)
				{
					g_feedIds.insertLast(keys[i]);
					g_feedXp.insertLast(HWP::SV::Int(feed, keys[i], 30));
				}
			}
		}

		SkillDef@ Def(int skill)
		{
			if (skill < 0 || skill >= int(g_skills.length()))
				return null;
			return g_skills[skill];
		}

		int SkillIndex(const string &in id)
		{
			for (int s = 0; s < NUM_SKILLS; s++)
				if (SKILL_IDS[s] == id)
					return s;
			return -1;
		}

		int FeedXp(const string &in ware)
		{
			for (uint i = 0; i < g_feedIds.length(); i++)
				if (g_feedIds[i] == ware)
					return g_feedXp[i];
			return 0;
		}

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("pets.enabled", true);
			g_debug = HWP::Settings::GetBool("pets.debug", false);
			g_secretChance = HWP::Settings::GetInt("pets.candle_chance", 0);
		}

		bool g_bowlReady = false; // this town level placed its bowl

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("pets.") == 0)
				RefreshSettings();
			// a client got the host's values: the bowl goes where the host has it
			if (key == "pets." && g_inTown && g_bowlReady)
			{
				if (g_enabled)
					SpawnBowl(BowlPos());
				else if (g_bowlUnit.IsValid())
				{
					g_bowlUnit.Destroy();
					g_bowlUnit = UnitPtr();
				}
			}
			if (key.findFirst("petwait.") == 0)
				HWP::PetWait::RefreshSettings();
		}

		vec3 BowlPos()
		{
			return vec3(float(HWP::Settings::GetInt("pets.bowl_x", -600)),
				float(HWP::Settings::GetInt("pets.bowl_y", 980)), 0.0f);
		}

		void LogPetClass(bool flying)
		{
			if (flying && !g_loggedFlying)
			{
				g_loggedFlying = true;
				HWP::Log("pets", "pet class active: HWPMiniPetFlying");
			}
			if (!flying && !g_loggedWalking)
			{
				g_loggedWalking = true;
				HWP::Log("pets", "pet class active: HWPMiniPetWalking");
			}
		}

		// ---- external pets (Gold Collector) ------------------------------------------

		funcdef bool ExternalCheck(PlayerRecord@ rec);

		class External
		{
			string id;
			string name; // lang key or text
			ExternalCheck@ check;
		}
		array<External@> g_externals;

		void RegisterExternal(const string &in id, const string &in name, ExternalCheck@ fn)
		{
			for (uint i = 0; i < g_externals.length(); i++)
				if (g_externals[i].id == id)
					return;
			External e;
			e.id = id;
			e.name = name;
			@e.check = fn;
			g_externals.insertLast(e);
		}

		// The pet definition the record's progress is keyed on ("" = no pet).
		string ActivePetId(PlayerRecord@ rec)
		{
			if (rec is null)
				return "";
			if (rec.pet !is null && rec.pet.m_unit !is null)
				return rec.pet.m_id;
			for (uint i = 0; i < g_externals.length(); i++)
				if (g_externals[i].check(rec))
					return g_externals[i].id;
			return "";
		}

		string PetName(PlayerRecord@ rec)
		{
			if (rec is null)
				return "";
			if (rec.pet !is null && rec.pet.m_unit !is null)
				return Resources::GetString(rec.pet.m_name);
			for (uint i = 0; i < g_externals.length(); i++)
			{
				if (!g_externals[i].check(rec))
					continue;
				string n = g_externals[i].name;
				return n.findFirst(".") == 0 ? Resources::GetString(n) : n;
			}
			return "";
		}

		// Family from the unit path: wyrm (+ wisp, living flame), raven, scarab, imp, cat,
		// dog, squire, candle, other.
		string FamilyOf(UnitPtr unit)
		{
			if (!unit.IsValid())
				return "other";
			auto prod = unit.GetUnitProducer();
			if (prod is null)
				return "other";
			string p = prod.GetResourceName();
			if (p.findFirst("wyrm") >= 0 || p.findFirst("wisp") >= 0 || p.findFirst("living_flame") >= 0) return "wyrm";
			if (p.findFirst("raven") >= 0 || p.findFirst("bird") >= 0) return "raven";
			if (p.findFirst("scarab") >= 0 || p.findFirst("beetle") >= 0) return "scarab";
			if (p.findFirst("imp") >= 0) return "imp";
			if (p.findFirst("cat_") >= 0 || p.findFirst("maltese") >= 0) return "cat";
			if (p.findFirst("dog") >= 0) return "dog";
			if (p.findFirst("candle") >= 0) return "candle";
			if (p.findFirst("squire") >= 0) return "squire";
			if (p.findFirst("gold_collector") >= 0) return "cat";
			return "other";
		}

		// ---- progress (owner's data bag) --------------------------------------------

		string Key(const string &in petId, const string &in what)
		{
			return "pets." + petId + "." + what;
		}

		int Level(PlayerRecord@ rec, const string &in petId)
		{
			if (rec is null || petId.isEmpty())
				return 0;
			return clamp(HWP::SaveData::Player(rec).GetInt(Key(petId, "lvl"), 1), 1, g_maxLevel);
		}

		int Xp(PlayerRecord@ rec, const string &in petId)
		{
			if (rec is null || petId.isEmpty())
				return 0;
			return HWP::SaveData::Player(rec).GetInt(Key(petId, "xp"), 0);
		}

		int XpToNext(int level)
		{
			return g_xpBase + g_xpPerLevel * level;
		}

		int Rank(PlayerRecord@ rec, const string &in petId, int skill)
		{
			if (rec is null || petId.isEmpty() || skill < 0 || skill >= NUM_SKILLS)
				return 0;
			auto def = Def(skill);
			int r = HWP::SaveData::Player(rec).GetInt(Key(petId, SKILL_IDS[skill]), 0);
			return clamp(r, 0, def is null ? 5 : def.maxRank);
		}

		int SpentPoints(PlayerRecord@ rec, const string &in petId)
		{
			int n = 0;
			for (int s = 0; s < NUM_SKILLS; s++)
				n += Rank(rec, petId, s);
			return n;
		}

		int FreePoints(PlayerRecord@ rec, const string &in petId)
		{
			return max(0, Level(rec, petId) - 1 - SpentPoints(rec, petId));
		}

		// Adds XP to the record's active pet; levels up as far as it goes.
		void AddXp(PlayerRecord@ rec, int amount, const string &in reason)
		{
			if (rec is null || !rec.local || amount <= 0 || !g_enabled)
				return;
			string petId = ActivePetId(rec);
			if (petId.isEmpty())
				return;
			auto bag = HWP::SaveData::Player(rec);
			int lvl = Level(rec, petId);
			if (lvl >= g_maxLevel)
				return;
			int xp = Xp(rec, petId) + amount;
			bool leveled = false;
			while (lvl < g_maxLevel && xp >= XpToNext(lvl))
			{
				xp -= XpToNext(lvl);
				lvl++;
				leveled = true;
			}
			if (lvl >= g_maxLevel)
				xp = 0;
			bag.SetInt(Key(petId, "xp"), xp);
			bag.SetInt(Key(petId, "lvl"), lvl);
			g_version++;
			if (g_debug)
				HWP::Log("pets", petId + " +" + amount + " xp (" + reason + "): level " + lvl + ", " + xp + "/" + XpToNext(lvl));
			if (leveled)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.pets.levelup", { { "name", PetName(rec) }, { "lvl", lvl } }));
				SendLevel(rec);
			}
		}

		bool SpendPoint(PlayerRecord@ rec, int skill)
		{
			string petId = ActivePetId(rec);
			auto def = Def(skill);
			if (rec is null || petId.isEmpty() || def is null)
				return false;
			if (FreePoints(rec, petId) <= 0)
				return false;
			int r = Rank(rec, petId, skill);
			if (r >= def.maxRank)
				return false;
			HWP::SaveData::Player(rec).SetInt(Key(petId, def.id), r + 1);
			g_version++;
			SendLevel(rec);
			// passives (Fetch) only apply on (re)spawn
			if (skill == Skill::Fetch)
			{
				auto pb = cast<PlayerBase>(rec.actor);
				if (pb !is null && rec.pet !is null)
					pb.ResetPet();
			}
			return true;
		}

		bool Feed(PlayerRecord@ rec, const string &in ware)
		{
			int xp = FeedXp(ware);
			if (rec is null || xp <= 0 || ActivePetId(rec).isEmpty())
				return false;
			if (HWP::Market::Count(rec, ware) <= 0)
				return false;
			if (Level(rec, ActivePetId(rec)) >= g_maxLevel)
				return false;
			HWP::Market::Take(rec, ware, 1);
			AddXp(rec, xp, "fed " + ware);
			g_version++;
			return true;
		}

		// ---- pickup toggles -----------------------------------------------------------

		const string KEY_OPTIONS_SET = "pets.options_set"; // the player changed a toggle

		// Vanilla never assigns PlayerRecord.petOptions (it saves 0 = None and
		// always passes 319 itself), so the field only means something once HWP
		// wrote it: until then (and for other players' records, whose bags are
		// not synced) it is vanilla's 319.
		int Options(PlayerRecord@ rec)
		{
			if (rec is null)
				return DEFAULT_OPTIONS;
			int o = int(rec.petOptions);
			if (o < 0 || (o == 0 && !HWP::SaveData::Player(rec).GetBool(KEY_OPTIONS_SET, false)))
				o = DEFAULT_OPTIONS;
			return o;
		}

		bool HasOption(PlayerRecord@ rec, int bit)
		{
			return (Options(rec) & bit) != 0;
		}

		void SetOption(PlayerRecord@ rec, int bit, bool on)
		{
			if (rec is null)
				return;
			int o = Options(rec);
			o = on ? (o | bit) : (o & ~bit);
			rec.petOptions = MiniPetOption(o);
			HWP::SaveData::Player(rec).SetBool(KEY_OPTIONS_SET, true);
			g_version++;
			auto pb = cast<PlayerBase>(rec.actor);
			if (pb !is null && rec.pet !is null)
				pb.ResetPet(); // re-runs Initialize with the new options
		}

		// What the HWP pet classes pass to the base Initialize.
		MiniPetOption OptionsFor(PlayerBase@ owner, MiniPetOption fallback)
		{
			if (owner is null || owner.m_record is null)
				return fallback;
			return MiniPetOption(Options(owner.m_record));
		}

		// Fetch (and the squire's Pack Mule) change the pet's base ranges.
		void ApplyPassives(MiniPet@ pet, PlayerBase@ owner, const string &in petId, const string &in family)
		{
			if (pet is null || owner is null || owner.m_record is null)
				return;
			int rank = Rank(owner.m_record, petId, Skill::Fetch);
			auto def = Def(Skill::Fetch);
			if (rank <= 0 || def is null)
				return;
			int v = def.Value(rank);
			if (family == "squire")
				v += Rank(owner.m_record, petId, Skill::Family) * 40;
			pet.m_pickupRange += v;
			pet.m_pickupLeashRange += v;
			pet.m_grabRadius += v / 4;
			pet.m_speed *= 1.0f + float(v) / 1000.0f;
		}

		// ---- XP sources -----------------------------------------------------------------

		bool HasTag(Actor@ actor, const string &in tag)
		{
			if (actor is null)
				return false;
			return (actor.Tags & ApplyTag(0, g_actorTags.GetTag(tag))) != 0;
		}

		void OnPickupEvent(SValue@ data)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec !is null && rec.local)
				OnPetPickup(rec, HWP::SV::Str(data, "pet"), MiniPetOption(HWP::SV::Int(data, "kind", 0)), HWP::SV::Str(data, "family"));
		}

		void OnOwnerKill(PlayerRecord@ rec, Actor@ killed)
		{
			if (rec is null || !rec.local || killed is null)
				return;
			int xp = g_xpKill;
			if (HasTag(killed, "boss"))
				xp = g_xpBoss;
			else if (HasTag(killed, "elite") || HasTag(killed, "miniboss"))
				xp = g_xpElite;
			AddXp(rec, xp, "kill");
		}

		const string PICKUP = "pets.pickup"; // host -> owner: { pet, kind, family }

		void OnPetPickup(PlayerRecord@ rec, const string &in petId, MiniPetOption kind, const string &in family)
		{
			if (rec is null)
				return;
			if (!rec.local)
			{
				// a pickup the host ran for a client's pet (the Gold Collector):
				// the owner's machine credits it
				if (!Network::IsServer())
					return;
				SValueBuilder b;
				b.PushDictionary();
				b.PushString("pet", petId);
				b.PushInteger("kind", int(kind));
				b.PushString("family", family);
				b.PopDictionary();
				HWP::Net::Send(rec.peer, PICKUP, b.Build());
				return;
			}
			AddXp(rec, g_xpPickup, "pickup");
			// Hoarder (scarab family): a little extra gold on every gold pickup
			if (family == "scarab" && kind == MiniPetOption::Gold)
			{
				int fr = Rank(rec, petId, Skill::Family);
				if (fr > 0)
					rec.GiveMaterial(MaterialType::Gold, 2 * fr, true);
			}
		}

		// ---- network: ranks and host-side effects --------------------------------------

		array<int> g_hostRanks(256 * NUM_SKILLS, 0);
		array<string> g_hostFamily(256, "");
		array<uint> g_hostLast(256 * NUM_SKILLS, 0);

		void ResetHost()
		{
			for (uint i = 0; i < g_hostRanks.length(); i++)
			{
				g_hostRanks[i] = 0;
				g_hostLast[i] = 0;
			}
			for (uint i = 0; i < g_hostFamily.length(); i++)
				g_hostFamily[i] = "";
		}

		void SendLevel(PlayerRecord@ rec)
		{
			if (rec is null || !rec.local)
				return;
			string petId = ActivePetId(rec);
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("lvl", Level(rec, petId));
			b.PushArray("ranks");
			for (int s = 0; s < NUM_SKILLS; s++)
				b.PushInteger(Rank(rec, petId, s));
			b.PopArray();
			auto pb = cast<PlayerBase>(rec.actor);
			string family = "other";
			if (pb !is null && pb.m_pet !is null)
				family = FamilyOf(pb.m_pet.m_unit);
			b.PushString("family", family);
			b.PopDictionary();
			HWP::Net::Request(LEVEL, b.Build());
		}

		void OnLevel(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer())
				return;
			array<int> ranks;
			ReadIntArray(data, "ranks", ranks);
			for (int s = 0; s < NUM_SKILLS; s++)
			{
				auto def = Def(s);
				int r = s < int(ranks.length()) ? ranks[s] : 0;
				g_hostRanks[int(peer) * NUM_SKILLS + s] = clamp(r, 0, def is null ? 5 : def.maxRank);
			}
			g_hostFamily[peer] = HWP::SV::Str(data, "family", "other");
		}

		bool IsHazard(UnitPtr u)
		{
			if (!u.IsValid())
				return false;
			auto prod = u.GetUnitProducer();
			if (prod is null)
				return false;
			string p = prod.GetResourceName();
			return p.findFirst("plants/vine") >= 0 || p.findFirst("/vine_") >= 0;
		}

		void RequestAct(int kind, array<uint>@ units)
		{
			if (units.length() == 0)
				return;
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("kind", kind);
			b.PushArray("units");
			for (uint i = 0; i < units.length() && i < 4; i++)
				b.PushInteger(int(units[i]));
			b.PopArray();
			b.PopDictionary();
			HWP::Net::Request(ACT, b.Build());
		}

		// Host: apply a requested skill effect after checking rank, cooldown and range.
		void OnAct(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer() || !g_enabled)
				return;
			auto rec = GetPlayerRecordByPeer(peer);
			if (rec is null || rec.actor is null)
				return;
			int kind = HWP::SV::Int(data, "kind", -1);
			auto def = Def(kind);
			if (def is null)
				return;
			int rank = g_hostRanks[int(peer) * NUM_SKILLS + kind];
			string family = g_hostFamily[peer];
			if (kind == Skill::Family)
				rank = (family == "wyrm") ? rank : 0; // the only family effect that reaches the host directly
			if (rank <= 0)
				return;
			uint now = g_scene.GetTime();
			uint idx = uint(peer) * NUM_SKILLS + kind;
			uint cd = uint(def.Cooldown(rank) * 3 / 4);
			if (g_hostLast[idx] != 0 && now - g_hostLast[idx] < cd)
				return;
			g_hostLast[idx] = now;

			Actor@ attacker = cast<Actor>(rec.actor);
			vec3 origin = rec.actor.m_unit.GetPosition();
			array<int> ids;
			ReadIntArray(data, "units", ids);
			int applied = 0;
			for (uint i = 0; i < ids.length() && i < 4; i++)
			{
				UnitPtr u = g_scene.GetUnit(uint(ids[i]));
				if (!u.IsValid() || u.IsDestroyed())
					continue;
				vec3 pos = u.GetPosition();
				if (distsq(pos, origin) > 500.0f * 500.0f)
					continue;
				if (kind == Skill::Hazard || kind == Skill::Family)
				{
					auto actor = cast<Actor>(u.GetScriptBehavior());
					if (actor is null || actor.IsDead() || !IsHazard(u))
						continue;
					DamageInfo di(attacker);
					int v = def.Value(rank);
					if (kind == Skill::Family)
					{
						di.FireDamage = v * 15;
						di.Damage = v * 15;
					}
					else
					{
						di.PureDamage = v;
						di.Damage = v;
					}
					actor.Damage(di, xy(pos), vec2(0, 1));
					applied++;
				}
				else if (kind == Skill::Smash)
				{
					auto brk = cast<Breakable>(u.GetScriptBehavior());
					if (brk is null)
						continue;
					DamageInfo di(attacker);
					di.PhysicalDamage = 60;
					di.Damage = 60;
					brk.Damage(di, xy(pos), vec2(0, 1));
					applied++;
				}
				else if (kind == Skill::Stun)
				{
					auto actor = cast<Actor>(u.GetScriptBehavior());
					if (actor is null || actor.IsDead() || actor.Team == attacker.Team || IsHazard(u))
						continue;
					if (HasTag(actor, "boss") || HasTag(actor, "elite") || HasTag(actor, "miniboss"))
						continue;
					int tier = def.Value(rank);
					string buffName = tier >= 3 ? "stun_greater" : (tier == 2 ? "stun" : "stun_minor");
					auto buff = LoadActorBuff("tweak/buffs/status_effects.sval:" + buffName);
					if (buff is null)
						continue;
					actor.ApplyBuff(ActorBuff(actor, buff, 1.0f, false));
					// Fire Bolt (imp family): burn the stunned target
					if (family == "imp")
					{
						int fr = g_hostRanks[int(peer) * NUM_SKILLS + Skill::Family];
						if (fr > 0)
						{
							DamageInfo di(attacker);
							di.FireDamage = 25 * fr;
							di.Damage = 25 * fr;
							actor.Damage(di, xy(pos), vec2(0, 1));
						}
					}
					applied++;
					break; // one target per stun
				}
			}
			if (g_debug && applied > 0)
				HWP::Log("pets", "peer " + peer + " " + def.id + " rank " + rank + ": " + applied + " target(s)");
		}

		// ---- Secret Sense (candle family) -------------------------------------------------

		const array<int> SECRET_CHANCE = { 3, 6, 10 }; // % per entrance by Family rank
		const float SECRET_RADIUS = 220.0f;  // owner distance at which the candle goes over
		const float SECRET_GROUP = 64.0f;    // wall tiles this close are one entrance

		// this floor's entrances (anchor = first tile seen) and their rolls; Start() clears
		array<vec2> g_secretSpots;
		array<bool> g_secretLit;
		int g_secretChance = 0; // setting pets.candle_chance: forces the % (testing), 0 = by rank

		void ResetSecrets()
		{
			g_secretSpots.resize(0);
			g_secretLit.resize(0);
		}

		bool IsSecretWall(UnitPtr u)
		{
			if (!u.IsValid() || u.IsDestroyed())
				return false;
			auto prod = u.GetUnitProducer();
			if (prod is null)
				return false;
			string p = prod.GetResourceName();
			return p.findFirst("_secret_dst_") >= 0 && p.findFirst("_corpse") < 0;
		}

		int SecretSpot(vec2 pos, int rank)
		{
			for (uint i = 0; i < g_secretSpots.length(); i++)
				if (distsq(g_secretSpots[i], pos) <= SECRET_GROUP * SECRET_GROUP)
					return int(i);
			int chance = g_secretChance > 0 ? g_secretChance : SECRET_CHANCE[clamp(rank, 1, 3) - 1];
			bool lit = randi(100) < chance;
			g_secretSpots.insertLast(pos);
			g_secretLit.insertLast(lit);
			if (g_debug)
				HWP::Log("pets", "secret entrance at " + int(pos.x) + "," + int(pos.y) + ": " + (lit ? "lit" : "not lit") + " (" + chance + "%)");
			return int(g_secretSpots.length()) - 1;
		}

		// the hover spot by the nearest intact tile of a lit entrance near the owner
		bool FindLitSecret(vec2 ownerPos, int rank, vec2 &out hover)
		{
			auto walls = g_scene.FetchUnitsWithBehavior("Breakable", ownerPos, int(SECRET_RADIUS));
			float best = -1;
			for (uint i = 0; i < walls.length(); i++)
			{
				if (!IsSecretWall(walls[i]))
					continue;
				vec2 tile = xy(walls[i].GetPosition()) + vec2(8, 8);
				int spot = SecretSpot(tile, rank);
				if (!g_secretLit[spot])
					continue;
				float d = distsq(tile, ownerPos);
				if (best >= 0 && d >= best)
					continue;
				best = d;
				vec2 away = ownerPos - tile;
				float len = length(away);
				hover = tile + (len > 1.0f ? away / len : vec2(0, 1)) * 22.0f;
			}
			return best >= 0;
		}

		// ---- the owner-side skill runner ------------------------------------------------

		class SkillRunner
		{
			array<int> m_timers(NUM_SKILLS, 0);
			string m_family = "other";
			// Secret Sense (candle family): the pet classes park the pet at m_secretPos
			// while m_secretHold (PetWait::Watcher.m_hold)
			EffectBehavior@ m_glow;
			bool m_secretHold = false;
			vec2 m_secretPos;
			int m_secretTimer = 0;

			void Update(int dt, PlayerBase@ owner, vec3 petPos, const string &in petId)
			{
				if (!g_enabled || g_inTown || owner is null || owner.IsHusk())
					return;
				auto rec = owner.m_record;
				if (rec is null || !rec.local || rec.IsDead() || petId.isEmpty())
					return;
				for (int s = 0; s < NUM_SKILLS; s++)
				{
					auto def = Def(s);
					if (def is null)
						continue;
					int rank = Rank(rec, petId, s);
					if (rank <= 0 || def.Cooldown(rank) <= 0)
						continue;
					m_timers[s] -= dt;
					if (m_timers[s] > 0)
						continue;
					bool fired = Fire(s, rank, def, owner, petPos, petId);
					m_timers[s] = fired ? def.Cooldown(rank) : 400;
				}
			}

			// Secret Sense (candle family): every secret entrance (breakable
			// _secret_dst_ wall tiles, grouped) gets one roll per floor, 3/6/10% by
			// Family rank; while the owner is near an entrance that won, the candle
			// hovers between them and the wall and flickers. Local owner only (other
			// players' ranks are not known here), not in town.
			void UpdateSecrets(int dt, PlayerBase@ owner, vec3 petPos, const string &in petId)
			{
				if (m_family != "candle")
					return;
				m_secretTimer -= dt;
				if (m_secretTimer <= 0)
				{
					m_secretTimer = 400;
					int rank = 0;
					if (g_enabled && !g_inTown && owner !is null && !owner.IsHusk() && owner.m_record !is null
						&& owner.m_record.local && !owner.m_record.IsDead() && !petId.isEmpty())
						rank = Rank(owner.m_record, petId, Skill::Family);
					bool was = m_secretHold;
					m_secretHold = rank > 0 && FindLitSecret(xy(owner.m_unit.GetPosition()), rank, m_secretPos);
					if (g_debug && was != m_secretHold)
						HWP::Log("pets", m_secretHold ? "candle: hovering by a secret entrance at " + int(m_secretPos.x) + "," + int(m_secretPos.y) : "candle: back to following");
				}
				if (m_glow !is null && m_glow.m_unit.IsDestroyed())
					@m_glow = null;
				if (!m_secretHold)
				{
					if (m_glow !is null)
						m_glow.Stop();
					@m_glow = null;
					return;
				}
				if (m_glow is null)
				{
					auto fx = Resources::GetEffect("effects/hwp/pet_secret.effect");
					if (fx is null || owner.m_pet is null || !owner.m_pet.m_unit.IsValid())
						return;
					UnitPtr u = g_effectUnit.Produce(g_scene, petPos);
					@m_glow = cast<EffectBehavior>(u.GetScriptBehavior());
					if (m_glow is null)
						return;
					m_glow.Initialize(fx);
					AttachedEffect aFx;
					@aFx.effect = m_glow;
					aFx.unit = owner.m_pet.m_unit;
					::m_attachedEffects.insertLast(aFx); // the game mode moves it with the pet
				}
				// a short ttl the pet keeps topping up: it goes out by itself with the pet
				if (m_glow.m_ttl < 300)
					m_glow.m_ttl = 700;
			}

			bool Fire(int skill, int rank, SkillDef@ def, PlayerBase@ owner, vec3 petPos, const string &in petId)
			{
				auto rec = owner.m_record;
				vec2 ownerPos = xy(owner.m_unit.GetPosition());
				switch (skill)
				{
					case Skill::Hazard:
					{
						array<uint> ids;
						auto units = g_scene.FetchActorsWithOtherTeam(owner.Team, xy(petPos), def.radius);
						for (uint i = 0; i < units.length() && ids.length() < 3; i++)
						{
							auto a = cast<Actor>(units[i].GetScriptBehavior());
							if (a is null || a.IsDead() || !IsHazard(units[i]))
								continue;
							ids.insertLast(units[i].GetId());
						}
						if (ids.length() == 0)
							return false;
						RequestAct(Skill::Hazard, ids);
						return true;
					}
					case Skill::Smash:
					{
						array<uint> ids;
						uint want = uint(max(1, def.Value(rank)));
						auto units = g_scene.FetchUnitsWithBehavior("Breakable", xy(petPos), def.radius);
						for (uint i = 0; i < units.length() && ids.length() < want; i++)
						{
							if (!units[i].IsValid() || units[i].IsDestroyed())
								continue;
							if (cast<Breakable>(units[i].GetScriptBehavior()) is null)
								continue;
							ids.insertLast(units[i].GetId());
						}
						if (ids.length() == 0)
							return false;
						RequestAct(Skill::Smash, ids);
						return true;
					}
					case Skill::Stun:
					{
						UnitPtr best;
						float bestD = float(def.radius) * float(def.radius);
						auto units = g_scene.FetchActorsWithOtherTeam(owner.Team, ownerPos, def.radius);
						for (uint i = 0; i < units.length(); i++)
						{
							auto a = cast<CompositeActorBehavior>(units[i].GetScriptBehavior());
							if (a is null || a.IsDead() || IsHazard(units[i]))
								continue;
							if (HasTag(a, "boss") || HasTag(a, "elite") || HasTag(a, "miniboss"))
								continue;
							float d = distsq(xy(units[i].GetPosition()), ownerPos);
							if (d < bestD)
							{
								bestD = d;
								best = units[i];
							}
						}
						if (!best.IsValid())
							return false;
						array<uint> ids = { best.GetId() };
						RequestAct(Skill::Stun, ids);
						return true;
					}
					case Skill::Mend:
					{
						if (rec.hp >= 0.8f)
							return false;
						float pct = float(def.Value(rank));
						if (m_family == "cat")
							pct *= 1.0f + 0.25f * Rank(rec, petId, Skill::Family);
						int amount = max(1, int(float(owner.GetMaxHp()) * pct / 100.0f));
						owner.Heal(amount, false);
						return true;
					}
					case Skill::Morale:
					{
						auto units = g_scene.FetchActorsWithOtherTeam(owner.Team, ownerPos, def.radius);
						for (uint i = 0; i < units.length(); i++)
						{
							auto a = cast<CompositeActorBehavior>(units[i].GetScriptBehavior());
							if (a !is null && !a.IsDead() && !IsHazard(units[i]))
								return false; // in combat
						}
						int r = def.Value(rank);
						string name = "hwp_morale_" + clamp(r, 1, 5);
						if (m_family == "dog" && Rank(rec, petId, Skill::Family) >= 2 && r >= 4)
							name = "hwp_morale_loyal";
						auto buff = LoadActorBuff(BUFFS_SVAL + ":" + name);
						if (buff is null)
							return true;
						owner.ApplyBuff(ActorBuff(owner, buff, 1.0f, false));
						return true;
					}
					case Skill::Family:
					{
						if (m_family == "wyrm")
						{
							array<uint> ids;
							auto units = g_scene.FetchActorsWithOtherTeam(owner.Team, xy(petPos), 220);
							for (uint i = 0; i < units.length() && ids.length() < 4; i++)
							{
								auto a = cast<Actor>(units[i].GetScriptBehavior());
								if (a is null || a.IsDead() || !IsHazard(units[i]))
									continue;
								ids.insertLast(units[i].GetId());
							}
							if (ids.length() == 0)
								return false;
							RequestAct(Skill::Family, ids);
							return true;
						}
						if (m_family == "raven")
						{
							auto chests = g_scene.FetchUnitsWithBehavior("Chest", ownerPos, def.radius);
							int n = 0;
							for (uint i = 0; i < chests.length(); i++)
								if (chests[i].IsValid() && !chests[i].IsDestroyed())
									n++;
							if (n > 0)
								HWP::Commands::Reply(Resources::GetString(".hwp.pets.scout", { { "n", n } }));
							return true;
						}
						return true; // passive families: nothing to tick
					}
				}
				return true;
			}
		}

		// ---- commands --------------------------------------------------------------------

		UnitPtr g_bowlUnit;

		void SpawnBowl(vec3 pos)
		{
			if (g_bowlUnit.IsValid())
				g_bowlUnit.Destroy();
			g_bowlUnit = UnitPtr();
			auto prod = Resources::GetUnitProducer(BOWL_UNIT);
			if (prod is null)
			{
				HWP::LogError("pets", "missing " + BOWL_UNIT);
				return;
			}
			g_bowlUnit = prod.Produce(g_scene, pos);
			HWP::Log("pets", "spawned the feeding bowl at " + int(pos.x) + "," + int(pos.y));
		}

		string Status(PlayerRecord@ rec)
		{
			string petId = ActivePetId(rec);
			if (petId.isEmpty())
				return Resources::GetString(".hwp.pets.none");
			int lvl = Level(rec, petId);
			string s = Resources::GetString(".hwp.pets.status", {
				{ "name", PetName(rec) }, { "lvl", lvl }, { "xp", Xp(rec, petId) },
				{ "next", lvl >= g_maxLevel ? 0 : XpToNext(lvl) }, { "points", FreePoints(rec, petId) } });
			string ranks = "";
			for (int i = 0; i < NUM_SKILLS; i++)
			{
				int r = Rank(rec, petId, i);
				if (r <= 0)
					continue;
				if (!ranks.isEmpty())
					ranks += ", ";
				ranks += Resources::GetString(".hwp.pets.skill." + SKILL_IDS[i] + ".name") + " " + r;
			}
			if (!ranks.isEmpty())
				s += " " + ranks;
			return s;
		}

		void CmdPet(array<string>@ args)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null)
				return;
			if (args.length() == 0)
			{
				HWP::Commands::Reply(Status(rec));
				HWP::Commands::Reply(Resources::GetString(".hwp.pets.cmd_hint"));
				return;
			}
			string a = args[0];
			if (a == "here")
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.pets.host_only"));
					return;
				}
				if (rec.actor is null)
					return;
				auto p = rec.actor.m_unit.GetPosition();
				HWP::Settings::SetInt("pets.bowl_x", int(p.x));
				HWP::Settings::SetInt("pets.bowl_y", int(p.y));
				HWP::Commands::NotifySettingChanged("pets.bowl_x");
				HWP::Commands::NotifySettingChanged("pets.bowl_y");
				if (g_inTown)
					SpawnBowl(vec3(float(int(p.x)), float(int(p.y)), 0.0f));
				HWP::Commands::Reply(Resources::GetString(".hwp.pets.moved"));
				return;
			}
			if (a == "skill" && args.length() >= 2)
			{
				int s = SkillIndex(args[1]);
				if (s < 0)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.pets.unknown_skill"));
					return;
				}
				HWP::Commands::Reply(SpendPoint(rec, s) ? Status(rec) : Resources::GetString(".hwp.pets.no_points"));
				return;
			}
			if (a == "feed" && args.length() >= 2)
			{
				HWP::Commands::Reply(Feed(rec, args[1]) ? Status(rec) : Resources::GetString(".hwp.pets.cannot_feed"));
				return;
			}
			if (a == "use" && args.length() >= 2 && g_debug)
			{
				// debug: put on any pet (unlocked for free)
				auto def = PetDef::Get(HashString(args[1]));
				if (def is null)
				{
					HWP::Commands::Reply("no pet " + args[1]);
					return;
				}
				if (!rec.HasPetUnlocked(def))
					rec.UnlockPet(def);
				@rec.pet = def;
				auto pb = cast<PlayerBase>(rec.actor);
				if (pb !is null)
					pb.ResetPet();
				HWP::Commands::Reply("pet: " + def.m_id);
				return;
			}
			if (a == "secret" && g_debug)
			{
				// debug: a trip to the nearest secret entrance tile on the floor
				auto pb = cast<PlayerBase>(rec.actor);
				if (pb is null)
					return;
				vec2 at = xy(pb.m_unit.GetPosition());
				auto walls = g_scene.FetchUnitsWithBehavior("Breakable", at, 20000);
				int n = 0;
				float best = -1;
				vec2 tile;
				for (uint i = 0; i < walls.length(); i++)
				{
					if (!IsSecretWall(walls[i]))
						continue;
					n++;
					vec2 t = xy(walls[i].GetPosition()) + vec2(8, 8);
					if (best < 0 || distsq(t, at) < best)
					{
						best = distsq(t, at);
						tile = t;
					}
				}
				if (best < 0)
				{
					HWP::Commands::Reply("pet secret: no secret wall tiles on this floor");
					return;
				}
				vec2 to = tile + vec2(0, args.length() >= 2 ? parseInt(args[1]) : 48);
				pb.m_unit.SetPosition(to.x, to.y, 0, true);
				HWP::Commands::Reply("pet secret: " + n + " tile(s); moved to " + int(to.x) + "," + int(to.y) + " by the tile at " + int(tile.x) + "," + int(tile.y));
				return;
			}
			if (a == "dye" && g_debug)
			{
				// debug: 'dye' shows the dyes and the pet's unit, 'dye <0|1> <dye id|none>' sets one for free
				string petId = HWP::PetDye::DyeablePetId(rec);
				if (args.length() >= 3)
				{
					string dye = args[2] == "none" ? "" : args[2];
					if (!dye.isEmpty() && HWP::PetDye::Get(dye) is null)
					{
						HWP::Commands::Reply("no dye " + dye);
						return;
					}
					HWP::PetDye::SetDyeId(rec, petId, dye, parseInt(args[1]));
					HWP::PetDye::RemakePet(rec);
					HWP::PetDye::Send(rec);
				}
				auto pb = cast<PlayerBase>(rec.actor);
				string unit = (pb !is null && pb.m_pet !is null && pb.m_pet.m_unit.IsValid()) ? pb.m_pet.m_unit.GetUnitProducer().GetResourceName() : "-";
				bool ours = pb !is null && (cast<HWPMiniPetWalking>(pb.m_pet) !is null || cast<HWPMiniPetFlying>(pb.m_pet) !is null);
				string at = "";
				if (pb !is null && pb.m_pet !is null && pb.m_pet.m_unit.IsValid())
				{
					vec3 d = pb.m_pet.m_unit.GetPosition() - pb.m_unit.GetPosition();
					at = " | at " + int(d.x) + "," + int(d.y);
				}
				HWP::Commands::Reply(HWP::PetDye::Current(rec) + " | unit " + unit + (ours ? " | HWP class" : " | base class") + at);
				return;
			}
			if (a == "xp" && args.length() >= 2 && g_debug)
			{
				AddXp(rec, parseInt(args[1]), "debug");
				HWP::Commands::Reply(Status(rec));
				return;
			}
			for (uint i = 0; i < OPTION_IDS.length(); i++)
			{
				if (OPTION_IDS[i] != a)
					continue;
				if (args.length() >= 2)
					SetOption(rec, OPTION_BITS[i], args[1] == "on" || args[1] == "1" || args[1] == "true");
				HWP::Commands::Reply(Resources::GetString(".hwp.pets.option", {
					{ "name", Resources::GetString(".hwp.pets.opt." + a) },
					{ "state", Resources::GetString(HasOption(rec, OPTION_BITS[i]) ? ".hwp.pets.on" : ".hwp.pets.off") } }));
				return;
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.pets.cmd_hint"));
		}

		// Boot-time checks: units now, PetDefs (loaded after modules) on the first gameplay load.
		bool g_checkedDefs = false;

		void SelfCheck(bool defs)
		{
			if (!defs)
			{
				HWP::CheckUnits("pets", { BOWL_UNIT });
				if (g_skills.length() == NUM_SKILLS)
					HWP::Log("pets", "self-check done: " + NUM_SKILLS + " skills, " + g_feedIds.length() + " foods");
				return;
			}
			if (g_checkedDefs)
				return;
			g_checkedDefs = true;
			int imported = 0;
			int missingUnit = 0;
			for (uint i = 0; i < PetDef::Instances.length(); i++)
			{
				auto d = PetDef::Instances[i];
				if (d.m_id.findFirst("hwp_pet_") != 0)
					continue;
				imported++;
				if (d.m_unit is null)
					missingUnit++;
			}
			if (imported == 0)
				HWP::Log("pets", "no HoH1 pets imported (run: python tools/import_hoh1.py pets)");
			else
				HWP::Log("pets", imported + " HoH1 pet(s) in the Pet Shop" + (missingUnit > 0 ? ", " + missingUnit + " with a missing unit" : ""));
		}
	}
}

// Hook: pet XP for the owner's kills (Player = the local player on every machine).
namespace HWPPets
{
	[Hook]
	void PlayerKilledActor(Player@ player, Actor@ killed, DamageInfo@ di)
	{
		if (player is null || player.m_record is null)
			return;
		HWP::Pets::OnOwnerKill(player.m_record, killed);
	}
}

// ---- the feeding bowl ---------------------------------------------------------------

class HWPPetBowl : AShopContent
{
	HWPPetBowl() {}
	HWPPetBowl(UnitPtr u, SValue& params) { super(u, params); }

	bool CanInteract(PlayerRecord@ player) override { return HWP::Pets::g_enabled; }

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPPetMenu(guiBuilder, this);
		return m_window;
	}

	string GetName() override { return "hwp_pet_bowl"; }

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class HWPPetMenu : AWindowObject
{
	HWPPetBowl@ m_bowl;
	int m_seenVersion = -1;
	string m_message;

	TextWidget@ m_state;
	TextWidget@ m_xp;
	TextWidget@ m_messageText;
	TextWidget@ m_points;
	Widget@ m_list;
	Widget@ m_rowTemplate;
	TextWidget@ m_headerTemplate;
	TextWidget@ m_lineTemplate;

	array<Widget@> m_rows;
	array<string> m_rowActions; // "skill:<i>", "feed:<ware>", "opt:<i>"

	HWPPetMenu(GUIBuilder@ b, HWPPetBowl@ bowl)
	{
		super(b, "gui/hwp_pets.gui");
		PauseGame(true, true);
		@m_bowl = bowl;

		@m_state = cast<TextWidget>(m_widget.GetWidgetById("state"));
		@m_xp = cast<TextWidget>(m_widget.GetWidgetById("xp"));
		@m_messageText = cast<TextWidget>(m_widget.GetWidgetById("message"));
		@m_points = cast<TextWidget>(m_widget.GetWidgetById("points"));
		@m_list = m_widget.GetWidgetById("list");
		@m_rowTemplate = m_widget.GetWidgetById("row-template");
		@m_headerTemplate = cast<TextWidget>(m_widget.GetWidgetById("header-template"));
		@m_lineTemplate = cast<TextWidget>(m_widget.GetWidgetById("line-template"));
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

	void AddLine(const string &in text)
	{
		auto l = cast<TextWidget>(m_lineTemplate.Clone());
		l.SetID("");
		l.m_visible = true;
		l.SetText(text);
		m_list.AddChild(l);
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
		m_seenVersion = HWP::Pets::g_version;
		m_list.ClearChildren();
		m_rows.removeRange(0, m_rows.length());
		m_rowActions.removeRange(0, m_rowActions.length());

		auto rec = GetLocalPlayerRecord();
		m_messageText.SetText(m_message);
		string petId = HWP::Pets::ActivePetId(rec);
		if (petId.isEmpty())
		{
			m_state.SetText(Resources::GetString(".hwp.pets.none"));
			m_xp.SetText("");
			m_points.SetText("");
			AddLine(Resources::GetString(".hwp.pets.none_hint"));
			return;
		}

		int lvl = HWP::Pets::Level(rec, petId);
		int free = HWP::Pets::FreePoints(rec, petId);
		m_state.SetText(Resources::GetString(".hwp.pets.state", { { "name", HWP::Pets::PetName(rec) }, { "lvl", lvl }, { "max", HWP::Pets::g_maxLevel } }));
		if (lvl >= HWP::Pets::g_maxLevel)
			m_xp.SetText(Resources::GetString(".hwp.pets.xp_max"));
		else
			m_xp.SetText(Resources::GetString(".hwp.pets.xp", { { "xp", HWP::Pets::Xp(rec, petId) }, { "next", HWP::Pets::XpToNext(lvl) } }));
		m_points.SetText(Resources::GetString(".hwp.pets.points", { { "n", free } }));

		AddHeader(Resources::GetString(".hwp.pets.skills"));
		for (int s = 0; s < HWP::Pets::NUM_SKILLS; s++)
		{
			auto def = HWP::Pets::Def(s);
			if (def is null)
				continue;
			int r = HWP::Pets::Rank(rec, petId, s);
			string name = Resources::GetString(".hwp.pets.skill." + def.id + ".name");
			if (s == HWP::Pets::Skill::Family)
			{
				auto pb = cast<PlayerBase>(rec.actor);
				string fam = (pb !is null && pb.m_pet !is null) ? HWP::Pets::FamilyOf(pb.m_pet.m_unit) : "other";
				name = Resources::GetString(".hwp.pets.family." + fam);
			}
			string label = Resources::GetString(".hwp.pets.skill_row", { { "name", name }, { "rank", r }, { "max", def.maxRank } });
			if (free > 0 && r < def.maxRank)
				label += " " + Resources::GetString(".hwp.pets.skill_up");
			AddRow(label, "skill:" + s);
			AddLine(Resources::GetString(".hwp.pets.skill." + def.id + ".desc"));
		}

		bool header = false;
		for (uint i = 0; i < HWP::Pets::g_feedIds.length(); i++)
		{
			string ware = HWP::Pets::g_feedIds[i];
			int n = HWP::Market::Count(rec, ware);
			if (n <= 0)
				continue;
			if (!header)
			{
				AddHeader(Resources::GetString(".hwp.pets.feed"));
				header = true;
			}
			auto good = HWP::Market::Get(ware);
			string wname = good !is null ? good.Name() : ware;
			AddRow(Resources::GetString(".hwp.pets.feed_row", { { "name", wname }, { "n", n }, { "xp", HWP::Pets::g_feedXp[i] } }), "feed:" + ware);
		}
		if (!header)
		{
			AddHeader(Resources::GetString(".hwp.pets.feed"));
			AddLine(Resources::GetString(".hwp.pets.feed_none"));
		}

		if (rec.pet !is null)
		{
			AddHeader(Resources::GetString(".hwp.pets.pickups"));
			for (uint i = 0; i < HWP::Pets::OPTION_IDS.length(); i++)
			{
				bool on = HWP::Pets::HasOption(rec, HWP::Pets::OPTION_BITS[i]);
				AddRow(Resources::GetString(".hwp.pets.option", {
					{ "name", Resources::GetString(".hwp.pets.opt." + HWP::Pets::OPTION_IDS[i]) },
					{ "state", Resources::GetString(on ? ".hwp.pets.on" : ".hwp.pets.off") } }), "opt:" + i);
			}
		}
	}

	bool Update(int ms, GameInput& gameInput, MenuInput& menuInput) override
	{
		bool result = AWindowObject::Update(ms, gameInput, menuInput);
		if (m_seenVersion != HWP::Pets::g_version)
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
		int idx = -1;
		for (uint i = 0; i < m_rows.length(); i++)
			if (m_rows[i] is sender)
				idx = int(i);
		if (idx < 0)
			return;
		auto rec = GetLocalPlayerRecord();
		string action = m_rowActions[idx];
		int colon = action.findFirst(":");
		string kind = action.substr(0, colon);
		string arg = action.substr(colon + 1);
		m_message = "";
		if (kind == "skill")
		{
			if (!HWP::Pets::SpendPoint(rec, parseInt(arg)))
				m_message = Resources::GetString(".hwp.pets.no_points");
		}
		else if (kind == "feed")
		{
			if (!HWP::Pets::Feed(rec, arg))
				m_message = Resources::GetString(".hwp.pets.cannot_feed");
			else
				m_message = Resources::GetString(".hwp.pets.fed");
		}
		else if (kind == "opt")
		{
			int i = parseInt(arg);
			HWP::Pets::SetOption(rec, HWP::Pets::OPTION_BITS[i], !HWP::Pets::HasOption(rec, HWP::Pets::OPTION_BITS[i]));
		}
		Refresh();
	}
}

// ---- module ----------------------------------------------------------------------------

namespace Modules
{
	class HWPPetsModule : Module, HWP::ModuleStart
	{
		bool m_bowlSpawned = false;
		bool m_levelSent = false;
		int m_delay = 0;

		HWPPetsModule()
		{
			super("hwp-pets");
			HWP::Pets::LoadDefs();
			HWP::Net::OnRequest(HWP::Pets::ACT, HWP::Net::RequestHandler(HWP::Pets::OnAct));
			HWP::Net::OnRequest(HWP::Pets::LEVEL, HWP::Net::RequestHandler(HWP::Pets::OnLevel));
			HWP::Net::OnEvent(HWP::Pets::PICKUP, HWP::Net::EventHandler(HWP::Pets::OnPickupEvent));
			HWP::PetDye::Init();
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::Pets::OnSettingChanged));
			HWP::Commands::Register("pet", " pet status; 'skill <id>', 'feed <crop>', '<gold|valuables|materials|health|caches|cursed|elixirs|xp> on|off', 'here' moves the bowl (host)", HWP::Commands::Handler(HWP::Pets::CmdPet));
			HWP::Pets::SelfCheck(false);
		}

		void Start(StartMode sMode)
		{
			HWP::Settings::Sync("pets.");
			HWP::Settings::Sync("petwait.");
			HWP::Pets::RefreshSettings();
			HWP::PetWait::RefreshSettings();
			HWP::Pets::ResetHost();
			HWP::Pets::ResetSecrets();
			HWP::Pets::g_bowlUnit = UnitPtr();
			HWP::Pets::g_bowlReady = false;
			HWP::PetDye::Start();
			HWP::Pets::g_version++;
			m_bowlSpawned = false;
			m_levelSent = false;
			m_delay = 0;
			HWP::Pets::SelfCheck(true);
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused)
				return;
			m_delay += ms;
			if (m_delay < 600)
				return;
			HWP::PetDye::Tick(GetLocalPlayerRecord());
			// a client places its bowl from the host's pets.* settings
			if (!m_bowlSpawned && g_inTown && (HWP::Settings::RemoteReady() || m_delay > 8000))
			{
				m_bowlSpawned = true;
				HWP::Pets::g_bowlReady = true;
				if (HWP::Pets::g_enabled)
					HWP::Pets::SpawnBowl(HWP::Pets::BowlPos());
			}
			if (!m_levelSent)
			{
				auto rec = GetLocalPlayerRecord();
				if (rec !is null && rec.actor !is null)
				{
					m_levelSent = true;
					HWP::Pets::SendLevel(rec);
				}
				else if (m_delay > 10000)
					m_levelSent = true;
			}
		}
	}
}
