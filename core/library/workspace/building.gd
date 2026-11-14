extends "res://core/library/workspace/workspace.gd"

# XX claude-library L8 (новый файл)
########################
## Здания: правка здания из генератора, сохранение, «В игру» (ATTN_22 §22.7.6, шаг L8)
########################
## Работает с объектом building_gen (BuildingGenSetting.OBJECT_KEY). При входе в область он выбирается в каталоге сам.
## Каждое изменение элемента пересобирает здание на месте (C_BuildingGen.set_spec: меш, коллизия, свет); несколько
## изменений за кадр сливаются в одну пересборку (_dirty, _process). Камера не прыгает; «Вписать» замеряет здание заново.
## Уровни gen.level (§22.4): 0 только готовые здания и масштаб; 1 модули (размеры в целых ю, этажи, крыша, стиль,
## вариант по сиду, сохранение); 2 полная правка (шаг 0.1, высота этажа, уклон, свес, плотность окон, стена двери).
## Здания игрока лежат в user://library/buildings/ (BuildingStore). «В игру» кладёт BuildingSpec в исполнение
## (extend_variant): призрак и здание в макете строятся по нему, макет файла здания не требует.
## Несохранённые правки теряются при смене вкладки или модели (как в «Покраске»). Перетягивание граней контура мышью
## в 3D не делалось: контур правят ползунки (§22.7.6, не вошло в v1).

const KEY := BuildingGenSetting.OBJECT_KEY
const DECIMALS_STEP_COARSE := 1.0
const DECIMALS_STEP_FINE := 0.1

## Готовые здания (все уровни правил)
const PRESETS := [
	{"name": "Жилой дом", "spec": {"width": 10.0, "depth": 7.0, "floors": 2, "style": "brick", "seed": 1}},
	{"name": "Угловой дом", "spec": {"shape": "l", "width": 14.0, "depth": 10.0, "notch_w": 5.0, "notch_d": 4.0, "floors": 2, "style": "plaster", "seed": 11}},
	{"name": "Многоэтажка", "spec": {"width": 12.0, "depth": 7.0, "floors": 4, "roof": "flat", "style": "stone", "seed": 5}},
	{"name": "Домик", "spec": {"width": 6.0, "depth": 5.0, "floors": 1, "pitch": 0.8, "overhang": 0.6, "style": "plaster", "seed": 77}},
]

var _spec: BuildingSpec = BuildingSpec.new().sanitize()
var _gen: C_BuildingGen
## Игрок уже правил здание в этой области: при перезагрузке объекта (смена правил) оно применяется заново
var _have_spec := false
var _dirty := false
var _silent := false
var _loaded_id := ""
var _saved: Array[Dictionary] = []

var _note: Label
var _open_btn: Button
var _body: VBoxContainer
var _level_note: Label
var _edit_box: VBoxContainer
var _free_box: VBoxContainer
var _save_box: VBoxContainer
var _shape_opt: OptionButton
var _w: HSlider
var _d: HSlider
var _nw: HSlider
var _nd: HSlider
var _floors: HSlider
var _floor_h: HSlider
var _pitch: HSlider
var _overhang: HSlider
var _density: HSlider
var _roof_opt: OptionButton
var _style_opt: OptionButton
var _door_opt: OptionButton
var _seed_spin: SpinBox
var _info: Label
var _name_edit: LineEdit
var _saved_list: ItemList
var _status: Label


