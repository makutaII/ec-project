class_name C_FlexShape extends ICapability

# XX claude-terra (новый файл, F2)
####################
## Способность. Хозяин данных формы flex-трака.
####################
## Два режима конца:
##  - свободный: дуга, касательная к началу (FlexSolver.arc_to), высота конца = уровни R/F, уклон 0;
##  - снап: в радиусе flex_snap_radius от курсора есть свободный сокет другого трака -> конец берет его
##    позицию, касательную и высоту, форма = кубик Эрмита (FlexSolver.best_hermite), профиль высоты
##    Эрмит по длине с уклонами соседей на обоих концах.
## Считает форму, отдает кривую в C_Path.set_curve. Меш и коллизии строит C_FlexVisual по on_curve_changed.
## Невозможная форма (r < r_min, L вне [l_min, l_max], уклон > max_grade, уход под землю) -> C_Invalid.
##
## События (шлет BuildTool, он компонентов не знает):
##   on_stretch_started  - начало зафиксировано, дальше тянем конец
##   on_stretch_moved    - {position} точка под курсором (мир)
##   on_stretch_ended    - конец зафиксирован
##   on_rotate_input     - R/F в фазе конца меняют уровень свободного конца
##   on_clone_state_to / on_receive_flex_state - перенос формы призрака в реальный объект
## Строку "L · R · dY (уклон)" в подсказке у призрака держит этот компонент (строка TrackNote, создается только у призрака; U20a.3).

const STEP := 1.0
const LABEL_PIXEL_SIZE := 0.0015   # размер метки на экране, подбирать по вкусу
const LABEL_FONT_SIZE := 32
const NEIGHBOR_EPS := 0.6          # сокет ближе - считаем его стыком начала
const SNAP_HYST := 0.7             # удерживаем уже выбранный сокет (множитель расстояния)
const GROUND_PERIOD_MS := 120      # проверка "под землей" не чаще

# --- состояние формы (сохраняется) ---
var target := Vector2(0.0, 10.0)   # свободный конец, плоскость начала (x вправо, y вперед)
var end_levels := 0                # уровни свободного конца относительно начала
var snapped_end := false
var end_pos := Vector2.ZERO        # конец у сокета (плоскость начала)
var end_tan := Vector2(0.0, 1.0)   # направление ДВИЖЕНИЯ в конце (плоскость)
var end_dy := 0.0                  # высота конца у сокета относительно начала
var end_slope := 0.0               # dy/ds движения в конце у сокета
var start_slope := 0.0             # dy/ds движения в начале (уклон соседа начала)
## XX claude-coaster C8.2: крен, градусы, + правый край ниже (RideShape, TrackMeshBuilder.frame). У рельсового flex остаётся 0:
## соседи без крена дают 0, наклон точек кривой не пишется, поведение прежнее
var start_roll := 0.0              # крен в начале: берётся у соседа начала (_neighbor_roll)
var end_roll := 0.0                # крен у привязанного конца: берётся у соседа конца (_snap_to)
var roll_twist := 0.0              # скручивание свободного конца: end = start + twist (задаёт игрок)

# --- производные ---
var length := 10.0
var radius := INF
var grade := 0.0
var dy := 0.0
var end_local := Vector3(0.0, 0.0, -10.0)
var stretching := false
var invalid := false

var _label: TrackNote.Line   # строка общей метки TrackNote (вместе с тоннелем и т.п.)
var _last_key: Array = []
var _snap_id := 0

# XX bug
const FREE_R_MIN := 4.0            # жесткий пол при выключенном контроле (балласт ±1.6)
var relaxed := false               # форма построена без лимитов (сохраняется)
var _issues: Array[String] = []    # какие лимиты нарушены (по реальным пределам)
#var _geom_valid := true
#==

var _ground_bad := false
var _ground_ms := 0
var _ground_pending := false

const BEND_MIN_GAP := 3.0          # изгиб не ближе к началу/концу, ю

var bends: Array[Vector2] = []     # изгибы в плоскости начала (сохраняются), максимум flex_max_bends
var editing := false
var _snapshot: Dictionary = {}


