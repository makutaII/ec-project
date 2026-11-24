class_name C_Socket extends ISnappable

####################
## Способность, Библиотека действий. Она живет на объекте всегда.
####################
## 💡Должен загружаться после C_Path 
## содержит внутри себя логику расчета (парсинг Path3D) точек стыковки
## Хранит точки стыковки (локальные координаты и вектор направления "наружу")


var sockets: Array[Dictionary] = []

## Изостыки (ATTN_10 D1): индекс сокета -> true. Электрический стык рвется, если изостык у любого из двух
## сокетов стыка. Механически трак сцеплен как раньше (снап, вагоны проезжают)
var gaps: Dictionary = {}
## Накладки изостыков (MeshInstance3D на Area3D сокета, владелец этот компонент): индекс сокета -> узел
var _gap_markers: Dictionary = {}

## Массив ссылок на валидные соседние сущности (для графа сети)
var connected_entities: Array[Entity] = []

# XX claude-terra 13.1.4
## Чужие сокеты, снап к которым отклонён (излом или подземное положение). Пока список не пуст,
## призрак или трак в драге красный (C_Invalid) и не ставится. Только жесткие траки: у flex свой C_Invalid
var _snap_rejected: Array[Area3D] = []
## Причина последнего отказа: "kink" (излом по вертикали), "bank" (крен не совпадает, ATTN_27), "underground" (трак уходит под землю),
## "network" (сокет другой сети: рельс и дорога, ATTN_28 §28.3) или "".
## Нужна для подсказки про разворот на 180°
var snap_reject_reason := ""
## Строка общей метки TrackNote с причиной отказа (создается по требованию)
var _hint: TrackNote.Line

# Настройки формы сокета
var  capsule_radius := 0.6
var capsule_height := 1.49

# Используем on_entity_ready, чтобы гарантировать, что C_TrackVisual 
# уже добавил свои инстансы (Path3D) в дерево.
# Вызывается ядром Entity после того, как все компоненты добавлены
# XX claude-terra
func on_added() -> void:
	entity.add_to_group(&"track_socket")   # для вертикального магнита в C_TrackDraggable


func on_entity_ready():
	_parse_paths()


# XX claude-car CS1 (ATTN_28 §28.3)
## Сеть сокетов сущности: &"rail" у рельсов, стрелок и горок, &"road" у дороги (C_Path.network_id).
## Сокеты разных сетей не стыкуются, не считаются соседями и не занимают друг другу стык
func network() -> StringName:
	return C_Path.network_of(entity)




# Парсим path , ищем его, а в нем curve 
func _parse_paths():
	# Стучимся в логический компонент пути
	var path_comp = get_comp(C_Path)
	if path_comp and path_comp.path_node:
		# XX claude-switch: у стрелки сокеты со всех маршрутов (носок общий, сливается в _add_socket_if_unique)
		# Луч питания (leg): у кросса с раздельными цепями каждый путь свой луч, у остальных всегда 0
		var pt := get_comp(C_PowerTrack) as C_PowerTrack
		var split = pt != null and pt.legs > 1 and path_comp.parallel_routes
		var curves = path_comp.all_curves()
		for i in curves.size():
			_parse_curve(curves[i], path_comp.path_node, i if split else 0)
		_refresh_gap_markers()   # изостыки могли прийти из сейва раньше сокетов



# Парсим кривую из path3d для вычисления сокетов
func _parse_curve(c: Curve3D, p: Path3D, leg: int = 0):
	if c.get_point_count() < 2: return

	# Берем точные координаты первой и последней точек
	var p_first = c.get_point_position(0)
	var p_last = c.get_point_position(c.get_point_count() - 1)

	# Направление на старте — это направление ручки `out`, либо просто вперед, если ручки нет
	var d_first = -c.get_point_out(0).normalized()
	if d_first.is_zero_approx(): #true если значения этого вектора приблизительно равны нулю
		d_first = -(c.get_point_position(1) - p_first).normalized()
	else:
		d_first = d_first # Смотрит наружу по направлению ручки
		
	# Направление на конце — это инвертированная ручка `in` (чтобы смотреть "наружу")
	var d_last = -c.get_point_in(c.get_point_count() - 1).normalized()
	
	if d_last.is_zero_approx():
		d_last = -(c.get_point_position(c.get_point_count() - 2) - p_last).normalized()
		
	# XX claude-coaster C5.4: «верх» поверхности на концах (у траков без крена это перпендикуляр к уклону, как у репера меша)
	var total := c.get_baked_length()
	var up_first := TrackMeshBuilder.frame(c, 0.0, total).u
	var up_last := TrackMeshBuilder.frame(c, total, total).u
	_add_socket_if_unique(p_first, d_first, true, leg, up_first)
	_add_cone(p.transform * p_first, Color.CHARTREUSE)  #debug
	
	
	_add_socket_if_unique(p_last, d_last, false, leg, up_last)
	_add_cone(p.transform * p_last, Color.DEEP_PINK)#debug





