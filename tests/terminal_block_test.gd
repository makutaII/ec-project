extends Node

# XX claude-wire W6 (новый файл)
## ATTN_23 W6: клеммник. Запуск: открыть tests/terminal_block_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: паспорт (ключ, тег switch, монтаж), число клемм (по умолчанию 4, один вход, остальные выходы), проводимость выходов на вход,
## смену числа клемм (убрать только свободные, занятые не уходят, добавленные встают по центру), сейв.

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _ready() -> void:
	var s := load("res://data/power/objects/terminal_block_01.tres") as EntitySetting
	check("паспорт загружен: категория dc_controller, тег switch", s != null and s.category == &"dc_controller" and s.tag == &"switch")
	check("клеммник ставится на плиту и на полку (монтаж)", s != null and Mount.has_mount(s))
	if s == null:
		print("ИТОГ: ОШИБОК %d" % (_bad + 1))
		return
	var f := EntityFactory.new()
	var e := f.create_from_setting(s)
	f.free()
	add_child(e)
	await get_tree().physics_frame
	var tb := e.get_comp(C_TerminalBlock) as C_TerminalBlock
	check("компонент C_TerminalBlock создан, по умолчанию 4 клеммы", tb != null and tb.count == 4)
	if tb == null:
		print("ИТОГ: ОШИБОК %d" % (_bad + 1))
		return
	print("== 1. Клеммы")
	check("t1 вход (DEV_IN), t2..t4 выходы (DEV_OUT)", tb.term(&"t1") != null and tb.term(&"t1").role == PowerTerminal.Role.DEV_IN \
			and tb.term(&"t2").role == PowerTerminal.Role.DEV_OUT and tb.term(&"t4").role == PowerTerminal.Role.DEV_OUT and tb.term(&"t5") == null)
	var xs := []
	for i in 4:
		xs.append(tb.term(StringName("t%d" % (i + 1))).position.x)
	check("клеммы по центру корпуса с шагом SPACING", is_equal_approx(xs[0], -1.5) and is_equal_approx(xs[3], 1.5) and is_equal_approx(xs[1] - xs[0], C_TerminalBlock.SPACING), str(xs))
	check("подпись и заголовок", tb.title() == "Клеммник" and tb.state_text().contains("4") and tb.positions() == 0)
	print("== 2. Проводимость")
	var l2 := tb._links_of(tb.term(&"t2"))
	check("любой выход проводит на вход без переворота полярности", l2.size() == 1 and l2[0]["terminal"] == tb.term(&"t1") and l2[0]["flip"] == false and l2[0]["via"] == tb)
	check("у входа внутренних связей нет", tb._links_of(tb.term(&"t1")).is_empty())
	print("== 3. Число клемм")
	check("ограничения: 2..5", C_TerminalBlock.MIN_TERMS == 2 and C_TerminalBlock.MAX_TERMS == 5)
	check("уменьшить до 2: лишние клеммы убраны", tb.set_count(2) == "" and tb.count == 2 and tb.term(&"t3") == null and tb.term(&"t4") == null)
	await get_tree().physics_frame
	check("осталось 2 клеммы по центру", is_equal_approx(tb.term(&"t1").position.x, -0.5) and is_equal_approx(tb.term(&"t2").position.x, 0.5))
	check("увеличить до 5: клеммы добавлены, все переставлены", tb.set_count(5) == "" and tb.count == 5 and tb.term(&"t5") != null \
			and is_equal_approx(tb.term(&"t1").position.x, -2.0) and is_equal_approx(tb.term(&"t5").position.x, 2.0))
	check("больше 5 и меньше 2 зажимаются", tb.set_count(9) == "" and tb.count == 5 and tb.set_count(0) == "" and tb.count == 2)
	tb.set_count(4)
	var sink := PowerTerminal.new()
	sink.role = PowerTerminal.Role.SINK
	add_child(sink)
	var wire_e := C_Wire.create_wire(self, tb.term(&"t4"), sink, PackedVector3Array([Vector3(0, 0.2, 0), Vector3(10, 0.2, 0)]))
	check("к выходу клеммника можно подключить провод", wire_e != null)
	var why := tb.set_count(3)
	check("занятую клемму убрать нельзя, причина названа", why != "" and tb.count == 4 and tb.term(&"t4") != null, why)
	wire_e.kill_me()
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("провод снят: клемму убрать можно", tb.set_count(3) == "" and tb.count == 3 and tb.term(&"t4") == null)
	print("== 4. Сейв")
	var d := tb.save_data()
	check("в сейве число клемм", d == {"count": 3}, str(d))
	tb.load_data({"count": 5})
	check("загрузка: 5 клемм", tb.count == 5 and tb.term(&"t5") != null)
	tb.load_data({})
	check("пустой сейв оставляет число клемм", tb.count == 5)
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
