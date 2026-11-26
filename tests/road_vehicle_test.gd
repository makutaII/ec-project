extends Node

# XX claude-car CS2 (новый файл)
## Тест машины на полосе (ATTN_28, этап CS2). Запуск: открыть tests/road_vehicle_test.tscn и нажать F6, смотреть Output.
## Сценарии:
##   1) машина из data/cars/objects: компоненты, паспорт CarConfig, слой выбора cars (не tracks), CSM знает машину
##   2) посадка на полосу и езда с постоянной скоростью, переезд стыка двух кусков дороги
##   3) конец дороги без продолжения: машина стоит у края (Р6)
##   4) дорогу достроили: машина поехала дальше сама
##   5) дорогу под машиной удалили: машина потеряла полосу и стоит
##   6) драг: над дорогой притягивается к оси и смотрит вдоль неё, Q/E меняют сторону, бросили на дороге: едет
##   7) сейв: on_road в save_data, load_data и restore_after_load садят машину обратно
##   8) PathWalker.advance с параметром слоя: рельсовая ходьба прежняя
## Красных строк FAIL в Output быть не должно. Скорости и габариты берутся из паспорта, правка CarConfig в .tres тест не ломает.

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


## Ждём, пока условие станет истинным, не дольше MAX_FRAMES физических кадров
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