# Добавляем сокет в массив, только если в этой точке его еще нет (слияние для стрелок)
## XX claude-switch: is_start = начало маршрута. Нужен PGM для полярности: у кросса два начала (сокеты 0 и 2)
func _add_socket_if_unique(pos: Vector3, dir: Vector3, is_start: bool = false, leg: int = 0, up: Vector3 = Vector3.UP):
	for s in sockets:
		if s.pos.distance_to(pos) < 0.01:
			return # Сокет уже зарегистрирован
			
	var new_socket =  _add_socked_area( pos, dir)
	new_socket.set_meta(&"joint_up", up)   # XX claude-coaster C5.4: «верх» сокета в кадре Entity, для проверки крена на стыке
	sockets.append({
		"pos": pos,
		"out_dir": dir,
		"socket": new_socket,
		"start": is_start,
		"leg": leg   # XX claude-switch: луч питания, которому принадлежит сокет (C_PowerTrack.legs)
	})



func _add_socked_area(_pos: Vector3, dir: Vector3) -> Area3D:
	#printt(entity.name)
	var area = Area3D.new()
	var collision = CollisionShape3D.new()
	var capsule = CapsuleShape3D.new()
	
	# подрезаем высоту сокета на коротком траке
	for s in sockets:
		if s.pos.distance_to(_pos) <= 1.5 and s.pos.distance_to(_pos) > 0:
			capsule_height = s.pos.distance_to(_pos) - 0.1
			s.socket.get_child(0).shape.height = s.pos.distance_to(_pos) - 0.1
	# Настройки формы сокета 
	capsule.height = capsule_height
	capsule.radius = capsule_radius
	
	collision.shape = capsule
	collision.rotation.x = PI/2 # положить вдоль Z капсулу вперед (-Z)
	
	# Важно: сначала добавляем в дерево сцены, чтобы трансформации работали корректно
	entity.add_child(area)
	area.add_child(collision)
	
	# XX claude-terra позиция и поворот вынесены в _orient_area (его же использует on_curve_changed)
	var piv = entity.get_comp(C_Pivot).offset
	#_orient_area(area, _pos + piv, dir)
	_orient_area(area, _pos + piv + Vector3(0.0, _surface_lift(), 0.0), dir)

		
	# нужные слои (collision_layer / collision_mask)
	#area.set_collision_layer_value(4, true) # вкл этот слой 
	area.collision_layer = 1 << 3 	# Слой 4 # заменяет активный слой этими
	area.collision_mask = 1 << 3
	area.name = entity.name + '_Socket_0' 
	
	# Подключаем сигнал, передавая саму area как второй аргумент
	area.area_entered.connect(_on_socket_area_entered.bind(area))
	area.area_exited.connect(_on_socket_area_exited)
	
	# Визуальный маркер
	_add_marker(collision)

	return area


## СИГНАЛЫ

