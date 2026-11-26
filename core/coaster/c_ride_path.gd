class_name C_RidePath extends C_Path

###########################
## Путь трака горок (ATTN_27 §27.4)
###########################
## Тот же C_Path (get_comp(C_Path) находит и его: Entity ищет по is_instance_of), но кривая строится не как
## прямая или дуга по radius и deg, а RideShape по паспорту RideTrackConfig: уклон, вертикальная дуга, поворот.
## Сокеты, вагоны, опоры и визуал стиля работают с кривой как обычно. Origin трака в середине кривой (centered),
## как у остальных. Крен (ATTN_27 R2, шаг C5) хранится в кривой как наклон точек и отдаётся roll_deg_at;
## меш, коллизия, вагон и сокеты учитывают его в следующих частях шага.

var _level := true   # оба угла 0 и крена нет: лежит на плоскости
var _roll_start := 0.0   # крен в начале, градусы (+ правый край ниже)
var _roll_end := 0.0
var _dyn := {}   # запечённый профиль нагрузок (RideDynamics.bake), считается при первом обращении


## radius и deg из аргументов не используются: форму задаёт паспорт
func generate_track_curve(_radius: float, _deg: float) -> Curve3D:
	var idc := get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as RideTrackConfig if idc else null
	if cfg == null:
		push_error("C_RidePath: у сущности нет паспорта RideTrackConfig, трак строится как обычный")
		return super(_radius, _deg)
	_dyn = {}   # кривая строится заново: профиль нагрузок устарел
	_level = RideShape.is_level(cfg.pitch_start_deg, cfg.pitch_end_deg, cfg.roll_start_deg, cfg.roll_end_deg)
	_roll_start = cfg.roll_start_deg
	_roll_end = cfg.roll_end_deg
	# radius и deg нужны остальным: radius_at() для физики схода, инфопанели, сохранению
	deg = cfg.deg
	var r := RideShape.plan_radius(cfg.length, cfg.pitch_start_deg, cfg.pitch_end_deg, cfg.deg)
	radius = r if is_finite(r) else cfg.length
	return RideShape.build(cfg.length, cfg.pitch_start_deg, cfg.pitch_end_deg, cfg.deg, cfg.roll_start_deg, cfg.roll_end_deg)


## Крен (градусы, + правый край ниже) на расстоянии offset от начала кривой. Линейно по длине, как в RideShape.roll_at
func roll_deg_at(offset: float) -> float:
	var total := curve.get_baked_length() if curve else 0.0
	return rad_to_deg(TrackMeshBuilder.roll_at(curve, offset, total)) if curve else 0.0   # C8.2: из наклона точек, годится и flex


## Ровный (оба угла 0, без крена) ведёт себя, как обычный плоский трак. С уклоном или креном: не подгоняется под листы рельефа
func is_flat() -> bool:
	return _level and not has_comp(C_FlexShape) and routes.size() <= 1


## Длина по самой кривой (у базового считается по radius и deg)
func get_length() -> float:
	return snapped(curve.get_baked_length(), 0.1) if curve else 0.0


## Половина ширины основания, ю: от неё зависит, насколько край трака с креном уходит вниз
func _half_width() -> float:
	var sv := get_comp(C_StyleVisual) as C_StyleVisual
	if sv != null and sv.style != null:
		return sv.style.collision_width * 0.5
	return collision_width * 0.5 if collision_width > 0.0 else 1.5


## Якорь высоты (C_TrackDraggable._anchor_offset): origin стоит выше земли ровно настолько, чтобы нижняя точка трака
## (ось кривой, а при крене нижний край основания) касалась её. Origin в середине кривой, поэтому нижняя половина
## дуги, уклона или трака с креном раньше уходила в землю (у обычного пандуса это |rise|/2, а у RidePath rise = 0)
func ground_anchor() -> float:
	if curve == null or path_node == null or has_comp(C_FlexShape):
		return 0.0   # у flex origin в начале кривой, его высота задаётся началом и уровнями конца
	return maxf(-(path_node.position.y + RideShape.lowest_y(curve, _half_width())), 0.0)


## Глубина под землёй: к проверке оси добавлены оба нижних края основания у трака с креном (край ниже оси)
func underground_depth(xf: Transform3D) -> float:
	var worst := super(xf)
	if not curve or not path_node or not entity.is_inside_tree() or not TrackMeshBuilder.has_roll(curve):
		return worst
	var hw := _half_width()
	var space := entity.get_world_3d().direct_space_state
	var tunnel := allows_underground()
	var total := curve.get_baked_length()
	var n := maxi(2, ceili(total / 4.0) + 1)
	for i in n:
		var s := total * float(i) / float(n - 1)
		var right_local := TrackMeshBuilder.frame(curve, s, total).r
		for side in [-1.0, 1.0]:
			var p: Vector3 = xf * (path_node.position + curve.sample_baked(s) + right_local * (hw * side))
			var gy := 0.0
			if not tunnel:
				var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 1000.0, p.z), Vector3(p.x, -1000.0, p.z),
						Global.active_layers(['ground']))
				var hit := space.intersect_ray(q)
				if not hit.is_empty():
					gy = hit.position.y
			worst = maxf(worst, gy - p.y)
	return worst


## Форма flex пересчитана (событие шлёт C_Path.set_curve): запечённый профиль нагрузок устарел
func on_curve_changed(_d: Dictionary) -> void:
	_dyn = {}


## Общая проверка центробежной силы по радиусу в плане здесь не нужна: боковую нагрузку считает ride_load_at (с учётом крена)
func handles_lateral_load() -> bool:
	return true


## Нагрузки (n, l) в долях g на вагон в точке offset кривой: n нормальная (< 0 отрыв), l боковая со знаком (в сторону «право»).
## speed: скорость вдоль трака, ю/с; g_eff: эффективная тяжесть вагона G·grade_k. Векторы профиля из локальных координат
## кривой переводятся в мир базисом пути (у Entity только поворот по yaw)
func ride_load_at(offset: float, speed: float, g_eff: float) -> Vector2:
	if curve == null or path_node == null:
		return Vector2(1.0, 0.0)
	if _dyn.is_empty():
		_dyn = RideDynamics.bake(curve)
	var smp := RideDynamics.sample(_dyn, offset)
	var b := path_node.global_basis
	return RideDynamics.loads(speed, b * (smp.kappa as Vector3), b * (smp.up as Vector3), b * (smp.right as Vector3), g_eff)