func _init() -> void:
	set_process(false)


func on_entity_ready() -> void:
	_apply(true)   # начальная короткая прямая через общий путь set_curve
	Global.flex_zones_changed.connect(_on_zones_toggled)   # XX claude-terra 13.1.7


func on_component_added(type: Script) -> void:
	if type == C_Selected:   # XX claude-terra 13.1.7: у выбранного трака полоса полная (с зеленым)
		_zones_refresh(true)
	if type == C_Ghost:
		relaxed = not Global.flex_limits
		_ensure_label()
		# пока ставится начало, конец не должен снапить призрак
		entity.send_event("on_socket_enabled", {"index": 1, "enabled": false})


# ==========================================
# События построения
# ==========================================

func on_stretch_started(_d: Dictionary) -> void:
	stretching = true
	snapped_end = false
	_snap_id = 0
	end_levels = 0
	start_slope = _neighbor_slope()
	start_roll = _neighbor_roll()   # XX claude-coaster C8.2
	roll_twist = 0.0
	end_roll = 0.0
	entity.send_event("on_socket_enabled", {"index": -1, "enabled": false})
	if _label:
		_label.visible = true
	_apply(true)
	_validate()


func on_stretch_moved(data: Dictionary) -> void:
	if not stretching or not data.has("position"):
		return
	var world: Vector3 = data.position
	var sock := _find_end_socket(world)
	if sock.is_empty():
		snapped_end = false
		_snap_id = 0
		var p: Vector3 = entity.to_local(world)
		target = Vector2(p.x, -p.z)
	else:
		_snap_to(sock)
	_apply()
	_validate()


## R/F в фазе конца: уровень свободного конца (у сокета высоту задает сокет)
func on_rotate_input(data: Dictionary) -> void:
	if not stretching or data.get("axis", "") != "x":
		return
	end_levels += int(signf(data.get("amount", 0.0)))
	_apply(true)
	_validate()


## XX claude-terra 13.1.4. Крупный шаг уровня свободного конца (Shift+R/F, PageUp/PageDown)
func on_elevation_input(data: Dictionary) -> void:
	if not stretching:
		return
	end_levels += int(data.get("levels", 0))
	_apply(true)
	_validate()


func on_stretch_ended(_d: Dictionary) -> void:
	stretching = false
	if _label:
		_label.visible = false
	entity.send_event("on_flex_final", {})


## Призрак отдает форму новому реальному объекту
func on_clone_state_to(data: Dictionary) -> void:
	var t: Entity = data.target
	t.send_event("on_receive_flex_state", {"flex_state": _state()})


func on_receive_flex_state(data: Dictionary) -> void:
	_set_state(data.get("flex_state", {}))
	_apply(true)
	entity.send_event("on_flex_final", {})


func set_target(t: Vector2) -> void:
	target = t
	_apply()


# XX claude-terra 13.1.4
## Призрак получил готовую форму (дубль последнего объекта): растягивания нет, ставится одним кликом.
## Форма задана в плоскости начала и от позы не зависит. От позы зависят уклон соседа в начале и "под землей":
## пока призрак ездит за курсором, их обновляет _tick_preshaped
var preshaped := false


func on_preshaped_set(_d: Dictionary) -> void:
	preshaped = true
	stretching = false
	relaxed = not Global.flex_limits
	if _label:
		_label.visible = true
	_ground_ms = 0
	_apply(true)
	set_process(true)


func _tick_preshaped() -> void:
	if not entity.has_comp(C_Ghost):
		preshaped = false
		set_process(false)
		return
	var now := Time.get_ticks_msec()
	if now - _ground_ms < GROUND_PERIOD_MS:
		return
	_ground_ms = now
	var s := _neighbor_slope()
	var sr := _neighbor_roll()   # XX claude-coaster C8.2
	if not is_equal_approx(s, start_slope) or not is_equal_approx(sr, start_roll):
		start_slope = s
		start_roll = sr
		_apply(true)
		entity.send_event("on_flex_final", {})   # после _apply меш и коллизии грубые, нужен финал
	var path := get_comp(C_Path) as C_Path
	_ground_bad = path != null and path.underground_depth(entity.global_transform) > Global.settings.underground_tolerance
	_refresh_state()


