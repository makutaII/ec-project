extends Control

########################
## Track Studio (ATTN_20). Редактор стилей траков, часть будущего режима Library.
########################
## Живёт в Library: кнопка «Track Studio» в верхней полосе, дочернее окно (ATTN_22 §22.5.4). Окном не управляет.
## T1: список стилей из data/tracks/styles, 3D-превью (тот же TrackMeshBuilder, что в игре),
## правка параметров стиля, профили текстом, паспорт с проверками, сохранение в .tres.
## Интерфейс собирается кодом, как в Icon Studio. Логика проверок и файлов лежит в lib/ без интерфейса.

const StudioSettings := preload("res://core/library/icon_studio/studio_settings.gd")
const StudioView := preload("res://core/library/track_studio/studio_view.gd")
const MaterialPanel := preload("res://core/library/track_studio/material_panel.gd")
const SleeperPanel := preload("res://core/library/track_studio/sleeper_panel.gd")
const ProfilePanel := preload("res://core/library/track_studio/profile_panel.gd")

const SETTINGS_PATH := "user://track_studio.cfg"
const REFRESH_DELAY := 0.12
const COLOR_ERROR := "#ff7b7b"
const COLOR_WARN := "#ffcf5c"
const COLOR_INFO := "#9fb3c8"
const COLOR_OK := "#7bd88f"

# Описание полей стиля. kind: float, bool, vec2, vec3, res (base: Material или Mesh)
const PROPS := [
	{"sec": "Части трака"},
	{"key": "ballast_enabled", "kind": "bool", "label": "Балласт включён",
		"tip": "Балласт входит в высоту трака: без него поверхность катания ниже (head_height). Нужна хотя бы одна часть"},
	{"key": "sleeper_enabled", "kind": "bool", "label": "Шпала включена",
		"tip": "Только визуал: без шпал размер шпалы всё равно задаёт высоту постели рельса. Нужна хотя бы одна часть"},
	{"key": "rail_enabled", "kind": "bool", "label": "Рельс включён",
		"tip": "Только визуал: без рельсов профиль рельса, колея, коллизия и высота трака остаются. Нужна хотя бы одна часть"},
	{"sec": "Рельсы"},
	{"key": "rail_x", "kind": "float", "label": "Половина колеи (rail_x)", "min": 0.1, "max": 5.0,
		"tip": "Расстояние от оси трака до оси рельса, ю"},
	{"key": "rail_material", "kind": "res", "base": "Material", "label": "Материал рельса", "part": "rail",
		"tip": "Пусто = общий серый материал"},
	{"key": "rail_uv_tile", "kind": "vec2", "label": "Тайл текстуры, ю", "min": 0.0, "max": 100.0, "part": "rail",
		"tip": "x вдоль пути, y поперек (по длине ломаной профиля). 0 = как раньше (для атласов)"},
	{"key": "rail_uv_rotate", "kind": "bool", "label": "Повернуть текстуру на 90°", "part": "rail",
		"tip": "Оси UV меняются местами. Слой питания учитывает поворот"},
	{"sec": "Шпалы"},
	{"key": "sleeper_mesh", "kind": "res", "base": "Mesh", "label": "Меш шпалы",
		"tip": "Пусто = BoxMesh размера sleeper_size. Контракт меша: origin в центре площади опоры, низ на y = 0, длинная сторона по X"},
	{"key": "sleeper_size", "kind": "vec3", "label": "Размер (X, Y, Z)", "min": 0.01, "max": 20.0,
		"tip": "Только для BoxMesh (если меша нет): ширина поперёк пути, высота, длина вдоль пути. Задаёт высоту постели рельса и при выключенных шпалах"},
	{"key": "sleeper_gap", "kind": "float", "label": "Зазор между шпалами", "min": 0.0, "max": 10.0, "part": "sleeper", "tip": "ю"},
	{"key": "sleeper_embed", "kind": "float", "label": "Вдавлена в балласт", "min": 0.0, "max": 5.0, "part": "ballast",
		"tip": "ю, без балласта игнорируется"},
	{"key": "sleeper_material", "kind": "res", "base": "Material", "label": "Материал шпалы", "part": "sleeper",
		"tip": "Пусто = общий материал (для своего меша: материалы самого меша)"},
	{"sec": "Балласт"},
	{"key": "ballast_material", "kind": "res", "base": "Material", "label": "Материал балласта", "part": "ballast",
		"tip": "Пусто = общий серый материал"},
	{"key": "ballast_uv_tile", "kind": "vec2", "label": "Тайл текстуры, ю", "min": 0.0, "max": 100.0, "part": "ballast",
		"tip": "x вдоль пути, y поперек (по длине ломаной профиля). 0 = как раньше (для атласов)"},
	{"key": "ballast_uv_rotate", "kind": "bool", "label": "Повернуть текстуру на 90°", "part": "ballast",
		"tip": "Оси UV меняются местами"},
	{"sec": "Коллизия"},
	{"key": "collision_width", "kind": "float", "label": "Ширина основания", "min": 0.5, "max": 10.0,
		"tip": "Ширина коллизии основания, ю. Должна совпадать с шириной балласта (или шпалы без балласта)"},
	{"key": "collision_end_inset", "kind": "float", "label": "Отступ коллизии от торца", "min": 0.0, "max": 1.0,
		"tip": "ю. Боксы коллизии короче трака на столько с каждого торца. У дуги внешний угол бокса выступает к торцу на полуширина * sin(половина угла нарезки) и мешает снапу: отступ делают не меньше выступа"},
	{"sec": "Лоток горок"},
	{"key": "surface_height", "kind": "float", "label": "Поверхность катания (дно)", "min": 0.0, "max": 5.0,
		"tip": "ю над origin пути. 0 = как у рельсовых стилей (низ шпалы + шпала + рельс). Больше 0: колёса идут на этой высоте, коллизия основания до неё"},
	{"key": "trough", "kind": "bool", "label": "Коллизия бортов лотка",
		"tip": "Вместо коллизии рельсов два бокса бортов от дна до верха борта, по профилю балласта. Нужна поверхность катания. Рельсы и шпалы выключаются отдельно в «Частях трака»"},
]

