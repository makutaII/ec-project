class_name SideDock extends SlidePanel

# U12 (ATTN_17 §17.4, §17.13): новый файл, забирает переключатели из TopBar
## Боковая панель слева поверх DC. Состав: стиль траков и «Ко всем», шаг поворота, привязка
## (сокеты работают, сетка пока серая), лимиты flex (L), тени траков, слой питания, тема,
## положение подсказок (серое до U16). Значения читаются и пишутся в Global.build_options,
## GFX, PGM, TSM; сама панель ничего не хранит. Автозакрытие и закрепление в SlidePanel.

const ROW_TOGGLE := preload("res://ui/widgets/toggle_row.tscn")
const ROW_OPTION := preload("res://ui/widgets/option_row.tscn")
const ROW_SPIN := preload("res://ui/widgets/spin_row.tscn")
const THEME_DARK := "res://ui/themes/theme_hud_dark.tres"
const THEME_LIGHT := "res://ui/themes/theme_hud_light.tres"
const CAPTION_W := 150.0

@onready var _items: VBoxContainer = %Items
@onready var _pin: Button = %PinButton
## Окна лежат в слое Windows; изнутри сцены панели `%` не виден, берём через владельца (UI)
@onready var _confirm: ConfirmDialog = owner.get_node("%ConfirmDialog")
@onready var _save_manager: SaveManager = get_node("/root/GameRoot/SaveManager")

var _opts: BuildOptions
var _style_option: OptionButton
var _style_apply: Button
var _rot_row: OptionRow
var _socket_row: ToggleRow
var _flex_row: ToggleRow
var _shadows_row: ToggleRow
var _power_row: ToggleRow
var _theme_row: OptionRow


func _ready() -> void:
	super._ready()
	_opts = Global.build_options
	_opts.load_saved()   # Settings к этому времени готов
	_build_style()
	_rot_row = _add_option("Шаг поворота", [15.0, 45.0, 90.0], ["15°", "45°", "90°"], 45.0)
	_rot_row.value_changed.connect(func(v: Variant) -> void:
		_opts.rot_step_deg = float(v)
		note_action())
	_socket_row = _add_toggle("Привязка к сокетам", true)
	_socket_row.value_changed.connect(func(v: Variant) -> void:
		_opts.socket_snap = bool(v)
		note_action())
	var grid := _add_toggle("Привязка к сетке", false)
	grid.set_value(false)
	grid.set_available(false, "Скоро")
	var grid_step: SpinRow = ROW_SPIN.instantiate()
	_items.add_child(grid_step)
	grid_step.configure(0.1, 10.0, 0.1)
	grid_step.setup("Шаг сетки", 1.0, CAPTION_W, false)
	grid_step.set_value(1.0)
	grid_step.set_available(false, "Скоро")
	_flex_row = _add_toggle("Лимиты flex (L)", false)
	_flex_row.value_changed.connect(func(v: Variant) -> void:
		_opts.flex_limits = bool(v)
		note_action())
	_shadows_row = _add_toggle("Тени траков", false)
	_shadows_row.value_changed.connect(func(v: Variant) -> void:
		GFX.set_track_shadows(bool(v))
		note_action())
	_power_row = _add_toggle("Слой питания", false)
	_power_row.value_changed.connect(func(v: Variant) -> void:
		PGM.toggle_power_layer(bool(v))
		note_action())
	_theme_row = _add_option("Тема", [&"dark", &"light"], ["Тёмная", "Светлая"], &"dark")
	_theme_row.value_changed.connect(func(v: Variant) -> void:
		_apply_theme(v)
		note_action())
	var hints := _add_option("Подсказки", [&"bottom", &"top_right"], ["Внизу", "Вверху справа"], &"bottom")
	hints.set_value(&"bottom")
	hints.set_available(false, "Скоро: положение подсказок появится в U16")

	_pin.toggled.connect(func(on: bool) -> void: pinned = on)
	opened.connect(_refresh)
	_opts.option_changed.connect(func(_k: StringName) -> void: _refresh())
	PGM.power_layer_toggled.connect(func(_on: bool) -> void: _refresh())
	GFX.track_shadows_changed.connect(func(_on: bool) -> void: _refresh())
	TSM.current_changed.connect(func(_id: StringName) -> void: _refresh())
	# Запомненная тема
	var saved := String(Settings.get_value("ui", "theme", "dark"))
	if saved == "light":
		_apply_theme(&"light")
	_refresh()


