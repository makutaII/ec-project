class_name C_Switch extends ICapability

# XX claude-switch (новый файл)
####################
## Способность. Управление стрелкой: какой маршрут активен, кто и как его переключает.
####################
## Геометрию и маршруты держит C_Path (routes / active_route), форму строит C_SwitchShape.
## Тут только положение и правила перекладки:
##  - MANUAL: переключает рычаг у стрелки (клик по рычагу, источник &"manual");
##  - REMOTE: рычаг заблокирован (привод держит стрелку), команды приходят из панели/проводов (&"remote").
##    Время перекладки throw_time (0 = мгновенно). Пока идет перекладка, состояние MOVING.
##  - Стрелку под вагоном не переложить (замок): пока тележка стоит на этом траке, команда отклоняется.
## Шина событий:
##   on_switch_request {route = -1 (следующий) или индекс, source} -> data.ok / data.reason
##   on_lever_pressed {collider, consumed} - от SelectTool по клику в рычаг
##   исходящие: on_switch_changed {route, source}, on_switch_moving {route}, on_switch_rejected {reason}
## Электрика:
##  - E0 (power_routing = false): стрелка один проводящий трак (C_PowerTrack), обе ветки всегда под током.
##  - E1 (power_routing = true): ток идет от носка только на выбранную ветку. Сокет неактивной ветки мертвый
##    (C_Socket.set_socket_live), PGM через него не ходит: трак за невыбранной веткой обесточен, пока его не
##    питает свой клип. При переключении сеть пересчитывается. Если выбранная ветка соединяет два разных контура,
##    сработает обычное "столкновение контуров" PGM (в реальности это КЗ между цепями).
##  - E2 (frog): у токопроводящей крестовины (electrofrog) полярность должна совпадать с выбранным путем, иначе колесо,
##    замкнувшее крестовину и соседний рельс, дает КЗ. Режимы Frog: INSULATED (пластиковая, КЗ нет), LIVE_FIXED
##    (крестовина привязана к пути 0: на пути 1 при заезде в зону крестовины КЗ), LIVE_SWITCHED (полярность
##    переключается вместе со стрелкой: контакты привода, реле, frog juicer). При power_routing КЗ нет: ток
##    на крестовину идет через остряки. КЗ отключает контур (PGM.trip_contour), сброс: аварийный стоп выкл/вкл.

enum Drive { MANUAL, REMOTE }
enum State { SETTLED, MOVING }
enum Frog { INSULATED, LIVE_FIXED, LIVE_SWITCHED }

const FROG_HALF := 1.5   # ю, половина зоны крестовины вдоль пути (колесо замыкает крестовину и рельс рядом)

const GROUP := &"switch"

var route := 0
var control: Drive = Drive.MANUAL
## Время перекладки, с. 0 = мгновенно
var throw_time := 0.0
## E1: ток только на выбранную ветку (см. шапку). Выставляет SwitchSettings, меняется в игре set_power_routing()
var power_routing := false
## E2: тип крестовины (см. шапку)
var frog: Frog = Frog.INSULATED
## Где крестовина вдоль каждого маршрута (дистанция от носка), -1 нет. [путь 0, путь 1]
var frog_s: Array[float] = []
## Стартовое положение. Задает SwitchSettings из паспорта (SwitchConfig); дальше живет route
var start_route := 0
var state: State = State.SETTLED

var _target := 0
var _source: StringName = &"manual"
var _t := 0.0
var _last_reason: StringName = &""   # причина последнего отказа request(), для отладочного UI
var _loaded := false      # load_data уже отработал: on_entity_ready не должен сбрасывать положение в стартовое
var _frog_watch := false  # следим за зоной крестовины (E2, LIVE_FIXED на пути 1)


func _init() -> void:
	set_physics_process(false)


func on_added() -> void:
	entity.add_to_group(GROUP)


func on_entity_ready() -> void:
	# Если сейв уже принес положение (load_data раньше on_entity_ready), стартовое его не перезаписывает
	if not _loaded:
		route = start_route
	_compute_frog()
	_apply(route, &"init")


# ==========================================
# API
# ==========================================

func route_count() -> int:
	var p := get_comp(C_Path) as C_Path
	return maxi(p.routes.size(), 1) if p else 1


