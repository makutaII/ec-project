@tool
extends EditorScript

###########################
## Проверка TrackStyle.surface_height (ATTN_27, шаг C4)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Без surface_height стиль считается как раньше; с ним поверхность катания берётся из поля,
## а боксы коллизии строятся до этой высоты (рельсовый бокс крошечный).


func _run() -> void:
	var errors: Array[String] = []

	var st := TrackStyle.new()   # поля по умолчанию: балласт 0.5, шпала 0.2, embed 0.1, рельс 0.25
	_expect(errors, "по умолчанию head_height как раньше", st.head_height(), 0.85)
	var plain_base := st.base_height()

	st.surface_height = 0.35
	_expect(errors, "surface_height задаёт head_height", st.head_height(), 0.35)
	_expect(errors, "base_height не менялся", st.base_height(), plain_base)

	var curve := Curve3D.new()
	curve.add_point(Vector3.ZERO)
	curve.add_point(Vector3(0, 0, -10))
	var bx := TrackMeshBuilder.segment_boxes(st, curve, 10.0, 0.0, 10.0)
	_expect(errors, "высота бокса основания = surface_height", (bx.ballast_size as Vector3).y, 0.35)
	_expect(errors, "рельсовый бокс крошечный", (bx.rail_size as Vector3).y, 0.01)
	_expect(errors, "верх рельсового бокса не выше поверхности катания", (bx.rail_l_xf as Transform3D).origin.y + 0.005 <= 0.35 + 0.0001, true)

	st.surface_height = 0.0
	var bx0 := TrackMeshBuilder.segment_boxes(st, curve, 10.0, 0.0, 10.0)
	_expect(errors, "без surface_height бокс основания как раньше", (bx0.ballast_size as Vector3).y, plain_base)
	_expect(errors, "без surface_height бокс рельса как раньше", (bx0.rail_size as Vector3).y, st.rail_height())

	if errors.is_empty():
		print("OK: surface_height работает, стили без него считаются как раньше")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: Variant, want: Variant) -> void:
	var ok := false
	if got is float or want is float:
		ok = absf(float(got) - float(want)) < 0.0001
	else:
		ok = got == want
	if not ok:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
