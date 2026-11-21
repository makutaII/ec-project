class_name BrushTool extends Node

# XX claude-terra 13.14 H2 (новый файл)
##########################
## Кисть рельефа (ATTN_13 §13.14): холм и яма, выравнивание, гравий, скалы. Меняет поле высот TGM.field.
##########################
## Модель «площадка + склон» (FieldBrush, спайк H0). Кисть описана ресурсом TerrainBrush в карточке каталога (тип поверхности, угол, радиус).
## Ввод: Ctrl+колесо подъём или яма вокруг курсора (с Shift до целого слоя), Alt+колесо радиус (запасной вариант: `,` и `.`),
## `[` и `]` угол склона (Shift ×5), ЛКМ с удержанием подтягивает поле под площадкой к высоте точки нажатия (одна правка на весь драг),
## Ctrl+Z отменяет последнюю правку поля, ПКМ выход. Мазок трогает только область стола (TGM.field_table_polygons).
## Кольца кисти: голубое площадка, жёлтое край склона, белое радиус. Оранжевое: угол смягчён, склон не вмещается в кисть.
## Яма не глубже слоя шпатлёвки (на нуле толщины слоя нет), пол (стол, верх листа) не трогается. Пределы сверху от листов, режимы «объекты в зоне»: H3.

const MSG_TIME := 2.5
const RING_POINTS := 48
const RING_LIFT := 0.08
const COL_PLATEAU := Color(0.45, 0.95, 1.0)
const COL_SLOPE := Color(1.0, 0.9, 0.35)
const COL_RADIUS := Color(1.0, 1.0, 1.0, 0.45)
const COL_LIMIT := Color(1.0, 0.55, 0.25)
## Не чаще раза в это время пересчитываем план для колец, с
const PREVIEW_PERIOD := 0.1
const CLIP_PERIOD := 0.5
const ANGLE_STEP := 5.0
const RADIUS_STEP := 0.5

var controller: ToolController
## Описание кисти (TerrainBrush из карточки). Ставит ToolController до enter()
var brush: TerrainBrush

var _fb := FieldBrush.new()
var _hover := Vector3.ZERO
var _hover_ok := false
var _leveling := false
var _anchor := 0.0
var _clip: Array = []
var _clip_t := 0.0
var _prev_t := 0.0
var _prev_key := ""
var _plan := {}
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0

var _mi: MeshInstance3D
var _imm: ImmediateMesh


func enter() -> void:
	_fb = FieldBrush.new()
	_fb.load_brush(brush)
	_leveling = false
	_hover_ok = false
	_plan = {}
	_prev_key = ""
	_clip = TGM.field_table_polygons()
	_ensure_preview()
	controller.publish_selection(null)


func exit(_to_drag: bool = false) -> void:
	_finish_level()
	if is_instance_valid(_mi):
		_mi.queue_free()
	InfoTips.clear(self)
	_mi = null
	_imm = null
	controller.select_build_object(null)   # снять нажатие с кнопки каталога


func _brush_title() -> String:
	return "Кисть · %s" % _fb.type_label()


## --- Ввод ---

func handle_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb:
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_rmb_pos = mb.position
				elif _rmb_pos.distance_to(mb.position) < 5:   # короткий клик, а не сдвиг камеры
					controller.switch_tool(controller.select_tool)
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_start_level()
				else:
					_finish_level()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_on_wheel(mb)
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if Actions.pressed(event, &"tool_undo"):
		_undo()
		return
	var a := Actions.axis_step(event, &"width_up", &"width_down", 5)
	if a != 0:
		_fb.angle = clampf(_fb.angle + float(a) * ANGLE_STEP, 5.0, 90.0)
		_prev_key = ""
		_say("Угол склона %.0f°" % _fb.angle)
		return
	# запасной ввод радиуса: на некоторых оконных менеджерах Alt+колесо перехватывается системой
	if k.physical_keycode == KEY_PERIOD or k.physical_keycode == KEY_COMMA:
		_change_radius(1.0 if k.physical_keycode == KEY_PERIOD else -1.0)


