class_name C_Bogie extends ICapability

class BogieData:
	var id: int
	var config: BogieConfig 	# конфиг конкретного боги из identity
	var pivot: Node3D              # Корневая нода тележки (из сцены)
	var raycast: RayCast3D          # Датчик рельса под тележкой
	var ray_home := Vector3.ZERO   # XX claude-terra штатная локальная позиция датчика (луч временно смещаем и возвращаем)
	var current_track: Entity
	var track_distance: float = 0.0
	var route: int = 0   # XX claude-switch: номер маршрута на кроссе (C_Path.curve_of). Остальным траком не важен
	## XX claude-coaster C2: знак движения при current_speed > 0 вдоль сплайна (+1 к концу, −1 к началу) на траке БЕЗ C_PowerTrack.
	## На траке с питанием его не читают: там знак даёт полярность (см. C_Bogie.dir_of)
	var dir_sign: float = 1.0
	## XX claude-coaster C5.3: «верх» поверхности трака под тележкой в мире (Vector3.UP, пока у трака нет крена)
	var up: Vector3 = Vector3.UP
	var calculated_global_pos: Vector3
	var calculated_global_basis: Basis
	## Мировой базис узла по хорде его осей (как его выставил расчёт). Нужен, чтобы после перемещения кузова считать допуски точно
	var world_basis := Basis.IDENTITY
	## Точка узла на рельсе (центровка по BogieConfig.axle_balance), считается только при lateral_play > 0
	var rail_pos := Vector3.ZERO
	#var is_front: bool = false # уже не надо

var is_derailed: bool = false

# XX claude-switch: вагоны с тележками в группе, по ней C_Switch проверяет замок (стрелку под вагоном не переложить)
const GROUP := &"bogie_owner"


# Сами боги, их id, конфиги из TrainVisual перекидываются сюда
var bogies_data: Array[BogieData] = []

## Конфиги тележек из паспорта (WagonConfig.bogie_configs). Задает BogieSetting до add_component
var bogie_configs: Array[BogieConfig] = []

# все колеса {'wheel_node', 'radius'}
var wheel_nodes: Array[Dictionary] = [] 

## Вес точки кузова на хорде от первой тележки к последней (BogieMath.anchor_weight): начало вагона лежит там.
## 0.5 у симметричных тележек. Считается один раз по положению узлов в модели
var body_anchor_w := 0.5

## Номера тележек, у которых своя копия конфига (правили в DebugPanel), паспорт типа не затронут
var _own_configs: Dictionary = {}


func on_added() -> void:
	entity.add_to_group(GROUP)   # XX claude-switch
	#Собираем массив данных боги (bogie_configs задал BogieSetting)

	# Принимаем контроль боги из визуала
	var comp = entity.get_comp(C_TrainVisual)
	var bogie_nodes = comp.bogie_nodes
	
	wheel_nodes = comp.wheel_nodes
	if comp.rig != null:
		bogie_configs = comp.bogie_configs   # тележки собраны из модели (ModelRig): конфиги оттуда, паспортные не используются
	
	# Формируем массив данных боги 
	for i in range(bogie_nodes.size()):
		var bogie = bogie_nodes[i]
		_create_bogies_data(i, bogie_configs[i], bogie)
	
	# Сортировка от первой тележки к последней
	bogies_data.sort_custom(func(a, b): return a.pivot.position.z < b.pivot.position.z)
	if bogies_data.size() > 1:
		body_anchor_w = BogieMath.anchor_weight(bogies_data.front().pivot.position.z, bogies_data.back().pivot.position.z)
		if body_anchor_w < -0.25 or body_anchor_w > 1.25:
			push_warning("[C_Bogie] %s: начало вагона далеко за крайними тележками (вес %.2f): проверьте b_offset_z и модель" % [entity.name, body_anchor_w])



func _create_bogies_data(_id: int, _config: BogieConfig, bogie:Node3D) -> void:
	
	var data = BogieData.new()
	data.id = _id
	data.config = _config
	data.pivot = bogie
	data.raycast = bogie.get_node('RayCast3D')
	data.ray_home = data.raycast.position   # XX claude-terra
	#data.is_front = bogie.position.z < 0.0
	data.calculated_global_pos = bogie.position

	bogies_data.append(data)



