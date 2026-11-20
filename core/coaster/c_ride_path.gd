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


## radius и deg из аргументов не используются: форму задаёт паспорт
func generate_track_curve(_radius: float, _deg: float) -> Curve3D:
	var idc := get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as RideTrackConfig if idc else null
	if cfg == null:
		push_error("C_RidePath: у сущности нет паспорта RideTrackConfig, трак строится как обычный")
		return super(_radius, _deg)
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
	return RideShape.roll_at(offset, total, _roll_start, _roll_end)


## Ровный (оба угла 0, без крена) ведёт себя, как обычный плоский трак. С уклоном или креном: не подгоняется под листы рельефа
func is_flat() -> bool:
	return _level and not has_comp(C_FlexShape) and routes.size() <= 1


## Длина по самой кривой (у базового считается по radius и deg)
func get_length() -> float:
	return snapped(curve.get_baked_length(), 0.1) if curve else 0.0
