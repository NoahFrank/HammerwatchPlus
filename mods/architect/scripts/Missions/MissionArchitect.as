// HWP override of scripts/Missions/MissionArchitect.as (see mods/architect/README.md).
// Every change is marked HWP; pristine copy: MissionArchitect.as.orig
float CalcArchitectCostMul(int numBuffs, int numDebuffs)
{
	float mul = 1.0f;
	
	int archLvl = g_currTownRecord.GetVariationOnBuilding(HashString("architect"));
	
	if (archLvl >= 1)
		mul = (pow(float(max(1, numBuffs)), 1.6f) - 1) / 7.0f + 1.0f;
	else
		mul = (pow(float(max(1, numBuffs)), 1.8f) - 1) / 6.0f + 1.0f;
	
	mul -= pow(float(numDebuffs), 1.5f) / 2.0f;
	
	return max(0.0f, mul);
}

class SelectArchitectLoadout : MissionGUILoadout
{
	PlayerRecord@ m_player;
	Widget@ m_scroll;
	Widget@ m_buffTemplate;
	uint32 m_buffSet;
	
	array<uint> m_buffs;
	array<uint8> m_payers; // HWP: peer that pays for m_buffs[i] (0 = host, split when architect.split is on)


	SelectArchitectLoadout(SValue& params)
	{
		super(params);
		
		m_buffSet = HashString(GetParamString(UnitPtr(), params, "buff-set", true));
	}


	bool BuildGUI(PlayerRecord@ plr, MissionLoadoutMenu@ menu, Widget@ segment, int yNavPos) override
	{
		auto currMissionDef = MissionDef::Get(MissionManager::g_module.m_missionDefHash);
		if (currMissionDef is null || (currMissionDef.m_id != "dark_citadel" && currMissionDef.m_id != "mega_dungeon"))
			return false;
		
		if (!MissionGUILoadout::BuildGUI(plr, menu, segment, yNavPos))
			return false;
		
		@m_player = plr;
		@m_buffTemplate = segment.GetWidgetById("template-buff");
		auto container = segment.GetWidgetById("container");

		auto rect = cast<AInteractableWidget>(segment.GetWidgetById("rect").Clone());
		rect.m_visible = true;
		rect.m_func = m_id + " open";
		rect.m_enabled = true; // HWP: every player may pick (and pay for) alterations
		rect.m_navPos = ivec2(0, yNavPos);

		auto group = rect.GetWidgetById("group");
		auto scroll = group.GetWidgetById("scroll");
		@m_scroll = scroll;
		
		// HWP: pull the party's current picks from the host. On the host the
		// request is answered synchronously - before this menu is registered
		// with the window manager, so the sync cannot find it - hence the list
		// is seeded from the synced state right here on every machine.
		HWP::Architect::RequestState();
		m_buffs.removeRange(0, m_buffs.length());
		m_payers.removeRange(0, m_payers.length());
		for (uint i = 0; i < HWP::Architect::g_ids.length(); i++)
		{
			m_buffs.insertLast(uint(HWP::Architect::g_ids[i]));
			m_payers.insertLast(uint8(i < HWP::Architect::g_payers.length() ? HWP::Architect::g_payers[i] : 0));
		}

		int width = 0;
		for (uint i = 0; i < m_buffs.length(); i++)
		{
			auto buff = MissionBuff::Get(m_buffs[i]);
			if (buff is null) // HWP: unknown id from a mismatched mod version
				continue;

			auto buffW = m_buffTemplate.Clone();
			buffW.m_visible = true;
			buffW.SetID(buff.m_id);

			auto text = cast<TextWidget>(buffW);
			text.SetText(HWPBuffLabel(i)); // HWP: "- name (payer)"
			text.m_width = scroll.m_width / 2;
			
			scroll.AddChild(buffW);
			width += buffW.m_width;
		}
		
		container.AddChild(rect);
		m_width = max(m_width, width);
		
		if (MissionBuff::GetMissionBuffs(plr, m_buffSet).length() <= 0)
			return false;
		
		return true;
	}

