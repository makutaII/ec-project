class_name LibraryScreen extends Control

# XX claude-library (новый файл)
########################
## LibraryScreen. Оболочка экрана Library, ATTN_22 §22.5.4, шаги L1, L1b
########################
## Верхняя полоса: название, кнопки студий (Model Studio, Track Studio, Icon Studio, Room Studio), у правого края «Закрыть». Всё ниже полосы это
## дочернее окно выбранной студии. Model Studio (прежнее тело экрана, model_studio.gd) создаётся один раз и при уходе
## скрывается; остальные студии создаются при открытии и освобождаются при уходе. Студии окном не управляют.
## Два способа запуска:
##   - оверлей поверх игры (ModeController): дерево на паузе, 3D главного вьюпорта выключено на время;
##   - отдельно (F6 на library_screen.tscn): без паузы, кнопки «Закрыть» нет.
## Перед уходом из студии и закрытием экрана активную студию спрашивают request_leave(proceed): она может не пустить
## (несохранённая работа) и сама спросит игрока. При закрытии Model Studio снимает объект через kill_me
## (регистрация в PGM), пауза и 3D возвращаются.

signal closed
## Поставить выбранную модель в игре (L4): ModeController закрывает экран и включает Build с этим исполнением.
## variant пуст, если покраски нет
signal place_requested(setting: EntitySetting, variant: Dictionary)
## Админ оставил комнату активной в Room Studio (ATTN_25 RM4): при закрытии экрана ModeController просит RoomBuilder сменить комнату.
## Приходит перед closed. id комнаты, которую надо сделать активной
signal room_keep_requested(id: StringName)

const ModelStudio := preload("res://core/library/model_studio.gd")

## Выключать 3D главного вьюпорта, пока открыт экран (в игре под экраном рисовать нечего)
const DISABLE_GAME_3D := true
## Кнопки студий автора. false: полоса студий скрыта, остаётся один Model Studio. Студии пишут в res://,
## поэтому на релизе false (до релиза true)
const SHOW_AUTHOR_STUDIOS := true
const TOOL_MODEL := &"model"
## Студии: id, название и откуда берётся: scene (PackedScene) или script (интерфейс собирается кодом).
## У Model Studio ни того, ни другого: её создаёт сама оболочка
const TOOLS := [
	{"id": &"model", "title": "Model Studio"},
	{"id": &"track", "title": "Track Studio", "scene": "res://core/library/track_studio/track_studio.tscn"},
	{"id": &"icon", "title": "Icon Studio", "scene": "res://core/library/icon_studio/icon_studio.tscn"},
	{"id": &"room", "title": "Room Studio", "scene": "res://core/library/room_studio/room_studio.tscn"},
]

var _embedded := false
var _prev_paused := false
var _prev_disable_3d: Variant = false
var _vp: Viewport
var _holder: Control
var _buttons := {}          # id студии -> Button
var _model: ModelStudio
var _active: Control
var _active_id: StringName = TOOL_MODEL
var _busy := false          # студия достраивает интерфейс: переключать и закрывать нельзя
var _closing := false
var _keep_room: StringName = &""   # выбор «Оставить активной» из Room Studio; живёт, пока открыт экран (студию можно закрыть и открыть)


func _ready() -> void:
	_embedded = get_tree().current_scene != self
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Корень из PackedScene под CanvasLayer получает размер 0: якоря из сцены считались до входа в дерево,
	# а перерасчёта никто не вызывает. Без этого экран схлопывается до минимального размера и не закрывает игру
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_build_ui()
	_model = ModelStudio.new()
	_model.name = "ModelStudio"
	_model.embedded = _embedded
	_model.place_requested.connect(place_requested.emit)
	_mount(_model)
	_active = _model
	_enter_overlay_state()


func _exit_tree() -> void:
	_leave_overlay_state()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	# Esc закрывает экран только из Model Studio: в других студиях он нужен полям ввода и диалогам
	if k.keycode == KEY_ESCAPE and _embedded and _active_id == TOOL_MODEL:
		close()
		get_viewport().set_input_as_handled()


## Закрыть экран (в оверлее). Активная студия может не пустить, если у неё несохранённая работа
func close() -> void:
	if not _embedded or _closing or _busy:
		return
	_ask_leave(func(): _finish_close.call_deferred())


func _finish_close() -> void:
	if _closing:
		return
	_closing = true
	# Студия убирается из дерева сразу: её _exit_tree записывает настройки
	if _active != null and _active != _model:
		_holder.remove_child(_active)
		_active.queue_free()
	_model.shutdown()
	if _keep_room != &"":
		room_keep_requested.emit(_keep_room)
	closed.emit()
	queue_free()


# ==========================================
# ОВЕРЛЕЙ: ПАУЗА И 3D ИГРЫ
# ==========================================

func _enter_overlay_state() -> void:
	if not _embedded:
		return
	_prev_paused = get_tree().paused
	get_tree().paused = true
	_vp = get_viewport()
	if DISABLE_GAME_3D and _vp != null:
		_prev_disable_3d = _vp.get("disable_3d")
		_vp.set("disable_3d", true)


