extends Node3D

# XX claude-library (новый файл)
## Проверка: кисть на группе мешей с общим атласом UV2 (ATTN_22 §22.7.2.1, шаги C2.1c и C2.2): PaintBake.group, transformed,
## bake_group, PaintData.layer_meshes, ключ кэша PNG по SHA-1, а в конце PaintEngine на нескольких мешах (нужен рендер:
## слой краски это SubViewport): опорный меш, пропуск перекрытия, луч по ближайшему мешу, закрывающие меши, штамп на дочернем меше,
## цвет слоя 16 бит, квадратный штамп, сухая кисть, образец вместо плоского цвета.
## Запуск: открыть tests/library_paint_group_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Library paint group: n/m». Меши это квадраты QuadMesh со своей UV2 (без xatlas).

const RES := 64

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_group()
	_test_transform_and_bake()
	_test_data_and_cache()
	await _test_engine()
	print("Library paint group: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Квадрат 1x1 в плоскости XY (лицом к +Z) с UV2 в четверти атласа cell..cell+0.5; surfaces копий поверхности
func _quad(mesh_name: String, cell: Vector2, with_uv2 := true, surfaces := 1) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	for s in surfaces:
		var arrays := QuadMesh.new().get_mesh_arrays()
		if with_uv2:
			var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var uv2 := PackedVector2Array()
			for v in vs:
				uv2.append(cell + Vector2((v.x + 0.5) * 0.5, (0.5 - v.y) * 0.5))
			arrays[Mesh.ARRAY_TEX_UV2] = uv2
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = mesh
	return mi


func _entry(mi: MeshInstance3D, xf := Transform3D.IDENTITY) -> Dictionary:
	var surfaces := PaintBake.collect(mi.mesh)
	var verts := 0
	for surf in surfaces:
		verts += (surf["verts"] as PackedVector3Array).size()
	return {"surfaces": surfaces, "verts": verts, "xform": xf}


# --- группа мешей общего атласа ---

func _test_group() -> void:
	var a := _quad("A", Vector2(0, 0), true, 2)
	var b := _quad("B", Vector2(0.5, 0))
	var d := _quad("D", Vector2(0, 0))
	var entries := [_entry(a), _entry(b), _entry(d)]
	_check("опорный меш: больше всего вершин (A, 8 против 4)", PaintBake.seed_index(entries) == 0 and PaintBake.seed_index([_entry(b), _entry(a)]) == 1)
	var occ := PaintBake.occupancy(entries[0]["surfaces"], 64)
	var filled := 0
	for v in occ:
		filled += v
	_check("занятость UV2: четверть атласа (%d из 4096 ячеек)" % filled, filled > 900 and filled < 1150)
	_check("занятость UV2: внутри острова 1, вне острова 0", occ[10 * 64 + 10] == 1 and occ[10 * 64 + 50] == 0 and occ[50 * 64 + 10] == 0)
	var g := PaintBake.group(entries)
	_check("группа: A и B в общем атласе, D перекрывает A и пропущен", g["included"] == PackedInt32Array([0, 1]) and g["skipped"] == PackedInt32Array([2]))
	var g2 := PaintBake.group([_entry(b), _entry(a), _entry(d)])
	_check("опорным становится самый крупный даже не первый в списке", g2["included"][0] == 1 and g2["skipped"] == PackedInt32Array([2]))
	var g3 := PaintBake.group([_entry(a), {"surfaces": [], "verts": 0, "xform": Transform3D.IDENTITY}])
	_check("меш без покрытия UV2 пропускается", g3["included"] == PackedInt32Array([0]) and g3["skipped"] == PackedInt32Array([1]))
	var g4 := PaintBake.group([_entry(a)])
	_check("один меш: он и опорный", g4["included"] == PackedInt32Array([0]) and g4["skipped"].is_empty())
	_check("пустой список не роняет", PaintBake.group([])["included"].is_empty())
	a.free()
	b.free()
	d.free()


# --- перевод в пространство опорного меша и общее запекание ---

func _test_transform_and_bake() -> void:
	var a := _quad("A", Vector2(0, 0))
	var b := _quad("B", Vector2(0.5, 0))
	var surfaces := PaintBake.collect(b.mesh)
	var xf := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(10, 0, 0))
	var moved := PaintBake.transformed(surfaces, xf)
	var vs: PackedVector3Array = surfaces[0]["verts"]
	var vs2: PackedVector3Array = moved[0]["verts"]
	var ns2: PackedVector3Array = moved[0]["norms"]
	var same := vs.size() == vs2.size() and not vs.is_empty()
	for i in vs.size():
		same = same and vs2[i].is_equal_approx(xf * vs[i])
	_check("transformed: позиции переведены матрицей", same)
	_check("transformed: нормали повёрнуты (+Z стала +X)", ns2.size() == vs.size() and ns2[0].is_equal_approx(xf.basis * Vector3(0, 0, 1)))
	_check("transformed: единичная матрица оставляет данные как есть", PaintBake.transformed(surfaces, Transform3D.IDENTITY).size() == surfaces.size())

	var entries := [_entry(a), _entry(b, Transform3D(Basis.IDENTITY, Vector3(2, 0, 0)))]
	var r := PaintBake.bake_group(entries, 32)
	_check("bake_group: карта построена, оба меша в группе", r["ok"] and r["included"] == PackedInt32Array([0, 1]) and r["skipped"].is_empty())
	if not r["ok"]:
		a.free()
		b.free()
		return
	var pos: PackedFloat32Array = r["pos"]
	var ia := (8 * 32 + 8) * 4      # тексель в четверти A (u,v < 0.5)
	var ib := (8 * 32 + 24) * 4     # тексель в четверти B (u >= 0.5)
	_check("bake_group: тексель A лежит у A (x от -0.5 до 0.5)", pos[ia + 3] == 1.0 and absf(pos[ia]) <= 0.51)
	_check("bake_group: тексель B сдвинут в пространство опорного (x от 1.5 до 2.5)", pos[ib + 3] == 1.0 and pos[ib] >= 1.49 and pos[ib] <= 2.51)
	a.free()
	b.free()


