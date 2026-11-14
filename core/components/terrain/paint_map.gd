class_name PaintMap extends RefCounted

# XX claude-terra 13.13 K1 (новый файл)
###################################
## Краска кистей «Трава», «Скала», «Гравий» (ATTN_13 §13.13). Данные без сцены и узлов.
###################################
## Мировая сетка: ячейка краски совпадает с ячейкой оболочки (PlasterSkin.cell_size), индекс ячейки i = floor(x / cell).
## Хранение разреженными чанками CHUNK x CHUNK ячеек, на ячейку CHANNELS байт: вес каждого класса 0..255.
## Сумма весов не больше 255, остаток это «краски нет» (основа листа). Мазок тянет вектор весов ячейки к цели
## (255 у класса кисти или 0 везде при стирании) с силой a = спад по расстоянию * сила.
## Краска ступени, TGM, воду и физику не меняет. Положение листа краску не двигает (мир, а не лист).

const CHUNK := 16
const CHANNELS := 4
const CHUNK_BYTES := CHUNK * CHUNK * CHANNELS
## Классы это номера каналов. Четвёртый канал в запасе (снег, песок)
const GRASS := 0
const ROCK := 1
const GRAVEL := 2
const RESERVE := 3
## Класс «стереть» для stamp
const ERASE := -1
## Вес ниже порога при стирании и другие классы при покраске сбрасываются в 0, у класса кисти выше 255 - порог в 255
## (иначе округление оставляет хвосты 1-5 навсегда)
const SNAP := 6
const FORMAT := 1

## Чанки изменились: keys это Array[Vector2i] индексов чанков (в том числе полностью стёртых)
signal changed(keys: Array)

## Размер ячейки, ю. 0 = карта пуста и размер ещё не выбран
var cell := 0.0

var _chunks := {}            # Vector2i -> PackedByteArray (CHUNK_BYTES)
var _stroke := false
var _before := {}            # Vector2i -> PackedByteArray до мазка (пустой массив: чанка не было)


## Спад кисти: 1 внутри радиуса hardness * radius, затем плавно до 0 на radius
static func falloff(dist: float, radius: float, hardness: float) -> float:
	if radius <= 0.0 or dist >= radius:
		return 0.0
	var inner := radius * clampf(hardness, 0.0, 1.0)
	if dist <= inner:
		return 1.0
	var t := (dist - inner) / (radius - inner)
	return 1.0 - t * t * (3.0 - 2.0 * t)


static func chunk_of(i: int, j: int) -> Vector2i:
	return Vector2i(floori(float(i) / CHUNK), floori(float(j) / CHUNK))


func is_empty() -> bool:
	return _chunks.is_empty()


func chunk_keys() -> Array:
	return _chunks.keys()


## Размер ячейки выбирается один раз по первой краске: дальше сетка карты не меняется (иначе краска уехала бы)
func ensure_cell(c: float) -> void:
	if _chunks.is_empty() and c > 0.0:
		cell = c


## --- Чтение ---

## Веса ячейки (i, j): r = трава, g = скала, b = гравий, a = запас; 0..1. Нет краски: все нули
func weights(i: int, j: int) -> Color:
	var key := chunk_of(i, j)
	if not _chunks.has(key):
		return Color(0, 0, 0, 0)
	var data: PackedByteArray = _chunks[key]
	var o := _offset(i, j, key)
	return Color(data[o], data[o + 1], data[o + 2], data[o + 3]) / 255.0


## Сырые байты чанка (CHUNK_BYTES, по ячейкам строка за строкой, CHANNELS на ячейку: трава, скала, гравий, запас).
## Пусто, если в чанке краски не было
func chunk_bytes(key: Vector2i) -> PackedByteArray:
	if not _chunks.has(key):
		return PackedByteArray()
	return _chunks[key]


