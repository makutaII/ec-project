extends Node

# XX claude-terra 13.14 H3 (новый файл)
## Тест пределов кисти и объектов в зоне (потолок от листа, пол, обход следа объекта, хуки отмены, опорные точки объекта).
## Запуск: открыть tests/field_limits_test.tscn и нажать F6. Результат в Output: строки PASS / FAIL и итог.
## Проверки на собственном TerrainField и FieldBrush, без сцены игры (потолок и следы подаются напрямую).

var _fails := 0


func check(name: String, ok: bool, info := "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", info)


func near(a: float, b: float, eps := 0.001) -> bool:
	return absf(a - b) <= eps


func rect(x0: float, z0: float, x1: float, z1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)])


func big() -> Array:
	return [rect(-100, -100, 100, 100)]


func node(x: float) -> int:
	return roundi(x / TerrainField.STEP)


## Потолок: низ листа на высоте 3 при x >= 10, левее листа нет
func ceil_sheet(r: Rect2i) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(r.size.x * r.size.y)
	for rj in r.size.y:
		for ri in r.size.x:
			a[rj * r.size.x + ri] = 3.0 if float(r.position.x + ri) * TerrainField.STEP >= 10.0 - 0.001 else INF
	return a


## Потолок 3 везде (кроме явных мест не нужен)
func ceil_all(r: Rect2i) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(r.size.x * r.size.y)
	a.fill(3.0)
	return a


func ceil_two(r: Rect2i) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(r.size.x * r.size.y)
	a.fill(2.0)
	return a


## Пол: верх листа 2 ю при x >= 10
func sheet_floor(x: float, _z: float) -> float:
	return 2.0 if x >= 10.0 - 0.001 else 0.0


func _ready() -> void:
	_test_ceiling()
	_test_pit_floor()
	_test_next_height()
	_test_bypass()
	_test_level_ceiling()
	_test_hooks()
	_test_support_points()
	print("ИТОГ: ", "ВСЕ ПРОШЛИ" if _fails == 0 else "ПРОВАЛЕНО %d" % _fails)


func _test_ceiling() -> void:
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.radius = 5.0
	b.ceiling_fn = Callable(self, "ceil_sheet")
	f.begin_edit()
	b.stroke(f, Vector2(12.0, 10.0), 5.0, 1, 1.0, big())
	f.end_edit()
	var mx := 0.0
	for j in range(node(0.0), node(20.0)):
		for i in range(node(10.0), node(20.0)):
			mx = maxf(mx, f.surface_at(i, j))
	check("потолок: под листом холм не выше низа листа", mx <= 3.0 + 0.01, str(mx))
	check("потолок: центр упёрся в низ листа", near(f.surface_at(node(12.0), node(10.0)), 3.0, 0.01), str(f.surface_at(node(12.0), node(10.0))))
	check("потолок: план сообщает об упоре", bool(b.last_plan["ceiling"]))
	check("потолок: левее листа насыпано выше потолка (там листа нет)", f.surface_at(node(8.0), node(10.0)) > 0.5)
	var g := TerrainField.new()
	var b2 := FieldBrush.new()
	b2.radius = 5.0
	b2.ceiling_fn = Callable(self, "ceil_sheet")
	b2.stroke(g, Vector2(12.0, 10.0), 2.0, 1, 1.0, big())
	check("потолок: площадка ниже листа, упора нет", not bool(b2.last_plan["ceiling"]) and near(g.surface_at(node(12.0), node(10.0)), 2.0, 0.01))
	# холм, который уже выше потолка (лист поставили поверх), подъём не опускает
	var h := TerrainField.new()
	var b3 := FieldBrush.new()
	b3.radius = 5.0
	b3.stroke(h, Vector2(12.0, 10.0), 6.0, 1, 1.0, big())
	var before := h.read_region(Rect2i(node(5.0), node(3.0), 30, 30))["w"] as PackedInt32Array
	b3.ceiling_fn = Callable(self, "ceil_all")
	b3.stroke(h, Vector2(12.0, 10.0), 7.0, 1, 1.0, big())
	var after := h.read_region(Rect2i(node(5.0), node(3.0), 30, 30))["w"] as PackedInt32Array
	var ok := true
	for k in before.size():
		if (after[k] & TerrainField.TH_MASK) < (before[k] & TerrainField.TH_MASK):
			ok = false
	check("потолок: подъём не опускает холм, который уже выше потолка", ok)


