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
var water_tool: WaterPourTool   # XX claude-terra 13.4 W3
var plaster_tool: PlasterTool   # XX claude-terra 13.5 G3
var paint_tool: PaintTool   # XX claude-terra 13.13 K2
var field_tool: FieldTool   # XX claude-terra 13.14 H1b
var brush_tool: BrushTool   # XX claude-terra 13.14 H2
var wire_tool: WireTool   # D4 (ATTN_10): провода между клеммами
var wiring_view: WiringView   # XX claude-wire W3: вид «Монтаж» внутри Operate (плита, пути)
var table_tool: TableTool   # XX claude-table T2: постановка секций подмакетника (режим «Секции»)
#@onready var save_controller: SaveManager = %SaveManager



# UI. Единственная связь с UI: ModeController (сигнал смены режима), его находим по группе mode_controller.
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

	# ⚡Сигнал из моде контроллера. По группе, а не по пути: узел UI можно переносить (U8);
	# в группу ModeController входит в _enter_tree, то есть раньше любого _ready
	var mode_node := get_tree().get_first_node_in_group(&"mode_controller")
	if mode_node:
		mode_node.current_mode_changed.connect(on_current_mode_changed)
	else:
		push_error("ToolController: ModeController не найден (группа mode_controller)")

	# Выбор объекта на панели (select_build_object) и кнопка «Дубль» (duplicate_last_object) подключает
	# сам ToolbarController. Обратные сигналы: BuildTool.last_changed и build_selection_cleared

	# XX claude-terra 13.3 S2: терморезак живёт среди остальных инструментов, но создаётся кодом
	cut_tool = ThermoCutTool.new()
	cut_tool.name = &"ThermoCutTool"
	%Tools.add_child(cut_tool)
	water_tool = WaterPourTool.new()
	water_tool.name = &"WaterPourTool"
	%Tools.add_child(water_tool)
	plaster_tool = PlasterTool.new()
	plaster_tool.name = &"PlasterTool"
	%Tools.add_child(plaster_tool)
	paint_tool = PaintTool.new()
	paint_tool.name = &"PaintTool"
	%Tools.add_child(paint_tool)
	field_tool = FieldTool.new()
	field_tool.name = &"FieldTool"
	%Tools.add_child(field_tool)
	brush_tool = BrushTool.new()
	brush_tool.name = &"BrushTool"
	%Tools.add_child(brush_tool)
	wire_tool = WireTool.new()
	wire_tool.name = &"WireTool"
	%Tools.add_child(wire_tool)
	table_tool = TableTool.new()
	table_tool.name = &"TableTool"
	%Tools.add_child(table_tool)

	# Инициализируем инструменты, передав им ссылку на себя
	for tool in %Tools.get_children():
		tool.controller = self

	# XX claude-wire W3: вид режима «Монтаж» (узел не инструмент, лежит рядом с ними)
	wiring_view = WiringView.new()
	wiring_view.name = &"WiringView"
	wiring_view.entities_root = entities_root
	add_child(wiring_view)
	wiring_view.active_changed.connect(func(_on: bool) -> void: select_tool.on_mode_changed())   # выбор, которого в новом виде быть не может, снимается
		
	# При старте инструмент - select_tool
	switch_tool(select_tool) 



func _unhandled_input(event: InputEvent) -> void:
	# U10: пока открыто модальное окно, клавиши (Delete, V, Z...) инструментам не идут
	if UIPointer.modal_open():
		return
	# H: включить или выключить подсказки внизу экрана (в Observe H прячет интерфейс, там это делает камера)
	if Global.current_mode != &'observe' and Actions.pressed(event, &"hints_toggle"):
		Hints.set_enabled(not Hints.enabled)
		get_viewport().set_input_as_handled()
		return
	# XX claude-terra 13.1.7: Z - показать или скрыть зоны проблем flex (радиус, уклон) в режиме Build
	if Actions.pressed(event, &"flex_zones_toggle") and Global.current_mode == &'build':
		Global.flex_zones = not Global.flex_zones
		get_viewport().set_input_as_handled()
		return
	# XX claude-terra 13.1.4: V - дубль последнего объекта (в Build, из SelectTool и BuildTool)
	if Actions.pressed(event, &"duplicate_last"):
		duplicate_last_object()
		if build_tool.can_duplicate() and _duplicate_mode_ok():   # XX claude-coaster C6.1
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
	if not _duplicate_mode_ok():   # XX claude-coaster C6.1: Build и Coaster
		return
	if active_tool != select_tool and active_tool != build_tool:
		return
	if not LYM.has_table():   # XX claude-table T4c
		LYM.notice.emit(LYM.EMPTY_NOTE)
		return
	# Выбран объект: дублируем его (копия на курсоре), иначе последний поставленный
	var sel := selected_for_duplicate()
	if sel != null:
		var sel_idc := sel.get_comp(C_Identity) as C_Identity
		if sel_idc != null and duplicate_fits_mode(sel_idc.setting, Global.current_mode):
			build_tool.duplicate_entity(sel)
	elif build_tool.can_duplicate() and duplicate_fits_mode(build_tool.last_setting, Global.current_mode):
		build_tool.duplicate_last()


