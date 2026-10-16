// Chat item links. The base game already has item linking: holding the context
// key for a second on an inventory item fires GameEvents::PlayerLinkedItem on
// every machine (Character.as -> "PlayerLinkedItem" message -> PlayerHandler),
// but only the short-lived loot log reacts. This module listens to the same
// event and writes a persistent, coloured line into the chat log, and adds
// "hwp link [slot]" to link an equipped item without opening the inventory.
namespace HWP
{
	namespace ChatLinks
	{
		string Link(Item::Item@ item)
		{
			return "\\c" + Item::QualityColorString(item.GetQuality()) + "[" + item.GetName() + "]\\d";
		}

		string Details(Item::Item@ item)
		{
			auto eq = cast<Equipment::Equipment>(item);
			if (eq is null)
				return "";
			return " " + Equipment::SlotToTooltip(eq.GetSlot()) + ", "
				+ Resources::GetString(".hwp.chatlinks.ilvl", { { "level", "" + eq.GetItemLevel() } });
		}

		void Announce(PlayerRecord@ plr, Item::Item@ item)
		{
			SValueBuilder b;
			b.PushString("\\c" + GetPlayerColor(plr.peer) + plr.GetName() + "\\d: " + Link(item) + Details(item));
			SendSystemMessage("AddChat", b.Build());
		}

		int SlotFromName(const string &in name)
		{
			if (name == "off") return int(EquippedItemsSlots::OffHand);
			if (name == "head") return int(EquippedItemsSlots::Head);
			if (name == "chest") return int(EquippedItemsSlots::Chest);
			if (name == "feet") return int(EquippedItemsSlots::Feet);
			if (name == "hands") return int(EquippedItemsSlots::Hands);
			if (name == "back") return int(EquippedItemsSlots::Back);
			return int(EquippedItemsSlots::MainHand);
		}

		// Same two calls Character.as makes when the context key is held.
		void LinkItem(PlayerRecord@ plr, Item::Item@ item)
		{
			GameEvents::PlayerLinkedItem(plr, item);
			SValueBuilder builder;
			Item::SaveItem(builder, item);
			(Network::Message("PlayerLinkedItem") << builder.Build()).SendToAll();
		}

		void CmdLink(array<string>@ args)
		{
			auto plr = GetLocalPlayerRecord();
			if (plr is null || plr.equipped is null)
				return;
			string slotName = args.length() > 0 ? args[0] : "main";
			int slot = SlotFromName(slotName);
			Item::Item@ item = plr.equipped.m_items[slot];
			if (item is null)
			{
				HWP::Commands::Reply(Resources::GetString(".hwp.chatlinks.nothing", { { "slot", slotName } }));
				return;
			}
			LinkItem(plr, item);
		}
	}
}

namespace Modules
{
	class HWPChatLinksModule : Module, IEventPlayerLinkedItem
	{
		HWPChatLinksModule()
		{
			super("hwp-chatlinks");
			GameEvents::Subscribe(this);
			HWP::Commands::Register("link", "[main|off|head|chest|feet|hands|back]  link an equipped item in chat", HWP::Commands::Handler(HWP::ChatLinks::CmdLink));
		}

		void OnEventPlayerLinkedItem(PlayerRecord@ plr, Item::Item@ item)
		{
			if (plr is null || item is null)
				return;
			HWP::ChatLinks::Announce(plr, item);
		}
	}
}
