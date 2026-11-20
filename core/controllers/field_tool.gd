class_name FieldTool extends Node

# XX claude-terra 13.14 H1b (новый файл)
##########################
## Шпатлёвка (ATTN_13 §13.14). Кладёт слой на стол или на листы пенопласта: прямоугольник, полигон или вся столешница.
##########################
## Слой не привязан к листу: он лежит на столе (пол 0) или на верху листа под ним и едет вместе с полом (TGM.field).
## Положить слой можно в любой момент, слой можно снять Ctrl+ЛКМ. Форму выбирает пресет (facet "shape": rect, polygon, table),
## ToolController кладёт её в shape перед enter(). Слой кладётся толщиной BASE_LAYERS (там, где уже толще, ничего не меняется)
## и только на область стола. Кисти-карточки (H2) работают с тем же полем и накладываются поверх.
## Ввод: ЛКМ угол (прямоугольник, второй клик кладёт) или вершина (полигон, клик по первой вершине или Enter кладёт),
## стол: ЛКМ кладёт на всю столешницу; Ctrl вместе с кликом или Enter снимает слой вместо укладки,
## Backspace убрать вершину, ПКМ сбросить (без рисунка выйти в SelectTool), Ctrl+Z отменить последнюю правку поля.
## Вершины на мировой сетке terrain_grid_step. Инструмент вызывает ToolController: enter, exit, handle_input, process_tick.

const SHAPE_RECT := &"rect"
const SHAPE_POLYGON := &"polygon"
const SHAPE_TABLE := &"table"
const SHAPES := [SHAPE_RECT, SHAPE_POLYGON, SHAPE_TABLE]
const SHAPE_NAMES := {&"rect": "прямоугольник", &"polygon": "полигон", &"table": "вся столешница"}
## Толщина укладываемого слоя, слоёв
const BASE_LAYERS := 1.0

const COL_OK := Color(0.45, 1.0, 0.65)
const COL_BAD := Color(1.0, 0.3, 0.3)
const COL_ERASE := Color(1.0, 0.55, 0.25)
const COL_CHAIN := Color(1.0, 0.85, 0.3)
const COL_CURSOR := Color(0.5, 0.9, 1.0)
const COL_CLOSE := Color(0.4, 1.0, 0.5)
const MSG_TIME := 2.5
const NOTE_PIXEL_SIZE := 0.0015
const NOTE_FONT_SIZE := 32
## Высота линий превью над поверхностью, ю
const LIFT := 0.05

var controller: ToolController
## Форма. Задаёт ToolController из пресета до enter()
var shape: StringName = SHAPE_RECT

var _drawing := false
var _verts := PackedVector2Array()      # вершины (мировые XZ, на сетке); у прямоугольника одна, угол A
var _cursor := Vector2.ZERO
var _has_cursor := false
var _plane_y := 0.0                     # высота плоскости, по которой водим курсор после первого клика
var _erase := false                     # Ctrl зажат: клик снимает слой
var _closing := false                   # курсор на первой вершине полигона: клик кладёт
var _reason := ""                       # почему сейчас нельзя положить ("" - можно)
var _dirty := true
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0

var _mi: MeshInstance3D
var _imm: ImmediateMesh
var _label: Label3D


func enter() -> void:
	if not SHAPES.has(shape):
		shape = SHAPE_RECT
	_reset_draw()
	_ensure_preview()
	_set_hint_contexts(true)
	controller.publish_selection(null)


func exit(_to_drag: bool = false) -> void:
	_reset_draw()
	_set_hint_contexts(false)
	if is_instance_valid(_mi):
		_mi.queue_free()
	if is_instance_valid(_label):
		_label.queue_free()
	_mi = null
	_imm = null
	_label = null
	controller.select_build_object(null)   # снять нажатие с кнопки каталога


## Подсказки: контекст по форме (прямоугольник это отсутствие контекстов)
func _set_hint_contexts(on: bool) -> void:
	Hints.set_context(&"field_polygon", on and shape == SHAPE_POLYGON)
	Hints.set_context(&"field_table", on and shape == SHAPE_TABLE)


## --- Ввод ---

func handle_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed:
			_rmb_pos = mb.position
		elif _rmb_pos.distance_to(mb.position) < 5:   # короткий клик, а не сдвиг камеры
			if _drawing:
				_reset_draw()
			else:
				controller.switch_tool(controller.select_tool)
		return
	if mb and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		_erase = mb.ctrl_pressed
		_on_click()
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	# Ctrl+Enter снимает слой: Actions.pressed требует точного совпадения модификаторов, поэтому Enter с Ctrl смотрим по клавише
	var enter_key := k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER
	if Actions.pressed(event, &"shape_confirm") or (enter_key and k.ctrl_pressed):
		if _drawing and shape == SHAPE_POLYGON:
			_erase = k.ctrl_pressed
			_commit(_polygon())
		return
	if Actions.pressed(event, &"shape_undo"):
		_undo_vertex()
		return
	if Actions.pressed(event, &"tool_undo"):
		_undo_edit()


