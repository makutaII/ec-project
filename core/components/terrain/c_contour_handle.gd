class_name C_ContourHandle extends Component

# XX claude-terra 13.2 B3 (новый файл)
####################
## Способность. Ручки правки контура выбранного листа пенопласта: вершины и рёбра. Образец: C_FlexHandle.
####################
## Ручки (Area3D на слое handles) видны только у выбранного настоящего листа (не призрак, не в драге).
##  - ЛКМ по вершине и тянуть: вершина идёт по плоскости верха листа, привязка к сетке в локальных координатах листа;
##  - ЛКМ по ручке ребра и тянуть: ребро сдвигается по своей нормали вместе с двумя вершинами;
##  - Shift+ЛКМ по ручке ребра: в середине ребра новая вершина;
##  - ПКМ по вершине: удалить (не меньше 3).
## Контур во время драга живой. Он должен проходить C_Contour.validate и не налезать на другие листы (D6);
## иначе лист красный, и на отпускании контур откатывается к исходному.
## Ввод шлёт SelectTool (общая шина: on_pointer_pressed, on_handle_drag, on_handle_released, on_handle_remove).
## Лист создаёт TerrainLayerSetting.

const RADIUS := 0.5
const PICK_RADIUS := 0.9
const EDGE_SIZE := 0.7
const EDGE_PICK := 1.0
const LIFT := 0.6       # ручка над верхом листа
const FLASH_TIME := 1.8

const KIND_NONE := 0
const KIND_VERTEX := 1
const KIND_EDGE := 2

static var _mat_vertex: StandardMaterial3D
static var _mat_edge: StandardMaterial3D

var _layer: C_TerrainLayer
var _contour: C_Contour
var _vh: Array[Area3D] = []   # ручки вершин
var _eh: Array[Area3D] = []   # ручки рёбер (ребро i от вершины i до вершины i+1)

var _kind := KIND_NONE
var _idx := -1
var _orig := PackedVector2Array()   # контур до драга
var _cur := PackedVector2Array()    # последний проверенный кандидат
var _plane_y := 0.0                 # мировая высота плоскости драга
var _grab := Vector2.ZERO           # точка мыши в локальных координатах в первый тик драга
var _has_grab := false
var _bad := false
var _note: TrackNote.Line
var _flash_stamp := 0


func on_added() -> void:
	name = 'C_ContourHandle'
	_layer = get_comp(C_TerrainLayer) as C_TerrainLayer
	_contour = get_comp(C_Contour) as C_Contour


func on_component_added(_t: Script) -> void:
	_sync()


func on_component_removed(_t: Script) -> void:
	if _kind != KIND_NONE and not _is_active():
		_cancel()
	_sync()


## C_TerrainLayer перестроил лист (форма или толщина изменились): ручки на новые места
func on_terrain_rebuilt(_d: Dictionary) -> void:
	_sync()


func _is_active() -> bool:
	if _layer != null and _layer.smooth > 0:
		return false   # K3d: лист с гипсовым бинтом не деформируется, ручек нет
	return has_comp(C_Selected) and not has_comp(C_Ghost) and not has_comp(C_Drag)


## K3d. Бинт наложен или снят: ручки пропадают или возвращаются
func on_plaster_changed(_d: Dictionary) -> void:
	if _layer != null and _layer.smooth > 0:
		_cancel()
	_sync()


## Привести число ручек и их положение в соответствие с контуром, включить или выключить слой
func _sync() -> void:
	if _contour == null or _layer == null or entity == null or not entity.is_inside_tree():
		return
	var show := _is_active()
	var n := _contour.points.size() if show else 0
	while _vh.size() < n:
		_vh.append(_make_handle(false))
	while _eh.size() < n:
		_eh.append(_make_handle(true))
	while _vh.size() > n:
		var v: Area3D = _vh.pop_back()
		v.queue_free()
	while _eh.size() > n:
		var e: Area3D = _eh.pop_back()
		e.queue_free()
	if n == 0:
		return
	var layer_bits := Global.active_layers(['handles'])
	var y := _layer.height() + LIFT
	var pts := _contour.points
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		_vh[i].position = Vector3(a.x, y, a.y)
		_eh[i].position = Vector3((a.x + b.x) * 0.5, y, (a.y + b.y) * 0.5)
		for h in [_vh[i], _eh[i]]:
			if h.collision_layer != layer_bits:   # слой меняем только при отличии (пересборка физики)
				h.collision_layer = layer_bits
			h.visible = true


