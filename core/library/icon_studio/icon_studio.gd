extends Control

########################
## Icon Studio (ATTN_18). Прототип режима Library.
########################
## Запуск: открыть icon_studio.tscn и нажать F6 (Run Current Scene).
## I0-I1: каркас, окно, настройки, список объектов, объект в мире.
## I2-I4: камера и слоты, свет, фон, тень, качество, предпросмотр в размере результата.
## Интерфейс собирается кодом, чтобы не плодить правки в .tscn.

const StudioSettings := preload("res://core/library/icon_studio/studio_settings.gd")
const StudioWorld := preload("res://core/library/icon_studio/studio_world.gd")
const Template := preload("res://core/library/icon_studio/icon_template.gd")

const DEFAULT_SETTLE := 2
const LAST_OBJECT_KEY := "last_object"
const TONEMAPS := ["Linear", "Reinhard", "Filmic", "ACES", "AgX"]

var settings: StudioSettings
var world: StudioWorld
var template: Template

var _all: Array[EntitySetting] = []
var _current: EntitySetting
var _building_tree := false
var _qualities := {}            # id -> QualityPreset
var _quality_ids: Array = []
var _bindings := {}             # ключ свойства шаблона -> {ctrl, kind, values, val}
var _slot_buttons: Array[Button] = []

var _split_left: HSplitContainer
var _split_right: HSplitContainer
var _search: LineEdit
var _tree: Tree
var _source: OptionButton
var _settle: SpinBox
var _auto_fit: CheckBox
var _ortho: CheckBox
var _fov: HSlider
var _fov_label: Label
var _per_object: CheckBox
var _flex_box: VBoxContainer
var _info: Label
var _viewport: SubViewport
var _view_area: PanelContainer
var _aspect_box: AspectRatioContainer
var _preview_vp: SubViewport
var _preview_cam: Camera3D
var _preview_holder: Control
var _preview_zoom: OptionButton
var _out_w: SpinBox
var _out_h: SpinBox
var _look_option: OptionButton
var _reset_dialog: ConfirmationDialog


func _ready() -> void:
	settings = StudioSettings.new()
	settings.name = "StudioSettings"
	add_child(settings)
	settings.restore_window()
	get_window().title = "Icon Studio"

	_build_qualities()
	_load_template()
	_build_ui()
	_load_objects()
	_apply_saved_ui()
	_sync_controls()
	_apply_template()
	_rebuild_tree()
	# Размеры контейнеров известны только после первого кадра раскладки
	await get_tree().process_frame
	_select_last_object()


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
	if k.keycode == KEY_F:
		world.fit()
		get_viewport().set_input_as_handled()
	elif k.keycode >= KEY_1 and k.keycode < KEY_1 + Template.SLOT_COUNT:
		_on_slot(k.keycode - KEY_1)
		get_viewport().set_input_as_handled()


# ==========================================
# ШАБЛОН И КАЧЕСТВО
# ==========================================

func _build_qualities() -> void:
	_qualities.clear()
	for id in GFX.qualities:
		_qualities[id] = GFX.qualities[id]
	for id in QualityPreset.builtin_ids():
		if not _qualities.has(id):
			_qualities[id] = QualityPreset.builtin(id)
	# Студийный tier: fps не важен, берём максимум (ATTN_18 I4). Встроенные tier игры не меняем
	var m := QualityPreset.builtin(&"high")
	m.id = &"icon_max"
	m.title = "Icon max"
	m.dir_shadow_atlas = 8192
	m.dir_shadow_splits = 4
	m.dir_shadow_max_distance = 300.0
	m.soft_shadow_quality = 5
	m.positional_shadow_atlas = 4096
	m.msaa = 3
	m.fxaa = false
	m.ssao = true
	m.ssao_half_size = false
	m.ssao_quality = 3
	m.ssil = true
	m.contact_shadows = true
	_qualities[&"icon_max"] = m
	_quality_ids = []
	for id in [&"low", &"medium", &"high", &"icon_max"]:
		if _qualities.has(id):
			_quality_ids.append(id)
	for id in _qualities:
		if not _quality_ids.has(id):
			_quality_ids.append(id)


