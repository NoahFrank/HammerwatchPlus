class ClassSorter
{
	Widget@ widget;
	int val;
}

// HWP (core): with the HammerwatchPlus classes the list outgrew its 262 px row
// (11 classes = 328 px) and an even count left the selection half a slot off
// centre. FitClassList shows at most HWP_CLASS_LIST_MAX classes, always an odd
// count, centred on the selection; stepping still cycles through every class.
const int HWP_CLASS_LIST_MAX = 7;

class CreateCharacterMenuClassTab : MenuTab
{
	Widget@ m_classList;
	Widget@ m_classTemplate;
	Widget@ m_currClass;

	TextWidget@ m_classTitle;
	TextWidget@ m_classDescription;

	SkillWidget@ m_skillTemplate;
	Widget@ m_skillList;

	EquipmentItemWidget@ m_equipmentTemplate;
	Widget@ m_equipmentList;
	array<Equipment::Item@> m_equipmentItems;

	TextInputWidget@ m_nameInput;
	MarkovName@ m_randomNameGen;
	vec4 fadeColor;

	CreateCharacterMenuClassTab(GUIBuilder@ b, uint id)
	{
		super(b, id, "gui/create_character/create_character_class.gui");

		fadeColor = ParseColorRGBA("#121314");

		@m_classList = m_widget.GetWidgetById("class-list");
		@m_classTemplate = m_widget.GetWidgetById("class-template");
		@m_classTitle = cast<TextWidget>(m_widget.GetWidgetById("class-title"));
		@m_classDescription = cast<TextWidget>(m_widget.GetWidgetById("class-desc"));

		@m_skillTemplate = cast<SkillWidget>(m_widget.GetWidgetById("skill-template"));
		@m_skillList = m_widget.GetWidgetById("skill-list");

		@m_equipmentTemplate = cast<EquipmentItemWidget>(m_widget.GetWidgetById("equipment-template"));
		@m_equipmentList = m_widget.GetWidgetById("equipment-list");

		@m_nameInput = cast<TextInputWidget>(m_widget.GetWidgetById("name-input"));
		if (m_nameInput !is null)
			m_nameInput.SetText(Platform::Service.GetMyName());

		array<string> names = {
			"mary", "patricia", "linda", /*"barbara",*/ "elizabeth", "jennifer", "maria", "susan", "margaret", "dorothy", "lisa", "nancy", "karen", "betty", "helen", "sandra",
			"donna", "carol", "ruth", "sharon", "michelle", "laura", "sarah", "kimberly", "deborah", "jessica", "shirley", "cynthia", "angela", "melissa", "brenda", "amy",
			"anna", "rebecca", "virginia", "kathleen", "pamela", "martha", "debra", "amanda", "stephanie", "carolyn", "christine", "marie", "janet", "catherine", "frances",
			"ann", "joyce", "diane", "james", "john", "robert", "michael", "william", "david", "richard", "charles", "joseph", "thomas", "christopher", "daniel", "paul",
			"mark", "donald", "george", "kenneth", "steven", "edward", "brian", "ronald", "anthony", "kevin", "jason", "matthew", "gary", "timothy", "jose", "larry", "jeffrey",
			"frank", "scott", "eric", "stephen", "andrew", "raymond", "gregory", "joshua", "jerry", "dennis", "walter", "patrick", "peter", "harold", "douglas", "henry", "carl",
			"arthur", "ryan", "roger"
		};
		names.insertLast(Platform::Service.GetMyName());

		@m_randomNameGen = MarkovName(names);

		array<PlayerClass@> classSort;
		for (uint i = 0; i < PlayerClass::Instances.length(); i++)
		{
			if (PlayerClass::Instances[i].parent != 0)
				continue;
			if (!CheckGlobalConditionals(PlayerClass::Instances[i].m_conditionals))
				continue;
			classSort.insertLast(PlayerClass::Instances[i]);
		}

		if (classSort.length() > 0)
		{
			classSort.sort(function(a, b) {
				return Resources::GetString(a.m_name) < Resources::GetString(b.m_name);
			});
		}

		int width = 0;
		int size = 0;
		for (uint i = 0; i < classSort.length(); i++)
		{
			auto plrClass = classSort[i];

			auto newClass = m_classTemplate.Clone();
			newClass.SetID(plrClass.m_id);
			newClass.m_visible = true;

			cast<SpriteWidget>(newClass.GetWidgetById("class-icon")).SetSprite(plrClass.m_icon);

			width += newClass.m_width;
			size++;

			auto button = cast<AInteractableWidget>(newClass.GetWidgetById("class-button"));
			button.m_func = "select " + plrClass.m_id;
			button.m_navPos = ivec2(size, 1);

			m_classList.AddChild(newClass);
		}

		width += m_classList.m_spacing * (size - 1);
		m_classList.m_width = width;

		BaseGameMode@ gm = cast<BaseGameMode>(g_gameMode);
		if (gm !is null)
			gm.m_windowManager.CloseTooltip();

		if (m_classList.m_children.length() > 0)
			SelectClass(m_classList.m_children[0].m_id);

		@m_input.m_menuContextOnPressed = WindowInput::OnFunc(this.MenuContext);
		@m_input.m_menuAdditionalOnPressed = WindowInput::OnFunc(this.MenuAdditional);
	}

