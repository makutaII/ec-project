extends Node

# XX claude-car CS4a (новый файл)
## Тест управляющих элементов дороги (ATTN_28, этап CS4a). Запуск: открыть tests/road_control_test.tscn и нажать F6, смотреть Output.
## Сценарии:
##   1) объекты стоп-секции, парковки и датчика: компонент C_RoadControl, вид из паспорта, потребитель шины
##   2) стоп-секция держит машину в середине куска, выключенная (или без питания) отпускает; клик по лампе переключает
##   3) парковка держит до команды release(), после неё машина уезжает, следующая снова встаёт
##   4) датчик: занят, пока на куске есть машина, свободен после выезда; сигнал и лампа
##   5) метка группы: стоп с группой держит, только пока занят датчик той же группы
##   6) шина: перегрузка отключает элементы (стоп не держит), сейв элемента
## Красных строк FAIL в Output быть не должно.

const ROAD_DIR := "res://data/roads/objects/"
const CAR_PATH := "res://data/cars/objects/car_red.tres"
const MAX_FRAMES := 2400

var _fails := 0


func piece(s: EntitySetting, pos: Vector3) -> Entity:
	var e: Entity = EntityFactory.new().create_from_setting(s)
	add_child(e)
	e.global_transform = Transform3D(Basis.IDENTITY, pos)
	return e


func clear() -> void:
	for c in get_children():
		c.free()
	await get_tree().physics_frame


func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func wait_until(cond: Callable) -> bool:
	for i in MAX_FRAMES:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()


