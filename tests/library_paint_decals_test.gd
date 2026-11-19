extends Node3D

# XX claude-library (новый файл)
## Проверка: декали (ATTN_22 §22.7.2.1, шаг C2.4): PaintDecals (встроенные формы, файлы), ориентация декали на поверхности
## (PaintBrushes.decal_right) и штамп декали в слой краски (нужен рендер): центр, цвет палитры или картинки, поворот,
## зеркало, прозрачность, две декали за один кадр.
## Запуск: открыть tests/library_paint_decals_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Library paint decals: n/m».

const RES := 64

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_shapes()
	_test_files()
	_test_orientation()
	await _test_render()
	print("Library paint decals: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _alpha(img: Image, x: int, y: int) -> float:
	return img.get_pixel(x, y).a


func _test_shapes() -> void:
	_check("встроенные декали: звезда, стрелка, крест, кольцо, полоса, у каждой есть название", PaintDecals.ORDER == ["star", "arrow", "cross", "ring", "stripe"] and PaintDecals.title("star") == "Звезда" and PaintDecals.is_builtin("ring") and PaintDecals.has("stripe") and not PaintDecals.has("nope"))
	var star := PaintDecals.image("star")
	_check("звезда: картинка 256x256 RGBA8, белая, центр и луч вверх закрашены, угол пуст", star != null and star.get_width() == 256 and star.get_height() == 256 and star.get_format() == Image.FORMAT_RGBA8 and _alpha(star, 128, 128) > 0.9 and _alpha(star, 128, 20) > 0.9 and _alpha(star, 6, 6) < 0.05 and star.get_pixel(128, 128).r > 0.99)
	var arrow := PaintDecals.image("arrow")
	_check("стрелка: голова справа (x = 0.35, y = 0.35) закрашена, слева (x = -0.35) пусто", _alpha(arrow, 172, 83) > 0.9 and _alpha(arrow, 83, 83) < 0.05 and _alpha(arrow, 128, 128) > 0.9)
	_check("крест: центр и конец руки закрашены, угол пуст", _alpha(PaintDecals.image("cross"), 128, 128) > 0.9 and _alpha(PaintDecals.image("cross"), 128, 30) > 0.9 and _alpha(PaintDecals.image("cross"), 30, 30) < 0.05)
	_check("кольцо: центр пуст, на радиусе 0.68 закрашено", _alpha(PaintDecals.image("ring"), 128, 128) < 0.05 and _alpha(PaintDecals.image("ring"), 128 + int(0.68 * 128), 128) > 0.9)
	var stripe := PaintDecals.image("stripe")
	_check("полоса: картинка 256x64, центр закрашен, скруглённый угол пуст", stripe.get_width() == 256 and stripe.get_height() == 64 and _alpha(stripe, 128, 32) > 0.9 and _alpha(stripe, 0, 0) < 0.5)
	_check("пропорции: звезда 1 x 1, полоса 1 x 0.25", PaintDecals.aspect_box("star") == Vector2.ONE and PaintDecals.aspect_box("stripe") == Vector2(1.0, 0.25) and PaintDecals.aspect_box("nope") == Vector2.ONE)
	_check("текстуры: кэш, зеркальная текстура отражена (голова стрелки слева)", PaintDecals.texture("star") != null and PaintDecals.texture("star") == PaintDecals.texture("star") and PaintDecals.flipped_texture("arrow") != null and PaintDecals.flipped_texture("arrow").get_image().get_pixel(83, 83).a > 0.9 and PaintDecals.flipped_texture("nope") == null)


func _test_files() -> void:
	var tmp := "user://library_decals_test"
	DirAccess.make_dir_recursive_absolute(tmp)
	var img := Image.create(64, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.6, 0.9, 1.0))
	img.save_png(tmp + "/my_logo.png")
	var saved := PaintDecals.dirs
	var saved_mixed := PaintDecals.mixed_dirs
	PaintDecals.dirs = [tmp, "user://library_decals_test_missing"]
	PaintDecals.mixed_dirs = []
	PaintDecals.refresh()
	var ids := PaintDecals.ids()
	_check("файлы: своя декаль идёт после встроенных, название из имени файла", ids.size() == PaintDecals.ORDER.size() + 1 and ids[ids.size() - 1] == "f:my_logo" and PaintDecals.title("f:my_logo") == "my logo" and not PaintDecals.is_builtin("f:my_logo") and PaintDecals.file_path("f:my_logo") == tmp + "/my_logo.png")
	_check("файлы: пропорции 64 x 16 это 1 x 0.25, текстура с цветом картинки", PaintDecals.aspect_box("f:my_logo") == Vector2(1.0, 0.25) and PaintDecals.texture("f:my_logo") != null and absf(PaintDecals.image("f:my_logo").get_pixel(32, 8).g - 0.6) < 0.02)
	DirAccess.remove_absolute(tmp + "/my_logo.png")
	PaintDecals.refresh()
	_check("файлы: убранная картинка пропадает из списка и кэша", not PaintDecals.has("f:my_logo") and PaintDecals.texture("f:my_logo") == null)

	# папка образцов: из неё берутся только файлы decal*, остальное это образцы
	var mixed := "user://library_decals_test_mixed"
	DirAccess.make_dir_recursive_absolute(mixed)
	img.save_png(mixed + "/decal_01.png")
	img.save_png(mixed + "/rust_tile.png")
	PaintDecals.dirs = [tmp]
	PaintDecals.mixed_dirs = [mixed]
	PaintDecals.refresh()
	_check("папка образцов: файл decal_01 это декаль, rust_tile нет", PaintDecals.has("f:decal_01") and not PaintDecals.has("f:rust_tile") and PaintDecals.ids().size() == PaintDecals.ORDER.size() + 1)
	_check("папка образцов: декаль читается напрямую (картинка не импортирована)", PaintDecals.texture("f:decal_01") != null and PaintDecals.aspect_box("f:decal_01") == Vector2(1.0, 0.25))
	DirAccess.remove_absolute(mixed + "/decal_01.png")
	DirAccess.remove_absolute(mixed + "/rust_tile.png")
	DirAccess.remove_absolute(mixed)
	DirAccess.remove_absolute(tmp)
	PaintDecals.dirs = saved
	PaintDecals.mixed_dirs = saved_mixed
	PaintDecals.refresh()


