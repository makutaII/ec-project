extends Node

# XX claude-car CS2 (новый файл)
## Бенч машин (ATTN_28, этап CS2). Запуск: tests/road_vehicle_bench.tscn, F6. Порог «норма или нет» решает автор.
## Длинная прямая из кусков road_s20, на ней N машин с зазором 3 ю едут (разгон, потом max_speed), стыки и проверка аварий CSM работают. Меряется кадр и время физики
## за 300 кадров после прогрева 60; отдельно время самого шага машин (скрипт C_RoadVehicle). Результат: строка на каждое N в Output.
## Если физика большая, а «шаг машин» маленький, дорого что-то вне скрипта машин (физический сервер, рендер, остальные компоненты). Для честного кадра запускать с окном игры (F5 даст то же
## число машин сценой выбора, здесь только дорога и машины без стола и комнаты).

const ROAD := "res://data/roads/objects/road_s20.tres"
const CAR := "res://data/cars/objects/car_red.tres"
const COUNTS := [50, 100]
const PIECES := 30
const GAP := 3.0
const WARM_FRAMES := 60
const MEASURE_FRAMES := 300


func _ready() -> void:
	var road_s: EntitySetting = load(ROAD)
	var car_s: EntitySetting = load(CAR)
	print("== Бенч машин: %d кусков дороги по 20 ю, зазор %.1f ю" % [PIECES, GAP])
	for n in COUNTS:
		var roads: Array[Entity] = []
		for i in PIECES:
			var e: Entity = EntityFactory.new().create_from_setting(road_s)
			add_child(e)
			e.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, -20.0 * i))
			roads.append(e)
		for i in 5:
			await get_tree().physics_frame
		var per_piece := int(20.0 / GAP)
		var placed := 0
		for i in n:
			var k = i / per_piece
			if k >= PIECES:
				break
			var car: Entity = EntityFactory.new().create_from_setting(car_s)
			add_child(car)
			var v := car.get_comp(C_RoadVehicle) as C_RoadVehicle
			if v.snap_to(roads[k], 0, 1.0 + float(i % per_piece) * GAP, Vector3(0, 0, -1)):
				placed += 1
		for i in WARM_FRAMES:
			await get_tree().physics_frame
		var fps := 0.0
		var phys := 0.0
		var proc := 0.0
		var script_us := 0
		CSM.take_step_usec()
		for i in MEASURE_FRAMES:
			await get_tree().physics_frame
			fps += Performance.get_monitor(Performance.TIME_FPS)
			phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			script_us += CSM.take_step_usec()
		var m := float(MEASURE_FRAMES)
		print("  машин %d (посажено %d): кадр %.1f fps, процесс %.2f мс, физика %.2f мс, из неё шаг машин (скрипт) %.2f мс" % [n, placed, fps / m, proc / m, phys / m, float(script_us) / 1000.0 / m])
		for c in get_children():
			c.free()
		await get_tree().physics_frame
	print("== Бенч закончен")
