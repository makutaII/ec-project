@tool
extends EditorScript

###########################
## Проверка якоря высоты траков горок RideShape.lowest_y (ATTN_27, C6.1)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Трак ставится на землю нижней точкой: origin Entity выше земли на ground_anchor = −(смещение пути + lowest_y).
## Смещение пути у центрированной кривой: −точка кривой на середине длины.

const TOL := 0.01
const HW := 1.6   # половина ширины основания у стиля coaster


func _run() -> void:
	var errors: Array[String] = []

	# 1. Ровный прямой: нижняя точка на оси, y = 0; якорь (для середины кривой) 0
	var flat := RideShape.build(10.0, 0.0, 0.0, 0.0)
	_expect(errors, "ровный: нижняя точка", RideShape.lowest_y(flat, HW), 0.0)
	_expect(errors, "ровный: якорь", _anchor(flat), 0.0)

	# 2. Прямой уклон 15°, длина 10: нижняя точка в начале (y 0), середина выше на 10·sin15°/2: якорь ≈ 1.29
	var slope := RideShape.build(10.0, 15.0, 15.0, 0.0)
	_expect(errors, "уклон 15°: нижняя точка", RideShape.lowest_y(slope, HW), 0.0)
	_expect(errors, "уклон 15°: якорь = половина набора", _anchor(slope), 10.0 * sin(deg_to_rad(15.0)) * 0.5)

	# 3. Дуга вверх 0 → 15° (въезд): нижняя точка в начале, якорь = высота середины кривой (дуга вогнутая, середина ниже половины набора)
	var arc := RideShape.build(12.0, 0.0, 15.0, 0.0)
	var arc_rise := arc.get_point_position(arc.get_point_count() - 1).y
	_expect(errors, "дуга: нижняя точка", RideShape.lowest_y(arc, HW), 0.0)
	_expect(errors, "дуга: якорь = высота середины кривой", _anchor(arc), arc.sample_baked(arc.get_baked_length() * 0.5).y)
	_expect_ge(errors, "дуга: якорь положительный", _anchor(arc), 0.1)
	_expect_ge(errors, "дуга: якорь меньше набора", arc_rise, _anchor(arc))

	# 4. Ровный трак с постоянным креном 30°: край основания ниже оси на 1.6·sin30° = 0.8
	var bank := RideShape.build(10.0, 0.0, 0.0, 0.0, 30.0, 30.0)
	_expect(errors, "крен 30°: нижний край", RideShape.lowest_y(bank, HW), -HW * sin(deg_to_rad(30.0)))
	_expect(errors, "крен 30°: якорь", _anchor(bank), HW * sin(deg_to_rad(30.0)))
	# Левый крен даёт то же (|sin|)
	var bank_l := RideShape.build(10.0, 0.0, 0.0, 0.0, -30.0, -30.0)
	_expect(errors, "левый крен: якорь тот же", _anchor(bank_l), HW * sin(deg_to_rad(30.0)))

	# 5. Штопор 0 → 30° (ровный): самая низкая точка на конце, где крен 30°
	var screw := RideShape.build(10.0, 0.0, 0.0, 0.0, 0.0, 30.0)
	_expect(errors, "штопор: нижний край на конце", RideShape.lowest_y(screw, HW), -HW * sin(deg_to_rad(30.0)))

	# 6. Подъём с креном: уклон 15°, крен 30°: край ниже начала на 0.8, начало самое низкое
	var slope_roll := RideShape.build(10.0, 15.0, 15.0, 0.0, 30.0, 30.0)
	_expect(errors, "подъём с креном: нижний край", RideShape.lowest_y(slope_roll, HW), -HW * sin(deg_to_rad(30.0)))

	if errors.is_empty():
		print("OK: якорь высоты: дуги, подъёмы и траки с креном стоят на земле нижней точкой")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


## Якорь как у C_RidePath.ground_anchor: смещение пути у центрированной кривой = −точка на середине длины
func _anchor(curve: Curve3D) -> float:
	var mid_y := curve.sample_baked(curve.get_baked_length() * 0.5).y
	return maxf(-(-mid_y + RideShape.lowest_y(curve, HW)), 0.0)


func _expect(errors: Array[String], name: String, got: float, want: float) -> void:
	if absf(got - want) > TOL:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_ge(errors: Array[String], name: String, got: float, min_value: float) -> void:
	if got < min_value:
		errors.append("%s: получили %s, ждали не меньше %s" % [name, got, min_value])
