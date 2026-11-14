class_name SettingsWindow extends ModalWindow

# U11 (ATTN_17 §17.3.1): новый файл
## Окно настроек: слева страницы, справа строки (подпись, элемент, «Сброс»). Применяется сразу,
## пишет через Settings (graphics, ui) и Actions (клавиши).
## Страницы: Графика, Звук (серая: звука в проекте нет), Клавиши, Интерфейс.
## Серые строки «Скоро»: язык (после U7), анимации (U19), масштаб интерфейса (roadmap).
## Полноэкранный режим и V-Sync при старте применяет это окно (_ready): оно создаётся вместе с UI.

const ROW_TOGGLE := preload("res://ui/widgets/toggle_row.tscn")
const ROW_OPTION := preload("res://ui/widgets/option_row.tscn")
const ROW_SPIN := preload("res://ui/widgets/spin_row.tscn")

## Порядок качества в списке (остальное в конце)
const QUALITY_ORDER: Array[StringName] = [&"low", &"medium", &"high"]
const DEFAULT_QUALITY := &"medium"
## Секция Settings для раскладки окон (пишет U13, здесь только сброс)
const WINDOWS_SECTION := "windows"

@onready var _nav: VBoxContainer = %Nav
@onready var _pages: Control = %Pages
@onready var _close: Button = %CloseButton

var _nav_group := ButtonGroup.new()
var _page_nodes: Dictionary = {}
var _nav_buttons: Dictionary = {}

var _quality_row: OptionRow
var _look_row: OptionRow
var _vsync_row: ToggleRow
var _fullscreen_row: ToggleRow
var _hints_row: ToggleRow

var _keys_msg: Label
var _key_buttons: Dictionary = {}
var _capturing: StringName = &""
var _reset_msg: Label


func _ready() -> void:
	visible = false
	_close.pressed.connect(close)
	_build_graphics()
	_build_sound()
	_build_keys()
	_build_interface()
	_show_page(&"graphics")
	_apply_saved_display()
	Actions.binding_changed.connect(_refresh_key_button)


func _opened() -> void:
	_capturing = &""
	_refresh_values()
	_keys_msg.text = ""
	_reset_msg.text = ""


# ---------------- страницы ----------------

func _add_page(id: StringName, title: String) -> VBoxContainer:
	var b := Button.new()
	b.text = title
	b.toggle_mode = true
	b.button_group = _nav_group
	b.custom_minimum_size = Vector2(0, 32)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(_show_page.bind(id))
	_nav.add_child(b)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.visible = false
	_pages.add_child(sc)
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override(&"separation", 8)
	sc.add_child(box)
	_page_nodes[id] = sc
	_nav_buttons[id] = b
	return box


func _show_page(id: StringName) -> void:
	for k in _page_nodes:
		(_page_nodes[k] as Control).visible = (k == id)
	(_nav_buttons[id] as Button).set_pressed_no_signal(true)


func _add_toggle(box: Control, title: String, default: bool) -> ToggleRow:
	var row: ToggleRow = ROW_TOGGLE.instantiate()
	box.add_child(row)
	row.setup(title, default)
	return row


func _add_option(box: Control, title: String, ids: Array, titles: Array, default: Variant) -> OptionRow:
	var row: OptionRow = ROW_OPTION.instantiate()
	box.add_child(row)
	row.set_options(ids, titles)
	row.setup(title, default)
	return row


