class_name InfoDevicesTab extends InfoTab

###########################
## Блок «Пульт и провода» во вкладке «Настройки» (ATTN_10 D4, U5a.4)
###########################
## Встроен в InfoSettingsTab (embed), создается кодом. У 3D-пульта: модель, выводы, «Автопроводка», сброс защиты, общий флаг «проводка обязательна».
## У провода: «Скрутка» (меняет полярность), куда ведёт.

var _src_box: VBoxContainer
var _src_info: Label
var _wiring_req: CheckBox
var _wire_box: VBoxContainer
var _wire_info: Label
var _twist: CheckBox
var _syncing := false


func _setup() -> void:
	var box := make_page("Пульт и провода")
	block_heading(box, "Пульт и провода")

	_src_box = VBoxContainer.new()
	box.add_child(_src_box)
	_src_info = Label.new()
	_src_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_src_info.custom_minimum_size = Vector2(120, 0)
	_src_box.add_child(_src_info)
	var auto_btn := Button.new()
	auto_btn.text = "Автопроводка (провода к клипам по меткам)"
	auto_btn.pressed.connect(_on_autowire_pressed)
	_src_box.add_child(auto_btn)
	var reset_btn := Button.new()
	reset_btn.text = "Сбросить защиту источника"
	reset_btn.pressed.connect(_on_reset_pressed)
	_src_box.add_child(reset_btn)
	_wiring_req = CheckBox.new()
	_wiring_req.text = "Проводка обязательна (клип без провода обесточен)"
	_wiring_req.toggled.connect(_on_wiring_required_toggled)
	_src_box.add_child(_wiring_req)

	_wire_box = VBoxContainer.new()
	box.add_child(_wire_box)
	_wire_info = Label.new()
	_wire_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_wire_info.custom_minimum_size = Vector2(120, 0)
	_wire_box.add_child(_wire_info)
	_twist = CheckBox.new()
	_twist.text = "Скрутка (поменять полярность)"
	_twist.toggled.connect(_on_twist_toggled)
	_wire_box.add_child(_twist)
	var del_hint := Label.new()
	del_hint.text = "Удалить провод: Del"
	del_hint.theme_type_variation = &"LabelDim"
	_wire_box.add_child(del_hint)


func can_show(entity: Entity) -> bool:
	if entity == null or entity.has_comp(C_Ghost):
		return false
	return entity.has_comp(C_PowerSource) or entity.has_comp(C_Wire)


func _on_bind() -> void:
	footer_message(&"auto_src", "")
	refresh()


func refresh() -> void:
	if target == null:
		return
	var ps := target.get_comp(C_PowerSource) as C_PowerSource
	var w := target.get_comp(C_Wire) as C_Wire
	_src_box.visible = ps != null
	_wire_box.visible = w != null
	_syncing = true
	if ps != null and ps.source != null:
		var s := ps.source
		var lines: PackedStringArray = ["Модель: %s, источник %d" % [String(s.data().get("name", s.model)), s.id]]
		for o in s.outputs:
			lines.append("Вывод %d%s: %+d%%, %.2f А из %.1f А, %s" % [o.label, (" " + o.suffix) if o.suffix != "" else "", o.command, o.current, o.i_max, o.state_text()])
		if s.estop:
			lines.append("Аварийный стоп включён")
		_src_info.text = "\n".join(lines)
		_wiring_req.set_pressed_no_signal(PGM.wiring_required)
	if w != null:
		var t := w.a if is_instance_valid(w.a) and w.a.is_upstream() else w.b
		var lines2: PackedStringArray = []
		if is_instance_valid(t) and t.role == PowerTerminal.Role.SRC:
			lines2.append("От вывода %d" % t.output_label)
		lines2.append("Скрутка: %s" % ("да" if w.twist else "нет"))
		if not w.is_valid_wire():
			lines2.append("Не подключён: свободный конец, тока нет")   # XX claude-wire W5
		_wire_info.text = "\n".join(lines2)
		_twist.set_pressed_no_signal(w.twist)
	_syncing = false


func _on_autowire_pressed() -> void:
	var ps := target.get_comp(C_PowerSource) as C_PowerSource if target else null
	if ps == null:
		return
	var n := ps.autowire(target.get_parent())
	if n > 0:
		footer_message(&"auto_src", "Создано проводов: %d" % n, &"ok")
	else:
		footer_message(&"auto_src", "Нечего подключать: нет клипов с метками этого источника или они уже с проводом", &"warn")
	refresh()


func _on_reset_pressed() -> void:
	var ps := target.get_comp(C_PowerSource) as C_PowerSource if target else null
	if ps and ps.source:
		PGM.reset_protection(ps.source)


func _on_wiring_required_toggled(on: bool) -> void:
	if _syncing:
		return
	PGM.wiring_required = on
	PGM.request_recalculate()


func _on_twist_toggled(_on: bool) -> void:
	if _syncing:
		return
	var w := target.get_comp(C_Wire) as C_Wire if target else null
	if w:
		w.toggle_twist()
	refresh()
