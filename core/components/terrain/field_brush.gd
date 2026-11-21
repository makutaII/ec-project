class_name FieldBrush extends RefCounted

# XX claude-terra 13.14 H2 (новый файл)
###################################
## Расчёт мазка кисти «площадка + склон» по полю высот (ATTN_13 §13.14). Данные без сцены, правит TerrainField.
###################################
## Мазок читает область узлов вокруг центра (read_region), считает план (перепад по кольцу, ширина склона, площадка) и меняет толщину
## слоя шпатлёвки в буфере, потом пишет изменённый прямоугольник обратно (write_region). Высоты в мазке абсолютные (пол + слой):
## площадка держит высоту ht, а толщина узла = ht - пол узла, не меньше нуля и не больше max_layers. Узлы вне полигонов clip (стол) мазок не трогает.
## Режимы: 1 подъём (только насыпает), -1 яма (только срезает), 0 выравнивание (подтягивает к ht в обе стороны, тип пишется на всю площадку и склон).
## Модель и формулы те же, что в tests/field_spike (H0, принята игроком).

const STEP := TerrainField.STEP
## Скорость подтягивания ЛКМ при силе 1, 1/с
const PULL_RATE := 12.0

var radius := 5.0
var angle := 25.0
var plateau_min := 1.0
var tol_frac := 0.25
var tol_max := 3.0
var strength := 0.5
var notch_layers := 0.25
var max_layers := 16.0
var radius_min := 1.5
var radius_max := 30.0
var mix := Vector3(1.0, 0.0, 0.0)
var type_names: Array[String] = ["гладкая", "каменистая", "скалистая"]

## План последнего мазка (preview и stroke): {"ht", "dh", "w", "p", "e", "t", "ang", "limit"}
var last_plan := {}

var _rect := Rect2i()
var _w := PackedInt32Array()
var _f := PackedFloat32Array()
var _iv: Array = []        # по строке области: PackedInt32Array интервалов узлов внутри стола


func load_brush(b: TerrainBrush) -> void:
	if b == null:
		return
	radius_min = b.radius_min
	radius_max = maxf(b.radius_max, b.radius_min)
	radius = clampf(b.radius_default, radius_min, radius_max)
	angle = clampf(b.angle_deg, 5.0, 90.0)
	plateau_min = b.plateau_min
	tol_frac = b.tolerance_frac
	tol_max = b.tolerance_max
	strength = clampf(b.strength, 0.1, 1.0)
	notch_layers = b.notch_layers
	max_layers = b.max_layers
	mix = b.surface_mix


## Подпись типа поверхности кисти: «гладкая» или «смесь»
func type_label() -> String:
	var n := 0
	var last := 0
	for t in 3:
		if mix[t] > 0.0:
			n += 1
			last = t
	if n <= 1:
		return type_names[last]
	return "смесь"


## Следующая высота площадки на щелчок колеса: на notch_layers от текущей или до ближайшего целого слоя
func next_height(hc: float, dir_: float, whole: bool, lh: float, floor_c: float) -> float:
	var ht := hc + dir_ * notch_layers * lh
	if whole:
		var rel := (hc - floor_c) / lh
		if dir_ > 0.0:
			ht = floor_c + (floorf(rel + 0.001) + 1.0) * lh
		else:
			ht = floor_c + (ceilf(rel - 0.001) - 1.0) * lh
	return clampf(ht, floor_c, floor_c + max_layers * lh)


## Тип поверхности узла по весам кисти и хешу узла
func type_for(i: int, j: int) -> int:
	var total := mix.x + mix.y + mix.z
	if total <= 0.0 or (mix.y <= 0.0 and mix.z <= 0.0):
		return TerrainField.SMOOTH
	if mix.x >= total:
		return TerrainField.SMOOTH
	var h := fposmod(sin(float(i) * 12.9898 + float(j) * 78.233) * 43758.5453, 1.0) * total
	if h < mix.x:
		return TerrainField.SMOOTH
	if h < mix.x + mix.y:
		return TerrainField.ROCKY
	return TerrainField.ROCK


