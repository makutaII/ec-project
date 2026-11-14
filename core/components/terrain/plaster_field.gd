class_name PlasterField extends RefCounted

# XX claude-terra 13.5 G1 (новый файл)
#######################
## Ядро гипсового бинта (ATTN_13 §13.5). Чистые функции над массивами высот, без сцены и узлов.
#######################
## Поле это прямоугольная сетка ячеек (w x d), индекс j * w + i. h: высота ступеней в центре ячейки (мир, Y).
## Оболочка S это верхняя огибающая ступеней: S >= h везде. Пандус идёт от верхней ступени вниз с уклоном
## «run ю на слой» (run = 0: ячейка не сглаживается). Подъём над ступенью ограничен max_up, поэтому обрыв выше
## слоя остаётся обрывом с одним слоем пандуса у подошвы. Закреплённые ячейки (ложе трака) получают S = h
## через мягкую маску: коэффициент f (0 закреплено, 1 свободно).
## Пандус считается двумя проходами «шаблона» (chamfer), каждый проход вперёд и назад, по 4 соседям.

## Подъём ниже этого считаем нулевым (оболочку не рисуем, иначе она мерцает вровень с ступенью), ю
const MIN_RAISE := 0.02
const DIAG := 1.41421356

# XX claude-terra 13.13 K4: профили классов краски (индексы как у PaintMap: трава, скала, гравий)
## Наибольший подъём у подошвы, слоёв. Трава: как в настройке (plaster_max_up), поэтому здесь -1. Скала без подошвы,
## гравий осыпью до двух слоёв
const CLASS_UP_LAYERS: Array[float] = [-1.0, 0.0, 2.0]
## Угол осыпи гравия, градусы: ширина пандуса на слой run = T / tan(угол)
const SCREE_DEG := 35.0
## Высота мелкого рельефа класса, долей слоя T (при масштабе 1)
const RELIEF_AMP: Array[float] = [0.12, 0.45, 0.10]


## Оболочка. Все массивы длиной w * d. cell: сторона ячейки (ю), T: высота слоя, max_up: наибольший подъём (ю).
## up (K4): наибольший подъём по ячейкам, ю; пустой массив = везде max_up.
## lip (0..1): доля первого шага пандуса, которую убираем у края ступени. Центр ячейки стоит в полуячейке от среза, поэтому без
## этого оболочка у верха стенки на шаг ниже среза и срез торчит над гипсом «стеклянным бортиком». 0 = как раньше, 1 = первая
## ячейка у среза вровень с верхом (оболочка и верх листа в одной плоскости, возможна рябь)
static func smooth(h: PackedFloat32Array, run: PackedFloat32Array, f: PackedFloat32Array, w: int, d: int,
		cell: float, T: float, max_up: float, up: PackedFloat32Array = PackedFloat32Array(), lip: float = 0.0) -> PackedFloat32Array:
	var s := h.duplicate()
	if up.is_empty():
		up = PackedFloat32Array()
		up.resize(w * d)
		up.fill(max_up)
	for _i in 2:
		_sweep(s, h, run, w, d, cell, T, up, true, lip)
		_sweep(s, h, run, w, d, cell, T, up, false, lip)
	var out := PackedFloat32Array()
	out.resize(w * d)
	for i in w * d:
		out[i] = h[i] + (s[i] - h[i]) * f[i]
	return out


