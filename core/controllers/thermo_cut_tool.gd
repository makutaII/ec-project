class_name ThermoCutTool extends Node

# XX claude-terra 13.3 S2 (новый файл)
##########################
## Терморезак (ATTN_13 §13.3). Вырезы в листах пенопласта: прямоугольник и полигон.
##########################
## Инструмент не создаёт объектов: вырез задаётся в мире (полигон XZ и диапазон высот), а FoamCutter.apply
## превращает его в обычные FoamCut каждого листа под ним (стопка листов режется вместе). Формат сейва не меняется.
## Форму выбирает пресет (facet "shape": "rect" или "polygon"), ToolController кладёт её в shape перед enter().
##
## Плоскость выреза = верх поверхности под курсором до первого клика (как D5 при рисовании листа), после клика она
## закреплена, R/F сдвигают её по слоям. Вырез идёт от плоскости вниз на depth слоёв или насквозь (End).
## Вершины на мировой сетке terrain_grid_step.
## Ввод: ЛКМ угол или вершина, второй клик (прямоугольник) или клик по первой вершине / Enter (полигон) режут,
## Backspace убрать вершину, ПКМ сбросить (без рисунка выйти в SelectTool), R/F и Shift+R/F, PgUp/PgDn плоскость,
## Ctrl+R/F глубина (Shift ×5), End насквозь, Ctrl+Z отменить последний вырез.
## Инструмент вызывает ToolController: enter, exit, handle_input, process_tick (как у BuildTool).

const SHAPE_RECT := &"rect"
const SHAPE_POLYGON := &"polygon"

const COL_OK := Color(0.45, 1.0, 0.65)
const COL_BAD := Color(1.0, 0.3, 0.3)
const COL_CHAIN := Color(1.0, 0.85, 0.3)
const COL_CURSOR := Color(0.5, 0.9, 1.0)
const COL_CLOSE := Color(0.4, 1.0, 0.5)

## Глубина выреза, слоёв (как толщина листа)
const MAX_DEPTH := C_TerrainLayer.MAX_LEVELS
## Наибольший сдвиг плоскости от поверхности, слоёв
const MAX_SHIFT := 64
## Сколько последних вырезов помнит Ctrl+Z
const MAX_HISTORY := 50
const MSG_TIME := 2.5
const NOTE_PIXEL_SIZE := 0.0015
const NOTE_FONT_SIZE := 32

var controller: ToolController
## Форма выреза. Задаёт ToolController из пресета до enter()
var shape: StringName = SHAPE_RECT

var _drawing := false
var _verts := PackedVector2Array()      # вершины (мировые XZ, на сетке); у прямоугольника одна, угол A
var _cursor := Vector2.ZERO
var _has_cursor := false
var _base_y := 0.0                      # высота поверхности под первым кликом, кратна layer_height
var _dy := 0                            # сдвиг плоскости от поверхности, слоёв
var _depth := 1
var _through := false                   # насквозь, до стола
var _dirty := true
var _reason := ""                       # почему сейчас нельзя резать ("" - можно или ещё нечего резать)
var _hits := 0                          # сколько листов заденет вырез
var _closing := false                   # курсор на первой вершине полигона: клик режет
var _history: Array = []                # Array из Array[Dictionary]: записи FoamCutter.apply, последняя в конце
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0

var _mi: MeshInstance3D
var _imm: ImmediateMesh
var _label: Label3D


func enter() -> void:
	_reset_draw()
	_ensure_preview()
	Hints.set_context(&"cut_polygon", shape == SHAPE_POLYGON)
	controller.publish_selection(null)


