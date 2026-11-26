class_name TrackMeshBuilder extends RefCounted

# XX claude-terra
###################################
## Общий построитель визуала трака по TrackStyle и кривой. Без состояния и без нод компонента:
## только чистые функции (репер кривой, свип профиля, шпалы, границы и боксы коллизии).
## Пользуются C_FlexVisual и (позже) визуал жестких траков, чтобы не держать два кода.
## Все координаты в системе кривой C_Path (origin пути), Area3D / StaticBody3D и пул
## CollisionShape3D остаются у компонента-владельца.
###################################

const MESH_STEP := 1.0
const MESH_STEP_PREVIEW := 2.0   # пока тянем конец, меш грубее
const UV_V_SCALE := 0.1
const COL_END_INSET := 0.2
const COL_OVERLAP := 0.1

class Fr extends RefCounted:
	var p: Vector3
	var r: Vector3
	var u: Vector3
	var f: Vector3

static var _mat_ballast: StandardMaterial3D
static var _mat_rail: StandardMaterial3D
static var _mat_sleeper: StandardMaterial3D


## Пустая геометрия коллизии-заглушки: C_Path генерирует свои коллизии, только если
## у Ballast/Head нет детей. Заглушка не даёт этому сработать, пока реальные боксы не готовы.
static func new_shape(size: Vector3 = Vector3(0.01, 0.01, 0.01)) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	cs.shape = bx
	return cs


static func set_box(cs: CollisionShape3D, size: Vector3, xf: Transform3D) -> void:
	var bx := cs.shape as BoxShape3D
	if not bx.size.is_equal_approx(size):
		bx.size = size
	cs.transform = xf


## Каркас визуала трака из стиля: Mesh, Sleepers, Ballast (Area3D), HeadStaticBody3D.
## Ballast/Head получают по одной заглушке коллизии (см. new_shape). Слои как у G239:
## треки = слой 3, видят треки и призраков. Используют C_FlexVisual и C_StyleVisual,
## чтобы структура сцены была одинаковой для C_Path / C_Blockable / C_Socket.
## solid_bit (XX claude-car CS1): бит слоя основания, у рельсов 1 << 2 (tracks), у дороги слой roads (C_Path.solid_layer_bit)
static func build_skeleton(style: TrackStyle, root_name: String, solid_bit: int = 1 << 2) -> Dictionary:
	ensure_materials()
	var root := Node3D.new()
	root.name = root_name

	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "Mesh"
	root.add_child(mesh_node)

	var sleepers := create_sleepers_node(style)
	root.add_child(sleepers)

	var ballast := Area3D.new()
	ballast.name = "Ballast"
	ballast.collision_layer = solid_bit
	ballast.collision_mask = solid_bit | (1 << 10)
	root.add_child(ballast)
	var b0 := new_shape()
	ballast.add_child(b0)

	var head := StaticBody3D.new()
	head.name = "HeadStaticBody3D"
	head.collision_layer = solid_bit
	head.collision_mask = solid_bit | (1 << 10)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.0
	head.physics_material_override = pm
	root.add_child(head)
	var h0 := new_shape()
	head.add_child(h0)

	return {
		"root": root, "mesh_node": mesh_node, "sleepers": sleepers,
		"ballast": ballast, "head": head, "ballast_dummy": b0, "head_dummy": h0,
	}


static func ensure_materials() -> void:
	if _mat_ballast:
		return
	_mat_ballast = StandardMaterial3D.new()
	_mat_ballast.albedo_color = Color(0.42, 0.40, 0.37)
	_mat_ballast.roughness = 1.0
	_mat_rail = StandardMaterial3D.new()
	_mat_rail.albedo_color = Color(0.65, 0.66, 0.70)
	_mat_rail.metallic = 0.5
	_mat_rail.roughness = 0.4
	_mat_sleeper = StandardMaterial3D.new()
	_mat_sleeper.albedo_color = Color(0.30, 0.20, 0.13)
	_mat_sleeper.roughness = 0.9
	# Меши шпал могут нести вершинный цвет (подкладки другого цвета без второго материала); у BoxMesh цвета нет, множитель 1
	_mat_sleeper.vertex_color_use_as_albedo = true
	_mat_sleeper.vertex_color_is_srgb = true