func _init() -> void:
	id = &"building"
	title = "Здания"


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var card := VBoxContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_constant_override("separation", 6)
	scroll.add_child(card)

	card.add_child(_caption("Здания", 18))
	_note = _muted_label(card)
	_open_btn = Button.new()
	_open_btn.text = "Открыть генератор"
	_open_btn.pressed.connect(_open_generator)
	card.add_child(_open_btn)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	card.add_child(_body)
	_level_note = _muted_label(_body)

	_body.add_child(_caption("Готовые"))
	var flow := HFlowContainer.new()
	_body.add_child(flow)
	for i in PRESETS.size():
		var b := Button.new()
		b.text = str(PRESETS[i]["name"])
		b.pressed.connect(_on_preset.bind(i))
		flow.add_child(b)

	_edit_box = VBoxContainer.new()
	_body.add_child(_edit_box)
	_edit_box.add_child(HSeparator.new())
	_edit_box.add_child(_caption("Форма"))
	_shape_opt = OptionButton.new()
	_shape_opt.add_item("Прямоугольник")
	_shape_opt.add_item("Г-образный")
	_shape_opt.item_selected.connect(func(_i: int) -> void: _on_edit())
	_edit_box.add_child(_shape_opt)
	_w = _slider(_edit_box, "Ширина", BuildingSpec.SIZE_MIN, BuildingSpec.SIZE_MAX, 1.0, "Размер вдоль X, ю (около м прототипа)")
	_d = _slider(_edit_box, "Глубина", BuildingSpec.SIZE_MIN, BuildingSpec.SIZE_MAX, 1.0, "Размер вдоль Z, ю")
	_nw = _slider(_edit_box, "Вырез по X", BuildingSpec.NOTCH_MIN, 12.0, 0.5, "Ширина выреза в углу Г-образного здания")
	_nd = _slider(_edit_box, "Вырез по Z", BuildingSpec.NOTCH_MIN, 12.0, 0.5, "Глубина выреза в углу Г-образного здания")
	_floors = _slider(_edit_box, "Этажи", BuildingSpec.FLOORS_MIN, BuildingSpec.FLOORS_MAX, 1.0)
	_edit_box.add_child(_caption("Крыша и стиль"))
	_roof_opt = OptionButton.new()
	_roof_opt.add_item("Двускатная")
	_roof_opt.add_item("Плоская")
	_roof_opt.item_selected.connect(func(_i: int) -> void: _on_edit())
	_edit_box.add_child(_roof_opt)
	_style_opt = OptionButton.new()
	for sid in BuildingStyles.ids():
		_style_opt.add_item(BuildingStyles.title(sid))
		_style_opt.set_item_metadata(_style_opt.item_count - 1, sid)
	_style_opt.item_selected.connect(func(_i: int) -> void: _on_edit())
	_edit_box.add_child(_style_opt)
	var seed_row := HBoxContainer.new()
	_edit_box.add_child(seed_row)
	var seed_cap := Label.new()
	seed_cap.text = "Сид"
	seed_cap.custom_minimum_size = Vector2(110, 0)
	seed_row.add_child(seed_cap)
	_seed_spin = SpinBox.new()
	_seed_spin.min_value = 0
	_seed_spin.max_value = BuildingSpec.SEED_MAX
	_seed_spin.step = 1
	_seed_spin.value_changed.connect(func(_v: float) -> void: _on_edit())
	seed_row.add_child(_seed_spin)
	var another := Button.new()
	another.text = "Другой вариант"
	another.tooltip_text = "Те же размеры и стиль, окна и дверь расставляются иначе"
	another.pressed.connect(_on_another)
	seed_row.add_child(another)

	_free_box = VBoxContainer.new()
	_body.add_child(_free_box)
	_free_box.add_child(_caption("Тонкие параметры"))
	_floor_h = _slider(_free_box, "Высота этажа", BuildingSpec.FLOOR_H_MIN, BuildingSpec.FLOOR_H_MAX, 0.1, "ю")
	_pitch = _slider(_free_box, "Уклон крыши", BuildingSpec.PITCH_MIN, BuildingSpec.PITCH_MAX, 0.01, "Подъём конька к половине пролёта")
	_overhang = _slider(_free_box, "Свес крыши", 0.0, BuildingSpec.OVERHANG_MAX, 0.05, "ю")
	_density = _slider(_free_box, "Плотность окон", BuildingSpec.DENSITY_MIN, BuildingSpec.DENSITY_MAX, 0.05, "1.0 это одно окно на 2.6 ю стены")
	_free_box.add_child(_caption("Дверь"))
	_door_opt = OptionButton.new()
	_door_opt.item_selected.connect(func(_i: int) -> void: _on_edit())
	_free_box.add_child(_door_opt)

	_info = _muted_label(_body)
	var fit_btn := Button.new()
	fit_btn.text = "Вписать"
	fit_btn.tooltip_text = "Замерить здание заново и вписать в кадр"
	fit_btn.pressed.connect(func() -> void: screen.world.remeasure(true))
	_body.add_child(fit_btn)

	_save_box = VBoxContainer.new()
	_body.add_child(_save_box)
	_save_box.add_child(HSeparator.new())
	_save_box.add_child(_caption("Мои здания"))
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Название здания"
	_save_box.add_child(_name_edit)
	var save_row := HBoxContainer.new()
	_save_box.add_child(save_row)
	var save := Button.new()
	save.text = "Сохранить здание"
	save.pressed.connect(_on_save.bind(false))
	save_row.add_child(save)
	var save_new := Button.new()
	save_new.text = "Как новое"
	save_new.pressed.connect(_on_save.bind(true))
	save_row.add_child(save_new)

	_body.add_child(_caption("Сохранённые здания"))
	_saved_list = ItemList.new()
	_saved_list.custom_minimum_size = Vector2(0, 110)
	_saved_list.item_activated.connect(func(_i: int) -> void: _on_load())
	_body.add_child(_saved_list)
	var list_row := HBoxContainer.new()
	_body.add_child(list_row)
	var load_btn := Button.new()
	load_btn.text = "Загрузить"
	load_btn.pressed.connect(_on_load)
	list_row.add_child(load_btn)
	var del_btn := Button.new()
	del_btn.text = "Удалить"
	del_btn.pressed.connect(_on_delete)
	list_row.add_child(del_btn)

	_status = _muted_label(card)
	_body.visible = false


