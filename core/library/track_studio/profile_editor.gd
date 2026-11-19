extends Control

########################
## Track Studio: графический редактор профиля (ATTN_20, шаг T4)
########################
## Рисует сечение пути (балласт, шпала, два рельса, размеры) и правит один профиль: рельса или балласта.
## Мышь: ЛКМ по точке - перетащить; ЛКМ по линии - добавить точку и тащить; ПКМ по точке - удалить;
## СКМ или Shift+ЛКМ по пустому месту - сдвиг; колесо - масштаб. Клавиши (при фокусе): Delete, Ctrl+Z, Ctrl+Y, стрелки.
## Правка идёт в координатах профиля (рельс: x от оси рельса, y от подошвы; балласт: x от оси трака, y от origin).

signal changed                  # профиль изменился (во время перетаскивания тоже)
signal selection_changed(index: int)

enum Target { RAIL, BALLAST }

const HIT_POINT := 10.0         # px
const HIT_SEGMENT := 8.0
const MAX_HISTORY := 100
const COLOR_BG := Color(0.12, 0.13, 0.15)
const COLOR_GRID := Color(1, 1, 1, 0.06)
const COLOR_GRID_MAJOR := Color(1, 1, 1, 0.14)
const COLOR_GROUND := Color(0.55, 0.45, 0.3, 0.9)
const COLOR_BALLAST := Color(0.5, 0.5, 0.52, 0.45)
const COLOR_SLEEPER := Color(0.45, 0.3, 0.18, 0.6)
const COLOR_RAIL := Color(0.75, 0.78, 0.85, 0.55)
const COLOR_EDIT := Color(0.35, 0.8, 1.0)
const COLOR_BAD := Color(1.0, 0.35, 0.35)
const COLOR_DIM := Color(1.0, 0.85, 0.4, 0.9)
const COLOR_HIDDEN := Color(1, 1, 1, 0.3)   # часть выключена в стиле: только контур (коллизия и высота остаются)

var style: TrackStyle
var target: int = Target.RAIL
var profile := PackedVector2Array()
var mirror := false
var snap_step := 0.025
var snap_on := true
var show_dims := true
var selected := -1

var _scale := 200.0             # px на ю
var _origin := Vector2.ZERO     # экранная точка мира (0, 0)
var _hover := -1
var _drag := -1
var _drag_pushed := false       # запись в историю делается при первом движении, а не при простом клике
var _pan := false
var _fitted := false
var _undo: Array[PackedVector2Array] = []
var _redo: Array[PackedVector2Array] = []
var _num_idx := -1
var _num_time := 0


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	custom_minimum_size = Vector2(320, 260)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


# ==========================================
# Данные
# ==========================================

## Загружает профиль (без записи в историю), сбрасывает выбор и историю
func load_profile(p: PackedVector2Array, tgt: int, st: TrackStyle) -> void:
	target = tgt
	style = st
	profile = p.duplicate()
	selected = -1
	_hover = -1
	_undo.clear()
	_redo.clear()
	_fitted = false
	selection_changed.emit(-1)
	queue_redraw()


## Подставляет новый профиль целиком (пресет, генератор) как одну правку
func apply_profile(p: PackedVector2Array) -> void:
	_push_undo()
	profile = p.duplicate()
	selected = -1
	selection_changed.emit(-1)
	changed.emit()
	queue_redraw()


func set_mirror(on: bool) -> void:
	mirror = on
	if on and not TrackProfileTools.is_symmetric(profile):
		_push_undo()
		profile = TrackProfileTools.symmetrize(profile)
		changed.emit()
	queue_redraw()


## Числовая правка выбранной точки (из полей панели); подряд идущие правки одной точки идут одной записью
func set_selected_point(v: Vector2) -> void:
	if selected < 0 or selected >= profile.size():
		return
	var now := Time.get_ticks_msec()
	if _num_idx != selected or now - _num_time > 1000:
		_push_undo()
	_num_idx = selected
	_num_time = now
	_set_point(selected, v)
	changed.emit()
	queue_redraw()


func undo() -> void:
	if _undo.is_empty():
		return
	_redo.append(profile.duplicate())
	profile = _undo.pop_back()
	_clamp_selection()
	changed.emit()
	queue_redraw()


func redo() -> void:
	if _redo.is_empty():
		return
	_undo.append(profile.duplicate())
	profile = _redo.pop_back()
	_clamp_selection()
	changed.emit()
	queue_redraw()


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func _push_undo() -> void:
	_undo.append(profile.duplicate())
	if _undo.size() > MAX_HISTORY:
		_undo.pop_front()
	_redo.clear()


func _clamp_selection() -> void:
	if selected >= profile.size():
		selected = profile.size() - 1
		selection_changed.emit(selected)


