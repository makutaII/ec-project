@tool
extends EditorScript

###########################
## Проверка сборки тележек из модели (паровоз: этап K3)
###########################
## Запуск: открыть файл, File → Run (Ctrl+Shift+X). Строит в памяти дерево узлов как у .glb (extras role и radius в meta),
## прогоняет ModelRig.extract. Сцена не нужна. Предупреждения в Output от проверок «колесо без radius» и «радиусы различаются»
## ожидаемы. Итог: «OK» или список ошибок.


func _run() -> void:
	var errors: Array[String] = []

	# 1. Разбор ролей
	_eq(errors, "unit_12", ModelRig.parse_unit("unit_12"), 12)
	_eq(errors, "unit_ без номера", ModelRig.parse_unit("unit_"), -1)
	_eq(errors, "unit_1a", ModelRig.parse_unit("unit_1a"), -1)
	_eq(errors, "wheel_2_3", ModelRig.parse_wheel("wheel_2_3"), [2, 3])
	_eq(errors, "wheel_2", ModelRig.parse_wheel("wheel_2"), [])
	_eq(errors, "wheel_1_11 и wheel_11_1 различаются", ModelRig.parse_wheel("wheel_1_11"), [1, 11])

	# 2. Дерево как у .glb: корень вагона -> корень модели -> body -> узлы тележек
	var root := Node3D.new()
	var glb := Node3D.new()
	root.add_child(glb)
	var body := MeshInstance3D.new()
	body.name = "body"
	glb.add_child(body)
	var rod := MeshInstance3D.new()
	rod.name = "drv_rod"
	rod.set_meta("extras", {"role": "drv_rod"})
	body.add_child(rod)
	# узел 4 создан раньше узла 2: порядок в результате идёт по номерам
	_unit(body, 4, Vector3(0, -0.122, 0.1), [[1, 0.939, -2.185], [2, 0.939, 0.006], [3, 0.939, 2.185]])
	_unit(body, 2, Vector3(0, -0.52, -5.3), [[1, 0.541, -1.18], [2, 0.541, 1.18]])
	# узел 3: крайние оси несимметричны (-2.0 и 2.5): центр узла должен сдвинуться на 0.25
	_unit(body, 3, Vector3(0, -0.52, 5.0), [[1, 0.541, -2.0], [2, 0.541, 0.0], [3, 0.541, 2.5]])

	var rig := ModelRig.extract(root, "тест")
	_check(errors, "узлы найдены", rig != null)
	if rig != null:
		_eq(errors, "число узлов", rig.units.size(), 3)
		_eq(errors, "порядок по номерам", [rig.units[0].number, rig.units[1].number, rig.units[2].number], [2, 3, 4])
		_eq(errors, "конфигов столько же, сколько узлов", rig.bogie_configs.size(), 3)

		var c2 := rig.units[0].config
		_near(errors, "unit_2: b_offset_z", c2.b_offset_z, -5.3)
		_near(errors, "unit_2: радиус", c2.wheel_pair_position.y, 0.541)
		_near(errors, "unit_2: полубаза", c2.half_base(), 1.18)
		_eq(errors, "unit_2: две оси", c2.axle_list().size(), 2)

		var c3 := rig.units[1].config
		_near(errors, "unit_3: центр сдвинут на середину осей", c3.b_offset_z, 5.25)
		_near(errors, "unit_3: полубаза", c3.half_base(), 2.25)
		_near(errors, "unit_3: смещения симметричны", c3.axle_offsets[0] + c3.axle_offsets[2], 0.0)
		_check(errors, "unit_3: крайние оси симметричны", BogieMath.extremes_symmetric(c3.axle_offsets))
		_near(errors, "unit_3: колесо сдвинуто вместе с центром", rig.units[1].wheels[0].node.position.z, -2.25)

		var c4 := rig.units[2].config
		_near(errors, "unit_4: b_offset_z", c4.b_offset_z, 0.1)
		_near(errors, "unit_4: радиус", c4.wheel_pair_position.y, 0.939)
		_eq(errors, "unit_4: три оси", c4.axle_list().size(), 3)
		_near(errors, "unit_4: средняя ось", c4.axle_offsets[1], 0.006)
		_eq(errors, "unit_4: колёса в порядке номеров", [rig.units[2].wheels[0].role, rig.units[2].wheels[2].role], [&"wheel_4_1", &"wheel_4_3"])

		for u in rig.units:
			_check(errors, "unit_%d вынут из кузова" % u.number, u.node.get_parent() == null)
			_check(errors, "unit_%d: колёса остались детьми узла" % u.number, u.wheels[0].node.get_parent() == u.node)
			_check(errors, "unit_%d: у колеса есть меш под шейдер" % u.number, u.wheels[0].meshes.size() == 1)
		_check(errors, "в кузове остался только привод", body.get_child_count() == 1 and body.get_child(0) == rod)
		for u in rig.units:
			u.node.free()

	# 3. Модель без узлов: прежний путь (null)
	var plain := Node3D.new()
	plain.add_child(MeshInstance3D.new())
	_check(errors, "модель без unit_*: null", ModelRig.extract(plain, "тест") == null)
	plain.free()

	# 4. Узел, у которого колесо без radius, пропускается: единственный узел модели не годится, ждём null
	var bad := Node3D.new()
	var bad_body := MeshInstance3D.new()
	bad.add_child(bad_body)
	var bu := Node3D.new()
	bu.set_meta("extras", {"role": "unit_1"})
	bad_body.add_child(bu)
	var bw := MeshInstance3D.new()
	bw.set_meta("extras", {"role": "wheel_1_1"})   # radius нет
	bu.add_child(bw)
	_check(errors, "колесо без radius: узел пропущен, null", ModelRig.extract(bad, "тест") == null)
	bad.free()

	root.free()

	if errors.is_empty():
		print("OK: тележки из модели собираются по узлам unit_* и колёсам wheel_*")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


## Узел тележки как в .glb: роль и radius лежат в meta "extras"
func _unit(parent: Node3D, number: int, pos: Vector3, wheels: Array) -> Node3D:
	var u := Node3D.new()
	u.name = "unit_%d" % number
	u.set_meta("extras", {"role": "unit_%d" % number})
	u.position = pos
	parent.add_child(u)
	for w in wheels:
		var m := MeshInstance3D.new()
		m.name = "wheel_%d_%d" % [number, w[0]]
		m.set_meta("extras", {"role": "wheel_%d_%d" % [number, w[0]], "radius": w[1]})
		m.position = Vector3(0, 0, w[2])
		u.add_child(m)
	return u


func _check(errors: Array[String], name: String, ok: bool) -> void:
	if not ok:
		errors.append(name)


func _eq(errors: Array[String], name: String, got: Variant, want: Variant) -> void:
	if got != want:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])


func _near(errors: Array[String], name: String, got: float, want: float, tol := 0.0001) -> void:
	if absf(got - want) > tol:
		errors.append("%s: получили %s, ждали %s" % [name, got, want])