## TODO Почистить скрипт
## ⚡Сигнал area вход
# s_socket - стац трак, d_socket - драг трак
func _on_socket_area_entered(s_socket: Area3D, d_socket: Area3D) -> void:
	# Чтобы стейты заехали в ентити
	await get_tree().physics_frame
	
	# Из Блокед не может быть снапа
	if entity.has_comp(C_Blocked):
		return
	
	var neighbor_entity = _find_entity_from_collider(s_socket)

	# XX claude-car CS1: сокет другой сети (рельс и дорога) не сосед и не цель снапа. Проверка раньше геометрических:
	# призрак или трак в драге краснеет, причина "network" (ATTN_28 §28.3)
	if neighbor_entity and neighbor_entity != entity and C_Path.network_of(neighbor_entity) != network():
		if entity.has_comp(C_Drag) or entity.has_comp(C_Ghost):
			_set_snap_rejected(s_socket, d_socket, true)
			if _snap_rejected.has(s_socket):
				snap_reject_reason = "network"
				_update_reject_hint()
		return

	## Добавляем соседа в список. Предохранители:
	# 1. Сущность найдена и это не мы сами. 2. Сущность не является призраком 3. Мы еще не добавили ее в массив.

	if neighbor_entity and neighbor_entity != entity:
		if not neighbor_entity.has_comp(C_Ghost) and not connected_entities.has(neighbor_entity):
			connected_entities.append(neighbor_entity)
			entity.send_event("on_neighbors_changed", {})   # XX claude-terra 13.1.5: опоры на стыке (кто строит общую)
			# новый реальный стык (flex встаёт из призрака, выхода из сокета не будет): пересчитать сеть
			if not entity.has_comp(C_Ghost):
				PGM.request_recalculate()

	# Снаппинг обрабатывается только той сущностью, которую СЕЙЧАС ТАЩАТ
	if not (entity.has_comp(C_Drag) or entity.has_comp(C_Ghost)):
		return
	
	# Если мы уже жестко зафиксированы в снапе, игнорируем новые триггеры
	if entity.has_comp(C_Snapped):
		return

	# Стац ентити. Проверка стац не есть драг
	var s_entity = _find_entity_from_collider(s_socket)
	if not s_entity or s_entity == entity:
		return

	# Проверяем, что объект коллизии — это тоже валидный сокет рельса
	if not s_entity.has_comp(C_Socket):
		return
	
	# ЗАЩИТА "Третьим не будет" и "Объект на объект":
	# Если стационарный сокет уже занят другим рельсом — отмена.
	if _is_socket_occupied(s_socket):
		return
		
	#TODO зачем проверять себя??
	# Если наш собственный уже занят другим рельсом — отмена.
	#if _is_socket_occupied(d_socket):
		#return
	#printt('entered',d_socket.name)
	# XX claude-terra снап по "yaw + позиция": трак остается горизонтальным, уклон живет внутри кривой
	var snap = _snap_transform(s_socket, d_socket)
	if snap == null:
		# XX claude-terra 13.1.4: излом больше joint_kink_max_deg или трак уходит под землю. Красный призрак
		_set_snap_rejected(s_socket, d_socket, true)
		return
	_set_snap_rejected(s_socket, d_socket, false)

	# Передаем управление в C_TrackDraggable
	var _comp = entity.get_comp(C_TrackDraggable)
	if _comp:
		_comp.start_snap(snap)

	# Тут делааем сеть или не делаем
	PGM.request_recalculate() # пересчет сети
	


## Выход ⚡Сигнал area 
func _on_socket_area_exited(_area: Area3D) -> void:
	_set_snap_rejected(_area, null, false)   # XX claude-terra 13.1.4: ушли от сокета, отказ снят
	var neighbor_entity = _find_entity_from_collider(_area)
	
	# Убираем соседа из списка
	if neighbor_entity and connected_entities.has(neighbor_entity):
		connected_entities.erase(neighbor_entity)
		entity.send_event("on_neighbors_changed", {})   # XX claude-terra 13.1.5

	PGM.request_recalculate() # пересчет сети
	
	# ⚡Сигнал для  UI обновление данных трака
	await get_tree().physics_frame



##  -------ДЛЯ ВАГОНА ----------

# Ищет соседа, который пристыкован к указанному краю нашего трака
func get_neighbor_at(is_exiting_end: bool) -> Entity:
	var path_comp = get_comp(C_Path)
	if not path_comp or not path_comp.path_node:
		return null
		
	var curve = path_comp.curve
	# Находим глобальную координату того края, с которого съезжаем
	var local_exit = curve.sample_baked(curve.get_baked_length() if is_exiting_end else 0.0)
	var global_exit = path_comp.path_node.to_global(local_exit)

	# Перебираем всех живых соседей
	for neighbor in get_connected_entities():
		var n_path = neighbor.get_comp(C_Path)
		if not n_path or not n_path.path_node:
			continue
			
		var n_curve = n_path.curve
		var n_node = n_path.path_node
		
		# Получаем глобальные координаты начала и конца соседа
		var n_start = n_node.to_global(n_curve.sample_baked(0.0))
		var n_end = n_node.to_global(n_curve.sample_baked(n_curve.get_baked_length()))
		
		# Если край соседа совпадает с нашей точкой выхода (с погрешностью 0.1м)
		if global_exit.distance_to(n_start) < 0.1 or global_exit.distance_to(n_end) < 0.1:
			return neighbor
			
	return null
	
	