# ==========================================
# ПУБЛИЧНЫЙ ИНТЕРФЕЙС / API
# ==========================================
#"track","offset","is_flipped"
# Вызывается из шасси при посадке вагона на рельс. Готовит данные боги дата к снапу вагона
# Возвращает массив расчетных позиций боги Первая - фронт, последняя - реар
func set_track_to_bogies_data(track_data: Dictionary, w_flipped: bool) -> Dictionary:
	is_derailed = false
	var track = track_data.get("track")
	var offset = track_data.get("offset", 0.0)
	
	if not is_instance_valid(track) or not track.has_comp(C_Path): return {}
		
	var path_comp = track.get_comp(C_Path)
	var route: int = track_data.get("route", 0)   # XX claude-switch
	var curve_len = path_comp.curve_of(route).get_baked_length()

	# "bogie_hits" (посадка после загрузки): у каждой тележки свой трак и свое положение на нем. Так вагон на стыке
	# траков (тележки на разных траках, обычное дело на коротких пандусах и эстакадах) не сжимается на трак первой тележки
	var hits := {}
	for h in track_data.get("bogie_hits", []):
		hits[h.bogie_id] = h
	
	for bogie in bogies_data:
		if hits.has(bogie.id):
			var hit: Dictionary = hits[bogie.id]
			var hit_track: Entity = hit.track
			if is_instance_valid(hit_track) and hit_track.has_comp(C_Path):
				var hit_path := hit_track.get_comp(C_Path) as C_Path
				bogie.current_track = hit_track
				bogie.route = hit.route
				bogie.track_distance = clampf(hit.distance, 0.0, hit_path.curve_of(hit.route).get_baked_length())
				bogie.dir_sign = 1.0   # XX claude-coaster C2: согласуем после цикла
				_assist_update_calc_global_pos(bogie)
				continue
		bogie.current_track = track
		bogie.route = route
		bogie.dir_sign = 1.0   # XX claude-coaster C2
		
		# Если вагон посажен мордой против сплайна (w_flipped = true), 
		# передняя тележка (у которой Z < 0) должна оказаться ближе к началу сплайна (0.0).
		var placement_dir = 1.0 if w_flipped else -1.0
		var initial_dist = offset + (bogie.pivot.position.z * placement_dir)
		
		bogie.track_distance = clampf(initial_dist, 0.0, curve_len)
		
		# Сразу обновляем глобальные позиции (с учетом словаря из прошлого шага)
		_assist_update_calc_global_pos(bogie)# , w_flipped) 
		
	_assist_align_directions()   # XX claude-coaster C2: тележки на разных траках горок смотрят в одну сторону

	# Возвращаем словарь крайних точек для хорды
	if bogies_data.size() > 0:
		return {
			"front": bogies_data.front().calculated_global_pos,
			"rear": bogies_data.back().calculated_global_pos
		}
	return {}




## Главный шаг расчета позиций в physics_process
# Не используется - is_w_flipped - разворот вагона по отношению к траку не имеет значения - он будет двигаться по полярности питания. 
# Направление расчитывается от флипа трака относительно направления питания контура
func calculate_next_positions(delta: float, speed: float)  -> Dictionary:#, is_w_flipped: bool)  -> Dictionary:
	var bogies_pos = {}
	#var bogies_pos = [] # массив расчетных позиций боги
	if is_derailed: return bogies_pos
	
	for bogie in bogies_data:
		_assist_move_bogie(bogie, delta, speed)
		_assist_check_transition(bogie)
		_assist_update_calc_global_pos(bogie)

	# Независимо от того, 2 оси у нас или 5, кузов строится по первой и последней:
	return {
		"front": bogies_data.front().calculated_global_pos,
		"rear": bogies_data.back().calculated_global_pos
		}




# ==========================================
# ВСПОМОГАТЕЛЬНЫЕ АССИСТ-ФУНКЦИИ (HELPERS)
# ==========================================

## Математический шаг по сплайну с учетом is_flipped трака
func _assist_move_bogie(bogie: BogieData, delta: float, speed: float) -> void:
	if not is_instance_valid(bogie.current_track): return
	# Формула: 
	# 1️⃣ если вагон развернут, локальное смещение тележки НЕ инвертируется относительно сплайна
	# 2️⃣ если трак  развернут, локальное смещение тележки инвертируется относительно сплайна
	# Разворот трака держит C_PowerTrack
	# Учитываем инверсию трака: с питанием по полярности (XX claude-switch), без питания по знаку тележки (XX claude-coaster C2)
	bogie.track_distance += speed * delta * dir_of(bogie)




