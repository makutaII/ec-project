extends Node

# XX claude-terra 13.14 H1 (новый файл)
## Тест поля высот шпатлёвки (TerrainField, FieldCollision, связка с TGM). Запуск: открыть tests/field_test.tscn и нажать F6.
## Результат в Output: строки PASS / FAIL и итог. Данные проверяются на собственном экземпляре TerrainField с заданным полом,
## связка со столом на TGM.field (после проверок поле очищается).

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


## Пол: ступень 2 ю при x >= 10 (как лист шириной от 10 вправо), иначе 0
func step_floor(x: float, _z: float) -> float:
	return 2.0 if x >= 10.0 - 0.001 else 0.0


func _ready() -> void:
	_test_data()
	_test_floor()
	_test_history()
	_test_save()
	_test_clip()
	await _test_collision()
	_test_tgm()
	print("ИТОГ: ", "ВСЕ ПРОШЛИ" if _fails == 0 else "ПРОВАЛЕНО %d" % _fails)


func _test_data() -> void:
	var f := TerrainField.new()
	check("данные: пустое поле", f.is_empty() and f.layer_node_count() == 0)
	var n := f.lay_polygon(rect(0, 0, 4, 4), 1.0)
	# граница входит: узлы 0..8 по обеим осям, 81 узел
	check("данные: прямоугольник 4x4 ю даёт 81 узел", n == 81 and f.layer_node_count() == 81, str(n))
	check("данные: толщина в узле равна 1 слою", near(f.layers_at(2, 2), 1.0) and near(f.thickness(2, 2), 1.0))
	check("данные: вне прямоугольника слоя нет", not f.has_layer(9, 0) and not f.has_layer(-1, 0))
	check("данные: поверхность над полом 0 равна 1", near(f.surface_at(4, 4), 1.0))
	check("данные: sample в центре ячейки", near(f.sample(1.25, 1.25), 1.0))
	check("данные: covered у края", f.covered(4.2, 2.0) and not f.covered(6.0, 2.0))
	# повторная укладка не тоньше: ничего не меняется
	check("данные: тот же слой повторно 0 узлов", f.lay_polygon(rect(0, 0, 4, 4), 1.0) == 0)
	check("данные: более тонкий слой не истончает", f.lay_polygon(rect(0, 0, 4, 4), 0.5) == 0 and near(f.layers_at(2, 2), 1.0))
	check("данные: более толстый слой утолщает", f.lay_polygon(rect(0, 0, 2, 2), 2.0) == 25 and near(f.layers_at(1, 1), 2.0))
	# толщина считается от layer_height
	f.layer_height = 2.0
	check("данные: толщина в ю = слои * layer_height", near(f.thickness(1, 1), 4.0))
	f.layer_height = 1.0
	# квантование 1/128 слоя
	var g := TerrainField.new()
	g.lay_polygon(rect(0, 0, 1, 1), 0.3)
	check("данные: квантование 1/128", near(g.layers_at(0, 0), roundf(0.3 * 128.0) / 128.0, 1e-6))
	# стирание
	check("данные: стирание снимает слой", f.erase_polygon(rect(0, 0, 2, 2)) == 25 and not f.has_layer(1, 1) and f.has_layer(6, 6))
	f.erase_polygon(rect(-1, -1, 10, 10))
	check("данные: после стирания всего поле пусто и чанков нет", f.is_empty() and f.chunk_keys().is_empty())
	# через границу чанка (узел 16 = 8 ю) и отрицательные координаты
	var h := TerrainField.new()
	h.lay_polygon(rect(-1, -1, 9, 9), 1.0)
	check("данные: слой через границу чанков и отрицательные узлы", h.has_layer(-2, -2) and h.has_layer(18, 18) and h.has_layer(0, 0) and not h.has_layer(19, 19))
	check("данные: девять чанков (-1..1 по обеим осям)", h.chunk_keys().size() == 9, str(h.chunk_keys().size()))
	# треугольник: узлы только внутри
	var t := TerrainField.new()
	t.lay_polygon(PackedVector2Array([Vector2(0, 0), Vector2(4, 0), Vector2(0, 4)]), 1.0)
	check("данные: треугольник, узел внутри", t.has_layer(2, 2) and t.has_layer(0, 0))
	check("данные: треугольник, узел снаружи", not t.has_layer(7, 7) and not t.has_layer(6, 4))
	check("данные: вырожденный полигон ничего не делает", t.lay_polygon(PackedVector2Array([Vector2(0, 0), Vector2(1, 1)]), 1.0) == 0)


