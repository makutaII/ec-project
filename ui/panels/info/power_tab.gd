class_name InfoPowerTab extends InfoTab

###########################
## Вкладка «Питание»: контур и напряжение трака, клипса питания, контур и напряжение локомотива
###########################
## Видна только у объектов с питанием: у трака с C_PowerTrack и у локомотива с C_Engine (U5a.2).
## Узлы в info_panel.tscn (PowerTab). Трак обновляется по сигналам PGM (update_tab, on_power_track_updated),
## локомотив живыми значениями в refresh(). Скорость и центробежная сила убраны (DebugPanel), радиус, угол и длину
## показывают «Сведения».
## D1 (ATTN_10): блок «PowerExtras» строится кодом под таблицей трака: «Поменять полярность» (клип),
## «Изостыки» (чекбокс на каждый сокет трака, доступны и без клипа), датчик занятости.
## Подвал вкладки (U5a.2): состояние цепи, конфликты клипа, КЗ, перегрузка, состояние датчика и кнопка «Сбросить защиту вывода».

## Сколько строк состояния цепи может быть в подвале одновременно
const STATE_SLOTS := 6

var _extra: VBoxContainer
var _sensor_box: CheckBox
var _rev_box: CheckBox
var _reset_btn: Button
var _gap_title: Label
var _gap_row: HFlowContainer
var _gap_boxes: Array[CheckBox] = []
## Для какой сущности построены чекбоксы изостыков
var _gap_for: Entity


func _setup() -> void:
	_n("PowerClipButton").pressed.connect(_on_power_clip_button_pressed)
	_n("ClipContourIDButton").item_selected.connect(_on_contour_id_item_selected)
	_build_extras()
	PGM.sensor_triggered.connect(func(_s: C_OccupancySensor, _o: bool) -> void: update_tab())


## Питание есть у трака с C_PowerTrack и у локомотива с C_Engine
func can_show(entity: Entity) -> bool:
	return entity != null and (entity.has_comp(C_PowerTrack) or entity.has_comp(C_Engine))


func components_changed() -> void:
	if target == null:
		return
	update_tab()
	panel.refresh_tab_visibility()


func _on_bind() -> void:
	_gap_for = null
	update_tab()


## Кнопка действия в подвале: сброс защиты вывода (видна, только когда вывод отключен защитой)
func _setup_footer() -> void:
	_reset_btn = Button.new()
	_reset_btn.text = "Сбросить защиту вывода"
	_reset_btn.visible = false
	_reset_btn.pressed.connect(_on_reset_pressed)
	footer_add_action(_reset_btn)


## Блок D1 под таблицей трака (в info_panel.tscn не правится)
func _build_extras() -> void:
	var host := _n("PowerTrackTab") as VBoxContainer
	if host == null:
		return
	_extra = VBoxContainer.new()
	_extra.name = "PowerExtras"
	host.add_child(_extra)

	_rev_box = CheckBox.new()
	_rev_box.text = "Поменять полярность (провода клипа)"
	_rev_box.toggled.connect(_on_reversed_toggled)
	_extra.add_child(_rev_box)

	_gap_title = Label.new()
	_gap_title.text = "Изостыки (разрыв цепи на стыке):"
	_extra.add_child(_gap_title)
	_gap_row = HFlowContainer.new()
	_extra.add_child(_gap_row)

	# D6: датчик занятости участка
	_sensor_box = CheckBox.new()
	_sensor_box.text = "Датчик занятости участка"
	_sensor_box.toggled.connect(_on_sensor_toggled)
	_extra.add_child(_sensor_box)


func update_tab() -> void:
	if not target: return
	var power_comp := target.get_comp(C_PowerTrack) as C_PowerTrack
	if power_comp != null:
		_update_track(power_comp)
	elif target.has_comp(C_Engine):
		_n("PowerTrackTab").hide()
		_n("PowerTrainTab").show()
		refresh()


## Трак: контур, напряжение, полярность, клип и блок «PowerExtras»
func _update_track(power_comp: C_PowerTrack) -> void:
	_n("PowerTrackTab").show()
	_n("PowerTrainTab").hide()

	var power_clip := target.get_comp(C_PowerClip) as C_PowerClip
	_update_extras(power_comp, power_clip)

	# XX claude-switch: у кросса с раздельными цепями "1 | 2" (по лучу на путь)
	_n("TrackContourLabel").text = power_comp.contour_text()
	_n("TrackVoltageLabel").text = power_comp.voltage_text()
	_n("FlippedLabel").text = power_comp.flip_text()

	# Power Clip. D1: клип можно поставить на любой трак, в том числе уже питаемый (второй фидер цепи)
	_n("PowerClipButton").disabled = false
	_n("PowerClipButton").button_pressed = power_clip != null
	_n("ClipContourIDButton").disabled = power_clip == null  # номер меняется только у клипа
	var _net_id: int = power_clip.net_id if power_clip else power_comp.net_id

	# 💡-option_button- Делаем селектор контура-
	_fill_clip_contour_button(_net_id)

	_set_lamp(_n("TrackVoltageLabel") as Label, PGM.get_power(_net_id))