# ==========================================
# Репер кривой
# ==========================================

## Крен кривой в точке s, радианы, + правый край ниже (правая тройка вокруг направления движения: «верх» уходит вправо).
## Берётся из наклона контрольных точек (Curve3D.set_point_tilt), которые у траков горок стоят через равные длины (RideShape),
## поэтому интерполяция по индексу равна линейной по длине. У остальных кривых наклон нулевой и функция даёт 0.
## XX claude-coaster C5.2
static func roll_at(curve: Curve3D, s: float, L: float) -> float:
	var n := curve.get_point_count()
	if n < 2:
		return 0.0
	var f := clampf(s / maxf(L, 0.0001), 0.0, 1.0) * float(n - 1)
	var i := mini(int(f), n - 2)
	var t0 := curve.get_point_tilt(i)
	var t1 := curve.get_point_tilt(i + 1)
	if t0 == 0.0 and t1 == 0.0:
		return 0.0
	return lerpf(t0, t1, f - float(i))


## «Верх» поверхности трака в локальных координатах кривой в точке s. Пока крена нет это ровно Vector3.UP (так вагоны
## ориентировались всегда, в том числе на подъёмах: Basis.looking_at сам берёт составляющую UP, перпендикулярную ходу),
## при крене репер с креном (frame().u). XX claude-coaster C5.3
static func surface_up_local(curve: Curve3D, s: float, L: float) -> Vector3:
	if roll_at(curve, s, L) == 0.0:
		return Vector3.UP
	return frame(curve, s, L).u


## Записывает крен в наклон контрольных точек кривой: линейно по индексу точки от roll_start_deg до roll_end_deg (градусы,
## + правый край ниже). Точки flex и траков горок стоят почти через равные длины, поэтому это линейно по длине, и roll_at
## читает то же самое. XX claude-coaster C8.2
static func apply_roll(curve: Curve3D, roll_start_deg: float, roll_end_deg: float) -> void:
	var n := curve.get_point_count()
	for i in n:
		var k := float(i) / float(maxi(n - 1, 1))
		curve.set_point_tilt(i, deg_to_rad(lerpf(roll_start_deg, roll_end_deg, k)))


## У кривой есть крен: хотя бы у одной точки ненулевой наклон
static func has_roll(curve: Curve3D) -> bool:
	for i in curve.get_point_count():
		if curve.get_point_tilt(i) != 0.0:
			return true
	return false


## Крен меняется вдоль кривой (начало и конец различаются больше чем на 0.6°): прямая с таким креном «скручивается»
static func is_twisted(curve: Curve3D, L: float) -> bool:
	return absf(roll_at(curve, 0.0, L) - roll_at(curve, L, L)) > 0.01


## Локальный репер кривой в точке s: right, up, forward (вперед = -Z на прямой).
## Крен (roll_at) поворачивает right и up вокруг направления движения; у кривых без наклона репер прежний
static func frame(curve: Curve3D, s: float, L: float) -> Fr:
	var fr := Fr.new()
	fr.p = curve.sample_baked(clampf(s, 0.0, L))
	var a := curve.sample_baked(clampf(s - 0.25, 0.0, L))
	var b := curve.sample_baked(clampf(s + 0.25, 0.0, L))
	var fwd := b - a
	if fwd.length_squared() < 1e-6:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	right = right.normalized()
	fr.f = fwd
	fr.r = right
	fr.u = right.cross(fwd).normalized()
	var roll := roll_at(curve, s, L)   # XX claude-coaster C5.2
	if roll != 0.0:
		fr.r = right.rotated(fwd, roll)
		fr.u = fr.u.rotated(fwd, roll)
	return fr


# ==========================================
# Меш: балласт (поверхность 0, если есть) и рельсы (style.rail_surface_index(), если включены)
# ==========================================

