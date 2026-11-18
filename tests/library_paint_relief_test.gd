extends Node3D

# XX claude-library (новый файл)
## Проверка: рельефная кисть, сухая кисть и смывка (ATTN_22 §22.7.2.1, шаг C2.2a). Нужен рендер (слой краски и карта рельефа
## это SubViewport). Квадрат с базовой текстурой: левая половина тёмная, правая светлая, граница посередине. Сухая кисть
## красит светлую сторону у границы, смывка тёмную, ровные участки далеко от границы не красятся совсем.
## Запуск: открыть tests/library_paint_relief_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Library paint relief: n/m».

const RES := 64

var _ok := 0
var _all := 0


func _ready() -> void:
	await _test()
	print("Library paint relief: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Квадрат 1x1 лицом к +Z, UV2 на весь атлас, базовая текстура: левая половина (u < 0.5) тёмная, правая светлая
func _quad() -> MeshInstance3D:
	var arrays := QuadMesh.new().get_mesh_arrays()
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2 := PackedVector2Array()
	for v in vs:
		uv2.append(Vector2(v.x + 0.5, 0.5 - v.y))
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var uv1 := PackedVector2Array()
	for v in vs:
		uv1.append(Vector2(v.x + 0.5, 0.5 - v.y))      # u растёт вместе с x: край посередине квадрата
	arrays[Mesh.ARRAY_TEX_UV] = uv1
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var v := 0.1 if x < 32 else 0.9
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mi.material_override = mat
	return mi


func _a(img: Image, x: int, y: int) -> float:
	return img.get_pixel(x, y).a


func _paint(eng: PaintEngine, opts: Dictionary) -> Image:
	eng.clear()
	await _frames(6)
	eng.begin_stroke()
	eng.stamp(Vector3.ZERO, Vector3(0, 0, 1), 0.6, Color(1, 0, 0), 1.0, 0.99, false, opts)
	eng.end_stroke()
	await _frames(6)
	return eng.read_layer()


func _test() -> void:
	var q := _quad()
	add_child(q)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 0, 3)
	await _frames(2)
	var src := PaintBake.collect(q.mesh)
	_check("collect: у поверхности есть UV1 и номер поверхности", src.size() == 1 and (src[0]["uv1"] as PackedVector2Array).size() == 4 and src[0]["surface"] == 0)
	var info := PaintBake.albedo_info(q.get_active_material(0))
	_check("albedo_info: текстура и масштаб материала", info["texture"] != null and info["scale"] == Vector2.ONE and PaintBake.albedo_info(null)["texture"] == null)

	var eng := PaintEngine.new()
	add_child(eng)
	var ok := await eng.setup(q, RES)
	_check("setup: карта кисти построена", ok and eng.is_built and not eng.relief_ready)
	if not ok:
		return
	var rel := {"relief": 1.0, "relief_sens": 1.0, "tan": Vector3(0, 1, 0), "load": 1.0}
	var before := await _paint(eng, rel)
	var none := 0
	for y in RES:
		for x in RES:
			none += 1 if _a(before, x, y) > 0.05 else 0
	_check("пока карта рельефа не построена, штампы с рельефом пропускаются (закрашено %d)" % none, none == 0)

	await eng.build_relief(3.0)
	_check("build_relief: карта готова на заданной ширине", eng.relief_ready and is_equal_approx(eng.relief_width, 3.0))

	# граница на x = 32 (u = 0.5): 2 пикселя справа это 34 (светлая сторона), слева 29 (тёмная), далеко 60 и 4
	var y_mid := 32
	var dry := await _paint(eng, rel)
	var d_near_light := _a(dry, 34, y_mid)
	var d_near_dark := _a(dry, 29, y_mid)
	_check("сухая кисть красит светлую кромку у границы (%.2f), тёмную сторону нет (%.2f)" % [d_near_light, d_near_dark], d_near_light > 0.3 and d_near_dark < 0.05)
	_check("сухая кисть не красит ровные участки далеко от границы (%.2f и %.2f)" % [_a(dry, 60, y_mid), _a(dry, 4, y_mid)], _a(dry, 60, y_mid) < 0.05 and _a(dry, 4, y_mid) < 0.05)

	var wash := await _paint(eng, {"relief": -1.0, "relief_sens": 1.0, "tan": Vector3(0, 1, 0), "load": 1.0})
	var w_near_dark := _a(wash, 29, y_mid)
	var w_near_light := _a(wash, 34, y_mid)
	_check("смывка красит тёмную сторону у границы (%.2f), светлую нет (%.2f)" % [w_near_dark, w_near_light], w_near_dark > 0.3 and w_near_light < 0.05)
	_check("смывка не красит ровные участки далеко от границы", _a(wash, 60, y_mid) < 0.05 and _a(wash, 4, y_mid) < 0.05)

	var plain := await _paint(eng, {"tan": Vector3(0, 1, 0), "load": 1.0})
	_check("обычная кисть красит всё (граница, светлая и тёмная стороны)", _a(plain, 34, y_mid) > 0.9 and _a(plain, 29, y_mid) > 0.9 and _a(plain, 60, y_mid) > 0.9)

	# чувствительность и ширина: меньше чувствительность, меньше краски; ширина перестраивает карту
	var weak := await _paint(eng, {"relief": 1.0, "relief_sens": 0.2, "tan": Vector3(0, 1, 0), "load": 1.0})
	var strong := await _paint(eng, {"relief": 1.0, "relief_sens": 3.0, "tan": Vector3(0, 1, 0), "load": 1.0})
	_check("чувствительность: слабая даёт не больше краски, чем сильная (%.2f и %.2f у границы)" % [_a(weak, 34, y_mid), _a(strong, 34, y_mid)], _a(weak, 34, y_mid) <= _a(strong, 34, y_mid) + 0.001 and _a(strong, 34, y_mid) > 0.3)
	await eng.build_relief(8.0)
	var wide := await _paint(eng, rel)
	var wide_cover := 0
	var narrow_cover := 0
	for x in range(32, RES):
		wide_cover += 1 if _a(wide, x, y_mid) > 0.3 else 0
		narrow_cover += 1 if _a(dry, x, y_mid) > 0.3 else 0
	_check("ширина кромки 8 даёт более широкую полосу, чем 3 (%d и %d пикселей)" % [wide_cover, narrow_cover], is_equal_approx(eng.relief_width, 8.0) and wide_cover > narrow_cover)

	eng.queue_free()
	q.queue_free()
	cam.queue_free()
	await _frames(2)


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
