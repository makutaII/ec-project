extends "res://core/library/workspace/workspace.gd"

# XX claude-library (новый файл)
########################
## Покраска: грунт по зонам, кисть, исполнения модели (ATTN_22 §22.7.2.1, шаги L3 и C2.1)
########################
## Два режима. «Заливка зон»: правит screen.variant (буфер исполнения текущей модели) и сразу применяет его к мешам
## кузова (screen.apply_variant); зоны: «Весь корпус» и каждая поверхность каждого меша (PaintZones).
## «Кисть»: рисует в слой краски по UV2 (PaintEngine): кисть, аэрограф, ластик; ЛКМ рисует, ПКМ вращает.
## Мазки кисти пока не входят в исполнение (сохранение и игра: шаг C2.1b): при выборе другой модели они пропадают.
## Уровни paint.level: 0 покраска выключена; 1 только цвет зоны; 2 плюс отделка, кроющая/лессировка и кисть.
## Исполнения хранятся JSON в user://library/variants/ (VariantIO); «Сохранить» обновляет открытое исполнение,
## «Как новое» создаёт копию. Несохранённые правки теряются при выборе другой модели.

const MODE_ZONES := 0
const MODE_BRUSH := 1
const STROKE_MAX_STEPS := 24    # штампов за одно движение мыши (шаг задаёт инструмент: spacing)

const PALETTE := [
	["Белый", "#f2f2f0"], ["Чёрный", "#1b1b1d"], ["Серый", "#7d7f82"], ["Красный", "#c0392b"],
	["Тёмно-красный", "#7a1f1f"], ["Оранжевый", "#e67e22"], ["Жёлтый", "#f1c40f"], ["Зелёный", "#2e9e5b"],
	["Тёмно-зелёный", "#1f5a3a"], ["Голубой", "#3b9ae1"], ["Синий", "#1f4e9c"], ["Коричневый", "#6b4226"],
]

var _note: Label
var _controls: VBoxContainer
var _zone_opt: OptionButton
var _color_btn: ColorPickerButton
var _finish_row: HBoxContainer
var _finish_opt: OptionButton
var _cover_check: CheckBox
var _name_edit: LineEdit
var _saved_list: ItemList
var _status: Label
var _zones: Array[Dictionary] = []
var _saved: Array[ModelVariant] = []
var _silent := false   # идёт программное заполнение элементов, их обработчики молчат
var _mode := MODE_ZONES
var _mode_zones_btn: Button
var _mode_brush_btn: Button
var _zone_cap: Label
var _zone_row: HBoxContainer
var _brush_box: VBoxContainer
var _brush_note: Label
var _tool := "brush"
var _tool_buttons := {}
var _tool_params := {}          # id инструмента -> {size, hardness, flow, ...}: правки ползунков помнятся по инструментам
var _size_slider: HSlider
var _flow_slider: HSlider
var _hard_slider: HSlider
var _undo_btn: Button
var _redo_btn: Button
var _scatter_slider: HSlider
var _spacing_slider: HSlider
var _stroke_active := false
var _last_pos := Vector2.ZERO
var _carry_px := 0.0              # сколько пикселей пройдено после последнего штампа
var _travel_px := 0.0             # длина мазка в пикселях (запас краски сухой кисти)
var _stroke_prev := Vector3.ZERO  # предыдущая точка мазка на модели
var _stroke_prev_ok := false
var _stroke_tan := Vector3.ZERO   # последнее направление мазка в касательной плоскости
var _rng := RandomNumberGenerator.new()
var _synced_engine: PaintEngine   # движок и исполнение, с которыми слой кисти уже согласован (см. _enter_brush)
var _synced_variant: ModelVariant