## Знак движения тележки при current_speed > 0 вдоль сплайна её трака: +1 к концу, −1 к началу.
## Трак с питанием: полярность контура (flip_of). Трак без питания (горки): запомненный знак тележки (dir_sign).
## XX claude-coaster C2: раньше без питания знак был всегда +1, и на стыке траков, повёрнутых друг к другу
## «задом наперёд», вагон ехал бы обратно
func dir_of(bogie: BogieData) -> float:
	if is_instance_valid(bogie.current_track):
		var pt := bogie.current_track.get_comp(C_PowerTrack) as C_PowerTrack
		if pt != null:
			return -1.0 if pt.flip_of(bogie.route) else 1.0   # XX claude-switch: луч кросса
	return bogie.dir_sign


## Мировая касательная сплайна тележки в её текущей точке (в сторону роста длины)
func _assist_tangent_of(bogie: BogieData) -> Vector3:
	var pc := bogie.current_track.get_comp(C_Path) as C_Path
	var crv: Curve3D = pc.curve_of(bogie.route)
	var t := crv.sample_baked_with_rotation(clampf(bogie.track_distance, 0.0, crv.get_baked_length()))
	return (pc.path_node.global_basis * -t.basis.z).normalized()


## После перехода на новый трак: если он без питания, знак выбираем так, чтобы движение продолжилось в ту же сторону
func _assist_inherit_direction(bogie: BogieData, positive_dir: Vector3) -> void:
	if not is_instance_valid(bogie.current_track) or bogie.current_track.has_comp(C_PowerTrack):
		return   # трак с питанием: знак даёт полярность
	bogie.dir_sign = BogieDirection.inherit(positive_dir, _assist_tangent_of(bogie), bogie.dir_sign)


## Посадка и загрузка: тележки одного вагона на разных траках горок (стык, загрузка по bogie_hits) должны двигаться
## в одну сторону. Эталон это первая тележка, остальным знак берём по её направлению
func _assist_align_directions() -> void:
	if bogies_data.size() < 2:
		return
	var ref := bogies_data[0]
	if not is_instance_valid(ref.current_track):
		return
	var ref_dir := _assist_tangent_of(ref) * dir_of(ref)
	for i in range(1, bogies_data.size()):
		var b := bogies_data[i]
		if is_instance_valid(b.current_track) and not b.current_track.has_comp(C_PowerTrack):
			b.dir_sign = BogieDirection.inherit(ref_dir, _assist_tangent_of(b), b.dir_sign)


## XX claude-coaster C6.0: можно ли въехать на соседний трак в точке gpos. Нужен конец его кривой рядом и касательная вдоль хода
## (JointMath.can_enter). Не конец (Т-стык, трак поперёк) или трак под большим углом: тележка не переходит, а сходит с конца
func _assist_can_enter(next_path: C_Path, gpos: Vector3, travel_dir: Vector3) -> bool:
	var route := next_path.entry_route(gpos)
	var nc: Curve3D = next_path.curve_of(route)
	if nc == null or next_path.path_node == null:
		return true   # данных нет: прежнее поведение
	var l := nc.get_baked_length()
	var ta := nc.sample_baked_with_rotation(0.0)
	var tb := nc.sample_baked_with_rotation(l)
	var nb: Basis = next_path.path_node.global_basis
	var gs = Global.settings
	return JointMath.can_enter(gpos, next_path.path_node.to_global(ta.origin), next_path.path_node.to_global(tb.origin),
			(nb * -ta.basis.z).normalized(), (nb * -tb.basis.z).normalized(), travel_dir,
			gs.joint_transition_gap_max, gs.joint_transition_max_deg)


