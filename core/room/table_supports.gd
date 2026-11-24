class_name TableSupports extends RefCounted

# XX claude-table T3 (новый файл)
###################################
## Опоры подмакетника (ATTN_23 T3): ножки по контуру футпринта. Чистые функции, узлов не создаёт.
###################################
## Ножка стоит в каждом внешнем углу футпринта (объединение секций, LYM.footprint) и через каждые SPAN_MAX u на длинных рёбрах.
## Отступ центра ножки от края плиты: половина ножки + EDGE_INSET (как у стола v1: 200 x 100 даёт те же 4 ножки в углах).
## RoomBuilder строит по этому плану коробки на слое room; пересборка по LYM.layout_changed.

## XX claude-table T4. Рама на полу: ширина бруса и зазор от края плиты, u
const RAIL_W := 4.0
const RAIL_INSET := 1.0
## Кронштейн к стене (T5): ширина, шаг, отступ крайнего от угла секции, наибольший вылет полки, u
const BRK_W := 4.0
const BRK_STEP := 60.0
const BRK_END := 8.0
const BRK_ARM_MAX := 40.0
const BRK_ARM_T := 2.0
const BRK_BACK_H := 22.0
const BRK_BACK_T := 1.5
const BRK_BRACE_T := 1.5
const BRK_BRACE_MAX := 18.0

## XX claude-wire W2. Подрамник (царги) под плитой: высота и ширина бруса, u. Отступ от края плиты как у ножек (EDGE_INSET)
const APRON_H := 6.0
const APRON_W := 2.0

## Зазор от края плиты до ножки, u
const EDGE_INSET := 3.0
## Наибольший пролёт между ножками на длинном ребре, u (стол v1 200 u обходится углами)
const SPAN_MAX := 240.0
## Ножки ближе этого друг к другу считаются одной (стыки секций), u
const MERGE_DIST := 1.0


## Центры ножек (x = X, y = Z) для внешних контуров footprint. Дыры (контуры по часовой стрелке) пропускаются
static func leg_positions(footprint: Array[PackedVector2Array], leg: float) -> PackedVector2Array:
	var d := leg * 0.5 + EDGE_INSET
	var res := PackedVector2Array()
	for raw in footprint:
		if Geometry2D.is_polygon_clockwise(raw):
			continue
		var poly := _cleaned(raw)
		var n := poly.size()
		if n < 3:
			continue
		var normals: Array[Vector2] = []
		for i in n:
			var a := poly[i]
			var b := poly[(i + 1) % n]
			var dir := (b - a).normalized()
			var nrm := Vector2(-dir.y, dir.x)
			if not Geometry2D.is_point_in_polygon((a + b) * 0.5 + nrm * 0.05, poly):
				nrm = -nrm
			normals.append(nrm)
		for i in n:
			var a := poly[i]
			var b := poly[(i + 1) % n]
			var n_prev := normals[(i - 1 + n) % n]
			var n_cur := normals[i]
			_add_unique(res, a + (n_prev + n_cur) * d)
			var edge_len := a.distance_to(b)
			if edge_len > SPAN_MAX:
				var k := int(ceil(edge_len / SPAN_MAX)) - 1
				for j in range(1, k + 1):
					_add_unique(res, a.lerp(b, float(j) / float(k + 1)) + n_cur * d)
	return res