func _make_handle(edge: bool) -> Area3D:
	if _mat_vertex == null:
		_mat_vertex = _make_mat(Color(1.0, 0.65, 0.1))
		_mat_edge = _make_mat(Color(0.35, 0.8, 1.0))
	var a := Area3D.new()
	a.name = "ContourEdgeHandle" if edge else "ContourVertexHandle"
	a.collision_layer = 0
	a.collision_mask = 0
	var cs := CollisionShape3D.new()
	var mi := MeshInstance3D.new()
	if edge:
		var bs := BoxShape3D.new()
		bs.size = Vector3.ONE * EDGE_PICK * 2.0
		cs.shape = bs
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * EDGE_SIZE
		mi.mesh = bm
		mi.material_override = _mat_edge
	else:
		var sp := SphereShape3D.new()
		sp.radius = PICK_RADIUS
		cs.shape = sp
		var sm := SphereMesh.new()
		sm.radius = RADIUS
		sm.height = RADIUS * 2.0
		mi.mesh = sm
		mi.material_override = _mat_vertex
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	a.add_child(cs)
	a.add_child(mi)
	entity.add_child(a)
	return a


func _make_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 10
	return m


# ==========================================
# Ввод (шлёт SelectTool, общий словарь data: consumed и drag пишем в него)
# ==========================================

func on_pointer_pressed(d: Dictionary) -> void:
	if d.get("consumed", false) or _contour == null or not _is_active():
		return
	var col = d.get("collider")
	if not (col is Area3D):
		return
	var vi := _vh.find(col)
	if vi >= 0:
		_begin(KIND_VERTEX, vi, _vh[vi])
		d["consumed"] = true
		d["drag"] = true
		return
	var ei := _eh.find(col)
	if ei >= 0:
		d["consumed"] = true
		if d.get("shift", false):
			_insert_vertex(ei)
		else:
			_begin(KIND_EDGE, ei, _eh[ei])
			d["drag"] = true


func on_handle_drag(d: Dictionary) -> void:
	if _kind == KIND_NONE or _contour == null:
		return
	var from: Vector3 = d.from
	var dir: Vector3 = d.dir
	if absf(dir.y) < 0.001:
		return
	var t := (_plane_y - from.y) / dir.y
	if t < 0.0:
		return
	var l: Vector3 = entity.to_local(from + dir * t)
	var pointer := Vector2(l.x, l.z)
	if not _has_grab:
		_grab = pointer   # от этой точки считаем смещение, чтобы ручка не прыгала под курсор
		_has_grab = true
		return
	var step: float = Global.settings.terrain_grid_step
	var cand := _orig.duplicate()
	var n := cand.size()
	if _kind == KIND_VERTEX:
		var o := _orig[_idx]
		var delta := pointer - _grab
		cand[_idx] = Vector2(snappedf(o.x + delta.x, step), snappedf(o.y + delta.y, step))
	else:
		var a := _orig[_idx]
		var b := _orig[(_idx + 1) % n]
		var e := b - a
		if e.length() < C_Contour.EPS:
			return
		var nrm := Vector2(e.y, -e.x).normalized()
		var shift := nrm * (pointer - _grab).dot(nrm)
		shift = Vector2(snappedf(shift.x, step), snappedf(shift.y, step))
		cand[_idx] = a + shift
		cand[(_idx + 1) % n] = b + shift
	_apply_candidate(cand)


func on_handle_released(_d: Dictionary) -> void:
	_finish()


## ПКМ по вершине: удалить
func on_handle_remove(d: Dictionary) -> void:
	if _contour == null or not _is_active():
		return
	var i := _vh.find(d.get("collider"))
	if i < 0:
		return
	d["consumed"] = true
	var pts := _contour.points
	if pts.size() <= 3:
		_flash("Меньше 3 вершин")
		return
	var cand := PackedVector2Array()
	for k in pts.size():
		if k != i:
			cand.append(pts[k])
	var why := _commit(cand)
	if why != "":
		_flash(why)


