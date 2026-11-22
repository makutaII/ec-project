extends Node

# XX claude-library (новый файл)
## Проверка: концы кисти и пресеты инструментов (ATTN_22 §22.7.2.1, шаг C2.2): текстуры PaintTips, пресеты PaintBrushes,
## направление конца (tangent), разброс, запас краски сухой кисти. Рендер не нужен.
## Запуск: открыть tests/library_paint_tips_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Library paint tips: n/m».

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_tips()
	_test_presets()
	_test_tangent()
	_test_helpers()
	print("Library paint tips: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _stats(img: Image) -> Dictionary:
	var n := img.get_width() * img.get_height()
	var sum := 0.0
	var low := 0
	var high := 0
	var cover := 0
	var vmax := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var v := img.get_pixel(x, y).r
			sum += v
			vmax = maxf(vmax, v)
			if v < 0.1:
				low += 1
			if v > 0.9:
				high += 1
			if v > 0.5:
				cover += 1
	return {"mean": sum / n, "low": float(low) / n, "high": float(high) / n, "cover": float(cover) / n, "max": vmax}


func _test_tips() -> void:
	_check("концы кисти: bristle, sponge, splatter", PaintTips.ORDER == ["bristle", "sponge", "splatter"])
	_check("пустой id и white означают «без текстуры»", PaintTips.image("") == null and PaintTips.texture("white") == null and not PaintTips.has(""))
	for id in PaintTips.ORDER:
		var img := PaintTips.image(id)
		_check("%s: картинка %dx%d, один канал" % [id, PaintTips.SIZE, PaintTips.SIZE], img != null and img.get_width() == PaintTips.SIZE and img.get_height() == PaintTips.SIZE and img.get_format() == Image.FORMAT_L8)
		_check("%s: текстура создана и повторный вызов даёт ту же" % id, PaintTips.texture(id) != null and PaintTips.texture(id) == PaintTips.texture(id))
		_check("%s: картинка одна и та же при повторном обращении (зерно фиксировано)" % id, PaintTips.image(id).get_data() == PaintTips.image(id).get_data())

	# bristle: полосы вдоль x, плотность меняется от ряда к ряду и почти постоянна внутри ряда
	var b := PaintTips.image("bristle")
	var row_means := PackedFloat32Array()
	var in_row := 0.0
	for y in b.get_height():
		var m := 0.0
		for x in b.get_width():
			m += b.get_pixel(x, y).r
		m /= b.get_width()
		row_means.append(m)
		var var_sum := 0.0
		for x in b.get_width():
			var_sum += pow(b.get_pixel(x, y).r - m, 2.0)
		in_row += sqrt(var_sum / b.get_width())
	in_row /= b.get_height()
	var avg := 0.0
	for m in row_means:
		avg += m
	avg /= row_means.size()
	var row_var := 0.0
	for m in row_means:
		row_var += pow(m - avg, 2.0)
	var row_std := sqrt(row_var / row_means.size())
	_check("bristle: ряды различаются (%.2f), внутри ряда ровно (%.3f)" % [row_std, in_row], row_std > 0.15 and in_row < 0.07)

	var sp := _stats(PaintTips.image("sponge"))
	_check("sponge: пористое пятно (среднее %.2f, пустого %.2f, плотного %.2f)" % [sp["mean"], sp["low"], sp["high"]], sp["mean"] > 0.3 and sp["mean"] < 0.75 and sp["low"] > 0.1 and sp["high"] > 0.1)
	var spl := _stats(PaintTips.image("splatter"))
	_check("splatter: россыпь точек (покрыто %.3f, максимум %.2f)" % [spl["cover"], spl["max"]], spl["cover"] > 0.02 and spl["cover"] < 0.25 and spl["max"] > 0.99)


func _test_presets() -> void:
	var all_ok := true
	var levels_ok := true
	var tips_ok := true
	for id in PaintBrushes.ORDER:
		var p := PaintBrushes.preset(id)
		for k in PaintBrushes.DEFAULTS:
			all_ok = all_ok and p.has(k)
		all_ok = all_ok and str(p["name"]) != "" and PaintBrushes.PRESETS.has(id)
		levels_ok = levels_ok and int(p["level"]) >= 2 and int(p["level"]) <= 3
		tips_ok = tips_ok and (str(p["tip"]) == "" or PaintTips.has(str(p["tip"]))) and (str(p["shape"]) == "round" or str(p["shape"]) == "box")
	_check("инструменты по порядку: кисть, аэрограф, ластик, сухая кисть, маска, декаль (концы кисти это не инструменты)", PaintBrushes.ORDER == ["brush", "airbrush", "eraser", "dry", "mask", "decal"])
	_check("концы кисти по порядку: круг, щётка, губка, брызги, квадрат", PaintBrushes.TIP_ORDER == ["round", "flat", "sponge", "splatter", "square"])
	_check("у каждого пресета есть все параметры и имя", all_ok)
	_check("уровни правил 2..3, тексты концов и форма известны", levels_ok and tips_ok)
	var tip_ok := true
	for id in PaintBrushes.TIP_ORDER:
		var t: Dictionary = PaintBrushes.TIPS[id]
		tip_ok = tip_ok and str(t["name"]) != "" and (str(t["tip"]) == "" or PaintTips.has(str(t["tip"]))) and (str(t["shape"]) == "round" or str(t["shape"]) == "box") \
			and int(t["level"]) >= 2 and int(t["level"]) <= 3 and float(t["size_mul"]) > 0.0 and float(t["spacing"]) > 0.0
	_check("концы кисти: названия, текстуры и формы известны, размер и шаг положительные", tip_ok)
	_check("кисть, аэрограф, ластик и сухая кисть выбирают конец, декаль нет", PaintBrushes.preset("brush")["tips"] == true and PaintBrushes.preset("airbrush")["tips"] == true and PaintBrushes.preset("eraser")["tips"] == true and PaintBrushes.preset("dry")["tips"] == true and PaintBrushes.preset("mask")["tips"] == true and PaintBrushes.preset("decal")["tips"] == false)
	_check("уровни: кисть, аэрограф, ластик и круг, квадрат с уровня 2; сухая кисть, декаль, щётка, губка, брызги с уровня 3", PaintBrushes.preset("brush")["level"] == 2 and PaintBrushes.preset("airbrush")["level"] == 2 and PaintBrushes.preset("eraser")["level"] == 2 and PaintBrushes.TIPS["round"]["level"] == 2 and PaintBrushes.TIPS["square"]["level"] == 2 and PaintBrushes.preset("dry")["level"] == 3 and PaintBrushes.preset("decal")["level"] == 3 and PaintBrushes.TIPS["flat"]["level"] == 3 and PaintBrushes.TIPS["sponge"]["level"] == 3 and PaintBrushes.TIPS["splatter"]["level"] == 3)
	_check("прежние инструменты не изменились (размер, жёсткость, поток)", PaintBrushes.preset("brush")["hardness"] == 0.8 and PaintBrushes.preset("airbrush")["accumulate"] == true and PaintBrushes.preset("airbrush")["flow"] == 0.12 and PaintBrushes.preset("eraser")["erase"] == true)
	_check("у новой кисти конец «круг», круг совпадает с параметрами по умолчанию", PaintBrushes.preset("brush")["end"] == "round" and PaintBrushes.preset("brush")["shape"] == PaintBrushes.TIPS["round"]["shape"] and PaintBrushes.preset("brush")["rotate"] == PaintBrushes.TIPS["round"]["rotate"] and float(PaintBrushes.preset("brush")["spacing"]) == float(PaintBrushes.TIPS["round"]["spacing"]))
	_check("сухая кисть по умолчанию красит кромки (relief 1), виды: кромки и выступы, впадины и тени", float(PaintBrushes.preset("dry")["relief"]) == 1.0 and float(PaintBrushes.preset("brush")["relief"]) == 0.0 and PaintBrushes.RELIEF_KINDS.size() == 2 and float(PaintBrushes.RELIEF_KINDS[0][0]) == 1.0 and float(PaintBrushes.RELIEF_KINDS[1][0]) == -1.0 and float(PaintBrushes.preset("dry")["relief_sens"]) > 0.0 and float(PaintBrushes.preset("dry")["relief_width"]) >= 1.0)
	_check("смывки как отдельного инструмента нет", not PaintBrushes.PRESETS.has("wash") and not PaintBrushes.PRESETS.has("flat") and not PaintBrushes.PRESETS.has("sponge") and not PaintBrushes.PRESETS.has("splatter") and not PaintBrushes.PRESETS.has("square"))
	_check("неизвестный id даёт «Кисть»", PaintBrushes.preset("nope")["name"] == "Кисть")
	var mod := PaintBrushes.preset("brush")
	mod["size"] = 0.5
	_check("правка копии не портит пресет", PaintBrushes.preset("brush")["size"] == 0.04)

	# apply_tip: щётка прямоугольная с полосами, брызги разбрасываются и крупнее, губка вращается случайно, квадрат без текстуры
	var p := PaintBrushes.preset("brush")
	PaintBrushes.apply_tip(p, "flat", 0.04)
	_check("apply_tip щётка: текстура bristle, прямоугольник 0.35 x 1, поворот по мазку, размер x1.5", p["end"] == "flat" and p["tip"] == "bristle" and p["shape"] == "box" and p["box"] == Vector2(0.35, 1.0) and p["rotate"] == "stroke" and is_equal_approx(float(p["size"]), 0.06))
	PaintBrushes.apply_tip(p, "splatter", 0.04)
	_check("apply_tip брызги: разброс, случайный поворот, размер x2.5", float(p["scatter"]) > 0.0 and p["rotate"] == "random" and p["tip"] == "splatter" and is_equal_approx(float(p["size"]), 0.1))
	PaintBrushes.apply_tip(p, "sponge", 0.04)
	_check("apply_tip губка: случайный поворот, текстура sponge, разброс сброшен", p["rotate"] == "random" and p["tip"] == "sponge" and float(p["scatter"]) == 0.0)
	PaintBrushes.apply_tip(p, "square", 0.04)
	_check("apply_tip квадрат: без текстуры, форма box, поворот по мазку", p["tip"] == "" and p["shape"] == "box" and p["rotate"] == "stroke")
	PaintBrushes.apply_tip(p, "round", 0.04)
	_check("apply_tip круг возвращает исходные параметры, неизвестный конец тоже даёт круг", p["tip"] == "" and p["shape"] == "round" and p["rotate"] == "none" and float(p["scatter"]) == 0.0 and is_equal_approx(float(p["size"]), 0.04))
	PaintBrushes.apply_tip(p, "nope", 0.04)
	_check("apply_tip: неизвестный id", p["end"] == "round")
	_check("ластик с концом губка: конец применяется и к ластику", _eraser_sponge())


func _eraser_sponge() -> bool:
	var e := PaintBrushes.preset("eraser")
	PaintBrushes.apply_tip(e, "sponge", float(PaintBrushes.PRESETS["eraser"]["size"]))
	return e["erase"] == true and e["tip"] == "sponge" and is_equal_approx(float(e["size"]), 0.09)


func _perp_unit(t: Vector3, n: Vector3) -> bool:
	return absf(t.length() - 1.0) < 0.001 and absf(t.dot(n.normalized())) < 0.001


func _test_tangent() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var n := Vector3(0, 0, 1)
	_check("fixed: по оси Y модели", PaintBrushes.tangent(n, "fixed", Vector3.ZERO, rng).is_equal_approx(Vector3(0, 1, 0)))
	_check("fixed на горизонтальной поверхности: по оси X", PaintBrushes.tangent(Vector3.UP, "fixed", Vector3.ZERO, rng).is_equal_approx(Vector3(1, 0, 0)))
	_check("stroke: вдоль смещения, проекция на плоскость", PaintBrushes.tangent(n, "stroke", Vector3(1, 0, 0.5), rng).is_equal_approx(Vector3(1, 0, 0)))
	_check("stroke без движения: прежнее направление", PaintBrushes.tangent(n, "stroke", Vector3.ZERO, rng, 0.0, Vector3(0, 1, 0.3)).is_equal_approx(Vector3(0, 1, 0)))
	_check("stroke без движения и без прежнего: по оси Y", PaintBrushes.tangent(n, "stroke", Vector3.ZERO, rng).is_equal_approx(Vector3(0, 1, 0)))
	var all_perp := true
	var seen := {}
	for i in 24:
		var t := PaintBrushes.tangent(n, "random", Vector3.ZERO, rng)
		all_perp = all_perp and _perp_unit(t, n)
		seen[snappedf(t.x, 0.01)] = true
	_check("random: единичные, в плоскости, разные (%d значений)" % seen.size(), all_perp and seen.size() > 10)
	var tilted := Vector3(1, 2, 3).normalized()
	_check("любая нормаль: результат перпендикулярен ей", _perp_unit(PaintBrushes.tangent(tilted, "stroke", Vector3(0.3, 0.1, -1), rng), tilted) and _perp_unit(PaintBrushes.tangent(tilted, "random", Vector3.ZERO, rng), tilted))
	var base := Vector3(1, 0, 0)
	var jit_ok := true
	for i in 30:
		var j := PaintBrushes.jittered(n, base, 1.0, rng)
		jit_ok = jit_ok and _perp_unit(j, n) and rad_to_deg(base.angle_to(j)) <= 45.01
	_check("jitter 1: поворот не больше 45 градусов", jit_ok)
	_check("jitter 0: направление не меняется", PaintBrushes.jittered(n, base, 0.0, rng).is_equal_approx(base))


func _test_helpers() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var n := Vector3(0, 0, 1)
	var t := Vector3(0, 1, 0)
	_check("разброс 0: смещения нет", PaintBrushes.scatter_offset(n, t, 2.0, 0.0, rng) == Vector3.ZERO)
	var off_ok := true
	for i in 40:
		var o := PaintBrushes.scatter_offset(n, t, 2.0, 0.5, rng)
		off_ok = off_ok and o.length() <= 1.0001 and absf(o.dot(n)) < 0.0001
	_check("разброс: точка в круге radius * scatter и в плоскости", off_ok)
	var dry := {"dry": 0.9, "dry_len": 100.0}
	_check("запас краски: без сухой кисти всегда 1", PaintBrushes.load_left({"dry": 0.0}, 5000.0) == 1.0)
	_check("запас краски убывает по длине мазка", PaintBrushes.load_left(dry, 0.0) == 1.0 and is_equal_approx(PaintBrushes.load_left(dry, 50.0), 0.5) and PaintBrushes.load_left(dry, 400.0) == 0.0)
	var flat := PaintBrushes.preset("brush")
	PaintBrushes.apply_tip(flat, "flat", 0.04)
	var o := PaintBrushes.stamp_opts(flat, Vector3(0, 1, 0), 0.7)
	_check("stamp_opts: текстура, форма, box, направление, запас", o["tip"] == "bristle" and o["shape"] == "box" and o["box"] == Vector2(0.35, 1.0) and o["tan"] == Vector3(0, 1, 0) and is_equal_approx(o["load"], 0.7) and o["dry"] == 0.0 and o["relief"] == 0.0)
	var mk := PaintBrushes.preset("mask")
	_check("маска: инструмент маски уровня 3, по умолчанию скотч, закрывает, трафарет накрывает рисунок; у остальных масок нет", mk["mask_tool"] == true and mk["level"] == 3 and mk["mask_kind"] == "tape" and mk["mask_close"] == true and mk["stencil_cover"] == "ink" and PaintBrushes.preset("brush")["mask_tool"] == false)
	var mo := PaintBrushes.stamp_opts(mk, Vector3(1, 0, 0), 1.0)
	_check("stamp_opts скотча: штамп в маску, без образца и рельефа, без трафарета", mo["mask"] == true and mo["sample"] == "" and mo["relief"] == 0.0 and not mo.has("stencil") and not PaintBrushes.stamp_opts(PaintBrushes.preset("brush"), Vector3.RIGHT, 1.0).has("mask"))
	mk["mask_kind"] = "stencil"
	mk["stencil_cover"] = "bg"
	var ms := PaintBrushes.stamp_opts(mk, Vector3(1, 0, 0), 1.0)
	_check("stamp_opts трафарета: картинка, без цвета палитры, накрывает фон", ms["mask"] == true and ms["stencil"] == true and ms["stencil_ink"] == false and ms["decal"] == "star" and ms["decal_tint"] == false)
	var dec := PaintBrushes.preset("decal")
	_check("декаль: инструмент-декаль, один штамп на нажатие, уровень 3, у обычных кистей декалей нет", dec["decal_tool"] == true and dec["single"] == true and dec["level"] == 3 and str(dec["decal"]) == "star" and PaintBrushes.preset("brush")["decal_tool"] == false and PaintBrushes.preset("brush")["single"] == false)
	var dop := PaintBrushes.stamp_opts(dec, Vector3(1, 0, 0), 1.0)
	_check("stamp_opts декали: id, зеркало, цвет палитры; у обычной кисти этих полей нет", dop["decal"] == "star" and dop["decal_mirror"] == false and dop["decal_tint"] == true and not PaintBrushes.stamp_opts(PaintBrushes.preset("brush"), Vector3.RIGHT, 1.0).has("decal"))
	var wash := PaintBrushes.preset("dry")
	wash["relief"] = -1.0           # переключатель вида сухой кисти: впадины и тени
	var od := PaintBrushes.stamp_opts(wash, Vector3(0, 1, 0), 1.0)
	_check("stamp_opts: сухая кисть с видом «впадины и тени» даёт relief -1 и чувствительность", od["relief"] == -1.0 and od["relief_sens"] == 1.0)


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