	void RefreshKeybinds(ControlMap@ currMap) override
	{
		if (m_navigationBar is null)
			return;

		array<KeyNavigationText@> navTexts = {
			KeyNavigationText(m_navigationBar.m_font.BuildText(FormatKeyName(GetActionBinding("MenuContext")) + " " + Resources::GetString(".menu.nav.create")), WindowInput::OnFunc(this.MenuContext)),
			KeyNavigationText(m_navigationBar.m_font.BuildText(FormatKeyName(GetActionBinding("MenuAdditional")) + " " + Resources::GetString(".menu.nav.random_name")), WindowInput::OnFunc(this.MenuAdditional)),
			KeyNavigationText(m_navigationBar.m_font.BuildText(FormatKeyName(GetActionBinding("MenuPreviousSubTab")) + " " + Resources::GetString(".menu.nav.prev_class")), WindowInput::OnFunc(this.StepClassPrev)),
			KeyNavigationText(m_navigationBar.m_font.BuildText(FormatKeyName(GetActionBinding("MenuNextSubTab")) + " " + Resources::GetString(".menu.nav.next_class")), WindowInput::OnFunc(this.StepClassNext))
		};

		m_navigationBar.BuildBar(navTexts, this);
	}

	// HWP (core): see HWP_CLASS_LIST_MAX
	void FitClassList()
	{
		int n = m_classList.m_children.length();
		int shown = (n % 2 == 1) ? n : n - 1;
		if (shown > HWP_CLASS_LIST_MAX)
			shown = HWP_CLASS_LIST_MAX;
		int midPoint = n / 2;
		int width = 0;
		for (int i = 0; i < n; i++)
		{
			auto child = m_classList.m_children[i];
			int d = i - midPoint;
			child.m_visible = (d < 0 ? -d : d) <= shown / 2;
			if (child.m_visible)
				width += child.m_width;
		}
		if (shown > 1)
			width += m_classList.m_spacing * (shown - 1);
		m_classList.m_width = width;
		Invalidate();
	}

	void StepClassPrev() { StepClass(-1); }
	void StepClassNext() { StepClass(1); }
	void MenuContext() { OnFunc(null, "create"); }
	void MenuAdditional() { OnFunc(null, "name-random"); }
	void OnInteractableIndexChanged() override {}

	bool Update(int ms, GameInput& gameInput, MenuInput& menuInput) override
	{
		auto record = GetLocalPlayerRecord();

		if (record is null)
			return AWindowObject::Update(ms, gameInput, menuInput);

%if GAME
		if (menuInput.MenuPreviousSubTab.Pressed)
			StepClass(-1);
		if (menuInput.MenuNextSubTab.Pressed)
			StepClass(1);
%endif

		return AWindowObject::Update(ms, gameInput, menuInput);
	}

	void StepClass(int i)
	{
		BaseGameMode@ gm = cast<BaseGameMode>(g_gameMode);
		if (gm !is null)
			@gm.m_windowManager.m_tooltip = null;

		int currIndex = m_classList.m_children.findByRef(m_currClass);
		if (currIndex < 0)
			return;

		int nextIndex = (currIndex + i) % m_classList.m_children.length();
		string nextClass = m_classList.m_children[nextIndex < 0 ? nextIndex + m_classList.m_children.length() : nextIndex].m_id;
		SelectClass(nextClass);
	}