	void Refresh()
	{
		m_scroll.ClearChildren();

		for (uint i = 0; i < m_buffs.length(); i++)
		{
			auto buff = MissionBuff::Get(m_buffs[i]);
			if (buff is null) // HWP
				continue;

			auto buffW = m_buffTemplate.Clone();
			buffW.m_visible = true;
			buffW.SetID(buff.m_id);

			auto text = cast<TextWidget>(buffW);
			text.SetText(HWPBuffLabel(i)); // HWP: "- name (payer)"
			text.m_width = m_scroll.m_width / 2;
			
			m_scroll.AddChild(buffW);
		}

		m_menu.RefreshCost();
	}

	void OnPlay() override
	{
		// HWP: everyone pays their own share - sponsored picks in full, the
		// host's picks split evenly across the party when architect.split is on.
		auto cost = CalcMyCost();
		HWP::Architect::OnMissionStarted();

		if (!cost.CanAfford(m_player))
		{
			// The menu hides Ready while the share is unaffordable and un-readies
			// a player whose share changes, so this is a force start racing a
			// pick. Nobody gets alterations they did not pay for, and nobody
			// goes negative.
			HWP::LogError("architect", m_player.GetName() + " cannot afford the architect share at start; alterations skipped");
			return;
		}

		if (Network::IsServer())
			cost.Spend(m_player);
		else
		{
			for (uint j = 0; j < cost.m_cost.length(); j += 2)
				m_player.materials[cost.m_cost[j]] -= cost.m_cost[j + 1];
		}

		for (uint i = 0; i < m_buffs.length(); i++)
		{
			auto missionBuff = MissionBuff::Get(m_buffs[i]);
			if (missionBuff is null)
				continue;
			
			m_player.architectBuffs.insertLast(missionBuff);
		}
	}

	ShopCost@ GetCost() override
	{
		return CalcMyCost(); // HWP: the local player's share, on clients too
	}

	// HWP: what the local player pays. Cost multiplier counts every pick no
	// matter who pays, like vanilla; rounding is per item, shares round up.
	ShopCost@ CalcMyCost()
	{
		int numBuffs = 0;
		int numDebuffs = 0;
		for (uint i = 0; i < m_buffs.length(); i++)
		{
			auto missionBuff = MissionBuff::Get(m_buffs[i]);
			if (missionBuff is null)
				continue;
			if (missionBuff.m_cost.GetTotalCost() == 0)
				numDebuffs++;
			else
				numBuffs++;
		}
		float mul = CalcArchitectCostMul(numBuffs, numDebuffs);

		uint8 me = uint8(m_player.peer);
		int players = HWP::Architect::ActivePlayers();
		auto cost = ShopCost();
		for (uint i = 0; i < m_buffs.length(); i++)
		{
			auto missionBuff = MissionBuff::Get(m_buffs[i]);
			if (missionBuff is null)
				continue;
			uint8 payer = i < m_payers.length() ? m_payers[i] : 0;
			bool split = payer == 0 && HWP::Architect::g_split && players > 1;
			if (!split && payer != me)
				continue;

			for (uint j = 0; j + 1 < missionBuff.m_cost.m_cost.length(); j += 2)
			{
				int amount = int(missionBuff.m_cost.m_cost[j + 1] * mul);
				if (split)
					amount = (amount + players - 1) / players;
				if (amount > 0)
					cost.AddCost(MaterialType(missionBuff.m_cost.m_cost[j]), amount);
			}
		}
		return cost;
	}

	// HWP: list label with the payer when more than one player is around
	string HWPBuffLabel(uint i)
	{
		auto buff = MissionBuff::Get(m_buffs[i]);
		string label = "- " + (buff is null ? "?" : Resources::GetString(buff.m_name));
		uint8 payer = i < m_payers.length() ? m_payers[i] : 0;
		if (HWP::Architect::ShowPayer())
			label += " (" + HWP::Architect::PayerName(payer) + ")";
		return label;
	}

	// HWP: the host's merged pick list
	void HWPSync(array<int>@ ids, array<int>@ payers)
	{
		int before = CalcMyCost().GetTotalCost();
		m_buffs.removeRange(0, m_buffs.length());
		m_payers.removeRange(0, m_payers.length());
		for (uint i = 0; i < ids.length(); i++)
		{
			m_buffs.insertLast(uint(ids[i]));
			m_payers.insertLast(uint8(i < payers.length() ? payers[i] : 0));
		}
		if (m_scroll !is null)
			Refresh();
		else if (m_menu !is null)
			m_menu.RefreshCost();

		// a share that changed under a readied player needs a fresh look (and a
		// fresh affordability check) before the host can start
		if (m_menu !is null && !Network::IsServer() && CalcMyCost().GetTotalCost() != before
			&& m_menu.GetLoadoutStatus() == MissionLoadoutStatus::Ready)
			m_menu.SetStatus(MissionLoadoutStatus::NotReady);
	}