func _leave_overlay_state() -> void:
	if not _embedded:
		return
	if DISABLE_GAME_3D and _vp != null and is_instance_valid(_vp):
		_vp.set("disable_3d", _prev_disable_3d)
	var tree := get_tree()
	if tree != null:
		tree.paused = _prev_paused


# ==========================================
# ИНТЕРФЕЙС
# ==========================================

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.1)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# set_anchors_preset без offsets оставляет прежний (нулевой) размер, поэтому именно _and_offsets_
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	root.add_child(margin)
	margin.add_child(_build_header())
	root.add_child(HSeparator.new())

	_holder = Control.new()
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(_holder)


## Верхняя полоса: название, кнопки студий, у правого края «Закрыть»
func _build_header() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)

	var title := Label.new()
	title.text = "LIBRARY"
	h.add_child(title)

	if SHOW_AUTHOR_STUDIOS:
		var group := ButtonGroup.new()
		for t in TOOLS:
			var b := Button.new()
			b.text = t["title"]
			b.toggle_mode = true
			b.button_group = group
			b.button_pressed = t["id"] == TOOL_MODEL
			b.pressed.connect(_on_tool_pressed.bind(t["id"]))
			_buttons[t["id"]] = b
			h.add_child(b)

	# «Закрыть» у правого края: распорка забирает свободную ширину (кнопки студий остаются слева)
	if _embedded:
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(spacer)
		var close_btn := Button.new()
		close_btn.text = "Закрыть"
		close_btn.tooltip_text = "Вернуться в игру (Esc в Model Studio)"
		close_btn.pressed.connect(close)
		h.add_child(close_btn)
	return h


## Студия на всю область под полосой (якоря заданы кодом: у студий из сцены размер при добавлении мог быть нулевым)
func _mount(c: Control) -> void:
	_holder.add_child(c)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


# ==========================================
# СТУДИИ
# ==========================================

func _on_tool_pressed(id: StringName) -> void:
	_sync_buttons()
	if id == _active_id or _busy or _closing:
		return
	# Model Studio остаётся в памяти со своим состоянием: из неё уходим без вопроса.
	# Остальные студии освобождаются, поэтому сначала спрашиваем
	if _active == _model:
		_activate(id)
	else:
		_ask_leave(func(): _activate.call_deferred(id))


## Спросить активную студию, можно ли уйти: proceed выполнится сразу или после подтверждения игрока
func _ask_leave(proceed: Callable) -> void:
	if _active != null and _active.has_method("request_leave"):
		_active.call("request_leave", proceed)
	else:
		proceed.call()


func _activate(id: StringName) -> void:
	if id == _active_id or _busy or _closing:
		return
	if _active == _model:
		_set_shown(_model, false)
	elif _active != null:
		_holder.remove_child(_active)
		_active.queue_free()
	_active = null
	_active_id = id
	_sync_buttons()
	if id == TOOL_MODEL:
		_active = _model
		_set_shown(_model, true)
		return

	var studio := _make_tool(id)
	if studio == null:
		_active_id = TOOL_MODEL
		_active = _model
		_set_shown(_model, true)
		_sync_buttons()
		return
	_busy = true
	_set_buttons_disabled(true)
	_active = studio
	_mount(_active)
	# Студия досоздаёт часть интерфейса после первого кадра: до этого переключать нельзя
	await get_tree().process_frame
	await get_tree().process_frame
	_busy = false
	_set_buttons_disabled(false)


## Новая студия по таблице TOOLS (сцена или скрипт); null, если создать не удалось
func _make_tool(id: StringName) -> Control:
	for t in TOOLS:
		if t["id"] != id:
			continue
		if t.has("script"):
			return (t["script"] as GDScript).new() as Control
		var path := String(t.get("scene", ""))
		var packed: PackedScene = null
		if path != "":
			packed = load(path) as PackedScene
		if packed == null:
			push_warning("Library: не удалось загрузить студию %s (%s)" % [id, path])
			return null
		var studio := packed.instantiate() as Control
		_setup_tool(id, studio)
		return studio
	return null


## Связь студии с оболочкой до входа в дерево. Room Studio: «Оставить активной» (только над игрой)
func _setup_tool(id: StringName, studio: Control) -> void:
	if id != &"room" or studio == null:
		return
	studio.set("embedded", _embedded)
	studio.set("keep_room", _keep_room)
	if studio.has_signal("keep_room_changed"):
		studio.connect("keep_room_changed", func(room_id: StringName) -> void: _keep_room = room_id)


## Показать или скрыть студию, которая остаётся в памяти. Скрытая не получает клавиш и таймеров, её SubViewport не рисуется
func _set_shown(c: Control, on: bool) -> void:
	c.visible = on
	c.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED


## Подсветка кнопок по активной студии (ButtonGroup сам переставил бы её на нажатую, даже если переход не состоялся)
func _sync_buttons() -> void:
	for id in _buttons:
		(_buttons[id] as Button).set_pressed_no_signal(id == _active_id)


func _set_buttons_disabled(on: bool) -> void:
	for id in _buttons:
		(_buttons[id] as Button).disabled = on
