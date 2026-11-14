extends Node

# XX claude-library L7 (новый файл)
## Проверка шага L7 (ATTN_22 §22.7.6): генератор зданий. Спецификация, раскладка окон и двери, меш, детерминизм,
## свет окон, сущность из building_gen.tres (коллизия, variant, перестройка на месте).
## Запуск: открыть tests/building_gen_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Building gen: n/m». Сцена закрывается сама с кодом 0 (всё прошло) или 1.

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_spec()
	_test_layout_rect()
	_test_layout_l()
	_test_mesh()
	_test_determinism()
	_test_lights()
	await _test_entity()
	print("Building gen: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _check(label: String, cond: bool, detail := "") -> void:
	_all += 1
	if cond:
		_ok += 1
	print("%s %s %s" % ["PASS" if cond else "FAIL", label, detail])


# --- спецификация ---

func _test_spec() -> void:
	var s := BuildingSpec.new().sanitize()
	_check("spec: по умолчанию допустим", s.shape == BuildingSpec.Shape.RECT and s.floors == 2 and BuildingStyles.has_style(s.style))
	var back := BuildingSpec.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	_check("spec: круг to_dict, JSON, from_dict", back.equals(s))

	var bad := BuildingSpec.from_dict({"width": 999, "depth": -5, "floors": 50, "floor_h": "abc", "pitch": 9.0,
		"style": "нет_такого", "shape": 7, "roof": null, "seed": -3, "door_wall": -9})
	_check("spec: мусор зажимается в допустимое", is_equal_approx(bad.width, BuildingSpec.SIZE_MAX) and is_equal_approx(bad.depth, BuildingSpec.SIZE_MIN)
		and bad.floors == BuildingSpec.FLOORS_MAX and is_equal_approx(bad.floor_h, 3.0) and is_equal_approx(bad.pitch, BuildingSpec.PITCH_MAX)
		and bad.style == BuildingStyles.DEFAULT and bad.shape == BuildingSpec.Shape.RECT and bad.seed_id == 0 and bad.door_wall == -1)
	_check("spec: пустой словарь и не-словарь дают здание по умолчанию",
		BuildingSpec.from_dict({}).equals(s) and BuildingSpec.from_variant({}).equals(s) and BuildingSpec.from_variant({"building": 5}).equals(s))

	var l := BuildingSpec.from_dict({"shape": "l", "width": 6.0, "depth": 12.0})
	_check("spec: L при стороне меньше %.0f становится прямоугольником" % BuildingSpec.L_MIN_SIZE, l.shape == BuildingSpec.Shape.RECT)
	var l2 := BuildingSpec.from_dict({"shape": "l", "width": 12.0, "depth": 9.0, "notch_w": 50.0, "notch_d": 0.1})
	_check("spec: вырез L зажат, остаётся стена не меньше %.0f" % BuildingSpec.NOTCH_LEFT_MIN,
		l2.shape == BuildingSpec.Shape.L and is_equal_approx(l2.notch_w, 12.0 - BuildingSpec.NOTCH_LEFT_MIN) and is_equal_approx(l2.notch_d, BuildingSpec.NOTCH_MIN))

	var ext := BuildingSpec.from_dict({"future_field": [1, 2], "v": 5})
	var d := ext.to_dict()
	_check("spec: неизвестное поле и версия не теряются", d.get("future_field") == [1, 2] and int(d["v"]) == 5)

	var nx := s.with_next_seed()
	_check("spec: другой вариант меняет только сид", nx.seed_id != s.seed_id and is_equal_approx(nx.width, s.width) and nx.floors == s.floors)
	var dup := s.duplicate_spec()
	dup.floors = 3
	_check("spec: копия независима", s.floors == 2 and dup.floors == 3)


# --- раскладка ---

func _poly_has_point(poly: PackedVector2Array, p: Vector2) -> bool:
	return Geometry2D.is_point_in_polygon(p, poly)


func _check_layout(tag: String, lay: BuildingLayout) -> void:
	var n := lay.edges.size()
	var closed := true
	var outward := true
	for i in n:
		var e := lay.edges[i]
		if not e.b.is_equal_approx(lay.edges[(i + 1) % n].a):
			closed = false
		var mid := (e.a + e.b) * 0.5
		if _poly_has_point(lay.poly, mid + e.normal * 0.1) or not _poly_has_point(lay.poly, mid - e.normal * 0.1):
			outward = false
	_check(tag + ": контур замкнут, нормали рёбер наружу", closed and outward)

	var inside := true
	var no_overlap := true
	var margin_ok := true
	var doors := 0
	for i in lay.openings.size():
		var o := lay.openings[i]
		var e := lay.edges[o.edge]
		if o.kind == BuildingLayout.Kind.DOOR:
			doors += 1
		var l := o.u - o.width * 0.5
		var r := o.u + o.width * 0.5
		if l < 0.5 or r > e.length - 0.5:
			margin_ok = false
		if o.y0 < 0.0:
			inside = false
		if o.kind != BuildingLayout.Kind.ATTIC and o.y0 + o.height > lay.wall_h:
			inside = false
		for j in range(i + 1, lay.openings.size()):
			var p := lay.openings[j]
			if p.edge != o.edge:
				continue
			var same_band := o.y0 < p.y0 + p.height and p.y0 < o.y0 + o.height
			if same_band and absf(o.u - p.u) < (o.width + p.width) * 0.5:
				no_overlap = false
	_check(tag + ": проёмы не ближе 0.5 к углу, не ниже земли, не выше карниза", margin_ok and inside)
	_check(tag + ": проёмы не перекрываются", no_overlap)
	_check(tag + ": одна дверь", doors == 1)
	if doors == 1:
		var de := lay.edges[lay.door_edge]
		_check(tag + ": дверь на стене, обращённой к -Z", de.normal.y < -0.9)

	var attic_ok := true
	for o in lay.openings:
		if o.kind != BuildingLayout.Kind.ATTIC:
			continue
		# слуховое окно целиком в треугольнике хотя бы одного из фронтонов
		var top := o.y0 + o.height - lay.wall_h
		var found := false
		for p in lay.pieces:
			var tri_w := p.span * (1.0 - top / p.rise)
			if top < p.rise and tri_w >= o.width + 0.4:
				found = true
		if not found:
			attic_ok = false
	_check(tag + ": слуховые окна помещаются во фронтон", attic_ok)


func _test_layout_rect() -> void:
	var spec := BuildingSpec.new().sanitize()
	var lay := BuildingLayout.build(spec)
	_check("rect: 4 ребра, 1 плечо, 1 скат", lay.edges.size() == 4 and lay.arms.size() == 1 and lay.pieces.size() == 1)
	_check("rect: высота стен = этажи * высота этажа", is_equal_approx(lay.wall_h, 6.0))
	_check_layout("rect", lay)
	var wins := 0
	for o in lay.openings:
		if o.kind == BuildingLayout.Kind.WINDOW:
			wins += 1
	_check("rect: окна есть на всех этажах (больше 4)", wins > 4, "окон %d" % wins)

	# сиды и размеры: правила держатся не только на одном здании
	var all_ok := true
	for sd in [1, 7, 42, 999, 31337]:
		for floors in [1, 2, 4]:
			for w in [4.0, 6.0, 10.0, 24.0]:
				var sp := BuildingSpec.new()
				sp.seed_id = sd
				sp.floors = floors
				sp.width = w
				sp.depth = 5.0 if w < 8.0 else 8.0
				sp.sanitize()
				var ll := BuildingLayout.build(sp)
				for o in ll.openings:
					var e := ll.edges[o.edge]
					if o.u - o.width * 0.5 < 0.5 or o.u + o.width * 0.5 > e.length - 0.5:
						all_ok = false
	_check("rect: края проёмов в стене на сетке сидов, этажей и ширин", all_ok)

	var flat := spec.duplicate_spec()
	flat.roof = BuildingSpec.Roof.FLAT
	var fl := BuildingLayout.build(flat)
	var attic := 0
	for o in fl.openings:
		if o.kind == BuildingLayout.Kind.ATTIC:
			attic += 1
	_check("rect: у плоской крыши скатов и слуховых окон нет", fl.pieces.is_empty() and attic == 0)


func _test_layout_l() -> void:
	var spec := BuildingSpec.from_dict({"shape": "l", "width": 12.0, "depth": 9.0, "notch_w": 4.0, "notch_d": 4.0})
	var lay := BuildingLayout.build(spec)
	_check("L: 6 рёбер, 2 плеча, 2 ската", lay.edges.size() == 6 and lay.arms.size() == 2 and lay.pieces.size() == 2)
	var area := 0.0
	for i in lay.poly.size():
		var a := lay.poly[i]
		var b := lay.poly[(i + 1) % lay.poly.size()]
		area += a.x * b.y - b.x * a.y
	_check("L: площадь плана = прямоугольник минус вырез", is_equal_approx(absf(area) * 0.5, 12.0 * 9.0 - 4.0 * 4.0), str(absf(area) * 0.5))
	_check_layout("L", lay)
	_check("L: две коробки коллизии", lay.collision_boxes().size() == 2)


# --- меш ---

func _surface_names(mesh: ArrayMesh) -> Array[String]:
	var out: Array[String] = []
	for i in mesh.get_surface_count():
		out.append(mesh.surface_get_name(i))
	return out


## Каждое ребро замкнутого тела делят чётное число треугольников (два у одного тела, четыре у касающихся)
func _is_closed(mesh: ArrayMesh, surface_names: Array[String]) -> bool:
	var edges := {}
	for si in mesh.get_surface_count():
		if not surface_names.has(mesh.surface_get_name(si)):
			continue
		var arr := mesh.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			for k in 3:
				var a := _key(v[idx[t + k]])
				var b := _key(v[idx[t + (k + 1) % 3]])
				var ek := [a, b] if a < b else [b, a]
				edges[ek] = int(edges.get(ek, 0)) + 1
	for ek in edges:
		if int(edges[ek]) % 2 != 0:
			return false
	return not edges.is_empty()


func _key(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))


