class_name PaintTool extends Node

# XX claude-terra 13.13 K2 (новый файл)
##########################
## Кисть «Трава», «Скала», «Гравий» (ATTN_13 §13.13). Красит оболочку гипсового бинта в PaintMap (TGM.paint).
##########################
## ЛКМ красит (держать и вести), Ctrl+ЛКМ стирает (режим выбирается в начале мазка), [ и ] радиус 1..MAX_RADIUS ю (Shift ×5),
## Ctrl+Z отменяет последний мазок, ПКМ выход. Красит только клетки под листами с гипсовым бинтом (PlasterSkin.is_plastered_at):
## на листе без бинта подпись «Сначала гипсовый бинт». Ступени, TGM, вода и физика не меняются, пересчёта геометрии мазок не вызывает.
## Класс кисти берётся из facet "brush" кнопки каталога (brush_from_facet).

const MAX_HISTORY := 50
const MSG_TIME := 2.5
const MIN_RADIUS := 1
const MAX_RADIUS := 20
const DEFAULT_RADIUS := 3
## Жёсткость кисти: внутри этой доли радиуса сила полная, дальше плавный спад
const HARDNESS := 0.5
## Сила одного штампа. Штампы идут вдоль мазка с шагом SPACING * радиус и накапливаются до полной краски
const STRENGTH := 0.5
const SPACING := 0.25
const RING_POINTS := 48
const RING_LIFT := 0.08
const COL_PAINT := Color(0.8, 0.95, 1.0)
const COL_ERASE := Color(1.0, 0.6, 0.3)
const COL_BAD := Color(1.0, 0.35, 0.3)

const NAMES := {PaintMap.GRASS: "Трава", PaintMap.ROCK: "Скала", PaintMap.GRAVEL: "Гравий"}

var controller: ToolController
## Класс кисти (PaintMap.GRASS, ROCK, GRAVEL); ставит ToolController перед switch_tool
var brush := PaintMap.GRASS

var _radius := DEFAULT_RADIUS
var _hover_ok := false          # под курсором клетка с бинтом
var _hover := Vector2.ZERO      # точка мира (x, z)
var _hover_sheet := false       # курсор над листом, но без бинта
var _painting := false
var _erasing := false
var _last := Vector2.ZERO       # конец последнего штампа в мазке
var _history: Array = []        # записи PaintMap.end_stroke
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0
var _dirty := true

var _mi: MeshInstance3D
var _imm: ImmediateMesh


## Класс кисти по facet кнопки каталога. Неизвестное значение: трава
static func brush_from_facet(f: String) -> int:
	match f:
		"rock":
			return PaintMap.ROCK
		"gravel":
			return PaintMap.GRAVEL
	return PaintMap.GRASS


func enter() -> void:
	_painting = false
	_hover_ok = false
	_hover_sheet = false
	_dirty = true
	_ensure_preview()
	Hints.set_context(&"paint", true)
	controller.publish_selection(null)


func exit(_to_drag: bool = false) -> void:
	_finish_stroke()
	Hints.set_context(&"paint", false)
	if is_instance_valid(_mi):
		_mi.queue_free()
	InfoTips.clear(self)
	_mi = null
	_imm = null
	controller.select_build_object(null)   # снять нажатие с кнопки каталога


## --- Ввод ---

func handle_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed:
			_rmb_pos = mb.position
		elif _rmb_pos.distance_to(mb.position) < 5:   # короткий клик, а не сдвиг камеры
			controller.switch_tool(controller.select_tool)
		return
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_start_stroke(mb.ctrl_pressed)
		else:
			_finish_stroke()
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if Actions.pressed(event, &"tool_undo"):
		_undo()
		return
	var w := Actions.axis_step(event, &"width_up", &"width_down", 5)
	if w != 0:
		_radius = clampi(_radius + w, MIN_RADIUS, MAX_RADIUS)
		_say("Радиус кисти %d ю" % _radius)


func _start_stroke(erase: bool) -> void:
	if _painting:
		return
	if not _hover_ok:
		_say("Сначала гипсовый бинт" if _hover_sheet else "Наведите на лист с гипсовым бинтом")
		return
	var map := TGM.paint
	map.ensure_cell(PlasterSkin.cell_size())
	if erase and map.is_empty():
		_say("Красить нечем стирать")
		return
	_painting = true
	_erasing = erase
	map.begin_stroke()
	_stamp(_hover)
	_last = _hover


