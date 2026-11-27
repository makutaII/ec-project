class_name WireRouter extends RefCounted

# XX claude-wire W7 (новый файл)
#####################
## Роутер автопроводки под столом (ATTN_23 §23.9, W7)
#####################
## Чистая логика без сцены: маршрут между двумя точками на поверхностях. Клемма на плите уходит вниз через ввод (отверстие рядом с ней),
## дальше провод идёт по нижней полке Г-образно или зигзагом в обход ножек и подрамника, у второй клеммы поднимается через ввод.
## Клемма блока на полке ввода не требует. Маршрут ложится на поверхности: ни одного отрезка по воздуху.
##
## ctx (Dictionary):
##   walkable: Array[PackedVector2Array]  где по полке можно вести провод (полка без подрамника)
##   keepouts: Array[Rect2]               запретные прямоугольники в плане (ножки с запасом)
##   shelf_y: float                       высота оси провода на полке
##   surface_y: Callable(x, z) -> float   высота оси провода на основной поверхности в точке ввода
##   hole_reason: Callable(Vector3) -> String   можно ли отверстие в плите в точке, пусто = можно
##   lane: int                            номер провода в серии: соседние провода идут зигзагом со сдвигом, не слипаются

## Расстояния от клеммы до ввода, перебираются по возрастанию, u
const HOLE_DISTANCES := [2.5, 4.0, 6.0, 9.0]
## Повороты направления поиска ввода от направления на цель, градусы
const HOLE_ANGLES := [0.0, 45.0, -45.0, 90.0, -90.0, 135.0, -135.0, 180.0]
## Сдвиг соседних проводов серии, u
const LANE_STEP := 0.4
## Шаг проверки отрезка пути на препятствия, u
const SAMPLE_STEP := 1.0
## Доли пути для зигзага: где ставится поперечный ход
const ZIG_T := [0.5, 0.25, 0.75, 0.1, 0.9]


## pa, pb: точки, где провод выходит на поверхность у клемм (после _drop). Возвращает узлы от pa до pb или пустой массив, если не вышло
static func route(pa: Vector3, pb: Vector3, ctx: Dictionary) -> PackedVector3Array:
	var shelf_y: float = ctx["shelf_y"]
	var head := PackedVector3Array()
	var tail := PackedVector3Array()
	var sa := Vector3(pa.x, shelf_y, pa.z)
	var sb := Vector3(pb.x, shelf_y, pb.z)
	if Mount.under_plate(pa.y):
		head.append(pa)
	else:
		var h: Variant = _hole(pa, pb, ctx)
		if h == null:
			return PackedVector3Array()
		var hp: Vector3 = h
		sa = Vector3(hp.x, shelf_y, hp.z)
		head = PackedVector3Array([pa, Vector3(hp.x, ctx["surface_y"].call(hp.x, hp.z), hp.z), sa])
	if Mount.under_plate(pb.y):
		tail.append(pb)
	else:
		var h2: Variant = _hole(pb, pa, ctx)
		if h2 == null:
			return PackedVector3Array()
		var hq: Vector3 = h2
		sb = Vector3(hq.x, shelf_y, hq.z)
		tail = PackedVector3Array([sb, Vector3(hq.x, ctx["surface_y"].call(hq.x, hq.z), hq.z), pb])
	var mid: Variant = _shelf_path(sa, sb, ctx)
	if mid == null:
		return PackedVector3Array()
	var res := PackedVector3Array()
	res.append_array(head)
	res.append_array(mid as PackedVector3Array)
	res.append_array(tail)
	return WireRoute.dedupe(res)


## Место ввода рядом с клеммой: ближайшая допустимая точка в стороне цели, потом вокруг. null: нет места
static func _hole(pe: Vector3, target: Vector3, ctx: Dictionary) -> Variant:
	var dir := Vector2(target.x - pe.x, target.z - pe.z)
	dir = Vector2.RIGHT if dir.length() < 0.01 else dir.normalized()
	for dist in HOLE_DISTANCES:
		for ang in HOLE_ANGLES:
			var p := Vector2(pe.x, pe.z) + dir.rotated(deg_to_rad(ang)) * dist
			if _hole_ok(p, ctx):
				return Vector3(p.x, 0.0, p.y)
	return null


static func _hole_ok(p: Vector2, ctx: Dictionary) -> bool:
	if ctx["hole_reason"].call(Vector3(p.x, 0.0, p.y)) != "":
		return false
	return _walkable(p, ctx) and not _in_keepout(p, ctx)


static func _walkable(p: Vector2, ctx: Dictionary) -> bool:
	for poly in ctx["walkable"]:
		if Geometry2D.is_point_in_polygon(p, poly):
			return true
	return false


static func _in_keepout(p: Vector2, ctx: Dictionary) -> bool:
	for r in ctx["keepouts"]:
		if (r as Rect2).has_point(p):
			return true
	return false


## Промежуточные узлы пути по полке от sa до sb (без самих sa, sb) или null. Серия (lane != 0) предпочитает зигзаг со сдвигом
static func _shelf_path(sa: Vector3, sb: Vector3, ctx: Dictionary) -> Variant:
	var a := Vector2(sa.x, sa.z)
	var b := Vector2(sb.x, sb.z)
	var shelf_y: float = ctx["shelf_y"]
	var lane: int = ctx["lane"]
	var shift := float((lane % 5) - 2) * LANE_STEP
	var plain: Array = [[], [Vector2(b.x, a.y)], [Vector2(a.x, b.y)]]
	var zig: Array = []
	for t in ZIG_T:
		var mx := lerpf(a.x, b.x, t) + shift
		var mz := lerpf(a.y, b.y, t) + shift
		zig.append([Vector2(mx, a.y), Vector2(mx, b.y)])
		zig.append([Vector2(a.x, mz), Vector2(b.x, mz)])
	var order: Array = []
	if lane != 0:
		order.append_array(zig)
		order.append_array(plain)
	else:
		order.append_array(plain)
		order.append_array(zig)
	var best: Array = []
	var best_len := INF
	for corners in order:
		var pts: Array = [a] + corners + [b]
		if not _path_ok(pts, ctx):
			continue
		if lane != 0:
			best = corners   # при серии берём первый подходящий зигзаг (порядок выше)
			break
		var l := _length(pts)
		if l < best_len:
			best_len = l
			best = corners
	if best_len == INF and lane == 0:
		return null
	if lane != 0 and best.is_empty() and not _path_ok([a, b], ctx):
		return null
	var res := PackedVector3Array()
	for c in best:
		res.append(Vector3((c as Vector2).x, shelf_y, (c as Vector2).y))
	return res


static func _length(pts: Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += (pts[i - 1] as Vector2).distance_to(pts[i] as Vector2)
	return l


## Путь по ломаной pts (в плане): внутренние точки внутри полки (без подрамника) и вне ножек. Концы не проверяются: клемма может стоять у края
static func _path_ok(pts: Array, ctx: Dictionary) -> bool:
	for i in range(1, pts.size()):
		var p: Vector2 = pts[i - 1]
		var q: Vector2 = pts[i]
		var n := maxi(1, ceili(p.distance_to(q) / SAMPLE_STEP))
		for k in range(0, n + 1):
			if (i == 1 and k == 0) or (i == pts.size() - 1 and k == n):
				continue
			var s := p.lerp(q, float(k) / float(n))
			if not _walkable(s, ctx) or _in_keepout(s, ctx):
				return false
	return true
