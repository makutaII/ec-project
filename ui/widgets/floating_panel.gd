class_name FloatingPanel extends PanelContainer

# U13 (ATTN_17 §17.3.4, §17.4): новый файл
## Плавающая панель: перетаскивается за заголовок, сворачивается кнопкой и двойным кликом по заголовку,
## меняет размер ручкой в правом нижнем углу. Не заходит под TopBar и за край экрана, при уменьшении
## окна подтягивается внутрь. Положение, размер и «свёрнута» запоминаются в Settings ([windows],
## доли экрана), сброс раскладки в окне настроек стирает секцию.
## Наследник вызывает setup_floating() один раз в своём _ready и кладёт панель в Control на весь
## экран (HUD). Клики и драг по панели в мир не уходят: PanelContainer забирает мышь.

## Секция Settings, её стирает кнопка «Сбросить раскладку окон»
const SECTION := "windows"
## Верхняя граница: высота TopBar
const TOP_LIMIT := 40.0
## Отступ от краёв экрана при размещении по умолчанию
const EDGE := 12.0
## Снизу по умолчанию оставляем место под подсказку внизу экрана
const DEFAULT_BOTTOM := 56.0

## Минимальный размер, не меньше размера содержимого
var min_panel_size := Vector2(420, 240)
## Размер при первом открытии
var default_panel_size := Vector2(574, 260)

var _id: StringName
var _handle: Control
var _body: Control
var _grip_host: Container
var _collapse_btn: Button
var _grip: Control

var _want_size := Vector2.ZERO
var _collapsed := false
var _placed := false
var _frac := Vector2.ZERO   # левый верхний угол в долях экрана

var _drag := false
var _drag_off := Vector2.ZERO
var _resize := false
var _resize_start_size := Vector2.ZERO
var _resize_start_mouse := Vector2.ZERO


## id: ключ в Settings; handle: заголовок (тянется и двойной клик); body: что прячется при сворачивании;
## button_host: контейнер заголовка, куда ставим кнопку сворачивания; grip_host: контейнер, в конце которого ручка
func setup_floating(id: StringName, handle: Control, body: Control, button_host: Container, grip_host: Container) -> void:
	_id = id
	_handle = handle
	_body = body
	_grip_host = grip_host
	custom_minimum_size = min_panel_size

	_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_handle.gui_input.connect(_on_handle_input)

	_collapse_btn = Button.new()
	_collapse_btn.text = "–"
	_collapse_btn.theme_type_variation = &"ButtonSmall"
	_collapse_btn.custom_minimum_size = Vector2(28, 22)
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.tooltip_text = "Свернуть или развернуть"
	_collapse_btn.pressed.connect(toggle_collapsed)
	button_host.add_child(_collapse_btn)

	if grip_host is BoxContainer:
		(grip_host as BoxContainer).alignment = BoxContainer.ALIGNMENT_END   # ручка в правом углу
	_grip = _FloatGrip.new()
	_grip.custom_minimum_size = Vector2(16, 14)
	_grip.size_flags_horizontal = Control.SIZE_SHRINK_END
	_grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	_grip.gui_input.connect(_on_grip_input)
	grip_host.add_child(_grip)

	_load_saved()
	visibility_changed.connect(_on_visibility_changed)
	get_viewport().size_changed.connect(_on_viewport_resized)


func is_collapsed() -> bool:
	return _collapsed


func toggle_collapsed() -> void:
	set_collapsed(not _collapsed)


func set_collapsed(on: bool) -> void:
	if on == _collapsed:
		return
	if on:
		_want_size = Vector2(size.x, maxf(size.y, _want_size.y))
	_collapsed = on
	_body.visible = not on
	_grip.visible = not on
	_collapse_btn.text = "+" if on else "–"
	_update_min()
	_apply_size()
	_clamp_position()
	_save()


# ---------------- размещение ----------------

func _on_visibility_changed() -> void:
	if visible:
		# размер контейнера известен после раскладки
		_place.call_deferred()


func _place() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_END
	var vp := _viewport_size()
	if _want_size == Vector2.ZERO:
		_want_size = default_panel_size
	_apply_size()
	if _placed:
		position = _clamped(_frac * vp)
		return
	_placed = true
	_frac = Vector2((vp.x - size.x - EDGE) / vp.x, (vp.y - size.y - DEFAULT_BOTTOM) / vp.y)
	position = _clamped(_frac * vp)


