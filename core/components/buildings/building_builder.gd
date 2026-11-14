class_name BuildingBuilder extends RefCounted

# XX claude-library L7 (новый файл)
########################
## BuildingBuilder. Меш здания из BuildingLayout и свет окон (ATTN_22 §22.7.6, шаг L7)
########################
## Один ArrayMesh с поверхностями по материалам (BuildingStyles.Surf: стена, крыша, цоколь, отделка, стекло), как
## TrackMeshBuilder собирает трак. Здание это набор замкнутых тел, а не стена с дырами: призма стен, призма цоколя
## (шире стен на PLINTH_OUT и уходит под землю), крыша из призм по плечам плана. Окна и дверь лежат на стене рамами и
## стеклом (выступают на FRAME_D), поэтому у стен нет T-образных стыков и каждое тело замкнуто само по себе.
## Нормали плоские (по грани), UV в ю (тайл задаёт материал стиля).
## Порядок обхода: лицевой стороной в Godot считается обход по часовой стрелке, Soup.quad и Soup.tri сами
## выбирают порядок вершин по подсказке «наружу», поэтому вызывающий код порядок вершин не выверяет.

const FRAME_T := 0.09        ## ширина наличника
const FRAME_D := 0.10        ## на сколько наличник выступает из стены
const SILL_D := 0.20         ## вынос подоконника
const GLASS_OFF := 0.03      ## стекло перед стеной
const GLOW_OFF := 0.06       ## светящийся прямоугольник перед стеклом
const PLINTH_OUT := 0.06     ## на сколько цоколь шире стены
const DOOR_LEAF_D := 0.05
const STEP_D := 0.55
const SURF_NAMES := ["wall", "roof", "plinth", "trim", "glass"]

const LIGHT_COLOR := Color(1.0, 0.78, 0.45)