func _test_pit_floor() -> void:
	var f := TerrainField.new()
	f.floor_fn = Callable(self, "sheet_floor")
	var b := FieldBrush.new()
	b.radius = 4.0
	b.stroke(f, Vector2(12.0, 10.0), 3.0, 1, 1.0, big())
	b.stroke(f, Vector2(12.0, 10.0), -5.0, -1, 1.0, big())
	var ok := true
	for j in range(0, 40):
		for i in range(0, 40):
			if f.surface_at(i, j) < f.floor_at(i, j) - 0.0001:
				ok = false
	check("яма: глубже верха листа и стола не уходит", ok)
	check("яма: слой на листе снят до пола", not f.has_layer(node(12.0), node(10.0)) and near(f.surface_at(node(12.0), node(10.0)), 2.0))
	var g := TerrainField.new()
	var b2 := FieldBrush.new()
	b2.radius = 4.0
	b2.stroke(g, Vector2(6.0, 6.0), 1.0, 1, 1.0, big())
	b2.stroke(g, Vector2(6.0, 6.0), -3.0, -1, 1.0, big())
	check("яма: на столе слой снят до нуля, ниже стола нет", not g.has_layer(node(6.0), node(6.0)) and near(g.surface_at(node(6.0), node(6.0)), 0.0))


func _test_next_height() -> void:
	var b := FieldBrush.new()
	check("высота щелчка: потолок режет шаг", near(b.next_height(0.9, 1.0, false, 1.0, 0.0, 1.0), 1.0))
	check("высота щелчка: уже под потолком, выше некуда", near(b.next_height(0.5, 1.0, false, 1.0, 0.0, 0.5), 0.5))
	check("высота щелчка: без потолка шаг четверть слоя", near(b.next_height(0.9, 1.0, false, 1.0, 0.0), 1.15))
	check("высота щелчка: вниз потолок не мешает", near(b.next_height(0.9, -1.0, false, 1.0, 0.0, 1.0), 0.65))


func _test_bypass() -> void:
	var ins: Array[Vector2i] = []
	for j in range(node(8.0), node(12.0) + 1):
		for i in range(node(8.0), node(12.0) + 1):
			ins.append(Vector2i(i, j))
	var obst: Array = [rect(8, 8, 12, 12)]
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.radius = 5.0
	b.objects_mode = FieldBrush.OBJ_BYPASS
	b.obstacles = obst
	b.stroke(f, Vector2(10.0, 10.0), 2.0, 1, 1.0, big())
	var none := true
	for v in ins:
		if f.has_layer(v.x, v.y):
			none = false
	check("обход: под следом объекта слоя нет", none)
	check("обход: вокруг следа слой есть", f.has_layer(node(7.0), node(10.0)) and f.has_layer(node(13.0), node(10.0)) and f.has_layer(node(10.0), node(6.0)))
	check("обход: план отмечает объект", bool(b.last_plan["locked"]))
	var g := TerrainField.new()
	var b2 := FieldBrush.new()
	b2.radius = 5.0
	b2.objects_mode = FieldBrush.OBJ_IGNORE
	b2.obstacles = obst
	b2.stroke(g, Vector2(10.0, 10.0), 2.0, 1, 1.0, big())
	var all_set := true
	for v in ins:
		if not g.has_layer(v.x, v.y):
			all_set = false
	check("игнорировать: след объекта кисть не учитывает", all_set)
	var l := TerrainField.new()
	var b3 := FieldBrush.new()
	b3.radius = 5.0
	b3.objects_mode = FieldBrush.OBJ_LIFT
	b3.obstacles = obst
	b3.stroke(l, Vector2(10.0, 10.0), 2.0, 1, 1.0, big())
	var lift_set := true
	for v in ins:
		if not l.has_layer(v.x, v.y):
			lift_set = false
	check("поднимать: кисть идёт под объектом (поднимает сам инструмент)", lift_set)
	# существующий слой под объектом обход не трогает
	var t := TerrainField.new()
	var b4 := FieldBrush.new()
	b4.radius = 5.0
	b4.objects_mode = FieldBrush.OBJ_IGNORE
	b4.stroke(t, Vector2(10.0, 10.0), 1.0, 1, 1.0, big())
	var w0 := {}
	for v in ins:
		w0[v] = t.word_at(v.x, v.y)
	b4.objects_mode = FieldBrush.OBJ_BYPASS
	b4.obstacles = obst
	b4.stroke(t, Vector2(10.0, 10.0), 3.0, 1, 1.0, big())
	var same := true
	for v in ins:
		if t.word_at(v.x, v.y) != w0[v]:
			same = false
	check("обход: слой под объектом не меняется", same)
	check("обход: вне следа слой вырос", t.surface_at(node(7.0), node(10.0)) > 1.0)