func _finish_stroke() -> void:
	if not _painting:
		return
	_painting = false
	var rec := TGM.paint.end_stroke()
	if rec.is_empty():
		return
	_history.append(rec)
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	TGM.plaster_dirty()   # K3: на плоском верху оболочка появляется в крашеных ячейках, это геометрия: после мазка


func _stamp(p: Vector2) -> void:
	var cls := PaintMap.ERASE if _erasing else brush
	TGM.paint.stamp(p, float(_radius), HARDNESS, cls, STRENGTH, TGM.skin.is_plastered_at)


func _undo() -> void:
	if _painting:
		return
	if _history.is_empty():
		_say("Отменять нечего")
		return
	TGM.paint.restore(_history.pop_back())
	TGM.plaster_dirty()
	_say("Мазок отменён")


func _say(text: String) -> void:
	_msg = text
	_msg_t = MSG_TIME
	_dirty = true


## --- Тик: наведение, мазок, превью ---

func process_tick(delta: float) -> void:
	if Global.current_mode != &"build":
		controller.switch_tool(controller.select_tool)
		return
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			_msg = ""
			_dirty = true
	if _painting and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_finish_stroke()   # кнопку отпустили над панелью или вне окна

	var ok := false
	var sheet := false
	var pos := _hover
	if not UIPointer.is_over_ui(get_viewport()):
		var hit := controller.get_mouse_ray(Global.active_layers(["ground", "plaster"]))
		if not hit.is_empty():
			var hp: Vector3 = hit.position
			pos = Vector2(hp.x, hp.z)
			ok = TGM.skin.is_plastered_at(pos)
			if not ok and hit.collider != null:
				var n: Node = hit.collider
				while n != null and not (n is Entity):
					n = n.get_parent()
				sheet = n != null and (n as Entity).get_comp(C_TerrainLayer) != null
	if ok != _hover_ok or sheet != _hover_sheet or pos != _hover:
		_hover_ok = ok
		_hover_sheet = sheet
		_hover = pos
		_dirty = true

	if _painting and ok:
		var step := maxf(float(_radius) * SPACING, TGM.paint.cell)
		var dist := _last.distance_to(pos)
		if dist >= step:
			var dir := (pos - _last) / dist
			var n := int(dist / step)
			for k in n:
				_last += dir * step
				_stamp(_last)
			_dirty = true

	if _dirty:
		_dirty = false
		_redraw()
		_update_note()


func _ensure_preview() -> void:
	if is_instance_valid(_mi):
		return
	_imm = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "PaintPreview"
	_mi.mesh = _imm
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	_mi.material_override = m
	add_child(_mi)   # узел инструмента не Node3D: превью живёт в мировых координатах


## Кольцо кисти по поверхности: высота каждой точки из поля оболочки
func _redraw() -> void:
	if _imm == null:
		return
	_imm.clear_surfaces()
	if not _hover_ok and not _hover_sheet:
		return
	var col := COL_BAD if not _hover_ok else (COL_ERASE if (_erasing if _painting else Actions.ctrl()) else COL_PAINT)
	var cy := TGM.skin.height_at(_hover)
	if is_nan(cy):
		cy = 0.0
	var r := float(_radius)
	_imm.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in RING_POINTS + 1:
		var a := TAU * float(i) / float(RING_POINTS)
		var p := _hover + Vector2(cos(a), sin(a)) * r
		var y := TGM.skin.height_at(p)
		if is_nan(y):
			y = cy
		_imm.surface_set_color(col)
		_imm.surface_add_vertex(Vector3(p.x, y + RING_LIFT, p.y))
	_imm.surface_end()


## Подсказка у курсора: кисть и сообщение (InfoToolTip, U20a)
func _update_note() -> void:
	if _imm == null:
		return
	var lines: Array = []
	if _hover_ok or _hover_sheet:
		lines.append(InfoTips.title("Кисть: %s · радиус %d ю" % [NAMES.get(brush, "?"), _radius]))
	if _msg != "":
		lines.append(InfoTips.warn(_msg))
	elif _hover_sheet and not _hover_ok:
		lines.append(InfoTips.warn("Сначала гипсовый бинт"))
	InfoTips.show_lines(self, lines)   # пустой набор снимает подсказку
