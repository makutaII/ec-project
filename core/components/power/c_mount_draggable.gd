class_name C_MountDraggable extends IDraggable

# XX claude-wire W4 (новый файл)
#####################
## Драг блока с монтажом (ATTN_23 §23.9, W4)
#####################
## Блок всегда стоит горизонтально, как раньше (C_TrackDraggable): на плите сверху с уровнем R/F и полем высот, либо на нижней
## полке (вторая столешница под основной): там высота это верх полки под курсором. Q/E крутят вокруг вертикали.
## Невозможное место (близко к краю полки) метит C_Invalid: красный призрак, не ставится, при драге блок возвращается назад.

var spin := 0.0                  # поворот вокруг вертикали, рад
var elevation := 0               # уровней над плитой, только на плите сверху
var drag_offset := Vector3.ZERO  # смещение хвата
var initial_transform: Transform3D


func on_drag_started(data: Dictionary) -> void:
	initial_transform = entity.global_transform
	var raw: Vector3 = entity.global_position - data.position
	drag_offset = Vector3(raw.x, 0.0, raw.z)
	spin = entity.global_basis.get_euler().y
	var T: float = Global.settings.layer_height
	elevation = maxi(0, roundi((entity.global_position.y - data.position.y) / T))


func on_drag_moved(data: Dictionary) -> void:
	var shelf := Mount.on_shelf(data.get("collider", null))
	var target: Vector3 = (data.position as Vector3) + drag_offset
	var pos := target
	if shelf:
		pos.y = (data.position as Vector3).y   # верх полки под курсором
	else:
		var T: float = Global.settings.layer_height
		pos = Vector3(target.x, TGM.field_track_level(target.x, target.z, target.y) + elevation * T, target.z)
	entity.global_transform = Transform3D(Basis(Vector3.UP, spin), pos)
	_mark(Mount.reason(pos, shelf))


func on_drag_ended(_data: Dictionary) -> void:
	if entity.has_comp(C_Blocked) or entity.has_comp(C_Invalid):
		entity.global_transform = initial_transform
		_mark("")
		PGM.request_recalculate()


## C_Invalid стоит, пока место не подходит
func _mark(why: String) -> void:
	if why != "" and not entity.has_comp(C_Invalid):
		entity.add_component(C_Invalid.new())
	elif why == "" and entity.has_comp(C_Invalid):
		entity.remove_component(C_Invalid)


func on_rotate_input(data: Dictionary) -> void:
	if data.axis == "y":
		spin += deg_to_rad(data.amount)
	if data.axis == "x":   # R/F: уровень, только на плите сверху
		elevation = maxi(0, elevation + int(signf(data.amount)))


func on_elevation_input(data: Dictionary) -> void:
	elevation = maxi(0, elevation + int(data.get("levels", 0)))


## --- Клонирование: гост отдаёт состояние новой сущности ---
func on_clone_state_to(data: Dictionary) -> void:
	var target_entity: Entity = data.target
	target_entity.send_event("on_receive_draggable_state", {"spin": spin, "elevation": elevation})


func on_receive_draggable_state(data: Dictionary) -> void:
	if data.has("spin"):
		spin = data.spin
	if data.has("elevation"):
		elevation = data.elevation


## Сброс поворота и высоты (кнопка в DragTool)
func on_drag_reset(_data: Dictionary) -> void:
	spin = 0.0
	elevation = 0
	drag_offset = Vector3.ZERO
	entity.global_basis = Basis.IDENTITY
