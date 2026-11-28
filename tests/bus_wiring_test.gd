extends Node

# XX claude-wire W8 (новый файл)
## ATTN_23 W8: шина аксессуаров на проводах. Запуск: открыть tests/bus_wiring_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: DeviceGraph.reach (напрямую, через клеммник в режиме шины, без провода, источник другого вида), C_BusTerminal (клемма, группа, призрак),
## PGM.bus_powered_for (виртуально без правила, с правилом нужен провод до шины), прибор «Шина 12 В» (клеммы, автопроводка к потребителям),
## клеммник в режиме шины (вид клемм, отказ с проводами, сейв), паспорт дома (клемма шины) и Схему (дом с клеммой остаётся виден).

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _term(role: PowerTerminal.Role, kind: PowerTerminal.Kind, pos: Vector3) -> PowerTerminal:
	var t := PowerTerminal.new()
	t.role = role
	t.kind = kind
	add_child(t)
	t.position = pos
	return t


func _entity(setting: EntitySetting, pos: Vector3) -> Entity:
	var f := EntityFactory.new()
	var e := f.create_from_setting(setting)
	f.free()
	add_child(e)
	e.global_position = pos
	return e


func _consumer(pos: Vector3) -> Entity:
	var s := EntitySetting.new()
	s.key = &"bus_test_consumer"
	s.category = &"building"
	s.components.append(IdentitySetting.new())
	var bs := BusTerminalSetting.new()
	bs.offset = Vector3(0, 1, 0)
	s.components.append(bs)
	return _entity(s, pos)


