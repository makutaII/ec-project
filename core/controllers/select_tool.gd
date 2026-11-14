class_name SelectTool extends Node

##########################
## Выбор и Ховер объектов
##########################

var controller: ToolController
var hovered_entity: Entity
var selected_entity: Entity

# Флаги для инпута

var clicked_entity: Entity = null

var lmb_start_pos := Vector2.ZERO
var rmb_start_pos := Vector2.ZERO

# флаги точек флекс-трака
var lmb_consumed := false   # нажатие забрал компонент (ручка / добавление изгиба)
var rmb_consumed := false
var handle_dragging := false

# XX claude-switch: выделение рамкой. Шаг 1: выбрать группу (по категориям) и удалить. Только режим Build
const MARQUEE_MIN_PX := 8.0   # рамка начинается, когда мышь ушла дальше этого от точки нажатия
var _group := GroupSelection.new()
var _marquee_armed := false   # ЛКМ нажата на пустом месте (или с Ctrl): может начаться рамка
var _marquee_active := false  # рамка тянется
var _marquee_start := Vector2.ZERO
var _marquee_additive := false   # рамка с Shift: добавляет к группе
var _shift_press := false        # ЛКМ нажата с Shift (Build): клик переключает объект в группе, драг добавляет рамкой
var _shift_click: Entity         # объект под курсором в момент нажатия с Shift (null: пустое место)
var _group_drag_candidate: Entity   # член группы под курсором в момент нажатия (без Shift/Ctrl): драг потащит всю группу
const GROUP_MOVABLE: Array[StringName] = [&"track", &"building"]   # категории, которые группа умеет двигать
var _group_layer: CanvasLayer
var _marquee: MarqueeOverlay
var _tooltip: InfoToolTip
# XX claude-table T2: сообщения подмакетника (отказ убрать секцию, высота стола) наверху экрана
var _note: Label
var _note_gen := 0

func _ready() -> void:
	_ensure_group_ui()
	LYM.notice.connect(_show_note)


func enter():

	if selected_entity and controller.to_drag:
		#INFO ДЕРГАЕМ ПАНЕЛЬ!
		controller.publish_selection(selected_entity)
		controller.to_drag = false
		_start_drag(selected_entity)

		




func process_tick(_delta):
	if handle_dragging and selected_entity:
		selected_entity.send_event("on_handle_drag", controller.get_mouse_ray_vec())
	else:
		_update_hover()



