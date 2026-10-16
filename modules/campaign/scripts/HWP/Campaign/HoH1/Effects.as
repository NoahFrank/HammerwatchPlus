// HoH2 implementations of the effect classes HoH1 units and buffs use and
// HoH2 lacks. tools/import_hoh1.py renames each HoH1 class to the HoH1-prefixed
// one here; the parameters are HoH1's.

// GiveGold / GiveOre: money and ore pickups. HoH1 credits the local player
// when "pickup" is set (every client applied a global pickup); HoH2 applies a
// pickup's effects only on the picker's own machine, so the picker is
// credited. Amounts are HoH1's, 1:1.
class HoH1GiveMaterial : IEffect
{
	int m_amount;
	MaterialType m_type;

	HoH1GiveMaterial(UnitPtr unit, SValue& params, MaterialType type)
	{
		m_amount = GetParamInt(unit, params, "amount");
		m_type = type;
	}

	CanEvade IsEvadable(Actor@ attacker) { return CanEvade::Neither; }
	void SetWeaponInformation(uint weapon) {}

	bool Apply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity, bool husk)
	{
		auto plr = cast<PlayerBase>(target.GetScriptBehavior());
		if (plr is null)
			return false;

		int given = plr.m_record.GiveMaterial(m_type, m_amount);
		LootLog::PresentMaterial(plr.m_record, m_type, given);
		return true;
	}

	bool CanApply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity) override
	{
		return cast<PlayerBase>(target.GetScriptBehavior()) !is null;
	}
}

class HoH1GiveGold : HoH1GiveMaterial
{
	HoH1GiveGold(UnitPtr unit, SValue& params) { super(unit, params, MaterialType::Gold); }
}

class HoH1GiveOre : HoH1GiveMaterial
{
	HoH1GiveOre(UnitPtr unit, SValue& params) { super(unit, params, MaterialType::Ore); }
}

// Decimate: takes a fraction of the target's health and mana. "amount" and
// "mana" are fractions of the current value, "amount-max" and "mana-max" of
// the maximum. The health part is pure damage, so armor and resistances
// don't soften it (HoH1 bypassed them too).
class HoH1Decimate : IEffect
{
	float m_hp;
	float m_hpMax;
	float m_mana;
	float m_manaMax;
	bool m_canKill;
	bool m_trueStrike;
	uint m_weaponInfo;

	HoH1Decimate(UnitPtr unit, SValue& params)
	{
		m_hp = GetParamFloat(unit, params, "amount", false, 0.0f);
		m_hpMax = GetParamFloat(unit, params, "amount-max", false, 0.0f);
		m_mana = GetParamFloat(unit, params, "mana", false, 0.0f);
		m_manaMax = GetParamFloat(unit, params, "mana-max", false, 0.0f);
		m_canKill = GetParamBool(unit, params, "can-kill", false, true);
		m_trueStrike = GetParamBool(unit, params, "true-strike", false, false);
	}

	CanEvade IsEvadable(Actor@ attacker) { return m_trueStrike ? CanEvade::Unevadable : CanEvade::Evadable; }
	void SetWeaponInformation(uint weapon) { m_weaponInfo = weapon; }

	bool Apply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity, bool husk)
	{
		target.TriggerCallbacks(UnitEventType::Damaged);

		if (!CanApply(owner, target, pos, dir, intensity))
			return false;

		auto actor = cast<Actor>(target.GetScriptBehavior());

		if ((m_mana != 0 || m_manaMax != 0) && actor.GetMana() >= 0)
		{
			float mana = m_mana * intensity * actor.GetCurrentMana() + m_manaMax * intensity * actor.GetMaxMana();
			if (mana >= 1)
				actor.GiveMana(-int(mana), false);
		}

		if ((m_hp != 0 || m_hpMax != 0) && FilterHuskDamage(owner, target, husk))
		{
			float maxHp = actor.GetMaxHp();
			float hp = m_hp * intensity * actor.GetHealth() * maxHp + m_hpMax * intensity * maxHp;
			if (hp >= 1)
			{
				auto di = DamageInfo(owner, m_weaponInfo);
				di.PureDamage = uint32(hp);
				di.CanKill = m_canKill;
				di.TrueStrike = m_trueStrike;
				di.DoT = true;
				actor.Damage(di, pos, dir);
			}
		}

		return true;
	}

	bool CanApply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity) override
	{
		return target.IsValid() && intensity > 0 && cast<Actor>(target.GetScriptBehavior()) !is null;
	}
}

// AddCurse: HoH1 curses become HoH2 shadow curses; a negative amount lifts
// that many (the remove-curse potion).
class HoH1AddCurse : IEffect
{
	int m_amount;

	HoH1AddCurse(UnitPtr unit, SValue& params)
	{
		m_amount = GetParamInt(unit, params, "amount");
	}

	CanEvade IsEvadable(Actor@ attacker) { return CanEvade::Neither; }
	void SetWeaponInformation(uint weapon) {}

	bool Apply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity, bool husk)
	{
		if (!CanApply(owner, target, pos, dir, intensity))
			return false;

		auto record = cast<Player>(target.GetScriptBehavior()).m_record;
		if (m_amount > 0)
			record.GiveShadowCurse(owner, m_amount);
		else
			record.shadowCurses -= min(-m_amount, record.shadowCurses);
		return true;
	}

	bool CanApply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity) override
	{
		auto plr = cast<Player>(target.GetScriptBehavior());
		if (plr is null)
			return false;
		return m_amount > 0 || plr.m_record.shadowCurses > 0;
	}
}

// Effects with no HoH2 counterpart: the lunar shield's Mt. Moon block charge
// (an HoH1 NG+ modifier), and two HoH1 player-class buffs nothing in the
// campaign grants. They load and never apply, so a pickup holding one stays
// on the ground.
class HoH1InertEffect : IEffect
{
	HoH1InertEffect(UnitPtr unit, SValue& params) {}

	CanEvade IsEvadable(Actor@ attacker) { return CanEvade::Neither; }
	void SetWeaponInformation(uint weapon) {}
	bool Apply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity, bool husk) { return false; }
	bool CanApply(Actor@ owner, UnitPtr target, vec2 pos, vec2 dir, float intensity) override { return false; }
}
