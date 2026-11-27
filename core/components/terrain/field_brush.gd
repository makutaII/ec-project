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
## Пределы (H3): сверху потолок (низ листа над узлом, ceiling_fn), выше него насыпать нельзя, холм упирается в лист; узел, который уже выше потолка,
## насыпка не трогает. Снизу пол (стол, верх листа): толщина не уходит в минус. Объекты в зоне (objects_mode): 0 игнорировать, 1 обходить
## (узлы под следом объекта не меняются, следы кладёт в obstacles инструмент), 2 поднимать (поднимает сам инструмент, кисть работает как при игнорировании).

const STEP := TerrainField.STEP
## Сторона блока узлов, в котором смесь типов даёт один тип (H4)
const MIX_BLOCK := 3
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
var radius_max := 15.0
## H2b: поверхности кисти (FieldSurface) и их слова: класс рельефа и слот материала в битах узла. Пусто: плоская базовая (слот 0, гладкая)
var surfaces: Array[FieldSurface] = []
var materials: FieldMaterials   # палитра слотов; null: общая FieldMaterials.shared()
## H2d: настройки игрока поверх карточки (панель «Инструмент»): -1 значение из поверхности, иначе своё для всех поверхностей кисти
var ov_opacity := -1.0
var ov_feather := -1.0     # ю
var ov_blend := -1.0       # ю
var ov_kind := -1          # класс рельефа
## H2d: режим «только краска»: мазок меняет материал и прозрачность существующих узлов в радиусе кисти, рельеф не трогает
var paint_only := false
var _src: Array[FieldSurface] = []
var _bits := PackedInt32Array([0])       # на поверхность: (слот << MAT_SHIFT) | (класс << TYPE_SHIFT)
var _cum := PackedFloat32Array([1.0])    # накопленные веса поверхностей
# H2c: на поверхность непрозрачность 0..1, мягкий край в ячейках и ширина перехода 0..15 (в слове узла)
var _opac := PackedFloat32Array([1.0])
var _feath := PackedFloat32Array([0.0])
var _blend := PackedInt32Array([0])
const OBJ_IGNORE := 0
const OBJ_BYPASS := 1
const OBJ_LIFT := 2
var objects_mode := OBJ_BYPASS
## Следы объектов (Array[PackedVector2Array], мировые XZ): ставит инструмент. Работают только в режиме OBJ_BYPASS
var obstacles: Array = []
## Потолок по узлам области: Callable(r: Rect2i) -> PackedFloat32Array (мир, Y; INF нет; пустой массив: потолка нигде нет). Пустой Callable: потолка нет
var ceiling_fn := Callable()
var type_names: Array[String] = ["гладкая", "каменистая", "скалистая"]

## План последнего мазка (preview и stroke): {"ht", "dh", "w", "p", "e", "t", "ang", "limit"}
var last_plan := {}

var _rect := Rect2i()
var _w := PackedInt32Array()
var _f := PackedFloat32Array()
var _iv: Array = []        # по строке области: PackedInt32Array интервалов узлов внутри стола
var _c := PackedFloat32Array()      # потолок по узлам области (пусто: нигде нет)
var _lock := PackedByteArray()      # 1: узел под объектом, мазок его не трогает (пусто: таких нет)


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
	set_surfaces(b.surfaces)
	objects_mode = clampi(b.objects_mode, OBJ_IGNORE, OBJ_LIFT)


