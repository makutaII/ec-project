extends Node

## ATTN_25 RM8: комната из .glb (RoomGlb, RoomRoot.import_glb, управление из свойств .glb, карточка по числам сцены).
## Запуск: открыть tests/room_glb_test.tscn и нажать F6. Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Берёт эталон data/models/room_test_01 (обёртка room_test_01.tscn + room_test_01.glb, собран tools/room_fixture.py) и проверяет,
## что роли и свойства Blender стали объектами Godot: коллайдеры, лампы, числа карточки, управление, лампочка, группы и слои.
## ПЕРВАЯ проверка: Godot-импортёр положил свойства Blender в метаданные узла "extras". Если она падает, дальше смотреть нечего:
## нужен другой путь чтения (см. ATTN_25 §25.8, предупреждение в RM8).
## Дополнительно, если рядом лежит data/models/room_test_glb/room_test_glb.glb (реальный экспорт), он только разбирается и печатается.

const ROOM_ID := &"room_test_01"

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func near(a: Vector3, b: Vector3, eps := 0.6) -> bool:
	return (a - b).length() <= eps


func _ready() -> void:
	print("== RM8: комната из .glb")
	var cfg := RoomCatalog.make(ROOM_ID)
	check("карточка room_test_01 со сценой", cfg != null and cfg.scene != null and cfg.id == ROOM_ID)
	if cfg == null or cfg.scene == null:
		_finish()
		return
	var room := cfg.scene.instantiate() as RoomRoot
	check("корень сцены RoomRoot", room != null)
	if room == null:
		_finish()
		return
	add_child(room)

	print("== 1. Свойства Blender дошли до Godot")
	var curtain := room.find_child("curtain", true, false)
	check("узел curtain есть в сцене", curtain != null)
	var ex := RoomGlb.extras(curtain)
	check("extras в метаданных узла (Godot положил Custom Properties в meta)", ex.has("ctl") and ex.has("role"),
			"НЕТ extras: импортёр Godot не отдаёт свойства узла, смотри RoomGlb.extras()" if ex.is_empty() else str(ex))
	if ex.is_empty():
		_finish()
		return
	check("числа приходят числами", ex.get("ctl_default") is float or ex.get("ctl_default") is int, str(typeof(ex.get("ctl_default"))))

	print("== 2. Разбор: прокси и якоря заменены")
	room.import_glb()
	check("glb.present", room.glb != null and room.glb.present)
	for nm in ["window_n", "door_s", "camera_bounds", "room_volume", "table_origin", "window_sun"]:
		check("служебного узла %s больше нет" % nm, room.find_child(nm, true, false) == null)
	check("предупреждений разбора нет", room.glb.warnings.is_empty(), str(room.glb.warnings))
	check("table_origin = (0, 0, 0)", near(room.glb.table_origin, Vector3.ZERO), str(room.glb.table_origin))
	check("window_sun = (0.35, -0.55, 0.75)", near(room.glb.sun_dir, Vector3(0.35, -0.55, 0.75).normalized(), 0.01), str(room.glb.sun_dir))

	print("== 3. Коллайдеры")
	var layer := Global.active_layers(["room"])
	for nm in ["collider_floor", "collider_bed", "collider_wardrobe"]:
		var b := room.find_child(nm, true, false) as StaticBody3D
		check("%s: StaticBody3D" % nm, b != null)
		if b == null:
			continue
		check("%s: слой room, маска 0" % nm, b.collision_layer == layer and b.collision_mask == 0, "%d" % b.collision_layer)
		var cs := b.get_child(0) as CollisionShape3D
		check("%s: BoxShape3D" % nm, cs != null and cs.shape is BoxShape3D)
	var bed := room.find_child("collider_bed", true, false) as StaticBody3D
	if bed != null and bed.get_child_count() > 0:
		var bs := (bed.get_child(0) as CollisionShape3D).shape as BoxShape3D
		check("collider_bed: размер 200 x 50 x 120 см", near(bs.size, Vector3(200, 50, 120)), str(bs.size))
		check("collider_bed: центр коробки (-130, -25, 120)", near(bed.position + (bed.get_child(0) as CollisionShape3D).position, Vector3(-130, -25, 120)),
				str(bed.position + (bed.get_child(0) as CollisionShape3D).position))

	print("== 4. Числа карточки из сцены")
	var c: Dictionary = room.glb.card
	check("floor_y = -50", is_equal_approx(float(c.get("floor_y", 0.0)), -50.0), str(c.get("floor_y")))
	check("size = (480, 250, 380)", c.has("size") and near(c["size"], Vector3(480, 250, 380)), str(c.get("size")))
	check("bounds = (-230, 3, -180) + (460, 190, 360)", c.has("bounds") and near((c["bounds"] as AABB).position, Vector3(-230, 3, -180))
			and near((c["bounds"] as AABB).size, Vector3(460, 190, 360)), str(c.get("bounds")))
	var w: Dictionary = c.get("window", {})
	check("window = x 0, w 170, sill 80, h 140", absf(float(w.get("x", 99)) - 0.0) < 0.6 and absf(float(w.get("w", 0)) - 170.0) < 0.6
			and absf(float(w.get("sill", 0)) - 80.0) < 0.6 and absf(float(w.get("h", 0)) - 140.0) < 0.6, str(w))
	var d: Dictionary = c.get("door", {})
	check("door = x 100, w 80, sill 0, h 200", absf(float(d.get("x", 0)) - 100.0) < 0.6 and absf(float(d.get("w", 0)) - 80.0) < 0.6
			and absf(float(d.get("sill", 9)) - 0.0) < 0.6 and absf(float(d.get("h", 0)) - 200.0) < 0.6, str(d))
	check("daylight = true", c.get("daylight", false) == true)
	check("карточка room_test_01.tres сходится со сценой", room.glb.diff(cfg).is_empty(), str(room.glb.diff(cfg)))
	var other := cfg.duplicate() as RoomConfig
	other.floor_y = -40.0
	other.window = {}
	check("diff ловит расхождения (floor_y и окно)", room.glb.diff(other).size() == 2, str(room.glb.diff(other)))
	room.glb.apply_to(other)
	check("apply_to исправляет карточку", room.glb.diff(other).is_empty(), str(room.glb.diff(other)))

	print("== 5. Лампы")
	check("ламп создано 2", room.glb.lights.size() == 2, str(room.glb.lights.size()))
	var la := room.find_child("lamp_ceiling_a", true, false) as SpotLight3D
	check("lamp_ceiling_a: SpotLight3D", la != null)
	if la != null:
		check("lamp_ceiling_a: энергия 150, дальность 400, угол 70", is_equal_approx(la.light_energy, 150.0) and is_equal_approx(la.spot_range, 400.0)
				and is_equal_approx(la.spot_angle, 70.0))
		check("lamp_ceiling_a: цвет #fff2dd, тень, bias", la.light_color.is_equal_approx(Color.html("#fff2dd")) and la.shadow_enabled
				and is_equal_approx(la.shadow_bias, RoomGlb.LAMP_BIAS))
		check("lamp_ceiling_a: светит вниз", near(-la.transform.basis.z, Vector3.DOWN, 0.01), str(-la.transform.basis.z))
		check("lamp_ceiling_a: позиция (-100, 195, 0)", near(la.position, Vector3(-100, 195, 0)), str(la.position))
	var lb := room.find_child("lamp_ceiling_b", true, false) as OmniLight3D
	check("lamp_ceiling_b: OmniLight3D, 100, 300, без тени", lb != null and is_equal_approx(lb.light_energy, 100.0)
			and is_equal_approx(lb.omni_range, 300.0) and not lb.shadow_enabled)

	print("== 6. Управление (реестр)")
	var reg := RoomControlRegistry.collect(room, "room_test_01")
	check("управлений 3", reg.defs.size() == 3, str(reg.defs.size()))
	check("замечаний реестра нет", reg.warnings.is_empty(), str(reg.warnings))
	check("Observe: 2 (curtain, lamp_a)", reg.for_scope(RoomControl.Scope.OBSERVE).size() == 2)
	var dc := reg.by_id(&"curtain")
	var dl := reg.by_id(&"lamp_a")
	var dl2 := reg.by_id(&"lamp_b")
	check("curtain: MECH, подпись 'Штора'", dc != null and dc.kind == RoomControl.Kind.MECH and dc.title == "Штора")
	check("lamp_a: TOGGLE, Observe, по умолчанию включена", dl != null and dl.kind == RoomControl.Kind.TOGGLE and dl.scope == RoomControl.Scope.OBSERVE
			and dl.value > 0.5)
	check("lamp_b: TOGGLE, Studio", dl2 != null and dl2.scope == RoomControl.Scope.STUDIO)
	if dc != null and curtain != null:
		check("curtain: механизм привязан к анимации mech_curtain", dc.mechanisms.size() == 1)
		var x0 := (curtain as Node3D).position.x
		dc.set_value(1.0, true)
		check("curtain: открыта, сдвиг +160 см по X", absf((curtain as Node3D).position.x - x0 - 160.0) < 1.0, "%.1f -> %.1f" % [x0, (curtain as Node3D).position.x])
		dc.set_value(0.0, true)
		check("curtain: закрыта, вернулась", absf((curtain as Node3D).position.x - x0) < 1.0)
	if dl != null and la != null:
		dl.set_value(0.0)
		check("lamp_a выключена: лампа скрыта", not la.visible)
		dl.set_value(1.0)
		check("lamp_a включена: лампа видна, энергия 150", la.visible and is_equal_approx(la.light_energy, 150.0))
	var bulb := room.find_child("bulb_lamp_a", true, false) as MeshInstance3D
	check("bulb_lamp_a есть, лампочек 1", bulb != null and room.glb.bulbs.size() == 1)
	if bulb != null and dl != null:
		var m := bulb.get_surface_override_material(0) as StandardMaterial3D
		check("лампочка: свой материал", m != null)
		if m != null:
			dl.set_value(0.0)
			check("лампа выключена: лампочка не светится", not m.emission_enabled)
			dl.set_value(1.0)
			check("лампа включена: лампочка светится", m.emission_enabled)

	print("== 7. Группы, слои, потолок")
	room.setup(1 << (Global.ROOM_VISUAL_LAYER - 1), 1 << (Global.ROOM_SHELL_LAYER - 1))
	var shell_bit := 1 << (Global.ROOM_SHELL_LAYER - 1)
	var vis_bit := 1 << (Global.ROOM_VISUAL_LAYER - 1)
	var wall := room.find_child("wall_n_left", true, false) as MeshInstance3D
	var ceil := room.get_ceiling_mesh()
	var flr := room.find_child("floor_slab", true, false) as MeshInstance3D
	var bedm := room.find_child("bed", true, false) as MeshInstance3D
	check("стена в оболочке (shell layer)", wall != null and wall.layers == shell_bit)
	check("потолок найден (ceiling_slab) и в оболочке", ceil != null and ceil.name == &"ceiling_slab" and ceil.layers == shell_bit)
	check("пол и кровать на visual layer комнаты", flr != null and flr.layers == vis_bit and bedm != null and bedm.layers == vis_bit)
	check("get_wall_meshes: стены есть, потолка нет", room.get_wall_meshes().has(wall) and not room.get_wall_meshes().has(ceil))
	var t2 := room.group_nodes(&"decor_t2")
	var t3 := room.group_nodes(&"decor_t3")
	check("decor_t2 и decor_t3 найдены по ролям", t2.size() == 1 and t3.size() == 1)
	room.set_detail(0)
	check("detail 0: T2 и T3 скрыты", not (t2[0] as Node3D).visible and not (t3[0] as Node3D).visible)
	room.set_detail(1)
	check("detail 1: T2 виден, T3 скрыт", (t2[0] as Node3D).visible and not (t3[0] as Node3D).visible)
	room.set_detail(2)
	check("detail 2: все видны", (t2[0] as Node3D).visible and (t3[0] as Node3D).visible)
	var lights_before := room.get_node_or_null("Lights")
	check("лампы лежат в узле Lights корня (take_lights их унесёт)", lights_before != null and lights_before.get_child_count() == 2)

	print("== 8. Повторный разбор ничего не ломает")
	room.import_glb()
	check("лампы не задвоились", room.get_node("Lights").get_child_count() == 2 and room.glb.lights.size() == 2)

	print("== 9. Комнаты без ролей работают как раньше (attic)")
	var acfg := RoomCatalog.make(&"attic")
	var attic := acfg.scene.instantiate() as RoomRoot
	check("attic: RoomRoot", attic != null)
	if attic != null:
		attic.import_glb()
		check("attic: ролей .glb нет, замечаний нет", not attic.glb.present and attic.glb.warnings.is_empty())
		check("attic: группы по именам (Shell, Ceiling)", not attic.group_nodes(&"shell").is_empty() and attic.get_ceiling() != null)
		attic.free()

	_real_file()
	room.queue_free()
	_finish()


## Необязательно: реальный экспорт пользователя только разбирается, ошибки не считаются
func _real_file() -> void:
	var path := "res://data/models/room_test_glb/room_test_glb.glb"
	if not ResourceLoader.exists(path):
		return
	print("== 10. Реальный экспорт room_test_glb.glb (только разбор)")
	var ps := load(path) as PackedScene
	if ps == null:
		print("  не загрузился как PackedScene")
		return
	var root := RoomRoot.new()
	root.name = "RoomTestGlb"
	root.add_child(ps.instantiate())
	add_child(root)
	root.import_glb()
	print("  роли найдены: ", root.glb.present, "; ламп ", root.glb.lights.size(), "; группы ", root.glb.groups.keys())
	print("  карточка: ", root.glb.card)
	for wmsg in root.glb.warnings:
		print("  замечание: ", wmsg)
	var reg := RoomControlRegistry.collect(root, "room_test_glb")
	print("  управлений: ", reg.defs.size(), "; замечаний реестра: ", reg.warnings.size())
	root.queue_free()


func _finish() -> void:
	print("")
	print("ИТОГ: OK" if _bad == 0 else "ИТОГ: ОШИБОК %d" % _bad)