func _on_wheel(mb: InputEventMouseButton) -> void:
	var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP
	if mb.ctrl_pressed:
		get_viewport().set_input_as_handled()   # зум камеры на это колесо не нужен
		_raise(1.0 if up else -1.0, mb.shift_pressed)
	elif mb.alt_pressed:
		get_viewport().set_input_as_handled()
		_change_radius(1.0 if up else -1.0)


func _change_radius(dir_: float) -> void:
	_fb.radius = clampf(_fb.radius + dir_ * RADIUS_STEP, _fb.radius_min, _fb.radius_max)
	_prev_key = ""
	_say("Радиус кисти %.1f ю" % _fb.radius)


func _undo() -> void:
	if _leveling:
		return
	if TGM.field.undo():
		TGM.field_reclip()
		_prev_key = ""
		_say("Правка отменена")
	else:
		_say("Отменять нечего")


## --- Подъём и яма ---

## Щелчок Ctrl+колеса: площадка на notch_layers выше или ниже поверхности под курсором (whole: до целого слоя)
func _raise(dir_: float, whole: bool) -> void:
	if not _hover_ok or _leveling:
		return
	var f := TGM.field
	var c := Vector2(_hover.x, _hover.z)
	var hc := f.sample(c.x, c.y)
	var fc := f.floor_at(roundi(c.x / TerrainField.STEP), roundi(c.y / TerrainField.STEP))
	var ht := _fb.next_height(hc, dir_, whole, f.layer_height, fc)
	if absf(ht - hc) < 0.0001:
		_say("Выше некуда" if dir_ > 0.0 else "Глубже слоя не копаем")
		return
	_clip = TGM.field_table_polygons()
	f.layer_height = float(Global.settings.layer_height)
	f.begin_edit()
	var changed := _fb.stroke(f, c, ht, int(dir_), 1.0, _clip)
	f.end_edit()
	_plan = _fb.last_plan
	if not changed:
		_say("Здесь нечего менять")
	_prev_key = ""


## --- Выравнивание ЛКМ ---

func _start_level() -> void:
	if not _hover_ok or _leveling:
		return
	var f := TGM.field
	f.layer_height = float(Global.settings.layer_height)
	_anchor = f.sample(_hover.x, _hover.z)
	_clip = TGM.field_table_polygons()
	_leveling = true
	f.begin_edit()


func _finish_level() -> void:
	if not _leveling:
		return
	_leveling = false
	TGM.field.end_edit()
	_prev_key = ""


func _say(text: String) -> void:
	_msg = text
	_msg_t = MSG_TIME
	_prev_key = ""


## --- Тик ---

func process_tick(delta: float) -> void:
	if Global.current_mode != &"build":
		controller.switch_tool(controller.select_tool)
		return
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			_msg = ""
			_prev_key = ""
	if _leveling and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_finish_level()   # отпускание пришло над UI
	_clip_t += delta
	if _clip_t >= CLIP_PERIOD and not _leveling:
		_clip_t = 0.0
		_clip = TGM.field_table_polygons()
	_update_hover()
	if _leveling and _hover_ok:
		var kk := 1.0 - exp(-FieldBrush.PULL_RATE * _fb.strength * delta)
		TGM.field.layer_height = float(Global.settings.layer_height)
		_fb.stroke(TGM.field, Vector2(_hover.x, _hover.z), _anchor, 0, kk, _clip)
		_plan = _fb.last_plan
		_redraw()
		return
	_prev_t += delta
	if _prev_t >= PREVIEW_PERIOD:
		_prev_t = 0.0
		_update_preview()