## Поверхности кисти (H2b): считает слова узла и накопленные веса. Слот берётся у палитры materials
func set_surfaces(list: Array[FieldSurface]) -> void:
	_src.assign(list)
	surfaces = []
	_bits = PackedInt32Array()
	_cum = PackedFloat32Array()
	_opac = PackedFloat32Array()
	_feath = PackedFloat32Array()
	_blend = PackedInt32Array()
	var pal := materials if materials != null else FieldMaterials.shared()
	var total := 0.0
	for s in list:
		if s == null or s.weight <= 0.0:
			continue
		surfaces.append(s)
		var slot := pal.slot_of(s) if pal != null else FieldMaterials.SLOT_BASE
		var kind := ov_kind if ov_kind >= 0 else s.kind
		_bits.append(((kind & TerrainField.TYPE_MASK) << TerrainField.TYPE_SHIFT) | ((slot & TerrainField.MAT_MASK) << TerrainField.MAT_SHIFT))
		total += s.weight
		_cum.append(total)
		_opac.append(clampf(ov_opacity if ov_opacity >= 0.0 else s.opacity, 0.0, 1.0))
		_feath.append(maxf(ov_feather if ov_feather >= 0.0 else s.feather, 0.0) / STEP)
		_blend.append(_blend_nibble(ov_blend if ov_blend >= 0.0 else s.blend))
	if _bits.is_empty():
		var kind0 := maxi(ov_kind, 0)
		_bits = PackedInt32Array([(kind0 & TerrainField.TYPE_MASK) << TerrainField.TYPE_SHIFT])
		_cum = PackedFloat32Array([1.0])
		_opac = PackedFloat32Array([clampf(ov_opacity, 0.0, 1.0) if ov_opacity >= 0.0 else 1.0])
		_feath = PackedFloat32Array([maxf(ov_feather, 0.0) / STEP])
		_blend = PackedInt32Array([_blend_nibble(maxf(ov_blend, 0.0))])


## H2d: ширина перехода в слове узла (0..15) по ширине в ю
static func _blend_nibble(blend: float) -> int:
	return clampi(roundi(clampf(blend, 0.0, FieldSurface.BLEND_MAX) / FieldSurface.BLEND_MAX * 15.0), 0, 15)


## H2d: пересчитать слова поверхностей после смены переопределений ov_* или материала
func reapply_surfaces() -> void:
	set_surfaces(_src)


## H2d: действующие значения первой поверхности кисти (с учётом переопределений) для слайдеров панели
func opacity_now() -> float:
	return _opac[0]


func feather_now() -> float:
	return _feath[0] * STEP


func blend_now() -> float:
	return float(_blend[0]) / 15.0 * FieldSurface.BLEND_MAX


func kind_now() -> int:
	return (_bits[0] >> TerrainField.TYPE_SHIFT) & TerrainField.TYPE_MASK


## Подпись поверхности кисти: подпись одной поверхности (или название её класса рельефа) или «смесь»
func type_label() -> String:
	if surfaces.size() <= 1:
		if surfaces.is_empty():
			return type_names[TerrainField.SMOOTH]
		var s := surfaces[0]
		return s.label if s.label != "" else type_names[clampi(s.kind, 0, type_names.size() - 1)]
	return "смесь"


## Следующая высота площадки на щелчок колеса: на notch_layers от текущей или до ближайшего целого слоя. ceil_c потолок над точкой (мир Y)
func next_height(hc: float, dir_: float, whole: bool, lh: float, floor_c: float, ceil_c := INF) -> float:
	var ht := hc + dir_ * notch_layers * lh
	if whole:
		var rel := (hc - floor_c) / lh
		if dir_ > 0.0:
			ht = floor_c + (floorf(rel + 0.001) + 1.0) * lh
		else:
			ht = floor_c + (ceilf(rel - 0.001) - 1.0) * lh
	return clampf(ht, floor_c, minf(floor_c + max_layers * lh, maxf(ceil_c, floor_c)))


## Индекс поверхности кисти для узла (i, j) по весам и хешу узла
func _pick(i: int, j: int) -> int:
	if _bits.size() <= 1:
		return 0
	# поверхность выбирается по хешу блока MIX_BLOCK x MIX_BLOCK узлов: пятна материалов в 1,5 ю, а не пёстрая крошка по ячейкам
	var bi := floori(float(i) / float(MIX_BLOCK))
	var bj := floori(float(j) / float(MIX_BLOCK))
	var h := fposmod(sin(float(bi) * 12.9898 + float(bj) * 78.233) * 43758.5453, 1.0) * _cum[_cum.size() - 1]
	for k in _cum.size():
		if h < _cum[k]:
			return k
	return _bits.size() - 1


## Биты типа и верхнего материала узла (i, j) по весам поверхностей кисти и хешу узла. Слой толщины и прозрачность в них не входят
func bits_for(i: int, j: int) -> int:
	return _bits[_pick(i, j)]


