class_name TunnelPortal extends RefCounted

# XX claude-terra 13.13 K5 (новый файл)
#######################
## Портал тоннеля (ATTN_13 §13.13). Чистые функции без сцены: где устья, какой проём, из каких коробок рамка.
## H7b: тот же набор коробок строит арку отдельного объекта «Портал тоннеля» (C_TunnelPortal): make_arch.
#######################
## Устье это место, где ось тоннельного трака пересекает внешний контур листа. Рамка стоит на стенке листа лицом наружу:
## две стойки, перемычка над проёмом, фаски верхних углов и два крыла под углом. В v1 рамка прямоугольная с фаской
## (арку из ступеней не построить; меш арки позже через ATTN_24). Рамка это декор: коллизии нет, в сейве только стиль.
## Стили лежат в C_Tunnel.portal; пустой стиль = портала нет.

const STYLE_NONE := &""
const STYLE_CONCRETE := &"concrete"
const STYLE_STONE := &"stone"
const STYLES: Array[StringName] = [STYLE_NONE, STYLE_CONCRETE, STYLE_STONE]
const NAMES := {&"": "нет", &"concrete": "бетон", &"stone": "камень"}
const COLORS := {&"concrete": Color(0.62, 0.62, 0.60), &"stone": Color(0.50, 0.45, 0.38)}

## Толщина стойки, перемычки и крыла (поперёк), глубина рамки наружу, ю
const POST := 0.6
const DEPTH := 0.5
const WING_LEN := 2.0
const WING_THICK := 0.3
const WING_DEG := 35.0
const LINTEL_MAX := 1.2
## Фаска верхнего угла проёма: сторона квадрата, повёрнутого на 45°
const CHAMFER := 0.7
## Объект «Портал тоннеля» (H7b): глубина арки в ю (от лицевой плоскости вглубь), толщина свода над проёмом, цвет тёмной плоскости.
## H7b2: глубина до 100 ю, тёмная плоскость стоит на своей глубине (не глубже арки); значения по умолчанию берёт паспорт (PortalConfig)
const DEPTH_MIN := 1
const DEPTH_MAX := 100
const DEPTH_DEFAULT := 5
const DARK_DEFAULT := 2.0
const DARK_STEP := 0.5
const ROOF := 0.6
const DARK_COLOR := Color(0.02, 0.02, 0.02)
## Устья ближе друг к другу, чем это (вершина контура даёт два попадания), считаем одним, ю
const MERGE := 0.3


## Следующий стиль по кругу: нет, бетон, камень
static func next_style(cur: StringName) -> StringName:
	var i := STYLES.find(cur)
	return STYLES[(i + 1) % STYLES.size()] if i >= 0 else STYLE_NONE


## Устья вдоль оси трака. samples: образцы C_Path.ballast_samples ({"l", "r", "y"}), poly: внешний контур листа в мире.
## Для каждого пересечения: {"p": Vector2 точка в мире, "out": Vector2 единичная нормаль наружу (от листа), "across": Vector2
## единичный поперёк трака, "width": ширина балласта, "lo", "hi": диапазон низа балласта на участке (как у автовыреза)}
static func mouths(samples: Array, poly: PackedVector2Array) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var n := samples.size() - 1
	var m := poly.size()
	if n < 1 or m < 3:
		return res
	for i in n:
		var a: Vector2 = ((samples[i]["l"] as Vector2) + (samples[i]["r"] as Vector2)) * 0.5
		var b: Vector2 = ((samples[i + 1]["l"] as Vector2) + (samples[i + 1]["r"] as Vector2)) * 0.5
		var seg := b - a
		if seg.length_squared() < 0.000001:
			continue
		var dir := seg.normalized()
		var y0: float = samples[i]["y"]
		var y1: float = samples[i + 1]["y"]
		for k in m:
			var hit: Variant = Geometry2D.segment_intersects_segment(a, b, poly[k], poly[(k + 1) % m])
			if hit == null:
				continue
			var p: Vector2 = hit
			# на оси сразу за точкой лист (трак заходит): наружу смотрит против хода
			var entering := Geometry2D.is_point_in_polygon(p + dir * 0.05, poly)
			var dup := false
			for r in res:
				if (r["p"] as Vector2).distance_to(p) < MERGE:
					dup = true
					break
			if dup:
				continue
			var l: Vector2 = samples[i]["l"]
			var rr: Vector2 = samples[i]["r"]
			var across := (l - rr)
			res.append({
				"p": p,
				"out": -dir if entering else dir,
				"across": across.normalized() if across.length() > 0.0001 else Vector2(-dir.y, dir.x),
				"width": across.length(),
				"lo": minf(y0, y1),
				"hi": maxf(y0, y1)})
	return res