func exit(_to_drag: bool = false) -> void:
	_reset_draw()
	Hints.set_context(&"cut_polygon", false)
	if is_instance_valid(_mi):
		_mi.queue_free()
	if is_instance_valid(_label):
		_label.queue_free()
	_mi = null
	_imm = null
	_label = null
	controller.select_build_object(null)   # снять нажатие с кнопки каталога


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
		_on_click()
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		if shape == SHAPE_POLYGON and _drawing:
			_try_commit(_polygon_shape())
		return
	if k.keycode == KEY_BACKSPACE:
		_undo_vertex()
		return
	if k.keycode == KEY_END:
		_through = not _through
		_dirty = true
		return
	if k.ctrl_pressed and k.keycode == KEY_Z:
		_undo_cut()
		return

	# R/F (по физической клавише): плоскость. Ctrl: глубина. Shift ×5. PgUp/PgDn: ×5
	var dir := 0
	var big := k.shift_pressed
	if k.keycode == KEY_PAGEUP:
		dir = 1
		big = true
	elif k.keycode == KEY_PAGEDOWN:
		dir = -1
		big = true
	elif k.keycode == KEY_R or k.physical_keycode == KEY_R:
		dir = 1
	elif k.keycode == KEY_F or k.physical_keycode == KEY_F:
		dir = -1
	if dir == 0:
		return
	var n := dir * (ElevationInput.BIG_STEP if big else 1)
	if k.ctrl_pressed:
		_depth = clampi(_depth + n, 1, MAX_DEPTH)
		_through = false
	else:
		_dy = clampi(_dy + n, -MAX_SHIFT, MAX_SHIFT)
	_dirty = true


func _on_click() -> void:
	if not _has_cursor:
		return
	if not _drawing:
		_drawing = true
		_verts = PackedVector2Array([_cursor])
		_dirty = true
		return
	if shape == SHAPE_POLYGON:
		if _closing:
			_try_commit(_polygon_shape())
		else:
			var chain := _verts.duplicate()
			chain.append(_cursor)
			var why := C_Contour.validate_chain(chain)
			if why != "":
				_say(why)
				return
			_verts.append(_cursor)
			_dirty = true
	else:
		_try_commit(FoamCutter.rect(_verts[0], _cursor))


## Backspace: полигон убирает последнюю вершину, прямоугольник отменяет рисунок
func _undo_vertex() -> void:
	if not _drawing:
		return
	if shape == SHAPE_POLYGON and _verts.size() > 1:
		_verts.remove_at(_verts.size() - 1)
	else:
		_drawing = false
		_verts = PackedVector2Array()
	_dirty = true


func _undo_cut() -> void:
	if _history.is_empty():
		_say("Отменять нечего")
		return
	var recs: Array[Dictionary] = _history.pop_back()
	var n := FoamCutter.revert(recs)
	_say("Отменено вырезов: %d" % n if n > 0 else "Вырез уже пропал (лист удалён или перестроен)")


## --- Резка ---

## Полигон по вершинам (замкнут на первую). Пустой, если вершин мало
func _polygon_shape() -> PackedVector2Array:
	return FoamCutter.polygon(_verts)


func _plane_y() -> float:
	var T: float = Global.settings.layer_height
	return _base_y + float(_dy) * T


## Нижняя отметка выреза. Насквозь: ниже стола
func _y_low() -> float:
	if _through:
		return -1.0
	var T: float = Global.settings.layer_height
	return _plane_y() - float(_depth) * T


func _try_commit(poly: PackedVector2Array) -> void:
	var why := FoamCutter.check(poly) if not poly.is_empty() else "Нулевой размер"
	if why != "":
		_say(why)
		return
	var recs := FoamCutter.apply(poly, _y_low(), _plane_y())
	if recs.is_empty():
		_say("Здесь нет пенопласта на этих слоях")
		return
	_history.append(recs)
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	var layers := {}
	for r in recs:
		layers[r["layer"]] = true
	_say("Вырезано в листах: %d (Ctrl+Z отмена)" % layers.size())
	_reset_draw()


func _reset_draw() -> void:
	_drawing = false
	_verts = PackedVector2Array()
	_closing = false
	_reason = ""
	_hits = 0
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

	var T: float = Global.settings.layer_height
	var p := Vector2.ZERO
	if _drawing:
		var ph := controller.get_mouse_plane_hit(_plane_y())
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
		var by := snappedf(hit.position.y, T)
		if not is_equal_approx(by, _base_y):
			_base_y = by
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


