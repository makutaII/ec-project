extends Node

# XX claude-terra 13.14 H5 (новый файл)
## Тест автоложа трака (FieldBed и TerrainField.set_bed): выемка в холме, насыпь над низиной, эстакада без ложа,
## возврат рельефа после снятия ложа, сигнал bed_changed, переопределение типа.
## Запуск: открыть tests/field_bed_test.tscn и нажать F6. Результат в Output: строки PASS / FAIL и итог.
## Проверки на собственном TerrainField без сцены игры (образцы трака задаются вручную).

var _fails := 0
var _bed_signals: Array = []


func check(name: String, ok: bool, info := "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", info)


func near(a: float, b: float, eps := 0.001) -> bool:
	return absf(a - b) <= eps


func node(x: float) -> int:
	return roundi(x / TerrainField.STEP)


## Прямой трак вдоль X на высоте y, ось z = 20, балласт шириной 2
func straight(y: float, x0 := 10.0, x1 := 30.0, z := 20.0) -> Array:
	var res: Array = []
	var x := x0
	while x <= x1 + 0.001:
		res.append({"l": Vector2(x, z - 1.0), "r": Vector2(x, z + 1.0), "y": y})
		x += 2.0
	return res


func params() -> Dictionary:
	return FieldBed.params(1.0, 1.5, 3.0, 6.0)


func bed_of(f: TerrainField, s: Array) -> Dictionary:
	return FieldBed.build_track(s, Callable(f, "surface_at"), Callable(f, "has_layer"), params())


func _ready() -> void:
	_test_cut()
	_test_fill()
	_test_viaduct()
	_test_no_field()
	_test_signal_and_types()
	_test_merge()
	print("ИТОГ: ", "ВСЕ ПРОШЛИ" if _fails == 0 else "ПРОВАЛЕНО %d" % _fails)


func _on_bed(keys: Array) -> void:
	_bed_signals.append(keys.size())


func _test_cut() -> void:
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 3.0)
	var b := bed_of(f, straight(0.0))
	check("выемка: ложе посчитано", not b.is_empty())
	f.set_bed(FieldBed.to_chunks(FieldBed.merge([b]), Callable(f, "has_layer")))
	var c := Vector2i(node(20.0), node(20.0))
	check("выемка: под траком земля срезана до ложа", near(f.shown_surface_at(c.x, c.y), 0.0), str(f.shown_surface_at(c.x, c.y)))
	check("выемка: поле само не изменилось", near(f.surface_at(c.x, c.y), 3.0))
	# край полосы: балласт 1 + плечо 1 = 2 ю от оси; на расстоянии 3,5 ю откос поднялся на 1 ю (run 1,5)
	check("выемка: откос поднимается от ложа", near(f.shown_surface_at(c.x, node(23.5)), 1.0), str(f.shown_surface_at(c.x, node(23.5))))
	check("выемка: далеко от трака земля без изменений", near(f.shown_surface_at(c.x, node(32.0)), 3.0))
	check("выемка: за охватом откоса у конца трака земля без изменений", near(f.shown_surface_at(node(1.0), c.y), 3.0))
	f.set_bed({})
	check("выемка: после снятия ложа рельеф вернулся", near(f.shown_surface_at(c.x, c.y), 3.0) and not f.has_bed())


