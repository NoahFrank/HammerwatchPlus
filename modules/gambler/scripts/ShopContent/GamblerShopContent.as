// Gambler NPC - Higher/Lower Card Game
// Player bets gold, draws a card against the dealer
// Higher wins (double bet), Lower loses (lose bet), Tie (no change)

class GamblerShopContent : AShopContent
{
	array<int> m_betAmounts = { 100, 1000, 10000, 100000, 1000000 };
	int m_selectedBet = 0;
	int m_playerCard = 0;
	int m_dealerCard = 0;
	int m_playerSuit = 0;
	int m_dealerSuit = 0;
	int m_gameState = 0; // 0 = betting, 1 = animating, 2 = result shown
	int m_result = 0; // -1 = lose, 0 = tie, 1 = win

	GamblerShopContent() {}
	GamblerShopContent(UnitPtr u, SValue& params) { super(u, params); }

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
		@m_window = GamblerMenu(guiBuilder, this);
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

		// Determine result (aces are high) - but don't apply gold yet
		int playerValue = GetCardValue(m_playerCard);
		int dealerValue = GetCardValue(m_dealerCard);
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
			case 1: return Resources::GetString(".dialogue.gambler.win") + "\n\\c00ff00+" + bet + " Gold\\d";
			case -1: return Resources::GetString(".dialogue.gambler.lose") + "\n\\cff0000-" + bet + " Gold\\d";
			case 0: return Resources::GetString(".dialogue.gambler.tie");
		}
		return "";
	}

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class GamblerMenu : AWindowObject
{
	GamblerShopContent@ m_gambler;
	TextWidget@ m_goldText;
	TextWidget@ m_resultText;
	SpriteWidget@ m_playerCardSprite;
	SpriteWidget@ m_dealerCardSprite;
	SpriteWidget@ m_playerDeckSprite;
	SpriteWidget@ m_dealerDeckSprite;
	TextWidget@ m_selectedBetText;
	ScalableSpriteButtonWidget@ m_playButton;
	array<ScalableSpriteButtonWidget@> m_betButtons;

	// Animation timing
	int m_animationTimer = 0;
	int ANIMATION_DURATION = 400;
	int REVEAL_DELAY = 200;

	GamblerMenu(GUIBuilder@ b, GamblerShopContent@ gambler)
	{
		super(b, "gui/gambler.gui");
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
			m_playButton.SetText("Drawing...");
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

		// Update selected bet display
		if (m_selectedBetText !is null)
			m_selectedBetText.SetText(FormatGold(m_gambler.GetSelectedBetAmount()) + " gold");

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
				m_resultText.SetText(Resources::GetString(".dialogue.gambler.bet.prompt"));

			if (m_playButton !is null)
				m_playButton.SetText("Flip Cards!");
		}
		else if (m_gambler.m_gameState == 1)
		{
			// Animating state - button shows Drawing...
			if (m_resultText !is null)
				m_resultText.SetText("Drawing cards...");

			if (m_playButton !is null)
				m_playButton.SetText("Drawing...");
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
				m_playButton.SetText("Reshuffle");
		}
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
		{
			m_manager.CloseWindow(this);
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
