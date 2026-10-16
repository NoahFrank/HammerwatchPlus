// Weapon swap: one alternate main-hand/off-hand pair per character, stored as
// serialized items in the player record (HWP bag keys weaponswap.main/off), so
// it survives saves and never duplicates: a swap unequips the current pair into
// the stash and equips the stashed pair through the vanilla EquippedItems
// (which sends PlayerEquipmentEquip/Unequip to the lobby). With an empty stash
// the hotkey stashes what you hold, so the flow is: press, equip the other
// weapons from your bag, press again to toggle.
namespace HWP
{
	namespace WeaponSwap
	{
		const string KEY_MAIN = "weaponswap.main";
		const string KEY_OFF = "weaponswap.off";
		const int DEFAULT_SCANCODE = 27; // SDL scancode for X
		const int COOLDOWN_MS = 1500;

		int g_scancode = DEFAULT_SCANCODE;
		string g_keyName = "X";
		bool g_wasDown = false;
		int g_cooldown = 0;
		HWPWeaponSwapHUD@ g_hud;

		void RefreshSettings()
		{
			g_scancode = HWP::Settings::GetInt("weaponswap.key", DEFAULT_SCANCODE);
			g_keyName = HWP::Settings::GetString("weaponswap.keyname", g_scancode == DEFAULT_SCANCODE ? "X" : "key " + g_scancode);
		}

		void OnSettingChanged(const string &in key)
		{
			if (key.findFirst("weaponswap.") == 0)
			{
				RefreshSettings();
				RefreshHUD();
			}
		}

		HWP::DataBag@ Bag() { return HWP::SaveData::Local(); }

		Equipment::Equipment@ LoadAlt(const string &in key)
		{
			auto sv = Bag().Get(key);
			if (sv is null)
				return null;
			return cast<Equipment::Equipment>(Item::LoadItem(sv));
		}

		void StoreAlt(const string &in key, Equipment::Equipment@ item)
		{
			if (item is null)
			{
				Bag().Remove(key);
				return;
			}
			SValueBuilder b;
			Item::SaveItem(b, item);
			Bag().Set(key, b.Build());
		}

		string ItemText(Equipment::Equipment@ item)
		{
			if (item is null)
				return Resources::GetString(".hwp.weaponswap.empty_hand");
			return "\\c" + Item::QualityColorString(item.GetQuality()) + item.GetName() + "\\d";
		}

		string AltText()
		{
			auto altMain = LoadAlt(KEY_MAIN);
			auto altOff = LoadAlt(KEY_OFF);
			if (altMain is null && altOff is null)
				return "";
			if (altOff is null)
				return ItemText(altMain);
			if (altMain is null)
				return ItemText(altOff);
			return ItemText(altMain) + " / " + ItemText(altOff);
		}

		void RefreshHUD()
		{
			if (g_hud !is null)
				g_hud.Refresh();
		}

		bool TypingInChat()
		{
			auto main = cast<MainMenuGameMode>(g_gameMode);
			return main !is null && main.m_wChat !is null && main.m_wChat.m_wInput !is null && main.m_wChat.m_wInput.m_typing;
		}

		void Feedback(PlayerRecord@ rec, const string &in text)
		{
			auto pb = cast<PlayerBase>(rec.actor);
			if (pb !is null && pb.m_unit.IsValid())
				AddFloatingText(FloatingTextType::Pickup, text, pb.m_unit.GetPosition());
		}

		void Swap()
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.equipped is null || rec.IsDead())
				return;

			int mainSlot = int(EquippedItemsSlots::MainHand);
			int offSlot = int(EquippedItemsSlots::OffHand);
			Equipment::Equipment@ curMain = rec.equipped.m_items[mainSlot];
			Equipment::Equipment@ curOff = rec.equipped.m_items[offSlot];
			Equipment::Equipment@ altMain = LoadAlt(KEY_MAIN);
			Equipment::Equipment@ altOff = LoadAlt(KEY_OFF);