func _new_template() -> Template:
	var t := Template.new()
	t.slots = _default_slots()
	return t


func _default_slots() -> Array:
	var a: Array = []
	for v in [[35.0, -25.0, false], [90.0, 0.0, false], [0.0, 0.0, false],
			[35.0, -89.0, false], [90.0, 0.0, true], [-35.0, -25.0, false]]:
		a.append({"yaw": v[0], "pitch": v[1], "ortho": v[2], "fov": 30.0, "zoom": 1.0, "pivot": Vector3.ZERO})
	return a


func _load_template() -> void:
	template = _new_template()
	var d: Variant = settings.get_value("template", "data", null)
	if d is Dictionary:
		template.from_dict(d)
		template.quality_id = StringName(template.quality_id)


func _quality_of_template() -> QualityPreset:
	var q: QualityPreset = _qualities.get(template.quality_id)
	if q == null:
		q = _qualities.get(&"medium")
	return q


## Отдаёт шаблон миру и предпросмотру, сохраняет шаблон
func _apply_template() -> void:
	var sz: Vector2i = template.output_size
	sz = Vector2i(clampi(sz.x, 16, 4096), clampi(sz.y, 16, 4096))
	template.output_size = sz
	_preview_vp.size = sz
	_aspect_box.ratio = float(sz.x) / float(sz.y)
	_update_preview_holder()
	world.apply_template(template, _quality_of_template())


func _template_changed() -> void:
	_apply_template()
	settings.set_value("template", "data", template.to_dict())


func _set_template(key: String, v: Variant) -> void:
	var cur: Variant = template.get(key)
	if typeof(cur) == TYPE_INT and typeof(v) == TYPE_FLOAT:
		v = int(v)
	template.set(key, v)
	_template_changed()


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
	_build_reset_dialog()


func _build_left_panel() -> void:
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	_split_left.add_child(left)
	var lv := VBoxContainer.new()
	left.add_child(lv)

	var title := Label.new()
	title.text = "Объекты игры"
	lv.add_child(title)

	_search = LineEdit.new()
	_search.placeholder_text = "Поиск по имени и описанию"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String): _rebuild_tree())
	lv.add_child(_search)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.item_selected.connect(_on_tree_selected)
	lv.add_child(_tree)

	var src_row := HBoxContainer.new()
	lv.add_child(src_row)
	var src_label := Label.new()
	src_label.text = "Источник"
	src_row.add_child(src_label)
	_source = OptionButton.new()
	_source.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_source.add_item("Entity (как в игре)", StudioWorld.SOURCE_ENTITY)
	_source.add_item("Только сцена (запасной)", StudioWorld.SOURCE_SCENE)
	_source.item_selected.connect(func(i: int):
		settings.set_value("ui", "source", i)
		_reload_current())
	src_row.add_child(_source)

	var settle_row := HBoxContainer.new()
	lv.add_child(settle_row)
	var settle_label := Label.new()
	settle_label.text = "Кадров «settle»"
	settle_label.tooltip_text = "Сколько кадров объект живёт после создания, чтобы построились меши. Потом обработка отключается."
	settle_row.add_child(settle_label)
	_settle = SpinBox.new()
	_settle.min_value = 0
	_settle.max_value = 10
	_settle.value = DEFAULT_SETTLE
	_settle.value_changed.connect(func(v: float):
		settings.set_value("ui", "settle", int(v))
		_reload_current())
	settle_row.add_child(_settle)

	_auto_fit = CheckBox.new()
	_auto_fit.text = "Вписывать при смене объекта"
	_auto_fit.button_pressed = true
	_auto_fit.toggled.connect(func(on: bool): settings.set_value("ui", "auto_fit", on))
	lv.add_child(_auto_fit)