static func build_mesh(style: TrackStyle, curve: Curve3D, L: float, preview: bool) -> ArrayMesh:
	ensure_materials()
	var n := maxi(2, ceili(L / (MESH_STEP_PREVIEW if preview else MESH_STEP)) + 1)
	var fr: Array = []
	for i in n:
		fr.append(frame(curve, L * i / float(n - 1), L))

	var am := ArrayMesh.new()

	# Балласт (необязательный): поверхность 0
	if style.ballast_enabled and style.ballast_profile.size() >= 2:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var bmat: Material = style.ballast_material if style.ballast_material else _mat_ballast
		st.set_material(bmat)
		var chain: Array = []
		var hw := 0.01
		for p in style.ballast_profile:
			chain.append(p)
			hw = maxf(hw, absf(p.x))
		sweep(st, fr, chain, L, hw, style.ballast_uv_tile, style.ballast_uv_rotate)
		if _has_normal_map(bmat):
			st.generate_tangents()
		st.commit(am)

	# Рельсы: поверхность style.rail_surface_index() (1 с балластом, 0 без). rail_enabled = false: только визуал,
	# поверхности нет, а коллизия рельсов (segment_boxes) и высоты берутся из rail_profile как раньше
	if style.rail_enabled:
		var rst := SurfaceTool.new()
		rst.begin(Mesh.PRIMITIVE_TRIANGLES)
		var rmat: Material = style.rail_material if style.rail_material else _mat_rail
		rst.set_material(rmat)
		var base := style.base_height()
		for sx in [-1.0, 1.0]:
			var c: float = sx * style.rail_x
			var chain: Array = []
			for p in style.rail_profile:
				chain.append(Vector2(c + p.x, base + p.y))
			sweep(rst, fr, chain, L, style.rail_x + style.rail_width(), style.rail_uv_tile, style.rail_uv_rotate)
		if _has_normal_map(rmat):
			rst.generate_tangents()
		rst.commit(am)
	return am


## Нормальной карте нужны тангенты, SurfaceTool сам их не строит
static func _has_normal_map(mat: Material) -> bool:
	var bm := mat as BaseMaterial3D
	return bm != null and bm.normal_enabled and bm.normal_texture != null


## Протягивает ломаную профиля (слева направо поверх) вдоль реперов.
## UV: x вдоль трака, y поперек. tile (ю на тайл): по оси > 0 включает мировой масштаб (вдоль: расстояние / tile.x,
## поперёк: длина ломаной от начала / tile.y), по оси 0 остаётся прежнее (вдоль 0.1 на ю, поперёк 0..1 по hw - полуширине).
## rotate: оси UV меняются местами (текстура повёрнута на 90°)
static func sweep(st: SurfaceTool, fr: Array, chain: Array, L: float, hw: float, tile := Vector2.ZERO, rotate := false) -> void:
	var n := fr.size()
	var u_scale := 1.0 / tile.x if tile.x > 0.0 else UV_V_SCALE
	var acc := 0.0   # длина ломаной от начала до точки a
	for j in chain.size() - 1:
		var a: Vector2 = chain[j]
		var b: Vector2 = chain[j + 1]
		var d := b - a
		if d.length_squared() < 1e-8:
			continue
		var nrm := Vector2(-d.y, d.x).normalized()   # наружу
		var ua: float
		var ub: float
		if tile.y > 0.0:
			ua = acc / tile.y
			ub = (acc + d.length()) / tile.y
		else:
			ua = (a.x + hw) / (2.0 * hw)
			ub = (b.x + hw) / (2.0 * hw)
		acc += d.length()
		for i in n - 1:
			var f0: Fr = fr[i]
			var f1: Fr = fr[i + 1]
			var v0 := -L * i / float(n - 1) * u_scale
			var v1 := -L * (i + 1) / float(n - 1) * u_scale
			var n0 := (f0.r * nrm.x + f0.u * nrm.y).normalized()
			var n1 := (f1.r * nrm.x + f1.u * nrm.y).normalized()
			var p := [
				f0.p + f0.r * a.x + f0.u * a.y,
				f0.p + f0.r * b.x + f0.u * b.y,
				f1.p + f1.r * b.x + f1.u * b.y,
				f1.p + f1.r * a.x + f1.u * a.y]
			var nm := [n0, n0, n1, n1]
			# U вдоль трака, V поперек (шейдер тока едет по U)
			var uv := [Vector2(v0, ua), Vector2(v0, ub), Vector2(v1, ub), Vector2(v1, ua)]
			if rotate:   # текстура повёрнута на 90°: вдоль пути UV.y
				uv = [Vector2(ua, v0), Vector2(ub, v0), Vector2(ub, v1), Vector2(ua, v1)]
			quad(st, p, nm, uv)


