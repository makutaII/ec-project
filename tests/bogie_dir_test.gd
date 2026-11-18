@tool
extends EditorScript

###########################
## Проверка знака движения тележки на траках без питания (ATTN_27, шаг C2)
###########################
## Запуск: открыть файл, File → Run (Ctrl+Shift+X). Проверяет чистую математику BogieDirection.inherit:
## на стыке траков, повёрнутых друг к другу «задом наперёд», мировое направление движения должно продолжаться.
## Итог в Output: «OK» или список ошибок. Сцена не нужна.


func _run() -> void:
	var errors: Array[String] = []

	# 1. Одинаковое и противоположное направление, наклон
	var fwd := Vector3(0, 0, -1)
	_expect(errors, "сонаправлен", BogieDirection.inherit(fwd, fwd, 1.0), 1.0)
	_expect(errors, "навстречу", BogieDirection.inherit(fwd, -fwd, 1.0), -1.0)
	var up_slope := Vector3(0, 0.5, -0.866).normalized()
	_expect(errors, "подъём, трак повёрнут", BogieDirection.inherit(up_slope, -up_slope, 1.0), -1.0)
	_expect(errors, "подъём сменился спуском, тот же ход", BogieDirection.inherit(up_slope, Vector3(0, -0.2, -0.98).normalized(), -1.0), 1.0)
	# 2. Перпендикуляр: решить нельзя, остаётся прежний знак
	_expect(errors, "перпендикуляр, запасной +1", BogieDirection.inherit(fwd, Vector3(1, 0, 0), 1.0), 1.0)
	_expect(errors, "перпендикуляр, запасной −1", BogieDirection.inherit(fwd, Vector3(1, 0, 0), -1.0), -1.0)

	# 3. Цепочка из 8 траков: у каждого касательная (в сторону роста длины) смотрит то вперёд, то назад,
	# с изломом до 6° вправо и влево. Мировое направление движения не должно меняться ни на одном стыке
	var kinks := [0.0, 4.0, -5.0, 3.0, 6.0, -2.0, 5.0, -4.0]
	var flips := [false, true, true, false, true, false, false, true]
	var angle := 0.0
	var dir := 1.0
	var world_dir := Vector3.ZERO
	for i in kinks.size():
		angle += deg_to_rad(kinks[i])
		var tangent := Vector3(sin(angle), 0, -cos(angle))
		if flips[i]:
			tangent = -tangent   # трак поставлен «задом наперёд»
		if i == 0:
			dir = 1.0
			world_dir = tangent * dir
			continue
		dir = BogieDirection.inherit(world_dir, tangent, dir)
		var now_dir := tangent * dir
		if now_dir.dot(world_dir) < 0.99:
			errors.append("цепочка: на стыке %d направление движения сменилось (dot %.3f)" % [i, now_dir.dot(world_dir)])
		world_dir = now_dir

	if errors.is_empty():
		print("OK: направление тележки на траках без питания продолжается через стыки")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: float, want: float) -> void:
	if not is_equal_approx(got, want):
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
