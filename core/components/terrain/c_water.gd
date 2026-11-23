class_name C_Water extends C_Visual

# XX claude-terra 13.4 W2 (новый файл)
###################################
## Водный участок (ATTN_13 §13.4). Плоскость воды на уровне level и область на сетке, найденная WaterFill.
###################################
## Origin Entity = точка клика (x, 0, z), меш строится в локальных координатах от неё.
## Живая вода: слушает TGM.terrain_changed и пересчитывает область, если изменился лист в слое воды рядом.
## H6: то же при правке поля высот шпатлёвки и ложа трака (TGM.field.changed, bed_changed).
## Домен (снимок стола на момент заливки) хранится в сейве: достроили кусок стола, океан не растёт.
## Чтобы изменить воду, её убирают и льют заново. Меш: верх одной поверхностью, у края домена вертикальные
## стенки вниз до стола. Материал прозрачный, коллизия на слое water (только для плавающих и инструмента).
## Сейв: level, domain, step (точка клика лежит в transform Entity).

## Минимальный интервал между пересчётами, с (листы в драге шлют terrain_changed каждый тик)
const RECOMPUTE_DELAY := 0.1

## Уровень поверхности в слоях над столом (поверхность на y = level * layer_height)
var level := 1
## Домен: прямоугольник стола на момент заливки (мир, XZ)
var domain := Rect2()
## Шаг сетки области, ю
var step := 1.0

var mesh_node: MeshInstance3D
var body: StaticBody3D
var _shape: CollisionShape3D

## Последний расчёт WaterFill.fill (cells можно не хранить после сборки меша: оставляем для запросов)
var region := {}
var _pending := false
var _bounds := Rect2()   # область воды в мире, XZ


func on_added() -> void:
	instance = Node3D.new()
	instance.name = 'Water'
	entity.add_child(instance)

	mesh_node = MeshInstance3D.new()
	mesh_node.name = 'Mesh'
	mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.add_child(mesh_node)

	body = StaticBody3D.new()
	body.name = 'Body'
	body.collision_layer = Global.active_layers(['water'])
	body.collision_mask = 0
	instance.add_child(body)

	parts = PartRegistry.build(instance)
	_collect_meshes()
	_on_instance_ready()


func on_entity_ready() -> void:
	entity.add_to_group(TGM.WATER_GROUP)
	update_visual()
	TGM.terrain_changed.connect(_on_terrain_changed)
	TGM.field.changed.connect(_on_field_changed)       # H6: правка поля (кисть, слой, отмена, фиксация насыпи)
	TGM.field.bed_changed.connect(_on_field_changed)   # H6: ложе трака
	if domain.size != Vector2.ZERO:   # загрузка сейва: level и domain уже в load_data
		_schedule()


## Точка клика и её ячейка: Origin Entity
func seed_point() -> Vector2:
	var p := entity.global_position
	return Vector2(p.x, p.z)


## Уровень поверхности воды (номинальный), мир Y
func level_y() -> float:
	return float(level) * float(Global.settings.layer_height)


## Высота, на которой вода реально нарисована (чуть ниже номинала)
func surface_y() -> float:
	return level_y() - WaterFill.SURFACE_DROP


## Задать воду и посчитать область сразу. Возвращает результат WaterFill.fill (ok, why, count, touches_edge)
func setup(new_level: int, new_domain: Rect2, new_step: float) -> Dictionary:
	level = maxi(1, new_level)
	domain = new_domain
	step = new_step
	return recompute()


## Пересчитать область по текущим листам и пересобрать меш
func recompute() -> Dictionary:
	_pending = false
	var res := WaterFill.fill(seed_point(), level_y(), domain, step, WaterFill.blocker_for(level_y()),
			WaterFill.MAX_CELLS, WaterFill.footprint_inside(), WaterFill.shore_for(level_y(), step))   # XX claude-table T2: край воды это край плиты; H6: поле и кромка
	region = res
	_bounds = res["bounds"] if res["ok"] else Rect2()
	_build(res)
	return res


func _schedule() -> void:
	if _pending or not is_inside_tree():
		return
	_pending = true
	get_tree().create_timer(RECOMPUTE_DELAY).timeout.connect(_on_delay)


func _on_delay() -> void:
	if _pending:
		recompute()


