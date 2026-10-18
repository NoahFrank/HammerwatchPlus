// Settings-backed town doodads. A Placeable is one unit the host places in
// town: its position lives in the town record as <prefix>_x / <prefix>_y, it is
// spawned shortly after a town load (host only) and 'hwp <cmd> here' moves it
// to where the host stands. Modules create one in their constructor:
//
//   @g_portal = HWP::Town::Placeable("campaign", "campaign.portal", PORTAL_UNIT, -1700, 250);
//   Start:       g_portal.OnLoad();   (HWP::ModuleStart)
//   UpdateFrame: g_portal.Update(ms, g_enabled);
//   'hwp x here': g_portal.MoveHere();
namespace HWP
{
	namespace Town
	{
		const int SPAWN_DELAY_MS = 600; // let the town finish placing its own units first

		// the local player pays gold for a town purchase; false (nothing paid)
		// when short
		bool PayGold(int price)
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || price < 0 || rec.GetMaterial(MaterialType::Gold) < price)
				return false;
			rec.GiveMaterial(MaterialType::Gold, -price, true);
			return true;
		}

		class Placeable
		{
			string m_tag;      // log tag / module name
			string m_prefix;   // settings prefix, e.g. "wave.statue"
			string m_unitPath;
			int m_defX;
			int m_defY;
			UnitPtr m_unit;
			bool m_spawnDone = true;
			int m_delay = 0;

			Placeable(const string &in tag, const string &in prefix, const string &in unitPath, int defX, int defY)
			{
				m_tag = tag;
				m_prefix = prefix;
				m_unitPath = unitPath;
				m_defX = defX;
				m_defY = defY;
			}

			vec3 Pos()
			{
				return vec3(float(HWP::Settings::GetInt(m_prefix + "_x", m_defX)),
					float(HWP::Settings::GetInt(m_prefix + "_y", m_defY)), 0.0f);
			}

			void Spawn(vec3 pos)
			{
				if (m_unit.IsValid())
					m_unit.Destroy();
				auto prod = Resources::GetUnitProducer(m_unitPath);
				if (prod is null)
				{
					HWP::LogError(m_tag, "missing " + m_unitPath);
					return;
				}
				m_unit = prod.Produce(g_scene, pos);
				HWP::Log(m_tag, m_unitPath + " spawned at " + pos.x + "," + pos.y);
			}

			// HWP::ModuleStart::Start
			void OnLoad()
			{
				m_unit = UnitPtr();
				m_spawnDone = false;
				m_delay = 0;
			}

			// Module::UpdateFrame: spawns once per town load on the host
			void Update(int ms, bool enabled)
			{
				if (m_spawnDone)
					return;
				m_delay += ms;
				if (m_delay < SPAWN_DELAY_MS)
					return;
				m_spawnDone = true;
				if (!Network::IsServer() || !enabled || !g_inTown)
					return;
				Spawn(Pos());
			}

			// 'hwp <cmd> here' (host): save the local player's position and
			// respawn there when in town. Replies to the chat itself.
			void MoveHere()
			{
				if (!Network::IsServer())
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.town.host_only"));
					return;
				}
				auto rec = GetLocalPlayerRecord();
				if (rec is null || rec.actor is null)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.town.no_actor"));
					return;
				}
				auto p = rec.actor.m_unit.GetPosition();
				int x = int(p.x);
				int y = int(p.y);
				HWP::Settings::SetInt(m_prefix + "_x", x);
				HWP::Settings::SetInt(m_prefix + "_y", y);
				HWP::Commands::NotifySettingChanged(m_prefix + "_x");
				HWP::Commands::NotifySettingChanged(m_prefix + "_y");
				if (g_inTown)
					Spawn(vec3(float(x), float(y), 0.0f));
				HWP::Commands::Reply(Resources::GetString(".hwp.town.moved", { { "what", m_tag }, { "x", x }, { "y", y } }));
			}
		}
	}
}

// Behaviour of town units a module spawns on every machine (netsync none:
// fishing spots, the pirate, farm plots, the well): a vanilla NPC that keeps
// its duplicates (vanilla removes all but one NPC of a unit type on the host).
class HWPLocalNPC : CompositeActorBehaviorNPC
{
	HWPLocalNPC(UnitPtr unit, SValue& params) { super(unit, params); }

	void CheckForExistance() override {}
}
