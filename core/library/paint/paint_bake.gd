class_name PaintBake extends RefCounted

# XX claude-library (новый файл)
########################
## PaintBake. Карта позиций и нормалей меша в развёртке UV2 (ATTN_22 §22.7.2.1, шаг C2.1; прототип C2.0)
########################
## collect() читает массивы меша в главном потоке (обращение к RenderingServer), bake() работает только с данными
## и потому безопасен в рабочем потоке. Результат: PackedFloat32Array pos и nrm (RGBAF, res*res*4), a = 1 у покрытых текселей.
## Растеризация треугольников UV2 на CPU во float32; 2 прохода dilation (добивка на 2 пикселя вокруг островов).
## Время на проверенных моделях: 512x512 около 0.7 с, 1024x1024 около 2.7 с (прототип C2.0).
## Группа мешей: group() выбирает меши с общим атласом UV2 без перекрытий (опорный самый крупный), transformed() переводит
## их поверхности в пространство опорного меша, bake_group() делает всё вместе и запекает одну карту на группу.

const DILATE_PASSES := 2
const EDGE_EPS := 0.0001     ## допуск «внутри» треугольника: закрывает щели на общих рёбрах
const INNER_EPS := 0.001     ## «строго внутри» для подсчёта перекрытий
const GROUP_GRID := 256      ## сетка занятости UV2 для проверки перекрытий между мешами группы
const GROUP_OVERLAP := 0.01  ## допустимая доля ячеек меша, уже занятых другими мешами группы


## Поверхности меша, у которых есть UV2: [{verts, uv2, norms, idx}]. Остальные пропускаются
static func collect(mesh: Mesh) -> Array:
	var out: Array = []
	for si in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(si)
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
		if not (verts is PackedVector3Array) or not (uv2 is PackedVector2Array) or (uv2 as PackedVector2Array).is_empty():
			continue
		var norms := PackedVector3Array()
		var nv: Variant = arrays[Mesh.ARRAY_NORMAL]
		if nv is PackedVector3Array:
			norms = nv
		var idx := PackedInt32Array()
		var iv: Variant = arrays[Mesh.ARRAY_INDEX]
		if iv is PackedInt32Array:
			idx = iv
		out.append({"verts": verts, "uv2": uv2, "norms": norms, "idx": idx})
	return out


## true, если у каждой поверхности меша есть UV2
static func has_uv2(mesh: Mesh) -> bool:
	if mesh == null or mesh.get_surface_count() == 0:
		return false
	for si in mesh.get_surface_count():
		var uv2: Variant = mesh.surface_get_arrays(si)[Mesh.ARRAY_TEX_UV2]
		if not (uv2 is PackedVector2Array) or (uv2 as PackedVector2Array).is_empty():
			return false
	return true


## Номер опорного меша группы: больше всего вершин, при равенстве первый. entries: [{surfaces, verts, xform}]
static func seed_index(entries: Array) -> int:
	var best := -1
	var best_n := -1
	for i in entries.size():
		var n := int(entries[i]["verts"])
		if n > best_n:
			best = i
			best_n = n
	return best


## Занятость UV2 в сетке grid x grid: 1, где центр ячейки внутри треугольника какой-либо поверхности
static func occupancy(surfaces: Array, grid: int = GROUP_GRID) -> PackedByteArray:
	var occ := PackedByteArray()
	occ.resize(grid * grid)
	for surf in surfaces:
		var us: PackedVector2Array = surf["uv2"]
		var order: PackedInt32Array = surf["idx"]
		if order.is_empty():
			order = PackedInt32Array(range(us.size()))
		for t in range(0, order.size() - 2, 3):
			var a := us[order[t]]
			var b := us[order[t + 1]]
			var c := us[order[t + 2]]
			var d := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
			if absf(d) < 1e-14:
				continue
			var x0 := clampi(int(floor(minf(a.x, minf(b.x, c.x)) * grid)), 0, grid - 1)
			var x1 := clampi(int(ceil(maxf(a.x, maxf(b.x, c.x)) * grid)), 0, grid - 1)
			var y0 := clampi(int(floor(minf(a.y, minf(b.y, c.y)) * grid)), 0, grid - 1)
			var y1 := clampi(int(ceil(maxf(a.y, maxf(b.y, c.y)) * grid)), 0, grid - 1)
			for y in range(y0, y1 + 1):
				var py := (y + 0.5) / grid
				for x in range(x0, x1 + 1):
					var px := (x + 0.5) / grid
					var w0 := ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / d
					var w1 := ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / d
					if w0 < 0.0 or w1 < 0.0 or w0 + w1 > 1.0:
						continue
					occ[y * grid + x] = 1
	return occ