## Запрос на перекладку. target = -1: следующий маршрут по кругу. Возвращает true, если принят
func request(target: int, source: StringName) -> bool:
	if state == State.MOVING:
		return _reject(&"moving")
	var n := route_count()
	if n < 2:
		return _reject(&"single_route")
	if target < 0:
		target = (route + 1) % n
	if target >= n:
		return _reject(&"bad_route")
	if source != &"force":
		if control == Drive.MANUAL and source != &"manual":
			return _reject(&"manual_only")
		if control == Drive.REMOTE and source != &"remote":
			return _reject(&"remote_only")
		# D6: привод дистанционной стрелки питается от шины аксессуаров
		if control == Drive.REMOTE and not PGM.bus_powered():
			return _reject(&"no_power")
	if target == route:
		return true
	if is_occupied():
		return _reject(&"occupied")

	if throw_time <= 0.0:
		_apply(target, source)
	else:
		state = State.MOVING
		_target = target
		_source = source
		_t = 0.0
		set_physics_process(true)
		entity.send_event("on_switch_moving", {"route": target})
	return true


## Замок: на стрелке стоит тележка какого-либо вагона, стоящего на рельсах (сошедший не в счет)
func is_occupied() -> bool:
	return not _bogies_on_switch().is_empty()


## Тележки вагонов, стоящих на рельсах, которые сейчас на этой стрелке
func _bogies_on_switch() -> Array[C_Bogie.BogieData]:
	var res: Array[C_Bogie.BogieData] = []
	if entity == null or not entity.is_inside_tree():
		return res
	for node in entity.get_tree().get_nodes_in_group(C_Bogie.GROUP):
		var wagon := node as Entity
		if wagon == null or wagon.is_queued_for_deletion():
			continue
		var bc := wagon.get_comp(C_Bogie) as C_Bogie
		if bc == null or bc.is_derailed:
			continue
		# Сошедший вагон (и тот, что в руке игрока) не на рельсах: стрелку он не держит,
		# хотя current_track у его тележек еще указывает на нее
		var ch := wagon.get_comp(C_Chassis) as C_Chassis
		if ch != null and not ch.is_on_rails:
			continue
		for b in bc.bogies_data:
			if b.current_track == entity:
				res.append(b)
	return res


# ==========================================
# События
# ==========================================

func on_switch_request(data: Dictionary) -> void:
	_last_reason = &""
	var ok := request(int(data.get("route", -1)), data.get("source", &"remote"))
	data["ok"] = ok
	data["reason"] = _last_reason


## Клик в рычаг (SelectTool шлет, когда луч попал в слой handles и сущность имеет C_Switch).
## Забираем нажатие всегда, даже если стрелка не приняла команду (иначе клик выберет/потащит трак)
func on_lever_pressed(data: Dictionary) -> void:

	var col := data.get("collider") as Node
	if col == null or not col.has_meta(&"switch_lever") or not entity.is_ancestor_of(col):
		return
	request(-1, &"manual")
	data["consumed"] = true


func _unhandled_key_input(event: InputEvent) -> void:
	# Временная кнопка пульта: T по выбранной стрелке = команда remote. Заменит панель/провода (Roadmap 13)
	if Actions.pressed(event, &"switch_throw") and entity and entity.has_comp(C_Selected) and not entity.has_comp(C_Ghost):
		request(-1, &"remote")


func _physics_process(delta: float) -> void:
	if state != State.MOVING:
		_check_frog()   # E2: следим за зоной крестовины
		return
	_t += delta
	if _t < throw_time:
		return
	state = State.SETTLED
	if is_occupied():
		_reject(&"occupied")   # пока перекладывали, заехала тележка: возвращаем как было
		_update_process()
		return
	_apply(_target, _source)


# ==========================================
# Внутреннее
# ==========================================

func _apply(target: int, source: StringName) -> void:
	var path := get_comp(C_Path) as C_Path
	if path and path.is_multi_route():
		path.set_active_route(target)
	route = target
	_update_liveness()
	_update_process()
	entity.send_event("on_switch_changed", {"route": route, "source": source})
	# E1: смена ветки меняет питание соседей. При старте пересчет не нужен (его вызовут стыки), призрак сеть не трогает
	if power_routing and source != &"init":
		_recalc_power()


## Включить или выключить E1 в игре
func set_power_routing(on: bool) -> void:
	if on == power_routing:
		return
	power_routing = on
	_update_liveness()
	_update_process()
	_recalc_power()
	entity.send_event("on_switch_power_mode_changed", {})   # визуал перекрашивает ветки сразу