# --- данные слоя и ключ кэша ---

func _png(color: Color, size := 8) -> PackedByteArray:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return img.save_png_to_buffer()


func _test_data_and_cache() -> void:
	var p := PaintData.new_paint()
	var layer := PaintData.set_texture_layer(p, "p1", "Body", 1024, "p1.png", PackedByteArray(), ["Body", "Tank", "Door"])
	_check("слой общего атласа: список мешей записан", layer["meshes"] == ["Body", "Tank", "Door"])
	_check("layer_meshes: из поля meshes", _same(PaintData.layer_meshes(layer), ["Body", "Tank", "Door"]))
	var legacy := {"mesh": "Body"}
	_check("layer_meshes: старый слой с одним mesh", _same(PaintData.layer_meshes(legacy), ["Body"]))
	_check("layer_meshes: пустой слой не роняет", PaintData.layer_meshes({}).is_empty())
	var one := PaintData.set_texture_layer(PaintData.new_paint(), "p1", "Body", 1024)
	_check("слой без списка не пишет поле meshes", not one.has("meshes"))

	PaintLayers.clear_cache()
	var png := _png(Color(1, 0, 0, 1))
	PaintData.set_texture_layer(p, "p1", "Body", 8, "", png, ["Body", "Tank", "Door"])
	var ov := PaintLayers.overlays_from({"paint": p})
	var tex: Variant = ov["Body"].get_shader_parameter("layer") if ov.has("Body") else null
	_check("overlays_from: накладка на каждый меш слоя, текстура общая", ov.size() == 3 and tex != null
		and ov["Tank"].get_shader_parameter("layer") == tex and ov["Door"].get_shader_parameter("layer") == tex)

	var a := png
	var b := png.duplicate()
	b[b.size() / 2] = (b[b.size() / 2] + 1) % 256     # тот же размер, другое содержимое (не PNG, нужен только ключ)
	_check("ключ кэша: одинаковая длина, но разное содержимое даёт разные ключи", a.size() == b.size() and PaintLayers._key(a) != PaintLayers._key(b))
	_check("ключ кэша: одинаковые байты дают один ключ", PaintLayers._key(a) == PaintLayers._key(png.duplicate()))
	_check("кэш: красный и зелёный PNG одного размера не делят текстуру", PaintLayers.texture_from_png(_png(Color(1, 0, 0, 1))) != PaintLayers.texture_from_png(_png(Color(0, 1, 0, 1))))


# --- движок на нескольких мешах ---

func _alpha_count(img: Image, rect: Rect2i) -> int:
	var n := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if img.get_pixel(x, y).a > 0.05:
				n += 1
	return n