## Флаги частей трака (вкладка «Параметры»). Хотя бы один должен быть включён
const PART_KEYS := ["ballast_enabled", "sleeper_enabled", "rail_enabled"]

var settings: StudioSettings
var view: StudioView

var _style: TrackStyle
var _current_path := ""
var _dirty := false
var _pending: Callable = Callable()

var _split_left: HSplitContainer
var _split_right: HSplitContainer
var _list: ItemList
var _file_label: Label
var _status: Label
var _viewport: SubViewport
var _view_area: PanelContainer
var _pass_nums: RichTextLabel
var _pass_msgs: RichTextLabel
var _ctrls := {}                     # ключ поля -> Control или Array[SpinBox] или Dictionary (res)
var _rows := {}                      # ключ поля -> строка HBoxContainer (для затемнения при выключенной части)
var _syncing := false
var _profiles: ProfilePanel
var _materials: MaterialPanel
var _sleepers: SleeperPanel
var _shape_opt: OptionButton
var _len_spin: SpinBox
var _rad_spin: SpinBox
var _ang_spin: SpinBox
var _sleepers_chk: CheckBox
var _rails_chk: CheckBox
var _shadows_chk: CheckBox
var _refresh_timer: Timer
var _discard_dialog: ConfirmationDialog
var _saveas_dialog: ConfirmationDialog
var _saveas_edit: LineEdit
var _saveas_info: Label
var _file_dialog: FileDialog
var _pick_key := ""
var _pick_base := ""


func _ready() -> void:
	settings = StudioSettings.new()
	settings.name = "StudioSettings"
	settings.path = SETTINGS_PATH
	add_child(settings)

	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.wait_time = REFRESH_DELAY
	_refresh_timer.timeout.connect(_refresh)
	add_child(_refresh_timer)

	_build_ui()
	_apply_saved_ui()
	_reload_list()
	# Размеры контейнеров известны только после первого кадра раскладки
	await get_tree().process_frame
	_open_initial()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and settings:
		settings.flush()


func _exit_tree() -> void:
	if settings:
		settings.flush()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F and not k.ctrl_pressed:
		view.fit()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_S and (k.ctrl_pressed or k.meta_pressed):
		_on_save()
		get_viewport().set_input_as_handled()


# ==========================================
# ИНТЕРФЕЙС
# ==========================================