	void SelectClass(const string &in classId)
	{
		Widget@ classWidget;
		for (uint i = 0; i < m_classList.m_children.length(); i++)
		{
			auto child = m_classList.m_children[i];
			if (child.m_id == classId)
			{
				@classWidget = child;
				break;
			}
		}

		if (m_currClass is classWidget || classWidget is null)
			return;

		if (m_currClass !is null)
			m_currClass.GetWidgetById("select").m_visible = false;

		@m_currClass = classWidget;
		m_currClass.GetWidgetById("select").m_visible = true;

		
		int midPoint = m_classList.m_children.length() / 2;
		int currIndex = m_classList.m_children.findByRef(m_currClass);

		if (currIndex != midPoint)
		{
			int steps = midPoint - currIndex;

			array<ClassSorter@> m_sort;
			for (uint i = 0; i < m_classList.m_children.length(); i++)
			{
				auto clss = ClassSorter();
				@clss.widget = m_classList.m_children[i];

				clss.val = (i + steps);

				if (clss.val >= int(m_classList.m_children.length()))
					clss.val -= m_classList.m_children.length();
				else if (clss.val < 0)
					clss.val += m_classList.m_children.length();

				m_sort.insertLast(clss);
			}

			m_sort.sort(function(a, b) { return a.val < b.val; });

			m_classList.ClearChildren();
			for (uint i = 0; i < m_sort.length(); i++)
				m_classList.AddChild(m_sort[i].widget);

			Invalidate();
		}
		FitClassList();


		auto plrClass = PlayerClass::Get(m_currClass.m_idHash);
		m_classTitle.SetText(Resources::GetString(plrClass.m_name));
		m_classDescription.SetText(Resources::GetString(plrClass.m_description));

		UnitPtr u;

		ivec2 navOffset = ivec2(0, 1);

		// Skills
		m_skillList.ClearChildren();
		int width = 0;
		int size = 0;
		for (uint i = 0; i < plrClass.m_skillDefs.length(); i++)
		{
			auto@ def = plrClass.m_skillDefs[i];
			if (def.m_type == PlayerSkillType::Dash)
				continue;

			auto@ skillParams = def.m_levelParams[0];
			if (skillParams is null)
			{
				PrintError("Unable to find parameters for player skill \""+ def.m_name +"\"!");
				continue;
			}

			array<SValue@>@ p = { @skillParams };

			string c = GetParamString(u, p, "class");
			Skills::Skill@ skill = cast<Skills::Skill>(InstantiateClass(c, u, skillParams));

			skill.Initialize(null, u, p, def.m_idHash);
			@skill.m_icon = def.m_icon;
			skill.m_name = def.m_name;
			skill.m_type = def.m_type;
			skill.m_id = def.m_id;


			auto newWidget = cast<SkillWidget>(m_skillTemplate.Clone());
			newWidget.SetID(skill.m_name);
			newWidget.m_visible = true;
			newWidget.m_navPos = navOffset;

			navOffset.x += 1;
			if (navOffset.x % 4 == 0)
			{
				navOffset.x = 0;
				navOffset.y += 1;
			}

			width += newWidget.m_width;
			size++;
			newWidget.m_navPos = ivec2(size, 2);

			newWidget.SetSkill(skill);
			m_skillList.AddChild(newWidget);
		}

		width += m_skillList.m_spacing * (size - 1);
		m_skillList.m_width = width;

		navOffset = ivec2(0, 2);

		// Equipment
		m_equipmentList.ClearChildren();
		m_equipmentItems.removeRange(0, m_equipmentItems.length());
		
		width = 0;
		size = 0;
		for (uint i = 0; i < plrClass.m_startingEquipment.length(); i++)
		{
			auto equipment = Equipment::BaseItem::Get(plrClass.m_startingEquipment[i]);
			if (equipment is null)
				continue;

			Equipment::Item equip;
			equip.quality = Item::Quality::Common;
			@equip.baseItem = equipment;
			equip.Finalize(1.0f, 1, 0, null, null);

			m_equipmentItems.insertLast(equip);

			auto newWidget = cast<EquipmentItemWidget>(m_equipmentTemplate.Clone());
			newWidget.SetID("");
			newWidget.m_visible = true;
			newWidget.m_navPos = navOffset;

			navOffset.x += 1;
			if (navOffset.x % 6 == 0)
			{
				navOffset.x = 0;
				navOffset.y += 1;
			}

			width += newWidget.m_width;
			size++;
			newWidget.m_navPos = ivec2(size, 3);

			newWidget.Set(equip);
			m_equipmentList.AddChild(newWidget);
		}

		width += m_equipmentList.m_spacing * (size - 1);
		m_equipmentList.m_width = width;


		RefreshInteractableWidgets(m_widget);
	}

	void Draw(SpriteBatch& sb, int idt) override
	{
		MenuTab::Draw(sb, idt);

		if (m_classList !is null)
		{
			vec4 colB = vec4(fadeColor.x, fadeColor.y, fadeColor.z, 0.0f);

			{
				vec2 origin = m_classList.m_origin + vec2(0, 15);
				vec2 target = origin + vec2(int(m_classList.m_width * 0.25f), 0);
				sb.DrawLineFade(origin, target, m_classTemplate.m_height + 5, fadeColor, colB);
			}

			{
				vec2 origin = m_classList.m_origin + vec2(m_classList.m_width, 15);
				vec2 target = origin - vec2(int(m_classList.m_width * 0.25f), 0);
				sb.DrawLineFade(origin, target, m_classTemplate.m_height + 5, fadeColor, colB);
			}
		}
	}

	void OnFunc(Widget@ sender, const string &in name) override
	{
		print("CreateCharacterMenuClassTab::" + name);

		array<string> parse = name.split(" ");
		if (parse[0] == "select")
			SelectClass(parse[1]);
		else if (parse[0] == "name-random")
			m_nameInput.SetText(m_randomNameGen.GenerateName());
		else if (parse[0] == "create")
			m_manager.GetCurrentWindow().OnFunc(sender, name);
		else if (parse[0] == "nextclass")
			StepClass(1);
		else if (parse[0] == "prevclass")
			StepClass(-1);
	}
}