func _apply_size() -> void:
	var vp := _viewport_size()
	var w := clampf(_want_size.x, custom_minimum_size.x, maxf(custom_minimum_size.x, vp.x))
	if _collapsed:
		size = Vector2(w, 0.0)   # контейнер сожмёт до высоты заголовка
	else:
		var h := clampf(_want_size.y, custom_minimum_size.y, maxf(custom_minimum_size.y, vp.y - TOP_LIMIT))
		size = Vector2(w, h)


func _on_viewport_resized() -> void:
	if not _placed or not visible:
		return
	_apply_size()
	position = _clamped(_frac * _viewport_size())


func _viewport_size() -> Vector2:
	return get_viewport_rect().size


## Внутри экрана и не выше TopBar
func _clamped(p: Vector2) -> Vector2:
	var vp := _viewport_size()
	return Vector2(
		clampf(p.x, 0.0, maxf(0.0, vp.x - size.x)),
		clampf(p.y, TOP_LIMIT, maxf(TOP_LIMIT, vp.y - size.y)))


func _clamp_position() -> void:
	position = _clamped(position)
	_remember_fraction()


func _remember_fraction() -> void:
	var vp := _viewport_size()
	_frac = Vector2(position.x / vp.x, position.y / vp.y)


# ---------------- перетаскивание и размер ----------------

func _on_handle_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			if mb.double_click:
				toggle_collapsed()
			else:
				_drag = true
				_drag_off = get_global_mouse_position() - global_position
		else:
			if _drag:
				_drag = false
				_save()
		_handle.accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _drag:
		position = _clamped(get_global_mouse_position() - _drag_off)
		_remember_fraction()
		_handle.accept_event()


func _on_grip_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_resize = true
			_resize_start_size = size
			_resize_start_mouse = get_global_mouse_position()
		elif _resize:
			_resize = false
			_save()
		_grip.accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _resize:
		var delta := get_global_mouse_position() - _resize_start_mouse
		var vp := _viewport_size()
		var w := clampf(_resize_start_size.x + delta.x, custom_minimum_size.x, maxf(custom_minimum_size.x, vp.x - position.x))
		var h := clampf(_resize_start_size.y + delta.y, custom_minimum_size.y, maxf(custom_minimum_size.y, vp.y - position.y))
		_want_size = Vector2(w, h)
		size = _want_size
		_grip.accept_event()


# ---------------- Settings ----------------

func _save() -> void:
	if _id == &"" or not _placed:
		return
	var vp := _viewport_size()
	var k := String(_id)
	Settings.set_value(SECTION, k + "_x", _frac.x)
	Settings.set_value(SECTION, k + "_y", _frac.y)
	Settings.set_value(SECTION, k + "_w", _want_size.x / vp.x)
	Settings.set_value(SECTION, k + "_h", _want_size.y / vp.y)
	Settings.set_value(SECTION, k + "_collapsed", _collapsed)


func _load_saved() -> void:
	var k := String(_id)
	if not Settings.has_value(SECTION, k + "_x"):
		return
	var vp := _viewport_size()
	_frac = Vector2(float(Settings.get_value(SECTION, k + "_x", 0.0)), float(Settings.get_value(SECTION, k + "_y", 0.0)))
	_want_size = Vector2(float(Settings.get_value(SECTION, k + "_w", 0.0)) * vp.x, float(Settings.get_value(SECTION, k + "_h", 0.0)) * vp.y)
	if _want_size.x <= 0.0 or _want_size.y <= 0.0:
		_want_size = Vector2.ZERO
	_placed = true
	_collapsed = bool(Settings.get_value(SECTION, k + "_collapsed", false))
	_body.visible = not _collapsed
	_grip.visible = not _collapsed
	_collapse_btn.text = "+" if _collapsed else "–"
	_update_min()


## Свёрнутая панель не держит минимальную высоту: остаётся только заголовок
func _update_min() -> void:
	custom_minimum_size = Vector2(min_panel_size.x, 0.0 if _collapsed else min_panel_size.y)


## Ручка размера: два штриха в углу
class _FloatGrip extends Control:
	func _draw() -> void:
		var c := get_theme_color(&"font_color", &"Label")
		c.a = 0.6
		draw_line(Vector2(size.x - 2, size.y - 12), Vector2(size.x - 12, size.y - 2), c, 1.0)
		draw_line(Vector2(size.x - 2, size.y - 7), Vector2(size.x - 7, size.y - 2), c, 1.0)
