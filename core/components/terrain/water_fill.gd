class_name WaterFill extends RefCounted

# XX claude-terra 13.4 W1 (новый файл)
#######################
## Ядро воды (ATTN_13 §13.4). Чистые функции без состояния, сцены и узлов нет.
#######################
## Вода это плоскость на уровне level_y (кратен layer_height) и область на сетке terrain_grid_step.
## Ячейка мокрая, если в слое воды [level_y - T, level_y) в ней нет твёрдого тела листа и она связана
## (по 4 соседям) с ячейкой точки клика. Домен (снимок стола на момент заливки) ограничивает область:
## за ним стена, а не утечка. Всё, что ниже уровня и достижимо, заливается.
## Занятость ячейки подаёт вызывающий (Callable(Vector2) -> bool): blocker_for() строит её по листам TGM и по полю высот шпатлёвки (H6),
## тест подаёт свою. Центр ячейки (i + 0,5) * шаг.
## H6. Поле: ячейка занята, если показанная поверхность поля (слой и ложе трака) в её центре не ниже плоскости воды. Дно у воды любое,
## плоскость одна на весь водоём: яма в поле заливается до уровня, подкоп берега даёт растекание (C_Water пересчитывает область при правке поля).
## У склона дорисовывается кромка (shore): занятые соседние ячейки, часть которых ниже плоскости, иначе между водой и склоном остаётся щель.

## Предохранитель области, ячеек (стол 200 x 100 при шаге 1 даёт 20000)
const MAX_CELLS := 60000
const EPS := 0.001
## На сколько ю поверхность воды ниже уровня (чтобы не мерцать вровень с верхом листа)
const SURFACE_DROP := 0.05


## Ячейки домена, целиком лежащие внутри прямоугольника domain (мировые ю)
static func grid_domain(domain: Rect2, step: float) -> Rect2i:
	var x0 := ceili(domain.position.x / step - EPS)
	var z0 := ceili(domain.position.y / step - EPS)
	var x1 := floori(domain.end.x / step + EPS)
	var z1 := floori(domain.end.y / step + EPS)
	return Rect2i(x0, z0, maxi(0, x1 - x0), maxi(0, z1 - z0))


static func cell_of(p: Vector2, step: float) -> Vector2i:
	return Vector2i(floori(p.x / step), floori(p.y / step))


static func cell_center(c: Vector2i, step: float) -> Vector2:
	return Vector2((float(c.x) + 0.5) * step, (float(c.y) + 0.5) * step)


## Занятость ячейки водой: листы и поле высот шпатлёвки (H6). Callable(Vector2) -> bool, центр ячейки в мире
static func blocker_for(level_y: float) -> Callable:
	var sheets := sheet_blocker_for(level_y)
	var fld := field_blocker(TGM.field if is_instance_valid(TGM) else null, level_y)
	if not fld.is_valid():
		return sheets
	return func(p: Vector2) -> bool: return sheets.call(p) or fld.call(p)


## H6. Занятость полем: показанная поверхность поля (слой и ложе трака) в точке не ниже плоскости воды (level_y - SURFACE_DROP).
## Вода идёт по уровню плоскостью, а дно у неё любое: яма, выкопанная кистью, заливается до уровня. Поля нет или оно пустое: Callable()
static func field_blocker(field: TerrainField, level_y: float) -> Callable:
	if field == null or (field.is_empty() and not field.has_bed()):
		return Callable()
	var plane := level_y - SURFACE_DROP
	return func(p: Vector2) -> bool: return field.ground_top(p.x, p.y) >= plane - EPS


## H6. Кромка у склона: ячейка сама занята (центр выше плоскости воды), но часть её ниже плоскости, поэтому вода подходит к склону
## вплотную. Такие ячейки рисуются водой (выше склона плоскость скрыта землёй), но воду не растекают и в область не входят.
## Callable(Vector2) -> bool по центру ячейки; девять узлов ячейки (углы, середины сторон, центр); sheet_blocked: занятость листами
static func field_shore(field: TerrainField, level_y: float, step: float, sheet_blocked: Callable = Callable()) -> Callable:
	if field == null or (field.is_empty() and not field.has_bed()):
		return Callable()
	var plane := level_y - SURFACE_DROP
	var h := step * 0.5
	return func(c: Vector2) -> bool:
		if sheet_blocked.is_valid() and sheet_blocked.call(c):
			return false
		for dz in [-h, 0.0, h]:
			for dx in [-h, 0.0, h]:
				# NO_GROUND (-INF): здесь нет поля, земля это стол или лист, ниже плоскости (выше был бы лист, его считает sheet_blocked)
				if field.ground_top(c.x + dx, c.y + dz) < plane - EPS:
					return true
		return false


