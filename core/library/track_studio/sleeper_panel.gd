extends VBoxContainer

########################
## Track Studio: вкладка «Шпала» (ATTN_20, шаг T3)
########################
## Генератор меша шпалы (дерево, бетон) и импорт меша из .glb/.gltf/.tscn с приведением к контракту
## (origin в центре площади опоры, низ на y = 0, длинная сторона по X). Логика в lib/sleeper_factory.gd.

const OUT_DIR := "res://data/tracks/meshes"
const PROFILES := [["Прямоугольное (фаски со всех рёбер)", "rect"], ["Трапеция (низ шире верха)", "trapezoid"]]
const LIVE_DELAY := 0.25

# Числовые параметры генератора: [ключ, название, мин, макс, шаг, подсказка]
const BODY_SPINS := [
	["length", "Длина (X, поперёк пути)", 0.5, 10.0, 0.01, ""],
	["height", "Высота корпуса", 0.02, 2.0, 0.005, ""],
	["width", "Ширина (Z, вдоль пути)", 0.02, 2.0, 0.005, ""],
	["chamfer", "Фаска", 0.0, 0.2, 0.005, "0 = без фасок, лишних рёбер нет"],
	["taper", "Трапеция: сужение верха", 0.0, 0.3, 0.005, "Только для сечения «Трапеция»"],
]
const PAD_SPINS := [
	["pad_x", "Центр от оси шпалы (X)", 0.0, 4.0, 0.005, "По умолчанию половина колеи стиля. Площадка и рельс независимы: рельс можно поставить и на корпус рядом с площадкой"],
	["pad_length", "Длина (X)", 0.02, 3.0, 0.01, ""],
	["pad_width", "Ширина (Z)", 0.0, 2.0, 0.005, "0 = на всю плоскую часть верха"],
	["pad_height", "Высота (Y)", 0.0, 0.3, 0.005, "Над верхом корпуса"],
]
const RELIEF_SPINS := [
	["top_dip", "Прогиб верха между площадками", 0.0, 0.2, 0.005, "0 = верх плоский, рёбра не создаются"],
	["relief_slope", "Длина скоса внутрь (X)", 0.005, 1.0, 0.005, "От края площадки в сторону прогиба"],
	["end_slope", "Скос к краю, высота", 0.0, 0.2, 0.005, "Верх заваливается от внешнего края площадки до конца шпалы на эту высоту. 0 = верх плоский, рёбра не создаются"],
]

var studio                      # track_studio.gd: get_style(), set_field(), say()

var _part_note: Label
var _profile_opt: OptionButton
var _spin := {}                 # ключ спецификации -> SpinBox
var _pads_chk: CheckBox
var _lifts_chk: CheckBox
var _pad_color: ColorPickerButton
var _uv_rot: CheckBox
var _live: CheckBox
var _live_active := false       # живое обновление включается после первой генерации
var _timer: Timer
var _gen_name: LineEdit
var _gen_mesh: ArrayMesh

var _src_edit: LineEdit
var _items_list: ItemList
var _items: Array[Dictionary] = []
var _scale: SpinBox
var _rot: SpinBox
var _auto: CheckBox
var _keep_mat: CheckBox
var _merge: CheckBox
var _imp_name: LineEdit
var _report: RichTextLabel
var _dialog: FileDialog
var _norm_mesh: ArrayMesh


func setup(studio_ref) -> void:
	studio = studio_ref
	_build()


