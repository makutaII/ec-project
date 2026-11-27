class_name C_Chassis extends ICapability

############################################
## Отвечает за поведение вагона на сплайне
#############################################
# Тело вагона
var rb: RigidBody3D 

var snapped_track: Entity
var current_spline_offset: float = 0.0
var current_speed: float = 0.0
var current_velocity_3d: Vector3 = Vector3.ZERO #скорость вагона в пространстве
var is_on_rails: bool = false # Вагон на рельсах
var is_w_flipped: bool = false # вагон развернут по траку или или нет

# Для дебага вынес в корень, достаточно и в _check_derailment
var centrifugal_force: float

### ==========================================
### НОВЫЕ ПЕРЕМЕННЫЕ ДЛЯ СИЛОВОЙ ПАРАДИГМЫ
### ==========================================
var applied_force: float = 0.0  # Постоянная приложенная сила/тяга (от C_Engine или C_Coupler), Н
var impulse_force: float = 0.0  # Разовый импульс силы (от пинка/удара), Н

# Чтобы сохранить мировое направление хода, если flip трака под передней тележкой сменился на обесточенной цепи
var _dir_track: Object = null
var _dir_route: int = 0
var _dir_flip: bool = false

# Значения из инспектора
var bogie_configs: Array[BogieConfig] = []
## Подвеска из паспорта (WagonConfig.suspension). null = значения по умолчанию. Задает ChassisSetting
var suspension_config: SuspensionConfig = null

# Скорость поверхности колеса (для визуального вращения мешей)
var wheel_surface_speed: float = 0.0

## Колёса в срыве сцепления: крутятся независимо от скорости шасси (wheel_surface_speed != current_speed).
## Читать для визуала пробуксовки (искры): разница wheel_surface_speed - current_speed это скорость проскальзывания
var is_slipping: bool = false
## Мотор тянет (напряжение выше порога страгивания), цель оборотов и жёсткость мотора. Приходят из C_Engine
var motor_active: bool = false
var motor_target: float = 0.0
var motor_k: float = 0.0

### ==========================================
### ПОДВЕСКА КУЗОВА (логика - в SuspensionState, тут только включатели)
### ==========================================
@export_category("Suspension")
## Выключение гасит ВХОДЫ подвески: кузов сам плавно возвращается в покой и подвеска засыпает.
@export var enable_suspension: bool = true
@export var debug_susp_vertical: bool = true  # стыки + неровности пути: heave и pitch от пути
@export var debug_susp_pitch: bool = true     # кивок при разгоне/торможении
@export var debug_susp_roll: bool = true      # крен в кривых
@export var debug_susp_lateral: bool = true   # боковая раскачка, yaw, смещение кузова наружу кривой
@export var debug_susp_hunting: bool = true   # рыскание тележек на скорости
@export var effect_multiplier: float = 1.0    # общий множитель входов

var _susp: SuspensionState
## true: у вагона своя копия SuspensionConfig (правили в DebugPanel), паспорт не затронут
var _susp_is_copy := false

# Кэш ссылок: get_comp() - это линейный поиск по детям, в физ. тике его быть не должно
var _bogie: C_Bogie
var _kin: C_Kinematics
var _is_loco := false

### СЦЕПКА 
### ==========================================
var coupler_force: float = 0.0
var motor_powered: bool = false

# g для качения/тяги (общая с C_Kinematics)
var gravity = RailPhysics.G_ROLL
## Коэффициент силы тяжести вдоль уклона. По умолчанию RailPhysics.GRADE_K; XX claude-coaster C3: C_RideCar подставляет значение из профиля заезда
var grade_k: float = RailPhysics.GRADE_K


func on_force_changed(data: Dictionary) -> void:
	applied_force = data.get("force", 0.0)
	motor_powered = data.get("powered", false)
	motor_active = data.get("active", false)
	motor_target = data.get("target_speed", 0.0)
	motor_k = data.get("motor_k", 0.0)


