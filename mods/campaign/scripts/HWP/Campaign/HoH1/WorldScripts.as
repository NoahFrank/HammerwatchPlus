// HoH2 implementations of the level-script types HoH1 levels use and HoH2
// lacks, under the names and Editable parameters the converted levels store
// (tools/import_hoh1.py campaign). Written against HoH2's API; where HoH2 has
// no such system (hardcore, character titles, top numbers) they keep the
// level flowing and do nothing else.
namespace HWP
{
	namespace HoH1
	{
		void Run(array<UnitPtr>@ units)
		{
			for (uint i = 0; i < units.length(); i++)
			{
				auto script = WorldScript::GetWorldScript(g_scene, units[i].GetScriptBehavior());
				if (script !is null)
					script.Execute();
			}
		}

		// The boss level's nodes and room, looked up in the loaded scene (so a
		// previous level can never leak in). The bosses call these on node
		// arrival; per-frame users cache the result for their own lifetime.
		array<WorldScript::BossLichNode@>@ LichNodes()
		{
			array<WorldScript::BossLichNode@> nodes;
			auto res = g_scene.FetchAllWorldScripts("BossLichNode");
			for (uint i = 0; i < res.length(); i++)
			{
				auto node = cast<WorldScript::BossLichNode>(res[i].GetUnit().GetScriptBehavior());
				if (node !is null)
					nodes.insertLast(node);
			}
			return nodes;
		}

		WorldScript::BossLichRoom@ LichRoom()
		{
			auto res = g_scene.FetchAllWorldScripts("BossLichRoom");
			return res.length() == 0 ? null : cast<WorldScript::BossLichRoom>(res[0].GetUnit().GetScriptBehavior());
		}

		WorldScript::VampireCenterNode@ CenterNode()
		{
			auto res = g_scene.FetchAllWorldScripts("VampireCenterNode");
			return res.length() == 0 ? null : cast<WorldScript::VampireCenterNode>(res[0].GetUnit().GetScriptBehavior());
		}
	}
}

namespace WorldScript
{
	[WorldScript color="238 232 170" icon="system/icons.png;160;288;32;32"]
	class SetEnvironment
	{
		[Editable]
		string Environment;

		SValue@ ServerExecute()
		{
			auto env = Resources::GetEnvironment(Environment);
			if (env is null)
			{
				HWP::LogError("campaign", "SetEnvironment: no environment " + Environment);
				return null;
			}
			g_scene.SetEnvironment(env);
			return null;
		}

		void ClientExecute(SValue@ val) { ServerExecute(); }
	}

	// HoH2 has no hardcore characters: always the OnFalse branch
	[WorldScript color="222 111 99" icon="system/icons.png;64;192;32;32"]
	class IsHardcore
	{
		[Editable]
		UnitFeed OnTrue;

		[Editable]
		UnitFeed OnFalse;

		SValue@ ServerExecute()
		{
			HWP::HoH1::Run(OnFalse.FetchAll());
			return null;
		}
	}

	// HoH1 boss kill bookkeeping (achievements, town record): a flag per boss
	// for the rest of the run, which the campaign module can read
	[WorldScript color="200 150 100" icon="system/icons.png;416;384;32;32"]
	class SetBossKilled
	{
		[Editable default=1]
		int BossNumber;

		SValue@ ServerExecute()
		{
			g_flags.Set("hwp_hoh1_boss_" + BossNumber, FlagState::Run);
			HWP::Log("campaign", "HoH1 boss " + BossNumber + " killed");
			return null;
		}

		void ClientExecute(SValue@ val) { ServerExecute(); }
	}

	[WorldScript color="#ff0000" icon="system/icons.png;32;192;32;32"]
	class CreateBossBar
	{
		[Editable]
		UnitFeed Actors;

		[Editable]
		string Name;

		[Editable]
		int SpriteVariation;

		[Editable default="#FF0000FF"]
		vec4 TextColor;

		SValue@ ServerExecute()
		{
			auto hud = g_gameMode.GetHUD();
			if (hud is null)
				return null;
			auto units = Actors.FetchAll();
			for (uint i = 0; i < units.length(); i++)
			{
				auto actor = cast<Actor>(units[i].GetScriptBehavior());
				if (actor !is null)
					hud.AddBossBar(actor, Name, array<float>());
			}
			return null;
		}

		void ClientExecute(SValue@ val) { ServerExecute(); }
	}

	// HoH1 placed a random enemy group from the act's enemy table; HoH2 levels
	// place their enemies from prefabs, so the converted levels keep the
	// placed ones and these points stay empty
	[WorldScript color="#bf0000" icon="system/icons.png;32;192;32;32"]
	class SpawnEnemyGroup
	{
		vec3 Position;

		[Editable default=28]
		int Radius;

		SValue@ ServerExecute() { return null; }
	}

	[WorldScript color="176 196 222" icon="system/icons.png;96;96;32;32"]
	class RandomLoot
	{
		vec3 Position;

		[Editable default=false]
		bool Forced;

		SValue@ ServerExecute() { return null; }
	}

	[WorldScript color="255 0 0" icon="system/icons.png;32;32;32;32"]
	class Wind
	{
		vec3 Position;
		bool Enabled;

		[Editable default=100 min=1]
		int Radius;

		[Editable default=0]
		int Direction;

		[Editable default=0.5]
		float Strength;

		[Editable default=1000]
		int ChangeTime;

		float m_intensity = -1.0f;

