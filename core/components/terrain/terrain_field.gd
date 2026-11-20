class_name TerrainField extends RefCounted

# XX claude-terra 13.14 H1 (новый файл)
###################################
## Поле высот шпатлёвки (ATTN_13 §13.14). Данные без сцены и узлов.
###################################
## Мировая сетка узлов с шагом STEP (0,5 ю): узел (i, j) лежит в мире в точке (i * STEP, j * STEP), сетка общая на макет
## и не привязана к столу. Хранение разреженными чанками CHUNK x CHUNK узлов.
## Узел это одно слово: младшие 12 бит толщина слоя шпатлёвки над полом в 1/UNITS слоя (до 31,99 слоя),
## следующие 2 бита тип поверхности (0 гладкая, 1 каменистая, 2 скалистая, 3 запас). Толщина 0 значит «слоя нет».
## Пол (floor) вычисляет TGM по листам и столу: у стола 0, у листа верх листа. Толщина относительная: слой едет вместе с полом.
## Пол не хранится в сейве, он перевычисляется (floor_fn) при загрузке и при изменении листов.
## Поверхность узла = пол + толщина * layer_height (толщина в слоях, layer_height в ю).
## Правки идут через begin_edit / end_edit (вложенные вызовы считаются одной правкой) с историей для отмены.

const STEP := 0.5
const CHUNK := 16
const CHUNK_NODES := CHUNK * CHUNK
## Единиц толщины на один слой
const UNITS := 128
const TH_MASK := 0x0FFF
const TYPE_SHIFT := 12
const TYPE_MASK := 0x3
const SMOOTH := 0
const ROCKY := 1
const ROCK := 2
const FORMAT := 1
const MAX_HISTORY := 50
## Допуск при выборе узлов у границы полигона, ю
const EDGE := 0.001
## Две пробные строки у узла (чуть ниже и чуть выше): узлы на горизонтальной границе полигона входят в область
const PROBES: Array[float] = [-0.001, 0.001]

## Изменились чанки: keys это Array[Vector2i] (данные или пол, в том числе чанки, которые исчезли)
signal changed(keys: Array)

## Высота слоя, ю (GlobalSetting.layer_height). Выставляет TGM
var layer_height := 1.0
## Пол в точке (x, z): Callable(x: float, z: float) -> float. Пустой Callable = пол везде 0
var floor_fn := Callable()
## Вызывается один раз перед пакетом вычислений пола (TGM собирает список листов)
var floor_prepare := Callable()

var _data := {}              # Vector2i -> PackedInt32Array (CHUNK_NODES слов)
var _floor := {}             # Vector2i -> PackedFloat32Array (CHUNK_NODES, пол узла)
var _depth := 0
var _no_history := false   # правка не пишется в историю (обрезка по столу)
var _pending := {}           # Vector2i -> PackedInt32Array до правки (пустой массив: чанка не было)
var _history: Array = []     # Array из словарей _pending


## --- Индексы ---

static func key_of(i: int, j: int) -> Vector2i:
	return Vector2i(floori(float(i) / float(CHUNK)), floori(float(j) / float(CHUNK)))


## Индекс узла в массиве чанка
static func index_in_chunk(i: int, j: int) -> int:
	return posmod(j, CHUNK) * CHUNK + posmod(i, CHUNK)


## Ближайший узел к координате мира
static func node_of(v: float) -> int:
	return roundi(v / STEP)


## --- Чтение ---

func is_empty() -> bool:
	return _data.is_empty()


func chunk_keys() -> Array:
	return _data.keys()


func has_chunk(key: Vector2i) -> bool:
	return _data.has(key)


## Слова чанка (CHUNK_NODES). Пусто, если чанка нет. Массив не менять снаружи
func chunk_words(key: Vector2i) -> PackedInt32Array:
	if not _data.has(key):
		return PackedInt32Array()
	return _data[key]


## Пол чанка (CHUNK_NODES). Пусто, если чанка нет
func chunk_floor(key: Vector2i) -> PackedFloat32Array:
	if not _floor.has(key):
		return PackedFloat32Array()
	return _floor[key]


func word_at(i: int, j: int) -> int:
	var key := key_of(i, j)
	if not _data.has(key):
		return 0
	var d: PackedInt32Array = _data[key]
	return d[index_in_chunk(i, j)]


## Толщина слоя в узле, слоёв
func layers_at(i: int, j: int) -> float:
	return float(word_at(i, j) & TH_MASK) / float(UNITS)


