extends Node

# XX claude-terra 13.13 K1 (новый файл)
## Тест данных кисти: PaintMap (штамп, спад, маска, стирание, сумма весов, отмена мазка, сейв).
## Сцены и TGM не нужно. Запуск: tests/paint_map_test.tscn, F6, строки PASS / FAIL в Output.

var _fails := 0
var _signals := 0
var _last_keys: Array = []


func check(name: String, ok: bool, info := "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", info)


func _on_changed(keys: Array) -> void:
	_signals += 1
	_last_keys = keys


func _sum(w: Color) -> float:
	return w.r + w.g + w.b + w.a


func _fresh() -> PaintMap:
	var m := PaintMap.new()
	m.ensure_cell(0.5)
	m.changed.connect(_on_changed)
	return m


func _ready() -> void:
	# спад кисти
	check("falloff: центр 1", is_equal_approx(PaintMap.falloff(0.0, 4.0, 0.5), 1.0))
	check("falloff: внутри жёсткой части 1", is_equal_approx(PaintMap.falloff(2.0, 4.0, 0.5), 1.0))
	check("falloff: на радиусе 0", PaintMap.falloff(4.0, 4.0, 0.5) == 0.0)
	check("falloff: середина спада 0.5", absf(PaintMap.falloff(3.0, 4.0, 0.5) - 0.5) < 0.001)
	check("falloff: жёсткость 1 без спада", PaintMap.falloff(3.99, 4.0, 1.0) == 1.0)
	check("falloff: радиус 0", PaintMap.falloff(0.0, 0.0, 0.5) == 0.0)

	# ячейка и чанки
	var m := PaintMap.new()
	m.ensure_cell(0.5)
	check("ensure_cell: пустая карта берёт размер", m.cell == 0.5)
	check("chunk_of: отрицательные индексы", PaintMap.chunk_of(-1, 0) == Vector2i(-1, 0) and PaintMap.chunk_of(-16, -17) == Vector2i(-1, -2) and PaintMap.chunk_of(16, 15) == Vector2i(1, 0))
	check("stamp без размера ячейки ничего не делает", PaintMap.new().stamp(Vector2.ZERO, 2.0, 0.5, PaintMap.GRASS) == 0)

	# покраска
	m = _fresh()
	var n := m.stamp(Vector2(0.25, 0.25), 2.0, 1.0, PaintMap.GRASS, 1.0)
	check("stamp: ячейки закрашены", n > 0, str(n))
	var w := m.weights(0, 0)
	check("stamp: центр полной травой", is_equal_approx(w.r, 1.0) and w.g == 0.0 and w.b == 0.0, str(w))
	check("stamp: вне радиуса пусто", _sum(m.weights(20, 20)) == 0.0)
	check("stamp: сигнал и ключ чанка", _signals == 1 and _last_keys.has(Vector2i(0, 0)) and _last_keys.has(Vector2i(-1, -1)), str(_last_keys))
	check("dominant: трава", m.dominant(0, 0) == PaintMap.GRASS)
	check("dominant: нет краски", m.dominant(30, 30) == -1)

	# смена класса: сумма не больше 255
	m.stamp(Vector2(0.25, 0.25), 2.0, 1.0, PaintMap.ROCK, 0.5)
	w = m.weights(0, 0)
	check("смена класса: смесь травы и скалы", w.r > 0.3 and w.g > 0.3, str(w))
	check("смена класса: сумма не больше 1", _sum(w) <= 1.001, str(_sum(w)))
	for k in 6:
		m.stamp(Vector2(0.25, 0.25), 2.0, 1.0, PaintMap.GRAVEL, 0.7)
	w = m.weights(0, 0)
	check("повторные мазки: гравий полностью, хвостов нет", w.b == 1.0 and w.r == 0.0 and w.g == 0.0, str(w))

	# мягкий край и накопление
	m = _fresh()
	for k in 8:
		m.stamp(Vector2.ZERO, 3.0, 0.3, PaintMap.GRASS, 0.5)
	check("накопление: центр полный", m.weights(0, 0).r == 1.0 or m.weights(-1, -1).r == 1.0)
	var edge := 0.0
	for i in range(5, 7):
		edge = maxf(edge, m.weights(i, 0).r)
	check("мягкий край: у границы слабее центра", edge < 1.0)

	# маска
	m = _fresh()
	var mask := func(p: Vector2) -> bool: return p.x > 0.0
	m.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.ROCK, 1.0, mask)
	check("маска: левая половина пуста", _sum(m.weights(-2, 0)) == 0.0)
	check("маска: правая половина закрашена", m.weights(2, 0).g == 1.0)

	# стирание
	m = _fresh()
	m.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.GRASS, 1.0)
	m.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.ERASE, 0.5)
	w = m.weights(1, 1)
	check("стирание: ослабляет краску", w.r > 0.3 and w.r < 0.7, str(w))
	for k in 12:
		m.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.ERASE, 0.5)
	check("стирание: до нуля без хвостов", _sum(m.weights(1, 1)) == 0.0, str(m.weights(1, 1)))
	var e := PaintMap.new()
	e.ensure_cell(0.5)
	check("стирание на пустой карте не создаёт чанков", e.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.ERASE) == 0 and e.is_empty())
	check("неизвестный класс", m.stamp(Vector2.ZERO, 3.0, 1.0, 9) == 0)

	# отмена мазка
	m = _fresh()
	m.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.GRASS, 1.0)
	var before := m.save_data()
	m.begin_stroke()
	m.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.ROCK, 1.0)
	m.stamp(Vector2(20, 20), 3.0, 1.0, PaintMap.GRAVEL, 1.0)   # новый чанк
	var rec := m.end_stroke()
	check("мазок: запись не пуста, два чанка и больше", rec.size() >= 2, str(rec.size()))
	check("мазок: краска сменилась", m.weights(0, 0).g == 1.0 and m.weights(40, 40).b == 1.0)
	m.restore(rec)
	check("отмена: прежняя трава", m.weights(0, 0).r == 1.0 and m.weights(0, 0).g == 0.0)
	check("отмена: новый чанк исчез", _sum(m.weights(40, 40)) == 0.0)
	check("отмена: данные как до мазка", m.save_data() == before)
	m.begin_stroke()
	check("пустой мазок: запись пуста", m.end_stroke().is_empty())

	# сейв
	m = _fresh()
	m.stamp(Vector2(1.0, 2.0), 3.0, 0.5, PaintMap.GRASS, 1.0)
	m.stamp(Vector2(-9.0, -7.0), 2.0, 1.0, PaintMap.ROCK, 1.0)
	m.stamp(Vector2(-9.0, -7.0), 1.0, 1.0, PaintMap.ERASE, 1.0)   # чанк с остатком
	var d := m.save_data()
	check("save: версия и ячейка", int(d.get("v", 0)) == PaintMap.FORMAT and is_equal_approx(float(d["cell"]), 0.5))
	var m2 := PaintMap.new()
	m2.load_data(d)
	var same := m2.cell == m.cell
	for key in m.chunk_keys():
		for j in PaintMap.CHUNK:
			for i in PaintMap.CHUNK:
				if m.weights(key.x * 16 + i, key.y * 16 + j) != m2.weights(key.x * 16 + i, key.y * 16 + j):
					same = false
	check("save/load: все веса совпали", same)
	var empty := PaintMap.new()
	empty.ensure_cell(0.5)
	check("save: пустая карта даёт пустой словарь", empty.save_data().is_empty())
	var blank := _fresh()
	blank.stamp(Vector2.ZERO, 2.0, 1.0, PaintMap.GRASS, 1.0)
	blank.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.ERASE, 1.0)
	check("save: стёртая краска не пишется", blank.save_data().is_empty())
	m2.load_data({})
	check("load пустого очищает карту", m2.is_empty() and m2.cell == 0.0)
	var bad := {"v": 1, "cell": 0.5, "chunks": [[1]]}
	m2.load_data(bad)
	check("load: короткая запись чанка пропущена", m2.is_empty())

	# K3: сырые байты чанка и маска крашеных ячеек
	m = _fresh()
	m.stamp(Vector2(0.25, 0.25), 1.0, 1.0, PaintMap.ROCK, 1.0)
	var raw := m.chunk_bytes(Vector2i(0, 0))
	check("chunk_bytes: размер чанка", raw.size() == PaintMap.CHUNK_BYTES)
	check("chunk_bytes: нет чанка, пусто", m.chunk_bytes(Vector2i(5, 5)).is_empty())
	check("chunk_bytes: канал скалы у ячейки (0, 0)", raw[PaintMap.ROCK] == 255 and raw[PaintMap.GRASS] == 0)
	var mk := m.painted_mask(-2, -2, 6, 6)   # окно, ячейка (0, 0) карты это (2, 2) маски
	check("painted_mask: размер окна", mk.size() == 36)
	check("painted_mask: крашеная ячейка", mk[2 * 6 + 2] == 1)
	check("painted_mask: ячейка вне мазка пуста", mk[5 * 6 + 5] == 0)
	var far := m.painted_mask(100, 100, 4, 4)
	check("painted_mask: окно вне краски пусто", not far.has(1))
	var cnt := 0
	for v in m.painted_mask(-20, -20, 40, 40):
		cnt += v
	var expect := 0
	for j in range(-6, 7):
		for i in range(-6, 7):
			if Vector2((float(i) + 0.5) * 0.5, (float(j) + 0.5) * 0.5).distance_to(Vector2(0.25, 0.25)) < 1.0:
				expect += 1
	check("painted_mask: число ячеек равно числу ячеек в радиусе", cnt == expect and cnt > 0, "%d из %d" % [cnt, expect])

	# K3: увеличение чанка для текстуры
	var src := PackedByteArray()
	src.resize(PaintMap.CHUNK_BYTES)
	var o := (3 * PaintMap.CHUNK + 5) * PaintMap.CHANNELS   # ячейка (5, 3)
	src[o] = 10
	src[o + 1] = 20
	src[o + 2] = 30
	src[o + 3] = 40
	var px := PaintSplat.chunk_pixels(src)
	check("chunk_pixels: размер 32 x 32 x 4", px.size() == 32 * 32 * 4)
	var all4 := true
	for dj in 2:
		for di in 2:
			var p := ((3 * 2 + dj) * 32 + 5 * 2 + di) * 4
			if px[p] != 10 or px[p + 1] != 20 or px[p + 2] != 30 or px[p + 3] != 40:
				all4 = false
	check("chunk_pixels: ячейка стала четырьмя пикселями", all4)
	var other := 0
	for b in px:
		if b != 0:
			other += 1
	check("chunk_pixels: больше ничего не закрашено", other == 16, str(other))
	check("chunk_pixels: неверный размер даёт нули", not PaintSplat.chunk_pixels(PackedByteArray([1, 2, 3])).has(1))

	# K3c: краска живёт только под бинтом
	m = _fresh()
	m.stamp(Vector2(0.25, 0.25), 3.0, 1.0, PaintMap.GRASS, 1.0)   # ячейки около (0, 0), в том числе в чанках (-1, *) и (*, -1)
	m.stamp(Vector2(10.25, 10.25), 1.0, 1.0, PaintMap.GRASS, 1.0)   # далеко от поля: чанк (1, 1)
	check("prune: далёкая краска есть до чистки", not m.chunk_bytes(Vector2i(1, 1)).is_empty())
	var p_own := PackedInt32Array()
	p_own.resize(8 * 8)
	p_own.fill(-1)
	for pj in range(2, 6):
		for pi in range(2, 6):
			p_own[pj * 8 + pi] = 0   # бинт на ячейках (i, j) = (-4 + 2 .. -4 + 5) поля с началом (-4, -4): -2..1
	var p_before := m.weights(0, 0)
	var far_before := m.weights(-5, 0)   # левее поля (его первая ячейка -4)
	_signals = 0
	var p_gone := m.prune_unowned(-4, -4, 8, 8, p_own)
	check("prune: снята краска вне бинта", p_gone > 0 and _signals == 1, "%d %d" % [p_gone, _signals])
	check("prune: под бинтом краска цела", m.weights(0, 0) == p_before and p_before.r > 0.9, str(m.weights(0, 0)))
	check("prune: вне бинта нет краски", _sum(m.weights(-3, -3)) == 0.0 and _sum(m.weights(2, 2)) == 0.0, str([m.weights(-3, -3), m.weights(2, 2)]))
	check("prune: ячейка вне поля тоже снята", far_before.r > 0.0 and _sum(m.weights(-5, 0)) == 0.0, str(far_before))
	check("prune: опустевший чанк не хранится, чанк с краской остался", m.chunk_bytes(Vector2i(1, 1)).is_empty() and not m.chunk_bytes(Vector2i(0, 0)).is_empty())
	_signals = 0
	check("prune: повторно ничего не меняет", m.prune_unowned(-4, -4, 8, 8, p_own) == 0 and _signals == 0)
	var empty_own := PackedInt32Array()
	m.prune_unowned(0, 0, 0, 0, empty_own)
	check("prune: бинта нет нигде, карта пуста и ячейка сброшена", m.is_empty() and m.cell == 0.0)
	m = _fresh()
	m.stamp(Vector2(0.25, 0.25), 2.0, 1.0, PaintMap.ROCK, 1.0)
	m.begin_stroke()
	m.stamp(Vector2(0.25, 0.25), 2.0, 1.0, PaintMap.GRAVEL, 1.0)
	var p_rec := m.end_stroke()
	m.prune_unowned(0, 0, 0, 0, empty_own)
	m.restore(p_rec)
	check("prune: отмена мазка после чистки не падает", not m.is_empty())

	# clear
	m = _fresh()
	m.stamp(Vector2.ZERO, 3.0, 1.0, PaintMap.GRASS, 1.0)
	_signals = 0
	m.clear()
	check("clear: карта пуста, сигнал, ячейка сброшена", m.is_empty() and _signals == 1 and m.cell == 0.0)

	print("---- paint_map_test: ", "ВСЕ PASS" if _fails == 0 else "ПРОВАЛОВ: %d" % _fails)