# ==========================================
# Расчет формы
# ==========================================
func on_flex_limits_changed(_d: Dictionary) -> void:
	relaxed = not Global.flex_limits
	_apply(true)
	_validate()


## real = true: настоящие пределы (для проверки), иначе те, по которым решаем форму
func _limits(real := false) -> FlexSolver.Limits:
	# XX claude-coaster C8: паспорт трака может задать свои пределы (flex горок), иначе из GlobalSetting
	var idc := get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as TrackConfig if idc else null
	var own := cfg.flex_limits() if cfg else null
	if own != null and (real or not relaxed):
		return own
	var gs = Global.settings
	var lim := FlexSolver.Limits.new()
	if real or not relaxed:
		lim.r_min = gs.flex_r_min
		lim.l_min = gs.flex_l_min
		lim.l_max = gs.flex_l_max
		lim.max_grade = gs.flex_max_grade
	else:
		lim.r_min = FREE_R_MIN
		lim.l_min = 2.0
		lim.l_max = 500.0
		lim.max_grade = 1.0
	return lim


func _apply(force := false) -> void:
	if entity == null:
		return
	var key := [snapped_end, _snap_id, end_pos, target.snapped(Vector2(0.05, 0.05)), end_levels, start_slope, relaxed, bends.duplicate(), start_roll, end_roll, roll_twist]
	#var key := [snapped_end, _snap_id, end_pos, target.snapped(Vector2(0.05, 0.05)), end_levels, start_slope, relaxed]
	if not force and key == _last_key:
		return
	_last_key = key
	var path := get_comp(C_Path) as C_Path
	if not path:
		return
	var lim := _limits()
	var res: Dictionary
	var y1 := 0.0
	var m1 := 0.0
	
	#Вставлено для ручек
	if not bends.is_empty():
		var p_end: Vector2 = end_pos if snapped_end else target
		var t_end := end_tan
		if not snapped_end:
			t_end = (p_end - bends.back()).normalized()   # у свободного конца касательная от последнего изгиба
			if t_end.is_zero_approx():
				t_end = Vector2(0.0, 1.0)
		var wp: Array[Vector2] = [Vector2.ZERO]
		wp.append_array(bends)
		wp.append(p_end)
		res = FlexSolver.best_chain(wp, Vector2(0.0, 1.0), t_end, lim, STEP, Global.settings.flex_bend_k)
		#res = FlexSolver.best_chain(wp, Vector2(0.0, 1.0), t_end, lim, STEP)
		res["radius"] = res.min_radius
		y1 = end_dy if snapped_end else end_levels * Global.settings.layer_height
		m1 = end_slope if snapped_end else 0.0
	elif snapped_end:
		res = FlexSolver.best_hermite(Vector2.ZERO, Vector2(0.0, 1.0), end_pos, end_tan, lim, STEP)
		y1 = end_dy
		m1 = end_slope
	else:
		res = FlexSolver.arc_to(target, lim, STEP)
		y1 = end_levels * Global.settings.layer_height
		
	var pts: PackedVector2Array = res.points
	radius = res.radius
	var cv: Dictionary = FlexSolver.to_curve3d(pts, 0.0, y1, start_slope, m1)
	# XX claude-coaster C8.2: крен концов в наклон точек кривой (меш, коллизия, вагон и опоры читают его оттуда)
	var roll_a := start_roll
	var roll_b := end_roll if snapped_end else start_roll + roll_twist
	if roll_a != 0.0 or roll_b != 0.0:
		TrackMeshBuilder.apply_roll(cv.curve, roll_a, roll_b)
	path.set_curve(cv.curve)   # шлет on_curve_changed: сокеты, опоры, меш
	length = cv.length
	grade = cv.max_grade
	dy = y1

	# Нарушения считаем по РЕАЛЬНЫМ пределам, блокируют они или нет решает _refresh_state
	var real := _limits(true)
	_issues.clear()
	if radius < real.r_min * 0.98:
		_issues.append("R")
	if length < real.l_min or length > real.l_max:
		_issues.append("L")
	if grade > real.max_grade:
		_issues.append("уклон")

	var last: Vector2 = pts[pts.size() - 1]
	end_local = Vector3(last.x, y1, -last.y)
	_update_label()
	_zones_refresh()   # XX claude-terra 13.1.7
	
	entity.send_event("on_bends_changed", {})