## Толщина слоя в узле, ю
func thickness(i: int, j: int) -> float:
	return layers_at(i, j) * layer_height


func has_layer(i: int, j: int) -> bool:
	return (word_at(i, j) & TH_MASK) != 0


func type_at(i: int, j: int) -> int:
	return (word_at(i, j) >> TYPE_SHIFT) & TYPE_MASK


func floor_at(i: int, j: int) -> float:
	var key := key_of(i, j)
	if not _floor.has(key):
		# чанка нет (соседний ряд узлов карты коллизии): пол считаем напрямую, иначе у слоя на листе край провалится к столу
		if floor_fn.is_valid():
			return float(floor_fn.call(float(i) * STEP, float(j) * STEP))
		return 0.0
	var f: PackedFloat32Array = _floor[key]
	return f[index_in_chunk(i, j)]


## Высота поверхности узла: пол + слой
func surface_at(i: int, j: int) -> float:
	return floor_at(i, j) + thickness(i, j)


## Высота поверхности в точке мира (билинейно по четырём узлам)
func sample(x: float, z: float) -> float:
	var fx := x / STEP
	var fz := z / STEP
	var i := floori(fx)
	var j := floori(fz)
	var tx := fx - float(i)
	var tz := fz - float(j)
	var a := lerpf(surface_at(i, j), surface_at(i + 1, j), tx)
	var b := lerpf(surface_at(i, j + 1), surface_at(i + 1, j + 1), tx)
	return lerpf(a, b, tz)


## Есть ли слой хотя бы в одном из четырёх узлов вокруг точки мира
func covered(x: float, z: float) -> bool:
	var i := floori(x / STEP)
	var j := floori(z / STEP)
	return has_layer(i, j) or has_layer(i + 1, j) or has_layer(i, j + 1) or has_layer(i + 1, j + 1)


## Число узлов со слоем (для проверок и отладки)
func layer_node_count() -> int:
	var n := 0
	for key: Vector2i in _data:
		var d: PackedInt32Array = _data[key]
		for w in d:
			if (w & TH_MASK) != 0:
				n += 1
	return n


## Ограничивающий прямоугольник узлов со слоем (мир, XZ). Пустое поле: Rect2()
func bounds() -> Rect2:
	var any := false
	var r := Rect2()
	for key: Vector2i in _data:
		var cr := Rect2(float(key.x * CHUNK) * STEP, float(key.y * CHUNK) * STEP, float(CHUNK) * STEP, float(CHUNK) * STEP)
		r = cr if not any else r.merge(cr)
		any = true
	return r


## --- Правки ---

func begin_edit() -> void:
	_depth += 1
	if _depth == 1:
		_pending = {}
		_prepare_floor()


## Закончить правку. Вложенные вызовы закрывают правку только на внешнем end_edit. Пустая правка в историю не попадает
func end_edit() -> void:
	_depth = maxi(_depth - 1, 0)
	if _depth > 0:
		return
	if _pending.is_empty():
		return
	for key: Vector2i in _pending:
		if _data.has(key) and _is_zero(_data[key]):
			_data.erase(key)
			_floor.erase(key)
	var keys := _pending.keys()
	if not _no_history:
		_history.append(_pending)
	_pending = {}
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	changed.emit(keys)


## Положить слой толщиной layers (в слоях) на узлы внутри полигона poly (мировые XZ, граница входит).
## Узлы, где слой уже толще, не меняются. Возвращает число изменённых узлов
func lay_polygon(poly: PackedVector2Array, layers: float) -> int:
	var units := clampi(roundi(layers * float(UNITS)), 1, TH_MASK)
	return _apply(poly, units, false)


## Снять слой (и тип) с узлов внутри полигона. Возвращает число изменённых узлов
func erase_polygon(poly: PackedVector2Array) -> int:
	return _apply(poly, 0, true)


## Положить слой толщиной layers на прямоугольник r (мир, XZ, граница входит)
func lay_rect(r: Rect2, layers: float) -> int:
	return lay_polygon(_rect_poly(r), layers)


func erase_rect(r: Rect2) -> int:
	return erase_polygon(_rect_poly(r))


