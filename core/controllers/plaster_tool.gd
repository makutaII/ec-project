class_name PlasterTool extends Node

# XX claude-terra 13.5 G3 (новый файл)
##########################
## Гипсовый бинт (ATTN_13 §13.5). Включает оболочку PlasterSkin на листах: C_TerrainLayer.smooth = ширина пандуса на слой.
##########################
## ЛКМ по листу: сглаживается весь связный холм (листы, которые касаются или лежат стопкой), Shift+ЛКМ только этот лист,
## Ctrl+ЛКМ снимает бинт (с холма, с Shift с листа). [ и ] ширина пандуса 1..4 ю на слой. Ctrl+Z отменяет последнее действие,
## ПКМ выход. Сырой пенопласт при наложении становится шпаклёвкой (стадия PLASTER), при снятии стадия остаётся.
## Геометрия, TGM и физика листов не меняются: оболочка лежит поверх ступеней (PlasterSkin).

const MAX_HISTORY := 50
const MSG_TIME := 2.5
## Листы касаются, если их контуры ближе этого расстояния, ю
const TOUCH := 0.1
const COL_ADD := Color(0.8, 0.95, 1.0)
const COL_REMOVE := Color(1.0, 0.6, 0.3)

var controller: ToolController

var _run := 2
var _hover: C_TerrainLayer
var _cluster: Array[C_TerrainLayer] = []
var _mode_key := ""             # "add/rem + single", чтобы перерисовать при смене модификаторов
var _dirty := true
var _history: Array = []        # Array из Array[Dictionary]: {"layer", "smooth", "stage"}
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0

var _mi: MeshInstance3D
var _imm: ImmediateMesh


func enter() -> void:
	_hover = null
	_cluster = []
	_dirty = true
	_ensure_preview()
	Hints.set_context(&"plaster", true)
	controller.publish_selection(null)


func exit(_to_drag: bool = false) -> void:
	Hints.set_context(&"plaster", false)
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
	if mb and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		_apply(mb.ctrl_pressed, mb.shift_pressed)
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if Actions.pressed(event, &"tool_undo"):
		_undo()
		return
	var w := Actions.axis_step(event, &"width_up", &"width_down")
	if w != 0:
		_run = clampi(_run + w, 1, C_TerrainLayer.PLASTER_MAX_RUN)
		# XX claude-terra 13.13 K0b-2: сообщение при каждом нажатии (подпись над листом видна только при наведении, а на холм
		# ширина ложится по следующему ЛКМ)
		_say("Ступень пандуса %d ю на слой (ЛКМ по холму применит)" % _run)
		_dirty = true


## Применить к холму или листу под курсором. remove: снять бинт
func _apply(remove: bool, single: bool) -> void:
	if _hover == null:
		_say("Наведите на лист")
		return
	var targets := _targets(single)
	var rec: Array[Dictionary] = []
	for l in targets:
		if remove and l.smooth == 0:
			continue
		if not remove and l.smooth == _run and l.stage >= C_TerrainLayer.FoamStage.PLASTER:
			continue
		rec.append({"layer": l, "smooth": l.smooth, "stage": l.stage})
		if remove:
			l.set_smooth(0)
		else:
			if l.stage < C_TerrainLayer.FoamStage.PLASTER:
				l.set_stage(C_TerrainLayer.FoamStage.PLASTER)
			l.set_smooth(_run)
	if rec.is_empty():
		_say("Без изменений")
		return
	_history.append(rec)
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	_say("%s листов: %d (Ctrl+Z отмена)" % ["Снято с" if remove else "Сглажено", rec.size()])


func _undo() -> void:
	while not _history.is_empty():
		var rec: Array = _history.pop_back()
		var n := 0
		for r: Dictionary in rec:
			var raw: Variant = r.get("layer")
			if not is_instance_valid(raw):
				continue
			var l := raw as C_TerrainLayer
			if l == null:
				continue
			l.set_stage(int(r["stage"]))
			l.set_smooth(int(r["smooth"]))
			n += 1
		if n > 0:
			_say("Отменено: листов %d" % n)
			_dirty = true
			return
	_say("Отменять нечего")


