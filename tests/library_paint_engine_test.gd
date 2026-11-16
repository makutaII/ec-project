extends Node3D

# XX claude-library (новый файл)
## Проверка шага C2.1 (ATTN_22): движок кисти (PaintEngine): карта позиций, штампы, ластик, отмена и повтор, очистка,
## защита обратной стороны, накладка в цепочке материалов (VariantApplier).
## Запуск: открыть tests/library_paint_engine_test.tscn и нажать F6 (нужен рендер: слой краски это SubViewport).
## Итог в Output: строки PASS/FAIL и «Library paint engine: n/m». Тест берёт сферу с UV2 из lightmap_unwrap
## (в запуске из редактора модуль xatlas доступен), слой 256x256 для скорости.

const RES := 256

var _ok := 0
var _all := 0
var _mi: MeshInstance3D
var _tri: TriangleMesh


func _ready() -> void:
	_test_overlay_chain()
	await _test_engine()
	print("Library paint engine: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _sphere() -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radial_segments = 32
	sphere.rings = 16
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
	var mat := StandardMaterial3D.new()
	mesh.surface_set_material(0, mat)
	var err := mesh.lightmap_unwrap(Transform3D.IDENTITY, 0.05)
	print("ИНФО  lightmap_unwrap сферы: %s" % ("OK" if err == OK else "ошибка %d" % err))
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = mesh
	return mi


## {red, blue, max_alpha} по слою; цвет после снятия премультипликации
func _stats(img: Image) -> Dictionary:
	var data := img.get_data()
	var red := 0
	var blue := 0
	var max_a := 0.0
	for i in range(0, data.size(), 4):
		var a := data[i + 3] / 255.0
		if a > max_a:
			max_a = a
		if a < 0.5:
			continue
		if data[i] > data[i + 2]:
			red += 1
		else:
			blue += 1
	return {"red": red, "blue": blue, "max_alpha": max_a}


func _probe(axis: Vector3) -> Dictionary:
	var c := _mi.mesh.get_aabb().get_center()
	return _tri.intersect_ray(c + axis * 6.0, -axis)


# --- цепочка материалов: накладка перед прежним next_pass ---

func _test_overlay_chain() -> void:
	var tail := StandardMaterial3D.new()   # прежняя цепочка (контур, питание)
	var base := StandardMaterial3D.new()
	base.next_pass = tail
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, BoxMesh.new().get_mesh_arrays())
	mesh.surface_set_material(0, base)
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = mesh
	var overlay := ShaderMaterial.new()
	VariantApplier.apply([mi], {}, {"Body": overlay})
	var o := mi.get_surface_override_material(0)
	_check("накладка: override-копия с метой, общий материал модели не тронут", o != null and o != base and o.has_meta(VariantApplier.META) and base.next_pass == tail)
	var chain_first := o.next_pass
	_check("накладка встала первой в цепочке next_pass (копия накладки)", chain_first is ShaderMaterial and chain_first != overlay and chain_first.next_pass == tail)
	VariantApplier.apply([mi], {}, {"Body": overlay})
	var o2 := mi.get_surface_override_material(0)
	_check("повторное применение не удлиняет цепочку", o2.next_pass is ShaderMaterial and (o2.next_pass as Material).next_pass == tail)
	var paint_variant := {"paint": PaintData.new_paint()}
	PaintData.set_zone(paint_variant["paint"], "all", Color.RED)
	VariantApplier.apply([mi], paint_variant, {"Body": overlay})
	var o3 := mi.get_surface_override_material(0) as StandardMaterial3D
	_check("заливка зоны и накладка вместе: цвет зоны и накладка в цепочке", o3.albedo_color.to_html(false) == "ff0000" and o3.next_pass is ShaderMaterial)
	VariantApplier.apply([mi], {})
	_check("сброс снимает и покраску, и накладку", mi.get_surface_override_material(0) == null)
	mi.free()


# --- движок ---

