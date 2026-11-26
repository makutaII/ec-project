extends Node

# XX claude-table T4 (новый файл)
## ATTN_23 T4+T5: рама на полу и кронштейны к стене. Запуск: открыть tests/table_support_test.tscn и F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: правила комнаты TableRules (проход, стена, окно, дверь, скос мансарды, стенд без стен), связность и глубину;
## план опор TableSupports.parts (ножки, рама, кронштейны); LYM.set_support и высоту рамы; RoomBuilder строит опоры по виду.

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _section(pos: Vector2, size: Vector2) -> Entity:
	var f := EntityFactory.new()
	var e := f.create_from_setting(load("res://data/table/objects/sec_100x100.tres") as EntitySetting)
	f.free()
	(e.get_comp(C_Contour) as C_Contour).set_rect(size)
	e.position = Vector3(pos.x, 0.0, pos.y)
	add_child(e)
	return e


func _poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


func _count(parts: Array[Dictionary], nm: String) -> int:
	var n := 0
	for p in parts:
		if String(p["name"]) == nm:
			n += 1
	return n


func _ready() -> void:
	var cfg := RoomConfig.new()   # 480 x 380, окно на севере (x 0, w 170), дверь на юге (x 100, w 80)
	var legs := LayoutConfig.Support.LEGS
	var wall := LayoutConfig.Support.WALL
	var plinth := LayoutConfig.Support.PLINTH
	print("== 1. Правила комнаты")
	check("ножки: у стены нельзя (проход)", TableRules.placement_reason(Rect2(-240, -50, 100, 100), cfg, legs, 60.0) != "")
	check("ножки: с проходом можно", TableRules.placement_reason(Rect2(-100, -50, 200, 100), cfg, legs, 60.0) == "")
	check("за стену нельзя в любом режиме", TableRules.placement_reason(Rect2(-250, -50, 100, 100), cfg, wall, 60.0) != "")
	check("кронштейны: вплотную к западной стене можно", TableRules.placement_reason(Rect2(-240, -50, 100, 100), cfg, wall, 60.0) == "")
	check("кронштейны: зазор 30 до стены нельзя", TableRules.placement_reason(Rect2(-210, -50, 100, 100), cfg, wall, 60.0) != "")
	check("кронштейны: напротив окна красный", TableRules.placement_reason(Rect2(-100, -190, 200, 100), cfg, wall, 60.0) == "Секция закрывает окно")
	check("кронштейны: рядом с окном можно", TableRules.placement_reason(Rect2(100, -190, 100, 100), cfg, wall, 60.0) == "")
	check("кронштейны: напротив двери красный", TableRules.placement_reason(Rect2(60, 90, 80, 100), cfg, wall, 60.0) == "Секция закрывает дверь")
	check("контакты секции у угла: две стены", TableRules.wall_contacts(Rect2(-240, -190, 100, 100), cfg).size() == 2)
	var attic := RoomConfig.new()
	attic.shape = &"attic"
	check("мансарда: на восточную стену не крепим", TableRules.wall_contacts(Rect2(140, -50, 100, 100), attic).is_empty())
	check("мансарда: у скоса красный", TableRules.placement_reason(Rect2(140, -50, 100, 100), attic, wall, 60.0) != "")
	var none := RoomConfig.new()
	none.shape = &"none"
	check("стенд без стен: ограничений нет", TableRules.placement_reason(Rect2(-1000, -50, 100, 100), none, wall, 60.0) == "")
	var stand: Array[Rect2] = [Rect2(-100, -50, 200, 100)]
	check("стенд без стен: кронштейны нельзя", TableRules.wall_layout_reason(stand, none) != "")

	print("== 2. Связность и глубина")
	var v1: Array[Rect2] = [Rect2(-100, -50, 200, 100)]
	check("стол v1 посреди комнаты: к стене не крепится", TableRules.wall_layout_reason(v1, cfg) == "Часть стола не касается стены")
	var joined: Array[Rect2] = [Rect2(-100, -50, 200, 100), Rect2(-240, -50, 140, 100)]
	check("две секции стыком, одна у стены: крепится", TableRules.wall_layout_reason(joined, cfg) == "")
	check("одна группа", TableRules.components(joined).size() == 1)
	var apart: Array[Rect2] = [Rect2(-240, -50, 100, 100), Rect2(0, -50, 100, 100)]
	check("две отдельные: две группы", TableRules.components(apart).size() == 2)
	check("отдельная секция без стены: отказ", TableRules.wall_layout_reason(apart, cfg) != "")
	var shallow: Array[Rect2] = [Rect2(-240, -50, 60, 100)]
	var deep: Array[Rect2] = [Rect2(-240, -50, 100, 100)]
	check("глубина 60: без предупреждения", TableRules.wall_depth_warning(shallow, cfg) == "")
	check("глубина 100: предупреждение", TableRules.wall_depth_warning(deep, cfg).contains("100"), TableRules.wall_depth_warning(deep, cfg))

	print("== 3. План опор")
	var th := 5.0
	var fp_v1: Array[PackedVector2Array] = [_poly(Rect2(-100, -50, 200, 100))]
	var p_legs := TableSupports.parts(legs, fp_v1, 50.0, th, 6.0, cfg)
	check("ножки: 4 штуки как раньше", _count(p_legs, "Leg") == 4 and p_legs.size() == 4)
	var p_plinth := TableSupports.parts(plinth, fp_v1, 10.0, th, 6.0, cfg)
	check("рама: 4 бруса вдоль рёбер", _count(p_plinth, "Rail") == 4 and p_plinth.size() == 4, str(p_plinth.size()))
	var rail_ok := true
	for p in p_plinth:
		rail_ok = rail_ok and is_equal_approx((p["size"] as Vector3).y, 5.0) and is_equal_approx((p["center"] as Vector3).y, -7.5)
	check("рама: от пола (-10) до низа плиты (-5)", rail_ok)
	check("рама высотой 5 u: бруса нет (плита на полу)", TableSupports.parts(plinth, fp_v1, 5.0, th, 6.0, cfg).is_empty())
	# XX claude-wire W2: подрамник под плитой
	var p_apron := TableSupports.parts(legs, fp_v1, 50.0, th, 6.0, cfg, true)
	check("подрамник: 4 ножки и 4 царги", _count(p_apron, "Leg") == 4 and _count(p_apron, "Apron") == 4 and p_apron.size() == 8, str(p_apron.size()))
	var apron_ok := true
	var long_n := 0
	var short_n := 0
	for p in p_apron:
		if String(p["name"]) != "Apron":
			continue
		var sz := p["size"] as Vector3
		var ctr := p["center"] as Vector3
		apron_ok = apron_ok and is_equal_approx(sz.y, TableSupports.APRON_H) and is_equal_approx(ctr.y + sz.y * 0.5, -th)
		if is_equal_approx(sz.x, 194.0):
			long_n += 1
			apron_ok = apron_ok and is_equal_approx(absf(ctr.z), 50.0 - TableSupports.EDGE_INSET - TableSupports.APRON_W * 0.5)
		elif is_equal_approx(sz.x, 94.0):
			short_n += 1
			apron_ok = apron_ok and is_equal_approx(absf(ctr.x), 100.0 - TableSupports.EDGE_INSET - TableSupports.APRON_W * 0.5)
	check("царги: верх на низе плиты, вдоль рёбер с отступом как у ножек", apron_ok and long_n == 2 and short_n == 2, "%d / %d" % [long_n, short_n])
	check("без флага подрамника его нет", _count(TableSupports.parts(legs, fp_v1, 50.0, th, 6.0, cfg), "Apron") == 0)
	check("рама с флагом подрамника: только брусья рамы", TableSupports.parts(plinth, fp_v1, 10.0, th, 6.0, cfg, true).size() == 4)
	check("высота 5 u: ни ножек, ни царг", TableSupports.parts(legs, fp_v1, 5.0, th, 6.0, cfg, true).is_empty())
	var low := TableSupports.parts(legs, fp_v1, 8.0, th, 6.0, cfg, true)
	var low_h := 0.0
	for p in low:
		if String(p["name"]) == "Apron":
			low_h = (p["size"] as Vector3).y
	check("низкий стол: царга не выше ножки", is_equal_approx(low_h, 3.0), str(low_h))
	var cs1 := LayoutConfig.new()
	cs1.apron = true
	var cs2 := LayoutConfig.new()
	cs2.set_state(cs1.get_state())
	check("LayoutConfig: подрамник пишется и читается", cs2.apron)
	cs2.set_state({"version": 1, "height": 60.0})
	check("старый сейв без ключа: подрамника нет", not cs2.apron)
	# XX claude-wire W4: нижняя полка (вторая столешница по размеру подрамника)
	var shelf := TableSupports.shelf_polygons(fp_v1)
	var smin := Vector2(INF, INF)
	var smax := Vector2(-INF, -INF)
	for sp in shelf:
		for pt in sp:
			smin = Vector2(minf(smin.x, pt.x), minf(smin.y, pt.y))
			smax = Vector2(maxf(smax.x, pt.x), maxf(smax.y, pt.y))
	check("полка: один контур, 194 x 94 (стол сжат на отступ ножек)", shelf.size() == 1 and smin.distance_to(Vector2(-97, -47)) < 0.01 and smax.distance_to(Vector2(97, 47)) < 0.01, "%s %s" % [smin, smax])
	var fp_l: Array[PackedVector2Array] = [PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(200, 50), Vector2(100, 50), Vector2(100, 100), Vector2(0, 100)])]
	var shelf_l := TableSupports.shelf_polygons(fp_l)
	var in_l := not shelf_l.is_empty()
	for sp in shelf_l:
		for pt in sp:
			in_l = in_l and Geometry2D.is_point_in_polygon(pt, fp_l[0])
	check("полка у Г-образного стола: внутри футпринта", in_l, str(shelf_l.size()))
	var lv := TableSupports.shelf_levels(th, 45.0)
	check("уровни полки: низ на уровне низа царг, толщина SHELF_T", is_equal_approx(lv.y, -th - TableSupports.APRON_H) and is_equal_approx(lv.x - lv.y, TableSupports.SHELF_T), str(lv))
	var lv_low := TableSupports.shelf_levels(th, 3.0)
	check("низкий стол: полка не глубже ножки", is_equal_approx(lv_low.y, -th - 3.0), str(lv_low))
	# XX claude-wire W5: глубина подрамника из настройки
	var deep := TableSupports.parts(legs, fp_v1, 50.0, th, 6.0, cfg, true, 12.0)
	var deep_h := 0.0
	var deep_top := 0.0
	for p in deep:
		if String(p["name"]) == "Apron":
			deep_h = (p["size"] as Vector3).y
			deep_top = (p["center"] as Vector3).y + deep_h * 0.5
	check("глубина подрамника 12: царги 12 u, верх по-прежнему на низе плиты", is_equal_approx(deep_h, 12.0) and is_equal_approx(deep_top, -th), "%s %s" % [deep_h, deep_top])
	var lv12 := TableSupports.shelf_levels(th, 45.0, 12.0)
	check("глубина 12: низ полки на 12 u под плитой", is_equal_approx(lv12.y, -th - 12.0) and is_equal_approx(lv12.x - lv12.y, TableSupports.SHELF_T), str(lv12))
	check("глубина больше ножки: полка не глубже ножки", is_equal_approx(TableSupports.shelf_levels(th, 10.0, 30.0).y, -th - 10.0))
	check("настройка глубины по умолчанию равна TableSupports.APRON_H", is_equal_approx(Global.settings.apron_depth, TableSupports.APRON_H) and is_equal_approx(LYM.apron_depth(), TableSupports.APRON_H))
	var pm := TableSupports.prism_mesh(shelf[0], lv.x, lv.y)
	var pverts: PackedVector3Array = pm.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var bb := pm.get_aabb()
	check("призма: 12 треугольников (верх, низ, 4 боковые грани)", pm.get_surface_count() == 1 and pverts.size() == 36, str(pverts.size()))
	check("призма: габариты 194 x толщина x 94", absf(bb.size.x - 194.0) < 0.01 and is_equal_approx(bb.size.y, TableSupports.SHELF_T) and absf(bb.size.z - 94.0) < 0.01 and is_equal_approx(bb.position.y, lv.y), str(bb))
	check("призма: вырожденный контур даёт пустой меш", TableSupports.prism_mesh(PackedVector2Array([Vector2.ZERO, Vector2(1, 0)]), 0.0, -1.0).get_surface_count() == 0)
	var fp_wall: Array[PackedVector2Array] = [_poly(Rect2(-240, -50, 140, 100))]
	var p_wall := TableSupports.parts(wall, fp_wall, 50.0, th, 6.0, cfg)
	check("кронштейны: 3 штуки по 3 детали на западном ребре 100 u", p_wall.size() == 9 and _count(p_wall, "BracketArm") == 3, str(p_wall.size()))
	var det_ok := true
	var arm_ok := true
	for p in p_wall:
		det_ok = det_ok and (p["basis"] as Basis).determinant() > 0.99
		if String(p["name"]) == "BracketArm":
			arm_ok = arm_ok and is_equal_approx((p["size"] as Vector3).z, 40.0)
	check("повороты деталей без отражения", det_ok)
	check("полка вылетает на 40 u (предел)", arm_ok)
	var no_wall := TableSupports.parts(wall, fp_v1, 50.0, th, 6.0, cfg)
	check("кронштейны без стены: контур на ножках", _count(no_wall, "Leg") == 4 and _count(no_wall, "BracketArm") == 0)

	print("== 4. LYM: опоры и высота")
	LYM.reset()
	var a := _section(Vector2.ZERO, Vector2(200, 100))
	await get_tree().physics_frame
	check("опоры по умолчанию: ножки", LYM.config.support == legs and LYM.config.height == 50.0)
	check("кронштейны без комнаты: отказ", LYM.set_support(wall) != "" and LYM.config.support == legs)
	check("рама: высота подогнана до 10", LYM.set_support(plinth) == "" and LYM.config.support == plinth and LYM.config.height == 10.0, str(LYM.config.height))
	LYM.set_height(100.0)
	check("у рамы высота не больше 20", LYM.config.height == 20.0)
	LYM.set_height(10.0)
	check("с ножек на раму и обратно: высота 50 вернулась", LYM.set_support(legs) == "" and LYM.config.height == 50.0, str(LYM.config.height))
	LYM.set_height(90.0)
	LYM.set_support(plinth)
	LYM.set_height(15.0)
	LYM.set_support(legs)
	check("высоту меняли на раме: остаётся своя", LYM.config.height == 15.0, str(LYM.config.height))
	var st := LYM.get_state()
	LYM.set_support(plinth)
	LYM.set_state(st)
	check("загрузка состояния возвращает опоры и высоту", LYM.config.support == legs and LYM.config.height == 15.0)
	LYM.set_state({"support": plinth, "height": 90.0})
	check("сейв с рамой и высотой 90: высота в пределе рамы", LYM.config.support == plinth and LYM.config.height == 20.0)
	LYM.reset()
	a.free()
	check("пустой стол: секций и футпринта нет", LYM.get_sections().is_empty() and LYM.footprint().is_empty())
	check("пустой стол: опор нет", TableSupports.parts(legs, LYM.footprint(), 50.0, th, 6.0, cfg).is_empty())
	LYM.set_aisle(200.0)
	check("проход не больше 150", LYM.config.aisle_min == 150.0)
	LYM.set_aisle(-5.0)
	check("проход не отрицательный", LYM.config.aisle_min == 0.0)
	LYM.reset()
	check("проход по умолчанию возвращается (reset)", LYM.config.aisle_min == LayoutConfig.new().aisle_min)

	print("== 4b. Прилипание к стенам")
	var big := Vector2(100, 100)
	var wall_edges := TableRules.wall_snap_rects(cfg, wall, 60.0)
	check("кронштейны: вплотную к западной стене", TableTool.snap_center(Vector2(-185, 0), big, wall_edges) == Vector2(-190, 0), str(TableTool.snap_center(Vector2(-185, 0), big, wall_edges)))
	var leg_edges := TableRules.wall_snap_rects(cfg, legs, 60.0)
	var sn := TableTool.snap_center(Vector2(-125, 0), big, leg_edges)
	check("ножки: на проходе 60 от западной стены", sn == Vector2(-130, 0) and TableRules.placement_reason(Rect2(sn - big * 0.5, big), cfg, legs, 60.0) == "", str(sn))
	var attic_edges := TableRules.wall_snap_rects(attic, wall, 60.0)
	check("мансарда: у скоса проход 60, а не стена", TableTool.snap_center(Vector2(155, 0), big, attic_edges) == Vector2(150, 0))
	check("стенд без стен: прилипать не к чему", TableRules.wall_snap_rects(none, wall, 60.0).is_empty())
	check("далеко от стены без прилипания", TableTool.snap_center(Vector2(0, 0), big, wall_edges) == Vector2(0, 0))

	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, комнату не строим")
		print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
		return

	print("== 5. Комната: кронштейны и рама в RoomBuilder")
	var rb := RoomBuilder.new()
	add_child(rb)
	var s1 := LYM.ensure_start_section(self)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("кронштейны принимаются и у стола посреди комнаты", LYM.set_support(wall) == "" and LYM.config.support == wall)
	check("предупреждение: стол не касается стены", LYM.support_warning().contains("Придвиньте"), LYM.support_warning())
	await get_tree().physics_frame
	await get_tree().physics_frame
	var legs_fb := 0
	var brk_fb := 0
	for ch in rb.table.get_children():
		if ch.name.begins_with("Leg"):
			legs_fb += 1
		elif ch.name.begins_with("Bracket"):
			brk_fb += 1
	check("без стены стол стоит на ножках", legs_fb == 4 and brk_fb == 0, "%d / %d" % [legs_fb, brk_fb])
	check("первая секция в воздухе красная", LYM.placement_reason(Rect2(150, 0, 100, 100)) != "")
	LYM.set_support(legs)
	var s2 := _section(Vector2(-170, 0), Vector2(140, 100))
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("кронштейны принимаются", LYM.set_support(wall) == "" and LYM.config.support == wall)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var brackets := 0
	var legs_n := 0
	for ch in rb.table.get_children():
		if ch.name.begins_with("BracketArm"):
			brackets += 1
		elif ch.name.begins_with("Leg"):
			legs_n += 1
	check("RoomBuilder построил кронштейны, ножек нет", brackets == 3 and legs_n == 0, "%d / %d" % [brackets, legs_n])
	check("убрать секцию, без которой стол отрывается от стены", LYM.removal_block_reason(s2).contains("крепление"), LYM.removal_block_reason(s2))
	check("новая секция у окна красная", LYM.placement_reason(Rect2(-100, -190, 200, 100)) == "Секция закрывает окно", LYM.placement_reason(Rect2(-100, -190, 200, 100)))
	check("новая секция в воздухе красная", LYM.placement_reason(Rect2(150, 0, 100, 100)) != "")
	check("предупреждение о глубине у стола 340 u", LYM.depth_warning() != "", LYM.depth_warning())
	check("рама: переключение разрешено, но высота 10", LYM.set_support(plinth) == "" and LYM.config.height == 10.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var rails := 0
	for ch in rb.table.get_children():
		if ch.name.begins_with("Rail"):
			rails += 1
	check("RoomBuilder построил раму: рёбра футпринта", rails == 4 or rails == 6, str(rails))
	check("комната сдвинута по высоте рамы 10", is_equal_approx(rb.floor_offset(), -10.0 - rb.config.floor_y), str(rb.floor_offset()))
	check("ножки в комнате вернулись", LYM.set_support(legs) == "" and LYM.config.height == 50.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var legs_back := 0
	for ch in rb.table.get_children():
		if ch.name.begins_with("Leg"):
			legs_back += 1
	check("ножек у стола 340 x 100: 4 угла и по одной на длинных рёбрах", legs_back == 6, str(legs_back))
	# XX claude-wire W2, W4: подрамник и нижняя полка в комнате
	var under_l := Global.active_layers(['underside'])
	LYM.set_apron(true)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var aprons := 0
	var shelves := 0
	var shelf_ok := true
	for ch in rb.table.get_children():
		if ch.name.begins_with("Apron"):
			aprons += 1
		if ch.name.begins_with("Shelf"):
			shelves += 1
			var sb := ch as StaticBody3D
			shelf_ok = shelf_ok and sb != null and (sb.collision_layer & under_l) != 0 \
					and (sb.collision_layer & (Global.active_layers(['ground']) | Global.active_layers(['room']))) == 0 and Mount.on_shelf(sb)
	check("RoomBuilder построил подрамник", aprons == 4 or aprons == 6, str(aprons))
	check("нижняя полка построена, тело только на слое underside", shelves >= 1 and shelf_ok, str(shelves))
	var c := LYM.section_rects()[0].get_center()
	var ray := PhysicsRayQueryParameters3D.create(Vector3(c.x, 50.0, c.y), Vector3(c.x, -200.0, c.y), under_l)
	var hit := rb.get_viewport().world_3d.direct_space_state.intersect_ray(ray)
	check("луч по слою underside бьёт в верх полки", not hit.is_empty() and absf(hit.position.y - (rb.table.global_position.y + LYM.shelf_top())) < 0.01 and Mount.on_shelf(hit.collider), str(hit))
	LYM.set_apron(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	aprons = 0
	shelves = 0
	for ch in rb.table.get_children():
		if ch.name.begins_with("Apron"):
			aprons += 1
		if ch.name.begins_with("Shelf"):
			shelves += 1
	hit = rb.get_viewport().world_3d.direct_space_state.intersect_ray(ray)
	check("подрамник выключен: ни царг, ни полки", aprons == 0 and shelves == 0 and hit.is_empty(), "%d %d" % [aprons, shelves])
	rb.queue_free()
	s1.free()
	s2.free()
	LYM.reset()
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