func _test_fill() -> void:
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 0.5)
	var b := bed_of(f, straight(2.0))
	f.set_bed(FieldBed.to_chunks(FieldBed.merge([b]), Callable(f, "has_layer")))
	var c := Vector2i(node(20.0), node(20.0))
	check("насыпь: над низиной земля поднята до ложа", near(f.shown_surface_at(c.x, c.y), 2.0), str(f.shown_surface_at(c.x, c.y)))
	check("насыпь: откос опускается", near(f.shown_surface_at(c.x, node(23.5)), 1.0), str(f.shown_surface_at(c.x, node(23.5))))
	check("насыпь: поле само не изменилось", near(f.surface_at(c.x, c.y), 0.5))
	f.set_bed({})
	check("насыпь: после снятия ложа низина вернулась", near(f.shown_surface_at(c.x, c.y), 0.5))
	# трак на уровне земли: полоса помечена (щебёнка), высота та же
	var g := TerrainField.new()
	g.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	var o := bed_of(g, straight(1.0))
	g.set_bed(FieldBed.to_chunks(FieldBed.merge([o]), Callable(g, "has_layer")))
	check("полоса: на уровне земли высота не меняется", near(g.shown_surface_at(node(20.0), node(20.0)), 1.0))
	check("полоса: тип узла полосы помечен", g.chunk_bed(TerrainField.key_of(node(20.0), node(20.0))).size() == 2)
	var ty := ((g.chunk_bed(TerrainField.key_of(node(20.0), node(20.0)))["t"]) as PackedByteArray)[TerrainField.index_in_chunk(node(20.0), node(20.0))]
	check("полоса: каменистая и без шума (тип | бит 4)", ty == (FieldBed.TYPE_ROCKY | FieldBed.FLAT_BIT), str(ty))


func _test_viaduct() -> void:
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 0.5)
	var b := bed_of(f, straight(5.0))
	check("эстакада: выше предела насыпи ложа нет", b.is_empty(), str(b.size()))


func _test_no_field() -> void:
	var f := TerrainField.new()
	var b := bed_of(f, straight(1.0))
	check("нет поля: ложа нет", b.is_empty())
	# слой есть только сбоку от трака: касание даёт насыпь
	var g := TerrainField.new()
	g.lay_rect(Rect2(0, 0, 40, 18), 0.5)
	var o := bed_of(g, straight(2.0))
	check("касание соседним слоем даёт насыпь", o.has(Vector2i(node(20.0), node(20.0))))
	check("слой вдали от трака не даёт насыпи", bed_of(TerrainField.new(), straight(2.0)).is_empty())


func _test_signal_and_types() -> void:
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 3.0)
	f.bed_changed.connect(_on_bed)
	var chunks := FieldBed.to_chunks(FieldBed.merge([bed_of(f, straight(0.0))]), Callable(f, "has_layer"))
	f.set_bed(chunks)
	check("сигнал: первое ложе сообщает чанки", _bed_signals.size() == 1 and _bed_signals[0] > 0)
	f.set_bed(FieldBed.to_chunks(FieldBed.merge([bed_of(f, straight(0.0))]), Callable(f, "has_layer")))
	check("сигнал: то же ложе второй раз не сообщает ничего", _bed_signals.size() == 1)
	f.set_bed({})
	check("сигнал: снятие ложа сообщает прежние чанки", _bed_signals.size() == 2 and _bed_signals[1] > 0)
	check("ложе: вне него BED_NONE", f.bed_height_at(0, 0) == TerrainField.BED_NONE)
	# тип откоса без слоя: каменистая (насыпь над пустым местом у края слоя)
	var g := TerrainField.new()
	g.lay_rect(Rect2(0, 0, 40, 18), 0.5)
	var ch := FieldBed.to_chunks(FieldBed.merge([bed_of(g, straight(2.0))]), Callable(g, "has_layer"))
	g.set_bed(ch)
	var bed := g.chunk_bed(TerrainField.key_of(node(20.0), node(20.0)))
	check("насыпь над пустым местом: узел получает каменистый тип", not bed.is_empty() and ((bed["t"]) as PackedByteArray)[TerrainField.index_in_chunk(node(20.0), node(20.0))] != FieldBed.NO_TYPE)


func _test_merge() -> void:
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 3.0)
	var a := bed_of(f, straight(0.0, 10.0, 30.0, 20.0))
	var b := bed_of(f, straight(1.0, 10.0, 30.0, 23.0))
	var m := FieldBed.merge([a, b])
	var k := Vector2i(node(20.0), node(21.0))
	check("слияние: узел берёт ближайший трак", a.has(k) and b.has(k) and near((m[k] as Vector3).y, (a[k] as Vector3).y if (a[k] as Vector3).x <= (b[k] as Vector3).x else (b[k] as Vector3).y))