func check(title: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print(("  OK    " if ok else "  FAIL  "), title)


func _car(s: EntitySetting, on: Entity, dist: float, dir := Vector3(0, 0, -1)) -> C_RoadVehicle:
	var car := piece(s, Vector3.ZERO)
	await frames(3)
	var v := car.get_comp(C_RoadVehicle) as C_RoadVehicle
	v.snap_to(on, 0, dist, dir)
	return v


func _ctl(e: Entity) -> C_RoadControl:
	return e.get_comp(C_RoadControl) as C_RoadControl


func _ready() -> void:
	var s20: EntitySetting = load(ROAD_DIR + "road_s20.tres")
	var stop_s: EntitySetting = load(ROAD_DIR + "road_stop_10.tres")
	var park_s: EntitySetting = load(ROAD_DIR + "road_parking_10.tres")
	var sens_s: EntitySetting = load(ROAD_DIR + "road_sensor_10.tres")
	var car_s: EntitySetting = load(CAR_PATH)

	print("== 1. элементы")
	var e_stop := piece(stop_s, Vector3(0, 0, -15))
	var e_park := piece(park_s, Vector3(20, 0, -15))
	var e_sens := piece(sens_s, Vector3(40, 0, -15))
	await frames(5)
	check("стоп-секция: C_RoadControl вида stop", _ctl(e_stop) != null and _ctl(e_stop).kind == &"stop")
	check("парковка: C_RoadControl вида parking", _ctl(e_park) != null and _ctl(e_park).kind == &"parking")
	check("датчик: C_RoadControl вида sensor", _ctl(e_sens) != null and _ctl(e_sens).kind == &"sensor")
	check("стоп-секция и датчик потребители шины, парковка в покое нет", PGM.bus.consumers.has(_ctl(e_stop)) and PGM.bus.consumers.has(_ctl(e_sens))
		and _ctl(e_stop).bus_watts() > 0.0 and _ctl(e_sens).bus_watts() > 0.0 and is_zero_approx(_ctl(e_park).bus_watts()))
	check("у элементов есть лампа, у стопа и парковки лампа-рычаг на слое handles", e_stop.get_node_or_null("ControlLamp") != null
		and e_stop.get_node_or_null("ControlLever") != null and (e_stop.get_node("ControlLever") as Area3D).collision_layer == Global.active_layers([&"handles"])
		and e_sens.get_node_or_null("ControlLever") == null)
	check("CSM отдаёт элемент по куску дороги", CSM.control_of(e_stop) == _ctl(e_stop))

	print("== 2. стоп-секция")
	await clear()
	var a0 := piece(s20, Vector3(0, 0, 0))
	var a1 := piece(stop_s, Vector3(0, 0, -15))
	var a2 := piece(s20, Vector3(0, 0, -30))
	await frames(5)
	var stop := _ctl(a1)
	var v1 := await _car(car_s, a0, 1.0)
	var held := await wait_until(func(): return v1.mode == C_RoadVehicle.Mode.HALTED and v1.halt_reason == &"control")
	check("включённая стоп-секция остановила машину", held)
	check("встала в середине куска (z около -15)", absf(v1.entity.global_position.z + 15.0) < 0.6 and v1.state.track == a1)
	var zs := v1.entity.global_position.z
	await frames(60)
	check("и держит её", is_equal_approx(v1.entity.global_position.z, zs) and v1.mode == C_RoadVehicle.Mode.HALTED)
	stop.set_enabled(false)
	var went := await wait_until(func(): return v1.state.has("track") and v1.state.track == a2)
	check("выключили катушку: машина отпущена и поехала дальше", went)
	await clear()
	a0 = piece(s20, Vector3(0, 0, 0))
	a1 = piece(stop_s, Vector3(0, 0, -15))
	a2 = piece(s20, Vector3(0, 0, -30))
	await frames(5)
	stop = _ctl(a1)
	# клик по лампе
	var press := {"collider": a1.get_node("ControlLever"), "consumed": false}
	stop.on_lever_pressed(press)
	check("клик по лампе забран и переключил катушку", bool(press.consumed) and not stop.enabled)
	var press2 := {"collider": a1, "consumed": false}
	stop.on_lever_pressed(press2)
	check("клик не по лампе элементом не забирается", not bool(press2.consumed) and not stop.enabled)
	stop.set_enabled(true)
	# нет питания: стоп не держит
	PGM.bus.tripped = true
	var v2 := await _car(car_s, a0, 1.0)
	var passed := await wait_until(func(): return v2.state.has("track") and v2.state.track == a2)
	check("без питания шины стоп-секция машину не держит", passed)
	PGM.bus.reset()

	print("== 3. парковка")
	await clear()
	var b0 := piece(s20, Vector3(0, 0, 0))
	var b1 := piece(park_s, Vector3(0, 0, -15))
	var b2 := piece(s20, Vector3(0, 0, -30))
	await frames(5)
	var park := _ctl(b1)
	var p1 := await _car(car_s, b0, 1.0)
	var parked := await wait_until(func(): return p1.mode == C_RoadVehicle.Mode.HALTED and p1.halt_reason == &"control")
	check("парковка остановила машину в середине куска", parked and absf(p1.entity.global_position.z + 15.0) < 0.6)
	await frames(120)
	check("и держит её, пока нет команды", p1.mode == C_RoadVehicle.Mode.HALTED and p1.state.track == b1)
	check("команда «поехали» принята", park.release())
	var left := await wait_until(func(): return p1.state.has("track") and p1.state.track == b2)
	check("после команды машина уехала с парковки", left)
	var p2 := await _car(car_s, b0, 1.0)
	var parked2 := await wait_until(func(): return p2.mode == C_RoadVehicle.Mode.HALTED and p2.halt_reason == &"control")
	check("следующая машина на парковке снова встала", parked2 and p2.state.track == b1)

	print("== 4. датчик")
	await clear()
	var changes: Array = []
	var on_change := func(c: C_RoadControl, occ: bool) -> void: changes.append([c, occ])
	CSM.sensor_changed.connect(on_change)
	var c0 := piece(s20, Vector3(0, 0, 0))
	var c1 := piece(sens_s, Vector3(0, 0, -15))
	var c2 := piece(s20, Vector3(0, 0, -30))
	await frames(5)
	var sensor := _ctl(c1)
	await frames(10)
	check("датчик без машин свободен", not sensor.occupied)
	var sv := await _car(car_s, c0, 1.0)
	var occ_seen := await wait_until(func(): return sensor.occupied)
	check("машина на куске датчика: занят", occ_seen and sv.state.track == c1)
	check("сигнал CSM.sensor_changed сообщил о занятости", changes.size() >= 1 and changes[0][0] == sensor and changes[0][1] == true)
	check("лампа красная при занятости", sensor._lamp_code == 1)
	var free_seen := await wait_until(func(): return not sensor.occupied)
	check("машина выехала: датчик снова свободен", free_seen and sv.state.track != c1)
	check("лампа зелёная, когда свободен, и пришёл второй сигнал", sensor._lamp_code == 2 and changes.size() >= 2 and changes[1][1] == false)
	CSM.sensor_changed.disconnect(on_change)

	print("== 5. группа")
	await clear()
	var g_sens := piece(sens_s, Vector3(0, 0, -15))
	var g_stop := piece(stop_s, Vector3(40, 0, -15))
	var g_pre := piece(s20, Vector3(0, 0, 0))
	var g_tail := piece(s20, Vector3(0, 0, -30))
	await frames(5)
	_ctl(g_sens).set_group(&"g1")
	_ctl(g_stop).set_group(&"g1")
	var gcar := await _car(car_s, g_stop, 2.0)   # любая машина для вопроса holds_for
	gcar.mode = C_RoadVehicle.Mode.OFF_ROAD
	await frames(10)
	check("датчик свободен: стоп-секция с группой не держит", not _ctl(g_stop).holds_for(gcar) and not CSM.group_occupied(&"g1"))
	var gdrive := await _car(car_s, g_pre, 1.0)
	var g_occ := await wait_until(func(): return _ctl(g_sens).occupied)
	check("машина на датчике: группа занята, стоп-секция группы держит", g_occ and CSM.group_occupied(&"g1") and _ctl(g_stop).holds_for(gcar))
	_ctl(g_stop).set_group(&"other")
	check("другая метка группы со стопом не связана", not _ctl(g_stop).holds_for(gcar))

	print("== 6. шина и сейв")
	await clear()
	var d0 := piece(s20, Vector3(0, 0, 0))
	var d1 := piece(stop_s, Vector3(0, 0, -15))
	await frames(5)
	var dctl := _ctl(d1)
	var dcar := await _car(car_s, d0, 1.0)
	check("стоп с питанием держит машину (holds_for)", dctl.holds_for(dcar))
	var old_imax := PGM.bus.i_max
	PGM.bus.i_max = 0.05
	var r := PGM.bus.step(0.1, PGM.mains, PGM.rules.supply_required, true, true)
	check("перегрузка шины отключила её (trip)", r == "trip" and PGM.bus.tripped)
	check("после отключения шины стоп-секция не держит", not dctl.holds_for(dcar))
	PGM.bus.reset()
	PGM.bus.i_max = old_imax
	check("после сброса шины держит снова", dctl.holds_for(dcar))
	dctl.set_enabled(false)
	dctl.set_group(&"gx")
	var saved := dctl.save_data()
	check("save_data: enabled и группа", saved.get("enabled", true) == false and saved.get("group", "") == "gx" and saved.has("comp_path"))
	var other := piece(stop_s, Vector3(40, 0, -15))
	await frames(5)
	_ctl(other).load_data(saved)
	check("load_data восстановил катушку и группу", not _ctl(other).enabled and _ctl(other).group == &"gx")
	gdrive = null

	await clear()
	print("== Итого: %s" % ("всё прошло" if _fails == 0 else "провалено проверок: %d" % _fails))
