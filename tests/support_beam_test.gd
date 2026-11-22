@tool
extends EditorScript

###########################
## Проверка наклона ригеля опоры на траке с креном (C_TrackSupport, ATTN_27)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Ригель опоры строится как yaw * Basis(−Z, крен). Он должен наклоняться так же, как репер лотка (TrackMeshBuilder.frame):
## правый крен (+) опускает правый край, «верх» уходит вправо.

const TOL := 0.001


func _run() -> void:
	var errors: Array[String] = []
	var yaw := Basis.looking_at(Vector3(0, 0, -1), Vector3.UP)   # трак вдоль −Z

	# 1. Крен 30°: «верх» ригеля = (sin30, cos30, 0), right = (cos30, −sin30, 0)
	var roll := deg_to_rad(30.0)
	var beam := yaw * Basis(Vector3(0, 0, -1), roll)
	_expect_v(errors, "верх ригеля", beam.y, Vector3(sin(roll), cos(roll), 0))
	_expect_v(errors, "right ригеля (правый край ниже)", beam.x, Vector3(cos(roll), -sin(roll), 0))
	_expect_f(errors, "глубина низа по центру: 0.3·cos(крен)", 0.3 * beam.y.y, 0.3 * cos(roll))

	# 2. Ригель совпадает с репером лотка на скрученном траке вдоль −Z
	var curve := RideShape.build(10.0, 0.0, 0.0, 0.0, 0.0, 30.0)
	var L := curve.get_baked_length()
	for s in [2.0, 5.0, 8.0]:
		var r := TrackMeshBuilder.roll_at(curve, s, L)
		var b := yaw * Basis(Vector3(0, 0, -1), r)
		var f := TrackMeshBuilder.frame(curve, s, L)
		_expect_v(errors, "верх ригеля = верх лотка (s=%s)" % s, b.y, f.u)
		_expect_v(errors, "right ригеля = right лотка (s=%s)" % s, b.x, f.r)

	# 3. Без крена roll_at даёт 0 (прежний код опоры не затрагивается)
	var plain := RideShape.build(10.0, 0.0, 0.0, 0.0)
	_expect_f(errors, "без крена roll_at", TrackMeshBuilder.roll_at(plain, 5.0, plain.get_baked_length()), 0.0)

	# 4. Просадка нижнего конца ригеля при 30°: 1.5·sin30 = 0.75
	_expect_f(errors, "просадка конца ригеля", 1.5 * absf(sin(roll)), 0.75)

	if errors.is_empty():
		print("OK: ригель опоры наклоняется вместе с лотком, без крена всё прежнее")
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
