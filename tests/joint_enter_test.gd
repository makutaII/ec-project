@tool
extends EditorScript

###########################
## Проверка перехода тележки на соседний трак JointMath.can_enter (ATTN_27, «Т-стык»)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.
## Тележка вылетает за конец трака. Соседний трак принимается как продолжение, только если въезд у его конца и
## он идёт вдоль хода. Трак поперёк (Т-стык) не принимается.

const GAP := 1.0
const ANG := 30.0


func _run() -> void:
	var errors: Array[String] = []
	var travel := Vector3(0, 0, -1)       # ход вдоль −Z
	var gpos := Vector3(0, 0, -0.3)       # тележка вылетела за конец ножки на 0.3

	# 1. Нормальный стык: сосед начинается в (0, 0, −0.3), идёт дальше вдоль −Z
	_expect(errors, "нормальный стык", JointMath.can_enter(gpos, Vector3(0, 0, -0.3), Vector3(0, 0, -10.3), Vector3(0, 0, 1), Vector3(0, 0, -1), travel, GAP, ANG), true)
	# 2. Стык с зазором 0.4 (допуск 1.0)
	_expect(errors, "зазор 0.4", JointMath.can_enter(gpos, Vector3(0, 0, -0.7), Vector3(0, 0, -10.7), Vector3(0, 0, 1), Vector3(0, 0, -1), travel, GAP, ANG), true)
	# 3. Сосед развёрнут (конец, к которому подъехали, второй): касательная в любую сторону
	_expect(errors, "сосед развёрнут", JointMath.can_enter(gpos, Vector3(0, 0, -10.3), Vector3(0, 0, -0.3), Vector3(0, 0, -1), Vector3(0, 0, 1), travel, GAP, ANG), true)
	# 4. Излом 20° (в допуске)
	var t20 := Vector3(sin(deg_to_rad(20.0)), 0, -cos(deg_to_rad(20.0)))
	_expect(errors, "излом 20°", JointMath.can_enter(gpos, Vector3(0, 0, -0.3), Vector3(5, 0, -10), -t20, t20, travel, GAP, ANG), true)
	# 5. Излом 45° (больше допуска)
	var t45 := Vector3(sin(deg_to_rad(45.0)), 0, -cos(deg_to_rad(45.0)))
	_expect(errors, "излом 45°", JointMath.can_enter(gpos, Vector3(0, 0, -0.3), Vector3(5, 0, -10), -t45, t45, travel, GAP, ANG), false)

	# 6. Т-стык: ножка упирается в середину поперечного трака (длина 10, лежит вдоль X на z = −1.6). Концы далеко
	_expect(errors, "Т-стык, поперечный трак", JointMath.can_enter(Vector3(0, 0, -0.3), Vector3(-5, 0, -1.6), Vector3(5, 0, -1.6), Vector3(-1, 0, 0), Vector3(1, 0, 0), travel, GAP, ANG), false)
	# 7. Г-стык: ножка упирается в КОНЕЦ поперечного трака (близко), но он идёт поперёк: 90°
	_expect(errors, "Г-стык, конец поперечного трака", JointMath.can_enter(Vector3(0, 0, -0.3), Vector3(0, 0, -0.5), Vector3(10, 0, -0.5), Vector3(-1, 0, 0), Vector3(1, 0, 0), travel, GAP, ANG), false)
	# 8. Далёкий трак вдоль хода (зазор 3): не продолжение
	_expect(errors, "зазор 3", JointMath.can_enter(gpos, Vector3(0, 0, -3.3), Vector3(0, 0, -13.3), Vector3(0, 0, 1), Vector3(0, 0, -1), travel, GAP, ANG), false)

	# 9. Подъём: ход вдоль уклона 15°, сосед в ту же сторону
	var up15 := Vector3(0, sin(deg_to_rad(15.0)), -cos(deg_to_rad(15.0)))
	_expect(errors, "подъём 15°", JointMath.can_enter(up15 * 0.3, up15 * 0.3, up15 * 10.3, -up15, up15, up15, GAP, ANG), true)

	# 10. axis_aligned: вырожденный ввод
	_expect(errors, "нулевая ось", JointMath.axis_aligned(Vector3.ZERO, travel, ANG), false)
	_expect(errors, "противоположные оси", JointMath.axis_aligned(travel, -travel, ANG), true)

	if errors.is_empty():
		print("OK: на соседний трак переходят только у его конца и вдоль хода, Т-стык не принимается")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: bool, want: bool) -> void:
	if got != want:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
