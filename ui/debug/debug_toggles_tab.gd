class_name DebugTogglesTab extends DebugTab

###########################
## Вкладка «Toggles»: отладочные выключатели и действия (U14)
###########################
## Выключатели читают и пишут флаги Global (и V-Sync окна). Флаги может переключить и клавиша (например, V-Sync на Ctrl+Shift+V),
## поэтому refresh() возвращает галочки в синхрон с реальным состоянием.
## Старые пункты меню-заглушки: «ничего» (очистка сцены) переехал сюда кнопкой с подтверждением. Пункты «++» и
## «jolt profile» ничего не делали (код закомментирован), их переносить нечего: убираются из TopPanel вместе с меню (U10).

## Выключатели: {check: CheckBox, get: Callable}
var _toggles: Array[Dictionary] = []
var _save_manager: SaveManager
var _confirm: ConfirmationDialog
var _preset: OptionButton
var _rules_label: Label
var _bus_check: CheckBox
var _bus_label: Label
var _bus_limit: SpinBox   # XX claude-car CS4a: предел тока шины, А


func _init() -> void:
	name = &"Toggles"
	add_child(make_header("Камера"))
	_add_toggle("Свободная камера", "Без границ комнаты и пределов сдвига, зум до 1000, наклон до +15 градусов (взгляд снизу)", "Gimbal.free_camera",
			func() -> bool:
				var g := (Engine.get_main_loop() as SceneTree).root.get_node_or_null("GameRoot/Gimbal") as Gimbal
				return g != null and g.free_camera,
			func(on: bool) -> void:
				var g := (Engine.get_main_loop() as SceneTree).root.get_node_or_null("GameRoot/Gimbal") as Gimbal
				if g:
					g.set_free_camera(on))
	add_child(make_header("Комната"))
	_add_toggle("Комната (стены и мебель)", "Скрывает стены, пол и мебель. Стол, свет и границы камеры остаются", "RoomBuilder.set_room_visible",
			func() -> bool:
				var r := _room()
				return r == null or r.is_room_visible(),
			func(on: bool) -> void:
				var r := _room()
				if r:
					r.set_room_visible(on))
	_add_toggle("Потолок", "Показывает плиту потолка. Скрытая плита всё равно отбрасывает тень (в Observe)", "RoomBuilder.set_ceiling_visible",
			func() -> bool:
				var r := _room()
				return r != null and r.is_ceiling_visible(),
			func(on: bool) -> void:
				var r := _room()
				if r:
					r.set_ceiling_visible(on))
	add_child(make_header("Маркеры и рельсы"))
	_add_toggle("Маркеры (куб над Entity, сокеты)", "Рисуются у объектов, созданных после включения", "Global.debug_markers",
			func() -> bool: return Global.debug_markers,
			func(on: bool) -> void: Global.debug_markers = on)
	_add_toggle("Лимиты flex (L)", "Применяется к тракам при следующем пересчете", "Global.flex_limits",
			func() -> bool: return Global.flex_limits,
			func(on: bool) -> void: Global.flex_limits = on)
	_add_toggle("Зоны проблем flex (Z)", "Зоны проблем flex цветной полосой над рельсами", "Global.flex_zones",
			func() -> bool: return Global.flex_zones,
			func(on: bool) -> void: Global.flex_zones = on)
	_add_toggle("Препятствия по ходу вагона", "Выключатель на случай просадки производительности", "Global.rail_obstacles",
			func() -> bool: return Global.rail_obstacles,
			func(on: bool) -> void: Global.rail_obstacles = on)
	_add_toggle("Физика вагона при драге", "Включено: вагон догоняет курсор и его можно бросить", "Global.drag_physics",
			func() -> bool: return Global.drag_physics,
			func(on: bool) -> void: Global.drag_physics = on)

	add_child(make_header("Электрика (DCS, D7)"))
	_preset = OptionButton.new()
	for id in DCSPresets.ORDER:
		_preset.add_item(DCSPresets.TITLES[id])
		_preset.set_item_metadata(_preset.item_count - 1, id)
	_preset.add_item("Своя (из сейва)")
	_preset.set_item_metadata(_preset.item_count - 1, &"custom")
	_preset.item_selected.connect(_on_preset_selected)
	add_child(_preset)
	_rules_label = Label.new()
	_rules_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rules_label.modulate = Color(1, 1, 1, 0.7)
	add_child(_rules_label)
	PGM.rules_changed.connect(_sync_rules)
	_sync_rules()
	_bus_check = CheckBox.new()
	_bus_check.text = "Шина аксессуаров включена (12 В)"
	_bus_check.toggled.connect(func(on: bool) -> void:
		PGM.bus.enabled = on
		_sync_bus())
	add_child(_bus_check)
	_bus_label = Label.new()
	_bus_label.modulate = Color(1, 1, 1, 0.7)
	add_child(_bus_label)
	# XX claude-car CS4a: предел тока шины. Защита срабатывает при нагрузке выше предела дольше 0.5 с, при двойной нагрузке сразу
	var limit_row := HBoxContainer.new()
	var limit_caption := Label.new()
	limit_caption.text = "Предел тока шины, А"
	limit_row.add_child(limit_caption)
	_bus_limit = SpinBox.new()
	_bus_limit.min_value = 0.1
	_bus_limit.max_value = 20.0
	_bus_limit.step = 0.05
	_bus_limit.value = PGM.bus.i_max
	_bus_limit.tooltip_text = "Нагрузка на шину считается только в пресете «Реалистичный» (правило «нагрузка от света и аксессуаров»)"
	_bus_limit.value_changed.connect(func(v: float) -> void:
		PGM.bus.i_max = v
		_sync_bus())
	limit_row.add_child(_bus_limit)
	add_child(limit_row)
	var bus_reset := Button.new()
	bus_reset.text = "Сбросить защиту шины"
	bus_reset.pressed.connect(func() -> void:
		PGM.reset_bus()
		_sync_bus())
	add_child(bus_reset)
	PGM.bus_event.connect(func(_k: String) -> void: _sync_bus())
	PGM.solver_stepped.connect(_sync_bus)
	_sync_bus()

	add_child(make_header("Экран"))
	_add_toggle("V-Sync (Ctrl+Shift+V)", "Без V-Sync fps не упирается в частоту монитора", "DisplayServer.window_set_vsync_mode",
			func() -> bool: return DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED,
			_set_vsync)

	_add_toggle("Оверлей статистики (F4)", "fps, draw calls, треугольники, траки и вагоны в углу экрана. Цифры отрисовки за все проходы кадра", "GFX.stats",
			func() -> bool: return GFX.is_stats_shown(),
			func(on: bool) -> void: GFX.set_stats_shown(on))

	add_child(make_header("Сцена"))
	var clear := Button.new()
	clear.text = "Очистить сцену..."
	clear.pressed.connect(func() -> void: _confirm.popup_centered())
	add_child(clear)
	_confirm = ConfirmationDialog.new()
	_confirm.dialog_text = "Удалить все объекты со сцены? Несохраненное пропадет."
	_confirm.confirmed.connect(_clear_scene)
	add_child(_confirm)


