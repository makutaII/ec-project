class_name PlasterSkin extends Node3D

# XX claude-terra 13.5 G2 (новый файл)
###################################
## Оболочка гипсового бинта (ATTN_13 §13.5). Один узел на весь макет, живёт в TGM (autoload).
###################################
## Для листов с C_TerrainLayer.smooth > 0 строит гладкую поверхность поверх ступеней: высоты ступеней с мировой сетки
## (cell = terrain_grid_step * CELL_K), затем PlasterField.smooth (пандусы, предел подъёма, закрепление у траков).
## Оболочка всегда не ниже ступеней, поэтому ступени, TGM, опоры, вода и D6 её не замечают.
## Меш рисуется только там, где оболочка выше ступеней (иначе мерцание вровень с верхом листа), материал по стадии листа.
## Коллизия на отдельном слое plaster: его видят только лучи постановки декора и зданий (EntitySetting.get_pick_layers).
## Лучи листов и траков оболочку не видят, иначе высота ступени округлялась бы вверх на склоне.
## Пересчёт по terrain_changed и при смене силы или стадии, не чаще раза в DELAY.

## Ячейка поля относительно шага сетки листов
const CELL_K := 0.5
## Наибольшее число ячеек поля (стол 200 x 100 при ячейке 0,5 даёт 80000)
const MAX_CELLS := 250000
const DELAY := 0.15
## Трак считается стоящим на ступени, если низ его балласта не дальше этого числа слоёв от верха ступени
const PIN_TOL_LAYERS := 1.5

var has_content := false
## Область оболочки в мире (XZ), для отсева лишних пересчётов
var region := Rect2()

var _mi: MeshInstance3D
var _body: StaticBody3D
var _shape: CollisionShape3D
var _pending := false

# XX claude-terra 13.13 K1
## Оболочка пересчитана (или снята). Слушают те, кому важны высоты оболочки (кисть)
signal rebuilt
## K3: краска (для крашеных клеток на плоском верху) и сплэт с материалами верха; ставит TGM до add_child
var paint: PaintMap
var splat: PaintSplat
## Подъём оболочки над ступенью в крашеной клетке на плоском верху, ю (больше PlasterField.MIN_RAISE)
const PAINT_LIFT := 0.025
## Последнее поле оболочки для запросов кисти: высота оболочки и «ячейка под бинтом». Индексы ячеек мировые (как у PaintMap)
var _f_sk := PackedFloat32Array()
var _f_own := PackedInt32Array()
var _f_i0 := 0
var _f_j0 := 0
var _f_w := 0
var _f_d := 0

# XX claude-terra 13.13 K0
## Замер пересборки: включается GlobalSetting.plaster_log_time, итог одной строкой в Output
var _log := false
var _log_t0 := 0       # начало пересборки, мкс
var _log_last := 0     # конец предыдущей фазы, мкс
var _log_laps: Array[String] = []
var _log_info := ""    # размеры поля и число листов

# XX claude-terra 13.13 K0b-2
## Кэш высот ступеней по листам. Опрос solid_intervals_at по ячейке был самой дорогой фазой пересборки (35-48%), а при
## наложении бинта, смене стадии или стиля форма листов не меняется. Высоты хранятся кусками HCHUNK x HCHUNK ячеек в мировых
## индексах (от рамки поля не зависят) и считаются лениво, только где спросили. Ключ формы листа: hash(форма, контур) + шаг + слой
const HCHUNK := 16
var _hcache := {}      # instance_id листа -> {"sig": Array, "chunks": {Vector2i: PackedFloat32Array}}
var _hc_new := 0       # кусков посчитано в этой пересборке
var _hc_hit := 0       # кусков взято из кэша


func _ready() -> void:
	name = "PlasterSkin"
	_mi = MeshInstance3D.new()
	_mi.name = "Mesh"
	add_child(_mi)
	_body = StaticBody3D.new()
	_body.name = "Body"
	_body.collision_layer = Global.active_layers(['plaster'])
	_body.collision_mask = 0
	add_child(_body)


## Пересчитать через DELAY (повторные запросы склеиваются)
func request() -> void:
	if _pending or not is_inside_tree():
		return
	_pending = true
	get_tree().create_timer(DELAY).timeout.connect(_on_delay)


func _on_delay() -> void:
	if _pending:
		rebuild()


## Размер ячейки оболочки и краски, ю
static func cell_size() -> float:
	return float(Global.settings.terrain_grid_step) * CELL_K


