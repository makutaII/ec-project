class_name C_TrainDraggable extends IDraggable

##################################
## Библиотека действий. Она живет на объекте всегда.
##################################
## способность двигать ентити вагон, когда включено C_Drag 
## компонент двигает сущность по евенту из ентити
##
## Управление перетаскиванием и посадкой вагона на рельсы

var initial_transform: Transform3D
var drag_offset := Vector3.ZERO # Смещение ентити



# Ссылки на текущий трак, если мы над ним
var current_track: Entity = null
var current_curve_point: float = 0.0 # Смещение на кривой
## От центра вагона до торца, ю (из паспорта WagonConfig.coupler_offset). Задает TrainDraggableSettings
var coupler_offset := 6.0
var current_route: int = 0           # XX claude-switch: маршрут на кроссе (ближайший к курсору)
var _snap_route: int = -1
var is_snapped_to_track := false # Флаг привязки к траку
var is_flipped_on_track := false # Флаг: смотрит ли вагон мордой к началу трака

## --Mark--
const MARK_SHADER := preload("res://core/visual/materials/shader_drop_marker.gdshader")
const MARK_WIDTH := 3.4
const MARK_DEPTH := 1.2        # толщина объема проекции
const MARK_TOP := 0.08         # верх объема над точкой попадания луча (краска не должна лечь на колеса)

var _mark: MeshInstance3D
var _mark_mat: ShaderMaterial
var _mark_k := 0.0             # 0 - над столом, 1 - притянут к траку


func _init() -> void:
	set_process(false)


func _mark_start() -> void:
	if _mark:
		return
	var length := 2.0 * coupler_offset
	var margin := 1.0   # запас под ореол
	var size := Vector3(MARK_WIDTH + 2.0 * margin, MARK_DEPTH, length + 2.0 * margin)

	_mark_mat = ShaderMaterial.new()
	_mark_mat.shader = MARK_SHADER
	_mark_mat.set_shader_parameter("half_size", size * 0.5)
	_mark_mat.set_shader_parameter("body_half", Vector2(MARK_WIDTH, length) * 0.5)

	var box := BoxMesh.new()
	box.size = size
	_mark = MeshInstance3D.new()
	_mark.name = "DropMarker"
	_mark.mesh = box
	_mark.material_override = _mark_mat
	_mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mark.top_level = true
	_mark.visible = false
	entity.add_child(_mark)
	_mark_k = 0.0
	set_process(true)


func _mark_stop() -> void:
	set_process(false)
	if _mark:
		_mark.queue_free()
		_mark = null


func _process(delta: float) -> void:
	if not _mark or not entity.is_inside_tree():
		return
	var from := entity.global_position + Vector3.UP * 3.0
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 500.0,
			Global.active_layers(['ground', 'tracks']))
	q.collide_with_areas = true   # балласт - Area3D
	var hit := entity.get_world_3d().direct_space_state.intersect_ray(q)
	_mark.visible = not hit.is_empty()
	if hit.is_empty():
		return

	var fwd := -entity.global_basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return
	var b := Basis.looking_at(fwd.normalized(), Vector3.UP)
	_mark.global_transform = Transform3D(b, hit.position + Vector3.UP * (MARK_TOP - MARK_DEPTH * 0.5))

	_mark_k = move_toward(_mark_k, 1.0 if is_snapped_to_track else 0.0, delta * 6.0)
	var c0: Color = Outline.STYLE[Outline.S.HOVER].color
	var c1: Color = Outline.STYLE[Outline.S.GHOST].color
	_mark_mat.set_shader_parameter("col", c0.lerp(c1, _mark_k))
	_mark_mat.set_shader_parameter("snap", _mark_k)
	
	
	
	
