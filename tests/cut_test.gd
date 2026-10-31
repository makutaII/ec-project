extends Node

# XX claude-terra 13.3 S1 (новый файл)
## Тест ядра терморезака: FoamCutter (формы, слои, перевод в локальные координаты, обрезка по окну),
## C_TerrainLayer.add_cut / remove_cut и вырез в вогнутом листе. Чистая математика, листов и TGM не нужно.
## Запуск: открыть tests/cut_test.tscn и нажать F6. Результат в Output: строки PASS / FAIL и итог.
## Применение к настоящим листам (apply, revert, D6 по блокам) проверяется в редакторе, см. ATTN_13 §13.3.

var _fails := 0


func check(name: String, ok: bool, info := "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", info)


func near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps


func area(p: PackedVector2Array) -> float:
	return absf(C_Contour.signed_area(p))


func poly(arr: Array) -> PackedVector2Array:
	var res := PackedVector2Array()
	for v: Vector2 in arr:
		res.append(v)
	return res


func _ready() -> void:
	# --- rect ---
	var r1 := FoamCutter.rect(Vector2(2, 3), Vector2(6, 9))
	check("rect: 4 вершины, площадь 24", r1.size() == 4 and near(area(r1), 24.0), str(r1))
	check("rect: обход против часовой", C_Contour.signed_area(r1) > 0.0)
	var r2 := FoamCutter.rect(Vector2(6, 9), Vector2(2, 3))
	check("rect: углы в любом порядке дают тот же прямоугольник", r2 == r1, str(r2))
	check("rect: нулевая сторона пустая", FoamCutter.rect(Vector2(1, 1), Vector2(1, 5)).is_empty())
	check("rect: 4×4 годен", FoamCutter.check(r1) == "", FoamCutter.check(r1))
	check("rect: 1×1 годен (площадь ровно 1)", FoamCutter.check(FoamCutter.rect(Vector2.ZERO, Vector2.ONE)) == "")
	check("rect: 0,5×4 не годен (ребро короче шага)", FoamCutter.check(FoamCutter.rect(Vector2.ZERO, Vector2(0.5, 4))) != "")

	# --- polygon ---
	var cw := poly([Vector2(0, 0), Vector2(0, 10), Vector2(10, 10), Vector2(10, 0)])
	var pcw := FoamCutter.polygon(cw)
	check("polygon: обход по часовой исправлен", C_Contour.signed_area(pcw) > 0.0 and pcw.size() == 4)
	var col := poly([Vector2(0, 0), Vector2(5, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	check("polygon: вершина на прямой убрана", FoamCutter.polygon(col).size() == 4, str(FoamCutter.polygon(col).size()))
	check("polygon: две точки пустой", FoamCutter.polygon(poly([Vector2(0, 0), Vector2(5, 0)])).is_empty())
	var bowtie := poly([Vector2(0, 0), Vector2(10, 10), Vector2(10, 0), Vector2(0, 10)])
	check("check: бабочка отклонена", FoamCutter.check(FoamCutter.polygon(bowtie)) == "Самопересечение",
			FoamCutter.check(FoamCutter.polygon(bowtie)))
	check("check: меньше 3 вершин", FoamCutter.check(poly([Vector2(0, 0), Vector2(5, 0)])) == "Меньше 3 вершин")

	# --- strip ---
	var s1 := FoamCutter.strip(poly([Vector2(0, 0), Vector2(10, 0)]), 4.0)
	check("strip: отрезок 10 шириной 4, площадь 40", s1.size() == 4 and near(area(s1), 40.0, 0.05), "%d / %f" % [s1.size(), area(s1)])
	check("strip: обход против часовой", C_Contour.signed_area(s1) > 0.0)
	var s2 := FoamCutter.strip(poly([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10)]), 4.0)
	check("strip: угол 90°, площадь 80", near(area(s2), 80.0, 0.1), str(area(s2)))
	check("strip: контур угла годен", FoamCutter.check(s2) == "", FoamCutter.check(s2))
	var s3 := FoamCutter.strip(poly([Vector2(0, 0), Vector2(10, 0)]), 0.2)
	check("strip: ширина подтянута до минимума 1", near(area(s3), 10.0, 0.05), str(area(s3)))
	var s4 := FoamCutter.strip(poly([Vector2(0, 0), Vector2(10, 0)]), 500.0)
	check("strip: ширина обрезана до 40", near(area(s4), 400.0, 0.5), str(area(s4)))
	check("strip: одна точка пустая, причина названа",
			FoamCutter.strip(poly([Vector2(0, 0)]), 4.0).is_empty() and FoamCutter.strip_why(poly([Vector2(0, 0)]), 4.0) != "")
	var long_axis := PackedVector2Array()
	for i in C_PolygonDraw.MAX_AXIS + 1:
		long_axis.append(Vector2(float(i) * 3.0, float(i % 2) * 3.0))
	check("strip: больше MAX_AXIS точек отклонена", FoamCutter.strip(long_axis, 2.0).is_empty()
			and FoamCutter.strip_why(long_axis, 2.0).begins_with("Больше"), FoamCutter.strip_why(long_axis, 2.0))
	check("strip: годная ось без причины", FoamCutter.strip_why(poly([Vector2(0, 0), Vector2(10, 0)]), 4.0) == "")

	# --- half_plane ---
	var hp := FoamCutter.half_plane(Vector2(0, 0), Vector2(10, 0), Vector2(5, 5))
	check("half_plane: точка стороны внутри", Geometry2D.is_point_in_polygon(Vector2(5, 20), hp))
	check("half_plane: другая сторона снаружи", not Geometry2D.is_point_in_polygon(Vector2(5, -20), hp))
	check("half_plane: обход против часовой", C_Contour.signed_area(hp) > 0.0)
	var hp2 := FoamCutter.half_plane(Vector2(0, 0), Vector2(10, 0), Vector2(5, -5))
	check("half_plane: сторона выбирается по точке", Geometry2D.is_point_in_polygon(Vector2(5, -20), hp2)
			and not Geometry2D.is_point_in_polygon(Vector2(5, 20), hp2))
	var hp3 := FoamCutter.half_plane(Vector2(0, 0), Vector2(10, 10), Vector2(0, 10))   # диагональ
	check("half_plane: диагональ", Geometry2D.is_point_in_polygon(Vector2(0, 30), hp3)
			and not Geometry2D.is_point_in_polygon(Vector2(30, 0), hp3))
	check("half_plane: точка на прямой пустая", FoamCutter.half_plane(Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)).is_empty())
	check("half_plane: a = b пустая", FoamCutter.half_plane(Vector2(3, 3), Vector2(3, 3), Vector2(5, 5)).is_empty())
	check("half_plane: годна как вырез", FoamCutter.check(hp) == "", FoamCutter.check(hp))

	# --- level_range ---
	var T := 1.0
	check("слои: весь лист 0..4", FoamCutter.level_range(0.0, 4, 0.0, 4.0, T) == Vector2i(0, 4))
	check("слои: середина 1..3", FoamCutter.level_range(0.0, 4, 1.0, 3.0, T) == Vector2i(1, 3))
	check("слои: пустой диапазон", FoamCutter.level_range(0.0, 4, 2.0, 2.0, T).y <= 0)
	check("слои: ниже листа обрезается", FoamCutter.level_range(0.0, 4, -5.0, 2.0, T) == Vector2i(0, 2))
	check("слои: выше листа обрезается", FoamCutter.level_range(0.0, 4, 3.0, 99.0, T) == Vector2i(3, 4))
	check("слои: целиком над листом нет", FoamCutter.level_range(0.0, 4, 4.0, 6.0, T).y <= FoamCutter.level_range(0.0, 4, 4.0, 6.0, T).x)
	check("слои: целиком под листом нет", FoamCutter.level_range(5.0, 4, 0.0, 5.0, T).y <= FoamCutter.level_range(5.0, 4, 0.0, 5.0, T).x)
	check("слои: лист на высоте 2, диапазон 2..3 = слой 0", FoamCutter.level_range(2.0, 4, 2.0, 3.0, T) == Vector2i(0, 1))
	check("слои: допуск 0,001 (3,0004 - 3,9996 даёт слой 3)", FoamCutter.level_range(0.0, 8, 3.0004, 3.9996, T) == Vector2i(3, 4))
	check("слои: частично задетый слой режется целиком", FoamCutter.level_range(0.0, 4, 0.3, 1.0, T) == Vector2i(0, 1))
	check("слои: layer_height 0,5", FoamCutter.level_range(0.0, 8, 1.0, 2.0, 0.5) == Vector2i(2, 4))

	# --- to_local ---
	var xf := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(10.0, 0.0, 5.0))
	var wp := poly([Vector2(10, 4), Vector2(10, 8), Vector2(6, 8), Vector2(6, 4)])
	var loc := FoamCutter.to_local(wp, xf.affine_inverse())
	check("to_local: четыре вершины, площадь сохранена", loc.size() == 4 and near(area(loc), 16.0), str(loc))
	check("to_local: вершина (10, 4) лист-повёрнутый даёт (1, 0)", loc.has(Vector2(1, 0)), str(loc))
	check("to_local: обход против часовой", C_Contour.signed_area(loc) > 0.0)
	var noisy := poly([Vector2(0.0000001, 0), Vector2(10, 0.0000002), Vector2(10, 10), Vector2(0, 10)])
	check("to_local: хвосты плавающей точки округлены", FoamCutter.to_local(noisy, Transform3D.IDENTITY)[0] == Vector2(0, 0),
			str(FoamCutter.to_local(noisy, Transform3D.IDENTITY)))
	var degen := poly([Vector2(0, 0), Vector2(0.0001, 0), Vector2(0, 0.0001)])
	check("to_local: после округления вырожденный даёт пустой", FoamCutter.to_local(degen, Transform3D.IDENTITY).is_empty())

	# --- clip_to_window ---
	var win := Rect2(0, 0, 10, 10)
	var inside := FoamCutter.rect(Vector2(2, 2), Vector2(5, 5))
	var ci := FoamCutter.clip_to_window(inside, win)
	check("clip: внутри окна без изменений", ci.size() == 1 and ci[0] == inside)
	var half := FoamCutter.half_plane(Vector2(0, 5), Vector2(10, 5), Vector2(5, 9))
	var ch := FoamCutter.clip_to_window(half, win)
	check("clip: полуплоскость режется до окна, площадь 50", ch.size() == 1 and near(area(ch[0]), 50.0, 0.05),
			"%d / %s" % [ch.size(), str(ch)])
	check("clip: полуплоскость после обрезки годна", ch.size() == 1 and FoamCutter.check(ch[0]) == "")
	var out := FoamCutter.rect(Vector2(20, 20), Vector2(30, 30))
	check("clip: вне окна пусто", FoamCutter.clip_to_window(out, win).is_empty())
	# вогнутый вырез (П): в окно попадает только перемычка, ножки остаются за окном
	var u := poly([Vector2(-5, 2), Vector2(15, 2), Vector2(15, 8), Vector2(12, 8), Vector2(12, 5), Vector2(-2, 5), Vector2(-2, 8), Vector2(-5, 8)])
	var cu := FoamCutter.clip_to_window(u, Rect2(0, 0, 10, 10))
	var cu_area := 0.0
	for pc in cu:
		cu_area += area(pc)
	check("clip: вогнутый вырез, площадь куска в окне 30", near(cu_area, 30.0, 0.05), str(cu_area))

	# --- C_TerrainLayer.add_cut / remove_cut (без Entity) ---
	var layer := C_TerrainLayer.new()
	layer.levels = 3
	var sq := FoamCutter.rect(Vector2(1, 1), Vector2(3, 3))
	var c1 := layer.add_cut(sq, 0, 2)
	check("add_cut: возвращает вырез", c1 != null and layer.cuts.size() == 1)
	check("add_cut: слои сохранены", c1 != null and c1.from_level == 0 and c1.to_level == 2)
	check("add_cut: пустой диапазон даёт null", layer.add_cut(sq, 2, 2) == null and layer.cuts.size() == 1)
	check("add_cut: две вершины даёт null", layer.add_cut(poly([Vector2(0, 0), Vector2(1, 1)]), 0, 1) == null)
	var c2 := layer.add_cut(sq, 1, 99)
	check("add_cut: верхняя граница обрезана толщиной листа", c2 != null and c2.to_level == 3)
	check("remove_cut: снимает именно этот вырез", layer.remove_cut(c1) and layer.cuts.size() == 1 and layer.cuts[0] == c2)
	check("remove_cut: повторно нечего снимать", not layer.remove_cut(c1))
	check("remove_cut: чужой вырез не снимается", not layer.remove_cut(FoamCut.new()) and layer.cuts.size() == 1)
	layer.free()

	# --- вогнутый лист с вырезом из FoamCutter через _slab_polygons ---
	var layer2 := C_TerrainLayer.new()
	var ell := poly([Vector2(0, 0), Vector2(10, 0), Vector2(10, 5), Vector2(5, 5), Vector2(5, 10), Vector2(0, 10)])
	var fc := FoamCut.new()
	fc.polygon = FoamCutter.rect(Vector2(-2, 3), Vector2(12, 4))   # полоса через всю ножку Г, выходит за край
	var cuts: Array[FoamCut] = [fc]
	var pieces: Array[PackedVector2Array] = layer2._slab_polygons(C_Contour.cleaned(ell), cuts)
	var total := 0.0
	var all_tri := true
	for pc in pieces:
		total += absf(C_Contour.signed_area(pc))
		if Geometry2D.triangulate_polygon(pc).is_empty():
			all_tri = false
	check("Г с поперечным вырезом 1 ю: площадь 75 - 10 = 65", near(total, 65.0, 0.05), str(total))
	check("Г с поперечным вырезом: лист распался минимум на 2 куска", pieces.size() >= 2, str(pieces.size()))
	check("Г с поперечным вырезом: все куски триангулируются", all_tri)
	layer2.free()

	# --- 13.3 S4: грани среза ---
	var outline := poly([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	check("edge_on_outline: ребро на контуре", C_TerrainLayer.edge_on_outline(Vector2(0, 0), Vector2(10, 0), outline))
	check("edge_on_outline: часть ребра контура", C_TerrainLayer.edge_on_outline(Vector2(2, 0), Vector2(6, 0), outline))
	check("edge_on_outline: ребро внутри контура это срез", not C_TerrainLayer.edge_on_outline(Vector2(0, 5), Vector2(10, 5), outline))
	check("edge_on_outline: параллельное ребро в 0,5 от контура это срез", not C_TerrainLayer.edge_on_outline(Vector2(0, 0.5), Vector2(10, 0.5), outline))
	check("edge_on_outline: допуск 0,01", C_TerrainLayer.edge_on_outline(Vector2(0, 0.005), Vector2(10, 0.005), outline))
	var ts := TerrainStyle.new()
	check("get_cut: сырой пенопласт имеет свой материал", ts.get_cut(0) != null and ts.get_cut(0) != ts.get_side(0))
	check("get_cut: материал один на всех (кэш)", ts.get_cut(0) == TerrainStyle.new().get_cut(0))
	check("get_cut: шпаклёвка и далее как бок", ts.get_cut(1) == ts.get_side(1) and ts.get_cut(3) == ts.get_side(3))
	var custom := StandardMaterial3D.new()
	var cm: Array[Material] = [custom]
	ts.cut_materials = cm
	check("get_cut: материал из стиля важнее встроенного", ts.get_cut(0) == custom)
	check("get_cut: слот без материала берёт бок", ts.get_cut(1) == ts.get_side(1))

	print("--------")
	print("cut_test: ", "PASS" if _fails == 0 else "FAIL (%d)" % _fails)
