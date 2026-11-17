extends Node

# XX claude-library (новый файл)
## Проверка: образцы кисти (ATTN_22 §22.7.2.1, шаг C2.3): PaintSamples (бесшовные текстуры 256x256 RGBA, рисуются кодом).
## Рендер не нужен. Штамп с образцом на модели проверяет tests/library_paint_group_test.
## Запуск: открыть tests/library_paint_samples_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Library paint samples: n/m».

var _ok := 0
var _all := 0


func _ready() -> void:
	_check("образцы: rust, dirt, soot, wear, streaks; у каждого есть название", PaintSamples.ORDER == ["rust", "dirt", "soot", "wear", "streaks"] and _titles_ok())
	_check("образцы доступны с уровня 3, пустой id и неизвестный id это «без образца»", PaintSamples.LEVEL == 3 and not PaintSamples.has("") and PaintSamples.image("nope") == null and PaintSamples.texture("") == null)
	for id in PaintSamples.ORDER:
		_test_sample(id)
	print("Library paint samples: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _titles_ok() -> bool:
	for id in PaintSamples.ORDER:
		if PaintSamples.title(id) == "":
			return false
	return true


func _test_sample(id: String) -> void:
	var img := PaintSamples.image(id)
	_check("%s: картинка %dx%d RGBA8, текстура есть, кэш отдаёт ту же" % [id, PaintSamples.SIZE, PaintSamples.SIZE], img != null and img.get_width() == PaintSamples.SIZE and img.get_height() == PaintSamples.SIZE and img.get_format() == Image.FORMAT_RGBA8 and PaintSamples.texture(id) != null and PaintSamples.texture(id) == PaintSamples.texture(id))
	_check("%s: при повторном построении та же картинка (зерно фиксировано)" % id, PaintSamples._build(id).get_data() == img.get_data())

	var n := img.get_width() * img.get_height()
	var a_sum := 0.0
	var a_sq := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var a := img.get_pixel(x, y).a
			a_sum += a
			a_sq += a * a
	var a_mean := a_sum / n
	var a_std := sqrt(maxf(a_sq / n - a_mean * a_mean, 0.0))
	_check("%s: пятнистость есть, но не пустая и не сплошная (альфа: среднее %.2f, разброс %.2f)" % [id, a_mean, a_std], a_mean > 0.03 and a_mean < 0.97 and a_std > 0.05)

	# бесшовность: перепад между краями не больше соседних столбцов и строк (с запасом)
	var seam_x := 0.0
	var inner_x := 0.0
	var seam_y := 0.0
	var inner_y := 0.0
	var size := img.get_width()
	for k in size:
		seam_x += absf(img.get_pixel(0, k).a - img.get_pixel(size - 1, k).a)
		inner_x += absf(img.get_pixel(size / 2, k).a - img.get_pixel(size / 2 - 1, k).a)
		seam_y += absf(img.get_pixel(k, 0).a - img.get_pixel(k, size - 1).a)
		inner_y += absf(img.get_pixel(k, size / 2).a - img.get_pixel(k, size / 2 - 1).a)
	seam_x /= size
	inner_x /= size
	seam_y /= size
	inner_y /= size
	_check("%s: бесшовно по обеим осям (шов %.3f и %.3f, внутри %.3f и %.3f)" % [id, seam_x, seam_y, inner_x, inner_y], seam_x <= inner_x * 3.0 + 0.03 and seam_y <= inner_y * 3.0 + 0.03)


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