## 13.13 K1. Высота оболочки (она не ниже ступеней) в ячейке с мировыми индексами (i, j). NAN: ячейка вне поля
func height_at_cell(i: int, j: int) -> float:
	var ii := i - _f_i0
	var jj := j - _f_j0
	if ii < 0 or jj < 0 or ii >= _f_w or jj >= _f_d:
		return NAN
	return _f_sk[jj * _f_w + ii]


## 13.13 K1. Ячейка (i, j) принадлежит листу с бинтом (под ним или на его пандусе): красить можно только здесь
func is_plastered_cell(i: int, j: int) -> bool:
	var ii := i - _f_i0
	var jj := j - _f_j0
	if ii < 0 or jj < 0 or ii >= _f_w or jj >= _f_d:
		return false
	return _f_own[jj * _f_w + ii] >= 0


## 13.13 K1. То же по точке мира (x, z)
func is_plastered_at(p: Vector2) -> bool:
	var c := cell_size()
	return is_plastered_cell(floori(p.x / c), floori(p.y / c))


## 13.13 K1. Высота оболочки в точке мира (ближайшая ячейка). NAN: вне поля
func height_at(p: Vector2) -> float:
	var c := cell_size()
	return height_at_cell(floori(p.x / c), floori(p.y / c))


func clear() -> void:
	_f_sk = PackedFloat32Array()
	_f_own = PackedInt32Array()
	_f_w = 0
	_f_d = 0
	_pending = false
	has_content = false
	region = Rect2()
	if _mi:
		_mi.mesh = null
	if is_instance_valid(_shape):
		_shape.queue_free()
	_shape = null
	rebuilt.emit()