## Убрать слой с узлов вне всех полигонов polys (например, вне секций стола). Возвращает число снятых узлов
func clip_to_polygons(polys: Array) -> int:
	if _data.is_empty():
		return 0
	var mask := {}   # Vector2i -> PackedByteArray: 1 у узлов внутри
	for poly: PackedVector2Array in polys:
		for sp: Array in _spans(poly):
			var j: int = sp[0]
			for i in range(int(sp[1]), int(sp[2]) + 1):
				var key := key_of(i, j)
				var m: PackedByteArray
				if mask.has(key):
					m = mask[key]
				else:
					m = PackedByteArray()
					m.resize(CHUNK_NODES)
					mask[key] = m
				m[index_in_chunk(i, j)] = 1
	var n := 0
	_no_history = true   # обрезка по столу не правка игрока: Ctrl+Z её не отменяет
	begin_edit()
	for key: Vector2i in _data.keys():
		var d: PackedInt32Array = _data[key]
		var m: PackedByteArray = mask.get(key, PackedByteArray())
		var bad := false
		for k in range(CHUNK_NODES):
			if d[k] != 0 and (m.is_empty() or m[k] == 0):
				bad = true
				break
		if not bad:
			continue
		_touch(key)
		for k in range(CHUNK_NODES):
			if d[k] != 0 and (m.is_empty() or m[k] == 0):
				d[k] = 0
				n += 1
		_data[key] = d
	end_edit()
	_no_history = false
	return n


## Отменить последнюю правку. false: отменять нечего
func undo() -> bool:
	if _history.is_empty():
		return false
	var rec: Dictionary = _history.pop_back()
	_prepare_floor()
	var keys := rec.keys()
	for key: Vector2i in rec:
		var before: PackedInt32Array = rec[key]
		if before.is_empty():
			_data.erase(key)
			_floor.erase(key)
		else:
			_data[key] = before
			_make_floor(key)
	changed.emit(keys)
	return true


func can_undo() -> bool:
	return not _history.is_empty()


## Очистить всё поле (новый макет, загрузка сейва). История тоже очищается
func clear() -> void:
	var keys := _data.keys()
	_data = {}
	_floor = {}
	_pending = {}
	_history = []
	_depth = 0
	if not keys.is_empty():
		changed.emit(keys)


## --- Пол ---

## Пересчитать пол в области area (мир, XZ) у существующих чанков. Сообщает changed о тех чанках, где пол изменился
func refresh_floor(area: Rect2) -> void:
	if _data.is_empty() or not floor_fn.is_valid():
		return
	_prepare_floor()
	var i0 := floori(area.position.x / STEP)
	var i1 := ceili(area.end.x / STEP)
	var j0 := floori(area.position.y / STEP)
	var j1 := ceili(area.end.y / STEP)
	var k0 := key_of(i0, j0)
	var k1 := key_of(i1, j1)
	var keys: Array = []
	for cz in range(k0.y, k1.y + 1):
		for cx in range(k0.x, k1.x + 1):
			var key := Vector2i(cx, cz)
			if not _data.has(key):
				continue
			var f: PackedFloat32Array = _floor[key]
			var any := false
			for jj in range(maxi(j0, cz * CHUNK), mini(j1, cz * CHUNK + CHUNK - 1) + 1):
				for ii in range(maxi(i0, cx * CHUNK), mini(i1, cx * CHUNK + CHUNK - 1) + 1):
					var n := (jj - cz * CHUNK) * CHUNK + (ii - cx * CHUNK)
					var v := float(floor_fn.call(float(ii) * STEP, float(jj) * STEP))
					if not is_equal_approx(f[n], v):
						f[n] = v
						any = true
			if any:
				_floor[key] = f
				keys.append(key)
	if not keys.is_empty():
		changed.emit(keys)


func _prepare_floor() -> void:
	if floor_prepare.is_valid():
		floor_prepare.call()


func _make_floor(key: Vector2i) -> void:
	var f := PackedFloat32Array()
	f.resize(CHUNK_NODES)
	if floor_fn.is_valid():
		for rz in range(CHUNK):
			for rx in range(CHUNK):
				f[rz * CHUNK + rx] = float(floor_fn.call(float(key.x * CHUNK + rx) * STEP, float(key.y * CHUNK + rz) * STEP))
	_floor[key] = f


## --- Сейв ---