func _build_ui() -> void:
	_split_left = HSplitContainer.new()
	_split_left.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_split_left)
	_split_left.dragged.connect(func(off: int): settings.set_value("ui", "split_left", off))

	_build_left_panel()

	_split_right = HSplitContainer.new()
	_split_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split_left.add_child(_split_right)
	_split_right.dragged.connect(func(off: int): settings.set_value("ui", "split_right", off))

	_build_center()
	_build_right_panel()
	_build_dialogs()


func _build_left_panel() -> void:
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(280, 0)
	_split_left.add_child(left)
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(sc)
	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(lv)

	var title := Label.new()
	title.text = "Стили траков"
	lv.add_child(title)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 150)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_list_selected)
	lv.add_child(_list)

	var r1 := HBoxContainer.new()
	lv.add_child(r1)
	_add_button(r1, "Новый", _on_new)
	_add_button(r1, "Дубль", _on_duplicate)
	_add_button(r1, "Обновить", func(): _reload_list())

	var r2 := HBoxContainer.new()
	lv.add_child(r2)
	_add_button(r2, "Сохранить", _on_save).tooltip_text = "Ctrl+S"
	_add_button(r2, "Сохранить как…", _open_save_as)
	var r3 := HBoxContainer.new()
	lv.add_child(r3)
	_add_button(r3, "Добавить в набор стилей проекта", _on_add_to_set).tooltip_text = "Добавляет сохранённый стиль строкой в setting/track_style_set.tres. После этого он есть в списке стилей на верхней панели игры, новые траки любой формы строятся в нём. Стиль должен быть сохранён (Ctrl+S)."

	_file_label = Label.new()
	_file_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	lv.add_child(_file_label)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(0.75, 0.85, 1.0)
	lv.add_child(_status)

	lv.add_child(HSeparator.new())
	var pt := Label.new()
	pt.text = "Превью"
	lv.add_child(pt)

	_shape_opt = OptionButton.new()
	_shape_opt.add_item("Прямая", StudioView.Shape.STRAIGHT)
	_shape_opt.add_item("Дуга", StudioView.Shape.ARC)
	_shape_opt.add_item("Прямая + дуга + прямая", StudioView.Shape.STRAIGHT_ARC)
	_shape_opt.item_selected.connect(func(i: int):
		view.shape = _shape_opt.get_item_id(i)
		settings.set_value("preview", "shape", view.shape)
		_rebuild_view(true))
	lv.add_child(_shape_opt)

	_len_spin = _preview_spin(lv, "Длина прямой, ю", 1.0, 100.0, 0.1, "length")
	_rad_spin = _preview_spin(lv, "Радиус дуги, ю", 3.0, 500.0, 1.0, "radius")
	_ang_spin = _preview_spin(lv, "Угол дуги, °", 5.0, 180.0, 1.0, "angle")

	_sleepers_chk = CheckBox.new()
	_sleepers_chk.text = "Показывать шпалы"
	_sleepers_chk.button_pressed = true
	_sleepers_chk.toggled.connect(func(on: bool):
		view.set_sleepers_visible(on)
		settings.set_value("preview", "sleepers", on))
	lv.add_child(_sleepers_chk)

	_rails_chk = CheckBox.new()
	_rails_chk.text = "Показывать рельсы"
	_rails_chk.button_pressed = true
	_rails_chk.toggled.connect(func(on: bool):
		view.set_rails_visible(on)
		settings.set_value("preview", "rails", on))
	lv.add_child(_rails_chk)

	_shadows_chk = CheckBox.new()
	_shadows_chk.text = "Тени"
	_shadows_chk.button_pressed = true
	_shadows_chk.toggled.connect(func(on: bool):
		view.set_shadows(on)
		settings.set_value("preview", "shadows", on))
	lv.add_child(_shadows_chk)

	var vr := HBoxContainer.new()
	lv.add_child(vr)
	_add_button(vr, "Общий", func(): view.view_iso())
	_add_button(vr, "Вблизи", func(): view.view_close())
	_add_button(vr, "Сверху", func(): view.view_top())
	_add_button(vr, "Вдоль", func(): view.view_along())

	var hint := Label.new()
	hint.text = "ЛКМ - орбита, ПКМ / СКМ / Shift+ЛКМ - сдвиг, колесо - масштаб, F - вписать"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.6)
	lv.add_child(hint)

	lv.add_child(HSeparator.new())
	_add_button(lv, "Сбросить панели", func():
		_split_left.split_offset = 0
		_split_right.split_offset = 0
		settings.set_value("ui", "split_left", 0)
		settings.set_value("ui", "split_right", 0))


