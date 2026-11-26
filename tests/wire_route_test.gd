extends Node

# XX claude-wire W1 (новый файл)
## ATTN_23 W1: трасса и вид провода без сцены. Запуск: открыть tests/wire_route_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: WireRoute (длина, повторные точки, скругление углов, прямой угол, разворот, короткие отрезки, базис вдоль отрезка
## в том числе по вертикали) и WireMesh (две поверхности, число вершин, нет NaN, перекрест жил при скрутке).

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _finite(arr: PackedVector3Array) -> bool:
	for v in arr:
		if is_nan(v.x) or is_nan(v.y) or is_nan(v.z) or is_inf(v.x) or is_inf(v.y) or is_inf(v.z):
			return false
	return true


func _ring_center(verts: PackedVector3Array, ring: int) -> Vector3:
	var c := Vector3.ZERO
	for j in WireMesh.RADIAL:
		c += verts[ring * WireMesh.RADIAL + j]
	return c / float(WireMesh.RADIAL)


func _ready() -> void:
	print("== 1. WireRoute: длина и повторные точки")
	var l_shape := PackedVector3Array([Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 0, 10)])
	var r := WireRoute.from_polyline(l_shape)
	check("длина Г-образной ломаной 20", is_equal_approx(r.length(), 20.0), str(r.length()))
	var dup := WireRoute.dedupe(PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0)]))
	check("повторные точки убраны", dup.size() == 3, str(dup))
	check("пустая ломаная: длина 0", is_equal_approx(WireRoute.from_polyline(PackedVector3Array()).length(), 0.0))

	print("== 2. WireRoute.smooth: углы")
	var sm := r.smooth()
	check("концы на месте", sm[0] == Vector3(0, 0, 0) and sm[sm.size() - 1] == Vector3(10, 0, 10))
	check("угол скруглён: точек больше трёх", sm.size() > 3, str(sm.size()))
	var sl := WireRoute.polyline_length(sm)
	check("скруглённая трасса короче ломаной, но не сильно", sl < 20.0 and sl > 18.5, str(sl))
	check("дуга не уходит за угол (10, 0, 0)", _finite(sm) and not sm.has(Vector3(10, 0, 0)))
	var straight := WireRoute.from_polyline(PackedVector3Array([Vector3(0, 0, 0), Vector3(5, 0, 0), Vector3(10, 0, 0)])).smooth()
	check("прямая: длина 10, без NaN", _finite(straight) and is_equal_approx(WireRoute.polyline_length(straight), 10.0), str(straight))
	var back := WireRoute.from_polyline(PackedVector3Array([Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(5, 0, 0)])).smooth()
	check("разворот на 180: без NaN, концы на месте", _finite(back) and back[0] == Vector3.ZERO and back[back.size() - 1] == Vector3(5, 0, 0), str(back))
	var tiny := WireRoute.from_polyline(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 0, 0.5)])).smooth()
	var tl := WireRoute.polyline_length(tiny)
	check("короткие отрезки: дуга внутри, длина не больше ломаной", _finite(tiny) and tl <= 1.0 + 0.0001 and tl > 0.5, str(tl))
	# XX claude-wire W5: радиус изгиба (настройка GlobalSetting.wire_bend_radius)
	var sm_small := r.smooth(0.3)
	var sm_zero := r.smooth(0.0)
	check("меньший радиус: трасса длиннее (угол острее)", WireRoute.polyline_length(sm_small) > sl and WireRoute.polyline_length(sm_small) < 20.0, str(WireRoute.polyline_length(sm_small)))
	check("радиус 0: острый угол, длина ломаной", is_equal_approx(WireRoute.polyline_length(sm_zero), 20.0) and _finite(sm_zero), str(WireRoute.polyline_length(sm_zero)))
	check("настройка радиуса по умолчанию равна WireRoute.BEND_RADIUS", is_equal_approx(Global.settings.wire_bend_radius, WireRoute.BEND_RADIUS))
	check("настройка высоты оси кабеля над поверхностью по умолчанию 0.2", is_equal_approx(Global.settings.wire_lift, 0.2))
	var two := WireRoute.from_polyline(PackedVector3Array([Vector3(0, 0, 0), Vector3(3, 0, 0)])).smooth()
	check("две точки без изменений", two.size() == 2)
	var vert := WireRoute.from_polyline(PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 10, 0), Vector3(5, 10, 0)])).smooth()
	check("вертикаль с поворотом: без NaN", _finite(vert) and vert.size() > 3)

	print("== 3. WireRoute.basis_along")
	for d in [Vector3.UP, Vector3.DOWN, Vector3.RIGHT, Vector3(1, 2, 3), Vector3(0, 0, -4)]:
		var b := WireRoute.basis_along(d)
		var ok := b.y.is_equal_approx(d.normalized()) and absf(b.x.dot(b.y)) < 0.0001 and absf(b.x.dot(b.z)) < 0.0001 \
				and is_equal_approx(b.x.length(), 1.0) and is_equal_approx(b.z.length(), 1.0) and is_equal_approx(b.determinant(), 1.0)
		check("базис вдоль %s: Y по направлению, ортонормирован" % str(d), ok, str(b))

	print("== 4. WireMesh")
	var empty := WireMesh.build(PackedVector3Array([Vector3.ZERO]), false)
	check("одна точка: пустой меш", empty.get_surface_count() == 0)
	var line := PackedVector3Array([Vector3(0, 0, 0), Vector3(20, 0, 0)])
	var plain := WireMesh.build(line, false)
	check("две поверхности (жилы)", plain.get_surface_count() == 2)
	var verts0: PackedVector3Array = plain.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check("вершины: два кольца", verts0.size() == 2 * WireMesh.RADIAL and _finite(verts0), str(verts0.size()))
	var c0 := _ring_center(verts0, 0)
	var c1 := _ring_center(verts0, 1)
	var off0 := Vector2(c0.y - c1.y, c0.z - c1.z).length()
	check("без скрутки жила не меняет сторону", off0 < 0.0001, str(off0))
	var tw := WireMesh.build(line, true)
	var tv: PackedVector3Array = tw.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check("скрутка: добавлены кольца на длинном отрезке", tv.size() > 2 * WireMesh.RADIAL and tv.size() % WireMesh.RADIAL == 0 and _finite(tv), str(tv.size()))
	var rings := tv.size() / WireMesh.RADIAL
	var s0 := _ring_center(tv, 0)
	var s1 := _ring_center(tv, rings - 1)
	var swap := Vector2(s0.y - s1.y, s0.z - s1.z).length()
	check("скрутка: жилы к концу поменялись местами (2 радиуса жилы)", is_equal_approx(swap, 2.0 * WireMesh.CORE_RADIUS), str(swap))
	var bent := WireMesh.build(WireRoute.from_polyline(l_shape).smooth(), true)
	var bv: PackedVector3Array = bent.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
	check("изогнутый провод со скруткой: вершины конечные", _finite(bv) and bv.size() > 0)
	var vertical := WireMesh.build(PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 10, 0)]), true)
	var vv: PackedVector3Array = vertical.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check("вертикальный провод со скруткой: вершины конечные", _finite(vv) and vv.size() > 0)
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
