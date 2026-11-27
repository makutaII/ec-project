class_name C_RoadVehicle extends Component

###########################
## Состояние и движение машины по дороге (ATTN_28 §28.4, CS2 и CS3)
###########################
## Положение это состояние ходьбы {track, route, dist, dir} (PathWalker, как у частей состава). Машина едет по оси полосы.
## Скорость (CS3): целевая v = min(max_speed, sqrt(lat_accel_max * R)) по радиусу кривой R (C_Path.radius_at), и машина успевает
## затормозить заранее: вперёд по пути на тормозной путь смотрятся ограничения и допустимая скорость в точке на расстоянии d считается
## как sqrt(v_огр^2 + 2 * brake * d). Конец дороги это ограничение 0: машина тормозит и встаёт у самого края (Р6).
## Фактическая скорость меняется не быстрее accel (разгон) и brake (торможение) из паспорта CarConfig.
## Дистанцию до машины впереди машина не держит (Р7): догнавшая машина врезается, это авария. Авария находится в тике CSM по
## перекрытию кузовов, обе машины встают (CRASHED), над ними метка с причиной, CSM.crashed даёт событие.
## Положение интегрируется каждый физический кадр, решения (целевая скорость, продолжить езду, потеря полосы) в тике CSM, 20 Гц.
## Вагоны машину не видят (слой cars), машина вагоны тоже: она только ходит по сплайну и не имеет физики.

## Слой пути, по которому ходит машина
const ROAD_LAYER := &"roads"
## Параметры по умолчанию, если в паспорте нет CarConfig
const DEFAULT_SPEED := 10.0
const DEFAULT_ACCEL := 6.0
const DEFAULT_BRAKE := 12.0
const DEFAULT_LAT_ACCEL := 3.0
## Насколько вперёд заглядываем из остановки, ю: есть ли дальше дорога
const RESUME_PROBE := 0.5
## Шаг просмотра пути вперёд при выборе скорости, ю, и запас к тормозному пути, ю
const LOOK_STEP := 1.0
const LOOK_MARGIN := 2.0
const LOOK_MAX := 40.0
## Насколько дальше за край смотрит луч при переходе на следующий кусок, ю (коллизия куска короче его на 0.2 ю с торца, PathWalker.advance)
const CROSS_PROBE := 0.3
## Запас луча вниз при поиске дороги под машиной после загрузки, ю
const LOAD_RAY_UP := 1.0
const LOAD_RAY_DOWN := 2.0

enum Mode { OFF_ROAD, DRIVING, HALTED, CRASHED }   # не на полосе, едет, стоит на конце дороги, авария

var mode := Mode.OFF_ROAD
## Состояние ходьбы {track, route, dist, dir}. Пусто, когда машина не на полосе
var state: Dictionary = {}
var speed := 0.0
## Скорость, к которой машина стремится (обновляется в тике CSM)
var target_speed := 0.0
## Описание аварии {reason, role, other, speed}, пока mode == CRASHED
var crash: Dictionary = {}

var _saved_on_road := false
var _held := false          # машина призрак или в драге: не едет
var _cfg: CarConfig
# Кэш пути под колёсами: шаг в кадр не должен искать компоненты
var _track: Entity
var _pc: C_Path
var _crv: Curve3D
var _node: Path3D
var _len := 0.0
var _head_h := 0.0
var _dist := 0.0
var _dir := 1.0
var _note: TrackNote.Line


func on_entity_ready() -> void:
	_cfg = CarConfig.from_entity(entity)
	_held = entity.has_comp(C_Drag) or entity.has_comp(C_Ghost)
	CSM.register(self)


func _exit_tree() -> void:
	if is_instance_valid(CSM):
		CSM.unregister(self)


func on_component_added(t: Script) -> void:
	if t == C_Drag or t == C_Ghost:
		_held = true


func on_component_removed(t: Script) -> void:
	_held = (t != C_Drag and entity.has_comp(C_Drag)) or (t != C_Ghost and entity.has_comp(C_Ghost))


# ==========================================
# Паспорт
# ==========================================

## Призрак или машина в драге: не едет и в проверке аварий не участвует
func is_held() -> bool:
	return _held


func max_speed() -> float:
	return _config().max_speed if _config() != null else DEFAULT_SPEED


func accel() -> float:
	return _config().accel if _config() != null else DEFAULT_ACCEL


func brake() -> float:
	return _config().brake if _config() != null else DEFAULT_BRAKE


func lat_accel() -> float:
	return _config().lat_accel_max if _config() != null else DEFAULT_LAT_ACCEL


