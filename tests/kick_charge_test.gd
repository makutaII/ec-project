@tool
extends EditorScript

###########################
## Проверка зарядки пинка KickCharge (ATTN_27)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.


func _run() -> void:
	var errors: Array[String] = []
	var p := KickCharge.defaults()

	# Короткое нажатие: сила short_power, как до зарядки
	_expect(errors, "tap 0.0", KickCharge.power_at(0.0, p), 10.0)
	_expect(errors, "tap 0.2", KickCharge.power_at(0.2, p), 10.0)
	# Зажатие: от power_min (3) до power_max (20) за charge_time (1.2) после hold_min (0.25)
	_expect(errors, "граница hold_min", KickCharge.power_at(0.25, p), 3.0)
	_expect(errors, "середина зарядки", KickCharge.power_at(0.25 + 0.6, p), 11.5)
	_expect(errors, "полная зарядка", KickCharge.power_at(0.25 + 1.2, p), 20.0)
	_expect(errors, "сверх полной", KickCharge.power_at(10.0, p), 20.0)

	# Для клавиш SelectTool поднимает power_min до short_power: зажатие не слабее нажатия
	p.power_min = maxf(float(p.power_min), float(p.short_power))
	_expect(errors, "клавиши: граница hold_min не слабее tap", KickCharge.power_at(0.25, p), 10.0)
	_expect(errors, "клавиши: полная зарядка", KickCharge.power_at(0.25 + 1.2, p), 20.0)
	# Числа можно переопределить (так делает C_RideCar)
	var q := KickCharge.defaults()
	q.power_max = 30.0
	q.charge_time = 2.0
	_expect(errors, "переопределённые числа", KickCharge.power_at(0.25 + 1.0, q), lerpf(3.0, 30.0, 0.5))
	# charge_time = 0 не делит на ноль
	q.charge_time = 0.0
	_expect(errors, "charge_time 0", KickCharge.power_at(5.0, q), 30.0)

	if errors.is_empty():
		print("OK: зарядка пинка считается верно")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: float, want: float) -> void:
	if absf(got - want) > 0.0001:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
