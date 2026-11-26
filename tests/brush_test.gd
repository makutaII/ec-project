extends Node

# XX claude-terra 13.14 H2 (новый файл)
## Тест кисти рельефа (FieldBrush, read_region, write_region, row_intervals). Запуск: открыть tests/brush_test.tscn и нажать F6.
## Результат в Output: строки PASS / FAIL и итог. Проверки на собственном TerrainField, без сцены игры.

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


## Пол: верх листа 2 ю при x >= 10
func sheet_floor(x: float, _z: float) -> float:
	return 2.0 if x >= 10.0 - 0.001 else 0.0


## Узел под мировой точкой
func node(x: float) -> int:
	return roundi(x / TerrainField.STEP)


func _ready() -> void:
	_test_region()
	_test_intervals()
	_test_raise()
	_test_pit()
	_test_level()
	_test_clip()
	_test_types()
	_test_floor()
	_test_materials()
	print("ИТОГ: ", "ВСЕ ПРОШЛИ" if _fails == 0 else "ПРОВАЛЕНО %d" % _fails)


func _test_region() -> void:
	var f := TerrainField.new()
	var r := Rect2i(-3, -2, 40, 30)   # через границы чанков и отрицательные узлы
	var d := f.read_region(r)
	check("область: размер буферов", (d["w"] as PackedInt32Array).size() == 1200 and (d["f"] as PackedFloat32Array).size() == 1200)
	check("область: чтение не создаёт чанков", f.is_empty())
	var w: PackedInt32Array = d["w"]
	for k in range(w.size()):
		w[k] = 128 if (k % 7 == 0) else 0
	f.write_region(r, w, Rect2i(0, 0, 20, 20))
	var back := f.read_region(r)
	var bw: PackedInt32Array = back["w"]
	var ok := true
	for rj in r.size.y:
		for ri in r.size.x:
			var i := r.position.x + ri
			var j := r.position.y + rj
			var inside := i >= 0 and i < 20 and j >= 0 and j < 20
			var want := w[rj * r.size.x + ri] if inside else 0
			if bw[rj * r.size.x + ri] != want:
				ok = false
	check("область: запись и чтение совпадают, вне изменённого прямоугольника нули", ok)
	check("область: запись одной правкой, отмена возвращает пустое поле", f.undo() and f.is_empty() and not f.can_undo())
	var seen := []
	f.changed.connect(func(keys: Array) -> void: seen.append(keys))
	f.begin_edit()
	f.write_region(r, w, Rect2i(0, 0, 4, 4))
	check("область: внутри правки changed уходит сразу", seen.size() == 1)
	f.end_edit()
	check("область: закрытие правки тоже сообщает", seen.size() == 2)


func _test_intervals() -> void:
	var f := TerrainField.new()
	var iv := f.row_intervals([rect(0, 0, 4, 4)], 2)
	check("интервалы: прямоугольник 0..4 ю даёт узлы 0..8", iv.size() == 2 and iv[0] == 0 and iv[1] == 8, str(iv))
	var iv2 := f.row_intervals([rect(0, 0, 4, 4), rect(4, 0, 8, 4)], 2)
	check("интервалы: соседние прямоугольники сливаются", iv2.size() == 2 and iv2[0] == 0 and iv2[1] == 16, str(iv2))
	var iv3 := f.row_intervals([rect(0, 0, 4, 4), rect(10, 0, 12, 4)], 2)
	check("интервалы: два отдельных", iv3.size() == 4 and iv3[1] == 8 and iv3[2] == 20, str(iv3))
	check("интервалы: строка вне полигона пустая", f.row_intervals([rect(0, 0, 4, 4)], 40).is_empty())
	var iv4 := f.row_intervals([rect(0, 0, 4, 4), rect(2, 0, 6, 4)], 2)
	check("интервалы: перекрытие даёт один без повторов", iv4.size() == 2 and iv4[0] == 0 and iv4[1] == 12, str(iv4))


func _big_clip() -> Array:
	return [rect(-100, -100, 100, 100)]


