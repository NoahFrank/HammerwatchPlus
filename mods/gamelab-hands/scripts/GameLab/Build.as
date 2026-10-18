// gamelab-hands: fixture verbs for a full character build (the fixture recipes' "setup").
// Each calls the function the game itself calls for the same change; the recipe reads every
// field back through `inspect player <key>` (MECHANICS.md section 8, the run-state schema).
namespace GameLab
{
	PlayerRecord@ FixtureRecord(const string &in id)
	{
		auto rec = GetLocalPlayerRecord();
		if (rec is null || rec.playerClass is null)
		{
			Fail(id, "no local character");
			return null;
		}
		return rec;
	}

	// xp <amount>: PlayerRecord.GiveExperience (kills, mission rewards), gain modifiers skipped
	void VerbXp(const string &in id, array<string>@ args)
	{
		auto rec = FixtureRecord(id);
		if (rec is null)
			return;
		if (args.length() < 1)
		{
			Fail(id, "usage: xp <amount>");
			return;
		}
		int ret = rec.GiveExperience(int(parseInt(args[0])), true);
		rec.RefreshStats();
		Emit(Reply(id, true).Int("returned", ret).Int("level", rec.level).Int("xp", rec.experience));
	}

	// material <gold|wood|stone|iron|crystals|dust|ore> <n>: PlayerRecord.GiveMaterial (pickups)
	void VerbMaterial(const string &in id, array<string>@ args)
	{
		auto rec = FixtureRecord(id);
		if (rec is null)
			return;
		array<string> names = { "gold", "wood", "stone", "iron", "crystals", "dust", "ore" };
		int type = args.length() > 0 ? names.find(args[0]) : -1;
		if (type < 0 || args.length() < 2)
		{
			Fail(id, "usage: material <" + join(names, "|") + "> <n>");
			return;
		}
		int got = rec.GiveMaterial(MaterialType(type), int(parseInt(args[1])), true);
		Emit(Reply(id, true).Str("material", args[0]).Int("given", got).Int("now", rec.GetMaterial(MaterialType(type))));
	}

	// charflag <name>: PlayerRecord.SetCharFlag (mission rewards set these)
	void VerbCharFlag(const string &in id, array<string>@ args)
	{
		auto rec = FixtureRecord(id);
		if (rec is null)
			return;
		if (args.length() < 1)
		{
			Fail(id, "usage: charflag <name>");
			return;
		}
		rec.SetCharFlag(HashString(args[0]), true);
		Emit(Reply(id, true).Str("flag", args[0]).Int("hash", HashString(args[0])));
	}

	// equip <baseItemId> <qualityMask> [ilvl]: Equipment::Generator.GenerateItem (the
	// spawnequipment cheat's path, Console/Cheats.as), then equipped.Equip like a new
	// character's starting gear (PlayerRecord.as:451-465). The quality is the generator's:
	// its RollQuality tests `mask & Common != 0`, which binds as `mask & (Common != 0)`, so
	// a mask without the Common bit rolls nothing and the base item's quality is used
	// (EquipmentGenerator.as:15; measured fixture-ranger 20261017-151727: rare asked, 2 given).
	// The reply carries the quality actually given. Equip refusing (MayEquip: level or
	// attribute requirements) returns the item itself, and fails the verb.
	void VerbEquip(const string &in id, array<string>@ args)
	{
		auto rec = FixtureRecord(id);
		if (rec is null)
			return;
		if (args.length() < 2)
		{
			Fail(id, "usage: equip <baseItemId> <quality> [ilvl]");
			return;
		}
		auto baseItem = Equipment::BaseItem::Get(args[0]);
		if (baseItem is null)
		{
			Fail(id, "no base item '" + args[0] + "'");
			return;
		}
		Equipment::Generator gen;
		gen.m_ilvl = args.length() > 2 ? int(parseInt(args[2])) : rec.level;
		gen.m_qualities = Item::ParseQuality(args[1]);
		auto item = gen.GenerateItem(baseItem);
		if (item is null)
		{
			Fail(id, "GenerateItem returned null for " + args[0] + " " + args[1]);
			return;
		}
		auto unequipped = rec.equipped.Equip(item);
		if (unequipped is item)
		{
			Fail(id, "equipped.Equip refused " + args[0] + " (MayEquip: requirements; character level " + rec.level + ", ilvl " + gen.m_ilvl + ")");
			return;
		}
		if (unequipped !is null)
			rec.equipInventory.Add(unequipped);
		rec.RefreshStats();
		auto plr = cast<PlayerBase>(rec.actor);
		if (plr !is null)
			plr.RefreshModifiers();
		Emit(Reply(id, true).Str("item", args[0]).Int("quality", int(item.quality)).Int("ilvl", gen.m_ilvl)
			.Bool("replaced", unequipped !is null));
	}