## Скорость вала мотора для противоЭДС (C_Engine): в сцеплении равна скорости шасси, в срыве скорость колёс
func get_motor_speed() -> float:
	return wheel_surface_speed if is_slipping else current_speed



func on_coupler_force(data: Dictionary) -> void:
	if is_on_rails: coupler_force += data.get("force", 0.0)



func on_impulse(data: Dictionary) -> void:  # Н·с, Δv = J / m
	if is_on_rails: impulse_force += data.get("impulse", 0.0)



## Мировой вектор движения при current_speed > 0 (как в _assist_move_bogie)
func get_motion_axis() -> Vector3:
	var bc := entity.get_comp(C_Bogie) as C_Bogie
	if not bc or bc.bogies_data.is_empty() or not is_instance_valid(bc.bogies_data[0].current_track):
		return -entity.global_basis.z
	var b = bc.bogies_data[0]
	var pc = b.current_track.get_comp(C_Path)
	var crv: Curve3D = pc.curve_of(b.route)   # XX claude-switch
	var t = crv.sample_baked_with_rotation(clampf(b.track_distance, 0.0, crv.get_baked_length()))
	var fwd: Vector3 = (pc.path_node.global_basis * -t.basis.z).normalized()
	return -fwd if bc.dir_of(b) < 0.0 else fwd   # XX claude-switch: луч кросса; XX claude-coaster C2: знак тележки без питания



func on_added():
	rb = get_comp(C_TrainVisual).rb



## Все компоненты уже на месте: кэшируем ссылки и собираем подвеску
func on_entity_ready() -> void:
	_ensure_refs()
	var cfg: SuspensionConfig = suspension_config
	if cfg == null:
		cfg = SuspensionConfig.new() # значения по умолчанию

	_susp = SuspensionState.new()
	_susp.rail_joint.connect(_on_susp_joint)
	_configure_suspension(cfg)


## Собирает производные подвески из конфига: частоты зависят от массы, а упоры и отклики пересчитываются из градусов
func _configure_suspension(cfg: SuspensionConfig) -> void:
	var span := 0.0
	if _bogie and _bogie.bogies_data.size() > 1:
		span = absf(_bogie.bogies_data.back().pivot.position.z - _bogie.bogies_data.front().pivot.position.z)
	_susp.setup(cfg, _kin.mass if _kin else 1.0, span)


## Для DebugPanel (U14): подвеска, которую сейчас использует вагон. null, если вагон еще не собран
func get_suspension_config() -> SuspensionConfig:
	return _susp.cfg if _susp else null


## Для DebugPanel (U14): подвеска этого вагона для правки. Первый вызов делает копию, чтобы правки не меняли
## общий паспорт типа (он один на все вагоны) и не задевали другие вагоны
func get_tunable_suspension() -> SuspensionConfig:
	if _susp == null:
		return null
	if not _susp_is_copy:
		_susp.cfg = _susp.cfg.duplicate() as SuspensionConfig
		_susp_is_copy = true
	return _susp.cfg


## Для DebugPanel (U14): пересчитать подвеску после правки конфига или массы. Колебания кузова обнуляются
func rebuild_suspension() -> void:
	if _susp:
		_configure_suspension(_susp.cfg)


func _ensure_refs() -> void:
	if _bogie != null and _kin != null:
		return
	_bogie = get_comp(C_Bogie) as C_Bogie
	_kin = get_comp(C_Kinematics) as C_Kinematics
	_is_loco = has_comp(C_Engine)


## ⚡ Стык рельс -> наружу в шину (под звук/анимацию). Редкое событие, словарь не страшен.
func _on_susp_joint(bogie_index: int, kind: StringName, strength: float) -> void:
	entity.send_event("on_rail_joint", {"bogie": bogie_index, "kind": kind, "strength": strength})



## Для вкладки Debug в InfoPanel
func get_suspension_debug() -> Array[String]:
	return _susp.get_debug_info() if _susp else ([] as Array[String])

# ==========================================
# ОБРАБОТКА СОБЫТИЙ
# ==========================================

