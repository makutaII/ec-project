extends Node

# XX claude-table T0 (новый файл)
## ATTN_23 T0: паспорт подмакетника, LYM и сейв. Запуск: открыть tests/table_layout_test.tscn и нажать F6.
## Результат в Output: во всех строках должно быть OK, в конце ИТОГ: OK.
## Проверяет: LayoutConfig пишет и читает состояние и держит пределы; LYM.table_rect() равен прежнему значению
## (200 x 100 с центром в нуле) и совпадает с TGM.table_rect(); SavedGame хранит layout, room_id; поле room_variants устарело (RM9b), но старый сейв с ним читается;
## сейв без этих полей читается как «до подмакетника».
## Блок «метрика до» печатает высоту верха стола (луч по слою ground) в точках стола и за его краем.
## Сохраните эти числа: после T1 (секция как Entity) они должны совпасть.

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _ready() -> void:
	print("== 1. LayoutConfig: состояние и пределы")
	var c := LayoutConfig.new()
	check("версия в состоянии", c.get_state().get("version") == LayoutConfig.VERSION)
	c.support = LayoutConfig.Support.WALL
	c.height = 80.0
	c.style = &"plywood"
	c.aisle_min = 75.0
	var back := LayoutConfig.new()
	back.set_state(c.get_state())
	check("круг записи и чтения", back.support == LayoutConfig.Support.WALL and back.height == 80.0
			and back.style == &"plywood" and back.aisle_min == 75.0, str(back.get_state()))
	back.set_state({"height": 500.0, "support": 9, "aisle_min": -5.0})
	check("высота не больше предела", back.height == LayoutConfig.HEIGHT_MAX)
	check("опоры вне списка не ломают", back.support == LayoutConfig.Support.WALL)
	check("проход не отрицательный", back.aisle_min == 0.0)
	back.set_state({"height": 1.0})
	check("высота не меньше предела", back.height == LayoutConfig.HEIGHT_MIN)
	back.set_state({})
	check("пустой словарь: значения по умолчанию", back.height == 50.0 and back.support == LayoutConfig.Support.LEGS)

	print("== 2. LYM.table_rect (стол v1)")
	LYM.reset()
	check("LYM.config по умолчанию", LYM.config.height == 50.0)
	var r := LYM.table_rect()
	check("плита 200 x 100 с центром в нуле", r == Rect2(-100.0, -50.0, 200.0, 100.0), str(r))
	check("TGM.table_rect равен LYM.table_rect", TGM.table_rect() == r)
	var fired := [0]
	LYM.layout_changed.connect(func(): fired[0] += 1)
	LYM.set_state(c.get_state())
	check("set_state шлёт layout_changed", fired[0] == 1)
	check("LYM читает состояние", LYM.config.height == 80.0 and LYM.get_state().get("height") == 80.0)
	LYM.reset()
	check("reset: по умолчанию", LYM.config.height == 50.0 and fired[0] == 2)

	print("== 3. SavedGame хранит подмакетник и комнату")
	var sg := SavedGame.new()
	check("старый сейв: layout пуст", sg.layout.is_empty() and sg.room_variants.is_empty())
	sg.layout = c.get_state()
	sg.room_variants = {"wall": "cream", "bedding": "blue"}
	sg.room_id = &"kid_room_10"
	var path := "user://table_layout_test.tres"
	var err := ResourceSaver.save(sg, path)
	check("сейв записан", err == OK, "код %d" % err)
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as SavedGame
	check("layout прочитан", loaded != null and loaded.layout.get("height") == 80.0 and loaded.layout.get("version") == LayoutConfig.VERSION)
	check("room_variants старого сейва читаются (игра их не использует)", loaded != null and loaded.room_variants.get("wall") == "cream" and loaded.room_variants.get("bedding") == "blue")
	check("room_id прочитан", loaded != null and loaded.room_id == &"kid_room_10")
	DirAccess.remove_absolute(path)

	print("== 4. Комната и метрика «до»")
	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, комнату и стол не строим (WoodFloor)")
		print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
		return
	var rb := RoomBuilder.new()
	add_child(rb)
	# XX claude-table T1: плиту строит секция-Entity, RoomBuilder её больше не делает
	var sec := LYM.ensure_start_section(self)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("стартовая секция создана", sec != null and LYM.get_sections().size() == 1)
	check("комната построена", rb.table != null and rb.is_in_group(&"room_root"))
	check("table_rect по паспорту комнаты", LYM.table_rect() == Rect2(-100.0, -50.0, 200.0, 100.0))
	var old_save := SavedGame.new()
	old_save.room_variants = {"wall": "cream"}
	old_save.room_id = &"kid_room_10"
	check("комната старого сейва ставится, варианты игнорируются", rb.request_room(old_save.room_id, RoomBuilder.SRC_LOAD) and rb.get_room_id() == &"kid_room_10")
	await get_tree().physics_frame
	check("стол цел", rb.table != null and is_instance_valid(rb.table))

	var space := get_viewport().world_3d.direct_space_state
	var mask := Global.active_layers(['ground'])
	print("  метрика до: верх стола по лучу сверху вниз (слой ground), u")
	var pts := [Vector2(0, 0), Vector2(90, 40), Vector2(-90, -40), Vector2(99.5, 49.5), Vector2(-99.5, -49.5),
			Vector2(101, 0), Vector2(0, 51), Vector2(-150, 0)]
	for p: Vector2 in pts:
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 50.0, p.y), Vector3(p.x, -200.0, p.y), mask)
		var hit := space.intersect_ray(q)
		print("    (%6.1f, %6.1f)  %s" % [p.x, p.y, ("y = %.3f" % hit.position.y) if not hit.is_empty() else "нет земли"])
	var inside_ok := true
	for p: Vector2 in [Vector2(0, 0), Vector2(90, 40), Vector2(-90, -40)]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, 50.0, p.y), Vector3(p.x, -200.0, p.y), mask))
		inside_ok = inside_ok and not hit.is_empty() and absf(hit.position.y) < 0.001
	check("внутри стола верх на y = 0", inside_ok)
	var out := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(-150, 50.0, 0), Vector3(-150, -200.0, 0), mask))
	check("за краем стола земли нет", out.is_empty())
	rb.queue_free()
	if sec != null:
		sec.free()

	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
