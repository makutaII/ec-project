class_name WireRoute extends RefCounted

# XX claude-wire W1 (новый файл)
#####################
## Трасса провода (ATTN_23 §23.9.5, W1)
#####################
## Чистая логика без сцены: ломаная провода в мировых координатах, длина, скругление углов, система координат вдоль отрезка.
## Тестируется без игры (tests/wire_route_test). Поверхности трассы (стол, низ плиты, рама, ввод) добавляет W5.

## Насколько от угла отступает скругление, u. Короткий отрезок отдаёт углу не больше половины своей длины
const BEND_RADIUS := 1.2
## Точки на дугу скругления
const ARC_STEPS := 4
## Точки ближе этого расстояния считаются одной
const MIN_SEG := 0.001

var points := PackedVector3Array()


static func from_polyline(line: PackedVector3Array) -> WireRoute:
	var r := WireRoute.new()
	r.points = dedupe(line)
	return r


## Убирает подряд идущие совпадающие точки
static func dedupe(line: PackedVector3Array) -> PackedVector3Array:
	var res := PackedVector3Array()
	for p in line:
		if res.is_empty() or res[res.size() - 1].distance_to(p) > MIN_SEG:
			res.append(p)
	return res


static func polyline_length(line: PackedVector3Array) -> float:
	var l := 0.0
	for i in range(1, line.size()):
		l += line[i - 1].distance_to(line[i])
	return l


## Длина по ломаной (по углам, без скругления), u
func length() -> float:
	return polyline_length(points)


## Ломаная со скруглёнными углами: каждый угол заменяется дугой (квадратичная кривая Безье). Концы остаются на месте.
## Прямые углы (колинеарные точки) и разворот на 180 градусов не скругляются
func smooth(bend_radius := BEND_RADIUS) -> PackedVector3Array:
	var n := points.size()
	if n < 3:
		return points.duplicate()
	var res := PackedVector3Array()
	res.append(points[0])
	for i in range(1, n - 1):
		var p := points[i]
		var da := points[i - 1] - p
		var db := points[i + 1] - p
		var la := da.length()
		var lb := db.length()
		if la < MIN_SEG or lb < MIN_SEG:
			res.append(p)
			continue
		var u := da / la
		var v := db / lb
		var cosv := u.dot(v)
		if cosv < -0.9999 or cosv > 0.9999:
			res.append(p)
			continue
		var d := minf(bend_radius, minf(la, lb) * 0.5)
		var p1 := p + u * d
		var p2 := p + v * d
		for k in ARC_STEPS + 1:
			var t := float(k) / float(ARC_STEPS)
			var q := p1 * ((1.0 - t) * (1.0 - t)) + p * (2.0 * (1.0 - t) * t) + p2 * (t * t)
			res.append(q)
	res.append(points[n - 1])
	return dedupe(res)


## Базис, у которого ось Y направлена вдоль dir (для цилиндров по отрезку). dir любой ненулевой, в том числе вертикаль
static func basis_along(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.RIGHT if absf(y.y) > 0.99 else Vector3.UP
	var x := ref.cross(y).normalized()
	var z := x.cross(y)
	return Basis(x, y, z)