func on_drag_started(_data: Dictionary) -> void:
	_mark_start()          # первой строкой, до await
	lift_levels = 0        # XX claude-terra 13.1.7
	initial_transform = entity.global_transform

	var track_h = Vector3(0,  Global.settings.get_track_height() + 0.15, 0) 
	if entity.global_position.y < 0.9:
		drag_offset = Vector3.ZERO + track_h # приподняли на старте повыше трака
	else:
		drag_offset.y = 0.15
	
	# Проверяем, если евент из билд моде, то смещения мыши не будет
	var _build_mode =  true if _data.has('build') and _data.build else false
	if not _build_mode :
		# Берем смещение по X/Z, чтобы мышь не центрировалась жестко по пивоту вагона
		var raw_offset = entity.global_position - _data.position

		# в билд тоже приподняли на старте 
		drag_offset.x = raw_offset.x
		drag_offset.z = raw_offset.z
	
	# ⚡Сигнал в trainvisual о смене слоя
	entity.send_event("on_select_layer", {'enabled':true})
	
	await get_tree().process_frame # Сначала выставляем все, потом вкл физику
	
	#⚡ включаем физику вагона - дернуть C_Kinematics
	entity.send_event("on_is_dragging", {'on':true, 'freeze': false})



func on_drag_moved(_data: Dictionary) -> void:
	# Если камера на вагоне, то не тянем
	var _comp = entity.get_comp(C_CameraTarget)
	if _comp and _comp.camera_instance: return
	
	var mouse_pos: Vector3 = _data.position
	var collider = _data.get("collider") # Ожидаем, что тул передает ноду коллизии
	
	is_snapped_to_track = false
	current_track = null
	
	# 1. Проверяем, над траком ли мы (Слой 3)
	if collider and (collider.collision_layer == Global.active_layers(['tracks'])):
		var track_entity = _find_entity_from_collider(collider)
		if track_entity :
			_snap_to_track(track_entity, mouse_pos)
			return
			
	# 2. Если мы не над траком, просто тащим ентити по воздуху/земле
	_apply_free_movement(mouse_pos)



func on_drag_ended(_data: Dictionary) -> void:
	_mark_stop()           # первой строкой
	if is_snapped_to_track and current_track:
		# Успешная посадка на рельсы
		# Передаем данные в тележки (C_Chassis), чтобы они закрепились на кривой
		entity.send_event("on_train_snapped", {
			"track": current_track,
			"offset": current_curve_point,
			"route": current_route,
			"is_wagon_flipped": is_flipped_on_track # Передаем разворот
		})
	else:
		# Бросили мимо рельсов — включаем физику Godot (RigidBody)
		#entity.send_event("on_train_derailed")
		pass
	
	# Отключаем флаг в физикс
	entity.send_event("on_is_dragging", {'on': false, 'freeze': false})
	rotation_euler = entity.rotation


# XX claude-terra 13.1.7. Уровень вагона над поверхностью под курсором, в слоях (GlobalSetting.layer_height).
# R/F ±1, Shift+R/F и PageUp/PageDown ±5 (как у трака). Работает, пока вагон не на рельсах
var lift_levels := 0


# Реакция на поворот ентити кнопками
func on_rotate_input(data: Dictionary):
	if data.axis == "x":   # XX claude-terra 13.1.7: R/F больше не наклон, а уровень, как у трака
		lift_levels = maxi(0, lift_levels + int(signf(data.amount)))
		return

	var rad = deg_to_rad(data.amount)
	if data.axis == "y": rotation_euler.y += rad
	
	# 1. Применяем поворот к  сущности
	entity.global_basis = Basis.from_euler(rotation_euler)
	
	# 2. Отправляем приказ физике подтянуть кузов
	entity.send_event("on_force_rotate_physics", {"basis": entity.global_basis})


## XX claude-terra 13.1.7. Крупный шаг уровня (Shift+R/F, PageUp/PageDown): ElevationInput, levels = ±5
func on_elevation_input(data: Dictionary) -> void:
	lift_levels = maxi(0, lift_levels + int(data.get("levels", 0)))


## XX claude-terra 13.1.7. Home в драге: вагон колесами вниз, без поворота, на стартовой высоте
## (верх трака + 0,15, около 1 ю над поверхностью), уровень R/F обнулен. Как Home у трака и листа
func on_drag_reset(_data: Dictionary) -> void:
	rotation_euler = Vector3.ZERO
	lift_levels = 0
	drag_offset.y = Global.settings.get_track_height() + 0.15
	entity.global_basis = Basis.IDENTITY
	entity.send_event("on_force_rotate_physics", {"basis": entity.global_basis})



# ==========================================
# Логика Снаппинга
# ==========================================
### ==========================================
### Логика Снаппинга
### ==========================================

