class_name FieldBed extends RefCounted

# XX claude-terra 13.14 H5 (новый файл)
###################################
## Автоложе трака (ATTN_13 §13.14, H5): выемка и насыпь с откосами под траком. Данные без сцены.
###################################
## Поле высот трогать не нужно: ложе считается поверх него и только на показе и в коллизии (TerrainField.set_bed). Исходная толщина слоя
## не меняется, поэтому после удаления трака рельеф возвращается сам.
## Модель. Низ балласта трака на образце это отметка ложа by. Узел внутри полосы (балласт плюс плечо, flat) получает высоту by: холм над
## траком срезан в выемку, низина под ним поднята в насыпь. Дальше от оси идёт откос с наклоном run (ю в плане на 1 ю высоты):
## выемка поднимается от by по откосу до земли (h = min(g, by + s)), насыпь опускается от by до земли (h = max(g, by - s)),
## s = (расстояние от края полосы) / run. Узел берёт ближайший к нему отрезок оси.
## Ограничения насыпи: она есть только там, где трак касается поля (в полосе вокруг оси есть узел со слоем), и не выше fill_max над землёй:
## выше это эстакада на опорах, поле под ней не трогается. Выемка работает везде, где земля выше ложа, но не дальше reach (откос обрезается).
## Узлы полосы со слоем получают тип «каменистая» без шума высоты (щебёночная полоса под балластом), остальное сохраняет свой тип.
## Результат по траку: Dictionary узел (Vector2i) -> Vector3(расстояние до оси, высота ложа, 1 если полоса / 0 если откос).

const STEP := TerrainField.STEP
const EPS := 0.001
## Тип «каменистая» в переопределении типа и бит «без шума высоты» (шейдер читает tmap: тип и бит 4)
const TYPE_ROCKY := TerrainField.ROCKY
const FLAT_BIT := 4
const NO_TYPE := 255
## Откос по умолчанию: ю в плане на 1 ю высоты (около 34°)
const DEFAULT_RUN := 1.5
## Запас по высоте при расчёте охвата отрезка, ю (сверх разницы ложа и земли на самом отрезке)
const REACH_SLACK := 1.0


## Параметры: shoulder (ю плечо), run (откос), fill_max (ю, насыпь не выше), max_dh (ю, охват откоса не больше)
static func params(shoulder: float, run: float, fill_max: float, max_dh: float) -> Dictionary:
	return {"shoulder": shoulder, "run": maxf(run, 0.1), "fill_max": fill_max, "max_dh": max_dh}