## Земля - лучи, поэтому не чаще GROUND_PERIOD_MS. Не зависит от остальных проверок
func _validate() -> void:
	if not stretching and not editing:
		return
	if not stretching:
		return
	var now := Time.get_ticks_msec()
	if now - _ground_ms >= GROUND_PERIOD_MS:
		_ground_ms = now
		_ground_pending = false
		var path := get_comp(C_Path) as C_Path
		_ground_bad = path != null and path.underground_depth(entity.global_transform) > Global.settings.underground_tolerance
	else:
		_ground_pending = true
		set_process(true)
	_refresh_state()


## Блокирует постановку (C_Invalid) только при включенном контроле
func _refresh_state() -> void:
	var violated := not _issues.is_empty() or _ground_bad
	_set_invalid(violated and not relaxed)


func _set_invalid(v: bool) -> void:
	if v != invalid:
		invalid = v
		if v:
			entity.add_component(C_Invalid.new())
		else:
			entity.remove_component(C_Invalid)
	_update_label()


func _update_label() -> void:
	if not _label:
		return
	var mid := Vector3(end_local.x * 0.5, end_local.y * 0.5, end_local.z * 0.5)
	var path := get_comp(C_Path) as C_Path
	if path and path.curve:
		mid = path.curve.sample_baked(path.curve.get_baked_length() * 0.5)
	_label.position = mid + Vector3(0.0, 6.0, 0.0)
	
	var r_txt := "∞" if is_inf(radius) else str(roundi(radius))
	var txt := "L %.1f · R %s · %+.1f (%.2f%%)" % [length, r_txt, dy, grade * 100.0]
	var reasons: Array[String] = _issues.duplicate()
	if _ground_bad:
		reasons.append("ground")
	if not reasons.is_empty():
		txt += "  ✗ " + ", ".join(PackedStringArray(reasons))
	var roll_b := end_roll if snapped_end else start_roll + roll_twist   # XX claude-coaster C8.2
	if start_roll != 0.0 or roll_b != 0.0:
		txt += "  · крен %+.0f° → %+.0f°" % [start_roll, roll_b]
	if relaxed:
		txt += "  [лимиты выкл, L]"
	_label.text = txt
	if invalid:
		_label.modulate = Color(1.0, 0.35, 0.35)      # блокирует постановку
	elif not reasons.is_empty():
		_label.modulate = Color(1.0, 0.85, 0.3)       # нарушение, но контроль выключен
	else:
		_label.modulate = Color.WHITE


func _process(_delta: float) -> void:
	if _zones_pending:   # XX claude-terra 13.1.7: отложенная перерисовка зон
		_zones_refresh()
	if preshaped:   # XX claude-terra 13.1.4
		_tick_preshaped()
		return
	if not _ground_pending or not (stretching or editing):
		if not _zones_pending:
			set_process(false)
		return
	#if not _ground_pending or not stretching:
		#set_process(false)
		#return
	if Time.get_ticks_msec() - _ground_ms >= GROUND_PERIOD_MS:
		_validate()


#
# ==========================================
# Поиск сокета для конца
# ==========================================

func _head_h() -> float:
	var p := get_comp(C_Path) as C_Path
	return p.head_height() if p else 0.0
	
	
