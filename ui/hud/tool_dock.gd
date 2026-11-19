class_name ToolDockView extends HBoxContainer

# U15a (ATTN_17 §17.4, вариант B): новый файл
## Нижний ряд HUD: слева панель категорий (кнопки 40×40 в 2 колонки), справа ToolDock с хедером
## (режим, категория, тег, теги, число объектов, действия) и телом (объекты с переносом строк, прокрутка вниз).
## Содержимое наполняет ToolbarController (контракт show_mode_ui / hide_mode_ui прежний); здесь только вид и
## растягивание: ToolDock тянется вверх за верхнюю границу (ResizeGrip) независимо от панели категорий.
## Высота запоминается в Settings [windows] tool_dock_h (доля высоты экрана), её стирает «Сбросить раскладку окон».

const SECTION := "windows"
const KEY_H := "tool_dock_h"
## Минимальная высота ToolDock (§17.6.9) и предел растяжения: доля высоты экрана
const MIN_H := 138.0
const MAX_FRAC := 0.45

## ⚡Изменилась высота, которую нижний ряд занимает у левого края (показан или спрятан ряд,
## открыта или закрыта категория, растягивание, размер окна). DC-панель стоит над этой высотой
signal occupied_changed

var _drag := false
var _start_h := 0.0
var _start_mouse := 0.0
var _occupied_queued := false


## Группа нужна раньше, чем у соседей по сцене UI отработает _ready (DC-панель стоит в дереве выше
## ряда и готова раньше него), поэтому вступление в группу здесь, а не в _ready
func _enter_tree() -> void:
	add_to_group(&"tool_dock_view")   # по группе его находит DC-панель (стоит над ним)


func _ready() -> void:
	for c: Control in [self, %CategoriesPanel, %DockColumn]:
		c.resized.connect(_queue_occupied)
		c.visibility_changed.connect(_queue_occupied)
	var grip := %ResizeGrip as Control
	grip.gui_input.connect(_on_grip_input)
	var saved := float(Settings.get_value(SECTION, KEY_H, 0.0))
	if saved > 0.0:
		_set_height(saved * _viewport_h())
	get_viewport().size_changed.connect(func() -> void: _set_height((%DockPanel as Control).custom_minimum_size.y))


# Узлы для ToolbarController (изнутри этой сцены `%` снаружи не виден, поэтому через методы)
func categories_panel() -> Control: return %CategoriesPanel
func category_grid() -> Container: return %CategoryGrid
func dock_column() -> Control: return %DockColumn
func mode_label() -> Label: return %ModeLabel
func category_label() -> Label: return %CategoryLabel
func tag_label() -> Label: return %TagLabel
func tags_box() -> Container: return %HeaderTags
func count_label() -> Label: return %CountLabel
func actions_strip() -> Container: return %ActionsStrip
func objects_box() -> Container: return %ObjectsBox
func objects_flow() -> Container: return %ObjectsFlow
func empty_label() -> Label: return %EmptyObjects


## Высота от нижнего края окна до верха того, что стоит у левого края: панель категорий или ToolDock
## (что выше, только видимое). 0, если ряд спрятан (Observe, фоторежим)
func occupied_height() -> float:
	if not is_visible_in_tree():
		return 0.0
	var h := 0.0
	for c: Control in [%CategoriesPanel, %DockColumn]:
		if c.visible:
			h = maxf(h, c.size.y)
	return h


## Размеры детей обновляет контейнер позже, чем приходит сигнал: сообщаем один раз после раскладки
func _queue_occupied() -> void:
	if _occupied_queued:
		return
	_occupied_queued = true
	_emit_occupied.call_deferred()


func _emit_occupied() -> void:
	_occupied_queued = false
	occupied_changed.emit()


func _viewport_h() -> float:
	return get_viewport_rect().size.y


func _set_height(h: float) -> void:
	var panel := %DockPanel as Control
	panel.custom_minimum_size.y = clampf(h, MIN_H, maxf(MIN_H, _viewport_h() * MAX_FRAC))


func _on_grip_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			if mb.double_click:
				_set_height(MIN_H)
				_save()
			else:
				_drag = true
				_start_h = (%DockPanel as Control).custom_minimum_size.y
				_start_mouse = get_global_mouse_position().y
		elif _drag:
			_drag = false
			_save()
		(%ResizeGrip as Control).accept_event()
		return
	if _drag and event is InputEventMouseMotion:
		# вверх = выше: высота растёт, когда курсор уходит вверх от точки нажатия
		_set_height(_start_h + (_start_mouse - get_global_mouse_position().y))
		(%ResizeGrip as Control).accept_event()


func _save() -> void:
	Settings.set_value(SECTION, KEY_H, (%DockPanel as Control).custom_minimum_size.y / _viewport_h())