func _on_click() -> void:
	if not _has_cursor:
		return
	if shape == SHAPE_TABLE:
		_commit_table()
		return
	if not _drawing:
		_drawing = true
		_verts = PackedVector2Array([_cursor])
		_dirty = true
		return
	if shape == SHAPE_POLYGON:
		if _closing:
			_commit(_polygon())
		else:
			var chain := _verts.duplicate()
			chain.append(_cursor)
			var why := C_Contour.validate_chain(chain)
			if why != "":
				_say(why)
			else:
				_verts.append(_cursor)
				_dirty = true
	else:
		_commit(_rect(_verts[0], _cursor))


## Backspace: полигон убирает последнюю вершину, прямоугольник и последняя вершина отменяют рисунок
func _undo_vertex() -> void:
	if not _drawing:
		return
	if shape == SHAPE_POLYGON and _verts.size() > 1:
		_verts.remove_at(_verts.size() - 1)
	else:
		_reset_draw()
	_dirty = true


func _undo_edit() -> void:
	if TGM.field.undo():
		TGM.field_reclip()
		_say("Правка отменена")
	else:
		_say("Отменять нечего")


## --- Укладка ---

## Прямоугольник по двум углам. Пустой, если одна из сторон нулевая
static func _rect(a: Vector2, b: Vector2) -> PackedVector2Array:
	if is_equal_approx(a.x, b.x) or is_equal_approx(a.y, b.y):
		return PackedVector2Array()
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	return PackedVector2Array([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)])


## Полигон по вершинам. Пустой, если вершин мало
func _polygon() -> PackedVector2Array:
	if _verts.size() < 3:
		return PackedVector2Array()
	return _verts.duplicate()


## Почему этот полигон положить нельзя ("" можно)
func _why_poly(poly: PackedVector2Array) -> String:
	if poly.is_empty():
		return "Нулевой размер"
	if shape == SHAPE_POLYGON:
		var why := C_Contour.validate(poly)
		if why != "":
			return why
	return ""


func _commit(poly: PackedVector2Array) -> void:
	if not LYM.has_table():
		_say(LYM.EMPTY_NOTE)
		return
	var why := _why_poly(poly)
	if why != "":
		_say(why)
		return
	var n := TGM.field_lay(poly, BASE_LAYERS, _erase)
	_finish(n)


func _commit_table() -> void:
	if not LYM.has_table():
		_say(LYM.EMPTY_NOTE)
		return
	_finish(TGM.field_lay_table(BASE_LAYERS, _erase))


func _finish(n: int) -> void:
	if n == 0:
		_say("Здесь уже нет слоя" if _erase else "Здесь уже лежит слой не тоньше")
		return
	_say(("Снято узлов: %d" if _erase else "Положено узлов: %d") % n + " (Ctrl+Z отмена)")
	_reset_draw()


func _reset_draw() -> void:
	_drawing = false
	_verts = PackedVector2Array()
	_closing = false
	_reason = ""
	_dirty = true


func _say(text: String) -> void:
	_msg = text
	_msg_t = MSG_TIME
	_dirty = true


## --- Тик: курсор и превью ---

func process_tick(delta: float) -> void:
	if Global.current_mode != &"build":
		controller.switch_tool(controller.select_tool)
		return
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			_msg = ""
			_dirty = true
	var ctrl := Input.is_key_pressed(KEY_CTRL)
	if ctrl != _erase:
		_erase = ctrl
		_dirty = true

	var p := Vector2.ZERO
	if _drawing:
		var ph := controller.get_mouse_plane_hit(_plane_y)
		if ph.is_empty():
			return
		p = Vector2(ph.position.x, ph.position.z)
	else:
		var hit := controller.get_mouse_ray(Global.active_layers(["ground"]))
		if hit.is_empty():
			if _has_cursor:
				_has_cursor = false
				_dirty = true
			_hide_preview()
			return
		if not is_equal_approx(hit.position.y, _plane_y):
			_plane_y = hit.position.y
			_dirty = true
		p = Vector2(hit.position.x, hit.position.z)

	var step: float = Global.settings.terrain_grid_step
	var c := Vector2(snappedf(p.x, step), snappedf(p.y, step))
	if not _has_cursor or not c.is_equal_approx(_cursor):
		_cursor = c
		_has_cursor = true
		_dirty = true
	if _dirty:
		_dirty = false
		_refresh()