func _test_mesh() -> void:
	var specs := {
		"rect": BuildingSpec.new().sanitize(),
		"L": BuildingSpec.from_dict({"shape": "l", "width": 12.0, "depth": 9.0}),
		"flat": BuildingSpec.from_dict({"roof": "flat", "floors": 3}),
	}
	for tag in specs:
		var lay := BuildingLayout.build(specs[tag])
		var res := BuildingBuilder.build(lay)
		var mesh: ArrayMesh = res["mesh"]
		_check("mesh %s: есть поверхности wall, roof, plinth, trim, glass" % tag,
			_surface_names(mesh) == ["wall", "roof", "plinth", "trim", "glass"], str(_surface_names(mesh)))
		_check("mesh %s: у каждой поверхности материал" % tag, _all_materials(mesh))
		_check("mesh %s: стены, крыша и цоколь замкнуты" % tag, _is_closed(mesh, ["wall", "roof", "plinth"]))
		var aabb := mesh.get_aabb()
		var lim := lay.bounds().grow(specs[tag].overhang + 0.8)
		_check("mesh %s: габарит в пределах плана и крыши" % tag, lim.encloses(aabb), "%s в %s" % [aabb, lim])
		_check("mesh %s: бюджет вершин (до 6000)" % tag, int(res["vertices"]) < 6000, "вершин %d, треугольников %d" % [res["vertices"], res["triangles"]])
		_check("mesh %s: нормали единичные" % tag, _normals_ok(mesh))


