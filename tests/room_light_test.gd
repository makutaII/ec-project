extends Node

## ATTN_25 RM6: свет комнаты в Observe → Light и сохранение состояния управлений.
## Запуск: открыть tests/room_light_test.tscn и нажать F6. Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: карточки света из реестра (только scope = observe), id карточек, Light с источником карточек и без,
## переключатель set_on/is_on (TOGGLE, SLIDER, MECH), RoomBuilder: управления активной комнаты, лампы работают после выноса
## из комнаты, get_control_state и set_control_state (сброс, значения, неизвестный id), смена комнаты, сейв SavedGame.
## Окно Observe и игра не нужны. Предупреждения в Output от отказов ожидаемы.

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _ctl(parent: Node, id: StringName, kind: RoomControl.Kind, scope: RoomControl.Scope, title := "", default_value := 1.0,
		mech: MechanismConfig = null) -> void:
	var c := RoomControl.new()
	c.id = id
	c.kind = kind
	c.scope = scope
	c.title = title
	c.default_value = default_value
	c.mechanism = mech
	parent.add_child(c)


func _ready() -> void:
	print("== 1. Карточки света из реестра")
	var root := Node3D.new()
	add_child(root)
	var l1 := OmniLight3D.new()
	l1.light_energy = 40.0
	root.add_child(l1)
	_ctl(l1, &"lamp_1", RoomControl.Kind.TOGGLE, RoomControl.Scope.OBSERVE, "Лампа 1")
	var l2 := OmniLight3D.new()
	root.add_child(l2)
	_ctl(l2, &"lamp_2", RoomControl.Kind.TOGGLE, RoomControl.Scope.STUDIO)
	var dim := OmniLight3D.new()
	dim.light_energy = 50.0
	root.add_child(dim)
	_ctl(dim, &"dim", RoomControl.Kind.SLIDER, RoomControl.Scope.OBSERVE, "Торшер", 0.5)
	var door := Node3D.new()
	root.add_child(door)
	var mc := MechanismConfig.new()
	mc.id = &"door"
	mc.actuator = MechanismConfig.Actuator.SLIDE
	mc.travel = 10.0
	mc.duration = 1.0
	_ctl(door, &"door", RoomControl.Kind.MECH, RoomControl.Scope.OBSERVE, "Дверь", 0.0, mc)
	var reg := RoomControlRegistry.collect(root)
	var cards := CardCatalogProvider.room_cards(reg)
	check("карточки только со scope = observe (лампа, торшер, дверь)", cards.size() == 3, str(cards.size()))
	check("id карточки с префиксом room:", cards[0].id == &"room:lamp_1", str(cards[0].id))
	check("подпись берётся у управления", cards[0].title == "Лампа 1" and cards[1].title == "Торшер")
	check("состояние карточек: лампа вкл, торшер вкл, дверь выкл", cards[0].on and cards[1].on and not cards[2].on)
	check("все карточки переключатели", cards.all(func(c: Dictionary) -> bool: return c.toggle))
	check("room_control_id", CardCatalogProvider.room_control_id(&"room:lamp_1") == &"lamp_1" and CardCatalogProvider.room_control_id(&"lamp") == &"")
	check("нет реестра: нет карточек", CardCatalogProvider.room_cards(null).is_empty())

	print("== 2. Light: карточки комнаты и свои")
	var prov := CardCatalogProvider.new()
	var base := prov._cards_for(&"light").size()
	check("без источника только карточки из CARDS", base == CardCatalogProvider.CARDS[&"light"].size(), str(base))
	prov.room_cards_source = func() -> Array: return CardCatalogProvider.room_cards(reg)
	var with_room := prov._cards_for(&"light")
	check("с источником добавляются карточки комнаты", with_room.size() == base + 3, str(with_room.size()))
	check("карточки комнаты в конце после времени суток и лампы", with_room[base].id == &"room:lamp_1")
	check("карточка комнаты нажата по состоянию реестра", prov._is_on(with_room[base]) and not prov._is_on(with_room[base + 2]))
	check("другие категории не затронуты", prov._cards_for(&"camera").size() == CardCatalogProvider.CARDS[&"camera"].size())
	prov.room_cards_source = func() -> Array: return []
	check("пустой ответ: Light как без комнаты", prov._cards_for(&"light").size() == base)

	print("== 3. Переключатель set_on / is_on")
	var d_lamp := reg.by_id(&"lamp_1")
	d_lamp.set_on(false)
	check("TOGGLE выключен", not d_lamp.is_on() and not l1.visible)
	d_lamp.set_on(true)
	check("TOGGLE включён, энергия прежняя", d_lamp.is_on() and l1.visible and is_equal_approx(l1.light_energy, 40.0))
	var d_dim := reg.by_id(&"dim")
	check("SLIDER по умолчанию 0.5: энергия 25", is_equal_approx(dim.light_energy, 25.0))
	d_dim.set_on(false)
	check("SLIDER выкл", not d_dim.is_on() and not dim.visible)
	d_dim.set_on(true)
	check("SLIDER вкл возвращает начальное значение", is_equal_approx(dim.light_energy, 25.0) and d_dim.is_on())
	var d_door := reg.by_id(&"door")
	d_door.set_on(true)
	check("MECH: цель 1, ещё в пути", d_door.is_on() and d_door.is_moving())
	reg.tick(1.1)
	check("MECH: дошёл", not d_door.is_moving() and is_equal_approx(d_door.value, 1.0))
	d_door.set_on(false)
	check("MECH: выкл по цели сразу", not d_door.is_on())

	print("== 4. RoomBuilder: управления активной комнаты")
	if Global.fast_debug:
		print("  пропуск: Global.fast_debug, комнату не строим")
	else:
		var dbg := Global.debug_mode
		var rb := RoomBuilder.new()
		add_child(rb)
		await get_tree().physics_frame
		await get_tree().physics_frame
		check("kid_room_10 из сцены: управлений нет", rb.get_controls().defs.is_empty() and rb.get_control_state().is_empty())
		check("request_room(attic)", rb.request_room(&"attic", &"start") and rb.get_room_id() == &"attic")
		check("в attic два управления, одно для Observe", rb.get_controls().defs.size() == 2 and rb.get_controls().for_scope(RoomControl.Scope.OBSERVE).size() == 1)
		var st := rb.get_control_state()
		check("состояние для сейва: только lamp_1 = 1", st.size() == 1 and is_equal_approx(float(st.get(&"lamp_1", -1.0)), 1.0), str(st))
		var lights := rb.get_room_lights()
		var lamp0 := lights.get_node_or_null("Lamp0") as Light3D if lights != null else null
		check("лампа вынесена из комнаты и найдена", lamp0 != null)
		check("set_control_on гасит лампу после выноса из комнаты", rb.set_control_on(&"lamp_1", false) and lamp0 != null and not lamp0.visible)
		check("состояние: lamp_1 = 0", is_equal_approx(float(rb.get_control_state().get(&"lamp_1", -1.0)), 0.0))
		check("неизвестное управление: false", not rb.set_control_on(&"nope", true) and not rb.set_control_value(&"nope", 1.0))
		var changed := [0]
		rb.room_controls_changed.connect(func() -> void: changed[0] += 1)
		rb.set_control_state({})
		check("пустое состояние (старый сейв): начальные значения", lamp0.visible and changed[0] == 1)
		rb.set_control_state({&"lamp_1": 0.0, &"no_such": 1.0})
		check("состояние из сейва: лампа выкл, неизвестный id пропущен", not lamp0.visible and changed[0] == 2)
		rb.set_control_state({"lamp_1": 1.0})
		check("ключи String тоже принимаются", lamp0.visible)
		rb.set_control_value(&"lamp_2", 0.0)
		check("studio-управление в сейв не попадает", not rb.get_control_state().has(&"lamp_2"))
		Global.debug_mode = true
		check("смена на bench: управлений нет", rb.request_room(&"bench", &"admin") and rb.get_controls().defs.is_empty() and rb.get_control_state().is_empty())
		check("возврат в attic: лампа снова по умолчанию (новый экземпляр)", rb.request_room(&"attic", &"admin") and rb.get_control_state().get(&"lamp_1", -1.0) == 1.0)
		Global.debug_mode = dbg
		rb.queue_free()

	print("== 5. SavedGame")
	var sg := SavedGame.new()
	check("поле room_controls пусто по умолчанию (старый сейв)", sg.room_controls.is_empty())
	sg.room_controls = {&"lamp_1": 0.0, &"door": 1.0}
	var path := "user://room_light_test.tres"
	var err := ResourceSaver.save(sg, path)
	check("сейв записан", err == OK, "код %d" % err)
	var back := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as SavedGame
	check("состояние читается обратно", back != null and back.room_controls.size() == 2
			and is_equal_approx(float(back.room_controls.get(&"door", -1.0)), 1.0), str(back.room_controls if back else null))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	root.queue_free()
	await get_tree().process_frame
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