## Лист изменился: пересчёт, если он задел слой воды рядом с областью (или с точкой клика, пока воды нет)
func _on_terrain_changed(aabb: AABB) -> void:
	if domain.size == Vector2.ZERO:
		return
	var T: float = Global.settings.layer_height
	if aabb.position.y > level_y() + TGM.EPS or aabb.end.y < level_y() - T - TGM.EPS:
		return
	if _zone().intersects(Rect2(aabb.position.x, aabb.position.z, aabb.size.x, aabb.size.z), true):
		_schedule()


## H6. Поле или ложе трака изменились (keys: чанки TerrainField): пересчёт, если чанк задел область воды. Высота здесь не смотрится:
## поле меняется кистью по высоте непрерывно, дешевле пересчитать (задержка RECOMPUTE_DELAY склеивает штрихи)
func _on_field_changed(keys: Array) -> void:
	if domain.size == Vector2.ZERO:
		return
	var zone := _zone()
	var span := float(TerrainField.CHUNK) * TerrainField.STEP
	for key: Vector2i in keys:
		if zone.intersects(Rect2(Vector2(key) * span, Vector2(span, span)), true):
			_schedule()
			return


## Пересчитать позже (загрузка сейва поля: вода могла посчитаться раньше поля)
func refresh_later() -> void:
	if domain.size != Vector2.ZERO:
		_schedule()


## Область, где правка может изменить воду: область воды с запасом (или окрестность точки клика, пока воды нет)
func _zone() -> Rect2:
	var zone := _bounds.grow(2.0) if _bounds.size != Vector2.ZERO else Rect2(seed_point() - Vector2.ONE * 2.0, Vector2.ONE * 4.0)
	return zone.merge(Rect2(seed_point() - Vector2.ONE, Vector2.ONE * 2.0))


## --- Меш ---

func _build(res: Dictionary) -> void:
	if mesh_node == null:
		return
	if not res["ok"]:
		mesh_node.mesh = null
		_clear_shape()
		return
	var o := seed_point()
	var y := surface_y()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_material())
	var s := step
	var shown: Dictionary = (res["cells"] as Dictionary).duplicate()
	shown.merge(res.get("shore", {}))   # H6: кромка у склона рисуется водой (выше склона плоскость скрыта землёй)
	for r: Vector3i in WaterFill.runs(shown):
		var a := Vector3(float(r.y) * s - o.x, y, float(r.x) * s - o.y)
		var b := Vector3(float(r.z) * s - o.x, y, float(r.x) * s - o.y)
		var c := Vector3(float(r.z) * s - o.x, y, float(r.x + 1) * s - o.y)
		var d := Vector3(float(r.y) * s - o.x, y, float(r.x + 1) * s - o.y)
		_quad(st, a, b, c, d, Vector3.UP)
	for w: Dictionary in WaterFill.edge_walls(res["cells"], res["dom"], s, WaterFill.footprint_inside()):
		var wa: Vector2 = w["a"] - o
		var wb: Vector2 = w["b"] - o
		var dir := wb - wa
		var n := Vector3(dir.y, 0.0, -dir.x).normalized()
		_quad(st, Vector3(wa.x, 0.0, wa.y), Vector3(wb.x, 0.0, wb.y), Vector3(wb.x, y, wb.y), Vector3(wa.x, y, wa.y), n)
	var mesh := st.commit()
	mesh_node.mesh = mesh
	_build_shape(mesh)
	update_visual()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_normal(n)
		st.add_vertex(v)


func _build_shape(mesh: ArrayMesh) -> void:
	_clear_shape()
	if mesh == null or body == null:
		return
	_shape = CollisionShape3D.new()
	_shape.shape = mesh.create_trimesh_shape()
	body.add_child(_shape)


func _clear_shape() -> void:
	if is_instance_valid(_shape):
		_shape.queue_free()
	_shape = null


static var _mat: StandardMaterial3D

## Прозрачная «эпоксидка»: гладкая, с бликом, двусторонняя
static func _material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.albedo_color = Color(0.22, 0.52, 0.78, 0.55)
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.roughness = 0.08
		_mat.metallic_specular = 0.9
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _mat


## --- Запросы ---

## Вода над точкой (x, z)? Для плавающих сущностей и подсказок
func has_water_at(p: Vector2) -> bool:
	if not region.get("ok", false):
		return false
	return (region["cells"] as Dictionary).has(WaterFill.cell_of(p, step))


## --- Сейв ---

func save_data() -> Dictionary:
	return {"level": level, "domain": domain, "step": step}


func load_data(data: Dictionary) -> void:
	level = maxi(1, int(data.get("level", level)))
	domain = data.get("domain", domain)
	step = float(data.get("step", step))
	if is_inside_tree():
		_schedule()
