class_name TableTool extends Node

# XX claude-table T2 (новый файл)
##########################
## Постановка секций подмакетника (ATTN_23 T2). Инструмент режима «Секции»: кнопка пресета в каталоге (категория table) включает его.
##########################
## Призрак это настоящая секция с C_Ghost (контуры как у объектов Build: зелёный можно, красный нельзя).
## Положение: курсор на плоскости стола (y = 0, за краем стола земли нет, поэтому не лучом по ground), левый верхний угол
## на сетке 1 u. Рядом с существующей секцией угол прилипает: ребро к ребру (контакт), а вдоль ребра выравнивается по краю.
## Красный призрак (причина над курсором): пересекает другую секцию, выходит за комнату (правила опор ниже)
## или в проход aisle_min, мешает мебель или стена (слой room).
## T4+T5: вид опор LayoutConfig.support меняет правила. Ножки и рама: секцию можно поставить отдельно на пол (кликом по полу),
## от стен проход aisle_min. Кронштейны: секция касается стены (окно и дверь нельзя закрывать) или стола; дальше 60 u от стены
## только жёлтое предупреждение «нужны опоры». Правила комнаты считает TableRules, остальное LYM.placement_reason.
## Ввод: ЛКМ поставить, Q/E повернуть на 90°, R/F высота стола ±5 (Shift и PgUp/PgDn ±25), Ctrl+Z убрать последнюю поставленную,
## ПКМ выйти в SelectTool. Секции прямоугольные; снап считает по ограничивающим прямоугольникам.

## Дальность прилипания, u
const SNAP_DIST := 8.0
const EPS := 0.01
## Объём проверки на мебель: от низа плиты до этой высоты над столом, u
const CLEAR_ABOVE := 10.0
const MSG_TIME := 2.5
const COL_OK := Color(0.45, 1.0, 0.6)
const COL_BAD := Color(1.0, 0.35, 0.35)

var controller: ToolController
## Пресет секции, который ставим. Его задаёт ToolController.select_build_object перед switch_tool
var ghost_setting: EntitySetting

var ghost: Entity
var _size := Vector2(100.0, 100.0)   # размер пресета (X, Z) без поворота
var _rot := false                    # повёрнут на 90°
var _cursor := Vector2.ZERO
var _has_cursor := false
var _center := Vector2.ZERO
var _reason := ""
var _warn := ""
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0
var _history: Array[Entity] = []


func enter() -> void:
	_has_cursor = false
	_reason = ""
	if ghost_setting == null:
		controller.switch_tool.call_deferred(controller.select_tool)
		return
	ghost = controller.entity_factory.create_from_setting(ghost_setting)
	controller.entities_root.add_child(ghost)
	ghost.name = 'ghost'
	ghost.add_component(C_Ghost.new())
	var cfg := TableConfig.from_entity(ghost)
	_size = cfg.size if cfg != null else Vector2(100.0, 100.0)
	_apply_size()
	ghost.visible = false
	controller.publish_selection(null)


func exit(_to_drag: bool = false) -> void:
	if is_instance_valid(ghost):
		ghost.queue_free()
	ghost = null
	InfoTips.clear(self)
	controller.select_build_object(null)   # снять нажатие с кнопки каталога


func process_tick(delta: float) -> void:
	if ghost == null or not is_instance_valid(ghost):
		return
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			_msg = ""
	var has := false
	if not UIPointer.is_over_ui(get_viewport()):
		var hit := controller.get_mouse_plane_hit(0.0)
		if not hit.is_empty():
			var p: Vector3 = hit["position"]
			_cursor = Vector2(p.x, p.z)
			has = true
			# XX claude-table T4: далеко от стола ножки и рама ставятся кликом по полу (луч до плоскости пола)
			if LYM.config.support != LayoutConfig.Support.WALL and not _near_table(_cursor):
				var fh := controller.get_mouse_plane_hit(-LYM.config.height)
				if not fh.is_empty():
					var fp: Vector3 = fh["position"]
					_cursor = Vector2(fp.x, fp.z)
	_has_cursor = has
	ghost.visible = has
	if has:
		_update_ghost()
	_update_note()


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
		_place()
		return
	if Actions.pressed(event, &"rotate_left") or Actions.pressed(event, &"rotate_right"):
		_rot = not _rot
		_apply_size()
		return
	if Actions.pressed(event, &"tool_undo"):
		_undo()
		return
	var n := ElevationInput.step_from_event(event)
	if n != 0:
		LYM.step_height(n)


## Курсор (на плоскости верха стола) у существующего стола: рядом работает прилипание ребро к ребру
func _near_table(cur: Vector2) -> bool:
	var reach := SNAP_DIST + maxf(_world_size().x, _world_size().y) * 0.5
	for r in TableTool.existing_rects():
		if r.grow(reach).has_point(cur):
			return true
	return false


func _apply_size() -> void:
	if not is_instance_valid(ghost):
		return
	var contour := ghost.get_comp(C_Contour) as C_Contour
	if contour != null:
		contour.set_rect(_world_size())


func _world_size() -> Vector2:
	return Vector2(_size.y, _size.x) if _rot else _size


## --- Положение и проверка ---

func _update_ghost() -> void:
	var sz := _world_size()
	_center = _snap_center(_cursor, sz)
	ghost.global_position = Vector3(_center.x, 0.0, _center.y)
	var rect := Rect2(_center - sz * 0.5, sz)
	_reason = _check(rect)
	_warn = LYM.depth_warning(rect) if _reason == "" else ""
	var blocked := ghost.has_comp(C_Blocked)
	if _reason != "" and not blocked:
		ghost.add_component(C_Blocked.new())
	elif _reason == "" and blocked:
		ghost.remove_component(C_Blocked)


