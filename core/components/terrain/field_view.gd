class_name FieldView extends Node3D

# XX claude-terra 13.14 H1 (новый файл)
###################################
## Показ поля высот (ATTN_13 §13.14). Одна плоская сетка на окно стола, высоту вершин даёт шейдер field_surface.gdshader.
###################################
## Окно это прямоугольник узлов, выровненный по чанкам и покрывающий LYM.table_rect(). Данные поля копируются в два буфера
## окна и загружаются в текстуры: fmap (RGF: пол, толщина слоя, ю) и tmap (RGBA8: R тип и бит ложа, G слот верхнего и нижнего материала, B прозрачность и ширина перехода, A есть слой). Меш не пересобирается при правке,
## меняется только текстура (замер H0: загрузка 0,1 мс при любом радиусе). Окно и меш пересоздаются, когда меняется стол.
## Узел окна (i, j) лежит в мире в точке ((origin.x + i) * STEP, (origin.y + j) * STEP).

const SHADER_PATH := "res://core/components/terrain/field_surface.gdshader"
## Набор материалов поверхности (текстуры и оттенки каналов, H4)
## Слой тоньше этого не рисуется, ю (тот же порог, что thin_eps в шейдере)
const THIN_EPS := 0.01
## H2e: наибольший радиус окна выборки узлов в шейдере (KR), узлов. Ширина перехода материала не больше KR_MAX - 1 ячеек
const KR_MAX := 3
const MATERIALS_PATH := "res://data/terrain/field_materials.tres"
const STEP := TerrainField.STEP
const CHUNK := TerrainField.CHUNK
## Запас по краям окна, чанков
const MARGIN_CHUNKS := 1
## Наибольший размер окна по стороне, узлов (стол больше не показывается: защита от случайных гигантских секций)
const MAX_DIM := 4096
## Высота, на которой цвет типа «гладкая» доходит до серого (шесть десятых от неё), ю
const MAX_H := 16.0
## Границы по высоте для отсечения плоской сетки камерой, ю
const AABB_Y0 := -1.0
const AABB_H := 40.0

var field: TerrainField

var _mi: MeshInstance3D
var _mat: ShaderMaterial
var _tf: ImageTexture
var _tt: ImageTexture
var _img_f: Image
var _img_t: Image
var _buf_f := PackedFloat32Array()   # по два числа на узел: пол, толщина
var _k_src := {}      # Vector2i чанка -> PackedInt32Array троек (узел окна x, z, ширина перехода 1..15): слой с материалом с переходом
var _k_wide := {}     # Vector2i чанка -> true, если в чанке есть клетки с окном шире 2x2 (K > 1)
var _buf_t := PackedByteArray()      # по четыре байта на узел: тип (с битом ложа), слоты материалов, прозрачность и переход, признак слоя
var _origin := Vector2i.ZERO         # узел окна (0, 0) в мировой сетке, кратен CHUNK
var _dims := Vector2i.ZERO           # размер окна в узлах (кратен CHUNK плюс 1)
var _dirty := false
var _full := false


func _ready() -> void:
	name = &"FieldView"
	_mat = ShaderMaterial.new()
	var sh := load(SHADER_PATH) as Shader
	if sh == null:
		push_error("FieldView: нет шейдера %s" % SHADER_PATH)
		return
	_mat.shader = sh
	_mat.set_shader_parameter("step_len", STEP)
	_mat.set_shader_parameter("max_h", MAX_H)
	set_materials(load(MATERIALS_PATH) as FieldMaterials)
	_mi = MeshInstance3D.new()
	_mi.name = &"Surface"
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_mi.visible = false
	add_child(_mi)


## Сменить набор материалов поверхности. null: шейдер рисует каналы цветами по умолчанию, без текстур
func set_materials(m: FieldMaterials) -> void:
	if m == null:
		push_warning("FieldView: нет набора материалов %s, поверхность без текстур" % MATERIALS_PATH)
		return
	m.apply(_mat)


