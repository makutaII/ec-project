class_name DragTool extends Node

#########################
## Инструмент перемещения(таскания)
#########################

var controller: ToolController
var target_entity: Entity

## Шаг поворота Q/E задаёт Global.build_options.rot_step_deg (U12)
const ROT_FINE := 5.0 # Градусы, Shift+Q/E (XX claude-terra 13.1.7)

# Флаг позиции пкм
var rmb_pressed_pos := Vector2.ZERO

# XX claude-switch: вращение Alt + мышь и высота Ctrl + мышь (см. DragModifiers)
var _mods := DragModifiers.new()

# Группа на вечной сцепке тащится целиком: все части по порядку от головной, их {reversed, spacing},
# индекс схваченной и её положение относительно каждой (для свободного перетаскивания без рельс)
var _group: Array[Entity] = []
var _group_parts: Array[Dictionary] = []
var _group_index := -1
var _group_rel: Array[Transform3D] = []

# XX claude-switch: перемещение группы, выбранной рамкой (U22 шаг 2). Не путать с _group выше (состав на вечной сцепке).
# Лидер (target_entity) тащится обычной логикой драга со всеми магнитами, остальные члены выбора (followers) жестко следуют
# за его позой: поза = поза лидера * относительная поза на старте. Поэтому поворот (Q/E, Alt), уровень (R/F, Ctrl)
# и привязка лидера к сокетам двигают всю группу как одно целое.
## Члены выбора, включая лидера. Задает SelectTool перед входом в драг. Пусто: обычный драг одного объекта
var sel_group: Array[Entity] = []
var _sg_followers: Array[Entity] = []
var _sg_rel := {}              # Entity -> Transform3D: поза в системе координат лидера
var _sg_start := {}            # Entity -> Transform3D: поза на старте (для отката)
var _sg_leader_start := Transform3D.IDENTITY


func _ready() -> void:
	add_child(_mods)   # DragModifiers слушает мышь через _input, ему нужно быть в дереве


## Начало драга
func enter():
	if not target_entity:
		controller.switch_tool(controller.select_tool)
		return

	_mods.reset()
	# Вешаем стейт (для визуала)
	target_entity.add_component(C_Drag.new())
	
	# Драг начался вот в этой точке
	# XX claude-wire W5: блок с монтажом (нижняя полка) берёт стартовую точку по своей маске: по слою ground луч бьёт в плиту над полкой,
	# смещение хвата получается на глубину полки, и блок «уезжает» от курсора
	var start_mask := Global.active_layers(['ground'])
	var start_id := target_entity.get_comp(C_Identity) as C_Identity
	if start_id and Mount.has_mount(start_id.setting):
		start_mask = _pick_mask()
	var hit = controller.get_mouse_ray(start_mask)
	# Драг проверит, если евент из билд моде, то смещения мыши не будет
	#hit['build'] = false
	if hit.is_empty():
		# Курсор вне стола (спавн кнопкой с панели): стартуем драг по плоскости стола, иначе вагон не оживёт
		hit = controller.get_mouse_plane_hit()
	if hit:
		_group_collect()   # до on_drag_started: всем частям C_Drag, иначе связи внутри группы порвутся
		target_entity.send_event("on_drag_started", hit)
		_group_start(hit)
		_sgroup_begin(hit)
		


# XX claude-terra
func _pick_mask() -> int:
	var identity := target_entity.get_comp(C_Identity) as C_Identity
	if identity and identity.setting:
		# XX claude-wire W4: блоки с монтажом при виде «Монтаж» тащатся и по подстолью
		return Mount.pick_mask(identity.setting, Global.active_layers(identity.setting.get_pick_layers()))
	return Global.active_layers(['ground','tracks','trains'])


## ⚡Сигнал(почти) о смене позиции в сущность. Там рзберется драгабл
func process_tick(_delta):
	# XX claude-switch: пока зажат Alt (вращение) или Ctrl (высота), курсор заморожен, объект стоит на месте, позицию не обновляем.
	# Остальные части состава и члены выбора следуют за объектом и в этом кадре: поворот и уровень двигают их позы
	if _mods.tick(target_entity, controller.get_viewport()):
		_group_move()
		_sgroup_follow()
		return
	#var hit = controller.get_mouse_ray((1 << 0) | (1 << 2)|(1 << 4))
	var hit = controller.get_mouse_ray(_pick_mask())   # XX claude-terra слои из EntitySetting.pick_layers
	if hit:
		_mods.remember(hit)   # XX claude-switch: позиция, с которой объект стоит (нужна при Alt и Ctrl)
		# Отправляем приказ в сущность. Оттуда C_TrackDraggable сам разберется.
		target_entity.send_event("on_drag_moved", hit)
		_group_move()
		_sgroup_follow()
		pass



