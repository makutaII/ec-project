extends Node

# XX claude-wire W4 (новый файл)
## ATTN_23 W4: монтаж блоков. Запуск: открыть tests/mount_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: Mount (базис по нормали, поворот вокруг неё и обратный расчёт, поверхность по позе и по коллайдеру,
## причины отказа на UNDER и FRAME, маска лучей при виде «Монтаж»), паспорта блоков (C_MountDraggable в селекторе,
## предохранителе и реверсоре) и C_MountDraggable на сущности (низ плиты, брус, плита сверху, возврат при отказе).

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


func _ortho(b: Basis) -> bool:
	return is_equal_approx(b.determinant(), 1.0) and absf(b.x.dot(b.y)) < 0.0001 and absf(b.y.dot(b.z)) < 0.0001 and absf(b.x.dot(b.z)) < 0.0001


func _ready() -> void:
	print("== 1. Mount: базис")
	var up := Mount.basis_for(Vector3.UP, 0.0)
	check("вверх без поворота: единичный базис", up.is_equal_approx(Basis.IDENTITY), str(up))
	var yaw := Mount.basis_for(Vector3.UP, deg_to_rad(90.0))
	check("вверх с поворотом: как поворот вокруг Y", yaw.is_equal_approx(Basis(Vector3.UP, deg_to_rad(90.0))), str(yaw))
	var down := Mount.basis_for(Vector3.DOWN, 0.0)
	check("вниз: ось Y вниз, базис правый", down.y.is_equal_approx(Vector3.DOWN) and _ortho(down), str(down))
	for n in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK, Vector3(1, 0.2, 0.5)]:
		var b := Mount.basis_for(n, 0.7)
		check("нормаль %s: Y по нормали, ортонормирован" % str(n), b.y.is_equal_approx(n.normalized()) and _ortho(b))
	print("== 2. Mount: поворот и поверхность")
	for n in [Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3(0, 0.1, -1)]:
		var spin := 0.9
		var b := Mount.basis_for(n, spin)
		check("поворот туда и обратно, нормаль %s" % str(n), is_equal_approx(Mount.spin_of(b, n.normalized()), spin), str(Mount.spin_of(b, n.normalized())))
	check("поверхность по позе: вверх TOP", Mount.surface_of_basis(up) == Mount.Surface.TOP)
	check("поверхность по позе: вниз UNDER", Mount.surface_of_basis(down) == Mount.Surface.UNDER)
	check("поверхность по позе: в сторону FRAME", Mount.surface_of_basis(Mount.basis_for(Vector3.RIGHT, 0.0)) == Mount.Surface.FRAME)
	var under_body := StaticBody3D.new()
	under_body.set_meta(Mount.META, &"UNDER")
	var frame_body := StaticBody3D.new()
	frame_body.set_meta(Mount.META, &"FRAME")
	var plain := StaticBody3D.new()
	check("коллайдер с метой UNDER", Mount.surface_of_collider(under_body) == Mount.Surface.UNDER)
	check("коллайдер с метой FRAME", Mount.surface_of_collider(frame_body) == Mount.Surface.FRAME)
	check("коллайдер без меты и null: TOP", Mount.surface_of_collider(plain) == Mount.Surface.TOP and Mount.surface_of_collider(null) == Mount.Surface.TOP)
	under_body.free()
	frame_body.free()
	plain.free()

	print("== 3. Паспорта блоков")
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
	var all := [Mount.Surface.TOP, Mount.Surface.UNDER, Mount.Surface.FRAME]

	print("== 4. Mount.reason")
	check("TOP: всегда можно", Mount.reason(Mount.Surface.TOP, Vector3(500, 0, 500), Vector3.UP, all) == "")
	check("UNDER в середине стола: можно", Mount.reason(Mount.Surface.UNDER, Vector3(0, -5, 0), Vector3.DOWN, all) == "")
	check("UNDER у края (3 u): нельзя", Mount.reason(Mount.Surface.UNDER, Vector3(-97, -5, 0), Vector3.DOWN, all) != "")
	check("UNDER на границе запаса: можно", Mount.reason(Mount.Surface.UNDER, Vector3(-100 + Mount.UNDER_MARGIN + 1.0, -5, 0), Vector3.DOWN, all) == "")
	check("UNDER не из allowed: нельзя", Mount.reason(Mount.Surface.UNDER, Vector3(0, -5, 0), Vector3.DOWN, [Mount.Surface.TOP]) != "")
	check("FRAME: боковая грань можно", Mount.reason(Mount.Surface.FRAME, Vector3(0, -20, 0), Vector3.RIGHT, all) == "")
	check("FRAME: верхняя грань бруса нельзя", Mount.reason(Mount.Surface.FRAME, Vector3(0, -20, 0), Vector3.UP, all) != "")

	print("== 5. Маска лучей")
	var sel := load("res://data/power/objects/block_selector_01.tres") as EntitySetting
	var ground := Global.active_layers(['ground'])
	var under_l := Global.active_layers(['underside'])
	check("без вида «Монтаж» маска прежняя", Mount.pick_mask(sel, ground) == ground)
	LYM.wiring_active = true
	check("вид включён, плита показана: ground и underside", Mount.pick_mask(sel, ground) == (ground | under_l))
	LYM.set_plate_visible(false)
	check("плита скрыта: только underside", Mount.pick_mask(sel, ground) == under_l)
	check("пульт без монтажа: маска прежняя", Mount.pick_mask(pult, ground) == ground)
	LYM.set_plate_visible(true)
	LYM.wiring_active = false

	print("== 6. C_MountDraggable на сущности")
	var f := EntityFactory.new()
	var blk := f.create_from_setting(sel)
	f.free()
	add_child(blk)
	await get_tree().physics_frame
	var md := blk.get_comp(C_MountDraggable) as C_MountDraggable
	check("у блока есть C_MountDraggable", md != null and md.allowed.size() == 3)
	if md != null:
		var under_hit := {"position": Vector3(0, -5, 0), "normal": Vector3.UP, "collider": sec.get_comp(C_TableSection).under_body}
		md.on_drag_started(under_hit)
		md.on_drag_moved(under_hit)
		check("низ плиты: блок висит вниз головой на y = -5", blk.global_basis.y.is_equal_approx(Vector3.DOWN) and is_equal_approx(blk.global_position.y, -5.0), str(blk.global_transform))
		check("низ плиты в середине стола: метки C_Invalid нет", not blk.has_comp(C_Invalid))
		md.on_rotate_input({"axis": "y", "amount": 90.0})
		md.on_drag_moved(under_hit)
		check("Q/E крутят вокруг нормали: блок остаётся вниз головой", blk.global_basis.y.is_equal_approx(Vector3.DOWN) and absf(Mount.spin_of(blk.global_basis, Vector3.DOWN) - deg_to_rad(90.0)) < 0.001)
		var edge_hit := {"position": Vector3(-98, -5, 0), "normal": Vector3.UP, "collider": sec.get_comp(C_TableSection).under_body}
		md.on_drag_moved(edge_hit)
		check("у края стола: C_Invalid", blk.has_comp(C_Invalid))
		md.on_drag_ended(edge_hit)
		check("отказ при отпускании: блок вернулся на место начала драга, метка снята", blk.global_position.is_equal_approx(Vector3.ZERO) and not blk.has_comp(C_Invalid), str(blk.global_position))
		var beam := StaticBody3D.new()
		beam.set_meta(Mount.META, &"FRAME")
		add_child(beam)
		md.on_drag_moved({"position": Vector3(40, -20, 30), "normal": Vector3.RIGHT, "collider": beam})
		check("брус: блок лёг боком (ось Y вдоль нормали)", blk.global_basis.y.is_equal_approx(Vector3.RIGHT) and blk.global_position.is_equal_approx(Vector3(40, -20, 30)) and not blk.has_comp(C_Invalid))
		md.on_drag_moved({"position": Vector3(40, -20, 30), "normal": Vector3.UP, "collider": beam})
		check("верхняя грань бруса: C_Invalid", blk.has_comp(C_Invalid))
		md.on_drag_moved({"position": Vector3(10, 0, 10), "normal": Vector3.UP, "collider": null})
		check("плита сверху: блок стоит как раньше, метка снята", Mount.surface_of_basis(blk.global_basis) == Mount.Surface.TOP and not blk.has_comp(C_Invalid) and is_equal_approx(blk.global_position.x, 10.0))
		beam.free()
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
