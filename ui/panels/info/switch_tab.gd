class_name InfoSwitchTab extends InfoTab

###########################
## Блок «Стрелка» во вкладке «Настройки» (отладка, XX claude-switch, U5a.4)
###########################
## Встроен в InfoSettingsTab (embed), создается кодом. Меняет СОСТОЯНИЕ C_Switch в игре, паспорт (SwitchConfig) не трогает.
## Отказ перекладки идет в подвал вкладки.

const SWITCH_REASONS := {
	&"moving": "идет перекладка",
	&"occupied": "на стрелке вагон (замок)",
	&"single_route": "у трака один маршрут",
	&"bad_route": "нет такого маршрута",
	&"manual_only": "стрелка ручная",
	&"remote_only": "стрелка дистанционная",
	&"no_power": "нет питания привода (шина аксессуаров)",
}

var _sw_status: Label
var _sw_control: OptionButton
var _sw_routing: CheckBox
var _sw_frog: OptionButton
var _sw_syncing := false   # идет программная расстановка виджетов: сигналы не обрабатываем


func _setup() -> void:
	var box := make_page("Стрелка")
	block_heading(box, "Стрелка")

	var hint := Label.new()
	hint.text = "Отладка: меняет состояние стрелки в игре, паспорт не трогает"
	hint.theme_type_variation = &"LabelDim"
	box.add_child(hint)

	_sw_status = Label.new()
	box.add_child(_sw_status)

	var throw_btn := Button.new()
	throw_btn.text = "Переложить (в обход рычага)"
	throw_btn.pressed.connect(_on_switch_throw_pressed)
	box.add_child(throw_btn)

	var l1 := Label.new()
	l1.text = "Управление"
	box.add_child(l1)
	_sw_control = OptionButton.new()
	_sw_control.add_item("Ручное (рычаг у носка)")
	_sw_control.add_item("Дистанционное (пульт, клавиша T)")
	_sw_control.item_selected.connect(_on_switch_control_selected)
	box.add_child(_sw_control)

	_sw_routing = CheckBox.new()
	_sw_routing.text = "Power routing (E1): ток только на выбранную ветку"
	_sw_routing.toggled.connect(_on_switch_routing_toggled)
	box.add_child(_sw_routing)

	var l2 := Label.new()
	l2.text = "Крестовина (E2)"
	box.add_child(l2)
	_sw_frog = OptionButton.new()
	_sw_frog.add_item("Пластиковая (КЗ нет)")
	_sw_frog.add_item("Токопроводящая, привязана к пути 0")
	_sw_frog.add_item("Токопроводящая, переключаемая")
	_sw_frog.item_selected.connect(_on_switch_frog_selected)
	box.add_child(_sw_frog)



func can_show(entity: Entity) -> bool:
	return _switch_of(entity) != null


static func _switch_of(entity: Entity) -> C_Switch:
	if entity == null or entity.has_comp(C_Ghost):
		return null
	return entity.get_comp(C_Switch) as C_Switch


func _get_switch() -> C_Switch:
	return _switch_of(target)


func _on_bind() -> void:
	footer_message(&"switch", "")
	_update_switch_tab()


## Статус стрелки живой: рычаг, привод и пульт меняют положение без участия панели
func refresh() -> void:
	_update_switch_tab()


func _update_switch_tab() -> void:
	var sw := _get_switch()
	if sw == null:
		return
	var pt := target.get_comp(C_PowerTrack) as C_PowerTrack
	var route_txt := "Прямо (0)" if sw.route == 0 else "Ответвление (%d)" % sw.route
	var state_txt := "идет перекладка" if sw.state == C_Switch.State.MOVING else "готова"
	var lock_txt := "на стрелке вагон" if sw.is_occupied() else "свободна"
	var frog_txt := "нет"
	if sw.frog_s.size() >= 2 and sw.frog_s[1] >= 0.0:
		frog_txt = "%.1f ю (прямо), %.1f ю (ответвление)" % [sw.frog_s[0], sw.frog_s[1]]
	_sw_status.text = "Положение: %s\nСостояние: %s\nЗамок: %s\nКонтур: %s\nКрестовина на: %s" % [
			route_txt, state_txt, lock_txt, pt.contour_text() if pt else "-", frog_txt]
	_sw_syncing = true
	_sw_control.select(int(sw.control))
	_sw_routing.set_pressed_no_signal(sw.power_routing)
	_sw_frog.select(int(sw.frog))
	_sw_syncing = false


func _on_switch_throw_pressed() -> void:
	var sw := _get_switch()
	if sw == null:
		return
	var d := {"route": -1, "source": &"force"}
	target.send_event("on_switch_request", d)
	footer_message(&"switch", "" if d.get("ok", false) else "Отказ: %s" % SWITCH_REASONS.get(d.get("reason", &""), String(d.get("reason", &""))), &"bad")
	_update_switch_tab()


func _on_switch_control_selected(index: int) -> void:
	var sw := _get_switch()
	if sw and not _sw_syncing:
		sw.set_control(index as C_Switch.Drive)


func _on_switch_routing_toggled(on: bool) -> void:
	var sw := _get_switch()
	if sw and not _sw_syncing:
		sw.set_power_routing(on)


func _on_switch_frog_selected(index: int) -> void:
	var sw := _get_switch()
	if sw and not _sw_syncing:
		sw.set_frog_mode(index as C_Switch.Frog)
