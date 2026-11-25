class_name C_PortalDraggable extends C_TrackDraggable

# XX claude-terra 13.14 H7b (новый файл)
##################################
## Драг объекта «Портал тоннеля» (C_TunnelPortal).
##################################
## Как у трака: только yaw, Q/E поворот, R/F уровень. Отличие в высоте. Портал стоит на отметке level (пол арки, ю в мире), а не на
## поверхности под курсором: рельсы в горе лежат ниже её поверхности, и по холму уровень рельсов не найти.
##  - курсор на траке: level это низ балласта трака под курсором (кратно слою), портал встаёт на рельсы;
##  - курсор на земле или листе: level не меняется (при первой постановке берётся уровень поля под курсором), так портал
##    можно задвинуть в гору на уровне рельсов;
##  - R/F и PageUp/PageDown меняют level на слои, вниз без ограничения «над поверхностью».
## Привязки к сокетам и вертикального магнита нет.

const MIN_LEVEL := -50.0

## Отметка пола арки в мире, ю
var level := 0.0
var _has_level := false


## Поза до драга: высоту сохраняем (портал, стоящий внутри горы, не выпрыгивает на поверхность)
func on_drag_started(data: Dictionary) -> void:
	super(data)
	level = entity.global_position.y
	_has_level = true


func on_drag_moved(data: Dictionary) -> void:
	var T: float = Global.settings.layer_height
	var pos: Vector3 = data.get("position", Vector3.ZERO)
	if _is_track_hit(data.get("collider")):
		level = roundf((pos.y - Global.settings.get_track_height()) / T) * T
		_has_level = true
	elif not _has_level:
		level = TGM.field_track_level(pos.x, pos.z, pos.y)
		_has_level = true
	super(data)


## Трак ли под курсором: коллайдер лежит внутри сущности с C_Path
static func _is_track_hit(collider: Variant) -> bool:
	var n := collider as Node
	while n != null:
		if n is Entity:
			return (n as Entity).has_comp(C_Path)
		n = n.get_parent()
	return false


func _apply_regular_movement(target_pos: Vector3) -> void:
	var pos := Vector3(target_pos.x, level, target_pos.z)
	entity.global_transform = Transform3D(Basis(Vector3.UP, rotation_euler.y), pos)


func on_rotate_input(data: Dictionary) -> void:
	if data.axis == "y":
		rotation_euler.y += deg_to_rad(data.amount)
	if data.axis == "x":   # R/F: один слой
		_step_level(int(signf(data.amount)))


func on_elevation_input(data: Dictionary) -> void:
	_step_level(int(data.get("levels", 0)))


func _step_level(layers: int) -> void:
	level = maxf(level + float(layers) * float(Global.settings.layer_height), MIN_LEVEL)


## Призрак или дубль получает ещё и отметку пола
func on_clone_state_to(data: Dictionary) -> void:
	super(data)
	var target: Entity = data.get("target")
	if target == null:
		return
	var t := target.get_comp(C_PortalDraggable) as C_PortalDraggable
	if t != null:
		t.level = level
		t._has_level = _has_level


func on_drag_reset(data: Dictionary) -> void:
	super(data)
	_has_level = false   # следующий on_drag_moved возьмёт уровень поля или трака под курсором
