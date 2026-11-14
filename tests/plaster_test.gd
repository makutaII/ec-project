extends Node

# XX claude-terra 13.5 G1 (новый файл)
## Тест ядра гипсового бинта: PlasterField (пандус, предел подъёма, закрепление, размытие, нормаль).
## Сцены и TGM не нужно. Запуск: tests/plaster_test.tscn, F6, строки PASS / FAIL в Output.

var _fails := 0


func check(name: String, ok: bool, info := "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", info)


func near(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps


## Поле w x d, слева (x < edge) высота lo, справа hi. Ячейка 0,5 ю
func step_field(w: int, d: int, edge: int, lo: float, hi: float) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(w * d)
	for j in d:
		for i in w:
			h[j * w + i] = lo if i < edge else hi
	return h


func filled(n: int, v: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a


func _ready() -> void:
	var w := 40
	var d := 5
	var c := 0.5
	var T := 1.0
	var h := step_field(w, d, 20, 4.0, 5.0)   # низкая ступень 4 слева, высокая 5 справа, край на ячейке 20
	var run := filled(w * d, 2.0)             # 2 ю на слой
	var f := filled(w * d, 1.0)
	var s := PlasterField.smooth(h, run, f, w, d, c, T, 1.0)
	var mid := 2 * w
	check("smooth: оболочка не ниже ступеней", _min_diff(s, h) >= -0.0001, str(_min_diff(s, h)))
	check("smooth: у края низкой стороны подъём почти на слой", s[mid + 19] > 4.7, str(s[mid + 19]))
	check("smooth: пандус спадает вниз по ходу от края", s[mid + 17] < s[mid + 18] and s[mid + 18] < s[mid + 19], "%f %f %f" % [s[mid + 17], s[mid + 18], s[mid + 19]])
	check("smooth: уклон 1 слой на 2 ю = 0,25 на ячейку", near(s[mid + 19] - s[mid + 18], 0.25, 0.02), str(s[mid + 19] - s[mid + 18]))
	check("smooth: пандус кончается за 2 ю (4 ячейки) от края", near(s[mid + 16], 4.0, 0.001) and s[mid + 17] > 4.0, "%f %f" % [s[mid + 16], s[mid + 17]])
	check("smooth: высокая ступень не тронута", near(s[mid + 25], 5.0, 0.0001) and near(s[mid + 20], 5.0, 0.0001))
	check("smooth: далеко от края низкая ступень не тронута", near(s[mid + 3], 4.0, 0.0001))

	# обрыв выше слоя: пандус только на один слой у подошвы
	var hc := step_field(w, d, 20, 0.0, 5.0)
	var sc := PlasterField.smooth(hc, run, f, w, d, c, T, 1.0)
	check("smooth: обрыв 5 слоёв, у подошвы не выше слоя", sc[mid + 19] <= 1.0001 and sc[mid + 19] > 0.7, str(sc[mid + 19]))
	check("smooth: обрыв 5 слоёв, дальше от края оболочка спадает до земли", near(sc[mid + 10], 0.0, 0.001), str(sc[mid + 10]))

	# run = 0: не сглаживается
	var s0 := PlasterField.smooth(h, filled(w * d, 0.0), f, w, d, c, T, 1.0)
	check("smooth: run 0 даёт ступени без изменений", _min_diff(s0, h) == 0.0 and _max_diff(s0, h) == 0.0)

	# крутой пандус (run 1) и пологий (run 4)
	var s1 := PlasterField.smooth(h, filled(w * d, 1.0), f, w, d, c, T, 1.0)
	var s4 := PlasterField.smooth(h, filled(w * d, 4.0), f, w, d, c, T, 1.0)
	check("smooth: run 1 круче run 4 (меньше длина пандуса)", s1[mid + 16] < s4[mid + 16], "%f %f" % [s1[mid + 16], s4[mid + 16]])
	check("smooth: run 4 тянется на 4 ю (8 ячеек)", s4[mid + 13] > 4.0 and near(s4[mid + 12], 4.0, 0.001), "%f %f" % [s4[mid + 13], s4[mid + 12]])

	# закрепление: f = 0 на куске
	var fp := filled(w * d, 1.0)
	for j in d:
		for i in range(14, 20):
			fp[j * w + i] = 0.0
	var sp := PlasterField.smooth(h, run, fp, w, d, c, T, 1.0)
	check("pin: закреплённые ячейки равны ступеням", near(sp[mid + 17], 4.0, 0.0001) and near(sp[mid + 19], 4.0, 0.0001))
	check("pin: вне закреплённых оболочка прежняя", near(sp[mid + 13], s[mid + 13], 0.0001))

	# маска закрепления
	var pin := PackedByteArray()
	pin.resize(w * d)
	for j in d:
		for i in range(10, 20):
			pin[j * w + i] = 1
	var pf := PlasterField.pin_factor(pin, w, d, 2)
	check("pin_factor: внутри 0", near(pf[mid + 15], 0.0, 0.0001), str(pf[mid + 15]))
	check("pin_factor: вдали 1", near(pf[mid + 35], 1.0, 0.0001), str(pf[mid + 35]))
	check("pin_factor: на краю между 0 и 1, монотонно", pf[mid + 20] > pf[mid + 19] and pf[mid + 22] >= pf[mid + 20] and pf[mid + 20] < 1.0 + 0.0001)

	# размытие сохраняет сумму в середине плоского поля
	var flat := filled(w * d, 3.0)
	var bl := PlasterField.box_blur(flat, w, d, 2)
	check("box_blur: плоское поле не меняется", near(bl[mid + 10], 3.0, 0.0001) and near(bl[0], 3.0, 0.0001))

	# нормаль
	var nz := PlasterField.normal(flat, w, d, 10, 2, c)
	check("normal: плоскость смотрит вверх", near(nz.y, 1.0, 0.0001) and near(nz.x, 0.0, 0.0001))
	var nr := PlasterField.normal(s, w, d, 18, 2, c)
	check("normal: на пандусе наклонена к низкой стороне (-X), нормаль.y меньше 1", nr.x < 0.0 and nr.y < 1.0 and nr.y > 0.5, str(nr))

	# XX claude-terra 13.13 K0b: быстрые циклы дают тот же результат, что прежние (опорные копии _ref_* ниже)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var same_smooth := 0.0
	var same_blur := 0.0
	var same_pin := 0.0
	for sz: Vector2i in [Vector2i(37, 29), Vector2i(3, 2), Vector2i(16, 16), Vector2i(40, 5), Vector2i(1, 1)]:
		var tw := sz.x
		var td := sz.y
		var th := PackedFloat32Array()
		var tr := PackedFloat32Array()
		var tf := PackedFloat32Array()
		var tp := PackedByteArray()
		for _k in tw * td:
			th.append(float(rng.randi_range(0, 4)))
			tr.append(float(rng.randi_range(0, 4)))
			tf.append(float(rng.randi_range(0, 2)) * 0.5)
			tp.append(1 if rng.randf() < 0.12 else 0)
		same_smooth = maxf(same_smooth, _max_abs_diff(PlasterField.smooth(th, tr, tf, tw, td, c, T, 1.0), _ref_smooth(th, tr, tf, tw, td, c, T, 1.0)))
		for r in [1, 2, 3]:
			same_blur = maxf(same_blur, _max_abs_diff(PlasterField.box_blur(tf, tw, td, r), _ref_blur(tf, tw, td, r)))
			same_pin = maxf(same_pin, _max_abs_diff(PlasterField.pin_factor(tp, tw, td, r), _ref_pin_factor(tp, tw, td, r)))
	check("K0b smooth: совпадает с прежним расчётом", same_smooth == 0.0, str(same_smooth))
	check("K0b box_blur: совпадает с прежним расчётом", same_blur < 0.00001, str(same_blur))
	check("K0b pin_factor: совпадает с прежним расчётом", same_pin < 0.00001, str(same_pin))
	var no_pin := PlasterField.pin_factor(PackedByteArray([0, 0, 0, 0, 0, 0]), 3, 2, 2)
	check("K0b pin_factor: без закреплений везде 1.0", no_pin.size() == 6 and _min_diff(no_pin, filled(6, 1.0)) == 0.0 and _max_diff(no_pin, filled(6, 1.0)) == 0.0)

	# XX claude-terra 13.13 K3: подъём оболочки в крашеных ячейках плоского верха
	var lh := filled(6, 2.0)
	var lsk := filled(6, 2.0)
	lsk[5] = 2.5   # уже поднята пандусом
	var lown := PackedInt32Array([0, 0, -1, 0, 0, 0])
	var lf := filled(6, 1.0)
	lf[3] = 0.5    # у трака
	var lmark := PackedByteArray([1, 0, 1, 1, 1, 1])
	var lout := PlasterField.lift_marked(lsk, lh, lown, lf, lmark, 0.025, PlasterField.MIN_RAISE)
	check("K3 lift: крашеная ячейка поднята", near(lout[0], 2.025, 0.0001))
	check("K3 lift: без краски не тронута", lout[1] == 2.0)
	check("K3 lift: вне бинта не тронута", lout[2] == 2.0)
	check("K3 lift: у трака не тронута", lout[3] == 2.0)
	check("K3 lift: у трака на полном закреплении тоже", lout[3] == 2.0)
	check("K3 lift: пандус не понижен", lout[5] == 2.5)
	check("K3 lift: исходный массив не изменён", lsk[0] == 2.0)
	check("K3 lift: выше порога меша", lout[0] - lh[0] > PlasterField.MIN_RAISE)

	# XX claude-terra 13.13 K4: рельеф класса краски
	var kn := 6
	var kT := 0.8
	var kup := PackedFloat32Array()
	kup.resize(kn * kn)
	kup.fill(1.0)
	var kh := filled(kn * kn, 0.0)
	for kk in kn * kn:
		if kk % kn >= 3:
			kh[kk] = kT
	var kf := filled(kn * kn, 1.0)
	var krun := filled(kn * kn, 2.0)
	var kold := PlasterField.smooth(kh, krun, kf, kn, kn, 0.5, kT, kT)
	var knew := PlasterField.smooth(kh, krun, kf, kn, kn, 0.5, kT, kT, filled(kn * kn, kT))
	check("K4 smooth: подъём по ячейкам = скалярному, если везде одинаков", _max_abs_diff(kold, knew) == 0.0)
	# XX claude-terra 13.13 K3b: lip убирает долю первого шага у края ступени
	var kfoot := 2 * kn + 2
	var kl0 := PlasterField.smooth(kh, krun, kf, kn, kn, 0.5, kT, kT, PackedFloat32Array(), 0.0)
	var kl5 := PlasterField.smooth(kh, krun, kf, kn, kn, 0.5, kT, kT, PackedFloat32Array(), 0.5)
	var kl1 := PlasterField.smooth(kh, krun, kf, kn, kn, 0.5, kT, kT, PackedFloat32Array(), 1.0)
	check("K3b lip 0: как раньше", _max_abs_diff(kl0, kold) == 0.0)
	check("K3b lip 0: у среза шаг 0,2", near(kl0[kfoot], kT - 0.2, 0.0001), str(kl0[kfoot]))
	check("K3b lip 0,5: у среза шаг 0,1", near(kl5[kfoot], kT - 0.1, 0.0001), str(kl5[kfoot]))
	check("K3b lip 1: у среза вровень с верхом", near(kl1[kfoot], kT, 0.0001), str(kl1[kfoot]))
	var lip_ok := true
	for kk in kn * kn:
		if kl1[kk] < kl0[kk] - 0.0001 or kl1[kk] > maxf(kh[kk], kT) + 0.0001 or kl1[kk] < kh[kk]:
			lip_ok = false
	check("K3b lip: оболочка не ниже ступеней и не выше верха", lip_ok)
	check("K3b lip: верх ступени не тронут", near(kl1[2 * kn + 4], kT, 0.0001))
	var knone := PlasterField.smooth(kh, krun, kf, kn, kn, 0.5, kT, kT, filled(kn * kn, 0.0))
	check("K4 smooth: подъём 0 даёт оболочку по ступеням (обрыв остаётся)", _max_abs_diff(knone, kh) == 0.0)
	check("K4 smooth: при подъёме выше нуля пандус есть", _max_abs_diff(kold, kh) > 0.1)

	var kwt := PackedByteArray()
	kwt.resize(kn * kn * 4)
	var krn := filled(kn * kn, 2.0)
	krn[0] = 0.0
	var cf0 := PlasterField.class_fields(kwt, krn, kT, 1.0)
	check("K4 классы: без краски ничего не меняется", _max_abs_diff(cf0["run"], krn) == 0.0 and near(float(cf0["up"][5]), kT, 0.0001))
	kwt[4 * 1] = 255   # ячейка 1: трава
	kwt[4 * 2 + 1] = 255   # ячейка 2: скала
	kwt[4 * 3 + 2] = 255   # ячейка 3: гравий
	kwt[4 * 4] = 128   # ячейка 4: трава 50% + скала 50%
	kwt[4 * 4 + 1] = 127
	kwt[0 + 1] = 255   # ячейка 0: скала, но run = 0 (нет пандуса)
	var cf := PlasterField.class_fields(kwt, krn, kT, 1.0)
	var cup: PackedFloat32Array = cf["up"]
	var crun: PackedFloat32Array = cf["run"]
	check("K4 классы: трава как в настройке", near(cup[1], kT, 0.0001) and crun[1] == 2.0)
	check("K4 классы: скала без подошвы", cup[2] == 0.0 and crun[2] == 2.0)
	check("K4 классы: гравий 2 слоя под 35 градусов", near(cup[3], 2.0 * kT, 0.0001) and near(crun[3], kT / tan(deg_to_rad(35.0)), 0.0001))
	check("K4 классы: смесь травы и скалы даёт середину", near(cup[4], 0.5 * kT, 0.01), str(cup[4]))
	check("K4 классы: ячейка без пандуса не меняется", crun[0] == 0.0 and near(cup[0], kT, 0.0001))
	check("K4 классы: пустая ячейка без краски как была", crun[5] == 2.0 and near(cup[5], kT, 0.0001))
	var kmask := PlasterField.mask_of(kwt)
	var kmask_ok := kmask.size() == kn * kn
	for kk in kn * kn:
		if kmask[kk] != (1 if kk <= 4 else 0):
			kmask_ok = false
	check("K4 маска по весам", kmask_ok)

	# мелкий рельеф
	var rw := 12
	var rn := rw * rw
	var rsk := filled(rn, 1.0)
	var rown := PackedInt32Array()
	rown.resize(rn)
	rown.fill(0)
	var rf := filled(rn, 1.0)
	var rwt := PackedByteArray()
	rwt.resize(rn * 4)
	for kk in rn:
		rwt[kk * 4 + 1] = 255   # везде скала
	var r1 := PlasterField.add_relief(rsk, rown, rf, rwt, -5, 7, rw, kT, 1.0)
	var r2 := PlasterField.add_relief(rsk, rown, rf, rwt, -5, 7, rw, kT, 1.0)
	check("K4 рельеф: детерминирован", _max_abs_diff(r1, r2) == 0.0)
	var only_up := true
	var any_up := false
	for kk in rn:
		if r1[kk] < rsk[kk]:
			only_up = false
		if r1[kk] > rsk[kk] + 0.01:
			any_up = true
	check("K4 рельеф: только вверх и не пустой", only_up and any_up)
	check("K4 рельеф: масштаб 0 выключает", _max_abs_diff(PlasterField.add_relief(rsk, rown, rf, rwt, -5, 7, rw, kT, 0.0), rsk) == 0.0)
	var shift := PlasterField.add_relief(rsk, rown, rf, rwt, -4, 7, rw, kT, 1.0)   # поле сдвинуто на одну ячейку
	check("K4 рельеф: сдвиг поля сдвигает рельеф вместе с миром", near(shift[3 * rw + 3], r1[3 * rw + 4], 0.0001))
	var rf0 := filled(rn, 0.0)
	check("K4 рельеф: под траком (f = 0) нет", _max_abs_diff(PlasterField.add_relief(rsk, rown, rf0, rwt, -5, 7, rw, kT, 1.0), rsk) == 0.0)
	var rown_n := PackedInt32Array()
	rown_n.resize(rn)
	rown_n.fill(-1)
	check("K4 рельеф: вне бинта нет", _max_abs_diff(PlasterField.add_relief(rsk, rown_n, rf, rwt, -5, 7, rw, kT, 1.0), rsk) == 0.0)
	var rwt_g := PackedByteArray()
	rwt_g.resize(rn * 4)
	var rwt_r := PackedByteArray()
	rwt_r.resize(rn * 4)
	for kk in rn:
		rwt_g[kk * 4] = 255
		rwt_r[kk * 4 + 1] = 255
	var sum_g := 0.0
	var sum_r := 0.0
	var rg := PlasterField.add_relief(rsk, rown, rf, rwt_g, 0, 0, rw, kT, 1.0)
	var rr := PlasterField.add_relief(rsk, rown, rf, rwt_r, 0, 0, rw, kT, 1.0)
	for kk in rn:
		sum_g += rg[kk] - 1.0
		sum_r += rr[kk] - 1.0
	check("K4 рельеф: у скалы крупнее, чем у травы", sum_r > sum_g * 1.5, "%.2f против %.2f" % [sum_r, sum_g])
	var nz_ok := true
	for ci in 3:
		for gi in range(-40, 40):
			var nv := PlasterField.relief_noise(gi, -gi * 3, ci)
			if nv < 0.0 or nv > 1.0:
				nz_ok = false
	check("K4 шум: 0..1 при отрицательных индексах", nz_ok)

	print("ИТОГО: ", "всё PASS" if _fails == 0 else "FAIL: %d" % _fails)


func _min_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := INF
	for i in a.size():
		m = minf(m, a[i] - b[i])
	return m


func _max_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var m := -INF
	for i in a.size():
		m = maxf(m, a[i] - b[i])
	return m


func _max_abs_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var m := 0.0
	for i in a.size():
		m = maxf(m, absf(a[i] - b[i]))
	return m


# --- опорные копии прежнего кода PlasterField (до K0b), только для сравнения ---

func _ref_smooth(h: PackedFloat32Array, run: PackedFloat32Array, f: PackedFloat32Array, w: int, d: int,
		cell: float, T: float, max_up: float) -> PackedFloat32Array:
	var s := h.duplicate()
	for _i in 2:
		_ref_sweep(s, h, run, w, d, cell, T, max_up, true)
		_ref_sweep(s, h, run, w, d, cell, T, max_up, false)
	var out := PackedFloat32Array()
	out.resize(w * d)
	for i in w * d:
		out[i] = h[i] + (s[i] - h[i]) * f[i]
	return out


func _ref_sweep(s: PackedFloat32Array, h: PackedFloat32Array, run: PackedFloat32Array, w: int, d: int,
		cell: float, T: float, max_up: float, forward: bool) -> void:
	var dirs: Array[Vector3i]
	if forward:
		dirs = [Vector3i(-1, 0, 0), Vector3i(-1, -1, 1), Vector3i(0, -1, 0), Vector3i(1, -1, 1)]
	else:
		dirs = [Vector3i(1, 0, 0), Vector3i(1, 1, 1), Vector3i(0, 1, 0), Vector3i(-1, 1, 1)]
	var j0 := 0 if forward else d - 1
	var j1 := d if forward else -1
	var dj := 1 if forward else -1
	var i0 := 0 if forward else w - 1
	var i1 := w if forward else -1
	var di := 1 if forward else -1
	var j := j0
	while j != j1:
		var i := i0
		while i != i1:
			var idx := j * w + i
			var r := run[idx]
			if r > 0.0:
				var drop := T / r * cell
				var best := s[idx]
				for dir in dirs:
					var nx := i + dir.x
					var nz := j + dir.y
					if nx < 0 or nx >= w or nz < 0 or nz >= d:
						continue
					var cand := s[nz * w + nx] - drop * (PlasterField.DIAG if dir.z == 1 else 1.0)
					if cand > best:
						best = cand
				s[idx] = minf(best, h[idx] + max_up)
			i += di
		j += dj


func _ref_blur(a: PackedFloat32Array, w: int, d: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(w * d)
	var n := float(2 * r + 1)
	for j in d:
		for i in w:
			var sum := 0.0
			for k in range(-r, r + 1):
				sum += a[j * w + clampi(i + k, 0, w - 1)]
			tmp[j * w + i] = sum / n
	var out := PackedFloat32Array()
	out.resize(w * d)
	for j in d:
		for i in w:
			var sum := 0.0
			for k in range(-r, r + 1):
				sum += tmp[clampi(j + k, 0, d - 1) * w + i]
			out[j * w + i] = sum / n
	return out


func _ref_pin_factor(pin: PackedByteArray, w: int, d: int, r: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(w * d)
	for i in w * d:
		a[i] = float(pin[i])
	if r > 0:
		a = _ref_blur(a, w, d, r)
		a = _ref_blur(a, w, d, r)
	for i in w * d:
		a[i] = 1.0 - clampf(a[i] * 2.0, 0.0, 1.0)
	return a