## Подключить данные. Вызывает TGM один раз
func bind(f: TerrainField) -> void:
	field = f
	field.changed.connect(_on_changed)
	field.bed_changed.connect(_on_changed)


## Окно по текущему столу. Вызывать при смене подмакетника (LYM.layout_changed) и при загрузке сейва
func refit() -> void:
	if field == null or _mi == null:
		return
	var r: Rect2 = LYM.table_rect()
	var i0 := floori(r.position.x / STEP) - MARGIN_CHUNKS * CHUNK
	var j0 := floori(r.position.y / STEP) - MARGIN_CHUNKS * CHUNK
	var i1 := ceili(r.end.x / STEP) + MARGIN_CHUNKS * CHUNK
	var j1 := ceili(r.end.y / STEP) + MARGIN_CHUNKS * CHUNK
	var c0 := TerrainField.key_of(i0, j0)
	var c1 := TerrainField.key_of(i1, j1)
	var origin := Vector2i(c0.x * CHUNK, c0.y * CHUNK)
	var dims := Vector2i((c1.x - c0.x + 1) * CHUNK + 1, (c1.y - c0.y + 1) * CHUNK + 1)
	if dims.x > MAX_DIM or dims.y > MAX_DIM:
		push_warning("FieldView: стол слишком большой для поля высот (%d x %d узлов)" % [dims.x, dims.y])
		return
	if origin == _origin and dims == _dims and _tf != null:
		return
	_origin = origin
	_dims = dims
	_build_window()


## Перекопировать всё поле в окно (после загрузки)
func rebuild_all() -> void:
	if _tf == null:
		refit()
		return
	_buf_f.fill(0.0)
	_buf_t.fill(0)
	_k_src.clear()
	_k_wide.clear()
	var all_keys: Array = []
	for key: Vector2i in field.chunk_keys():
		_copy_chunk(key)
		all_keys.append(key)
	for key: Vector2i in field.bed_keys():
		if not field.has_chunk(key):
			_copy_chunk(key)   # чанк только с ложем трака
			all_keys.append(key)
	_refresh_k(all_keys)
	_dirty = true
	_update_visible()


func _process(_delta: float) -> void:
	if _dirty and _tf != null:
		_upload()


func _on_changed(keys: Array) -> void:
	if _tf == null:
		refit()
		if _tf == null:
			return
		rebuild_all()
		return
	for key: Vector2i in keys:
		_copy_chunk(key)
	_refresh_k(keys)
	_dirty = true
	_update_visible()


func _update_visible() -> void:
	if _mi != null:
		_mi.visible = field != null and not field.is_empty()


## Окно изменилось: новые буферы, текстуры, меш и параметры шейдера
func _build_window() -> void:
	var n := _dims.x * _dims.y
	_buf_f = PackedFloat32Array()
	_buf_f.resize(n * 2)
	_buf_t = PackedByteArray()
	_buf_t.resize(n * 4)
	_img_f = Image.create_from_data(_dims.x, _dims.y, false, Image.FORMAT_RGF, _buf_f.to_byte_array())
	_img_t = Image.create_from_data(_dims.x, _dims.y, false, Image.FORMAT_RGBA8, _buf_t)
	_tf = ImageTexture.create_from_image(_img_f)
	_tt = ImageTexture.create_from_image(_img_t)
	_mat.set_shader_parameter("fmap", _tf)
	_mat.set_shader_parameter("tmap", _tt)
	_mat.set_shader_parameter("origin", _origin)
	_mat.set_shader_parameter("dims", _dims)
	_mi.mesh = _make_grid(_origin, _dims)
	_mi.custom_aabb = AABB(
		Vector3(float(_origin.x) * STEP, AABB_Y0, float(_origin.y) * STEP),
		Vector3(float(_dims.x - 1) * STEP, AABB_H, float(_dims.y - 1) * STEP))
	rebuild_all()


