@tool
extends EditorScript

###########################
## Проверка пределов flex-трака горок RideFlexConfig (ATTN_27, шаг C8.1)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Flex горок строится тем же решателем FlexSolver, но по пределам паспорта: поворот круче, уклон больше, чем у рельсового flex.

const TOL := 0.05


func _run() -> void:
	var errors: Array[String] = []

	# 1. Паспорт отдаёт свои пределы, обычный TrackConfig нет (значит GlobalSetting)
	_expect_bool(errors, "TrackConfig: пределы из GlobalSetting (null)", TrackConfig.new().flex_limits() == null, true)
	var cfg := RideFlexConfig.new()
	var lim := cfg.flex_limits()
	_expect_f(errors, "r_min", lim.r_min, 8.0)
	_expect_f(errors, "l_min", lim.l_min, 4.0)
	_expect_f(errors, "l_max", lim.l_max, 120.0)
	_expect_f(errors, "max_grade", lim.max_grade, 0.7)
	# Паспорт горок наследует форму трака горок: C_RidePath строится через create_path
	_expect_bool(errors, "RideFlexConfig это RideTrackConfig", cfg is RideTrackConfig, true)

	# 2. Свободный конец (10, 10): дуга 90°, R = 10. Горки: R = 10 (r_min 8 не мешает). Рельсовые пределы (r_min 25): R ≥ 25
	var target := Vector2(10.0, 10.0)
	var arc_ride := FlexSolver.arc_to(target, lim)
	_expect_f(errors, "горки: радиус дуги к цели (10, 10)", arc_ride.radius, 10.0, 0.2)
	var rail := FlexSolver.Limits.new()   # r_min 25 по умолчанию
	var arc_rail := FlexSolver.arc_to(target, rail)
	_expect_ge(errors, "рельсы: радиус не меньше r_min", arc_rail.radius, 24.9)

	# 3. Круче r_min дуги не получить: цель очень близко сбоку (3, 3): R = 3 < r_min 8, решатель растягивает до r_min
	var arc_tight := FlexSolver.arc_to(Vector2(3.0, 3.0), lim)
	_expect_ge(errors, "круче r_min не бывает", arc_tight.radius, 7.9)

	# 4. Уклон: S-образный подъём (нулевые уклоны на концах) на dy за прямую длиной 10 даёт max |dy/ds| = 1.5·dy/L
	var pts := PackedVector2Array()
	for i in 11:
		pts.append(Vector2(0.0, float(i)))
	var ok := FlexSolver.to_curve3d(pts, 0.0, 4.0, 0.0, 0.0)   # 1.5·4/10 = 0.6 < 0.7
	_expect_f(errors, "подъём 4 за 10: уклон", ok.max_grade, 0.6, 0.02)
	_expect_bool(errors, "подъём 4 за 10 в пределах горок", ok.max_grade <= lim.max_grade, true)
	_expect_bool(errors, "подъём 4 за 10 вне рельсовых пределов", ok.max_grade > 0.045, true)
	var bad := FlexSolver.to_curve3d(pts, 0.0, 6.0, 0.0, 0.0)  # 1.5·6/10 = 0.9 > 0.7
	_expect_bool(errors, "подъём 6 за 10 вне пределов горок", bad.max_grade > lim.max_grade, true)

	if errors.is_empty():
		print("OK: пределы flex горок: поворот от 8, уклон до 0,7, остальное через FlexSolver")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect_f(errors: Array[String], name: String, got: float, want: float, tol := TOL) -> void:
	if absf(got - want) > tol:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_ge(errors: Array[String], name: String, got: float, min_value: float) -> void:
	if got < min_value:
		errors.append("%s: получили %s, ждали не меньше %s" % [name, got, min_value])


func _expect_bool(errors: Array[String], name: String, got: bool, want: bool) -> void:
	if got != want:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
