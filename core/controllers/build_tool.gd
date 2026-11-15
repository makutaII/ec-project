class_name BuildTool extends Node

##########################
## Установка объектов
##########################
## Создает гост по нажатию кнопки, размещает его объекты 


var controller: ToolController

var ghost_setting: EntitySetting # TODO переимновать в entity_setting
## XX claude-library L4: исполнение модели для призрака и поставленных объектов (из Library или копии объекта). Пусто: по умолчанию
var ghost_variant: Dictionary = {}
var ghost : Entity
## Состав из кнопки «Составы» (null: ставится обычный объект). ghost_setting при этом головная часть
var consist: ConsistSetting
## ToolController кладет состав сюда до switch_tool, enter() забирает его в consist
## (exit() предыдущего инструмента consist обнуляет, поэтому напрямую его до switch_tool не ставят)
var pending_consist: ConsistSetting

var rmb_pressed_pos := Vector2.ZERO

# Параметры вращения
## Шаг поворота Q/E задаёт Global.build_options.rot_step_deg (U12)
const ROT_FINE := 5.0 # Градусы, Shift+Q/E (XX claude-terra 13.1.7)

# XX claude-terra: 0 - ставим начало flex, 1 - тянем конец
var stretch_phase := 0

# XX claude-terra T6: тоннельный режим (клавиша U). Новые призраки траков получают C_Tunnel, режим запоминается
var tunnel_mode := false

# XX claude-terra 13.1.4: дубль последнего поставленного объекта (клавиша V, кнопка в панели Build)
## Последний поставленный объект сменился (кнопка дубля включается и показывает имя)
signal last_changed(setting: EntitySetting)
## Что дублировать: настройка последнего объекта и он сам (источник состояния, если еще жив)
var last_setting: EntitySetting
## Стиль исходного трака при дубле выбранного (пусто: стиль сессии). Берется один раз в enter()
var _dup_style: StringName = &""
## XX claude-switch: вращение призрака Alt + мышь и высота Ctrl + мышь (см. DragModifiers)
var _mods := DragModifiers.new()
var last_entity: Entity
## Призрак получил готовую форму (flex): фазу растягивания пропускаем, ставится одним кликом
var preshaped := false
var _dup_pending := false


func _ready() -> void:
	add_child(_mods)   # XX claude-switch: DragModifiers слушает мышь через _input, ему нужно быть в дереве


func enter():
	consist = pending_consist
	pending_consist = null
	stretch_phase = 0
	preshaped = false   # XX claude-terra 13.1.4
	_mods.reset()
	if ghost: ghost.queue_free()
	# Дубль выбранного трака берет его стиль, остальные призраки стиль сессии (пустой запрос)
	ghost = controller.entity_factory.create_from_setting(ghost_setting, _dup_style if _dup_pending else &"", ghost_variant)
	_dup_style = &""
	# Стиль сессии сменили, пока призрак в руке: перестроить в новом стиле (ATTN_17 §17.13)
	if not TSM.current_changed.is_connected(_on_track_style_changed):
		TSM.current_changed.connect(_on_track_style_changed)

	match ghost_setting.build_behavior:
		EntitySetting.BuildBehavior.GHOST_PLACE:
			_enter_ghost_place()
		EntitySetting.BuildBehavior.SPAWN_AND_DRAG:
			_enter_spawn_and_drag()
		EntitySetting.BuildBehavior.PLACE_THEN_STRETCH:   # XX claude-terra
			_enter_ghost_place()
		EntitySetting.BuildBehavior.DRAW_POLYGON:   # XX claude-terra 13.2 B2: лист любой формы, вершины кликами
			_enter_ghost_place()
			ghost.add_component(C_PolygonDraw.new())
		EntitySetting.BuildBehavior.DRAW_STRIP:   # XX claude-terra 13.2 B5: лист-полоса по ломаной
			_enter_ghost_place()
			var strip_draw := C_PolygonDraw.new()
			strip_draw.strip = true
			ghost.add_component(strip_draw)

	# XX claude-terra 13.1.4: призрак-дубль получает состояние последнего объекта
	if _dup_pending:
		_dup_pending = false
		_apply_duplicate_state()
	# XX claude-terra 13.2 B2: подсказки рисования полигона (у дубля с готовой формой их нет)
	var _strip := _draw_active() and _poly().strip
	Hints.set_context(&"polygon", _draw_active() and not _strip)
	Hints.set_context(&"strip", _strip)