func _config() -> CarConfig:
	if _cfg == null:
		_cfg = CarConfig.from_entity(entity)
	return _cfg


## Габариты кузова для проверки аварий, ю
func body_length() -> float:
	return _config().length if _config() != null else 5.0


func body_width() -> float:
	return _config().width if _config() != null else 2.2


# ==========================================
# Посадка и потеря полосы
# ==========================================

## Посадка на полосу. world_dir: в какую сторону смотрит машина, по нему выбирается направление ходьбы. false: полосы нет
func snap_to(track: Entity, route: int, dist: float, world_dir: Vector3) -> bool:
	var st := PathWalker.from_snap(track, route, dist, world_dir)
	if st.is_empty():
		return false
	_clear_crash()
	_set_state(st)
	mode = Mode.DRIVING
	speed = 0.0
	target_speed = max_speed()
	_apply_pose()
	return true


## ⚡ Драг посадил машину на полосу: {track, route, offset, world_dir}
func on_car_snapped(data: Dictionary) -> void:
	snap_to(data.track, int(data.get("route", 0)), float(data.offset), data.world_dir)


## ⚡ Машину сняли с полосы (взяли в драг или бросили мимо дороги)
func on_car_unsnapped(_data: Dictionary) -> void:
	_lose_road()


func _lose_road() -> void:
	_clear_crash()
	state = {}
	_track = null
	_pc = null
	_crv = null
	mode = Mode.OFF_ROAD
	speed = 0.0
	target_speed = 0.0


## Кэш пути по новому состоянию ходьбы
func _set_state(st: Dictionary) -> void:
	state = st
	_dist = float(st.dist)
	_dir = float(st.dir)
	if st.track != _track or _pc == null or _crv == null or _pc.curve_of(int(st.route)) != _crv:
		_track = st.track
		_pc = (st.track as Entity).get_comp(C_Path) as C_Path
		_crv = _pc.curve_of(int(st.route)) if _pc != null else null
		_node = _pc.path_node if _pc != null else null
		_len = _crv.get_baked_length() if _crv != null else 0.0
		_head_h = _pc.head_height() if _pc != null else 0.0


func _road_valid() -> bool:
	return _track != null and is_instance_valid(_track) and not _track.is_queued_for_deletion()


# ==========================================
# Движение каждый физический кадр
# ==========================================

func _physics_process(delta: float) -> void:
	if mode != Mode.DRIVING or _held:
		return
	var t0 := Time.get_ticks_usec()
	if not _road_valid():
		_lose_road()
		return
	var a := accel() if target_speed > speed else brake()
	speed = move_toward(speed, target_speed, a * delta)
	var target := _dist + _dir * speed * delta
	if target >= 0.0 and target <= _len:
		_dist = target
		state.dist = target
		_apply_pose_fast()
	else:
		var nxt := PathWalker.advance(state, speed * delta, ROAD_LAYER, CROSS_PROBE)
		if nxt.is_empty():
			_halt()
		else:
			_set_state(nxt)
			_apply_pose()
	CSM.add_step_usec(Time.get_ticks_usec() - t0)


## Решения 20 Гц (вызывает CSM)
func decide(_dt: float) -> void:
	match mode:
		Mode.DRIVING:
			if not _road_valid():
				_lose_road()
			elif not _held:
				target_speed = _plan_speed()
		Mode.HALTED:
			if not _road_valid():
				_lose_road()
			elif not PathWalker.advance(state, RESUME_PROBE, ROAD_LAYER, CROSS_PROBE).is_empty():
				mode = Mode.DRIVING   # дорогу достроили
				target_speed = _plan_speed()
		Mode.CRASHED:
			if not _road_valid():
				_lose_road()


## Скорость, с которой можно ехать сейчас: ограничение в этой точке и допустимая скорость по ограничениям впереди,
## чтобы успеть затормозить (sqrt(v_огр^2 + 2 * brake * d)); дорога кончилась: ограничение 0 у края
func _plan_speed() -> float:
	var br := maxf(brake(), 0.1)
	var best := _limit_at(state)
	var look := minf(speed * speed / (2.0 * br) + LOOK_MARGIN, LOOK_MAX)
	var st := state
	var d := 0.0
	while d < look:
		var step := PathWalker.dist_to_end(st)
		if step > LOOK_STEP:
			# внутри маршрута: просто сдвигаем состояние
			st = st.duplicate()
			st.dist = float(st.dist) + float(st.dir) * LOOK_STEP
			d += LOOK_STEP
		else:
			var nxt := PathWalker.advance(st, step + 0.01, ROAD_LAYER, CROSS_PROBE)
			d += step
			if nxt.is_empty():
				best = minf(best, sqrt(2.0 * br * maxf(d, 0.0)))   # конец дороги: остановиться у самого края
				break
			st = nxt
			d += 0.01
		best = minf(best, sqrt(_limit_at(st) * _limit_at(st) + 2.0 * br * d))
	return best


