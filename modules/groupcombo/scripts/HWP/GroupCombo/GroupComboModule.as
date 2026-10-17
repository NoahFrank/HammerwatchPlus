// Group combo. The host counts, twice a second, how many living players have
// an active combo (PlayerBase.m_comboActive is synced to everyone). Two or more
// -> every player in combo gets the matching group buff (group_2/3/4 in
// tweak/hwp/buffs_groupcombo.sval), re-applied each tick so it stays up while
// the condition holds. All living players in combo -> Group Unity: 2 s of no
// damage taken, once per 30 s, announced in chat.
//
// Buff delivery: the host's own player gets a real ActorBuff (the engine then
// mirrors it to clients as a husk buff). Remote players are husks on the host
// and refuse non-husk buffs, so they get the vanilla "UnitBuffed" message,
// which the owning client applies for real - the same path the game uses for
// server-side effects.
namespace HWP
{
	namespace GroupCombo
	{
		const string UNITY_EVENT = "groupcombo.unity";
		const string BUFF_FILE = "tweak/hwp/buffs_groupcombo.sval";
		const int TICK_MS = 500;
		const int GROUP_DURATION_MS = 1500;
		const int UNITY_DURATION_MS = 2000;
		const int UNITY_COOLDOWN_MS = 30000;

		int g_cooldown = 0;
		int g_lastCount = -1;
		int g_lastAlive = 0;
		bool g_enabled = true;

		void RefreshSettings()
		{
			g_enabled = HWP::Settings::GetBool("groupcombo.enabled", true);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("groupcombo.") == 0)
				RefreshSettings();
		}

		ActorBuffDef@ GroupDef(int inCombo)
		{
			string key = inCombo >= 4 ? "group_4" : (inCombo == 3 ? "group_3" : "group_2");
			return LoadActorBuff(BUFF_FILE + ":" + key);
		}

		void Apply(PlayerBase@ pb, ActorBuffDef@ def, int duration)
		{
			if (def is null || pb is null || pb.m_record is null)
				return;

			if (pb.m_record.local)
			{
				auto buff = ActorBuff(pb, def, 1.0f, false);
				buff.m_duration = duration;
				pb.ApplyBuff(buff);
			}
			else
			{
				(Network::Message("UnitBuffed") << pb.m_unit << pb.m_unit << def.m_pathHash << 1.0f << uint(0) << duration).SendToAll();
			}
		}

		void Tick(int ms)
		{
			if (!Network::IsServer())
				return;
			if (g_cooldown > 0)
				g_cooldown -= ms;
			if (!g_enabled || g_inTown)
				return;

			int alive = 0;
			array<PlayerBase@> inCombo;
			for (uint i = 0; i < g_players.length(); i++)
			{
				auto rec = g_players[i];
				if (rec is null || rec.peer == 255)
					continue;
				auto pb = cast<PlayerBase>(rec.actor);
				if (pb is null || pb.IsDead())
					continue;
				alive++;
				if (pb.m_comboActive)
					inCombo.insertLast(pb);
			}

			int n = int(inCombo.length());
			g_lastAlive = alive;
			if (n != g_lastCount)
			{
				if (n >= 2 || g_lastCount >= 2)
					HWP::Log("groupcombo", n + "/" + alive + " players in combo");
				g_lastCount = n;
			}
			if (n < 2)
				return;

			auto def = GroupDef(n);
			for (uint i = 0; i < inCombo.length(); i++)
				Apply(inCombo[i], def, GROUP_DURATION_MS);

			if (n == alive && g_cooldown <= 0)
			{
				g_cooldown = UNITY_COOLDOWN_MS;
				auto unity = LoadActorBuff(BUFF_FILE + ":unity");
				for (uint i = 0; i < inCombo.length(); i++)
					Apply(inCombo[i], unity, UNITY_DURATION_MS);

				SValueBuilder b;
				b.PushDictionary();
				b.PushInteger("count", n);
				b.PopDictionary();
				HWP::Net::Broadcast(UNITY_EVENT, b.Build());
			}
		}

		void OnUnity(SValue@ data)
		{
			int count = HWP::SV::Int(data, "count", 0);

			SValueBuilder b;
			b.PushString("\\cffd27f" + Resources::GetString(".hwp.groupcombo.unity.chat", { { "count", "" + count } }) + "\\d");
			SendSystemMessage("AddChat", b.Build());
		}

		void CmdStatus(array<string>@ args)
		{
			HWP::Commands::Reply(Resources::GetString(".hwp.groupcombo.status", {
				{ "combo", "" + (g_lastCount < 0 ? 0 : g_lastCount) }, { "alive", "" + g_lastAlive },
				{ "cooldown", "" + (g_cooldown > 0 ? g_cooldown / 1000 : 0) },
				{ "enabled", g_enabled ? "yes" : "no" } })
				+ (Network::IsServer() ? "" : " (counted on the host)"));
		}
	}
}

namespace Modules
{
	class HWPGroupComboModule : Module, HWP::ModuleStart
	{
		int m_acc = 0;

		HWPGroupComboModule()
		{
			super("hwp-groupcombo");
			HWP::Net::OnEvent(HWP::GroupCombo::UNITY_EVENT, HWP::Net::EventHandler(HWP::GroupCombo::OnUnity));
			HWP::Commands::Register("groupcombo", " show the group combo state", HWP::Commands::Handler(HWP::GroupCombo::CmdStatus));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::GroupCombo::OnSettingChanged));

			// resolve the buff file at boot so a broken sval shows in the log
			if (LoadActorBuff(HWP::GroupCombo::BUFF_FILE + ":group_2") is null)
				HWP::LogError("groupcombo", "cannot load " + HWP::GroupCombo::BUFF_FILE);
		}

		void Start(StartMode sMode)
		{
			m_acc = 0;
			HWP::GroupCombo::g_cooldown = 0;
			HWP::GroupCombo::g_lastCount = -1;
			HWP::GroupCombo::RefreshSettings();
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (paused)
				return;
			m_acc += ms;
			if (m_acc < HWP::GroupCombo::TICK_MS)
				return;
			int step = m_acc;
			m_acc = 0;
			HWP::GroupCombo::Tick(step);
		}
	}
}