## Меняет точку с учётом зеркала (парная точка отражается, средняя встаёт на x = 0)
func _set_point(i: int, v: Vector2) -> void:
	var n := profile.size()
	if mirror:
		var j := TrackProfileTools.mirror_index(i, n)
		if i == j:
			v.x = 0.0
		else:
			profile[j] = Vector2(-v.x, v.y)
	profile[i] = v


# ==========================================
# Система координат
# ==========================================

## Профиль -> мир сечения (ю). Рельс стоит на base_height и смещён на rail_x
func _to_world(p: Vector2) -> Vector2:
	if target == Target.RAIL and style:
		return Vector2(style.rail_x + p.x, style.base_height() + p.y)
	return p


func _from_world(w: Vector2) -> Vector2:
	if target == Target.RAIL and style:
		return Vector2(w.x - style.rail_x, w.y - style.base_height())
	return w


func _w2s(w: Vector2) -> Vector2:
	return _origin + Vector2(w.x, -w.y) * _scale


func _s2w(s: Vector2) -> Vector2:
	var d := (s - _origin) / _scale
	return Vector2(d.x, -d.y)


func _p2s(p: Vector2) -> Vector2:
	return _w2s(_to_world(p))


func _s2p(s: Vector2) -> Vector2:
	return _from_world(_s2w(s))


## Вписывает редактируемую часть в вид
func fit() -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in profile:
		var w := _to_world(p)
		lo = lo.min(w)
		hi = hi.max(w)
	if lo.x == INF:
		lo = Vector2(-1, 0)
		hi = Vector2(1, 0.5)
	var margin := 0.25 if target == Target.RAIL else 0.35
	lo -= Vector2(margin, margin)
	hi += Vector2(margin, margin)
	var sz := hi - lo
	_scale = clampf(minf(size.x / maxf(sz.x, 0.01), size.y / maxf(sz.y, 0.01)), 10.0, 4000.0)
	var c := (lo + hi) * 0.5
	_origin = size * 0.5 - Vector2(c.x, -c.y) * _scale
	_fitted = true
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and not _fitted and size.x > 10.0:
		fit()


# ==========================================
# Отрисовка
# ==========================================

func _draw() -> void:
	if not _fitted and size.x > 10.0:
		fit()
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	_draw_grid()
	_draw_context()
	_draw_profile()


func _grid_step() -> float:
	if _scale > 700.0:
		return 0.025
	if _scale > 280.0:
		return 0.05
	if _scale > 110.0:
		return 0.1
	if _scale > 40.0:
		return 0.25
	return 0.5


func _draw_grid() -> void:
	var step := _grid_step()
	var lo := _s2w(Vector2(0.0, size.y))
	var hi := _s2w(Vector2(size.x, 0.0))
	var ix := floori(lo.x / step)
	while ix * step <= hi.x:
		var x := ix * step
		var sx := _w2s(Vector2(x, 0.0)).x
		draw_line(Vector2(sx, 0.0), Vector2(sx, size.y), COLOR_GRID_MAJOR if ix % 5 == 0 else COLOR_GRID)
		ix += 1
	var iy := floori(lo.y / step)
	while iy * step <= hi.y:
		var y := iy * step
		var sy := _w2s(Vector2(0.0, y)).y
		draw_line(Vector2(0.0, sy), Vector2(size.x, sy), COLOR_GRID_MAJOR if iy % 5 == 0 else COLOR_GRID)
		iy += 1
	var gy := _w2s(Vector2.ZERO).y
	draw_line(Vector2(0.0, gy), Vector2(size.x, gy), COLOR_GROUND, 2.0)
	var cx := _w2s(Vector2.ZERO).x
	draw_line(Vector2(cx, 0.0), Vector2(cx, size.y), Color(1, 1, 1, 0.2), 1.0)


## Слои сечения пути вокруг редактируемого профиля. Редактируемый профиль берётся из редактора, а не из стиля
func _draw_context() -> void:
	if style == null:
		return
	var ballast := profile if target == Target.BALLAST else style.ballast_profile
	var rail := profile if target == Target.RAIL else style.rail_profile
	if style.ballast_enabled and ballast.size() >= 3:
		var pts := PackedVector2Array()
		for p in ballast:
			pts.append(_w2s(p))
		if Geometry2D.triangulate_polygon(pts).size() > 0:
			draw_colored_polygon(pts, COLOR_BALLAST)
	# Шпала в разрезе: ширина по X, высота постели
	var dims := style.sleeper_dims()
	var sb := style.sleeper_bottom()
	var r := Rect2(_w2s(Vector2(-dims.x * 0.5, sb + dims.y)), Vector2(dims.x, dims.y) * _scale)
	if style.sleeper_enabled:
		draw_rect(r, COLOR_SLEEPER)
		draw_rect(r, Color(1, 1, 1, 0.25), false, 1.0)
	else:
		draw_rect(r, COLOR_HIDDEN, false, 1.0)
	# Рельсы: оба на одной высоте, один профиль
	var base := style.base_height()
	for sx in [-1.0, 1.0]:
		var pts := PackedVector2Array()
		for p in rail:
			pts.append(_w2s(Vector2(sx * style.rail_x + p.x, base + p.y)))
		if not style.rail_enabled:
			if pts.size() >= 2:
				var loop := pts.duplicate()
				loop.append(pts[0])
				draw_polyline(loop, COLOR_HIDDEN, 1.0)
		elif pts.size() >= 3 and Geometry2D.triangulate_polygon(pts).size() > 0:
			draw_colored_polygon(pts, COLOR_RAIL)
	if show_dims:
		_draw_dims(ballast, rail)