#### Резервный переход через границы/сокеты (если рейкаст на мгновение потерял рельс)
func _assist_check_transition(bogie: BogieData) -> void:
	if not is_instance_valid(bogie.current_track): return
	
	var path_comp = bogie.current_track.get_comp(C_Path)
	var crv: Curve3D = path_comp.curve_of(bogie.route)   # XX claude-switch
	var curve_len = crv.get_baked_length()

	# 1. Тележка в пределах текущего сплайна — переход не нужен
	if bogie.track_distance >= 0.0 and bogie.track_distance <= curve_len:
		return 
	
	# 2. Вычисляем "перебег" (overflow) в зазоре
	var is_exiting_end = bogie.track_distance > curve_len
	var overflow = bogie.track_distance - curve_len if is_exiting_end else bogie.track_distance
	
	# 3. Получаем крайнюю точку и глобальный вектор вылета (касательную)
	var edge_offset = curve_len if is_exiting_end else 0.0
	
	var edge_transform = crv.sample_baked_with_rotation(edge_offset)
	var edge_global_pos = path_comp.path_node.to_global(edge_transform.origin)
	
	# В Godot вперед - это -Z
	var global_forward = (path_comp.path_node.global_basis * -edge_transform.basis.z).normalized()
	# XX claude-coaster C2: мировое направление движения при current_speed > 0 в точке стыка (до смены трака)
	var positive_dir: Vector3 = global_forward * dir_of(bogie)
	if not is_exiting_end:
		global_forward = -global_forward # Инвертируем, если вылетели с нулевой отметки
		
	# Экстраполируем глобальную позицию тележки в воздухе над зазором
	var extrapolated_pos = edge_global_pos + (global_forward * abs(overflow))

	# 4. Стреляем рейкастом для поиска нового рельса
	if is_instance_valid(bogie.raycast):
		# Смещаем луч чуть вперед по вектору, чтобы "перепрыгнуть" пустоту зазора (~0.2)
		var look_ahead_pos = extrapolated_pos + (global_forward * 0.1)
		
		# XX claude-terra: старт луча = высота поверхности трака в точке экстраполяции + подъем датчика над поверхностью.
		# Раньше look_ahead_pos + Vector3(0, sensor_pos.y, 0) складывало высоту дважды (на траке выше стола луч
		# стартовал слишком высоко), а датчик навсегда оставался смещенным относительно тележки.
		var track_h = path_comp.head_height()

		## моя‼️Замена b_offset на b_offset_z
		var b_off_y = bogie.config.wheel_pair_position.y if bogie.config else 0.0
		var lift = track_h + b_off_y + bogie.ray_home.y
		# XX claude-coaster C5.3: подъём датчика вдоль «верха» трака (без крена это Vector3.UP: прежнее смещение по Y)
		var ray_up: Vector3 = path_comp.surface_up_at(bogie.track_distance, bogie.route)
		bogie.raycast.global_position = look_ahead_pos + ray_up * lift
		bogie.raycast.force_raycast_update()
		var ray_hit = bogie.raycast.is_colliding()
		var ray_collider = bogie.raycast.get_collider() if ray_hit else null
		bogie.raycast.position = bogie.ray_home   # возвращаем датчик на место

		if ray_hit:
			var hit_entity = _find_entity_from_collider(ray_collider)
			
			# Если нащупали новый трак
			# XX claude-switch: стрелка пускает только со стороны концов активного маршрута
			if is_instance_valid(hit_entity) and hit_entity != bogie.current_track and hit_entity.has_comp(C_Path) \
					and hit_entity.get_comp(C_Path).entry_route(extrapolated_pos) >= 0 \
					and _assist_can_enter(hit_entity.get_comp(C_Path), extrapolated_pos, positive_dir):   # XX claude-coaster C6.0
				var next_path = hit_entity.get_comp(C_Path)
				
				# Переводим глобальную точку полета в локальную систему нового трака
				var local_hit_pos = next_path.path_node.to_local(extrapolated_pos)
				
				# Проецируем на новую кривую. Это автоматически решает все стыки (1-0, 0-1)
				bogie.current_track = hit_entity
				bogie.route = next_path.entry_route(extrapolated_pos)   # XX claude-switch
				bogie.track_distance = next_path.curve_of(bogie.route).get_closest_offset(local_hit_pos)
				_assist_inherit_direction(bogie, positive_dir)   # XX claude-coaster C2
				return
	
	# 5. Если улетели за пределы толерантности зазора (0.4м) и ничего не нащупали — дерейл
	if abs(overflow) > 0.4:
		is_derailed = true



#### Получение глобальной координаты на сплайне с поддержкой экстраполяции над зазором
func _assist_sample_pos_with_extrapolation(path_comp: C_Path, distance: float, curve_len: float, route: int = 0) -> Vector3:
	var crv: Curve3D = path_comp.curve_of(route)   # XX claude-switch
	if distance >= 0.0 and distance <= curve_len:
		var transform_baked = crv.sample_baked_with_rotation(distance)
		return path_comp.path_node.to_global(transform_baked.origin)
	else:
		var is_exiting_end = distance > curve_len
		var overflow = distance - curve_len if is_exiting_end else distance
		var edge_offset = curve_len if is_exiting_end else 0.0
		
		var edge_transform = crv.sample_baked_with_rotation(edge_offset)
		var edge_global_pos = path_comp.path_node.to_global(edge_transform.origin)
		
		var global_forward = (path_comp.path_node.global_basis * -edge_transform.basis.z).normalized()
		if not is_exiting_end:
			global_forward = -global_forward
			
		return edge_global_pos + (global_forward * abs(overflow))