func _test_floor() -> void:
	var f := TerrainField.new()
	f.floor_fn = Callable(self, "step_floor")
	f.lay_polygon(rect(8, 0, 12, 2), 1.0)
	check("пол: узел на столе, поверхность 1", near(f.floor_at(16, 0), 0.0) and near(f.surface_at(16, 0), 1.0))
	check("пол: узел на листе, пол 2, поверхность 3", near(f.floor_at(20, 0), 2.0) and near(f.surface_at(20, 0), 3.0))
	check("пол: относительная толщина едет вместе с полом", near(f.thickness(20, 0), f.thickness(16, 0)))
	# узел без чанка: пол считается напрямую (карта коллизии берёт крайний ряд у соседа)
	var e := TerrainField.new()
	e.floor_fn = Callable(self, "step_floor")
	e.lay_polygon(rect(6, 0, 7.5, 2), 1.0)
	check("пол: узел в отсутствующем чанке берётся из floor_fn", e.chunk_keys().size() == 1 and near(e.floor_at(20, 0), 2.0))
	# пол изменился (лист убрали): пересчёт
	f.floor_fn = Callable()
	var got := []
	f.changed.connect(func(keys: Array) -> void: got.append(keys))
	f.floor_fn = func(_x: float, _z: float) -> float: return 5.0
	f.refresh_floor(Rect2(7, -1, 6, 4))
	check("пол: refresh_floor поднял пол", near(f.floor_at(20, 0), 5.0) and near(f.surface_at(20, 0), 6.0))
	check("пол: refresh_floor сообщил changed", got.size() == 1)
	got.clear()
	f.refresh_floor(Rect2(7, -1, 6, 4))
	check("пол: повтор без изменений тихий", got.is_empty())
	# пол не хранится в сейве
	var d := f.save_data()
	var g := TerrainField.new()
	g.floor_fn = func(_x: float, _z: float) -> float: return 0.5
	g.load_data(d)
	check("пол: после загрузки считается заново", near(g.floor_at(20, 0), 0.5))


func _test_history() -> void:
	var f := TerrainField.new()
	check("отмена: нечего отменять", not f.can_undo() and not f.undo())
	f.lay_polygon(rect(0, 0, 4, 4), 1.0)
	f.lay_polygon(rect(2, 2, 6, 6), 2.0)
	check("отмена: две правки в истории", f.can_undo())
	check("отмена: вторая правка отменена", f.undo() and near(f.layers_at(10, 10), 0.0) and near(f.layers_at(8, 8), 1.0) and near(f.layers_at(2, 2), 1.0))
	check("отмена: первая правка отменена", f.undo() and f.is_empty())
	check("отмена: история пуста", not f.can_undo())
	# вложенные begin/end считаются одной правкой
	f.begin_edit()
	f.lay_polygon(rect(0, 0, 2, 2), 1.0)
	f.lay_polygon(rect(10, 10, 12, 12), 1.0)
	f.end_edit()
	check("отмена: вложенная правка одна", f.undo() and f.is_empty() and not f.can_undo())
	# пустая правка в историю не попадает
	f.lay_polygon(rect(0, 0, 2, 2), 1.0)
	f.lay_polygon(rect(0, 0, 2, 2), 1.0)
	check("отмена: пустая правка не пишется", f.undo() and f.is_empty() and not f.can_undo())
	# предел истории
	for i in range(TerrainField.MAX_HISTORY + 10):
		f.lay_polygon(rect(0, 0, 1, 1), 1.0 + float(i) * 0.01)
	var cnt := 0
	while f.undo():
		cnt += 1
	check("отмена: история не длиннее MAX_HISTORY", cnt == TerrainField.MAX_HISTORY, str(cnt))
	# отмена стирания возвращает слой
	var g := TerrainField.new()
	g.lay_polygon(rect(0, 0, 4, 4), 1.5)
	g.erase_polygon(rect(0, 0, 4, 4))
	check("отмена: стирание отменяется", g.is_empty() and g.undo() and near(g.layers_at(3, 3), 1.5))


