class_name FoamCutter extends RefCounted

# XX claude-terra 13.3 S1 (новый файл)
#######################
## Ядро терморезака (ATTN_13 §13.3). Чистые функции без состояния, UI нет.
#######################
## Вырез задаётся в мире: полигон XZ и диапазон высот [y_lo, y_hi). apply() режет все листы, которые под него попали
## (стопка листов тоже), и для каждого листа создаёт обычный FoamCut: локальный полигон и номера слоёв.
## Формат сейва листа не меняется, контур листа не трогается (решение Д3).
## Слой, задетый диапазоном хоть частично, режется целиком (так же, как автовырезы под балласт).
## Формы (rect, polygon, strip, half_plane) возвращают мировой полигон с обходом против часовой стрелки
## или пустой массив, если форма не вышла. Причину отказа даёт check() (и strip_why() для полосы).
## Вершины приходят от инструмента на мировой сетке terrain_grid_step; после перевода в локальные координаты
## листа они округляются до 0,001 (без хвостов плавающей точки в сейве).

## Наибольшее число вершин выреза (полоса по 30 точкам оси даёт почти вдвое больше точек)
const MAX_POINTS := 128
## Полоса: допустимая ширина, ю
const STRIP_WIDTH_MIN := 1.0
const STRIP_WIDTH_MAX := 40.0
## Полуплоскость строится квадратом такой стороны, а перед записью в лист обрезается по его габариту
const REACH := 400.0
## Допуск при переводе высоты в слой (как в C_TerrainLayer._track_cuts)
const LEVEL_EPS := 0.001
## Точность локальных координат
const ROUND := 0.001
## Запас вокруг листа при обрезке выреза по габариту, ю
const WINDOW_GROW := 1.0


## --- Формы ---

## Прямоугольник по двум противоположным углам. Пустой, если одна из сторон нулевая
static func rect(a: Vector2, b: Vector2) -> PackedVector2Array:
	var lo := a.min(b)
	var hi := a.max(b)
	if hi.x - lo.x < C_Contour.EPS or hi.y - lo.y < C_Contour.EPS:
		return PackedVector2Array()
	return PackedVector2Array([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)])


## Произвольный полигон: убираем повторы и коллинеарные вершины, обход делаем против часовой.
## Меньше трёх вершин после чистки: пустой массив
static func polygon(points: PackedVector2Array) -> PackedVector2Array:
	var p := C_Contour.cleaned(points)
	if p.size() < 3:
		return PackedVector2Array()
	if C_Contour.signed_area(p) < 0.0:
		p.reverse()
	return p


## Полоса вдоль ломаной оси шириной width (стык MITER, торцы прямые, как у листа-полосы 13.2 B5).
## Пустой массив: не вышло, причина в strip_why()
static func strip(axis: PackedVector2Array, width: float) -> PackedVector2Array:
	var r := _strip_raw(axis, width)
	if r.size() != 1:
		return PackedVector2Array()
	var out: PackedVector2Array = r[0]
	for i in out.size():
		out[i] = _round2(out[i])
	if C_Contour.signed_area(out) < 0.0:
		out.reverse()
	return out


## Почему не вышла полоса ("" - вышла)
static func strip_why(axis: PackedVector2Array, width: float) -> String:
	if axis.size() < 2:
		return "Нужно минимум 2 точки оси"
	if axis.size() > C_PolygonDraw.MAX_AXIS:
		return "Больше %d точек оси" % C_PolygonDraw.MAX_AXIS
	var r := _strip_raw(axis, width)
	if r.size() != 1:
		return "Полоса образует петлю или дыру"
	return ""


static func _strip_raw(axis: PackedVector2Array, width: float) -> Array[PackedVector2Array]:
	var res: Array[PackedVector2Array] = []
	if axis.size() < 2 or axis.size() > C_PolygonDraw.MAX_AXIS:
		return res
	var w := clampf(width, STRIP_WIDTH_MIN, STRIP_WIDTH_MAX)
	for pc: PackedVector2Array in Geometry2D.offset_polyline(axis, w * 0.5, Geometry2D.JOIN_MITER, Geometry2D.END_BUTT):
		res.append(pc)
	return res


## Полуплоскость по прямой a-b: та сторона, где лежит точка side (линия-рез, «отсечь край»).
## Пустой, если a и b совпали или side лежит на самой прямой. reach: на сколько ю полуплоскость уходит от прямой и вдоль неё
static func half_plane(a: Vector2, b: Vector2, side: Vector2, reach: float = REACH) -> PackedVector2Array:
	var d := b - a
	if d.length() < C_Contour.EPS:
		return PackedVector2Array()
	d = d.normalized()
	var n := Vector2(-d.y, d.x)
	var s := n.dot(side - a)
	if absf(s) < C_Contour.EPS:
		return PackedVector2Array()
	if s < 0.0:
		n = -n
	var p0 := a - d * reach
	var p1 := b + d * reach
	var res := PackedVector2Array([p0, p1, p1 + n * reach, p0 + n * reach])
	if C_Contour.signed_area(res) < 0.0:
		res.reverse()
	return res