#### Обновление позиций и доворот (YAW) ноды тележки по хорде колесных пар
func _assist_update_calc_global_pos(bogie: BogieData) -> void:
	if not is_instance_valid(bogie.current_track): return
	
	var path_comp = bogie.current_track.get_comp(C_Path)
	var curve_len = path_comp.curve_of(bogie.route).get_baked_length()   # XX claude-switch
	var track_h = path_comp.head_height()
	var wp_z = bogie.config.half_base() if bogie.config else 0.0   # полубаза: у узла из 3 и больше осей это расстояние до крайней
	# XX claude-coaster C5.3: «верх» поверхности под тележкой. Без крена ровно Vector3.UP: подъём на head_height по Y и
	# Basis.looking_at(…, UP) остаются прежними; с креном подъём и поворот идут вдоль повёрнутого «верха»
	var up: Vector3 = path_comp.surface_up_at(bogie.track_distance, bogie.route)
	bogie.up = up
	
	# --- ИСПРАВЛЕНИЕ: Получаем данные о развороте трака ---
	var is_track_flipped := dir_of(bogie) < 0.0   # XX claude-switch (питание), XX claude-coaster C2 (без питания)
	# --------------------------------------------------------
	
	if wp_z > 0.001:
		# Двухосная тележка: считаем крайние точки колесных пар (front/rear)
		var front_pos = _assist_sample_pos_with_extrapolation(path_comp, bogie.track_distance + wp_z, curve_len, bogie.route)
		var rear_pos = _assist_sample_pos_with_extrapolation(path_comp, bogie.track_distance - wp_z, curve_len, bogie.route)
		
		# Центр тележки — точка посередине между осями
		bogie.calculated_global_pos = (front_pos + rear_pos) / 2.0
		bogie.calculated_global_pos += up * track_h
		
		# Поворот pivot тележки строго по вектору между осями
		var forward_dir = (front_pos - rear_pos).normalized()
		
		# --- ИСПРАВЛЕНИЕ: Инвертируем вектор для 2-осной тележки, если сплайн встречный (1-1) ---
		if is_track_flipped:
			forward_dir = -forward_dir
		# ----------------------------------------------------------------------------------------
		
		if is_instance_valid(bogie.pivot) and forward_dir.length_squared() > 0.001:
			bogie.world_basis = Basis.looking_at(forward_dir, up)
			bogie.pivot.global_basis = bogie.world_basis
		# Точка узла для поперечного хода: между серединой хорды крайних осей и точкой рельса в центре узла
		if bogie.config and bogie.config.lateral_play > 0.0:
			var arc_pos = _assist_sample_pos_with_extrapolation(path_comp, bogie.track_distance, curve_len, bogie.route)
			bogie.rail_pos = ((front_pos + rear_pos) / 2.0).lerp(arc_pos, bogie.config.axle_balance) + up * track_h
	else:
		# Одноосная тележка: расчет по центральной точке
		bogie.calculated_global_pos = _assist_sample_pos_with_extrapolation(path_comp, bogie.track_distance, curve_len, bogie.route)
		bogie.calculated_global_pos += up * track_h
		
		if is_instance_valid(bogie.pivot):
			var transform_baked = path_comp.curve_of(bogie.route).sample_baked_with_rotation(clampf(bogie.track_distance, 0.0, curve_len))
			var global_forward = (path_comp.path_node.global_basis * -transform_baked.basis.z).normalized()
			
			# --- ИСПРАВЛЕНИЕ: Инвертируем вектор для 1-осной тележки, если сплайн встречный (1-1) ---
			if is_track_flipped:
				global_forward = -global_forward
			# --------------------------------------------------------------------------------
			
			if global_forward.length_squared() > 0.001:
				bogie.world_basis = Basis.looking_at(global_forward, up)
				bogie.pivot.global_basis = bogie.world_basis
			bogie.rail_pos = bogie.calculated_global_pos
				
				
				