## Узловой прямоугольник под кистью радиуса rc ячеек вокруг центра c (мир, XZ)
static func brush_rect(c: Vector2, rc: float) -> Rect2i:
	var cx := c.x / STEP
	var cz := c.y / STEP
	var x0 := floori(cx - rc)
	var x1 := ceili(cx + rc)
	var z0 := floori(cz - rc)
	var z1 := ceili(cz + rc)
	return Rect2i(x0, z0, x1 - x0 + 1, z1 - z0 + 1)


## Считать область вокруг c на самый широкий мазок и интервалы стола по строкам
func _load(field: TerrainField, c: Vector2, clip: Array) -> void:
	var tol := minf(radius * tol_frac, tol_max)
	_rect = brush_rect(c, (radius + tol) / STEP)
	var r := field.read_region(_rect)
	_w = r["w"]
	_f = r["f"]
	_iv = []
	for rj in _rect.size.y:
		_iv.append(field.row_intervals(clip, _rect.position.y + rj))


## План мазка без записи (кольца кисти и подпись). mode как у stroke
func preview(field: TerrainField, c: Vector2, ht: float, mode: int, clip: Array) -> Dictionary:
	_load(field, c, clip)
	last_plan = _plan(c, ht, mode, field.layer_height)
	return last_plan


## Мазок: считает план и меняет поле. kk доля пути к цели за вызов (1 сразу). Вызывать внутри field.begin_edit / end_edit.
## Возвращает true, если поле изменилось
func stroke(field: TerrainField, c: Vector2, ht: float, mode: int, kk: float, clip: Array) -> bool:
	_load(field, c, clip)
	var lh := field.layer_height
	last_plan = _plan(c, ht, mode, lh)
	var ch := _apply(c, last_plan, mode, kk, lh)
	if ch.size.x <= 0:
		return false
	field.write_region(_rect, _w, ch)
	return true


func _plan(c: Vector2, ht: float, mode: int, lh: float) -> Dictionary:
	var tol := minf(radius * tol_frac, tol_max)
	var dmax := radius + tol
	var pmin := minf(plateau_min, maxf(radius - STEP, STEP))
	var rmax := dmax / STEP
	var r0 := pmin / STEP
	var cx := c.x / STEP
	var cz := c.y / STEP
	var r0sq := r0 * r0
	var rmsq := rmax * rmax
	var unit_y := lh / float(TerrainField.UNITS)
	var up := 0.0
	var down := 0.0
	var x_end := _rect.end.x - 1
	for rj in _rect.size.y:
		var j := _rect.position.y + rj
		var dz := float(j) - cz
		var iv: PackedInt32Array = _iv[rj]
		var row := rj * _rect.size.x - _rect.position.x
		for q in range(0, iv.size(), 2):
			var a := maxi(iv[q], _rect.position.x)
			var b := mini(iv[q + 1], x_end)
			for i in range(a, b + 1):
				var dx := float(i) - cx
				var d2 := dx * dx + dz * dz
				if d2 < r0sq or d2 > rmsq:
					continue
				var k := row + i
				var df := ht - (_f[k] + float(_w[k] & TerrainField.TH_MASK) * unit_y)
				if df > up:
					up = df
				elif -df > down:
					down = -df
	var dh := up
	if mode < 0:
		dh = down
	elif mode == 0:
		dh = maxf(up, down)
	var t_set := tan(deg_to_rad(minf(angle, 89.99)))
	var w_min := STEP
	var w_max := maxf(dmax - pmin, w_min)
	var w_want := dh / t_set
	var w := w_want
	var limit := ""
	if w < w_min:
		w = w_min
		limit = "сетка"
	if w > w_max:
		w = w_max
		limit = "место"
	var t_eff := dh / w
	var ang := rad_to_deg(atan(t_eff))
	if limit == "сетка" and (dh < 0.0001 or angle - ang < 2.0):
		limit = ""
	var p := maxf(pmin, radius - w)
	return {"ht": ht, "dh": dh, "w": w, "p": p, "e": p + w, "t": t_eff, "ang": ang, "limit": limit}