## Плоская сетка узлов окна в мировых координатах (y = 0)
static func _make_grid(origin: Vector2i, dims: Vector2i) -> ArrayMesh:
	var verts := PackedVector3Array()
	verts.resize(dims.x * dims.y)
	var k := 0
	for j in range(dims.y):
		for i in range(dims.x):
			verts[k] = Vector3(float(origin.x + i) * STEP, 0.0, float(origin.y + j) * STEP)
			k += 1
	var idx := PackedInt32Array()
	idx.resize((dims.x - 1) * (dims.y - 1) * 6)
	var t := 0
	for j in range(dims.y - 1):
		for i in range(dims.x - 1):
			var a := j * dims.x + i
			var b := a + 1
			var c := a + dims.x
			var d := c + 1
			# по часовой стрелке при взгляде сверху: лицевая сторона вверх (шейдер всё равно рисует обе)
			idx[t] = a
			idx[t + 1] = b
			idx[t + 2] = c
			idx[t + 3] = b
			idx[t + 4] = d
			idx[t + 5] = c
			t += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## Чанк поля в буферы окна (отсутствующий чанк обнуляет свою область). Ложе трака (H5) поверх: высота ложа вместо слоя,
## тип каменистый (бит 4 в тип: шейдер не добавляет шум высоты). Узлу ложа без данных поля пол берётся у floor_at
func _copy_chunk(key: Vector2i) -> void:
	var ci0 := key.x * CHUNK - _origin.x
	var cj0 := key.y * CHUNK - _origin.y
	if ci0 < 0 or cj0 < 0 or ci0 + CHUNK > _dims.x or cj0 + CHUNK > _dims.y:
		return
	var words := field.chunk_words(key)
	var fl := field.chunk_floor(key)
	var bed := field.chunk_bed(key)
	var bh := PackedFloat32Array()
	var bt := PackedByteArray()
	if not bed.is_empty():
		bh = bed["h"]
		bt = bed["t"]
	var lh := field.layer_height
	var have := not words.is_empty()
	var srcs := PackedInt32Array()
	for rz in range(CHUNK):
		var row := (cj0 + rz) * _dims.x + ci0
		for rx in range(CHUNK):
			var o := row + rx
			var k := rz * CHUNK + rx
			var f0 := 0.0
			var th := 0.0
			var ty := 0
			var mt := 0
			var un := 0
			var tr := 0
			var bl := 0
			if have:
				var w := words[k]
				f0 = fl[k]
				th = float(w & TerrainField.TH_MASK) / float(TerrainField.UNITS) * lh
				ty = (w >> TerrainField.TYPE_SHIFT) & TerrainField.TYPE_MASK
				mt = (w >> TerrainField.MAT_SHIFT) & TerrainField.MAT_MASK
				un = (w >> TerrainField.UNDER_SHIFT) & TerrainField.NIB_MASK
				tr = (w >> TerrainField.TRANS_SHIFT) & TerrainField.NIB_MASK
				bl = (w >> TerrainField.BLEND_SHIFT) & TerrainField.NIB_MASK
			if not bh.is_empty() and bh[k] > TerrainField.BED_NONE * 0.5:
				if not have:
					f0 = field.floor_at(key.x * CHUNK + rx, key.y * CHUNK + rz)
				th = maxf(bh[k] - f0, 0.0)
				if bt[k] != FieldBed.NO_TYPE:
					ty = bt[k]
					mt = FieldMaterials.SLOT_BED   # H2b: ложе трака рисуется материалом ложа, H2c: непрозрачно и без размытия перехода
					un = FieldMaterials.SLOT_BED
					tr = 0
					bl = 0
			if bl > 0 and th >= THIN_EPS:
				srcs.append(ci0 + rx)
				srcs.append(cj0 + rz)
				srcs.append(bl)
			_buf_f[o * 2] = f0
			_buf_f[o * 2 + 1] = th
			_buf_t[o * 4] = ty
			_buf_t[o * 4 + 1] = mt | (un << 4)
			_buf_t[o * 4 + 2] = tr | (bl << 4)
			_buf_t[o * 4 + 3] = 255 if th >= THIN_EPS else 0
	if srcs.is_empty():
		_k_src.erase(key)
	else:
		_k_src[key] = srcs
	_k_wide.erase(key)   # биты K чанка сброшены записью типа, _refresh_k выставит заново


