class_name C_TrackDraggable extends IDraggable

##################################
## Библиотека действий. Она живет на объекте всегда.   
##################################
## способность двигать ентити, когда включено C_Drag 
## компонент двигает сущность по евенту из ентити
##
# XX claude-terra: трак всегда горизонтален (в Entity только yaw). Высота = уровень (слой) над
## поверхностью под курсором. R/F меняют уровень. Наклон живет внутри кривой (C_Path.rise / flex).

@export var snap_break_distance := 9.6 # Дистанция срыва снапа (в метрах)

var drag_offset := Vector3.ZERO # смещение мыши
var rotation_euler := Vector3.ZERO # Храним тут, чтобы не терять при смене тулзов
var initial_transform: Transform3D # Стартпозиция

# XX claude-terra
var elevation := 0 # уровень над поверхностью под курсором, в слоях (GlobalSetting.layer_height)

# Состояние снаппинга
var is_snapped_locked := false # блокировка мыши в снапе
var snapped_entity_transform := Transform3D()




## Считает свой оффсет и запоминает стартовую позицию
func on_drag_started(_data: Dictionary) -> void:

	initial_transform = entity.global_transform
	# Берем смещение, но обнуляем Y, чтобы не тащить за собой перепады высот
	var raw_offset = entity.global_position - _data.position
	drag_offset = Vector3(raw_offset.x, 0.0, raw_offset.z)

	# XX claude-terra: yaw берем из позы (раньше после загрузки сейва трак при хвате прыгал в yaw = 0),
	# а высоту сохраняем, иначе стоящий на высоте трак "упадет" на стол при хвате
	rotation_euler = Vector3(0.0, entity.global_basis.get_euler().y, 0.0)
	var T: float = Global.settings.layer_height
	elevation = maxi(0, roundi((entity.global_position.y - _anchor_offset() - _data.position.y) / T))

	is_snapped_locked = false

	if entity.has_comp(C_Snapped):
		entity.remove_component(C_Snapped)



# Движение мышью кждый тик
# Обращать внимание на то какие слои хватает рейкаст (EntitySetting.pick_layers)
func on_drag_moved(_data: Dictionary) -> void:
	var mouse_pos: Vector3 = _data.position
	# XX claude-terra: нормаль поверхности больше не используется, трак не наклоняется по земле
	var target_pos = mouse_pos + drag_offset

	if is_snapped_locked and entity.has_comp(C_Snapped):
		# Расстояние по горизонтали от виртуальной позиции мыши до точки снапа
		var snap_o = snapped_entity_transform.origin
		var distance_to_mouse = Vector2(target_pos.x, target_pos.z).distance_to(Vector2(snap_o.x, snap_o.z))

		if distance_to_mouse > snap_break_distance:
			# МЫШЬ ОТЪЕХАЛА: срываем снап, убираем компонент-маркер
			entity.remove_component(C_Snapped)
			is_snapped_locked = false
			_apply_regular_movement(target_pos)
		else:
			# МЫШЬ РЯДОМ: Жестко удерживаем трансформ снапа, полностью игнорируя мелкие движения
			entity.global_transform = snapped_entity_transform
	else:
		# Снапа нет — обычное движение по поверхности
		_apply_regular_movement(target_pos)
	_update_level_label()   # XX claude-terra 13.1.7


# XX claude-terra 13.1.7 ===== Метка уровня над призраком и траком в драге =====

var _level_label: TrackNote.Line   # строка общей метки TrackNote (вместе с отказом снапа, тоннелем)


func on_component_added(t: Script) -> void:
	if (t == C_Ghost or t == C_Drag) and not entity.has_comp(C_FlexShape):   # у flex своя метка L / R / уклон
		_ensure_level_label()


func on_component_removed(t: Script) -> void:
	if t == C_Drag and _level_label and not entity.has_comp(C_Ghost):
		_level_label.queue_free()
		_level_label = null


