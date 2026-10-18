// Buff tooltips: hovering a buff or debuff icon in the HUD's buff bar shows a
// tooltip with the effect's name, its description and, above it, the seconds
// it has left, counting down. HUD components get no mouse input, so
// HWPBuffTipsHUD hit-tests the cursor against the HUDBuffs icons itself every
// frame and draws a vanilla ToolTip (CreateTooltip, header = time left) on top
// of the HUD. Buffs without a "hud" icon never reach the buff bar, so they
// have no tooltip either; their text still shows in the character menu's
// Effects tab. Setting: bufftips.enabled.
namespace HWP
{
	namespace BuffTips
	{
		// lang key -> text; empty and the placeholder "title" mean no text
		string Text(const string &in s)
		{
			if (s.isEmpty() || s == "title")
				return "";
			return s.substr(0, 1) == "." ? Resources::GetString(s) : s;
		}

		// name and description of whatever kind of buff the icon shows
		string Describe(IBuffWidgetInfo@ info, string &out desc)
		{
			desc = "";
			auto buff = cast<ActorBuff>(info);
			if (buff !is null && buff.m_def !is null)
			{
				desc = Text(buff.m_def.m_description);
				return Text(buff.m_def.m_name);
			}
			auto stacked = cast<ActorBuffStacked>(info);
			if (stacked !is null && stacked.m_def !is null)
			{
				string name = Text(stacked.m_def.m_name);
				if (!name.isEmpty())
				{
					desc = Text(stacked.m_def.m_desc);
					return name;
				}
				if (stacked.m_def.m_buffDef !is null)
				{
					desc = Text(stacked.m_def.m_buffDef.m_description);
					return Text(stacked.m_def.m_buffDef.m_name);
				}
				return "";
			}
			auto skill = cast<Skills::Skill>(info);
			if (skill !is null)
				return Text(skill.m_name);
			return "";
		}
	}
}

class HWPBuffTipsHUD : HUDComponent
{
	HUD@ m_hud;
	ToolTip@ m_tip;
	IBuffWidgetInfo@ m_tipBuff;
	int m_tipSecs = -1;
	int m_tipCount = -1;
	vec2 m_mouse;

	HWPBuffTipsHUD(HUD@ hud, GUIBuilder@ b)
	{
		super(b, "");
		@m_hud = hud;
		m_drawOnTop = true;
	}

	HUDBuffs@ Buffs()
	{
		for (uint i = 0; i < m_hud.m_components.length(); i++)
		{
			auto buffs = cast<HUDBuffs>(m_hud.m_components[i]);
			if (buffs !is null)
				return buffs;
		}
		return null;
	}

	// the buff icon under the cursor; the buff bar draws its widgets scaled by
	// its own m_scale (ui_hud_scale_buffs), the cursor is in unscaled HUD units
	BuffWidget@ Hovered()
	{
		auto buffs = Buffs();
		if (buffs is null || !buffs.IsVisible() || buffs.m_wBuffList is null)
			return null;
		float scale = buffs.m_scale;
		auto children = buffs.m_wBuffList.m_children;
		for (uint i = 0; i < children.length(); i++)
		{
			auto w = cast<BuffWidget>(children[i]);
			if (w is null || !w.m_visible || w.m_buff is null || w.m_buff.GetBuffIcon() is null)
				continue;
			vec2 o = (w.m_origin + buffs.m_offset) * scale;
			if (m_mouse.x >= o.x && m_mouse.x < o.x + w.m_width * scale && m_mouse.y >= o.y && m_mouse.y < o.y + w.m_height * scale)
				return w;
		}
		return null;
	}

	void ClearTip()
	{
		if (m_tip !is null)
			m_tip.Cleanup();
		@m_tip = null;
		@m_tipBuff = null;
		m_tipSecs = -1;
		m_tipCount = -1;
	}

	void Update(int dt, PlayerRecord@ record) override
	{
		m_mouse = GetGameModeMousePosition() / g_gameMode.m_wndScale;

		auto gm = cast<BaseGameMode>(g_gameMode);
		bool menuOpen = gm !is null && gm.m_windowManager.GetCurrentWindow() !is null;
		auto w = (!menuOpen && HWP::Settings::GetBool("bufftips.enabled", true)) ? Hovered() : null;
		if (w is null)
		{
			ClearTip();
			return;
		}

		auto info = w.m_buff;
		int left = info.GetBuffIconDuration();
		// no countdown for permanent buffs (kept up by script, e.g. Heroic Legacy)
		int secs = (left > 0 && left < 3600000 && info.GetBuffIconMaxDuration() > 0) ? int(ceil(left / 1000.0f)) : 0;
		int count = info.GetBuffIconCount();
		if (info is m_tipBuff && secs == m_tipSecs && count == m_tipCount)
			return;

		string desc;
		string name = HWP::BuffTips::Describe(info, desc);
		if (name.isEmpty())
			name = Resources::GetString(".hwp.bufftips.unnamed");
		if (count > 1)
			name = Resources::GetString(".hwp.bufftips.stacks", { { "name", name }, { "count", count } });
		string header = secs > 0 ? Resources::GetString(".hwp.bufftips.left", { { "secs", secs } }) : "";

		ClearTip();
		if (info.IsDebuff())
			name = "\\cff6666" + name;
		@m_tip = CreateTooltip(Resources::GetSValue("gui/variable/itemtooltip_common.sval"), name, desc, Item::Quality::None, header);
		@m_tipBuff = info;
		m_tipSecs = secs;
		m_tipCount = count;
	}

	void Draw(SpriteBatch& sb, int idt) override
	{
		if (m_tip is null)
			return;

		// above and to the right of the cursor (the buff bar is at the bottom),
		// leaving room for the header line drawn over the box, kept on screen
		vec2 size = m_tip.GetSize();
		vec2 pos = m_mouse + vec2(8, -size.y - 6);
		pos.x = min(pos.x, float(g_gameMode.m_wndWidth) - size.x - 2);
		pos.y = max(pos.y, 10.0f);

		mat4 tform;
		tform *= g_gameMode.m_wndInvScaleTransform;
		tform *= mat::scale(mat4(), g_gameMode.m_wndScale);
		sb.PushTransformation(tform);
		m_tip.Draw(sb, vec2(int(pos.x), int(pos.y)));
		sb.PopTransformation();
	}
}

namespace HWPBuffTips
{
	[Hook]
	void HUDConstructor(HUD@ hud, GUIBuilder@ b)
	{
		hud.m_components.insertLast(HWPBuffTipsHUD(hud, b));
	}
}

namespace Modules
{
	class HWPBuffTipsModule : Module
	{
		HWPBuffTipsModule()
		{
			super("hwp-bufftips");
			HWP::Log("bufftips", "ready");
		}
	}
}