## H2e: радиус окна шейдера по клеткам (tmap.r, биты 8 и 16: K - 1). Окно 2x2 (K = 1) точно, пока в округе нет слоя с материалом с
## шириной перехода; такой узел расширяет окно клеток, до которых дотягивается его переход. Пересчёт только чанков keys и их соседей,
## где есть узлы с переходом рядом или были раньше
func _refresh_k(keys: Array) -> void:
	var todo := {}
	for key: Vector2i in keys:
		for dj in range(-1, 2):
			for di in range(-1, 2):
				todo[key + Vector2i(di, dj)] = true
	for ck: Vector2i in todo:
		var ci0 := ck.x * CHUNK - _origin.x
		var cj0 := ck.y * CHUNK - _origin.y
		if ci0 < 0 or cj0 < 0 or ci0 + CHUNK > _dims.x or cj0 + CHUNK > _dims.y:
			continue
		var near := false
		for dj in range(-1, 2):
			for di in range(-1, 2):
				if _k_src.has(ck + Vector2i(di, dj)):
					near = true
		if not near and not _k_wide.has(ck):
			continue
		var kl := PackedByteArray()
		kl.resize(CHUNK * CHUNK)
		kl.fill(0)
		if near:
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var src: PackedInt32Array = _k_src.get(ck + Vector2i(di, dj), PackedInt32Array())
					for q in range(0, src.size(), 3):
						scatter_k(kl, src[q] - ci0, src[q + 1] - cj0, src[q + 2])
		var wide := false
		for rz in range(CHUNK):
			var row := (cj0 + rz) * _dims.x + ci0
			for rx in range(CHUNK):
				var kb := kl[rz * CHUNK + rx]
				var o := (row + rx) * 4
				_buf_t[o] = (_buf_t[o] & 7) | (kb << 3)
				if kb > 0:
					wide = true
		if wide:
			_k_wide[ck] = true
		else:
			_k_wide.erase(ck)


## H2e: вклад узла слоя с шириной перехода bn (1..15) в радиус окна клеток чанка. (lx, lz): узел в клетках относительно угла чанка
## (может лежать вне 0..CHUNK-1: узел соседнего чанка). kl: на клетку K - 1 (0..KR_MAX - 1), берётся наибольшее. Узел на смещении (ox, oz)
## от клетки (узел минус клетка) влияет на неё, если расстояние от узла до квадрата клетки меньше его радиуса влияния 1 + ширина
## перехода в ячейках (как reach в field_surface.gdshader), и входит в окно K, если ox и oz лежат в [1 - K, K]
static func scatter_k(kl: PackedByteArray, lx: int, lz: int, bn: int) -> void:
	var reach := 1.0 + minf(float(bn) / 15.0 * FieldSurface.BLEND_MAX / STEP, float(KR_MAX) - 1.0)
	for oz in range(-2, 4):
		var cz := lz - oz
		if cz < 0 or cz >= CHUNK:
			continue
		var dz := float(oz - 1) if oz > 0 else float(-oz)
		var kz := oz if oz > 0 else 1 - oz
		for ox in range(-2, 4):
			var cx := lx - ox
			if cx < 0 or cx >= CHUNK:
				continue
			var dx := float(ox - 1) if ox > 0 else float(-ox)
			if sqrt(dx * dx + dz * dz) >= reach:
				continue
			var kx := ox if ox > 0 else 1 - ox
			var idx := cz * CHUNK + cx
			kl[idx] = maxi(int(kl[idx]), maxi(kx, kz) - 1)


func _upload() -> void:
	_dirty = false
	_img_f.set_data(_dims.x, _dims.y, false, Image.FORMAT_RGF, _buf_f.to_byte_array())
	_tf.update(_img_f)
	_img_t.set_data(_dims.x, _dims.y, false, Image.FORMAT_RGBA8, _buf_t)
	_tt.update(_img_t)
