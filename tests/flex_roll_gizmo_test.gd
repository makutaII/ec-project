@tool
extends EditorScript

###########################
## Проверка математики кольца крена flex: JointMath.ring_basis, roll_of_point, twist_for (ATTN_27, шаг C8.3)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Кольцо стоит на конце flex перпендикулярно ходу, его плоскость это right и «верх» без крена. Курсор на кольце даёт крен конца,
## скручивание = крен конца − крен начала, шагами 5° (Shift: 1°).

const TOL := 0.01


func _run() -> void:
	var errors: Array[String] = []
	var f := Vector3(0, 0, -1)

	# 1. Базис кольца на горизонтальном ходе: X = right (+X), Y = ход, Z = «верх» без крена (+Y мира). Правая тройка
	var b := JointMath.ring_basis(f)
	_expect_v(errors, "кольцо: X (right)", b.x, Vector3(1, 0, 0))
	_expect_v(errors, "кольцо: Y (ось = ход)", b.y, f)
	_expect_v(errors, "кольцо: Z («верх»)", b.z, Vector3(0, 1, 0))
	_expect_v(errors, "правая тройка: X × Y = Z", b.x.cross(b.y), b.z)
	# На подъёме 15°: Z перпендикулярен ходу
	var fp := Vector3(0, sin(deg_to_rad(15.0)), -cos(deg_to_rad(15.0)))
	var bp := JointMath.ring_basis(fp)
	_expect_f(errors, "подъём: Z ⟂ ходу", bp.z.dot(fp), 0.0)
	_expect_f(errors, "подъём: Z единичный", bp.z.length(), 1.0)
	_expect_v(errors, "подъём: Y = ход", bp.y, fp)
	# Вертикальный ход: единичный базис, без деления на ноль
	_expect_v(errors, "вертикальный ход", JointMath.ring_basis(Vector3.UP).x, Vector3(1, 0, 0))

	# 2. Крен по точке кольца: точка на «верхе» 0°, повёрнутая вправо на 30° даёт 30°, влево −20°
	_expect_f(errors, "точка сверху", JointMath.roll_of_point(f, Vector3(0, 2.4, 0)), 0.0)
	_expect_f(errors, "точка 30° вправо", JointMath.roll_of_point(f, Vector3(0, 2.4, 0).rotated(f, deg_to_rad(30.0))), 30.0)
	_expect_f(errors, "точка 20° влево", JointMath.roll_of_point(f, Vector3(0, 2.4, 0).rotated(f, deg_to_rad(-20.0))), -20.0)
	_expect_f(errors, "точка справа (+X) это крен 90°", JointMath.roll_of_point(f, Vector3(2.4, 0, 0)), 90.0)
	_expect_f(errors, "точка снизу это 180°", absf(JointMath.roll_of_point(f, Vector3(0, -2.4, 0))), 180.0)
	_expect_f(errors, "точка в центре", JointMath.roll_of_point(f, Vector3.ZERO), 0.0)
	# Составляющая вдоль хода игнорируется (курсор не в плоскости кольца)
	_expect_f(errors, "вдоль хода игнорируется", JointMath.roll_of_point(f, Vector3(0, 2.4, -3.0).rotated(f, deg_to_rad(30.0))), 30.0)
	# Согласие с roll_about (то же соглашение знака, что у соседей при снапе)
	var up30 := Vector3.UP.rotated(f, deg_to_rad(30.0))
	_expect_f(errors, "согласие с roll_about", JointMath.roll_of_point(f, up30 * 2.4), JointMath.roll_about(f, up30))

	# 3. Скручивание: конец − начало, приведено к (−180, 180], шаг 5 (1 с Shift)
	_expect_f(errors, "скручивание 30 − 0", JointMath.twist_for(30.0, 0.0, 5.0), 30.0)
	_expect_f(errors, "округление до 5: 32°", JointMath.twist_for(32.0, 0.0, 5.0), 30.0)
	_expect_f(errors, "округление до 5: 33°", JointMath.twist_for(33.0, 0.0, 5.0), 35.0)
	_expect_f(errors, "Shift: шаг 1°", JointMath.twist_for(33.4, 0.0, 1.0), 33.0)
	_expect_f(errors, "от начала −30°: конец 10° это 40°", JointMath.twist_for(10.0, -30.0, 5.0), 40.0)
	_expect_f(errors, "оборот: конец 170°, начало −30° это −160° (короткий путь)", JointMath.twist_for(170.0, -30.0, 5.0), -160.0)
	_expect_f(errors, "оборот в другую сторону", JointMath.twist_for(-170.0, 30.0, 5.0), 160.0)

	if errors.is_empty():
		print("OK: кольцо крена flex: базис, крен по курсору и скручивание считаются верно")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect_f(errors: Array[String], name: String, got: float, want: float) -> void:
	if absf(got - want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_v(errors: Array[String], name: String, got: Vector3, want: Vector3) -> void:
	if got.distance_to(want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
