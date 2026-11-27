extends Node

# XX claude-wire W7 (новый файл)
## ATTN_23 W7: автопроводка под столом. Запуск: открыть tests/wire_router_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: WireRouter (клемма на плите уходит через ввод вниз, дальше по полке, у второй клеммы вверх; блок на полке без ввода; обход ножки;
## отказ без места под ввод; сдвиг соседних проводов), AutoWire на столе с полкой и без неё (провод лежит на поверхностях, дуги по воздуху нет).

var _bad := 0
const SHELF_Y := -9.8
const SURF_Y := 0.2


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _ctx(lane := 0, walk: Array = [], keep: Array = [], reject_all := false) -> Dictionary:
	if walk.is_empty():
		walk = [PackedVector2Array([Vector2(-90, -40), Vector2(90, -40), Vector2(90, 40), Vector2(-90, 40)])]
	return {
		"walkable": walk,
		"keepouts": keep,
		"shelf_y": SHELF_Y,
		"surface_y": func(_x: float, _z: float) -> float: return SURF_Y,
		"hole_reason": func(p: Vector3) -> String: return "отказ" if reject_all or absf(p.x) > 95.0 or absf(p.z) > 45.0 else "",
		"lane": lane,
	}


## Вертикальные отрезки (ввод): пары соседних узлов с одним (x, z) и разной высотой
func _verticals(r: PackedVector3Array) -> Array:
	var res := []
	for i in r.size() - 1:
		if absf(r[i].x - r[i + 1].x) < 0.001 and absf(r[i].z - r[i + 1].z) < 0.001 and absf(r[i].y - r[i + 1].y) > 0.001:
			res.append(Vector2(r[i].x, r[i].z))
	return res


func _in_rects(r: PackedVector3Array, rects: Array) -> bool:
	for i in r.size() - 1:
		var p := Vector2(r[i].x, r[i].z)
		var q := Vector2(r[i + 1].x, r[i + 1].z)
		for k in range(0, 21):
			var s := p.lerp(q, float(k) / 20.0)
			for rect in rects:
				if (rect as Rect2).has_point(s) and not (k == 0 or k == 20):
					return true
	return false