## H2c: биты узла (тип, верхний и нижний материал, прозрачность, ширина перехода) для мазка в узел (i, j) на расстоянии d ячеек от центра
## при крае кисти на e_cells ячеек. w0 прежнее слово узла (толщина в нём не нужна, слой нового слова ставит вызывающий).
## Непрозрачность: opacity поверхности, у края мазка спадает на feather ячеек. Прежний материал уходит вниз и просвечивает;
## тот же верхний материал долю не наращивает (opacity потолок), нет прежнего слоя: внизу базовый слот. Класс рельефа меняется,
## когда верхний материал виден хотя бы наполовину
func paint_bits(w0: int, i: int, j: int, d: float, e_cells: float) -> int:
	var k := _pick(i, j)
	var bits := _bits[k]
	var top := (bits >> TerrainField.MAT_SHIFT) & TerrainField.MAT_MASK
	var kind := (bits >> TerrainField.TYPE_SHIFT) & TerrainField.TYPE_MASK
	var an := _opac[k]
	if _feath[k] > 0.0:
		an *= clampf((e_cells - d) / _feath[k], 0.0, 1.0)
	var old_has := (w0 & TerrainField.TH_MASK) > 0
	var old_top := (w0 >> TerrainField.MAT_SHIFT) & TerrainField.MAT_MASK
	var old_under := (w0 >> TerrainField.UNDER_SHIFT) & TerrainField.NIB_MASK
	var old_alpha := 1.0 - float((w0 >> TerrainField.TRANS_SHIFT) & TerrainField.NIB_MASK) / 15.0
	var under := FieldMaterials.SLOT_BASE
	var alpha := an
	if old_has:
		if old_top == top:
			under = old_under
			alpha = maxf(old_alpha, an)
		else:
			under = old_top if old_alpha >= 0.5 else old_under
		if alpha < 0.5 and old_top != top:
			kind = (w0 >> TerrainField.TYPE_SHIFT) & TerrainField.TYPE_MASK
	var tr := clampi(roundi((1.0 - alpha) * 15.0), 0, 15)
	return (kind << TerrainField.TYPE_SHIFT) | (top << TerrainField.MAT_SHIFT) | (under << TerrainField.UNDER_SHIFT) \
			| (tr << TerrainField.TRANS_SHIFT) | (_blend[k] << TerrainField.BLEND_SHIFT)


## Класс рельефа узла (гладкая, каменистая, скалистая) по весам кисти и хешу узла
func type_for(i: int, j: int) -> int:
	return (bits_for(i, j) >> TerrainField.TYPE_SHIFT) & TerrainField.TYPE_MASK


## Слот материала узла по весам кисти и хешу узла
func mat_for(i: int, j: int) -> int:
	return (bits_for(i, j) >> TerrainField.MAT_SHIFT) & TerrainField.MAT_MASK


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
	_c = ceiling_fn.call(_rect) if ceiling_fn.is_valid() else PackedFloat32Array()
	_lock = PackedByteArray()
	if objects_mode == OBJ_BYPASS and not obstacles.is_empty():
		_load_locks(field)


## Узлы под следами объектов в _lock (одна строка области за раз через row_intervals)
func _load_locks(field: TerrainField) -> void:
	var area := Rect2(Vector2(_rect.position) * STEP, Vector2(_rect.size) * STEP).grow(STEP)
	var near: Array = []
	for poly: PackedVector2Array in obstacles:
		if C_Contour.bounds_of(poly).intersects(area):
			near.append(poly)
	if near.is_empty():
		return
	_lock.resize(_rect.size.x * _rect.size.y)
	var x_end := _rect.end.x - 1
	for rj in _rect.size.y:
		var iv := field.row_intervals(near, _rect.position.y + rj)
		var row := rj * _rect.size.x - _rect.position.x
		for q in range(0, iv.size(), 2):
			for i in range(maxi(iv[q], _rect.position.x), mini(iv[q + 1], x_end) + 1):
				_lock[row + i] = 1


## Предел толщины узла k в единицах: по max_layers и по потолку (не больше cap, у узла без потолка cap)
func _node_cap(k: int, fl: float, unit_y: float, cap: int) -> int:
	if _c.is_empty():
		return cap
	var ce := _c[k]
	if is_inf(ce):
		return cap
	return clampi(floori((ce - fl) / unit_y + 0.001), 0, cap)