## Ограничивающие прямоугольники настоящих секций
static func existing_rects() -> Array[Rect2]:
	var res: Array[Rect2] = []
	for e in LYM.get_sections():
		var poly := LYM.section_polygon(e)
		if poly.size() >= 3:
			res.append(C_Contour.bounds_of(poly))
	return res


## Центр секции размера sz для курсора cur: левый верхний угол на сетке 1 u, затем прилипание к рёбрам существующих секций.
## По каждой оси сначала контакт (ребро к ребру), если он дальше SNAP_DIST, то выравнивание по краю
static func snap_center(cur: Vector2, sz: Vector2, rects: Array[Rect2]) -> Vector2:
	var half := sz * 0.5
	var c := (cur - half).round() + half
	var res := c
	var d_contact := Vector2(SNAP_DIST, SNAP_DIST)
	var d_align := Vector2(SNAP_DIST, SNAP_DIST)
	var best_contact := Vector2(INF, INF)
	var best_align := Vector2(INF, INF)
	for r in rects:
		for cand: float in [r.end.x + half.x, r.position.x - half.x]:
			var d := absf(cand - c.x)
			if d < d_contact.x:
				d_contact.x = d
				best_contact.x = cand
		for cand: float in [r.position.x + half.x, r.end.x - half.x]:
			var d := absf(cand - c.x)
			if d < d_align.x:
				d_align.x = d
				best_align.x = cand
		for cand: float in [r.end.y + half.y, r.position.y - half.y]:
			var d := absf(cand - c.y)
			if d < d_contact.y:
				d_contact.y = d
				best_contact.y = cand
		for cand: float in [r.position.y + half.y, r.end.y - half.y]:
			var d := absf(cand - c.y)
			if d < d_align.y:
				d_align.y = d
				best_align.y = cand
	if best_contact.x != INF:
		res.x = best_contact.x
	elif best_align.x != INF:
		res.x = best_align.x
	if best_contact.y != INF:
		res.y = best_contact.y
	elif best_align.y != INF:
		res.y = best_align.y
	return res


func _snap_center(cur: Vector2, sz: Vector2) -> Vector2:
	# XX claude-table T4b: к стенам прилипаем так же, как к рёбрам секций (кронштейны вплотную, ножки и рама на проходе)
	var edges := TableTool.existing_rects()
	edges.append_array(TableRules.wall_snap_rects(LYM.room_config(), int(LYM.config.support), LYM.config.aisle_min))
	return TableTool.snap_center(cur, sz, edges)


## Общее ребро длиннее EPS (касание углом не считается)
static func shares_edge(a: Rect2, b: Rect2) -> bool:
	var z_overlap := minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
	var x_overlap := minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
	if z_overlap > EPS and (absf(a.end.x - b.position.x) < EPS or absf(b.end.x - a.position.x) < EPS):
		return true
	if x_overlap > EPS and (absf(a.end.y - b.position.y) < EPS or absf(b.end.y - a.position.y) < EPS):
		return true
	return false


## Почему здесь нельзя ставить; пусто: можно. Комната, опоры и соседи: LYM.placement_reason, затем мебель и стены (слой room)
func _check(rect: Rect2) -> String:
	var why := LYM.placement_reason(rect)
	if why != "":
		return why
	if _hits_room(rect):
		return "Мешает мебель или стена"
	return ""


## Объём плиты (от низа плиты до CLEAR_ABOVE над столом) пересекает слой room: мебель, стены. Края чуть сужены
func _hits_room(rect: Rect2) -> bool:
	var th := LYM.plate_thickness()
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(rect.size.x - 0.2, 0.1), th + CLEAR_ABOVE - 0.2, maxf(rect.size.y - 0.2, 0.1))
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	var c := rect.get_center()
	q.transform = Transform3D(Basis.IDENTITY, Vector3(c.x, (CLEAR_ABOVE - th) * 0.5, c.y))
	q.collision_mask = Global.active_layers(['room'])
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return not controller.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## --- Действия ---

func _place() -> void:
	if not _has_cursor or not is_instance_valid(ghost):
		return
	if _reason != "":
		_say(_reason)
		return
	var e := controller.entity_factory.create_from_setting(ghost_setting)
	e.position = Vector3(_center.x, 0.0, _center.y)   # entities_root в нуле
	var contour := e.get_comp(C_Contour) as C_Contour
	if contour != null:
		contour.set_rect(_world_size())
	controller.entities_root.add_child(e)
	_history.append(e)
	while _history.size() > 50:
		_history.pop_front()


## Ctrl+Z: убрать последнюю поставленную секцию (по правилам удаления: не последняя, без объектов на ней)
func _undo() -> void:
	while not _history.is_empty():
		var e: Entity = _history.pop_back()
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			e.kill_me()
			return


func _say(text: String) -> void:
	_msg = text
	_msg_t = MSG_TIME


## --- Подсказка у курсора (InfoToolTip, U20a) ---

func _update_note() -> void:
	if not _has_cursor:
		InfoTips.clear(self)
		return
	var sz := _world_size()
	var lines: Array = [InfoTips.title("Секция %d × %d · высота стола %d" % [int(sz.x), int(sz.y), int(LYM.config.height)])]
	if _msg != "":
		lines.append(InfoTips.warn(_msg))
	elif _reason != "":
		lines.append(InfoTips.danger(_reason))
	elif _warn != "":
		lines.append(InfoTips.warn(_warn))
	InfoTips.show_lines(self, lines)
