// Safety net for a vanilla level generation hang. OutdoorGenerator picks its
// base level once and keeps it across "retrying from scratch": when a
// required prefab set can never fit on that base (seen with forest_2 on
// base_levels/level_6 and forest_skill), the game retries the same layout
// forever until the connection times out. This picks the base level again
// on every retry and sets aside a base that failed RETRIES times in a row.
class HWPOutdoorGenerator : OutdoorGenerator
{
	int RETRIES = 10;

	MissionPrefabDef@ m_hwpBase;
	int m_hwpFails = 0;
	array<MissionPrefabDef@> m_hwpBad;

	bool InitializeGeneration() override
	{
		if (m_baseLevelPfbSet.isEmpty())
		{
			PrintError("No level prefab defined!");
			return false;
		}

		if (m_hwpBase !is null && ++m_hwpFails >= RETRIES)
		{
			PrintWarning("[HWP] base level failed generation " + m_hwpFails + " times, picking another");
			m_hwpBad.insertLast(m_hwpBase);
			@m_hwpBase = null;
			m_hwpFails = 0;
		}

		auto startPrefabs = MissionPrefabDef::GetPossiblePrefabs(HashString(m_baseLevelPfbSet));
		if (m_hwpBase is null)
		{
			array<MissionPrefabDef@> good;
			for (uint i = 0; i < startPrefabs.length(); i++)
				if (m_hwpBad.findByRef(startPrefabs[i]) < 0)
					good.insertLast(startPrefabs[i]);
			if (good.length() == 0)
				m_hwpBad.removeRange(0, m_hwpBad.length());   // every base failed: start over
			else
				startPrefabs = good;
		}
		else
		{
			startPrefabs.removeRange(0, startPrefabs.length());
			startPrefabs.insertLast(m_hwpBase);
		}

		@m_tmpStartPfbPicked = null;
		while (m_tmpStartPfbPicked is null && startPrefabs.length() > 0)
		{
			int tn = MissionPrefabDef::RollIndex(startPrefabs);
			if (tn < 0)
				break;
			@m_hwpBase = startPrefabs[tn];
			@m_tmpStartPfbPicked = m_hwpBase.UsePrefab();
			startPrefabs.removeAt(tn);
		}

		if (m_tmpStartPfbPicked is null)
		{
			PrintError("No level prefab found!");
			return false;
		}

		m_size = m_tmpStartPfbPicked.m_gridSz * 16;
		return true;
	}
}
