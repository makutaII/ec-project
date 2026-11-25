extends Node

# XX claude-terra 13.14 H5 (новый файл)
## Тест автоложа трака (FieldBed и TerrainField.set_bed): выемка в холме, насыпь над низиной, эстакада без ложа,
## возврат рельефа после снятия ложа, сигнал bed_changed, переопределение типа, фиксация ложа в поле (FieldBed.bake, H5b), трак с флагом U без ложа (H7b), режим ложа «Только полоса» (H5c).
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
	_test_bake()
	_test_tunnel()
	_test_strip()
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


func table_polys(r := Rect2(0, 0, 40, 40)) -> Array:
	return [TerrainField._rect_poly(r)]


func shown(f: TerrainField, x: float, z: float) -> float:
	return f.shown_surface_at(node(x), node(z))


## H5b. Фиксация ложа: выемка и насыпь становятся данными поля, повтор ничего не меняет, отмена возвращает рельеф,
## сдвинутый трак считается от зафиксированного, вне стола и под листом поле не пишется
func _test_bake() -> void:
	# выемка
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 3.0)
	var n := FieldBed.bake(f, bed_of(f, straight(0.0)), table_polys(), Callable())
	check("фиксация выемки: узлы записаны", n > 0, str(n))
	check("фиксация выемки: поле под траком срезано", near(f.surface_at(node(20.0), node(20.0)), 0.0), str(f.surface_at(node(20.0), node(20.0))))
	check("фиксация выемки: откос записан", near(f.surface_at(node(20.0), node(23.5)), 1.0), str(f.surface_at(node(20.0), node(23.5))))
	check("фиксация выемки: далеко от трака поле прежнее", near(f.surface_at(node(20.0), node(32.0)), 3.0))
	# после фиксации ложе трака ничего не меняет и показ совпадает с полем
	var b2 := bed_of(f, straight(0.0))
	f.set_bed(FieldBed.to_chunks(FieldBed.merge([b2]), Callable(f, "has_layer")))
	check("фиксация выемки: показ с ложем равен полю", near(shown(f, 20.0, 20.0), 0.0, 0.01) and near(shown(f, 20.0, 23.5), 1.0, 0.01))
	check("фиксация выемки: повтор ничего не меняет", FieldBed.bake(f, b2, table_polys(), Callable()) == 0)
	# трак сдвинули: старая выемка осталась рельефом, ложе нового положения считается от неё
	f.set_bed({})
	var moved := bed_of(f, straight(0.0, 10.0, 30.0, 30.0))
	f.set_bed(FieldBed.to_chunks(FieldBed.merge([moved]), Callable(f, "has_layer")))
	check("сдвиг трака: старая выемка осталась", near(shown(f, 20.0, 20.0), 0.0, 0.01), str(shown(f, 20.0, 20.0)))
	check("сдвиг трака: новая выемка на новом месте", near(shown(f, 20.0, 30.0), 0.0, 0.01), str(shown(f, 20.0, 30.0)))
	# отмена
	f.set_bed({})
	check("отмена: правка фиксации откатывается одним шагом", f.undo() and near(f.surface_at(node(20.0), node(20.0)), 3.0) and near(f.surface_at(node(20.0), node(23.5)), 3.0))

	# насыпь: тип «каменистая» в полосе, откос без слоя тоже каменистый
	var g := TerrainField.new()
	g.lay_rect(Rect2(0, 0, 40, 40), 0.5)
	var nf := FieldBed.bake(g, bed_of(g, straight(2.0)), table_polys(), Callable())
	check("фиксация насыпи: узлы записаны", nf > 0)
	check("фиксация насыпи: под траком высота ложа", near(g.surface_at(node(20.0), node(20.0)), 2.0), str(g.surface_at(node(20.0), node(20.0))))
	check("фиксация насыпи: полоса каменистая", g.type_at(node(20.0), node(20.0)) == TerrainField.ROCKY)
	check("фиксация насыпи: откос ниже полосы", g.surface_at(node(20.0), node(23.5)) < 2.0 and g.surface_at(node(20.0), node(23.5)) > 0.5)

	# вне стола не пишется
	var h := TerrainField.new()
	h.lay_rect(Rect2(0, 0, 40, 40), 3.0)
	FieldBed.bake(h, bed_of(h, straight(0.0)), table_polys(Rect2(20, 0, 20, 40)), Callable())
	check("вне стола: узел за контуром не тронут", near(h.surface_at(node(15.0), node(20.0)), 3.0))
	check("вне стола: узел внутри контура записан", near(h.surface_at(node(25.0), node(20.0)), 0.0))

	# потолок: слой не доходит до листа над узлом
	var k := TerrainField.new()
	k.lay_rect(Rect2(0, 0, 40, 40), 0.5)
	var low := func(r: Rect2i) -> PackedFloat32Array:
		var a := PackedFloat32Array()
		a.resize(r.size.x * r.size.y)
		a.fill(1.5)
		return a
	FieldBed.bake(k, bed_of(k, straight(2.0)), table_polys(), low)
	check("потолок: насыпь не выше низа листа", k.surface_at(node(20.0), node(20.0)) <= 1.5 + 0.001, str(k.surface_at(node(20.0), node(20.0))))
	check("потолок: до потолка поднялась", k.surface_at(node(20.0), node(20.0)) > 1.4)

	# нет ложа: ничего
	check("пустое ложе: нечего писать", FieldBed.bake(TerrainField.new(), {}, table_polys(), Callable()) == 0)