func _build_center() -> void:
	# Вид имеет пропорции результата: что в рамке, то и попадёт в кадр
	_view_area = PanelContainer.new()
	_view_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_area.custom_minimum_size = Vector2(320, 240)
	_view_area.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.11)
	_view_area.add_theme_stylebox_override("panel", bg)
	_split_right.add_child(_view_area)

	_aspect_box = AspectRatioContainer.new()
	_aspect_box.stretch_mode = AspectRatioContainer.STRETCH_FIT
	_aspect_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view_area.add_child(_aspect_box)

	# Шахматка под видом: видна при прозрачном фоне (как в предпросмотре)
	var view_checker := TextureRect.new()
	view_checker.texture = _make_checker()
	view_checker.stretch_mode = TextureRect.STRETCH_TILE
	view_checker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view_checker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	view_checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_aspect_box.add_child(view_checker)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_aspect_box.add_child(svc)

	# Один World3D на оба вида. own_world_3d не годится: у такого вида свойство world_3d пустое
	var studio_world3d := World3D.new()
	_viewport = SubViewport.new()
	_viewport.world_3d = studio_world3d
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.handle_input_locally = false
	svc.add_child(_viewport)

	world = StudioWorld.new()
	world.name = "StudioWorld"
	_viewport.add_child(world)
	_view_area.gui_input.connect(world.handle_gui_input)
	world.camera_changed.connect(_on_camera_changed)

	# Предпросмотр: тот же мир, размер ровно как у результата
	_preview_vp = SubViewport.new()
	_preview_vp.size = template.output_size
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_vp.world_3d = studio_world3d
	add_child(_preview_vp)
	_preview_cam = Camera3D.new()
	_preview_cam.current = true
	_preview_vp.add_child(_preview_cam)
	var views: Array[SubViewport] = [_viewport, _preview_vp]
	world.register_views(views, _preview_cam)


func _build_right_panel() -> void:
	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(340, 0)
	_split_right.add_child(right)
	var rv := VBoxContainer.new()
	right.add_child(rv)

	# --- Предпросмотр 1:1 ---
	var ph := HBoxContainer.new()
	rv.add_child(ph)
	var pl := Label.new()
	pl.text = "Предпросмотр, реальный размер"
	pl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ph.add_child(pl)
	_preview_zoom = OptionButton.new()
	_preview_zoom.add_item("×1", 1)
	_preview_zoom.add_item("×2", 2)
	_preview_zoom.add_item("×4", 4)
	_preview_zoom.item_selected.connect(func(_i: int):
		settings.set_value("ui", "preview_zoom", _preview_zoom.get_selected_id())
		_update_preview_holder())
	ph.add_child(_preview_zoom)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 230)
	rv.add_child(scroll)
	_preview_holder = Control.new()
	scroll.add_child(_preview_holder)
	var checker := TextureRect.new()
	checker.texture = _make_checker()
	checker.stretch_mode = TextureRect.STRETCH_TILE
	checker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	checker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	checker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_holder.add_child(checker)
	var pr := TextureRect.new()
	pr.texture = _preview_vp.get_texture()
	pr.stretch_mode = TextureRect.STRETCH_SCALE
	pr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	pr.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_holder.add_child(pr)

	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.custom_minimum_size = Vector2(0, 90)
	_info.text = "Выберите объект в списке."
	rv.add_child(_info)

	# --- Вкладки настроек ---
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rv.add_child(tabs)
	_build_tab_camera(_tab(tabs, "Камера"))
	_build_tab_light(_tab(tabs, "Свет"))
	_build_tab_background(_tab(tabs, "Фон"))
	_build_tab_quality(_tab(tabs, "Качество"))

	var reset_btn := Button.new()
	reset_btn.text = "Сброс…"
	reset_btn.pressed.connect(func(): _reset_dialog.popup_centered())
	rv.add_child(reset_btn)


