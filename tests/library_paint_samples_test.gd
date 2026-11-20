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
	_test_files()
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
		seam_y += absf(img.get_pixel(k, 0).a - img.get_pixel(k, size - 1).a)
		for m in range(0, size - 1):
			inner_x += absf(img.get_pixel(m, k).a - img.get_pixel(m + 1, k).a)
			inner_y += absf(img.get_pixel(k, m).a - img.get_pixel(k, m + 1).a)
	seam_x /= size
	seam_y /= size
	inner_x /= float(size) * (size - 1)       # средний перепад между соседними столбцами и строками по всей картинке
	inner_y /= float(size) * (size - 1)
	_check("%s: бесшовно по обеим осям (шов %.3f и %.3f, средний перепад соседних %.3f и %.3f)" % [id, seam_x, seam_y, inner_x, inner_y], seam_x <= inner_x * 3.0 + 0.02 and seam_y <= inner_y * 3.0 + 0.02)


## Свои образцы из файлов: папка подменяется временной, файл появляется и исчезает вместе с папкой
func _test_files() -> void:
	var tmp := "user://library_samples_test"
	DirAccess.make_dir_recursive_absolute(tmp)
	var img := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.8, 0.2, 0.1, 0.5))
	img.save_png(tmp + "/ржавые_подтёки.png")
	img.save_png(tmp + "/b_plain.png")
	img.save_png(tmp + "/decal_star.png")       # файл на «decal» виден и как образец, и как декаль
	var note := FileAccess.open(tmp + "/notes.txt", FileAccess.WRITE)
	note.store_string("не картинка")
	note.close()
	var saved := PaintSamples.dirs
	PaintSamples.dirs = [tmp, "user://library_samples_test_missing"]
	PaintSamples.refresh()
	var ids := PaintSamples.ids()
	_check("файлы: образцы из папки идут после встроенных, по имени, текстовый файл пропущен", ids.size() == PaintSamples.ORDER.size() + 3 and ids[ids.size() - 3] == "f:b_plain" and ids[ids.size() - 2] == "f:decal_star" and ids[ids.size() - 1] == "f:ржавые_подтёки")
	_check("файлы: название из имени файла, has и file_path", PaintSamples.title("f:ржавые_подтёки") == "ржавые подтёки" and PaintSamples.has("f:b_plain") and PaintSamples.file_path("f:b_plain") == tmp + "/b_plain.png" and PaintSamples.file_path("rust") == "")
	var tex := PaintSamples.texture("f:b_plain")
	_check("файлы: текстура загружена с размером картинки и кэшируется; у встроенных image есть, у файла нет", tex != null and tex.get_width() == 8 and tex.get_height() == 4 and PaintSamples.texture("f:b_plain") == tex and PaintSamples.image("f:b_plain") == null and PaintSamples.image("rust") != null)
	_check("файлы: неизвестный файловый id это «без образца»", PaintSamples.texture("f:нет") == null and not PaintSamples.has("f:нет"))
	DirAccess.remove_absolute(tmp + "/b_plain.png")
	PaintSamples.refresh()
	_check("файлы: убранный файл пропадает из списка после refresh", not PaintSamples.has("f:b_plain") and PaintSamples.has("f:ржавые_подтёки"))
	_check("файлы: файл decal_* остаётся образцом (текстурой любой кисти)", PaintSamples.has("f:decal_star") and PaintSamples.texture("f:decal_star") != null)
	DirAccess.remove_absolute(tmp + "/decal_star.png")
	DirAccess.remove_absolute(tmp + "/ржавые_подтёки.png")
	DirAccess.remove_absolute(tmp + "/notes.txt")
	DirAccess.remove_absolute(tmp)
	PaintSamples.dirs = saved
	PaintSamples.refresh()


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