func _test_raise() -> void:
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.radius = 5.0
	b.angle = 25.0
	var c := Vector2(20.0, 20.0)
	f.begin_edit()
	var ch := b.stroke(f, c, 1.0, 1, 1.0, _big_clip())
	f.end_edit()
	check("подъём: поле изменилось", ch and not f.is_empty())
	var ci := node(c.x)
	check("подъём: центр на высоте площадки", near(f.surface_at(ci, ci), 1.0, 0.01), str(f.surface_at(ci, ci)))
	var pl := b.last_plan
	check("подъём: угол не круче заданного (с допуском сетки)", float(pl["ang"]) <= 25.5, str(pl["ang"]))
	check("подъём: площадка p + склон w не шире радиуса с допуском", float(pl["e"]) <= 5.0 + 1.25 + 0.01, str(pl["e"]))
	# слой монотонно убывает от центра
	var mono := true
	var prev := f.surface_at(ci, ci)
	for k in range(1, 14):
		var h := f.surface_at(ci + k, ci)
		if h > prev + 0.01:
			mono = false
		prev = h
	check("подъём: от центра высота не растёт", mono)
	# крутизна склона между соседними узлами
	var steep := 0.0
	for j in range(ci - 14, ci + 15):
		for i in range(ci - 14, ci + 14):
			steep = maxf(steep, absf(f.surface_at(i, j) - f.surface_at(i + 1, j)))
	var lim := tan(deg_to_rad(25.0)) * TerrainField.STEP + 0.02
	check("подъём: перепад между соседними узлами не больше угла", steep <= lim, "%.3f > %.3f" % [steep, lim])
	check("подъём: далеко от кисти слоя нет", not f.has_layer(ci + 20, ci) and not f.has_layer(ci, ci - 20))
	# одна правка
	check("подъём: Ctrl+Z убирает мазок целиком", f.undo() and f.is_empty())
	# высокий подъём: угол смягчается, площадка не меньше минимума
	var g := TerrainField.new()
	var b2 := FieldBrush.new()
	b2.radius = 3.0
	b2.angle = 20.0
	g.begin_edit()
	b2.stroke(g, c, 6.0, 1, 1.0, _big_clip())
	g.end_edit()
	check("подъём: на 6 ю при радиусе 3 угол смягчён", str(b2.last_plan["limit"]) == "место" and float(b2.last_plan["ang"]) > 20.0, str(b2.last_plan))
	check("подъём: площадка не меньше минимума", float(b2.last_plan["p"]) >= 1.0 - 0.001)
	# потолок max_layers
	var h2 := TerrainField.new()
	var b3 := FieldBrush.new()
	b3.max_layers = 2.0
	h2.begin_edit()
	b3.stroke(h2, c, 10.0, 1, 1.0, _big_clip())
	h2.end_edit()
	check("подъём: толщина не больше max_layers", near(h2.thickness(ci, ci), 2.0, 0.01), str(h2.thickness(ci, ci)))


func _test_pit() -> void:
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.radius = 4.0
	var c := Vector2(20.0, 20.0)
	var ci := node(c.x)
	f.begin_edit()
	b.stroke(f, c, 3.0, 1, 1.0, _big_clip())
	f.end_edit()
	check("яма: холм поднят", near(f.surface_at(ci, ci), 3.0, 0.01))
	f.begin_edit()
	b.stroke(f, c, 1.0, -1, 1.0, _big_clip())
	f.end_edit()
	check("яма: центр опущен до высоты площадки", near(f.surface_at(ci, ci), 1.0, 0.01), str(f.surface_at(ci, ci)))
	f.begin_edit()
	b.stroke(f, c, 0.0, -1, 1.0, _big_clip())
	f.end_edit()
	check("яма: до пола слой снят совсем, толщины нет", not f.has_layer(ci, ci) and near(f.surface_at(ci, ci), 0.0))
	check("яма: глубже пола не бывает", near(f.thickness(ci, ci), 0.0))
	check("яма: яма не поднимает: вне кисти узлы не выросли", f.surface_at(ci + 30, ci) <= 0.001)
	check("яма: отмена возвращает прежнюю высоту", f.undo() and near(f.surface_at(ci, ci), 1.0, 0.01))
	var plan_ok := b.next_height(1.0, -1.0, false, 1.0, 0.0) >= 0.0 and near(b.next_height(0.2, -1.0, false, 1.0, 0.0), 0.0)
	check("яма: следующая высота не ниже пола", plan_ok)
	check("высота: Shift на целый слой вверх", near(b.next_height(1.3, 1.0, true, 1.0, 0.0), 2.0))
	check("высота: Shift на целый слой вниз", near(b.next_height(1.3, -1.0, true, 1.0, 0.0), 1.0))
	check("высота: на листе слои от пола листа", near(b.next_height(2.3, 1.0, true, 1.0, 2.0), 3.0))


