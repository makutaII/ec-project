@tool
extends EditorScript

###########################
## Проверка осей узла и точки кузова (паровоз: этап K2)
###########################
## Запуск: открыть файл, File → Run (Ctrl+Shift+X). Чистая математика BogieMath и BogieConfig, сцена не нужна.
## Итог в Output: «OK» или список ошибок.


func _run() -> void:
	var errors: Array[String] = []

	# 1. Вес точки кузова: симметричные тележки дают середину хорды
	_expect(errors, "симметрично", BogieMath.anchor_weight(-2.56, 2.56), 0.5)
	_expect(errors, "симметрично, дробные", BogieMath.anchor_weight(-5.3, 5.299), 0.5, 0.001)
	# Паровоз без заднего шасси: передний узел далеко впереди, ведущие почти в центре
	_expect(errors, "несимметрично", BogieMath.anchor_weight(-4.6, 0.9), 4.6 / 5.5)
	_expect(errors, "вырожденная база", BogieMath.anchor_weight(1.0, 1.0), 0.5)
	# Вес подставляется в lerp: начало вагона оказывается на своём месте хорды
	var front := Vector3(0, 0, -10.0)
	var rear := Vector3(0, 0, -10.0 + 5.5)   # хорда 5.5, как между узлами -4.6 и 0.9
	var origin := front.lerp(rear, BogieMath.anchor_weight(-4.6, 0.9))
	_expect(errors, "начало вагона на 4.6 от первой тележки", front.distance_to(origin), 4.6)

	# 2. Крайние оси
	_expect_bool(errors, "две оси симметричны", BogieMath.extremes_symmetric(PackedFloat32Array([1.5, -1.5])), true)
	_expect_bool(errors, "три оси, средняя сдвинута", BogieMath.extremes_symmetric(PackedFloat32Array([-2.185, 0.006, 2.185])), true)
	_expect_bool(errors, "крайние несимметричны", BogieMath.extremes_symmetric(PackedFloat32Array([-2.0, 0.0, 2.5])), false)
	_expect_bool(errors, "одна ось", BogieMath.extremes_symmetric(PackedFloat32Array([0.3])), true)

	# 3. BogieConfig: прежние паспорта
	var cfg := BogieConfig.new()
	cfg.wheel_pair_position = Vector3(0, 0.7, 1.5)
	_expect(errors, "две оси: полубаза", cfg.half_base(), 1.5)
	_expect_array(errors, "две оси: порядок +z, -z", cfg.axle_list(), [1.5, -1.5])
	cfg.wheel_pair_position = Vector3(0, 0.7, 0.0)
	_expect(errors, "одна ось: полубаза", cfg.half_base(), 0.0)
	_expect_array(errors, "одна ось в центре", cfg.axle_list(), [0.0])

	# 4. BogieConfig: три ведущие оси
	cfg.axle_offsets = PackedFloat32Array([-2.185, 0.006, 2.185])
	cfg.wheel_pair_position = Vector3(0, 0.939, 2.185)
	_expect(errors, "три оси: полубаза", cfg.half_base(), 2.185)
	_expect_array(errors, "три оси: смещения как заданы", cfg.axle_list(), [-2.185, 0.006, 2.185])
	_expect(errors, "коллизия узла по Z", BogieMath.collision_length(cfg.half_base(), 0.939), (2.185 + 0.939) * 2.0)

	# 5. Фаза колеса: вперёд по ходу фаза растёт
	_expect(errors, "фаза: старт", BogieMath.wheel_phase(0.0), 0.0)
	_expect(errors, "фаза: полоборота вперёд", BogieMath.wheel_phase(-PI), 0.5)
	_expect(errors, "фаза: четверть оборота вперёд", BogieMath.wheel_phase(-PI / 2.0), 0.25)
	_expect(errors, "фаза: назад на четверть", BogieMath.wheel_phase(PI / 2.0), 0.75)
	_expect(errors, "фаза: полный оборот", BogieMath.wheel_phase(-TAU), 0.0, 0.0001)

	if errors.is_empty():
		print("OK: оси узла, вес точки кузова и фаза колеса")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect(errors: Array[String], name: String, got: float, want: float, tol := 0.00001) -> void:
	if absf(got - want) > tol:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_bool(errors: Array[String], name: String, got: bool, want: bool) -> void:
	if got != want:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _expect_array(errors: Array[String], name: String, got: PackedFloat32Array, want: Array) -> void:
	if got.size() != want.size():
		errors.append("%s: размер %d, ждали %d" % [name, got.size(), want.size()])
		return
	for i in want.size():
		if absf(got[i] - float(want[i])) > 0.00001:
			errors.append("%s: [%d] %s, ждали %s" % [name, i, got[i], want[i]])