## План мазка без записи (кольца кисти и подпись). mode как у stroke
func preview(field: TerrainField, c: Vector2, ht: float, mode: int, clip: Array) -> Dictionary:
	_load(field, c, clip)
	last_plan = _paint_plan(ht) if paint_only else _plan(c, ht, mode, field.layer_height)
	return last_plan


## H2d: «план» режима «только краска»: рельеф не меняется, кольцо кисти одно (радиус)
func _paint_plan(ht: float) -> Dictionary:
	return {"ht": ht, "dh": 0.0, "w": 0.0, "p": radius, "e": radius, "t": 0.0, "ang": angle, "limit": ""}


## Мазок: считает план и меняет поле. kk доля пути к цели за вызов (1 сразу). Вызывать внутри field.begin_edit / end_edit.
## Возвращает true, если поле изменилось
func stroke(field: TerrainField, c: Vector2, ht: float, mode: int, kk: float, clip: Array) -> bool:
	_load(field, c, clip)
	var lh := field.layer_height
	var ch: Rect2i
	if paint_only:
		last_plan = _paint_plan(ht)
		ch = _apply_paint(c)
	else:
		last_plan = _plan(c, ht, mode, lh)
		ch = _apply(c, last_plan, mode, kk, lh)
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
	var capped := false
	var locked := false
	var cap0 := mini(TerrainField.TH_MASK, roundi(max_layers * float(TerrainField.UNITS)))
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
				if not _lock.is_empty() and _lock[k] != 0:
					locked = true
					continue
				var hh := _f[k] + float(_w[k] & TerrainField.TH_MASK) * unit_y
				var df := ht - hh
				if df > 0.0:
					# выше потолка не насыпать: достижимая высота узла f + cap * unit_y (но не ниже того, что уже есть)
					var reach := _f[k] + float(_node_cap(k, _f[k], unit_y, cap0)) * unit_y
					if reach < ht - 0.0001 and not _c.is_empty() and not is_inf(_c[k]):
						capped = true   # упор именно в лист, а не в max_layers
					df = clampf(reach - hh, 0.0, df)
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
	return {"ht": ht, "dh": dh, "w": w, "p": p, "e": p + w, "t": t_eff, "ang": ang, "limit": limit, "ceiling": capped and mode >= 0, "locked": locked}


## H2d: режим «только краска». Красит существующие узлы в радиусе кисти (мимо следов объектов): материал, прозрачность, переход.
## Толщину узлов не трогает. Возвращает прямоугольник изменённых узлов (пустой, если менять нечего)
func _apply_paint(c: Vector2) -> Rect2i:
	var r_cells := radius / STEP
	var rsq := r_cells * r_cells
	var cx := c.x / STEP
	var cz := c.y / STEP
	var minx := 1 << 30
	var maxx := -(1 << 30)
	var minz := 1 << 30
	var maxz := -(1 << 30)
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
				if d2 > rsq:
					continue
				var k := row + i
				if not _lock.is_empty() and _lock[k] != 0:
					continue
				var w0 := _w[k]
				var u0 := w0 & TerrainField.TH_MASK
				if u0 == 0:
					continue
				var nw := paint_bits(w0, i, j, sqrt(d2), r_cells) | u0
				if nw != w0:
					_w[k] = nw
					minx = mini(minx, i)
					maxx = maxi(maxx, i)
					minz = mini(minz, j)
					maxz = maxi(maxz, j)
	if maxx < minx:
		return Rect2i()
	return Rect2i(minx, minz, maxx - minx + 1, maxz - minz + 1)


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
				if not _lock.is_empty() and _lock[k] != 0:
					continue
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
				var ncap := _node_cap(k, fl, unit_y, cap)
				var ut := clampf((tgt - fl) / unit_y, 0.0, float(ncap))
				if mode > 0 and ut < float(u0):
					ut = float(u0)   # подъём не опускает, даже если узел уже выше потолка (объект или лист вошли в холм)
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
						nw = paint_bits(w0, i, j, d, e_cells) | nu
				elif mode == 0 and u0 > 0:
					# выравнивание красит тип и там, где высота уже на месте
					nw = paint_bits(w0, i, j, d, e_cells) | u0
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