func handle_input(event: InputEvent):
	# XX claude-table T2: в режиме «Секции» R/F (Shift, PgUp/PgDn) меняют высоту стола
	if Global.current_mode == &'sections':
		var n := ElevationInput.step_from_event(event)
		if n != 0:
			LYM.step_height(n)
			return
	# --- ПКМ: Обработка (Отмена vs Камера) ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			rmb_start_pos = event.position
			rmb_consumed = _try_handle_remove()
		else:
			if rmb_consumed:
				rmb_consumed = false
				return
			if rmb_start_pos.distance_to(event.position) < 5:
				_clear_selection()
		return

	# --- ЛКМ: Нажатие ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			lmb_start_pos = event.position
			lmb_consumed = _try_press_lever() or _try_handle_press()   # XX claude-switch: рычаг стрелки
			if lmb_consumed:
				return
			clicked_entity = _get_entity_under_mouse()
			# XX claude-switch: рамка начинается на пустом месте, с зажатым Ctrl (поверх объектов и листов террейна) или с Shift.
			# Shift: клик без драга переключает объект в группе, драг добавляет объекты рамки к группе
			_marquee_armed = false
			_marquee_active = false
			_marquee_additive = false
			_shift_press = false
			_shift_click = null
			_group_drag_candidate = null
			var in_build: bool = Global.current_mode == &'build'
			var shift: bool = in_build and Actions.shift()
			# Нажатие на члене группы без модификаторов: группа остается, драг потащит ее всю, клик без драга выберет только его.
			# Рамку при этом не взводим: иначе она начнется на 8 px, раньше драга на 10 px, и снимет группу
			if in_build and clicked_entity != null and not shift and not Actions.ctrl() and _group.has_member(clicked_entity):
				_group_drag_candidate = clicked_entity
				clicked_entity = null
			if in_build and _group_drag_candidate == null and (clicked_entity == null or shift or Actions.ctrl()):
				_marquee_armed = true
				_marquee_start = event.position
				if shift:
					_shift_press = true
					_marquee_additive = true
					_shift_click = clicked_entity
					clicked_entity = null
				elif Actions.ctrl():
					clicked_entity = null   # Ctrl+ЛКМ только рамка, объект под курсором не выбираем
			if clicked_entity:
				set_selection(clicked_entity)
		else:
			# XX claude-switch: рамка отпущена, собираем группу
			if _marquee_active:
				_finish_marquee(event.position)
				_marquee_armed = false
				_marquee_active = false
				_shift_press = false
				_shift_click = null
				clicked_entity = null
				return
			_marquee_armed = false
			if _group_drag_candidate != null:
				# Клик без драга по члену группы: выбираем только его
				var one := _group_drag_candidate
				_group_drag_candidate = null
				if is_instance_valid(one):
					set_selection(one)
				clicked_entity = null
				return
			if _shift_press:
				# Shift+клик без драга: переключить объект в группе (по пустому месту ничего не меняет)
				_shift_press = false
				if _shift_click != null and is_instance_valid(_shift_click):
					_toggle_in_group(_shift_click)
				_shift_click = null
				clicked_entity = null
				return
			if lmb_consumed:
				if handle_dragging and selected_entity:
					selected_entity.send_event("on_handle_released", {})
				handle_dragging = false
				lmb_consumed = false
				return
			if not clicked_entity and lmb_start_pos.distance_to(event.position) < 5:
				_clear_selection()
			clicked_entity = null

	# XX claude-switch: рамка тянется
	if event is InputEventMouseMotion and _marquee_armed and Input.is_action_pressed("lmb"):
		if not _marquee_active and _marquee_start.distance_to(event.position) > MARQUEE_MIN_PX:
			_marquee_active = true
			clicked_entity = null
			if _marquee_additive:
				_seed_group_from_single()   # Shift: одиночный выбор входит в группу
			else:
				_clear_selection()   # группа заменяет одиночный выбор
		if _marquee_active:
			_marquee.set_rect(Rect2(_marquee_start, Vector2.ZERO).expand(event.position))

	# XX claude-switch: протащили член группы: двигаем всю группу
	if event is InputEventMouseMotion and Input.is_action_pressed("lmb") and _group_drag_candidate != null:
		if lmb_start_pos.distance_to(event.position) > 10:
			var leader := _group_drag_candidate
			_group_drag_candidate = null
			if is_instance_valid(leader):
				_start_group_drag(leader)
			return

	# --- ЛКМ: Движение (Переход в Драг) ---
	if event is InputEventMouseMotion and Input.is_action_pressed("lmb"):
		if clicked_entity and clicked_entity == selected_entity and Global.current_mode != &'sections':   # XX claude-table T2: секции не таскаем, их ставит TableTool
			# Если протащили достаточно далеко — включаем инструмент перетаскивания
			if lmb_start_pos.distance_to(event.position) > 10:
				_start_drag(clicked_entity)
				clicked_entity = null

	# XX claude-switch: Del удаляет группу, выбранную рамкой, а без группы выбранный объект.
	# По событию клавиши (Actions.pressed), а не опросом Input.is_action_just_pressed: опрос был истинен на любом событии кадра,
	# в том числе на движении мыши, и срабатывал, когда Del уже забрал LineEdit, а также на Shift+Del и Ctrl+Del
	if Actions.pressed(event, &"delete"):
		_delete_selection()
		return
	# XX claude-terra 13.2 B6: B - автонасыпь под выбранным траком и цепочкой за ним (только Build)
	if selected_entity and Actions.pressed(event, &"embankment_toggle") \
			and Global.current_mode == &'build' and selected_entity.has_comp(C_Path):
		Embankment.build(selected_entity, controller)

		
	# XX claude-terra T6: тоннельный флаг выбранного трака (у не-траков события никто не слушает)
	if selected_entity and Actions.pressed(event, &"tunnel_toggle"):
		selected_entity.send_event("on_tunnel_toggle", {})
	# XX claude-terra 13.13 K5: стиль портала (у не-тоннельных траков события никто не слушает)
	if selected_entity and Actions.pressed(event, &"tunnel_portal"):
		selected_entity.send_event("on_portal_cycle", {})

	if selected_entity and Actions.pressed(event, &"wagon_kick_fwd"):
		selected_entity.send_event("on_train_kicked", {"power_kick": 10.0}) # Пинок силой 10m\s
	if selected_entity and Actions.pressed(event, &"wagon_kick_back"):
		selected_entity.send_event("on_train_kicked", {"power_kick": -10.0}) # Пинок силой 10m\s



