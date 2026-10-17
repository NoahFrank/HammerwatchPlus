// Gambler NPC - higher/lower card game.
// The player bets gold and draws a card against the dealer: higher wins the
// bet, lower loses it, a tie returns it. Interact class of actors/npcs/town/hwp_gambler.unit.

namespace HWP
{
	namespace Gambler
	{
		const int REROLL_PER_LEVEL = 2000;  // gold per item level for a gear reroll
		const int TOKEN_LEVELS = 5;         // or 1 bet token (HWP::Market) per 5 item levels
	}
}

class HWPGamblerShop : AShopContent
{
	array<int> m_betAmounts = { 100, 1000, 10000, 100000, 1000000 };
	int m_selectedBet = 0;
	int m_playerCard = 0;
	int m_dealerCard = 0;
	int m_playerSuit = 0;
	int m_dealerSuit = 0;
	int m_gameState = 0; // 0 = betting, 1 = animating, 2 = result shown
	int m_result = 0; // -1 = lose, 0 = tie, 1 = win

	HWPGamblerShop() {}
	HWPGamblerShop(UnitPtr u, SValue& params) { super(u, params); }

	bool CanInteract(PlayerRecord@ player) override
	{
		if (!player.local)
			return true;
		return CheckConditionals(m_conditionals, player);
	}

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		m_gameState = 0;
		m_selectedBet = 0;
		m_playerCard = 0;
		m_dealerCard = 0;
		@m_window = HWPGamblerMenu(guiBuilder, this);
		return m_window;
	}

	string GetName() override { return "gambler"; }

	int GetPlayerGold()
	{
		return m_player.GetMaterial(MaterialType::Gold);
	}

	bool CanAffordBet(int betIndex)
	{
		if (betIndex < 0 || betIndex >= int(m_betAmounts.length()))
			return false;
		return GetPlayerGold() >= m_betAmounts[betIndex];
	}

	void SelectBet(int betIndex)
	{
		if (CanAffordBet(betIndex))
			m_selectedBet = betIndex;
	}

	int GetSelectedBetAmount()
	{
		if (m_selectedBet < 0 || m_selectedBet >= int(m_betAmounts.length()))
			return 0;
		return m_betAmounts[m_selectedBet];
	}

	string GetCardName(int card)
	{
		switch(card)
		{
			case 1: return "A";
			case 2: return "2";
			case 3: return "3";
			case 4: return "4";
			case 5: return "5";
			case 6: return "6";
			case 7: return "7";
			case 8: return "8";
			case 9: return "9";
			case 10: return "10";
			case 11: return "J";
			case 12: return "Q";
			case 13: return "K";
		}
		return "?";
	}

	string GetSuitSymbol(int suit)
	{
		switch(suit)
		{
			case 0: return "\\cff0000H\\d"; // Heart (red)
			case 1: return "\\cff0000D\\d"; // Diamond (red)
			case 2: return "S"; // Spade
			case 3: return "C"; // Club
		}
		return "";
	}

	bool IsRedSuit(int suit)
	{
		return suit == 0 || suit == 1; // Hearts and Diamonds
	}

	int GetCardValue(int card)
	{
		// Aces are high (value 14)
		if (card == 1)
			return 14;
		return card;
	}

	bool PlayGame()
	{
		if (m_gameState != 0)
			return false;

		int bet = GetSelectedBetAmount();
		if (bet <= 0 || !CanAffordBet(m_selectedBet))
			return false;

		// Draw cards (1-13) and suits (0-3)
		m_playerCard = randi(13) + 1;
		m_dealerCard = randi(13) + 1;
		m_playerSuit = randi(4);
		m_dealerSuit = randi(4);

		// Lucky Leaf (farming herb): a losing dealer card is redrawn once, 25 %.
		int playerValue = GetCardValue(m_playerCard);
		int dealerValue = GetCardValue(m_dealerCard);
		if (dealerValue > playerValue && m_player !is null && m_player.HasMissionBuff("hwp_herb_lucky_leaf") && randf() < 0.25f)
		{
			m_dealerCard = randi(13) + 1;
			m_dealerSuit = randi(4);
			dealerValue = GetCardValue(m_dealerCard);
		}

		// Determine result (aces are high) - but don't apply gold yet
		if (playerValue > dealerValue)
			m_result = 1;
		else if (playerValue < dealerValue)
			m_result = -1;
		else
			m_result = 0;

		// Enter animation state (gold transfer happens after animation)
		m_gameState = 1;
		return true;
	}

	void FinalizeGame()
	{
		int bet = GetSelectedBetAmount();

		// Apply gold changes based on result
		if (m_result == 1)
			m_player.GiveMaterial(MaterialType::Gold, bet, true);
		else if (m_result == -1)
			m_player.GiveMaterial(MaterialType::Gold, -bet, true);

		// Move to result shown state
		m_gameState = 2;
	}

	void ResetGame()
	{
		m_gameState = 0;
		m_playerCard = 0;
		m_dealerCard = 0;
		m_playerSuit = 0;
		m_dealerSuit = 0;
	}

	string GetResultText()
	{
		int bet = GetSelectedBetAmount();
		switch(m_result)
		{
			case 1: return Resources::GetString(".hwp.gambler.win") + "\n" + Resources::GetString(".hwp.gambler.won", {{ "amount", bet }});
			case -1: return Resources::GetString(".hwp.gambler.lose") + "\n" + Resources::GetString(".hwp.gambler.lost", {{ "amount", bet }});
			case 0: return Resources::GetString(".hwp.gambler.tie");
		}
		return "";
	}

	// --- Gear reroll: 2000 gold x item level, or 1 bet token per 5 item levels
	// (fish sell for tokens), rerolls the modifiers of an equipped item. Base
	// item, quality, item level, upgrades and colours stay; only the rolled
	// modifiers (and therefore the name) change. Uniques/legendaries can't.
	int m_rerollSlot = 0;

	// Whatever is in the selected slot (generated items and uniques alike).
	Equipment::Equipment@ RerollSlotEquipment()
	{
		if (m_player is null || m_player.equipped is null)
			return null;
		if (m_rerollSlot < 0 || m_rerollSlot >= int(m_player.equipped.m_items.length()))
			return null;
		return m_player.equipped.m_items[m_rerollSlot];
	}

	// The generated item in the selected slot; null for an empty slot and for
	// uniques (Equipment::UniqueEquipment has no rolled modifiers).
	Equipment::Item@ RerollItem()
	{
		return cast<Equipment::Item>(RerollSlotEquipment());
	}

	// Legendary, quest, unique and cursed items keep their modifiers.
	bool IsRerollable(Equipment::Equipment@ eq)
	{
		auto item = cast<Equipment::Item>(eq);
		if (item is null)
			return false;
		int blocked = int(Item::Quality::Legendary) | int(Item::Quality::Quest) | int(Item::Quality::Unique) | int(Item::Quality::Cursed);
		return (int(item.quality) & blocked) == 0;
	}

	int RerollCost()
	{
		auto item = RerollItem();
		if (item is null)
			return 0;
		return HWP::Gambler::REROLL_PER_LEVEL * max(1, item.GetItemLevel());
	}

	// 1 token for item levels 1-5, 2 for 6-10, ...
	int RerollTokenCost()
	{
		auto item = RerollItem();
		if (item is null)
			return 0;
		int ilvl = max(1, item.GetItemLevel());
		return (ilvl + HWP::Gambler::TOKEN_LEVELS - 1) / HWP::Gambler::TOKEN_LEVELS;
	}

	int GetPlayerTokens()
	{
		return HWP::Market::Tokens(m_player);
	}

	void CycleRerollSlot(int dir)
	{
		int n = int(EquippedItemsSlots::Size);
		m_rerollSlot = (m_rerollSlot + dir + n) % n;
	}

	string RerollSlotName()
	{
		return Resources::GetString(".hwp.gambler.slot_" + m_rerollSlot);
	}

	bool CanReroll(bool tokens)
	{
		if (!IsRerollable(RerollSlotEquipment()))
			return false;
		if (tokens)
			return GetPlayerTokens() >= RerollTokenCost();
		return GetPlayerGold() >= RerollCost();
	}

	// tokens: pay in bet tokens instead of gold
	bool Reroll(bool tokens)
	{
		if (m_gameState == 1 || !CanReroll(tokens))
			return false;
		auto item = RerollItem();
		if (tokens)
		{
			if (!HWP::Market::SpendTokens(m_player, RerollTokenCost()))
				return false;
		}
		else
			m_player.GiveMaterial(MaterialType::Gold, -RerollCost(), true);

		Equipment::Generator gen;
		gen.m_slots = Equipment::Slot::None;        // keep the base item
		gen.m_qualities = Item::Quality::None;      // keep the quality
		gen.ModifyItem(item, null, null, true);     // clear + regenerate the modifiers at the item's own ilvl; Finalize keeps ilvl/upgrades/colours

		m_player.equipped.RefreshPlayerModifiers();
		m_player.equipped.m_isDirty = true;
		if (m_player.local)
		{
			SValueBuilder builder;
			Item::SaveItem(builder, item);
			(Network::Message("PlayerEquipmentEquip") << builder.Build() << m_rerollSlot).SendToAll();
		}
		GetHUD().RefreshSkillList(m_player);
		return true;
	}

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class HWPGamblerMenu : AWindowObject
{
	HWPGamblerShop@ m_gambler;
	TextWidget@ m_goldText;
	TextWidget@ m_resultText;
	SpriteWidget@ m_playerCardSprite;
	SpriteWidget@ m_dealerCardSprite;
	SpriteWidget@ m_playerDeckSprite;
	SpriteWidget@ m_dealerDeckSprite;
	TextWidget@ m_selectedBetText;
	ScalableSpriteButtonWidget@ m_playButton;
	ScalableSpriteButtonWidget@ m_sellButton;
	ScalableSpriteButtonWidget@ m_rerollButton;
	ScalableSpriteButtonWidget@ m_rerollTokenButton;
	TextWidget@ m_rerollText;
	TextWidget@ m_tokenText;
	array<ScalableSpriteButtonWidget@> m_betButtons;

	// Animation timing
	int m_animationTimer = 0;
	int ANIMATION_DURATION = 400;
	int REVEAL_DELAY = 200;

	HWPGamblerMenu(GUIBuilder@ b, HWPGamblerShop@ gambler)
	{
		super(b, "gui/hwp_gambler.gui");
		PauseGame(true, true);
		@m_gambler = gambler;

		@m_goldText = cast<TextWidget>(m_widget.GetWidgetById("gold-amount"));
		@m_resultText = cast<TextWidget>(m_widget.GetWidgetById("result-text"));
		@m_playerCardSprite = cast<SpriteWidget>(m_widget.GetWidgetById("player-card-sprite"));
		@m_dealerCardSprite = cast<SpriteWidget>(m_widget.GetWidgetById("dealer-card-sprite"));
		@m_playerDeckSprite = cast<SpriteWidget>(m_widget.GetWidgetById("player-deck-sprite"));
		@m_dealerDeckSprite = cast<SpriteWidget>(m_widget.GetWidgetById("dealer-deck-sprite"));
		@m_selectedBetText = cast<TextWidget>(m_widget.GetWidgetById("selected-bet"));
		@m_playButton = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("play-btn"));
		@m_sellButton = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("sell-btn"));
		@m_rerollButton = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("reroll-btn"));
		@m_rerollText = cast<TextWidget>(m_widget.GetWidgetById("reroll-item"));
		@m_rerollTokenButton = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("reroll-tok-btn"));
		@m_tokenText = cast<TextWidget>(m_widget.GetWidgetById("token-amount"));

		for (int i = 0; i < 5; i++)
		{
			auto btn = cast<ScalableSpriteButtonWidget>(m_widget.GetWidgetById("bet-btn-" + i));
			if (btn !is null)
				m_betButtons.insertLast(btn);
		}

		m_animationTimer = 0;
		UpdateUI();
	}

	void OnClose() override
	{
		PauseGame(false, true);
	}

	string FormatGold(int amount)
	{
		if (amount >= 1000000)
			return "" + (amount / 1000000) + "M";
		else if (amount >= 1000)
			return "" + (amount / 1000) + "K";
		return "" + amount;
	}

	string GetCardSpriteName(int card, int suit)
	{
		string suitChar;
		switch(suit)
		{
			case 0: suitChar = "h"; break;  // Hearts
			case 1: suitChar = "d"; break;  // Diamonds
			case 2: suitChar = "s"; break;  // Spades
			case 3: suitChar = "c"; break;  // Clubs
		}
		return "card-" + suitChar + "-" + card;
	}

	void StartCardAnimation()
	{
		// Show card sprites at deck positions with card-back
		if (m_playerCardSprite !is null)
		{
			m_playerCardSprite.m_visible = true;
			m_playerCardSprite.SetSprite("card-back");
			m_playerCardSprite.m_offset = vec2(10, 10);  // Start at deck position
			// Animate from deck (10,10) to reveal (80,10) with arc through (45,-20)
			m_playerCardSprite.Animate(WidgetVec2BezierAnimation("offset", vec2(10, 10), vec2(45, -20), vec2(80, 10), ANIMATION_DURATION));
		}

		if (m_dealerCardSprite !is null)
		{
			m_dealerCardSprite.m_visible = true;
			m_dealerCardSprite.SetSprite("card-back");
			m_dealerCardSprite.m_offset = vec2(-10, 10);  // Start at deck position (right-anchored)
			// Animate from deck (-10,10) to reveal (-80,10) with arc through (-45,-20)
			m_dealerCardSprite.Animate(WidgetVec2BezierAnimation("offset", vec2(-10, 10), vec2(-45, -20), vec2(-80, 10), ANIMATION_DURATION));
		}

		// Set timer for when to reveal cards
		m_animationTimer = ANIMATION_DURATION + REVEAL_DELAY;

		// Update button text
		if (m_playButton !is null)
			m_playButton.SetText(Resources::GetString(".hwp.gambler.drawing"));
	}

	void OnAnimationComplete()
	{
		// Reveal the actual cards
		if (m_playerCardSprite !is null)
			m_playerCardSprite.SetSprite(GetCardSpriteName(m_gambler.m_playerCard, m_gambler.m_playerSuit));
		if (m_dealerCardSprite !is null)
			m_dealerCardSprite.SetSprite(GetCardSpriteName(m_gambler.m_dealerCard, m_gambler.m_dealerSuit));

		// Finalize the game (apply gold changes)
		m_gambler.FinalizeGame();

		// Update UI to show result
		UpdateUI();
	}

	void ResetCardDisplay()
	{
		// Reset card positions and hide them
		if (m_playerCardSprite !is null)
		{
			m_playerCardSprite.m_offset = vec2(80, 10);
			m_playerCardSprite.m_visible = false;
		}
		if (m_dealerCardSprite !is null)
		{
			m_dealerCardSprite.m_offset = vec2(-80, 10);
			m_dealerCardSprite.m_visible = false;
		}

		m_animationTimer = 0;
	}

	bool Update(int ms, GameInput& gameInput, MenuInput& menuInput) override
	{
		bool result = AWindowObject::Update(ms, gameInput, menuInput);

		// Handle animation timing
		if (m_gambler.m_gameState == 1 && m_animationTimer > 0)
		{
			m_animationTimer -= ms;
			if (m_animationTimer <= 0)
			{
				OnAnimationComplete();
			}
		}

		return result;
	}

	void UpdateUI()
	{
		// Update gold display (show exact amount)
		if (m_goldText !is null)
			m_goldText.SetText("" + m_gambler.GetPlayerGold());

		if (m_tokenText !is null)
			m_tokenText.SetText(Resources::GetString(".hwp.gambler.tokens", { { "n", m_gambler.GetPlayerTokens() } }));

		// Sell button: what the wares in the player's bag are worth (crops and
		// herbs in gold, fish in bet tokens)
		if (m_sellButton !is null)
		{
			auto worth = HWP::Market::Worth(m_gambler.m_player);
			if (worth.count <= 0)
				m_sellButton.SetText(Resources::GetString(".hwp.gambler.sell_none"));
			else
				m_sellButton.SetText(Resources::GetString(".hwp.gambler.sell_wares", { { "count", worth.count }, { "price", HWP::Market::Price(worth.gold, worth.tokens, true) } }));
		}

		// Reroll row: the equipped item in the selected slot and its price
		if (m_rerollText !is null)
		{
			auto eq = m_gambler.RerollSlotEquipment();
			auto item = m_gambler.RerollItem();
			if (eq is null)
				m_rerollText.SetText(Resources::GetString(".hwp.gambler.reroll_empty", { { "slot", m_gambler.RerollSlotName() } }));
			else if (!m_gambler.IsRerollable(eq))
				m_rerollText.SetText(Resources::GetString(".hwp.gambler.reroll_fixed", {
					{ "slot", m_gambler.RerollSlotName() }, { "name", eq.GetName() } }));
			else
				m_rerollText.SetText(Resources::GetString(".hwp.gambler.reroll_item", {
					{ "slot", m_gambler.RerollSlotName() }, { "name", item.GetName() }, { "ilvl", item.GetItemLevel() } }));
		}
		if (m_rerollButton !is null)
		{
			int cost = m_gambler.RerollCost();
			if (cost <= 0)
				m_rerollButton.SetText(Resources::GetString(".hwp.gambler.reroll"));
			else
				m_rerollButton.SetText(Resources::GetString(".hwp.gambler.reroll_cost", { { "gold", FormatGold(cost) } }));
		}
		if (m_rerollTokenButton !is null)
		{
			int tokens = m_gambler.RerollTokenCost();
			if (tokens <= 0)
				m_rerollTokenButton.SetText(Resources::GetString(".hwp.gambler.reroll_tokens_none"));
			else
				m_rerollTokenButton.SetText(Resources::GetString(".hwp.gambler.reroll_tokens", { { "n", tokens } }));
		}

		// Update selected bet display
		if (m_selectedBetText !is null)
			m_selectedBetText.SetText(FormatGold(m_gambler.GetSelectedBetAmount()) + " " + Resources::GetString(".hwp.gambler.gold"));

		// Update bet button states
		for (int i = 0; i < int(m_betButtons.length()); i++)
		{
			if (m_betButtons[i] !is null)
			{
				bool isSelected = (i == m_gambler.m_selectedBet);
				m_betButtons[i].SetChecked(isSelected);
			}
		}

		// Update card displays and button text based on state
		if (m_gambler.m_gameState == 0)
		{
			// Betting state - reveal slots are empty
			if (m_playerCardSprite !is null)
				m_playerCardSprite.m_visible = false;
			if (m_dealerCardSprite !is null)
				m_dealerCardSprite.m_visible = false;

			if (m_resultText !is null)
				m_resultText.SetText(Resources::GetString(".hwp.gambler.bet_prompt"));

			if (m_playButton !is null)
				m_playButton.SetText(Resources::GetString(".hwp.gambler.flip"));
		}
		else if (m_gambler.m_gameState == 1)
		{
			// Animating state - button shows Drawing...
			if (m_resultText !is null)
				m_resultText.SetText(Resources::GetString(".hwp.gambler.drawing_cards"));

			if (m_playButton !is null)
				m_playButton.SetText(Resources::GetString(".hwp.gambler.drawing"));
		}
		else if (m_gambler.m_gameState == 2)
		{
			// Result shown state
			if (m_playerCardSprite !is null)
				m_playerCardSprite.SetSprite(GetCardSpriteName(m_gambler.m_playerCard, m_gambler.m_playerSuit));
			if (m_dealerCardSprite !is null)
				m_dealerCardSprite.SetSprite(GetCardSpriteName(m_gambler.m_dealerCard, m_gambler.m_dealerSuit));

			if (m_resultText !is null)
				m_resultText.SetText(m_gambler.GetResultText());

			if (m_playButton !is null)
				m_playButton.SetText(Resources::GetString(".hwp.gambler.reshuffle"));
		}
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
		{
			m_manager.CloseWindow(this);
			return;
		}

		if (name == "sell")
		{
			if (m_gambler.m_gameState == 1)
				return;
			auto sale = HWP::Market::Sell(m_gambler.m_player);
			if (sale.count > 0 && m_resultText !is null)
				m_resultText.SetText(Resources::GetString(".hwp.gambler.sold", { { "price", HWP::Market::Price(sale.gold, sale.tokens) } }));
			UpdateUI();
			return;
		}

		if (name == "reroll-prev" || name == "reroll-next")
		{
			m_gambler.CycleRerollSlot(name == "reroll-prev" ? -1 : 1);
			UpdateUI();
			return;
		}

		if (name == "reroll" || name == "reroll-tokens")
		{
			if (m_gambler.m_gameState == 1)
				return;
			bool tokens = name == "reroll-tokens";
			auto before = m_gambler.RerollSlotEquipment();
			bool ok = m_gambler.Reroll(tokens);
			if (m_resultText !is null)
			{
				if (ok)
					m_resultText.SetText(Resources::GetString(".hwp.gambler.rerolled", { { "name", before.GetName() } }));
				else if (before is null)
					m_resultText.SetText(Resources::GetString(".hwp.gambler.reroll_nothing"));
				else if (!m_gambler.IsRerollable(before))
					m_resultText.SetText(Resources::GetString(".hwp.gambler.reroll_legendary"));
				else if (tokens)
					m_resultText.SetText(Resources::GetString(".hwp.gambler.reroll_poor_tokens", { { "n", m_gambler.RerollTokenCost() } }));
				else
					m_resultText.SetText(Resources::GetString(".hwp.gambler.reroll_poor", { { "gold", m_gambler.RerollCost() } }));
			}
			UpdateUI();
			return;
		}

		if (name == "play")
		{
			if (m_gambler.m_gameState == 0)
			{
				if (m_gambler.PlayGame())
				{
					StartCardAnimation();
				}
			}
			else if (m_gambler.m_gameState == 2)
			{
				m_gambler.ResetGame();
				ResetCardDisplay();
				UpdateUI();
			}
			// Ignore clicks during animation (state 1)
			return;
		}

		// Bet selection buttons
		for (int i = 0; i < 5; i++)
		{
			if (name == "bet-" + i)
			{
				if (m_gambler.m_gameState == 0)
				{
					m_gambler.SelectBet(i);
					UpdateUI();
				}
				return;
			}
		}
	}
}
