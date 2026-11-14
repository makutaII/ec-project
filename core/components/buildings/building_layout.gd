class_name BuildingLayout extends RefCounted

# XX claude-library L7 (новый файл)
########################
## BuildingLayout. Раскладка здания по BuildingSpec: контур, стены, окна и дверь, крыша (ATTN_22 §22.7.6, шаг L7)
########################
## Чистые данные, без нод и ресурсов: считается на любой машине одинаково (сид идёт через хэш строки, не через randi).
## Система координат здания: начало в центре плана на земле, Y вверх, дверь на стороне -Z (если не задана иначе).
## План лежит в плоскости (x, z) и хранится как Vector2(x, z). Ребро контура i идёт от вершины i к вершине i + 1.
## Правила окон (по длине стены, этажу, сиду):
##  - окна ставятся на каждый этаж, число на стене по модулю MODULE / density, края окон не ближе CORNER_MARGIN к углу;
##  - на первом этаже в одной ячейке стены с дверью вместо окна дверь; если на ней окон нет, дверь по центру;
##  - ширина окна выбирается из трёх по сиду, на верхних этажах при трёх и более ячейках окно иногда пропускается;
##  - у двускатной крыши в центре каждого фронтона слуховое окно, если оно помещается в треугольник.
## Контуры только с прямыми углами (смещение контура для цоколя и крыши считается по нормалям рёбер).

const PLINTH_H := 0.45         ## высота цоколя над землёй
const SKIRT := 0.6             ## юбка вниз под фундамент
const CORNER_MARGIN := 0.9     ## от угла до края окна
const MODULE := 2.6            ## ширина ячейки окна при density 1
const MIN_USABLE := 1.2        ## на стене меньше этого после отступов окон нет
const DOOR_W := 1.0
const SILL_GROUND := 1.25      ## низ окна первого этажа над землёй
const SILL_UPPER := 0.9        ## низ окна верхнего этажа над полом этажа
const FLAT_ROOF_H := 0.3
const WIN_WIDTHS := [0.9, 1.1, 1.3]
const ATTIC_MIN_SPAN := 3.0

enum Kind { WINDOW, DOOR, ATTIC }


class Edge extends RefCounted:
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	var dir := Vector2.ZERO
	## Наружу из здания
	var normal := Vector2.ZERO
	var length := 0.0


class Opening extends RefCounted:
	var edge := 0
	var kind := 0   ## Kind
	## 0 первый этаж; у слухового окна номер равен числу этажей
	var floor_idx := 0
	## Центр от начала ребра, ю
	var u := 0.0
	var width := 1.0
	## Низ над землёй
	var y0 := 0.0
	var height := 1.0


class RoofPiece extends RefCounted:
	var x0 := 0.0
	var z0 := 0.0
	var x1 := 0.0
	var z1 := 0.0
	var ridge_x := true
	## Размер поперёк конька
	var span := 0.0
	## Высота конька над линией карниза
	var rise := 0.0


var spec: BuildingSpec
var poly := PackedVector2Array()
var edges: Array[Edge] = []
var openings: Array[Opening] = []
var pieces: Array[RoofPiece] = []
## Прямоугольные плечи плана (для крыши и коллизии): один у прямоугольника, два у L (плечо вдоль X и плечо вдоль Z)
var arms: Array[Rect2] = []
## Высота стен (до карниза)
var wall_h := 0.0
## Высота конька над стенами (наибольшая) или плоской крыши
var roof_h := 0.0
var door_edge := -1


static func build(p_spec: BuildingSpec) -> BuildingLayout:
	var l := BuildingLayout.new()
	l.spec = p_spec.duplicate_spec()
	l._make_plan()
	l._make_roof()
	l._make_openings()
	return l


## Габарит без свесов: от низа юбки до конька
func bounds() -> AABB:
	return AABB(Vector3(-spec.width * 0.5, -SKIRT, -spec.depth * 0.5), Vector3(spec.width, SKIRT + wall_h + roof_h, spec.depth))


