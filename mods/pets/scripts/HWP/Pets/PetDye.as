// Pet dyes at the tailor. The tailor's unit (a class_units.py copy) names
// HWPDyerShopContent instead of EquipmentDyerShopContent: with a pet out, talking
// to her first asks "your gear or your pet?". The pet window lists every dye
// the town has unlocked (the same PlayerColors the tailor puts on gear) for
// gold by quality (100 / 250 / 500 / 1000), plus a free "remove". The dye is
// per character and per pet (HWP data "pets.dye.<petId>" = the PlayerColors
// id of the primary section, "pets.dye2.<petId>" the secondary one).
//
// Pets listed in PetDyeParts.as have two sections, like gear (body / eyes,
// shell / legs, clothes / rucksack ...): tools/make_pet_dyes.py writes dye-ready
// copies of their units (players/pets/hwp/dye/<petId>_<p|s|ps>.unit) whose
// textures index the dyed section's pixels for the engine's multicolour shader
// (channel 0 = primary, 1 = secondary). A dyed pet is swapped for the copy that
// matches what is dyed, so undyed sections keep their own colours. Other pets
// (and these, if the copies were not generated) get one section: the whole
// sprite tinted with Colorize.
//
//   pets.dye    peer -> host  { pet, dye, dye2 }        my pet's dyes (on a change and
//                                                       once per level, so everyone knows)
//   pets.dyed   host -> all   { peer, pet, dye, dye2 }  store them, re-make the pet if they changed
namespace HWP
{
	namespace PetDye
	{
		const string KEY = "pets.dye.";
		const string KEY2 = "pets.dye2.";
		const string VARIANTS = "players/pets/hwp/dye/";
		const string DYE = "pets.dye";
		const string DYED = "pets.dyed";
		const int PAGE = 10;

		string g_sentPet = "?"; // the active pet whose dye this level last sent

		// the dye with that id, if it has the three colours Colorize takes
		PlayerColors@ Get(const string &in id)
		{
			if (id.isEmpty())
				return null;
			uint hash = HashString(id);
			for (uint i = 0; i < PlayerColors::Instances.length(); i++)
			{
				auto c = PlayerColors::Instances[i];
				if (c.m_idHash == hash)
					return c.m_colors.length() >= 3 ? c : null;
			}
			return null;
		}

		// the vanilla pet (a MiniPet our pet units make) the record has out, or "":
		// external pets like the Gold Collector make their own units and are not dyed
		string DyeablePetId(PlayerRecord@ rec)
		{
			if (rec is null || rec.pet is null || rec.pet.m_unit is null)
				return "";
			return rec.pet.m_id;
		}

		// part 0 = the primary section (or the whole pet), 1 = the secondary one
		string DyeId(PlayerRecord@ rec, const string &in petId, int part = 0)
		{
			if (rec is null || petId.isEmpty())
				return "";
			return HWP::SaveData::Player(rec).GetString((part == 1 ? KEY2 : KEY) + petId, "");
		}

		void SetDyeId(PlayerRecord@ rec, const string &in petId, const string &in dye, int part = 0)
		{
			if (rec is null || petId.isEmpty())
				return;
			auto bag = HWP::SaveData::Player(rec);
			string key = (part == 1 ? KEY2 : KEY) + petId;
			if (dye.isEmpty())
				bag.Remove(key);
			else
				bag.SetString(key, dye);
		}

		bool TwoParts(const string &in petId)
		{
			return !Parts(petId).isEmpty();
		}

		// a section's name: "Body", "Eyes" ... or "Whole pet" for a one-section pet
		string PartName(const string &in petId, int part)
		{
			auto names = Parts(petId).split("/");
			if (names.length() != 2)
				return Resources::GetString(".hwp.pets.dye.part.whole");
			return Resources::GetString(".hwp.pets.dye.part." + names[part == 1 ? 1 : 0]);
		}

		// "p", "s", "ps" or "": which dye-ready copy the pet's dyes need
		string WantedVariant(PlayerRecord@ rec, const string &in petId)
		{
			if (!TwoParts(petId))
				return "";
			return (Get(DyeId(rec, petId, 0)) !is null ? "p" : "") + (Get(DyeId(rec, petId, 1)) !is null ? "s" : "");
		}

