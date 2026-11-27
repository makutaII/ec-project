class_name WireTool extends Node

##########################
## Инструмент «Провод» (ATTN_10 §10.5.7, D4; ATTN_23 §23.9, W5)
##########################
## Клик по клемме начинает провод, клики по поверхности ставят точки трассы, клик по второй клемме соединяет.
## Совместимость и занятость проверяет PowerTerminal.can_connect; причина отказа показывается у курсора.
## Провод лежит на поверхности (стол, нижняя полка), а не висит над ней: у клеммы он спускается на поверхность вертикально
## (_drop), дальше идёт по ней. Между столешницей и нижней полкой провод проходит через ввод: вертикально в отверстии в точке клика
## (Mount.hole_reason: не ближе 3 u к краю стола).
## Свободный конец (W5): Shift+ЛКМ по поверхности начинает провод без клеммы; Enter или короткий ПКМ заканчивает провод в точке под курсором
## без подключения (оголённый наконечник, ручка WireEnd). ЛКМ по свободному концу берёт его и продолжает провод: можно подключить к клемме,
## закончить в другом месте (ПКМ, Enter) или отменить (Esc), провод при этом не меняется, пока не закончено.
## Esc: отмена начатого провода, повторно выход в SelectTool. Удаление провода: выбрать (SelectTool) и Del.

var controller: ToolController

## Клемма начала, null при свободном начале
var start: PowerTerminal
## Узлы трассы от начала. Для продолженного провода это его узлы от якорного конца к продолжаемому
var points := PackedVector3Array()

var _active := false          # провод начат (с клеммы, свободно или продолжением)
var _resume: C_Wire           # продолжаемый провод (брали его свободный конец), иначе null
var _resume_which: StringName = &"b"
var _hover: PowerTerminal
var _hover_end: WireEnd       # свободный конец под курсором (подсвечивается как клемма)
var _preview: MeshInstance3D
var _rmb_start := Vector2.ZERO


func enter() -> void:
	_reset()
	_hover = null
	_preview = MeshInstance3D.new()
	_preview.mesh = ImmediateMesh.new()
	_preview.top_level = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	_preview.material_override = mat
	add_child(_preview)


func exit(_to_drag: bool = false) -> void:
	_set_hover(null)
	_set_hover_end(null)
	_reset()
	if is_instance_valid(_preview):
		_preview.queue_free()
	InfoTips.clear(self)


## Высота оси кабеля над поверхностью (GlobalSetting.wire_lift)
func _lift() -> float:
	return Global.settings.wire_lift


func process_tick(_delta: float) -> void:
	var t := _terminal_under_mouse() if not UIPointer.is_over_ui(get_viewport()) else null
	_set_hover(t)
	# XX claude-wire W6: свободный конец, который можно взять, подсвечивается при наведении, как клемма
	var h: WireEnd = null
	if t == null and not _active and not UIPointer.is_over_ui(get_viewport()):
		h = _end_under_mouse()
	_set_hover_end(h)
	_update_preview(t)


func handle_input(event: InputEvent) -> void:
	if Actions.pressed(event, &"wire_cancel"):
		_cancel()
		return
	if _active and Actions.pressed(event, &"wire_finish"):
		_finish_free()
		return
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed:
			_rmb_start = mb.position
		elif _rmb_start.distance_to(mb.position) < 5:
			if _active:
				_finish_free()   # ПКМ заканчивает провод здесь, свободным концом
			else:
				_cancel()        # без начатого провода выход из инструмента, как раньше
		return
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or UIPointer.is_over_ui(get_viewport()):
		return
	var t := _terminal_under_mouse()
	if not _active:
		if t != null:
			if t.is_free():
				_begin_terminal(t)
			return
		var h := _end_under_mouse()
		if h != null:
			_begin_resume(h)
		elif Actions.shift():
			_begin_free()
		return
	if t != null:
		_finish_on_terminal(t)
		return
	var hit := _surface_hit()
	if hit.is_empty():
		return
	var why := _append_node(hit.position + Vector3.UP * _lift())
	if why != "":
		LYM.notice.emit(why)


# ------ Начало ------

func _begin_terminal(t: PowerTerminal) -> void:
	start = t
	points = PackedVector3Array()
	var d: Variant = _drop(t)
	if d != null:
		points.append(d)
	_set_active(true)


func _begin_free() -> void:
	var hit := _surface_hit()
	if hit.is_empty():
		return
	start = null
	points = PackedVector3Array([hit.position + Vector3.UP * _lift()])
	_set_active(true)


## Взять свободный конец провода и продолжить его: узлы провода от якорного конца к этому, сам конец снимается
func _begin_resume(h: WireEnd) -> void:
	var w := h.wire
	if not is_instance_valid(w):
		return
	_resume = w
	_resume_which = h.which
	var pts := w.points.duplicate()
	var anchor := w.b if h.which == &"a" else w.a
	if h.which == &"a":
		pts.reverse()
	if not pts.is_empty():
		pts.remove_at(pts.size() - 1)   # свободный конец: теперь он «под курсором»
	start = anchor if is_instance_valid(anchor) else null
	points = pts
	_set_active(true)


func _set_active(on: bool) -> void:
	_active = on
	Hints.set_context(&"wire_started", on)


func _reset() -> void:
	start = null
	points = PackedVector3Array()
	_resume = null
	_set_active(false)