## Какие меши образуют один атлас без перекрытий. entries: [{surfaces, verts, ...}].
## {included: PackedInt32Array (опорный первым, остальные по номеру), skipped: PackedInt32Array}.
## Опорный входит всегда; другой меш входит, если его UV2 не пустой и не перекрывает занятое больше допуска
static func group(entries: Array, grid: int = GROUP_GRID) -> Dictionary:
	var included := PackedInt32Array()
	var skipped := PackedInt32Array()
	if entries.is_empty():
		return {"included": included, "skipped": skipped}
	var seed_i := seed_index(entries)
	var rest: Array = []
	for i in entries.size():
		if i != seed_i:
			rest.append(i)
	rest.sort_custom(func(a: int, b: int) -> bool:
		var na := int(entries[a]["verts"])
		var nb := int(entries[b]["verts"])
		return na > nb if na != nb else a < b)
	var union := PackedByteArray()
	union.resize(grid * grid)
	var others := PackedInt32Array()
	var order: Array = [seed_i]
	order.append_array(rest)
	for k in order.size():
		var i: int = order[k]
		var occ := occupancy(entries[i]["surfaces"], grid)
		var cnt := 0
		var over := 0
		for j in occ.size():
			if occ[j] == 1:
				cnt += 1
				if union[j] == 1:
					over += 1
		if k == 0 or (cnt > 0 and over <= maxi(2, int(cnt * GROUP_OVERLAP))):
			for j in occ.size():
				if occ[j] == 1:
					union[j] = 1
			if k == 0:
				included.append(i)
			else:
				others.append(i)
		else:
			skipped.append(i)
	others.sort()
	included.append_array(others)
	skipped.sort()
	return {"included": included, "skipped": skipped}


## Поверхности в пространстве xf (позиции через xf, нормали через обратную транспонированную). Единичный xf: те же данные
static func transformed(surfaces: Array, xf: Transform3D) -> Array:
	if xf.is_equal_approx(Transform3D.IDENTITY):
		return surfaces
	var nb := xf.basis.inverse().transposed()
	var out: Array = []
	for surf in surfaces:
		var vs: PackedVector3Array = surf["verts"]
		var ns: PackedVector3Array = surf["norms"]
		var v2 := PackedVector3Array()
		v2.resize(vs.size())
		for i in vs.size():
			v2[i] = xf * vs[i]
		var n2 := PackedVector3Array()
		if not ns.is_empty():
			n2.resize(ns.size())
			for i in ns.size():
				n2[i] = (nb * ns[i]).normalized()
		out.append({"verts": v2, "uv2": surf["uv2"], "norms": n2, "idx": surf["idx"]})
	return out


## Группа мешей одним запеканием. entries: [{surfaces, verts, xform}]; xform переводит меш в пространство опорного.
## Результат bake() плюс included и skipped (номера в entries). Работает только с данными: можно в рабочем потоке
static func bake_group(entries: Array, res: int) -> Dictionary:
	var g := group(entries)
	var surfaces: Array = []
	for i in g["included"]:
		surfaces.append_array(transformed(entries[i]["surfaces"], entries[i]["xform"]))
	var out := bake(surfaces, res)
	out["included"] = g["included"]
	out["skipped"] = g["skipped"]
	return out


