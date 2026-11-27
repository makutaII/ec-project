class_name C_Visual extends Component

###################################
## База визуала. Инстанс сцены, меши, оверлеи состояний.
## Наследники: C_TrackVisual, C_TrainVisual
###################################
# В базу уходит всё, что у трека и трейна совпадало: инстанс сцены, меши, оверлеи состояний (ghost/selected/hovered/blocked), материалы. Использую шаблонный метод: база строит инстанс, а наследник добавляет своё через хук _on_instance_ready(). Так не нужно вызывать super.on_added().

var instance: Node3D
var scene: PackedScene
## Общая палитра и материалы состояний (ghost, selected, hover, blocked, питание). Один ресурс на всю игру
var visual_settings: VisualStateSettings = VisualStateSettings.shared()
var mesh_nodes: Array[MeshInstance3D] = []
var parts: PartRegistry

var _outline_state := -1

func on_added() -> void:
	instance = scene.instantiate() as Node3D
	entity.add_child(instance)
	_prepare_instance()   # хук: наследник вынимает из модели узлы, которые не должны попасть ни в реестр частей, ни в mesh_nodes
	parts = PartRegistry.build(instance)   # новое
	_collect_meshes()
	# XX claude-library L4: исполнение модели на меши кузова. Тележки и колёса строятся в хуке ниже и не красятся
	if not entity.variant.is_empty():
		VariantApplier.apply(mesh_nodes, entity.variant)
	_on_instance_ready()   # хук для наследников


## Переопределяется в наследниках. Вызывается сразу после создания инстанса, до PartRegistry.build и сбора мешей
func _prepare_instance() -> void:
	pass


## Переопределяется в наследниках
func _on_instance_ready() -> void:
	pass


# --- Реакция на состояния ---
func on_component_added(_type: Script) -> void:
	update_visual()

func on_component_removed(_type: Script) -> void:
	update_visual(_type)


## Наследник может расширить: super(_removing_type) + свой блок
func update_visual(_removing_type: Script = null) -> void:
	# XX claude-terra: C_Invalid (невалидная форма flex) красим как blocked
	if (has_comp(C_Blocked) and _removing_type != C_Blocked) or (has_comp(C_Invalid) and _removing_type != C_Invalid):
		_set_overlay(visual_settings.blocked_material)
	elif has_comp(C_Ghost) and _removing_type != C_Ghost:
		_set_overlay(visual_settings.ghost_material)
	elif has_comp(C_Selected) and _removing_type != C_Selected:
		_set_overlay(visual_settings.selected_material)
	elif has_comp(C_MultiSelected) and _removing_type != C_MultiSelected:   # XX claude-switch: группа, выбранная рамкой
		_set_overlay(visual_settings.selected_material)
	elif has_comp(C_Hovered) and _removing_type != C_Hovered:
		_set_overlay(visual_settings.hover_material)
	else:
		_set_overlay(null)
	
	_update_outline(_removing_type)
	

### ====Outline====
func _pick_outline_state(removing: Script) -> int:
	if (has_comp(C_Blocked) and removing != C_Blocked) or (has_comp(C_Invalid) and removing != C_Invalid):
		return Outline.S.BLOCKED
	if has_comp(C_Ghost) and removing != C_Ghost:
		return Outline.S.GHOST
	if has_comp(C_MultiSelected) and removing != C_MultiSelected:   # XX claude-switch: группа, выбранная рамкой
		return Outline.S.MULTI
	if has_comp(C_Selected) and removing != C_Selected:
		return Outline.S.SELECTED
	if has_comp(C_Hovered) and removing != C_Hovered:
		return Outline.S.HOVER
	return -1

func _update_outline(removing: Script) -> void:
	var s := _pick_outline_state(removing)
	if s == _outline_state:
		return
	if instance and _outline_state >= 0:
		_set_outline_layer(instance, Outline.layer_of(_outline_state), false)
	_outline_state = s
	if instance and s >= 0:
		_set_outline_layer(instance, Outline.layer_of(s), true)
	Outline.set_owner_state(self, s)


func _set_outline_layer(node: Node, layer: int, on: bool) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).set_layer_mask_value(layer, on)
	for c in node.get_children():
		_set_outline_layer(c, layer, on)


func _exit_tree() -> void:
	Outline.set_owner_state(self, -1)
	

### ====Outline END====



func _set_overlay(mat: Material) -> void:
	for mesh in mesh_nodes:
		if is_instance_valid(mesh):   # XX claude-wire W7: меш мог быть освобождён (клемма клеммника убрана)
			mesh.set_material_overlay(mat)


# --- Меши ---
func _collect_meshes() -> void:
	mesh_nodes = []
	_find_meshes(instance)

func _find_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		mesh_nodes.append(node)
	for child in node.get_children():
		_find_meshes(child)


func get_visual_offset() -> Vector3:
	return Vector3.ZERO


func get_center_world() -> Vector3:
	if mesh_nodes.is_empty():
		return instance.global_position
	var local_center := mesh_nodes[0].get_aabb().size * 0.5
	local_center.x = 0
	local_center.y = 0
	return instance.to_global(local_center)


## Вставляет материал в конец цепочки next_pass
func apply_material(mesh_instance: MeshInstance3D, _material: Material) -> void:
	var current_mat = mesh_instance.get_active_material(0)
	if not current_mat:
		return
	while current_mat.next_pass != null:
		if current_mat.next_pass == _material:
			return
		current_mat = current_mat.next_pass
	current_mat.next_pass = _material