func _add_note(box: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"LabelDim"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(l)
	return l


# ---------------- Графика ----------------

func _build_graphics() -> void:
	var box := _add_page(&"graphics", "Графика")
	var q_ids: Array = []
	var q_titles: Array = []
	for id in QUALITY_ORDER:
		if GFX.qualities.has(id):
			q_ids.append(id)
			q_titles.append(GFX.qualities[id].title)
	for id in GFX.qualities:
		if not q_ids.has(id):
			q_ids.append(id)
			q_titles.append(GFX.qualities[id].title)
	_quality_row = _add_option(box, "Качество", q_ids, q_titles, DEFAULT_QUALITY)
	_quality_row.value_changed.connect(func(v: Variant) -> void: GFX.apply_quality(v))

	var l_ids: Array = []
	var l_titles: Array = []
	for id in GFX.looks:
		l_ids.append(id)
		l_titles.append(GFX.looks[id].title)
	_look_row = _add_option(box, "Вид (Look)", l_ids, l_titles, GFX.DEFAULT_LOOK)
	_look_row.value_changed.connect(func(v: Variant) -> void: GFX.apply_look(v))

	_vsync_row = _add_toggle(box, "Вертикальная синхронизация", true)
	_vsync_row.value_changed.connect(func(v: Variant) -> void: _set_vsync(bool(v)))
	_fullscreen_row = _add_toggle(box, "Полный экран", false)
	_fullscreen_row.value_changed.connect(func(v: Variant) -> void: _set_fullscreen(bool(v)))


func _set_vsync(on: bool) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)
	Settings.set_value("graphics", "vsync", on)


func _set_fullscreen(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)
	Settings.set_value("graphics", "fullscreen", on)


## Запомненные V-Sync и полный экран при старте (если игрок их менял)
func _apply_saved_display() -> void:
	if Settings.has_value("graphics", "vsync"):
		_set_vsync(bool(Settings.get_value("graphics", "vsync", true)))
	if Settings.has_value("graphics", "fullscreen") and bool(Settings.get_value("graphics", "fullscreen", false)):
		_set_fullscreen(true)


func _is_fullscreen() -> bool:
	var m := DisplayServer.window_get_mode()
	return m == DisplayServer.WINDOW_MODE_FULLSCREEN or m == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


# ---------------- Звук ----------------

func _build_sound() -> void:
	var box := _add_page(&"sound", "Звук")
	_add_note(box, "Звука в проекте пока нет. Громкость шин появится вместе с ним.")
	for i in AudioServer.bus_count:
		var row: SpinRow = ROW_SPIN.instantiate()
		box.add_child(row)
		row.configure(0.0, 1.0, 0.01)
		row.setup("Шина: %s" % AudioServer.get_bus_name(i), 1.0)
		row.set_value(1.0)
		row.set_available(false, "Скоро")


# ---------------- Клавиши ----------------

func _build_keys() -> void:
	var box := _add_page(&"keys", "Клавиши")
	_add_note(box, "Нажмите на клавишу действия и новую клавишу. Esc отменяет. Занятая клавиша в том же контексте не назначается.")
	_keys_msg = Label.new()
	_keys_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_keys_msg)
	# Действия по группам, группы в порядке первого появления
	var groups: Dictionary = {}
	for e in Actions.get_entries():
		if e.has("gesture"):
			continue
		var g: StringName = e.group
		if not groups.has(g):
			groups[g] = []
		groups[g].append(e)
	for g in groups:
		var h := Label.new()
		h.text = String(g).capitalize()
		h.theme_type_variation = &"LabelDim"
		box.add_child(h)
		for e in groups[g]:
			box.add_child(_make_key_row(e))


func _make_key_row(e: Dictionary) -> HBoxContainer:
	var id: StringName = e.id
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	var cap := Label.new()
	cap.text = _title_of(id)
	cap.custom_minimum_size = Vector2(260, 0)
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(cap)
	var kb := Button.new()
	kb.custom_minimum_size = Vector2(160, 28)
	kb.disabled = not e.remappable
	kb.pressed.connect(_begin_capture.bind(id))
	row.add_child(kb)
	_key_buttons[id] = kb
	var rb := Button.new()
	rb.text = "Сброс"
	rb.theme_type_variation = &"ButtonSmall"
	rb.custom_minimum_size = Vector2(72, 24)
	rb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rb.visible = e.remappable
	rb.pressed.connect(func() -> void:
		Actions.reset_binding(id)
		_keys_msg.text = "")
	row.add_child(rb)
	_refresh_key_button(id)
	return row