func rebuild() -> void:
	_pending = false
	_log = bool(Global.settings.plaster_log_time)   # XX claude-terra 13.13 K0
	_log_laps.clear()
	_log_info = ""
	_hc_new = 0
	_hc_hit = 0
	_log_t0 = Time.get_ticks_usec()
	_log_last = _log_t0
	var all: Array[C_TerrainLayer] = []
	var smooth_sheets: Array[C_TerrainLayer] = []
	for e in TGM.get_layers():
		var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
		if l == null:
			continue
		all.append(l)
		if l.smooth > 0:
			smooth_sheets.append(l)
	if smooth_sheets.is_empty():
		clear()
		return

	var gs = Global.settings
	var T: float = gs.layer_height
	var c: float = float(gs.terrain_grid_step) * CELL_K

	# 1. зоны: контур листа и контур, раздутый на ширину пандуса
	var zones: Array[Dictionary] = []
	var box := Rect2()
	var first := true
	for l in smooth_sheets:
		var inner := l.world_polygon()
		if inner.size() < 3:
			continue
		var run := float(l.smooth)
		var outer: Array[PackedVector2Array] = []
		for p: PackedVector2Array in Geometry2D.offset_polygon(inner, run, Geometry2D.JOIN_ROUND):
			outer.append(p)
		zones.append({"layer": l, "inner": inner, "outer": outer, "run": run, "stage": l.stage})
		var b := C_Contour.bounds_of(inner).grow(run + 1.0)
		box = b if first else box.merge(b)
		first = false
	if zones.is_empty():
		clear()
		return

	var i0 := floori(box.position.x / c)
	var j0 := floori(box.position.y / c)
	var w := ceili(box.end.x / c) - i0
	var d := ceili(box.end.y / c) - j0
	if w < 2 or d < 2 or w * d > MAX_CELLS:
		push_warning("[PlasterSkin] поле %d x %d ячеек вне допустимого, оболочка не построена" % [w, d])
		clear()
		return
	var origin := Vector2(float(i0) * c, float(j0) * c)
	region = box
	_log_info = "поле %d x %d (%d яч.), листов с бинтом %d из %d" % [w, d, w * d, smooth_sheets.size(), all.size()]
	_lap("зоны")

	# 2. высоты ступеней: верх самого высокого твёрдого участка над центром ячейки (K0b-2: из кэша по листам)
	var hh := PackedFloat32Array()
	hh.resize(w * d)
	var seen := {}
	for l in all:
		seen[l.get_instance_id()] = true
		var lb := C_Contour.bounds_of(l.world_polygon())
		if lb.size == Vector2.ZERO or not lb.intersects(box):
			continue
		var x0 := maxi(0, floori(lb.position.x / c) - i0)
		var x1 := mini(w - 1, ceili(lb.end.x / c) - i0)
		var z0 := maxi(0, floori(lb.position.y / c) - j0)
		var z1 := mini(d - 1, ceili(lb.end.y / c) - j0)
		_raise_heights(hh, l, lb, c, i0, j0, w, x0, x1, z0, z1)
	for id in _hcache.keys():   # листы, которых больше нет
		if not seen.has(id):
			_hcache.erase(id)
	_log_info += ", кусков высот новых %d из кэша %d" % [_hc_new, _hc_hit]
	_lap("высоты")

	# 3. кому принадлежит ячейка: сначала лист под ней, потом тот, чей пандус сюда дотягивается
	var own := PackedInt32Array()
	own.resize(w * d)
	own.fill(-1)
	for pass_n in 2:
		for zi in zones.size():
			var polys: Array[PackedVector2Array] = []
			if pass_n == 0:
				polys.append(zones[zi]["inner"])
			else:
				polys.assign(zones[zi]["outer"])
			for poly in polys:
				var pb := C_Contour.bounds_of(poly)
				var x0 := maxi(0, floori(pb.position.x / c) - i0)
				var x1 := mini(w - 1, ceili(pb.end.x / c) - i0)
				var z0 := maxi(0, floori(pb.position.y / c) - j0)
				var z1 := mini(d - 1, ceili(pb.end.y / c) - j0)
				for j in range(z0, z1 + 1):
					for i in range(x0, x1 + 1):
						if own[j * w + i] >= 0:
							continue
						var p := origin + Vector2((float(i) + 0.5) * c, (float(j) + 0.5) * c)
						if Geometry2D.is_point_in_polygon(p, poly):
							own[j * w + i] = zi
	var run_arr := PackedFloat32Array()
	run_arr.resize(w * d)
	for k in w * d:
		if own[k] >= 0:
			run_arr[k] = zones[own[k]]["run"]
	_lap("владельцы")

	# 4. ложе траков: оболочка там не поднимается над ступенью
	var pin := _track_pin(origin, c, w, d, hh, box, T)
	var f := PlasterField.pin_factor(pin, w, d, 2)
	_lap("ложе траков")

	# 5. оболочка
	var max_up: float = float(gs.plaster_max_up) * T
	# XX claude-terra 13.13 K4: класс краски задаёт подошву и осыпь (ширина пандуса и подъём по ячейкам)
	var wt := PackedByteArray()
	var up_arr := PackedFloat32Array()
	if paint != null and not paint.is_empty():
		wt = paint.field_weights(i0, j0, w, d)
		var cf := PlasterField.class_fields(wt, run_arr, T, float(gs.plaster_max_up))
		run_arr = cf["run"]
		up_arr = cf["up"]
		_lap("классы краски")
	var sk := PlasterField.smooth(hh, run_arr, f, w, d, c, T, max_up, up_arr, clampf(float(gs.plaster_lip), 0.0, 1.0))
	_lap("оболочка")
	if not wt.is_empty():
		# K4: мелкий рельеф только вверх. K3: на плоском верху оболочка есть только в крашеных ячейках
		sk = PlasterField.add_relief(sk, own, f, wt, i0, j0, w, T, float(gs.plaster_relief_scale))
		sk = PlasterField.lift_marked(sk, hh, own, f, PlasterField.mask_of(wt), PAINT_LIFT, PlasterField.MIN_RAISE)
		_lap("рельеф и краска")
	_f_sk = sk
	_f_own = own
	_f_i0 = i0
	_f_j0 = j0
	_f_w = w
	_f_d = d
	_build_mesh(sk, hh, own, zones, origin, c, w, d)


## 13.13 K0. Закрыть очередную фазу пересборки: сколько мс она заняла
func _lap(label: String) -> void:
	if not _log:
		return
	var now := Time.get_ticks_usec()
	_log_laps.append("%s %.1f" % [label, float(now - _log_last) / 1000.0])
	_log_last = now


## 13.13 K0. Итоговая строка замера в Output: общее время, размеры поля, фазы, число треугольников
func _log_done(tri_count: int) -> void:
	if not _log:
		return
	var total := float(Time.get_ticks_usec() - _log_t0) / 1000.0
	print("[PlasterSkin] rebuild %.1f мс | %s | %s | треугольников %d" % [total, _log_info, ", ".join(_log_laps), tri_count])