func _test_engine() -> void:
	var a := _quad("A", Vector2(0, 0), true, 2)    # опорный: больше вершин
	var b := _quad("B", Vector2(0.5, 0))           # дочерний, общий атлас
	var d := _quad("D", Vector2(0, 0))             # дочерний, перекрывает атлас A
	var c := _quad("C", Vector2.ZERO, false)       # без UV2: закрывает B спереди
	add_child(a)
	a.add_child(b)
	b.position = Vector3(2, 0, 0)
	a.add_child(d)
	d.position = Vector3(4, 0, 0)
	add_child(c)
	c.position = Vector3(2, 0, 1)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	add_child(cam)
	cam.position = Vector3(2, 0, 5)
	cam.current = true
	await _frames(2)

	var eng := PaintEngine.new()
	add_child(eng)
	var ok := await eng.setup([a, b, d], RES, [c])
	_check("setup на трёх мешах: карта построена (покрыто %d)" % eng.bake_info.get("covered", 0), ok and eng.is_built)
	if not ok:
		return
	_check("опорный меш A, в группе A и B", eng.target == a and eng.meshes.size() == 2 and eng.meshes[0] == a and eng.meshes[1] == b)
	_check("D перекрывает атлас: пропущен", eng.skipped.size() == 1 and eng.skipped[0] == d and _same(eng.skipped_names(), ["D"]))
	_check("имена мешей группы", _same(eng.mesh_names(), ["A", "B"]))
	_check("габарит группы по обоим мешам (x от -0.5 до 2.5)", is_equal_approx(eng.size_ref, 3.0))

	var mouse := get_viewport().get_visible_rect().size * 0.5
	_check("мазок по B закрыт видимым мешом без UV2", eng.raycast(cam, mouse).is_empty())
	c.visible = false
	var hit := eng.raycast(cam, mouse)
	_check("скрытый закрывающий меш не мешает: попали в B", not hit.is_empty() and hit["mesh"] == b)
	if hit.is_empty():
		return
	_check("попадание в пространстве опорного меша (x = 2) с нормалью +Z", (hit["position"] as Vector3).is_equal_approx(Vector3(2, 0, 0)) and (hit["normal"] as Vector3).dot(Vector3(0, 0, 1)) > 0.99)

	eng.begin_stroke()
	eng.stamp(hit["position"], hit["normal"], eng.radius_for(0.3), Color(1, 0, 0), 1.0, 0.5)
	eng.end_stroke()
	await _frames(6)
	var img := eng.read_layer()
	var half := RES / 2
	var in_b := _alpha_count(img, Rect2i(half, 0, half, half))
	var in_a := _alpha_count(img, Rect2i(0, 0, half, half))
	_check("штамп на дочернем меше красит его четверть атласа (%d текселей)" % in_b, in_b > 200)
	_check("опорный меш A мазком по B не тронут", in_a == 0)

	# C2.2: цвет слоя без искажений (слой 16 бит), форма штампа, сухая кисть. Центр B в текселях (48, 16), угол (57, 6)
	eng.clear()
	await _frames(6)
	var pos: Vector3 = hit["position"]
	var nrm: Vector3 = hit["normal"]
	eng.begin_stroke()
	eng.stamp(pos, nrm, 0.4, Color(0.5, 0.25, 0.75), 1.0, 0.99)
	eng.end_stroke()
	await _frames(6)
	img = eng.read_layer()
	var mid := img.get_pixel(48, 16)
	_check("слой хранит цвет как есть: центр штампа (0.5, 0.25, 0.75) при полной альфе", absf(mid.r - 0.5) < 0.02 and absf(mid.g - 0.25) < 0.02 and absf(mid.b - 0.75) < 0.02 and mid.a > 0.97)
	_check("круглый штамп радиуса 0.4 угла квадрата (0.3, 0.3) не достаёт", img.get_pixel(57, 6).a < 0.05)
	eng.begin_stroke()
	eng.stamp(pos, nrm, 0.4, Color(0, 1, 0), 1.0, 0.99, false, {"shape": "box", "box": Vector2.ONE, "tan": Vector3(0, 1, 0), "load": 1.0})
	eng.end_stroke()
	await _frames(6)
	var corner := eng.read_layer().get_pixel(57, 6)
	_check("квадратный штамп того же радиуса красит угол", corner.a > 0.5 and corner.g > 0.8)

	var dry_opts := {"tip": "bristle", "shape": "box", "box": Vector2.ONE, "tan": Vector3(0, 1, 0), "load": 1.0, "dry": 0.9}
	eng.clear()
	await _frames(6)
	eng.begin_stroke()
	eng.stamp(pos, nrm, 0.45, Color(1, 0, 0), 1.0, 0.5, false, dry_opts)
	eng.end_stroke()
	await _frames(6)
	var full := _alpha_count(eng.read_layer(), Rect2i(half, 0, half, half))
	eng.clear()
	await _frames(6)
	dry_opts["load"] = 0.05
	eng.begin_stroke()
	eng.stamp(pos, nrm, 0.45, Color(1, 0, 0), 1.0, 0.5, false, dry_opts)
	eng.end_stroke()
	await _frames(6)
	var dried := _alpha_count(eng.read_layer(), Rect2i(half, 0, half, half))
	_check("щетина с полным запасом красит (%d текселей), с почти пустым заметно меньше (%d)" % [full, dried], full > 200 and dried < full / 2)

	# C2.3: образец вместо плоского цвета. Синяя краска с образцом «Ржавчина» ложится рыжей (красный канал больше синего)
	eng.clear()
	await _frames(6)
	eng.begin_stroke()
	eng.stamp(pos, nrm, 0.45, Color(0, 0, 1), 1.0, 0.99, false, {"sample": "rust", "sample_size": 0.1})
	eng.end_stroke()
	await _frames(6)
	var rust_img := eng.read_layer()
	var painted := 0
	var red_sum := 0.0
	var blue_sum := 0.0
	for y in range(0, half):
		for x in range(half, RES):
			var px := rust_img.get_pixel(x, y)
			if px.a > 0.3:
				painted += 1
				red_sum += px.r
				blue_sum += px.b
	_check("образец ржавчины: краска легла (%d текселей) цветом образца, а не синим (красный %.1f, синий %.1f)" % [painted, red_sum, blue_sum], painted > 50 and red_sum > blue_sum * 1.5)

	eng.queue_free()
	a.queue_free()
	c.queue_free()
	cam.queue_free()
	await _frames(2)


func _same(got: Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in got.size():
		if str(got[i]) != str(want[i]):
			return false
	return true


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