## 13.3 S5. Ступенчатый скос. Прямая a-b это гребень (верх скоса), сторона side та, где пенопласт убирается.
## Слой k (k = 0 верхний) вырезается там, где расстояние от гребня не меньше k * run: получается лестница из count
## ступеней, каждая шириной run. Возвращает по одному полигону на слой (индекс = k), пустой массив: a и b совпали,
## side лежит на прямой, run <= 0 или count < 1. Вырезы по слоям это обычные FoamCut: модель и сейв не меняются
static func bevel_steps(a: Vector2, b: Vector2, side: Vector2, run: float, count: int, reach: float = REACH) -> Array[PackedVector2Array]:
	var res: Array[PackedVector2Array] = []
	if run <= 0.0 or count < 1:
		return res
	var d := b - a
	if d.length() < C_Contour.EPS:
		return res
	d = d.normalized()
	var n := Vector2(-d.y, d.x)
	var s := n.dot(side - a)
	if absf(s) < C_Contour.EPS:
		return res
	if s < 0.0:
		n = -n
	for k in count:
		var shift := n * (float(k) * run)
		res.append(half_plane(a + shift, b + shift, side + shift, reach))
	return res


## K6 (скос по ребру). Ребро a-b контура листа, inward: единичный вектор внутрь листа, run: ширина ступени, count: высота
## скоса в слоях. Возвращает по одному прямоугольнику на слой (индекс = k, 0 верхний), как bevel_steps: слой k режется
## на (count - k) * run внутрь от ребра и на margin наружу, вдоль ребра ровно от a до b. Верхний слой самый широкий,
## нижний шириной run: лестница из count ступеней по run, нижняя ступень у самого ребра. Пустой массив: ребро нулевое,
## run <= 0, count < 1 или inward нулевой
static func bevel_edge(a: Vector2, b: Vector2, inward: Vector2, run: float, count: int, margin: float) -> Array[PackedVector2Array]:
	var res: Array[PackedVector2Array] = []
	if run <= 0.0 or count < 1 or (b - a).length() < C_Contour.EPS or inward.length() < C_Contour.EPS:
		return res
	var n := inward.normalized()
	for k in count:
		var dk := float(count - k) * run
		var quad := PackedVector2Array([a + n * dk, b + n * dk, b - n * margin, a - n * margin])
		if C_Contour.signed_area(quad) < 0.0:
			quad.reverse()
		res.append(quad)
	return res


## Ближайшее к точке p ребро полигона: {"a", "b", "dist", "inward"} (inward: единичный вектор внутрь полигона).
## Пустой словарь: полигон меньше треугольника
static func nearest_edge(poly: PackedVector2Array, p: Vector2) -> Dictionary:
	var n := poly.size()
	if n < 3:
		return {}
	var best := -1
	var best_d := INF
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_to(q)
		if d < best_d:
			best_d = d
			best = i
	var ea := poly[best]
	var eb := poly[(best + 1) % n]
	var dir := (eb - ea).normalized()
	var inw := Vector2(-dir.y, dir.x)
	var mid := (ea + eb) * 0.5
	if not Geometry2D.is_point_in_polygon(mid + inw * 0.05, poly):
		inw = -inw
	return {"a": ea, "b": eb, "dist": best_d, "inward": inw}


## Вырезать скос: polys из bevel_steps, y_top = верх скоса (плоскость). Слой k режется в диапазоне
## [y_top - (k + 1) * T, y_top - k * T). Записи для revert() общие на весь скос
static func apply_bevel(polys: Array[PackedVector2Array], y_top: float, only: C_TerrainLayer = null) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var T: float = Global.settings.layer_height
	for k in polys.size():
		var yt := y_top - float(k) * T
		res.append_array(apply(polys[k], yt - T, yt, only))
	return res


## Годен ли вырез: причина отказа или "". Те же правила, что у контура листа (D3): без самопересечений,
## ребро не короче шага сетки, площадь не меньше 1 ю², вершин не больше MAX_POINTS
static func check(poly: PackedVector2Array) -> String:
	if poly.size() < 3:
		return "Меньше 3 вершин"
	return C_Contour.validate(poly, MAX_POINTS)


## --- Перевод в слои и локальные координаты ---

## Слои [from, to) листа, которые задевает диапазон высот [y_lo, y_hi). Vector2i.ZERO (to <= from): не задевает.
## base_y: низ листа, levels: толщина в слоях, T: layer_height
static func level_range(base_y: float, levels: int, y_lo: float, y_hi: float, T: float) -> Vector2i:
	var lv := maxi(1, levels)
	var a := clampf((y_lo - base_y) / T + LEVEL_EPS, 0.0, float(lv))
	var b := clampf((y_hi - base_y) / T - LEVEL_EPS, 0.0, float(lv))
	var f := floori(a)
	var t := ceili(b)
	if t <= f:
		return Vector2i.ZERO
	return Vector2i(f, t)


