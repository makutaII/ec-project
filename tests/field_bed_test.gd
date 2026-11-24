extends Node

# XX claude-terra 13.14 H5 (новый файл)
## Тест автоложа трака (FieldBed и TerrainField.set_bed): выемка в холме, насыпь над низиной, эстакада без ложа,
## возврат рельефа после снятия ложа, сигнал bed_changed, переопределение типа, фиксация ложа в поле (FieldBed.bake, H5b), тоннельный трак в холме с порталами (H7).
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


func tunnel_params() -> Dictionary:
	return FieldBed.params(1.0, 1.5, 3.0, 6.0, 2.0, 1.0, 0.5)   # габарит 2 ю над низом балласта, свод не тоньше 1 ю, стенки выемки круче (0,5)


func tunnel_bed(f: TerrainField, s: Array) -> Dictionary:
	return FieldBed.build_track(s, Callable(f, "surface_at"), Callable(f, "has_layer"), tunnel_params(), true)


func max_x(b: Dictionary) -> float:
	var m := -INF
	for key: Vector2i in b:
		m = maxf(m, float(key.x) * TerrainField.STEP)
	return m


## H7. Тоннельный трак в холме: под высоким холмом ложа нет (холм свод), перед ним открытая выемка, на её торце портал; низкий холм режется целиком
func _test_tunnel() -> void:
	# холм с x = 20 (8 слоёв) над равниной 1 слой; трак на высоте 1 входит в холм
	var f := TerrainField.new()
	f.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	f.lay_rect(Rect2(20, 0, 20, 40), 8.0)
	var s := straight(1.0, 4.0, 36.0)
	var closed := FieldBed.tunnel_closed(s, Callable(f, "surface_at"), tunnel_params())
	# образцы x = 4, 6, ..., 36: закрыты с x = 20 (индекс 8) и дальше
	check("тоннель: до холма образцы открыты", closed[0] == 0 and closed[7] == 0 and closed[8] == 1)
	check("тоннель: в холме образцы закрыты", closed[8] == 1 and closed[16] == 1)
	var b := tunnel_bed(f, s)
	check("тоннель: перед холмом ложе есть (полоса)", b.has(Vector2i(node(10.0), node(20.0))))
	check("тоннель: в холме ложа нет", not b.has(Vector2i(node(26.0), node(20.0))) and not b.has(Vector2i(node(30.0), node(20.0))))
	check("тоннель: торец не закруглён, за порталом (x = 19,5) земля цела", max_x(b) <= 19.501, str(max_x(b)))
	check("тоннель: ложе доходит до самого холма (до x = 19,5)", max_x(b) >= 19.499, str(max_x(b)))
	var pl := FieldBed.portals(s, Callable(f, "surface_at"), tunnel_params())
	check("тоннель: один портал у входа в холм", pl.size() == 1, str(pl.size()))
	if pl.size() == 1:
		var p: Dictionary = pl[0]
		check("тоннель: портал у самого холма (x = 19,5, холм с x = 20), а не на образце в стороне", (p["p"] as Vector2).is_equal_approx(Vector2(19.5, 20.0)), str(p["p"]))
		check("тоннель: лицевая плоскость оголовка на 0,5 ю наружу от портала", (p["front"] as Vector2).is_equal_approx(Vector2(19.0, 20.0)), str(p["front"]))
		var w: Dictionary = p["wall"]
		var us: PackedFloat32Array = w["u"]
		var bs: PackedFloat32Array = w["bottom"]
		var ts: PackedFloat32Array = w["top"]
		var c0 := -1
		for i in us.size():
			if absf(us[i]) < 0.001:
				c0 = i
		check("оголовок: колонка на оси от дна выемки до земли холма", c0 >= 0 and near(bs[c0], 1.0) and near(ts[c0], 8.0), "c0=%d" % c0)
		check("оголовок: по краям сходит на нет", us.size() >= 5 and ts[0] - bs[0] < FieldBed.WALL_MIN and ts[us.size() - 1] - bs[us.size() - 1] < FieldBed.WALL_MIN,
				str(us.size()))
		check("тоннель: портал смотрит из холма в выемку", (p["out"] as Vector2).is_equal_approx(Vector2(-1.0, 0.0)), str(p["out"]))
		var mesh := TunnelPortal.make_node(&"", p["front"], p["out"], 3.0, 1.0, 3.0, 8.0, true, p["wall"])
		check("оголовок: узел портала с каменным оголовком, зевом и без рамки", mesh.get_node_or_null("Headwall") != null and mesh.get_child_count() == 2, str(mesh.get_child_count()))
		mesh.free()
		check("тоннель: проём от низа балласта на высоту габарита", near(p["floor"], 1.0) and near(p["vault"], 3.0), "%s %s" % [p["floor"], p["vault"]])
		check("тоннель: у портала ширина балласта и высота земли в холме", near(p["width"], 2.0) and near(p["top"], 8.0), "%s %s" % [p["width"], p["top"]])

	# стенки выемки у тоннеля круче: низкий холм (3 слоя), край выемки на 2,5 ю от оси есть, на 3,5 ю нет (обычный откос 1,5 дал бы и там)
	var low_t := TerrainField.new()
	low_t.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	low_t.lay_rect(Rect2(20, 0, 20, 40), 3.0)
	var steep := tunnel_bed(low_t, s)
	var soft := FieldBed.build_track(s, Callable(low_t, "surface_at"), Callable(low_t, "has_layer"), tunnel_params(), false)
	var k25 := Vector2i(node(30.0), node(22.5))
	var k35 := Vector2i(node(30.0), node(23.5))
	check("тоннель: крутая стенка выемки у края (2,5 ю от оси, высота 2)", steep.has(k25) and near((steep[k25] as Vector3).y, 2.0), str(steep.get(k25)))
	check("тоннель: на 3,5 ю от оси выемки уже нет (стенка крутая)", not steep.has(k35))
	check("обычный трак: тот же откос положе (на 3,5 ю выемка есть)", soft.has(k35), str(soft.get(k35)))

	# тот же трак без тоннеля режет холм целиком
	var plain := FieldBed.build_track(s, Callable(f, "surface_at"), Callable(f, "has_layer"), tunnel_params(), false)
	check("без тоннеля: ложе идёт и в холме", plain.has(Vector2i(node(30.0), node(20.0))))

	# низкий холм (3 слоя) ниже габарита и свода: открыт на всю длину, режется выемкой, порталов нет
	var low := TerrainField.new()
	low.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	low.lay_rect(Rect2(20, 0, 20, 40), 3.0)
	var lb := tunnel_bed(low, s)
	check("низкий холм: выемка по всей длине", lb.has(Vector2i(node(30.0), node(20.0))) and near((lb[Vector2i(node(30.0), node(20.0))] as Vector3).y, 1.0))
	check("низкий холм: порталов нет", FieldBed.portals(s, Callable(low, "surface_at"), tunnel_params()).is_empty())

	# трак целиком под холмом: ложа и порталов нет
	var all := TerrainField.new()
	all.lay_rect(Rect2(0, 0, 40, 40), 8.0)
	check("весь трак под холмом: ложа нет", tunnel_bed(all, s).is_empty())
	check("весь трак под холмом: порталов нет", FieldBed.portals(s, Callable(all, "surface_at"), tunnel_params()).is_empty())

	# холм посередине: два портала, оба смотрят наружу
	var mid := TerrainField.new()
	mid.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	mid.lay_rect(Rect2(14, 0, 12, 40), 8.0)
	var pm := FieldBed.portals(s, Callable(mid, "surface_at"), tunnel_params())
	check("холм посередине: два портала", pm.size() == 2, str(pm.size()))
	if pm.size() == 2:
		var xs: Array = []
		for d: Dictionary in pm:
			xs.append("%.2f:%d" % [(d["p"] as Vector2).x, roundi((d["out"] as Vector2).x)])
		xs.sort()
		check("холм посередине: у входа x = 13,5 наружу влево, у выхода x = 26,25 наружу вправо", xs == ["13.50:-1", "26.25:1"], str(xs))
	var mb := tunnel_bed(mid, s)
	check("холм посередине: ложе по обе стороны холма, в холме нет", mb.has(Vector2i(node(6.0), node(20.0))) and mb.has(Vector2i(node(32.0), node(20.0)))
			and not mb.has(Vector2i(node(20.0), node(20.0))))

	# боковой склон ниже свода: трак на краю холма остаётся открытым
	var edge := TerrainField.new()
	edge.lay_rect(Rect2(0, 0, 40, 40), 1.0)
	edge.lay_rect(Rect2(20, 0, 20, 20.5), 8.0)   # холм кончается у оси трака: правый край z = 21 на равнине
	var es := FieldBed.tunnel_closed(s, Callable(edge, "surface_at"), tunnel_params())
	check("край холма: сбоку земля ниже свода, образец открыт", es[10] == 0, str(es[10]))