func _test_orientation() -> void:
	var n := Vector3(0, 0, 1)
	_check("decal_right: без поворота вправо по картинке это +X (вверх по картинке +Y)", PaintBrushes.decal_right(n, 0.0).is_equal_approx(Vector3(1, 0, 0)))
	_check("decal_right: поворот на 90 градусов против часовой: вправо по картинке это +Y", PaintBrushes.decal_right(n, 90.0).is_equal_approx(Vector3(0, 1, 0)))
	_check("decal_right: поворот на 180 градусов даёт -X", PaintBrushes.decal_right(n, 180.0).is_equal_approx(Vector3(-1, 0, 0)))
	var tilted := Vector3(1, 2, 3).normalized()
	var r := PaintBrushes.decal_right(tilted, 35.0)
	_check("decal_right: на наклонной поверхности единичный вектор в плоскости", absf(r.length() - 1.0) < 0.001 and absf(r.dot(tilted)) < 0.001)


## Квадрат 1x1 лицом к +Z, UV2 на весь атлас: пиксель слоя (px, py) это точка (px / 64 - 0.5, 0.5 - py / 64)
func _quad() -> MeshInstance3D:
	var arrays := QuadMesh.new().get_mesh_arrays()
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2 := PackedVector2Array()
	for v in vs:
		uv2.append(Vector2(v.x + 0.5, 0.5 - v.y))
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _opts(id: String, angle: float, mirror := false, tint := true) -> Dictionary:
	return {"decal": id, "decal_mirror": mirror, "decal_tint": tint, "tan": PaintBrushes.decal_right(Vector3(0, 0, 1), angle), "load": 1.0}


func _place(eng: PaintEngine, at: Vector3, radius: float, color: Color, flow: float, opts: Dictionary) -> void:
	eng.begin_stroke()
	eng.stamp(at, Vector3(0, 0, 1), radius, color, flow, 1.0, false, opts)
	eng.end_stroke()


func _fresh(eng: PaintEngine) -> void:
	eng.clear()
	await _frames(6)