#track_data: "track"- сам трак,"offset" смещение по сплайну ,"is_flipped" - разворот трака в контуре
# Ловит евент от C_TrainDraggable при успешном дропе на рельс

func on_train_snapped(track_data: Dictionary) -> void:
	snapped_track = track_data.get("track")
	current_spline_offset = track_data.get("offset", 0.0)
	
	# === ВЫЧИСЛЯЕМ is_w_flipped НА МЕСТЕ ===
	var path_comp = snapped_track.get_comp(C_Path)
	if path_comp and path_comp.curve:
		# Получаем вектор касательной сплайна в точке посадки
		var curve_transform = path_comp.curve_of(track_data.get("route", 0)).sample_baked_with_rotation(current_spline_offset)   # XX claude-switch
		var track_forward = (path_comp.path_node.global_basis * -curve_transform.basis.z).normalized()
		
		# Берем текущий вектор морды вагона (который нам выставил драг-тул)
		var wagon_forward = -entity.global_basis.z
		
		# Если вектора смотрят навстречу друг другу — вагон перевернут
		is_w_flipped = wagon_forward.dot(track_forward) < 0
	else:
		is_w_flipped = false

	is_on_rails = true
	_reset_wheels()
	if _susp: _susp.reset()
	
	var bogie_comp = entity.get_comp(C_Bogie)
	if not bogie_comp: 	return
		
	#  Синхронизируем тележки с точкой снапа. Вернется массив с правильными позициями боги
	var b_calc_pos = bogie_comp.set_track_to_bogies_data(track_data, is_w_flipped)
	
	# Обновляем позицию вагона по рассчитанным позициям боги
	if b_calc_pos.is_empty(): 
		return
		
	var front_calc_pos = b_calc_pos.front
	var rear_calc_pos = b_calc_pos.rear

	if front_calc_pos != Vector3.ZERO and rear_calc_pos != Vector3.ZERO:
		entity.global_position = front_calc_pos.lerp(rear_calc_pos, bogie_comp.body_anchor_w)   # у симметричных тележек середина хорды

	if rb:
		_assist_rb_to_entity()
		await get_tree().process_frame
		rb.freeze = true
		rb.linear_damp = 2.5
		rb.angular_damp = 2.5



## Как только игрок схватил вагон, отключаем математику рельс,сбрасываем скорость и силы
func on_drag_started(_data: Dictionary) -> void:
	is_on_rails = false
	current_speed = 0.0
	applied_force = 0.0
	impulse_force = 0.0
	coupler_force = 0.0
	_reset_wheels()
	if _susp: _susp.reset()


## Колёса без срыва и без вращения (посадка, драг, сход)
func _reset_wheels() -> void:
	is_slipping = false
	wheel_surface_speed = 0.0



## Пинок. "+" всегда означает "носом вперёд", как в C_Kinematics.
## current_speed > 0 направлен по get_motion_axis() (учитывает разворот контура),
## поэтому знак берём из сравнения носа вагона с этой осью.
func on_train_kicked(data: Dictionary) -> void:
	if not is_on_rails:
		return
	var J = data.get("power_kick", 0.0) * RailPhysics.KICK_IMPULSE_K
	var sgn = signf((-entity.global_basis.z).dot(get_motion_axis()))
	impulse_force += (sgn if sgn != 0.0 else 1.0) * J



