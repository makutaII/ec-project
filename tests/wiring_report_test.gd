extends Node

# XX claude-wire W6 (новый файл)
## ATTN_23 W6: секция хранит проводку. Запуск: открыть tests/wiring_report_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: LYM.wiring_report (блоки, пульты, провода, длина по участкам, вводы, свободные концы), причину отказа удаления секции
## (блоки и провода называются своими именами), LYM.wiring_problems (блок и провод под плитой без полки), сообщение при смене макета.

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _section(preset: String, pos: Vector2) -> Entity:
	var f := EntityFactory.new()
	var e := f.create_from_setting(load("res://data/table/objects/%s.tres" % preset) as EntitySetting)
	f.free()
	e.position = Vector3(pos.x, 0.0, pos.y)
	add_child(e)
	return e


func _block(at: Vector3) -> Entity:
	var f := EntityFactory.new()
	var e := f.create_from_setting(load("res://data/power/objects/block_selector_01.tres") as EntitySetting)
	f.free()
	add_child(e)
	e.global_position = at
	return e


func _ready() -> void:
	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, секции не создаются")
		print("ИТОГ: OK")
		return
	LYM.reset()
	var a := _section("sec_200x100", Vector2.ZERO)        # x -100..100
	var b := _section("sec_100x100", Vector2(150, 0))     # x 100..200
	await get_tree().physics_frame
	LYM.set_apron(true)
	var top := LYM.shelf_top()
	var lift: float = Global.settings.wire_lift
	check("нижняя полка есть, верх ниже плиты", not LYM.shelf_polygons().is_empty() and top < -5.0, str(top))

	print("== 1. Отчёт секции")
	var empty := LYM.wiring_report(b)
	check("пустая секция: всё по нулям", empty["blocks"] == 0 and empty["wires"] == 0 and empty["holes"] == 0 and empty["free_ends"] == 0 and is_equal_approx(empty["length"], 0.0), str(empty))
	var blk := _block(Vector3(150, top, 0))
	var wire := C_Wire.create_wire(self, null, null, PackedVector3Array([
			Vector3(130, lift, 0), Vector3(150, lift, 0), Vector3(150, top + lift, 0), Vector3(170, top + lift, 0)]))
	await get_tree().physics_frame
	var rb := LYM.wiring_report(b)
	check("блок на полке под секцией B", rb["blocks"] == 1, str(rb))
	check("провод на секции B: один, ввод в плиту один, оба конца свободны", rb["wires"] == 1 and rb["holes"] == 1 and rb["free_ends"] == 2, str(rb))
	var expected := 40.0 + absf(top)   # 20 по столу, вертикаль через плиту до полки, 20 по полке
	check("длина провода по участкам над секцией", absf(rb["length"] - expected) < 0.2, "%s ожидали %s" % [rb["length"], expected])
	var ra := LYM.wiring_report(a)
	check("секция A (под нулём мира) ничего не хранит", ra["blocks"] == 0 and ra["wires"] == 0)

	print("== 2. Отказ удаления секции")
	var why := LYM.removal_block_reason(b)
	check("причина называет блоки и провода", why.contains("Блоки 1") and why.contains("Провода 1"), why)
	check("секцию A убрать можно", LYM.removal_block_reason(a) == "")

	print("== 3. Проводка без опоры")
	check("полка есть: проблем нет", LYM.wiring_problems().is_empty(), str(LYM.wiring_problems()))
	var seen: Array[String] = []
	LYM.notice.connect(func(t: String) -> void: seen.append(t))
	LYM.set_apron(false)
	var problems := LYM.wiring_problems()
	check("подрамник выключен: блок и провод без опоры", problems.size() == 2, str(problems))
	check("в списке блок назван, провод назван", " ".join(problems).contains("Коммутатор") or " ".join(problems).contains("под столом"), str(problems))
	check("при смене макета есть сообщение о проводке без опоры", seen.any(func(t: String) -> bool: return t.contains("без опоры")), str(seen))
	var n_before := seen.size()
	LYM.set_apron(false)
	LYM.set_height(LYM.config.height)
	check("повторные смены без новых проблем молчат", seen.size() == n_before)
	LYM.set_apron(true)
	check("полку вернули: проблем нет", LYM.wiring_problems().is_empty(), str(LYM.wiring_problems()))
	blk.global_position = Vector3(150, top - 3.0, 0)
	check("блок ниже полки: проблема", LYM.wiring_problems().size() == 1)
	blk.global_position = Vector3(150, top, 0)
	check("блок на плите сверху проблемой не считается", _block(Vector3(150, 0, 0)) != null and LYM.wiring_problems().is_empty())
	var out_edge := _block(Vector3(-99, top, 0))
	check("блок под плитой вне полки (у края): проблема", LYM.wiring_problems().size() == 1, str(LYM.wiring_problems()))
	out_edge.queue_free()
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