		// pushes the local player (each client pushes its own; remote players
		// are husks) and every non-player actor in range, as in HoH1
		void Update(int dt)
		{
			if (m_intensity < 0.0f)
				m_intensity = Enabled ? 1.0f : 0.0f;
			float change = 1.0f / max(1, ChangeTime);
			m_intensity = clamp(m_intensity + dt * (Enabled ? change : -change), 0.0f, 1.0f);
			if (m_intensity <= 0.0f)
				return;

			float ang = Direction / 180.0f * PI;
			vec2 push = vec2(cos(ang), sin(ang)) * Strength * m_intensity;
			auto res = g_scene.FetchUnitsWithBehavior("Actor", xy(Position), Radius, true);
			for (uint i = 0; i < res.length(); i++)
			{
				auto actor = cast<Actor>(res[i].GetScriptBehavior());
				if (actor is null || cast<PlayerHusk>(actor) !is null)
					continue;
				if (cast<Player>(actor) is null && !Network::IsServer())
					continue;
				auto body = res[i].GetPhysicsBody();
				if (body !is null)
					body.SetLinearVelocity(body.GetLinearVelocity() + push);
			}
		}
	}

	[WorldScript color="200 150 100" icon="system/icons.png;416;384;32;32"]
	class UnlinkSouls
	{
		SValue@ ServerExecute() { return null; }
	}

	[WorldScript color="200 150 100" icon="system/icons.png;416;384;32;32"]
	class GiveCharacterTitle
	{
		[Editable]
		UnitFeed Targets;

		[Editable]
		int TitleIndex;

		SValue@ ServerExecute() { return null; }
	}

	[WorldScript color="200 150 100" icon="system/icons.png;416;384;32;32"]
	class ClearTopNumbers
	{
		SValue@ ServerExecute() { return null; }
	}

	[WorldScript color="200 150 100" icon="system/icons.png;416;384;32;32"]
	class HideTopNumber
	{
		[Editable]
		string ID;

		SValue@ ServerExecute() { return null; }
	}

	[WorldScript color="#eee8aa" icon="system/icons.png;416;256;32;32"]
	class HideSpeechBubble
	{
		[Editable]
		UnitFeed Bubble;

		SValue@ ServerExecute()
		{
			auto units = Bubble.FetchAll();
			for (uint i = 0; i < units.length(); i++)
				units[i].SetHidden(true);
			return null;
		}

		void ClientExecute(SValue@ val) { ServerExecute(); }
	}

	[WorldScript color="#eee8aa" icon="system/icons.png;416;256;32;32"]
	class HideAllSpeechBubbles
	{
		SValue@ ServerExecute() { return null; }
	}

	// boss movement data (the Three Councilors and the Vampire Lord teleport between these)
	[WorldScript color="100 255 100" icon="system/icons.png;96;32;32;32"]
	class BossLichNode
	{
		vec3 Position;

		[Editable]
		UnitFeed NextNodes;

		BossLichNode@ PickNextNode()
		{
			auto nodes = NextNodes.FetchAll();
			if (nodes.length() == 0)
				return null;
			return cast<BossLichNode>(nodes[randi(nodes.length())].GetScriptBehavior());
		}

		SValue@ ServerExecute() { return null; }
	}

	[WorldScript color="100 100 255" icon="system/icons.png;96;32;32;32"]
	class VampireCenterNode : BossLichNode
	{
		BossLichNode@ PickNextNode() override
		{
			// any plain node, never the center itself
			auto nodes = HWP::HoH1::LichNodes();
			for (int i = int(nodes.length()) - 1; i >= 0; i--)
			{
				if (cast<VampireCenterNode>(nodes[i]) !is null)
					nodes.removeAt(i);
			}
			if (nodes.length() == 0)
				return null;
			return nodes[randi(nodes.length())];
		}
	}

	[WorldScript color="100 255 100" icon="system/icons.png;96;32;32;32"]
	class BossLichRoom
	{
		vec3 Position;

		[Editable]
		int Width;

		[Editable]
		int Height;

		bool IsInside(vec3 pos)
		{
			vec2 half = vec2(Width, Height) / 2.0f;
			vec2 d = xy(pos) - xy(Position);
			return abs(d.x) < half.x && abs(d.y) < half.y;
		}

		SValue@ ServerExecute() { return null; }
	}

	// HoH1 elevators banked run gold and ore at home for a tax. HoH2 keeps
	// what a run earns anyway, so the elevator is scenery: same fields, no use.
	[WorldScript color="210 105 30" icon="system/icons.png;96;96;32;32"]
	class StoreOre
	{
		bool Enabled;

		[Editable]
		array<CollisionArea@>@ Areas;

		[Editable]
		UnitFeed Unit;

		[Editable]
		string UseScene;

		SValue@ ServerExecute() { return null; }
	}

	// HoH1 town and dungeon shops (the item forge room). HoH2 has none of
	// those menus, so these are inert until we give them HoH2 shop contents.
	[WorldScript color="#B0C4DE" icon="system/icons.png;384;352;32;32"]
	class ShopArea
	{
		bool Enabled;

		[Editable]
		array<CollisionArea@>@ Areas;

		[Editable default=0]
		int Type;

		[Editable]
		string Category;

		[Editable default=1]
		int ShopLevel;

		[Editable]
		UnitFeed UsedUnits;

		[Editable]
		string UsedUnitScene;

		SValue@ ServerExecute() { return null; }
	}
}