func _test_level() -> void:
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.radius = 5.0
	var c := Vector2(20.0, 20.0)
	var ci := node(c.x)
	f.begin_edit()
	b.stroke(f, c, 4.0, 1, 1.0, _big_clip())
	f.end_edit()
	# выравнивание по якорю 1,5: срезает и насыпает
	f.begin_edit()
	b.stroke(f, c, 1.5, 0, 1.0, _big_clip())
	f.end_edit()
	check("выравнивание: центр на высоте якоря", near(f.surface_at(ci, ci), 1.5, 0.01), str(f.surface_at(ci, ci)))
	check("выравнивание: площадка вокруг центра ровная", near(f.surface_at(ci + 1, ci), 1.5, 0.01) and near(f.surface_at(ci, ci - 2), 1.5, 0.01))
	# подтягивание небольшими шагами сходится к якорю
	var g := TerrainField.new()
	var b2 := FieldBrush.new()
	b2.radius = 4.0
	g.begin_edit()
	b2.stroke(g, c, 3.0, 1, 1.0, _big_clip())
	for n in 200:
		b2.stroke(g, c, 1.0, 0, 0.09, _big_clip())
	g.end_edit()
	check("выравнивание: малыми шагами доходит до якоря", near(g.surface_at(ci, ci), 1.0, g.layer_height / 128.0 + 0.001), str(g.surface_at(ci, ci)))
	check("выравнивание: весь драг одна правка", g.undo() and g.is_empty())


func _test_clip() -> void:
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.radius = 5.0
	var c := Vector2(8.0, 20.0)   # правый край стола x = 8
	f.begin_edit()
	b.stroke(f, c, 1.0, 1, 1.0, [rect(0, 0, 8, 40)])
	f.end_edit()
	var ci := node(c.x)
	check("стол: у края слой есть", f.has_layer(ci, node(c.y)) and f.has_layer(ci - 4, node(c.y)))
	check("стол: за краем слоя нет", not f.has_layer(ci + 1, node(c.y)) and not f.has_layer(ci + 6, node(c.y)))
	var all_in := true
	for key: Vector2i in f.chunk_keys():
		var w := f.chunk_words(key)
		for k in w.size():
			if w[k] != 0:
				var i := key.x * TerrainField.CHUNK + k % TerrainField.CHUNK
				if i > 16:
					all_in = false
	check("стол: ни один узел не вышел за правую границу", all_in)
	# стол кончается дальше радиуса: мазок целиком
	var g := TerrainField.new()
	g.begin_edit()
	b.stroke(g, Vector2(20, 20), 1.0, 1, 1.0, [rect(0, 0, 8, 8)])
	g.end_edit()
	check("стол: мазок вне стола ничего не меняет", g.is_empty())


## H2b: поверхность кисти для тестов (без текстуры, различается оттенком и повтором)
func _surf(kind: int, tint: Color, tile := 3.0, weight := 1.0) -> FieldSurface:
	var s := FieldSurface.new()
	s.kind = kind
	s.tint = tint
	s.tile = tile
	s.weight = weight
	return s


