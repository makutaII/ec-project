@tool
extends EditorScript

###########################
## Проверка коллизии бортов лотка горок (TrackStyle.trough, ATTN_27, шаг C4)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Профили U и W заданы в коде (как в Track Studio: ломаная от нижнего левого угла вверх, по верху и вниз справа).

const TOL := 0.0001


func _run() -> void:
	var errors: Array[String] = []

	# U: борта 0.3 толщиной, верх 0.8, дно 0.3 (как data/tracks/styles/coaster.tres)
	var u := TrackStyle.new()
	u.ballast_profile = PackedVector2Array([Vector2(-1.6, 0), Vector2(-1.6, 0.8), Vector2(-1.3, 0.8), Vector2(-1.3, 0.3),
		Vector2(1.3, 0.3), Vector2(1.3, 0.8), Vector2(1.6, 0.8), Vector2(1.6, 0)])
	u.collision_width = 3.2
	u.surface_height = 0.3
	_expect_i(errors, "U без trough: бортов нет", u.trough_boards().size(), 0)
	u.trough = true
	var bu := u.trough_boards()
	_expect_i(errors, "U: два борта", bu.size(), 2)
	if bu.size() == 2:
		_expect_v(errors, "U: левый борт", bu[0], Vector3(-1.6, -1.3, 0.8))
		_expect_v(errors, "U: правый борт", bu[1], Vector3(1.3, 1.6, 0.8))

	# Боксы сегмента: основание до дна, борта от дна до верха, середины на x = ±1.45
	var curve := Curve3D.new()
	curve.add_point(Vector3.ZERO)
	curve.add_point(Vector3(0, 0, -10))
	var bx := TrackMeshBuilder.segment_boxes(u, curve, 10.0, 0.0, 10.0)
	_expect_v(errors, "U: основание", Vector3((bx.ballast_size as Vector3).x, (bx.ballast_size as Vector3).y, 0), Vector3(3.2, 0.3, 0))
	_expect_v(errors, "U: размер борта (толщина, высота)", Vector3((bx.rail_size as Vector3).x, (bx.rail_size as Vector3).y, 0), Vector3(0.3, 0.5, 0))
	_expect_v(errors, "U: левый борт, центр", (bx.rail_l_xf as Transform3D).origin, Vector3(-1.45, 0.55, -5.0))
	_expect_v(errors, "U: правый борт, центр", (bx.rail_r_xf as Transform3D).origin, Vector3(1.45, 0.55, -5.0))

	# W: прямоугольник 3.2 × 0.8 с двумя пазами под колёса (дно 0.3): в коллизию входят только крайние стенки
	var w := TrackStyle.new()
	w.ballast_profile = PackedVector2Array([Vector2(-1.6, 0), Vector2(-1.6, 0.8), Vector2(-1.2, 0.8), Vector2(-1.2, 0.3),
		Vector2(-0.4, 0.3), Vector2(-0.4, 0.8), Vector2(0.4, 0.8), Vector2(0.4, 0.3), Vector2(1.2, 0.3), Vector2(1.2, 0.8),
		Vector2(1.6, 0.8), Vector2(1.6, 0)])
	w.surface_height = 0.3
	w.trough = true
	var bw := w.trough_boards()
	_expect_i(errors, "W: два борта", bw.size(), 2)
	if bw.size() == 2:
		_expect_v(errors, "W: левая стенка", bw[0], Vector3(-1.6, -1.2, 0.8))
		_expect_v(errors, "W: правая стенка", bw[1], Vector3(1.2, 1.6, 0.8))

	# Невалидные случаи: нет дна, нет surface_height, нет балласта
	var flat := TrackStyle.new()
	flat.ballast_profile = PackedVector2Array([Vector2(-1.5, 0), Vector2(-1.5, 0.5), Vector2(1.5, 0.5), Vector2(1.5, 0)])
	flat.trough = true
	flat.surface_height = 0.5
	_expect_i(errors, "плоский профиль: бортов нет", flat.trough_boards().size(), 0)
	u.surface_height = 0.0
	_expect_i(errors, "без surface_height бортов нет", u.trough_boards().size(), 0)
	u.surface_height = 0.3
	u.ballast_enabled = false
	_expect_i(errors, "без балласта бортов нет", u.trough_boards().size(), 0)
	u.ballast_enabled = true
	_expect_f(errors, "head_height лотка = дно", u.head_height(), 0.3)

	# Стиль без trough и без surface_height считается как раньше
	var old := TrackStyle.new()
	var bo := TrackMeshBuilder.segment_boxes(old, curve, 10.0, 0.0, 10.0)
	_expect_f(errors, "обычный стиль: высота рельсового бокса", (bo.rail_size as Vector3).y, old.rail_height())
	_expect_f(errors, "обычный стиль: левый рельс по x", (bo.rail_l_xf as Transform3D).origin.x, -old.rail_x)

	if errors.is_empty():
		print("OK: борта лотка U и W определяются по профилю, коллизия строится в слотах рельсов, обычные стили без изменений")
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


func _expect_i(errors: Array[String], name: String, got: int, want: int) -> void:
	if got != want:
		errors.append("%s: получили %d, ждали %d" % [name, got, want])