		// the tailor's gear price for the dye's quality, without the item level
		int Cost(PlayerColors@ c)
		{
			if (c is null)
				return 0;
			if (c.m_quality == Item::Quality::Epic) return 1000;
			if (c.m_quality == Item::Quality::Rare) return 500;
			if (c.m_quality == Item::Quality::Uncommon) return 250;
			return 100;
		}

		bool Usable(PlayerColors@ c)
		{
			if (c is null || c.m_default || c.m_blockedByDLC || c.m_colors.length() < 3)
				return false;
			if (c.m_blueprintHash == 0)
				return true;
			return g_myTownRecord !is null && g_myTownRecord.m_blueprints.HasBlueprint(c.m_blueprintHash);
		}

		// the dyes the tailor would offer for gear: not a default, blueprint unlocked
		array<PlayerColors@>@ Unlocked()
		{
			array<PlayerColors@> list;
			for (uint i = 0; i < PlayerColors::Instances.length(); i++)
				if (Usable(PlayerColors::Instances[i]))
					list.insertLast(PlayerColors::Instances[i]);
			list.sort(function(a, b)
			{
				if (a.m_quality != b.m_quality)
					return int(a.m_quality) < int(b.m_quality);
				if (a.m_category != b.m_category)
					return a.m_category < b.m_category;
				if (a.m_sortOrder != b.m_sortOrder)
					return a.m_sortOrder < b.m_sortOrder;
				return a.m_id < b.m_id;
			});
			return list;
		}

		string Hex2(float f)
		{
			int v = clamp(int(f * 255.0f + 0.5f), 0, 255);
			string digits = "0123456789abcdef";
			return digits.substr(v / 16, 1) + digits.substr(v % 16, 1);
		}

		// "Cat: Body: Crimson, Eyes: no dye" (or "Cat: Crimson" for a one-section pet)
		string Current(PlayerRecord@ rec)
		{
			string petId = DyeablePetId(rec);
			string pet = HWP::Pets::PetName(rec);
			if (!TwoParts(petId))
				return Resources::GetString(".hwp.pets.dye.current", { { "pet", pet }, { "dye", Name(Get(DyeId(rec, petId, 0))) } });
			return Resources::GetString(".hwp.pets.dye.current2", { { "pet", pet },
				{ "part", PartName(petId, 0) }, { "dye", Name(Get(DyeId(rec, petId, 0))) },
				{ "part2", PartName(petId, 1) }, { "dye2", Name(Get(DyeId(rec, petId, 1))) } });
		}

		// the dye's name in its mid colour
		string Name(PlayerColors@ c)
		{
			if (c is null)
				return Resources::GetString(".hwp.pets.dye.none");
			vec4 m = c.m_colors[1];
			return "\\c" + Hex2(m.x) + Hex2(m.y) + Hex2(m.z) + c.m_name + "\\d";
		}

		// a pet being made (HWPMiniPet*::Initialize, after the base Initialize):
		// true when it was replaced by the dye-ready copy its dyes need (the caller
		// stops there), else its dyes are applied
		bool Apply(MiniPet@ pet, PlayerBase@ owner, const string &in petId, const string &in variant, MiniPetOption options)
		{
			if (pet is null || owner is null || !pet.m_unit.IsValid())
				return false;
			auto rec = owner.m_record;
			if (TwoParts(petId))
			{
				string want = WantedVariant(rec, petId);
				if (want != variant && Swap(pet, owner, petId, want, options))
					return true;
				if (want == variant)
				{
					for (int part = 0; part < 2; part++)
					{
						auto c = Get(DyeId(rec, petId, part));
						if (c !is null)
							pet.m_unit.SetMultiColor(part, c.m_colors[0], c.m_colors[1], c.m_colors[2], false);
					}
					return false;
				}
				// no dye-ready copy (tools/make_pet_dyes.py not run): tint the whole pet
			}
			auto c = Get(DyeId(rec, petId, 0));
			if (c is null)
				@c = Get(DyeId(rec, petId, 1));
			if (c !is null)
				pet.m_unit.Colorize(c.m_colors[0], c.m_colors[1], c.m_colors[2]);
			return false;
		}