			if (curMain is null && curOff is null && altMain is null && altOff is null)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.weaponswap.nothing"));
				return;
			}

			// requirement checks happen while the current pair is still worn,
			// as a manual equip would see it
			bool canMain = altMain is null || rec.equipped.MayEquip(altMain, false);
			bool canOff = altOff is null || rec.equipped.MayEquip(altOff, false);

			if (curMain !is null)
				rec.equipped.Unequip(EquippedItemsSlots::MainHand);
			if (curOff !is null)
				rec.equipped.Unequip(EquippedItemsSlots::OffHand);

			Equipment::Equipment@ keepMain = curMain;
			Equipment::Equipment@ keepOff = curOff;

			if (altMain !is null)
			{
				if (canMain)
					rec.equipped.Equip(altMain, EquippedItemsSlots::MainHand);
				else
				{
					if (curMain !is null)
						rec.equipped.Equip(curMain, EquippedItemsSlots::MainHand);
					@keepMain = altMain;
					HWP::Commands::Reply(Resources::GetString(".hwp.weaponswap.cannot", { { "item", altMain.GetName() } }));
				}
			}
			if (altOff !is null)
			{
				if (canOff && (rec.equipped.m_items[mainSlot] is null || rec.equipped.m_items[mainSlot].GetSlot() != Equipment::Slot::TwoHanded))
					rec.equipped.Equip(altOff, EquippedItemsSlots::OffHand);
				else
				{
					if (curOff !is null && (rec.equipped.m_items[mainSlot] is null || rec.equipped.m_items[mainSlot].GetSlot() != Equipment::Slot::TwoHanded))
						rec.equipped.Equip(curOff, EquippedItemsSlots::OffHand);
					@keepOff = altOff;
					if (canOff)
						HWP::Commands::Reply(Resources::GetString(".hwp.weaponswap.cannot", { { "item", altOff.GetName() } }));
				}
			}

			StoreAlt(KEY_MAIN, keepMain);
			StoreAlt(KEY_OFF, keepOff);
			g_cooldown = COOLDOWN_MS;

			bool stashedOnly = altMain is null && altOff is null;
			Feedback(rec, Resources::GetString(stashedOnly ? ".hwp.weaponswap.stashed" : ".hwp.weaponswap.swapped", { { "key", g_keyName } }));
			HWP::Log("weaponswap", (stashedOnly ? "stashed " : "swapped; stash now ") + ItemText(keepMain) + " / " + ItemText(keepOff));
			RefreshHUD();
		}

		// move the stash back into the bag
		void Drop()
		{
			auto rec = GetLocalPlayerRecord();
			if (rec is null || rec.equipInventory is null)
				return;
			auto altMain = LoadAlt(KEY_MAIN);
			auto altOff = LoadAlt(KEY_OFF);
			int needed = (altMain is null ? 0 : 1) + (altOff is null ? 0 : 1);
			if (needed == 0)
				return;
			if (rec.equipInventory.m_maxItems >= 0 && int(rec.equipInventory.m_items.length()) + needed > rec.equipInventory.m_maxItems)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.weaponswap.inventory_full"));
				return;
			}
			if (altMain !is null)
				rec.equipInventory.Add(altMain);
			if (altOff !is null)
				rec.equipInventory.Add(altOff);
			Bag().Remove(KEY_MAIN);
			Bag().Remove(KEY_OFF);
			HWP::Commands::Reply(Resources::GetString(".hwp.weaponswap.dropped"));
			RefreshHUD();
		}

		void Poll(int ms, bool paused)
		{
			if (g_cooldown > 0)
				g_cooldown -= ms;
			bool down = Platform::IsKeyDown(ControllerType::Keyboard, 0, g_scancode);
			bool pressed = down && !g_wasDown;
			g_wasDown = down;
			if (!pressed || paused || g_cooldown > 0 || TypingInChat())
				return;
			Swap();
		}

		void CmdSwap(array<string>@ args) { Swap(); }
		void CmdSwapDrop(array<string>@ args) { Drop(); }

		void CmdSwapKey(array<string>@ args)
		{
			if (args.length() < 1 || parseInt(args[0]) <= 0)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.weaponswap.status", {
					{ "items", AltText().isEmpty() ? "-" : AltText() }, { "code", "" + g_scancode }, { "name", g_keyName } }));
				return;
			}
			int code = parseInt(args[0]);
			HWP::Settings::SetInt("weaponswap.key", code);
			if (args.length() >= 2)
				HWP::Settings::SetString("weaponswap.keyname", args[1]);
			else
				HWP::Settings::Reset("weaponswap.keyname");
			RefreshSettings();
			RefreshHUD();
			HWP::Commands::Reply(Resources::GetString(".hwp.weaponswap.key_set", { { "code", "" + code }, { "name", g_keyName } }));
		}
	}
}

class HWPWeaponSwapHUD : HUDComponent
{
	TextWidget@ m_text;

	HWPWeaponSwapHUD(GUIBuilder@ b)
	{
		super(b, "gui/hwp_weaponswap.gui");
		@m_text = cast<TextWidget>(m_widget.GetWidgetById("text"));
		m_visible = false;
	}

	void Refresh()
	{
		auto alt = HWP::WeaponSwap::AltText();
		m_visible = !alt.isEmpty();
		if (m_visible)
			m_text.SetText(Resources::GetString(".hwp.weaponswap.hud", { { "key", HWP::WeaponSwap::g_keyName }, { "items", alt } }));
	}

	void Start() override
	{
		Refresh();
	}
}

namespace HWPWeaponSwap
{
	[Hook]
	void HUDConstructor(HUD@ hud, GUIBuilder@ b)
	{
		auto comp = HWPWeaponSwapHUD(b);
		hud.m_components.insertLast(comp);
		@HWP::WeaponSwap::g_hud = comp;
	}
}

namespace Modules
{
	class HWPWeaponSwapModule : Module
	{
		bool m_hudRefreshed = false;

		HWPWeaponSwapModule()
		{
			super("hwp-weaponswap");
			HWP::Commands::Register("swap", " swap to the alternate weapon set (hotkey X)", HWP::Commands::Handler(HWP::WeaponSwap::CmdSwap));
			HWP::Commands::Register("swapkey", "[scancode [name]]  show or set the swap hotkey", HWP::Commands::Handler(HWP::WeaponSwap::CmdSwapKey));
			HWP::Commands::Register("swapdrop", " move the alternate set back into your inventory", HWP::Commands::Handler(HWP::WeaponSwap::CmdSwapDrop));
			HWP::Commands::OnSettingChanged(HWP::Commands::SettingListener(HWP::WeaponSwap::OnSettingChanged));
		}

		void Load(SValue@ save, StartMode sMode) override
		{
			HWP::WeaponSwap::RefreshSettings();
			HWP::WeaponSwap::g_cooldown = 0;
			HWP::WeaponSwap::g_wasDown = false;
			m_hudRefreshed = false;
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			if (!m_hudRefreshed)
			{
				// the HUD is built after Load; refresh once the record is there
				m_hudRefreshed = true;
				HWP::WeaponSwap::RefreshHUD();
			}
			HWP::WeaponSwap::Poll(ms, paused);
		}
	}
}