## Del: группа, выбранная рамкой, иначе одиночный выбор. Группа проверяется первой и только по живым членам (GroupSelection.clear
## чистит members), поэтому после клика по другому объекту Del удаляет именно его, а не прежнюю рамку
func _delete_selection() -> void:
	if not _group.members.is_empty():
		_delete_group()
	elif selected_entity != null and is_instance_valid(selected_entity):
		_delete_single(selected_entity)


func _delete_group() -> void:
	var removed := 0
	for e in _group.take_members():
		if e.is_queued_for_deletion():
			continue   # уже ушел вместе с вечной группой соседа
		_kill_entity(e)
		removed += 1
	if removed > 0:
		_show_note("Удалено объектов: %d" % removed)


func _delete_single(e: Entity) -> void:
	_kill_entity(e)
	# kill_me может отказать (секция с объектами на ней, LYM.notice скажет почему): тогда выбор остается как был
	if e.is_queued_for_deletion():
		selected_entity = null
		Hints.set_context(&"selected", false)
		Hints.set_context(&"switch", false)
		#INFO ДЕРГАЕМ ПАНЕЛЬ!
		controller.publish_selection(null)


## Убрать объект. Вечная группа (паровоз с тендером, секции) уходит целиком, как при одиночном Del
func _kill_entity(e: Entity) -> void:
	var coupler := e.get_comp(C_Coupler) as C_Coupler
	if coupler != null:
		for member in coupler.get_permanent_group():
			if member != e and is_instance_valid(member):
				member.kill_me()
	e.kill_me()   # entity сама почистит за собой


## XX claude-table T1b: что можно выбрать в текущем режиме. Секции стола (ящики) выбираются только в режиме «Секции»,
## а в нём не выбирается ничего, кроме секций. В остальных режимах секция для выбора и рамки не существует
func _is_pickable(e: Entity) -> bool:
	return e != null and e.has_comp(C_TableSection) == (Global.current_mode == &'sections')


## Смена режима (зовёт ToolController): выбор и ховер, которых в новом режиме быть не может, снимаются
func on_mode_changed() -> void:
	if selected_entity != null and (not is_instance_valid(selected_entity) or not _is_pickable(selected_entity)):
		_clear_selection()
	if hovered_entity != null and (not is_instance_valid(hovered_entity) or not _is_pickable(hovered_entity)):
		if is_instance_valid(hovered_entity):
			hovered_entity.remove_component(C_Hovered)
		hovered_entity = null


func _get_entity_under_mouse() -> Entity:
	# Слой земли(1), траков(3), трейна(5), селектеда(11)- 11 это гост!
	
	#var hit = controller.get_mouse_ray((1 << 0) | (1 << 2) |(1 << 4)| (1 << 10)) 
	var hit = _pick_ray()
	if hit and hit.collider:
		var e = _find_entity(hit.collider)
		return e if _is_pickable(e) else null   # XX claude-table T1b: чужое под курсором это пустое место
	return null


## XX claude-terra 13.4. Луч выбора: как раньше, плюс вода. Трак и вагон выбираются сквозь воду;
## воду берём, если она ближе земли (стола, листа) под ней или земли нет
func _pick_ray() -> Dictionary:
	# XX claude-table T1b: в режиме «Секции» смотрим только плиту (вагон или трак на ней не заслоняют её)
	if Global.current_mode == &'sections':
		return controller.get_mouse_ray(Global.active_layers(['ground', 'ghost']))
	var hit: Dictionary = controller.get_mouse_ray(Global.active_layers(['ground','tracks','trains','ghost','power']))
	if not hit.is_empty() and hit.collider is CollisionObject3D \
			and (hit.collider.collision_layer & Global.active_layers(['ground'])) == 0:
		return hit
	var w: Dictionary = controller.get_mouse_ray(Global.active_layers(['water']))
	if w.is_empty():
		return hit
	var cam := get_viewport().get_camera_3d()
	if hit.is_empty() or (cam != null and cam.global_position.distance_squared_to(w.position) < cam.global_position.distance_squared_to(hit.position)):
		return w
	return hit



func set_selection(entity_to_select: Entity):
	_group.clear()   # XX claude-switch: одиночный выбор заменяет группу

	if selected_entity == entity_to_select: return 
	if selected_entity: 
		# ⚡Сигнал в c_path или trainvisual о смене слоя
		selected_entity.send_event("on_select_layer", {'enabled':false})
		selected_entity.remove_component(C_Selected)
		#selected_entity = null # из старого, убрать? 
	selected_entity = entity_to_select
	Hints.set_context(&"selected", selected_entity != null)
	Hints.set_context(&"switch", selected_entity != null and selected_entity.has_comp(C_Switch))
	
	if selected_entity:
		selected_entity.add_component(C_Selected.new())
		# ⚡Сигнал в visual о смене слоя
		selected_entity.send_event("on_select_layer", {'enabled':true})
		
	#INFO ДЕРГАЕМ ПАНЕЛЬ!
	controller.publish_selection(selected_entity)