func _tab(tabs: TabContainer, title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(sc)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(box)
	return box


func _build_tab_camera(box: VBoxContainer) -> void:
	_ortho = CheckBox.new()
	_ortho.text = "Ортогональная проекция"
	_ortho.toggled.connect(func(on: bool): world.set_ortho(on))
	box.add_child(_ortho)

	var fov_row := HBoxContainer.new()
	box.add_child(fov_row)
	var fl := Label.new()
	fl.text = "Угол обзора (fov)"
	fl.custom_minimum_size = Vector2(150, 0)
	fov_row.add_child(fl)
	_fov = HSlider.new()
	_fov.min_value = 10
	_fov.max_value = 60
	_fov.step = 1
	_fov.value = 30
	_fov.custom_minimum_size = Vector2(100, 0)
	_fov.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fov_row.add_child(_fov)
	_fov_label = Label.new()
	_fov_label.custom_minimum_size = Vector2(40, 0)
	fov_row.add_child(_fov_label)
	_fov.value_changed.connect(func(v: float):
		_fov_label.text = String.num(v, 0)
		world.set_fov(v))

	_add_slider(box, "Поле вокруг объекта", "fit_margin", 0.0, 0.4, 0.01)

	var views := HFlowContainer.new()
	box.add_child(views)
	for v in [["3/4", 35.0, -25.0], ["Сбоку", 90.0, 0.0], ["Спереди", 0.0, 0.0],
			["Сзади", 180.0, 0.0], ["Сверху", NAN, -89.0]]:
		var b := Button.new()
		b.text = v[0]
		var vy: float = v[1]
		var vp: float = v[2]
		b.pressed.connect(func():
			world.set_view(world.yaw if is_nan(vy) else vy, vp))
		views.add_child(b)

	var fit_btn := Button.new()
	fit_btn.text = "Вписать (F)"
	fit_btn.pressed.connect(func(): world.fit())
	box.add_child(fit_btn)

	var sl := Label.new()
	sl.text = "Слоты ракурса: клик или клавиши 1–6 переходят, Shift запоминает (пустой слот запоминается сразу)"
	sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(sl)
	var slots := HBoxContainer.new()
	box.add_child(slots)
	for i in Template.SLOT_COUNT:
		var b := Button.new()
		b.custom_minimum_size = Vector2(44, 0)
		b.pressed.connect(func(): _on_slot(i))
		slots.add_child(b)
		_slot_buttons.append(b)
	_per_object = CheckBox.new()
	_per_object.text = "Слоты для этого объекта"
	_per_object.toggled.connect(func(on: bool):
		settings.set_value("ui", "per_object", on)
		_refresh_slots())
	box.add_child(_per_object)
	_add_check(box, "Плавный переход к слоту", "smooth_slots")

	_flex_box = VBoxContainer.new()
	_flex_box.visible = false
	box.add_child(_flex_box)
	var flex_l := Label.new()
	flex_l.text = "Форма flex"
	_flex_box.add_child(flex_l)
	var flex_row := HBoxContainer.new()
	_flex_box.add_child(flex_row)
	for p in [["Прямая", &"straight"], ["Дуга", &"arc"], ["Змейка", &"snake"]]:
		var b := Button.new()
		b.text = p[0]
		var preset: StringName = p[1]
		b.pressed.connect(func():
			var ok: bool = await world.apply_flex_preset(preset)
			if not ok:
				_info.text += "\nНе удалось применить форму flex.")
		flex_row.add_child(b)


func _build_tab_light(box: VBoxContainer) -> void:
	_add_check(box, "Свет следует за камерой", "light_follow_camera")
	_add_slider(box, "Ключевой, яркость", "key_energy", 0.0, 4.0, 0.05)
	_add_slider(box, "Заполняющий, яркость", "fill_energy", 0.0, 2.0, 0.05)
	_add_slider(box, "Контровой, яркость", "rim_energy", 0.0, 3.0, 0.05)
	_add_slider(box, "Ключевой, наклон", "key_pitch", -89.0, 0.0, 1.0)
	_add_slider(box, "Ключевой, поворот", "key_yaw", -180.0, 180.0, 1.0)
	_add_color(box, "Цвет света", "light_color")
	_add_check(box, "Тень", "shadow")
	_add_slider(box, "Мягкость тени", "shadow_softness", 0.0, 8.0, 0.1)


func _build_tab_background(box: VBoxContainer) -> void:
	_add_option(box, "Фон", "bg_mode", ["Прозрачный", "Ровный цвет", "Поверхность с горизонтом"], [0, 1, 2])
	_add_color(box, "Цвет фона", "bg_color")
	_add_color(box, "Небо, верх", "sky_top")
	_add_color(box, "Небо, горизонт", "sky_horizon")
	_add_color(box, "Поверхность", "ground_color")
	_add_option(box, "Способ тени (прозр./цвет)", "catcher_mode", ["Шейдер light()", "shadow_to_opacity"], [0, 1])
	var n := Label.new()
	n.text = "Тень на прозрачном фоне и на ровном цвете рисуется «ловцом тени» (пол без цвета, виден только в тени)."
	n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(n)


func _build_tab_quality(box: VBoxContainer) -> void:
	var labels: Array = []
	for id in _quality_ids:
		labels.append(String((_qualities[id] as QualityPreset).title))
	_add_option(box, "Качество", "quality_id", labels, _quality_ids)
	_add_slider(box, "Суперсэмплинг ×", "supersample", 1.0, 8.0, 1.0)

	var size_row := HBoxContainer.new()
	box.add_child(size_row)
	var sl := Label.new()
	sl.text = "Размер, px"
	sl.custom_minimum_size = Vector2(150, 0)
	size_row.add_child(sl)
	_out_w = _size_spin()
	_out_h = _size_spin()
	size_row.add_child(_out_w)
	var x := Label.new()
	x.text = "×"
	size_row.add_child(x)
	size_row.add_child(_out_h)

	box.add_child(HSeparator.new())
	var cl := Label.new()
	cl.text = "Коррекция (в реальном времени)"
	box.add_child(cl)
	_add_option(box, "Тонмаппинг", "tonemap", TONEMAPS, [0, 1, 2, 3, 4])
	_add_slider(box, "Экспозиция", "exposure", 0.2, 3.0, 0.05)
	_add_slider(box, "Яркость", "brightness", 0.5, 1.5, 0.01)
	_add_slider(box, "Контраст", "contrast", 0.5, 1.5, 0.01)
	_add_slider(box, "Насыщенность", "saturation", 0.0, 2.0, 0.01)

	var look_row := HBoxContainer.new()
	box.add_child(look_row)
	_look_option = OptionButton.new()
	_look_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id in GFX.looks:
		_look_option.add_item(String(id))
	look_row.add_child(_look_option)
	var lb := Button.new()
	lb.text = "Взять из Look"
	lb.pressed.connect(_take_look)
	look_row.add_child(lb)


func _size_spin() -> SpinBox:
	var s := SpinBox.new()
	s.min_value = 16
	s.max_value = 4096
	s.step = 1
	s.value = 150
	s.value_changed.connect(func(_v: float):
		template.output_size = Vector2i(int(_out_w.value), int(_out_h.value))
		_template_changed())
	return s


func _take_look() -> void:
	var id := StringName(_look_option.get_item_text(_look_option.selected))
	var l: GraphicsPreset = GFX.looks.get(id)
	if l == null:
		return
	template.tonemap = int(l.tonemap)
	template.exposure = l.tonemap_exposure
	template.brightness = l.brightness
	template.contrast = l.contrast
	template.saturation = l.saturation
	_sync_controls()
	_template_changed()


func _build_reset_dialog() -> void:
	_reset_dialog = ConfirmationDialog.new()
	_reset_dialog.title = "Сброс"
	_reset_dialog.dialog_text = "Что сбросить?\n«Всё»: окно, панели, шаблон, слоты, камера и настройки списка вернутся к умолчанию."
	_reset_dialog.ok_button_text = "Сбросить всё"
	_reset_dialog.cancel_button_text = "Отмена"
	_reset_dialog.add_button("Только шаблон", true, "template")
	_reset_dialog.add_button("Только вид камеры", true, "camera")
	_reset_dialog.confirmed.connect(_reset_all)
	_reset_dialog.custom_action.connect(func(action: StringName):
		_reset_dialog.hide()
		if action == &"camera":
			_reset_camera()
		elif action == &"template":
			_reset_template())
	add_child(_reset_dialog)


# --- Привязка элементов к полям шаблона ---

func _row(box: VBoxContainer, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	box.add_child(row)
	var lab := Label.new()
	lab.text = text
	lab.custom_minimum_size = Vector2(150, 0)
	row.add_child(lab)
	return row


func _add_slider(box: VBoxContainer, text: String, key: String, lo: float, hi: float, step: float) -> void:
	var row := _row(box, text)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.custom_minimum_size = Vector2(100, 0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sl)
	var val := Label.new()
	val.custom_minimum_size = Vector2(40, 0)
	row.add_child(val)
	sl.value_changed.connect(func(v: float):
		val.text = String.num(v, 2)
		_set_template(key, v))
	_bindings[key] = {"ctrl": sl, "kind": "slider", "val": val}


func _add_check(box: VBoxContainer, text: String, key: String) -> void:
	var cb := CheckBox.new()
	cb.text = text
	cb.toggled.connect(func(on: bool): _set_template(key, on))
	box.add_child(cb)
	_bindings[key] = {"ctrl": cb, "kind": "check"}


func _add_color(box: VBoxContainer, text: String, key: String) -> void:
	var row := _row(box, text)
	var cp := ColorPickerButton.new()
	cp.custom_minimum_size = Vector2(70, 24)
	cp.edit_alpha = false
	cp.color_changed.connect(func(c: Color): _set_template(key, c))
	row.add_child(cp)
	_bindings[key] = {"ctrl": cp, "kind": "color"}


func _add_option(box: VBoxContainer, text: String, key: String, labels: Array, values: Array) -> void:
	var row := _row(box, text)
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for l in labels:
		ob.add_item(String(l))
	ob.item_selected.connect(func(i: int): _set_template(key, values[i]))
	row.add_child(ob)
	_bindings[key] = {"ctrl": ob, "kind": "option", "values": values}


## Элементы показывают значения шаблона (сигналы не срабатывают)
func _sync_controls() -> void:
	for key in _bindings:
		var b: Dictionary = _bindings[key]
		var v: Variant = template.get(key)
		match String(b.kind):
			"slider":
				(b.ctrl as HSlider).set_value_no_signal(float(v))
				(b.val as Label).text = String.num(float(v), 2)
			"check":
				(b.ctrl as CheckBox).set_pressed_no_signal(bool(v))
			"color":
				(b.ctrl as ColorPickerButton).color = v
			"option":
				var idx: int = (b.values as Array).find(v)
				if idx >= 0:
					(b.ctrl as OptionButton).select(idx)
	_out_w.set_value_no_signal(template.output_size.x)
	_out_h.set_value_no_signal(template.output_size.y)
	_refresh_slots()


func _sync_camera_controls() -> void:
	_ortho.set_pressed_no_signal(world.ortho)
	_fov.set_value_no_signal(world.fov)
	_fov_label.text = String.num(world.fov, 0)


func _make_checker() -> ImageTexture:
	var img := Image.create(16, 16, false, Image.FORMAT_RGB8)
	img.fill(Color(0.42, 0.42, 0.42))
	for y in 16:
		for x in 16:
			if (x < 8) != (y < 8):
				img.set_pixel(x, y, Color(0.62, 0.62, 0.62))
	return ImageTexture.create_from_image(img)


func _update_preview_holder() -> void:
	if _preview_holder == null:
		return
	var z := _preview_zoom.get_selected_id() if _preview_zoom.item_count > 0 else 1
	_preview_holder.custom_minimum_size = Vector2(template.output_size) * float(z)


## Подставляет сохранённые значения в элементы (сигналы при этом не должны писать лишнее)
func _apply_saved_ui() -> void:
	_split_left.split_offset = int(settings.get_value("ui", "split_left", 0))
	_split_right.split_offset = int(settings.get_value("ui", "split_right", 0))
	_source.select(clampi(int(settings.get_value("ui", "source", 0)), 0, _source.item_count - 1))
	_settle.set_value_no_signal(int(settings.get_value("ui", "settle", DEFAULT_SETTLE)))
	_auto_fit.set_pressed_no_signal(bool(settings.get_value("ui", "auto_fit", true)))
	_per_object.set_pressed_no_signal(bool(settings.get_value("ui", "per_object", false)))
	var z := int(settings.get_value("ui", "preview_zoom", 1))
	for i in _preview_zoom.item_count:
		if _preview_zoom.get_item_id(i) == z:
			_preview_zoom.select(i)
	var cam: Variant = settings.get_value("camera", "state", {})
	if cam is Dictionary:
		world.set_camera_state(cam)
	_sync_camera_controls()


# ==========================================
# СЛОТЫ РАКУРСА
# ==========================================

func _obj_key() -> String:
	return _current.resource_path.get_file().get_basename()


func _use_object_slots() -> bool:
	return _per_object.button_pressed and _current != null


## Копия слотов (шаблонных или объекта): правим копию и кладём обратно _slots_put
func _slots_get() -> Array:
	var src: Array = template.slots
	if _use_object_slots():
		var st: Variant = settings.get_value("object_overrides", _obj_key(), null)
		if st is Array:
			src = st
	var a := src.duplicate(true)
	a.resize(Template.SLOT_COUNT)
	return a


func _slots_put(a: Array) -> void:
	if _use_object_slots():
		settings.set_value("object_overrides", _obj_key(), a)
	else:
		template.slots = a
		_template_changed()
	_refresh_slots()


func _refresh_slots() -> void:
	var a := _slots_get()
	for i in _slot_buttons.size():
		_slot_buttons[i].text = str(i + 1) + ("" if a[i] is Dictionary else " ·")
		_slot_buttons[i].tooltip_text = "Слот %d: %s" % [i + 1, "задан" if a[i] is Dictionary else "пуст"]


func _on_slot(i: int) -> void:
	var a := _slots_get()
	if Input.is_key_pressed(KEY_SHIFT) or not (a[i] is Dictionary):
		a[i] = world.capture_slot()
		_slots_put(a)
		_info.text = "Ракурс сохранён в слот %d" % (i + 1)
	else:
		world.go_slot(a[i], template.smooth_slots)
		_sync_camera_controls()


# ==========================================
# СПИСОК ОБЪЕКТОВ
# ==========================================

func _load_objects() -> void:
	_all.clear()
	for dir in Global.object_dirs:
		for file in DirAccess.get_files_at(dir):
			if not file.ends_with(".tres"):
				continue
			var res := load(dir + file)
			if res is EntitySetting and res.build_behavior != EntitySetting.BuildBehavior.CUT_TOOL:   # 13.3 S2: инструмент не объект
				_all.append(res)
	_all.sort_custom(func(a: EntitySetting, b: EntitySetting) -> bool:
		if a.category != b.category:
			return String(a.category) < String(b.category)
		if a.tag != b.tag:
			return String(a.tag) < String(b.tag)
		return a.id < b.id)


func _rebuild_tree() -> void:
	_building_tree = true
	_tree.clear()
	var root := _tree.create_item()
	var f := _search.text.strip_edges().to_lower()
	var cats := {}
	var tags := {}
	var current_item: TreeItem = null
	for s in _all:
		if f != "" and not (s.name.to_lower().contains(f) or s.description.to_lower().contains(f)):
			continue
		var cat_key := String(s.category)
		if not cats.has(cat_key):
			var ci := _tree.create_item(root)
			ci.set_text(0, cat_key)
			ci.set_selectable(0, false)
			cats[cat_key] = ci
		var tag_key := cat_key + "/" + String(s.tag)
		if not tags.has(tag_key):
			var ti := _tree.create_item(cats[cat_key])
			ti.set_text(0, String(s.tag))
			ti.set_selectable(0, false)
			tags[tag_key] = ti
		var it := _tree.create_item(tags[tag_key])
		it.set_text(0, "%s  %s" % [s.name, s.description])
		it.set_metadata(0, s)
		if s.icon:
			it.set_icon(0, s.icon)
			it.set_icon_max_width(0, 24)
		if s == _current:
			current_item = it
	if current_item:
		current_item.select(0)
	_building_tree = false


func _on_tree_selected() -> void:
	if _building_tree:
		return
	var it := _tree.get_selected()
	if it == null:
		return
	var s: Variant = it.get_metadata(0)
	if s is EntitySetting:
		_show_object(s)


func _select_last_object() -> void:
	var path := String(settings.get_value("state", LAST_OBJECT_KEY, ""))
	for s in _all:
		if s.resource_path == path:
			_current = s
			_rebuild_tree()   # выделяет _current в списке
			_show_object(s, true)
			return
	if not _all.is_empty():
		_info.text = "Выберите объект в списке."


# ==========================================
# ОБЪЕКТ И КАМЕРА
# ==========================================

func _reload_current() -> void:
	if _current:
		_show_object(_current, true)


func _show_object(s: EntitySetting, force := false) -> void:
	if not force and s == _current:
		return
	_current = s
	settings.set_value("state", LAST_OBJECT_KEY, s.resource_path)
	_info.text = "Загрузка: %s ..." % s.name
	_flex_box.visible = false
	var t0 := Time.get_ticks_msec()
	var info: Dictionary = await world.set_subject(s, _source.get_selected_id(), int(_settle.value))
	if info.stale or s != _current:
		return
	if info.ok and _auto_fit.button_pressed:
		world.fit()
	_flex_box.visible = world.has_flex()
	_refresh_slots()
	_show_info(s, info, Time.get_ticks_msec() - t0)


func _show_info(s: EntitySetting, info: Dictionary, ms: int) -> void:
	var lines: Array[String] = []
	lines.append("%s (id %d)" % [s.name, s.id])
	lines.append("%s / %s" % [s.category, s.tag])
	lines.append("Источник: %s, %d мс" % [info.via, ms])
	if info.ok:
		var a: AABB = info.aabb
		lines.append("Мешей: %d" % info.meshes)
		lines.append("Размер: %.2f × %.2f × %.2f" % [a.size.x, a.size.y, a.size.z])
	if info.warn != "":
		lines.append("Внимание: " + info.warn)
	if info.error != "":
		lines.append("Ошибка: " + info.error)
	_info.text = "\n".join(lines)


func _on_camera_changed() -> void:
	settings.set_value("camera", "state", world.get_camera_state())


func _reset_camera() -> void:
	world.set_camera_state({"yaw": 35.0, "pitch": -25.0, "fov": 30.0, "ortho": false})
	world.fit()
	_sync_camera_controls()
	_on_camera_changed()


func _reset_template() -> void:
	template = _new_template()
	_sync_controls()
	_template_changed()


func _reset_all() -> void:
	settings.reset_all()
	settings.reset_window()
	_split_left.split_offset = 0
	_split_right.split_offset = 0
	_source.select(0)
	_settle.set_value_no_signal(DEFAULT_SETTLE)
	_auto_fit.set_pressed_no_signal(true)
	_per_object.set_pressed_no_signal(false)
	_preview_zoom.select(0)
	_search.text = ""
	_reset_template()
	_reset_camera()
	_rebuild_tree()
	settings.flush()
	_reload_current()