## K4. Веса классов по полю w x d: 4 байта на ячейку (трава, скала, гравий, запас), строка за строкой. Ячейка (0, 0) поля
## это ячейка (i0, j0) карты. Нет краски: нули
func field_weights(i0: int, j0: int, w: int, d: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * d * CHANNELS)
	for key: Vector2i in _chunks:
		var gx0 := key.x * CHUNK
		var gz0 := key.y * CHUNK
		if gx0 + CHUNK <= i0 or gx0 >= i0 + w or gz0 + CHUNK <= j0 or gz0 >= j0 + d:
			continue
		var data: PackedByteArray = _chunks[key]
		for cj in CHUNK:
			var gj := gz0 + cj - j0
			if gj < 0 or gj >= d:
				continue
			for ci in CHUNK:
				var gi := gx0 + ci - i0
				if gi < 0 or gi >= w:
					continue
				var s := (cj * CHUNK + ci) * CHANNELS
				var o := (gj * w + gi) * CHANNELS
				out[o] = data[s]
				out[o + 1] = data[s + 1]
				out[o + 2] = data[s + 2]
				out[o + 3] = data[s + 3]
	return out


## K3. Где есть краска: маска w x d (1 = в ячейке есть любой вес). Ячейка (0, 0) маски это ячейка (i0, j0) карты
func painted_mask(i0: int, j0: int, w: int, d: int) -> PackedByteArray:
	var mark := PackedByteArray()
	mark.resize(w * d)
	for key: Vector2i in _chunks:
		var gx0 := key.x * CHUNK
		var gz0 := key.y * CHUNK
		if gx0 + CHUNK <= i0 or gx0 >= i0 + w or gz0 + CHUNK <= j0 or gz0 >= j0 + d:
			continue
		var data: PackedByteArray = _chunks[key]
		for cj in CHUNK:
			var gj := gz0 + cj - j0
			if gj < 0 or gj >= d:
				continue
			for ci in CHUNK:
				var gi := gx0 + ci - i0
				if gi < 0 or gi >= w:
					continue
				var o := (cj * CHUNK + ci) * CHANNELS
				if (data[o] | data[o + 1] | data[o + 2] | data[o + 3]) != 0:
					mark[gj * w + gi] = 1
	return mark


## Класс с наибольшим весом или -1, если краски меньше трети (85 из 255)
func dominant(i: int, j: int) -> int:
	var w := weights(i, j)
	var best := -1
	var best_v := 85.0 / 255.0
	for ch in CHANNELS:
		if w[ch] > best_v:
			best_v = w[ch]
			best = ch
	return best


func _offset(i: int, j: int, key: Vector2i) -> int:
	return ((j - key.y * CHUNK) * CHUNK + (i - key.x * CHUNK)) * CHANNELS


## --- Запись ---

## Начать мазок: прежние данные тронутых чанков запоминаются для отмены
func begin_stroke() -> void:
	_stroke = true
	_before = {}


## Закончить мазок. Запись для restore(): {Vector2i: PackedByteArray}. Пусто, если мазок ничего не изменил
func end_stroke() -> Dictionary:
	_stroke = false
	var rec := _before
	_before = {}
	return rec


## Откатить мазок по записи end_stroke
func restore(rec: Dictionary) -> void:
	var keys: Array = []
	for key: Vector2i in rec:
		var old: PackedByteArray = rec[key]
		if old.is_empty():
			_chunks.erase(key)
		else:
			_chunks[key] = old.duplicate()
		keys.append(key)
	if not keys.is_empty():
		changed.emit(keys)


## Штамп кисти: центр в мире (x, z), radius в ю, hardness 0..1, cls GRASS, ROCK, GRAVEL или ERASE, strength 0..1.
## mask: Callable(Vector2 центр ячейки) -> bool, где можно красить (нет Callable: везде). Возвращает число изменённых ячеек
func stamp(center: Vector2, radius: float, hardness: float, cls: int, strength: float = 1.0, mask: Callable = Callable()) -> int:
	if cell <= 0.0 or radius <= 0.0 or strength <= 0.0:
		return 0
	if cls != ERASE and (cls < 0 or cls >= CHANNELS):
		return 0
	var i0 := floori((center.x - radius) / cell)
	var i1 := floori((center.x + radius) / cell)
	var j0 := floori((center.y - radius) / cell)
	var j1 := floori((center.y + radius) / cell)
	var touched := 0
	var keys := {}
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var p := Vector2((float(i) + 0.5) * cell, (float(j) + 0.5) * cell)
			var a := falloff(p.distance_to(center), radius, hardness) * strength
			if a <= 0.0:
				continue
			if mask.is_valid() and not bool(mask.call(p)):
				continue
			if _blend(i, j, cls, a):
				touched += 1
				keys[chunk_of(i, j)] = true
	if touched > 0:
		changed.emit(keys.keys())
	return touched


