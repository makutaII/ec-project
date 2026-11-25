class_name C_MountDraggable extends IDraggable

# XX claude-wire W4 (новый файл)
#####################
## Драг блока с монтажом (ATTN_23 §23.9, W4)
#####################
## Блок ставится на поверхность под курсором: плита сверху (как у C_TrackDraggable: уровень R/F, поле высот),
## низ плиты (UNDER, блок висит вниз головой) или боковая грань бруса (FRAME). Ось Y блока идёт по нормали поверхности,
## Q/E крутят вокруг неё. Поза хранится в global_transform сущности (сейв её пишет), поверхность и поворот берутся из позы.
## Невозможное место (за краем рамы, не та грань, поверхность не из allowed) метит C_Invalid: красный призрак, не ставится,
## при драге блок возвращается на старое место.

## Где крепится (Mount.Surface), из паспорта
var allowed: Array = []

var spin := 0.0                  # поворот вокруг нормали, рад
var elevation := 0               # уровней над поверхностью, только на плите сверху
var drag_offset := Vector3.ZERO  # смещение хвата, только на плите сверху
var initial_transform: Transform3D
var _normal := Vector3.UP


func on_drag_started(data: Dictionary) -> void:
	initial_transform = entity.global_transform
	_normal = entity.global_basis.y.normalized()
	spin = Mount.spin_of(entity.global_basis, _normal)
	if Mount.surface_of_basis(entity.global_basis) == Mount.Surface.TOP:
		var raw: Vector3 = entity.global_position - data.position
		drag_offset = Vector3(raw.x, 0.0, raw.z)
		var T: float = Global.settings.layer_height
		elevation = maxi(0, roundi((entity.global_position.y - data.position.y) / T))
	else:
		drag_offset = Vector3.ZERO
		elevation = 0


func on_drag_moved(data: Dictionary) -> void:
	var surface := Mount.surface_of_collider(data.get("collider", null))
	var pos: Vector3 = data.position
	var n := Vector3.UP
	match surface:
		Mount.Surface.UNDER:
			n = Vector3.DOWN
		Mount.Surface.FRAME:
			n = data.get("normal", Vector3.UP)
		_:
			var T: float = Global.settings.layer_height
			var target := pos + drag_offset
			pos = Vector3(target.x, TGM.field_track_level(target.x, target.z, target.y) + elevation * T, target.z)
	_normal = n
	entity.global_transform = Transform3D(Mount.basis_for(n, spin), pos)
	_mark(Mount.reason(surface, pos, n, allowed))


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
	entity.global_basis = Mount.basis_for(_normal, 0.0)