## Кромка по листам и полю для C_Water и инструмента: Callable() если поля нет
static func shore_for(level_y: float, step: float) -> Callable:
	return field_shore(TGM.field if is_instance_valid(TGM) else null, level_y, step, sheet_blocker_for(level_y))


## Занятость по листам: точка занята, если лист в ней сплошной в слое воды [level_y - T, level_y)
static func sheet_blocker_for(level_y: float) -> Callable:
	var T: float = Global.settings.layer_height
	var lo := level_y - T
	var cand: Array[Dictionary] = []
	if is_instance_valid(TGM):
		for e in TGM.get_layers():
			var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
			if l == null or l.top_y() <= lo + EPS or l.base_y() >= level_y - EPS:
				continue
			cand.append({"layer": l, "rect": C_Contour.bounds_of(l.world_polygon())})
	return func(p: Vector2) -> bool:
		for c in cand:
			if not (c["rect"] as Rect2).has_point(p):
				continue
			for iv: Vector2 in (c["layer"] as C_TerrainLayer).solid_intervals_at(p):
				if iv.x < level_y - EPS and iv.y > lo + EPS:
					return true
		return false


## XX claude-table T2. Ячейка (центр в мире, ю) лежит на плите подмакетника. Секции есть: по их контурам (стол из нескольких секций,
## вода у вырезанного угла не вытекает); секций нет (стенд, тест): Callable() и домен-прямоугольник, как раньше
static func footprint_inside() -> Callable:
	if not is_instance_valid(LYM) or LYM.get_sections().is_empty():
		return Callable()
	return func(p: Vector2) -> bool: return LYM.contains(p.x, p.y)


## Залить. Результат:
##  ok - область найдена, иначе why = причина ("" при ok);
##  cells - Dictionary Vector2i -> true; count; touches_edge - область дошла до края домена;
##  shore - кромка у склона (H6, только если подан shore): занятые ячейки рядом с водой, часть которых ниже плоскости воды;
##    в область и счёт не входят, меш рисует их вместе с cells;
##  bounds - Rect2 области в мире (ю); dom - Rect2i ячеек домена.
## inside (необязательно): Callable(Vector2) -> bool, центр ячейки на плите. Ячейка вне плиты это край домена (стена, не утечка)
## shore (необязательно): Callable(Vector2) -> bool по центру занятой ячейки (shore_for): ячейка кромки
static func fill(seed_pos: Vector2, level_y: float, domain: Rect2, step: float, blocked: Callable, max_cells: int = MAX_CELLS,
		inside: Callable = Callable(), shore: Callable = Callable()) -> Dictionary:
	var res := {"ok": false, "why": "", "cells": {}, "count": 0, "touches_edge": false, "bounds": Rect2(), "dom": Rect2i(), "shore": {}}
	var memo := {}   # Vector2i -> bool: занятость считается один раз на ячейку (поле считать дорого, соседи спрашивают её по несколько раз)
	var is_blocked := func(c: Vector2i) -> bool:
		if memo.has(c):
			return bool(memo[c])
		var b: bool = blocked.call(Vector2((float(c.x) + 0.5) * step, (float(c.y) + 0.5) * step))
		memo[c] = b
		return b
	var T: float = Global.settings.layer_height
	if level_y < T - EPS:
		res["why"] = "Уровень воды ниже первого слоя"
		return res
	var dom := grid_domain(domain, step)
	res["dom"] = dom
	var s := cell_of(seed_pos, step)
	if not dom.has_point(s) or (inside.is_valid() and not inside.call(cell_center(s, step))):
		res["why"] = "Точка за краем стола"
		return res
	if is_blocked.call(s):
		res["why"] = "Здесь выше уровня воды"
		return res
	var cells := {}
	cells[s] = true
	var queue: Array[Vector2i] = [s]
	var head := 0
	var edge := false
	var lo := s
	var hi := s
	while head < queue.size():
		var c := queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if cells.has(n):
				continue
			if not dom.has_point(n) or (inside.is_valid() and not inside.call(cell_center(n, step))):
				edge = true
				continue
			if is_blocked.call(n):
				continue
			cells[n] = true
			queue.append(n)
			lo = Vector2i(mini(lo.x, n.x), mini(lo.y, n.y))
			hi = Vector2i(maxi(hi.x, n.x), maxi(hi.y, n.y))
		if queue.size() > max_cells:
			res["why"] = "Слишком большая область"
			return res
	if shore.is_valid():
		var ring := {}
		for c: Vector2i in cells:
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + d
				if cells.has(n) or ring.has(n) or not dom.has_point(n):
					continue
				if inside.is_valid() and not inside.call(cell_center(n, step)):
					continue
				if shore.call(cell_center(n, step)):
					ring[n] = true
		res["shore"] = ring
	res["ok"] = true
	res["cells"] = cells
	res["count"] = cells.size()
	res["touches_edge"] = edge
	res["bounds"] = Rect2(Vector2(lo) * step, Vector2(hi - lo + Vector2i.ONE) * step)
	return res