# ---- HELPERS ---

#лямбда-фильтр  для защиты от крашей. Если игрок удалил рельс через инструмент удаления (вызвался queue_free()), физический сигнал exited может не успеть отработать. Фильтр гарантирует, что диспетчер получит только живые объекты.
# Возвращает массив живых соседей для PGM
func get_connected_entities() -> Array[Entity]:
	# Очищаем массив от "мертвых" ссылок перед отдачей
	connected_entities = connected_entities.filter(
		func(e): return is_instance_valid(e) and not e.is_queued_for_deletion()
	)
	return connected_entities


const JOINT_XZ := 1.2   # по горизонтали сокеты одного стыка ближе этого (диаметр капсулы сокета)


## Электрические соседи: геометрический стык (connected_entities) и сокеты на одной высоте поверхности катания.
## Если у стыкующихся траков разная head_height (ступенька, ATTN_15 §2.10), снапа нет и электрической связи тоже:
## нужен переходный элемент. Для вагона (get_neighbor_at) список connected_entities не фильтруется:
## сход на ступеньке решает физика (луч Bogie), как и задумано.
func get_electric_neighbors() -> Array[Entity]:
	var out: Array[Entity] = []
	for n in get_connected_entities():
		var other := n.get_comp(C_Socket) as C_Socket
		if other and _has_level_joint(other):
			out.append(n)
	return out


## Есть ли у нас и соседа пара сокетов в одной точке стыка на одной высоте
func _has_level_joint(other: C_Socket) -> bool:
	var tol: float = Global.settings.joint_level_tol
	for a in sockets:
		var pa: Vector3 = (a["socket"] as Area3D).global_position
		for b in other.get_sockets():
			var pb: Vector3 = (b["socket"] as Area3D).global_position
			if Vector2(pa.x - pb.x, pa.z - pb.z).length() < JOINT_XZ and absf(pa.y - pb.y) <= tol:
				return true
	return false
	


func get_sockets() -> Array[Dictionary]:
	return sockets


## XX claude-switch: луч питания сокета i (0 у всех, кроме кросса с раздельными цепями)
func leg_of_socket(i: int) -> int:
	return int(sockets[i].get("leg", 0)) if i >= 0 and i < sockets.size() else 0


## XX claude-switch (E1, power routing): мертвый сокет не проводит ток в обе стороны.
## По умолчанию все живые. Выставляет C_Switch по положению стрелки, читает PGM при обходе сети
func set_socket_live(i: int, live: bool) -> void:
	if i >= 0 and i < sockets.size():
		sockets[i]["live"] = live


func is_socket_live(i: int) -> bool:
	return bool(sockets[i].get("live", true)) if i >= 0 and i < sockets.size() else true


## ---- ИЗОСТЫКИ (ATTN_10 §10.5.4) ----

func is_gap(i: int) -> bool:
	return bool(gaps.get(i, false))


## Поставить или снять изостык на сокете i. Сеть питания пересчитывается
func set_gap(i: int, on: bool) -> void:
	if i < 0 or i >= sockets.size() or is_gap(i) == on:
		return
	if on:
		gaps[i] = true
	else:
		gaps.erase(i)
	_refresh_gap_markers()
	if entity and not entity.has_comp(C_Ghost):
		PGM.request_recalculate()


## Подпись сокета для UI: начало или конец маршрута
func socket_label(i: int) -> String:
	if i < 0 or i >= sockets.size():
		return ""
	return "начало" if bool(sockets[i].get("start", i == 0)) else "конец"


