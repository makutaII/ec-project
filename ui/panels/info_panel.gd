class_name InfoPanel extends FloatingPanel

###########################
## InfoPanel. Панель сведений о выбранном объекте
###########################
## Только реестр вкладок. Вся логика во вкладках ui/panels/info/ (базовый класс InfoTab, U5):
## панель привязывает цель, показывает вкладки по can_show (а не по номеру) и 10 раз в секунду
## обновляет только активную вкладку.
## Цель приходит сигналом ToolController.selection_changed.

@onready var tab_container: TabContainer = %TabContainer

## Частота обновления живых значений активной вкладки, раз в секунду
const REFRESH_HZ := 10.0

var current_target: Entity

## ⚡Сигнал для спидометра
signal s_select_entity( sel_entity:Variant, spdmetr_on: bool, vert :bool)

var _tabs: Array[InfoTab] = []
var _power: InfoPowerTab
var _main: InfoMainTab
var _acc := 0.0


func _ready() -> void:
	add_to_group(&"info_panel")   # по группе её находит спидометр
	# U13: плавающая панель (внизу справа по умолчанию, тянется за заголовок, сворачивается, запоминает место)
	var vbox := $VBoxContainer
	var grip_row := HBoxContainer.new()
	vbox.add_child(grip_row)
	setup_floating(&"info_panel", $VBoxContainer/HeaderHBoxContainer/PanelContainer, tab_container,
		$VBoxContainer/HeaderHBoxContainer, grip_row)
	hide() # Прячем панель на старте
	# ⚡Сигнал из ToolController: какой объект показывать
	var _tc := get_node_or_null("../../../ToolController")   # HUD → UI → GameRoot (после U8)
	if _tc:
		_tc.selection_changed.connect(set_target)

	_power = InfoPowerTab.new()
	_main = InfoMainTab.new()
	# Вкладки из сцены, в порядке сцены; затем вкладки, создаваемые кодом
	_add_tab(_main, tab_container.get_node("MainTab"))
	_add_tab(_power, tab_container.get_node("PowerTab"))
	_add_tab(InfoTransformTab.new(), tab_container.get_node("TransformTab"))
	_add_tab(InfoVisualTab.new(), tab_container.get_node("VisualTab"))   # U13: секции компонентов (D13)
	_add_tab(InfoMechTab.new())
	_add_tab(InfoTerrainTab.new())
	_add_tab(InfoTableTab.new())   # XX claude-table T4: опоры и высота стола
	_add_tab(InfoSwitchTab.new())
	_add_tab(InfoDevicesTab.new())   # D4: 3D-пульт и провода
	_add_tab(InfoSwitchboxTab.new())   # D5: коммутаторы и задачи
	_update_tab_visibility()

	# Трак питания обновляется по сигналам менеджера, поезд живыми значениями вкладки
	PGM.power_tab_updated.connect(_power.update_tab)
	PGM.power_updated.connect(_power.on_power_track_updated)
	PGM.output_event.connect(func(_l: int, _k: String, _r: String) -> void: _power.update_tab())


func _add_tab(tab: InfoTab, scene_control: Control = null) -> void:
	tab.setup(self, scene_control)
	_tabs.append(tab)


func _process(delta: float) -> void:
	if not visible or current_target == null:
		return
	_acc += delta
	if _acc < 1.0 / REFRESH_HZ:
		return
	_acc = 0.0
	var active := tab_container.get_current_tab_control()
	for tab in _tabs:
		if tab.control == active:
			tab.refresh()
			break


## Вызывается ToolController (selection_changed), когда выбор сменился
func set_target(entity: Entity) -> void:
	# Камера вагона включена: этот клик ее только выключает
	if _wagon_camera_active():
		_release_wagon_camera()
		return

	# 1. Отписываемся от старого объекта
	if is_instance_valid(current_target):
		current_target.component_added.disconnect(_on_components_changed)
		current_target.component_removed.disconnect(_on_components_changed)
	for tab in _tabs:
		tab.unbind()

	current_target = entity

	# 2. Если кликнули в пустоту - прячем панель
	if not current_target:
		s_select_entity.emit(null, false, false)
		hide()
		return

	# 3. Подписываемся на новый объект (компоненты добавляются и убираются)
	current_target.component_added.connect(_on_components_changed)
	current_target.component_removed.connect(_on_components_changed)

	# Спидометр: галочки в панели нет (убрана в U14c), он выключен до переписывания в U23
	s_select_entity.emit(current_target, false, false)

	show()

	# 4. Привязываем вкладки и выставляем видимость по can_show
	for tab in _tabs:
		tab.bind(current_target)
	_update_tab_visibility()


## Камера вагона включена (U13: состояние в C_CameraTarget, переключатель на вкладке Visual)
func _wagon_camera_active() -> bool:
	if not is_instance_valid(current_target):
		return false
	var ct := current_target.get_comp(C_CameraTarget) as C_CameraTarget
	return ct != null and ct.camera_instance != null


func _release_wagon_camera() -> void:
	current_target.send_event("on_wagon_camera_selected", {"selected": false})


## Для вкладок: пересчитать, какие вкладки показывать (набор компонентов цели мог измениться)
func refresh_tab_visibility() -> void:
	_update_tab_visibility()


## Прячет вкладки, которые не подходят цели. Если активная спряталась, открывается первая
func _update_tab_visibility() -> void:
	for tab in _tabs:
		var idx := tab_container.get_tab_idx_from_control(tab.control)
		tab_container.set_tab_hidden(idx, not tab.can_show(current_target))
	var current := tab_container.get_current_tab_control()
	var idx_now := tab_container.get_tab_idx_from_control(current)
	if idx_now < 0 or tab_container.is_tab_hidden(idx_now):
		tab_container.current_tab = 0


## Вызывается ТОЛЬКО когда у цели добавился или удалился компонент
func _on_components_changed(_type: Script) -> void:
	for tab in _tabs:
		tab.components_changed()