## Локомотив: контур и напряжение его источника питания
func refresh() -> void:
	if not target: return
	var engine := target.get_comp(C_Engine) as C_Engine
	if engine == null: return

	_n("EngineContourLabel").text = str(engine.power.net_id)
	_n("TrainVoltageLabel").text = str(engine.power.voltage)
	_set_lamp(_n("TrainVoltageLabel") as Label, PGM.get_power(engine.power.net_id))


## Цвет напряжения из темы: плюс (LampOn), минус (LampBad), ноль (обычный)
func _set_lamp(label: Label, value: float) -> void:
	var variation: StringName = &"LampOn" if value > 0.0 else (&"LampBad" if value < 0.0 else &"")
	if label.theme_type_variation != variation:
		label.theme_type_variation = variation


func on_power_track_updated(_contour : int, _voltage : float) ->void:
	if not target: return

	var _power_comp := target.get_comp(C_PowerTrack) as C_PowerTrack
	if _power_comp: # Если трак
		_n("TrackContourLabel").text = _power_comp.contour_text()
		_n("TrackVoltageLabel").text = _power_comp.voltage_text()
		_n("FlippedLabel").text = _power_comp.flip_text()
		_set_lamp(_n("TrackVoltageLabel") as Label, _voltage)


func _on_contour_id_item_selected(index: int):
	if not target: return
	
	var power_clip = target.has_comp(C_PowerClip)
	if power_clip:
		power_clip = target.get_comp(C_PowerClip)

	if not power_clip: return
	
	# Извлекаем зашитый ID контура из выбранного пункта меню
	var new_contour_id = _n("ClipContourIDButton").get_item_id(index)
	
	# Если значение изменилось — обновляем данные компонента
	if power_clip.net_id != new_contour_id:
		power_clip.set_contour(new_contour_id)
		# Вешаем на трак новый контур (пересчет сети поправит остальные траки)
		target.get_comp(C_PowerTrack).net_id = new_contour_id
		
		#await get_tree().physics_frame
		
		PGM.request_recalculate()
		# На всякий случай перерисовываем панель, чтобы закрепить состояние
		update_tab()


func _on_power_clip_button_pressed() -> void:
	
	if not target or not target.has_comp(C_PowerTrack):
		return # это powertrack?
	
	var _btn_pressed: bool = _n("PowerClipButton").button_pressed
	# Выбор контура: трак уже в цепи (второй фидер), иначе номер из списка (0 = первый свободный)
	var _contour: int = (target.get_comp(C_PowerTrack) as C_PowerTrack).net_id
	if _contour == 0:
		var _btn := _n("ClipContourIDButton") as OptionButton
		_contour = _btn.get_item_id(_btn.selected) if _btn.selected >= 0 else 0
	
	# Менеджер проверит и создаст (0 если свободных номеров нет)
	_contour = PGM.create_power_clip(target, _contour, _btn_pressed)
	if _btn_pressed and _contour == 0:
		_n("PowerClipButton").button_pressed = false
	update_tab()


func _fill_clip_contour_button(_current_contour_id) -> void:
	var option_button = _n("ClipContourIDButton") as OptionButton
	option_button.clear() # Полностью очищаем старые пункты
	
	# 1.1️⃣ Добавляем базовый вариант (0 - отключено от питания)
	option_button.add_item("0: Отключено", 0)
	
	# Получаем массив контуров, которые УЖЕ заняты другими клеммами на макете
	var occupied_contours = PGM.get_occupied_contours()
	var current_id = _current_contour_id # Текущий контур этого объекта

	# 2. 2️⃣ Все номера: у цепи может быть несколько фидеров, занятый номер отмечается, но выбирается
	# D2: список выводов всех источников («Вывод 3», у dual «Вывод 11 · A»), не только 10 первых
	for i in PGM.all_labels():
		var _text := PGM.label_text(i)
		if i != current_id and i in occupied_contours:
			_text += " (занят)"
		else:
			_text += " (свободен)"
		option_button.add_item(_text, i) # Текст и внутренний ID элемента
	
	# 3. 3️⃣ Выставляем визуальный фокус на текущий контур объекта
	# Так как мы передавали реальный ID контура вторым аргументом в add_item,
	# мы можем легко найти индекс нужной строки
	for idx in range(option_button.item_count):
		if option_button.get_item_id(idx) == current_id:
			option_button.select(idx)
			break


## Блок D1: состояние цепи, «Поменять полярность», изостыки
func _on_sensor_toggled(on: bool) -> void:
	if target == null:
		return
	if on and not target.has_comp(C_OccupancySensor):
		target.add_component(C_OccupancySensor.new())
	elif not on:
		target.remove_component(C_OccupancySensor)
	_update_extras(target.get_comp(C_PowerTrack) as C_PowerTrack, target.get_comp(C_PowerClip) as C_PowerClip)