func enter() -> void:
	_apply_level()
	_refresh_list()
	var cur: EntitySetting = screen.current_setting
	if cur == null or cur.get_key() != KEY:
		_open_generator()
	else:
		_adopt_subject()


func exit() -> void:
	_dirty = false


func on_loading(_setting: EntitySetting) -> void:
	_gen = null
	_dirty = false


func on_subject(_setting: EntitySetting, _info_dict: Dictionary, _ms: int) -> void:
	_adopt_subject()


## «В игру»: здание из генератора уходит в исполнение целиком
func extend_variant(variant: Dictionary) -> void:
	if _gen != null:
		variant["building"] = _spec.to_dict()


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		_apply()


# ==========================================
# ОБЪЕКТ И УРОВЕНЬ
# ==========================================

func _open_generator() -> void:
	var cat: Variant = screen.catalog
	if cat == null:
		return
	if not cat.select_key(KEY):
		cat.set_category(&"building")
		cat.select_key(KEY)


## Взять C_BuildingGen показанного объекта; нет генератора: подсказка и кнопка
func _adopt_subject() -> void:
	_gen = null
	var cur: EntitySetting = screen.current_setting
	var ent := screen.world.subject as Entity if screen.world != null else null
	if cur != null and cur.get_key() == KEY and ent != null and is_instance_valid(ent):
		_gen = ent.get_comp(C_BuildingGen) as C_BuildingGen
	_body.visible = _gen != null
	_open_btn.visible = _gen == null
	if _gen == null:
		_note.text = "Правка зданий работает с объектом «Генератор зданий». Выберите его в каталоге слева или нажмите кнопку."
		return
	_note.text = ""
	if _have_spec:
		_gen.set_spec(_spec)   # объект перезагрузился (например, сменились правила): вернуть здание игрока
	else:
		_spec = _gen.spec.duplicate_spec()
	_apply_level()
	_sync_ui()
	screen.world.remeasure(false)


func _gen_level() -> int:
	return clampi(screen.rules.level(LibraryRules.K_GEN), 0, 2)


func _apply_level() -> void:
	if _edit_box == null:
		return
	var lvl := _gen_level()
	_edit_box.visible = lvl >= 1
	_free_box.visible = lvl >= 2
	_save_box.visible = lvl >= 1
	var step := DECIMALS_STEP_COARSE if lvl < 2 else DECIMALS_STEP_FINE
	_w.step = step
	_d.step = step
	_level_note.text = ["Уровень правил: готовые здания и масштаб.",
		"Уровень правил: модули (размеры в целых ю, этажи, крыша, стиль).",
		"Уровень правил: полная правка."][lvl]


# ==========================================
# ЭЛЕМЕНТЫ
# ==========================================

func _caption(text: String, font_size := 0) -> Label:
	var l := Label.new()
	l.text = text
	if font_size > 0:
		l.add_theme_font_size_override("font_size", font_size)
	else:
		l.modulate = Color(1, 1, 1, 0.85)
	return l


func _muted_label(parent: Node) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.modulate = Color(1, 1, 1, 0.6)
	parent.add_child(l)
	return l


