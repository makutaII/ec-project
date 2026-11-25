class_name ModeController extends Node

########################
##    ModeController 
## 💡 LVL1 - Переключает текущий режим игры, обрабатывает события mode 
########################
## Реестр режимов: у каждого режима есть обработчик его панели. Контракт обработчика:
##   show_mode_ui(mode: StringName)   показать панель режима (с анимацией)
##   hide_mode_ui()                   спрятать панель режима, сбросить выбранную категорию
##   debug_open_category(index: int)  необязательно: открыть категорию по номеру (Global.active_ui_category)
## Build, Operate и Observe обслуживает ToolbarController (каталог режима регистрирует адаптер).
## У режима без обработчика показывается простая панель из _plain_panels.
## Режим «wiring» («Монтаж», ATTN_23 §23.9): каталог проводки (категория dc_controller, тег wire), вид плиты и путей ведёт WiringView.
## Режим «sections» (ящики подмакетника, ATTN_23): панель категории table (пресеты секций), ставит их TableTool.
## Library это экран поверх игры (ATTN_22 §22.5.2), режим HUD не меняется: см. _open_library.


@onready var tool_controller: ToolController = $"../../ToolController"
#@onready var GR : GameRoot = $"../../"

## ⚡ Сигнал наружу о смене режима
signal current_mode_changed(_current_mode)

## режим -> обработчик
var _handlers := {}
## режим -> панель без обработчика
var _plain_panels := {}

# XX claude-library L1: экран Library поверх игры
const LIBRARY_SCREEN := preload("res://core/library/library_screen.tscn")
## Слой экрана Library: выше UI (0) и подсказок (10), чтобы игра ни рисовалась, ни кликалась поверх
const LIBRARY_LAYER := 50
var _library_screen: Control
var _library_layer: CanvasLayer
var _library_prev_mode: StringName = &"build"
## Запрос «В игру» из Library: модель и исполнение, которые надо взять в руку после закрытия экрана (ATTN_22 L4)
var _library_place_setting: EntitySetting
var _library_place_variant: Dictionary = {}
## «Оставить активной» из Room Studio (ATTN_25 RM4): комната, которую надо сделать активной после закрытия экрана
var _library_keep_room: StringName = &""
## Кнопки режимов живут в TopBar (U9). Берём через TopBar: изнутри его сцены % снаружи не виден
@onready var _mode_panel = %TopBar.get_mode_panel()


func _enter_tree() -> void:
	add_to_group(&"mode_controller")   # по группе его находит ToolController (не по пути, U8)


func _ready() -> void:
	#⚡Сигнал о выборе режима из панели коннектится с контроллером
	_mode_panel.mode_selected.connect(on_mode_selected)

	var toolbar := get_node_or_null("%ToolbarController")
	_handlers = {
		&"build": toolbar,
		&"operate": toolbar,
		&"observe": toolbar,
		&"sections": toolbar,   # XX claude-table T2: каталог секций (категория table)
		&"coaster": toolbar,   # XX claude-coaster C1: каталог траков горок (ATTN_27)
		&"wiring": toolbar,   # XX claude-wire W3: режим «Монтаж» (ATTN_23 §23.9)
	}
	_plain_panels = {&"library": get_node_or_null("%LibraryPanel")}

	# Режим быстрой загрузки: Observe недоступен, кнопка режима скрыта. Секций стола тоже нет (XX claude-table T1b)
	if Global.fast_debug:
		for btn_name in ["ObserveButton", "SectionsButton", "WiringButton"]:
			var fast_btn := _mode_panel.get_node_or_null("VBoxContainer/" + btn_name) as Control
			if fast_btn:
				fast_btn.hide()

	# Задежка, чтобы создались кнопки в билдпанели
	await get_tree().process_frame
	await get_tree().process_frame
	
	# Выбор режима для старта по Global переменной
	var _mode := Global.current_mode
	_show_mode_ui(_mode)
	var _mode_button := _mode_panel.get_node_or_null("VBoxContainer/" + _mode.capitalize() + "Button") as Button
	if _mode_button:
		_mode_button.button_pressed = true
	
	#DD дебаг Запускаем активную категорию 
	if Global.debug_mode:
		var handler = _handlers.get(_mode)
		if handler != null and handler.has_method("debug_open_category"):
			handler.debug_open_category(Global.active_ui_category)




