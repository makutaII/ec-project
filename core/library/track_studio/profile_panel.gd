extends VBoxContainer

########################
## Track Studio: вкладка «Профили» (ATTN_20, шаг T4)
########################
## Графический редактор профиля рельса и балласта (profile_editor.gd), пресеты и генераторы (lib/profile_tools.gd),
## числовые поля выбранной точки, текстовый ввод как запасной вариант.

const ProfileEditor := preload("res://core/library/track_studio/profile_editor.gd")

# Поля генератора: [ключ, название, мин, макс, шаг]
const VIGNOLE_SPINS := [
	["height", "Высота рельса", 0.05, 1.0, 0.005],
	["foot_width", "Ширина подошвы", 0.02, 1.0, 0.005],
	["foot_height", "Толщина края подошвы", 0.005, 0.2, 0.005],
	["web_width", "Толщина шейки", 0.005, 0.3, 0.005],
	["head_width", "Ширина головки", 0.02, 0.8, 0.005],
	["head_height", "Высота головки", 0.01, 0.5, 0.005],
]
const TRAPEZOID_SPINS := [
	["bottom_half", "Полуширина по низу", 0.1, 6.0, 0.01],
	["top_half", "Полуширина верха", 0.05, 6.0, 0.01],
	["height", "Высота", 0.02, 3.0, 0.005],
]

var studio                      # track_studio.gd: get_style(), set_field(), say()

var _editor: ProfileEditor
var _target_opt: OptionButton
var _preset_opt: OptionButton
var _mirror: CheckBox
var _snap_chk: CheckBox
var _snap_spin: SpinBox
var _dims_chk: CheckBox
var _undo_btn: Button
var _redo_btn: Button
var _px: SpinBox
var _py: SpinBox
var _pt_label: Label
var _status: Label
var _part_note: Label
var _rail_gen: VBoxContainer
var _ballast_gen: VBoxContainer
var _spins := {}                # "rail:height" -> SpinBox
var _text_chk: CheckBox
var _text_box: VBoxContainer
var _text_edit: TextEdit
var _text_status: Label
var _syncing := false


func setup(studio_ref) -> void:
	studio = studio_ref
	_build()
	visibility_changed.connect(_on_visibility)


func _key() -> String:
	return "rail_profile" if _target_opt.selected == 0 else "ballast_profile"


func _kind() -> String:
	return "rail" if _target_opt.selected == 0 else "ballast"