	//bool UpdateTooltip(WindowManager@ manager) override
	//{
	//	for (uint i = 0; i < m_buttons.length(); i++)
	//	{
	//		if (m_buttons[i].m_hovering)
	//		{
	//			auto buff = MissionBuff::Get(m_buttons[i].m_id);
	//			if (buff !is null)
	//			{
	//				auto iconFrame = ScriptSprite(Resources::GetTexture2D("gui/gui.png"), vec4(76, 210, 28, 28));
	//				string desc = buff.m_description;
	//				if (buff.m_cost !is null)
	//					desc += "\n\n" + buff.m_cost.GetText(m_player);
					
	//				manager.SetTooltip(
	//					CreateTitledTooltip(Resources::GetSValue("gui/variable/itemtooltip_common.sval"),
	//						buff.m_name,
	//						desc,
	//						buff.m_icon,
	//						iconFrame)
	//				);
					
					
	//			}
				
	//			return true;
	//		}
	//	}
		
	//	return false;
	//}

	void NetSync(array<int>@ buffs)
	{
		// vanilla host-only sync; HWP keeps it working (all paid by the host)
		m_buffs.removeRange(0, m_buffs.length());
		m_payers.removeRange(0, m_payers.length());
		for (uint i = 0; i < buffs.length(); i++)
		{
			m_buffs.insertLast(int(buffs[i]));
			m_payers.insertLast(0);
		}

		m_menu.RefreshCost();
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		print("MissionArchitect::" + name);
		
		auto parse = name.split(" ");
		if (parse[1] == "open")
		{
			cast<BaseGameMode>(g_gameMode).m_windowManager.AddWindowObject(
				SelectArchitectSelector(this));
		}
	}

}

class SelectArchitectSelector : AWindowObject
{
	SelectArchitectLoadout@ m_host;
	ITooltip@ m_selectedTooltip;
	Widget@ m_compareAnchor;

	array<uint> m_buffs;

	bool m_changed;

	SelectArchitectSelector(SelectArchitectLoadout@ host)
	{
		super(g_gameMode.m_guiBuilder, "gui/mission_loadout/architect_picker.gui");

		@m_host = host;

		@m_compareAnchor = m_widget.GetWidgetById("compare-anchor");

		auto templateW = m_widget.GetWidgetById("template");
		auto scroll = m_widget.GetWidgetById("scroll");

		auto buffs = MissionBuff::GetMissionBuffs(host.m_player, m_host.m_buffSet);
		for (uint i = 0; i < buffs.length(); i++)
		{
			auto buffW = cast<AInteractableWidget>(templateW.Clone());
			buffW.m_visible = true;
			buffW.SetID(buffs[i].m_id);
			buffW.m_navPos = ivec2(0, i);
			
			auto text = cast<TextWidget>(buffW.GetWidgetById("text"));
			text.SetText(Resources::GetString(buffs[i].m_name));
			
			auto cost = cast<TextWidget>(buffW.GetWidgetById("cost"));
			cost.m_textWidth = 55;
			cost.SetText(buffs[i].m_cost.GetText(host.m_player));

			HWPMarkWidget(buffW, buffs[i].m_idHash, Resources::GetString(buffs[i].m_name)); // HWP

			scroll.AddChild(buffW);
		}

		for (uint i = 0; i < m_host.m_buffs.length(); i++)
			m_buffs.insertLast(m_host.m_buffs[i]);
		
		RefreshCost();

		if (m_host.m_buffs.length() > 0)
			UpdateSelectedTooltip();

		@m_input.m_menuAdditionalOnPressed = WindowInput::OnFunc(this.Apply);
	}

