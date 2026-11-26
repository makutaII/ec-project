extends Node

# XX claude-wire W3 (новый файл)
## ATTN_23 W3, W4: вид «Монтаж» внутри Operate. Запуск: открыть tests/wiring_view_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: плиту (LYM.set_plate_visible скрывает меш, коллизия ground остаётся, новая секция при скрытой плите скрыта,
## LYM.reset возвращает плиту); WiringView (схема прячет поезда, здания, декор, рельеф; дороги и блоки остаются;
## «как есть» и выход из режима возвращают всё; чужая невидимость не ломается).

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _section(pos: Vector2) -> Entity:
	var f := EntityFactory.new()
	var e := f.create_from_setting(load("res://data/table/objects/sec_100x100.tres") as EntitySetting)
	f.free()
	e.position = Vector3(pos.x, 0.0, pos.y)
	add_child(e)
	return e


## Пробная сущность только с паспортом нужной категории
func _dummy(root: Node3D, category: StringName) -> Entity:
	var s := EntitySetting.new()
	s.key = StringName("wv_test_" + String(category))
	s.category = category
	s.components.append(IdentitySetting.new())
	var f := EntityFactory.new()
	var e := f.create_from_setting(s)
	f.free()
	root.add_child(e)
	return e


func _tag_ids(p: EntityCatalogProvider, cat: StringName) -> Array:
	var ids := []
	for t in p.get_tags(cat):
		ids.append(t["id"])
	return ids


func _ready() -> void:
	print("== 1. Плита стола")
	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, секции не создаются")
	else:
		LYM.reset()
		var a := _section(Vector2.ZERO)
		await get_tree().physics_frame
		var ca := a.get_comp(C_TableSection) as C_TableSection
		check("плита видна по умолчанию", LYM.plate_visible and ca.mesh_node.visible)
		LYM.set_plate_visible(false)
		check("плита скрыта: меш не виден", not ca.mesh_node.visible)
		check("коллизия ground осталась", (ca.body.collision_layer & Global.active_layers(['ground'])) != 0 and ca.body.get_child_count() > 0)
		var b := _section(Vector2(100, 0))
		await get_tree().physics_frame
		check("новая секция при скрытой плите тоже скрыта", not (b.get_comp(C_TableSection) as C_TableSection).mesh_node.visible)
		LYM.set_plate_visible(true)
		check("плита показана: обе секции видны", ca.mesh_node.visible and (b.get_comp(C_TableSection) as C_TableSection).mesh_node.visible)
		LYM.set_plate_visible(false)
		LYM.reset()
		check("LYM.reset возвращает плиту", LYM.plate_visible)

	print("== 2. WiringView: вид «Монтаж» внутри Operate и схема путей")
	var root := Node3D.new()
	add_child(root)
	var train := _dummy(root, &"train")
	var house := _dummy(root, &"building")
	var decor := _dummy(root, &"decor")
	var terrain := _dummy(root, &"terrain")
	var track := _dummy(root, &"track")
	var block := _dummy(root, &"dc_controller")
	var other_hidden := _dummy(root, &"building")
	other_hidden.visible = false   # скрыт кем-то другим: режим его не трогает
	var wv := WiringView.new()
	wv.entities_root = root
	add_child(wv)
	check("по умолчанию схема", wv.paths == WiringView.Paths.SCHEME)
	wv.on_mode_changed(&"operate")
	check("смена режима на Operate вид не включает", not wv.active and train.visible)
	wv.set_active(true)
	check("вид включён: LYM.wiring_active", wv.active and LYM.wiring_active)
	check("схема: поезд, здание, декор, рельеф скрыты", not train.visible and not house.visible and not decor.visible and not terrain.visible)
	check("схема: дорога и блок остаются", track.visible and block.visible)
	wv.set_paths(WiringView.Paths.ALL)
	check("«как есть»: всё видно, кроме скрытого другими", train.visible and house.visible and decor.visible and terrain.visible and not other_hidden.visible)
	wv.set_paths(WiringView.Paths.SCHEME)
	check("снова схема", not train.visible and not house.visible)
	wv.on_mode_changed(&"build")
	check("выход из Operate выключает вид", not wv.active and not LYM.wiring_active and LYM.plate_visible)
	check("выход из режима: всё как было", train.visible and house.visible and decor.visible and terrain.visible and track.visible and block.visible)
	check("чужая невидимость осталась", not other_hidden.visible)
	check("метки убраны", not train.has_meta(WiringView.META_PREV))
	wv.set_paths(WiringView.Paths.ALL)
	wv.set_active(true)
	check("при «как есть» вход в вид ничего не прячет", train.visible and house.visible)
	wv.set_active(false)
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
