class_name C_BuildingGen extends C_Visual

# XX claude-library L7 (новый файл)
###################################
## Визуал здания из генератора (ATTN_22 §22.7.6, шаг L7). Сцены нет: меш и коллизия строятся в коде (как C_TableSection).
###################################
## Устройство как у house_01: корень RigidBody3D (заморожен, слой trains), меш и коробки коллизии под ним.
## Данные: BuildingSpec. Откуда он берётся и как переживает сейв:
##  - спецификация лежит в Entity.variant["building"] (словарь BuildingSpec.to_dict()), как покраска. Фабрика отдаёт
##    variant до создания компонентов, поэтому здание строится сразу нужным, без перестройки;
##  - призрак, поставленный объект, копия (V) и сейв макета переносят variant сами, файлов user:// макет не требует;
##  - set_spec меняет здание «на месте» (Library, тест): пересобирает меш, коллизию и свет и обновляет variant.
## Свет: C_Mechanisms получает LightConfig из make_lights() (по одному на стену с окнами), при смене формы
## set_light_configs пересоздаёт источники. Порядок в components: Identity, BuildingGen (он же добавляет C_Mechanisms).
## Покраска Library (variant["paint"]) применяется к мешу как у остальных моделей; после перестройки меша заново.

## Задаёт BuildingGenSetting до add_component. null: здание по умолчанию
var spec: BuildingSpec
var layout: BuildingLayout
var rb: RigidBody3D
var mesh_node: MeshInstance3D
## Число вершин и треугольников последней сборки: {vertices, triangles}
var stats := {}

var _shapes: Array[CollisionShape3D] = []


## Базовый C_Visual.on_added инстанцирует сцену; у здания сцены нет, всё строится кодом
func on_added() -> void:
	if spec == null:
		spec = BuildingSpec.new().sanitize()
	rb = RigidBody3D.new()
	rb.name = "BuildingBody"
	rb.freeze = true
	instance = rb
	entity.add_child(rb)
	rb.collision_layer = Global.active_layers([&"trains"])
	rb.collision_mask = Global.active_layers([&"ground", &"tracks", &"trains", &"ghost", &"room", &"supports"])

	mesh_node = MeshInstance3D.new()
	mesh_node.name = "Building"
	rb.add_child(mesh_node)

	parts = PartRegistry.build(instance)
	_build_geometry()
	_collect_meshes()
	_apply_paint()
	_store_spec()
	_on_instance_ready()


## Здание целиком в исполнении сущности: так оно попадает в сейв, копию и призрак
func _store_spec() -> void:
	entity.variant["building"] = spec.to_dict()


## Свет окон для C_Mechanisms
func make_lights() -> Array[LightConfig]:
	return BuildingBuilder.make_lights(layout)


## Сменить здание. Пересобирает меш, коллизию и свет, обновляет variant. Можно звать до и после попадания в дерево
func set_spec(new_spec: BuildingSpec) -> void:
	spec = new_spec.duplicate_spec()
	if rb == null:
		return   # on_added ещё не было: здание построится с новым spec
	_build_geometry()
	_apply_paint()
	_store_spec()
	var mech := get_comp(C_Mechanisms) as C_Mechanisms
	if mech != null:
		mech.set_light_configs(make_lights())
	entity.send_event("on_building_changed", {})


func _build_geometry() -> void:
	layout = BuildingLayout.build(spec)
	var res := BuildingBuilder.build(layout)
	mesh_node.mesh = res["mesh"] as ArrayMesh
	stats = {"vertices": res["vertices"], "triangles": res["triangles"]}
	_build_collision()


func _build_collision() -> void:
	for cs in _shapes:
		if is_instance_valid(cs):
			rb.remove_child(cs)
			cs.queue_free()
	_shapes.clear()
	for box in layout.collision_boxes():
		var cs := CollisionShape3D.new()
		cs.name = "BuildingCollisionShape3D"
		var bx := BoxShape3D.new()
		bx.size = box.size
		cs.shape = bx
		cs.position = box.get_center()
		rb.add_child(cs)
		_shapes.append(cs)


## Покраска Library (поверхности меша: wall, roof, plinth, trim, glass). После перестройки меша материалы
## поверхностей новые, поэтому применяется заново
func _apply_paint() -> void:
	var pv: Variant = entity.variant.get("paint")
	if pv is Dictionary and not PaintData.is_blank(pv as Dictionary):
		VariantApplier.apply(mesh_nodes, entity.variant)


## Выбранный объект и призрак лежат на слое ghost (как у C_TrainVisual), чтобы луч тула не попал в сам объект
func on_select_layer(data: Dictionary) -> void:
	if rb == null:
		return
	if data.get("enabled", false):
		rb.collision_layer = Global.active_layers([&"ghost"])
		rb.collision_mask = Global.active_layers([&"ground", &"tracks", &"trains", &"room", &"supports"])
	else:
		rb.collision_layer = Global.active_layers([&"trains"])
		rb.collision_mask = Global.active_layers([&"ground", &"tracks", &"trains", &"ghost", &"room", &"supports"])