## Проём тоннеля в устье: те же слои, что режет автовырез (C_TerrainLayer._track_cuts). base: низ листа, lv: слоёв в листе,
## T: высота слоя, body: высота трака над низом балласта с габаритом (th + tunnel_clearance), tol: underground_tolerance.
## {"floor": Y дна проёма, "vault": Y низа свода} или пусто, если свода нет (лист ниже габарита: канава) или трак листа не касается
static func opening(lo: float, hi: float, base: float, lv: int, T: float, body: float, tol: float) -> Dictionary:
	lv = maxi(1, lv)
	var top := base + float(lv) * T
	if T <= 0.0 or lo >= top - tol or hi + body <= base + 0.001:
		return {}
	var f := clampi(floori((lo - base) / T + 0.001), 0, lv - 1)
	var e := clampi(ceili((hi + body - base) / T - 0.001), f + 1, lv)
	if e >= lv:
		return {}
	return {"floor": base + float(f) * T, "vault": base + float(e) * T}


## Коробки рамки в местной системе устья: x поперёк трака, y вверх от мира, z наружу от стенки; начало в точке устья
## на оси (y = 0 это мировой 0, дальше используйте floor_y и vault_y как есть). width: ширина проёма (балласт и зазор выреза)
## Каждая коробка: {"pos": Vector3 центр, "size": Vector3, "rot_y": рад, "rot_z": рад}
static func parts(width: float, floor_y: float, vault_y: float, top_y: float) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var h := vault_y - floor_y
	if h <= 0.0 or width <= 0.0:
		return res
	var hw := width * 0.5
	var lintel := clampf(top_y - vault_y, 0.2, LINTEL_MAX)
	var a := deg_to_rad(WING_DEG)
	for s in [-1.0, 1.0]:
		var sg: float = s
		# стойка
		res.append({"pos": Vector3(sg * (hw + POST * 0.5), floor_y + h * 0.5, DEPTH * 0.5),
			"size": Vector3(POST, h, DEPTH), "rot_y": 0.0, "rot_z": 0.0})
		# фаска верхнего угла: квадрат на 45°, его половина торчит в проём
		res.append({"pos": Vector3(sg * (hw - CHAMFER * 0.25), vault_y - CHAMFER * 0.25, DEPTH * 0.5),
			"size": Vector3(CHAMFER, CHAMFER, DEPTH), "rot_y": 0.0, "rot_z": sg * PI * 0.25})
		# крыло: от внешней грани стойки наружу и в сторону; левое и правое зеркальны
		var cx := sg * (hw + POST + WING_LEN * 0.5 * cos(a))
		var cz := WING_LEN * 0.5 * sin(a)
		res.append({"pos": Vector3(cx, floor_y + h * 0.5, cz),
			"size": Vector3(WING_LEN, h, WING_THICK), "rot_y": -sg * a, "rot_z": 0.0})
	# перемычка над проёмом поверх стоек
	res.append({"pos": Vector3(0.0, vault_y + lintel * 0.5, DEPTH * 0.5),
		"size": Vector3(width + POST * 2.0, lintel, DEPTH), "rot_y": 0.0, "rot_z": 0.0})
	return res