func _start_drag(target: Entity):
	controller.drag_tool.target_entity = target
	controller.switch_tool(controller.drag_tool)



# ---- HOVER ---
func _update_hover():
	# (1 << 0) | (1 << 2) | (1 << 10)
	# Слои земля, трак, вагон
	# Курсор над панелью UI: объект за ней не подсвечиваем
	var result = {}
	if not UIPointer.is_over_ui(get_viewport()):
		result = _pick_ray()
	var new_hover = null
	

	# Наехали на сущность?
	if result and result.collider:
		var entity = _find_entity(result.collider)
		if entity and entity.has_comp(IHoverable) and _is_pickable(entity):
			new_hover = entity
			
	# Если Новый ховер не такой же как был, то делаем ховером новый
	if hovered_entity != new_hover:
		if hovered_entity: 
			hovered_entity.remove_component(C_Hovered)
		hovered_entity = new_hover
		if hovered_entity: 
			hovered_entity.add_component(C_Hovered.new())



## Flex
## ЛКМ: ручка или Shift+клик по кривой выбранного flex. Тул компонентов не знает
func _try_handle_press() -> bool:
	if not selected_entity:
		return false
	# выбранный объект лежит на слое ghost (on_select_layer), поэтому ghost тоже в маске
	var hit = controller.get_mouse_ray(Global.active_layers(['handles', 'tracks', 'ghost']))
	if hit.is_empty():
		return false
	var data := {"collider": hit.collider, "position": hit.position,
			"shift": Actions.shift(), "consumed": false, "drag": false}
	selected_entity.send_event("on_pointer_pressed", data)
	handle_dragging = data.drag
	return data.consumed


## XX claude-switch. Рычаг стрелки (слой handles) работает без выделения: клик по рычагу перекладывает стрелку.
## Забираем нажатие, чтобы клик не выбрал и не потащил трак
func _try_press_lever() -> bool:
	if Global.current_mode == &'sections':
		return false   # XX claude-table T1b: в режиме «Секции» рычаги и ручки не работают
	var hit = controller.get_mouse_ray(Global.active_layers(['handles']))
	if hit.is_empty():
		return false
	var e = _find_entity(hit.collider)
	if e == null or not (e.has_comp(C_Switch) or e.has_comp(C_PowerSource) or e.has_comp(C_PowerDevice)):   # D4, D5: ручки и кнопки пульта, тумблеры коммутаторов
		return false
	var data := {"collider": hit.collider, "consumed": false, "drag": false, "ray": controller.get_mouse_ray_vec()}
	e.send_event("on_lever_pressed", data)
	# Ручка пульта тянется мышью: выбираем пульт и ведем ручку через on_handle_drag, как ручку flex
	if data.consumed and data.drag:
		set_selection(e)
		handle_dragging = true
	return data.consumed


func _try_handle_remove() -> bool:
	if not selected_entity:
		return false
	var hit = controller.get_mouse_ray(Global.active_layers(['handles']))
	if hit.is_empty():
		return false
	var data := {"collider": hit.collider, "consumed": false}
	selected_entity.send_event("on_handle_remove", data)
	return data.consumed
	
	


# Снимает селекшн при лкм пкм без драга
func _clear_selection():
	_group.clear()   # XX claude-switch: снимаем и группу
	_clear_single_selection()


## XX claude-switch: снять только одиночный выбор, группу не трогаем (Shift добавляет к выбору)
func _clear_single_selection():
	if selected_entity: 
		selected_entity.remove_component(C_Selected)
		# ⚡Сигнал в visual о смене слоя
		selected_entity.send_event("on_select_layer", {'enabled':false})
	selected_entity = null
	Hints.set_context(&"selected", false)
	Hints.set_context(&"switch", false)
	
	#INFO ОЧИЩАЕМ ПАНЕЛЬ! +
	controller.publish_selection(null)



func _find_entity(node):
	var curr = node
	while curr:
		if curr is Entity: return curr
		curr = curr.get_parent()
	return null



## XX claude-switch: снять группу и рамку (смена режима)
func clear_group() -> void:
	_group.clear()
	_marquee_armed = false
	_marquee_active = false
	if _marquee != null:
		_marquee.set_rect(Rect2())