### Передача инпутов в ентити, tool_controller вызывает
func handle_input(event: InputEvent):
	# XX claude-terra 13.1.7: Shift+Q/E поворот на ROT_FINE (5°), без Shift шаг из Global.build_options (U12)
	var _shift := Actions.shift()
	var _rot := ROT_FINE if _shift else Global.build_options.rot_step_deg
	# XX claude-switch: клавиши по событию (Actions.pressed_shift_ok), а не опросом Input.is_action_just_pressed: опрос был истинен
	# на любом событии кадра (и на движении мыши: поворот мог удвоиться) и не замечал, что клавишу забрал LineEdit
	if Actions.pressed_shift_ok(event, &"rotate_left"):
		target_entity.send_event("on_rotate_input", {"axis": "y", "amount": _rot})
	if Actions.pressed_shift_ok(event, &"rotate_right"):
		target_entity.send_event("on_rotate_input", {"axis": "y", "amount": -_rot})
	# XX claude-terra 13.1.4: с Shift R/F идут крупным шагом через ElevationInput, обычный шаг без Shift
	if Actions.pressed_shift_ok(event, &"level_up") and not _shift:
		target_entity.send_event("on_rotate_input", {"axis": "x", "amount": Global.build_options.rot_step_deg})
	if Actions.pressed_shift_ok(event, &"level_down") and not _shift:
		target_entity.send_event("on_rotate_input", {"axis": "x", "amount": -Global.build_options.rot_step_deg})
	# XX claude-terra 13.1.4: Shift+R/F и PageUp/PageDown, крупный шаг уровня (трак, лист, вагон, 13.1.7)
	var _levels := ElevationInput.levels_from_event(event)
	if _levels != 0:
		target_entity.send_event("on_elevation_input", {"levels": _levels})
	if Actions.pressed(event, &"reset_transform"):
		target_entity.send_event("on_drag_reset", {}) # сбросить состояние
	# 13.1.7: PageUp/PageDown теперь крупный шаг уровня (ElevationInput выше) для всех, и для вагона тоже
		
	if Input.is_action_just_released("lmb"):
		controller.switch_tool(controller.select_tool)# Драг окончен дропом
	
	#  ПКМ 
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed: # нажали 
			rmb_pressed_pos = event.position
		else: # отпустили
			# Отменяем драг режим если это был короткий клик (не драг камеры)
			if rmb_pressed_pos.distance_to(event.position) < 5:
				controller.switch_tool(controller.select_tool)


## Драг окончен
func exit(_to_drag : bool = false):
	_mods.reset()   # вернуть курсор, если драг кончился при зажатом Alt или Ctrl
	# Выбор рамкой решает судьбу группы до конца драга лидера: его on_drag_ended сбросит флаг отказа привязки, а нам он нужен
	_sgroup_end()
	if target_entity:
		target_entity.remove_component(C_Drag)
		target_entity.send_event("on_drag_ended", {})
		_group_end()


## Что тащится вместе со схваченным вагоном: состав из шаблона, который только что появился
## (controller.consist_drag), или группа на вечных сцепках. Остальным частям сразу C_Drag
func _group_collect() -> void:
	_group_clear()
	var entities: Array[Entity] = []
	var parts: Array[Dictionary] = []
	var hint: Dictionary = controller.consist_drag
	controller.consist_drag = {}
	if not hint.is_empty() and (hint["entities"] as Array).has(target_entity):
		entities.assign(hint["entities"])
		parts.assign(hint["parts"])
	else:
		var coupler := target_entity.get_comp(C_Coupler) as C_Coupler
		if coupler == null:
			return
		var prev: Entity = null
		for item in coupler.get_ordered_consist(true):
			var e: Entity = item["entity"]
			entities.append(e)
			parts.append({
				"reversed": item["reversed"],
				"spacing": 0.0 if prev == null else prev.global_position.distance_to(e.global_position),
			})
			prev = e
	if entities.size() < 2:
		return
	var start := target_entity.global_transform
	for i in entities.size():
		var member := entities[i]
		_group.append(member)
		_group_parts.append(parts[i])
		_group_rel.append(start.affine_inverse() * member.global_transform)
		if member == target_entity:
			_group_index = i
		else:
			member.add_component(C_Drag.new())


## Остальным частям группы начало драга (схваченной оно уже послано)
func _group_start(hit: Dictionary) -> void:
	for member in _group:
		if member != target_entity and is_instance_valid(member):
			member.send_event("on_drag_started", hit)