## H2b: палитра с различимыми служебными слотами и поверхностями кистей list
func _palette(list: Array[FieldSurface]) -> FieldMaterials:
	var m := FieldMaterials.new()
	m.base = _surf(0, Color(1, 1, 1), 3.0)
	m.cliff = _surf(2, Color(0.5, 0.5, 0.5), 5.0)
	m.bed = _surf(1, Color(0.9, 0.8, 0.6), 2.5)
	m.set_brush_surfaces(list)
	return m


func _test_types() -> void:
	var s_rock := _surf(TerrainField.ROCK, Color(0.3, 0.9, 0.3), 4.0)
	var s_smooth := _surf(TerrainField.SMOOTH, Color(0.6, 0.2, 0.2), 3.0)
	var s_rocky := _surf(TerrainField.ROCKY, Color(0.2, 0.2, 0.8), 2.0)
	var pal := _palette([s_rock, s_smooth, s_rocky])
	var f := TerrainField.new()
	var b := FieldBrush.new()
	b.materials = pal
	b.radius = 4.0
	b.set_surfaces([s_rock])
	var c := Vector2(20.0, 20.0)
	f.begin_edit()
	b.stroke(f, c, 1.0, 1, 1.0, _big_clip())
	f.end_edit()
	var ci := node(c.x)
	check("тип: скалистая кисть пишет скалистый тип", f.type_at(ci, ci) == TerrainField.ROCK and f.type_at(ci + 2, ci) == TerrainField.ROCK)
	check("материал: кисть пишет слот своей поверхности", f.mat_at(ci, ci) == pal.slot_of(s_rock) and f.mat_at(ci + 2, ci) == pal.slot_of(s_rock) and pal.slot_of(s_rock) >= FieldMaterials.SLOT_FIRST, str(f.mat_at(ci, ci)))
	b.set_surfaces([s_smooth])
	f.begin_edit()
	b.stroke(f, c, 1.0, 0, 1.0, _big_clip())
	f.end_edit()
	check("тип: выравнивание гладкой кистью перекрашивает площадку", f.type_at(ci, ci) == TerrainField.SMOOTH)
	check("материал: выравнивание перекрашивает слот площадки", f.mat_at(ci, ci) == pal.slot_of(s_smooth), str(f.mat_at(ci, ci)))
	var g := TerrainField.new()
	var m := FieldBrush.new()
	m.materials = pal
	m.radius = 6.0
	var m1 := _surf(TerrainField.SMOOTH, Color(0.6, 0.2, 0.2), 3.0, 0.4)
	var m2 := _surf(TerrainField.ROCKY, Color(0.2, 0.2, 0.8), 2.0, 0.3)
	var m3 := _surf(TerrainField.ROCK, Color(0.3, 0.9, 0.3), 4.0, 0.3)
	m.set_surfaces([m1, m2, m3])
	g.begin_edit()
	m.stroke(g, c, 1.0, 1, 1.0, _big_clip())
	g.end_edit()
	var kinds := {}
	var mats := {}
	for j in range(ci - 8, ci + 9):
		for i in range(ci - 8, ci + 9):
			if g.has_layer(i, j):
				kinds[g.type_at(i, j)] = true
				mats[g.mat_at(i, j)] = true
	check("тип: смешанная кисть даёт все три типа", kinds.size() == 3, str(kinds.keys()))
	check("материал: смешанная кисть даёт три разных слота", mats.size() == 3, str(mats.keys()))
	check("тип: подпись одной поверхности и смеси", b.type_label() == "гладкая" and m.type_label() == "смесь")
	s_smooth.label = "лужайка"
	b.set_surfaces([s_smooth])
	check("тип: подпись поверхности из её label", b.type_label() == "лужайка")
	check("тип: кисть без поверхностей красит базовой (слот 0, гладкая)", FieldBrush.new().mat_for(3, 3) == FieldMaterials.SLOT_BASE and FieldBrush.new().type_for(3, 3) == TerrainField.SMOOTH)
	check("тип: тип узла стабилен", m.type_for(5, 7) == m.type_for(5, 7))
	# H4: смесь пятнами (блок MIX_BLOCK x MIX_BLOCK узлов одного типа), а не по ячейкам
	var blocks_ok := true
	for bj in range(-3, 4):
		for bi in range(-3, 4):
			var t0 := m.bits_for(bi * FieldBrush.MIX_BLOCK, bj * FieldBrush.MIX_BLOCK)
			for dj in FieldBrush.MIX_BLOCK:
				for di in FieldBrush.MIX_BLOCK:
					if m.bits_for(bi * FieldBrush.MIX_BLOCK + di, bj * FieldBrush.MIX_BLOCK + dj) != t0:
						blocks_ok = false
	check("тип: смесь даёт пятна, узлы блока одного типа и слота", blocks_ok)
	var same := 0
	for j in range(0, 40):
		for i in range(0, 40):
			if m.bits_for(i, j) == m.bits_for(i + 1, j):
				same += 1
	check("тип: соседние узлы чаще одного типа, чем разных", same > 800, str(same))
	# слот материала переживает утолщение слоя и сейв
	var h := TerrainField.new()
	b.set_surfaces([s_rock])
	h.begin_edit()
	b.stroke(h, c, 1.0, 1, 1.0, _big_clip())
	h.end_edit()
	var h2 := TerrainField.new()
	h2.load_data(h.save_data())
	check("материал: слот и тип узла возвращаются из сейва", h2.mat_at(ci, ci) == pal.slot_of(s_rock) and h2.type_at(ci, ci) == TerrainField.ROCK, str(h2.mat_at(ci, ci)))


