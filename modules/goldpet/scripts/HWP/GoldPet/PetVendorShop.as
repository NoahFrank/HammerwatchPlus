// Pet vendor: sells and upgrades the gold collector pet. Interact class of
// actors/npcs/town/hwp_pet_vendor.unit. The char flags has_gold_pet,
// has_gold_pet_tier_2 and has_gold_pet_tier_3 keep their original names so
// characters from the standalone GoldCollectorPet mod keep their pet.

// Pet helpers shared with the module
namespace HWP { namespace GoldPet
{
	// Get the player's current pet tier (0 = no pet, 1-3 = tier level)
	int GetPlayerPetTier(PlayerRecord@ player)
	{
		if (player.HasCharFlag(HashString("has_gold_pet_tier_3")))
			return 3;
		if (player.HasCharFlag(HashString("has_gold_pet_tier_2")))
			return 2;
		if (player.HasCharFlag(HashString("has_gold_pet")))
			return 1;
		return 0;
	}

	bool IsPetAliveForPlayer(PlayerRecord@ player)
	{
		if (player is null || player.actor is null)
			return false;

		vec2 playerPos = xy(player.actor.m_unit.GetPosition());
		auto units = g_scene.FetchActorsWithTeam(player.actor.Team, playerPos, 9999);
		for (uint i = 0; i < units.length(); i++)
		{
			auto behavior = cast<HWPGoldCollectorPet>(units[i].GetScriptBehavior());
			if (behavior !is null && behavior.m_ownerRecord !is null && behavior.m_ownerRecord.peer == player.peer)
				return true;
		}
		return false;
	}

	void DespawnPetForPlayer(PlayerRecord@ player)
	{
		if (player is null || player.actor is null)
			return;

		vec2 playerPos = xy(player.actor.m_unit.GetPosition());
		auto units = g_scene.FetchActorsWithTeam(player.actor.Team, playerPos, 9999);
		for (uint i = 0; i < units.length(); i++)
		{
			auto behavior = cast<HWPGoldCollectorPet>(units[i].GetScriptBehavior());
			if (behavior !is null && behavior.m_ownerRecord !is null && behavior.m_ownerRecord.peer == player.peer)
			{
				units[i].Destroy();
				return;
			}
		}
	}

	void SpawnPetForPlayer(PlayerRecord@ player, int tier = -1)
	{
		if (player is null || player.actor is null)
			return;

		// Use current tier if not specified
		if (tier < 0)
			tier = GetPlayerPetTier(player);

		if (tier <= 0)
			return;

		auto prod = Resources::GetUnitProducer("actors/pets/hwp_gold_collector_pet.unit");
		if (prod is null)
		{
			HWP::LogError("goldpet", "missing actors/pets/hwp_gold_collector_pet.unit");
			return;
		}

		vec3 spawnPos = player.actor.m_unit.GetPosition();
		auto petUnit = prod.Produce(g_scene, spawnPos);

		auto petBehavior = cast<HWPGoldCollectorPet>(petUnit.GetScriptBehavior());
		if (petBehavior !is null)
		{
			petBehavior.ConfigureForTier(tier);

			// Determine if this is a husk (non-server spawned unit)
			bool isHusk = !Network::IsServer();
			petBehavior.Initialize(player.actor, 1.0f, isHusk, 0);

			// Server broadcasts ownership to all clients
			if (Network::IsServer())
			{
				(Network::Message("SetOwnedUnit") << petUnit << player.actor.m_unit << 1.0f << 0).SendToAll();
			}
		}
	}
} }

class HWPPetVendorShop : AShopContent
{
	// Tier costs
	int m_tier1Cost = 10000;
	int m_tier2Cost = 50000;
	int m_tier3Cost = 150000;

	HWPPetVendorShop() {}
	HWPPetVendorShop(UnitPtr u, SValue& params)
	{
		super(u, params);
	}