## Ближайший свободный сокет чужого трака (по горизонтали от курсора).
## Возвращает {area, pos, out} или {}
func _find_end_socket(world: Vector3) -> Dictionary:
	if not Global.build_options.socket_snap:
		return {}   # U12: привязка к сокетам выключена
	var radius_max: float = Global.settings.flex_snap_radius
	#var start_w := entity.global_position
	var start_w := entity.global_position + Vector3(0.0, _head_h(), 0.0)
	var best := {}
	var best_d := radius_max
	for node in entity.get_tree().get_nodes_in_group(&"track_socket"):
		var other := node as Entity
		if other == null or other == entity or other.is_queued_for_deletion() or other.has_comp(C_Ghost):
			continue
		var oc := other.get_comp(C_Socket) as C_Socket
		if not oc or oc.network() != &"rail":   # XX claude-car CS1: flex цепляется только к рельсам
			continue
		for s in oc.sockets:
			var a: Area3D = s.socket
			var sp := a.global_position
			if sp.distance_to(start_w) < NEIGHBOR_EPS:
				continue   # стык моего начала
			var d := Vector2(sp.x - world.x, sp.z - world.z).length()
			if a.get_instance_id() == _snap_id:
				d *= SNAP_HYST
			if d >= best_d:
				continue
			if not oc.is_socket_free(a):
				continue
			best_d = d
			best = {"area": a, "pos": sp, "out": -a.global_basis.z, "up": oc._joint_up_world(a)}   # XX claude-coaster C8.2: «верх» сокета для крена
	return best


func _snap_to(sock: Dictionary) -> void:
	var o: Vector3 = sock.out
	var oh := Vector2(o.x, o.z)
	if oh.length() < 0.001:
		snapped_end = false
		return
	var local: Vector3 = entity.to_local(sock.pos)
	var d_loc: Vector3 = entity.global_basis.inverse() * (-o)   # движение в конце = против "наружу" соседа
	snapped_end = true
	_snap_id = (sock.area as Area3D).get_instance_id()
	end_pos = Vector2(local.x, -local.z)
	end_tan = Vector2(d_loc.x, -d_loc.z).normalized()
	#end_dy = local.y
	end_dy = local.y - _head_h()   # кривая у основания, сокет соседа на поверхности катания
	end_slope = -o.y / oh.length()
	# XX claude-coaster C8.2: крен у соседа конца. Мой ход в конце направлен к соседу (−o), «верх» сокета соседа в мире
	end_roll = _clean_roll(JointMath.roll_about(-o, sock.up)) if sock.has("up") else 0.0


## Сосед в моём начале: {o: направление «наружу» его сокета (в мою сторону), up: «верх» сокета в мире}. Пусто, если соседа нет.
## XX claude-coaster C8.2: общий поиск для уклона и крена
func _neighbor_start() -> Dictionary:
	#var start_w := entity.global_position
	var start_w := entity.global_position + Vector3(0.0, _head_h(), 0.0)
	var fwd := -entity.global_basis.z
	for node in entity.get_tree().get_nodes_in_group(&"track_socket"):
		var other := node as Entity
		if other == null or other == entity or other.is_queued_for_deletion() or other.has_comp(C_Ghost):
			continue
		var oc := other.get_comp(C_Socket) as C_Socket
		if not oc or oc.network() != &"rail":   # XX claude-car CS1: flex цепляется только к рельсам
			continue
		for s in oc.sockets:
			var a: Area3D = s.socket
			if a.global_position.distance_to(start_w) >= NEIGHBOR_EPS:
				continue
			var o := -a.global_basis.z
			var h := Vector2(o.x, o.z).length()
			if h > 0.001 and o.dot(fwd) > 0.0:
				return {"o": o, "up": oc._joint_up_world(a)}
	return {}


## Уклон соседа в моем начале (dy/ds движения от соседа ко мне). Нет соседа - 0
func _neighbor_slope() -> float:
	var n := _neighbor_start()
	if n.is_empty():
		return 0.0
	var o: Vector3 = n.o
	return o.y / Vector2(o.x, o.z).length()


## XX claude-coaster C8.2: крен соседа в моём начале, градусы (+ правый край ниже). Нет соседа или крена нет: 0
func _neighbor_roll() -> float:
	var n := _neighbor_start()
	if n.is_empty():
		return 0.0
	return _clean_roll(JointMath.roll_about(n.o, n.up))