func _slider(parent: Node, caption: String, lo: float, hi: float, step: float, tip := "") -> HSlider:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var cap := Label.new()
	cap.text = caption
	cap.tooltip_text = tip
	cap.custom_minimum_size = Vector2(110, 0)
	row.add_child(cap)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = step
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(sl)
	var val := Label.new()
	val.custom_minimum_size = Vector2(46, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	sl.set_meta("row", row)
	sl.set_meta("val_label", val)
	sl.value_changed.connect(func(v: float) -> void:
		val.text = _fmt(v, sl.step)
		_on_edit())
	return sl


static func _fmt(v: float, step: float) -> String:
	if step >= 1.0:
		return str(int(roundf(v)))
	return String.num(v, 1 if step >= 0.1 else 2)


func _set_slider(sl: HSlider, v: float) -> void:
	sl.set_value_no_signal(v)
	sl.set_meta("shown", sl.value)   # ползунок округляет значение до шага: сверять с показанным, а не с _spec
	(sl.get_meta("val_label") as Label).text = _fmt(sl.value, sl.step)


## Игрок двигал этот ползунок (значение не равно показанному при последней синхронизации). Нетронутые ползунки
## не перезаписывают поля _spec: здание с шагом 0.1 не округляется, когда игрок трогает другой элемент
func _moved(sl: HSlider) -> bool:
	return not is_equal_approx(sl.value, float(sl.get_meta("shown", NAN)))


func _row_of(sl: HSlider) -> Control:
	return sl.get_meta("row") as Control


## Из элементов в _spec
func _on_edit() -> void:
	if _silent or _gen == null:
		return
	_spec.shape = BuildingSpec.Shape.L if _shape_opt.selected == 1 else BuildingSpec.Shape.RECT
	if _moved(_w):
		_spec.width = _w.value
	if _moved(_d):
		_spec.depth = _d.value
	if _moved(_nw):
		_spec.notch_w = _nw.value
	if _moved(_nd):
		_spec.notch_d = _nd.value
	if _moved(_floors):
		_spec.floors = int(_floors.value)
	_spec.roof = BuildingSpec.Roof.FLAT if _roof_opt.selected == 1 else BuildingSpec.Roof.GABLE
	_spec.style = StringName(_style_opt.get_item_metadata(maxi(_style_opt.selected, 0)))
	_spec.seed_id = int(_seed_spin.value)
	if _gen_level() >= 2:
		if _moved(_floor_h):
			_spec.floor_h = _floor_h.value
		if _moved(_pitch):
			_spec.pitch = _pitch.value
		if _moved(_overhang):
			_spec.overhang = _overhang.value
		if _moved(_density):
			_spec.density = _density.value
		_spec.door_wall = _door_opt.selected - 1
	_spec.sanitize()
	_dirty = true


## Из _spec в элементы (без сигналов)
func _sync_ui() -> void:
	if _gen == null or _shape_opt == null:
		return
	_silent = true
	var can_l := _spec.width >= BuildingSpec.L_MIN_SIZE and _spec.depth >= BuildingSpec.L_MIN_SIZE
	_shape_opt.set_item_disabled(1, not can_l)
	_shape_opt.select(1 if _spec.is_l() else 0)
	_set_slider(_w, _spec.width)
	_set_slider(_d, _spec.depth)
	_nw.min_value = BuildingSpec.NOTCH_MIN
	_nw.max_value = maxf(_spec.width - BuildingSpec.NOTCH_LEFT_MIN, BuildingSpec.NOTCH_MIN)
	_nd.min_value = BuildingSpec.NOTCH_MIN
	_nd.max_value = maxf(_spec.depth - BuildingSpec.NOTCH_LEFT_MIN, BuildingSpec.NOTCH_MIN)
	_set_slider(_nw, _spec.notch_w)
	_set_slider(_nd, _spec.notch_d)
	_row_of(_nw).visible = _spec.is_l()
	_row_of(_nd).visible = _spec.is_l()
	_set_slider(_floors, _spec.floors)
	_roof_opt.select(1 if _spec.roof == BuildingSpec.Roof.FLAT else 0)
	for i in _style_opt.item_count:
		if StringName(_style_opt.get_item_metadata(i)) == _spec.style:
			_style_opt.select(i)
	_seed_spin.set_value_no_signal(_spec.seed_id)
	_set_slider(_floor_h, _spec.floor_h)
	_set_slider(_pitch, _spec.pitch)
	_set_slider(_overhang, _spec.overhang)
	_set_slider(_density, _spec.density)
	_row_of(_pitch).visible = _spec.roof == BuildingSpec.Roof.GABLE
	_door_opt.clear()
	_door_opt.add_item("Авто (к −Z)")
	var edges := _gen.layout.edges.size()
	for i in edges:
		_door_opt.add_item("Стена %d" % (i + 1))
	_door_opt.select(clampi(_spec.door_wall + 1, 0, edges))
	_silent = false
	_update_info()


func _update_info() -> void:
	if _gen == null or _gen.layout == null:
		return
	var lay := _gen.layout
	var windows := 0
	for o in lay.openings:
		if o.kind != BuildingLayout.Kind.DOOR:
			windows += 1
	var k := ModelInfo.PROTOTYPE_M_PER_UNIT
	var h := lay.wall_h + lay.roof_h
	_info.text = "Габарит: %.1f x %.1f x %.1f ю (около %.0f x %.0f x %.0f м прототипа)\nЭтажей %d, окон %d, вершин %d, треугольников %d" % [
		_spec.width, _spec.depth, h, _spec.width * k, _spec.depth * k, h * k,
		_spec.floors, windows, int(_gen.stats["vertices"]), int(_gen.stats["triangles"])]


# ==========================================
# ПЕРЕСБОРКА
# ==========================================

func _apply() -> void:
	if _gen == null or not is_instance_valid(_gen):
		return
	_gen.set_spec(_spec)
	_spec = _gen.spec.duplicate_spec()
	_have_spec = true
	_sync_ui()
	screen.world.remeasure(false)
	# перестроенный меш получил новые материалы: покраска Library (заливка зон) накладывается заново
	if not PaintData.is_blank(screen.variant.paint):
		screen.apply_variant()


func _on_preset(i: int) -> void:
	if _gen == null:
		return
	_spec = BuildingSpec.from_dict(PRESETS[i]["spec"])
	_loaded_id = ""
	_name_edit.text = str(PRESETS[i]["name"])
	_apply()
	screen.world.remeasure(true)
	_status.text = "Готовое здание: %s." % PRESETS[i]["name"]


func _on_another() -> void:
	if _gen == null:
		return
	_spec = _spec.with_next_seed()
	_apply()
	_status.text = "Другой вариант: сид %d." % _spec.seed_id


# ==========================================
# ЗДАНИЯ ИГРОКА
# ==========================================

func _refresh_list() -> void:
	if _saved_list == null:
		return
	_saved = BuildingStore.list_all()
	_saved_list.clear()
	for e in _saved:
		var sp := e["spec"] as BuildingSpec
		_saved_list.add_item("%s (%s, %d эт.)" % [e["name"], "Г" if sp.is_l() else "прям.", sp.floors])
		if str(e["id"]) == _loaded_id:
			_saved_list.select(_saved_list.item_count - 1)


func _selected_entry() -> Dictionary:
	var sel := _saved_list.get_selected_items()
	if sel.is_empty() or sel[0] >= _saved.size():
		return {}
	return _saved[sel[0]]


func _on_save(as_new: bool) -> void:
	if _gen == null or _gen_level() < 1:
		return
	var entry_id := _loaded_id
	if as_new or entry_id == "":
		entry_id = BuildingStore.make_id()
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		nm = "Здание"
	var err := BuildingStore.save(entry_id, nm, _spec)
	if err != OK:
		_status.text = "Не удалось сохранить здание (код %d)." % err
		return
	_loaded_id = entry_id
	_refresh_list()
	_status.text = "Сохранено: %s. Оно в Build, «Мои здания»." % nm


func _on_load() -> void:
	var e := _selected_entry()
	if e.is_empty() or _gen == null:
		return
	_spec = (e["spec"] as BuildingSpec).duplicate_spec()
	_loaded_id = str(e["id"])
	_name_edit.text = str(e["name"])
	_apply()
	screen.world.remeasure(true)
	_status.text = "Загружено: %s." % e["name"]


func _on_delete() -> void:
	var e := _selected_entry()
	if e.is_empty():
		return
	var err := BuildingStore.delete(str(e["id"]))
	if err != OK:
		_status.text = "Не удалось удалить (код %d)." % err
		return
	if str(e["id"]) == _loaded_id:
		_loaded_id = ""
	_refresh_list()
	_status.text = "Удалено: %s. Поставленные здания остаются на макете." % e["name"]