### ==========================================
### ИНТЕГРАЦИЯ СИЛ И РАСЧЁТ УСКОРЕНИЯ (ФИЗИКА)
### ==========================================
func _assist_speed_correction(delta: float) -> void:
	var mass: float = _kin.mass
	if mass <= 0.0:
		mass = 1.0
		
	var roll_res: float = _kin.roll_resistance
	var long_grip: float = _kin.longitudinal_grip
	
	var is_loco = _is_loco 

	# РАЗДЕЛЯЕМ силы: тяга мотора и внешний пинок
	var engine_force = applied_force
	var external_kick_force = (impulse_force / delta if delta > 0.0 else 0.0)
	var coupling_force = coupler_force; coupler_force = 0.0
	
	impulse_force = 0.0 

	var wheels_locked = false

	# Питание снято или ниже порога: колёса снова стопорит червяк, буксовать нечему
	if is_slipping and not motor_active:
		is_slipping = false

	# 1. БЛОКИРОВКА ЧЕРВЯЧНОЙ ПЕРЕДАЧИ (Тормоз юзом)
	# Локомотив блокирует колеса только если нет тяги от мотора (в срыве мотор тянет, даже если сила мала)
	if is_loco and abs(engine_force) < 0.01 and not is_slipping:
		roll_res = _kin.locked_wheel_friction 
		wheels_locked = true
		
	# 4. СРЫВ СЦЕПЛЕНИЯ (Пробуксовка)
	var max_traction_force = mass * gravity * long_grip
	var effective_engine_force = engine_force

	# Сцепление ограничивает ТОЛЬКО мотор! Срыв: колёса стартуют со скорости рельса
	if not is_slipping and abs(engine_force) > max_traction_force:
		is_slipping = true
		wheel_surface_speed = current_speed

	# В срыве на шасси работает трение скольжения, оно направлено по проскальзыванию колеса относительно рельса
	var slip_dir := 0.0
	if is_slipping:
		var rel := wheel_surface_speed - current_speed
		slip_dir = sign(rel) if abs(rel) > 0.001 else sign(engine_force)
		effective_engine_force = slip_dir * max_traction_force * RailPhysics.SLIP_KINETIC

	# Итоговая активная сила = обрезанная тяга мотора + неограниченный пинок + сцепка
	var total_active_force = effective_engine_force + external_kick_force + coupling_force
	
	# XX claude-terra: уклон считаем ДО направления движения, чтобы трение покоя держало вагон на горке
	# get_motion_axis() - мировой вектор при current_speed > 0, его y > 0 на подъеме
	var incline_force = mass * RailPhysics.G_ROLL * grade_k * get_motion_axis().y   # XX claude-coaster C3: grade_k вместо константы
	var drive_force = total_active_force - incline_force

	# 2. Направление движения
	var movement_sign = sign(current_speed)
	if movement_sign == 0.0:
		movement_sign = sign(drive_force)

	# 3. Базовое сопротивление (Трение)
	var friction_force = mass * gravity * roll_res * movement_sign

	# 5. Итоговая сила (В ускорение кузова идут обе силы)
	var net_force = drive_force - friction_force

	# 6. Остановка (если стоим и суммарной силы не хватает для старта)	
	if is_loco and not motor_powered and abs(current_speed) < 0.01 \
			and abs(external_kick_force + coupling_force) < 0.01:
		current_speed = 0.0
		wheel_surface_speed = 0.0
		is_slipping = false
		return

	# 7. Интегрирование скорости шасси
	var acceleration = net_force / mass
	var new_speed = current_speed + acceleration * delta

	# 8. Защита от проскакивания нуля при торможении
	if movement_sign != 0.0 and sign(new_speed) != movement_sign and abs(drive_force) < abs(friction_force):   # XX claude-terra
		current_speed = 0.0
	else:
		current_speed = new_speed

	# 9. СКОРОСТЬ ВРАЩЕНИЯ КОЛЕС (Для боги)
	if wheels_locked:
		wheel_surface_speed = 0.0 # Колеса стоят, локо скользит юзом
	elif is_slipping:
		_spin_slipping_wheels(delta, effective_engine_force)
		# Сцепление возвращается, когда колёса догнали рельс и мотор снова укладывается в предел
		if abs(wheel_surface_speed - current_speed) < RailPhysics.SLIP_REGAIN_DV and abs(engine_force) <= max_traction_force:
			is_slipping = false
			wheel_surface_speed = current_speed
	else:
		wheel_surface_speed = current_speed