## Godot: лицевая сторона - по часовой. Порядок вершин выбираем по ожидаемой нормали
static func quad(st: SurfaceTool, p: Array, nm: Array, uv: Array) -> void:
	var geo: Vector3 = (p[1] - p[0]).cross(p[2] - p[0])
	var avg: Vector3 = nm[0] + nm[1] + nm[2] + nm[3]
	var idx: Array = [0, 1, 2, 0, 2, 3]
	if geo.dot(avg) > 0.0:
		idx = [0, 2, 1, 0, 3, 2]
	for k in idx:
		st.set_normal(nm[k])
		st.set_uv(uv[k])
		st.add_vertex(p[k])


# ==========================================
# Шпалы
# ==========================================

## Нода MultiMeshInstance3D для шпал стиля (меш и материал из стиля или по умолчанию)
static func create_sleepers_node(style: TrackStyle) -> MultiMeshInstance3D:
	ensure_materials()
	var node := MultiMeshInstance3D.new()
	node.name = "Sleepers"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	if style.sleeper_mesh:
		mm.mesh = style.sleeper_mesh
		if style.sleeper_material:
			node.material_override = style.sleeper_material
		elif style.sleeper_mesh.get_surface_count() > 0 and style.sleeper_mesh.surface_get_material(0) == null:
			node.material_override = _mat_sleeper   # у меша нет своих материалов: общий вместо белого по умолчанию
	else:
		var bm := BoxMesh.new()
		bm.size = style.sleeper_size
		mm.mesh = bm
		node.material_override = style.sleeper_material if style.sleeper_material else _mat_sleeper
	node.multimesh = mm
	return node


## Шпалы: целое число с равномерным шагом (шаг чуть подстраивается под длину), каждая в центре своей доли.
## Две доли по half-step на стыке двух траков дают тот же шаг, что и внутри трака.
static func place_sleepers(mm: MultiMesh, style: TrackStyle, curve: Curve3D, L: float) -> void:
	if not style.sleeper_enabled:
		# Только визуал: размер шпалы по-прежнему задаёт base_height(), но самих шпал нет
		if mm.instance_count != 0:
			mm.instance_count = 0
		return
	var n := maxi(1, roundi(L / style.sleeper_step()))
	var step := L / float(n)
	if mm.instance_count != n:
		mm.instance_count = n
	var y0 := style.sleeper_bottom()
	if style.sleeper_mesh == null:
		y0 += style.sleeper_size.y * 0.5   # BoxMesh центрирован по высоте
	for k in n:
		var f := frame(curve, (k + 0.5) * step, L)
		var b := Basis(f.r, f.u, f.r.cross(f.u))
		mm.set_instance_transform(k, Transform3D(b, f.p + f.u * y0))


# ==========================================
# Коллизии: границы сегментов и боксы
# ==========================================