func _enter_ghost_place() -> void:
	controller.entities_root.add_child(ghost)
	ghost.name = 'ghost'
	ghost.add_component(C_Ghost.new())
	ghost.send_event("on_select_layer", {'enabled': true})
	if tunnel_mode:   # XX claude-terra T6: у не-траков события никто не слушает
		ghost.send_event("on_tunnel_set", {"on": true})
	controller.publish_selection(ghost)



func _enter_spawn_and_drag() -> void:
	controller.entities_root.add_child(ghost)      # сначала в дерево
	var hit = controller.get_mouse_ray(_pick_mask())   # XX claude-terra
	if hit.is_empty():
		hit = controller.get_mouse_plane_hit()   # кнопка спавна не над столом
	if hit:
		ghost.send_event("on_drag_moved", hit)     # теперь get_tree() есть
	# Состав вагонов: остальные части появляются сразу и тащатся группой (DragTool)
	if consist != null:
		var parts_entities := ConsistPlacer.spawn_loose(consist, ghost, controller.entity_factory, controller.entities_root)
		controller.consist_drag = {"entities": parts_entities, "parts": consist.template.parts}
	controller.select_tool.set_selection(ghost)
	_remember(ghost_setting, null)   # XX claude-terra 13.1.4: состояния нет, дубль = еще одна копия
	ghost = null
	controller.to_drag = true
	controller.switch_tool(controller.select_tool)



func handle_input(event: InputEvent):
	if not ghost: return

	# XX claude-terra 13.2 B2: пока рисуем полигон листа, ввод ведет отдельная функция
	if _draw_active():
		_handle_draw_input(event)
		return

	#  ПКМ 
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			rmb_pressed_pos = event.position
		else:
			# Отменяем билд режим если это был короткий клик (не драг камеры)
			if rmb_pressed_pos.distance_to(event.position) < 5:
				if stretch_phase == 1:   # XX claude-terra: ПКМ в фазе конца - отмена, новый призрак
					enter()
				else:
					controller.switch_tool(controller.select_tool)

	# Транслируем намерение покрутить
	# XX claude-terra 13.1.7: Shift+Q/E поворот на ROT_FINE (5°), без Shift шаг из Global.build_options (U12)
	var _shift := Actions.shift()
	var _rot := ROT_FINE if _shift else Global.build_options.rot_step_deg
	# XX claude-switch: по событию клавиши, как в DragTool (опрос Input.is_action_just_pressed срабатывал на любом событии кадра)
	if Actions.pressed_shift_ok(event, &"rotate_left"):
		ghost.send_event("on_rotate_input", {"axis": "y", "amount": _rot})
	if Actions.pressed_shift_ok(event, &"rotate_right"):
		ghost.send_event("on_rotate_input", {"axis": "y", "amount": -_rot})
	# XX claude-terra 13.1.4: с Shift R/F идут крупным шагом через ElevationInput, обычный шаг без Shift
	if Actions.pressed_shift_ok(event, &"level_up") and not _shift:
		ghost.send_event("on_rotate_input", {"axis": "x", "amount": Global.build_options.rot_step_deg})
	if Actions.pressed_shift_ok(event, &"level_down") and not _shift:
		ghost.send_event("on_rotate_input", {"axis": "x", "amount": -Global.build_options.rot_step_deg})
	# XX claude-terra 13.1.4: Shift+R/F и PageUp/PageDown, крупный шаг уровня
	var _levels := ElevationInput.levels_from_event(event)
	if _levels != 0:
		ghost.send_event("on_elevation_input", {"levels": _levels})

	# XX claude-terra T6: тоннельный режим. Трак с флагом может уходить под листы пенопласта
	if Actions.pressed(event, &"tunnel_toggle") and ghost.has_comp(C_Path):
		tunnel_mode = not tunnel_mode
		ghost.send_event("on_tunnel_set", {"on": tunnel_mode})

	# Переключатель контроля лимитов flex
	if Actions.pressed(event, &"flex_limits_toggle"):
		Global.flex_limits = not Global.flex_limits
		ghost.send_event("on_flex_limits_changed", {})
		
		
	# ЛКМ - Построить
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		
		if ghost.has_comp(C_Blocked) or ghost.has_comp(C_Invalid):   # XX claude-terra
			return # Не строим, если гост красный (пересекается с чем-то / невалидная форма)

		# XX claude-terra: flex ставится в две фазы, тул только шлет события
		# 13.1.4: призрак-дубль flex уже имеет форму, растягивать нечего
		var _stretch := ghost_setting.build_behavior == EntitySetting.BuildBehavior.PLACE_THEN_STRETCH and not preshaped
		if _stretch and stretch_phase == 0:
			stretch_phase = 1
			ghost.send_event("on_stretch_started", {})
			return
		if _stretch:
			ghost.send_event("on_stretch_ended", {})

		# Состав: места частей считаем до постановки. Не помещается на путь: не ставим (призрак красный)
		var consist_snap := _consist_snap()
		if consist != null and ConsistPlacer.plan(consist, ghost, consist_snap).is_empty():
			return

		# 1. Спавним реальный объект и получаем ссылку на него
		var spawned_entity = _place_real_object()
		if consist != null and spawned_entity:
			ConsistPlacer.spawn(consist, spawned_entity, consist_snap, controller.entity_factory, controller.entities_root)
		if _stretch and spawned_entity:
			enter()   # новый призрак: можно продолжать от свободного конца
			return
		if preshaped and spawned_entity:   # XX claude-terra 13.1.4: следующая копия с той же формой
			_dup_pending = true
			enter()
			return
		
		if not spawned_entity:
			return