func _cancel() -> void:
	if _active:
		_reset()
	else:
		controller.switch_tool(controller.select_tool)


# ------ Трасса ------

## Ломаная провода в порядке от якоря: клемма начала (если есть) и узлы
func _last_point() -> Variant:
	if not points.is_empty():
		return points[points.size() - 1]
	return null


## Добавляет узел трассы (p уже с подъёмом оси над поверхностью). Смена стороны столешницы это ввод: к точке по прежней плоскости,
## дальше вертикально через плиту. Возвращает причину отказа или пусто
func _append_node(p: Vector3) -> String:
	var last: Variant = _last_point()
	if last != null and Mount.under_plate((last as Vector3).y) != Mount.under_plate(p.y):
		var why := Mount.hole_reason(p)
		if why != "":
			return why
		points.append(Vector3(p.x, (last as Vector3).y, p.z))
	points.append(p)
	return ""


## Точка на поверхности под клеммой (с подъёмом оси): провод спускается к ней вертикально и дальше лежит. null: поверхности нет
## или клемма уже у поверхности. Луч идёт вниз от клеммы, поэтому у клеммы на нижней полке плита над ней не мешает
func _drop(t: PowerTerminal) -> Variant:
	var from := t.global_position + Vector3.UP * 0.05
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 200.0, Global.active_layers(["ground", "tracks", "plaster", "underside"]))
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var p: Vector3 = hit.position + Vector3.UP * _lift()
	if p.y >= t.global_position.y - 0.05:
		return null
	return p


func _surface_hit() -> Dictionary:
	return controller.get_mouse_ray(Mount.wire_mask(Global.active_layers(["ground", "tracks", "plaster"])))


# ------ Завершение ------

func _terminal_reason(t: PowerTerminal) -> String:
	if _resume != null:
		return _resume.end_refuse_reason(_resume_which, t)
	if start != null:
		return PowerTerminal.refuse_reason(start, t)
	return "" if t.is_free() else "на клемме уже есть провод"


## Трасса в порядке провода (от a к b): у продолженного начала порядок обращён
func _wire_points() -> PackedVector3Array:
	var pts := points.duplicate()
	if _resume != null and _resume_which == &"a":
		pts.reverse()
	return pts


func _finish_on_terminal(t: PowerTerminal) -> void:
	if _terminal_reason(t) != "":
		return   # причина уже показана у курсора
	var d: Variant = _drop(t)
	if d != null:
		var why := _append_node(d)
		if why != "":
			LYM.notice.emit(why)
			return
	if _resume != null:
		_resume.reroute(_wire_points(), _resume_which, t)
	else:
		# провод всегда ведётся от клеммы выше по току: порядок концов не важен для сети
		C_Wire.create_wire(controller.entities_root, start, t, points)
	_reset()


## Закончить провод здесь без подключения: свободный конец в точке под курсором (или в последнем узле, если курсор не над поверхностью)
func _finish_free() -> void:
	if not _active:
		return
	var hit := _surface_hit()
	if not hit.is_empty():
		var why := _append_node(hit.position + Vector3.UP * _lift())
		if why != "":
			LYM.notice.emit(why)
			return
	if points.size() + (1 if start != null else 0) < 2:
		LYM.notice.emit("Провод слишком короткий: поставьте хотя бы одну точку")
		return
	if _resume != null:
		_resume.reroute(_wire_points(), _resume_which, null)
	else:
		C_Wire.create_wire(controller.entities_root, start, null, points)
	_reset()


# ------ Мышь ------

func _terminal_under_mouse() -> PowerTerminal:
	var hit := controller.get_mouse_ray(Global.active_layers(["power"]))
	if hit.is_empty():
		return null
	return hit.collider as PowerTerminal


func _end_under_mouse() -> WireEnd:
	var hit := controller.get_mouse_ray(Global.active_layers(["power"]))
	if hit.is_empty():
		return null
	return hit.collider as WireEnd


func _set_hover(t: PowerTerminal) -> void:
	if t == _hover:
		return
	if is_instance_valid(_hover):
		_hover.set_highlight(false)
	_hover = t
	if is_instance_valid(_hover):
		_hover.set_highlight(true)


func _set_hover_end(h: WireEnd) -> void:
	if h == _hover_end:
		return
	if is_instance_valid(_hover_end):
		_hover_end.set_highlight(false)
	_hover_end = h
	if is_instance_valid(_hover_end):
		_hover_end.set_highlight(true)


func _update_preview(t: PowerTerminal) -> void:
	var im := _preview.mesh as ImmediateMesh
	im.clear_surfaces()
	InfoTips.clear(self)
	if not _active:
		return
	var end := Vector3.ZERO
	var ok := true
	if t != null:
		end = t.global_position
		var why := _terminal_reason(t)
		if why != "":
			ok = false
			InfoTips.show_lines(self, [InfoTips.danger(why)])
	else:
		var hit := _surface_hit()
		if hit.is_empty():
			return
		end = hit.position + Vector3.UP * _lift()
	(_preview.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.85, 0.2) if ok else Color(1.0, 0.25, 0.2)
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	if start != null:
		im.surface_add_vertex(start.global_position)
	for p in points:
		im.surface_add_vertex(p)
	im.surface_add_vertex(end)
	im.surface_end()
