@tool
extends EditorScript

###########################
## Проверка формы траков горок RideShape (ATTN_27, шаг C4)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Проверяет концы кривой (положение и касательная), стыковку набора «въезд, подъём, выезд» и ручки на торцах,
## из которых сокеты берут направление.

const TOL := 0.002


func _run() -> void:
	var errors: Array[String] = []

	# 1. Прямой уклон 15°, длина 10: две точки, конец (0, 10·sin15°, −10·cos15°)
	var a := deg_to_rad(15.0)
	var slope := RideShape.build(10.0, 15.0, 15.0, 0.0)
	_expect_int(errors, "прямой уклон: точек", slope.get_point_count(), 2)
	_expect_v(errors, "прямой уклон: конец", slope.get_point_position(1), Vector3(0, 10.0 * sin(a), -10.0 * cos(a)))

	# 2. Дуга вверх 0 → 15°, длина 12: kappa = θ/L, Δy = (1 − cosθ)/kappa, Δz = −sinθ/kappa
	var k := a / 12.0
	var up_in := RideShape.build(12.0, 0.0, 15.0, 0.0)
	_expect_v(errors, "въезд: конец", _end(up_in), Vector3(0, (1.0 - cos(a)) / k, -sin(a) / k))
	_expect_v(errors, "въезд: касательная в конце", _end_dir(up_in), RideShape.tangent(a, 0.0))
	_expect_v(errors, "въезд: касательная в начале", _start_dir(up_in), Vector3(0, 0, -1))

	# 3. Дуга от 15° до ровного (верх горки): начало идёт вверх, конец ровный
	var up_out := RideShape.build(12.0, 15.0, 0.0, 0.0)
	_expect_v(errors, "выезд: касательная в начале", _start_dir(up_out), RideShape.tangent(a, 0.0))
	_expect_v(errors, "выезд: касательная в конце", _end_dir(up_out), Vector3(0, 0, -1))

	# 4. Набор стыкуется без излома: конец одного и начало следующего смотрят одинаково
	_expect_v(errors, "въезд → подъём", _end_dir(up_in), _start_dir(slope))
	_expect_v(errors, "подъём → выезд", _end_dir(slope), _start_dir(up_out))

	# 5. Ровный поворот 90°, R = 20: как у обычной дуги C_Path (x = R(1 − cosα), z = −R·sinα)
	var al := deg_to_rad(90.0)
	var turn := RideShape.build(20.0 * al, 0.0, 0.0, 90.0)
	_expect_v(errors, "поворот: конец", _end(turn), Vector3(20.0 * (1.0 - cos(al)), 0, -20.0 * sin(al)))

	# 6. Винтовой участок: уклон 10° и поворот 90°, длина 30. Плановый радиус = L·cosθ/α
	var th := deg_to_rad(10.0)
	var rp := RideShape.plan_radius(30.0, 10.0, 10.0, 90.0)
	_expect_f(errors, "плановый радиус", rp, 30.0 * cos(th) / al)
	var helix := RideShape.build(30.0, 10.0, 10.0, 90.0)
	_expect_v(errors, "винт: конец", _end(helix), Vector3(rp * (1.0 - cos(al)), 30.0 * sin(th), -rp * sin(al)))
	_expect_v(errors, "винт: касательная в конце", _end_dir(helix), RideShape.tangent(th, al))
	_expect_f(errors, "прямой без поворота: плановый радиус бесконечен", RideShape.plan_radius(10.0, 15.0, 15.0, 0.0), INF)
	_expect_bool(errors, "ровный трак ровный", RideShape.is_level(0.0, 0.0), true)
	_expect_bool(errors, "уклон не ровный", RideShape.is_level(0.0, 15.0), false)

	# 7. Ручки на торцах: сокеты берут направление «наружу» как −out у первой точки и −in у последней
	for pair in [["въезд", up_in], ["выезд", up_out], ["винт", helix]]:
		var c: Curve3D = pair[1]
		var n := c.get_point_count()
		_expect_v(errors, "%s: ручка начала смотрит назад" % pair[0], -c.get_point_out(0).normalized(), -_start_dir(c))
		_expect_v(errors, "%s: ручка конца смотрит вперёд" % pair[0], -c.get_point_in(n - 1).normalized(), _end_dir(c))

	# 8. Крен: хранится в наклоне точек кривой, линейно по длине, + правый. Ось от крена не меняется
	var plain := RideShape.build(10.0, 0.0, 0.0, 0.0)
	var twist := RideShape.build(10.0, 0.0, 0.0, 0.0, 0.0, 30.0)
	_expect_int(errors, "прямой с креном: две точки", twist.get_point_count(), 2)
	_expect_f(errors, "прямой с креном: tilt в начале", twist.get_point_tilt(0), 0.0)
	_expect_f(errors, "прямой с креном: tilt в конце", twist.get_point_tilt(1), deg_to_rad(30.0))
	_expect_v(errors, "ось прямого не зависит от крена", twist.get_point_position(1), plain.get_point_position(1))
	var rolled := RideShape.build(12.0, 0.0, 15.0, 0.0, -10.0, 20.0)   # въезд на подъём с креном −10 → 20
	var plain_up := RideShape.build(12.0, 0.0, 15.0, 0.0)
	_expect_v(errors, "ось дуги не зависит от крена", _end(rolled), _end(plain_up))
	var last := rolled.get_point_count() - 1
	_expect_f(errors, "дуга: tilt в начале", rolled.get_point_tilt(0), deg_to_rad(-10.0))
	_expect_f(errors, "дуга: tilt в конце", rolled.get_point_tilt(last), deg_to_rad(20.0))
	var mid := int(last * 0.5)
	_expect_f(errors, "дуга: tilt в середине (линейно)", rolled.get_point_tilt(mid), deg_to_rad(lerpf(-10.0, 20.0, float(mid) / float(last))))
	_expect_f(errors, "roll_at: начало", RideShape.roll_at(0.0, 10.0, 5.0, 25.0), 5.0)
	_expect_f(errors, "roll_at: середина", RideShape.roll_at(5.0, 10.0, 5.0, 25.0), 15.0)
	_expect_f(errors, "roll_at: за концом зажимается", RideShape.roll_at(99.0, 10.0, 5.0, 25.0), 25.0)
	_expect_bool(errors, "с креном трак не ровный", RideShape.is_level(0.0, 0.0, 0.0, 30.0), false)
	_expect_bool(errors, "без крена и уклона ровный", RideShape.is_level(0.0, 0.0, 0.0, 0.0), true)
	# Старые вызовы build без крена: tilt нулевой
	_expect_f(errors, "без крена tilt 0", plain_up.get_point_tilt(plain_up.get_point_count() - 1), 0.0)

	# Справка (не ошибка): в какую сторону Godot наклоняет «верх» при положительном наклоне точки. По соглашению
	# ATTN_27 + это правый крен: «верх» уходит вправо (+X у трака, идущего в −Z). Часть C5.2 берёт крен из RideShape.roll_at
	# и от этой справки не зависит; строка нужна, чтобы увидеть, совпадают ли направления
	var up := twist.sample_baked_up_vector(twist.get_baked_length(), true)
	print("Справка: tilt +30° у трака вдоль −Z, «верх» на конце = %s (по соглашению x > 0: %s)" % [up, "совпадает" if up.x > 0.1 else "НЕ совпадает, знак Godot обратный"])

	if errors.is_empty():
		print("OK: форма траков горок (уклон, вертикальные дуги, винт, крен) считается верно")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _end(c: Curve3D) -> Vector3:
	return c.get_point_position(c.get_point_count() - 1)


## Касательная в начале: по первой ручке или, если ручки нулевые, по двум первым точкам
func _start_dir(c: Curve3D) -> Vector3:
	var o := c.get_point_out(0)
	if o.length_squared() > 0.000001:
		return o.normalized()
	return (c.get_point_position(1) - c.get_point_position(0)).normalized()


func _end_dir(c: Curve3D) -> Vector3:
	var n := c.get_point_count()
	var i := c.get_point_in(n - 1)
	if i.length_squared() > 0.000001:
		return (-i).normalized()
	return (c.get_point_position(n - 1) - c.get_point_position(n - 2)).normalized()


func _expect_v(errors: Array[String], name: String, got: Vector3, want: Vector3) -> void:
	if got.distance_to(want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_f(errors: Array[String], name: String, got: float, want: float) -> void:
	var ok := (is_inf(got) and is_inf(want)) or absf(got - want) < TOL
	if not ok:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_int(errors: Array[String], name: String, got: int, want: int) -> void:
	if got != want:
		errors.append("%s: получили %d, ждали %d" % [name, got, want])


func _expect_bool(errors: Array[String], name: String, got: bool, want: bool) -> void:
	if got != want:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