## Белая накладка на стыке у сокетов с изостыком
func _refresh_gap_markers() -> void:
	for i in sockets.size():
		var has: bool = _gap_markers.has(i) and is_instance_valid(_gap_markers[i])
		if is_gap(i) and not has:
			var area := sockets[i].socket as Area3D
			if area == null:
				continue
			var m := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(2.6, 0.5, 0.4)   # поперек пути, тонкая пластина
			m.mesh = box
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.95, 0.95, 0.9)
			m.material_override = mat
			m.position = Vector3(0.0, 0.15, 0.25)   # чуть внутрь трака (+Z сокета смотрит внутрь)
			m.name = "GapMarker"
			area.add_child(m)
			_gap_markers[i] = m
		elif not is_gap(i) and has:
			(_gap_markers[i] as Node).queue_free()
			_gap_markers.erase(i)



#------SAVE\LOAD----

## Только изостыки. Без них пусто и в сейв компонент не попадает (старые сейвы не меняются)
func save_data() -> Dictionary:
	if gaps.is_empty():
		return {}
	return {
		'comp_path': get_script().resource_path,
		'comp_name': get_script().resource_path.get_file().get_basename(),
		'gaps': gaps.keys(),
	}


func load_data(data: Dictionary) -> void:
	gaps.clear()
	for k in data.get("gaps", []):
		gaps[int(k)] = true
	_refresh_gap_markers()



## Проверка: занят ли сокет стабильно установленным (не таскиваемым) рельсом
func _is_socket_occupied(socket_area: Area3D) -> bool:
	# XX claude-switch: сокет выключен (закрытый стык упора, flex в растяжке): get_overlapping_areas() на нем
	# ошибка, а подключаться к нему нельзя. Считаем занятым
	if not socket_area.monitoring:
		return true
	var my_entity = _find_entity_from_collider(socket_area)
	
	for area in socket_area.get_overlapping_areas():
		# 1. Игнорируем сам этот же сокет
		if area == socket_area:
			continue
			
		var other_entity = _find_entity_from_collider(area)
		
		# 2. Игнорируем ВСЕ коллизии нашей же сущности (балласт, другие сокеты)
		if other_entity == my_entity:
			continue
			
		# XX claude-car CS1: сокет другой сети (рельс и дорога в одной точке) стык не занимает
		if other_entity and C_Path.network_of(other_entity) != C_Path.network_of(my_entity):
			continue

		# 3. Игнорируем гостов и объекты, которые сейчас находятся в режиме Drag
		if other_entity and (other_entity.has_comp(C_Ghost) or other_entity.has_comp(C_Drag)):
			continue
			
		# Если мы дошли сюда, значит в сокете лежит стабильный, чужой рельс!
		return true
		
	return false





# Хелпер подъема по дереву до Entity (аналогично c_blockable)
func _find_entity_from_collider(node: Node) -> Entity:
	var current = node
	while current:
		if current is Entity:
			return current
		current = current.get_parent()
	return null



# Рекурсивный поиск всех Path3D в визуале
func _find_paths_recursive(node: Node) -> Array[Path3D]:
	var result: Array[Path3D] = []
	if node is Path3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_paths_recursive(child))
	return result
	
	

# XX claude-terra ===== Террейн: снап по yaw, магнит, flex =====

## Ориентирует Area3D сокета: -Z смотрит наружу вдоль dir (dir может иметь наклон по y)
func _orient_area(area: Area3D, _pos: Vector3, dir: Vector3) -> void:
	area.position = _pos
	if dir.is_zero_approx():
		return
	var z_axis = -dir.normalized()
	var x_axis = Vector3.UP.cross(z_axis).normalized()
	# Защита от коллинеарности (если сокет смотрит ровно в небо)
	if x_axis.is_zero_approx():
		x_axis = Vector3.RIGHT.cross(z_axis).normalized()
	var y_axis = z_axis.cross(x_axis).normalized()
	area.transform.basis = Basis(x_axis, y_axis, z_axis)


