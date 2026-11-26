extends Node

# XX claude-table T1 (новый файл)
## ATTN_23 T1: секция стола как Entity. Запуск: открыть tests/table_section_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: пресеты каталога table.section.*; стартовая секция 200 x 100 и верх плиты на y = 0 по лучу ground;
## за краем земли нет; сумма секций в LYM.table_rect; последняя секция не удаляется; запись и чтение секции.

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _top(p: Vector2) -> Variant:
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 50.0, p.y), Vector3(p.x, -200.0, p.y), Global.active_layers(['ground']))
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(q)
	return null if hit.is_empty() else hit.position.y


func _ready() -> void:
	print("== 1. Пресеты каталога")
	for stem in ["sec_100x200", "sec_100x100", "sec_50x100", "sec_200x100"]:
		var s := load("res://data/table/objects/%s.tres" % stem) as EntitySetting
		check("пресет " + stem, s != null and s.category == &"table" and s.tag == &"section")
	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, секции не создаются")
		print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
		return

	print("== 2. Стартовая секция")
	LYM.reset()
	var a := LYM.ensure_start_section(self)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("секция создана", a != null and LYM.get_sections().size() == 1)
	check("table_rect 200 x 100", LYM.table_rect() == Rect2(-100.0, -50.0, 200.0, 100.0), str(LYM.table_rect()))
	check("повторный вызов ничего не добавляет", LYM.ensure_start_section(self) == null and LYM.get_sections().size() == 1)
	var t0 = _top(Vector2(0, 0))
	check("верх плиты на y = 0", t0 != null and absf(t0) < 0.001, str(t0))
	check("у края внутри тоже", _top(Vector2(99.5, 49.5)) != null)
	check("за краем земли нет", _top(Vector2(-150, 0)) == null)
	check("contains: внутри и снаружи", LYM.contains(0, 0) and LYM.contains(100, 50) and not LYM.contains(101, 0))

	check("has_table: секция есть", LYM.has_table())   # XX claude-table T4c
	print("== 3. Последняя секция (T4b: убрать можно, стол остаётся пустым)")
	check("пустую последнюю убирать можно", LYM.removal_block_reason(a) == "")
	a.kill_me()
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("kill_me её убрал", not is_instance_valid(a) or a.is_queued_for_deletion())
	check("секций нет, футпринт пуст", LYM.get_sections().is_empty() and LYM.footprint().is_empty())
	check("has_table: секций нет", LYM.has_table() == Global.fast_debug)   # XX claude-table T4c
	check("земли нет", _top(Vector2(0, 0)) == null)
	check("table_rect по паспорту комнаты", LYM.table_rect() == Rect2(-100.0, -50.0, 200.0, 100.0), str(LYM.table_rect()))
	a = LYM.ensure_start_section(self)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("стартовая секция создаётся снова", a != null and LYM.get_sections().size() == 1 and _top(Vector2(0, 0)) != null)

	print("== 4. Вторая секция")
	var setting := load("res://data/table/objects/sec_100x100.tres") as EntitySetting
	var f := EntityFactory.new()
	var b := f.create_from_setting(setting)
	f.free()
	add_child(b)
	b.global_position = Vector3(150, 0, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("секций две", LYM.get_sections().size() == 2)
	check("table_rect вырос", LYM.table_rect() == Rect2(-100.0, -50.0, 300.0, 100.0), str(LYM.table_rect()))
	var tb = _top(Vector2(150, 0))
	check("верх второй на y = 0", tb != null and absf(tb) < 0.001, str(tb))
	check("вторую убирать можно", LYM.removal_block_reason(b) == "")

	print("== 5. Запись и чтение")
	var sec := b.get_comp(C_TableSection) as C_TableSection
	sec.thickness = 8.0
	var data := sec.save_data()
	sec.thickness = 5.0
	sec.load_data(data)
	check("толщина прочитана", sec.thickness == 8.0, str(sec.thickness))

	b.free()
	a.free()
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