## Клонирование госта по лкм
func _place_real_object() -> Entity:

	if ghost.has_comp(C_Blocked):# Не строим, если гост красный
		return null
		
	# Запрашиваем у фабрики создание реального объекта на основе настроек госта.
	# style_id госта: объект встанет в том же стиле, что показывал призрак
	var real_entity = controller.entity_factory.create_from_setting(ghost_setting, ghost.style_id, ghost.variant)
	
	# Ставим реальный объект точно в ту же позицию и поворот, где сейчас гост
	real_entity.global_transform = ghost.global_transform
	
	# Добавляем в дерево (в рут сущностей)
	controller.entities_root.add_child(real_entity)
	
	# 💥 Тул приказывает госту клонировать стейт. draggable выполнит:
	ghost.send_event("on_clone_state_to", {"target": real_entity})
	#real_entity.send_event("on_drag_ended", {})
	_remember(ghost_setting, real_entity)   # XX claude-terra 13.1.4
	return real_entity


## Посадка призрака головной части на трак (для расчёта мест остальных частей состава). Пусто: не на рельсах
func _consist_snap() -> Dictionary:
	if consist == null or ghost == null:
		return {}
	var dr := ghost.get_comp(C_TrainDraggable) as C_TrainDraggable
	if dr == null or not dr.is_snapped_to_track or not is_instance_valid(dr.current_track):
		return {}
	return {"track": dr.current_track, "offset": dr.current_curve_point, "route": dr.current_route}


## Призрак состава красный, пока состав не помещается на путь (головная не на рельсах или путь кончился)
func _update_consist_fit() -> void:
	if consist == null or ghost == null:
		return
	var fits := not ConsistPlacer.plan(consist, ghost, _consist_snap()).is_empty()
	if not fits and not ghost.has_comp(C_Invalid):
		ghost.add_component(C_Invalid.new())
	elif fits and ghost.has_comp(C_Invalid):
		ghost.remove_component(C_Invalid)


# XX claude-terra 13.2 B2 ===== Рисование полигона листа (DRAW_POLYGON) =====

## Компонент рисования на призраке (null: призрак не из DRAW_POLYGON)
func _poly() -> C_PolygonDraw:
	if ghost == null or not is_instance_valid(ghost):
		return null
	return ghost.get_comp(C_PolygonDraw) as C_PolygonDraw