	void RefreshKeybinds(ControlMap@ currMap) override
	{
		if (m_navigationBar is null)
			return;

		auto currInteractable = m_input.GetCurrentInteractable();
		if (currInteractable is null)
			return;

		array<string>@ rawTexts = currInteractable.NavigationBarText();
		array<KeyNavigationText@> navTexts;
		for (uint i = 0; i < rawTexts.length(); i++)
			navTexts.insertLast(KeyNavigationText(m_navigationBar.m_font.BuildText(rawTexts[i])));

		navTexts.insertLast(KeyNavigationText(m_navigationBar.m_font.BuildText(FormatKeyName(GetActionBinding("MenuAdditional")) + " " + Resources::GetString(".menu.nav.apply")), WindowInput::OnFunc(this.Apply)));

		m_navigationBar.BuildBar(navTexts, this);
	}

	void OnInteractableIndexChanged() override
	{
		auto currInteractable = m_input.GetCurrentInteractable();
		if (currInteractable is null)
			return;

		array<string>@ rawTexts = currInteractable.NavigationBarText();
		array<KeyNavigationText@> navTexts;
		for (uint i = 0; i < rawTexts.length(); i++)
			navTexts.insertLast(KeyNavigationText(m_navigationBar.m_font.BuildText(rawTexts[i])));

		navTexts.insertLast(KeyNavigationText(m_navigationBar.m_font.BuildText(FormatKeyName(GetActionBinding("MenuAdditional")) + " " + Resources::GetString(".menu.nav.apply")), WindowInput::OnFunc(this.Apply)));

		m_navigationBar.BuildBar(navTexts, this);
	}

	// HWP: checkmark + "(payer)" suffix for one row of the picker
	void HWPMarkWidget(Widget@ buffW, uint id, const string &in baseName)
	{
		int idx = m_host.m_buffs.find(id);
		buffW.GetWidgetById("selected").m_visible = idx > -1;
		auto text = cast<TextWidget>(buffW.GetWidgetById("text"));
		if (text is null)
			return;
		string label = baseName;
		if (idx > -1)
		{
			uint8 payer = uint(idx) < m_host.m_payers.length() ? m_host.m_payers[idx] : 0;
			if (HWP::Architect::ShowPayer())
				label += " (" + HWP::Architect::PayerName(payer) + ")";
		}
		text.SetText(label);
	}

	// HWP: the host sent a new merged list while the picker is open
	void RefreshFromHost()
	{
		auto buffs = MissionBuff::GetMissionBuffs(m_host.m_player, m_host.m_buffSet);
		auto list = m_widget.GetWidgetById("scroll");
		for (uint i = 0; i < list.m_children.length(); i++)
		{
			auto child = list.m_children[i];
			string baseName;
			for (uint j = 0; j < buffs.length(); j++)
				if (buffs[j].m_idHash == child.m_idHash)
					baseName = Resources::GetString(buffs[j].m_name);
			HWPMarkWidget(child, child.m_idHash, baseName);
		}

		m_buffs.removeRange(0, m_buffs.length());
		for (uint i = 0; i < m_host.m_buffs.length(); i++)
			m_buffs.insertLast(m_host.m_buffs[i]);

		RefreshCost();
		UpdateSelectedTooltip();
	}

	void RefreshCost()
	{
		auto cost = cast<TextWidget>(m_widget.GetWidgetById("total-cost"));
		cost.SetText(m_host.CalcMyCost().GetText(m_host.m_player)); // HWP: your share
		
		
		int numBuffs = 0;
		int numDebuffs = 0;
		for (uint i = 0; i < m_buffs.length(); i++)
		{
			auto missionBuff = MissionBuff::Get(m_buffs[i]);
			if (missionBuff is null)
				continue;
			
			if (missionBuff.m_cost.GetTotalCost() == 0)
				numDebuffs++;
			else
				numBuffs++;
		}
		
		float mul = CalcArchitectCostMul(numBuffs, numDebuffs);
		auto costMul = cast<TextWidget>(m_widget.GetWidgetById("cost-mul"));
		costMul.SetText(Resources::GetString(".architect.cost_mul", {{ "mul", int(mul * 100.0f + 0.5f) + "%" }}));
	}

	void Draw(SpriteBatch& sb, int idt) override
	{
		AWindowObject::Draw(sb, idt);

		if (m_selectedTooltip !is null)
		{
			vec2 ttPos = m_compareAnchor.m_origin;
			m_selectedTooltip.Draw(sb, ttPos);
		}
	}