## XX claude-coaster C6.1: дубль и клавиша V работают в Build и в Coaster
func _duplicate_mode_ok() -> bool:
	return Global.current_mode == &'build' or Global.current_mode == &'coaster'


## XX claude-coaster C6.1: в Coaster копируется только объект горок, в Build объект горок не копируется
## (категории режима в CatalogMeta.MODE_CATEGORIES). Без этого V в Coaster ставила бы последний рельс из Build, и наоборот
static func duplicate_fits_mode(setting: EntitySetting, mode: StringName) -> bool:
	if setting == null:
		return false
	var coaster_cats: Array = CatalogMeta.MODE_CATEGORIES.get(&"coaster", [])
	return coaster_cats.has(setting.category) == (mode == &'coaster')


## Что дублировать по V и кнопке «Дубль»: выбранный в SelectTool настоящий объект (не призрак) с паспортом. null: ничего
func selected_for_duplicate() -> Entity:
	if active_tool != select_tool:
		return null
	var e: Entity = select_tool.selected_entity
	if e == null or not is_instance_valid(e) or e.is_queued_for_deletion() or e.has_comp(C_Ghost):
		return null
	var idc := e.get_comp(C_Identity) as C_Identity
	if idc == null or idc.setting == null:
		return null
	return e



## Инструменты сообщают, о каком объекте показывать информацию. UI подписан на selection_changed
func publish_selection(entity: Entity) -> void:
	current_target = entity
	selection_changed.emit(entity)



## Выбран объект для стройки (из панели инструментов). null: снять выбор
## variant: исполнение модели из Library (ATTN_22): призрак и поставленный объект получают его. Пусто: вид по умолчанию
## Состав из шаблона, который только что появился и сразу тащится: {"entities", "parts"}. Кладет BuildTool,
## забирает DragTool.enter(): тащится весь состав, а не только схваченная часть (даже на обычных сцепках)
var consist_drag: Dictionary = {}