## Рисуем сами (не дубль с готовой формой): ввод идет в _handle_draw_input
func _draw_active() -> bool:
	var d := _poly()
	return d != null and not d.preshaped


## Ввод рисования. ЛКМ: первая вершина, следующие, замыкание кликом по первой вершине. Enter замыкает,
## Backspace убирает вершину, ПКМ сбрасывает рисунок (без вершин выходит в SelectTool).
## R/F, Shift+R/F, PgUp/PgDn: уровень (до первого клика маркер идет через C_TerrainDraggable). Ctrl+R/F: толщина.
## Q/E не работают: yaw листа при рисовании всегда 0, повернуть готовый лист можно в драге
func _handle_draw_input(event: InputEvent) -> void:
	var d := _poly()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			rmb_pressed_pos = event.position
		elif rmb_pressed_pos.distance_to(event.position) < 5:
			if d.drawing:
				enter()   # сброс рисунка: новый призрак-маркер
			else:
				controller.switch_tool(controller.select_tool)
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if not d.drawing:
			if ghost.has_comp(C_Blocked) or ghost.has_comp(C_Invalid):
				return   # маркер на чужом листе того же уровня
			d.begin()
		elif d.is_closing():
			_close_polygon()
		else:
			d.add_vertex()
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if Actions.pressed(event, &"shape_confirm"):
		if d.drawing:
			_close_polygon()
		return
	if Actions.pressed(event, &"shape_undo"):
		d.undo_vertex()
		return

	# ширина полосы: [ и ] (физические клавиши, раскладка не важна), Shift ×5
	var w := Actions.axis_step(event, &"width_up", &"width_down", 5)
	if w != 0:
		if d.strip:
			d.add_width(Global.settings.terrain_grid_step * w)
		return

	# толщина (Ctrl) или уровень
	var dz := ElevationInput.depth_from_event(event)
	if dz != 0:
		d.add_levels(dz)
		return
	var n := ElevationInput.step_from_event(event)
	if n == 0:
		return
	if d.drawing:
		d.elevate(n)
	else:
		ghost.send_event("on_elevation_input", {"levels": n})


## Замкнуть контур и поставить лист. Следом новый призрак: можно рисовать следующий лист
func _close_polygon() -> void:
	var d := _poly()
	if d == null or not d.try_close():
		return
	if _place_real_object():
		enter()


# XX claude-terra 13.1.4 ===== Дубль последнего объекта =====

func _remember(setting: EntitySetting, entity: Entity) -> void:
	last_setting = setting
	last_entity = entity
	last_changed.emit(setting)


func can_duplicate() -> bool:
	return last_setting != null


## Дубль ВЫБРАННОГО объекта: призрак той же настройки на курсоре с состоянием исходного (поворот, уровень, форма flex)
## и со стилем исходного трака. Исходный становится «последним»: следующая V тоже копирует его
func duplicate_entity(e: Entity) -> void:
	var idc := e.get_comp(C_Identity) as C_Identity
	if idc == null or idc.setting == null:
		return
	_dup_style = e.style_id
	_remember(idc.setting, e)
	duplicate_last()


## ⚡Сигнал TSM: стиль сессии сменился. Призрак трака, следующий сессии, пересобирается в новом стиле
## с тем же состоянием (поворот, уровень). Не трогаем призрак, который уже тянут (flex), с готовой формой
## и рисуемый полигон: он поставится в прежнем стиле (стиль берётся у призрака, а не у сессии)
func _on_track_style_changed(id: StringName) -> void:
	if ghost == null or ghost_setting == null or ghost.style_id == &"" or ghost.style_id == id:
		return
	if stretch_phase != 0 or preshaped or _draw_active():
		return
	var old := ghost
	enter()   # старый призрак освобождается внутри, новый строится в активном стиле
	if ghost != null and is_instance_valid(old):
		old.send_event("on_clone_state_to", {"target": ghost})