	bool CanInteract(PlayerRecord@ player) override
	{
		if (!player.local)
			return true;
		return CheckConditionals(m_conditionals, player);
	}

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		@m_window = HWPPetVendorMenu(guiBuilder, this);
		return m_window;
	}

	string GetName() override { return "pet_vendor"; }

	int GetPlayerGold()
	{
		return m_player.GetMaterial(MaterialType::Gold);
	}

	int GetPlayerPetTier()
	{
		return HWP::GoldPet::GetPlayerPetTier(m_player);
	}

	// Returns: -1 (not built), 0 (tier 1), 1 (tier 2), 2 (tier 3)
	int GetHunterLodgeTier()
	{
		if (g_currTownRecord is null)
			return -1;
		return g_currTownRecord.GetVariationOnBuilding(HashString("hunters_cabin"));
	}

	bool IsPetAlive()
	{
		return HWP::GoldPet::IsPetAliveForPlayer(m_player);
	}

	// Tier 1 purchase checks
	bool CanAffordTier1()
	{
		return GetPlayerGold() >= m_tier1Cost;
	}

	bool CanBuyTier1()
	{
		if (GetPlayerPetTier() >= 1)
			return false;  // Already have tier 1+
		return CanAffordTier1();
	}

	// Tier 2 purchase checks
	bool HasLodgeForTier2()
	{
		return GetHunterLodgeTier() >= 1;  // Need lodge variation 1 (tier 2)
	}

	bool CanAffordTier2()
	{
		return GetPlayerGold() >= m_tier2Cost;
	}

	bool CanBuyTier2()
	{
		if (GetPlayerPetTier() < 1)
			return false;  // Need tier 1 first
		if (GetPlayerPetTier() >= 2)
			return false;  // Already have tier 2+
		if (!HasLodgeForTier2())
			return false;  // Need Hunter Lodge tier 2
		return CanAffordTier2();
	}

	// Tier 3 purchase checks
	bool HasLodgeForTier3()
	{
		return GetHunterLodgeTier() >= 2;  // Need lodge variation 2 (tier 3)
	}

	bool CanAffordTier3()
	{
		return GetPlayerGold() >= m_tier3Cost;
	}

	bool CanBuyTier3()
	{
		if (GetPlayerPetTier() < 2)
			return false;  // Need tier 2 first
		if (GetPlayerPetTier() >= 3)
			return false;  // Already have tier 3
		if (!HasLodgeForTier3())
			return false;  // Need Hunter Lodge tier 3
		return CanAffordTier3();
	}

	bool BuyTier1()
	{
		if (!CanBuyTier1())
			return false;

		m_player.GiveMaterial(MaterialType::Gold, -m_tier1Cost, true);
		m_player.SetCharFlag(HashString("has_gold_pet"), true);
		HWP::GoldPet::SpawnPetForPlayer(m_player, 1);
		return true;
	}

	bool BuyTier2()
	{
		if (!CanBuyTier2())
			return false;

		m_player.GiveMaterial(MaterialType::Gold, -m_tier2Cost, true);
		m_player.SetCharFlag(HashString("has_gold_pet_tier_2"), true);

		// Respawn pet with new tier if currently active
		if (IsPetAlive())
		{
			HWP::GoldPet::DespawnPetForPlayer(m_player);
		}
		HWP::GoldPet::SpawnPetForPlayer(m_player, 2);
		return true;
	}

	bool BuyTier3()
	{
		if (!CanBuyTier3())
			return false;

		m_player.GiveMaterial(MaterialType::Gold, -m_tier3Cost, true);
		m_player.SetCharFlag(HashString("has_gold_pet_tier_3"), true);

		// Respawn pet with new tier if currently active
		if (IsPetAlive())
		{
			HWP::GoldPet::DespawnPetForPlayer(m_player);
		}
		HWP::GoldPet::SpawnPetForPlayer(m_player, 3);
		return true;
	}

	bool SummonPet()
	{
		int tier = GetPlayerPetTier();
		if (tier <= 0)
			return false;

		if (IsPetAlive())
			return false;

		HWP::GoldPet::SpawnPetForPlayer(m_player, tier);
		return true;
	}

	void Save(SValueBuilder& builder) override { }
	void Load(SValue@ sval) override { }
}

class HWPPetVendorMenu : AWindowObject
{
	HWPPetVendorShop@ m_shop;
	TextWidget@ m_goldText;
	TextWidget@ m_tierStatusText;

	// Tier 1 widgets
	Widget@ m_tier1Section;
	TextWidget@ m_tier1ReqText;
	Widget@ m_buyTier1Button;

	// Tier 2 widgets
	Widget@ m_tier2Section;
	TextWidget@ m_tier2ReqText;
	Widget@ m_buyTier2Button;

	// Tier 3 widgets
	Widget@ m_tier3Section;
	TextWidget@ m_tier3ReqText;
	Widget@ m_buyTier3Button;

	// Summon button
	Widget@ m_summonButton;

	HWPPetVendorMenu(GUIBuilder@ b, HWPPetVendorShop@ shop)
	{
		super(b, "gui/hwp_goldpet_vendor.gui");
		PauseGame(true, true);
		@m_shop = shop;

		@m_goldText = cast<TextWidget>(m_widget.GetWidgetById("gold-amount"));
		@m_tierStatusText = cast<TextWidget>(m_widget.GetWidgetById("tier-status"));

		@m_tier1Section = m_widget.GetWidgetById("tier1-section");
		@m_tier1ReqText = cast<TextWidget>(m_widget.GetWidgetById("tier1-req"));
		@m_buyTier1Button = m_widget.GetWidgetById("buy-tier1");

		@m_tier2Section = m_widget.GetWidgetById("tier2-section");
		@m_tier2ReqText = cast<TextWidget>(m_widget.GetWidgetById("tier2-req"));
		@m_buyTier2Button = m_widget.GetWidgetById("buy-tier2");

		@m_tier3Section = m_widget.GetWidgetById("tier3-section");
		@m_tier3ReqText = cast<TextWidget>(m_widget.GetWidgetById("tier3-req"));
		@m_buyTier3Button = m_widget.GetWidgetById("buy-tier3");

		@m_summonButton = m_widget.GetWidgetById("summon-button");

		UpdateUI();
	}