func _blend(i: int, j: int, cls: int, a: float) -> bool:
	var key := chunk_of(i, j)
	var data: PackedByteArray
	if _chunks.has(key):
		data = _chunks[key]
	else:
		if cls == ERASE:
			return false
		data = PackedByteArray()
		data.resize(CHUNK_BYTES)
	var o := _offset(i, j, key)
	var nv := PackedInt32Array([0, 0, 0, 0])
	var diff := false
	for ch in CHANNELS:
		var old := int(data[o + ch])
		var target := 255 if ch == cls else 0
		var v := old + roundi(float(target - old) * a)
		if ch == cls:
			if v > 255 - SNAP:
				v = 255
		elif v < SNAP:
			v = 0
		nv[ch] = v
		if v != old:
			diff = true
	if not diff:
		return false
	if _stroke and not _before.has(key):
		_before[key] = _chunks[key].duplicate() if _chunks.has(key) else PackedByteArray()
	for ch in CHANNELS:
		data[o + ch] = nv[ch]
	_chunks[key] = data
	return true


## K3c. Убрать краску там, где нет бинта: own (w x d, ячейка (0, 0) это ячейка (i0, j0) карты) меньше 0 или ячейка вне поля.
## Краска живёт на гипсе: снят бинт или удалён лист, и краски под ним не остаётся (иначе она всплывала бы при новом бинте).
## Возвращает число обнулённых ячеек. Мазок и его отмену это не затрагивает: чистка идёт при пересборке оболочки
func prune_unowned(i0: int, j0: int, w: int, d: int, own: PackedInt32Array) -> int:
	var cleared := 0
	var keys: Array = []
	var gone: Array = []
	for key: Vector2i in _chunks:
		var data: PackedByteArray = _chunks[key]
		var gx0 := key.x * CHUNK
		var gz0 := key.y * CHUNK
		var touched := false
		var kept := false
		for cj in CHUNK:
			var gj := gz0 + cj - j0
			for ci in CHUNK:
				var o := (cj * CHUNK + ci) * CHANNELS
				if (data[o] | data[o + 1] | data[o + 2] | data[o + 3]) == 0:
					continue
				var gi := gx0 + ci - i0
				if gi >= 0 and gi < w and gj >= 0 and gj < d and own[gj * w + gi] >= 0:
					kept = true
					continue
				data[o] = 0
				data[o + 1] = 0
				data[o + 2] = 0
				data[o + 3] = 0
				cleared += 1
				touched = true
		if touched:
			keys.append(key)
			if kept:
				_chunks[key] = data
			else:
				gone.append(key)
	for key: Vector2i in gone:
		_chunks.erase(key)
	if _chunks.is_empty():
		cell = 0.0
	if not keys.is_empty():
		changed.emit(keys)
	return cleared


## Убрать всю краску (новый макет, загрузка)
func clear() -> void:
	var keys := _chunks.keys()
	_chunks = {}
	_before = {}
	_stroke = false
	cell = 0.0
	if not keys.is_empty():
		changed.emit(keys)


## --- Сейв ---

## {"v", "cell", "chunks": [[cx, cz, сжатые байты], ...]}. Чанки без краски не пишутся
func save_data() -> Dictionary:
	var list: Array = []
	for key: Vector2i in _chunks:
		var data: PackedByteArray = _chunks[key]
		var any := false
		for b in data:
			if b != 0:
				any = true
				break
		if any:
			list.append([key.x, key.y, data.compress(FileAccess.COMPRESSION_DEFLATE)])
	if list.is_empty():
		return {}
	return {"v": FORMAT, "cell": cell, "chunks": list}


## Загрузить из save_data. Пустой словарь (сейв до кистей) очищает карту
func load_data(d: Dictionary) -> void:
	clear()
	if d.is_empty():
		return
	cell = float(d.get("cell", 0.0))
	var keys: Array = []
	for item in d.get("chunks", []):
		var arr: Array = item
		if arr.size() < 3:
			continue
		var data := (arr[2] as PackedByteArray).decompress(CHUNK_BYTES, FileAccess.COMPRESSION_DEFLATE)
		if data.size() != CHUNK_BYTES:
			continue
		var key := Vector2i(int(arr[0]), int(arr[1]))
		_chunks[key] = data
		keys.append(key)
	if _chunks.is_empty():
		cell = 0.0
	elif not keys.is_empty():
		changed.emit(keys)