func _test_save() -> void:
	var f := TerrainField.new()
	check("сейв: пустое поле даёт пустой словарь", f.save_data().is_empty())
	f.lay_polygon(rect(-3, -3, 20, 12), 1.25)
	f.lay_polygon(rect(0, 0, 3, 3), 7.5)
	var d := f.save_data()
	check("сейв: версия и чанки", int(d.get("v", 0)) == TerrainField.FORMAT and (d["chunks"] as Array).size() == f.chunk_keys().size())
	var g := TerrainField.new()
	g.load_data(d)
	var same := g.chunk_keys().size() == f.chunk_keys().size()
	for key: Vector2i in f.chunk_keys():
		same = same and g.chunk_words(key) == f.chunk_words(key)
	check("сейв: слова чанков совпали после загрузки", same)
	check("сейв: узлов столько же", g.layer_node_count() == f.layer_node_count())
	g.load_data({})
	check("сейв: пустой словарь очищает поле", g.is_empty())
	# размер: гладкий слой на 40x40 ю сжимается сильно
	var big := TerrainField.new()
	big.lay_polygon(rect(0, 0, 40, 40), 1.0)
	var raw := big.chunk_keys().size() * TerrainField.CHUNK_NODES * 2
	var packed := 0
	for item: Array in big.save_data()["chunks"]:
		packed += (item[2] as PackedByteArray).size()
	check("сейв: сжатие плоского слоя не хуже 10 раз", packed * 10 < raw, "%d из %d" % [packed, raw])


func _test_clip() -> void:
	var f := TerrainField.new()
	f.lay_polygon(rect(0, 0, 20, 20), 1.0)
	var removed := f.clip_to_polygons([rect(0, 0, 10, 20)])
	check("обрезка: узлы вне стола сняты", removed > 0 and not f.has_layer(30, 10) and f.has_layer(10, 10) and f.has_layer(20, 10))
	check("обрезка: правая половина снята вся", not f.has_layer(21, 10) and not f.has_layer(40, 40))
	check("обрезка: в историю не пишется, Ctrl+Z снимает укладку", f.undo() and f.is_empty() and not f.can_undo())
	var g := TerrainField.new()
	g.lay_polygon(rect(0, 0, 4, 4), 1.0)
	check("обрезка: стол вне слоя снимает всё", g.clip_to_polygons([rect(100, 100, 110, 110)]) > 0 and g.is_empty())
	var e := TerrainField.new()
	check("обрезка: пустое поле 0", e.clip_to_polygons([rect(0, 0, 1, 1)]) == 0)


