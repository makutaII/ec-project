class_name WaterPourTool extends Node

# XX claude-terra 13.4 W3 (новый файл)
##########################
## Налить воду (ATTN_13 §13.4). Инструмент не рисует форму: игрок указывает место, а WaterFill заливает область
## ниже уровня воды, связанную с точкой клика. Превью показывает область до клика.
##########################
## Уровень воды = верх земли под курсором (стол, дно выемки) + глубина в слоях. Домен = столешница на момент клика:
## за краем стола вода останавливается (океан у края), достроенный потом кусок стола воду не расширяет.
## Ввод: ЛКМ налить, Shift+ЛКМ осушить (убрать воду под курсором), R/F глубина (Shift ×5), PgUp/PgDn ±5,
## Ctrl+Z отменить последний налив, ПКМ выйти в SelectTool.
## Вода это Entity (data/terrain/water_body.tres) с C_Water: живая, пересчитывается при правке рельефа (листов и поля высот, H6).

const BODY_PATH := "res://data/terrain/water_body.tres"
const MAX_DEPTH := 32
const MAX_HISTORY := 50
const MSG_TIME := 2.5
## Сколько отрезков границы области рисуем в превью (океан по краю стола даёт больше, остальное опускаем)
const MAX_EDGE_LINES := 6000

const COL_OK := Color(0.45, 0.8, 1.0)
const COL_BAD := Color(1.0, 0.3, 0.3)
const COL_CURSOR := Color(0.5, 0.9, 1.0)

var controller: ToolController

var _depth := 1
var _cursor := Vector2.ZERO
var _floor_level := 0
var _has_cursor := false
var _dirty := true
var _terrain_ver := 0
var _res := {}              # последний результат WaterFill.fill
var _res_level := -1
var _res_ver := -1
var _reason := ""
var _exists := false
var _history: Array[Entity] = []
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0

var _mi: MeshInstance3D
var _imm: ImmediateMesh


func enter() -> void:
	_has_cursor = false
	_res = {}
	_dirty = true
	_ensure_preview()
	if not TGM.terrain_changed.is_connected(_on_terrain_changed):
		TGM.terrain_changed.connect(_on_terrain_changed)
	if not TGM.field.changed.is_connected(_on_field_changed):   # H6: вода считается и по полю высот
		TGM.field.changed.connect(_on_field_changed)
		TGM.field.bed_changed.connect(_on_field_changed)
	Hints.set_context(&"water_pour", true)
	controller.publish_selection(null)


func exit(_to_drag: bool = false) -> void:
	Hints.set_context(&"water_pour", false)
	if TGM.terrain_changed.is_connected(_on_terrain_changed):
		TGM.terrain_changed.disconnect(_on_terrain_changed)
	if TGM.field.changed.is_connected(_on_field_changed):
		TGM.field.changed.disconnect(_on_field_changed)
		TGM.field.bed_changed.disconnect(_on_field_changed)
	if is_instance_valid(_mi):
		_mi.queue_free()
	InfoTips.clear(self)
	_mi = null
	_imm = null
	controller.select_build_object(null)   # снять нажатие с кнопки каталога


func _on_terrain_changed(_aabb: AABB) -> void:
	_terrain_ver += 1
	_dirty = true


func _on_field_changed(_keys: Array) -> void:
	_terrain_ver += 1
	_dirty = true


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
		if mb.shift_pressed:
			_drain()
		else:
			_pour()
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if Actions.pressed(event, &"tool_undo"):
		_undo()
		return
	var n := ElevationInput.step_from_event(event)
	if n == 0:
		return
	_depth = clampi(_depth + n, 1, MAX_DEPTH)
	_dirty = true


## Налить: создать тело воды и посчитать область
func _pour() -> void:
	if not _has_cursor:
		return
	if _reason != "":
		_say(_reason)
		return
	if _exists:
		_say("Здесь уже налито на этот уровень")
		return
	var setting := load(BODY_PATH) as EntitySetting
	if setting == null:
		_say("Не найден " + BODY_PATH)
		return
	var e := controller.entity_factory.create_from_setting(setting)
	e.global_transform = Transform3D(Basis.IDENTITY, Vector3(_cursor.x, 0.0, _cursor.y))
	controller.entities_root.add_child(e)
	var w := e.get_comp(C_Water) as C_Water
	var step: float = Global.settings.terrain_grid_step
	var res := w.setup(_level(), TGM.table_rect(), step) if w != null else {"ok": false, "why": "Нет компонента воды"}
	if not res["ok"]:
		e.queue_free()
		_say(res["why"])
		return
	_history.append(e)
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	_say("Налито: %.0f ю² (Ctrl+Z отмена)" % (float(res["count"]) * step * step))
	_dirty = true


## Осушить: убрать воду под курсором (без отмены: налить заново одним кликом)
func _drain() -> void:
	var hit := controller.get_mouse_ray(Global.active_layers(["water"]))
	if hit.is_empty() or hit.collider == null:
		_say("Под курсором нет воды")
		return
	var n: Node = hit.collider
	while n != null and not (n is Entity):
		n = n.get_parent()
	if n == null:
		return
	_history.erase(n)
	(n as Entity).queue_free()
	_say("Вода убрана")
	_dirty = true


func _undo() -> void:
	while not _history.is_empty():
		var e: Entity = _history.pop_back()
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			e.queue_free()
			_say("Налив отменён")
			_dirty = true
			return
	_say("Отменять нечего")


func _say(text: String) -> void:
	_msg = text
	_msg_t = MSG_TIME
	_dirty = true