func _build() -> void:
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	var r1 := _row(v, "Профиль")
	_target_opt = OptionButton.new()
	_target_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_opt.add_item("Рельс")
	_target_opt.add_item("Балласт")
	_target_opt.item_selected.connect(func(_i: int): _load_target())
	r1.add_child(_target_opt)

	_part_note = Label.new()
	_part_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_part_note.modulate = Color(1.0, 0.85, 0.5)
	_part_note.visible = false
	v.add_child(_part_note)

	_editor = ProfileEditor.new()
	_editor.custom_minimum_size = Vector2(0, 320)
	_editor.changed.connect(_on_changed)
	_editor.selection_changed.connect(_on_selection)
	v.add_child(_editor)

	var hint := Label.new()
	hint.text = "ЛКМ по точке: тащить. ЛКМ по линии: добавить точку. ПКМ по точке: удалить. СКМ или Shift+ЛКМ: сдвиг. Колесо: масштаб. Alt при перетаскивании: без привязки."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.6)
	v.add_child(hint)

	var rt := HBoxContainer.new()
	v.add_child(rt)
	_undo_btn = _button(rt, "Отменить", func(): _editor.undo())
	_redo_btn = _button(rt, "Повторить", func(): _editor.redo())
	_button(rt, "Вписать", func(): _editor.fit())

	var ro := HBoxContainer.new()
	v.add_child(ro)
	_mirror = CheckBox.new()
	_mirror.text = "Зеркало"
	_mirror.tooltip_text = "Правка одной половины, вторая повторяет. Несимметричный профиль при включении станет симметричным по правой половине."
	_mirror.toggled.connect(func(on: bool):
		_editor.set_mirror(on)
		_update_state())
	ro.add_child(_mirror)
	_snap_chk = CheckBox.new()
	_snap_chk.text = "Привязка"
	_snap_chk.button_pressed = true
	_snap_chk.toggled.connect(func(on: bool): _editor.snap_on = on)
	ro.add_child(_snap_chk)
	_snap_spin = SpinBox.new()
	_snap_spin.min_value = 0.001
	_snap_spin.max_value = 0.5
	_snap_spin.step = 0.001
	_snap_spin.value = 0.025
	_snap_spin.suffix = "ю"
	_snap_spin.value_changed.connect(func(x: float): _editor.snap_step = x)
	ro.add_child(_snap_spin)
	_dims_chk = CheckBox.new()
	_dims_chk.text = "Размеры"
	_dims_chk.button_pressed = true
	_dims_chk.toggled.connect(func(on: bool):
		_editor.show_dims = on
		_editor.queue_redraw())
	ro.add_child(_dims_chk)

	var rp := _row(v, "Выбранная точка")
	_pt_label = Label.new()
	_pt_label.text = "—"
	_pt_label.custom_minimum_size = Vector2(28, 0)
	rp.add_child(_pt_label)
	_px = _make_spin(rp, -10.0, 10.0, 0.001, "x")
	_py = _make_spin(rp, -10.0, 10.0, 0.001, "y")

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)

	v.add_child(HSeparator.new())
	var pt := Label.new()
	pt.text = "Пресеты и генераторы"
	pt.add_theme_font_size_override("font_size", 16)
	v.add_child(pt)
	var rs := _row(v, "Пресет")
	_preset_opt = OptionButton.new()
	_preset_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rs.add_child(_preset_opt)
	_button(rs, "Применить", _on_apply_preset)

	_rail_gen = VBoxContainer.new()
	v.add_child(_rail_gen)
	for sp in VIGNOLE_SPINS:
		_gen_spin(_rail_gen, "rail", sp, float(TrackProfileTools.VIGNOLE_DEFAULTS[sp[0]]))
	_button(_rail_gen, "Сгенерировать рельс Виньоля", func():
		_editor.apply_profile(TrackProfileTools.rail_vignole(_gen_params("rail", VIGNOLE_SPINS))))
	_ballast_gen = VBoxContainer.new()
	v.add_child(_ballast_gen)
	for sp in TRAPEZOID_SPINS:
		_gen_spin(_ballast_gen, "ballast", sp, float(TrackProfileTools.TRAPEZOID_DEFAULTS[sp[0]]))
	_button(_ballast_gen, "Сгенерировать насыпь трапецией", func():
		_editor.apply_profile(TrackProfileTools.ballast_trapezoid(_gen_params("ballast", TRAPEZOID_SPINS))))

	v.add_child(HSeparator.new())
	_text_chk = CheckBox.new()
	_text_chk.text = "Текстом (запасной ввод)"
	_text_chk.toggled.connect(func(on: bool):
		_text_box.visible = on
		if on:
			_fill_text())
	v.add_child(_text_chk)
	_text_box = VBoxContainer.new()
	_text_box.visible = false
	v.add_child(_text_box)
	var th := Label.new()
	th.text = "Одна точка на строку: «x y». Обход слева направо поверх, низ профиля на y = 0."
	th.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_box.add_child(th)
	_text_edit = TextEdit.new()
	_text_edit.custom_minimum_size = Vector2(0, 130)
	_text_box.add_child(_text_edit)
	var tb := HBoxContainer.new()
	_text_box.add_child(tb)
	_button(tb, "Применить", _on_apply_text)
	_button(tb, "Вернуть", _fill_text)
	_text_status = Label.new()
	_text_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_box.add_child(_text_status)