	// assign <str|dex|int|foc|vit> <n|all>: the attribute assigner's Buy("assign")
	// (Town/AttributeAssignerShopContent.as:10-31), once per point, while points are placeable
	void VerbAssign(const string &in id, array<string>@ args)
	{
		auto rec = FixtureRecord(id);
		if (rec is null)
			return;
		array<string> names = { "str", "dex", "int", "foc", "vit" };
		int stat = args.length() > 0 ? names.find(args[0]) : -1;
		if (stat < 0 || args.length() < 2)
		{
			Fail(id, "usage: assign <" + join(names, "|") + "> <n|all>");
			return;
		}
		int want = args[1] == "all" ? 100000 : int(parseInt(args[1]));
		int placed = 0;
		while (placed < want && rec.GetPlaceableStatPoints() > 0)
		{
			if (stat == 0) rec.pickedStr++;
			else if (stat == 1) rec.pickedDex++;
			else if (stat == 2) rec.pickedInt++;
			else if (stat == 3) rec.pickedFoc++;
			else rec.pickedVit++;
			placed++;
		}
		rec.SyncStatPoints();
		rec.RefreshModifiers();
		rec.RefreshStats();
		if (args[1] != "all" && placed < want)
		{
			Fail(id, "only " + placed + " of " + want + " points were placeable");
			return;
		}
		Emit(Reply(id, true).Str("stat", args[0]).Int("placed", placed).Int("left", rec.GetPlaceableStatPoints())
			.Int("dex", rec.currStats.Dex));
	}

	// upgrade <shopId> <upgradeId> <step>: what an upgrade shop's Buy("buy") does
	// (Town/UpgradeShop.as:139-150: SetShopUpgradeLevel, RefreshModifiers) minus the cost;
	// e.g. upgrade apothecary potion-charges 0 = the first potion charge
	void VerbUpgrade(const string &in id, array<string>@ args)
	{
		auto rec = FixtureRecord(id);
		if (rec is null)
			return;
		if (args.length() < 3)
		{
			Fail(id, "usage: upgrade <shopId> <upgradeId> <step>");
			return;
		}
		auto shop = UpgradeShop::Get(args[0]);
		if (shop is null)
		{
			Fail(id, "no upgrade shop '" + args[0] + "'");
			return;
		}
		int step = int(parseInt(args[2]));
		bool found = false;
		for (uint i = 0; i < shop.m_upgrades.length() && !found; i++)
			found = shop.m_upgrades[i].m_idHash == HashString(args[1]) && step < int(shop.m_upgrades[i].m_steps.length());
		if (!found)
		{
			Fail(id, "shop '" + args[0] + "' has no upgrade '" + args[1] + "' step " + step);
			return;
		}
		rec.SetShopUpgradeLevel(shop.m_idHash, HashString(args[1]), step);
		rec.RefreshModifiers();
		rec.RefreshStats();
		Emit(Reply(id, true).Str("shop", args[0]).Str("upgrade", args[1]).Int("step", step)
			.Int("level", rec.GetShopUpgradeLevel(shop.m_idHash, HashString(args[1])))
			.Int("potionCharges", rec.currStats.PotionCharges));
	}

	// teleport <x> <y>: set the local player's unit position (the respawn path's call,
	// Player.as SetPosition(x, y, z, true)). Measurement scenarios only: a gate scenario that
	// teleports is not evidence of play.
	void VerbTeleport(const string &in id, array<string>@ args)
	{
		auto plr = GetLocalPlayer();
		if (plr is null || args.length() < 2)
		{
			Fail(id, plr is null ? "no spawned local player" : "usage: teleport <x> <y>");
			return;
		}
		vec3 p = plr.m_unit.GetPosition();
		plr.m_unit.SetPosition(parseFloat(args[0]), parseFloat(args[1]), p.z, true);
		vec3 q = plr.m_unit.GetPosition();
		Emit(Reply(id, true).Num("fromX", p.x).Num("fromY", p.y).Num("x", q.x).Num("y", q.y));
	}

	// timescale <x>: measurement only, NOT a test accelerator. Sets the engine cvar g_timescale
	// (0.1-16), turning e_cheats on first. Game-ms timers scale with it but player movement per
	// frame does not (floor-soak 20261017-175501 at 4x: intents timed out after a quarter of
	// the walk), so gameplay results under it are not results at 1x.
	void VerbTimescale(const string &in id, array<string>@ args)
	{
		if (args.length() < 1)
		{
			Fail(id, "usage: timescale <x>");
			return;
		}
		float x = max(0.1f, min(16.0f, parseFloat(args[0])));
		// g_timescale only changes with e_cheats on (SetVar alone read back 1.0: timescale
		// 20261017-175222); the engine allows e_cheats in modded games. Lab saves only.
		auto t = GetVarType("e_cheats");
		if (t == cvar_type::Bool)
			SetVar("e_cheats", true);
		else
			SetVar("e_cheats", 1);
		SetVar("g_timescale", x);
		Emit(Reply(id, true).Num("set", x).Num("timescale", GetVarFloat("g_timescale"))
			.Int("cheatsType", int(t)).Bool("cheats", t == cvar_type::Bool ? GetVarBool("e_cheats") : GetVarInt("e_cheats") != 0));
	}

	// cull: the cht_kill_all cheat's body (Console/Cheats.as:970-980): Kill every targetable
	// actor not on the player's team. Measurement scenarios only, like teleport.
	void VerbCull(const string &in id, array<string>@ args)
	{
		auto enemies = g_scene.FetchAllActorsWithOtherTeam(g_team_player);
		int killed = 0;
		for (uint i = 0; i < enemies.length(); i++)
		{
			Actor@ a = cast<Actor>(enemies[i].GetScriptBehavior());
			if (a !is null && a.IsTargetable())
			{
				a.Kill(null, 0);
				killed++;
			}
		}
		Emit(Reply(id, true).Int("found", enemies.length()).Int("killed", killed));
	}
}
