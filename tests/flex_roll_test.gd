@tool
extends EditorScript

###########################
## Проверка крена flex: JointMath.roll_about, TrackMeshBuilder.apply_roll (ATTN_27, шаг C8.2)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Flex берёт крен у соседей: roll_about переводит «верх» сокета соседа в градусы крена по ходу flex,
## apply_roll пишет его в наклон точек кривой, roll_at читает тот же крен обратно.

const TOL := 0.01


func _run() -> void:
	var errors: Array[String] = []
	var f := Vector3(0, 0, -1)

	# 1. roll_about возвращает угол, на который «верх» повёрнут вокруг хода от базового (правая тройка, + правый край ниже)
	_expect(errors, "без крена", JointMath.roll_about(f, Vector3.UP), 0.0)
	_expect(errors, "крен 30°", JointMath.roll_about(f, Vector3.UP.rotated(f, deg_to_rad(30.0))), 30.0)
	_expect(errors, "крен −20°", JointMath.roll_about(f, Vector3.UP.rotated(f, deg_to_rad(-20.0))), -20.0)
	_expect(errors, "крен 90°", JointMath.roll_about(f, Vector3.UP.rotated(f, deg_to_rad(90.0))), 90.0)
	# 2. На подъёме 15°: базовый «верх» перпендикулярен ходу
	var fp := Vector3(0, sin(deg_to_rad(15.0)), -cos(deg_to_rad(15.0)))
	var base := (Vector3.UP - fp * fp.dot(Vector3.UP)).normalized()
	_expect(errors, "подъём, без крена", JointMath.roll_about(fp, base), 0.0)
	_expect(errors, "подъём, крен 25°", JointMath.roll_about(fp, base.rotated(fp, deg_to_rad(25.0))), 25.0)
	# 3. Ход в обратную сторону (сосед смотрит навстречу): тот же мировой «верх» даёт крен с обратным знаком
	var up30 := Vector3.UP.rotated(f, deg_to_rad(30.0))
	_expect(errors, "навстречу: знак меняется", JointMath.roll_about(-f, up30), -30.0)
	# 4. «Верх» не обязан быть строго ⟂ ходу: берётся проекция
	_expect(errors, "верх с составляющей вдоль хода", JointMath.roll_about(f, (up30 + f * 0.3).normalized()), 30.0)
	# 5. Согласие с репером лотка: крен, записанный в кривую, читается по «верху» frame() обратно
	var curve := RideShape.build(10.0, 0.0, 0.0, 0.0, 0.0, 30.0)
	var L := curve.get_baked_length()
	var u_end := TrackMeshBuilder.frame(curve, L, L).u
	_expect(errors, "репер: крен в конце", JointMath.roll_about(f, u_end), 30.0)
	var u_mid := TrackMeshBuilder.frame(curve, L * 0.5, L).u
	_expect(errors, "репер: крен в середине", JointMath.roll_about(f, u_mid), 15.0)

	# 6. apply_roll на кривой с 11 точками: линейно по индексу, roll_at читает то же
	var c := Curve3D.new()
	for i in 11:
		c.add_point(Vector3(0, 0, -float(i)))
	_expect_bool(errors, "без крена has_roll", TrackMeshBuilder.has_roll(c), false)
	TrackMeshBuilder.apply_roll(c, -10.0, 20.0)
	_expect_bool(errors, "после apply_roll has_roll", TrackMeshBuilder.has_roll(c), true)
	_expect(errors, "tilt в начале", rad_to_deg(c.get_point_tilt(0)), -10.0)
	_expect(errors, "tilt в конце", rad_to_deg(c.get_point_tilt(10)), 20.0)
	_expect(errors, "tilt в середине", rad_to_deg(c.get_point_tilt(5)), 5.0)
	var Lc := c.get_baked_length()
	_expect(errors, "roll_at в середине", rad_to_deg(TrackMeshBuilder.roll_at(c, Lc * 0.5, Lc)), 5.0)
	_expect(errors, "roll_at на четверти", rad_to_deg(TrackMeshBuilder.roll_at(c, Lc * 0.25, Lc)), -2.5)

	# 7. Нулевой крен не создаёт наклона: has_roll ложно (обычный flex рельс не меняется)
	var plain := Curve3D.new()
	for i in 4:
		plain.add_point(Vector3(0, 0, -float(i)))
	TrackMeshBuilder.apply_roll(plain, 0.0, 0.0)
	_expect_bool(errors, "нулевой крен", TrackMeshBuilder.has_roll(plain), false)

	if errors.is_empty():
		print("OK: крен flex: roll_about, apply_roll и roll_at согласованы с репером лотка")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: float, want: float) -> void:
	if absf(got - want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_bool(errors: Array[String], name: String, got: bool, want: bool) -> void:
	if got != want:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