## Ложе одного трака. s: образцы C_Path.ballast_samples ({"l": Vector2, "r": Vector2, "y": float}), raw: Callable(i, j) -> float
## (высота земли в узле без ложа), has_layer: Callable(i, j) -> bool (есть ли слой поля в узле)
static func build_track(s: Array, raw: Callable, has_layer: Callable, p: Dictionary) -> Dictionary:
	var out := {}
	var n := s.size()
	if n < 2:
		return out
	var c := PackedVector2Array()
	var hw := PackedFloat32Array()
	var ys := PackedFloat32Array()
	for d: Dictionary in s:
		var l: Vector2 = d["l"]
		var r: Vector2 = d["r"]
		c.append((l + r) * 0.5)
		hw.append(l.distance_to(r) * 0.5 + float(p["shoulder"]))
		ys.append(float(d["y"]))
	var touch := PackedByteArray()
	touch.resize(n)
	for k in n:
		touch[k] = 1 if _touches(c[k], hw[k], has_layer) else 0
	var run: float = p["run"]
	var fill_max: float = p["fill_max"]
	for k in n - 1:
		var pa := c[k]
		var pb := c[k + 1]
		var ab := pb - pa
		var l2 := ab.length_squared()
		if l2 < 0.000001:
			continue
		var can_fill := touch[k] == 1 or touch[k + 1] == 1
		var ga := float(raw.call(roundi(pa.x / STEP), roundi(pa.y / STEP)))
		var gb := float(raw.call(roundi(pb.x / STEP), roundi(pb.y / STEP)))
		var dh := minf(maxf(absf(ys[k] - ga), absf(ys[k + 1] - gb)) + REACH_SLACK, float(p["max_dh"]))
		var reach := maxf(hw[k], hw[k + 1]) + run * dh
		var lo := pa.min(pb) - Vector2(reach, reach)
		var hi := pa.max(pb) + Vector2(reach, reach)
		for j in range(floori(lo.y / STEP), ceili(hi.y / STEP) + 1):
			for i in range(floori(lo.x / STEP), ceili(hi.x / STEP) + 1):
				var pt := Vector2(float(i) * STEP, float(j) * STEP)
				var t := clampf((pt - pa).dot(ab) / l2, 0.0, 1.0)
				var dist := pt.distance_to(pa + ab * t)
				if dist > reach:
					continue
				var key := Vector2i(i, j)
				if out.has(key) and (out[key] as Vector3).x <= dist:
					continue
				var hwt := lerpf(hw[k], hw[k + 1], t)
				var by := lerpf(ys[k], ys[k + 1], t)
				var g := float(raw.call(i, j))
				var flat := dist <= hwt
				var run_s := 0.0 if flat else (dist - hwt) / run
				var h := g
				if g > by + EPS:
					h = by if flat else minf(g, by + run_s)
				elif g < by - EPS:
					if not can_fill or by - g > fill_max:
						continue
					h = by if flat else maxf(g, by - run_s)
				var strip := flat and bool(has_layer.call(i, j))
				if absf(h - g) <= EPS and not strip:
					continue
				out[key] = Vector3(dist, h, 1.0 if flat else 0.0)
	return out


## Есть ли слой поля в квадрате вокруг c на расстоянии r (плюс шаг сетки)
static func _touches(c: Vector2, r: float, has_layer: Callable) -> bool:
	var rr := r + STEP
	for j in range(floori((c.y - rr) / STEP), ceili((c.y + rr) / STEP) + 1):
		for i in range(floori((c.x - rr) / STEP), ceili((c.x + rr) / STEP) + 1):
			if Vector2(float(i) * STEP, float(j) * STEP).distance_to(c) <= rr and has_layer.call(i, j):
				return true
	return false


## Слить ложа нескольких траков: на узел берётся запись с меньшим расстоянием до оси
static func merge(results: Array) -> Dictionary:
	var res := {}
	for r: Dictionary in results:
		for key: Vector2i in r:
			var v: Vector3 = r[key]
			if not res.has(key) or (res[key] as Vector3).x > v.x:
				res[key] = v
	return res


## Слитое ложе в чанки TerrainField.set_bed: ключ чанка -> {"h": PackedFloat32Array (BED_NONE: нет ложа), "t": PackedByteArray (NO_TYPE оставить тип узла)}.
## has_layer нужен узлам откоса без слоя: насыпь там каменистая
static func to_chunks(merged: Dictionary, has_layer: Callable) -> Dictionary:
	var by_chunk := {}
	for key: Vector2i in merged:
		var ck := TerrainField.key_of(key.x, key.y)
		if not by_chunk.has(ck):
			by_chunk[ck] = []
		(by_chunk[ck] as Array).append(key)
	var chunks := {}
	for ck: Vector2i in by_chunk:
		var h := PackedFloat32Array()
		h.resize(TerrainField.CHUNK_NODES)
		h.fill(TerrainField.BED_NONE)
		var t := PackedByteArray()
		t.resize(TerrainField.CHUNK_NODES)
		t.fill(NO_TYPE)
		for key: Vector2i in by_chunk[ck]:
			var v: Vector3 = merged[key]
			var idx := TerrainField.index_in_chunk(key.x, key.y)
			h[idx] = v.y
			if v.z > 0.5:
				t[idx] = TYPE_ROCKY | FLAT_BIT
			elif not bool(has_layer.call(key.x, key.y)):
				t[idx] = TYPE_ROCKY
		chunks[ck] = {"h": h, "t": t}
	return chunks