## {"v", "chunks": [[cx, cz, сжатые байты], ...]}: на узел 16 бит (слово), чанки без слоя не пишутся
func save_data() -> Dictionary:
	var list: Array = []
	for key: Vector2i in _data:
		var d: PackedInt32Array = _data[key]
		if _is_zero(d):
			continue
		var bytes := PackedByteArray()
		bytes.resize(CHUNK_NODES * 2)
		for k in range(CHUNK_NODES):
			bytes.encode_u16(k * 2, d[k])
		list.append([key.x, key.y, bytes.compress(FileAccess.COMPRESSION_DEFLATE)])
	if list.is_empty():
		return {}
	return {"v": FORMAT, "chunks": list}


## Загрузить из save_data. Пустой словарь (сейв до поля) очищает поле. Пол считается заново через floor_fn
func load_data(d: Dictionary) -> void:
	clear()
	if d.is_empty():
		return
	_prepare_floor()
	var keys: Array = []
	for item in d.get("chunks", []):
		var arr: Array = item
		if arr.size() < 3:
			continue
		var bytes := (arr[2] as PackedByteArray).decompress(CHUNK_NODES * 2, FileAccess.COMPRESSION_DEFLATE)
		if bytes.size() != CHUNK_NODES * 2:
			continue
		var words := PackedInt32Array()
		words.resize(CHUNK_NODES)
		for k in range(CHUNK_NODES):
			words[k] = bytes.decode_u16(k * 2)
		var key := Vector2i(int(arr[0]), int(arr[1]))
		_data[key] = words
		_make_floor(key)
		keys.append(key)
	if not keys.is_empty():
		changed.emit(keys)


## --- Внутреннее ---

static func _rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


static func _is_zero(d: PackedInt32Array) -> bool:
	for w in d:
		if w != 0:
			return false
	return true


func _touch(key: Vector2i) -> void:
	if _pending.has(key):
		return
	if _data.has(key):
		var d: PackedInt32Array = _data[key]
		_pending[key] = d.duplicate()
	else:
		_pending[key] = PackedInt32Array()


func _apply(poly: PackedVector2Array, units: int, erase: bool) -> int:
	if poly.size() < 3:
		return 0
	var n := 0
	begin_edit()
	for sp: Array in _spans(poly):
		var j: int = sp[0]
		for i in range(int(sp[1]), int(sp[2]) + 1):
			n += _set_node(i, j, units, erase)
	end_edit()
	return n


## Записать узел: слой не тоньше units (erase: слой снят). Возвращает 1, если узел изменился
func _set_node(i: int, j: int, units: int, erase: bool) -> int:
	var key := key_of(i, j)
	var idx := index_in_chunk(i, j)
	var d := PackedInt32Array()
	if _data.has(key):
		d = _data[key]
	if erase:
		if d.is_empty() or d[idx] == 0:
			return 0
		_touch(key)
		d[idx] = 0
		_data[key] = d
		return 1
	var w := 0
	if not d.is_empty():
		w = d[idx]
	if (w & TH_MASK) >= units:
		return 0
	_touch(key)
	if d.is_empty():
		d.resize(CHUNK_NODES)
		_data[key] = d
		_make_floor(key)
	d[idx] = (w & (TYPE_MASK << TYPE_SHIFT)) | units
	_data[key] = d
	return 1


## Строки растеризации полигона: массив [j, i0, i1] (узлы i0..i1 строки j включительно, граница входит)
func _spans(poly: PackedVector2Array) -> Array:
	var res: Array = []
	if poly.size() < 3:
		return res
	var miny := poly[0].y
	var maxy := miny
	for p in poly:
		miny = minf(miny, p.y)
		maxy = maxf(maxy, p.y)
	var j0 := ceili(miny / STEP - 0.01)
	var j1 := floori(maxy / STEP + 0.01)
	for j in range(j0, j1 + 1):
		var z := float(j) * STEP
		for dz in PROBES:
			var xs := _crossings(poly, z + dz)
			for a in range(0, xs.size() - 1, 2):
				var i0 := ceili((xs[a] - EDGE) / STEP)
				var i1 := floori((xs[a + 1] + EDGE) / STEP)
				if i1 >= i0:
					res.append([j, i0, i1])
	return res


## Отсортированные X пересечений полигона с горизонталью z (правило «полуинтервала» по Y, чётное-нечётное)
static func _crossings(poly: PackedVector2Array, z: float) -> PackedFloat32Array:
	var xs := PackedFloat32Array()
	var n := poly.size()
	for k in range(n):
		var a := poly[k]
		var b := poly[(k + 1) % n]
		if (a.y <= z) != (b.y <= z):
			xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
	xs.sort()
	return xs