func _ensure_level_label() -> void:
	if _level_label:
		return
	_level_label = TrackNote.line(entity, &"level", 0)
	_level_label.position = Vector3(0.0, 6.0, 0.0)


## "Ур. 3.0 · +1.0 ю (4.37%)": уровень низа трака над столом в слоях, у пандуса еще подъем и уклон.
## Красная, пока призрак не валиден (C_Blocked, C_Invalid)
func _update_level_label() -> void:
	if _level_label == null:
		return
	var T: float = Global.settings.layer_height
	var txt := "Ур. %.1f" % ((entity.global_position.y - _anchor_offset()) / T)
	var p := entity.get_comp(C_Path) as C_Path
	if p and absf(p.rise) > 0.0001:
		var L := p.get_length()
		var pct := absf(p.rise) / sqrt(maxf(L * L - p.rise * p.rise, 0.0001)) * 100.0
		txt += " · %+.1f ю (%.2f%%)" % [p.rise, pct]
	_level_label.text = txt   # сеттер сам пропускает то же значение
	_level_label.modulate = Color(1.0, 0.35, 0.35) if (entity.has_comp(C_Blocked) or entity.has_comp(C_Invalid)) else Color.WHITE


# XX claude-terra
## Обычное движение: только yaw, высота = поверхность + уровни, затем вертикальный магнит
func _apply_regular_movement(target_pos: Vector3) -> void:
	var T: float = Global.settings.layer_height
	# XX claude-terra 13.14 H5: на поле высот трак встаёт на уровень, кратный слою (ложе подровняет землю под ним)
	var gy := TGM.field_track_level(target_pos.x, target_pos.z, target_pos.y)
	var pos := Vector3(target_pos.x, gy + elevation * T + _anchor_offset(), target_pos.z)
	pos = _apply_vertical_magnet(pos)
	entity.global_transform = Transform3D(Basis(Vector3.UP, rotation_euler.y), pos)


# XX claude-terra
## Origin жесткого трака в середине кривой. У пандуса нижний конец стоит на уровне, центр выше на |rise|/2
func _anchor_offset() -> float:
	var p := entity.get_comp(C_Path) as C_Path
	return p.ground_anchor() if p else 0.0   # XX claude-coaster C6.1: у обычных путей прежнее |rise|/2


# XX claude-terra
## Вертикальный магнит: если мой сокет рядом (по горизонтали) со свободным чужим сокетом на другой высоте,
## поднимаем/опускаем трак на разницу, чтобы сокеты перекрылись и сработал снап
func _apply_vertical_magnet(pos: Vector3) -> Vector3:
	if is_snapped_locked or not Global.build_options.socket_snap:
		return pos
	var mine := entity.get_comp(C_Socket) as C_Socket
	if not mine:
		return pos
	var gs = Global.settings
	var yaw := Basis(Vector3.UP, rotation_euler.y)
	var best_d: float = gs.magnet_radius
	var best_dy := 0.0
	var path := entity.get_comp(C_Path) as C_Path
	var net := mine.network()   # XX claude-car CS1: магнит тянет только к сокетам своей сети
	for node in get_tree().get_nodes_in_group(&"track_socket"):
		var other := node as Entity
		if other == null or other == entity or other.is_queued_for_deletion() or other.has_comp(C_Ghost):
			continue
		var oc := other.get_comp(C_Socket) as C_Socket
		if not oc or oc.network() != net:
			continue
		for osock in oc.sockets:
			if not oc.is_socket_free(osock.socket):
				continue
			var tp: Vector3 = osock.socket.global_position
			for msock in mine.sockets:
				var mp: Vector3 = pos + yaw * msock.socket.position   # где будет мой сокет
				var d := Vector2(tp.x - mp.x, tp.z - mp.z).length()
				var dy := tp.y - mp.y
				if d < best_d and absf(dy) <= gs.magnet_max_dy:
					# XX claude-terra 13.1.4: магнит не тянет трак под землю (пандус вниз к траку на столе).
					# Проверяем каждого кандидата, а не только лучшего: уходящий под землю не мешает дальнему
					if dy != 0.0 and path and path.underground_depth(Transform3D(yaw, Vector3(pos.x, pos.y + dy, pos.z))) > gs.underground_tolerance:
						continue
					best_d = d
					best_dy = dy
	pos.y += best_dy
	return pos