func _test_render() -> void:
	var q := _quad()
	add_child(q)
	await _frames(2)
	var eng := PaintEngine.new()
	add_child(eng)
	var ok := await eng.setup(q, RES)
	_check("setup: карта кисти построена, размер текселя посчитан (%.4f)" % eng.texel_world, ok and eng.is_built and eng.texel_world > 0.005 and eng.texel_world < 0.05)
	if not ok:
		return

	await _fresh(eng)
	_place(eng, Vector3.ZERO, 0.4, Color(1, 0, 0), 1.0, _opts("star", 0.0))
	await _frames(6)
	var img := eng.read_layer()
	var mid := img.get_pixel(32, 32)
	_check("звезда цветом палитры: центр красный и плотный (%.2f, %.2f, %.2f, %.2f)" % [mid.r, mid.g, mid.b, mid.a], mid.a > 0.9 and mid.r > 0.9 and mid.g < 0.1 and mid.b < 0.1)
	_check("за пределами декали (0.35, 0.35 при радиусе 0.4) краски нет", _alpha(img, 54, 9) < 0.05)

	await _fresh(eng)
	_place(eng, Vector3.ZERO, 0.4, Color(1, 0, 0), 1.0, _opts("star", 0.0, false, false))
	await _frames(6)
	var white := eng.read_layer().get_pixel(32, 32)
	_check("без цвета палитры белая форма остаётся белой", white.a > 0.9 and white.r > 0.9 and white.g > 0.9 and white.b > 0.9)

	await _fresh(eng)
	_place(eng, Vector3.ZERO, 0.4, Color(1, 0, 0), 0.5, _opts("star", 0.0))
	await _frames(6)
	var half := _alpha(eng.read_layer(), 32, 32)
	_check("поток это прозрачность декали (%.2f при 0.5)" % half, half > 0.4 and half < 0.6)

	# стрелка: голова справа от центра. Точки головы (+-0.14, 0.14) это пиксели (40, 23) и (23, 23), (40, 41) и (23, 41)
	await _fresh(eng)
	_place(eng, Vector3.ZERO, 0.4, Color(0, 0, 1), 1.0, _opts("arrow", 0.0))
	await _frames(6)
	var a0 := eng.read_layer()
	_check("стрелка без поворота: голова справа (%.2f), слева пусто (%.2f)" % [_alpha(a0, 40, 23), _alpha(a0, 23, 23)], _alpha(a0, 40, 23) > 0.5 and _alpha(a0, 23, 23) < 0.1)

	await _fresh(eng)
	_place(eng, Vector3.ZERO, 0.4, Color(0, 0, 1), 1.0, _opts("arrow", 0.0, true))
	await _frames(6)
	var am := eng.read_layer()
	_check("зеркально: голова слева (%.2f), справа пусто (%.2f)" % [_alpha(am, 23, 23), _alpha(am, 40, 23)], _alpha(am, 23, 23) > 0.5 and _alpha(am, 40, 23) < 0.1)

	await _fresh(eng)
	_place(eng, Vector3.ZERO, 0.4, Color(0, 0, 1), 1.0, _opts("arrow", 90.0))
	await _frames(6)
	var a90 := eng.read_layer()
	_check("поворот 90 градусов: голова вверх (оба верхних пикселя закрашены), вниз пусто", _alpha(a90, 40, 23) > 0.5 and _alpha(a90, 23, 23) > 0.5 and _alpha(a90, 40, 41) < 0.1 and _alpha(a90, 23, 41) < 0.1)

	await _fresh(eng)
	_place(eng, Vector3.ZERO, 0.4, Color(0, 0, 1), 1.0, _opts("arrow", 180.0))
	await _frames(6)
	var a180 := eng.read_layer()
	_check("поворот 180 градусов: голова слева", _alpha(a180, 23, 23) > 0.5 and _alpha(a180, 40, 23) < 0.1)

	# две декали в одном кадре не должны слиться в одну пачку
	await _fresh(eng)
	eng.begin_stroke()
	eng.stamp(Vector3(-0.25, 0, 0), Vector3(0, 0, 1), 0.15, Color(1, 0, 0), 1.0, 1.0, false, _opts("star", 0.0))
	eng.stamp(Vector3(0.25, 0, 0), Vector3(0, 0, 1), 0.15, Color(1, 0, 0), 1.0, 1.0, false, _opts("star", 0.0))
	eng.end_stroke()
	await _frames(6)
	var two := eng.read_layer()
	_check("две декали за кадр: обе на месте (%.2f и %.2f)" % [_alpha(two, 16, 32), _alpha(two, 48, 32)], _alpha(two, 16, 32) > 0.9 and _alpha(two, 48, 32) > 0.9)

	eng.queue_free()
	q.queue_free()
	await _frames(2)


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
