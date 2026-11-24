extends Node

# XX claude-wire W0 (новый файл)
## ATTN_23 W0: провод и секции. Запуск: открыть tests/wire_section_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: C_Wire.probe_points (только точки излома, без начала сущности); LYM.objects_on_section не считает провод
## стоящим на секции под нулём мира, считает по его изломам; провод без изломов секцию не держит; removal_block_reason.
## До исправления сущность провода (стоит в нуле мира) блокировала удаление секции под точкой (0, 0).

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _section(preset: String, pos: Vector2) -> Entity:
	var f := EntityFactory.new()
	var e := f.create_from_setting(load("res://data/table/objects/%s.tres" % preset) as EntitySetting)
	f.free()
	e.position = Vector3(pos.x, 0.0, pos.y)
	add_child(e)
	return e


func _term(role: PowerTerminal.Role, pos: Vector3) -> PowerTerminal:
	var t := PowerTerminal.new()
	t.role = role
	add_child(t)
	t.position = pos
	return t


## Новый провод между двумя свободными клеммами с заданными изломами
func _wire(mid: PackedVector3Array) -> Entity:
	var src := _term(PowerTerminal.Role.SRC, Vector3(150, 0.6, 0))
	var dst := _term(PowerTerminal.Role.SINK, Vector3(160, 1.5, 10))
	return C_Wire.create_wire(self, src, dst, mid)


func _ready() -> void:
	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, секции не строим")
		print("ИТОГ: OK")
		return
	LYM.reset()
	var a := _section("sec_200x100", Vector2.ZERO)        # x -100..100, под нулём мира
	var b := _section("sec_100x100", Vector2(150, 0))     # x 100..200
	await get_tree().physics_frame

	print("== 1. probe_points: только изломы")
	var w_b := _wire(PackedVector3Array([Vector3(140, 1, 0), Vector3(180, 1, 20)]))
	check("провод создан", w_b != null)
	var wc := w_b.get_comp(C_Wire) as C_Wire
	var pp := wc.probe_points()
	check("две точки излома", pp.size() == 2 and pp[0] == Vector2(140, 0) and pp[1] == Vector2(180, 20), str(pp))
	check("сущность провода стоит в нуле мира", w_b.global_position.is_equal_approx(Vector3.ZERO), str(w_b.global_position))

	print("== 2. objects_on_section: провод по изломам")
	check("провод над секцией B считается на B", LYM.objects_on_section(b).has(w_b))
	check("секция под нулём мира его не держит", not LYM.objects_on_section(a).has(w_b))
	check("секцию A можно убрать", LYM.removal_block_reason(a) == "", LYM.removal_block_reason(a))
	check("секцию B убрать нельзя", LYM.removal_block_reason(b) != "")

	print("== 3. Провод с изломом над A")
	var w_a := _wire(PackedVector3Array([Vector3(-30, 1, 10)]))
	check("провод над A считается на A", w_a != null and LYM.objects_on_section(a).has(w_a))
	check("и не считается на B", not LYM.objects_on_section(b).has(w_a))
	check("секцию A убрать нельзя", LYM.removal_block_reason(a) != "")

	print("== 4. Провод без изломов")
	w_a.kill_me()
	w_b.kill_me()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var w0 := _wire(PackedVector3Array())
	check("пустые точки: probe_points пуст", w0 != null and (w0.get_comp(C_Wire) as C_Wire).probe_points().is_empty())
	check("не мешает убрать секцию A", not LYM.objects_on_section(a).has(w0) and LYM.removal_block_reason(a) == "")
	check("не мешает убрать секцию B", not LYM.objects_on_section(b).has(w0))
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