## Одна поверхность меша: плоские грани по вершинам, индексы по два треугольника на четырёхугольник
class Soup extends RefCounted:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	## Четырёхугольник a, b, c, d (по периметру). hint: примерно «наружу», по нему выбирается лицевая сторона
	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, hint: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
		# Лицевая нормаль треугольника (a, b, c) при обходе по часовой: cross(c - a, b - a)
		var n := (c - a).cross(b - a)
		if n.length_squared() < 1e-10:
			return
		if n.dot(hint) < 0.0:
			var tv := b
			b = d
			d = tv
			var tu := ub
			ub = ud
			ud = tu
			n = -n
		n = n.normalized()
		var base := verts.size()
		verts.append(a)
		verts.append(b)
		verts.append(c)
		verts.append(d)
		for i in 4:
			normals.append(n)
		uvs.append(ua)
		uvs.append(ub)
		uvs.append(uc)
		uvs.append(ud)
		idx.append(base)
		idx.append(base + 1)
		idx.append(base + 2)
		idx.append(base)
		idx.append(base + 2)
		idx.append(base + 3)

	func tri(a: Vector3, b: Vector3, c: Vector3, hint: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
		var n := (c - a).cross(b - a)
		if n.length_squared() < 1e-10:
			return
		if n.dot(hint) < 0.0:
			var tv := b
			b = c
			c = tv
			var tu := ub
			ub = uc
			uc = tu
			n = -n
		n = n.normalized()
		var base := verts.size()
		verts.append(a)
		verts.append(b)
		verts.append(c)
		for i in 3:
			normals.append(n)
		uvs.append(ua)
		uvs.append(ub)
		uvs.append(uc)
		idx.append(base)
		idx.append(base + 1)
		idx.append(base + 2)


## Собрать меш. Возвращает {mesh: ArrayMesh, surfaces: {Surf: индекс поверхности}, vertices, triangles}
static func build(layout: BuildingLayout) -> Dictionary:
	var soups: Array[Soup] = []
	for i in BuildingStyles.SURF_COUNT:
		soups.append(Soup.new())

	var S := BuildingStyles.Surf
	_prism(layout, soups[S.WALL], layout.poly, 0.0, layout.wall_h)
	_prism(layout, soups[S.PLINTH], layout.offset_poly(PLINTH_OUT), -BuildingLayout.SKIRT, BuildingLayout.PLINTH_H)
	if layout.spec.roof == BuildingSpec.Roof.GABLE:
		for p in layout.pieces:
			_gable(soups[S.ROOF], layout.wall_h, p, layout.spec.overhang)
	else:
		_prism(layout, soups[S.ROOF], layout.offset_poly(0.12), layout.wall_h, layout.wall_h + BuildingLayout.FLAT_ROOF_H)
	for o in layout.openings:
		match o.kind:
			BuildingLayout.Kind.DOOR:
				_door(layout, soups, o)
			BuildingLayout.Kind.ATTIC:
				_window(layout, soups, o, 0.06, 0.08)
			_:
				_window(layout, soups, o, FRAME_T, FRAME_D)

	var mesh := ArrayMesh.new()
	var mats := BuildingStyles.materials(layout.spec.style)
	var surfaces := {}
	var vcount := 0
	var tcount := 0
	for s in BuildingStyles.SURF_COUNT:
		var soup := soups[s]
		if soup.verts.is_empty():
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in soup.verts.size():
			st.set_normal(soup.normals[i])
			st.set_uv(soup.uvs[i])
			st.add_vertex(soup.verts[i])
		for i in soup.idx:
			st.add_index(i)
		st.generate_tangents()
		st.commit(mesh)
		var si := mesh.get_surface_count() - 1
		mesh.surface_set_material(si, mats[s])
		mesh.surface_set_name(si, SURF_NAMES[s])
		surfaces[s] = si
		vcount += soup.verts.size()
		tcount += int(soup.idx.size() / 3.0)
	return {"mesh": mesh, "surfaces": surfaces, "vertices": vcount, "triangles": tcount}


## Хэш геометрии (вершины и индексы всех поверхностей): для проверки детерминизма
static func mesh_hash(mesh: ArrayMesh) -> int:
	var h := 17
	for i in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(i)
		h = [h, (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).hash(), (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).hash()].hash()
	return h


# ==========================================
# Стены, цоколь, плоская крыша: призма по контуру
# ==========================================

## Призма по контуру pts (те же вершины и порядок, что у layout.poly, нормали берутся у рёбер раскладки)
static func _prism(layout: BuildingLayout, s: Soup, pts: PackedVector2Array, y0: float, y1: float) -> void:
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var nm := layout.edges[i].normal
		var hint := Vector3(nm.x, 0.0, nm.y)
		var seg := a.distance_to(b)
		s.quad(Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y), hint,
			Vector2(0.0, y0), Vector2(seg, y0), Vector2(seg, y1), Vector2(0.0, y1))
	var ids := Geometry2D.triangulate_polygon(pts)
	for k in range(0, ids.size(), 3):
		var p0 := pts[ids[k]]
		var p1 := pts[ids[k + 1]]
		var p2 := pts[ids[k + 2]]
		s.tri(Vector3(p0.x, y1, p0.y), Vector3(p1.x, y1, p1.y), Vector3(p2.x, y1, p2.y), Vector3.UP, p0, p1, p2)
		s.tri(Vector3(p0.x, y0, p0.y), Vector3(p1.x, y0, p1.y), Vector3(p2.x, y0, p2.y), Vector3.DOWN, p0, p1, p2)


# ==========================================
# Двускатная крыша: замкнутая призма на плечо плана
# ==========================================

static func _pt(ridge_x: bool, a: float, c: float, y: float) -> Vector3:
	return Vector3(a, y, c) if ridge_x else Vector3(c, y, a)