## Колёса в срыве: мотор раскручивает их к своей цели, трение скольжения тормозит. Неявный шаг, устойчив при любом dt.
## Колёса блокирует упор или затор (шасси стоит), а мотор раскручивает их до оборотов холостого хода
func _spin_slipping_wheels(delta: float, friction_on_body: float) -> void:
	if motor_k <= 0.0 or delta <= 0.0:
		wheel_surface_speed = motor_target
		return
	var tau := RailPhysics.WHEEL_SPINUP_TAU
	var drag := friction_on_body / motor_k # реакция трения на колесо, в единицах скорости (против силы на шасси)
	wheel_surface_speed = (tau / delta * wheel_surface_speed + motor_target - drag) / (tau / delta + 1.0)



## Если это Локомотив, скорость будет приходить от C_Engine.
## Если вагон — от пинка выше или C_Coupler (тяга соседнего вагона).
func on_speed_changed(data: Dictionary) -> void:
	current_speed = data.get("speed", 0.0)
	_check_derailment() # проверка схода



## Проверка схода. Такая же есть в кинематикс, зачем?
func _check_derailment() -> void:
	if  not is_on_rails: return
	_ensure_refs()
	var bogie_comp := _bogie
	if not bogie_comp or bogie_comp.bogies_data.is_empty(): return
		
	# Берем переднюю тележку для проверки
	var front_bogie = bogie_comp.bogies_data[0]
	var actual_track = front_bogie.current_track
	
	# СЦЕНАРИЙ 1.1: Рельсы кончились
	if not is_instance_valid(actual_track):
		entity.send_event("on_derailed", {"reason": "end_of_track", "current_velocity_3d": current_velocity_3d})
		return
		
	# СЦЕНАРИЙ 1.2: Нет пути
	var path_comp = actual_track.get_comp(C_Path)
	if not path_comp: 
		entity.send_event("on_derailed", {"reason": "no_path", "current_velocity_3d": current_velocity_3d})
		return # отсутствие ноды path это сход
	
	# --- СЦЕНАРИЙ 1.5: Непроходимый (слишком крутой) радиус ---
	# XX claude-terra радиус берем в точке передней тележки (для flex он меняется по длине)
	var r = path_comp.radius_at(front_bogie.track_distance)
	if r < _kin.min_curve_radius:
		entity.send_event("on_derailed", {"reason": "tight_curve", "radius": r, "current_velocity_3d": current_velocity_3d})
		return

	# XX claude-coaster C6.1: у траков горок боковую нагрузку считает C_RideCar по кривизне с учётом крена (RideDynamics)
	if path_comp.handles_lateral_load():
		centrifugal_force = 0.0
		return

	# Прямая: сход от центробежной силы невозможен
	if is_inf(r):
		centrifugal_force = 0.0
		return

	# СЦЕНАРИЙ 2: Превышение скорости в повороте, если реборда не держит центробежную силу - сход
	# Формула центробежной силы из архитектуры: F = (m * v^2) / r
	centrifugal_force = (_kin.mass * current_speed * current_speed) / r
	
	if centrifugal_force > _kin.max_grip:
		entity.send_event("on_derailed", {"reason": "hi speed", "force": centrifugal_force, "current_velocity_3d": current_velocity_3d})
		return




## Отладка схода (только debug-сборка): причина, скорость и где стоит каждая тележка в момент схода.
## Читать в консоли редактора: строки с [DERAIL]
func _log_derail(data: Dictionary) -> void:
	_ensure_refs()
	var parts: Array[String] = []
	if _bogie:
		for i in _bogie.bogies_data.size():
			var b = _bogie.bogies_data[i]
			if not is_instance_valid(b.current_track):
				parts.append("b%d: нет трака" % i)
				continue
			var pc := b.current_track.get_comp(C_Path) as C_Path
			var clen: float = pc.curve_of(b.route).get_baked_length() if pc else -1.0
			var rad: String = str(pc.radius_at(b.track_distance)) if pc else "?"
			parts.append("b%d: %s route=%d s=%.3f/%.3f r=%s" % [i, b.current_track.name, b.route, b.track_distance, clen, rad])
	print("[DERAIL] %s | reason=%s | v=%.2f м/с | mass=%.2f grip=%.1f | %s | extra=%s" % [
		entity.name, data.get("reason", "?"), current_speed, _kin.mass, _kin.max_grip,
		" ; ".join(parts), str(data.get("force", data.get("radius", "")))])