		// replace the pet with the copy for `want` ("" = the plain pet); the new one
		// runs its own Initialize (and so its own Apply)
		bool Swap(MiniPet@ pet, PlayerBase@ owner, const string &in petId, const string &in want, MiniPetOption options)
		{
			UnitProducer@ prod = null;
			if (want.isEmpty())
			{
				if (owner.m_record.pet !is null)
					@prod = owner.m_record.pet.m_unit;
			}
			else
				@prod = Resources::GetUnitProducer(VARIANTS + petId + "_" + want + ".unit");
			if (prod is null)
				return false;
			auto unit = prod.Produce(g_scene, pet.m_unit.GetPosition());
			auto next = cast<MiniPet>(unit.GetScriptBehavior());
			if (next is null)
			{
				unit.Destroy();
				return false;
			}
			@owner.m_pet = next;
			next.Initialize(owner, options);
			pet.m_unit.Destroy();
			return true;
		}

		void RemakePet(PlayerRecord@ rec)
		{
			if (DyeablePetId(rec).isEmpty())
				return;
			auto pb = cast<PlayerBase>(rec.actor);
			if (pb !is null)
				pb.ResetPet();
		}

		// local: tell everyone the active pet's dye
		void Send(PlayerRecord@ rec)
		{
			if (rec is null || !rec.local)
				return;
			string petId = DyeablePetId(rec);
			g_sentPet = petId;
			if (petId.isEmpty())
				return;
			SValueBuilder b;
			b.PushDictionary();
			b.PushString("pet", petId);
			b.PushString("dye", DyeId(rec, petId, 0));
			b.PushString("dye2", DyeId(rec, petId, 1));
			b.PopDictionary();
			HWP::Net::Request(DYE, b.Build());
		}

		// local, every frame: resend when the active pet changed (new level, new pet)
		void Tick(PlayerRecord@ rec)
		{
			if (rec !is null && rec.local && rec.actor !is null && DyeablePetId(rec) != g_sentPet)
				Send(rec);
		}

		// local: pay and dye a section of the active pet ("" removes that dye, free)
		string Dye(const string &in dyeId, int part = 0)
		{
			auto rec = GetLocalPlayerRecord();
			string petId = DyeablePetId(rec);
			if (petId.isEmpty())
				return Resources::GetString(".hwp.pets.dye.no_pet");
			if (!TwoParts(petId))
				part = 0;
			auto c = Get(dyeId);
			if (!dyeId.isEmpty() && !Usable(c))
				return "";
			if (DyeId(rec, petId, part) == dyeId)
				return Resources::GetString(".hwp.pets.dye.same");
			if (c !is null && !HWP::Town::PayGold(Cost(c)))
				return Resources::GetString(".hwp.pets.dye.no_gold", { { "gold", Cost(c) } });
			SetDyeId(rec, petId, dyeId, part);
			RemakePet(rec);
			Send(rec);
			HWP::Pets::g_version++;
			if (c is null)
				return Resources::GetString(".hwp.pets.dye.removed");
			return Resources::GetString(".hwp.pets.dye.done", { { "dye", Name(c) } });
		}

		// host: pass it on to everyone
		void OnDyeRequest(uint8 peer, SValue@ data)
		{
			if (!Network::IsServer())
				return;
			SValueBuilder b;
			b.PushDictionary();
			b.PushInteger("peer", peer);
			b.PushString("pet", HWP::SV::Str(data, "pet", ""));
			b.PushString("dye", HWP::SV::Str(data, "dye", ""));
			b.PushString("dye2", HWP::SV::Str(data, "dye2", ""));
			b.PopDictionary();
			HWP::Net::Broadcast(DYED, b.Build());
		}

