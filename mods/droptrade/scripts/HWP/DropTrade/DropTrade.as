// Drop key for the inventory: with an inventory item hovered in the player
// menu, the key (default Q, SDL scancode 20) drops it at your feet, next to
// vanilla Destroy. The menu's own bindings have no free action for it, so
// the key is polled raw like the weapon swap key.
namespace HWP
{
	namespace DropTrade
	{
		const int DEFAULT_SCANCODE = 20; // SDL scancode for Q

		PlayerMenuCharacterTab@ g_tab;
		int g_scancode = DEFAULT_SCANCODE;
		string g_keyName = "Q";
		bool g_wasDown = false;

		void LoadKey()
		{
			g_scancode = HWP::Settings::GetInt("droptrade.key", DEFAULT_SCANCODE);
			g_keyName = HWP::Settings::GetString("droptrade.keyname", g_scancode == DEFAULT_SCANCODE ? "Q" : "key " + g_scancode);
		}

		string NavText()
		{
			return "[" + g_keyName + "] " + Resources::GetString(".hwp.droptrade.drop");
		}

		void MakeButton(KeyNavigationText@ text, WindowInput::OnFunc@ func)
		{
			@text.m_func = func;
			@text.m_hoverSnd = Resources::GetSoundEvent("event:/sfx/ui/hover");
			@text.m_clickSnd = Resources::GetSoundEvent("event:/sfx/ui/click");
		}

		bool TypingInChat()
		{
			auto main = cast<MainMenuGameMode>(g_gameMode);
			return main !is null && main.m_wChat !is null && main.m_wChat.m_wInput !is null && main.m_wChat.m_wInput.m_typing;
		}

		// true while the character tab is open and on top: not behind a dialog
		// (the vanilla destroy confirm), and no text input has the keyboard,
		// since the raw key poll cannot tell the drop key from typing a 'q'
		bool TabOpen()
		{
			auto gm = cast<BaseGameMode>(g_gameMode);
			if (g_tab is null || gm is null || gm.m_windowManager is null || gm.m_windowManager.m_objects.length() == 0)
				return false;
			auto cb = GetControlBindings();
			if ((cb !is null && cb.IsExpectingTextInput()) || TypingInChat())
				return false;
			auto menu = cast<PlayerMenu>(gm.m_windowManager.m_objects[gm.m_windowManager.m_objects.length() - 1]);
			return menu !is null && menu.m_tabSystem !is null
				&& menu.m_tabSystem.m_currentIndex >= 0 && menu.m_tabSystem.m_currentIndex < int(menu.m_tabSystem.m_tabs.length())
				&& menu.m_tabSystem.m_tabs[menu.m_tabSystem.m_currentIndex] is g_tab;
		}

		void Poll()
		{
			bool down = Platform::IsKeyDown(ControllerType::Keyboard, 0, g_scancode);
			bool pressed = down && !g_wasDown;
			g_wasDown = down;
			if (pressed && TabOpen())
				g_tab.HWPDrop();
		}

		void CmdDropKey(array<string>@ args)
		{
			if (args.length() >= 1)
			{
				int code = parseInt(args[0]);
				if (code <= 0)
				{
					HWP::Commands::Reply(Resources::GetString(".hwp.droptrade.key_usage"));
					return;
				}
				HWP::Settings::SetInt("droptrade.key", code);
				HWP::Settings::SetString("droptrade.keyname", args.length() >= 2 ? args[1].toUpper() : "key " + code);
				LoadKey();
			}
			HWP::Commands::Reply(Resources::GetString(".hwp.droptrade.key", { { "code", "" + g_scancode }, { "name", g_keyName } }));
		}
	}
}

namespace Modules
{
	class HWPDropTradeModule : Module, HWP::ModuleStart
	{
		HWPDropTradeModule()
		{
			super("hwp-droptrade");
			HWP::Commands::Register("dropkey", "[scancode [name]]  show or set the inventory drop key", HWP::Commands::Handler(HWP::DropTrade::CmdDropKey));
			HWP::Log("droptrade", "menu destroy key " + FormatKeyName(GetActionBinding("MenuAdditional")));
		}

		void Start(StartMode sMode)
		{
			HWP::DropTrade::LoadKey();
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			HWP::DropTrade::Poll();
		}
	}
}