## Низ призмы лежит на уровне кончика свеса (чуть ниже карниза), торцы-фронтоны вровень со стеной
static func _gable(s: Soup, wall_h: float, p: BuildingLayout.RoofPiece, ov: float) -> void:
	var slope := p.rise / (p.span * 0.5)
	var ye := wall_h - ov * slope
	var top := wall_h + p.rise
	var a0 := p.x0 if p.ridge_x else p.z0
	var a1 := p.x1 if p.ridge_x else p.z1
	var c0 := p.z0 if p.ridge_x else p.x0
	var c1 := p.z1 if p.ridge_x else p.x1
	var cc := (c0 + c1) * 0.5
	var cl := c0 - ov
	var ch := c1 + ov
	var ax := Vector3(0, 0, 1) if p.ridge_x else Vector3(1, 0, 0)
	var al := Vector3(1, 0, 0) if p.ridge_x else Vector3(0, 0, 1)
	var rx := p.ridge_x
	var sl := Vector2(cc - cl, top - ye).length()

	s.quad(_pt(rx, a0, cl, ye), _pt(rx, a1, cl, ye), _pt(rx, a1, cc, top), _pt(rx, a0, cc, top), Vector3.UP - ax,
		Vector2(a0, 0.0), Vector2(a1, 0.0), Vector2(a1, sl), Vector2(a0, sl))
	s.quad(_pt(rx, a1, ch, ye), _pt(rx, a0, ch, ye), _pt(rx, a0, cc, top), _pt(rx, a1, cc, top), Vector3.UP + ax,
		Vector2(a1, 0.0), Vector2(a0, 0.0), Vector2(a0, sl), Vector2(a1, sl))
	s.tri(_pt(rx, a0, cl, ye), _pt(rx, a0, ch, ye), _pt(rx, a0, cc, top), -al, Vector2(cl, ye), Vector2(ch, ye), Vector2(cc, top))
	s.tri(_pt(rx, a1, cl, ye), _pt(rx, a1, ch, ye), _pt(rx, a1, cc, top), al, Vector2(cl, ye), Vector2(ch, ye), Vector2(cc, top))
	s.quad(_pt(rx, a0, cl, ye), _pt(rx, a1, cl, ye), _pt(rx, a1, ch, ye), _pt(rx, a0, ch, ye), Vector3.DOWN,
		Vector2(a0, cl), Vector2(a1, cl), Vector2(a1, ch), Vector2(a0, ch))


# ==========================================
# Окна и дверь
# ==========================================

## Прямоугольный брус на стене: вдоль ребра от u0 до u1, по высоте от y0 до y1, наружу от стены (o0) до o1.
## Задняя грань у стены не строится, если не задан back (замкнутое тело, например ступень)
static func _box(layout: BuildingLayout, s: Soup, e: BuildingLayout.Edge, u0: float, u1: float, y0: float, y1: float, o0: float, o1: float, back := false) -> void:
	var a := layout.wall_point(e, u0, y0, o1)
	var b := layout.wall_point(e, u1, y0, o1)
	var c := layout.wall_point(e, u1, y1, o1)
	var d := layout.wall_point(e, u0, y1, o1)
	var a0 := layout.wall_point(e, u0, y0, o0)
	var b0 := layout.wall_point(e, u1, y0, o0)
	var c0 := layout.wall_point(e, u1, y1, o0)
	var d0 := layout.wall_point(e, u0, y1, o0)
	var out := Vector3(e.normal.x, 0.0, e.normal.y)
	var al := Vector3(e.dir.x, 0.0, e.dir.y)
	s.quad(a, b, c, d, out, Vector2(u0, y0), Vector2(u1, y0), Vector2(u1, y1), Vector2(u0, y1))
	s.quad(a0, a, d, d0, -al, Vector2(o0, y0), Vector2(o1, y0), Vector2(o1, y1), Vector2(o0, y1))
	s.quad(b, b0, c0, c, al, Vector2(o1, y0), Vector2(o0, y0), Vector2(o0, y1), Vector2(o1, y1))
	s.quad(d, c, c0, d0, Vector3.UP, Vector2(u0, o1), Vector2(u1, o1), Vector2(u1, o0), Vector2(u0, o0))
	s.quad(a0, b0, b, a, Vector3.DOWN, Vector2(u0, o0), Vector2(u1, o0), Vector2(u1, o1), Vector2(u0, o1))
	if back:
		s.quad(a0, b0, c0, d0, -out, Vector2(u0, y0), Vector2(u1, y0), Vector2(u1, y1), Vector2(u0, y1))