## Границы сегментов коллизии: по накопленному углу касательной и по макс. длине.
## Торцы короче трака на COL_END_INSET, чтобы стык соседей не давал overlap балласта.
## single_if_straight: у прямой (начало и конец смотрят одинаково) один сегмент на всю длину. Нарезка по
## flex_collision_step нужна гибкому траку, а у фиксированной прямой она только удваивает число форм
## (каждая форма стоит физике тика: Area3D с мониторингом на сотнях траков)
static func collision_cuts(curve: Curve3D, L: float, preview: bool, single_if_straight := false) -> PackedFloat32Array:
	var span := maxf(L - 2.0 * COL_END_INSET, 0.2)
	if single_if_straight and not is_twisted(curve, L) and frame(curve, COL_END_INSET, L).f.angle_to(frame(curve, COL_END_INSET + span, L).f) < 0.01:
		return PackedFloat32Array([COL_END_INSET, COL_END_INSET + span])
	var gs = Global.settings
	var k := 2.0 if preview else 1.0
	var deg_max := deg_to_rad(gs.track_ballast_segment.deg_per_segment) * k
	var len_max: float = gs.flex_collision_step * k
	var s_end := COL_END_INSET + span
	var cuts := PackedFloat32Array([COL_END_INSET])
	var seg_start := COL_END_INSET
	var acc := 0.0
	var prev: Vector3 = frame(curve, seg_start, L).f
	var prev_roll := roll_at(curve, seg_start, L)   # XX claude-coaster C5.2: скручивание считается как поворот
	var s := seg_start
	while s < s_end - 0.001:
		s = minf(s + 1.0, s_end)
		var cur: Vector3 = frame(curve, s, L).f
		var cur_roll := roll_at(curve, s, L)
		acc += prev.angle_to(cur) + absf(cur_roll - prev_roll)
		prev = cur
		prev_roll = cur_roll
		if acc >= deg_max or s - seg_start >= len_max:
			cuts.append(s)
			seg_start = s
			acc = 0.0
	var last := cuts[cuts.size() - 1]
	if last < s_end - 0.001:
		if cuts.size() > 1 and s_end - last < 2.0:
			cuts[cuts.size() - 1] = s_end   # короткий хвост приклеиваем к предыдущему
		else:
			cuts.append(s_end)
	return cuts


## Боксы одного сегмента [s0, s1]: основание (балласт + шпалы) и два рельса.
## Размеры это контракт трака (collision_width, base_height, rail_*), а не косметика.
## Возвращает: ballast_size, ballast_xf, rail_size, rail_l_xf, rail_r_xf
static func segment_boxes(style: TrackStyle, curve: Curve3D, L: float, s0: float, s1: float) -> Dictionary:
	var base_h := style.base_height()
	var rail_h := style.rail_height()
	var rail_w := style.rail_width()
	var rail_y := base_h + rail_h * 0.5   # середина бокса рельса по высоте над origin
	var x_l := -style.rail_x
	var x_r := style.rail_x
	if style.surface_height > 0.0:
		# XX claude-coaster C4: лоток. Основание до поверхности катания. Рельс: крошечный бокс внутри основания,
		# а у стиля с trough два бокса бортов от дна до верха борта (те же два слота: число форм на сегмент не меняется)
		base_h = style.surface_height
		rail_h = 0.01
		rail_w = 0.01
		rail_y = base_h * 0.5
		var bd := style.trough_boards()
		if bd.size() == 2:
			var lb := bd[0]
			var rb := bd[1]
			rail_w = maxf(lb.y - lb.x, rb.y - rb.x)   # размер общий для обоих: берём больший борт, позиции свои
			rail_h = maxf(lb.z, rb.z) - base_h
			rail_y = base_h + rail_h * 0.5
			x_l = (lb.x + lb.y) * 0.5
			x_r = (rb.x + rb.y) * 0.5
	var f := frame(curve, (s0 + s1) * 0.5, L)
	var chord := curve.sample_baked(s0).distance_to(curve.sample_baked(s1)) + COL_OVERLAP
	var b := Basis(f.r, f.u, f.r.cross(f.u))
	var rail_c := f.p + f.u * rail_y
	return {
		"ballast_size": Vector3(style.collision_width, base_h, chord),
		"ballast_xf": Transform3D(b, f.p + f.u * (base_h * 0.5)),
		"rail_size": Vector3(rail_w, rail_h, chord),
		"rail_l_xf": Transform3D(b, rail_c + f.r * x_l),
		"rail_r_xf": Transform3D(b, rail_c + f.r * x_r),
	}
