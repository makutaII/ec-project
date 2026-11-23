extends Node

# XX claude-terra 13.4 W1 (новый файл)
## Тест ядра воды: WaterFill (область заливки, домен, край стола, полосы, стенки). Листов и TGM не нужно:
## занятость ячейки подаётся функцией. Запуск: tests/water_test.tscn, F6, строки PASS / FAIL в Output.

var _fails := 0


func check(name: String, ok: bool, info := "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", info)


## Стол 20 x 10 ячеек: x 0..20, z 0..10. Кольцо берега x 5..10, z 2..6 (20 ячеек) с водоёмом внутри 6..9 x 3..5 (6 ячеек)
func ring_blocker(p: Vector2) -> bool:
	var outer := Rect2(5, 2, 5, 4)
	var inner := Rect2(6, 3, 3, 2)
	return outer.has_point(p) and not inner.has_point(p)


func _ready() -> void:
	var dom := Rect2(0, 0, 20, 10)
	var gd := WaterFill.grid_domain(dom, 1.0)
	check("grid_domain: 20 x 10 ячеек", gd == Rect2i(0, 0, 20, 10), str(gd))
	check("grid_domain: вершины не на сетке сжимают домен", WaterFill.grid_domain(Rect2(0.4, 0.4, 5.2, 3.2), 1.0) == Rect2i(1, 1, 4, 2))

	var pond := WaterFill.fill(Vector2(7.5, 3.5), 2.0, dom, 1.0, ring_blocker)
	check("fill: водоём внутри кольца 3 x 2 = 6 ячеек", pond["ok"] and pond["count"] == 6, str(pond["count"]))
	check("fill: водоём не касается края", pond["ok"] and not pond["touches_edge"])
	check("fill: bounds водоёма", pond["ok"] and pond["bounds"] == Rect2(6, 3, 3, 2), str(pond["bounds"]))

	var out := WaterFill.fill(Vector2(1.5, 1.5), 2.0, dom, 1.0, ring_blocker)
	check("fill: снаружи 200 - 20 = 180 ячеек (водоём внутри кольца не достижим)", out["ok"] and out["count"] == 180, str(out["count"]))
	check("fill: снаружи доходит до края", out["ok"] and out["touches_edge"])

	check("fill: клик на берегу отказ с причиной", not WaterFill.fill(Vector2(5.5, 2.5), 2.0, dom, 1.0, ring_blocker)["ok"]
			and WaterFill.fill(Vector2(5.5, 2.5), 2.0, dom, 1.0, ring_blocker)["why"] != "")
	check("fill: клик за краем стола отказ", not WaterFill.fill(Vector2(25, 5), 2.0, dom, 1.0, ring_blocker)["ok"])
	check("fill: уровень ниже слоя отказ", not WaterFill.fill(Vector2(7.5, 3.5), 0.0, dom, 1.0, ring_blocker)["ok"])

	var empty := func(_p: Vector2) -> bool: return false
	var all := WaterFill.fill(Vector2(10.5, 5.5), 1.0, dom, 1.0, empty)
	check("fill: пустой стол заливается весь (200)", all["ok"] and all["count"] == 200 and all["touches_edge"], str(all["count"]))
	check("fill: предохранитель MAX_CELLS", not WaterFill.fill(Vector2(10.5, 5.5), 1.0, dom, 1.0, empty, 50)["ok"])

	# домен меньше стола: «замёрзла на границе», что за ним, не заливается
	var small := WaterFill.fill(Vector2(10.5, 5.5), 1.0, Rect2(8, 4, 4, 3), 1.0, empty)
	check("fill: домен 4 x 3 даёт 12 ячеек", small["ok"] and small["count"] == 12, str(small["count"]))

	# шаг 2
	var half := WaterFill.fill(Vector2(10.5, 5.5), 1.0, dom, 2.0, empty)
	check("fill: шаг 2 даёт 10 x 5 = 50 ячеек", half["ok"] and half["count"] == 50, str(half["count"]))

	# полосы
	var rn := WaterFill.runs(pond["cells"])
	check("runs: водоём 3 x 2 это две полосы по 3", rn.size() == 2 and rn[0] == Vector3i(3, 6, 9) and rn[1] == Vector3i(4, 6, 9), str(rn))
	var rn2 := WaterFill.runs(out["cells"])
	var total := 0
	for r in rn2:
		total += r.z - r.y
	check("runs: сумма длин полос равна числу ячеек", total == out["count"], "%d / %d" % [total, out["count"]])
	check("runs: строка 2 с кольцом разбита на две полосы", rn2.filter(func(v: Vector3i): return v.x == 2).size() == 2)

	# стенки у края
	var w := WaterFill.edge_walls(all["cells"], all["dom"], 1.0)
	check("edge_walls: периметр стола 2 * (20 + 10) = 60 граней", w.size() == 60, str(w.size()))
	check("edge_walls: водоём внутри без стенок", WaterFill.edge_walls(pond["cells"], pond["dom"], 1.0).is_empty())

	# плавающие сущности: рейкаст видит воду (W4)
	var plain := EntitySetting.new()
	plain.category = &"building"
	var boat := EntitySetting.new()
	boat.category = &"building"
	boat.floats = true
	check("floats: обычный объект воду не видит", not plain.get_pick_layers().has(&"water"))
	check("floats: плавающий видит воду и землю", boat.get_pick_layers().has(&"water") and boat.get_pick_layers().has(&"ground"))
	var tboat := EntitySetting.new()
	tboat.category = &"terrain"
	tboat.floats = true
	check("floats: у категории с одним слоем ground добавляется water", tboat.get_pick_layers() == [&"ground", &"water"], str(tboat.get_pick_layers()))
	tboat.floats = false
	check("floats: выключили, слоёв категории water нет", not tboat.get_pick_layers().has(&"water"))
	check("water_level_at: без воды NO_WATER", TGM.water_level_at(0.0, 0.0) == TGM.NO_WATER)

	_test_field()
	print("ИТОГО: ", "всё PASS" if _fails == 0 else "FAIL: %d" % _fails)


