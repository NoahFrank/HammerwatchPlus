// Map icons for things the vanilla map does not mark. Dyes: every DyeBucket
// unit in the level gets a local marker unit (doodads/hwp/map_icon_dye.unit,
// a minimap sprite only) that goes away once the dye is picked up. Setting
// `mapicons.dyes` (default on).
namespace HWP
{
	namespace MapIcons
	{
		const string DYE_ICON = "doodads/hwp/map_icon_dye.unit";
		const int SCAN_MS = 1000;

		array<UnitPtr> g_dyes;    // the dyes we marked
		array<UnitPtr> g_markers; // their markers (same index)

		void Clear()
		{
			for (uint i = 0; i < g_markers.length(); i++)
				if (g_markers[i].IsValid())
					g_markers[i].Destroy();
			g_dyes.removeRange(0, g_dyes.length());
			g_markers.removeRange(0, g_markers.length());
		}

		int IndexOf(UnitPtr u)
		{
			int id = u.GetId();
			for (uint i = 0; i < g_dyes.length(); i++)
				if (g_dyes[i].IsValid() && g_dyes[i].GetId() == id)
					return int(i);
			return -1;
		}

		void Scan()
		{
			if (!HWP::Settings::GetBool("mapicons.dyes", true))
			{
				Clear();
				return;
			}
			// picked up, gone or hidden (a client's pickup before the host's
			// destroy arrives, a secret the level keeps hidden): drop the marker
			for (int i = int(g_dyes.length()) - 1; i >= 0; i--)
			{
				if (g_dyes[i].IsValid() && !g_dyes[i].IsHidden())
					continue;
				if (g_markers[i].IsValid())
					g_markers[i].Destroy();
				g_dyes.removeAt(i);
				g_markers.removeAt(i);
			}
			auto dyes = g_scene.FetchAllUnitsWithBehavior("DyeBucket");
			if (dyes.length() == 0)
				return;
			auto prod = Resources::GetUnitProducer(DYE_ICON);
			if (prod is null)
				return;
			for (uint i = 0; i < dyes.length(); i++)
			{
				if (dyes[i].IsHidden() || IndexOf(dyes[i]) >= 0)
					continue;
				g_dyes.insertLast(dyes[i]);
				g_markers.insertLast(prod.Produce(g_scene, dyes[i].GetPosition()));
			}
		}
	}
}

namespace Modules
{
	class HWPMapIconsModule : Module, HWP::ModuleStart
	{
		int m_timer = 0;

		HWPMapIconsModule()
		{
			super("hwp-mapicons");
			HWP::CheckUnits("core", { HWP::MapIcons::DYE_ICON });
		}

		void UpdateFrame(int ms, GameInput& gameInput, MenuInput& menuInput, bool paused) override
		{
			m_timer -= ms;
			if (m_timer > 0)
				return;
			m_timer = HWP::MapIcons::SCAN_MS;
			HWP::MapIcons::Scan();
		}

		void Start(StartMode sMode)
		{
			// a new level: the old units are gone with the old scene
			HWP::MapIcons::g_dyes.removeRange(0, HWP::MapIcons::g_dyes.length());
			HWP::MapIcons::g_markers.removeRange(0, HWP::MapIcons::g_markers.length());
			m_timer = 1500;
		}
	}
}