func _row(parent: Control, text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	parent.add_child(h)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(130, 0)
	h.add_child(l)
	return h


func _button(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _make_spin(parent: Control, lo: float, hi: float, step: float, prefix: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.prefix = prefix
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.editable = false
	s.value_changed.connect(func(_v: float):
		if not _syncing:
			_editor.set_selected_point(Vector2(_px.value, _py.value)))
	parent.add_child(s)
	return s


func _gen_spin(parent: Control, kind: String, sp: Array, value: float) -> void:
	var r := _row(parent, sp[1])
	var s := SpinBox.new()
	s.min_value = sp[2]
	s.max_value = sp[3]
	s.step = sp[4]
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(s)
	_spins["%s:%s" % [kind, sp[0]]] = s


func _gen_params(kind: String, list: Array) -> Dictionary:
	var out := {}
	for sp in list:
		out[sp[0]] = (_spins["%s:%s" % [kind, sp[0]]] as SpinBox).value
	return out


# ==========================================
# Состояние
# ==========================================

## Студия вызывает при открытии стиля
func refresh_from_style() -> void:
	if studio == null or _editor == null:
		return
	_load_target()


## Студия вызывает при смене флагов частей: подпись над редактором и перерисовка сечения
func update_parts() -> void:
	if _part_note == null or studio == null:
		return
	var note := TrackStyleValidator.part_note(studio.get_style(), _kind())
	_part_note.text = note
	_part_note.visible = not note.is_empty()
	if _editor:
		_editor.queue_redraw()


func _on_visibility() -> void:
	# Контекст (колея, шпала, второй профиль) мог измениться на других вкладках
	if not is_visible_in_tree() or studio == null or studio.get_style() == null:
		return
	var current: PackedVector2Array = studio.get_style().get(_key())
	if current != _editor.profile:
		_load_target()
	else:
		_editor.queue_redraw()


func _load_target() -> void:
	var style: TrackStyle = studio.get_style()
	if style == null:
		return
	var target := ProfileEditor.Target.RAIL if _target_opt.selected == 0 else ProfileEditor.Target.BALLAST
	_editor.load_profile(style.get(_key()), target, style)
	_preset_opt.clear()
	for n in (TrackProfileTools.RAIL_PRESETS if target == ProfileEditor.Target.RAIL else TrackProfileTools.BALLAST_PRESETS):
		_preset_opt.add_item(n)
	_rail_gen.visible = target == ProfileEditor.Target.RAIL
	_ballast_gen.visible = target == ProfileEditor.Target.BALLAST
	_seed_generators(style)
	if _mirror.button_pressed:
		_editor.set_mirror(true)   # при асимметрии станет симметричным и сам сообщит об изменении
	_update_state()
	_on_selection(-1)
	update_parts()
	if _text_chk.button_pressed:
		_fill_text()


## Стартовые значения генераторов из текущего стиля
func _seed_generators(style: TrackStyle) -> void:
	_set_gen("rail:height", style.rail_height())
	_set_gen("rail:foot_width", style.rail_width())
	var hi := 0.0
	var bw := 0.0
	for v in style.ballast_profile:
		hi = maxf(hi, v.y)
		bw = maxf(bw, absf(v.x))
	if bw > 0.0:
		_set_gen("ballast:bottom_half", bw)
		_set_gen("ballast:top_half", minf(bw, _top_half(style.ballast_profile)))
		_set_gen("ballast:height", hi)


func _top_half(p: PackedVector2Array) -> float:
	var top := 0.0
	for v in p:
		top = maxf(top, v.y)
	var h := 0.0
	for v in p:
		if absf(v.y - top) < 0.0005:
			h = maxf(h, absf(v.x))
	return h


func _set_gen(key: String, value: float) -> void:
	if _spins.has(key):
		(_spins[key] as SpinBox).set_value_no_signal(value)


func _on_changed() -> void:
	studio.set_field(_key(), _editor.profile.duplicate())
	_update_state()
	_editor.queue_redraw()
	if _text_chk.button_pressed:
		_fill_text()


func _update_state() -> void:
	_undo_btn.disabled = not _editor.can_undo()
	_redo_btn.disabled = not _editor.can_redo()
	var info := TrackProfileTools.inspect(_editor.profile)
	var t := "Точек %d, ширина %.3f, высота %.3f" % [_editor.profile.size(), info["width"], info["height"]]
	var msg := TrackProfileTools.problems_text(_editor.profile)
	if msg.is_empty():
		_status.text = t
		_status.modulate = Color(0.75, 0.9, 0.75)
	else:
		_status.text = "%s. Проблемы: %s" % [t, msg]
		_status.modulate = Color(1.0, 0.6, 0.5)


func _on_selection(i: int) -> void:
	_syncing = true
	var ok := i >= 0 and i < _editor.profile.size()
	_px.editable = ok
	_py.editable = ok
	_pt_label.text = str(i + 1) if ok else "—"
	if ok:
		_px.set_value_no_signal(_editor.profile[i].x)
		_py.set_value_no_signal(_editor.profile[i].y)
	_syncing = false
	if ok:
		_update_state()


func _on_apply_preset() -> void:
	if _preset_opt.item_count == 0:
		return
	_editor.apply_profile(TrackProfileTools.preset(_kind(), _preset_opt.get_item_text(_preset_opt.selected)))


# --- текст ---

func _fill_text() -> void:
	_text_edit.text = TrackStyleIO.profile_to_text(_editor.profile)
	_text_status.text = ""


func _on_apply_text() -> void:
	var r := TrackStyleIO.parse_profile(_text_edit.text)
	if not r["ok"]:
		_text_status.text = String(r["error"])
		_text_status.modulate = Color(1.0, 0.5, 0.5)
		return
	_text_status.text = "применено, точек %d" % (r["points"] as PackedVector2Array).size()
	_text_status.modulate = Color(0.6, 0.9, 0.6)
	_editor.apply_profile(r["points"])