func _preview_spin(parent: Control, text: String, lo: float, hi: float, step: float, key: String) -> SpinBox:
	var h := HBoxContainer.new()
	parent.add_child(h)
	var l := Label.new()
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value_changed.connect(func(v: float):
		if _syncing:
			return
		view.set(key, v)
		settings.set_value("preview", key, v)
		_rebuild_view(true))
	h.add_child(s)
	return s


func _build_center() -> void:
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.custom_minimum_size = Vector2(320, 0)
	_split_right.add_child(center)

	_view_area = PanelContainer.new()
	_view_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view_area.custom_minimum_size = Vector2(320, 240)
	_view_area.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.11)
	_view_area.add_theme_stylebox_override("panel", bg)
	center.add_child(_view_area)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view_area.add_child(svc)

	_viewport = SubViewport.new()
	_viewport.world_3d = World3D.new()
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.handle_input_locally = false
	svc.add_child(_viewport)

	view = StudioView.new()
	view.name = "StudioView"
	view.viewport = _viewport
	_viewport.add_child(view)
	_view_area.gui_input.connect(view.handle_gui_input)

	# Паспорт: числа стиля и замечания проверки
	var pass_panel := PanelContainer.new()
	pass_panel.custom_minimum_size = Vector2(0, 190)
	center.add_child(pass_panel)
	var ph := HBoxContainer.new()
	pass_panel.add_child(ph)
	_pass_nums = _make_rich()
	ph.add_child(_pass_nums)
	ph.add_child(VSeparator.new())
	_pass_msgs = _make_rich()
	_pass_msgs.size_flags_stretch_ratio = 1.4
	ph.add_child(_pass_msgs)


func _make_rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.selection_enabled = true
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return r


func _build_right_panel() -> void:
	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(380, 0)
	_split_right.add_child(right)
	var tabs := TabContainer.new()
	right.add_child(tabs)

	# --- Параметры ---
	var sc := ScrollContainer.new()
	sc.name = "Параметры"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(sc)
	var pv := VBoxContainer.new()
	pv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(pv)
	for spec in PROPS:
		_build_prop(pv, spec)

	# --- Профили (T4) ---
	_profiles = ProfilePanel.new()
	_profiles.name = "Профили"
	tabs.add_child(_profiles)
	_profiles.setup(self)

	# --- Материалы (T2) и Шпала (T3) ---
	_materials = MaterialPanel.new()
	_materials.name = "Материалы"
	tabs.add_child(_materials)
	_materials.setup(self)
	_sleepers = SleeperPanel.new()
	_sleepers.name = "Шпала"
	tabs.add_child(_sleepers)
	_sleepers.setup(self)


func _build_prop(parent: Control, spec: Dictionary) -> void:
	if spec.has("sec"):
		var sec_label := Label.new()
		sec_label.text = spec["sec"]
		sec_label.add_theme_font_size_override("font_size", 16)
		parent.add_child(HSeparator.new())
		parent.add_child(sec_label)
		return
	var key: String = spec["key"]
	var row := HBoxContainer.new()
	parent.add_child(row)
	_rows[key] = row
	var l := Label.new()
	l.text = spec["label"]
	l.custom_minimum_size = Vector2(150, 0)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.tooltip_text = "%s\n%s" % [key, spec.get("tip", "")]
	row.add_child(l)
	match spec["kind"]:
		"float":
			var s := _make_spin(spec["min"], spec["max"])
			s.value_changed.connect(func(v: float): _set_prop(key, v))
			row.add_child(s)
			_ctrls[key] = s
		"bool":
			var c := CheckBox.new()
			c.toggled.connect(func(on: bool): _set_prop(key, on))
			row.add_child(c)
			_ctrls[key] = c
		"vec2", "vec3":
			var n := 2 if spec["kind"] == "vec2" else 3
			var spins: Array = []
			for i in n:
				var s := _make_spin(spec["min"], spec["max"])
				s.value_changed.connect(func(_v: float): _on_vec_changed(key, spins))
				row.add_child(s)
				spins.append(s)
			_ctrls[key] = spins
		"res":
			var box := VBoxContainer.new()
			box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(box)
			var path_label := Label.new()
			path_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
			path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			box.add_child(path_label)
			var br := HBoxContainer.new()
			box.add_child(br)
			var base: String = spec["base"]
			_add_button(br, "Выбрать…", func(): _open_pick(key, base))
			_add_button(br, "Очистить", func(): _set_prop(key, null))
			_ctrls[key] = path_label