## Поза Entity для стыка сокетов (только yaw + позиция) или null, если излом больше допуска.
## s_socket - стоящий сокет, d_socket - мой (локальный, базис Entity = только yaw)
func _snap_transform(s_socket: Area3D, d_socket: Area3D) -> Variant:
	snap_reject_reason = ""
	var t_dir := -s_socket.global_basis.z    # "наружу" у стоящего сокета
	var d_dir := -d_socket.basis.z           # "наружу" у моего, локально
	# Стык гладкий, если наружные векторы почти противоположны и по вертикали
	var kink := absf(rad_to_deg(asin(clampf(t_dir.y, -1.0, 1.0)) + asin(clampf(d_dir.y, -1.0, 1.0))))
	if kink > Global.settings.joint_kink_max_deg:
		snap_reject_reason = "kink"
		return null
	var want := Vector2(-t_dir.x, -t_dir.z)
	var have := Vector2(d_dir.x, d_dir.z)
	if want.length_squared() < 0.0001 or have.length_squared() < 0.0001:
		return null
	# поворот вокруг Y на угол a меняет угол вектора в (x,z) на -a
	var yaw := have.angle() - want.angle()
	var b := Basis(Vector3.UP, yaw)
	# XX claude-coaster C5.4: крен на стыке. Мировые «верха» сокетов, разница вокруг оси стыка (излом по вертикали в неё не входит)
	var bank := JointMath.bank_diff_deg(t_dir, _joint_up_world(s_socket), b * _joint_up_local(d_socket))
	if bank > Global.settings.joint_bank_max_deg:
		snap_reject_reason = "bank"
		return null
	var xf := Transform3D(b, s_socket.global_position - b * d_socket.position)
	# XX claude-terra снап, при котором трак уходит под землю, отклоняем (пандус вниз к траку на столе: развернуть на 180°)
	var path := get_comp(C_Path) as C_Path
	if path and path.underground_depth(xf) > Global.settings.underground_tolerance:
		snap_reject_reason = "underground"
		return null
	return xf


## «Верх» сокета в кадре Entity-владельца (meta joint_up, пишет _add_socket_if_unique и on_curve_changed). Vector3.UP, если не задан
func _joint_up_local(area: Area3D) -> Vector3:
	return area.get_meta(&"joint_up", Vector3.UP)


## «Верх» сокета в мире: кадр Entity-владельца (родитель области) поворачивает его
func _joint_up_world(area: Area3D) -> Vector3:
	var parent := area.get_parent() as Node3D
	var up := _joint_up_local(area)
	return parent.global_basis * up if parent else up


# XX claude-terra 13.1.4
## Отметить или снять отказ снапа к чужому сокету. Пока есть хоть один отказ, на сущности висит C_Invalid.
## d_socket нужен только при отметке: если сокеты уже разошлись (ждали физкадр), отказ не ставим
func _set_snap_rejected(other: Area3D, d_socket: Area3D, on: bool) -> void:
	if entity.has_comp(C_FlexShape):
		return   # у flex свой C_Invalid (форма, пределы), не мешаем
	if on:
		if d_socket == null or not is_instance_valid(other) or not d_socket.overlaps_area(other):
			return
		if not _snap_rejected.has(other):
			_snap_rejected.append(other)
	else:
		_snap_rejected.erase(other)
	# сокеты соседа могли удалиться без сигнала выхода
	_snap_rejected = _snap_rejected.filter(
		func(a): return is_instance_valid(a) and not a.is_queued_for_deletion())
	var bad := not _snap_rejected.is_empty()
	if bad and not entity.has_comp(C_Invalid):
		entity.add_component(C_Invalid.new())
	elif not bad and entity.has_comp(C_Invalid):
		entity.remove_component(C_Invalid)
	if not bad:
		snap_reject_reason = ""
	_update_reject_hint()


## Метка над призраком или траком в драге: почему снап отклонён и что делать. Для подземного положения это разворот
## на 180° (пандус вниз к траку на столе: стыковать нижним концом). Q/E крутят на ROT_STEP = 45°, значит 4 нажатия
func _update_reject_hint() -> void:
	if _snap_rejected.is_empty() or snap_reject_reason == "":
		if _hint:
			_hint.queue_free()
			_hint = null
		return
	if _hint == null:
		_hint = TrackNote.line(entity, &"snap", 1)   # под строкой уровня, не поверх нее
		_hint.modulate = Color(1.0, 0.35, 0.35)
		_hint.position = Vector3(0.0, 6.0, 0.0)
	if snap_reject_reason == "underground":
		_hint.text = "Под землёй: разверни на 180° (Q/E ×4)"
	elif snap_reject_reason == "bank":
		_hint.text = "Крен не совпадает: больше %.0f°" % Global.settings.joint_bank_max_deg   # XX claude-coaster C5.4
	elif snap_reject_reason == "network":
		_hint.text = "Другая сеть: дорога не стыкуется с рельсом"   # XX claude-car CS1
	else:
		_hint.text = "Излом по вертикали больше %.0f°" % Global.settings.joint_kink_max_deg