func _init() -> void:
	id = &"paint"
	title = "Покраска"


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var card := VBoxContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_constant_override("separation", 6)
	scroll.add_child(card)

	var head := Label.new()
	head.text = "Покраска"
	head.add_theme_font_size_override("font_size", 18)
	card.add_child(head)
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card.add_child(_note)

	_controls = VBoxContainer.new()
	_controls.add_theme_constant_override("separation", 6)
	card.add_child(_controls)

	var mode_row := HBoxContainer.new()
	_controls.add_child(mode_row)
	var mode_group := ButtonGroup.new()
	_mode_zones_btn = Button.new()
	_mode_zones_btn.text = "Заливка зон"
	_mode_zones_btn.toggle_mode = true
	_mode_zones_btn.button_group = mode_group
	_mode_zones_btn.button_pressed = true
	_mode_zones_btn.pressed.connect(_set_mode.bind(MODE_ZONES))
	mode_row.add_child(_mode_zones_btn)
	_mode_brush_btn = Button.new()
	_mode_brush_btn.text = "Кисть"
	_mode_brush_btn.toggle_mode = true
	_mode_brush_btn.button_group = mode_group
	_mode_brush_btn.pressed.connect(_set_mode.bind(MODE_BRUSH))
	mode_row.add_child(_mode_brush_btn)

	_zone_cap = _caption("Зона")
	_controls.add_child(_zone_cap)
	_zone_opt = OptionButton.new()
	_zone_opt.item_selected.connect(func(_i: int) -> void: _sync_controls())
	_controls.add_child(_zone_opt)

	_controls.add_child(_caption("Цвет"))
	_color_btn = ColorPickerButton.new()
	_color_btn.edit_alpha = false
	_color_btn.custom_minimum_size = Vector2(0, 28)
	_color_btn.color = Color.from_string(PALETTE[3][1], Color.RED)
	_color_btn.color_changed.connect(func(_c: Color) -> void: _apply_zone())
	_controls.add_child(_color_btn)
	var grid := GridContainer.new()
	grid.columns = 6
	for p in PALETTE:
		var b := Button.new()
		b.custom_minimum_size = Vector2(32, 28)
		b.tooltip_text = p[0]
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color.from_string(p[1], Color.WHITE)
		sb.set_corner_radius_all(3)
		for state in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(state, sb)
		b.pressed.connect(_pick_palette.bind(p[1]))
		grid.add_child(b)
	_controls.add_child(grid)

	_finish_row = HBoxContainer.new()
	_controls.add_child(_finish_row)
	_finish_opt = OptionButton.new()
	_finish_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for key in PaintData.FINISH_ORDER:
		_finish_opt.add_item(str(PaintData.FINISHES[key]["name"]))
		_finish_opt.set_item_metadata(_finish_opt.item_count - 1, key)
	_finish_opt.item_selected.connect(func(_i: int) -> void: _apply_zone(false))
	_finish_row.add_child(_finish_opt)
	_cover_check = CheckBox.new()
	_cover_check.text = "Кроющая"
	_cover_check.button_pressed = true
	_cover_check.tooltip_text = "Кроющая краска закрывает рисунок модели. Без галочки цвет накладывается на рисунок (лессировка)."
	_cover_check.toggled.connect(func(_on: bool) -> void: _apply_zone(false))
	_finish_row.add_child(_cover_check)

	var row := HBoxContainer.new()
	_zone_row = row
	_controls.add_child(row)
	var reset_zone := Button.new()
	reset_zone.text = "Сбросить зону"
	reset_zone.pressed.connect(_on_reset_zone)
	row.add_child(reset_zone)
	var reset_all := Button.new()
	reset_all.text = "Сбросить всё"
	reset_all.pressed.connect(_on_reset_all)
	row.add_child(reset_all)

	_build_brush_box()

	_controls.add_child(HSeparator.new())
	_controls.add_child(_caption("Исполнения"))
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Название исполнения"
	_controls.add_child(_name_edit)
	var row2 := HBoxContainer.new()
	_controls.add_child(row2)
	var save := Button.new()
	save.text = "Сохранить"
	save.pressed.connect(_on_save.bind(false))
	row2.add_child(save)
	var save_new := Button.new()
	save_new.text = "Как новое"
	save_new.pressed.connect(_on_save.bind(true))
	row2.add_child(save_new)
	_saved_list = ItemList.new()
	_saved_list.custom_minimum_size = Vector2(0, 110)
	_saved_list.item_activated.connect(func(_i: int) -> void: _on_load())
	_controls.add_child(_saved_list)
	var row3 := HBoxContainer.new()
	_controls.add_child(row3)
	var load_btn := Button.new()
	load_btn.text = "Загрузить"
	load_btn.pressed.connect(_on_load)
	row3.add_child(load_btn)
	var del_btn := Button.new()
	del_btn.text = "Удалить"
	del_btn.pressed.connect(_on_delete)
	row3.add_child(del_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(1, 1, 1, 0.6)
	add_child(_status)


func enter() -> void:
	_refresh()


func on_loading(_setting: EntitySetting) -> void:
	_status.text = ""


func on_subject(_setting: EntitySetting, _info: Dictionary, _ms: int) -> void:
	_refresh()


# ==========================================
# СОСТОЯНИЕ
# ==========================================

func _paint_level() -> int:
	return screen.rules.level(LibraryRules.K_PAINT)


func _refresh() -> void:
	var meshes: Array = screen.body_meshes()
	var level := _paint_level()
	var locked: bool = screen.is_current_locked()
	var usable := level > 0 and not locked and not meshes.is_empty()
	_controls.visible = usable
	if level == 0:
		_note.text = "Покраска отключена правилами (%s)." % screen.rules.label()
	elif locked:
		_note.text = "Модель закрыта: красить можно только открытые модели."
	elif meshes.is_empty():
		_note.text = "У модели нет мешей для покраски."
	else:
		_note.text = "Выберите зону и цвет: покраска применяется сразу. Несохранённые правки пропадут при выборе другой модели."
	if not usable:
		return
	# Новая модель: движок кисти освобождён экраном, режим «Кисть» сбрасывается на «Заливку зон»
	if _mode == MODE_BRUSH and (screen.paint_engine == null or not screen.paint_engine.is_built):
		_mode = MODE_ZONES
		_mode_zones_btn.button_pressed = true
	var can_brush := level >= 2 and not PaintEngine.candidates(meshes).is_empty()
	_mode_brush_btn.disabled = not can_brush
	if level < 2:
		_mode_brush_btn.tooltip_text = "Кисть доступна с уровня 2 (правила)"
	elif not can_brush:
		_mode_brush_btn.tooltip_text = "У модели нет мешей с UV2 (tests/uv2_audit.gd, tools/glb_preflight.py --brush): кисть недоступна, остаётся заливка зон"
	else:
		_mode_brush_btn.tooltip_text = "Рисовать кистью, аэрографом и ластиком по UV2 модели"
	_update_tool_levels(level)
	_apply_mode_visibility()
	_build_zone_list()
	_sync_controls()
	_refresh_saved()


func _build_zone_list() -> void:
	var keep := _selected_zone_id()
	var key: StringName = screen.current_setting.get_key() if screen.current_setting != null else &""
	_zones = PaintZones.list(screen.body_meshes(), ModelInfo.find(key))
	_silent = true
	_zone_opt.clear()
	var painted := PaintData.zones(screen.variant.paint)
	var select := 0
	for i in _zones.size():
		var z := _zones[i]
		var mark := "  ●" if painted.has(z["id"]) else ""
		_zone_opt.add_item(str(z["title"]) + mark)
		if z["id"] == keep:
			select = i
	_zone_opt.select(select)
	_silent = false


func _selected_zone_id() -> String:
	var i := _zone_opt.selected if _zone_opt != null else -1
	if i < 0 or i >= _zones.size():
		return PaintData.ALL
	return str(_zones[i]["id"])


## Элементы показывают состояние выбранной зоны из исполнения
func _sync_controls() -> void:
	if _silent:
		return
	_silent = true
	var spec := PaintData.zone_spec(screen.variant.paint, _selected_zone_id())
	if not spec.is_empty():
		_color_btn.color = Color.from_string(str(spec["color"]), _color_btn.color)
		_cover_check.button_pressed = bool(spec["cover"])
		var idx := PaintData.FINISH_ORDER.find(str(spec["finish"]))
		_finish_opt.select(maxi(idx, 0))
	_silent = false


## Записать в зону то, что выбрано в элементах, и применить. color_changed: создаёт зону.
## Отделка и «кроющая» меняют только уже окрашенную зону (чтобы не красить зону случайно)
func _apply_zone(create := true) -> void:
	if _silent or _mode != MODE_ZONES:
		return
	var zone := _selected_zone_id()
	if not create and PaintData.zone_spec(screen.variant.paint, zone).is_empty():
		return
	var finish := str(_finish_opt.get_item_metadata(_finish_opt.selected))
	if _paint_level() < 2:
		finish = "keep"
	var cover := _cover_check.button_pressed if _paint_level() >= 2 else true
	PaintData.set_zone(screen.variant.paint, zone, _color_btn.color, finish, cover)
	screen.apply_variant()
	_mark_painted()


func _pick_palette(hex: String) -> void:
	_color_btn.color = Color.from_string(hex, _color_btn.color)
	_apply_zone()


func _mark_painted() -> void:
	var painted := PaintData.zones(screen.variant.paint)
	for i in _zones.size():
		var z := _zones[i]
		_zone_opt.set_item_text(i, str(z["title"]) + ("  ●" if painted.has(z["id"]) else ""))


func _on_reset_zone() -> void:
	PaintData.clear_zone(screen.variant.paint, _selected_zone_id())
	screen.apply_variant()
	_mark_painted()


func _on_reset_all() -> void:
	PaintData.clear_all(screen.variant.paint)
	screen.apply_variant()
	_mark_painted()


# ==========================================
# ИСПОЛНЕНИЯ
# ==========================================

func _refresh_saved() -> void:
	_saved_list.clear()
	if screen.current_setting == null:
		return
	_saved = VariantIO.list_variants(VariantIO.DEFAULT_DIR, String(screen.current_setting.get_key()))
	for v in _saved:
		_saved_list.add_item(v.name if v.name != "" else v.id)


func _on_save(as_new: bool) -> void:
	var v: ModelVariant = screen.variant
	var old_id := v.id
	if as_new or not ModelVariant.is_valid_id(v.id):
		v.id = ModelVariant.make_id()
	var typed := _name_edit.text.strip_edges()
	if typed != "":
		v.name = typed
	elif v.name == "":
		v.name = "Исполнение %d" % (_saved.size() + 1)
	_name_edit.text = v.name

	# Слой кисти: живой слой движка, а без движка прежние файлы слоёв исполнения (при «Как новое» копируются)
	var files := {}
	var eng: PaintEngine = screen.paint_engine
	if eng != null and eng.is_built:
		await eng.wait_idle()
		PaintData.remove_texture_layer(v.paint, PaintData.TEXTURE_LAYER_ID)
		if not eng.is_empty():
			var file := PaintData.TEXTURE_LAYER_ID + ".png"
			files[file] = eng.to_png()
			PaintData.set_texture_layer(v.paint, PaintData.TEXTURE_LAYER_ID, str(eng.target.name), eng.res, file, PackedByteArray(), eng.mesh_names())
	else:
		for layer in PaintData.texture_layers(v.paint):
			var f := str(layer.get("file", ""))
			if f != "" and ModelVariant.is_valid_id(old_id):
				var bytes := VariantIO.load_layer_png(old_id, f)
				if not bytes.is_empty():
					files[f] = bytes
	var err := VariantIO.save_layers(v.id, files)
	if err == OK:
		err = VariantIO.save_variant(v)
	if err != OK:
		_status.text = "Не удалось сохранить исполнение (код %d)." % err
		return
	if not screen.profile.variants.has(v.id):
		screen.profile.variants.append(v.id)
		VariantIO.save_profile(screen.profile)
	_status.text = "Сохранено: %s%s." % [v.name, " (со слоем кисти)" if not files.is_empty() else ""]
	_refresh_saved()


func _on_load() -> void:
	var sel := _saved_list.get_selected_items()
	if sel.is_empty() or sel[0] >= _saved.size():
		return
	var loaded := _saved[sel[0]].duplicate_variant()
	loaded.base = String(screen.current_setting.get_key())
	screen.variant = loaded
	_name_edit.text = loaded.name
	_build_zone_list()
	_sync_controls()
	await _sync_engine_from_variant()
	_status.text = "Загружено: %s." % loaded.name


## Слой кисти исполнения в Library: есть движок (режим «Кисть» уже включали) загружает в него PNG или очищает слой;
## движка нет: слой показывается статичной накладкой из файла, движок подхватит его при входе в «Кисть»
func _sync_engine_from_variant() -> void:
	var v: ModelVariant = screen.variant
	var layers := PaintData.texture_layers(v.paint)
	var eng: PaintEngine = screen.paint_engine
	if eng != null and eng.is_built:
		_synced_engine = eng
		_synced_variant = v
		var bytes := PackedByteArray()
		if not layers.is_empty() and layers[0].has("file"):
			bytes = VariantIO.load_layer_png(v.id, str(layers[0]["file"]))
		if bytes.is_empty():
			await eng.wait_idle()
			if not eng.is_empty():
				eng.clear()
		else:
			await eng.load_png(bytes)
		screen.apply_variant()
	else:
		screen.show_variant_layers()


func _on_delete() -> void:
	var sel := _saved_list.get_selected_items()
	if sel.is_empty() or sel[0] >= _saved.size():
		return
	var v := _saved[sel[0]]
	VariantIO.delete_variant(v.id)
	screen.profile.variants.erase(v.id)
	VariantIO.save_profile(screen.profile)
	_status.text = "Удалено: %s." % (v.name if v.name != "" else v.id)
	_refresh_saved()


func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.modulate = Color(1, 1, 1, 0.7)
	return l


# ==========================================
# РЕЖИМ «КИСТЬ» (C2.1)
# ==========================================

func _build_brush_box() -> void:
	for id in PaintBrushes.ORDER:
		_tool_params[id] = PaintBrushes.preset(id)
	_brush_box = VBoxContainer.new()
	_brush_box.add_theme_constant_override("separation", 6)
	_brush_box.visible = false
	_controls.add_child(_brush_box)

	_brush_note = Label.new()
	_brush_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_brush_box.add_child(_brush_note)

	var tool_row := HFlowContainer.new()
	tool_row.add_theme_constant_override("h_separation", 4)
	tool_row.add_theme_constant_override("v_separation", 4)
	_brush_box.add_child(tool_row)
	var group := ButtonGroup.new()
	for id in PaintBrushes.ORDER:
		var b := Button.new()
		b.text = str(PaintBrushes.PRESETS[id]["name"])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = id == _tool
		b.pressed.connect(_select_tool.bind(id))
		tool_row.add_child(b)
		_tool_buttons[id] = b

	# минимумы в три раза меньше прежних (размер 1 -> 0.33, поток 5 -> 1.67); у жёсткости минимум 0 и так
	_size_slider = _add_slider("Размер, %", 0.33, 30.0, 0.01, "size")
	_flow_slider = _add_slider("Поток, %", 1.67, 100.0, 0.01, "flow")
	_hard_slider = _add_slider("Жёсткость, %", 0.0, 95.0, 1.0, "hardness")
	_scatter_slider = _add_slider("Разброс, %", 0.0, 200.0, 1.0, "scatter")
	_spacing_slider = _add_slider("Шаг, px", 2.0, 60.0, 1.0, "spacing", 1.0)

	var row := HBoxContainer.new()
	_brush_box.add_child(row)
	_undo_btn = Button.new()
	_undo_btn.text = "Отменить"
	_undo_btn.tooltip_text = "Ctrl+Z"
	_undo_btn.pressed.connect(_on_undo)
	row.add_child(_undo_btn)
	_redo_btn = Button.new()
	_redo_btn.text = "Повторить"
	_redo_btn.tooltip_text = "Ctrl+Y"
	_redo_btn.pressed.connect(_on_redo)
	row.add_child(_redo_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Очистить слой"
	clear_btn.pressed.connect(_on_clear_layer)
	row.add_child(clear_btn)
	_sync_tool_sliders()


## Ползунок параметра инструмента. key: size, flow, hardness, scatter или spacing; value_scale: сколько единиц ползунка
## в единице параметра (проценты: 100, пиксели: 1)
func _add_slider(caption: String, lo: float, hi: float, step: float, key: String, value_scale := 100.0) -> HSlider:
	var row := HBoxContainer.new()
	_brush_box.add_child(row)
	var l := Label.new()
	l.text = caption
	l.custom_minimum_size = Vector2(100, 0)
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value_changed.connect(func(v: float) -> void:
		if not _silent:
			_tool_params[_tool][key] = v / value_scale)
	row.add_child(sl)
	return sl


func _sync_tool_sliders() -> void:
	var p: Dictionary = _tool_params[_tool]
	_silent = true
	_size_slider.value = float(p["size"]) * 100.0
	_flow_slider.value = float(p["flow"]) * 100.0
	_hard_slider.value = float(p["hardness"]) * 100.0
	_scatter_slider.value = float(p["scatter"]) * 100.0
	_spacing_slider.value = float(p["spacing"])
	_silent = false


## Инструменты, которым не хватает уровня правил, недоступны (серые, подсказка с нужным уровнем)
func _update_tool_levels(level: int) -> void:
	for id in PaintBrushes.ORDER:
		var need := int(PaintBrushes.PRESETS[id].get("level", PaintBrushes.DEFAULTS["level"]))
		var b: Button = _tool_buttons[id]
		b.disabled = level < need
		b.tooltip_text = "Нужен уровень покраски %d (правила: «Реалистичная»)" % need if level < need else ""
	if int(PaintBrushes.PRESETS[_tool].get("level", PaintBrushes.DEFAULTS["level"])) > level:
		_tool_buttons["brush"].button_pressed = true
		_select_tool("brush")


func _select_tool(id: String) -> void:
	_tool = id
	_sync_tool_sliders()


func _set_mode(m: int) -> void:
	if m == _mode:
		return
	_mode = m
	_stroke_end()
	_apply_mode_visibility()
	if m == MODE_BRUSH:
		_enter_brush()


func _apply_mode_visibility() -> void:
	var zones := _mode == MODE_ZONES
	_zone_cap.visible = zones
	_zone_opt.visible = zones
	_zone_row.visible = zones
	_finish_row.visible = zones and _paint_level() >= 2
	_brush_box.visible = not zones


## Строит карту кисти (в потоке) и включает рисование. Если нельзя, возвращает «Заливку зон»
func _enter_brush() -> void:
	_brush_note.text = "Построение карты кисти..."
	var ok: bool = await screen.ensure_paint_engine()
	if _mode != MODE_BRUSH:
		return
	if ok:
		var eng: PaintEngine = screen.paint_engine
		var ms := int(eng.bake_info.get("ms", 0))
		var text := "Карта кисти готова (%d мс, мешей: %d). ЛКМ рисует, ПКМ вращает, колесо зум. Мазки сохраняются вместе с исполнением." % [ms, eng.meshes.size()]
		if not eng.skipped.is_empty():
			text += "\nНе красятся (UV2 перекрывает другие меши): %s. Blender: «UV2: общий атлас»." % ", ".join(eng.skipped_names())
		_brush_note.text = text
		# Слой уже согласован с этим исполнением и движком (вышли в «Заливку зон» и вернулись): живые мазки,
		# ещё не сохранённые в файл, не трогаем. Иначе загрузить слой исполнения (или очистить, если его нет)
		if screen.paint_engine != _synced_engine or screen.variant != _synced_variant:
			await _sync_engine_from_variant()
	else:
		_brush_note.text = "Кисть недоступна для этой модели."
		_mode_zones_btn.button_pressed = true
		_set_mode(MODE_ZONES)


func exit() -> void:
	_stroke_end()


func view_input(event: InputEvent) -> bool:
	if _mode != MODE_BRUSH or screen.paint_engine == null or not screen.paint_engine.is_built:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_stroke_begin(mb.position)
			else:
				_stroke_end()
			return true
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			# вид вращается левой кнопкой: правую отдаём ему как левую
			var e := mb.duplicate() as InputEventMouseButton
			e.button_index = MOUSE_BUTTON_LEFT
			screen.world.handle_gui_input(e)
			return true
	elif event is InputEventMouseMotion and _stroke_active:
		_stroke_move((event as InputEventMouseMotion).position)
	return false


func handle_key(event: InputEventKey) -> bool:
	if _mode != MODE_BRUSH or not event.ctrl_pressed:
		return false
	if event.keycode == KEY_Z and not event.shift_pressed:
		_on_undo()
		return true
	if event.keycode == KEY_Y or (event.keycode == KEY_Z and event.shift_pressed):
		_on_redo()
		return true
	return false


func _process(_delta: float) -> void:
	if _stroke_active and bool(_tool_params[_tool]["accumulate"]):
		_stamp_at(_last_pos)
	if _undo_btn != null and _brush_box.visible and screen != null and screen.paint_engine != null:
		_undo_btn.disabled = not screen.paint_engine.can_undo()
		_redo_btn.disabled = not screen.paint_engine.can_redo()


func _stroke_begin(pos: Vector2) -> void:
	_stroke_active = true
	_last_pos = pos
	_carry_px = 0.0
	_travel_px = 0.0
	_stroke_prev_ok = false
	_stroke_tan = Vector3.ZERO
	_rng.randomize()
	screen.paint_engine.begin_stroke()
	_stamp_at(pos)


## Штампы вдоль отрезка мыши с шагом spacing инструмента (остаток шага переносится на следующее движение)
func _stroke_move(pos: Vector2) -> void:
	var dist := pos.distance_to(_last_pos)
	if dist <= 0.0:
		return
	var spacing := maxf(float(_tool_params[_tool]["spacing"]), 1.0)
	var d := spacing - _carry_px
	var count := 0
	while d <= dist and count < STROKE_MAX_STEPS:
		_stamp_at(_last_pos.lerp(pos, d / dist), spacing)
		d += spacing
		count += 1
	_carry_px = dist - (d - spacing)
	_last_pos = pos


func _stroke_end() -> void:
	if not _stroke_active:
		return
	_stroke_active = false
	if screen != null and screen.paint_engine != null:
		screen.paint_engine.end_stroke()


## Один штамп в точке экрана. step_px: сколько пикселей мазка пройдено с прошлого штампа (запас краски сухой кисти)
func _stamp_at(pos: Vector2, step_px := 0.0) -> void:
	var eng: PaintEngine = screen.paint_engine
	if eng == null or not eng.is_built:
		return
	var hit := eng.raycast(screen.world.camera, pos)
	if hit.is_empty():
		return
	_travel_px += step_px
	var p: Dictionary = _tool_params[_tool]
	var n: Vector3 = hit["normal"]
	var at: Vector3 = hit["position"]
	var jit := float(p["jitter"])
	var radius := eng.radius_for(float(p["size"])) * (1.0 + _rng.randf_range(-1.0, 1.0) * jit * 0.5)
	# направление конца: по мазку (смещение на модели), случайное или по оси Y; без движения прежнее
	var move := at - _stroke_prev if _stroke_prev_ok else Vector3.ZERO
	var base := PaintBrushes.tangent(n, str(p["rotate"]), move, _rng, 0.0, _stroke_tan)
	if str(p["rotate"]) == "stroke" and move.length() > 0.00001:
		_stroke_tan = base
	_stroke_prev = at
	_stroke_prev_ok = true
	var tan_dir := PaintBrushes.jittered(n, base, jit, _rng)
	var center := at + PaintBrushes.scatter_offset(n, tan_dir, radius, float(p["scatter"]), _rng)
	var opts := PaintBrushes.stamp_opts(p, tan_dir, PaintBrushes.load_left(p, _travel_px))
	eng.stamp(center, n, radius, _color_btn.color, float(p["flow"]), float(p["hardness"]), bool(p["erase"]), opts)


func _on_undo() -> void:
	if screen.paint_engine != null:
		screen.paint_engine.undo()


func _on_redo() -> void:
	if screen.paint_engine != null:
		screen.paint_engine.redo()


func _on_clear_layer() -> void:
	if screen.paint_engine != null:
		screen.paint_engine.clear()
