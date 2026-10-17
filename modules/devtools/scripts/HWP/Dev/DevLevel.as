// Level loader for tools/dev_check.py --level (dev-only module, never
// packaged). Inert unless the gitignored lang file
// res/language/english/hwp_devlevel.lang defines
// .hwp.dev.level = "<mission id> <floor id>". Once in town (dev_check clicks
// Continue in the main menu: nothing script-side runs there) it creates a
// throwaway character if the profile has none (dev_check runs on its own
// test save slot, never the player's), starts that floor of the mission and
// prints "[HWP:dev] level ready ..." when the level has run for a few seconds
// (dev_check waits for that line and harvests the log).
namespace HWP
{
	namespace DevLevel
	{
		const string KEY = ".hwp.dev.level";
		const string STAGE = "hwp_dev_level_stage";   // GlobalCache: survives level changes
		const int TOWN_WAIT_MS = 3000;
		const int LEVEL_WAIT_MS = 5000;

		const string TEST_NAME = "HWP Test";
		int g_ms = 0;

		// A new profile has a player record without a class (the town would
		// open the pick/create character window); give it a level 1 character.
		bool EnsureCharacter()
		{
			auto plr = GetLocalPlayerRecord();
			if (plr is null)
				return false;
			if (plr.playerClass !is null)
				return true;
			auto gm = cast<AGameplayGameMode>(g_gameMode);
			if (gm is null || PlayerClass::Instances.length() == 0 || PlayerVoice::Instances.length() == 0)
				return false;
			PlayerClass@ cls = null;
			for (uint i = 0; i < PlayerClass::Instances.length() && cls is null; i++)
			{
				if (PlayerClass::Instances[i].parent == 0)
					@cls = PlayerClass::Instances[i];
			}
			if (cls is null)
				return false;
			for (uint i = 0; i < g_players.length(); i++)
			{
				if (g_players[i].peer == 255 || !g_players[i].local)
					continue;
				@g_players[i] = PlayerRecord(g_players[i]);
				@plr = g_players[i];
				break;
			}
			plr.CreateCharacter(cls, TEST_NAME, PlayerVoice::Instances[0]);
			gm.SpawnLocalPlayers();
			gm.m_windowManager.QueueClear();
			Log("dev", "created test character '" + TEST_NAME + "' (" + cls.m_id + ")");
			return true;
		}

		bool Active()
		{
			return Resources::HasString(KEY);
		}

		void Start(const string &in spec)
		{
			auto parts = spec.split(" ");
			if (parts.length() != 2)
			{
				LogError("dev", "bad " + KEY + " '" + spec + "', want '<mission id> <floor id>'");
				return;
			}
			auto def = MissionDef::Get(parts[0]);
			if (def is null)
			{
				LogError("dev", "no mission " + parts[0]);
				return;
			}
			for (uint i = 0; i < def.m_levels.length(); i++)
			{
				if (def.m_levels[i].m_id != parts[1])
					continue;
				Log("dev", "starting " + parts[0] + " floor " + i + " (" + parts[1] + ") " + def.m_levels[i].m_level);
				MissionManager::SetMission(HashString(parts[0]), randi());
				MissionManager::g_module.m_missionLevelIndex = i;
				MissionManager::g_module.StartMission();
				return;
			}
			LogError("dev", "mission " + parts[0] + " has no floor " + parts[1]);
		}

		void Tick(int ms)
		{
			if (!Active())
				return;
			g_ms += ms;
			auto stage = GlobalCache::Get(STAGE);
			if (stage == "" && g_inTown && g_ms >= TOWN_WAIT_MS)
			{
				if (!EnsureCharacter())
					return;
				g_ms = 0;
				GlobalCache::Set(STAGE, "town");
			}
			else if (stage == "town" && g_inTown && g_ms >= TOWN_WAIT_MS)
			{
				GlobalCache::Set(STAGE, "level");
				Start(Resources::GetString(KEY));
			}
			else if (stage == "level" && !g_inTown && g_ms >= LEVEL_WAIT_MS)
			{
				GlobalCache::Set(STAGE, "done");
				Log("dev", "level ready " + GetCurrentLevelFilename() + " mode " + Reflect::GetTypeName(g_gameMode));
			}
		}
	}
}

namespace Modules
{
	class HWPDevModule : Module
	{
		HWPDevModule()
		{
			super("hwp-devtools");
			HWP::DevLevel::g_ms = 0;
			// tools/dev_check.py looks for this line to know the loader is armed
			if (HWP::DevLevel::Active() && GlobalCache::Get(HWP::DevLevel::STAGE) == "")
				HWP::Log("dev", "level loader on: " + Resources::GetString(HWP::DevLevel::KEY));
			if (HWP::DevTown::Active())
				HWP::Log("dev", "town script on");
			HWP::Commands::Register("devtown", "build  (dev, test slot) every building at top tier, then reload the town", HWP::Commands::Handler(HWP::DevTown::CmdDevTown));
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			HWP::DevLevel::Tick(ms);
			HWP::DevTown::Tick(ms);
		}
	}
}