func _update_extras(power_track: C_PowerTrack, clip: C_PowerClip) -> void:
	if _extra == null:
		return
	_extra.visible = power_track != null
	if power_track == null:
		footer_clear()
		return
	var sensor := target.get_comp(C_OccupancySensor) as C_OccupancySensor
	_sensor_box.set_pressed_no_signal(sensor != null)
	if sensor != null:
		footer_message(&"sensor", "Участок %s. Проходов (освобождений): %d" % [sensor.state_text(), sensor.passes], &"warn" if sensor.occupied else &"ok")
	else:
		footer_message(&"sensor", "")

	# Состояние: что не так с клипом, треком или цепью. Строки идут в подвал, у каждой свой тип
	var lines: Array = []   # [текст, тип]
	if clip and clip.conflict_text() != "":
		lines.append([clip.conflict_text(), &"warn"])
	if power_track.fault:
		lines.append(["КЗ: здесь не сходится полярность (реверсивная петля или перепутанные провода)", &"bad"])
	if clip and clip.wired:
		if clip.wire_net != 0:
			lines.append(["Питается по проводу от вывода %d%s" % [clip.wire_net, " (скрутка)" if clip.wire_flip else ""], &"info"])
		else:
			lines.append(["Провод подключен, но не доходит до вывода пульта: клип обесточен", &"warn"])
	elif clip and PGM.wiring_required:
		lines.append(["Проводка обязательна: клипу нужен провод от пульта", &"warn"])
	var net_id: int = clip.net_id if clip else power_track.net_id
	if net_id != 0 and PGM.shorted_nets.has(net_id):
		lines.append(["Цепь %d в КЗ полярности: защита отключает напряжение (сброс: кнопка ниже после устранения причины)" % net_id, &"bad"])
	var out: PowerOutput = PGM.get_output(net_id) if net_id != 0 else null
	if out != null and out.tripped:
		lines.append(["Вывод %d отключен защитой: %s" % [net_id, out.state_text()], &"bad"])
	elif out != null and out.state == PowerOutput.State.OVERLOAD:
		lines.append(["Перегрузка вывода %d: %.2f А при лимите %.2f А" % [net_id, out.current, out.i_max], &"warn"])
	for i in STATE_SLOTS:
		if i < lines.size():
			footer_message(StringName("state%d" % i), lines[i][0], lines[i][1])
		else:
			footer_message(StringName("state%d" % i), "")
	_reset_btn.visible = out != null and out.tripped
	refresh_footer()

	# Полярность подключения клипа
	_rev_box.visible = clip != null
	if clip:
		_rev_box.set_pressed_no_signal(clip.reversed)

	# Изостыки: чекбокс на каждый сокет (пересобираются при смене цели)
	var sock := target.get_comp(C_Socket) as C_Socket
	var count: int = sock.sockets.size() if sock else 0
	if _gap_for != target or _gap_boxes.size() != count:
		_rebuild_gap_boxes(sock, count)
	for i in _gap_boxes.size():
		_gap_boxes[i].set_pressed_no_signal(sock.is_gap(i))
	var gaps_on: bool = PGM.rules.gaps_enabled   # D7: при gaps_enabled = false изостыки скрыты
	_gap_title.visible = count > 0 and gaps_on
	_gap_row.visible = count > 0 and gaps_on


func _rebuild_gap_boxes(sock: C_Socket, count: int) -> void:
	for b in _gap_boxes:
		if is_instance_valid(b):
			b.queue_free()
	_gap_boxes.clear()
	_gap_for = target
	for i in count:
		var box := CheckBox.new()
		box.text = "%d: %s" % [i, sock.socket_label(i)]
		box.toggled.connect(_on_gap_toggled.bind(i))
		_gap_row.add_child(box)
		_gap_boxes.append(box)


func _on_reversed_toggled(on: bool) -> void:
	if not target:
		return
	var clip := target.get_comp(C_PowerClip) as C_PowerClip
	if clip:
		clip.set_reversed(on)


func _on_gap_toggled(on: bool, socket_index: int) -> void:
	if not target:
		return
	var sock := target.get_comp(C_Socket) as C_Socket
	if sock:
		sock.set_gap(socket_index, on)


## Сброс защиты вывода этого фидера. Если причина не устранена, защита сработает снова
func _on_reset_pressed() -> void:
	if not target:
		return
	var clip := target.get_comp(C_PowerClip) as C_PowerClip
	var pt := target.get_comp(C_PowerTrack) as C_PowerTrack
	var net_id: int = clip.net_id if clip else (pt.net_id if pt else 0)
	if net_id != 0:
		PGM.reset_output(net_id)
	update_tab()