static func _sweep(s: PackedFloat32Array, h: PackedFloat32Array, run: PackedFloat32Array, w: int, d: int,
		cell: float, T: float, up: PackedFloat32Array, forward: bool, lip: float = 0.0) -> void:
	# XX claude-terra 13.13 K0b: соседи записаны развёрнуто (без массива направлений и проверок границ на каждый шаг).
	# Порядок обхода и арифметика прежние, результат побитово тот же. Вперёд: (i-1,j) (i,j-1) и диагонали (i-1,j-1) (i+1,j-1);
	# назад: (i+1,j) (i,j+1) и диагонали (i+1,j+1) (i-1,j+1)
	var wm := w - 1
	if forward:
		for j in d:
			var row := j * w
			for i in w:
				var idx := row + i
				var r := run[idx]
				if r <= 0.0:
					continue
				var drop := T / r * cell   # падение высоты на шаг по стороне ячейки
				var drop_d := drop * DIAG
				var drop_src := drop * (1.0 - lip)   # шаг от ячейки, которая ещё не поднята (край ступени): lip убирает его долю
				var drop_d_src := drop_src * DIAG
				var best := s[idx]
				var cand := 0.0
				if i > 0:
					cand = s[idx - 1] - (drop_src if s[idx - 1] == h[idx - 1] else drop)
					if cand > best:
						best = cand
				if j > 0:
					cand = s[idx - w] - (drop_src if s[idx - w] == h[idx - w] else drop)
					if cand > best:
						best = cand
					if i > 0:
						cand = s[idx - w - 1] - (drop_d_src if s[idx - w - 1] == h[idx - w - 1] else drop_d)
						if cand > best:
							best = cand
					if i < wm:
						cand = s[idx - w + 1] - (drop_d_src if s[idx - w + 1] == h[idx - w + 1] else drop_d)
						if cand > best:
							best = cand
				s[idx] = minf(best, h[idx] + up[idx])
	else:
		var dm := d - 1
		for j in range(dm, -1, -1):
			var row := j * w
			for i in range(wm, -1, -1):
				var idx := row + i
				var r := run[idx]
				if r <= 0.0:
					continue
				var drop := T / r * cell
				var drop_d := drop * DIAG
				var drop_src := drop * (1.0 - lip)   # шаг от ячейки, которая ещё не поднята (край ступени): lip убирает его долю
				var drop_d_src := drop_src * DIAG
				var best := s[idx]
				var cand := 0.0
				if i < wm:
					cand = s[idx + 1] - (drop_src if s[idx + 1] == h[idx + 1] else drop)
					if cand > best:
						best = cand
				if j < dm:
					cand = s[idx + w] - (drop_src if s[idx + w] == h[idx + w] else drop)
					if cand > best:
						best = cand
					if i < wm:
						cand = s[idx + w + 1] - (drop_d_src if s[idx + w + 1] == h[idx + w + 1] else drop_d)
						if cand > best:
							best = cand
					if i > 0:
						cand = s[idx + w - 1] - (drop_d_src if s[idx + w - 1] == h[idx + w - 1] else drop_d)
						if cand > best:
							best = cand
				s[idx] = minf(best, h[idx] + up[idx])


## 13.13 K3. На плоском верху оболочка рисуется только в крашеных ячейках: там она поднимается над ступенью на lift
## (выше MIN_RAISE, иначе ячейка не попадёт в меш). Не трогает ячейки вне бинта (own < 0), у траков (f < 1) и уже
## поднятые пандусом. mark: 1 = ячейка крашеная (PaintMap.painted_mask). Возвращает новую высоту оболочки
static func lift_marked(sk: PackedFloat32Array, hh: PackedFloat32Array, own: PackedInt32Array, f: PackedFloat32Array,
		mark: PackedByteArray, lift: float, eps: float) -> PackedFloat32Array:
	var out := sk.duplicate()
	for k in out.size():
		if mark[k] == 1 and own[k] >= 0 and f[k] > 0.999 and out[k] - hh[k] <= eps:
			out[k] = hh[k] + lift
	return out