## Шум вычислений (меньше 0.05°) не крен: у соседей без крена наклон точек кривой не пишется
static func _clean_roll(r: float) -> float:
	return 0.0 if absf(r) < 0.05 else snappedf(r, 0.01)


# ==========================================
# XX claude-terra 13.1.7. Зоны проблем: цветная полоса над рельсами (FlexZones)
# ==========================================

const ZONES_PERIOD_MS := 60        # не чаще: призрак перестраивается на каждое движение мыши

var _zones_mi: MeshInstance3D
var _zones_ms := 0
var _zones_pending := false


func on_component_removed(type: Script) -> void:
	if type == C_Selected:
		_zones_refresh(true)


func _on_zones_toggled() -> void:
	_zones_refresh(true)


## Полная полоса (с зеленым) у призрака, выбранного и редактируемого трака, у остальных только проблемные участки.
## Пределы настоящие (flex_r_min, flex_max_grade), независимо от клавиши L: контроль выключен, а вагон все равно сойдет
func _zones_refresh(force := false) -> void:
	if entity == null or not entity.is_inside_tree():
		return
	if not Global.flex_zones:
		_zones_hide()
		return
	var now := Time.get_ticks_msec()
	if not force and now - _zones_ms < ZONES_PERIOD_MS:
		_zones_pending = true
		set_process(true)
		return
	_zones_ms = now
	_zones_pending = false
	var path := get_comp(C_Path) as C_Path
	if path == null or path.curve == null or path.path_node == null:
		return
	var zl := _limits(true)   # XX claude-coaster C8: пределы flex горок свои (у обычного flex те же gs.flex_r_min и flex_max_grade)
	var full := entity.has_comp(C_Ghost) or stretching or editing or entity.has_comp(C_Selected)
	var fv := get_comp(C_FlexVisual) as C_FlexVisual
	var rail_x: float = fv.style.rail_x if fv and fv.style else 0.875
	var mesh := FlexZones.build_mesh(path, zl.r_min, zl.max_grade, full, rail_x * Global.flash_width)
	if mesh == null:
		_zones_hide()
		return
	if _zones_mi == null:
		_zones_mi = MeshInstance3D.new()
		_zones_mi.name = "FlexZones"
		_zones_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_zones_mi.material_override = FlexZones.material()
		entity.add_child.call_deferred(_zones_mi)   # первый раз можем оказаться внутри _ready сущности
	_zones_mi.mesh = mesh
	_zones_mi.transform = path.path_node.transform
	_zones_mi.visible = true


func _zones_hide() -> void:
	if _zones_mi:
		_zones_mi.visible = false


# ==========================================
# Метка над призраком
# ==========================================

func _ensure_label() -> void:
	if _label:
		return
	_label = TrackNote.line(entity, &"flex", 0)
	_label.visible = false

# ==========================================
# F3: изгибы (события шлет C_FlexHandle)
# ==========================================

func on_bend_edit_begin(_d: Dictionary) -> void:
	_begin_edit()


func on_bend_edit_end(_d: Dictionary) -> void:
	_end_edit()


func on_bend_moved(d: Dictionary) -> void:
	var i: int = d.get("index", -1)
	if not editing or i < 0 or i >= bends.size():
		return
	var p: Vector2 = d.pos
	if p.length() < BEND_MIN_GAP or p.distance_to(_end_plane()) < BEND_MIN_GAP:
		return
	bends[i] = p
	_apply()
	_validate()


func on_bend_add(d: Dictionary) -> void:
	var path := get_comp(C_Path) as C_Path
	if not path or not path.curve or bends.size() >= Global.settings.flex_max_bends:
		return
	var p: Vector3 = entity.to_local(d.position)
	var q := Vector2(p.x, -p.z)
	if q.length() < BEND_MIN_GAP or q.distance_to(_end_plane()) < BEND_MIN_GAP:
		return
	_begin_edit()
	if bends.is_empty() and not snapped_end:
		target = Vector2(end_local.x, -end_local.z)   # фиксируем реальный конец дуги (он мог упереться в лимит)
	var s := path.curve.get_closest_offset(p)
	var idx := 0
	for i in bends.size():
		if path.curve.get_closest_offset(bend_local(i)) < s:
			idx += 1
	bends.insert(idx, q)
	_apply(true)
	_validate()
	_end_edit()


