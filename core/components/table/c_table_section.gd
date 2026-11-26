class_name C_TableSection extends C_Visual

# XX claude-table T1 (новый файл)
###################################
## Плита секции подмакетника (ATTN_23). Сцены нет: меш и коллизия строятся в коде (как C_TerrainLayer).
###################################
## Секция = призма: контур C_Contour в плане, верх на y = 0 Entity, толщина вниз (по умолчанию 5 u, как в v1).
## Origin Entity лежит на верхней плоскости плиты: стартовая секция стоит в нуле, остальные ставит TableTool (T2).
##  - меш: верх, низ и стенки (SurfaceTool), нормали плоские, материал общий на все секции (TableStyle придёт в T6);
##  - коллизия: StaticBody3D на слое ground. Прямоугольный контур это один BoxShape3D, остальные раскладываются
##    на выпуклые куски. У призрака (C_Ghost) тело уезжает на слой ghost, иначе луч тула попадёт в сам призрак;
##  - LYM (подмакетник) видит секцию по группе LYM.GROUP и слушает layout_changed;
##  - TGM.terrain_changed: поставили, изменили, убрали секцию (опоры эстакады пересчитывают землю под собой).
## Опоры (ножки) в T1 по-прежнему строит RoomBuilder; секция про них не знает.
## Контуры состояний (ховер, выбор, призрак, красный призрак) рисует база C_Visual, как у листов пенопласта (T2).
## Сейв: thickness. Контур сохраняет C_Contour, поза лежит в transform Entity.

## Толщина плиты по умолчанию, u (значение v1: RoomConfig.table_top_thickness)
const DEFAULT_THICKNESS := 5.0
## Пределы толщины, u
const MIN_THICKNESS := 0.5
const MAX_THICKNESS := 20.0
## Цвет плиты (как в v1: RoomBuilder.COL_TABLE). Материалы по стилям придут в T6
const COL_TABLE := Color(0.62, 0.50, 0.38)

static var _material: StandardMaterial3D

var thickness := DEFAULT_THICKNESS
var mesh_node: MeshInstance3D
var body: StaticBody3D

var _shapes: Array[CollisionShape3D] = []
var _ready_done := false
var _last_aabb := AABB()


## Базовый C_Visual.on_added инстанцирует сцену; у плиты сцены нет
func on_added() -> void:
	instance = Node3D.new()
	instance.name = 'Plate'
	entity.add_child(instance)

	mesh_node = MeshInstance3D.new()
	mesh_node.name = 'Mesh'
	mesh_node.material_override = _get_material()
	mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	instance.add_child(mesh_node)
	# XX claude-wire W3: плиту может скрывать режим «Монтаж» (коллизия остаётся). Призрак секции виден всегда
	mesh_node.visible = LYM.plate_visible or entity.has_comp(C_Ghost)
	LYM.plate_visible_changed.connect(_on_plate_visible)

	body = StaticBody3D.new()
	body.name = 'Body'
	instance.add_child(body)
	_apply_collision_layers()

	parts = PartRegistry.build(instance)
	_collect_meshes()
	_on_instance_ready()


func on_entity_ready() -> void:
	entity.add_to_group(LYM.GROUP)
	_ready_done = true
	_rebuild()
	update_visual()


func on_contour_changed(_d: Dictionary) -> void:
	if _ready_done:
		_rebuild()


func on_component_added(type: Script) -> void:
	super(type)
	if type == C_Ghost:
		_apply_collision_layers()


func on_component_removed(type: Script) -> void:
	super(type)
	if type == C_Ghost:
		_apply_collision_layers(type)


func _exit_tree() -> void:
	super()
	# секция убрана: сообщаем область, где земля пропала (призрак землёй не был)
	if not is_instance_valid(LYM) or entity == null or entity.has_comp(C_Ghost):
		return
	if _last_aabb.size != Vector3.ZERO and is_instance_valid(TGM):
		TGM.notify_changed(_last_aabb)
	if _ready_done:
		LYM.layout_changed.emit()


static func _get_material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.albedo_color = COL_TABLE
		_material.roughness = 0.9
	return _material


## --- Слои коллизии ---

## removing: тип компонента, который прямо сейчас снимается (has_comp на него еще может отвечать true)
func _apply_collision_layers(removing: Script = null) -> void:
	if body == null:
		return
	var ghost := entity.has_comp(C_Ghost) and removing != C_Ghost
	body.collision_layer = Global.active_layers(['ghost']) if ghost else Global.active_layers(['ground'])
	body.collision_mask = 0   # статическое тело само ничего не ищет


## --- Толщина ---

## Задать толщину плиты, u (в пределах MIN..MAX). Верх остаётся на y = 0, низ уходит. Пересобирает меш и коллизию
func set_thickness(t: float) -> void:
	t = clampf(t, MIN_THICKNESS, MAX_THICKNESS)
	if is_equal_approx(t, thickness):
		return
	thickness = t
	if _ready_done:
		_rebuild()


## --- Геометрия для запросов LYM ---

## Контур секции в мире (x = X, y = Z). Пусто, если контура нет
func world_polygon() -> PackedVector2Array:
	var res := PackedVector2Array()
	var contour := entity.get_comp(C_Contour) as C_Contour
	if contour == null:
		return res
	var xf := entity.global_transform if entity.is_inside_tree() else entity.transform
	for p in contour.points:
		var w := xf * Vector3(p.x, 0.0, p.y)
		res.append(Vector2(w.x, w.z))
	return res


