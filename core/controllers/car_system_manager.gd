extends Node
# class_name не задаём: это синглтон CSM (autoload), как TGM, LYM и PGM
###########################
## CSM. Менеджер системы машин (autoload), ATTN_28 CS2 и CS3
###########################
## Хранит машины (C_RoadVehicle регистрируется сам при готовности сущности) и гоняет решения с частотой TICK_HZ.
## Положение машина интегрирует сама каждый физический кадр (C_RoadVehicle._physics_process), а решения (целевая скорость,
## остановиться на конце дороги, поехать снова, потеря полосы) и проверка аварий считаются здесь реже: 20 Гц, как в Wunderland (ATTN_28 §28.6).
## Авария (CS3, Р7): контроля дистанции нет, поэтому машина, догнавшая другую, врезается. Перекрытие кузовов ищется в тике по сетке
## ячеек CELL (соседние ячейки), а не перебором всех пар: стоимость растёт с числом машин линейно.
## Управляющие элементы (CS4a): C_RoadControl регистрируется сам, CSM отдаёт его машинам по куску дороги (control_of), считает занятость
## датчиков в тике и хранит занятость групп для автоматики «занято, значит стоп».

## Частота решений, Гц
const TICK_HZ := 20.0
const TICK := 1.0 / TICK_HZ
## Размер ячейки сетки аварий, ю (больше длины кузова)
const CELL := 6.0
## Кузова считаются чуть меньше, чтобы касание без перекрытия не было аварией
const BODY_SHRINK := 0.95
## Разница высот, выше которой машины на разных уровнях (эстакада над дорогой) не сталкиваются, ю
const LEVEL_GAP := 1.5

## ⚡ Тик решений. dt это прошедшее с прошлого тика время, с
signal ticked(dt: float)
## ⚡ Авария двух машин. culprit врезалась (догнала), victim пострадала; при лобовом culprit более быстрая.
## reason: &"rear_end", &"head_on", &"side"
signal crashed(culprit: C_RoadVehicle, victim: C_RoadVehicle, reason: StringName)

## Сколько аварий было с начала сессии
var crash_count := 0

## ⚡ Датчик сменил состояние
signal sensor_changed(control: C_RoadControl, occupied: bool)

var _vehicles: Array[C_RoadVehicle] = []
var _controls: Dictionary = {}     # instance_id куска дороги -> C_RoadControl
var _groups_occupied: Dictionary = {}   # метка группы -> занят ли какой-либо датчик группы
var _acc := 0.0
var _step_usec := 0


func register(v: C_RoadVehicle) -> void:
	if v != null and not _vehicles.has(v):
		_vehicles.append(v)


func unregister(v: C_RoadVehicle) -> void:
	_vehicles.erase(v)


## Живые машины (без удаляемых)
func get_vehicles() -> Array[C_RoadVehicle]:
	var res: Array[C_RoadVehicle] = []
	for v in _vehicles:
		if is_instance_valid(v) and not v.is_queued_for_deletion():
			res.append(v)
	return res


func count() -> int:
	return get_vehicles().size()


## XX claude-car CS4a. Управляющий элемент куска дороги (стоп-секция, парковка, датчик) или null
func control_of(track: Entity) -> C_RoadControl:
	if track == null or not is_instance_valid(track):
		return null
	return _controls.get(track.get_instance_id())


func register_control(c: C_RoadControl) -> void:
	if c != null and c.entity != null:
		_controls[c.entity.get_instance_id()] = c


func unregister_control(c: C_RoadControl) -> void:
	if c != null and c.entity != null and _controls.get(c.entity.get_instance_id()) == c:
		_controls.erase(c.entity.get_instance_id())


## Занят ли какой-либо датчик группы (по состоянию последнего тика)
func group_occupied(group: StringName) -> bool:
	return bool(_groups_occupied.get(group, false))


## Замер: машины прибавляют сюда время своего физического шага, мкс. Бенч забирает через take_step_usec
func add_step_usec(us: int) -> void:
	_step_usec += us


func take_step_usec() -> int:
	var us := _step_usec
	_step_usec = 0
	return us


func _physics_process(delta: float) -> void:
	_acc += delta
	if _acc < TICK:
		return
	var dt := _acc
	_acc = 0.0
	var alive: Array[C_RoadVehicle] = []
	for v in _vehicles:
		if is_instance_valid(v):
			alive.append(v)
			v.decide(dt)
	_vehicles = alive
	_update_controls()
	_check_crashes()
	ticked.emit(dt)


# ==========================================
# Управляющие элементы
# ==========================================

