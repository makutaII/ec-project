@tool
extends EditorScript

###########################
## Проверка крена на стыке траков JointMath.bank_diff_deg (ATTN_27, шаг C5.4)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Разница крена меряется вокруг оси стыка по мировым «верхам» сокетов: излом по вертикали в неё не входит,
## у обычных траков она 0, трак, повёрнутый на 180°, сравнивается по тому же мировому вектору.

const TOL := 0.01


func _run() -> void:
	var errors: Array[String] = []

	# 1. Одинаковые «верха»: 0
	var ts := Vector3(0, sin(deg_to_rad(10.0)), -cos(deg_to_rad(10.0)))   # стоящий трак идёт вверх на 10°
	var us := Vector3(0, cos(deg_to_rad(10.0)), sin(deg_to_rad(10.0)))    # его «верх» (перпендикуляр к ходу)
	_expect(errors, "одинаковые верха", JointMath.bank_diff_deg(ts, us, us), 0.0)

	# 2. Излом по вертикали (стыкуемый идёт под 15°, его «верх» наклонён), крена нет: разница 0, это не крен
	var ud := Vector3(0, cos(deg_to_rad(15.0)), sin(deg_to_rad(15.0)))
	_expect(errors, "только излом по вертикали", JointMath.bank_diff_deg(ts, us, ud), 0.0)

	# 3. Крен 10° у соседа (вращение «верха» вокруг оси стыка), без излома и с изломом
	_expect(errors, "крен 10°", JointMath.bank_diff_deg(ts, us, us.rotated(ts.normalized(), deg_to_rad(10.0))), 10.0)
	_expect(errors, "крен 10° вместе с изломом", JointMath.bank_diff_deg(ts, us, ud.rotated(ts.normalized(), deg_to_rad(10.0))), 10.0)
	_expect(errors, "крен −7°", JointMath.bank_diff_deg(ts, us, us.rotated(ts.normalized(), deg_to_rad(-7.0))), 7.0)

	# 4. «Верх» вдоль оси (вырожденный случай): 0, без деления на ноль
	_expect(errors, "верх вдоль оси", JointMath.bank_diff_deg(ts, ts, us), 0.0)

	# 5. Стык по настоящей геометрии траков: прямой с креном 20° и сосед
	var a := RideShape.build(10.0, 0.0, 0.0, 0.0, 20.0, 20.0)
	var La := a.get_baked_length()
	var ua := TrackMeshBuilder.frame(a, La, La).u               # «верх» у конца стоящего трака (идёт в −Z)
	var axis := Vector3(0, 0, -1)
	# 5a. Сосед продолжает вперёд, тот же крен 20°: разница 0
	var b_same := RideShape.build(10.0, 0.0, 0.0, 0.0, 20.0, 20.0)
	_expect(errors, "сосед вперёд, тот же крен", JointMath.bank_diff_deg(axis, ua, TrackMeshBuilder.frame(b_same, 0.0, b_same.get_baked_length()).u), 0.0)
	# 5b. Сосед с креном 25°: разница 5°
	var b_more := RideShape.build(10.0, 0.0, 0.0, 0.0, 25.0, 25.0)
	_expect(errors, "сосед вперёд, крен на 5° больше", JointMath.bank_diff_deg(axis, ua, TrackMeshBuilder.frame(b_more, 0.0, b_more.get_baked_length()).u), 5.0)
	# 5c. Сосед повёрнут на 180° (стыкуется своим концом): относительно своего хода его крен обратный.
	# Построен с креном −20° и повернут вокруг Y на π: мировой «верх» тот же, разница 0. С тем же знаком +20° было бы 40°
	var b_flip := RideShape.build(10.0, 0.0, 0.0, 0.0, -20.0, -20.0)
	var up_flip := Basis(Vector3.UP, PI) * TrackMeshBuilder.frame(b_flip, 0.0, b_flip.get_baked_length()).u
	_expect(errors, "сосед развёрнут, крен −20° относительно его хода", JointMath.bank_diff_deg(axis, ua, up_flip), 0.0)
	var b_flip_bad := RideShape.build(10.0, 0.0, 0.0, 0.0, 20.0, 20.0)
	var up_flip_bad := Basis(Vector3.UP, PI) * TrackMeshBuilder.frame(b_flip_bad, 0.0, b_flip_bad.get_baked_length()).u
	_expect(errors, "сосед развёрнут, тот же знак крена: 40°", JointMath.bank_diff_deg(axis, ua, up_flip_bad), 40.0)

	if errors.is_empty():
		print("OK: крен на стыке считается вокруг оси стыка, излом и разворот траков на него не влияют")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: float, want: float) -> void:
	if absf(got - want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