func _make_spin(lo: float, hi: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.001
	s.custom_arrow_step = 0.05
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func _add_button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _build_dialogs() -> void:
	_discard_dialog = ConfirmationDialog.new()
	_discard_dialog.title = "Несохранённые изменения"
	_discard_dialog.dialog_text = "В текущем стиле есть несохранённые изменения. Отбросить их?"
	_discard_dialog.ok_button_text = "Отбросить"
	_discard_dialog.cancel_button_text = "Отмена"
	_discard_dialog.confirmed.connect(func():
		var cb := _pending
		_pending = Callable()
		_dirty = false
		if cb.is_valid():
			cb.call())
	_discard_dialog.canceled.connect(func():
		_pending = Callable()
		_select_in_list(_current_path))
	add_child(_discard_dialog)

	_saveas_dialog = ConfirmationDialog.new()
	_saveas_dialog.title = "Сохранить стиль как"
	_saveas_dialog.ok_button_text = "Сохранить"
	_saveas_dialog.cancel_button_text = "Отмена"
	# Размер задан явно, подписи без автопереноса: у Label с автопереносом минимальная высота при первом показе
	# считается по нулевой ширине, окно получалось выше экрана, и ряд кнопок оказывался за его краем
	_saveas_dialog.min_size = Vector2i(520, 170)
	var sv := VBoxContainer.new()
	sv.custom_minimum_size = Vector2(480, 0)
	_saveas_dialog.add_child(sv)
	var sl := Label.new()
	sl.text = "Идентификатор: латиница в нижнем регистре, цифры, _ (он же имя файла)"
	sv.add_child(sl)
	_saveas_edit = LineEdit.new()
	sv.add_child(_saveas_edit)
	_saveas_edit.text_changed.connect(func(_t: String): _update_saveas_info())
	_saveas_info = Label.new()
	_saveas_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sv.add_child(_saveas_info)
	# Enter в поле = «Сохранить» (запасной способ подтвердить, даже если кнопка не видна)
	_saveas_dialog.register_text_enter(_saveas_edit)
	_saveas_dialog.confirmed.connect(_on_saveas_confirmed)
	add_child(_saveas_dialog)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.use_native_dialog = false
	_file_dialog.title = "Выбрать ресурс"
	_file_dialog.add_filter("*.tres,*.res,*.material,*.mesh", "Ресурсы Godot")
	_file_dialog.current_dir = "res://data"
	_file_dialog.file_selected.connect(_on_file_picked)
	add_child(_file_dialog)


# ==========================================
# НАСТРОЙКИ ИНТЕРФЕЙСА
# ==========================================

func _apply_saved_ui() -> void:
	_split_left.split_offset = int(settings.get_value("ui", "split_left", 0))
	_split_right.split_offset = int(settings.get_value("ui", "split_right", 0))
	_syncing = true
	view.shape = int(settings.get_value("preview", "shape", StudioView.Shape.STRAIGHT))
	view.length = float(settings.get_value("preview", "length", view.length))
	view.radius = float(settings.get_value("preview", "radius", view.radius))
	view.angle = float(settings.get_value("preview", "angle", view.angle))
	_shape_opt.select(_shape_opt.get_item_index(view.shape))
	_len_spin.set_value_no_signal(view.length)
	_rad_spin.set_value_no_signal(view.radius)
	_ang_spin.set_value_no_signal(view.angle)
	var sl := bool(settings.get_value("preview", "sleepers", true))
	var sh := bool(settings.get_value("preview", "shadows", true))
	var rl := bool(settings.get_value("preview", "rails", true))
	_rails_chk.set_pressed_no_signal(rl)
	view.set_rails_visible(rl)
	_sleepers_chk.set_pressed_no_signal(sl)
	_shadows_chk.set_pressed_no_signal(sh)
	view.set_sleepers_visible(sl)
	view.set_shadows(sh)
	_syncing = false


func _open_initial() -> void:
	var last := String(settings.get_value("state", "last_style", ""))
	if not last.is_empty() and FileAccess.file_exists(last):
		_load_path(last)
		return
	var paths := TrackStyleIO.list_paths()
	if paths.size() > 0:
		_load_path(paths[0])
	else:
		_on_new()


# ==========================================
# СПИСОК И ОТКРЫТИЕ СТИЛЯ
# ==========================================

func _reload_list() -> void:
	_list.clear()
	for p in TrackStyleIO.list_paths():
		var i := _list.add_item(p.get_file().get_basename())
		_list.set_item_metadata(i, p)
		_list.set_item_tooltip(i, p)
	_select_in_list(_current_path)


func _select_in_list(path: String) -> void:
	_list.deselect_all()
	for i in _list.item_count:
		if String(_list.get_item_metadata(i)) == path:
			_list.select(i)
			return


func _on_list_selected(i: int) -> void:
	var path := String(_list.get_item_metadata(i))
	if path == _current_path:
		return
	_guard(func(): _load_path(path))


## Для оболочки Library (ATTN_22 §22.5.4): перед уходом из студии. proceed выполнится сразу или после подтверждения «Отбросить»
func request_leave(proceed: Callable) -> void:
	_guard(proceed)


## Выполняет действие сразу или после подтверждения, если есть несохранённые правки
func _guard(action: Callable) -> void:
	if not _dirty:
		action.call()
		return
	_pending = action
	_discard_dialog.popup_centered()


func _load_path(path: String) -> void:
	var s := TrackStyleIO.load_style(path)
	if s == null:
		_say("Не удалось загрузить %s" % path, true)
		return
	_open_style(TrackStyleIO.working_copy(s), path, false)


func _open_style(style: TrackStyle, path: String, dirty: bool) -> void:
	_style = style
	_current_path = path
	_dirty = dirty
	_sync_controls()
	_materials.refresh_from_style()
	_profiles.refresh_from_style()
	_sleepers.refresh_from_style()
	view.set_style(_style)
	view.fit()
	_update_passport()
	_update_file_label()
	_select_in_list(path)
	if not path.is_empty():
		settings.set_value("state", "last_style", path)
	_say("")


func _on_new() -> void:
	_guard(func():
		var s := TrackStyle.new()
		s.id = StringName(TrackStyleIO.unique_id("new_style"))
		_open_style(s, "", true))


func _on_duplicate() -> void:
	if _style == null:
		return
	_guard(func():
		var s := TrackStyleIO.working_copy(_style)
		s.id = StringName(TrackStyleIO.unique_id(String(_style.id) + "_copy"))
		_open_style(s, "", true))


# ==========================================
# ПРАВКА ПОЛЕЙ
# ==========================================

func _sync_controls() -> void:
	_syncing = true
	for spec in PROPS:
		if spec.has("sec"):
			continue
		var key: String = spec["key"]
		var v: Variant = _style.get(key)
		var c: Variant = _ctrls[key]
		match spec["kind"]:
			"float":
				(c as SpinBox).set_value_no_signal(v)
			"bool":
				(c as CheckBox).set_pressed_no_signal(v)
			"vec2":
				c[0].set_value_no_signal(v.x)
				c[1].set_value_no_signal(v.y)
			"vec3":
				c[0].set_value_no_signal(v.x)
				c[1].set_value_no_signal(v.y)
				c[2].set_value_no_signal(v.z)
			"res":
				(c as Label).text = TrackStyleIO.describe(v)
	_syncing = false
	_sync_parts()


# --- интерфейс для вкладок материалов и шпал ---

func get_style() -> TrackStyle:
	return _style


## Задаёт поле стиля из вкладки (материал, меш, тайл): обновляет элементы, превью и паспорт
func set_field(key: String, value: Variant) -> void:
	if _style == null:
		return
	_style.set(key, value)
	_sync_controls()
	_mark_dirty()


func say(text: String, error := false) -> void:
	_say(text, error)


func _set_prop(key: String, value: Variant) -> void:
	if _syncing or _style == null:
		return
	if key in PART_KEYS and not value:
		# Ничего не выбрано быть не может: последнюю включённую часть выключить нельзя
		var others := 0
		for k in PART_KEYS:
			if k != key and _style.get(k):
				others += 1
		if others == 0:
			_syncing = true
			(_ctrls[key] as CheckBox).set_pressed_no_signal(true)
			_syncing = false
			_say("Нужна хотя бы одна часть: балласт, шпалы или рельсы", true)
			return
	_style.set(key, value)
	if _ctrls.get(key) is Label:
		(_ctrls[key] as Label).text = TrackStyleIO.describe(value)
	if key in PART_KEYS:
		_sync_parts()
	_mark_dirty()


## Синхронизация с флагами частей: поля выключенной части затемняются и блокируются, галочки превью и остальные
## вкладки получают пояснение. Поля, которые остаются контрактом (rail_x, rail_profile, размер шпалы, collision_width),
## не блокируются: их читают коллизия и высота трака
func _sync_parts() -> void:
	if _style == null:
		return
	var on := {"rail": _style.rail_enabled, "sleeper": _style.sleeper_enabled, "ballast": _style.ballast_enabled}
	for spec in PROPS:
		if not spec.has("part"):
			continue
		var row := _rows.get(spec["key"]) as Control
		if row == null:
			continue
		var enabled: bool = on[spec["part"]]
		row.modulate.a = 1.0 if enabled else 0.45
		_set_inputs_enabled(row, enabled)
	if _rails_chk:
		_rails_chk.disabled = not _style.rail_enabled
		_rails_chk.tooltip_text = "" if _style.rail_enabled else "Рельс выключен в стиле (Параметры, Части трака)"
	if _sleepers_chk:
		_sleepers_chk.disabled = not _style.sleeper_enabled
		_sleepers_chk.tooltip_text = "" if _style.sleeper_enabled else "Шпала выключена в стиле (Параметры, Части трака)"
	if _profiles:
		_profiles.update_parts()
	if _materials:
		_materials.update_parts()
	if _sleepers:
		_sleepers.update_parts()


func _set_inputs_enabled(node: Node, enabled: bool) -> void:
	for c in node.get_children():
		if c is SpinBox:
			(c as SpinBox).editable = enabled
		elif c is BaseButton:
			(c as BaseButton).disabled = not enabled
		_set_inputs_enabled(c, enabled)


func _on_vec_changed(key: String, spins: Array) -> void:
	if _syncing or _style == null:
		return
	if spins.size() == 2:
		_set_prop(key, Vector2(spins[0].value, spins[1].value))
	else:
		_set_prop(key, Vector3(spins[0].value, spins[1].value, spins[2].value))


func _mark_dirty() -> void:
	_dirty = true
	_update_file_label()
	_refresh_timer.start()


func _refresh() -> void:
	view.set_style(_style)
	_update_passport()


func _rebuild_view(refit: bool) -> void:
	view.rebuild()
	if refit:
		view.fit()


# --- набор стилей проекта (ATTN_17 §17.13) ---

func _on_add_to_set() -> void:
	if _style == null:
		return
	if _current_path.is_empty() or _dirty:
		_say("Сначала сохраните стиль (Ctrl+S): в набор попадает файл стиля", true)
		return
	var r := TrackStyleSetIO.add_to_project(_current_path)
	if not r["ok"]:
		_say(String(r["error"]), true)
		return
	if r["already"]:
		_say("Стиль «%s» уже в наборе. Выберите его в списке стилей на верхней панели игры." % String(r["id"]))
		return
	_say("Стиль «%s» добавлен в setting/track_style_set.tres. Выберите его в списке стилей на верхней панели: новые траки любой формы встанут в нём. Замер: tests/track_style_bench.tscn." % String(r["id"]))


# --- выбор ресурса ---

func _open_pick(key: String, base: String) -> void:
	_pick_key = key
	_pick_base = base
	var start := "res://data/tracks/materials" if base == "Material" else "res://data/tracks/meshes"
	_file_dialog.current_dir = start if DirAccess.dir_exists_absolute(start) else "res://data"
	_file_dialog.popup_centered(Vector2i(900, 600))


func _on_file_picked(path: String) -> void:
	var res := ResourceLoader.load(path)
	if res == null:
		_say("Не удалось загрузить %s" % path, true)
		return
	var ok := (res is Material) if _pick_base == "Material" else (res is Mesh)
	if not ok:
		_say("%s: это %s, а нужен %s" % [path.get_file(), res.get_class(), _pick_base], true)
		return
	_set_prop(_pick_key, res)
	_say("%s: %s" % [_pick_key, path.get_file()])


# ==========================================
# СОХРАНЕНИЕ
# ==========================================

func _on_save() -> void:
	if _style == null:
		return
	if _current_path.is_empty():
		_open_save_as()
		return
	_write(_current_path)


func _open_save_as() -> void:
	if _style == null:
		return
	_saveas_edit.text = String(_style.id)
	_update_saveas_info()
	_saveas_dialog.popup_centered(Vector2i(520, 170))
	_saveas_edit.grab_focus()
	_saveas_edit.select_all()


func _update_saveas_info() -> void:
	var id := _saveas_edit.text.strip_edges()
	var ok_btn := _saveas_dialog.get_ok_button()
	if not TrackStyleIO.is_valid_id(id):
		_saveas_info.text = "Недопустимый идентификатор"
		_saveas_info.modulate = Color(1.0, 0.5, 0.5)
		ok_btn.disabled = true
		return
	ok_btn.disabled = false
	var p := TrackStyleIO.path_for_id(id)
	if FileAccess.file_exists(p) and p != _current_path:
		_saveas_info.text = "Файл %s уже есть: будет перезаписан" % p
		_saveas_info.modulate = Color(1.0, 0.8, 0.4)
	else:
		_saveas_info.text = p
		_saveas_info.modulate = Color(0.8, 0.9, 1.0)


func _on_saveas_confirmed() -> void:
	var id := _saveas_edit.text.strip_edges()
	if not TrackStyleIO.is_valid_id(id):
		_say("Недопустимый идентификатор: латиница в нижнем регистре, цифры, _", true)
		return
	_style.id = StringName(id)
	_write(TrackStyleIO.path_for_id(id))


func _write(path: String) -> void:
	var err := TrackStyleIO.save(_style, path)
	if err != OK:
		_say("Не удалось записать %s (код %d)" % [path, err], true)
		return
	_current_path = path
	_dirty = false
	settings.set_value("state", "last_style", path)
	_reload_list()
	_update_file_label()
	_say("Сохранено: %s. Godot подхватит файл при возврате фокуса в редактор." % path)


func _update_file_label() -> void:
	if _style == null:
		_file_label.text = ""
		return
	var fname := _current_path.get_file() if not _current_path.is_empty() else "(не сохранён) %s.tres" % String(_style.id)
	_file_label.text = fname + (" *" if _dirty else "")


func _say(text: String, error := false) -> void:
	_status.text = text
	_status.modulate = Color(1.0, 0.55, 0.55) if error else Color(0.75, 0.85, 1.0)
	if error and not text.is_empty():
		push_warning("TrackStudio: " + text)


# ==========================================
# ПАСПОРТ
# ==========================================

func _update_passport() -> void:
	if _style == null:
		return
	var t := "[b]Паспорт: %s[/b]\n[table=2]" % _esc(String(_style.id))
	for row in TrackStyleValidator.numbers(_style):
		t += "[cell]%s  [/cell][cell][b]%s[/b][/cell]" % [_esc(row[0]), _esc(row[1])]
	t += "[/table]"
	_pass_nums.text = t

	var msgs := TrackStyleValidator.validate(_style)
	var ne := 0
	var nw := 0
	var body := ""
	for m in msgs:
		match m["level"]:
			TrackStyleValidator.Level.ERROR:
				ne += 1
				body += "[color=%s][b]Ошибка:[/b] %s[/color]\n" % [COLOR_ERROR, _esc(m["text"])]
			TrackStyleValidator.Level.WARN:
				nw += 1
				body += "[color=%s][b]Внимание:[/b] %s[/color]\n" % [COLOR_WARN, _esc(m["text"])]
			_:
				body += "[color=%s]%s[/color]\n" % [COLOR_INFO, _esc(m["text"])]
	var head := "[b]Проверка[/b]: "
	if ne == 0 and nw == 0:
		head += "[color=%s]ошибок и предупреждений нет[/color]\n" % COLOR_OK
	else:
		head += "ошибок %d, предупреждений %d\n" % [ne, nw]
	if not TrackStyleValidator.can_build(_style):
		var why := "не включена ни одна часть трака." if not _style.has_any_part() else "в профиле рельса (или балласта) меньше 2 точек."
		head += "[color=%s]Меш не строится: %s[/color]\n" % [COLOR_ERROR, why]
	_pass_msgs.text = head + body


static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")
