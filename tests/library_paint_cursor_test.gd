extends Node3D

# XX claude-library (новый файл)
## Проверка: контур кисти (ATTN_22 §22.7.2.1): PaintCursor, текстуры колец и размещение декалей. Рендер не нужен
## (декали только создаются и ставятся), но узел должен стоять в дереве. Запуск: tests/library_paint_cursor_test.tscn, F6.
## Итог в Output: строки PASS/FAIL и «Library paint cursor: n/m».

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_textures()
	_test_placement()
	print("Library paint cursor: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _alpha(img: Image, fx: float, fy: float) -> float:
	var s := img.get_width()
	return img.get_pixel(clampi(int(fx * s), 0, s - 1), clampi(int(fy * s), 0, s - 1)).a


func _test_textures() -> void:
	var round_img := PaintCursor.ring_image("round")
	var box_img := PaintCursor.ring_image("box")
	_check("кольцо: картинка %dx%d RGBA8" % [PaintCursor.TEX_SIZE, PaintCursor.TEX_SIZE], round_img.get_width() == PaintCursor.TEX_SIZE and round_img.get_format() == Image.FORMAT_RGBA8 and box_img.get_height() == PaintCursor.TEX_SIZE)
	# круг: центр пуст, линия на 0.955 радиуса (справа от центра), за краем кольца пусто
	var line_x := 0.5 + 0.5 * PaintCursor.LINE_CENTER
	_check("круг: центр пуст, линия светлая и плотная", _alpha(round_img, 0.5, 0.5) == 0.0 and _alpha(round_img, line_x, 0.5) > 0.95 and round_img.get_pixel(int(line_x * PaintCursor.TEX_SIZE), PaintCursor.TEX_SIZE / 2).r > 0.95)
	_check("круг: угол картинки пуст (кольцо круглое)", _alpha(round_img, 0.97, 0.97) == 0.0)
	_check("прямоугольник: угол занят линией (кольцо квадратное)", _alpha(box_img, line_x, line_x) > 0.95 and _alpha(box_img, 0.5, 0.5) == 0.0)
	var halo := _alpha(round_img, 0.5 + 0.5 * (PaintCursor.LINE_CENTER - 0.035), 0.5)
	_check("тёмная обводка рядом с линией (полупрозрачная, чёрная)", halo > 0.1 and halo < 0.7)
	_check("текстуры кешируются, box и round разные", PaintCursor.ring_texture("round") == PaintCursor.ring_texture("round") and PaintCursor.ring_texture("round") != PaintCursor.ring_texture("box") and PaintCursor.ring_texture("nope") == PaintCursor.ring_texture("round"))


func _test_placement() -> void:
	var c := PaintCursor.new()
	add_child(c)
	_check("создан скрытым, четыре декали (внешнее, внутреннее, разброс, предпросмотр)", not c.visible and c.get_child_count() == 4 and not c.preview.visible)

	# плоская поверхность лицом к +Z; конец вдоль +Y; мягкая кисть без внутреннего кольца
	c.show_at(Vector3(1, 2, 3), Vector3(0, 0, 1), Vector3(0, 1, 0), 0.5, {"shape": "round", "box": Vector2.ONE, "hardness": 0.0, "scatter": 0.0})
	_check("контур показан в точке, ось проекции вдоль нормали, ось X вдоль конца", c.visible and c.global_position.is_equal_approx(Vector3(1, 2, 3)) and c.global_transform.basis.y.is_equal_approx(Vector3(0, 0, 1)) and c.global_transform.basis.x.is_equal_approx(Vector3(0, 1, 0)))
	_check("внешнее кольцо: размер 2R, глубина проекции больше нуля", c.outer.visible and c.outer.size.is_equal_approx(Vector3(1.0, 0.75, 1.0)))
	_check("мягкая кисть (жёсткость 0): внутреннего кольца нет, разброса нет", not c.inner.visible and not c.scatter_ring.visible)

	c.show_at(Vector3.ZERO, Vector3(0, 1, 0), Vector3(1, 0, 0), 1.0, {"shape": "round", "hardness": 0.5, "scatter": 0.8})
	_check("жёсткость 0.5: внутреннее кольцо вдвое меньше", c.inner.visible and c.inner.size.is_equal_approx(Vector3(1.0, 1.5, 1.0)))
	_check("разброс 0.8: тонкое кольцо радиуса R * 1.8", c.scatter_ring.visible and is_equal_approx(c.scatter_ring.size.x, 3.6))

	c.show_at(Vector3.ZERO, Vector3(0, 1, 0), Vector3(1, 0, 0), 1.0, {"shape": "box", "box": Vector2(0.35, 1.0), "hardness": 0.99})
	_check("щётка: внешнее кольцо 0.7 вдоль конца и 2 поперёк, внутреннего у твёрдой нет", is_equal_approx(c.outer.size.x, 0.7) and is_equal_approx(c.outer.size.z, 2.0) and not c.inner.visible)
	_check("для прямоугольного конца текстура квадратная, для круглого круг", c.outer.texture_albedo == PaintCursor.ring_texture("box"))

	c.show_at(Vector3.ZERO, Vector3(0, 1, 0), Vector3(0, 1, 0), 1.0, {"shape": "round", "hardness": 0.8})
	_check("направление вдоль нормали выправляется (результат ортогонален)", absf(c.global_transform.basis.x.dot(c.global_transform.basis.y)) < 0.001 and c.global_transform.basis.x.length() > 0.99)
	c.show_at(Vector3.ZERO, Vector3(0, 1, 0), Vector3(1, 0, 0), 1.0, {"shape": "round", "hardness": 0.8, "erase": true})
	_check("ластик: кольцо красноватое", c.outer.modulate.r > c.outer.modulate.g and c.outer.modulate.g < 0.9)
	var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	c.show_at(Vector3.ZERO, Vector3(0, 1, 0), Vector3(1, 0, 0), 1.0, {"shape": "box", "box": Vector2(1.0, 0.25), "hardness": 0.0, "decal_tex": tex, "decal_color": Color(1, 0, 0)})
	_check("предпросмотр декали: картинка по размеру рамки, цвет и полупрозрачность", c.preview.visible and c.preview.texture_albedo == tex and is_equal_approx(c.preview.size.x, 2.0) and is_equal_approx(c.preview.size.z, 0.5) and c.preview.modulate.r == 1.0 and c.preview.modulate.g == 0.0 and c.preview.modulate.a < 1.0)
	c.show_at(Vector3.ZERO, Vector3(0, 1, 0), Vector3(1, 0, 0), 1.0, {"shape": "round", "hardness": 0.8})
	_check("без декали предпросмотр скрыт", not c.preview.visible)
	c.hide_cursor()
	_check("hide_cursor скрывает контур", not c.visible)
	c.queue_free()


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
