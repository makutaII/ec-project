@tool
extends EditorScript

###########################
## Проверка привода от колеса (паровоз: этап K4)
###########################
## Запуск: открыть файл, File → Run (Ctrl+Shift+X). Сцена и сущность не нужны. Проверяет:
## 1. C_Bogie.wheel_phase: выбор ведущего (самого большого) колеса и колеса по роли, фаза по накопленному углу;
## 2. Mech.linear: позы по анимации идут линейно по фазе (без smoothstep), как для цикла привода.
## Итог в Output: «OK» или список ошибок. Предупреждение «колесо с ролью ... не найдено» от проверки 1 ожидаемо.


func _run() -> void:
	var errors: Array[String] = []

	# 1. Фаза колёс. У колеса: radius, role, angle (накопленный угол, вперёд по ходу он уменьшается)
	var bg := C_Bogie.new()
	bg.wheel_nodes.append({"radius": 0.541, "role": &"wheel_2_1", "angle": 0.0})
	bg.wheel_nodes.append({"radius": 0.939, "role": &"wheel_4_1", "angle": -PI})
	bg.wheel_nodes.append({"radius": 0.939, "role": &"wheel_4_2", "angle": -PI})
	_near(errors, "без роли: ведущее колесо, пол-оборота вперёд", bg.wheel_phase(), 0.5)
	_near(errors, "роль малого колеса", bg.wheel_phase(&"wheel_2_1"), 0.0)
	_near(errors, "роль ведущего колеса", bg.wheel_phase(&"wheel_4_2"), 0.5)
	_near(errors, "чужая роль (part_role по умолчанию): ведущее колесо", bg.wheel_phase(&"door_left"), 0.5)
	_near(errors, "нет такого колеса: ноль", bg.wheel_phase(&"wheel_9_9"), 0.0)
	bg.free()
	var empty := C_Bogie.new()
	_near(errors, "колёс нет: ноль", empty.wheel_phase(), 0.0)
	empty.free()

	# 2. Позы по фазе: деталь сдвигается на 4 по X за один оборот, ключи на 0 и 2 с (как после экспорта цикла)
	var root := Node3D.new()
	var rod := Node3D.new()
	rod.name = "drv_rod"
	root.add_child(rod)
	var anim := Animation.new()
	anim.length = 2.0
	var tp := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(tp, NodePath("drv_rod"))
	anim.position_track_insert_key(tp, 0.0, Vector3.ZERO)
	anim.position_track_insert_key(tp, 2.0, Vector3(4, 0, 0))
	var lib := AnimationLibrary.new()
	lib.add_animation(&"mech_drive", anim)
	var player := AnimationPlayer.new()
	root.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library(&"", lib)

	var cfg := MechanismConfig.new()
	cfg.id = &"drive"
	cfg.actuator = MechanismConfig.Actuator.ANIM
	cfg.source = MechanismConfig.Source.WHEEL_PHASE
	var m := C_Mechanisms.Mech.new()
	m.cfg = cfg
	_check(errors, "анимация mech_drive найдена", C_Mechanisms.bind_anim(m, root, "тест"))
	m.linear = true
	m.t = 0.25
	m.apply()
	_near(errors, "фаза 0.25: линейно, x = 1", rod.position.x, 1.0)
	m.t = 0.75
	m.apply()
	_near(errors, "фаза 0.75: x = 3", rod.position.x, 3.0)
	m.t = 0.0
	m.apply()
	_near(errors, "фаза 0: поза покоя", rod.position.x, 0.0)
	m.linear = false
	m.t = 0.25
	m.apply()
	_near(errors, "для команд (не фаза) прежний smoothstep: x = 4 * 0.15625", rod.position.x, 4.0 * smoothstep(0.0, 1.0, 0.25))
	m.linear = true
	m.t = 0.5
	_near(errors, "pose_error по фазе: ноль после apply", _apply_error(m), 0.0)
	root.free()

	if errors.is_empty():
		print("OK: фаза колеса и линейные позы цикла привода")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _apply_error(m: C_Mechanisms.Mech) -> float:
	m.apply()
	return m.pose_error()


func _check(errors: Array[String], name: String, ok: bool) -> void:
	if not ok:
		errors.append(name)


func _near(errors: Array[String], name: String, got: float, want: float, tol := 0.0001) -> void:
	if absf(got - want) > tol:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