func _world_aabb() -> AABB:
	var poly := world_polygon()
	if poly.size() < 3:
		return AABB()
	var b := C_Contour.bounds_of(poly)
	return AABB(Vector3(b.position.x, -thickness, b.position.y), Vector3(b.size.x, thickness, b.size.y))


## XX claude-wire W3
func _on_plate_visible(on: bool) -> void:
	if mesh_node != null and is_instance_valid(mesh_node):
		mesh_node.visible = on or (entity != null and entity.has_comp(C_Ghost))


## --- Сборка ---

func _rebuild() -> void:
	if mesh_node == null:
		return
	var contour := entity.get_comp(C_Contour) as C_Contour
	if contour == null or contour.points.size() < 3:
		return
	var pts := contour.normalized_points()
	var tris := Geometry2D.triangulate_polygon(pts)
	if tris.is_empty():
		var why := C_Contour.validate(pts)
		push_warning("[C_TableSection] контур не триангулируется, плита не построена%s" % ((": " + why) if why != "" else " (вырожденный контур)"))
		mesh_node.mesh = null
		_clear_shapes()
		return
	mesh_node.mesh = _build_mesh(pts, tris)
	_build_collision(pts, contour.is_rect())
	_notify()


func _build_mesh(pts: PackedVector2Array, tris: PackedInt32Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y1 := 0.0
	var y0 := -thickness
	# верх и низ
	for i in range(0, tris.size(), 3):
		var a := pts[tris[i]]
		var b := pts[tris[i + 1]]
		var c := pts[tris[i + 2]]
		_tri(st, Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(c.x, y1, c.y), Vector3.UP)
		_tri(st, Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(c.x, y0, c.y), Vector3.DOWN)
	# стенки. Наружу от ребра d это (d.y, -d.x)
	var n := pts.size()
	for i in n:
		var p0 := pts[i]
		var p1 := pts[(i + 1) % n]
		var d := p1 - p0
		if d.length_squared() < 0.000001:
			continue
		var outward := Vector3(d.y, 0.0, -d.x).normalized()
		var a0 := Vector3(p0.x, y0, p0.y)
		var a1 := Vector3(p1.x, y0, p1.y)
		var b0 := Vector3(p0.x, y1, p0.y)
		var b1 := Vector3(p1.x, y1, p1.y)
		_tri(st, a0, a1, b1, outward)
		_tri(st, a0, b1, b0, outward)
	return st.commit()


## Треугольник, лицевая сторона которого смотрит в nrm (лицевая грань в Godot идёт по часовой стрелке)
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, nrm: Vector3) -> void:
	if (b - a).cross(c - a).dot(nrm) > 0.0:
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_normal(nrm)
		st.add_vertex(v)


func _build_collision(pts: PackedVector2Array, is_rect: bool) -> void:
	_clear_shapes()
	_add_shapes(body, pts, is_rect, 0.0, -thickness)


## Формы призмы контура между y_top и y_bottom в тело target. Прямоугольник это один BoxShape3D, остальное выпуклые куски
func _add_shapes(target: StaticBody3D, pts: PackedVector2Array, is_rect: bool, y_top: float, y_bottom: float) -> void:
	if is_rect:
		var r := C_Contour.bounds_of(pts)
		var box := BoxShape3D.new()
		box.size = Vector3(r.size.x, y_top - y_bottom, r.size.y)
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = Vector3(r.position.x + r.size.x * 0.5, (y_top + y_bottom) * 0.5, r.position.y + r.size.y * 0.5)
		target.add_child(cs)
		_shapes.append(cs)
		return
	var pieces: Array = Geometry2D.decompose_polygon_in_convex(pts)
	if pieces.is_empty():
		pieces = [pts]   # разбить не вышло: пробуем контур целиком (если он выпуклый, это сработает)
	for piece: PackedVector2Array in pieces:
		var v := PackedVector3Array()
		for p: Vector2 in piece:
			v.append(Vector3(p.x, y_bottom, p.y))
			v.append(Vector3(p.x, y_top, p.y))
		var shape := ConvexPolygonShape3D.new()
		shape.points = v
		var cs := CollisionShape3D.new()
		cs.shape = shape
		target.add_child(cs)
		_shapes.append(cs)


## Старые куски убираем сразу (remove_child), иначе до конца кадра рядом лежат старая и новая коллизия
func _clear_shapes() -> void:
	for cs in _shapes:
		if is_instance_valid(cs):
			if cs.get_parent():
				cs.get_parent().remove_child(cs)
			cs.queue_free()
	_shapes.clear()


func _notify() -> void:
	if not is_instance_valid(LYM) or entity == null or not entity.is_inside_tree() or entity.has_comp(C_Ghost):
		return
	var old := _last_aabb
	_last_aabb = _world_aabb()
	if is_instance_valid(TGM):
		TGM.notify_changed(_last_aabb if old.size == Vector3.ZERO else old.merge(_last_aabb))
	LYM.layout_changed.emit()


## --- Сейв ---
func save_data() -> Dictionary:
	return {"thickness": thickness}


func load_data(data: Dictionary) -> void:
	thickness = clampf(float(data.get("thickness", thickness)), MIN_THICKNESS, MAX_THICKNESS)
	if _ready_done:
		_rebuild()