## ===============================
## Питание под тележками: одно решение для мотора и света (ATTN_10 §10.5.6, D3).
## Берется тележка с наибольшим |V|. Ведущая тележка меняется, только если другая сильнее больше чем на `SUPPLY_HYSTERESIS`:
## на изостыке со встречным питанием направление не дергается туда-сюда.
## Возвращает {"net": метка цепи (0 нет питания), "voltage": % со знаком, "bogie": индекс или -1}
const SUPPLY_HYSTERESIS := 0.5
var _supply_idx := -1

func best_supply() -> Dictionary:
	var volts: Array[float] = []
	var nets: Array[int] = []
	var best := -1
	var best_abs := 0.0
	for i in bogies_data.size():
		var bogie := bogies_data[i]
		var net := 0
		var v := 0.0
		if is_instance_valid(bogie.current_track):
			var pt := bogie.current_track.get_comp(C_PowerTrack) as C_PowerTrack
			if pt != null:
				net = pt.contour_of(bogie.route)
				if net != 0:
					v = PGM.get_power(net)
		nets.append(net)
		volts.append(v)
		# при равенстве побеждает меньшая метка цепи, затем меньший индекс: результат не зависит от порядка обхода
		if absf(v) > best_abs + 0.001 or (best >= 0 and absf(absf(v) - best_abs) <= 0.001 and v != 0.0 and net < nets[best]):
			best = i
			best_abs = absf(v)
	if best < 0:
		_supply_idx = -1
		return {"net": 0, "voltage": 0.0, "bogie": -1}
	if _supply_idx >= 0 and _supply_idx < volts.size() and nets[_supply_idx] != 0 and volts[_supply_idx] != 0.0:
		if best_abs <= absf(volts[_supply_idx]) + SUPPLY_HYSTERESIS:
			best = _supply_idx
	_supply_idx = best
	return {"net": nets[best], "voltage": volts[best], "bogie": best}


func _physics_process(delta: float) -> void:
	wheel_rotate(delta)
	
	
func wheel_rotate(delta):
	
	var comp_chassis = entity.get_comp(C_Chassis) as C_Chassis
	var comp_kinem = entity.get_comp(C_Kinematics) as C_Kinematics
	var speed_real = 0.0
	var wheel_speed = 0.0
	if comp_chassis.is_on_rails	:
		speed_real = comp_chassis.current_speed 
		wheel_speed =  comp_chassis.wheel_surface_speed 
	else: 
		# Продольная скорость кузова, как в C_Kinematics._update_wheel_speed: вертикаль падения и боковой юз колёса не крутят
		var rb = comp_kinem.rb
		speed_real = rb.linear_velocity.dot(-rb.global_basis.z)
		wheel_speed = comp_kinem.wheel_surface_speed 
		# Драг мышью гонит тело своей скоростью, колёса при этом не крутятся: это не проскальзывание
		if comp_kinem.is_dragging:
			speed_real = 0.0
			wheel_speed = 0.0

	# Стоим и колёса стоят: без сброса slip_blend залипал на последнем значении (красный на полу после дропа)
	# Колёса могут крутиться и на стоящем шасси (буксуют в упоре), поэтому смотрим на обе скорости
	if abs(speed_real) < 0.01 and abs(wheel_speed) < 0.01:
		_set_wheels_slip(0.0)
		return

	for wheel in wheel_nodes:
		# Диаметр 
		var _r: float = wheel.radius

		# Переводим линейную скорость колеса в угловую скорость (радианы в секунду)
		var _angular_velocity = -wheel_speed / _r
		# Применяем вращение к мешам колесных пар вокруг локальной оси X
		wheel.wheel_node.rotate_object_local(Vector3.RIGHT, _angular_velocity * delta)
		wheel['angle'] = fposmod(float(wheel.get('angle', 0.0)) + _angular_velocity * delta, TAU)   # накопленный угол: по нему идёт фаза привода
		
		# Считаем проскальзывание для шейдера
		# XX claude замена
		var slip_amount = abs(abs(speed_real) - abs(wheel_speed))
		#var slip_amount = abs(speed_real - wheel_speed) 
		var max_expected_slip = 3.0 # макс скорость, на которую шейдер будет срабатывать
		
		# Отправляем параметр slip в материал колеса
		var slip_normalized = clampf(slip_amount / max_expected_slip, 0.0, 1.0)

		_set_wheel_slip(wheel, slip_normalized)


