namespace HWP
{
	const string VERSION = "0.1.0";

	void Log(const string &in module, const string &in msg)
	{
		print("[HWP:" + module + "] " + msg);
	}

	void LogError(const string &in module, const string &in msg)
	{
		PrintError("[HWP:" + module + "] " + msg);
	}

	// Self-check helpers for module constructors / Load: log every missing
	// resource with the same wording, return how many were missing.
	int CheckUnits(const string &in module, const array<string> &in paths)
	{
		int missing = 0;
		for (uint i = 0; i < paths.length(); i++)
		{
			if (Resources::GetUnitProducer(paths[i]) is null)
			{
				LogError(module, "missing unit " + paths[i]);
				missing++;
			}
		}
		return missing;
	}

	// equipment (weapons, armour) lives in Equipment::BaseItem, not Item::
	int CheckEquipment(const string &in module, const array<string> &in ids)
	{
		int missing = 0;
		for (uint i = 0; i < ids.length(); i++)
		{
			if (Equipment::BaseItem::Get(ids[i]) is null)
			{
				LogError(module, "missing equipment " + ids[i]);
				missing++;
			}
		}
		return missing;
	}

	int CheckItems(const string &in module, const array<string> &in ids)
	{
		int missing = 0;
		for (uint i = 0; i < ids.length(); i++)
		{
			if (Item::Get(ids[i]) is null)
			{
				LogError(module, "missing item " + ids[i]);
				missing++;
			}
		}
		return missing;
	}

	int CheckLootTables(const string &in module, const array<string> &in ids)
	{
		int missing = 0;
		for (uint i = 0; i < ids.length(); i++)
		{
			if (Item::GetLootTable(ids[i]) is null)
			{
				LogError(module, "missing loot table " + ids[i]);
				missing++;
			}
		}
		return missing;
	}
}