func _update_controls() -> void:
	if _controls.is_empty():
		return
	var on_track := {}
	for v in _vehicles:
		if v.mode != C_RoadVehicle.Mode.OFF_ROAD and v.state.has("track") and is_instance_valid(v.state.track):
			on_track[(v.state.track as Object).get_instance_id()] = true
	var groups := {}
	for id in _controls.keys():
		var c: C_RoadControl = _controls[id]
		if not is_instance_valid(c):
			_controls.erase(id)
			continue
		c.tick(on_track)
		if c.kind == C_RoadControl.KIND_SENSOR and not c.group.is_empty() and c.occupied:
			groups[c.group] = true
	_groups_occupied = groups


# ==========================================
# Аварии
# ==========================================

func _check_crashes() -> void:
	var grid := {}
	var list: Array[C_RoadVehicle] = []
	for v in _vehicles:
		if v.mode == C_RoadVehicle.Mode.OFF_ROAD or v.is_held() or not v.entity.is_inside_tree():
			continue
		list.append(v)
		var p := v.entity.global_position
		var key := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(v)
	for a in list:
		var pa := a.entity.global_position
		var ka := Vector2i(floori(pa.x / CELL), floori(pa.z / CELL))
		for ox in range(-1, 2):
			for oz in range(-1, 2):
				var cell: Array = grid.get(Vector2i(ka.x + ox, ka.y + oz), [])
				for b in cell:
					if b.get_instance_id() <= a.get_instance_id():
						continue   # каждую пару один раз
					_check_pair(a, b)


func _check_pair(a: C_RoadVehicle, b: C_RoadVehicle) -> void:
	if a.mode == C_RoadVehicle.Mode.CRASHED and b.mode == C_RoadVehicle.Mode.CRASHED:
		return
	var pa := a.entity.global_position
	var pb := b.entity.global_position
	if absf(pa.y - pb.y) > LEVEL_GAP:
		return   # разные уровни (эстакада)
	var fa := _flat(-a.entity.global_basis.z)
	var fb := _flat(-b.entity.global_basis.z)
	if not _boxes_overlap(pa, fa, a.body_length(), a.body_width(), pb, fb, b.body_length(), b.body_width()):
		return
	var same := fa.dot(fb)
	var culprit := a
	var victim := b
	var reason := &"side"
	var rel := absf(a.speed - b.speed)
	if same > 0.5:
		reason = &"rear_end"
		# позади та, у которой другая впереди по её ходу
		var ahead := Vector2(pb.x - pa.x, pb.z - pa.z).dot(fa) > 0.0
		culprit = a if ahead else b
		victim = b if ahead else a
		rel = maxf(culprit.speed - victim.speed, culprit.speed if victim.mode == C_RoadVehicle.Mode.CRASHED else 0.0)
	elif same < -0.5:
		reason = &"head_on"
		culprit = a if a.speed >= b.speed else b
		victim = b if culprit == a else a
		rel = a.speed + b.speed
	else:
		culprit = a if a.speed >= b.speed else b
		victim = b if culprit == a else a
		rel = sqrt(a.speed * a.speed + b.speed * b.speed)
	culprit.set_crashed(reason, &"culprit", victim, rel)
	victim.set_crashed(reason, &"victim", culprit, rel)
	crash_count += 1
	crashed.emit(culprit, victim, reason)


static func _flat(v: Vector3) -> Vector2:
	var f := Vector2(v.x, v.z)
	return f.normalized() if f.length_squared() > 0.0001 else Vector2(0.0, -1.0)


## Пересечение двух прямоугольников (вид сверху) по теореме о разделяющей оси. Длина вдоль хода, ширина поперёк
static func _boxes_overlap(pa: Vector3, fa: Vector2, la: float, wa: float, pb: Vector3, fb: Vector2, lb: float, wb: float) -> bool:
	var d := Vector2(pb.x - pa.x, pb.z - pa.z)
	var ra := Vector2(-fa.y, fa.x)
	var rb := Vector2(-fb.y, fb.x)
	var ha_l := la * 0.5 * BODY_SHRINK
	var ha_w := wa * 0.5 * BODY_SHRINK
	var hb_l := lb * 0.5 * BODY_SHRINK
	var hb_w := wb * 0.5 * BODY_SHRINK
	for axis in [fa, ra, fb, rb]:
		var rad_a := ha_l * absf(fa.dot(axis)) + ha_w * absf(ra.dot(axis))
		var rad_b := hb_l * absf(fb.dot(axis)) + hb_w * absf(rb.dot(axis))
		if absf(d.dot(axis)) > rad_a + rad_b:
			return false
	return true
