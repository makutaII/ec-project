class_name InfoSectionView extends RefCounted

# XX claude-terra 13.14 H2d (новый файл; код вынесен из InfoVisualTab, поведение то же)
###########################
## Рисует строки InfoSection контролами и обновляет их значения. Общий для вкладки «Вид» (секции компонентов цели) и вкладки
## «Инструмент» (секции настроек инструмента). Строки типа note сюда не попадают: их выносит вкладка в подвал.
###########################

## Контрол строки InfoSection (button, label, toggle, slider, list). Живые строки дописываются в live: [{type, row, control}]
static func make_row(row: Dictionary, live: Array[Dictionary]) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var type: StringName = row.type
	if type == &"button":
		var b := Button.new()
		b.text = String(row.title)
		b.pressed.connect(func() -> void: (row.action as Callable).call())
		h.add_child(b)
		return h
	var cap := Label.new()
	cap.text = String(row.title)
	cap.custom_minimum_size = Vector2(100, 0)
	cap.theme_type_variation = &"LabelSmall"
	cap.clip_text = true
	cap.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	cap.tooltip_text = cap.text
	cap.mouse_filter = Control.MOUSE_FILTER_PASS
	h.add_child(cap)
	var ctl: Control
	match type:
		&"label":
			ctl = Label.new()
		&"toggle":
			var t := CheckButton.new()
			t.focus_mode = Control.FOCUS_NONE
			t.toggled.connect(func(on: bool) -> void: (row.setter as Callable).call(on))
			ctl = t
		&"slider":
			var s := HSlider.new()
			s.min_value = float(row.min)
			s.max_value = float(row.max)
			s.step = float(row.step)
			s.custom_minimum_size = Vector2(80, 0)
			s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			s.value_changed.connect(func(v: float) -> void: (row.setter as Callable).call(v))
			ctl = s
		&"list":
			var o := OptionButton.new()
			o.focus_mode = Control.FOCUS_NONE
			o.fit_to_longest_item = false   # ширину не задает самый длинный пункт
			o.clip_text = true
			o.custom_minimum_size.x = 80
			var ids: Array = row.ids
			var titles: Array = row.titles
			for i in ids.size():
				o.add_item(String(titles[i]), i)
				o.set_item_metadata(i, ids[i])
			o.item_selected.connect(func(i: int) -> void: (row.setter as Callable).call(o.get_item_metadata(i)))
			ctl = o
		_:
			ctl = Label.new()
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(ctl)
	live.append({"type": type, "row": row, "control": ctl})
	return h


## Обновить контрол живой строки значением из getter (без сигнала setter)
static func refresh_row(v: Dictionary) -> void:
	var row: Dictionary = v.row
	var ctl: Control = v.control
	if not is_instance_valid(ctl):
		return
	match v.type:
		&"label":
			var val: Variant = row.value
			(ctl as Label).text = str((val as Callable).call() if val is Callable else val)
		&"toggle":
			(ctl as CheckButton).set_pressed_no_signal(bool((row.getter as Callable).call()))
		&"slider":
			var sl := ctl as HSlider
			sl.set_value_no_signal(float((row.getter as Callable).call()))
		&"list":
			var o := ctl as OptionButton
			var cur: Variant = (row.getter as Callable).call()
			for i in o.item_count:
				if o.get_item_metadata(i) == cur:
					o.select(i)
					break