func _draw_dims(ballast: PackedVector2Array, rail: PackedVector2Array) -> void:
	var font := ThemeDB.fallback_font
	var base := style.base_height()
	var rail_hi := 0.0
	for p in rail:
		rail_hi = maxf(rail_hi, p.y)
	var rw := style.rail_width()
	# Поверхность катания: вертикаль справа от правого рельса
	var hx := style.rail_x + rw * 0.5 + 0.12
	var top := base + rail_hi
	draw_line(_w2s(Vector2(hx, 0.0)), _w2s(Vector2(hx, top)), COLOR_DIM, 1.0)
	draw_string(font, _w2s(Vector2(hx, top)) + Vector2(4, -4), "h %.3f" % top, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COLOR_DIM)
	# Ширина подошвы
	var wy := base - 0.04
	draw_line(_w2s(Vector2(style.rail_x - rw * 0.5, wy)), _w2s(Vector2(style.rail_x + rw * 0.5, wy)), COLOR_DIM, 1.0)
	draw_string(font, _w2s(Vector2(style.rail_x - rw * 0.5, wy)) + Vector2(0, 14), "подошва %.3f" % rw, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COLOR_DIM)
	# Колея
	draw_string(font, _w2s(Vector2(-style.rail_x + 0.1, base + 0.12)), "колея %.3f" % (style.rail_x * 2.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COLOR_DIM)
	# Ширина балласта по низу
	if style.ballast_enabled and ballast.size() >= 2:
		var lo := INF
		var hi := -INF
		for p in ballast:
			lo = minf(lo, p.x)
			hi = maxf(hi, p.x)
		draw_line(_w2s(Vector2(lo, -0.05)), _w2s(Vector2(hi, -0.05)), COLOR_DIM, 1.0)
		draw_string(font, _w2s(Vector2(lo, -0.05)) + Vector2(2, 14), "балласт %.3f" % (hi - lo), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COLOR_DIM)


func _draw_profile() -> void:
	if profile.size() == 0:
		return
	var crossings := TrackProfileTools.intersections(profile)
	var bad_segments := {}
	for c in crossings:
		bad_segments[c.x] = true
		bad_segments[c.y] = true
	for i in profile.size() - 1:
		var col := COLOR_BAD if bad_segments.has(i) else COLOR_EDIT
		draw_line(_p2s(profile[i]), _p2s(profile[i + 1]), col, 2.5, true)
	var font := ThemeDB.fallback_font
	for i in profile.size():
		var s := _p2s(profile[i])
		var col := COLOR_BAD if profile[i].y < -0.001 else COLOR_EDIT
		var radius := 5.0
		if i == selected:
			radius = 7.0
			draw_circle(s, radius + 2.0, Color(1, 1, 1, 0.9))
		elif i == _hover:
			radius = 6.5
		draw_circle(s, radius, col)
		draw_string(font, s + Vector2(8, -8), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.7))
	var msg := TrackProfileTools.problems_text(profile)
	if not msg.is_empty():
		draw_string(font, Vector2(8, 18), msg, HORIZONTAL_ALIGNMENT_LEFT, size.x - 16.0, 13, COLOR_BAD)
	if mirror:
		draw_string(font, Vector2(8, size.y - 8), "зеркало", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.6))


# ==========================================
# Ввод
# ==========================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_motion(event as InputEventMouseMotion)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		_on_key(event as InputEventKey)


func _on_button(mb: InputEventMouseButton) -> void:
	if mb.pressed:
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(1.15, mb.position)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(1.0 / 1.15, mb.position)
			MOUSE_BUTTON_MIDDLE:
				_pan = true
			MOUSE_BUTTON_LEFT:
				grab_focus()
				_press(mb)
			MOUSE_BUTTON_RIGHT:
				grab_focus()
				var i := _hit_point(mb.position)
				if i >= 0:
					_delete(i)
	else:
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_pan = false
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_pan = false
			_drag = -1