# при выходе из селекта чистим 
func exit(_to_drag : bool = false):
	# XX claude-switch: рамка и группа при выходе из выбора снимаются (в драг группа уходит с инструментом, ее тащат)
	if not _to_drag:
		_group.clear()
	_group_drag_candidate = null
	_marquee_armed = false
	_marquee_active = false
	_marquee.set_rect(Rect2())
	
	if selected_entity: 
		selected_entity.remove_component(C_Hovered)
		if !_to_drag: # если выход не в драг, то убираем селект полностью
			_clear_selection()
			#INFO Очищаем панель
			controller.publish_selection(null) 
		
	if hovered_entity:
		if is_instance_valid(hovered_entity):
			hovered_entity.remove_component(C_Hovered)
		hovered_entity = null
	
	handle_dragging = false


# ==========================================
# XX claude-switch. Выделение рамкой: интерфейс и обработчики
# ==========================================

## Рамка и панель сводки живут в своем CanvasLayer (ниже слоя подсказок Hints = 10)
func _ensure_group_ui() -> void:
	if _group_layer != null:
		return
	_group_layer = CanvasLayer.new()
	_group_layer.name = "GroupSelectionLayer"
	_group_layer.layer = 5
	add_child(_group_layer)
	_marquee = MarqueeOverlay.new()
	_group_layer.add_child(_marquee)
	_tooltip = InfoToolTip.new()
	_group_layer.add_child(_tooltip)
	_note = Label.new()
	_note.name = "LayoutNote"
	_note.visible = false
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_note.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_note.position.y = 70.0
	_note.add_theme_font_size_override("font_size", 20)
	_note.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	_note.add_theme_color_override("font_outline_color", Color.BLACK)
	_note.add_theme_constant_override("outline_size", 8)
	_group_layer.add_child(_note)
	_tooltip.category_toggled.connect(func(cat: StringName, on: bool): _group.set_category_enabled(cat, on))
	_tooltip.delete_pressed.connect(_delete_group)
	_group.changed.connect(_on_group_changed)
	_on_group_changed()


## Сообщение подмакетника наверху экрана на 3 секунды
func _show_note(text: String) -> void:
	_ensure_group_ui()
	_note.text = text
	_note.visible = true
	_note_gen += 1
	var gen := _note_gen
	await get_tree().create_timer(3.0).timeout
	if gen == _note_gen and is_instance_valid(_note):
		_note.visible = false


func _on_group_changed() -> void:
	_tooltip.set_state(_group.members.size(), _group.counts(), _group.enabled)
	_tooltip.visible = not _group.candidates.is_empty()
	Hints.set_context(&"group", not _group.candidates.is_empty())


func _finish_marquee(end_pos: Vector2) -> void:
	var rect := Rect2(_marquee_start, Vector2.ZERO).expand(end_pos)
	_marquee.set_rect(Rect2())
	_group.select_in_rect(rect, controller.entities_root, get_viewport().get_camera_3d(), _marquee_additive)


## Shift+клик: объект в группе убирается, не в группе добавляется. Если выбран один объект, он входит в группу
## (Shift+клик по самому выбранному снимает выбор)
func _toggle_in_group(e: Entity) -> void:
	if e == null or e.has_comp(C_Ghost):
		return
	if _group.has_member(e):
		_group.remove_entity(e)
		return
	if e == selected_entity and _group.candidates.is_empty():
		_clear_single_selection()
		return
	_seed_group_from_single()
	_group.add_entity(e)


## Одиночный выбор становится первым членом группы (Shift при выбранном объекте). Объект не из выбираемых категорий просто снимается
func _seed_group_from_single() -> void:
	if selected_entity == null:
		return
	var e := selected_entity
	_clear_single_selection()
	_group.add_entity(e)


## Групповой драг: лидер (тот, за кого взялись) тащится обычным драгом, остальные члены следуют за его позой (DragTool.sel_group).
## Двигаем только траки и домики: вагоны и террейн имеют собственную логику драга (физика, сетка листов), жестко вести их за лидером пока нельзя.
## Если такие объекты включены в группу, перемещение отклоняется с подсказкой в панели: снимите галки категорий.
func _start_group_drag(leader: Entity) -> void:
	for e in _group.members:
		if is_instance_valid(e) and not GROUP_MOVABLE.has(GroupSelection.category_of(e)):
			_tooltip.set_note("Двигать группу можно, если в ней только траки и домики. Снимите галки: вагоны, террейн.")
			return
	_tooltip.set_note("")
	controller.drag_tool.sel_group.assign(_group.members)   # assign, а не присваивание: типизированный Array[Entity]
	_start_drag(leader)