		// every peer but the dyer: store it on that player's record and re-make
		// their pet when it changed
		void OnDyed(SValue@ data)
		{
			int peer = HWP::SV::Int(data, "peer", -1);
			if (peer < 0 || peer == int(Lobby::GetLocalPeer()))
				return;
			auto rec = GetPlayerRecordByPeer(uint8(peer));
			string petId = HWP::SV::Str(data, "pet", "");
			string dye = HWP::SV::Str(data, "dye", "");
			string dye2 = HWP::SV::Str(data, "dye2", "");
			if (rec is null || petId.isEmpty() || (!dye.isEmpty() && Get(dye) is null) || (!dye2.isEmpty() && Get(dye2) is null))
				return;
			if (DyeId(rec, petId, 0) == dye && DyeId(rec, petId, 1) == dye2)
				return;
			SetDyeId(rec, petId, dye, 0);
			SetDyeId(rec, petId, dye2, 1);
			if (DyeablePetId(rec) == petId)
				RemakePet(rec);
		}

		void Init()
		{
			HWP::Net::OnRequest(DYE, HWP::Net::RequestHandler(OnDyeRequest));
			HWP::Net::OnEvent(DYED, HWP::Net::EventHandler(OnDyed));
		}

		void Start()
		{
			g_sentPet = "?";
		}
	}
}

// The tailor (in place of EquipmentDyerShopContent): with a pet out, a choice
// between the vanilla gear dyer and the pet dyes.
class HWPDyerShopContent : EquipmentDyerShopContent
{
	HWPDyerShopContent() {}
	HWPDyerShopContent(UnitPtr u, SValue& params) { super(u, params); }

	AWindowObject@ MakeShopWindow(GUIBuilder@ guiBuilder) override
	{
		if (!HWP::Pets::g_enabled || HWP::PetDye::DyeablePetId(m_player).isEmpty())
			return EquipmentDyerShopContent::MakeShopWindow(guiBuilder);
		@m_window = HWPDyerChoice(guiBuilder, this);
		return m_window;
	}
}

class HWPDyerChoice : AWindowObject
{
	HWPDyerShopContent@ m_shop;

	HWPDyerChoice(GUIBuilder@ b, HWPDyerShopContent@ shop)
	{
		super(b, "gui/hwp_dyer_choice.gui");
		@m_shop = shop;
		PauseGame(true, true);
		auto text = cast<TextWidget>(m_widget.GetWidgetById("pet-dye"));
		if (text !is null)
		{
			auto rec = GetLocalPlayerRecord();
			text.SetText(HWP::PetDye::Current(rec));
		}
	}

	void OnClose() override
	{
		PauseGame(false, true);
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
		{
			m_manager.CloseWindow(this);
			return;
		}
		if (name != "gear" && name != "pet")
			return;
		// close this one first (it un-pauses), then open the next (it pauses)
		auto manager = m_manager;
		manager.CloseWindow(this);
		AWindowObject@ next;
		if (name == "gear")
			@next = EquipmentDyerWindow(m_builder, m_shop);
		else
			@next = HWPPetDyeMenu(m_builder);
		@m_shop.m_window = next;
		manager.AddWindowObject(next);
	}
}

class HWPPetDyeMenu : AWindowObject
{
	TextWidget@ m_state;
	TextWidget@ m_gold;
	TextWidget@ m_messageText;
	TextWidget@ m_pageText;
	Widget@ m_list;
	Widget@ m_rowTemplate;
	TextWidget@ m_lineTemplate;
	array<Widget@> m_rows;
	array<string> m_rowDyes; // PlayerColors id, "" = remove, "<" / ">" = page, "|" = switch section
	int m_page = 0;
	int m_part = 0; // the section the rows dye (0 = primary or the whole pet, 1 = secondary)
	string m_message;

	HWPPetDyeMenu(GUIBuilder@ b)
	{
		super(b, "gui/hwp_pets.gui");
		PauseGame(true, true);
		auto title = cast<TextWidget>(m_widget.GetWidgetById("title"));
		if (title !is null)
			title.SetText(Resources::GetString(".hwp.pets.dye.title"));
		@m_state = cast<TextWidget>(m_widget.GetWidgetById("state"));
		@m_gold = cast<TextWidget>(m_widget.GetWidgetById("xp"));
		@m_messageText = cast<TextWidget>(m_widget.GetWidgetById("message"));
		@m_pageText = cast<TextWidget>(m_widget.GetWidgetById("points"));
		@m_list = m_widget.GetWidgetById("list");
		@m_rowTemplate = m_widget.GetWidgetById("row-template");
		@m_lineTemplate = cast<TextWidget>(m_widget.GetWidgetById("line-template"));
		Refresh();
	}