static func _window(layout: BuildingLayout, soups: Array[Soup], o: BuildingLayout.Opening, t: float, depth: float) -> void:
	var e := layout.edges[o.edge]
	var trim := soups[BuildingStyles.Surf.TRIM]
	var glass := soups[BuildingStyles.Surf.GLASS]
	var ul := o.u - o.width * 0.5
	var ur := o.u + o.width * 0.5
	var y0 := o.y0
	var y1 := o.y0 + o.height
	var out := Vector3(e.normal.x, 0.0, e.normal.y)
	glass.quad(layout.wall_point(e, ul, y0, GLASS_OFF), layout.wall_point(e, ur, y0, GLASS_OFF),
		layout.wall_point(e, ur, y1, GLASS_OFF), layout.wall_point(e, ul, y1, GLASS_OFF), out,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	_box(layout, trim, e, ul - t, ul, y0, y1 + t, 0.0, depth)
	_box(layout, trim, e, ur, ur + t, y0, y1 + t, 0.0, depth)
	_box(layout, trim, e, ul, ur, y1, y1 + t, 0.0, depth)
	_box(layout, trim, e, ul - t - 0.05, ur + t + 0.05, y0 - 0.12, y0, 0.0, maxf(SILL_D, depth + 0.05))


static func _door(layout: BuildingLayout, soups: Array[Soup], o: BuildingLayout.Opening) -> void:
	var e := layout.edges[o.edge]
	var trim := soups[BuildingStyles.Surf.TRIM]
	var plinth := soups[BuildingStyles.Surf.PLINTH]
	var ul := o.u - o.width * 0.5
	var ur := o.u + o.width * 0.5
	var y0 := o.y0
	var y1 := o.y0 + o.height
	_box(layout, trim, e, ul, ur, y0, y1, 0.0, DOOR_LEAF_D)
	_box(layout, trim, e, ul - FRAME_T, ul, y0, y1 + FRAME_T, 0.0, FRAME_D)
	_box(layout, trim, e, ur, ur + FRAME_T, y0, y1 + FRAME_T, 0.0, FRAME_D)
	_box(layout, trim, e, ul, ur, y1, y1 + FRAME_T, 0.0, FRAME_D)
	_box(layout, plinth, e, ul - 0.25, ur + 0.25, -0.2, BuildingLayout.PLINTH_H, 0.0, STEP_D, true)


# ==========================================
# Свет окон
# ==========================================

## Один источник на стену, у которой есть окна: свет у стены снаружи и светящиеся прямоугольники по стеклу окон.
## Настройки как у окон house_01 (ночью, от шины аксессуаров, 70 % окон горит, окна загораются не разом)
static func make_lights(layout: BuildingLayout) -> Array[LightConfig]:
	var out: Array[LightConfig] = []
	for ei in layout.edges.size():
		var wins := layout.windows_of_edge(ei)
		if wins.is_empty():
			continue
		var e := layout.edges[ei]
		var yaw := rad_to_deg(atan2(e.normal.x, e.normal.y))
		var lc := LightConfig.new()
		lc.id = StringName("window_%d" % ei)
		lc.title = "Окна: стена %d" % (ei + 1)
		lc.kind = LightConfig.Kind.OMNI
		lc.rule = LightConfig.Rule.NIGHT
		lc.color = LIGHT_COLOR
		lc.energy = 1.0
		lc.light_range = 7.0
		lc.power_source = LightConfig.LightSupply.BUS
		lc.power_w = 0.4 * wins.size()
		lc.glow_rect_ratio = 0.7
		lc.fade_time = 0.8
		lc.delay_jitter = 8.0
		var mean := Vector3.ZERO
		for w in wins:
			var c := layout.wall_point(e, w.u, w.y0 + w.height * 0.5, GLOW_OFF)
			var gr := GlowRect.new()
			gr.position = c
			gr.rotation_deg = Vector3(0.0, yaw, 0.0)
			gr.size = Vector2(w.width, w.height)
			lc.glow_rects.append(gr)
			mean += c
		mean /= float(wins.size())
		lc.position = mean + Vector3(e.normal.x, 0.0, e.normal.y) * 0.8
		out.append(lc)
	return out