## Коробки коллизии: по одной на плечо, от низа юбки до конька плеча
func collision_boxes() -> Array[AABB]:
	var out: Array[AABB] = []
	for i in arms.size():
		var r := arms[i]
		var rise := pieces[i].rise if i < pieces.size() else FLAT_ROOF_H
		out.append(AABB(Vector3(r.position.x, -SKIRT, r.position.y), Vector3(r.size.x, SKIRT + wall_h + rise, r.size.y)))
	return out


## Контур, смещённый наружу на d (только прямые углы: вершина сдвигается на сумму нормалей смежных рёбер)
func offset_poly(d: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := poly.size()
	for i in n:
		var prev := edges[(i - 1 + n) % n]
		var next := edges[i]
		out.append(poly[i] + (prev.normal + next.normal) * d)
	return out


## Ребро контура, на котором лежит точка (x, z); -1 если не лежит. Возвращает и расстояние от начала ребра
func edge_at(p: Vector2) -> Dictionary:
	for i in edges.size():
		var e := edges[i]
		var rel := p - e.a
		var along := rel.dot(e.dir)
		var off := rel.dot(e.normal)
		if absf(off) < 0.01 and along > 0.01 and along < e.length - 0.01:
			return {"edge": i, "u": along}
	return {"edge": -1, "u": 0.0}


## Точка стены в системе здания: ребро e, расстояние вдоль u, высота y, вынос наружу off
func wall_point(e: Edge, u: float, y: float, off: float) -> Vector3:
	var p := e.a + e.dir * u + e.normal * off
	return Vector3(p.x, y, p.y)


## Окна стены (без двери), для света
func windows_of_edge(ei: int) -> Array[Opening]:
	var out: Array[Opening] = []
	for o in openings:
		if o.edge == ei and o.kind != Kind.DOOR:
			out.append(o)
	return out


# ==========================================
# План
# ==========================================

func _make_plan() -> void:
	var hw := spec.width * 0.5
	var hd := spec.depth * 0.5
	wall_h = spec.floors * spec.floor_h
	poly = PackedVector2Array()
	arms.clear()
	if spec.is_l():
		var nw := spec.notch_w
		var nd := spec.notch_d
		poly.append(Vector2(-hw, -hd))
		poly.append(Vector2(hw, -hd))
		poly.append(Vector2(hw, hd - nd))
		poly.append(Vector2(hw - nw, hd - nd))
		poly.append(Vector2(hw - nw, hd))
		poly.append(Vector2(-hw, hd))
		arms.append(Rect2(-hw, -hd, spec.width, spec.depth - nd))     # плечо вдоль X
		arms.append(Rect2(-hw, -hd, spec.width - nw, spec.depth))     # плечо вдоль Z
	else:
		poly.append(Vector2(-hw, -hd))
		poly.append(Vector2(hw, -hd))
		poly.append(Vector2(hw, hd))
		poly.append(Vector2(-hw, hd))
		arms.append(Rect2(-hw, -hd, spec.width, spec.depth))

	var area := 0.0
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	edges.clear()
	for i in n:
		var e := Edge.new()
		e.a = poly[i]
		e.b = poly[(i + 1) % n]
		e.length = e.a.distance_to(e.b)
		e.dir = (e.b - e.a) / e.length
		e.normal = Vector2(e.dir.y, -e.dir.x) if area > 0.0 else Vector2(-e.dir.y, e.dir.x)
		edges.append(e)


func _make_roof() -> void:
	pieces.clear()
	roof_h = FLAT_ROOF_H
	if spec.roof != BuildingSpec.Roof.GABLE:
		return
	roof_h = 0.0
	for r in arms:
		var p := RoofPiece.new()
		p.x0 = r.position.x
		p.z0 = r.position.y
		p.x1 = r.end.x
		p.z1 = r.end.y
		p.ridge_x = r.size.x >= r.size.y
		p.span = minf(r.size.x, r.size.y)
		p.rise = maxf(spec.pitch * p.span * 0.5, 0.35)
		roof_h = maxf(roof_h, p.rise)
		pieces.append(p)


# ==========================================
# Окна и дверь
# ==========================================

func _make_openings() -> void:
	openings.clear()
	door_edge = _pick_door_edge()
	var wh := clampf(spec.floor_h * 0.45, 1.0, 1.6)
	var door_h := minf(2.0, spec.floor_h - 0.7)
	for ei in edges.size():
		var e := edges[ei]
		var usable := e.length - 2.0 * CORNER_MARGIN
		var n := 0
		if usable >= MIN_USABLE:
			n = maxi(1, int(floor(usable / (MODULE / spec.density))))
		var cell := usable / float(n) if n > 0 else 0.0
		var door_cell := -1
		if ei == door_edge and n > 0:
			door_cell = mini(int(_rand(ei, 0, 0, 3) * n), n - 1)
		for f in spec.floors:
			for i in n:
				var u := CORNER_MARGIN + cell * (float(i) + 0.5)
				if f == 0 and i == door_cell:
					_add(ei, Kind.DOOR, 0, u, DOOR_W, BuildingLayout.PLINTH_H, door_h)
					continue
				if f >= 1 and n >= 3 and _rand(ei, f, i, 7) < 0.10:
					continue
				var w: float = WIN_WIDTHS[int(_rand(ei, f, i, 5) * WIN_WIDTHS.size()) % WIN_WIDTHS.size()]
				w = minf(w, cell * 0.7)
				var y0 := f * spec.floor_h + (SILL_GROUND if f == 0 else SILL_UPPER)
				_add(ei, Kind.WINDOW, f, u, w, y0, wh)
		if ei == door_edge and n == 0 and e.length >= 1.8:
			_add(ei, Kind.DOOR, 0, e.length * 0.5, DOOR_W, BuildingLayout.PLINTH_H, door_h)
	_make_attic_windows()


func _add(ei: int, kind: int, f: int, u: float, w: float, y0: float, h: float) -> void:
	var o := Opening.new()
	o.edge = ei
	o.kind = kind
	o.floor_idx = f
	o.u = u
	o.width = w
	o.y0 = y0
	o.height = h
	openings.append(o)


func _pick_door_edge() -> int:
	if spec.door_wall >= 0 and spec.door_wall < edges.size():
		return spec.door_wall
	var best := 0
	var best_score := -1.0
	for i in edges.size():
		var e := edges[i]
		var score := e.length + (100.0 if e.normal.y < -0.9 else 0.0)
		if score > best_score:
			best_score = score
			best = i
	return best


## Слуховое окно в центре каждого фронтона, если помещается в треугольник
func _make_attic_windows() -> void:
	for p in pieces:
		if p.span < ATTIC_MIN_SPAN:
			continue
		var ah := clampf(p.rise * 0.45, 0.4, 0.9)
		var aw := clampf(p.span * 0.15, 0.5, 0.8)
		var y_off := maxf(0.2, p.rise * 0.12)
		if y_off + ah > p.rise * 0.8:
			continue
		var tri_w := p.span * (1.0 - (y_off + ah) / p.rise)
		if tri_w < aw + 0.5:
			continue
		var ends: Array[Vector2] = []
		if p.ridge_x:
			var zc := (p.z0 + p.z1) * 0.5
			ends.append(Vector2(p.x0, zc))
			ends.append(Vector2(p.x1, zc))
		else:
			var xc := (p.x0 + p.x1) * 0.5
			ends.append(Vector2(xc, p.z0))
			ends.append(Vector2(xc, p.z1))
		for pt in ends:
			var hit := edge_at(pt)
			if int(hit.edge) < 0:
				continue   # торец плеча внутри здания (стыковка с другим плечом): окна нет
			var u := float(hit.u)
			var e := edges[int(hit.edge)]
			if u - aw * 0.5 < 0.5 or u + aw * 0.5 > e.length - 0.5:
				continue   # у самого угла стены окно не ставим (как и у обычных окон)
			_add(int(hit.edge), Kind.ATTIC, spec.floors, u, aw, wall_h + y_off, ah)


## Число 0..1 от сида и четырёх целых: одно и то же на любой машине и в любом запуске
func _rand(a: int, b: int, c: int, salt: int) -> float:
	var h := ("%d|%d|%d|%d|%d" % [spec.seed_id, a, b, c, salt]).hash()
	return float(h & 0xffff) / 65536.0