# Событие схода с рельс. Здесь определяем флаги шасси. В кинематикс сделает физику
func on_derailed(_data: Dictionary) -> void:
	
	if not is_on_rails: return
	if OS.is_debug_build():
		_log_derail(_data)
	is_on_rails = false
	snapped_track = null
	current_speed = 0.0
	coupler_force = 0.0
	_reset_wheels()
	if _susp: _susp.reset()


## На обесточенной цепи flip пересчитывается вместе с сетью (достроили/убрали трак, переложили стрелку) и может
## смениться под едущим вагоном. Знак скорости привязан к flip, поэтому без поправки вагон поехал бы обратно.
## В запитанной цепи так не делаем: смена полярности должна реверсировать движение
func _keep_world_direction(bc: C_Bogie) -> void:
	if bc.bogies_data.is_empty():
		return
	var b = bc.bogies_data[0]
	var pt := b.current_track.get_comp(C_PowerTrack) as C_PowerTrack
	if pt == null:
		return
	var f := pt.flip_of(b.route)
	if b.current_track == _dir_track and b.route == _dir_route and f != _dir_flip and pt.contour_of(b.route) == 0:
		current_speed = -current_speed
	_dir_track = b.current_track
	_dir_route = b.route
	_dir_flip = f


# ==========================================
# ФИЗИЧЕСКИЙ ЦИКЛ
# ==========================================
func _physics_process(delta: float) -> void:
	if not is_on_rails: return

	_ensure_refs()
	var bogie_comp := _bogie
	if not bogie_comp: return
	
	# 1. Проверяем состояние тележек на рельсах
	if bogie_comp.is_derailed:
		entity.send_event("on_derailed", {"reason": "bogie derailed", "current_velocity_3d": current_velocity_3d})
		return
		
	# XX claude-fix: трак под любой тележкой удалили (не только под передней): сход.
	# Иначе ниже в snapped_track присваивается освобождённый инстанс (ошибка и краш)
	for b in bogie_comp.bogies_data:
		if not is_instance_valid(b.current_track):
			entity.send_event("on_derailed", {"reason": "track_removed", "current_velocity_3d": current_velocity_3d})
			return

	_keep_world_direction(bogie_comp)

	# 2. Проверяем состояние вагона в движении
	_check_derailment() 
	if not is_on_rails: return   # XX claude-fix: после схода дальше не считаем позиции
	_assist_speed_correction(delta)

	# 3. Заставляем тележки пересчитать позиции
	var b_calc_pos = bogie_comp.calculate_next_positions(delta, current_speed)
	var front_calc_pos = b_calc_pos["front"]
	var rear_calc_pos = b_calc_pos["rear"]

	# 4. Обновляем актуальный трак (как и раньше - трак последней тележки)
	snapped_track = bogie_comp.bogies_data.back().current_track

	if front_calc_pos == Vector3.ZERO or rear_calc_pos == Vector3.ZERO:
		entity.send_event("on_derailed", {"reason": "front end calc_pos failed", "current_velocity_3d": current_velocity_3d})
		return

	# Запоминаем позицию до перемещения
	var previous_pos = entity.global_position

	# 3. Позиционируем вагон на хорде между тележками: начало вагона на весе body_anchor_w (0.5 у симметричных тележек)
	entity.global_position = front_calc_pos.lerp(rear_calc_pos, bogie_comp.body_anchor_w)

	# Вычисляем фактический вектор 3D-скорости
	if delta > 0.0:
		current_velocity_3d = (entity.global_position - previous_pos) / delta

	# 4. ПОВОРОТ КУЗОВА: вычисляем направляющий вектор от задней к передней
	var forward_dir = (front_calc_pos - rear_calc_pos).normalized()
	
	# Защита от схлопывания точек (если дистанция вдруг стала нулевой)
	if forward_dir.length_squared() > 0.001:
		# Выравниваем локальный -Z (морду) по вектору движения
		# XX claude-coaster C5.3: «верх» кузова это среднее «верха» крайних тележек (без крена ровно Vector3.UP)
		var body_up := Vector3.UP
		var tb = bogie_comp.bogies_data
		if tb.size() > 0:
			body_up = (tb[0].up + tb[tb.size() - 1].up).normalized()
		entity.global_basis = Basis.looking_at(forward_dir, body_up)

	# --- ИНТЕГРАЦИЯ ПОДВЕСКИ ---
	_assist_suspension_dynamics(delta)
	
	# 5. Подтягиваем ригид к ентити
	_assist_rb_to_entity()

	# 6. Допуски узлов тележек (поперечный ход, предел курса): когда кузов уже на месте. Без допусков в паспорте ничего не делает
	if bogie_comp.has_tolerances():
		bogie_comp.apply_tolerances(rb.global_transform)