## H6. Вода по полю высот шпатлёвки: яма заливается до уровня, кромка у склона, подкоп берега, ложе трака. Свой TerrainField, без TGM
func _test_field() -> void:
	var dom := Rect2(0, 0, 20, 10)
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 20, 10), 1.0)
	f.erase_rect(Rect2(6, 3, 3, 2))   # яма 3 x 2 ячейки (узлы x 6..9, z 3..5 без слоя)
	f.erase_rect(Rect2(12, 3, 3, 2))  # вторая яма рядом, между ямами берег
	check("ground_top: вне слоя нет поверхности", f.ground_top(6.5, 3.5) == TerrainField.NO_GROUND)
	check("ground_top: на слое его верх", near_f(f.ground_top(1.5, 1.5), 1.0), str(f.ground_top(1.5, 1.5)))
	var blocked := WaterFill.field_blocker(f, 1.0)
	var shore := WaterFill.field_shore(f, 1.0, 1.0)
	check("field_blocker: берег занят, яма свободна", blocked.call(Vector2(1.5, 1.5)) and not blocked.call(Vector2(7.5, 3.5)))
	check("field_blocker: пустое поле не блокирует", not WaterFill.field_blocker(TerrainField.new(), 1.0).is_valid())

	var pond := WaterFill.fill(Vector2(7.5, 3.5), 1.0, dom, 1.0, blocked, WaterFill.MAX_CELLS, Callable(), shore)
	check("поле: яма 3 x 2 заливается до уровня (6 ячеек)", pond["ok"] and pond["count"] == 6, str(pond["count"]))
	check("поле: водоём в яме не касается края", pond["ok"] and not pond["touches_edge"])
	check("поле: кромка 10 ячеек вокруг ямы", (pond["shore"] as Dictionary).size() == 10, str((pond["shore"] as Dictionary).size()))
	check("поле: кромка не входит в область", not (pond["cells"] as Dictionary).has(Vector2i(5, 3)) and (pond["shore"] as Dictionary).has(Vector2i(5, 3)))
	var no_shore := WaterFill.fill(Vector2(7.5, 3.5), 1.0, dom, 1.0, blocked)
	check("поле: без кромки (по умолчанию) shore пуст", no_shore["ok"] and (no_shore["shore"] as Dictionary).is_empty())

	check("поле: клик на берегу отказ", not WaterFill.fill(Vector2(1.5, 1.5), 1.0, dom, 1.0, blocked)["ok"])
	var over := WaterFill.fill(Vector2(1.5, 1.5), 2.0, dom, 1.0, WaterFill.field_blocker(f, 2.0), WaterFill.MAX_CELLS, Callable(), WaterFill.field_shore(f, 2.0, 1.0))
	check("поле: выше слоя заливается весь стол (200 ячеек, до края)", over["ok"] and over["count"] == 200 and over["touches_edge"], str(over["count"]))
	check("поле: у залитого стола кромки нет", (over["shore"] as Dictionary).is_empty())

	# подкоп берега: канал между ямами, вода растекается во вторую яму
	var second := WaterFill.fill(Vector2(13.5, 3.5), 1.0, dom, 1.0, blocked)
	check("поле: вторая яма отдельно 6 ячеек", second["ok"] and second["count"] == 6, str(second["count"]))
	f.erase_rect(Rect2(9, 3, 3, 2))
	var joined := WaterFill.fill(Vector2(7.5, 3.5), 1.0, dom, 1.0, WaterFill.field_blocker(f, 1.0), WaterFill.MAX_CELLS, Callable(), WaterFill.field_shore(f, 1.0, 1.0))
	check("поле: прокопали берег, вода заняла обе ямы и канал (18 ячеек)", joined["ok"] and joined["count"] == 18, str(joined["count"]))
	f.lay_rect(Rect2(9, 3, 3, 2), 1.0)
	var closed := WaterFill.fill(Vector2(7.5, 3.5), 1.0, dom, 1.0, WaterFill.field_blocker(f, 1.0))
	check("поле: насыпали обратно, вода в первой яме (6 ячеек)", closed["ok"] and closed["count"] == 6, str(closed["count"]))

	# слой тоньше: яма не дошла до края
	var g := TerrainField.new()
	g.lay_rect(Rect2(0, 0, 20, 10), 3.0)
	check("поле: слой выше уровня воды не заливается", not WaterFill.fill(Vector2(7.5, 3.5), 2.0, dom, 1.0, WaterFill.field_blocker(g, 2.0))["ok"])

	# ложе трака: траншея в слое держит воду
	var h := TerrainField.new()
	h.lay_rect(Rect2(0, 0, 20, 10), 3.0)
	var merged := {}
	for j in range(6, 11):
		for i in range(12, 19):
			merged[Vector2i(i, j)] = Vector3(0.0, 0.0, 1.0)
	h.set_bed(FieldBed.to_chunks(merged, Callable(h, "has_layer")))
	var trench := WaterFill.fill(Vector2(7.5, 3.5), 1.0, dom, 1.0, WaterFill.field_blocker(h, 1.0), WaterFill.MAX_CELLS, Callable(), WaterFill.field_shore(h, 1.0, 1.0))
	check("ложе: траншея трака заливается (6 ячеек)", trench["ok"] and trench["count"] == 6, str(trench["count"]))
	check("ложе: у траншеи кромка", not (trench["shore"] as Dictionary).is_empty())
	h.set_bed({})
	check("ложе: после снятия ложа воды нет", not WaterFill.fill(Vector2(7.5, 3.5), 1.0, dom, 1.0, WaterFill.field_blocker(h, 1.0))["ok"])


func near_f(a: float, b: float) -> bool:
	return absf(a - b) < 0.001