## 💡Вызывается из C_Socket при успешной коллизии сокетов
func start_snap(target_global_transform: Transform3D) -> void:
	if entity.has_comp(C_GroupFollower):
		return   # XX claude-switch: член группы следует за лидером, сам к сокетам не привязывается
	if not Global.build_options.socket_snap:
		return   # U12: привязка к сокетам выключена в SideDock
	snapped_entity_transform = target_global_transform
	is_snapped_locked = true # Блокируем обычное влияние мыши
	# Актуализируем углы сразу при снапе. Тогда после в драге снапа угол не возвращается
	rotation_euler = target_global_transform.basis.get_euler()


	if not entity.has_comp(C_Snapped):
		entity.add_component(C_Snapped.new()) # Вешаем маркер стейта

	# Мгновенно примагничиваем рельс в идеальную позицию
	entity.global_transform = snapped_entity_transform
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame




func on_drag_ended(_data: Dictionary) -> void:
	# Если рельс заблокирован коллизией балласта при отпускании — возвращаем назад
	# XX claude-terra 13.1.4: отклонённый снап (излом или подземное положение) тоже возвращает на место
	var sock := entity.get_comp(C_Socket) as C_Socket
	if entity.has_comp(C_Blocked) or (sock and sock.has_snap_rejection()):
		entity.global_transform = initial_transform

	# Запрашиваем пересчет сети после возврата на исходную
		PGM.request_recalculate()

	# XX claude-terra 13.1.4: красный флаг отказа снапа снимаем после драга (на старом месте трак валиден)
	if sock:
		sock.clear_snap_rejection()

	# При дропе объекта отключаем логику срыва, чтобы рельс остался лежать в точке снапа
	is_snapped_locked = false



func on_rotate_input(data: Dictionary):
	if data.axis == "y":
		rotation_euler.y += deg_to_rad(data.amount)
	if data.axis == "x":   # XX claude-terra: R/F теперь уровень (слой), а не pitch
		elevation = maxi(0, elevation + int(signf(data.amount)))



# XX claude-terra 13.1.4
## Крупный шаг уровня (Shift+R/F, PageUp/PageDown): ElevationInput, levels = ±5
func on_elevation_input(data: Dictionary) -> void:
	elevation = maxi(0, elevation + int(data.get("levels", 0)))



## --- Блок синхронизации состояния (Клонирование) ---

# Вызывается у Госта в момент клонирования(отдаем данные). см build_tool 
func on_clone_state_to(data: Dictionary) -> void:
	var target_entity: Entity = data.target

	# Гост кричит в новую сущность: "Прими мои настройки драга!"
	target_entity.send_event("on_receive_draggable_state", {
		"rotation_euler": rotation_euler,
		"elevation": elevation   # XX claude-terra
		})


# Вызывается у Реального объекта в момент клонирования (принимаем данные). см build_tool 
func on_receive_draggable_state(data: Dictionary) -> void:
	if data.has("rotation_euler"):
		rotation_euler = data.rotation_euler
	if data.has("elevation"):   # XX claude-terra
		elevation = data.elevation



## Сброс высоты и вращения в дефолт (вызывается из DragTool по кнопке)
func on_drag_reset(_data: Dictionary) -> void:
	# 1. Сбрасываем накопленные игроком углы в ноль
	rotation_euler = Vector3.ZERO

	# 2. Сбрасываем смещение по высоте
	drag_offset = Vector3.ZERO
	elevation = 0   # XX claude-terra

	# 3. Принудительно сбрасываем локальный трансформ самой сущности, 
	# чтобы визуально она сразу выровнялась до следующего тика on_drag_moved
	entity.rotation = Vector3.ZERO