# ==========================================
# ВСПОМОГАТЕЛЬНЫЕ АССИСТ-ФУНКЦИИ (HELPERS)
# ==========================================
func _assist_suspension_dynamics(delta: float) -> void:
	if _susp == null or _bogie == null or _bogie.bogies_data.is_empty():
		return
	# Выключатель гасит ВХОДЫ (mask/intensity = 0). Состояние не трогаем: моды сами вернутся
	# в покой по своей динамике, и подвеска уснёт (стоимость 0). Жёсткий reset - только при
	# драге/сходе/посадке.
	var mask := 0
	var intensity := 0.0
	if enable_suspension:
		intensity = effect_multiplier
		if debug_susp_vertical: mask |= SuspensionState.CH_VERTICAL
		if debug_susp_pitch: mask |= SuspensionState.CH_PITCH
		if debug_susp_roll: mask |= SuspensionState.CH_ROLL
		if debug_susp_lateral: mask |= SuspensionState.CH_LATERAL
		if debug_susp_hunting: mask |= SuspensionState.CH_HUNTING

	var bd := _bogie.bogies_data
	var rear: C_Bogie.BogieData = bd.back() if bd.size() > 1 else null
	_susp.update(delta, current_speed, current_velocity_3d, entity.global_basis,
			bd.front(), rear, mask, intensity)



####======================================================

func _assist_rb_to_entity() -> void:
	if not rb.top_level: 
		rb.top_level = true
		
	if not is_on_rails:
		return

	var t := entity.global_transform
	# Подвеска спит -> смещения нет и множить нечего
	if _susp and not _susp.is_at_rest():
		t = t * _susp.get_offset_transform()
	# Стоящему вагону transform не пишем: каждая запись - вызов в физ. сервер
	if rb.global_transform != t:
		rb.global_transform = t


	
	
# Получаем массу вагона из кинематикс(или откуда надо)
func get_wagon_props(_p: String) -> float:
	if _kin == null: _kin = entity.get_comp(C_Kinematics) as C_Kinematics
	if _kin == null: return 0.0
	match _p:
		'mass': return _kin.mass
		'max_grip': return _kin.max_grip
		'roll_resistance': return _kin.roll_resistance
		'longitudinal_grip': return _kin.longitudinal_grip
		'min_curve_radius': return _kin.min_curve_radius
		'max_tractive_force': return _kin.max_tractive_force
		'max_theoretical_speed': return _kin.max_theoretical_speed
		'max_yaw_deg': return _kin.max_yaw_deg
		'yaw_spring': return _kin.yaw_spring
	return 0.0