## Узел рамки в мире: боксы по parts, стиль задаёт цвет. at: точка устья (x, z), out: нормаль наружу. Без коллизии
static func make_node(style: StringName, at: Vector2, out: Vector2, width: float, floor_y: float, vault_y: float, top_y: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Portal"
	var z := Vector3(out.x, 0.0, out.y).normalized()
	var x := Vector3.UP.cross(z).normalized()
	root.transform = Transform3D(Basis(x, Vector3.UP, z), Vector3(at.x, 0.0, at.y))
	var mat := _style_material(style)
	for part in parts(width, floor_y, vault_y, top_y):
		root.add_child(_box_node(part, mat))
	return root


## Арка объекта «Портал тоннеля» в местной системе: начало на полу в центре проёма на лицевой плоскости, x поперёк, y вверх,
## z наружу (из горы); арка уходит вглубь горы на depth ю (в -z). Лицевая рамка и крылья те же, что у рамки листа (parts), за ними
## тело арки: две стенки и свод поверх проёма. Тёмная плоскость закрывает проём на глубине dark_depth (меньше нуля: на дальнем
## конце арки; больше глубины арки: на дальнем конце). Коллизии нет (выбор объекта идёт по отдельному телу, см. C_TunnelPortal).
## Проём: width x height, пол на y = 0
static func make_arch(style: StringName, width: float, height: float, depth: float, dark_depth := -1.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Arch"
	if width <= 0.0 or height <= 0.0:
		return root
	var d := clampf(depth, float(DEPTH_MIN), float(DEPTH_MAX))
	var mat := _style_material(style)
	for part in parts(width, 0.0, height, height + ROOF):
		root.add_child(_box_node(part, mat))
	for part in body_parts(width, height, d):
		root.add_child(_box_node(part, mat))
	root.add_child(make_dark(width, height, dark_z(d, dark_depth)))
	return root


## Тёмная плоскость: z её центра при глубине dark_depth (меньше нуля или глубже арки: на дальнем конце)
static func dark_z(depth: float, dark_depth: float) -> float:
	var dd := depth if (dark_depth < 0.0 or dark_depth > depth) else dark_depth
	return -dd + 0.02


## Тёмная плоскость проёма: чёрный бокс без освещения, центр на (0, height / 2, z)
static func make_dark(width: float, height: float, z: float) -> MeshInstance3D:
	var dark := StandardMaterial3D.new()
	dark.albedo_color = DARK_COLOR
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var fm := MeshInstance3D.new()
	fm.name = "Dark"
	var fb := BoxMesh.new()
	fb.size = Vector3(width, height, 0.04)
	fm.mesh = fb
	fm.material_override = dark
	fm.position = Vector3(0.0, height * 0.5, z)
	return fm


## Коробки тела арки (за лицевой плоскостью, z от 0 до -depth): две стенки и свод. Формат как у parts
static func body_parts(width: float, height: float, depth: float) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	if width <= 0.0 or height <= 0.0 or depth <= 0.0:
		return res
	var hw := width * 0.5
	for s in [-1.0, 1.0]:
		var sg: float = s
		res.append({"pos": Vector3(sg * (hw + POST * 0.5), (height + ROOF) * 0.5, -depth * 0.5),
			"size": Vector3(POST, height + ROOF, depth), "rot_y": 0.0, "rot_z": 0.0})
	res.append({"pos": Vector3(0.0, height + ROOF * 0.5, -depth * 0.5),
		"size": Vector3(width + POST * 2.0, ROOF, depth), "rot_y": 0.0, "rot_z": 0.0})
	return res


static func _style_material(style: StringName) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLORS.get(style, COLORS[STYLE_CONCRETE])
	mat.roughness = 1.0
	return mat


static func _box_node(part: Dictionary, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = part["size"]
	mi.mesh = box
	mi.material_override = mat
	mi.position = part["pos"]
	mi.rotation = Vector3(0.0, part["rot_y"], part["rot_z"])
	return mi