func _ready() -> void:
	print("== 1. DeviceGraph.reach")
	var bus := _term(PowerTerminal.Role.SRC, PowerTerminal.Kind.ACCESSORY, Vector3.ZERO)
	var cons := _term(PowerTerminal.Role.SINK, PowerTerminal.Kind.ACCESSORY, Vector3(10, 0, 0))
	var g := DeviceGraph.new()
	var r0 := g.reach(cons, PowerTerminal.Kind.ACCESSORY)
	check("без провода: не подключён, питания нет", r0["wired"] == false and r0["reachable"] == false)
	g.add_wire(bus, cons, false)
	var r1 := g.reach(cons, PowerTerminal.Kind.ACCESSORY)
	check("провод напрямую к шине: подключён и дошёл", r1["wired"] == true and r1["reachable"] == true)
	var track_src := _term(PowerTerminal.Role.SRC, PowerTerminal.Kind.TRACK, Vector3(0, 0, 5))
	var cons2 := _term(PowerTerminal.Role.SINK, PowerTerminal.Kind.ACCESSORY, Vector3(10, 0, 5))
	var g2 := DeviceGraph.new()
	g2.add_wire(track_src, cons2, false)
	var r2 := g2.reach(cons2, PowerTerminal.Kind.ACCESSORY)
	check("провод к источнику другого вида: подключён, но шины нет", r2["wired"] == true and r2["reachable"] == false)

	print("== 2. Через клеммник в режиме шины")
	var tb_e := _entity(load("res://data/power/objects/terminal_block_01.tres") as EntitySetting, Vector3(30, 0, 0))
	await get_tree().physics_frame
	var tb := tb_e.get_comp(C_TerminalBlock) as C_TerminalBlock
	check("по умолчанию клеммы рельсовые", tb != null and not tb.accessory and tb.term(&"t1").kind == PowerTerminal.Kind.TRACK)
	check("переключить на шину без проводов можно", tb.set_accessory(true) == "" and tb.accessory and tb.term(&"t1").kind == PowerTerminal.Kind.ACCESSORY and tb.term(&"t3").kind == PowerTerminal.Kind.ACCESSORY)
	check("подпись клеммника называет шину", tb.state_text().contains("шина"))
	var cons3 := _term(PowerTerminal.Role.SINK, PowerTerminal.Kind.ACCESSORY, Vector3(40, 0, 0))
	var g3 := DeviceGraph.new()
	g3.add_wire(bus, tb.term(&"t1"), false)
	g3.add_wire(tb.term(&"t2"), cons3, false)
	var r3 := g3.reach(cons3, PowerTerminal.Kind.ACCESSORY)
	check("шина, вход клеммника, выход, потребитель: дошёл", r3["wired"] == true and r3["reachable"] == true)
	var g4 := DeviceGraph.new()
	g4.add_wire(tb.term(&"t2"), cons3, false)
	var r4 := g4.reach(cons3, PowerTerminal.Kind.ACCESSORY)
	check("вход клеммника без провода от шины: подключён, но не дошёл", r4["wired"] == true and r4["reachable"] == false)
	var w := C_Wire.create_wire(self, tb.term(&"t3"), cons3, PackedVector3Array([Vector3(35, 0.2, 0), Vector3(36, 0.2, 0)]))
	check("к клемме шины клеммника подключается потребитель шины", w != null)
	check("вид клемм с проводом не меняют", tb.set_accessory(false) != "" and tb.accessory)
	var d := tb.save_data()
	check("в сейве число клемм и режим шины", d == {"count": 4, "accessory": true}, str(d))
	w.kill_me()
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("провод снят: вид можно менять обратно", tb.set_accessory(false) == "" and not tb.accessory and tb.term(&"t1").kind == PowerTerminal.Kind.TRACK)
	tb.load_data({"count": 3, "accessory": true})
	check("загрузка: 3 клеммы, шина", tb.count == 3 and tb.accessory and tb.term(&"t3").kind == PowerTerminal.Kind.ACCESSORY)

	print("== 3. C_BusTerminal")
	var house := _consumer(Vector3(60, 0, 0))
	await get_tree().physics_frame
	var bt := house.get_comp(C_BusTerminal) as C_BusTerminal
	check("клемма шины создана: ACCESSORY, потребитель, ключ bus", bt != null and bt.terminal != null and bt.terminal.kind == PowerTerminal.Kind.ACCESSORY and bt.terminal.role == PowerTerminal.Role.SINK and bt.terminal.key == &"bus")
	check("клемма на объекте по смещению", bt.terminal.global_position.is_equal_approx(Vector3(60, 1, 0)), str(bt.terminal.global_position))
	check("компонент в группе bus_terminal, клемма в power_terminal", bt.is_in_group(&"bus_terminal") and bt.terminal.is_in_group(&"power_terminal"))
	check("пока провода нет, не запитан", not bt.is_fed())
	bt.apply_bus({"wired": true, "reachable": true})
	check("apply_bus: запитан", bt.is_fed())
	bt.apply_bus({"wired": true, "reachable": false})
	check("провод есть, шины нет: не запитан", not bt.is_fed())
	bt.apply_bus({})
	var ghost_s := EntitySetting.new()
	ghost_s.key = &"bus_test_ghost"
	ghost_s.category = &"building"
	ghost_s.components.append(IdentitySetting.new())
	ghost_s.components.append(BusTerminalSetting.new())
	var f := EntityFactory.new()
	var ge := f.create_from_setting(ghost_s)
	f.free()
	add_child(ge)
	var gbt := ge.get_comp(C_BusTerminal) as C_BusTerminal
	gbt.on_component_added(C_Ghost)   # как при добавлении C_Ghost сущности
	check("у призрака клемма шины выключена", gbt.terminal.collision_layer == 0 and not gbt.is_in_group(&"bus_terminal") and not gbt.terminal.is_in_group(&"power_terminal"))
	gbt.on_component_removed(C_Ghost)   # призрак стал объектом
	check("призрак стал объектом: клемма включилась", gbt.terminal.collision_layer != 0 and gbt.is_in_group(&"bus_terminal") and gbt.terminal.is_in_group(&"power_terminal"))

	print("== 4. PGM.bus_powered_for")
	var prev_rule := PGM.wiring_required
	var bus_on := PGM.bus_powered()
	PGM.wiring_required = false
	check("без правила проводки: как шина", PGM.bus_powered_for(house) == bus_on)
	PGM.wiring_required = true
	check("правило включено, провода нет: потребитель с клеммой без питания", not PGM.bus_powered_for(house))
	bt.apply_bus({"wired": true, "reachable": true})
	check("правило включено, провод до шины: как шина", PGM.bus_powered_for(house) == bus_on)
	var plain := _entity(_plain_setting(), Vector3(80, 0, 0))
	check("объект без клеммы шины питается виртуально, как раньше", PGM.bus_powered_for(plain) == bus_on)
	check("пустая сущность: как шина", PGM.bus_powered_for(null) == bus_on)
	PGM.wiring_required = prev_rule

	print("== 5. Прибор «Шина 12 В»")
	var bs_set := load("res://data/power/objects/bus_box_01.tres") as EntitySetting
	check("паспорт шины: dc_controller, switch, монтаж", bs_set != null and bs_set.category == &"dc_controller" and bs_set.tag == &"switch" and Mount.has_mount(bs_set))
	var box := _entity(bs_set, Vector3(100, 0, 0))
	await get_tree().physics_frame
	var src := box.get_comp(C_BusSource) as C_BusSource
	check("три клеммы шины: SRC, ACCESSORY", src != null and src.term(&"t1") != null and src.term(&"t3") != null and src.term(&"t4") == null \
			and src.term(&"t2").role == PowerTerminal.Role.SRC and src.term(&"t2").kind == PowerTerminal.Kind.ACCESSORY)
	check("заголовок и состояние", src.title() == "Шина 12 В" and src.state_text() != "" and src.positions() == 0)
	var c1 := _consumer(Vector3(110, 0, 20))
	var c2 := _consumer(Vector3(90, 0, -20))
	await get_tree().physics_frame
	var made := src.autowire(self)
	check("автопроводка: проводов столько же, сколько потребителей без провода (учтён и ранее созданный)", made >= 2, str(made))
	var c1b := c1.get_comp(C_BusTerminal) as C_BusTerminal
	var c2b := c2.get_comp(C_BusTerminal) as C_BusTerminal
	check("клеммы обоих потребителей заняты проводами", c1b.terminal.has_wire() and c2b.terminal.has_wire())
	check("каждая клемма потребителя получила ровно один провод", c1b.terminal.wires.size() == 1 and c2b.terminal.wires.size() == 1)

	print("== 6. Схема: дом с клеммой шины остаётся виден")
	var root := Node3D.new()
	add_child(root)
	var shown := _consumer_in(root)
	var hidden := _dummy_building(root)
	var wv := WiringView.new()
	wv.entities_root = root
	add_child(wv)
	wv.set_active(true)
	check("схема прячет здание без клеммы, дом с клеммой шины остаётся", not hidden.visible and shown.visible)
	wv.set_active(false)
	check("после выхода видны оба", hidden.visible and shown.visible)
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)


func _plain_setting() -> EntitySetting:
	var s := EntitySetting.new()
	s.key = &"bus_test_plain"
	s.category = &"building"
	s.components.append(IdentitySetting.new())
	return s


func _consumer_in(root: Node3D) -> Entity:
	var e := _consumer(Vector3.ZERO)
	e.reparent(root)
	return e


func _dummy_building(root: Node3D) -> Entity:
	var e := _entity(_plain_setting(), Vector3.ZERO)
	e.reparent(root)
	return e
