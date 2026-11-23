class_name InfoMechTab extends InfoTab

###########################
## Блок «Механизмы» и «Свет» во вкладке «Вид»: слайдеры, открыть всё, яркость, авто (U5a.3)
###########################
## Встроен в InfoVisualTab (embed), создается кодом. Виден только у сущностей с C_Mechanisms, у которых есть механизмы
## или источники света. Цвет статуса из темы (LampBad, LampWarn).

var _mech_list: VBoxContainer
var _mech_rows: Dictionary = {}      # StringName -> {slider, check, enabled, status}
var _mech_drag: StringName = &""     # id механизма, чей слайдер тянут сейчас
var _light_rows: Dictionary = {}     # StringName -> {slider, check, enabled, status}
var _light_drag: StringName = &""    # id источника света, чей слайдер тянут сейчас


func _setup() -> void:
	_mech_list = make_page("Механизмы")


func can_show(entity: Entity) -> bool:
	var comp := _comp_of(entity)
	return comp != null and not (comp.get_list().is_empty() and comp.get_light_list().is_empty())


static func _comp_of(entity: Entity) -> C_Mechanisms:
	if entity == null or entity.has_comp(C_Ghost):
		return null
	return entity.get_comp(C_Mechanisms) as C_Mechanisms


func _get_mech_comp() -> C_Mechanisms:
	return _comp_of(target)


func _on_bind() -> void:
	_rebuild_mech_tab()


func refresh() -> void:
	_update_mech_tab()


## Пересобирает строки при смене цели
func _rebuild_mech_tab() -> void:
	for c in _mech_list.get_children():
		_mech_list.remove_child(c)
		c.queue_free()
	_mech_rows.clear()
	_light_rows.clear()
	_mech_drag = &""
	_light_drag = &""

	var comp := _get_mech_comp()
	if comp == null:
		return
	var mechs := comp.get_list()
	var lamps := comp.get_light_list()
	if mechs.is_empty() and lamps.is_empty():
		return

	if not mechs.is_empty():
		var mech_head := Label.new()
		mech_head.text = "Механизмы"
		mech_head.theme_type_variation = &"LabelDim"
		_mech_list.add_child(mech_head)
	for item in mechs:
		_add_mech_row(item)

	if not mechs.is_empty():
		var all_row := HFlowContainer.new()
		var b_open := Button.new()
		b_open.text = "Открыть всё"
		b_open.pressed.connect(_on_mech_all.bind(1.0))
		var b_close := Button.new()
		b_close.text = "Закрыть всё"
		b_close.pressed.connect(_on_mech_all.bind(0.0))
		all_row.add_child(b_open)
		all_row.add_child(b_close)
		_mech_list.add_child(all_row)

	if not lamps.is_empty():
		if not mechs.is_empty():
			_mech_list.add_child(HSeparator.new())
		var head := Label.new()
		head.text = "Свет"
		head.theme_type_variation = &"LabelDim"
		_mech_list.add_child(head)
		for item in lamps:
			_add_light_row(item)
		var l_row := HFlowContainer.new()
		var b_on := Button.new()
		b_on.text = "Включить весь"
		b_on.pressed.connect(_on_light_all.bind(1.0))
		var b_off := Button.new()
		b_off.text = "Выключить весь"
		b_off.pressed.connect(_on_light_all.bind(0.0))
		l_row.add_child(b_on)
		l_row.add_child(b_off)
		_mech_list.add_child(l_row)
	_update_mech_tab()


## Каркас строки: заголовок мелким шрифтом слева и статус справа, ниже идут элементы управления (U5a.3).
## Заголовок обрезается многоточием, статус короткий, поэтому ширина строки задается только нижним рядом
func _row_box(title_text: String, status: Label) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = title_text
	title.tooltip_text = title_text
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.theme_type_variation = &"LabelSmall"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.custom_minimum_size.x = 40
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(title)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status.mouse_filter = Control.MOUSE_FILTER_PASS   # подсказка с полным текстом статуса
	head.add_child(status)
	box.add_child(head)
	return box


func _add_mech_row(item: Dictionary) -> void:
	var id: StringName = item.id
	var status := Label.new()
	var box := _row_box(item.title, status)

	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 6)
	box.add_child(ctl)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.custom_minimum_size.x = 60
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.drag_started.connect(func(): _mech_drag = id)
	slider.drag_ended.connect(func(_changed): _mech_drag = &"")
	slider.value_changed.connect(func(v): if _mech_drag == id: _send_mech(id, v))
	ctl.add_child(slider)

	var check := CheckButton.new()
	check.text = "Откр."
	check.tooltip_text = "Открыто"
	check.toggled.connect(func(on): _send_mech(id, 1.0 if on else 0.0))
	ctl.add_child(check)

	var en := CheckBox.new()
	en.text = "вкл"
	en.tooltip_text = "Выключенный механизм не реагирует на команды"
	en.toggled.connect(func(on):
		var comp := _get_mech_comp()
		if comp: comp.set_enabled(id, on))
	ctl.add_child(en)

	_mech_list.add_child(box)
	_mech_rows[id] = {"slider": slider, "check": check, "enabled": en, "status": status}