func _build() -> void:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = LIVE_DELAY
	_timer.timeout.connect(func(): _on_generate(false))
	add_child(_timer)

	_part_note = Label.new()
	_part_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_part_note.modulate = Color(1.0, 0.85, 0.5)
	_part_note.visible = false
	v.add_child(_part_note)

	# --- Генератор ---
	_title(v, "Генератор: корпус")
	var rk := _row(v, "Сечение")
	_profile_opt = OptionButton.new()
	_profile_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for k in PROFILES:
		_profile_opt.add_item(k[0])
	_profile_opt.item_selected.connect(func(_i: int): _changed())
	rk.add_child(_profile_opt)
	for sp in BODY_SPINS:
		_spin_row(v, sp)

	_title(v, "Площадки под рельс")
	_pads_chk = _check(v, "Площадки включены (на любом сечении)", false)
	_pads_chk.toggled.connect(func(_on: bool): _changed())
	for sp in PAD_SPINS:
		_spin_row(v, sp)
	var rc := _row(v, "Цвет площадок")
	_pad_color = ColorPickerButton.new()
	_pad_color.custom_minimum_size = Vector2(80, 0)
	_pad_color.edit_alpha = false
	_pad_color.color = Color(0.30, 0.30, 0.33)
	_pad_color.tooltip_text = "Цвет хранится в вершинах меша: один материал и одна поверхность, на нагрузку не влияет. Умножается на текстуру материала шпалы."
	_pad_color.color_changed.connect(func(_c: Color): _changed())
	rc.add_child(_pad_color)
	_lifts_chk = _check(v, "Рельс стоит на площадке (поднимает рельс)", true)
	_lifts_chk.tooltip_text = "Выключено: площадки только деталь (костыль), рельс стоит на корпусе, высота постели = высота корпуса"
	_lifts_chk.toggled.connect(func(_on: bool): _changed())

	_title(v, "Рельеф")
	for sp in RELIEF_SPINS:
		_spin_row(v, sp)

	_title(v, "UV")
	_uv_rot = _check(v, "Повернуть UV на 90° (волокна поперёк)", false)
	_uv_rot.toggled.connect(func(_on: bool): _changed())
	var hint := Label.new()
	hint.text = "UV генератора в ю: в материале шпалы выберите проекцию «UV меша в ю». Материалу нужно «Цвет вершин» (в пресете шпалы включено)."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.6)
	v.add_child(hint)

	_live = _check(v, "Обновлять сразу после первой генерации", true)
	var rg := HBoxContainer.new()
	v.add_child(rg)
	_button(rg, "Сгенерировать в стиль", func(): _on_generate(true))
	_button(rg, "Убрать меш (BoxMesh)", func():
		_live_active = false
		studio.set_field("sleeper_mesh", null))
	var rn := _row(v, "Имя файла")
	_gen_name = LineEdit.new()
	_gen_name.text = "sleeper_01"
	_gen_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gen_name.tooltip_text = "res://data/tracks/meshes/<имя>.res"
	rn.add_child(_gen_name)
	_button(v, "Сохранить сгенерированный меш и назначить", _on_save_generated)

	v.add_child(HSeparator.new())

	# --- Импорт ---
	_title(v, "Импорт меша")
	var rs := _row(v, "Файл")
	_src_edit = LineEdit.new()
	_src_edit.editable = false
	_src_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rs.add_child(_src_edit)
	_button(rs, "Выбрать…", func(): _dialog.popup_centered(Vector2i(900, 600)))
	_items_list = ItemList.new()
	_items_list.select_mode = ItemList.SELECT_MULTI
	_items_list.custom_minimum_size = Vector2(0, 90)
	v.add_child(_items_list)

	var ro := _row(v, "Масштаб ×")
	_scale = _spin_plain(ro, 0.0001, 10000.0, 0.0001, 1.0)
	_scale.tooltip_text = "Умножает размеры меша. Из Blender в метрах: ориентир 1 ю около 1 м прототипа."
	var rr := _row(v, "Поворот Y, °")
	_rot = _spin_plain(rr, -360.0, 360.0, 90.0, 0.0)
	_auto = _check(v, "Длинную сторону на X автоматически", true)
	_keep_mat = _check(v, "Сохранить материалы меша", true)
	_merge = _check(v, "Слить поверхности в одну", false)
	var ri := _row(v, "Имя файла")
	_imp_name = LineEdit.new()
	_imp_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ri.add_child(_imp_name)
	var rb := HBoxContainer.new()
	v.add_child(rb)
	_button(rb, "Нормализовать в стиль", func(): _on_normalize(false))
	_button(rb, "Нормализовать и сохранить", func(): _on_normalize(true))
	_report = RichTextLabel.new()
	_report.bbcode_enabled = true
	_report.fit_content = true
	_report.scroll_active = false
	_report.custom_minimum_size = Vector2(0, 80)
	v.add_child(_report)

	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.use_native_dialog = false
	_dialog.title = "Меш шпалы"
	_dialog.add_filter("*.glb,*.gltf,*.tscn,*.res,*.tres", "Меши и сцены")
	_dialog.current_dir = "res://data/import"
	_dialog.file_selected.connect(_on_source_picked)
	add_child(_dialog)