## H7b. Трак с флагом U ложа не получает (TerrainManager.bed_refresh пропускает его), автотоннеля в FieldBed больше нет.
## Здесь проверяем то, что видно без сцены: у параметров ложа нет тоннельных полей, а обычный трак по-прежнему режет холм целиком
func _test_tunnel() -> void:
	var p := params()
	check("H7b: в параметрах ложа нет тоннельных полей", not p.has("tunnel_run") and not p.has("roof") and not p.has("body"), str(p.keys()))
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	f.lay_rect(Rect2(20, 0, 20, 40), 8.0)
	var s := straight(1.0, 4.0, 36.0)
	var b := bed_of(f, s)
	check("H7b: обычный трак режет холм (в холме ложе есть)", b.has(Vector2i(node(30.0), node(20.0))))
	check("H7b: ложе в холме на высоте балласта", near((b[Vector2i(node(30.0), node(20.0))] as Vector3).y, 1.0), str(b.get(Vector2i(node(30.0), node(20.0)))))


## H5c. Режим «Только полоса»: тот же расчёт с почти вертикальным откосом. Полоса (балласт 2 ю и плечо 1 ю, до 2 ю от оси) режется
## и там, и там; за её краем «Авто» (откос 1,5) ещё режет холм, «Только полоса» (откос 0,05) его не трогает
func _test_strip() -> void:
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	f.lay_rect(Rect2(20, 0, 20, 40), 3.0)
	var s := straight(1.0, 4.0, 36.0)
	var auto := bed_of(f, s)
	var strip := FieldBed.build_track(s, Callable(f, "surface_at"), Callable(f, "has_layer"), FieldBed.params(1.0, 0.05, 3.0, 6.0))
	var edge := Vector2i(node(30.0), node(22.0))   # на краю полосы (2 ю от оси)
	var out := Vector2i(node(30.0), node(22.5))   # на 0,5 ю за краем
	check("полоса: узел на краю полосы срезан до ложа", strip.has(edge) and near((strip[edge] as Vector3).y, 1.0), str(strip.get(edge)))
	check("полоса: за краем холм не тронут (борт почти вертикальный)", not strip.has(out) or near((strip[out] as Vector3).y, 3.0), str(strip.get(out)))
	check("авто: за краем полосы откос ещё режет холм", auto.has(out) and (auto[out] as Vector3).y < 2.0, str(auto.get(out)))
	check("полоса: в самой полосе ложе то же, что у «Авто»", strip.has(Vector2i(node(30.0), node(20.0))) and near((strip[Vector2i(node(30.0), node(20.0))] as Vector3).y, 1.0))
	check("откос не меньше FieldBed.MIN_RUN", is_equal_approx(float(FieldBed.params(1.0, 0.0, 3.0, 6.0)["run"]), FieldBed.MIN_RUN))
	# насыпь над низиной с тем же крутым бортом: плечо поднято, за краем земля цела
	var g := TerrainField.new()
	g.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	var hi := straight(3.0)
	var fs := FieldBed.build_track(hi, Callable(g, "surface_at"), Callable(g, "has_layer"), FieldBed.params(1.0, 0.05, 3.0, 6.0))
	var fe := Vector2i(node(20.0), node(22.0))
	check("полоса: насыпь в полосе поднята до ложа (3)", fs.has(fe) and near((fs[fe] as Vector3).y, 3.0), str(fs.get(fe)))
	check("полоса: за краем насыпи земля цела", not fs.has(Vector2i(node(20.0), node(22.5))) or near((fs[Vector2i(node(20.0), node(22.5))] as Vector3).y, 1.0), str(fs.get(Vector2i(node(20.0), node(22.5)))))