func _refresh() -> void:
	_reason = ""
	_closing = false
	var poly := PackedVector2Array()
	var step: float = Global.settings.terrain_grid_step
	if _drawing and _has_cursor:
		if shape == SHAPE_POLYGON:
			_closing = _verts.size() >= 3 and _cursor.distance_to(_verts[0]) < step * 0.5
			if _closing:
				poly = _polygon()
				_reason = _why_poly(poly)
			else:
				var chain := _verts.duplicate()
				chain.append(_cursor)
				_reason = C_Contour.validate_chain(chain)
		else:
			poly = _rect(_verts[0], _cursor)
			_reason = _why_poly(poly)
	_redraw(poly)
	_update_note()


func _ensure_preview() -> void:
	if is_instance_valid(_mi):
		return
	_imm = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "FieldToolPreview"
	_mi.mesh = _imm
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	_mi.material_override = m
	add_child(_mi)   # узел инструмента не Node3D: превью живёт в мировых координатах
	_label = Label3D.new()
	_label.name = "FieldToolNote"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.no_depth_test = true
	_label.pixel_size = NOTE_PIXEL_SIZE
	_label.font_size = NOTE_FONT_SIZE
	_label.outline_size = 8
	add_child(_label)


func _hide_preview() -> void:
	if _imm:
		_imm.clear_surfaces()
	if is_instance_valid(_label):
		_label.visible = false


func _line_color() -> Color:
	if _reason != "":
		return COL_BAD
	return COL_ERASE if _erase else COL_OK


## Контур области, ломаная рисунка и крест курсора. Для режима «стол» контуры стола
func _redraw(poly: PackedVector2Array) -> void:
	if _imm == null:
		return
	_imm.clear_surfaces()
	if not _has_cursor:
		return
	var y := _plane_y + LIFT
	var col := _line_color()
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	var arm := 0.6
	_line(Vector3(_cursor.x - arm, y, _cursor.y), Vector3(_cursor.x + arm, y, _cursor.y), COL_CURSOR)
	_line(Vector3(_cursor.x, y, _cursor.y - arm), Vector3(_cursor.x, y, _cursor.y + arm), COL_CURSOR)
	if shape == SHAPE_TABLE:
		for sp in TGM.field_table_polygons():
			_ring(sp, y, COL_ERASE if _erase else COL_OK)
	elif _drawing:
		if not poly.is_empty():
			_ring(poly, y, col)
		elif shape == SHAPE_POLYGON:
			# незамкнутая ломаная: готовые рёбра и ребро к курсору
			var chain := _verts.duplicate()
			chain.append(_cursor)
			for i in chain.size() - 1:
				_line(Vector3(chain[i].x, y, chain[i].y), Vector3(chain[i + 1].x, y, chain[i + 1].y),
						COL_CHAIN if (i < chain.size() - 2 or _reason == "") else COL_BAD)
		for v in _verts:   # кресты поставленных вершин
			_line(Vector3(v.x - 0.4, y, v.y), Vector3(v.x + 0.4, y, v.y), COL_CHAIN)
			_line(Vector3(v.x, y, v.y - 0.4), Vector3(v.x, y, v.y + 0.4), COL_CHAIN)
		if _closing:   # клик замкнёт контур
			var f := _verts[0]
			_line(Vector3(f.x - 0.8, y, f.y - 0.8), Vector3(f.x + 0.8, y, f.y + 0.8), COL_CLOSE)
			_line(Vector3(f.x - 0.8, y, f.y + 0.8), Vector3(f.x + 0.8, y, f.y - 0.8), COL_CLOSE)
	_imm.surface_end()


func _ring(poly: PackedVector2Array, y: float, c: Color) -> void:
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		_line(Vector3(a.x, y, a.y), Vector3(b.x, y, b.y), c)


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_imm.surface_set_color(c)
	_imm.surface_add_vertex(a)
	_imm.surface_set_color(c)
	_imm.surface_add_vertex(b)


## Подпись у курсора: что делаем и почему нельзя
func _update_note() -> void:
	if not is_instance_valid(_label):
		return
	if not _has_cursor:
		_label.visible = false
		return
	var lines: Array[String] = [
		"Шпатлёвка · %s · %s" % [SHAPE_NAMES.get(shape, "прямоугольник"), "снять (Ctrl)" if _erase else "слой %.0f" % BASE_LAYERS]]
	var col := Color.WHITE
	if _msg != "":
		lines.append(_msg)
		col = Color(1.0, 0.85, 0.3)
	elif _drawing and _reason != "":
		lines.append(_reason)
		col = Color(1.0, 0.35, 0.35)
	elif shape == SHAPE_TABLE:
		lines.append("Клик: на всю столешницу")
	_label.text = "\n".join(lines)
	_label.modulate = col
	_label.position = Vector3(_cursor.x, _plane_y + 1.6, _cursor.y)
	_label.visible = true
