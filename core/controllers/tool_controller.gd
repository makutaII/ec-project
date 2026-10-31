class_name ToolController extends Node3D

##########################
##  Главный инструмент для управления инструментами в режиме BUILD. 
##  Связь с UI.
##########################
## Переключает текущий инструмент - билд, селект, драг

#@onready var GR : GameRoot = $".."
#@onready var world: World = $"../World"

@onready var entity_factory: EntityFactory = $"../EntityFactory"
@onready var entities_root: Node3D = %EntitiesRoot # Здесь лежат сущности




# Инструменты
@onready var build_tool: BuildTool = %BuildTool
@onready var select_tool = %SelectTool
@onready var drag_tool: DragTool = %DragTool
@onready var observe_tool = get_node_or_null('%ObserveTool')
# XX claude-terra 13.3 S2: терморезак. Узел создаётся кодом в _ready (game_root.tscn не правим)
var cut_tool: ThermoCutTool
#@onready var save_controller: SaveManager = %SaveManager



# UI. Единственная связь с UI: ModeController (сигнал смены режима).
# Остальное UI берёт из сигналов ниже (selection_changed, tool_changed, build_selection_cleared),
# а панель инструментов (ToolbarController) сама находит этот узел по группе tool_controller


# Текущий активный инструмент
var active_tool: Node 

## ⚡Сигнал: объект, который показывает инфопанель, сменился (null: ничего)
signal selection_changed(entity: Entity)
## ⚡Сигнал: сменился активный инструмент
signal tool_changed(tool_name: StringName)
## ⚡Сигнал: выбор объекта для стройки снят (UI снимает нажатие с кнопки объекта)
signal build_selection_cleared

## Сущность, о которой сейчас показывается информация (выбранная, призрак стройки)
var current_target: Entity = null



func _ready() -> void:
	add_to_group(&"tool_controller")   # по группе его находит UI (ToolbarController)

	# ⚡Сигнал из моде контроллера
	$"../UI/ModeController".current_mode_changed.connect(on_current_mode_changed)

	# Выбор объекта на панели (select_build_object) и кнопка «Дубль» (duplicate_last_object) подключает
	# сам ToolbarController. Обратные сигналы: BuildTool.last_changed и build_selection_cleared

	# XX claude-terra 13.3 S2: терморезак живёт среди остальных инструментов, но создаётся кодом
	cut_tool = ThermoCutTool.new()
	cut_tool.name = &"ThermoCutTool"
	%Tools.add_child(cut_tool)

	# Инициализируем инструменты, передав им ссылку на себя
	for tool in %Tools.get_children():
		tool.controller = self
		
	# При старте инструмент - select_tool
	switch_tool(select_tool) 



func _unhandled_input(event: InputEvent) -> void:
	# XX claude-terra 13.1.7: Z - показать или скрыть зоны проблем flex (радиус, уклон) в режиме Build
	var kz := event as InputEventKey
	if kz and kz.pressed and not kz.echo and kz.keycode == KEY_Z and Global.current_mode == &'build' \
			and not (kz.ctrl_pressed or kz.alt_pressed or kz.shift_pressed or kz.meta_pressed):
		Global.flex_zones = not Global.flex_zones
		get_viewport().set_input_as_handled()
		return
	# XX claude-terra 13.1.4: V - дубль последнего объекта (в Build, из SelectTool и BuildTool)
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.keycode == KEY_V \
			and not (k.ctrl_pressed or k.alt_pressed or k.shift_pressed or k.meta_pressed):
		duplicate_last_object()
		if build_tool.can_duplicate() and Global.current_mode == &'build':
			get_viewport().set_input_as_handled()
			return
	if active_tool: 
		active_tool.handle_input(event) # Смотрит ввод активного инструмента



func _process(delta: float) -> void:
	if active_tool and active_tool.has_method("process_tick"):
		active_tool.process_tick(delta) # Смотрит тик активного инструмента
	#$"../UI/ModeLabel".text = active_tool.name

var to_drag := false

# Выбор инструмента/tool
func switch_tool(new_tool: Node):
	if active_tool: 
		# При выходе в драг надо без  отмены селект
		var _to_drag = active_tool == $%SelectTool and new_tool == %DragTool
		#to_drag = _to_drag
		active_tool.exit(_to_drag)

	active_tool = new_tool
	Hints.set_tool(active_tool.name)
	tool_changed.emit(active_tool.name)
	active_tool.enter()