func _title(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	parent.add_child(l)


func _row(parent: Control, text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	parent.add_child(h)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(170, 0)
	h.add_child(l)
	return h


func _spin_plain(parent: Control, lo: float, hi: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(s)
	return s


func _spin_row(parent: Control, sp: Array) -> void:
	var r := _row(parent, sp[1])
	r.tooltip_text = sp[5]
	var key: String = sp[0]
	var box := _spin_plain(r, sp[2], sp[3], sp[4], float(TrackSleeperFactory.GENERATED_DEFAULTS[key]))
	box.value_changed.connect(func(_v: float): _changed())
	_spin[key] = box


func _check(parent: Control, text: String, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	parent.add_child(c)
	return c


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# ==========================================
# Состояние
# ==========================================

## Студия вызывает при открытии стиля. Меш, собранный генератором, возвращает свои параметры (метаданные track_spec);
## иначе размеры берутся из sleeper_size, центр площадок из rail_x стиля
## Студия вызывает при смене флагов частей: подпись, если шпалы выключены в стиле
func update_parts() -> void:
	if _part_note == null or studio == null:
		return
	var note := TrackStyleValidator.part_note(studio.get_style(), "sleeper")
	_part_note.text = note
	_part_note.visible = not note.is_empty()


func refresh_from_style() -> void:
	update_parts()
	var style: TrackStyle = studio.get_style() if studio else null
	_live_active = false
	_gen_mesh = null
	if style == null or _spin.is_empty():
		return
	var spec := {}
	if style.sleeper_mesh and style.sleeper_mesh.has_meta("track_spec"):
		spec = style.sleeper_mesh.get_meta("track_spec")
		if style.sleeper_mesh is ArrayMesh:
			_gen_mesh = style.sleeper_mesh
	else:
		spec = TrackSleeperFactory.GENERATED_DEFAULTS.duplicate()
		spec["length"] = style.sleeper_size.x
		spec["height"] = style.sleeper_size.y
		spec["width"] = style.sleeper_size.z
		spec["pad_x"] = style.rail_x
	_set_ui(spec)


func _set_ui(spec: Dictionary) -> void:
	var d: Dictionary = TrackSleeperFactory.GENERATED_DEFAULTS.duplicate()
	d.merge(spec, true)
	for k in _spin:
		(_spin[k] as SpinBox).set_value_no_signal(float(d[k]))
	for i in PROFILES.size():
		if PROFILES[i][1] == d["profile"]:
			_profile_opt.select(i)
	_pads_chk.set_pressed_no_signal(bool(d["pads"]))
	_lifts_chk.set_pressed_no_signal(bool(d["pad_lifts_rail"]))
	_pad_color.color = d["pad_color"]
	_uv_rot.set_pressed_no_signal(bool(d["uv_rotate"]))


func _spec() -> Dictionary:
	var spec := {
		"profile": PROFILES[_profile_opt.selected][1],
		"pads": _pads_chk.button_pressed,
		"pad_lifts_rail": _lifts_chk.button_pressed,
		"pad_color": _pad_color.color,
		"uv_rotate": _uv_rot.button_pressed,
	}
	for k in _spin:
		spec[k] = (_spin[k] as SpinBox).value
	return spec


func _changed() -> void:
	if _live_active and _live.button_pressed:
		_timer.start()


# ==========================================
# Генератор
# ==========================================

func _on_generate(announce := true) -> void:
	if studio.get_style() == null:
		return
	_gen_mesh = TrackSleeperFactory.generate(_spec())
	_live_active = true
	studio.set_field("sleeper_mesh", _gen_mesh)
	if announce:
		var inf := TrackSleeperFactory.info(_gen_mesh)
		studio.say("Шпала сгенерирована: %d треугольников" % inf["triangles"])


func _on_save_generated() -> void:
	if _gen_mesh == null:
		studio.say("Сначала сгенерируйте меш", true)
		return
	_save(_gen_mesh, _gen_name.text.strip_edges())


func _save(mesh: ArrayMesh, nm: String) -> void:
	if not TrackStyleIO.is_valid_id(nm):
		studio.say("Имя файла: латиница в нижнем регистре, цифры, _", true)
		return
	var path := OUT_DIR.path_join(nm + ".res")
	var err := TrackSleeperFactory.save_mesh(mesh, path)
	if err != OK:
		studio.say("Не удалось записать %s (код %d)" % [path, err], true)
		return
	_live_active = false   # дальше правки не должны затирать записанный файл
	studio.set_field("sleeper_mesh", mesh)
	studio.say("Меш записан: %s" % path)


# ==========================================
# Импорт
# ==========================================

func _on_source_picked(path: String) -> void:
	_src_edit.text = path
	_items = TrackSleeperFactory.load_meshes(path)
	_items_list.clear()
	for it in _items:
		var inf := TrackSleeperFactory.info(it["mesh"])
		var s: Vector3 = inf["size"]
		_items_list.add_item("%s  (%.3f × %.3f × %.3f, %d тр.)" % [it["name"], s.x, s.y, s.z, inf["triangles"]])
	if _items.is_empty():
		_report.text = "[color=#ff7b7b]В файле нет мешей[/color]"
		return
	_items_list.select(0)
	_imp_name.text = _clean_name(path.get_file().get_basename())
	_report.text = "Найдено мешей: %d. Выберите нужные в списке (Ctrl или Shift для нескольких)." % _items.size()


func _clean_name(raw: String) -> String:
	var re := RegEx.new()
	re.compile("[^a-z0-9_]")
	var out := re.sub(raw.to_lower(), "_", true)
	if out.is_empty() or not (out[0] >= "a" and out[0] <= "z"):
		out = "sleeper_" + out
	return out


func _on_normalize(save: bool) -> void:
	if studio.get_style() == null:
		return
	var picked: Array = []
	for i in _items_list.get_selected_items():
		picked.append(_items[i])
	if picked.is_empty():
		studio.say("Выберите меш в списке импорта", true)
		return
	var res := TrackSleeperFactory.normalize(picked, {
		"scale": _scale.value, "rotate_y": _rot.value, "auto_orient": _auto.button_pressed,
		"keep_materials": _keep_mat.button_pressed, "merge": _merge.button_pressed})
	var mesh: ArrayMesh = res["mesh"]
	var rep: Dictionary = res["report"]
	if mesh.get_surface_count() == 0:
		_report.text = "[color=#ff7b7b]Нормализация не дала геометрии[/color]"
		return
	_norm_mesh = mesh
	_show_report(rep, mesh)
	if save:
		_save(mesh, _imp_name.text.strip_edges())
	else:
		studio.set_field("sleeper_mesh", mesh)


func _show_report(rep: Dictionary, mesh: ArrayMesh) -> void:
	var b: AABB = rep["before"]
	var a: AABB = rep["after"]
	var t := "[b]До:[/b] %.3f × %.3f × %.3f\n" % [b.size.x, b.size.y, b.size.z]
	t += "[b]После:[/b] %.3f × %.3f × %.3f, центр опоры (%.3f; %.3f), низ %.3f\n" % [
		a.size.x, a.size.y, a.size.z, a.get_center().x, a.get_center().z, a.position.y]
	t += "Поверхностей %d, треугольников %d\n" % [rep["surfaces"], rep["triangles"]]
	for n in rep["notes"]:
		t += "[color=#ffcf5c]%s[/color]\n" % n
	var has_mat := false
	for i in mesh.get_surface_count():
		if mesh.surface_get_material(i) != null:
			has_mat = true
	if has_mat:
		t += "Материалы меша сохранены. Чтобы они работали, очистите «Материал шпалы» стиля.\n"
	_report.text = t