## Мировой полигон в локальные координаты листа (inv = обратная к global_transform Entity), округление до ROUND,
## повторы убраны, обход против часовой. Пустой массив: после округления вырожден
static func to_local(poly: PackedVector2Array, inv: Transform3D) -> PackedVector2Array:
	var res := PackedVector2Array()
	for p in poly:
		var l := inv * Vector3(p.x, 0.0, p.y)
		res.append(_round2(Vector2(l.x, l.z)))
	return polygon(res)


## Обрезка выреза по окну (габарит листа с запасом). Полигон внутри окна возвращается как есть.
## Результат может состоять из нескольких кусков (вогнутый вырез). Обход против часовой, мусор отброшен
static func clip_to_window(poly: PackedVector2Array, win: Rect2) -> Array[PackedVector2Array]:
	var res: Array[PackedVector2Array] = []
	if poly.size() < 3:
		return res
	if win.encloses(C_Contour.bounds_of(poly)):
		res.append(poly)
		return res
	var w := PackedVector2Array([win.position, Vector2(win.end.x, win.position.y), win.end, Vector2(win.position.x, win.end.y)])
	for pc: PackedVector2Array in Geometry2D.intersect_polygons(poly, w):
		var q := pc.duplicate()
		var a := C_Contour.signed_area(q)
		if absf(a) < C_TerrainLayer.MIN_PIECE_AREA:
			continue
		if a < 0.0:
			q.reverse()
		res.append(q)
	return res


static func _round2(v: Vector2) -> Vector2:
	return Vector2(snappedf(v.x, ROUND), snappedf(v.y, ROUND))


## --- Применение к листам ---

## Листы, которые вырез реально заденет (в диапазоне высот под полигоном есть твёрдое тело). Для превью инструмента
static func affected(world_poly: PackedVector2Array, y_lo: float, y_hi: float, only: C_TerrainLayer = null) -> Array[C_TerrainLayer]:
	return _overlapped(world_poly, y_lo, y_hi, false, only)


## K3d. Листы с гипсовым бинтом, которые вырез задел бы: они не режутся, инструмент говорит об этом
static func blocked(world_poly: PackedVector2Array, y_lo: float, y_hi: float, only: C_TerrainLayer = null) -> Array[C_TerrainLayer]:
	return _overlapped(world_poly, y_lo, y_hi, true, only)


## K3d. Сколько разных листов с бинтом задел бы скос (те же диапазоны высот, что у apply_bevel)
static func blocked_bevel(polys: Array[PackedVector2Array], y_top: float, only: C_TerrainLayer = null) -> int:
	var seen := {}
	var T: float = Global.settings.layer_height
	for k in polys.size():
		var yt := y_top - float(k) * T
		for l in blocked(polys[k], yt - T, yt, only):
			seen[l] = true
	return seen.size()


## Листы под вырезом: с бинтом (plastered) или без. only: только этот лист (скос по ребру не режет соседей)
static func _overlapped(world_poly: PackedVector2Array, y_lo: float, y_hi: float, plastered: bool, only: C_TerrainLayer = null) -> Array[C_TerrainLayer]:
	var res: Array[C_TerrainLayer] = []
	if world_poly.size() < 3 or y_hi <= y_lo or not is_instance_valid(TGM):
		return res
	var T: float = Global.settings.layer_height
	for e in TGM.get_layers():
		var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
		if l == null or (l.smooth > 0) != plastered or (only != null and l != only):
			continue
		var lr := level_range(l.base_y(), l.levels, y_lo, y_hi, T)
		if lr.y <= lr.x:
			continue
		if l.overlaps(world_poly, l.base_y() + float(lr.x) * T, l.base_y() + float(lr.y) * T):
			res.append(l)
	return res


## Вырезать объём (мировой полигон, диапазон высот) из всех листов под ним. Возвращает записи
## {"layer": C_TerrainLayer, "cut": FoamCut} для revert(). Пустой массив: резать нечего
static func apply(world_poly: PackedVector2Array, y_lo: float, y_hi: float, only: C_TerrainLayer = null) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var T: float = Global.settings.layer_height
	for l in affected(world_poly, y_lo, y_hi, only):
		var lr := level_range(l.base_y(), l.levels, y_lo, y_hi, T)
		var win := C_Contour.bounds_of(l.world_polygon()).grow(WINDOW_GROW)
		var inv := l.entity.global_transform.affine_inverse()
		for piece in clip_to_window(world_poly, win):
			var local := to_local(piece, inv)
			if local.size() < 3:
				continue
			var c := l.add_cut(local, lr.x, lr.y)
			if c != null:
				res.append({"layer": l, "cut": c})
	return res


## Откатить записи apply() (в обратном порядке). Лист мог исчезнуть или уже потерять вырез (например, подрезан
## при уменьшении толщины): такие записи пропускаются. Возвращает число снятых вырезов
static func revert(records: Array[Dictionary]) -> int:
	var n := 0
	for i in range(records.size() - 1, -1, -1):
		var raw: Variant = records[i].get("layer")
		if not is_instance_valid(raw):   # лист удалён: приведение типа к освобождённому объекту дало бы ошибку
			continue
		var l := raw as C_TerrainLayer
		var c := records[i].get("cut") as FoamCut
		if l == null or c == null:
			continue
		if l.remove_cut(c):
			n += 1
	return n