func on_bend_remove(d: Dictionary) -> void:
	var i: int = d.get("index", -1)
	if i < 0 or i >= bends.size():
		return
	_begin_edit()
	bends.remove_at(i)
	_apply(true)
	_validate()
	_end_edit()


func _begin_edit() -> void:
	if editing:
		return
	editing = true
	_snapshot = _state()
	_ensure_label()
	_label.visible = true
	entity.send_event("on_flex_edit_started", {})


## Невалидная правка (лимиты при включенном контроле, под землей, пересечение) откатывается
func _end_edit() -> void:
	if not editing:
		return
	var path := get_comp(C_Path) as C_Path
	_ground_bad = path != null and path.underground_depth(entity.global_transform) > Global.settings.underground_tolerance
	var bad := (not relaxed and (not _issues.is_empty() or _ground_bad)) or has_comp(C_Blocked)
	editing = false
	if bad:
		_set_state(_snapshot)
		_apply(true)
	_ground_bad = false
	_set_invalid(false)
	if _label:
		_label.visible = false
	entity.send_event("on_flex_final", {})
	entity.send_event("on_bends_changed", {})


func _end_plane() -> Vector2:
	if snapped_end:
		return end_pos
	return target if not bends.is_empty() else Vector2(end_local.x, -end_local.z)


## Положение ручки i в осях Entity: точка кривой, ближайшая к изгибу в плане (там же высота)
func bend_local(i: int) -> Vector3:
	var q := bends[i]
	var best := Vector3(q.x, 0.0, -q.y)
	var path := get_comp(C_Path) as C_Path
	if path == null or path.curve == null:
		return best
	var bd := INF
	for p in path.curve.get_baked_points():
		var d := Vector2(p.x - q.x, -p.z - q.y).length_squared()
		if d < bd:
			bd = d
			best = p
	return best
	

# ==========================================
# SAVE\LOAD / клонирование
# ==========================================

func _state() -> Dictionary:
	return {
		"target": target,
		"end_levels": end_levels,
		"snapped_end": snapped_end,
		"end_pos": end_pos,
		"end_tan": end_tan,
		"end_dy": end_dy,
		"end_slope": end_slope,
		"start_slope": start_slope,
		"start_roll": start_roll,
		"end_roll": end_roll,
		"roll_twist": roll_twist,
		"relaxed": relaxed,
		"bends": bends.duplicate(),
	}


func _set_state(d: Dictionary) -> void:
	if d.has("target"): target = d.target
	if d.has("end_levels"): end_levels = d.end_levels
	if d.has("snapped_end"): snapped_end = d.snapped_end
	if d.has("end_pos"): end_pos = d.end_pos
	if d.has("end_tan"): end_tan = d.end_tan
	if d.has("end_dy"): end_dy = d.end_dy
	if d.has("end_slope"): end_slope = d.end_slope
	if d.has("start_slope"): start_slope = d.start_slope
	if d.has("start_roll"): start_roll = d.start_roll
	if d.has("end_roll"): end_roll = d.end_roll
	if d.has("roll_twist"): roll_twist = d.roll_twist
	if d.has("relaxed"): relaxed = d.relaxed
	if d.has("bends"):
		bends.clear()
		for b in d.bends:
			bends.append(b)


func save_data() -> Dictionary:
	var d := _state()
	d['comp_path'] = get_script().resource_path
	d['comp_name'] = get_script().resource_path.get_file().get_basename()
	return d


func load_data(data: Dictionary) -> void:
	_set_state(data)
	_apply(true)
	# После загрузки меш и коллизии нужны сразу в финальном виде: иначе C_FlexVisual перестроит их позже по таймеру
	# (flex_rebuild_period), а SaveManager уже сажает вагоны на рельсы лучом и не находит трак (вагон остается сошедшим)
	entity.send_event("on_flex_final", {})