func _test_floor() -> void:
	var f := TerrainField.new()
	f.floor_fn = Callable(self, "sheet_floor")
	var b := FieldBrush.new()
	b.radius = 5.0
	var c := Vector2(6.0, 10.0)   # правее x = 10 лежит лист высотой 2
	var ci := node(c.x)
	f.begin_edit()
	b.stroke(f, c, 1.0, 1, 1.0, _big_clip())
	f.end_edit()
	check("пол: на столе слой поднят до 1", near(f.surface_at(ci, node(c.y)), 1.0, 0.01))
	check("пол: площадка ниже верха листа слоя на листе не даёт", not f.has_layer(node(11.0), node(c.y)))
	f.floor_fn = Callable(self, "sheet_floor")
	var g := TerrainField.new()
	g.floor_fn = Callable(self, "sheet_floor")
	g.begin_edit()
	b.stroke(g, Vector2(12.0, 10.0), 3.0, 1, 1.0, _big_clip())
	g.end_edit()
	check("пол: на листе толщина считается от верха листа", near(g.thickness(node(12.0), node(10.0)), 1.0, 0.01) and near(g.surface_at(node(12.0), node(10.0)), 3.0, 0.01))
	check("пол: у края листа склон спускается на стол", g.has_layer(node(8.0), node(10.0)) and g.surface_at(node(8.0), node(10.0)) < 3.0)
	# пол чужого чанка кэшируется и обновляется
	var h := TerrainField.new()
	var calls := [0]
	h.floor_fn = func(_x: float, _z: float) -> float:
		calls[0] += 1
		return 0.0
	h.read_region(Rect2i(0, 0, 8, 8))
	var n1: int = calls[0]
	h.read_region(Rect2i(0, 0, 8, 8))
	check("пол: пол чанка без данных считается один раз", n1 > 0 and calls[0] == n1, "%d %d" % [n1, calls[0]])
	h.floor_fn = func(_x: float, _z: float) -> float: return 1.5
	h.refresh_floor(Rect2(-1, -1, 10, 10))
	check("пол: refresh_floor обновляет и чанки без данных", near(h.floor_at(2, 2), 1.5))