##⚡ Сигнал из панели ModePanel. Ставим новый режим
func on_mode_selected(new_mode: StringName) -> void:
	# XX claude-library L1: Library открывается экраном поверх игры, режим HUD и Global.current_mode не меняются
	if new_mode == &"library":
		_open_library()
		return

	var current_m := Global.current_mode
	
	if new_mode == current_m:	return

	# XX claude-table T4c: выход из «Секций» при пустом столе. Режим меняется, но игрока предупреждаем
	if current_m == &"sections" and not LYM.has_table():
		LYM.notice.emit(LYM.EMPTY_NOTE)

	# Выключаем панель категорий текущего режима и сбрасываем его выбор
	_hide_mode_ui(current_m)
	
	# Выключаем контейнеры объектов (кнопок) и остальные панели
	for _cont in %MainControl.get_children():
		_cont.hide()

	# Отключаем все кнопки
	for _btn in get_tree().get_nodes_in_group('category_buttons'):
		_btn.button_pressed = false
		
	# Включаем панель нового режима
	_show_mode_ui(new_mode)

	# Режим пишем сюда, не в ToolController: ModeController владелец режима
	Global.current_mode = new_mode
	# ⚡Сигнал наружу
	current_mode_changed.emit(new_mode)



func _show_mode_ui(mode: StringName) -> void:
	var handler = _handlers.get(mode)
	if handler != null:
		handler.show_mode_ui(mode)
		return
	var panel := _plain_panels.get(mode) as Control
	if panel:
		panel.show()


func _hide_mode_ui(mode: StringName) -> void:
	var handler = _handlers.get(mode)
	if handler != null:
		handler.hide_mode_ui()


# XX claude-library L1
## Открыть экран Library поверх игры. Пауза и выключение 3D игры делает сам экран
func _open_library() -> void:
	if is_instance_valid(_library_screen):
		return
	_library_prev_mode = Global.current_mode
	_library_layer = CanvasLayer.new()
	_library_layer.name = "LibraryLayer"
	_library_layer.layer = LIBRARY_LAYER
	_library_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_library_screen = LIBRARY_SCREEN.instantiate()
	_library_screen.closed.connect(_on_library_closed)
	_library_screen.place_requested.connect(_on_library_place)
	_library_screen.room_keep_requested.connect(_on_library_room_keep)
	_library_layer.add_child(_library_screen)
	get_parent().add_child(_library_layer)


## Экран закрыт: кнопка режима возвращается на прежний режим (сам режим не менялся)
func _on_library_closed() -> void:
	_library_screen = null
	if is_instance_valid(_library_layer):
		_library_layer.queue_free()
	_library_layer = null
	var btn := _mode_panel.get_node_or_null("VBoxContainer/" + String(_library_prev_mode).capitalize() + "Button") as Button
	if btn:
		btn.button_pressed = true
	if _library_keep_room != &"":
		var keep_id := _library_keep_room
		_library_keep_room = &""
		_apply_kept_room.call_deferred(keep_id)
	if _library_place_setting != null:
		var setting := _library_place_setting
		var variant := _library_place_variant
		_library_place_setting = null
		_library_place_variant = {}
		_start_build_from_library.call_deferred(setting, variant)


## Room Studio просит оставить комнату активной (админ): применяется после закрытия экрана
func _on_library_room_keep(id: StringName) -> void:
	_library_keep_room = id


## Сменить активную комнату на выбранную в Room Studio. Права проверяет RoomBuilder.request_room (источник admin: Global.debug_mode)
func _apply_kept_room(id: StringName) -> void:
	var rb := get_tree().get_first_node_in_group(&"room_root") as RoomBuilder
	if rb == null or rb.get_room_id() == id:
		return
	rb.request_room(id, RoomBuilder.SRC_ADMIN)


## «В игру» в Library: закрыть экран и включить Build с этой моделью и её исполнением
func _on_library_place(setting: EntitySetting, variant: Dictionary) -> void:
	_library_place_setting = setting
	_library_place_variant = variant
	if is_instance_valid(_library_screen):
		_library_screen.close()


func _start_build_from_library(setting: EntitySetting, variant: Dictionary) -> void:
	if Global.current_mode != &"build":
		var build_btn := _mode_panel.get_node_or_null("VBoxContainer/BuildButton") as Button
		if build_btn:
			build_btn.button_pressed = true
		on_mode_selected(&"build")
	tool_controller.select_build_object(setting, variant)