## K0b-2. Поднять hh до верха листа l над центрами ячеек в прямоугольнике x0..x1, z0..z1 (индексы поля).
## Значения берутся из кусков кэша; кусок считается при первом обращении и после любой смены формы листа
func _raise_heights(hh: PackedFloat32Array, l: C_TerrainLayer, lb: Rect2, c: float, i0: int, j0: int, w: int,
		x0: int, x1: int, z0: int, z1: int) -> void:
	if l.entity == null or not l.entity.is_inside_tree():
		return   # как solid_intervals_at: листа вне сцены нет
	var id := l.get_instance_id()
	var sig: Array = [hash([l.shape_hash(), l.world_polygon()]), c, Global.settings.layer_height]
	var entry: Dictionary = _hcache.get(id, {})
	if entry.is_empty() or entry["sig"] != sig:
		entry = {"sig": sig, "chunks": {}}
		_hcache[id] = entry
	var chunks: Dictionary = entry["chunks"]
	var gx0 := x0 + i0   # тот же прямоугольник в мировых индексах ячеек
	var gx1 := x1 + i0
	var gz0 := z0 + j0
	var gz1 := z1 + j0
	for cz in range(floori(float(gz0) / HCHUNK), floori(float(gz1) / HCHUNK) + 1):
		for cx in range(floori(float(gx0) / HCHUNK), floori(float(gx1) / HCHUNK) + 1):
			var key := Vector2i(cx, cz)
			var arr: PackedFloat32Array
			if chunks.has(key):
				arr = chunks[key]
				_hc_hit += 1
			else:
				arr = _height_chunk(l, lb, c, cx, cz)
				chunks[key] = arr
				_hc_new += 1
			var ox := cx * HCHUNK
			var oz := cz * HCHUNK
			var ia := maxi(gx0, ox)
			var ib := mini(gx1, ox + HCHUNK - 1)
			for gj in range(maxi(gz0, oz), mini(gz1, oz + HCHUNK - 1) + 1):
				var hrow := (gj - j0) * w - i0      # индекс в hh = hrow + gi
				var arow := (gj - oz) * HCHUNK - ox  # индекс в куске = arow + gi
				for gi in range(ia, ib + 1):
					var v := arr[arow + gi]
					if v > hh[hrow + gi]:
						hh[hrow + gi] = v


## K0b-2. Высоты одного куска HCHUNK x HCHUNK ячеек листа l (cx, cz мировые индексы куска): верх самого высокого твёрдого
## участка над центром ячейки или 0, если там твёрдого нет. Прежняя формула: центр ячейки внутри рамки листа lb
func _height_chunk(l: C_TerrainLayer, lb: Rect2, c: float, cx: int, cz: int) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	arr.resize(HCHUNK * HCHUNK)
	var ox := cx * HCHUNK
	var oz := cz * HCHUNK
	for j in HCHUNK:
		for i in HCHUNK:
			var p := Vector2((float(ox + i) + 0.5) * c, (float(oz + j) + 0.5) * c)
			if not lb.has_point(p):
				continue
			var best := 0.0
			for iv: Vector2 in l.solid_intervals_at(p):
				if iv.y > best:
					best = iv.y
			arr[j * HCHUNK + i] = best
	return arr


## Ячейки под траками (балласт и зазор), где низ балласта стоит на ступени
func _track_pin(origin: Vector2, c: float, w: int, d: int, hh: PackedFloat32Array, box: Rect2, T: float) -> PackedByteArray:
	var pin := PackedByteArray()
	pin.resize(w * d)
	var pad: float = float(Global.settings.plaster_pin_margin) + float(Global.settings.terrain_cut_margin)
	for t in TGM.get_tracks():
		var path := t.get_comp(C_Path) as C_Path
		if path == null:
			continue
		var s := path.ballast_samples()
		for k in range(s.size() - 1):
			var a: Dictionary = s[k]
			var b: Dictionary = s[k + 1]
			var la: Vector2 = a["l"]
			var ra: Vector2 = a["r"]
			var lb: Vector2 = b["l"]
			var rb: Vector2 = b["r"]
			var da := (la - ra).normalized()
			var db := (lb - rb).normalized()
			var quad := PackedVector2Array([la + da * pad, lb + db * pad, rb - db * pad, ra - da * pad])
			var qb := C_Contour.bounds_of(quad)
			if not qb.intersects(box):
				continue
			var y_bottom := (float(a["y"]) + float(b["y"])) * 0.5
			var x0 := maxi(0, floori(qb.position.x / c) - int(floor(origin.x / c)))
			var x1 := mini(w - 1, ceili(qb.end.x / c) - int(floor(origin.x / c)))
			var z0 := maxi(0, floori(qb.position.y / c) - int(floor(origin.y / c)))
			var z1 := mini(d - 1, ceili(qb.end.y / c) - int(floor(origin.y / c)))
			for j in range(z0, z1 + 1):
				for i in range(x0, x1 + 1):
					if absf(y_bottom - hh[j * w + i]) > PIN_TOL_LAYERS * T:
						continue
					var p := origin + Vector2((float(i) + 0.5) * c, (float(j) + 0.5) * c)
					if Geometry2D.is_point_in_polygon(p, quad):
						pin[j * w + i] = 1
	return pin