func _add_light_row(item: Dictionary) -> void:
	var id: StringName = item.id
	var status := Label.new()
	var box := _row_box(item.title, status)

	# Слайдер = яркость: множитель к energy из конфига (0..GAIN_MAX). Включение и выключение - кнопка "Горит"
	var bright := HBoxContainer.new()
	bright.add_theme_constant_override("separation", 6)
	box.add_child(bright)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = LightConfig.GAIN_MAX
	slider.step = 0.05
	slider.tooltip_text = "Яркость (множитель к энергии из конфига)"
	slider.custom_minimum_size.x = 60
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.drag_started.connect(func(): _light_drag = id)
	slider.drag_ended.connect(func(_changed): _light_drag = &"")
	slider.value_changed.connect(func(v): if _light_drag == id: _send_light_gain(id, v))
	bright.add_child(slider)
	var gain_label := Label.new()
	gain_label.custom_minimum_size.x = 40
	gain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bright.add_child(gain_label)

	# Кнопки под слайдером: при нехватке места переносятся на следующую строку, ширину не растят
	var btns := HFlowContainer.new()
	btns.add_theme_constant_override("h_separation", 6)
	box.add_child(btns)
	var check := CheckButton.new()
	check.text = "Горит"
	check.toggled.connect(func(on): _send_light(id, 1.0 if on else 0.0))
	btns.add_child(check)
	var auto := Button.new()
	auto.text = "Авто"
	auto.tooltip_text = "Вернуть источник правилу (ночь, направление движения)"
	auto.pressed.connect(func(): _send_light_auto(id))
	btns.add_child(auto)
	var en := CheckBox.new()
	en.text = "вкл"
	en.tooltip_text = "Выключенный источник не реагирует на команды и правила"
	en.toggled.connect(func(on):
		var comp := _get_mech_comp()
		if comp: comp.set_light_enabled(id, on))
	btns.add_child(en)

	_mech_list.add_child(box)
	_light_rows[id] = {"slider": slider, "gain_label": gain_label, "check": check, "auto": auto, "enabled": en, "status": status}


## Пока вкладка открыта. Только синхронизация вида, команд не шлёт (set_*_no_signal)
func _update_mech_tab() -> void:
	var comp := _get_mech_comp()
	if comp == null:
		return
	_update_light_rows(comp)
	for item in comp.get_list():
		var r: Dictionary = _mech_rows.get(item.id, {})
		if r.is_empty():
			continue
		var usable: bool = item.enabled and item.found
		if _mech_drag != item.id:
			r.slider.set_value_no_signal(item.t)
		r.slider.editable = usable
		r.check.set_pressed_no_signal(item.target > 0.5)
		r.check.disabled = not usable
		r.enabled.set_pressed_no_signal(item.enabled)
		r.enabled.disabled = not item.found
		if not item.found:
			_set_status(r.status, "нет части", &"LampBad", "В модели нет части этого механизма")
		else:
			_set_status(r.status, "..." if item.moving else "%d%%" % roundi(item.t * 100.0))


func _update_light_rows(comp: C_Mechanisms) -> void:
	for item in comp.get_light_list():
		var r: Dictionary = _light_rows.get(item.id, {})
		if r.is_empty():
			continue
		var usable: bool = item.enabled and item.found
		var has_rule: bool = item.rule != LightConfig.Rule.COMMAND
		if _light_drag != item.id:
			r.slider.set_value_no_signal(item.gain)
		r.slider.editable = usable
		r.gain_label.text = "%d%%" % roundi(item.gain * 100.0)
		r.check.set_pressed_no_signal(item.target > 0.5)
		r.check.disabled = not usable
		r.auto.disabled = not (usable and has_rule and item.manual)
		r.enabled.set_pressed_no_signal(item.enabled)
		r.enabled.disabled = not item.found
		if not item.found:
			_set_status(r.status, "нет света", &"LampBad", "В модели нет этого источника света")
		elif item.no_power and item.target > 0.5:
			_set_status(r.status, "нет тока", &"LampWarn", "Нет питания: свет не горит")
		elif item.culled:
			var q: QualityPreset = GFX.get_quality()
			_set_status(r.status, "свечение" if (q and q.entity_light_emissive_only) else "бюджет", &"LampWarn",
				"Источник света отключён настройками качества: только свечение" if (q and q.entity_light_emissive_only) else "Источник света отключён по бюджету источников")
		elif item.changing:
			_set_status(r.status, "...")
		elif has_rule:
			_set_status(r.status, "ручн." if item.manual else "авто")
		else:
			_set_status(r.status, "%d%%" % roundi(item.t * 100.0))


## Подпись статуса: текст, вариация темы (пусто = обычный цвет) и подсказка с полным текстом
static func _set_status(label: Label, text: String, variation: StringName = &"", tip: String = "") -> void:
	label.text = text
	label.tooltip_text = tip
	if label.theme_type_variation != variation:
		label.theme_type_variation = variation


func _send_light(id: StringName, state: float) -> void:
	if target:
		target.send_event("on_light_set", {"id": id, "state": state})


func _send_light_gain(id: StringName, gain: float) -> void:
	if target:
		target.send_event("on_light_gain", {"id": id, "gain": gain})


func _send_light_auto(id: StringName) -> void:
	if target:
		target.send_event("on_light_auto", {"id": id})


func _on_light_all(state: float) -> void:
	var comp := _get_mech_comp()
	if comp == null:
		return
	for item in comp.get_light_list():
		_send_light(item.id, state)


func _send_mech(id: StringName, state: float) -> void:
	if target:
		target.send_event("on_mechanism_set", {"id": id, "state": state})


func _on_mech_all(state: float) -> void:
	var comp := _get_mech_comp()
	if comp == null:
		return
	for item in comp.get_list():
		_send_mech(item.id, state)