func _test_engine() -> void:
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	_check("меш без UV2: has_uv2 false, кандидатов нет", not PaintBake.has_uv2(box.mesh) and PaintEngine.candidates([box]).is_empty())
	box.free()

	_mi = _sphere()
	add_child(_mi)
	_tri = _mi.mesh.generate_triangle_mesh()
	_check("меш с UV2: has_uv2 true, он единственный кандидат", PaintBake.has_uv2(_mi.mesh) and PaintEngine.candidates([_mi]).size() == 1 and PaintEngine.candidates([_mi])[0] == _mi)

	var eng := PaintEngine.new()
	add_child(eng)
	var ok := await eng.setup(_mi, RES)
	_check("setup: карта позиций построена (покрыто %d, перекрытий %d)" % [eng.bake_info.get("covered", 0), eng.bake_info.get("overlapped", 0)], ok and eng.is_built)
	if not ok:
		return
	_check("радиус кисти считается от габарита группы мешей", is_equal_approx(eng.radius_for(0.1), eng.size_ref * 0.1) and eng.size_ref > 0.0)
	var ov := eng.make_overlay()
	_check("накладка слоя: шейдер и текстура слоя заданы", ov.shader != null and ov.get_shader_parameter("layer") != null and eng.texture != null)

	var p1 := _probe(Vector3.RIGHT)
	var p2 := _probe(Vector3.LEFT)
	_check("лучи в две стороны сферы попали", not p1.is_empty() and not p2.is_empty())
	if p1.is_empty() or p2.is_empty():
		return
	var r := eng.radius_for(0.25)

	# 1. штрих красным, затем штрих синим
	eng.begin_stroke()
	eng.stamp(p1["position"], p1["normal"], r, Color(1, 0, 0), 1.0, 0.5)
	eng.end_stroke()
	await _frames(6)
	var s1 := _stats(eng.read_layer())
	_check("красный штамп нанёс краску (текселей: %d)" % s1["red"], s1["red"] > 0 and s1["blue"] == 0)
	_check("после штриха в истории есть шаг отмены", eng.can_undo() and not eng.can_redo())
	eng.begin_stroke()
	eng.stamp(p2["position"], p2["normal"], r, Color(0, 0, 1), 1.0, 0.5)
	eng.end_stroke()
	await _frames(6)
	var s2 := _stats(eng.read_layer())
	_check("синий штрих добавлен, красный на месте (красных %d -> %d, синих %d)" % [s1["red"], s2["red"], s2["blue"]], s2["red"] >= s1["red"] * 0.95 and s2["blue"] > 0)

	# 2. отмена и повтор
	_check("undo принят", eng.undo())
	await _frames(5)
	var s3 := _stats(eng.read_layer())
	_check("отмена убрала синий и оставила красный", s3["blue"] == 0 and s3["red"] > 0 and eng.can_redo())
	_check("redo принят", eng.redo())
	await _frames(5)
	var s4 := _stats(eng.read_layer())
	_check("повтор вернул синий", s4["blue"] > 0 and s4["red"] > 0)
	eng.undo()
	await _frames(5)
	eng.undo()
	await _frames(5)
	var s5 := _stats(eng.read_layer())
	_check("две отмены: слой пуст, отменять больше нечего", s5["red"] == 0 and s5["blue"] == 0 and not eng.can_undo())
	eng.redo()
	await _frames(5)
	eng.redo()
	await _frames(5)

	# 3. ластик тем же штампом стирает красный
	eng.begin_stroke()
	eng.stamp(p1["position"], p1["normal"], r, Color(1, 1, 1), 1.0, 0.5, true)
	eng.end_stroke()
	await _frames(6)
	var s6 := _stats(eng.read_layer())
	_check("ластик стёр красный (плотных текселей %d -> %d), синий цел" % [s2["red"], s6["red"]], s6["red"] == 0 and s6["blue"] > 0)

	# 4. очистка и её отмена
	eng.clear()
	await _frames(8)
	var s7 := _stats(eng.read_layer())
	_check("очистка сделала слой пустым", s7["red"] == 0 and s7["blue"] == 0 and s7["max_alpha"] < 0.01)
	_check("очистка тоже шаг истории: отмена возвращает синий", eng.undo())
	await _frames(5)
	_check("после отмены очистки синий на месте", _stats(eng.read_layer())["blue"] > 0)
	eng.clear()
	await _frames(8)

	# 5. обратная сторона: нормаль попадания смотрит в другую сторону, краски быть не должно
	eng.begin_stroke()
	eng.stamp(p1["position"], -(p1["normal"] as Vector3), r, Color(1, 0, 0), 1.0, 0.5)
	eng.end_stroke()
	await _frames(6)
	_check("штамп с противоположной нормалью ничего не красит", _stats(eng.read_layer())["max_alpha"] < 0.05)

	# 6. штампы с разными параметрами в одном кадре: обе серии отрисованы
	eng.begin_stroke()
	eng.stamp(p1["position"], p1["normal"], r, Color(1, 0, 0), 1.0, 0.5)
	eng.stamp(p2["position"], p2["normal"], r, Color(0, 0, 1), 1.0, 0.5)
	eng.end_stroke()
	await _frames(8)
	var s8 := _stats(eng.read_layer())
	_check("красный и синий штампы из одной очереди оба на слое", s8["red"] > 0 and s8["blue"] > 0)

	# 7. набор краски: 4 штампа потоком 0.25 в одну точку дают плотнее одного
	eng.clear()
	await _frames(8)
	eng.stamp(p1["position"], p1["normal"], r, Color(1, 0, 0), 0.25, 0.5)
	await _frames(4)
	var a1 := float(_stats(eng.read_layer())["max_alpha"])
	for i in 3:
		eng.stamp(p1["position"], p1["normal"], r, Color(1, 0, 0), 0.25, 0.5)
		await _frames(3)
	var a4 := float(_stats(eng.read_layer())["max_alpha"])
	_check("набор краски: альфа растёт (%.2f -> %.2f)" % [a1, a4], a4 > a1 + 0.2)

	# 8. PNG слоя: сохранение, пустота, загрузка, начало истории
	eng.clear()
	await _frames(8)
	_check("очищенный слой пуст (is_empty)", eng.is_empty())
	eng.begin_stroke()
	eng.stamp(p1["position"], p1["normal"], r, Color(1, 0, 0), 1.0, 0.5)
	eng.end_stroke()
	await eng.wait_idle()
	_check("слой с краской не пуст (is_empty)", not eng.is_empty())
	var before := _stats(eng.read_layer())
	var png := eng.to_png()
	_check("to_png даёт читаемый PNG (%d КБ)" % (png.size() / 1024), png.size() > 0 and PaintLayers.texture_from_png(png) != null)
	eng.clear()
	await eng.wait_idle()
	_check("после очистки слой пуст", eng.is_empty())
	_check("load_png принял PNG", await eng.load_png(png))
	var after := _stats(eng.read_layer())
	_check("загруженный слой совпадает с сохранённым (плотных текселей %d и %d)" % [before["red"], after["red"]],
		before["red"] > 0 and absi(int(before["red"]) - int(after["red"])) <= int(before["red"]) * 0.02)
	_check("после загрузки история начинается заново", not eng.can_undo() and not eng.can_redo())
	_check("мусор вместо PNG load_png не принимает", not await eng.load_png(PackedByteArray([1, 2, 3])))

	eng.queue_free()
	_mi.queue_free()


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