## Сменить способ управления в игре (отладка/аксессуар). Пока идет перекладка, не меняем
func set_control(mode: Drive) -> void:
	if state == State.MOVING:
		return
	control = mode


## Сменить тип крестовины в игре (E2)
func set_frog_mode(mode: Frog) -> void:
	frog = mode
	_update_process()


## Сокеты стрелки по порядку: [0] носок, [1] конец прямой, [2] конец ответвления.
## E1: живы носок и сокет активной ветки. E0: все живые
func _update_liveness() -> void:
	var sock := get_comp(C_Socket) as C_Socket
	if sock == null:
		return
	for i in sock.sockets.size():
		var live := true
		if power_routing and i >= 1:
			live = (i == 1 + route)
		sock.set_socket_live(i, live)


## Физика нужна только пока идет перекладка или пока включено слежение за крестовиной
func _update_process() -> void:
	_frog_watch = frog == Frog.LIVE_FIXED and not power_routing and route != 0 \
			and not frog_s.is_empty() and entity != null and not entity.has_comp(C_Ghost)
	set_physics_process(state == State.MOVING or _frog_watch)


## Положение крестовины: где внутренний рельс ответвления пересекает внутренний рельс прямой.
## У прямой он на оси, поэтому ищем точку, где ответвление ушло от оси на колею
func _compute_frog() -> void:
	frog_s = []
	var path := get_comp(C_Path) as C_Path
	if path == null or path.routes.size() < 2:
		return
	var vis := get_comp(C_SwitchVisual) as C_SwitchVisual
	var gauge := vis.style.rail_x * 2.0 if vis and vis.style else 1.75
	var c1: Curve3D = path.routes[1]
	var l1 := c1.get_baked_length()
	var n := maxi(1, ceili(l1 / 0.25))
	var s0 := -1.0
	var s1 := -1.0
	for i in n + 1:
		var s := l1 * i / n
		var p := c1.sample_baked(s)
		if absf(p.x) >= gauge:
			s1 = s
			s0 = -p.z          # прямая идет вдоль -Z от носка
			break
	frog_s = [s0, s1]


## E2: на пути, чья полярность не совпадает с крестовиной, тележка в зоне крестовины замыкает цепь
func _check_frog() -> void:
	var pt := get_comp(C_PowerTrack) as C_PowerTrack
	var cid := pt.contour_of(0) if pt else 0
	if cid == 0 or PGM.get_power(cid) == 0.0:
		return   # цепь обесточена, замыкать нечего
	var zone: float = frog_s[route] if route < frog_s.size() else -1.0
	if zone < 0.0:
		return
	for b in _bogies_on_switch():
		if absf(b.track_distance - zone) <= FROG_HALF:
			PGM.trip_contour(cid, "frog")
			entity.send_event("on_switch_short", {"contour": cid})
			return


func _recalc_power() -> void:
	if entity and not entity.has_comp(C_Ghost):
		PGM.request_recalculate()


func _reject(reason: StringName) -> bool:
	_last_reason = reason
	entity.send_event("on_switch_rejected", {"reason": reason})
	return false


# ==========================================
# Save / Load
# ==========================================

func save_data() -> Dictionary:
	return {
		'comp_path': get_script().resource_path,
		'comp_name': get_script().resource_path.get_file().get_basename(),
		"route": route,
		"control": int(control),
		"throw_time": throw_time,
		"power_routing": power_routing,
		"frog": int(frog),
	}


func load_data(data: Dictionary) -> void:
	control = int(data.get("control", control)) as Drive
	throw_time = float(data.get("throw_time", throw_time))
	power_routing = bool(data.get("power_routing", power_routing))
	frog = int(data.get("frog", int(frog))) as Frog
	_loaded = true
	# Положение применяем сразу: сущность уже собрана (SaveManager грузит после add_child),
	# а вагоны садятся на трак позже (restore_snap_after_load) и считают смещение по активной кривой
	_apply(int(data.get("route", route)), &"load")


## Строки подсказки при наведении и вкладки «Подсказки» (контракт HoverLines, U5a.5)
func get_hover_lines() -> Array:
	var lines: Array = [HoverLines.line("Положение: %s" % ("прямо" if route == 0 else "ответвление (%d)" % route))]
	if state == State.MOVING:
		lines.append(HoverLines.line("идёт перекладка", &"warn"))
	elif is_occupied():
		lines.append(HoverLines.line("на стрелке вагон (замок)", &"warn"))
	return lines