## Мягкая маска закрепления: pin (0/1) размывается двумя проходами по радиусу r ячеек.
## Результат: 0 внутри закреплённого, 1 вдали, между ними плавно
static func pin_factor(pin: PackedByteArray, w: int, d: int, r: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(w * d)
	if not pin.has(1):   # XX claude-terra 13.13 K0b: закреплений нет, везде свободно (1.0), размытие не нужно
		a.fill(1.0)
		return a
	for i in w * d:
		a[i] = float(pin[i])
	if r > 0:
		a = box_blur(a, w, d, r)
		a = box_blur(a, w, d, r)
	for i in w * d:
		a[i] = 1.0 - clampf(a[i] * 2.0, 0.0, 1.0)
	return a


## Размытие окном (2r + 1) по строкам и столбцам, за краем значение краевой ячейки
## (K0b: сумма окна скользит, на ячейку две выборки вместо 2r + 1, результат тот же)
static func box_blur(a: PackedFloat32Array, w: int, d: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(w * d)
	var n := float(2 * r + 1)
	for j in d:
		var row := j * w
		var sum := 0.0
		for k in range(-r, r + 1):
			sum += a[row + clampi(k, 0, w - 1)]
		tmp[row] = sum / n
		for i in range(1, w):
			sum += a[row + mini(i + r, w - 1)] - a[row + maxi(i - 1 - r, 0)]
			tmp[row + i] = sum / n
	var out := PackedFloat32Array()
	out.resize(w * d)
	for i in w:
		var sum := 0.0
		for k in range(-r, r + 1):
			sum += tmp[clampi(k, 0, d - 1) * w + i]
		out[i] = sum / n
		for j in range(1, d):
			sum += tmp[mini(j + r, d - 1) * w + i] - tmp[maxi(j - 1 - r, 0) * w + i]
			out[j * w + i] = sum / n
	return out


## Нормаль оболочки в ячейке (центральные разности, на краю односторонние)
static func normal(s: PackedFloat32Array, w: int, d: int, i: int, j: int, cell: float) -> Vector3:
	var xl := s[j * w + maxi(i - 1, 0)]
	var xr := s[j * w + mini(i + 1, w - 1)]
	var zl := s[maxi(j - 1, 0) * w + i]
	var zr := s[mini(j + 1, d - 1) * w + i]
	var dx := float(mini(i + 1, w - 1) - maxi(i - 1, 0)) * cell
	var dz := float(mini(j + 1, d - 1) - maxi(j - 1, 0)) * cell
	var gx := (xr - xl) / maxf(dx, 0.0001)
	var gz := (zr - zl) / maxf(dz, 0.0001)
	return Vector3(-gx, 1.0, -gz).normalized()


## --- 13.13 K4: рельеф класса краски ---

## Маска крашеных ячеек по весам (PaintMap.field_weights: на ячейку 4 байта)
static func mask_of(wt: PackedByteArray) -> PackedByteArray:
	var n := wt.size() >> 2
	var mark := PackedByteArray()
	mark.resize(n)
	for k in n:
		var o := k * 4
		if (wt[o] | wt[o + 1] | wt[o + 2] | wt[o + 3]) != 0:
			mark[k] = 1
	return mark


## Ширина пандуса и подъём у подошвы по ячейкам с учётом краски. wt: веса классов (4 байта на ячейку), run: ширина пандуса
## зоны, T: высота слоя, base_up_layers: plaster_max_up. В крашеной ячейке параметры берутся от смеси классов по весам
## и сходят на зону там, где краска слабеет: трава как у бинта, скала без подошвы (подъём 0, обрыв остаётся обрывом),
## гравий с осыпью до CLASS_UP_LAYERS слоёв под SCREE_DEG. Ячейки без пандуса (run <= 0) не меняются.
## Возвращает {"run": PackedFloat32Array, "up": PackedFloat32Array (ю)}
static func class_fields(wt: PackedByteArray, run: PackedFloat32Array, T: float, base_up_layers: float) -> Dictionary:
	var n := run.size()
	var run_out := run.duplicate()
	var up := PackedFloat32Array()
	up.resize(n)
	up.fill(base_up_layers * T)
	var scree_run := T / tan(deg_to_rad(SCREE_DEG))
	for k in n:
		var o := k * 4
		var sum := float(wt[o]) + float(wt[o + 1]) + float(wt[o + 2])
		if sum <= 0.0 or run[k] <= 0.0:
			continue
		var cover := minf(sum / 255.0, 1.0)
		var up_mix := 0.0
		var run_mix := 0.0
		for cls in 3:
			var q := float(wt[o + cls]) / sum
			var ul: float = CLASS_UP_LAYERS[cls]
			up_mix += q * (base_up_layers if ul < 0.0 else ul) * T
			run_mix += q * (scree_run if cls == 2 else run[k])
		up[k] = lerpf(up[k], up_mix, cover)
		run_out[k] = lerpf(run[k], run_mix, cover)
	return {"run": run_out, "up": up}


## Мелкий рельеф крашеных ячеек, только вверх (оболочка не опускается ниже прежней). i0, j0: мировые индексы ячейки (0, 0)
## поля, они задают шум, поэтому рельеф не зависит от рамки поля и не меняется между пересчётами. f: закрепление у траков
## (0 закреплено): под траком рельефа нет. scale: масштаб (0 = выключено). Возвращает новую оболочку
static func add_relief(sk: PackedFloat32Array, own: PackedInt32Array, f: PackedFloat32Array, wt: PackedByteArray,
		i0: int, j0: int, w: int, T: float, scale: float) -> PackedFloat32Array:
	if scale <= 0.0:
		return sk
	var out := sk.duplicate()
	for k in out.size():
		if own[k] < 0 or f[k] <= 0.0:
			continue
		var o := k * 4
		var sum := float(wt[o]) + float(wt[o + 1]) + float(wt[o + 2])
		if sum <= 0.0:
			continue
		@warning_ignore("integer_division")   # k / w: номер строки поля
		var gj := j0 + k / w
		var gi := i0 + k % w
		var add := 0.0
		for cls in 3:
			var wc := float(wt[o + cls]) / 255.0
			if wc > 0.0:
				add += wc * float(RELIEF_AMP[cls]) * relief_noise(gi, gj, cls)
		out[k] += add * T * scale * f[k]
	return out


## Шум рельефа класса в ячейке (gi, gj) мировых индексов, 0..1. Без состояния: одно и то же при любом пересчёте и загрузке
static func relief_noise(gi: int, gj: int, cls: int) -> float:
	match cls:
		1:   # скала: плато с гранями, крупные ступени
			var v := _value_noise(float(gi) / 3.5, float(gj) / 3.5, 2)
			return clampf(floorf(v * 4.0) / 3.0 + 0.1 * _hash01(gi, gj, 5), 0.0, 1.0)
		2:   # гравий: мелкая россыпь, почти по ячейке
			return 0.5 * _hash01(gi, gj, 3) + 0.5 * _value_noise(float(gi) / 2.0, float(gj) / 2.0, 4)
	return _value_noise(float(gi) / 6.0, float(gj) / 6.0, 1)   # трава: низкий плавный


static func _hash01(i: int, j: int, seed_n: int) -> float:
	var n := ((i * 73856093) ^ (j * 19349663) ^ (seed_n * 83492791)) & 0xFFFFFFFF
	n = (((n >> 13) ^ n) * 1274126177) & 0xFFFFFFFF   # 32 бита: без переполнения int64, результат один на всех платформах
	n = n ^ (n >> 16)
	return float(n & 0xFFFF) / 65535.0


static func _value_noise(x: float, y: float, seed_n: int) -> float:
	var ix := floori(x)
	var iy := floori(y)
	var fx := x - float(ix)
	var fy := y - float(iy)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a := lerpf(_hash01(ix, iy, seed_n), _hash01(ix + 1, iy, seed_n), fx)
	var b := lerpf(_hash01(ix, iy + 1, seed_n), _hash01(ix + 1, iy + 1, seed_n), fx)
	return lerpf(a, b, fy)