# ---------------- строки ----------------

func _add_toggle(title: String, default: bool) -> ToggleRow:
	var row: ToggleRow = ROW_TOGGLE.instantiate()
	_items.add_child(row)
	row.setup(title, default, CAPTION_W, false)
	return row


func _add_option(title: String, ids: Array, titles: Array, default: Variant) -> OptionRow:
	var row: OptionRow = ROW_OPTION.instantiate()
	_items.add_child(row)
	row.set_options(ids, titles)
	row.setup(title, default, CAPTION_W, false)
	return row


func _refresh() -> void:
	_rot_row.set_value(_opts.rot_step_deg)
	_socket_row.set_value(_opts.socket_snap)
	_flex_row.set_value(_opts.flex_limits)
	_shadows_row.set_value(GFX.is_track_shadows())
	_power_row.set_value(PGM.is_power_layer_active)
	_theme_row.set_value(&"light" if String(Settings.get_value("ui", "theme", "dark")) == "light" else &"dark")
	_sync_style(TSM.current_id)


func _apply_theme(id: StringName) -> void:
	var path := THEME_LIGHT if id == &"light" else THEME_DARK
	get_tree().root.theme = load(path) as Theme
	Settings.set_value("ui", "theme", String(id))


# ---------------- стиль траков (из TopBar, U3c) ----------------

## Стиль траков сессии (ATTN_17 §17.13): список из набора стилей проекта (TSM), «Ко всем» пересобирает траки
func _build_style() -> void:
	var cap := Label.new()
	cap.text = "Стиль траков"
	cap.theme_type_variation = &"LabelSmall"
	_items.add_child(cap)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	_items.add_child(row)
	_style_option = OptionButton.new()
	_style_option.focus_mode = Control.FOCUS_NONE   # стрелки и пробел остаются инструментам
	_style_option.custom_minimum_size = Vector2(0, 32)
	_style_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option.tooltip_text = "Стиль траков: новые траки создаются в нём, стоящие не меняются"
	_style_option.item_selected.connect(func(i: int) -> void:
		TSM.set_current(_style_option.get_item_metadata(i))
		note_action())
	row.add_child(_style_option)
	_style_apply = Button.new()
	_style_apply.text = "Ко всем"
	_style_apply.custom_minimum_size = Vector2(0, 32)
	_style_apply.focus_mode = Control.FOCUS_NONE
	_style_apply.tooltip_text = "Пересобрать все траки на столе в выбранном стиле. Макет сохраняется в автосейв."
	_style_apply.pressed.connect(_on_style_apply_pressed)
	row.add_child(_style_apply)
	TSM.set_changed.connect(_fill_style_items)   # Track Studio добавил стиль в набор
	_fill_style_items()


func _fill_style_items() -> void:
	_style_option.clear()
	for st in TSM.style_set.styles:
		if st == null:
			continue
		var i := _style_option.item_count
		_style_option.add_item(String(st.id))
		_style_option.set_item_metadata(i, st.id)
		var tip := "высота рельса %.2f" % st.head_height()
		if st.use_scene:
			tip += ", сцены Blender"
		_style_option.set_item_tooltip(i, tip)
	_sync_style(TSM.current_id)


func _sync_style(id: StringName) -> void:
	if _style_option == null:
		return
	for i in _style_option.item_count:
		if _style_option.get_item_metadata(i) == id:
			_style_option.select(i)
			return


func _on_style_apply_pressed() -> void:
	note_action()
	var msg := "Все траки на столе будут пересобраны в стиле «%s».\nМакет перед этим сохраняется в автосейв: до следующего сохранения им можно откатиться (загрузить autosave).\nПродолжить?" % TSM.current_id
	if await _confirm.ask("Стиль всех траков", msg, "Применить", "Отмена"):
		_style_apply.disabled = true
		await _save_manager.apply_session_style_to_all()
		_style_apply.disabled = false