## {ok, pos, nrm, res, tris, covered, dilated, overlapped, ms, error}
static func bake(surfaces: Array, res: int) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var n := res * res
	var pos := PackedFloat32Array()
	pos.resize(n * 4)
	var nrm := PackedFloat32Array()
	nrm.resize(n * 4)
	var own := PackedInt32Array()       # -1 пусто, -2 добавлен dilation, иначе номер треугольника
	own.resize(n)
	own.fill(-1)
	var inner := PackedByteArray()      # 1: тексель строго внутри треугольника-владельца
	inner.resize(n)
	var tris := 0
	var covered := 0
	var overlapped := 0

	for surf in surfaces:
		var vs: PackedVector3Array = surf["verts"]
		var us: PackedVector2Array = surf["uv2"]
		var ns: PackedVector3Array = surf["norms"]
		var has_n := ns.size() == vs.size()
		var order: PackedInt32Array = surf["idx"]
		if order.is_empty():
			order = PackedInt32Array(range(vs.size()))
		for t in range(0, order.size() - 2, 3):
			var ia := order[t]
			var ib := order[t + 1]
			var ic := order[t + 2]
			var a := us[ia]
			var b := us[ib]
			var c := us[ic]
			tris += 1
			var d := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
			if absf(d) < 1e-14:
				continue
			var pa := vs[ia]
			var pb := vs[ib]
			var pc := vs[ic]
			var na := Vector3.UP
			var nb := Vector3.UP
			var nc := Vector3.UP
			if has_n:
				na = ns[ia]
				nb = ns[ib]
				nc = ns[ic]
			else:
				var fn := (pb - pa).cross(pc - pa).normalized()
				na = fn
				nb = fn
				nc = fn
			var x0 := clampi(int(floor(minf(a.x, minf(b.x, c.x)) * res)), 0, res - 1)
			var x1 := clampi(int(ceil(maxf(a.x, maxf(b.x, c.x)) * res)), 0, res - 1)
			var y0 := clampi(int(floor(minf(a.y, minf(b.y, c.y)) * res)), 0, res - 1)
			var y1 := clampi(int(ceil(maxf(a.y, maxf(b.y, c.y)) * res)), 0, res - 1)
			for y in range(y0, y1 + 1):
				var py := (y + 0.5) / res
				for x in range(x0, x1 + 1):
					var px := (x + 0.5) / res
					var w0 := ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / d
					var w1 := ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / d
					var w2 := 1.0 - w0 - w1
					if w0 < -EDGE_EPS or w1 < -EDGE_EPS or w2 < -EDGE_EPS:
						continue
					var is_inner := 1 if (w0 > INNER_EPS and w1 > INNER_EPS and w2 > INNER_EPS) else 0
					var i := y * res + x
					if own[i] != -1:
						if is_inner == 1 and inner[i] == 1:
							overlapped += 1
							continue
						if not (is_inner == 1 and inner[i] == 0):
							continue
					else:
						covered += 1
					own[i] = tris
					inner[i] = is_inner
					var p := pa * w0 + pb * w1 + pc * w2
					var nn := (na * w0 + nb * w1 + nc * w2).normalized()
					var o := i * 4
					pos[o] = p.x
					pos[o + 1] = p.y
					pos[o + 2] = p.z
					pos[o + 3] = 1.0
					nrm[o] = nn.x
					nrm[o + 1] = nn.y
					nrm[o + 2] = nn.z
					nrm[o + 3] = 1.0

	# dilation: пустой тексель рядом с покрытым копирует его позицию и нормаль
	var dilated := 0
	for pass_i in DILATE_PASSES:
		var prev := own.duplicate()
		for y in res:
			for x in res:
				var i := y * res + x
				if prev[i] != -1:
					continue
				var src := -1
				if x > 0 and prev[i - 1] != -1:
					src = i - 1
				elif x < res - 1 and prev[i + 1] != -1:
					src = i + 1
				elif y > 0 and prev[i - res] != -1:
					src = i - res
				elif y < res - 1 and prev[i + res] != -1:
					src = i + res
				if src >= 0:
					for k in 4:
						pos[i * 4 + k] = pos[src * 4 + k]
						nrm[i * 4 + k] = nrm[src * 4 + k]
					own[i] = -2
					dilated += 1

	return {
		"ok": covered > 0, "pos": pos, "nrm": nrm, "res": res, "tris": tris, "covered": covered,
		"dilated": dilated, "overlapped": overlapped, "ms": Time.get_ticks_msec() - t0,
		"error": "" if covered > 0 else "ни одного покрытого текселя: нет UV2 или все треугольники вырождены",
	}