func _update_hover() -> void:
	if _leveling:
		var ph := controller.get_mouse_plane_hit(_anchor)
		if ph.is_empty():
			return
		_hover = ph.position
		_hover_ok = true
		return
	var hit := controller.get_mouse_ray(Global.active_layers(["ground"]))
	if hit.is_empty():
		if _hover_ok:
			_hover_ok = false
			_prev_key = ""
			_hide_preview()
		return
	_hover = hit.position
	_hover_ok = true


## План для колец: следующий щелчок вверх в точке под курсором. Пересчёт только когда сменилась ячейка, радиус, угол или поле
func _update_preview() -> void:
	if not _hover_ok:
		return
	var f := TGM.field
	var c := Vector2(_hover.x, _hover.z)
	var key := "%d,%d|%.1f|%.0f|%d" % [roundi(c.x / TerrainField.STEP), roundi(c.y / TerrainField.STEP), _fb.radius, _fb.angle, hash(_msg)]
	if key == _prev_key:
		return
	_prev_key = key
	f.layer_height = float(Global.settings.layer_height)
	var hc := f.sample(c.x, c.y)
	var fc := f.floor_at(roundi(c.x / TerrainField.STEP), roundi(c.y / TerrainField.STEP))
	var ht := _fb.next_height(hc, 1.0, false, f.layer_height, fc)
	_plan = _fb.preview(f, c, ht, 1, _clip)
	_redraw()


## --- Превью ---

func _ensure_preview() -> void:
	if is_instance_valid(_mi):
		return
	_imm = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "BrushToolPreview"
	_mi.mesh = _imm
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	_mi.material_override = m
	add_child(_mi)


func _hide_preview() -> void:
	if _imm:
		_imm.clear_surfaces()
	InfoTips.clear(self)


func _redraw() -> void:
	if _imm == null:
		return
	_imm.clear_surfaces()
	if not _hover_ok or _plan.is_empty():
		_hide_preview()
		return
	var f := TGM.field
	var c := Vector2(_hover.x, _hover.z)
	var limited: bool = str(_plan["limit"]) == "место"
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	_ring(f, c, float(_plan["p"]), COL_PLATEAU)
	_ring(f, c, float(_plan["e"]), COL_LIMIT if limited else COL_SLOPE)
	_ring(f, c, _fb.radius, COL_RADIUS)
	_imm.surface_end()
	_update_note()


func _ring(f: TerrainField, c: Vector2, r: float, col: Color) -> void:
	var prev := Vector3.ZERO
	for n in RING_POINTS + 1:
		var a := TAU * float(n) / float(RING_POINTS)
		var x := c.x + cos(a) * r
		var z := c.y + sin(a) * r
		var v := Vector3(x, f.sample(x, z) + RING_LIFT, z)
		if n > 0:
			_imm.surface_set_color(col)
			_imm.surface_add_vertex(prev)
			_imm.surface_set_color(col)
			_imm.surface_add_vertex(v)
		prev = v


func _limit_text() -> String:
	var lim := str(_plan.get("limit", ""))
	if lim == "место":
		return "угол смягчён: склон не вмещается в кисть. Увеличьте радиус"
	if lim == "сетка":
		return "склон не уже одной ячейки"
	return ""


func _update_note() -> void:
	if _imm == null:
		return
	var f := TGM.field
	var hc := f.sample(_hover.x, _hover.z)
	var lines: Array = [InfoTips.title("%s · радиус %.1f ю · угол %.0f°" % [_brush_title(), _fb.radius, _fb.angle])]
	lines.append(InfoTips.info("высота %.2f слоя · площадка %.1f ю, склон %.1f ю, угол склона %.0f°" % [
		hc / maxf(f.layer_height, 0.001), float(_plan["p"]), float(_plan["w"]), float(_plan["ang"])]))
	var lim := _limit_text()
	if _msg != "":
		lines.append(InfoTips.warn(_msg))
	elif lim != "":
		lines.append(InfoTips.warn(lim))
	elif _leveling:
		lines.append(InfoTips.dim("выравнивание"))
	InfoTips.show_lines(self, lines)