func _test_collision() -> void:
	var f := TerrainField.new()
	f.floor_fn = Callable(self, "step_floor")
	var col := FieldCollision.new()
	add_child(col)
	col.bind(f)
	f.lay_polygon(rect(0, 0, 4, 4), 1.0)
	col.flush()
	check("коллизия: тело на чанк", col.body_count() == 1 and col.has_body(Vector2i(0, 0)), str(col.body_count()))
	var body := col.get_child(0) as StaticBody3D
	var cs := body.get_child(0) as CollisionShape3D
	var hs := cs.shape as HeightMapShape3D
	check("коллизия: карта квадратная (CHUNK+1)", hs != null and hs.map_width == TerrainField.CHUNK + 1 and hs.map_depth == hs.map_width)
	check("коллизия: высота узла внутри слоя 1", near(hs.map_data[2 * hs.map_width + 2], 1.0))
	check("коллизия: узел вне слоя на полу 0", near(hs.map_data[12 * hs.map_width + 12], 0.0))
	check("коллизия: масштаб шага", near(cs.scale.x, TerrainField.STEP) and near(cs.scale.z, TerrainField.STEP) and near(cs.scale.y, 1.0))
	check("коллизия: слой ground", body.collision_layer == Global.active_layers(['ground']) and body.collision_mask == 0)
	# слой через границу чанка: общий ряд узлов виден у соседа
	f.lay_polygon(rect(7, 0, 9, 2), 1.0)
	col.flush()
	check("коллизия: соседний чанк создан", col.body_count() == 2 and col.has_body(Vector2i(1, 0)), str(col.body_count()))
	var hs0 := ((col.get_child(0) as StaticBody3D).get_child(0) as CollisionShape3D).shape as HeightMapShape3D
	check("коллизия: крайний ряд первого чанка берётся у соседа", near(hs0.map_data[2 * hs0.map_width + TerrainField.CHUNK], 1.0))
	# слой снят: тело убрано
	f.erase_polygon(rect(-1, -1, 20, 20))
	col.flush()
	await get_tree().process_frame
	check("коллизия: после стирания тел нет", col.body_count() == 0, str(col.body_count()))
	# пересборка ждёт паузы
	f.lay_polygon(rect(0, 0, 2, 2), 1.0)
	check("коллизия: до паузы тело не создано", col.body_count() == 0)
	col.queue_free()
	await get_tree().process_frame


func _test_tgm() -> void:
	var f: TerrainField = TGM.field
	f.clear()
	var tr: Rect2 = LYM.table_rect()
	check("стол: у TGM есть поле, окно и коллизия", f != null and TGM.field_view != null and TGM.field_collision != null)
	# область заведомо шире стола: слой ложится только на стол
	var big := tr.grow(30.0)
	var n := TGM.field_lay(TerrainField._rect_poly(big), 1.0)
	check("стол: слой положен", n > 0 and not f.is_empty(), str(n))
	var b := f.bounds()
	check("стол: слой не вылезает за стол больше чем на чанк", b.position.x >= tr.position.x - 16.0 * TerrainField.STEP and b.end.x <= tr.end.x + 16.0 * TerrainField.STEP)
	var mid := tr.get_center()
	check("стол: в середине стола слой есть", f.covered(mid.x, mid.y))
	check("стол: далеко за столом слоя нет", not f.covered(tr.end.x + 20.0, tr.end.y + 20.0))
	check("стол: field_surface_y в середине равна 1", near(TGM.field_surface_y(mid.x, mid.y), 1.0, 0.01), str(TGM.field_surface_y(mid.x, mid.y)))
	check("стол: вне слоя field_surface_y = NO_FIELD", TGM.field_surface_y(tr.end.x + 20.0, tr.end.y + 20.0) == TGM.NO_FIELD)
	check("стол: Ctrl+Z снимает правку", f.undo() and f.is_empty())
	# вся столешница и снятие
	var nt := TGM.field_lay_table(2.0)
	check("стол: вся столешница", nt > 0 and near(TGM.field_surface_y(mid.x, mid.y), 2.0, 0.01))
	var ne := TGM.field_lay_table(0.0, true)
	check("стол: снятие со всей столешницы", ne > 0 and f.is_empty())
	# сейв-цикл через словарь
	TGM.field_lay_table(1.0)
	var d := f.save_data()
	f.clear()
	f.load_data(d)
	TGM.field_dirty()
	check("стол: слой после сейва и загрузки на месте", near(TGM.field_surface_y(mid.x, mid.y), 1.0, 0.01))
	f.clear()