func _say(text: String) -> void:
	_msg = text
	_msg_t = MSG_TIME
	_dirty = true


func _targets(single: bool) -> Array[C_TerrainLayer]:
	var res: Array[C_TerrainLayer] = []
	if _hover == null:
		return res
	if single:
		res.append(_hover)
		return res
	return _cluster


## --- Связный холм ---

## Листы, связанные с l касанием или перекрытием контуров и по высоте (стопка и соседи на одном уровне)
func _cluster_of(start: C_TerrainLayer) -> Array[C_TerrainLayer]:
	var all: Array[C_TerrainLayer] = []
	var polys := {}
	for e in TGM.get_layers():
		var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
		if l == null:
			continue
		all.append(l)
		var grown: PackedVector2Array = l.world_polygon()
		var off := Geometry2D.offset_polygon(grown, TOUCH, Geometry2D.JOIN_MITER)
		polys[l] = (off[0] as PackedVector2Array) if not off.is_empty() else grown
	var res: Array[C_TerrainLayer] = [start]
	var head := 0
	while head < res.size():
		var a := res[head]
		head += 1
		for b in all:
			if res.has(b):
				continue
			if b.base_y() > a.top_y() + TGM.EPS or a.base_y() > b.top_y() + TGM.EPS:
				continue
			if not Geometry2D.intersect_polygons(polys[a], b.world_polygon()).is_empty():
				res.append(b)
	return res


## --- Тик: наведение и превью ---

func process_tick(delta: float) -> void:
	if Global.current_mode != &"build":
		controller.switch_tool(controller.select_tool)
		return
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			_msg = ""
			_dirty = true

	var found: C_TerrainLayer = null
	if not UIPointer.is_over_ui(get_viewport()):
		var hit := controller.get_mouse_ray(Global.active_layers(["ground"]))
		if not hit.is_empty() and hit.collider != null:
			var n: Node = hit.collider
			while n != null and not (n is Entity):
				n = n.get_parent()
			if n != null:
				found = (n as Entity).get_comp(C_TerrainLayer) as C_TerrainLayer
				if found != null and ((n as Entity).has_comp(C_Ghost) or (n as Entity).has_comp(C_Drag)):
					found = null
	var key := "%s%s" % [Actions.ctrl(), Actions.shift()]
	if found != _hover or key != _mode_key:
		_hover = found
		_mode_key = key
		if _hover != null:
			_cluster = _cluster_of(_hover)
		else:
			_cluster = []
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
	_mi.name = "PlasterPreview"
	_mi.mesh = _imm
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	_mi.material_override = m
	add_child(_mi)   # узел инструмента не Node3D: превью живёт в мировых координатах


## Контуры листов, которые заденет клик
func _redraw() -> void:
	if _imm == null:
		return
	_imm.clear_surfaces()
	if _hover == null:
		return
	var remove := Actions.ctrl()
	var col := COL_REMOVE if remove else COL_ADD
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	for l in _targets(Actions.shift()):
		var poly := l.world_polygon()
		var y := l.top_y() + 0.05
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			_imm.surface_set_color(col)
			_imm.surface_add_vertex(Vector3(a.x, y, a.y))
			_imm.surface_set_color(col)
			_imm.surface_add_vertex(Vector3(b.x, y, b.y))
	_imm.surface_end()


## Подсказка у курсора: что сделает клик и сообщение (InfoToolTip, U20a)
func _update_note() -> void:
	if _imm == null:
		return
	if _hover == null:
		if _msg != "":
			InfoTips.show_lines(self, [InfoTips.warn(_msg)])
		else:
			InfoTips.clear(self)
		return
	var T: float = Global.settings.layer_height
	var single := Actions.shift()
	var remove := Actions.ctrl()
	var lines: Array = []
	if remove:
		lines.append(InfoTips.title("Гипсовый бинт: снять · листов %d" % _targets(single).size()))
	else:
		lines.append(InfoTips.title("Гипсовый бинт · ступень %d ю (%.0f°) · листов %d" % [_run, rad_to_deg(atan2(T, float(_run))), _targets(single).size()]))
	if _msg != "":
		lines.append(InfoTips.warn(_msg))
	InfoTips.show_lines(self, lines)