func _level() -> int:
	return maxi(1, _floor_level + _depth)


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
	# H6: луч видит и поле высот (слой plaster): дно ямы, вырытой кистью, а не стол под ним. Уровень считается от целого слоя
	# под поверхностью (дно 0,7 слоя даёт 0, глубина 1 заливает яму ровно до верха слоя 1), допуск 0,02 слоя к целому сверху
	var hit := controller.get_mouse_ray(Global.active_layers(["ground", "plaster"]))
	if hit.is_empty():
		if _has_cursor:
			_has_cursor = false
			_dirty = true
		_hide_preview()
		return
	var fl := floori(hit.position.y / T + 0.02)
	var step: float = Global.settings.terrain_grid_step
	var c := Vector2(snappedf(hit.position.x, step), snappedf(hit.position.z, step))
	if not _has_cursor or not c.is_equal_approx(_cursor) or fl != _floor_level:
		_cursor = c
		_floor_level = fl
		_has_cursor = true
		_dirty = true
	if _dirty:
		_dirty = false
		_refresh()


## Пересчёт области. Если новая точка лежит в уже посчитанной области на том же уровне, область та же: не считаем заново
func _refresh() -> void:
	var step: float = Global.settings.terrain_grid_step
	var level := _level()
	var seed_cell := WaterFill.cell_of(_cursor, step)
	var reuse = not _res.is_empty() and _res.get("ok", false) and _res_level == level and _res_ver == _terrain_ver \
			and (_res["cells"] as Dictionary).has(seed_cell)
	if not reuse:
		var ly := float(level) * float(Global.settings.layer_height)
		_res = WaterFill.fill(_cursor, ly, TGM.table_rect(), step, WaterFill.blocker_for(ly),
				WaterFill.MAX_CELLS, WaterFill.footprint_inside(), WaterFill.shore_for(ly, step))   # XX claude-table T2; H6
		_res_level = level
		_res_ver = _terrain_ver
	_reason = "" if _res["ok"] else str(_res["why"])
	_exists = false
	if _res["ok"] and is_instance_valid(controller.entities_root):
		for n in controller.entities_root.get_children():
			var e := n as Entity
			if e == null or e.is_queued_for_deletion():
				continue
			var w := e.get_comp(C_Water) as C_Water
			if w != null and w.level == level and w.has_water_at(_cursor):
				_exists = true
				break
	_redraw()
	_update_note()


func _ensure_preview() -> void:
	if is_instance_valid(_mi):
		return
	_imm = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "WaterPourPreview"
	_mi.mesh = _imm
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	_mi.material_override = m
	add_child(_mi)   # узел инструмента не Node3D: превью живёт в мировых координатах


func _hide_preview() -> void:
	if _imm:
		_imm.clear_surfaces()
	InfoTips.clear(self)


## Граница области на высоте воды и крест курсора
func _redraw() -> void:
	if _imm == null:
		return
	_imm.clear_surfaces()
	if not _has_cursor:
		return
	var y := float(_level()) * float(Global.settings.layer_height) - WaterFill.SURFACE_DROP + 0.02
	var ok := _reason == "" and not _exists
	var col := COL_OK if ok else COL_BAD
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	var arm := 1.0
	_line(Vector3(_cursor.x - arm, y, _cursor.y), Vector3(_cursor.x + arm, y, _cursor.y), COL_CURSOR)
	_line(Vector3(_cursor.x, y, _cursor.y - arm), Vector3(_cursor.x, y, _cursor.y + arm), COL_CURSOR)
	if _res.get("ok", false):
		var s: float = Global.settings.terrain_grid_step
		var cells: Dictionary = _res["cells"]
		var n := 0
		for c: Vector2i in cells:
			var x0 := float(c.x) * s
			var z0 := float(c.y) * s
			if not cells.has(c + Vector2i(-1, 0)):
				_line(Vector3(x0, y, z0), Vector3(x0, y, z0 + s), col)
				n += 1
			if not cells.has(c + Vector2i(1, 0)):
				_line(Vector3(x0 + s, y, z0), Vector3(x0 + s, y, z0 + s), col)
				n += 1
			if not cells.has(c + Vector2i(0, -1)):
				_line(Vector3(x0, y, z0), Vector3(x0 + s, y, z0), col)
				n += 1
			if not cells.has(c + Vector2i(0, 1)):
				_line(Vector3(x0, y, z0 + s), Vector3(x0 + s, y, z0 + s), col)
				n += 1
			if n > MAX_EDGE_LINES:
				break
	_imm.surface_end()


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_imm.surface_set_color(c)
	_imm.surface_add_vertex(a)
	_imm.surface_set_color(c)
	_imm.surface_add_vertex(b)


## Подсказка у курсора: уровень, площадь, предупреждения (InfoToolTip, U20a)
func _update_note() -> void:
	if _imm == null:
		return
	if not _has_cursor:
		InfoTips.clear(self)
		return
	var lines: Array = [InfoTips.title("Налить воду · глубина %d · уровень %d" % [_depth, _level()])]
	if _msg != "":
		lines.append(InfoTips.warn(_msg))
	elif _reason != "":
		lines.append(InfoTips.danger(_reason))
	elif _exists:
		lines.append(InfoTips.danger("Здесь уже налито на этот уровень"))
	else:
		var s: float = Global.settings.terrain_grid_step
		var area := float(_res["count"]) * s * s
		lines.append(InfoTips.ok("Площадь %.0f ю²%s" % [area, ", доходит до края стола" if _res["touches_edge"] else ""]))
	InfoTips.show_lines(self, lines)