## Комната игры (RoomBuilder в группе room_root). null в режиме --fast
func _room() -> RoomBuilder:
	return (Engine.get_main_loop() as SceneTree).get_first_node_in_group(&"room_root") as RoomBuilder


func setup(save_manager: SaveManager) -> void:
	_save_manager = save_manager


func _add_toggle(text: String, tip: String, var_name: String, getter: Callable, setter: Callable) -> void:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override(&"separation", -4)
	add_child(cell)
	var cb := CheckBox.new()
	cb.text = text
	cb.tooltip_text = tip
	cb.set_pressed_no_signal(getter.call())
	cb.toggled.connect(func(on: bool) -> void: setter.call(on))
	cell.add_child(cb)
	var vl := make_var_label(var_name)
	cell.add_child(vl)
	_toggles.append({"check": cb, "get": getter})


func _on_preset_selected(i: int) -> void:
	var id: StringName = _preset.get_item_metadata(i)
	if id != &"custom":
		PGM.apply_preset(id)


func _sync_rules() -> void:
	var r := PGM.rules
	var idx := DCSPresets.ORDER.find(r.preset)
	_preset.select(idx if idx >= 0 else _preset.item_count - 1)
	_rules_label.text = "Точность P%d, проводка %s, сеть %s, конфликт %s, защита %s, изостыки %s, свет нагружает %s" % [
		int(r.fidelity), "обязательна" if r.wiring_required else "по желанию", "нужна" if r.supply_required else "не нужна",
		"отключает оба" if r.conflict_policy == 1 else "ведёт первый", ["нет", "авто", "ручной сброс"][int(r.short_protection)],
		"да" if r.gaps_enabled else "нет", "да" if r.load_for_lights else "нет"]


func _sync_bus() -> void:
	if _bus_check == null:
		return
	_bus_check.set_pressed_no_signal(PGM.bus.enabled)
	if _bus_limit != null:
		_bus_limit.set_value_no_signal(PGM.bus.i_max)
	_bus_label.text = "Шина: %s, нагрузка %.2f из %.1f А" % [
		"ОТКЛЮЧЕНА ЗАЩИТОЙ" if PGM.bus.tripped else ("запитана" if PGM.bus_powered() else "без питания"),
		PGM.bus.load_a, PGM.bus.i_max]


func refresh() -> void:
	_sync_rules()
	_sync_bus()
	for t in _toggles:
		(t.check as CheckBox).set_pressed_no_signal(t.get.call())


func _set_vsync(on: bool) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0


func _clear_scene() -> void:
	if is_instance_valid(_save_manager):
		_save_manager.clear_scene()