func _all_materials(mesh: ArrayMesh) -> bool:
	for i in mesh.get_surface_count():
		if mesh.surface_get_material(i) == null:
			return false
	return true


func _normals_ok(mesh: ArrayMesh) -> bool:
	for si in mesh.get_surface_count():
		var nn: PackedVector3Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_NORMAL]
		for n in nn:
			if absf(n.length() - 1.0) > 0.001:
				return false
	return true


func _test_determinism() -> void:
	var a := BuildingBuilder.mesh_hash(BuildingBuilder.build(BuildingLayout.build(BuildingSpec.new().sanitize()))["mesh"])
	var b := BuildingBuilder.mesh_hash(BuildingBuilder.build(BuildingLayout.build(BuildingSpec.new().sanitize()))["mesh"])
	_check("детерминизм: один spec даёт один меш", a == b)
	var differs := false
	for sd in range(2, 12):
		var sp := BuildingSpec.new()
		sp.seed_id = sd
		sp.sanitize()
		if BuildingBuilder.mesh_hash(BuildingBuilder.build(BuildingLayout.build(sp))["mesh"]) != a:
			differs = true
	_check("детерминизм: другой сид даёт другое здание", differs)
	var sp2 := BuildingSpec.new()
	sp2.style = &"stone"
	sp2.sanitize()
	var m1: ArrayMesh = BuildingBuilder.build(BuildingLayout.build(sp2))["mesh"]
	_check("стиль меняет материал, не геометрию", BuildingBuilder.mesh_hash(m1) == a
		and m1.surface_get_material(0) != BuildingStyles.materials(BuildingStyles.DEFAULT)[0])


# --- свет ---

func _test_lights() -> void:
	var lay := BuildingLayout.build(BuildingSpec.new().sanitize())
	var lights := BuildingBuilder.make_lights(lay)
	var windows := 0
	for o in lay.openings:
		if o.kind != BuildingLayout.Kind.DOOR:
			windows += 1
	var rects := 0
	var ids := {}
	var bus := true
	for lc in lights:
		rects += lc.glow_rects.size()
		ids[lc.id] = true
		if lc.power_source != LightConfig.LightSupply.BUS or lc.rule != LightConfig.Rule.NIGHT:
			bus = false
	_check("свет: прямоугольников столько же, сколько окон", rects == windows, "%d из %d" % [rects, windows])
	_check("свет: источники с разными id, ночью, от шины", ids.size() == lights.size() and not lights.is_empty() and bus)
	var inside_pad := true
	for lc in lights:
		for gr in lc.glow_rects:
			if absf(gr.position.y) > lay.bounds().end.y or gr.size.x <= 0.0:
				inside_pad = false
	_check("свет: прямоугольники в пределах здания по высоте", inside_pad)