## Пересчёт состояния выреза и превью
func _refresh() -> void:
	_reason = ""
	_hits = 0
	_closing = false
	var poly := PackedVector2Array()
	var step: float = Global.settings.terrain_grid_step
	if _drawing and _has_cursor:
		if shape == SHAPE_POLYGON:
			_closing = _verts.size() >= 3 and _cursor.distance_to(_verts[0]) < step * 0.5
			if _closing:
				poly = _polygon_shape()
				_reason = FoamCutter.check(poly)
			else:
				var chain := _verts.duplicate()
				chain.append(_cursor)
				_reason = C_Contour.validate_chain(chain)
		else:
			poly = FoamCutter.rect(_verts[0], _cursor)
			_reason = "Нулевой размер" if poly.is_empty() else FoamCutter.check(poly)
	if not poly.is_empty() and _reason == "":
		_hits = FoamCutter.affected(poly, _y_low(), _plane_y()).size()
		if _hits == 0:
			_reason = "Здесь нет пенопласта на этих слоях"
	_redraw(poly)
	_update_note()


func _ensure_preview() -> void:
	if is_instance_valid(_mi):
		return
	_imm = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "ThermoCutPreview"
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
	_label.name = "ThermoCutNote"
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


## Контур выреза сверху и снизу, рёбра по вершинам, ломаная рисунка и крест курсора
func _redraw(poly: PackedVector2Array) -> void:
	if _imm == null:
		return
	_imm.clear_surfaces()
	if not _has_cursor:
		return
	var top := _plane_y() + 0.02
	var bottom := maxf(_y_low(), 0.0)
	var ok := _reason == ""
	var col := COL_OK if ok else COL_BAD

	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	# крест курсора
	var arm := 0.6
	_line(Vector3(_cursor.x - arm, top, _cursor.y), Vector3(_cursor.x + arm, top, _cursor.y), COL_CURSOR)
	_line(Vector3(_cursor.x, top, _cursor.y - arm), Vector3(_cursor.x, top, _cursor.y + arm), COL_CURSOR)
	if _drawing:
		if not poly.is_empty():
			_ring(poly, top, col)
			_ring(poly, bottom, col)
			for v in poly:
				_line(Vector3(v.x, top, v.y), Vector3(v.x, bottom, v.y), col)
		elif shape == SHAPE_POLYGON:
			# незамкнутая ломаная: готовые рёбра и ребро к курсору
			var chain := _verts.duplicate()
			chain.append(_cursor)
			for i in chain.size() - 1:
				_line(Vector3(chain[i].x, top, chain[i].y), Vector3(chain[i + 1].x, top, chain[i + 1].y),
						COL_CHAIN if (i < chain.size() - 2 or ok) else COL_BAD)
		for v in _verts:   # кресты поставленных вершин
			_line(Vector3(v.x - 0.4, top, v.y), Vector3(v.x + 0.4, top, v.y), COL_CHAIN)
			_line(Vector3(v.x, top, v.y - 0.4), Vector3(v.x, top, v.y + 0.4), COL_CHAIN)
		if _closing:   # клик замкнёт контур
			var f := _verts[0]
			_line(Vector3(f.x - 0.8, top, f.y - 0.8), Vector3(f.x + 0.8, top, f.y + 0.8), COL_CLOSE)
			_line(Vector3(f.x - 0.8, top, f.y + 0.8), Vector3(f.x + 0.8, top, f.y - 0.8), COL_CLOSE)
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


## Подпись у курсора: что режем и почему нельзя
func _update_note() -> void:
	if not is_instance_valid(_label):
		return
	if not _has_cursor:
		_label.visible = false
		return
	var T: float = Global.settings.layer_height
	var depth_text := "насквозь" if _through else "глубина %d" % _depth
	var lines: Array[String] = [
		"Терморезак · %s" % ("полигон" if shape == SHAPE_POLYGON else "прямоугольник"),
		"Плоскость: ур. %d · %s" % [roundi(_plane_y() / T), depth_text]]
	var col := Color.WHITE
	if _msg != "":
		lines.append(_msg)
		col = Color(1.0, 0.85, 0.3)
	elif _drawing and _reason != "":
		lines.append(_reason)
		col = Color(1.0, 0.35, 0.35)
	elif _drawing and _hits > 0:
		lines.append("Заденет листов: %d" % _hits)
		col = COL_OK
	_label.text = "\n".join(lines)
	_label.modulate = col
	_label.position = Vector3(_cursor.x, _plane_y() + 1.6, _cursor.y)
	_label.visible = true