## Название действия: перевод по ключу, пока перевода нет (U7) это читаемый id
func _title_of(id: StringName) -> String:
	for e in Actions.get_entries():
		if e.id == id:
			var key: String = e.title_key
			var t := tr(key)
			return String(id).replace("_", " ") if t == key else t
	return String(id)


func _refresh_key_button(id: StringName) -> void:
	if _key_buttons.has(id):
		var kb: Button = _key_buttons[id]
		kb.text = "Нажмите клавишу…" if _capturing == id else Actions.key_text(id)


func _begin_capture(id: StringName) -> void:
	var prev := _capturing
	_capturing = id
	_keys_msg.text = ""
	if prev != &"":
		_refresh_key_button(prev)
	_refresh_key_button(id)


func _finish_capture(k: InputEventKey) -> void:
	# Модификатор сам по себе не клавиша: ждём основную
	if k.keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		return
	var id := _capturing
	_capturing = &""
	if k.keycode == KEY_ESCAPE:
		_refresh_key_button(id)
		return
	var ev := InputEventKey.new()
	ev.physical_keycode = k.physical_keycode
	ev.shift_pressed = k.shift_pressed
	ev.ctrl_pressed = k.ctrl_pressed
	ev.alt_pressed = k.alt_pressed
	var clash := Actions.set_binding(id, ev)
	if clash != &"":
		_keys_msg.text = "Клавиша уже занята действием «%s». Назначение отменено." % _title_of(clash)
	else:
		_keys_msg.text = ""
	_refresh_key_button(id)


func _input(event: InputEvent) -> void:
	if _capturing != &"" and visible and WindowStack.top() == self:
		var k := event as InputEventKey
		if k != null and k.pressed and not k.echo:
			get_viewport().set_input_as_handled()
			_finish_capture(k)
		return
	super._input(event)


# ---------------- Интерфейс ----------------

func _build_interface() -> void:
	var box := _add_page(&"interface", "Интерфейс")
	_hints_row = _add_toggle(box, "Подсказки внизу экрана", true)
	_hints_row.value_changed.connect(func(v: Variant) -> void: Hints.set_enabled(bool(v)))

	var lang := _add_option(box, "Язык", [&"ru", &"en"], ["Русский", "English"], &"ru")
	lang.set_value(&"ru")
	lang.set_available(false, "Скоро: появится вместе с локализацией")
	var anim := _add_toggle(box, "Анимации интерфейса", true)
	anim.set_value(true)
	anim.set_available(false, "Скоро")
	var scale_row: SpinRow = ROW_SPIN.instantiate()
	box.add_child(scale_row)
	scale_row.configure(0.75, 1.5, 0.05)
	scale_row.setup("Масштаб интерфейса", 1.0)
	scale_row.set_value(1.0)
	scale_row.set_available(false, "Скоро")

	var reset := Button.new()
	reset.text = "Сбросить раскладку окон"
	reset.custom_minimum_size = Vector2(0, 32)
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(func() -> void:
		Settings.erase_section(WINDOWS_SECTION)
		_reset_msg.text = "Положение и размеры окон вернутся к исходным при следующем запуске.")
	box.add_child(reset)
	_reset_msg = _add_note(box, "")


# ---------------- Значения ----------------

## Показать текущее состояние игры (окно могли открыть после смены из других мест)
func _refresh_values() -> void:
	_quality_row.set_value(GFX.state.quality)
	_look_row.set_value(GFX.state.look)
	_vsync_row.set_value(DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED)
	_fullscreen_row.set_value(_is_fullscreen())
	_hints_row.set_value(Hints.enabled)
	for id in _key_buttons:
		_refresh_key_button(id)
