class_name FieldObjects extends RefCounted

# XX claude-terra 13.14 H3 (новый файл)
###################################
## Объекты на земле для кисти рельефа (ATTN_13 §13.14, режимы «объекты в зоне»). Данные без сцены, кроме collect.
###################################
## Объект это сущность с визуалом (здание, декор, всё, что игрок ставит на землю). Не объекты: призраки, сущности в драге, секции стола, листы,
## вода, траки (их подкладывает автоподушка H5) и всё, что едет по рельсам (группа C_Bogie.GROUP).
## След объекта в плане: выпуклая оболочка рамок его мешей (мировые XZ). Опорные точки: вершины оболочки, середины сторон и центр,
## по ним считается, на какой высоте объект стоит на земле.

## Запас вокруг следа, ю: узлы вплотную к объекту тоже считаются занятыми (поверхность между узлами интерполируется)
const MARGIN := TerrainField.STEP * 0.5


## Объекты под rect (мировые XZ). Элементы: {"entity": Entity, "poly": PackedVector2Array (след с запасом), "pts": PackedVector2Array (опорные точки)}
static func collect(root: Node, area: Rect2) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	if root == null or not root.is_inside_tree():
		return res
	for n in root.get_children():
		var e := n as Entity
		if e == null or not is_object(e):
			continue
		var hull := footprint(e)
		if hull.size() < 3:
			continue
		var bb := C_Contour.bounds_of(hull).grow(MARGIN)
		if not bb.intersects(area):
			continue
		var poly := hull
		var grown := Geometry2D.offset_polygon(hull, MARGIN, Geometry2D.JOIN_MITER)
		if not grown.is_empty() and C_Contour.bounds_of(grown[0]).get_area() >= C_Contour.bounds_of(hull).get_area():
			poly = grown[0]   # иначе (оболочка пришла по часовой и «сжалась») остаётся оболочка без запаса
		res.append({"entity": e, "poly": poly, "pts": support_points(hull)})
	return res


## Стоит ли сущность на земле как объект (см. шапку файла)
static func is_object(e: Entity) -> bool:
	if not e.is_inside_tree() or e.is_queued_for_deletion():
		return false
	if e.has_comp(C_Ghost) or e.has_comp(C_Drag) or e.has_comp(C_TerrainLayer) or e.has_comp(C_Water) or e.has_comp(C_Path):
		return false
	if e.has_comp(C_TableSection) or e.is_in_group(LYM.GROUP):
		return false   # секция стола это сама земля, а не стоящий на ней объект (иначе обход запирал бы весь стол, а подъём двигал бы стол)
	if e.is_in_group(C_Bogie.GROUP):
		return false
	return e.has_comp(C_Visual)


## След сущности в плане: выпуклая оболочка рамок всех видимых мешей визуала (мировые XZ). Пусто, если мешей нет
static func footprint(e: Entity) -> PackedVector2Array:
	var vis := e.get_comp(C_Visual) as C_Visual
	if vis == null:
		return PackedVector2Array()
	var pts := PackedVector2Array()
	for mi in vis.mesh_nodes:
		if not is_instance_valid(mi) or not mi.is_visible_in_tree() or mi.mesh == null:
			continue
		var xf := mi.global_transform
		var bb := mi.get_aabb()
		for cx in 2:
			for cy in 2:
				for cz in 2:
					var v := xf * (bb.position + bb.size * Vector3(cx, cy, cz))
					pts.append(Vector2(v.x, v.z))
	if pts.size() < 3:
		return PackedVector2Array()
	var hull := Geometry2D.convex_hull(pts)
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)   # Godot замыкает оболочку повтором первой точки
	if Geometry2D.is_polygon_clockwise(hull):
		hull.reverse()   # по часовой это «дыра» для offset_polygon и Clipper
	return hull


## Опорные точки: вершины оболочки, середины сторон, центр
static func support_points(hull: PackedVector2Array) -> PackedVector2Array:
	var res := PackedVector2Array()
	var n := hull.size()
	var c := Vector2.ZERO
	for i in n:
		res.append(hull[i])
		res.append((hull[i] + hull[(i + 1) % n]) * 0.5)
		c += hull[i]
	if n > 0:
		res.append(c / float(n))
	return res


## Следы объектов (для обхода): Array[PackedVector2Array]
static func polys_of(objs: Array) -> Array:
	var res: Array = []
	for o: Dictionary in objs:
		res.append(o["poly"])
	return res