func _press(mb: InputEventMouseButton) -> void:
	var i := _hit_point(mb.position)
	if i >= 0:
		_drag = i
		_drag_pushed = false
		_select(i)
		return
	var seg := _hit_segment(mb.position)
	if seg >= 0:
		_insert_on_segment(seg, mb.position)
		return
	if mb.shift_pressed:
		_pan = true
	else:
		_select(-1)


func _on_motion(mm: InputEventMouseMotion) -> void:
	if _pan:
		_origin += mm.relative
		queue_redraw()
		return
	if _drag >= 0:
		if not _drag_pushed:
			_push_undo()
			_drag_pushed = true
		var v := _s2p(mm.position)
		if snap_on and not mm.alt_pressed:
			v = TrackProfileTools.snap(v, snap_step)
		_set_point(_drag, v)
		changed.emit()
		selection_changed.emit(_drag)
		queue_redraw()
		return
	var h := _hit_point(mm.position)
	if h != _hover:
		_hover = h
		queue_redraw()


func _on_key(k: InputEventKey) -> void:
	if k.keycode == KEY_DELETE and selected >= 0:
		_delete(selected)
	elif k.keycode == KEY_Z and (k.ctrl_pressed or k.meta_pressed):
		undo()
	elif k.keycode == KEY_Y and (k.ctrl_pressed or k.meta_pressed):
		redo()
	elif selected >= 0 and k.keycode in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
		var d := Vector2.ZERO
		match k.keycode:
			KEY_LEFT: d.x = -1.0
			KEY_RIGHT: d.x = 1.0
			KEY_UP: d.y = 1.0
			KEY_DOWN: d.y = -1.0
		set_selected_point(profile[selected] + d * (snap_step if snap_on else 0.005))
	else:
		return
	accept_event()


func _zoom(factor: float, at: Vector2) -> void:
	var before := _s2w(at)
	_scale = clampf(_scale * factor, 10.0, 4000.0)
	_origin = at - Vector2(before.x, -before.y) * _scale   # точка под курсором остаётся на месте
	queue_redraw()


func _select(i: int) -> void:
	if selected != i:
		selected = i
		selection_changed.emit(i)
	queue_redraw()


func _hit_point(s: Vector2) -> int:
	var best := -1
	var best_d := HIT_POINT
	for i in profile.size():
		var d := _p2s(profile[i]).distance_to(s)
		if d <= best_d:
			best_d = d
			best = i
	return best


func _hit_segment(s: Vector2) -> int:
	var best := -1
	var best_d := HIT_SEGMENT
	for i in profile.size() - 1:
		var c := Geometry2D.get_closest_point_to_segment(s, _p2s(profile[i]), _p2s(profile[i + 1]))
		var d := c.distance_to(s)
		if d <= best_d:
			best_d = d
			best = i
	return best


## Новая точка на сегменте seg (между seg и seg + 1) в позиции мыши; при зеркале добавляется и парная
func _insert_on_segment(seg: int, pos: Vector2) -> void:
	_push_undo()
	var v := _s2p(pos)
	if snap_on:
		v = TrackProfileTools.snap(v, snap_step)
	var n := profile.size()
	var arr := Array(profile)
	if mirror:
		var mseg := n - 2 - seg   # сегмент-пара: между n-1-(seg+1) и n-1-seg
		if mseg == seg:
			# сегмент лежит на оси симметрии: одна точка на x = 0
			v.x = 0.0
			arr.insert(seg + 1, v)
			profile = PackedVector2Array(arr)
			_drag = seg + 1
			_drag_pushed = true
			_select(_drag)
			changed.emit()
			return
		# вставляем сначала позже стоящую, чтобы номера не поехали
		var lo_seg := mini(seg, mseg)
		var hi_seg := maxi(seg, mseg)
		var v_hi := v if seg == hi_seg else Vector2(-v.x, v.y)
		var v_lo := Vector2(-v_hi.x, v_hi.y)
		arr.insert(hi_seg + 1, v_hi)
		arr.insert(lo_seg + 1, v_lo)
		profile = PackedVector2Array(arr)
		_drag = (seg + 1) if seg == lo_seg else (seg + 2)
	else:
		arr.insert(seg + 1, v)
		profile = PackedVector2Array(arr)
		_drag = seg + 1
	_drag_pushed = true
	_select(_drag)
	changed.emit()
	queue_redraw()


func _delete(i: int) -> void:
	var n := profile.size()
	if n <= 2:
		return
	_push_undo()
	var arr := Array(profile)
	if mirror:
		var j := TrackProfileTools.mirror_index(i, n)
		if j != i and n > 3:
			arr.remove_at(maxi(i, j))
			arr.remove_at(mini(i, j))
		else:
			arr.remove_at(i)
	else:
		arr.remove_at(i)
	profile = PackedVector2Array(arr)
	selected = -1
	_hover = -1
	selection_changed.emit(-1)
	changed.emit()
	queue_redraw()