## Ограничение скорости в точке состояния: предел паспорта и поворот
func _limit_at(st: Dictionary) -> float:
	var v := max_speed()
	var r := PathWalker.radius_at(st)
	if r < INF:
		v = minf(v, sqrt(lat_accel() * maxf(absf(r), 0.01)))
	return v


## Встали на самом краю маршрута
func _halt() -> void:
	if _crv != null:
		state.dist = _len if _dir > 0.0 else 0.0
		_dist = float(state.dist)
		_apply_pose_fast()
	mode = Mode.HALTED
	speed = 0.0
	target_speed = 0.0


## Положение по общему пути (после смены куска, посадки, остановки)
func _apply_pose() -> void:
	if _crv == null:
		return
	_apply_pose_fast()


## Центр кузова над точкой сплайна (точка плюс высота головки), смотрит вдоль хода. Один замер сплайна и одна запись transform
func _apply_pose_fast() -> void:
	var gt := _node.global_transform * _crv.sample_baked_with_rotation(_dist)
	var heading := (-gt.basis.z * _dir).normalized()
	var basis := entity.global_basis
	if absf(heading.y) < 0.99:
		basis = Basis.looking_at(heading, Vector3.UP)
	entity.global_transform = Transform3D(basis, gt.origin + Vector3(0.0, _head_h, 0.0))


# ==========================================
# Авария (CS3)
# ==========================================

## ⚡ CSM нашёл перекрытие. role: &"culprit" (догнала или врезалась) или &"victim". reason: &"rear_end", &"head_on", &"side"
func set_crashed(reason: StringName, role: StringName, other: C_RoadVehicle, rel_speed: float) -> void:
	if mode == Mode.CRASHED or mode == Mode.OFF_ROAD:
		return
	mode = Mode.CRASHED
	speed = 0.0
	target_speed = 0.0
	crash = {"reason": reason, "role": role, "other": other, "speed": rel_speed}
	if _note == null:
		_note = TrackNote.line(entity, &"crash", 1)
		_note.position = Vector3(0.0, 4.0, 0.0)
	_note.modulate = Color(1.0, 0.35, 0.3)
	_note.text = crash_text()
	_note.visible = true


## Причина аварии, видимая игроку
func crash_text() -> String:
	if crash.is_empty():
		return ""
	var v := "%.1f ю/с" % float(crash.get("speed", 0.0))
	match crash.reason:
		&"rear_end":
			return "Авария: догнала машину впереди (%s)" % v if crash.role == &"culprit" else "Авария: в машину врезалась другая сзади (%s)" % v
		&"head_on":
			return "Авария: встречная машина на той же полосе (%s)" % v
	return "Авария: машины пересеклись (%s)" % v


func _clear_crash() -> void:
	crash = {}
	if _note != null:
		_note.queue_free()
		_note = null


# ==========================================
# Сейв и загрузка
# ==========================================

func save_data() -> Dictionary:
	return {
		'comp_path': get_script().resource_path,
		'comp_name': get_script().resource_path.get_file().get_basename(),
		'on_road': mode != Mode.OFF_ROAD,
	}


func load_data(data: Dictionary) -> void:
	_saved_on_road = bool(data.get("on_road", false))


## Вызывается из SaveManager после того, как все объекты расставлены. Положение и поворот машина уже получила из сейва вместе с
## сущностью, здесь только находим полосу под ней. false: машина была на полосе, но дороги под ней пока нет (коллизии не готовы),
## SaveManager повторит попытку через кадр. true: села или садиться не нужно
func restore_after_load() -> bool:
	if not _saved_on_road:
		return true
	if not entity.is_inside_tree():
		return false
	var from := entity.global_position + Vector3.UP * LOAD_RAY_UP
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * LOAD_RAY_DOWN, Global.active_layers([ROAD_LAYER]))
	var hit := entity.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return false
	var node: Node = hit.collider
	while node != null and not node is Entity:
		node = node.get_parent()
	var road := node as Entity
	var pc := road.get_comp(C_Path) as C_Path if road != null else null
	if pc == null or pc.path_node == null or pc.curve == null:
		return false
	var local := pc.path_node.to_local(entity.global_position)
	var route := pc.route_at(local)
	var dist := pc.curve_of(route).get_closest_offset(local)
	return snap_to(road, route, dist, -entity.global_basis.z)