## Горизонтальные полосы области: Vector3i(z, x0, x1) на строку, x1 не входит. Для меша и подсчёта
static func runs(cells: Dictionary) -> Array[Vector3i]:
	var rows := {}
	for c: Vector2i in cells:
		if not rows.has(c.y):
			rows[c.y] = []
		rows[c.y].append(c.x)
	var zs := rows.keys()
	zs.sort()
	var res: Array[Vector3i] = []
	for z: int in zs:
		var xs: Array = rows[z]
		xs.sort()
		var start: int = xs[0]
		var prev: int = xs[0]
		for i in range(1, xs.size()):
			var x: int = xs[i]
			if x != prev + 1:
				res.append(Vector3i(z, start, prev + 1))
				start = x
			prev = x
		res.append(Vector3i(z, start, prev + 1))
	return res


## Стенки у края домена: мокрые ячейки на границе дают вертикальную грань. Элемент: {"a": Vector2, "b": Vector2}
## (концы грани в мире, ю), обход так, что нормаль смотрит наружу
static func edge_walls(cells: Dictionary, dom: Rect2i, step: float, inside: Callable = Callable()) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	if inside.is_valid():
		# XX claude-table T2: край это любая грань мокрой ячейки, за которой нет плиты (или домена)
		for c: Vector2i in cells:
			var x0 := float(c.x) * step
			var z0 := float(c.y) * step
			if _outside(c + Vector2i(-1, 0), dom, step, inside):
				res.append({"a": Vector2(x0, z0 + step), "b": Vector2(x0, z0)})
			if _outside(c + Vector2i(1, 0), dom, step, inside):
				res.append({"a": Vector2(x0 + step, z0), "b": Vector2(x0 + step, z0 + step)})
			if _outside(c + Vector2i(0, -1), dom, step, inside):
				res.append({"a": Vector2(x0, z0), "b": Vector2(x0 + step, z0)})
			if _outside(c + Vector2i(0, 1), dom, step, inside):
				res.append({"a": Vector2(x0 + step, z0 + step), "b": Vector2(x0, z0 + step)})
		return res
	var x_min := float(dom.position.x) * step
	var x_max := float(dom.end.x) * step
	var z_min := float(dom.position.y) * step
	var z_max := float(dom.end.y) * step
	for c: Vector2i in cells:
		var x0 := float(c.x) * step
		var z0 := float(c.y) * step
		if c.x == dom.position.x:   # запад: нормаль -X
			res.append({"a": Vector2(x_min, z0 + step), "b": Vector2(x_min, z0)})
		if c.x == dom.end.x - 1:   # восток: нормаль +X
			res.append({"a": Vector2(x_max, z0), "b": Vector2(x_max, z0 + step)})
		if c.y == dom.position.y:   # север (-Z): нормаль -Z
			res.append({"a": Vector2(x0, z_min), "b": Vector2(x0 + step, z_min)})
		if c.y == dom.end.y - 1:   # юг (+Z): нормаль +Z
			res.append({"a": Vector2(x0 + step, z_max), "b": Vector2(x0, z_max)})
	return res


static func _outside(c: Vector2i, dom: Rect2i, step: float, inside: Callable) -> bool:
	return not dom.has_point(c) or not inside.call(cell_center(c, step))
