extends Node

# XX claude-wire W5 (новый файл)
## ATTN_23 W5: провод со свободным концом. Запуск: открыть tests/wire_free_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: создание провода с одной клеммой и свободным концом (в граф не идёт, клемму занимает, ручка WireEnd на конце), провод без клемм,
## отказ при одной точке, причины подключения свободного конца (end_refuse_reason), подключение (reroute), втулку в плите,
## сейв и загрузку свободного конца, probe_points со свободным концом.

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _term(role: PowerTerminal.Role, pos: Vector3) -> PowerTerminal:
	var t := PowerTerminal.new()
	t.role = role
	add_child(t)
	t.position = pos
	return t


func _wc(e: Entity) -> C_Wire:
	return e.get_comp(C_Wire) as C_Wire if e != null else null


func _ready() -> void:
	print("== 1. Провод: клемма и свободный конец")
	var sink := _term(PowerTerminal.Role.SINK, Vector3(10, 0.6, 0))
	var e := C_Wire.create_wire(self, sink, null, PackedVector3Array([Vector3(10, 0.2, 0), Vector3(30, 0.2, 0)]))
	var w := _wc(e)
	check("провод создан", w != null)
	if w == null:
		print("ИТОГ: ОШИБОК %d" % (_bad + 1))
		return
	check("живой, но не полный: в граф не идёт", w.is_alive() and not w.is_valid_wire())
	check("клемма занята проводом", sink.wires.has(w) and not sink.is_free())
	check("конец b свободен, a подключён", w.end_is_free(&"b") and not w.end_is_free(&"a"))
	check("свободный конец в последней точке", w.free_end_pos(&"b").is_equal_approx(Vector3(30, 0.2, 0)))
	var hs := w.end_handles()
	check("одна ручка свободного конца, это конец b", hs.size() == 1 and hs[0].which == &"b" and hs[0].wire == w and hs[0].position.is_equal_approx(Vector3(30, 0.2, 0)))
	check("ручка на слое power", hs.size() == 1 and (hs[0].collision_layer & Global.active_layers(["power"])) != 0)
	check("probe_points: оба узла", w.probe_points().size() == 2 and w.probe_points()[1] == Vector2(30, 0))

	print("== 2. Причины подключения свободного конца")
	var src := _term(PowerTerminal.Role.SRC, Vector3(30, 0.6, 5))
	var sink2 := _term(PowerTerminal.Role.SINK, Vector3(40, 0.6, 5))
	check("к клемме источника можно", w.end_refuse_reason(&"b", src) == "")
	check("к клемме потребителя нельзя (обе стороны вниз по току)", w.end_refuse_reason(&"b", sink2) != "")
	check("занятый конец a нельзя подключать", w.end_refuse_reason(&"a", src) != "")
	check("после проверки клемма a по-прежнему занята этим проводом", sink.wires.has(w))
	var busy := _term(PowerTerminal.Role.SINK, Vector3(50, 0.6, 5))
	var other := C_Wire.create_wire(self, busy, null, PackedVector3Array([Vector3(50, 0.2, 5), Vector3(60, 0.2, 5)]))
	check("занятая клемма отказывает", other != null and w.end_refuse_reason(&"b", busy) != "")

	print("== 3. Подключение конца (reroute)")
	w.reroute(PackedVector3Array([Vector3(10, 0.2, 0), Vector3(30, 0.2, 0), Vector3(30, 0.2, 5)]), &"b", src)
	check("провод стал полным", w.is_valid_wire() and not w.end_is_free(&"b"))
	check("ручек нет", w.end_handles().is_empty())
	check("клемма b занята проводом", src.wires.has(w))

	print("== 4. Втулка в плите")
	var sink3 := _term(PowerTerminal.Role.SINK, Vector3(0, -9.4, 0))
	var vert := C_Wire.create_wire(self, sink3, null, PackedVector3Array([Vector3(0, -9.0, 0), Vector3(20, -9.0, 0), Vector3(20, 0.2, 0), Vector3(40, 0.2, 0)]))
	var wv := _wc(vert)
	await get_tree().physics_frame
	check("вертикаль через плиту: втулка и ручка конца", vert != null and wv != null and wv._extras.size() == 2, str(wv._extras.size() if wv else -1))

	print("== 5. Оба конца свободны")
	var both := C_Wire.create_wire(self, null, null, PackedVector3Array([Vector3(0, 0.2, 20), Vector3(10, 0.2, 20)]))
	var wb := _wc(both)
	check("создан, две ручки: a и b", wb != null and wb.end_handles().size() == 2 and wb.end_is_free(&"a") and wb.end_is_free(&"b"))
	check("свободный конец a это первая точка", wb != null and wb.free_end_pos(&"a").is_equal_approx(Vector3(0, 0.2, 20)))
	check("одна точка без клемм: провода нет", C_Wire.create_wire(self, null, null, PackedVector3Array([Vector3(0, 0.2, 20)])) == null)
	check("клемма и ни одной точки: провода нет", C_Wire.create_wire(self, sink2, null, PackedVector3Array()) == null)
	check("клемма и одна точка: можно", _wc(C_Wire.create_wire(self, sink2, null, PackedVector3Array([Vector3(40, 0.2, 5)]))) != null)

	print("== 6. Сейв и загрузка свободного конца")
	var src2 := _term(PowerTerminal.Role.SRC, Vector3(70, 0.6, 0))
	src2.add_to_group(&"power_terminal")   # группу даёт PowerTerminal.create; у терминала из new() её нет, а загрузка ищет клемму по группе
	var saved_e := C_Wire.create_wire(self, src2, null, PackedVector3Array([Vector3(70, 0.2, 0), Vector3(80, 0.2, 10)]), true)
	var sw := _wc(saved_e)
	var d := sw.save_data()
	check("в сейве клемма a, нет b, точки и скрутка", d.has("a") and not d.has("b") and (d["points"] as PackedVector3Array).size() == 2 and d["twist"] == true)
	var full := _wc(C_Wire.create_wire(self, _term(PowerTerminal.Role.SRC, Vector3(100, 0.6, 0)), _term(PowerTerminal.Role.SINK, Vector3(110, 0.6, 0)), PackedVector3Array([Vector3(100, 0.2, 0), Vector3(110, 0.2, 0)])))
	var fd := full.save_data()
	check("полный провод пишет обе клеммы, как раньше", fd.has("a") and fd.has("b"))
	saved_e.kill_me()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var f := EntityFactory.new()
	var e2 := f.create_from_setting(load(C_Wire.WIRE_SETTING_PATH) as EntitySetting)
	f.free()
	add_child(e2)
	var w2 := _wc(e2)
	w2.load_data(d)
	check("загрузка: клемма найдена, конец остался свободным", w2.restore_after_load() and is_instance_valid(w2.a) and w2.end_is_free(&"b") and w2.twist)
	check("загрузка: ручка на конце, живой, не полный", w2.end_handles().size() == 1 and w2.is_alive() and not w2.is_valid_wire())
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