## Посадка схваченной части на трак: пусто, если она не на рельсах
func _group_snap() -> Dictionary:
	var dr := target_entity.get_comp(C_TrainDraggable) as C_TrainDraggable
	if dr == null or not dr.is_snapped_to_track or not is_instance_valid(dr.current_track):
		return {}
	return {"track": dr.current_track, "offset": dr.current_curve_point, "route": dr.current_route}


## Части группы за схваченной: по пути, если она на рельсах и группа помещается, иначе жёстко за ней
func _group_move() -> void:
	if _group.size() < 2:
		return
	var states: Array[Dictionary] = ConsistPlacer.plan_parts(_group_parts, _group_index, target_entity, _group_snap())
	for i in _group.size():
		var e := _group[i]
		if i == _group_index or not is_instance_valid(e):
			continue
		if states.is_empty():
			e.global_transform = target_entity.global_transform * _group_rel[i]
		else:
			ConsistPlacer.pose(e, _group_parts[i], states[i])


## Дроп: остальные части получают конец драга, группа садится на рельсы вслед за схваченной
func _group_end() -> void:
	if _group.size() >= 2:
		for e in _group:
			if e != target_entity and is_instance_valid(e):
				e.send_event("on_drag_ended", {})
		var snap := _group_snap()
		if not snap.is_empty():
			ConsistPlacer.seat_group(_group, _group_parts, _group_index, snap)
		# C_Drag снимаем после посадки: пока он есть, вечные связи на паузе, а не рвутся
		for e in _group:
			if e != target_entity and is_instance_valid(e):
				e.remove_component(C_Drag)
	_group_clear()


func _group_clear() -> void:
	_group.clear()
	_group_parts.clear()
	_group_rel.clear()
	_group_index = -1


# ==========================================
# XX claude-switch. Перемещение группы, выбранной рамкой
# ==========================================

## Старт: запоминаем позы, вешаем ведомым состояние драга и сообщаем им о начале (как лидеру, тем же вводом курсора)
func _sgroup_begin(hit: Dictionary) -> void:
	_sg_followers.clear()
	_sg_rel.clear()
	_sg_start.clear()
	if sel_group.size() < 2 or not is_instance_valid(target_entity):
		return
	_sg_leader_start = target_entity.global_transform
	var inv := _sg_leader_start.affine_inverse()
	for e in sel_group:
		if e == target_entity or not is_instance_valid(e) or e.is_queued_for_deletion():
			continue
		_sg_followers.append(e)
		_sg_start[e] = e.global_transform
		_sg_rel[e] = inv * e.global_transform
		e.add_component(C_GroupFollower.new())   # маркер: следует за лидером, сам к сокетам не привязывается
		e.add_component(C_Drag.new())            # как у лидера: уходит со слоев выбора, чтобы курсор не попадал в него
		e.send_event("on_drag_started", hit)


## Каждый кадр после движения лидера: ведомые занимают свою позу относительно лидера
func _sgroup_follow() -> void:
	if _sg_followers.is_empty() or not is_instance_valid(target_entity):
		return
	var lx := target_entity.global_transform
	for f in _sg_followers:
		if is_instance_valid(f):
			f.global_transform = lx * (_sg_rel[f] as Transform3D)


## Конец: если заблокирован ХОТЬ ОДИН член группы (перекрытие, отказ привязки), откатываем ВСЮ группу, иначе она осталась бы разорванной
func _sgroup_end() -> void:
	if _sg_followers.is_empty():
		sel_group = []
		return
	var blocked := _is_blocked(target_entity)
	for f in _sg_followers:
		if is_instance_valid(f) and _is_blocked(f):
			blocked = true
	if blocked:
		if is_instance_valid(target_entity):
			target_entity.global_transform = _sg_leader_start
		for f in _sg_followers:
			if is_instance_valid(f):
				f.global_transform = _sg_start[f]
		PGM.request_recalculate()
	for f in _sg_followers:
		if not is_instance_valid(f):
			continue
		if f.has_comp(C_GroupFollower):
			f.remove_component(C_GroupFollower)
		if f.has_comp(C_Drag):
			f.remove_component(C_Drag)
		f.send_event("on_drag_ended", {})
	_sg_followers.clear()
	_sg_rel.clear()
	_sg_start.clear()
	sel_group = []


func _is_blocked(e: Entity) -> bool:
	if not is_instance_valid(e):
		return false
	if e.has_comp(C_Blocked):
		return true
	var sock := e.get_comp(C_Socket) as C_Socket
	return sock != null and sock.has_snap_rejection()