func select_build_object(setting: EntitySetting, variant: Dictionary = {}) -> void:
	if setting == null :
		# Очищаем селекта в UI если null
		build_selection_cleared.emit()
		return

	# XX claude-table T4c: без секций стола строить нечего, разрешены только пресеты секций
	if setting.category != &"table" and not LYM.has_table():
		LYM.notice.emit(LYM.EMPTY_NOTE)
		build_selection_cleared.emit()
		return

	# Кнопка состава: призрак головной части, остальные части BuildTool ставит по шаблону (ConsistPlacer)
	var consist_setting := setting as ConsistSetting
	if consist_setting != null:
		setting = consist_setting.head

	# XX claude-library L8: кнопка «Мои здания» это обёртка. Ставится общий объект генератора, здание игрока идёт в исполнении
	var building_preset := setting as BuildingPresetSetting
	if building_preset != null:
		variant = building_preset.make_variant()
		setting = building_preset.base

	# XX claude-terra 13.3 S2: кнопка терморезака включает инструмент, призрака нет. Форма выреза из facet "shape"
	if setting.build_behavior == EntitySetting.BuildBehavior.CUT_TOOL:
		cut_tool.shape = StringName(setting.get_facet(&"shape")) if setting.get_facet(&"shape") != "" else ThermoCutTool.SHAPE_RECT
		switch_tool(cut_tool)
		return

	# XX claude-terra 13.4 W3: кнопка «Налить воду» включает WaterPourTool
	if setting.build_behavior == EntitySetting.BuildBehavior.WATER_TOOL:
		switch_tool(water_tool)
		return
	# XX claude-terra 13.5 G3: кнопка «Гипсовый бинт» включает PlasterTool
	if setting.build_behavior == EntitySetting.BuildBehavior.PLASTER_TOOL:
		switch_tool(plaster_tool)
		return

	# XX claude-terra 13.13 K2: кнопка кисти включает PaintTool, класс из facet "brush"
	if setting.build_behavior == EntitySetting.BuildBehavior.PAINT_TOOL:
		paint_tool.brush = PaintTool.brush_from_facet(setting.get_facet(&"brush"))
		switch_tool(paint_tool)
		return

	# XX claude-terra 13.14 H1b: кнопка шпатлёвки включает FieldTool, форма из facet "shape"
	if setting.build_behavior == EntitySetting.BuildBehavior.FIELD_TOOL:
		var fshape := StringName(setting.get_facet(&"shape")) if setting.get_facet(&"shape") != "" else FieldTool.SHAPE_RECT
		field_tool.shape = fshape
		switch_tool(field_tool)
		return

	# XX claude-terra 13.14 H2: кнопка кисти рельефа включает BrushTool, описание кисти это TerrainBrush в components карточки
	if setting.build_behavior == EntitySetting.BuildBehavior.BRUSH_TOOL:
		brush_tool.brush = null
		for comp in setting.components:
			if comp is TerrainBrush:
				brush_tool.brush = comp
				break
		switch_tool(brush_tool)
		return

	# XX claude-table T2: пресет секции (категория table) включает TableTool, режим «Секции»
	if setting.category == &"table":
		table_tool.ghost_setting = setting
		switch_tool(table_tool)
		return

	# D4: кнопка «Провод» включает WireTool
	if setting.build_behavior == EntitySetting.BuildBehavior.WIRE_TOOL:
		switch_tool(wire_tool)
		return

	build_tool.ghost_setting = setting
	build_tool.ghost_variant = variant   # XX claude-library L4
	build_tool.pending_consist = consist_setting   # BuildTool.enter() заберет его после exit() прошлого инструмента
	# переключение в build_tool
	switch_tool(build_tool)




# ------- MENU -----------
# ⚡Сигнал из toppanel\верхнего меню .
# TODO Можно переносить В сейвменеджер.Это его зона ответсвенности.
#func _on_menu_button_pressed(idx : int) -> void:
	 #Пока все индексы передаем в save контроллер
	#SaveManager.menu_click_handling(idx)



# 💡 --- Общие хелперы для инструментов ---

## keep_ground_sides: не отбрасывать боковые грани слоёв ground, water, plaster (нужно выбору и ховеру: бок пенопластового блока наводится)
func get_mouse_ray(mask: int = -1, keep_ground_sides := false) -> Dictionary:
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
			and (hit.collider.collision_layer & Global.active_layers(['ground', 'water', 'plaster'])) != 0 \
			and hit.normal.y < 0.7 and not keep_ground_sides:   # XX claude-terra 13.4: бок воды тоже не поверхность
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
	if _new_mode != &'build':
		select_tool.clear_group()   # XX claude-switch: группа, выбранная рамкой, живет только в Build
	# Observe: инструмент без выбора и драга. Выход из прежнего инструмента сам снимает выделение и призрака
	if observe_tool:
		if _new_mode == &'observe':
			switch_tool(observe_tool)
		elif active_tool == observe_tool:
			switch_tool(select_tool)
	# XX claude-table T1b: режим «Секции» (ящики подмакетника): только выбор, без призрака и инструментов стройки.
	# Выбор, которого в новом режиме быть не может (секция вне «Секции», объект дороги в «Секциях»), снимается
	if active_tool == table_tool and _new_mode != &'sections':
		switch_tool(select_tool)   # TableTool живёт только в режиме «Секции»
	elif _new_mode == &'sections' and active_tool != select_tool:
		switch_tool(select_tool)
	# XX claude-wire W3: вне Operate вид «Монтаж» выключается (плита и пути возвращаются)
	if wiring_view:
		wiring_view.on_mode_changed(_new_mode)
	select_tool.on_mode_changed()


### Получаем текущий current mode
#func get_current_mode() -> StringName:
	#return GR.current_mode


### Получаем текущий debug_mode
#func get_debug_mode() -> bool:
	#return GR.debug_mode
