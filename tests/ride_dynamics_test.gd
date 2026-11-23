@tool
extends EditorScript

###########################
## Проверка нагрузок на вагон RideDynamics (ATTN_27, шаг C6.1)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## n: нормальная нагрузка в долях g (1 стоит на ровном, 0 невесомость), l: боковая в долях g.

const TOL := 0.01
const G := 9.8


func _run() -> void:
	var errors: Array[String] = []
	var up := Vector3.UP
	var right := Vector3(1, 0, 0)

	# 1. Прямая, любая скорость: n = 1, l = 0
	var ld := RideDynamics.loads(20.0, Vector3.ZERO, up, right, G)
	_expect(errors, "прямая: n", ld.x, 1.0)
	_expect(errors, "прямая: l", ld.y, 0.0)

	# 2. Горб R = 10 (κ вниз): n = 1 − v²/(g·R). v = 5: 0.745. v² = g·R (v ≈ 9.9): ноль. Быстрее: отрицательная
	var crest := Vector3(0, -0.1, 0)
	_expect(errors, "горб, v=5", RideDynamics.loads(5.0, crest, up, right, G).x, 1.0 - 25.0 * 0.1 / G)
	_expect(errors, "горб, невесомость", RideDynamics.loads(sqrt(G * 10.0), crest, up, right, G).x, 0.0)
	_expect_lt(errors, "горб, быстрее: отрыв", RideDynamics.loads(12.0, crest, up, right, G).x, 0.0)

	# 3. Впадина R = 10 (κ вверх), v = 10: n = 1 + 100·0.1/9.8 ≈ 2.02
	_expect(errors, "впадина, v=10", RideDynamics.loads(10.0, Vector3(0, 0.1, 0), up, right, G).x, 1.0 + 100.0 * 0.1 / G)

	# 4. Плоский правый поворот R = 20 без крена (κ вправо), v = 10: l = v²/(R·g) = 0.51, n = 1
	var turn := RideDynamics.loads(10.0, Vector3(0.05, 0, 0), up, right, G)
	_expect(errors, "поворот без крена: l", turn.y, 100.0 * 0.05 / G)
	_expect(errors, "поворот без крена: n", turn.x, 1.0)

	# 5. Идеальный вираж: tgθ = v²κ/g, «верх» наклонён вправо на θ, правый край ниже. Боковая нагрузка 0, n = 1/cosθ
	var theta := atan(100.0 * 0.05 / G)
	var up_b := Vector3(sin(theta), cos(theta), 0)
	var right_b := Vector3(cos(theta), -sin(theta), 0)
	var bank := RideDynamics.loads(10.0, Vector3(0.05, 0, 0), up_b, right_b, G)
	_expect(errors, "идеальный вираж: l = 0", bank.y, 0.0)
	_expect(errors, "идеальный вираж: n = 1/cosθ", bank.x, 1.0 / cos(theta))

	# 6. Вираж с недокреном (10° вместо 27°): боковая нагрузка есть, но меньше, чем без крена
	var t10 := deg_to_rad(10.0)
	var part := RideDynamics.loads(10.0, Vector3(0.05, 0, 0), Vector3(sin(t10), cos(t10), 0), Vector3(cos(t10), -sin(t10), 0), G)
	_expect_lt(errors, "недокрен: l меньше, чем без крена", absf(part.y), absf(turn.y))
	_expect_lt(errors, "недокрен: l больше нуля", 0.0, absf(part.y))

	# 7. Запечённый профиль по кривой. Дуга вверх 0 → 15° длиной 12 (впадина R ≈ 45.8): κ ≈ 0.0218 вверх
	var arc := RideShape.build(12.0, 0.0, 15.0, 0.0)
	var b_arc := RideDynamics.bake(arc)
	var k_mid := (RideDynamics.sample(b_arc, 6.0).kappa as Vector3)
	_expect(errors, "дуга: κ вверх", k_mid.y, deg_to_rad(15.0) / 12.0)
	_expect(errors, "дуга: κ не боковая", k_mid.x, 0.0)
	# Прямой уклон: κ = 0
	var slope := RideShape.build(10.0, 15.0, 15.0, 0.0)
	_expect(errors, "уклон: κ = 0", (RideDynamics.sample(RideDynamics.bake(slope), 5.0).kappa as Vector3).length(), 0.0)
	# Плоский правый поворот 90° R = 20: |κ| = 0.05, вектор вправо (+X в начале, поворачивается вместе с ходом)
	var turn_c := RideShape.build(20.0 * PI * 0.5, 0.0, 0.0, 90.0)
	var k_turn := (RideDynamics.sample(RideDynamics.bake(turn_c), 0.0).kappa as Vector3)
	_expect(errors, "поворот: |κ| = 1/R", k_turn.length(), 0.05)
	_expect(errors, "поворот: κ вправо в начале", k_turn.normalized().x, 1.0)
	# Штопор: «верх» и «право» запечены с креном
	var screw := RideShape.build(10.0, 0.0, 0.0, 0.0, 0.0, 30.0)
	var s_end := RideDynamics.sample(RideDynamics.bake(screw), 10.0)
	_expect(errors, "штопор: верх на конце", (s_end.up as Vector3).x, sin(deg_to_rad(30.0)))
	_expect(errors, "штопор: право на конце опущено", (s_end.right as Vector3).y, -sin(deg_to_rad(30.0)))

	if errors.is_empty():
		print("OK: нагрузки на вагон: горб, впадина, поворот, вираж и запечённый профиль считаются верно")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: float, want: float) -> void:
	if absf(got - want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_lt(errors: Array[String], name: String, got: float, limit: float) -> void:
	if not (got < limit):
		errors.append("%s: получили %s, ждали меньше %s" % [name, got, limit])