func _build_mesh(sk: PackedFloat32Array, hh: PackedFloat32Array, own: PackedInt32Array, zones: Array[Dictionary],
		origin: Vector2, c: float, w: int, d: int) -> void:
	var tools := {}   # стадия -> SurfaceTool
	var counts := {}
	var eps := PlasterField.MIN_RAISE
	# XX claude-terra 13.13 K0b: вершина «поднята», если оболочка выше ступени. Ячейка без поднятых углов пропускается
	# сразу (раньше на неё тратились массивы треугольников), нормаль вершины считается один раз и берётся из кэша.
	# Порядок треугольников и вершин прежний, меш тот же
	var n := w * d
	var raised := PackedByteArray()
	raised.resize(n)
	for k in n:
		if sk[k] - hh[k] > eps:
			raised[k] = 1
	var nrm := PackedVector3Array()
	nrm.resize(n)
	var nrm_ok := PackedByteArray()
	nrm_ok.resize(n)
	for j in d - 1:
		for i in w - 1:
			var a := j * w + i
			if raised[a] + raised[a + 1] + raised[a + w] + raised[a + w + 1] == 0:
				continue
			var tris := [[a, a + 1, a + w + 1], [a, a + w + 1, a + w]]
			for tri in tris:
				var owner_idx := -1
				for v: int in tri:
					if raised[v] == 1:
						owner_idx = own[v]
						break
				if owner_idx < 0:
					continue
				var zone: Dictionary = zones[owner_idx]
				var stage: int = zone["stage"]
				if not tools.has(stage):
					var fresh := SurfaceTool.new()
					fresh.begin(Mesh.PRIMITIVE_TRIANGLES)
					var zl: C_TerrainLayer = zone["layer"]
					var style := zl.style if zl.style != null else TerrainStyle.new()
					fresh.set_material(splat.surface_material(style, stage) if splat != null else style.get_top(stage))
					tools[stage] = fresh
					counts[stage] = 0
				var st: SurfaceTool = tools[stage]
				for v: int in tri:
					var vi := v % w
					@warning_ignore("integer_division")   # v / w: номер строки сетки, дробная часть не нужна
					var vj := v / w
					if nrm_ok[v] == 0:
						nrm[v] = PlasterField.normal(sk, w, d, vi, vj, c)
						nrm_ok[v] = 1
					st.set_normal(nrm[v])
					st.add_vertex(Vector3(origin.x + (float(vi) + 0.5) * c, sk[v], origin.y + (float(vj) + 0.5) * c))
				counts[stage] += 1
	_lap("меш: ячейки в вершины")
	var tri_total := 0
	for stage in counts:
		tri_total += int(counts[stage])
	if tools.is_empty():
		clear()
		region = Rect2()
		# XX claude-terra 13.13 K1: оболочки над ступенями нет (плоский верх), но лист с бинтом есть: красить на нём можно
		_f_sk = sk
		_f_own = own
		_f_i0 = int(floor(origin.x / c))
		_f_j0 = int(floor(origin.y / c))
		_f_w = w
		_f_d = d
		_log_done(0)
		rebuilt.emit()
		return
	var mesh := ArrayMesh.new()
	for stage in tools:
		(tools[stage] as SurfaceTool).commit(mesh)
	_mi.mesh = mesh
	_lap("меш: commit")
	if is_instance_valid(_shape):
		_shape.queue_free()
	_shape = CollisionShape3D.new()
	_shape.shape = mesh.create_trimesh_shape()
	_body.add_child(_shape)
	has_content = true
	_lap("коллизия")
	_log_done(tri_total)
	rebuilt.emit()