func _test_level_ceiling() -> void:
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.radius = 4.0
	b.ceiling_fn = Callable(self, "ceil_two")
	b.stroke(f, Vector2(10.0, 10.0), 1.0, 1, 1.0, big())
	for n in 50:
		b.stroke(f, Vector2(10.0, 10.0), 5.0, 0, 0.5, big())
	check("выравнивание: подтягивание вверх упирается в потолок", near(f.surface_at(node(10.0), node(10.0)), 2.0, 0.01), str(f.surface_at(node(10.0), node(10.0))))


func _test_hooks() -> void:
	var f := TerrainField.new()
	var calls := [0]
	var cb := func() -> void: calls[0] += 1
	f.attach_undo(cb)   # вне правки: не хранится
	f.begin_edit()
	f.lay_rect(Rect2(0, 0, 4, 4), 1.0)
	f.attach_undo(cb)
	f.end_edit()
	check("хуки: вне правки привязка игнорируется", calls[0] == 0 and f.can_undo())
	f.undo()
	check("хуки: отмена правки вызывает привязанное действие один раз", calls[0] == 1, str(calls[0]))
	check("хуки: отменять больше нечего", not f.undo())
	# правка без изменений: хук не хранится и в историю не попадает
	f.begin_edit()
	f.attach_undo(cb)
	f.end_edit()
	check("хуки: пустая правка не оставляет следов", not f.can_undo() and calls[0] == 1)
	# история ограничена 50 записями, хуки выравниваются вместе с ней
	var n := [0]
	var cb2 := func() -> void: n[0] += 1
	for k in 60:
		f.begin_edit()
		f.lay_rect(Rect2(float(k) * 0.5, 0, 0.5, 0.5), 1.0)
		f.attach_undo(cb2)
		f.end_edit()
	var undone := 0
	while f.undo():
		undone += 1
	check("хуки: 60 правок, отменяется 50, каждое действие вызвано", undone == TerrainField.MAX_HISTORY and n[0] == undone, "%d %d" % [undone, n[0]])


func _test_support_points() -> void:
	var hull := rect(0, 0, 4, 2)
	var p := FieldObjects.support_points(hull)
	check("опорные точки: 4 вершины, 4 середины, центр", p.size() == 9)
	check("опорные точки: центр в конце", p[8].is_equal_approx(Vector2(2, 1)))
	var polys := FieldObjects.polys_of([{"poly": hull}, {"poly": rect(5, 5, 6, 6)}])
	check("следы: polys_of собирает полигоны", polys.size() == 2 and (polys[1] as PackedVector2Array).size() == 4)