## Есть ли отказ снапа (DragTool: на дропе такой трак возвращается на место)
func has_snap_rejection() -> bool:
	return not _snap_rejected.is_empty()


## Сброс отказов, например после драга
func clear_snap_rejection() -> void:
	_snap_rejected.clear()
	snap_reject_reason = ""
	_update_reject_hint()
	if not entity.has_comp(C_FlexShape) and entity.has_comp(C_Invalid):
		entity.remove_component(C_Invalid)


## Публичная проверка для вертикального магнита: сокет свободен (нет стабильного соседа)
func is_socket_free(area: Area3D) -> bool:
	return not _is_socket_occupied(area)


## Форма пути изменилась (flex): переставляем СУЩЕСТВУЮЩИЕ Area3D, не пересоздаем.
## Пересоздание сбрасывает overlaps (угроза Infinite Rebuild Loop из TDD).
func on_curve_changed(_data: Dictionary) -> void:
	var path_comp := get_comp(C_Path) as C_Path
	if not path_comp or not path_comp.curve or not path_comp.path_node or sockets.size() < 2:
		return
	if path_comp.is_multi_route():
		return   # XX claude-switch: форма стрелки статична, сокеты не двигаем (3 штуки, не 2)
	var c := path_comp.curve
	var length := c.get_baked_length()
	var xf := path_comp.path_node.transform
	var p0 := c.sample_baked(0.0)
	var p1 := c.sample_baked(length)
	# наружу: в начале назад по касательной, в конце вперед
	var d0 := -(-c.sample_baked_with_rotation(0.0).basis.z).normalized()
	var d1 := (-c.sample_baked_with_rotation(length).basis.z).normalized()
	var ends := [[p0, d0], [p1, d1]]
	for i in 2:
		sockets[i].pos = ends[i][0]
		sockets[i].out_dir = ends[i][1]
		#_orient_area(sockets[i].socket, xf * ends[i][0], ends[i][1])
		_orient_area(sockets[i].socket, xf * ends[i][0] + Vector3(0.0, _surface_lift(), 0.0), ends[i][1])
		sockets[i].socket.set_meta(&"joint_up", TrackMeshBuilder.frame(c, 0.0 if i == 0 else length, length).u)   # XX claude-coaster C5.4

# XX claude-terra
## Включает/выключает конкретный сокет (index 0 начало, 1 конец, -1 все). Шлет flex-призрак:
## пока ставится начало/тянется конец, сокеты не должны сами снапить призрак.
func on_socket_enabled(data: Dictionary) -> void:
	var idx: int = data.get("index", -1)
	var on: bool = data.get("enabled", true)
	for k in sockets.size():
		if idx >= 0 and k != idx:
			continue
		var a: Area3D = sockets[k].socket
		a.set_deferred("monitoring", on)
		a.set_deferred("monitorable", on)

## Сокеты на поверхности катания, не у основания: стык двух стилей выравнивается по рельсам
func _surface_lift() -> float:
	var p := get_comp(C_Path) as C_Path
	return p.head_height() if p else 0.0
	
## ==== МАРКЕРЫ ====

# Шарик 
func _add_marker(_node, _color = Color.RED):
	if not Global.debug_markers:
		return
	# Визуальный маркер (шарик)
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.08
	sphere.height = 0.16
	marker.mesh = sphere
	
	# Красный материал
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color
	mat.emission_enabled = true

	marker.material_override = mat
	# поставить на кончик капсулы
	marker.position = Vector3(0, 1.5, 0)
	_node.add_child(marker)



# Конус
func _add_cone(_pos, _color = Color.BURLYWOOD):
	if not Global.debug_markers:
		return
	var marker := MeshInstance3D.new()

	var cone := CylinderMesh.new()
	cone.top_radius = 0.01
	cone.bottom_radius = 0.12
	cone.height = 2
	marker.mesh = cone
	
	#marker.position = _p.transform * (_pos) # Если _p закидываем в функцию
	marker.position = _pos
	marker.position.y += 0.8
	# материал
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color
	mat.emission_enabled = true
	marker.material_override = mat
	
	entity.add_child(marker)
