class_name C_CarVisual extends C_Visual

###########################
## Кузов и колёса машины (ATTN_28 §28.4, CS2)
###########################
## Модель машины это сцена из паспорта (CarConfig.scene), как у вагонов: базовый C_Visual создаёт инстанс, PartRegistry, цвет по варианту
## объекта. Нет сцены: кузов, кабина и четыре колеса собираются из примитивов по CarConfig (габариты, цвет). Начало координат на
## поверхности дороги между колёсами, вперёд -Z. Базовый C_Visual даёт подсветку состояний (ghost, selected, hovered, blocked) по mesh_nodes.
## Выбор мышью: Area3D на слое cars. Пока машину тащат или она призрак, слой снят (on_select_layer), чтобы луч видел дорогу под ней.

var pick_area: Area3D

var _cfg: CarConfig


## Есть сцена: базовый on_added строит инстанс из PackedScene; нет: модель собирается кодом, остальные шаги те же
func on_added() -> void:
	_cfg = CarConfig.from_entity(entity)
	if scene != null:
		if _cfg == null:
			_cfg = CarConfig.new()
		super.on_added()
		return
	if _cfg == null:
		push_error("C_CarVisual: в паспорте (C_Identity.object_config) нет CarConfig, габариты по умолчанию")
		_cfg = CarConfig.new()
	instance = _build_model()
	entity.add_child(instance)
	parts = PartRegistry.build(instance)
	_collect_meshes()
	_on_instance_ready()


func _on_instance_ready() -> void:
	if pick_area == null:
		_make_scene_pick_area()   # у сцены своей области выбора нет: строим по меши
	on_select_layer({"enabled": entity.has_comp(C_Ghost)})


## Область выбора мышью по общей рамке мешей сцены (в координатах инстанса; дерево сцены ещё может быть вне дерева игры)
func _make_scene_pick_area() -> void:
	var box := AABB()
	var first := true
	for m in mesh_nodes:
		if m.mesh == null:
			continue
		var ab := _relative_xf(m) * m.mesh.get_aabb()
		box = ab if first else box.merge(ab)
		first = false
	if first:
		box = AABB(Vector3(-_cfg.width * 0.5, 0.0, -_cfg.length * 0.5), Vector3(_cfg.width, _cfg.height, _cfg.length))
	pick_area = Area3D.new()
	pick_area.name = "CarPick"
	pick_area.collision_layer = Global.active_layers([&"cars"])
	pick_area.collision_mask = 0
	pick_area.monitoring = false
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	shape.shape = bs
	shape.position = box.get_center()
	pick_area.add_child(shape)
	instance.add_child(pick_area)


## Преобразование узла относительно корня инстанса по цепочке родителей (без глобальных координат)
func _relative_xf(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != instance:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


## ⚡ Драг и призрак снимают слой выбора, чтобы курсор видел дорогу под машиной
func on_select_layer(data: Dictionary) -> void:
	if pick_area == null:
		return
	pick_area.collision_layer = 0 if bool(data.get("enabled", false)) else Global.active_layers([&"cars"])


func _build_model() -> Node3D:
	var root := Node3D.new()
	root.name = "CarModel"
	var L := _cfg.length
	var W := _cfg.width
	var H := _cfg.height
	var r := _cfg.wheel_radius
	var body_h := (H - r) * 0.55
	var cabin_h := (H - r) - body_h

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = _cfg.body_color
	body_mat.roughness = 0.5
	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = _cfg.body_color.lerp(Color(0.75, 0.85, 0.9), 0.65)
	glass_mat.roughness = 0.2
	var wheel_mat := StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.08, 0.08, 0.09)
	wheel_mat.roughness = 0.9

	var body := _box("Body", Vector3(W, body_h, L), Vector3(0.0, r + body_h * 0.5, 0.0), body_mat)
	root.add_child(body)
	var cabin := _box("Cabin", Vector3(W * 0.9, cabin_h, L * 0.5), Vector3(0.0, r + body_h + cabin_h * 0.5, L * 0.08), glass_mat)
	root.add_child(cabin)

	var wheel_w := W * 0.14
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var cyl := CylinderMesh.new()
			cyl.top_radius = r
			cyl.bottom_radius = r
			cyl.height = wheel_w
			cyl.radial_segments = 12
			var wheel := MeshInstance3D.new()
			wheel.name = "Wheel_%s%s" % ["L" if sx < 0.0 else "R", "F" if sz < 0.0 else "B"]
			wheel.mesh = cyl
			wheel.material_override = wheel_mat
			wheel.rotation_degrees = Vector3(0.0, 0.0, 90.0)
			wheel.position = Vector3(sx * (W * 0.5 - wheel_w * 0.5), r, sz * L * 0.32)
			root.add_child(wheel)

	pick_area = Area3D.new()
	pick_area.name = "CarPick"
	pick_area.collision_layer = Global.active_layers([&"cars"])
	pick_area.collision_mask = 0
	pick_area.monitoring = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(W, H, L)
	shape.shape = box
	shape.position = Vector3(0.0, H * 0.5, 0.0)
	pick_area.add_child(shape)
	root.add_child(pick_area)
	return root


func _box(node_name: String, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	return mi