# --- сущность ---

func _test_entity() -> void:
	var setting := load("res://data/buildings/objects/building_gen.tres") as EntitySetting
	_check("объект: building_gen.tres читается, категория building", setting != null and setting.category == &"building" and setting.get_key() == &"building.house.building_gen")
	if setting == null:
		return
	var factory := EntityFactory.new()
	add_child(factory)

	var variant := {"building": BuildingSpec.from_dict({"shape": "l", "width": 12.0, "depth": 9.0, "floors": 3, "seed": 5}).to_dict()}
	var ent := factory.create_from_setting(setting, &"", variant)
	add_child(ent)
	await get_tree().process_frame
	await get_tree().process_frame
	var gen := ent.get_comp(C_BuildingGen) as C_BuildingGen
	_check("сущность: есть C_BuildingGen, построена по variant", gen != null and gen.spec.is_l() and gen.spec.floors == 3)
	if gen == null:
		ent.queue_free()
		factory.queue_free()
		return
	_check("сущность: корень RigidBody3D заморожен, слой trains",
		gen.rb != null and gen.rb.freeze and gen.rb.collision_layer == Global.active_layers([&"trains"]))
	_check("сущность: коллизия по плечам (2 коробки) и меш на месте", gen.layout.collision_boxes().size() == 2 and _count_shapes(gen.rb) == 2 and gen.mesh_node.mesh != null)
	_check("сущность: spec лежит в variant", BuildingSpec.from_dict(ent.variant["building"]).equals(gen.spec))

	var mech := ent.get_comp(C_Mechanisms) as C_Mechanisms
	var lamps_before := mech.get_lamps().size() if mech != null else -1
	_check("сущность: C_Mechanisms создал источники окон", mech != null and lamps_before == BuildingBuilder.make_lights(gen.layout).size() and lamps_before > 0, "ламп %d" % lamps_before)

	# перестройка на месте: меньше этажей и прямоугольник
	var nspec := gen.spec.duplicate_spec()
	nspec.shape = BuildingSpec.Shape.RECT
	nspec.floors = 1
	gen.set_spec(nspec)
	await get_tree().process_frame
	_check("перестройка: коллизия и меш пересобраны (1 коробка)", _count_shapes(gen.rb) == 1 and gen.layout.edges.size() == 4)
	_check("перестройка: variant обновлён", int(ent.variant["building"]["floors"]) == 1 and ent.variant["building"]["shape"] == "rect")
	_check("перестройка: свет пересоздан под новые стены", mech.get_lamps().size() == BuildingBuilder.make_lights(gen.layout).size())
	_check("перестройка: у корня нет лишних источников", _count_lights(gen.rb) == mech.get_lamps().size())

	# выбранный объект и призрак уходят на слой ghost
	ent.send_event("on_select_layer", {"enabled": true})
	_check("слои: выбранный на слое ghost", gen.rb.collision_layer == Global.active_layers([&"ghost"]))
	ent.send_event("on_select_layer", {"enabled": false})
	_check("слои: снятие выбора возвращает trains", gen.rb.collision_layer == Global.active_layers([&"trains"]))

	# вторая сущность из variant первой: так работают копия, призрак и сейв
	var ent2 := factory.create_from_setting(setting, &"", ent.variant)
	add_child(ent2)
	await get_tree().process_frame
	var gen2 := ent2.get_comp(C_BuildingGen) as C_BuildingGen
	_check("копия: здание из variant то же самое", gen2 != null and gen2.spec.equals(gen.spec)
		and BuildingBuilder.mesh_hash(gen2.mesh_node.mesh) == BuildingBuilder.mesh_hash(gen.mesh_node.mesh))

	# без variant: здание по умолчанию, variant наполняется
	var ent3 := factory.create_from_setting(setting)
	add_child(ent3)
	await get_tree().process_frame
	var gen3 := ent3.get_comp(C_BuildingGen) as C_BuildingGen
	_check("по умолчанию: здание создано, variant хранит его", gen3 != null and ent3.variant.has("building"))

	ent.queue_free()
	ent2.queue_free()
	ent3.queue_free()
	factory.queue_free()


func _count_shapes(root: Node) -> int:
	var n := 0
	for c in root.get_children():
		if c is CollisionShape3D and not c.is_queued_for_deletion():
			n += 1
	return n


func _count_lights(root: Node) -> int:
	var n := 0
	for c in root.get_children():
		if c is Light3D and not c.is_queued_for_deletion():
			n += 1
	return n