## Контур без повторных и лежащих на одной прямой вершин
static func _cleaned(poly: PackedVector2Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in poly:
		if pts.is_empty() or pts[pts.size() - 1].distance_to(p) > 0.001:
			pts.append(p)
	if pts.size() > 1 and pts[0].distance_to(pts[pts.size() - 1]) <= 0.001:
		pts.remove_at(pts.size() - 1)
	var changed := true
	while changed and pts.size() >= 3:
		changed = false
		for i in pts.size():
			var a := pts[(i - 1 + pts.size()) % pts.size()]
			var b := pts[i]
			var c := pts[(i + 1) % pts.size()]
			if absf((b - a).cross(c - b)) < 0.001:
				pts.remove_at(i)
				changed = true
				break
	return pts


static func _add_unique(list: PackedVector2Array, p: Vector2) -> void:
	for q in list:
		if q.distance_to(p) < MERGE_DIST:
			return
	list.append(p)


## XX claude-table T4. План опор для вида support (LayoutConfig.Support): список деталей-коробок
## {"name", "size": Vector3, "center": Vector3, "basis": Basis}, координаты мира (верх плиты y = 0, пол y = -height).
## Ножки: leg_positions. Рама: брус вдоль каждого ребра футпринта от пола до низа плиты, отступ внутрь.
## Кронштейны: вдоль рёбер, лежащих на стене, через каждые BRK_STEP; контур без стенового ребра (комнату сменили) встаёт на ножки.
## XX claude-wire W2: apron добавляет подрамник под плитой к ножкам (у рамы и кронштейнов свои брусья, им он не нужен)
static func parts(support: int, footprint: Array[PackedVector2Array], height: float, th: float, leg: float,
		cfg: RoomConfig, apron := false) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var leg_h := height - th
	match support:
		LayoutConfig.Support.PLINTH:
			if leg_h <= 0.0:
				return res
			for raw in footprint:
				if Geometry2D.is_polygon_clockwise(raw):
					continue
				_plinth_rails(res, _cleaned(raw), leg_h, height)
		LayoutConfig.Support.WALL:
			for raw in footprint:
				if Geometry2D.is_polygon_clockwise(raw):
					continue
				var poly := _cleaned(raw)
				if poly.size() < 3:
					continue
				if not _wall_brackets(res, poly, th, cfg):
					var one: Array[PackedVector2Array] = [raw]
					_legs(res, one, leg, leg_h, height)   # без стены: на ножки
		_:
			_legs(res, footprint, leg, leg_h, height)
			if apron:
				for raw in footprint:
					if Geometry2D.is_polygon_clockwise(raw):
						continue
					_apron_beams(res, _cleaned(raw), th, leg_h)
	return res


static func _legs(res: Array[Dictionary], footprint: Array[PackedVector2Array], leg: float, leg_h: float, height: float) -> void:
	if leg_h <= 0.0:
		return
	for p in leg_positions(footprint, leg):
		res.append({"name": "Leg", "size": Vector3(leg, leg_h, leg), "center": Vector3(p.x, -height + leg_h * 0.5, p.y),
				"basis": Basis.IDENTITY})


## XX claude-wire W2: подрамник. Брус вдоль каждого ребра контура сразу под плитой (верх бруса на низе плиты), отступ внутрь как у ножек.
## Дыры (контуры по часовой) пропускаются, как у ножек. Нет места под плитой (leg_h <= 0): брусьев нет, высота бруса не больше ножки
static func _apron_beams(res: Array[Dictionary], poly: PackedVector2Array, th: float, leg_h: float) -> void:
	if leg_h <= 0.0:
		return
	var h := minf(APRON_H, leg_h)
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var edge_len := a.distance_to(b) - 2.0 * EDGE_INSET
		if edge_len < APRON_W:
			continue
		var dir := (b - a).normalized()
		var nrm := _inward_normal(poly, a, b)
		var mid := (a + b) * 0.5 + nrm * (APRON_W * 0.5 + EDGE_INSET)
		var dir3 := Vector3(dir.x, 0.0, dir.y)
		res.append({"name": "Apron", "size": Vector3(edge_len, h, APRON_W),
				"center": Vector3(mid.x, -th - h * 0.5, mid.y), "basis": Basis(dir3, Vector3.UP, dir3.cross(Vector3.UP))})


static func _inward_normal(poly: PackedVector2Array, a: Vector2, b: Vector2) -> Vector2:
	var dir := (b - a).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	if not Geometry2D.is_point_in_polygon((a + b) * 0.5 + nrm * 0.05, poly):
		nrm = -nrm
	return nrm


static func _plinth_rails(res: Array[Dictionary], poly: PackedVector2Array, rail_h: float, height: float) -> void:
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var edge_len := a.distance_to(b) - 2.0 * RAIL_INSET
		if edge_len < RAIL_W:
			continue
		var dir := (b - a).normalized()
		var nrm := _inward_normal(poly, a, b)
		var mid := (a + b) * 0.5 + nrm * (RAIL_W * 0.5 + RAIL_INSET)
		var dir3 := Vector3(dir.x, 0.0, dir.y)
		res.append({"name": "Rail", "size": Vector3(edge_len, rail_h, RAIL_W),
				"center": Vector3(mid.x, -height + rail_h * 0.5, mid.y), "basis": Basis(dir3, Vector3.UP, dir3.cross(Vector3.UP))})


## Кронштейны вдоль рёбер контура, лежащих на стене. false: ни одного стенового ребра (кронштейнам не к чему крепиться)
static func _wall_brackets(res: Array[Dictionary], poly: PackedVector2Array, th: float, cfg: RoomConfig) -> bool:
	var found := false
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var wall := _wall_of_edge(a, b, cfg)
		if wall == &"":
			continue
		found = true
		var nrm := _inward_normal(poly, a, b)
		var depth := 0.0
		for p in poly:
			depth = maxf(depth, (p - a).dot(nrm))
		var arm := clampf(depth - 0.5, 4.0, BRK_ARM_MAX)
		var edge_len := a.distance_to(b)
		var dir := (b - a) / edge_len
		var count := 1
		var s0 := edge_len * 0.5
		var step := 0.0
		if edge_len > 2.0 * BRK_END + 1.0:
			var span := edge_len - 2.0 * BRK_END
			count = maxi(2, int(ceil(span / BRK_STEP)) + 1)
			s0 = BRK_END
			step = span / float(count - 1)
		for k in count:
			_bracket(res, a + dir * (s0 + step * float(k)), nrm, arm, th)
	return found


## Стена, на которой лежит ребро a-b контура (&"" если не лежит или к стене нельзя крепить)
static func _wall_of_edge(a: Vector2, b: Vector2, cfg: RoomConfig) -> StringName:
	if not TableRules.has_walls(cfg):
		return &""
	var r := TableRules.interior(cfg)
	var e := TableRules.EPS
	var res := &""
	if absf(a.y - b.y) <= e:
		if absf(a.y - r.position.y) <= e:
			res = TableRules.NORTH
		elif absf(a.y - r.end.y) <= e:
			res = TableRules.SOUTH
	elif absf(a.x - b.x) <= e:
		if absf(a.x - r.position.x) <= e:
			res = TableRules.WEST
		elif absf(a.x - r.end.x) <= e:
			res = TableRules.EAST
	return res if res != &"" and TableRules.mountable(cfg, res) else &""


## Один кронштейн в точке q стены: пластина на стене, полка под плитой и раскос 45 градусов. nrm: от стены в комнату
static func _bracket(res: Array[Dictionary], q: Vector2, nrm: Vector2, arm: float, th: float) -> void:
	var n3 := Vector3(nrm.x, 0.0, nrm.y)
	var t3 := Vector3.UP.cross(n3)
	var base := Basis(t3, Vector3.UP, n3)
	var q3 := Vector3(q.x, 0.0, q.y)
	res.append({"name": "BracketBack", "size": Vector3(BRK_W, BRK_BACK_H, BRK_BACK_T),
			"center": q3 + n3 * (BRK_BACK_T * 0.5) + Vector3(0.0, -th - BRK_BACK_H * 0.5, 0.0), "basis": base})
	res.append({"name": "BracketArm", "size": Vector3(BRK_W, BRK_ARM_T, arm),
			"center": q3 + n3 * (arm * 0.5) + Vector3(0.0, -th - BRK_ARM_T * 0.5, 0.0), "basis": base})
	var a := minf(BRK_BRACE_MAX, arm - BRK_BACK_T - 1.0)
	if a >= 4.0:
		var p1 := q3 + n3 * BRK_BACK_T + Vector3(0.0, -th - BRK_ARM_T - a, 0.0)
		var p2 := q3 + n3 * (BRK_BACK_T + a) + Vector3(0.0, -th - BRK_ARM_T, 0.0)
		var long_axis := (n3 + Vector3.UP).normalized()
		res.append({"name": "BracketBrace", "size": Vector3(BRK_W, BRK_BRACE_T, p1.distance_to(p2)),
				"center": (p1 + p2) * 0.5, "basis": Basis(t3, long_axis.cross(t3), long_axis)})