## H4, H2b: палитра материалов поверхности поля
func _test_materials() -> void:
	var m := load("res://data/terrain/field_materials.tres") as FieldMaterials
	check("материалы: набор загружается", m != null)
	if m == null:
		return
	check("материалы: служебные поверхности с текстурой (плоская, склоны, ложе)", m.base != null and m.cliff != null and m.bed != null and m.base.texture != null and m.cliff.texture != null and m.bed.texture != null)
	var sl := m.slots()
	check("материалы: в палитре не меньше трёх слотов и не больше предела", sl.size() >= FieldMaterials.SLOT_FIRST and sl.size() <= FieldMaterials.MAX_SLOTS, str(sl.size()))
	# карточки кистей из поставки красят слотами палитры
	var hill := (load("res://data/terrain/objects/relief_hill.tres") as EntitySetting).components[0] as TerrainBrush
	var gravel := (load("res://data/terrain/objects/relief_gravel.tres") as EntitySetting).components[0] as TerrainBrush
	var rocks := (load("res://data/terrain/objects/relief_rocks.tres") as EntitySetting).components[0] as TerrainBrush
	var fb := FieldBrush.new()
	fb.materials = m
	fb.set_surfaces(hill.surfaces)
	check("материалы: кисть холма красит плоской поверхностью (слот 0)", fb.mat_for(0, 0) == FieldMaterials.SLOT_BASE and fb.type_for(0, 0) == TerrainField.SMOOTH)
	fb.set_surfaces(gravel.surfaces)
	check("материалы: кисть гравия красит слотом ложа и каменистым типом", fb.mat_for(0, 0) == FieldMaterials.SLOT_BED and fb.type_for(0, 0) == TerrainField.ROCKY)
	fb.set_surfaces(rocks.surfaces)
	check("материалы: кисть скал красит слотом склонов и скалистым типом", fb.mat_for(0, 0) == FieldMaterials.SLOT_CLIFF and fb.type_for(0, 0) == TerrainField.ROCK)
	# одинаковые материалы делят слот, новые занимают свободный, переполнение красит базовым
	var pal := _palette([_surf(0, Color(1, 1, 1), 3.0), _surf(1, Color(0.2, 0.7, 0.2), 3.0), _surf(2, Color(0.2, 0.7, 0.2), 3.0)])
	check("палитра: поверхность как у базовой делит слот 0", pal.slot_of(_surf(1, Color(1, 1, 1), 3.0)) == 0)
	check("палитра: новая поверхность занимает слот, класс рельефа в слот не входит", pal.slots().size() == 4 and pal.slot_of(_surf(2, Color(0.2, 0.7, 0.2), 3.0)) == 3)
	var many: Array[FieldSurface] = []
	for i in 20:
		many.append(_surf(0, Color(0.01 * float(i + 1), 0.5, 0.5), 3.0))
	var full := _palette(many)
	check("палитра: слотов не больше предела", full.slots().size() == FieldMaterials.MAX_SLOTS, str(full.slots().size()))
	check("палитра: поверхность без места красит базовым слотом", full.slot_of(many[19]) == FieldMaterials.SLOT_BASE)
	# параметры шейдера
	var mat := ShaderMaterial.new()
	var sh := load("res://core/components/terrain/field_surface.gdshader") as Shader
	check("материалы: шейдер поверхности загружается", sh != null)
	mat.shader = sh
	m.apply(mat)
	var arr = mat.get_shader_parameter("texs")
	var tints = mat.get_shader_parameter("tints")
	var tiles = mat.get_shader_parameter("tiles")
	check("материалы: массив текстур по слотам палитры", arr is Texture2DArray and (arr as Texture2DArray).get_layers() == m.slots().size(), str(arr))
	check("материалы: оттенки и повторы на все 16 слотов", tints is PackedColorArray and (tints as PackedColorArray).size() == FieldMaterials.MAX_SLOTS and tiles is PackedFloat32Array and (tiles as PackedFloat32Array).size() == FieldMaterials.MAX_SLOTS)
	check("материалы: повтор склонов из палитры", tiles is PackedFloat32Array and is_equal_approx((tiles as PackedFloat32Array)[FieldMaterials.SLOT_CLIFF], m.cliff.tile))
	check("материалы: слот склонов передан шейдеру", mat.get_shader_parameter("slot_cliff") == FieldMaterials.SLOT_CLIFF)