## Фаза колеса 0..1 за оборот (BogieMath.wheel_phase): ход вперёд увеличивает фазу, по ней идёт цикл привода (WHEEL_PHASE).
## role: роль колеса модели (wheel_<n>_<k>); пусто или другая роль: самое большое колесо (у паровоза ведущее). Колёс нет: 0
func wheel_phase(role: StringName = &"") -> float:
	var w := _phase_wheel(role)
	if w.is_empty():
		return 0.0
	return BogieMath.wheel_phase(float(w.get('angle', 0.0)))


var _phase_cache := {}   # роль -> колесо (словарь из wheel_nodes)


func _phase_wheel(role: StringName) -> Dictionary:
	if role != &"" and ModelRig.parse_wheel(String(role)).is_empty():
		role = &""   # роль не похожа на колесо (в MechanismConfig part_role по умолчанию другое): берём ведущее
	if _phase_cache.has(role):
		return _phase_cache[role]
	var best := {}
	for w in wheel_nodes:
		if role != &"":
			if w.get('role', &"") == role:
				best = w
				break
		elif best.is_empty() or float(w.radius) > float(best.radius) + 0.001:
			best = w
	if best.is_empty() and role != &"":
		push_warning("[C_Bogie] %s: колесо с ролью '%s' не найдено, фаза привода не считается" % [entity.name if entity else "?", role])
	_phase_cache[role] = best   # и пустой результат: не искать каждый кадр
	return best


## Допуски узлов (BogieConfig.lateral_play и yaw_limit_deg): узел сдвигается поперёк кузова к своей точке на рельсе и не поворачивается
## относительно кузова больше предела. Зовётся после того, как кузов поставлен (C_Chassis), body_xf это итоговый transform кузова.
## Узлы без допусков (по умолчанию все) не трогаются
func has_tolerances() -> bool:
	for bd in bogies_data:
		if bd.config != null and (bd.config.lateral_play > 0.0 or bd.config.yaw_limit_deg < 179.0):
			return true
	return false


func apply_tolerances(body_xf: Transform3D) -> void:
	var inv := body_xf.affine_inverse()
	for bd in bogies_data:
		var cfg := bd.config
		if cfg == null or not is_instance_valid(bd.pivot):
			continue
		var lateral := cfg.lateral_play > 0.0
		var limit_yaw := cfg.yaw_limit_deg < 179.0
		if not lateral and not limit_yaw:
			continue
		# Базис в осях кузова из мирового по хорде осей: точно по текущему кузову, без отставания на кадр
		var local_basis := inv.basis * bd.world_basis
		if limit_yaw:
			local_basis = BogieMath.clamp_yaw(local_basis, cfg.yaw_limit_deg)
		bd.pivot.basis = local_basis
		if lateral:
			bd.pivot.position.x = BogieMath.clamp_lateral((inv * bd.rail_pos).x, cfg.lateral_play)


## Все колёса без проскальзывания (шейдер в нормальный цвет)
func _set_wheels_slip(value: float) -> void:
	for wheel in wheel_nodes:
		_set_wheel_slip(wheel, value)


## Пишем в материал только при изменении: set_shader_parameter каждый кадр на каждое колесо лишний
func _set_wheel_slip(wheel: Dictionary, value: float) -> void:
	if absf(float(wheel.get('slip', -1.0)) - value) < 0.002:
		return
	wheel['slip'] = value
	for _mesh in wheel.meshes:
		var mat := (_mesh as MeshInstance3D).material_overlay as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("slip_blend", value)




func _find_entity_from_collider(collider: Node) -> Entity:
	var curr: Node = collider
	while curr:
		if curr is Entity: return curr as Entity
		curr = curr.get_parent()
	return null
#


## Для DebugPanel (U14): конфиг тележки с номером i (номер в WagonConfig.bogie_configs). null, если такой нет
func bogie_config(i: int) -> BogieConfig:
	for b in bogies_data:
		if b.id == i:
			return b.config
	return null


## Для DebugPanel (U14): конфиг тележки i для правки. Первый вызов делает копию, чтобы правки не меняли общий паспорт типа
func tunable_bogie_config(i: int) -> BogieConfig:
	for b in bogies_data:
		if b.id != i or b.config == null:
			continue
		if not _own_configs.has(i):
			b.config = b.config.duplicate() as BogieConfig
			_own_configs[i] = true
		return b.config
	return null