# XX claude-terra 13.1.4
## Дубль последнего поставленного объекта. Только в режиме Build и только из SelectTool или BuildTool
## (в драге, Observe и т.п. клавиша ничего не делает)
func duplicate_last_object() -> void:
	if Global.current_mode != &'build' or not build_tool.can_duplicate():
		return
	if active_tool == select_tool or active_tool == build_tool:
		build_tool.duplicate_last()



## Инструменты сообщают, о каком объекте показывать информацию. UI подписан на selection_changed
func publish_selection(entity: Entity) -> void:
	current_target = entity
	selection_changed.emit(entity)



## Выбран объект для стройки (из панели инструментов). null: снять выбор
func select_build_object(setting: EntitySetting) -> void:
	if setting == null :
		# Очищаем селекта в UI если null
		build_selection_cleared.emit()
		return

	# XX claude-terra 13.3 S2: кнопка терморезака включает инструмент, призрака нет. Форма выреза из facet "shape"
	if setting.build_behavior == EntitySetting.BuildBehavior.CUT_TOOL:
		cut_tool.shape = StringName(setting.get_facet(&"shape")) if setting.get_facet(&"shape") != "" else ThermoCutTool.SHAPE_RECT
		switch_tool(cut_tool)
		return

	build_tool.ghost_setting = setting
	# переключение в build_tool
	switch_tool(build_tool)




# ------- MENU -----------
# ⚡Сигнал из toppanel\верхнего меню .
# TODO Можно переносить В сейвменеджер.Это его зона ответсвенности.
#func _on_menu_button_pressed(idx : int) -> void:
	 #Пока все индексы передаем в save контроллер
	#SaveManager.menu_click_handling(idx)



# 💡 --- Общие хелперы для инструментов ---

func get_mouse_ray(mask: int = -1) -> Dictionary:
	var mouse_pos = get_viewport().get_mouse_position()
	var camera = get_viewport().get_camera_3d()
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	#TODO Нужен не только 3 леер
	query.collision_mask = (1) if mask == -1 else mask # Земля (1) и Траки (3-й слой -> маска 4)
	
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# Боковая грань и кромка стола (слой ground) не поверхность: иначе трак или вагон встанет ниже столешницы
	if not hit.is_empty() and hit.collider is CollisionObject3D \
			and (hit.collider.collision_layer & Global.active_layers(['ground'])) != 0 \
			and hit.normal.y < 0.7:
		return {}
	return hit



## Точка луча мыши на плоскости y (по умолчанию уровень стола). Запасной вариант, когда луч не попал в стол:
## например, кнопка спавна на панели находится не над столом
func get_mouse_plane_hit(y := 0.0) -> Dictionary:
	var mouse_pos := get_viewport().get_mouse_position()
	var camera := get_viewport().get_camera_3d()
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	var p = Plane(Vector3.UP, y).intersects_ray(from, dir)
	if p == null:
		return {}
	return {"position": p, "normal": Vector3.UP, "collider": null}


## Луч из камеры в мир (для драга по плоскости, считает сам компонент)
func get_mouse_ray_vec() -> Dictionary:
	var mouse_pos := get_viewport().get_mouse_position()
	var camera := get_viewport().get_camera_3d()
	return {"from": camera.project_ray_origin(mouse_pos), "dir": camera.project_ray_normal(mouse_pos)}
	


## 💡--------------Меняем режим ---------------------------------

func on_current_mode_changed(_new_mode):
	# Global.current_mode уже записал ModeController
	Hints.set_mode(_new_mode)
	# Observe: инструмент без выбора и драга. Выход из прежнего инструмента сам снимает выделение и призрака
	if observe_tool:
		if _new_mode == &'observe':
			switch_tool(observe_tool)
		elif active_tool == observe_tool:
			switch_tool(select_tool)


### Получаем текущий current mode
#func get_current_mode() -> StringName:
	#return GR.current_mode


### Получаем текущий debug_mode
#func get_debug_mode() -> bool:
	#return GR.debug_mode
