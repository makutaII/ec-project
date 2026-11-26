class_name C_CarDraggable extends IDraggable

##################################
## Перетаскивание и посадка машины на полосу (ATTN_28 §28.4, CS2)
##################################
## Аналог C_TrainDraggable, но проще: у машины нет физики и тележек, она только садится на сплайн дороги.
## Над дорогой (коллайдер на слое roads) машина притягивается к оси полосы и смотрит вдоль неё; Q/E меняют сторону движения.
## Над столом тащится свободно, R/F и PageUp/PageDown меняют уровень, Home сбрасывает.
## Бросили на дороге: машина получает on_car_snapped и едет. Бросили мимо: стоит на месте (on_car_unsnapped).

var current_track: Entity = null
var current_curve_point := 0.0
var current_route := 0
var is_snapped_to_road := false
## Смотрит ли машина против хода сплайна (решается при первой посадке и меняется Q/E)
var is_flipped_on_road := false

var rotation_euler := Vector3.ZERO
## Уровень над поверхностью под курсором, в слоях (GlobalSetting.layer_height), пока машина не на дороге
var lift_levels := 0

var _drag_offset := Vector3.ZERO
var _snap_route := -1


func on_drag_started(data: Dictionary) -> void:
	lift_levels = 0
	_drag_offset = Vector3(0.0, 0.15, 0.0)
	if not bool(data.get("build", false)) and data.has("position"):
		# Захватили существующую машину: не центрируем курсор по её началу координат
		var raw: Vector3 = entity.global_position - data.position
		_drag_offset.x = raw.x
		_drag_offset.z = raw.z
	entity.send_event("on_select_layer", {"enabled": true})
	entity.send_event("on_car_unsnapped", {})   # пока тащим, машина не едет


func on_drag_moved(data: Dictionary) -> void:
	var mouse_pos: Vector3 = data.position
	var collider = data.get("collider")
	is_snapped_to_road = false
	current_track = null
	if collider != null and collider is CollisionObject3D \
			and collider.collision_layer == Global.active_layers([&"roads"]):
		var road := _find_entity(collider)
		if road != null:
			_snap_to_road(road, mouse_pos)
			return
	_free_move(mouse_pos)


func on_drag_ended(_data: Dictionary) -> void:
	_emit_snap(entity)
	entity.send_event("on_select_layer", {"enabled": false})
	rotation_euler = entity.rotation


## Q и E: на дороге меняют сторону движения, над столом поворачивают. R и F меняют уровень
func on_rotate_input(data: Dictionary) -> void:
	if data.axis == "x":
		lift_levels = maxi(0, lift_levels + int(signf(data.amount)))
		return
	if data.axis != "y":
		return
	if is_snapped_to_road:
		is_flipped_on_road = not is_flipped_on_road
		return
	rotation_euler.y += deg_to_rad(data.amount)
	entity.global_basis = Basis.from_euler(rotation_euler)


## Shift+R/F и PageUp/PageDown: уровень ±5 (ElevationInput)
func on_elevation_input(data: Dictionary) -> void:
	lift_levels = maxi(0, lift_levels + int(data.get("levels", 0)))


## Home в драге: без поворота и на нулевом уровне
func on_drag_reset(_data: Dictionary) -> void:
	rotation_euler = Vector3.ZERO
	lift_levels = 0
	entity.global_basis = Basis.IDENTITY
	is_flipped_on_road = false


# ==========================================
# Клонирование призрака в настоящий объект (BuildTool)
# ==========================================

## Призрак передаёт состояние настоящей машине: поворот и посадку на полосу
func on_clone_state_to(data: Dictionary) -> void:
	var target: Entity = data.target
	target.send_event("on_receive_draggable_state", {"global_transform": target.global_transform})
	_emit_snap(target)


func on_receive_draggable_state(data: Dictionary) -> void:
	if data.has("global_transform"):
		entity.global_transform = data.global_transform


# ==========================================
# Посадка
# ==========================================

func _snap_to_road(road: Entity, world_mouse: Vector3) -> void:
	var pc := road.get_comp(C_Path) as C_Path
	if pc == null or pc.path_node == null or pc.curve == null:
		_free_move(world_mouse)
		return
	var local := pc.path_node.to_local(world_mouse)
	current_route = pc.route_at(local)
	var curve := pc.curve_of(current_route)
	current_curve_point = curve.get_closest_offset(local)
	var t := curve.sample_baked_with_rotation(current_curve_point)
	var point := pc.path_node.to_global(t.origin)
	var forward := (pc.path_node.global_basis * -t.basis.z).normalized()

	# Сторону движения выбираем при первой посадке на этот маршрут по тому, куда смотрит машина
	if not is_snapped_to_road or current_track != road or _snap_route != current_route:
		is_flipped_on_road = (-entity.global_basis.z).dot(forward) < 0.0
	if is_flipped_on_road:
		forward = -forward

	entity.global_position = point + Vector3.UP * pc.head_height()
	if absf(forward.dot(Vector3.UP)) < 0.99:
		entity.global_transform.basis = Basis.looking_at(forward, Vector3.UP)
	current_track = road
	_snap_route = current_route
	is_snapped_to_road = true


func _free_move(world_mouse: Vector3) -> void:
	var T: float = Global.settings.layer_height
	entity.transform.origin = world_mouse + _drag_offset + Vector3(0.0, lift_levels * T, 0.0)
	is_snapped_to_road = false
	current_track = null


## Говорит машине target, что она посажена на полосу (если сейчас над дорогой)
func _emit_snap(target: Entity) -> void:
	if not is_snapped_to_road or current_track == null or not is_instance_valid(current_track):
		return
	target.send_event("on_car_snapped", {
		"track": current_track,
		"route": current_route,
		"offset": current_curve_point,
		"world_dir": -entity.global_basis.z,
	})


func _find_entity(node: Node) -> Entity:
	var current := node
	while current != null:
		if current is Entity:
			return current
		current = current.get_parent()
	return null
