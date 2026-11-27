@tool
extends EditorScript

###########################
## Проверка допусков узлов тележек: поперечный ход и предел курса (ведущие оси длинного локо)
###########################
## Запуск: открыть файл, File → Run (Ctrl+Shift+X). Сцена не нужна: узлы создаются в памяти, кузов задаётся transform.
## Итог в Output: «OK» или список ошибок.


func _run() -> void:
	var errors: Array[String] = []

	# 0. Геометрия: на дуге середина хорды между крайними узлами уходит внутрь на (половина хорды)² / (2R)
	_near(errors, "сагитта 10.6 м на R 42.2", 5.3 * 5.3 / (2.0 * 42.2), 0.3328, 0.001)

	# 1. Поперечный ход
	var bg := C_Bogie.new()
	var u_lat := _unit(bg, 0.45, 180.0)
	var u_small := _unit(bg, 0.2, 180.0)
	var u_free := _unit(bg, 0.0, 180.0)   # без допусков
	var body_id := Transform3D.IDENTITY
	u_lat.rail_pos = Vector3(0.33, 0.0, 0.0)
	u_small.rail_pos = Vector3(0.33, 0.0, 0.0)
	u_free.rail_pos = Vector3(0.33, 0.0, 0.0)
	bg.apply_tolerances(body_id)
	_near(errors, "ход в пределах допуска: x = 0.33", u_lat.pivot.position.x, 0.33)
	_near(errors, "допуск меньше сдвига: x = 0.2", u_small.pivot.position.x, 0.2)
	_near(errors, "узел без допусков не трогается", u_free.pivot.position.x, 0.0)
	u_lat.rail_pos = Vector3(-0.8, 0.0, 0.0)
	bg.apply_tolerances(body_id)
	_near(errors, "в другую сторону: x = -0.45", u_lat.pivot.position.x, -0.45)

	# 2. Кузов повёрнут и сдвинут: x считается в осях кузова
	var body := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(10.0, 0.0, 5.0))
	u_lat.rail_pos = body * Vector3(0.2, 0.0, -3.0)
	bg.apply_tolerances(body)
	_near(errors, "кузов повёрнут: x = 0.2", u_lat.pivot.position.x, 0.2)

	# 3. Предел курса: рыскание ограничивается, наклон сохраняется
	var u_yaw := _unit(bg, 0.0, 3.0)
	u_yaw.world_basis = Basis.from_euler(Vector3(deg_to_rad(5.0), deg_to_rad(10.0), 0.0), EULER_ORDER_YXZ)
	bg.apply_tolerances(body_id)
	var e := u_yaw.pivot.basis.get_euler(EULER_ORDER_YXZ)
	_near(errors, "курс ограничен: 3 градуса", rad_to_deg(e.y), 3.0, 0.01)
	_near(errors, "наклон сохранён: 5 градусов", rad_to_deg(e.x), 5.0, 0.01)
	u_yaw.world_basis = Basis.from_euler(Vector3(0.0, deg_to_rad(-10.0), 0.0), EULER_ORDER_YXZ)
	bg.apply_tolerances(body_id)
	_near(errors, "в другую сторону: -3 градуса", rad_to_deg(u_yaw.pivot.basis.get_euler(EULER_ORDER_YXZ).y), -3.0, 0.01)
	u_yaw.world_basis = Basis.from_euler(Vector3(0.0, deg_to_rad(2.0), 0.0), EULER_ORDER_YXZ)
	bg.apply_tolerances(body_id)
	_near(errors, "в пределах допуска: 2 градуса как есть", rad_to_deg(u_yaw.pivot.basis.get_euler(EULER_ORDER_YXZ).y), 2.0, 0.01)

	# 4. Курс считается относительно кузова, а не мира
	u_yaw.world_basis = Basis(Vector3.UP, deg_to_rad(95.0))   # кузов 90, узел на 5 градусов правее
	bg.apply_tolerances(Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3.ZERO))
	_near(errors, "курс относительно кузова: 3 градуса", rad_to_deg(u_yaw.pivot.basis.get_euler(EULER_ORDER_YXZ).y), 3.0, 0.01)

	# 5. Есть ли допуски в паспортах
	_check(errors, "допуски есть", bg.has_tolerances())
	var empty := C_Bogie.new()
	_unit(empty, 0.0, 180.0)
	_check(errors, "допусков нет: ничего не считаем", not empty.has_tolerances())

	# 6. Чистые функции
	_near(errors, "clamp_lateral", BogieMath.clamp_lateral(0.7, 0.45), 0.45)
	var same := Basis(Vector3.UP, deg_to_rad(1.0))
	_check(errors, "clamp_yaw в пределах возвращает тот же базис", BogieMath.clamp_yaw(same, 3.0).is_equal_approx(same))

	for owner in [bg, empty]:
		for bd in owner.bogies_data:
			bd.pivot.free()
	bg.free()
	empty.free()
	if errors.is_empty():
		print("OK: допуски узлов тележек (поперечный ход и предел курса)")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for err in errors:
			print("  - ", err)


## Узел тележки в памяти: BogieData с узлом-пивотом и конфигом допусков
func _unit(bg: C_Bogie, play: float, yaw_limit: float) -> C_Bogie.BogieData:
	var cfg := BogieConfig.new()
	cfg.lateral_play = play
	cfg.yaw_limit_deg = yaw_limit
	var bd := C_Bogie.BogieData.new()
	bd.config = cfg
	bd.pivot = Node3D.new()
	bg.bogies_data.append(bd)
	return bd


func _check(errors: Array[String], name: String, ok: bool) -> void:
	if not ok:
		errors.append(name)


func _near(errors: Array[String], name: String, got: float, want: float, tol := 0.0001) -> void:
	if absf(got - want) > tol:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
