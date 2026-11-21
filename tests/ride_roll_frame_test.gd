@tool
extends EditorScript

###########################
## Проверка репера трака с креном TrackMeshBuilder.frame (ATTN_27, шаг C5.2)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Крен + это правый крен: правый край лотка ниже, «верх» уходит вправо (+X у трака, идущего в −Z).
## Ось трака от крена не меняется, обычные кривые (без наклона точек) дают прежний репер.

const TOL := 0.001


func _run() -> void:
	var errors: Array[String] = []

	# 1. Без крена репер прежний: right = +X, up = +Y, вперёд = −Z
	var plain := RideShape.build(10.0, 0.0, 0.0, 0.0)
	var Lp := plain.get_baked_length()
	var f0 := TrackMeshBuilder.frame(plain, 5.0, Lp)
	_expect_v(errors, "без крена: right", f0.r, Vector3(1, 0, 0))
	_expect_v(errors, "без крена: up", f0.u, Vector3(0, 1, 0))
	_expect_v(errors, "без крена: вперёд", f0.f, Vector3(0, 0, -1))
	_expect_f(errors, "без крена: roll_at", TrackMeshBuilder.roll_at(plain, 5.0, Lp), 0.0)
	_expect_bool(errors, "без крена не скручен", TrackMeshBuilder.is_twisted(plain, Lp), false)

	# 2. Прямой трак длиной 10 с креном 0 → 30°: в начале, середине и конце 0, 15, 30°
	var twist := RideShape.build(10.0, 0.0, 0.0, 0.0, 0.0, 30.0)
	var L := twist.get_baked_length()
	for pair in [[0.0, 0.0], [5.0, 15.0], [10.0, 30.0]]:
		var s: float = pair[0]
		var tau := deg_to_rad(pair[1])
		var f := TrackMeshBuilder.frame(twist, s, L)
		_expect_v(errors, "крен %s°: вперёд" % pair[1], f.f, Vector3(0, 0, -1))
		_expect_v(errors, "крен %s°: up" % pair[1], f.u, Vector3(sin(tau), cos(tau), 0))
		_expect_v(errors, "крен %s°: right (правый край ниже)" % pair[1], f.r, Vector3(cos(tau), -sin(tau), 0))
		_expect_v(errors, "крен %s°: ось" % pair[1], f.p, Vector3(0, 0, -s))
		_expect_v(errors, "крен %s°: right × up = назад" % pair[1], f.r.cross(f.u), -f.f)
	_expect_bool(errors, "0 → 30° скручен", TrackMeshBuilder.is_twisted(twist, L), true)

	# 3. Постоянный крен 20° (вираж): репер повёрнут на всём протяжении, не скручен
	var bank := RideShape.build(10.0, 0.0, 0.0, 0.0, 20.0, 20.0)
	var Lb := bank.get_baked_length()
	_expect_bool(errors, "постоянный крен не скручен", TrackMeshBuilder.is_twisted(bank, Lb), false)
	for s in [1.0, 5.0, 9.0]:
		var fb := TrackMeshBuilder.frame(bank, s, Lb)
		_expect_v(errors, "постоянный крен 20°: up", fb.u, Vector3(sin(deg_to_rad(20.0)), cos(deg_to_rad(20.0)), 0))

	# 4. Левый крен −30: «верх» уходит влево
	var left := RideShape.build(10.0, 0.0, 0.0, 0.0, -30.0, -30.0)
	var fl := TrackMeshBuilder.frame(left, 5.0, left.get_baked_length())
	_expect_v(errors, "левый крен: up", fl.u, Vector3(-sin(deg_to_rad(30.0)), cos(deg_to_rad(30.0)), 0))
	_expect_v(errors, "левый крен: right (правый край выше)", fl.r, Vector3(cos(deg_to_rad(30.0)), sin(deg_to_rad(30.0)), 0))

	# 5. Крен вместе с уклоном и дугой: репер ортонормирован, ось от крена не меняется
	var arc := RideShape.build(12.0, 0.0, 15.0, 0.0, 0.0, 25.0)
	var La := arc.get_baked_length()
	for s in [2.0, 6.0, 10.0]:
		var fa := TrackMeshBuilder.frame(arc, s, La)
		_expect_f(errors, "дуга с креном: |right|", fa.r.length(), 1.0)
		_expect_f(errors, "дуга с креном: |up|", fa.u.length(), 1.0)
		_expect_f(errors, "дуга с креном: right ⟂ up", fa.r.dot(fa.u), 0.0)
		_expect_f(errors, "дуга с креном: up ⟂ вперёд", fa.u.dot(fa.f), 0.0)
	var plain_arc := RideShape.build(12.0, 0.0, 15.0, 0.0)
	_expect_v(errors, "дуга: ось не зависит от крена", TrackMeshBuilder.frame(arc, 6.0, La).p, TrackMeshBuilder.frame(plain_arc, 6.0, plain_arc.get_baked_length()).p)

	# 6. «Верх» для вагонов (surface_up_local, шаг C5.3): без крена ровно Vector3.UP даже на подъёме и дуге
	# (так вагоны ориентировались всегда, поведение обычных траков не меняется), с креном повёрнутый репер
	_expect_bool(errors, "прямая без крена: верх == UP", TrackMeshBuilder.surface_up_local(plain, 5.0, Lp) == Vector3.UP, true)
	var up_arc := RideShape.build(12.0, 0.0, 15.0, 0.0)
	var Lu := up_arc.get_baked_length()
	_expect_bool(errors, "дуга вверх без крена: верх == UP", TrackMeshBuilder.surface_up_local(up_arc, 6.0, Lu) == Vector3.UP, true)
	var slope := RideShape.build(10.0, 15.0, 15.0, 0.0)
	_expect_bool(errors, "уклон без крена: верх == UP", TrackMeshBuilder.surface_up_local(slope, 5.0, slope.get_baked_length()) == Vector3.UP, true)
	_expect_v(errors, "прямая с креном 0 → 30°: верх в середине", TrackMeshBuilder.surface_up_local(twist, 5.0, L), Vector3(sin(deg_to_rad(15.0)), cos(deg_to_rad(15.0)), 0))
	_expect_v(errors, "верх совпадает с frame().u", TrackMeshBuilder.surface_up_local(arc, 6.0, La), TrackMeshBuilder.frame(arc, 6.0, La).u)
	# Basis.looking_at с этим «верхом» даёт ось Y, равную «верху» (вагон наклоняется вместе с лотком)
	var up_roll := TrackMeshBuilder.surface_up_local(bank, 5.0, Lb)
	var bas := Basis.looking_at(Vector3(0, 0, -1), up_roll)
	_expect_v(errors, "вагон: ось Y корпуса = верх лотка", bas.y, up_roll)
	_expect_v(errors, "вагон: ось Z корпуса назад", bas.z, Vector3(0, 0, 1))
	# Среднее «верха» двух тележек на соседних точках: нормированная сумма ровно UP, когда оба UP
	_expect_bool(errors, "среднее двух UP == UP", (Vector3.UP + Vector3.UP).normalized() == Vector3.UP, true)

	if errors.is_empty():
		print("OK: репер трака с креном: правый крен + опускает правый край, без крена репер прежний")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect_v(errors: Array[String], name: String, got: Vector3, want: Vector3) -> void:
	if got.distance_to(want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_f(errors: Array[String], name: String, got: float, want: float) -> void:
	if absf(got - want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_bool(errors: Array[String], name: String, got: bool, want: bool) -> void:
	if got != want:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