	void UpdateSelectedTooltip()
	{
	
		string title = Resources::GetString(".menu.loadout.alterations");
		string description;

		for (uint i = 0; i < m_buffs.length(); i++)
		{
			auto missionBuff = MissionBuff::Get(m_buffs[i]);
			if (missionBuff is null)
				continue;
			
			description += "- " + Resources::GetString(missionBuff.m_description);
			description += "\n\n";
		}

		if (description.isEmpty())
		{
			@m_selectedTooltip = null;
			return;
		}

		@m_selectedTooltip = CreateTitledTooltip(
			Resources::GetSValue("gui/variable/itemtooltip_common.sval"), 
			title, 
			description,
			null,
			null
		);
	}

	void Apply()
	{
		// HWP: picks are live-synced from the host; applying just closes
		m_manager.CloseTooltip();

		m_changed = false;
		m_closing = true;
	}

	bool Back() override
	{
		if (m_changed)
		{
			//g_gameMode.ShowDialog("exit", Resources::GetString(".option.prompt.settings_appy"), Resources::GetString(".menu.nav.save"), Resources::GetString(".menu.nav.revert"), this);
			Apply();
			return false;
		}

		return true;
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "hover")
		{
			auto buff = MissionBuff::Get(sender.m_idHash);
			if (buff !is null)
			{
				string desc = Resources::GetString(buff.m_description);
				if (buff.m_cost !is null)
					desc += "\n\n" + buff.m_cost.GetText(m_host.m_player);
				
				m_manager.SetTooltip(
					CreateTitledTooltip(Resources::GetSValue("gui/variable/itemtooltip_common.sval"),
						Resources::GetString(buff.m_name),
						desc,
						null,
						null)
				, true);
			}
		}
		else if (name == "select")
		{
			// HWP: toggle my own pick; the host merges everyone's picks and
			// syncs the list back (architect.sync -> RefreshFromHost)
			uint id = sender.m_idHash;
			uint8 me = uint8(Lobby::GetLocalPeer());
			int idx = m_host.m_buffs.find(id);
			if (idx > -1 && uint(idx) < m_host.m_payers.length() && m_host.m_payers[idx] != me)
				return; // someone else's pick, only they can remove it

			array<int> mine;
			for (uint i = 0; i < m_host.m_buffs.length(); i++)
			{
				if (i < m_host.m_payers.length() && m_host.m_payers[i] == me && m_host.m_buffs[i] != id)
					mine.insertLast(int(m_host.m_buffs[i]));
			}
			if (idx < 0)
				mine.insertLast(int(id));

			HWP::Architect::SendPicks(mine);
			m_changed = true;
		}
		else if (name == "exit yes")
			Apply();
		else if (name == "exit no")
			m_closing = true;
	}
}

class ToppleTowersTask : QueuedTasks::QueuedTask
{
	ToppleTowersTask() { }
	ToppleTowersTask(SValue@ save) { }
	
	void Execute() override
	{
		if (!Network::IsServer())
			return;
		
		uint towerTag = 1 << g_actorTags.GetTag("tower");
		auto enemies = g_scene.FetchAllActorsWithOtherTeam(g_team_player);
		int numDestroyed = 0;
		
		print("Architect: Toppling towers, tag: " + towerTag);
		for (uint i = 0; i < enemies.length(); i++)
		{
			auto actor = cast<Actor>(enemies[i].GetScriptBehavior());
			if ((actor.Tags & towerTag) == towerTag)
			{
				actor.Kill(null, 0);
				numDestroyed++;
			}
		}
		print("Toppled " + numDestroyed + " towers");
	}
}

class RevealWaygatesTask : QueuedTasks::QueuedTask
{
	RevealWaygatesTask() { }
	RevealWaygatesTask(SValue@ save) { }
	
	void Execute() override
	{
		//if (!Network::IsServer())
		//	return;
		
		auto allBeacons = g_scene.FetchAllUnitsWithBehavior("TeleportBeacon");
		for (uint i = 0; i < allBeacons.length(); i++)
		{
			auto beacon = cast<TeleportBeacon>(allBeacons[i].GetScriptBehavior());
			if (beacon !is null)
				beacon.Reveal();
		}
		
		print("Revealed " + allBeacons.length() + " waygates");
	}
}