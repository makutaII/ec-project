extends Node

# XX claude-wire W4 (новый файл)
## ATTN_23 W4: монтаж блоков на плиту и на нижнюю полку. Запуск: открыть tests/mount_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: Mount (метка полки, причины отказа у края полки, маски лучей блоков и проводов при виде «Монтаж»),
## паспорта блоков (C_MountDraggable у селектора, предохранителя, реверсора; у 3D-пульта нет) и C_MountDraggable на сущности
## (плита сверху как раньше, полка: высота верха полки, C_Invalid у края и возврат при отказе, поворот Q/E, блок не переворачивается).

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _section(pos: Vector2) -> Entity:
	var f := EntityFactory.new()
	var e := f.create_from_setting(load("res://data/table/objects/sec_200x100.tres") as EntitySetting)
	f.free()
	e.position = Vector3(pos.x, 0.0, pos.y)
	add_child(e)
	return e


func _ready() -> void:
	print("== 1. Mount: полка по коллайдеру")
	var shelf_body := StaticBody3D.new()
	shelf_body.set_meta(Mount.META, &"SHELF")
	var plain := StaticBody3D.new()
	check("тело с метой SHELF", Mount.on_shelf(shelf_body))
	check("тело без меты и null: не полка", not Mount.on_shelf(plain) and not Mount.on_shelf(null))
	shelf_body.free()
	plain.free()

	print("== 2. Паспорта блоков")
	var sel := load("res://data/power/objects/block_selector_01.tres") as EntitySetting
	for stem in ["block_selector_01", "fuse_01", "reverser_01"]:
		var s := load("res://data/power/objects/%s.tres" % stem) as EntitySetting
		check("%s: драг с монтажом" % stem, s != null and Mount.has_mount(s))
	var pult := load("res://ui/dc_controllers/objects/dc_3d_1.tres") as EntitySetting
	check("3D-пульт остаётся без монтажа (только сверху)", pult != null and not Mount.has_mount(pult))
	check("пустой паспорт: без монтажа", not Mount.has_mount(null))

	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, секции не создаются")
		print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
		return
	LYM.reset()
	var sec := _section(Vector2.ZERO)   # x -100..100, z -50..50
	await get_tree().physics_frame
	await get_tree().physics_frame
	var ground := Global.active_layers(['ground'])
	var tracks := Global.active_layers(['tracks'])
	var under_l := Global.active_layers(['underside'])

	print("== 3. Маски лучей")
	check("без вида «Монтаж» маска блока прежняя", Mount.pick_mask(sel, ground) == ground)
	check("без вида «Монтаж» маска провода прежняя", Mount.wire_mask(ground | tracks) == (ground | tracks))
	LYM.wiring_active = true
	check("вид включён, плита показана: блок видит ground и полку", Mount.pick_mask(sel, ground) == (ground | under_l))
	check("вид включён, плита показана: провод видит ground, tracks и полку", Mount.wire_mask(ground | tracks) == (ground | tracks | under_l))
	LYM.set_plate_visible(false)
	check("плита скрыта: блок видит только полку", Mount.pick_mask(sel, ground) == under_l)
	check("плита скрыта: провод видит tracks и полку, но не ground", Mount.wire_mask(ground | tracks) == (tracks | under_l))
	check("пульт без монтажа: маска прежняя", Mount.pick_mask(pult, ground) == ground)
	LYM.set_plate_visible(true)
	LYM.wiring_active = false

	print("== 4. Mount.reason: край полки")
	check("плита сверху: ограничений нет", Mount.reason(Vector3(500, 0, 500), false) == "")
	check("полки нет (подрамник выключен): на полку нельзя", Mount.reason(Vector3(0, -10, 0), true) != "")
	LYM.set_apron(true)
	check("полка есть: в середине стола можно", Mount.reason(Vector3(0, LYM.shelf_top(), 0), true) == "")
	check("у края полки (1 u): нельзя", Mount.reason(Vector3(-96, LYM.shelf_top(), 0), true) != "")
	check("за запасом от края (SHELF_MARGIN + 1): можно", Mount.reason(Vector3(-97 + Mount.SHELF_MARGIN + 1.0, LYM.shelf_top(), 0), true) == "")

	print("== 5. C_MountDraggable на сущности")
	var f := EntityFactory.new()
	var blk := f.create_from_setting(sel)
	f.free()
	add_child(blk)
	await get_tree().physics_frame
	var md := blk.get_comp(C_MountDraggable) as C_MountDraggable
	check("у блока есть C_MountDraggable", md != null)
	if md != null:
		var shelf_col := StaticBody3D.new()
		shelf_col.set_meta(Mount.META, &"SHELF")
		add_child(shelf_col)
		var top := LYM.shelf_top()
		var hit := {"position": Vector3(0, top, 0), "normal": Vector3.UP, "collider": shelf_col}
		md.on_drag_started(hit)
		md.on_drag_moved(hit)
		check("полка: блок стоит на верху полки, вертикально", is_equal_approx(blk.global_position.y, top) and blk.global_basis.y.is_equal_approx(Vector3.UP), str(blk.global_transform))
		check("полка в середине: метки C_Invalid нет", not blk.has_comp(C_Invalid))
		md.on_rotate_input({"axis": "y", "amount": 90.0})
		md.on_drag_moved(hit)
		check("Q/E: поворот вокруг вертикали, блок не переворачивается", blk.global_basis.y.is_equal_approx(Vector3.UP) and absf(blk.global_basis.get_euler().y - deg_to_rad(90.0)) < 0.001)
		var edge := {"position": Vector3(-96, top, 0), "normal": Vector3.UP, "collider": shelf_col}
		md.on_drag_moved(edge)
		check("у края полки: C_Invalid", blk.has_comp(C_Invalid))
		md.on_drag_ended(edge)
		check("отказ при отпускании: блок вернулся на место начала драга, метка снята", blk.global_position.is_equal_approx(Vector3.ZERO) and not blk.has_comp(C_Invalid), str(blk.global_position))
		md.on_drag_moved({"position": Vector3(10, 0, 10), "normal": Vector3.UP, "collider": sec.get_comp(C_TableSection).body})
		check("плита сверху: блок стоит как раньше, метка снята", is_equal_approx(blk.global_position.x, 10.0) and is_equal_approx(blk.global_position.z, 10.0) and not blk.has_comp(C_Invalid))
		shelf_col.free()
	LYM.set_apron(false)
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
