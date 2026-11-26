class_name WireTool extends Node

##########################
## Инструмент «Провод» (ATTN_10 §10.5.7, D4)
##########################
## Клик по клемме начинает провод, клики по столу ставят точки излома, клик по второй клемме соединяет.
## Совместимость и занятость проверяет PowerTerminal.can_connect; причина отказа показывается у курсора.
## ПКМ или Esc: отмена начатого провода, повторно выход в SelectTool. Удаление провода: выбрать (SelectTool) и Del.

var controller: ToolController

var start: PowerTerminal
var points := PackedVector3Array()

var _hover: PowerTerminal
var _preview: MeshInstance3D
var _rmb_start := Vector2.ZERO

## Провод лежит на поверхности под курсором (на столе, на нижней полке), не висит над ней: высота оси кабеля над поверхностью, u
const LIFT := 0.2   # XX claude-wire W4: было 1.0


func enter() -> void:
	start = null
	points = PackedVector3Array()
	_hover = null
	_preview = MeshInstance3D.new()
	_preview.mesh = ImmediateMesh.new()
	_preview.top_level = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	_preview.material_override = mat
	add_child(_preview)
	Hints.set_context(&"wire_started", false)


func exit(_to_drag: bool = false) -> void:
	_set_hover(null)
	start = null
	points = PackedVector3Array()
	if is_instance_valid(_preview):
		_preview.queue_free()
	InfoTips.clear(self)
	Hints.set_context(&"wire_started", false)


func process_tick(_delta: float) -> void:
	var t := _terminal_under_mouse() if not UIPointer.is_over_ui(get_viewport()) else null
	_set_hover(t)
	_update_preview(t)


func handle_input(event: InputEvent) -> void:
	if Actions.pressed(event, &"wire_cancel"):
		_cancel()
		return
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed:
			_rmb_start = mb.position
		elif _rmb_start.distance_to(mb.position) < 5:
			_cancel()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or UIPointer.is_over_ui(get_viewport()):
		return
	var t := _terminal_under_mouse()
	if start == null:
		if t != null and t.is_free():
			start = t
			points = PackedVector3Array()
			Hints.set_context(&"wire_started", true)
		return
	if t != null:
		if PowerTerminal.refuse_reason(start, t) != "":
			return   # причина уже показана у курсора
		# провод всегда ведётся от клеммы выше по току: порядок концов не важен для сети
		C_Wire.create_wire(controller.entities_root, start, t, points)
		start = null
		points = PackedVector3Array()
		Hints.set_context(&"wire_started", false)
		return
	var hit := controller.get_mouse_ray(Mount.wire_mask(Global.active_layers(["ground", "tracks", "plaster"])))   # XX claude-wire W4: полка
	if not hit.is_empty():
		points.append(hit.position + Vector3.UP * LIFT)


func _cancel() -> void:
	if start != null:
		start = null
		points = PackedVector3Array()
		Hints.set_context(&"wire_started", false)
	else:
		controller.switch_tool(controller.select_tool)


func _terminal_under_mouse() -> PowerTerminal:
	var hit := controller.get_mouse_ray(Global.active_layers(["power"]))
	if hit.is_empty():
		return null
	return hit.collider as PowerTerminal


func _set_hover(t: PowerTerminal) -> void:
	if t == _hover:
		return
	if is_instance_valid(_hover):
		_hover.set_highlight(false)
	_hover = t
	if is_instance_valid(_hover):
		_hover.set_highlight(true)


func _update_preview(t: PowerTerminal) -> void:
	var im := _preview.mesh as ImmediateMesh
	im.clear_surfaces()
	InfoTips.clear(self)
	if start == null:
		return
	var end := Vector3.ZERO
	var ok := true
	if t != null:
		end = t.global_position
		var why := PowerTerminal.refuse_reason(start, t)
		if why != "":
			ok = false
			InfoTips.show_lines(self, [InfoTips.danger(why)])
	else:
		var hit := controller.get_mouse_ray(Mount.wire_mask(Global.active_layers(["ground", "tracks", "plaster"])))   # XX claude-wire W4: полка
		if hit.is_empty():
			return
		end = hit.position + Vector3.UP * LIFT
	(_preview.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.85, 0.2) if ok else Color(1.0, 0.25, 0.2)
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	im.surface_add_vertex(start.global_position)
	for p in points:
		im.surface_add_vertex(p)
	im.surface_add_vertex(end)
	im.surface_end()
