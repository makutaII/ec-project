extends Node

# XX claude-track-studio (новый файл)
## Проверка шагов T2 и T3 (ATTN_20): разбор наборов текстур, сборка материала, конвертация нормали,
## генератор и нормализация меша шпалы. Запуск: открыть tests/track_lib_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «TrackLib: n/m». Файлы набора не меняются (временные файлы в user://track_lib_test).

const SETS := "res://data/textures/track"
const TMP := "user://track_lib_test"
const EPS := 0.002

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_scan_real_sets()
	_test_scan_names()
	_test_build_material()
	_test_dx_to_gl()
	_test_generator()
	_test_normalize()
	_test_style_set_io()
	_test_budget()
	_test_parts()
	print("TrackLib: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


# --- T2: наборы ---

func _test_scan_real_sets() -> void:
	var sets := TrackMaterialBuilder.list_sets(SETS)
	print("наборы: ", sets)
	for s in sets:
		var f := TrackMaterialBuilder.scan(SETS.path_join(s))
		var keys := []
		for k in f:
			keys.append(k)
		print("  %s: %s" % [s, keys])
		if s.ends_with("_1K-JPG"):
			_check("%s: цвет, нормаль GL, шероховатость найдены" % s,
				f.has("albedo") and f.has("normal") and f.has("roughness") and f.get("normal_is_dx", true) == false)
			_check("%s: IdMask и превью не приняты за карты" % s, not f.has("idmask") and String(f.get("albedo", "")).contains("_Color"))
	if sets.has("Metal007_1K-JPG"):
		var m := TrackMaterialBuilder.scan(SETS.path_join("Metal007_1K-JPG"))
		_check("Metal007: есть карта металличности, нет AO", m.has("metallic") and not m.has("ao"))
	if sets.has("Sleeper_01v1"):
		var sl := TrackMaterialBuilder.scan(SETS.path_join("Sleeper_01v1"))
		_check("Sleeper_01v1 (свои имена): цвет, нормаль, шероховатость, металличность, AO",
			sl.has("albedo") and sl.has("normal") and sl.has("roughness") and sl.has("metallic") and sl.has("ao"))
	if sets.has("Gravel023_1K-JPG"):
		var info := TrackMaterialBuilder.import_info(String(TrackMaterialBuilder.scan(SETS.path_join("Gravel023_1K-JPG"))["normal"]))
		_check("import_info читает .import нормали", info["ok"])


func _test_scan_names() -> void:
	DirAccess.make_dir_recursive_absolute(TMP + "/ph")
	for n in ["rock_diff_1k.jpg", "rock_nor_gl_1k.jpg", "rock_nor_dx_1k.jpg", "rock_rough_1k.jpg", "rock_arm_1k.jpg", "rock_disp_1k.png", "readme.txt"]:
		var fa := FileAccess.open(TMP + "/ph/" + n, FileAccess.WRITE)
		fa.store_8(0)
		fa.close()
	var f := TrackMaterialBuilder.scan(TMP + "/ph")
	_check("Poly Haven имена: цвет, нормаль GL (не DX), шероховатость, ORM, высота",
		f.has("albedo") and f.has("roughness") and f.has("orm") and f.has("height")
		and String(f["normal"]).contains("nor_gl") and f["normal_is_dx"] == false)
	DirAccess.make_dir_recursive_absolute(TMP + "/dx")
	var fb := FileAccess.open(TMP + "/dx/wall_NormalDX.jpg", FileAccess.WRITE)
	fb.store_8(0)
	fb.close()
	var g := TrackMaterialBuilder.scan(TMP + "/dx")
	_check("только NormalDX: нормаль найдена и помечена как DX", g.has("normal") and g["normal_is_dx"] == true)


func _test_build_material() -> void:
	var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
	var t := ImageTexture.create_from_image(img)
	var tex := {"albedo": t, "normal": t, "roughness": t, "ao": t}
	var ballast := TrackMaterialBuilder.build(tex, TrackMaterialBuilder.preset("ballast"))
	_check("ballast: нормаль включена, AO включено, металличность 0 без карты",
		ballast.normal_enabled and ballast.ao_enabled and is_equal_approx(ballast.metallic, 0.0))
	_check("ballast: фильтр с мипмапами и анизотропией",
		ballast.texture_filter == BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC)
	var tex2 := tex.duplicate()
	tex2["metallic"] = t
	var rail := TrackMaterialBuilder.build(tex2, TrackMaterialBuilder.preset("rail"))
	_check("rail: металличность 1 при карте, AO выключено пресетом", is_equal_approx(rail.metallic, 1.0) and not rail.ao_enabled)
	var sl := TrackMaterialBuilder.preset("sleeper")
	sl["triplanar"] = true
	sl["mesh_uv_units"] = false
	sl["tile"] = Vector2(2.0, 2.0)
	var sm := TrackMaterialBuilder.build(tex, sl)
	_check("sleeper triplanar: uv1_triplanar и масштаб 1/тайл", sm.uv1_triplanar and is_equal_approx(sm.uv1_scale.x, 0.5))
	var gen := TrackMaterialBuilder.preset("sleeper")
	gen["tile"] = Vector2(4.0, 4.0)
	var gm := TrackMaterialBuilder.build(tex, gen)
	_check("sleeper по умолчанию: UV в ю, без triplanar, цвет вершин включён",
		not gm.uv1_triplanar and is_equal_approx(gm.uv1_scale.x, 0.25) and gm.vertex_color_use_as_albedo)
	var orm := TrackMaterialBuilder.build({"albedo": t, "orm": t}, TrackMaterialBuilder.preset("ballast"))
	_check("ORM: каналы AO=R, rough=G, metal=B",
		orm.ao_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_RED
		and orm.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		and orm.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE)
	# реальный набор: текстуры грузятся и материал собирается
	var found := TrackMaterialBuilder.scan(SETS.path_join("Gravel023_1K-JPG"))
	if not found.is_empty():
		var real := TrackMaterialBuilder.build(TrackMaterialBuilder.load_textures(found), TrackMaterialBuilder.preset("ballast"))
		_check("Gravel023: материал с цветом, нормалью и шероховатостью", real.albedo_texture != null and real.normal_texture != null and real.roughness_texture != null)


func _test_dx_to_gl() -> void:
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(Color8(100, 10, 200))
	DirAccess.make_dir_recursive_absolute(TMP)
	img.save_png(TMP + "/x_NormalDX.png")
	var out := TrackMaterialBuilder.convert_dx_to_gl(TMP + "/x_NormalDX.png")
	var ok := false
	if not out.is_empty():
		var r := Image.load_from_file(out)
		var px := r.get_pixel(0, 0)
		ok = absi(roundi(px.g8) - 245) <= 1 and absi(roundi(px.r8) - 100) <= 1 and absi(roundi(px.b8) - 200) <= 1
	_check("DX -> GL: зелёный канал инвертирован, остальные нет", ok)


# --- T3: шпалы ---

@warning_ignore("integer_division")
func _test_generator() -> void:
	var wood := TrackSleeperFactory.generate({})
	var a := wood.get_aabb()
	var base_tris := wood.get_faces().size() / 3
	_check("корпус: размер 3 × 0.2 × 0.3", _near(a.size, Vector3(3.0, 0.2, 0.3)))
	_check("корпус: центр опоры в 0, низ на 0", absf(a.get_center().x) < EPS and absf(a.get_center().z) < EPS and absf(a.position.y) < EPS)
	_check("корпус: одна поверхность, 32 треугольника, без вершинного цвета", wood.get_surface_count() == 1 and base_tris == 32 and wood.surface_get_arrays(0)[Mesh.ARRAY_COLOR] == null)
	_check("рельеф 0: лишних рёбер нет (те же 32 треугольника)",
		TrackSleeperFactory.generate({"top_dip": 0.0, "end_slope": 0.0}).get_faces().size() / 3 == base_tris)

	var trap := TrackSleeperFactory.generate({"profile": "trapezoid"})
	_check("трапеция: тот же габарит, треугольников 24 (6 граней)", _near(trap.get_aabb().size, Vector3(3.0, 0.2, 0.3)) and trap.get_faces().size() / 3 == 24)

	# площадки на любом сечении
	for prof in ["rect", "trapezoid"]:
		var pm := TrackSleeperFactory.generate({"profile": prof, "pads": true, "rail_x": 0.875, "pad_x": 0.875})
		_check("площадки на сечении %s: высота 0.22, +24 треугольника" % prof,
			absf(pm.get_aabb().size.y - 0.22) < EPS and pm.get_faces().size() / 3 == TrackSleeperFactory.generate({"profile": prof}).get_faces().size() / 3 + 24)
	var padded := TrackSleeperFactory.generate({"pads": true, "pad_color": Color(1, 0, 0)})
	var cols = padded.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var white := 0
	var red := 0
	if cols != null:
		for c in (cols as PackedColorArray):
			if c.is_equal_approx(Color.WHITE):
				white += 1
			elif c.r > 0.9 and c.g < 0.1:
				red += 1
	_check("площадки: вершинный цвет (корпус белый, площадки заданного цвета), одна поверхность", white > 0 and red == 72 and padded.get_surface_count() == 1)

	# рельс на корпусе при включённых площадках
	var seat := TrackSleeperFactory.generate({"pads": true, "pad_lifts_rail": false})
	var st_seat := TrackStyle.new()
	st_seat.sleeper_mesh = seat
	var st_lift := TrackStyle.new()
	st_lift.sleeper_mesh = padded
	_check("pad_lifts_rail = false: постель рельса 0.2 при AABB 0.22", absf(st_seat.sleeper_dims().y - 0.2) < EPS and absf(seat.get_aabb().size.y - 0.22) < EPS)
	_check("pad_lifts_rail = true: рельс на площадке, постель 0.22", absf(st_lift.sleeper_dims().y - 0.22) < EPS)

	# рельеф
	var dip := TrackSleeperFactory.generate({"top_dip": 0.03})
	_check("прогиб верха: треугольников больше, габарит прежний", dip.get_faces().size() / 3 > base_tris and _near(dip.get_aabb().size, Vector3(3.0, 0.2, 0.3)))
	var slope := TrackSleeperFactory.generate({"end_slope": 0.03})
	_check("скос к краю: треугольников больше, габарит прежний (верх у площадок на полной высоте)", slope.get_faces().size() / 3 > base_tris and _near(slope.get_aabb().size, Vector3(3.0, 0.2, 0.3)))
	# у торца верх опущен на высоту скоса: у вершин торца (x = 1.5) нет точек выше 0.17
	var sv: PackedVector3Array = slope.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var end_top := 0.0
	for v in sv:
		if absf(v.x - 1.5) < 0.0001:
			end_top = maxf(end_top, v.y)
	_check("скос к краю: верх у торца ниже на 0.03", absf(end_top - 0.17) < EPS)
	var no_room := TrackSleeperFactory.generate({"end_slope": 0.03, "pad_x": 1.45, "pad_length": 0.4})
	_check("скос не создаётся, если площадка доходит до края", no_room.get_faces().size() / 3 == base_tris)
	var both := TrackSleeperFactory.generate({"top_dip": 0.03, "end_slope": 0.03, "profile": "trapezoid", "pads": true})
	_check("прогиб, скос, площадки и трапеция вместе строятся", both.get_faces().size() > 0 and both.get_surface_count() == 1)
	var dip_only := TrackSleeperFactory.generate({"top_dip": 0.03}).get_faces().size()
	_check("прогиб и скос складываются: вместе треугольников больше, чем у одного прогиба", dip_only < TrackSleeperFactory.generate({"top_dip": 0.03, "end_slope": 0.03}).get_faces().size())

	# UV
	var uv_a: PackedVector2Array = TrackSleeperFactory.generate({}).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var uv_b: PackedVector2Array = TrackSleeperFactory.generate({"uv_rotate": true}).surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var swapped := uv_a.size() == uv_b.size() and uv_a.size() > 0
	for i in mini(uv_a.size(), uv_b.size()):
		if not is_equal_approx(uv_a[i].x, uv_b[i].y) or not is_equal_approx(uv_a[i].y, uv_b[i].x):
			swapped = false
			break
	_check("uv_rotate: u и v поменялись местами", swapped)

	# контракт и валидатор
	var st := TrackStyle.new()
	st.sleeper_mesh = wood
	var bad := 0
	for m in TrackStyleValidator.validate(st):
		if m["level"] >= TrackStyleValidator.Level.WARN:
			bad += 1
	_check("валидатор: сгенерированная шпала без замечаний", bad == 0)
	var padded_style := TrackStyle.new()
	padded_style.sleeper_mesh = TrackSleeperFactory.generate({"pads": true, "pad_lifts_rail": false, "top_dip": 0.03, "end_slope": 0.03})
	var bad2 := 0
	for m in TrackStyleValidator.validate(padded_style):
		if m["level"] >= TrackStyleValidator.Level.WARN:
			bad2 += 1
	_check("валидатор: шпала с площадками и рельефом без замечаний", bad2 == 0)
	# нормали наружу: у верхней грани нормаль вверх
	var arrays := wood.surface_get_arrays(0)
	var up := 0
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in verts.size():
		if absf(verts[i].y - 0.2) < 0.0001 and norms[i].y > 0.9:
			up += 1
	_check("корпус: у вершин верха нормаль вверх", up >= 4)
	# в рельефе нормали тоже наружу: у вершин низа нет нормалей вверх
	for mesh in [dip, slope]:
		var rv: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var rn: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
		var inward := 0
		for i in rv.size():
			if rv[i].y < 0.0001 and rn[i].y > 0.5:
				inward += 1
		_check("рельеф: у вершин низа нет нормалей вверх", inward == 0)


func _test_normalize() -> void:
	var src := TrackSleeperFactory.generate({})
	# «неправильный» меш: в сантиметрах, повёрнут на 90°, смещён
	var bad_xf := Transform3D(Basis(Vector3.UP, PI * 0.5).scaled(Vector3.ONE * 100.0), Vector3(10.0, 7.0, -3.0))
	var res := TrackSleeperFactory.normalize([{"mesh": src, "xform": bad_xf}], {"scale": 0.01})
	var mesh: ArrayMesh = res["mesh"]
	var a := mesh.get_aabb()
	_check("normalize: размер 3 × 0.2 × 0.3 после масштаба и авто-поворота", _near(a.size, Vector3(3.0, 0.2, 0.3)))
	_check("normalize: центр опоры в 0, низ на 0", absf(a.get_center().x) < EPS and absf(a.get_center().z) < EPS and absf(a.position.y) < EPS)
	_check("normalize: в отчёте есть заметка о повороте", (res["report"]["notes"] as PackedStringArray).size() >= 1)
	var merged := TrackSleeperFactory.normalize([{"mesh": TrackSleeperFactory.generate({"profile": "trapezoid", "pads": true}), "xform": Transform3D.IDENTITY}], {"merge": true})
	_check("normalize: слияние даёт одну поверхность", (merged["mesh"] as ArrayMesh).get_surface_count() == 1)


func _test_style_set_io() -> void:
	var set_ := TrackStyleSet.new()
	var a := TrackStyle.new()
	a.id = &"zz_test_a"
	a.take_over_path("res://data/tracks/styles/zz_test_a.tres")   # путь только в памяти, файл не создаётся
	var b := TrackStyle.new()
	b.id = &"zz_test_a"   # тот же id, другой файл
	b.take_over_path("res://data/tracks/styles/zz_test_b.tres")
	var scene_style := TrackStyle.new()
	scene_style.id = &"zz_test_scene"
	scene_style.use_scene = true
	var r := TrackStyleSetIO.check_add(set_, a, a.resource_path)
	_check("набор стилей: новый стиль можно добавить", r["ok"] and not r["already"])
	set_.styles.append(a)
	r = TrackStyleSetIO.check_add(set_, a, a.resource_path)
	_check("набор стилей: тот же файл уже в наборе", r["ok"] and r["already"])
	r = TrackStyleSetIO.check_add(set_, b, b.resource_path)
	_check("набор стилей: тот же id из другого файла отклонён", not r["ok"] and String(r["error"]).contains("zz_test_a"))
	r = TrackStyleSetIO.check_add(set_, scene_style, "res://data/tracks/styles/zz_test_scene.tres")
	_check("набор стилей: стиль-сцена отклонён", not r["ok"])
	r = TrackStyleSetIO.check_add(set_, a, "")
	_check("набор стилей: без файла отклонён", not r["ok"])
	var broken := TrackStyleSet.new()
	broken.styles.append(a)
	broken.styles.append(b)
	_check("набор стилей: проверка находит повтор id", not broken.validate().is_empty())


func _test_budget() -> void:
	var b := TrackStyleValidator.budget(TrackStyle.new())
	_check("бюджет: меш, шпалы и всего считаются", not b.is_empty() and b["mesh"] > 0 and b["sleepers"] > 0 and b["total"] == b["mesh"] + b["sleepers"])
	_check("бюджет: шпал на 10 ю порядка 10/0.7", b["sleeper_count"] >= 13 and b["sleeper_count"] <= 16)
	var st := TrackStyle.new()
	st.sleeper_mesh = TrackSleeperFactory.generate({})
	var b2 := TrackStyleValidator.budget(st)
	_check("бюджет: у меша шпалы 32 треугольника на штуку", b2["per_sleeper"] == 32)


## Части трака: rail_enabled и sleeper_enabled только визуал, высота и коллизии те же
func _test_parts() -> void:
	var curve := Curve3D.new()
	curve.add_point(Vector3.ZERO)
	curve.add_point(Vector3(0.0, 0.0, -10.0))
	var full := TrackStyle.new()
	var no_rail := TrackStyle.new()
	no_rail.rail_enabled = false
	var no_sleeper := TrackStyle.new()
	no_sleeper.sleeper_enabled = false

	_check("части: по умолчанию всё включено, индекс рельса 1 (с балластом)", full.has_any_part() and full.rail_surface_index() == 1)
	_check("части: рельс выключен, индекс поверхности -1", no_rail.rail_surface_index() == -1)
	var flat := TrackStyle.new()
	flat.ballast_enabled = false
	_check("части: без балласта индекс рельса 0", flat.rail_surface_index() == 0)

	_check("части: рельс выключен, меш только балласт (1 поверхность вместо 2)",
		TrackMeshBuilder.build_mesh(full, curve, 10.0, false).get_surface_count() == 2
		and TrackMeshBuilder.build_mesh(no_rail, curve, 10.0, false).get_surface_count() == 1)
	var sleepers_only := TrackStyle.new()
	sleepers_only.ballast_enabled = false
	sleepers_only.rail_enabled = false
	_check("части: без балласта и рельсов меш пустой, но строится", TrackMeshBuilder.build_mesh(sleepers_only, curve, 10.0, false).get_surface_count() == 0)

	_check("части: head_height и base_height не зависят от rail_enabled и sleeper_enabled",
		is_equal_approx(full.head_height(), no_rail.head_height()) and is_equal_approx(full.head_height(), no_sleeper.head_height())
		and is_equal_approx(full.base_height(), no_sleeper.base_height()))

	var L := curve.get_baked_length()
	var a := TrackMeshBuilder.segment_boxes(full, curve, L, 0.0, L)
	var b := TrackMeshBuilder.segment_boxes(no_rail, curve, L, 0.0, L)
	var c := TrackMeshBuilder.segment_boxes(no_sleeper, curve, L, 0.0, L)
	_check("части: коллизия рельсов (боксы) та же при выключенном рельсе",
		a.rail_size.is_equal_approx(b.rail_size) and a.rail_l_xf.is_equal_approx(b.rail_l_xf) and a.rail_r_xf.is_equal_approx(b.rail_r_xf)
		and a.ballast_size.is_equal_approx(b.ballast_size) and a.ballast_xf.is_equal_approx(b.ballast_xf))
	_check("части: коллизия та же при выключенных шпалах",
		a.rail_size.is_equal_approx(c.rail_size) and a.rail_l_xf.is_equal_approx(c.rail_l_xf) and a.ballast_size.is_equal_approx(c.ballast_size))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	TrackMeshBuilder.place_sleepers(mm, no_sleeper, curve, L)
	_check("части: шпалы выключены, instance_count = 0", mm.instance_count == 0)
	TrackMeshBuilder.place_sleepers(mm, full, curve, L)
	_check("части: шпалы включены, шпалы расставлены", mm.instance_count > 0)

	var none := TrackStyle.new()
	none.ballast_enabled = false
	none.sleeper_enabled = false
	none.rail_enabled = false
	_check("части: ни одной части = нельзя строить и ошибка проверки",
		not none.has_any_part() and not TrackStyleValidator.can_build(none)
		and TrackStyleValidator.validate(none).any(func(e: Dictionary) -> bool: return e.level == TrackStyleValidator.Level.ERROR))
	_check("части: выключенный рельс не даёт ошибок проверки",
		not TrackStyleValidator.validate(no_rail).any(func(e: Dictionary) -> bool: return e.level == TrackStyleValidator.Level.ERROR))
	var bud := TrackStyleValidator.budget(no_sleeper)
	_check("части: бюджет без шпал не считает шпалы", bud["sleeper_count"] == 0 and bud["sleepers"] == 0)


func _near(a: Vector3, b: Vector3) -> bool:
	return (a - b).length() < EPS


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