func save_data() -> Dictionary:
	return {
		'comp_path':get_script().resource_path,		# "res://core/components/c_power_clip.gd"
		'comp_name':get_script().resource_path.get_file().get_basename(),
		'is_on_rails': is_on_rails,
		# Оставлено для старых сейвов. current_spline_offset обновляется ТОЛЬКО при посадке,
		# пока вагон едет - он устаревает, поэтому при загрузке не используется.
		'current_spline_offset':current_spline_offset,
	}



var _saved_on_rails := true   # старые сейвы без этого поля считаем "на рельсах"

func load_data(_data: Dictionary) -> void:
	_saved_on_rails = _data.get("is_on_rails", true)
	if _data.has("current_spline_offset"):
		current_spline_offset = _data.current_spline_offset



## Вызывается из SaveManager после того, как все объекты расставлены.
## Каждая тележка находит свой трак лучом: вагон может стоять на стыке, и тогда тележки на разных траках
## (раньше все тележки ставились на трак первой и вагон на стыке сжимался).
## Возвращает false, если вагон был на рельсах, но трак под первой тележкой пока не найден (flex или физика еще не
## готовы): SaveManager повторит попытку через кадр. true: вагон сел или садиться не нужно
func restore_snap_after_load() -> bool:
	if not _saved_on_rails:
		return true   # вагон был сошедшим - остаётся в физике Godot
	_ensure_refs()
	if not _bogie or _bogie.bogies_data.is_empty():
		return true   # нечем искать трак

	var hits: Array[Dictionary] = []
	for b in _bogie.bogies_data:
		var hit := _track_under_bogie(b)
		if not hit.is_empty():
			hits.append(hit)
	# Первая тележка обязательна (по ней считаем направление и положение центра). Остальные без трака
	# ставятся как раньше, относительно трака первой
	var first: Dictionary = {}
	for h in hits:
		if h.bogie_id == _bogie.bogies_data[0].id:
			first = h
	if first.is_empty():
		return false

	var b0 := _bogie.bogies_data[0]
	var pc := first.track.get_comp(C_Path) as C_Path
	var crv := pc.curve_of(first.route)
	var t := crv.sample_baked_with_rotation(first.distance)
	var tangent := (pc.path_node.global_basis * -t.basis.z).normalized()
	var flipped := (-entity.global_basis.z).dot(tangent) < 0.0
	var placement_dir := 1.0 if flipped else -1.0
	# offset - положение ЦЕНТРА вагона на сплайне (так его ждёт set_track_to_bogies_data)
	var offset: float = first.distance - b0.pivot.position.z * placement_dir

	on_train_snapped({"track": first.track, "offset": offset, "route": first.route, "bogie_hits": hits})
	return true


## Трак под тележкой по лучу датчика: {bogie_id, track, route, distance}. Пусто, если под лучом не трак
## (земля, воздух, коллизии еще не готовы). distance считается по ФАКТИЧЕСКОМУ положению тележки, а не из сейва
## (там значение с момента посадки)
func _track_under_bogie(b: C_Bogie.BogieData) -> Dictionary:
	if not is_instance_valid(b.raycast) or not is_instance_valid(b.pivot):
		return {}
	b.raycast.force_raycast_update()
	if not b.raycast.is_colliding():
		return {}
	var track_entity := _find_entity_from_collider(b.raycast.get_collider())
	if not track_entity:
		return {}
	var pc := track_entity.get_comp(C_Path) as C_Path
	if not pc or not pc.curve or not pc.path_node:
		return {}   # под лучом не трак (земля и т.п.) - не садимся, иначе is_on_rails=true без пути
	var local_pos := pc.path_node.to_local(b.pivot.global_position)
	var route := pc.route_at(local_pos)   # XX claude-switch: кросс, маршрут под тележкой
	return {
		"bogie_id": b.id,
		"track": track_entity,
		"route": route,
		"distance": pc.curve_of(route).get_closest_offset(local_pos),
	}




### Хелпер для подъема по дереву (такой же, как используется в сокетах трака)
func _find_entity_from_collider(node: Node) -> Entity:
	var current = node
	while current:
		if current is Entity:
			return current
		current = current.get_parent()
	return null