func _ready() -> void:
	var road_s: EntitySetting = load(ROAD_DIR + "road_s20.tres")
	var car_s: EntitySetting = load(CAR_PATH)
	var road_layer := Global.active_layers([&"roads"])

	print("== 1. машина")
	var car := piece(car_s, Vector3(0, 30, 0))
	await frames(5)
	var veh := car.get_comp(C_RoadVehicle) as C_RoadVehicle
	var vis := car.get_comp(C_CarVisual) as C_CarVisual
	var drag := car.get_comp(C_CarDraggable) as C_CarDraggable
	var cfg := CarConfig.from_entity(car)
	check("у машины есть C_RoadVehicle, C_CarVisual, C_CarDraggable и паспорт CarConfig", veh != null and vis != null and drag != null and cfg != null)
	check("слой выбора cars, не tracks и не roads", vis != null and vis.pick_area != null
		and vis.pick_area.collision_layer == Global.active_layers([&"cars"])
		and (vis.pick_area.collision_layer & (Global.active_layers([&"tracks"]) | road_layer)) == 0)
	check("у кузова есть меши для подсветки (кузов, кабина, 4 колеса)", vis != null and vis.mesh_nodes.size() == 6)
	check("CSM знает машину", CSM.get_vehicles().has(veh))
	check("свободная машина вне дороги не едет", veh != null and veh.mode == C_RoadVehicle.Mode.OFF_ROAD)
	var speed := cfg.max_speed if cfg != null else C_RoadVehicle.DEFAULT_SPEED

	print("== 2. езда и стык")
	await clear()
	var r0 := piece(road_s, Vector3(0, 0, 0))
	var r1 := piece(road_s, Vector3(0, 0, -20))
	var r2 := piece(road_s, Vector3(0, 0, -40))
	car = piece(car_s, Vector3.ZERO)
	await frames(5)
	veh = car.get_comp(C_RoadVehicle) as C_RoadVehicle
	check("посадка на полосу: snap_to вернул true", veh.snap_to(r0, 0, 5.0, Vector3(0, 0, -1)))
	check("после посадки машина едет (DRIVING) на первом куске", veh.mode == C_RoadVehicle.Mode.DRIVING and veh.state.track == r0)
	var z0 := car.global_position.z
	await frames(30)
	check("машина движется вперёд по -Z", car.global_position.z < z0 - 0.5)
	var head_h := ((r0.get_comp(C_Path)) as C_Path).head_height()
	check("колёса на поверхности дороги (y равен высоте головки)", absf(car.global_position.y - head_h) < 0.05)
	check("смотрит вдоль дороги (-Z)", (-car.global_basis.z).dot(Vector3(0, 0, -1)) > 0.99)
	var crossed := await wait_until(func(): return veh.state.has("track") and veh.state.track == r1)
	check("проехала стык: машина перешла на второй кусок", crossed)
	var crossed2 := await wait_until(func(): return veh.state.has("track") and veh.state.track == r2)
	check("проехала второй стык: перешла на третий кусок", crossed2)

	print("== 3. конец дороги")
	var halted := await wait_until(func(): return veh.mode == C_RoadVehicle.Mode.HALTED)
	check("на конце дороги машина стоит (HALTED)", halted)
	check("стоит у самого края дороги (z около -50)", absf(car.global_position.z + 50.0) < 0.6)
	var zs := car.global_position.z
	await frames(30)
	check("стоящая машина не двигается", is_equal_approx(car.global_position.z, zs))

	print("== 4. дорогу достроили")
	var r3 := piece(road_s, Vector3(0, 0, -60))
	var resumed := await wait_until(func(): return veh.state.has("track") and veh.state.track == r3)
	check("машина поехала дальше на новый кусок сама", resumed)
	check("на новом куске она едет (DRIVING)", veh.mode == C_RoadVehicle.Mode.DRIVING)

	print("== 5. дорогу удалили")
	r3.free()
	var lost := await wait_until(func(): return veh.mode == C_RoadVehicle.Mode.OFF_ROAD)
	check("дорогу под машиной удалили: машина потеряла полосу", lost)
	var zl := car.global_position.z
	await frames(20)
	check("и стоит", is_equal_approx(car.global_position.z, zl))

	print("== 6. драг")
	await clear()
	var d0 := piece(road_s, Vector3.ZERO)
	var d1 := piece(road_s, Vector3(0, 0, -20))
	car = piece(car_s, Vector3(30, 0, -5))
	await frames(5)
	veh = car.get_comp(C_RoadVehicle) as C_RoadVehicle
	drag = car.get_comp(C_CarDraggable) as C_CarDraggable
	var hp := (d1.get_comp(C_Path) as C_Path)
	drag.on_drag_started({"build": true})
	drag.on_drag_moved({"position": Vector3(0, 0, -22), "collider": null})
	check("над столом машина не на дороге", not drag.is_snapped_to_road and veh.mode == C_RoadVehicle.Mode.OFF_ROAD)
	drag.on_drag_moved({"position": Vector3(1.0, 0, -25), "collider": hp.head_node})
	check("над дорогой машина притянулась к полосе", drag.is_snapped_to_road and drag.current_track == d1)
	check("ось машины на оси дороги (x около 0, z около -25)", absf(car.global_position.x) < 0.05 and absf(car.global_position.z + 25.0) < 0.6)
	var fwd := -car.global_basis.z
	drag.on_rotate_input({"axis": "y", "amount": 90.0})
	drag.on_drag_moved({"position": Vector3(1.0, 0, -25), "collider": hp.head_node})
	check("Q/E на дороге меняют сторону движения", (-car.global_basis.z).dot(fwd) < -0.99)
	drag.on_drag_ended({})
	check("бросили на дороге: машина едет", veh.mode == C_RoadVehicle.Mode.DRIVING)
	var zd := car.global_position.z
	await frames(30)
	check("и едет в выбранную сторону (против прежней)", (car.global_position.z - zd) * fwd.z < 0.0)
	drag.on_drag_started({})
	check("взяли в драг: машина не едет", veh.mode == C_RoadVehicle.Mode.OFF_ROAD)
	drag.on_drag_moved({"position": Vector3(20, 0, 20), "collider": null})
	drag.on_drag_ended({})
	check("бросили мимо дороги: стоит на месте", veh.mode == C_RoadVehicle.Mode.OFF_ROAD)

	print("== 7. сейв")
	await clear()
	var s0 := piece(road_s, Vector3.ZERO)
	car = piece(car_s, Vector3.ZERO)
	await frames(5)
	veh = car.get_comp(C_RoadVehicle) as C_RoadVehicle
	veh.snap_to(s0, 0, 8.0, Vector3(0, 0, -1))
	await frames(10)
	var saved := veh.save_data()
	check("save_data: on_road истина, есть comp_path и comp_name", bool(saved.get("on_road", false)) and saved.has("comp_path") and saved.has("comp_name"))
	var pos_saved := car.global_position
	var car2 := piece(car_s, pos_saved)
	car2.global_basis = car.global_basis
	await frames(5)
	var veh2 := car2.get_comp(C_RoadVehicle) as C_RoadVehicle
	veh2.load_data(saved)
	check("до restore_after_load загруженная машина не на полосе", veh2.mode == C_RoadVehicle.Mode.OFF_ROAD)
	var ok := veh2.restore_after_load()
	if not ok:
		await frames(5)
		ok = veh2.restore_after_load()
	check("restore_after_load нашла дорогу под машиной и посадила её", ok and veh2.mode == C_RoadVehicle.Mode.DRIVING and veh2.state.track == s0)
	var veh3 := piece(car_s, Vector3(40, 0, 0)).get_comp(C_RoadVehicle) as C_RoadVehicle
	veh3.load_data({"on_road": false})
	check("машина, не стоявшая на дороге, садиться не должна", veh3.restore_after_load() and veh3.mode == C_RoadVehicle.Mode.OFF_ROAD)

	print("== 8. PathWalker и слои")
	await clear()
	var rail_s: EntitySetting = load("res://data/tracks/objects/g119.tres")
	var t0 := piece(rail_s, Vector3.ZERO)
	var t1 := piece(rail_s, Vector3(0, 0, -11.9))
	var q0 := piece(road_s, Vector3(40, 0, 0))
	var q1 := piece(road_s, Vector3(40, 0, -20))
	await frames(5)
	var rs := RailWalker.from_snap(t0, 0, 5.0, Vector3(0, 0, -1))
	var rn := RailWalker.advance(rs, 4.0)
	check("RailWalker по-прежнему ходит по рельсам (в пределах трака)", not rn.is_empty() and rn.track == t0)
	var rj := RailWalker.advance(rs, 9.0)
	check("RailWalker переходит на следующий рельсовый трак через стык", not rj.is_empty() and rj.track == t1)
	var cs := PathWalker.from_snap(q0, 0, 15.0, Vector3(0, 0, -1))
	var cj := PathWalker.advance(cs, 9.0, &"roads")
	check("PathWalker со слоем roads переходит на следующий кусок дороги", not cj.is_empty() and cj.track == q1)
	var cj_rail := PathWalker.advance(cs, 9.0)   # слой по умолчанию tracks: дорогу не видит
	check("слой по умолчанию tracks не видит дорогу (вагоны дорогу не замечают)", cj_rail.is_empty())

	await clear()
	print("== Итого: %s" % ("всё прошло" if _fails == 0 else "провалено проверок: %d" % _fails))