# ==========================================
# Правка
# ==========================================

func _begin(kind: int, idx: int, handle: Area3D) -> void:
	_kind = kind
	_idx = idx
	_orig = _contour.points.duplicate()
	_cur = _orig
	_plane_y = handle.global_position.y
	_has_grab = false
	_bad = false


## Новый кандидат контура при драге: годный применяем (призма живая), негодный оставляем как был и красим лист
func _apply_candidate(cand: PackedVector2Array) -> void:
	if cand == _cur:
		return
	_cur = cand
	var why := C_Contour.validate(cand)
	if why == "":
		_contour.set_points(cand)
		_layer.update_validity()   # перекрытие с другими листами (D6): C_Invalid
		_bad = entity.has_comp(C_Invalid)
		if _bad:
			why = "Налезает на другой лист"
	else:
		_bad = true
		if not entity.has_comp(C_Invalid):
			entity.add_component(C_Invalid.new())
	_show(why)


## Драг закончен: годный контур остаётся, негодный откатывается
func _finish() -> void:
	if _kind == KIND_NONE:
		return
	var bad := _bad
	var why := ""
	_kind = KIND_NONE
	if bad:
		_contour.set_points(_orig)
		_layer.update_validity()   # на старом месте контур годен: красный флаг снимется
		why = "Так нельзя, вернул прежнюю форму"
	elif _cur != _orig:
		entity.send_event("on_terrain_moved", {})   # пересчёт канав под траки и земли (опоры)
	_cur = _orig
	if why != "":
		_flash(why)
	else:
		_hide_note()
	_sync()


## Снятие выделения посреди драга: откатить без сообщений
func _cancel() -> void:
	_kind = KIND_NONE
	if _contour and _cur != _orig and not _orig.is_empty():
		_contour.set_points(_orig)
	if _layer:
		_layer.update_validity()
	_hide_note()


## Shift+ЛКМ по ручке ребра: вершина в середине ребра (на сетке)
func _insert_vertex(ei: int) -> void:
	var pts := _contour.points
	var n := pts.size()
	if n >= C_Contour.MAX_POINTS:
		_flash("Больше %d вершин" % C_Contour.MAX_POINTS)
		return
	var step: float = Global.settings.terrain_grid_step
	var mid := (pts[ei] + pts[(ei + 1) % n]) * 0.5
	mid = Vector2(snappedf(mid.x, step), snappedf(mid.y, step))
	var cand := PackedVector2Array()
	for k in n:
		cand.append(pts[k])
		if k == ei:
			cand.append(mid)
	var why := _commit(cand)
	if why != "":
		_flash(why)


## Сразу заменить контур (вставка и удаление вершины). Возвращает причину отказа или ""
func _commit(cand: PackedVector2Array) -> String:
	var why := C_Contour.validate(cand)
	if why != "":
		return why
	var old := _contour.points.duplicate()
	_contour.set_points(cand)
	_layer.update_validity()
	if entity.has_comp(C_Invalid):
		_contour.set_points(old)
		_layer.update_validity()
		return "Налезает на другой лист"
	entity.send_event("on_terrain_moved", {})
	return ""


# ==========================================
# Подпись
# ==========================================

func _show(msg: String) -> void:
	if msg == "":
		_hide_note()
		return
	if _note == null:
		_note = TrackNote.line(entity, &"contour", 1)
	_note.text = msg
	_note.modulate = Color(1.0, 0.35, 0.35)
	_note.position = Vector3(0.0, _layer.height() + 3.0, 0.0)
	_note.visible = true


func _hide_note() -> void:
	if _note:
		_note.queue_free()
		_note = null


## Сообщение на пару секунд
func _flash(msg: String) -> void:
	_show(msg)
	_flash_stamp += 1
	var stamp := _flash_stamp
	get_tree().create_timer(FLASH_TIME).timeout.connect(func():
		if _flash_stamp == stamp and _kind == KIND_NONE:
			_hide_note())
