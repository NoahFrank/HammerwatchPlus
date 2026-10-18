# chatlinks

Item links in chat.

- The base game already links items: **hold the context key (~1 s) on an
  inventory item** (`Character.as MenuContextUp`), which sends the serialized
  item to everyone and raises `GameEvents::PlayerLinkedItem` on each machine.
  Vanilla only shows it in the fading loot log.
- `HWPChatLinksModule` implements `IEventPlayerLinkedItem` and adds a
  persistent chat line: `<player>: [Item Name] Main Hand, ilvl 12`, name in
  rarity colour, player name in player colour.
- `hwp link [main|off|head|chest|feet|hands|back]` links an equipped item
  (default main hand) using the same two calls the inventory makes.

Not done (morning decision): typing `[item]` tokens into the chat input and a
hover tooltip on the chat line. The chat widget renders plain text; a tooltip
needs a custom chat list widget (`GameChat.as` is not overridden yet).

## Test checklist

1. `python -m gamelab run mod-chatlinks --mode lab`: no script errors.
2. Solo: open the inventory, hold the context key on an item: a chat line with
   the coloured name appears (plus the vanilla loot-log flash).
3. `hwp link` and `hwp link off` print the equipped items; an empty slot
   prints the "nothing equipped" hint.
4. Co-op: the other player sees the same line with your name in your colour.