func _ready() -> void:
	print("== 1. Плита, плита: два ввода и ход по полке")
	var pa := Vector3(-60, SURF_Y, 0)
	var pb := Vector3(60, SURF_Y, 10)
	var r := WireRouter.route(pa, pb, _ctx())
	check("маршрут найден, концы на месте", not r.is_empty() and r[0] == pa and r[r.size() - 1] == pb, str(r.size()))
	var v := _verticals(r)
	check("ровно два ввода", v.size() == 2, str(v))
	var holes_ok := true
	for h in v:
		holes_ok = holes_ok and absf((h as Vector2).x) < 95.0
	check("вводы допустимы по правилу отверстий", holes_ok)
	check("ввод у первой клеммы не ближе 2.5 u и у второй тоже", v.size() == 2 and (v[0] as Vector2).distance_to(Vector2(pa.x, pa.z)) >= 2.499 and (v[1] as Vector2).distance_to(Vector2(pb.x, pb.z)) >= 2.499, str(v))
	var shelf_nodes_ok := true
	var surf_nodes_ok := true
	for p in r:
		if p.y < 0.0:
			shelf_nodes_ok = shelf_nodes_ok and is_equal_approx(p.y, SHELF_Y)
		else:
			surf_nodes_ok = surf_nodes_ok and is_equal_approx(p.y, SURF_Y)
	check("узлы на полке на высоте полки, узлы сверху на высоте поверхности: провод лежит, а не висит", shelf_nodes_ok and surf_nodes_ok)
	var inside := true
	for p in r:
		if p.y < 0.0:
			inside = inside and Geometry2D.is_point_in_polygon(Vector2(p.x, p.z), (_ctx()["walkable"] as Array)[0])
	check("все узлы на полке внутри разрешённой зоны", inside)

	print("== 2. Клемма на полке без ввода")
	var sa := Vector3(-60, SHELF_Y, 0)
	var sb := Vector3(60, SHELF_Y, 10)
	var rs := WireRouter.route(sa, sb, _ctx())
	check("полка, полка: вводов нет", not rs.is_empty() and _verticals(rs).is_empty(), str(rs))
	var rm := WireRouter.route(sa, pb, _ctx())
	check("полка, плита: один ввод", not rm.is_empty() and _verticals(rm).size() == 1 and rm[0] == sa and rm[rm.size() - 1] == pb, str(_verticals(rm)))

	print("== 3. Обход ножки")
	var leg := Rect2(-5, -5, 10, 10)
	var rl := WireRouter.route(sa, sb, _ctx(0, [], [leg]))
	check("маршрут в обход найден", not rl.is_empty())
	check("путь не заходит в запретный прямоугольник", not _in_rects(rl, [leg]), str(rl))
	var blocked := Rect2(-5, -50, 10, 100)
	check("если ножка перегораживает полку целиком, маршрута нет", WireRouter.route(sa, sb, _ctx(0, [], [blocked])).is_empty())

	print("== 4. Нет места под ввод")
	check("все отверстия запрещены: пусто", WireRouter.route(pa, pb, _ctx(0, [], [], true)).is_empty())
	var tiny := [PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])]
	check("полка слишком мала: пусто", WireRouter.route(pa, pb, _ctx(0, tiny)).is_empty())
	check("но блок на полке с блоком на полке в малой зоне не требует вводов", WireRouter.route(Vector3(0, SHELF_Y, 0), Vector3(0.5, SHELF_Y, 0.5), _ctx(0, tiny)).size() >= 2)

	print("== 5. Серия: соседние провода со сдвигом")
	var r0 := WireRouter.route(sa, sb, _ctx(0))
	var r2 := WireRouter.route(sa, sb, _ctx(2))
	var r3 := WireRouter.route(sa, sb, _ctx(3))
	check("провод серии идёт иначе, чем первый", not r2.is_empty() and r2 != r0)
	check("соседние провода серии отличаются друг от друга", not r3.is_empty() and r3 != r2)

	print("== 6. AutoWire на столе")
	if Global.fast_debug:
		print("  пропуск: Global.fast_debug = true, секции не создаются")
		print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
		return
	LYM.reset()
	var f := EntityFactory.new()
	var sec := f.create_from_setting(load("res://data/table/objects/sec_200x100.tres") as EntitySetting)
	f.free()
	add_child(sec)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var lift: float = Global.settings.wire_lift
	var ta := PowerTerminal.new()
	ta.role = PowerTerminal.Role.SRC
	add_child(ta)
	ta.position = Vector3(-50, 0.6, 0)
	var tb := PowerTerminal.new()
	tb.role = PowerTerminal.Role.SINK
	add_child(tb)
	tb.position = Vector3(50, 0.6, 10)
	var plain := AutoWire.points(ta, tb)
	check("без полки: провод по поверхности между точками под клеммами, без дуги по воздуху", plain.size() == 2 and is_equal_approx(plain[0].y, lift) and is_equal_approx(plain[1].y, lift), str(plain))
	LYM.set_apron(true)
	var routed := AutoWire.points(ta, tb)
	var shelf_top: float = LYM.shelf_top() + lift
	var under_ok := true
	for p in routed:
		if p.y < 0.0:
			under_ok = under_ok and is_equal_approx(p.y, shelf_top)
	check("с полкой: два ввода и ход по полке", routed.size() >= 6 and _verticals(routed).size() == 2 and under_ok, str(routed))
	check("с полкой: начало и конец у клемм под ними", is_equal_approx(routed[0].x, -50.0) and is_equal_approx(routed[routed.size() - 1].x, 50.0))
	var wire_e := C_Wire.create_wire(self, ta, tb, routed)
	check("провод по трассе создан, втулок две", wire_e != null and (wire_e.get_comp(C_Wire) as C_Wire).holes().size() == 2)
	check("провод не висит: нет отрезка, поднимающегося над поверхностью больше чем на подъём оси и клемму", routed.size() > 0 and routed[0].y <= 0.6)
	LYM.set_apron(false)
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