## Новый призрак того же объекта с тем же состоянием (поворот, уровень, форма flex). Работает из SelectTool
## и из BuildTool. Источник состояния - сам последний объект (его on_clone_state_to работает так же, как у призрака).
## Если его уже удалили, получится обычный свежий призрак той же настройки
func duplicate_last() -> void:
	if last_setting == null:
		return
	consist = null   # дубль копирует одну поставленную часть, не весь состав
	ghost_setting = last_setting
	# XX claude-library L4: копия берет исполнение исходного объекта (если он жив)
	ghost_variant = last_entity.variant.duplicate(true) if is_instance_valid(last_entity) else {}
	_dup_pending = true
	if controller.active_tool == self:
		enter()
	else:
		controller.switch_tool(self)


func _apply_duplicate_state() -> void:
	if ghost == null or not is_instance_valid(last_entity) or last_entity.is_queued_for_deletion() \
			or not last_entity.is_inside_tree():
		return
	if ghost.has_comp(C_Path):   # тоннельный флаг копии совпадает с исходным, режим U подстраиваем
		tunnel_mode = last_entity.has_comp(C_Tunnel)
		ghost.send_event("on_tunnel_set", {"on": tunnel_mode})
	last_entity.send_event("on_clone_state_to", {"target": ghost})
	if ghost.has_comp(C_FlexShape):
		preshaped = true
		ghost.send_event("on_preshaped_set", {})



# XX claude-terra
func _pick_mask() -> int:
	return Global.active_layers(ghost_setting.get_pick_layers())



func process_tick(_delta):
	# XX claude-terra 13.2 B2: после первого клика курсор ведет горизонтальная плоскость на высоте призрака (D5)
	if ghost and _draw_active() and _poly().drawing:
		var plane_hit := controller.get_mouse_plane_hit(ghost.global_position.y)
		if not plane_hit.is_empty():
			_poly().set_cursor(plane_hit.position)
		return
	# XX claude-switch: пока зажат Alt (вращение) или Ctrl (высота), призрак стоит на месте, позицию не обновляем.
	# Не во время растягивания flex и не у листа, который рисуется по вершинам: там Ctrl+R/F это толщина, а Alt вращать нечего
	if ghost and stretch_phase == 0 and not _draw_active() and _mods.tick(ghost, controller.get_viewport()):
		return
	#var hit = controller.get_mouse_ray((1 << 0) | (1 << 2)|(1 << 4))
	# XX claude-terra слои из EntitySetting.pick_layers
	var hit = controller.get_mouse_ray(_pick_mask()) 
	
	if hit and ghost:
		# Отправляем приказ в сущность. Оттуда C_TrackDraggable сам разберется
		if stretch_phase == 1:   # XX claude-terra
			ghost.send_event("on_stretch_moved", hit)
		else:
			_mods.remember(hit)   # XX claude-switch: позиция призрака (нужна при Alt и Ctrl)
			ghost.send_event("on_drag_moved", hit)
			_update_consist_fit()




## Выполняется при выходе из инстр.
func exit(_to_drag : bool = false):
	_mods.reset()   # XX claude-switch: вернуть курсор, если вышли из инструмента при зажатом Alt или Ctrl
	consist = null
	if TSM.current_changed.is_connected(_on_track_style_changed):
		TSM.current_changed.disconnect(_on_track_style_changed)
	Hints.set_context(&"polygon", false)   # XX claude-terra 13.2 B2
	Hints.set_context(&"strip", false)
	if ghost:
		ghost.queue_free()
		ghost = null
		
	
	# Очищаем селекта в UI (null)
	controller.select_build_object(null)
	
	#INFO ОЧИЩАЕМ ПАНЕЛЬ!
	controller.publish_selection(null)



# find_snap перенесен из snap_service. Но он вообще не нужен... пока. Может потом для power 
func _find_snap(dragging_entity: Entity, _mouse_pos: Vector3) -> Dictionary:
	# Если сокеты есть, идем дальше
	var c_socket = dragging_entity.get_comp(C_Socket)
	if not c_socket: 
		return {"is_snapped": false}
	
	var best_snap = {
		"is_snapped": false,
		"target_socket": {
			"position": 0,
			"direction":0
		},
		"dragging_socket": 0
	}
					
	return best_snap