## Меняет слова в буфере _w. Возвращает прямоугольник узлов, где что-то изменилось (size.x = 0: ничего)
func _apply(c: Vector2, pl: Dictionary, mode: int, kk: float, lh: float) -> Rect2i:
	var ht: float = pl["ht"]
	var p_cells: float = float(pl["p"]) / STEP
	var e_cells: float = float(pl["e"]) / STEP
	var tstep: float = float(pl["t"]) * STEP        # высота на одну ячейку расстояния
	var cx := c.x / STEP
	var cz := c.y / STEP
	var unit_y := lh / float(TerrainField.UNITS)
	var cap := mini(TerrainField.TH_MASK, roundi(max_layers * float(TerrainField.UNITS)))
	var esq := e_cells * e_cells
	var minx := 1 << 30
	var maxx := -(1 << 30)
	var minz := 1 << 30
	var maxz := -(1 << 30)
	var x_end := _rect.end.x - 1
	var sh := TerrainField.TYPE_SHIFT
	var mixed := mix.y > 0.0 or mix.z > 0.0
	var type_fixed := type_for(0, 0)
	for rj in _rect.size.y:
		var j := _rect.position.y + rj
		var dz := float(j) - cz
		var iv: PackedInt32Array = _iv[rj]
		var row := rj * _rect.size.x - _rect.position.x
		for q in range(0, iv.size(), 2):
			var a := maxi(iv[q], _rect.position.x)
			var b := mini(iv[q + 1], x_end)
			for i in range(a, b + 1):
				var dx := float(i) - cx
				var d2 := dx * dx + dz * dz
				if d2 > esq:
					continue
				var d := sqrt(d2)
				var k := row + i
				var w0 := _w[k]
				var u0 := w0 & TerrainField.TH_MASK
				var fl := _f[k]
				var hh := fl + float(u0) * unit_y
				var tgt := ht
				if d <= p_cells:
					if mode > 0:
						tgt = maxf(hh, ht)
					elif mode < 0:
						tgt = minf(hh, ht)
				else:
					var s := (d - p_cells) * tstep
					if mode > 0:
						tgt = maxf(hh, ht - s)
					elif mode < 0:
						tgt = minf(hh, ht + s)
					elif hh > ht:
						tgt = minf(hh, ht + s)
					else:
						tgt = maxf(hh, ht - s)
				# цель в единицах толщины. Подтягивание не короче одной единицы, иначе выравнивание остановилось бы в 0,1 слоя от цели
				var ut := clampf((tgt - fl) / unit_y, 0.0, float(cap))
				var u1 := float(u0) + (ut - float(u0)) * kk
				if kk < 1.0:
					var dd := ut - float(u0)
					if absf(dd) >= 0.5 and absf(u1 - float(u0)) < 1.0:
						u1 = float(u0) + signf(dd)
				var nu := clampi(roundi(u1), 0, cap)
				var nw := w0
				if nu != u0:
					if nu == 0:
						nw = 0
					else:
						nw = ((type_for(i, j) if mixed else type_fixed) << sh) | nu
				elif mode == 0 and u0 > 0:
					# выравнивание красит тип и там, где высота уже на месте
					nw = ((type_for(i, j) if mixed else type_fixed) << sh) | u0
				if nw != w0:
					_w[k] = nw
					if i < minx:
						minx = i
					if i > maxx:
						maxx = i
					if j < minz:
						minz = j
					if j > maxz:
						maxz = j
	if maxx < minx:
		return Rect2i()
	return Rect2i(minx, minz, maxx - minx + 1, maxz - minz + 1)