	void OnClose() override
	{
		PauseGame(false, true);
	}

	void AddRow(const string &in text, const string &in dye)
	{
		auto row = m_rowTemplate.Clone();
		row.SetID("");
		row.m_visible = true;
		auto btn = cast<ScalableSpriteButtonWidget>(row);
		if (btn !is null)
			btn.SetText(text);
		m_list.AddChild(row);
		m_rows.insertLast(row);
		m_rowDyes.insertLast(dye);
	}

	void Refresh()
	{
		m_list.ClearChildren();
		m_rows.removeRange(0, m_rows.length());
		m_rowDyes.removeRange(0, m_rowDyes.length());
		auto rec = GetLocalPlayerRecord();
		string petId = HWP::PetDye::DyeablePetId(rec);
		bool two = HWP::PetDye::TwoParts(petId);
		if (!two)
			m_part = 0;
		auto current = HWP::PetDye::Get(HWP::PetDye::DyeId(rec, petId, m_part));
		m_state.SetText(HWP::PetDye::Current(rec));
		m_gold.SetText(Resources::GetString(".hwp.pets.dye.gold", { { "n", rec is null ? 0 : rec.GetMaterial(MaterialType::Gold) } }));
		m_messageText.SetText(m_message);

		auto dyes = HWP::PetDye::Unlocked();
		int pages = max(1, (int(dyes.length()) + HWP::PetDye::PAGE - 1) / HWP::PetDye::PAGE);
		m_page = clamp(m_page, 0, pages - 1);
		m_pageText.SetText(Resources::GetString(".hwp.pets.dye.page", { { "page", m_page + 1 }, { "pages", pages }, { "n", dyes.length() } }));

		if (two)
			AddRow(Resources::GetString(".hwp.pets.dye.section", { { "part", HWP::PetDye::PartName(petId, m_part) }, { "other", HWP::PetDye::PartName(petId, 1 - m_part) } }), "|");
		if (current !is null)
			AddRow(Resources::GetString(".hwp.pets.dye.remove_part", { { "part", HWP::PetDye::PartName(petId, m_part) } }), "");
		if (dyes.length() == 0)
		{
			auto l = cast<TextWidget>(m_lineTemplate.Clone());
			l.SetID("");
			l.m_visible = true;
			l.SetText(Resources::GetString(".hwp.pets.dye.none_unlocked"));
			m_list.AddChild(l);
		}
		int from = m_page * HWP::PetDye::PAGE;
		for (int i = from; i < from + HWP::PetDye::PAGE && i < int(dyes.length()); i++)
			AddRow(Resources::GetString(".hwp.pets.dye.row", { { "dye", HWP::PetDye::Name(dyes[i]) }, { "gold", HWP::PetDye::Cost(dyes[i]) } }), dyes[i].m_id);
		if (m_page > 0)
			AddRow(Resources::GetString(".hwp.pets.dye.prev"), "<");
		if (m_page + 1 < pages)
			AddRow(Resources::GetString(".hwp.pets.dye.next"), ">");
		m_widget.Invalidate();
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		if (name == "close")
		{
			m_manager.CloseWindow(this);
			return;
		}
		if (name != "row")
			return;
		int idx = -1;
		for (uint i = 0; i < m_rows.length(); i++)
			if (m_rows[i] is sender)
				idx = int(i);
		if (idx < 0)
			return;
		string dye = m_rowDyes[idx];
		m_message = "";
		if (dye == "<")
			m_page--;
		else if (dye == ">")
			m_page++;
		else if (dye == "|")
			m_part = 1 - m_part;
		else
			m_message = HWP::PetDye::Dye(dye, m_part);
		Refresh();
	}
}