func _snap_to_track(track_entity: Entity, world_mouse_pos: Vector3) -> void:
	var path_comp = track_entity.get_comp(C_Path)
	if not path_comp or not path_comp.path_node or not path_comp.curve:
		_apply_free_movement(world_mouse_pos)
		return

	var path_node = path_comp.path_node
	var local_mouse_pos = path_node.to_local(world_mouse_pos)
	# XX claude-switch: у кросса берем кривую, ближайшую к курсору (обычному траку всегда активная)
	current_route = path_comp.route_at(local_mouse_pos)
	var curve = path_comp.curve_of(current_route)


	# 1. Находим ближайшую точку на кривой в локальных координатах
	current_curve_point = curve.get_closest_offset(local_mouse_pos)

	# 2. Получаем Transform3D точки на кривой, чтобы узнать касательную (tangent)
	var curve_point_transform = curve.sample_baked_with_rotation(current_curve_point)
	var global_point_pos = path_node.to_global(curve_point_transform.origin)

	# 3. Вычисляем глобальный вектор направления сплайна. -Z
	var track_forward = (path_node.global_transform.basis * -curve_point_transform.basis.z).normalized()
	
	# 4. Проверяем сонаправленность ТОЛЬКО при первой посадке на трак
	if not is_snapped_to_track or current_track != track_entity or _snap_route != current_route:
		var wagon_forward = -entity.global_transform.basis.z     
		is_flipped_on_track = wagon_forward.dot(track_forward) < 0
		
	# 5. Разворачиваем итоговый вектор привязки, если вагон смотрит назад
	var final_forward = track_forward
	if is_flipped_on_track:
		final_forward = -track_forward

	# 6. Устанавливаем позицию и выравниваем базис (поворот).Прибавляем высоту от drag_offset
	#entity.global_position = global_point_pos + Vector3(0,  Global.settings.get_track_height(), 0) 
	# XX claude-coaster C5.3: «верх» трака (без крена ровно Vector3.UP: прежние подъём по Y и поворот)
	var surf_up: Vector3 = path_comp.surface_up_at(current_curve_point, current_route)
	entity.global_position = global_point_pos + surf_up * path_comp.head_height()
	# Защита от коллинеарности с вектором UP (если рельсы идут строго вертикально)
	if abs(final_forward.dot(Vector3.UP)) < 0.99:
		entity.global_transform.basis = Basis.looking_at(final_forward, surf_up)

	# 7. Отправляем приказ физике подтянуть кузов
	entity.send_event("on_force_rotate_physics", {"basis": entity.global_basis})
	
	# Сохраняем стейт
	current_track = track_entity
	_snap_route = current_route
	is_snapped_to_track = true




	# Свободное таскание над столом.
func _apply_free_movement(world_mouse_pos: Vector3) -> void:
	# transform не бьет ошибку если ентити не в дереве еще
	#entity.position = world_mouse_pos + drag_offset

	var T: float = Global.settings.layer_height
	entity.transform.origin = world_mouse_pos + drag_offset + Vector3(0.0, lift_levels * T, 0.0)   # XX claude-terra 13.1.7
	# 🛠️ Обязательно обнуляем стейт, когда вагон сорвался с рельсов
	is_snapped_to_track = false # 🛠️
	current_track = null        # 🛠️
	
	#get_node('/root/GameRoot/UI/Labeltest').text = 'free'



# ==========================================
# Хелперы
# ==========================================

func _find_entity_from_collider(node: Node) -> Entity:
	var current = node
	while current:
		if current is Entity: return current
		current = current.get_parent()
	return null
	
	## --- Блок синхронизации состояния (Клонирование) ---

var rotation_euler := Vector3.ZERO # Храним тут, чтобы не терять при смене тулзов

# Вызывается у Госта в момент клонирования(отдаем данные). см build_tool 
func on_clone_state_to(_data: Dictionary) -> void:
	var target_entity: Entity = _data.target
	#rotation_euler = target_entity.global_transform.basis.get_euler()
	# Гост кричит в новую сущность: "Прими мои настройки драга!"
	target_entity.send_event("on_receive_draggable_state", {
		"global_transform": target_entity.global_transform
		})


# Вызывается у Реального объекта в момент клонирования (принимаем данные). см build_tool 
func on_receive_draggable_state(data: Dictionary) -> void:
	if data.has("global_transform"):
		entity.global_transform = data.global_transform


	
	