	void OnClose() override
	{
		PauseGame(false, true);
	}

	void UpdateUI()
	{
		// Update gold display
		if (m_goldText !is null)
			m_goldText.SetText("" + m_shop.GetPlayerGold());

		int currentTier = m_shop.GetPlayerPetTier();
		bool petAlive = m_shop.IsPetAlive();

		// Update tier status
		if (m_tierStatusText !is null)
		{
			if (currentTier == 0)
				m_tierStatusText.SetText(Resources::GetString(".hwp.goldpet.tier_none"));
			else if (currentTier == 1)
				m_tierStatusText.SetText(Resources::GetString(".hwp.goldpet.tier_status_1"));
			else if (currentTier == 2)
				m_tierStatusText.SetText(Resources::GetString(".hwp.goldpet.tier_status_2"));
			else
				m_tierStatusText.SetText(Resources::GetString(".hwp.goldpet.tier_status_3"));
		}

		// Tier 1 section
		if (m_tier1Section !is null)
		{
			m_tier1Section.m_visible = (currentTier == 0);
		}
		if (m_buyTier1Button !is null)
		{
			m_buyTier1Button.m_visible = m_shop.CanBuyTier1();
		}
		if (m_tier1ReqText !is null)
		{
			if (!m_shop.CanAffordTier1())
				m_tier1ReqText.SetText(Resources::GetString(".hwp.goldpet.need_gold_1"));
			else
				m_tier1ReqText.SetText("");
		}

		// Tier 2 section
		if (m_tier2Section !is null)
		{
			m_tier2Section.m_visible = (currentTier >= 1 && currentTier < 3);
		}
		if (m_buyTier2Button !is null)
		{
			m_buyTier2Button.m_visible = (currentTier == 1);
		}
		if (m_tier2ReqText !is null)
		{
			if (currentTier < 1)
				m_tier2ReqText.SetText(Resources::GetString(".hwp.goldpet.need_tier_1"));
			else if (!m_shop.HasLodgeForTier2())
				m_tier2ReqText.SetText(Resources::GetString(".hwp.goldpet.need_lodge_2"));
			else if (!m_shop.CanAffordTier2())
				m_tier2ReqText.SetText(Resources::GetString(".hwp.goldpet.need_gold_2"));
			else if (currentTier >= 2)
				m_tier2ReqText.SetText(Resources::GetString(".hwp.goldpet.tier_owned"));
			else
				m_tier2ReqText.SetText(Resources::GetString(".hwp.goldpet.tier_ready"));
		}

		// Tier 3 section
		if (m_tier3Section !is null)
		{
			m_tier3Section.m_visible = (currentTier >= 2);
		}
		if (m_buyTier3Button !is null)
		{
			m_buyTier3Button.m_visible = (currentTier == 2);
		}
		if (m_tier3ReqText !is null)
		{
			if (currentTier < 2)
				m_tier3ReqText.SetText(Resources::GetString(".hwp.goldpet.need_tier_2"));
			else if (!m_shop.HasLodgeForTier3())
				m_tier3ReqText.SetText(Resources::GetString(".hwp.goldpet.need_lodge_3"));
			else if (!m_shop.CanAffordTier3())
				m_tier3ReqText.SetText(Resources::GetString(".hwp.goldpet.need_gold_3"));
			else if (currentTier >= 3)
				m_tier3ReqText.SetText(Resources::GetString(".hwp.goldpet.tier_owned"));
			else
				m_tier3ReqText.SetText(Resources::GetString(".hwp.goldpet.tier_ready"));
		}

		// Summon button
		if (m_summonButton !is null)
		{
			m_summonButton.m_visible = (currentTier > 0 && !petAlive);
		}
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
		{
			m_manager.CloseWindow(this);
			return;
		}

		if (name == "buy-tier1")
		{
			if (m_shop.BuyTier1())
			{
				UpdateUI();
				m_manager.CloseWindow(this);
			}
			return;
		}

		if (name == "buy-tier2")
		{
			if (m_shop.BuyTier2())
			{
				UpdateUI();
				m_manager.CloseWindow(this);
			}
			return;
		}

		if (name == "buy-tier3")
		{
			if (m_shop.BuyTier3())
			{
				UpdateUI();
				m_manager.CloseWindow(this);
			}
			return;
		}

		if (name == "summon")
		{
			if (m_shop.SummonPet())
			{
				UpdateUI();
				m_manager.CloseWindow(this);
			}
			return;
		}
	}
}
