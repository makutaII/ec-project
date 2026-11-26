class_name C_RoadVehicle extends Component

###########################
## Состояние и движение машины по дороге (ATTN_28 §28.4, CS2)
###########################
## Положение это состояние ходьбы {track, route, dist, dir} (PathWalker, как у частей состава). Машина едет по оси полосы с
## постоянной скоростью max_speed из паспорта CarConfig (скорость по радиусу, разгон и торможение это CS3).
## Положение интегрируется каждый физический кадр, решения (конец дороги, потеря полосы, поехать снова) идут в тике CSM, 20 Гц.
## Конец дороги без продолжения: машина стоит (Р6), разворота и исчезновения нет. Когда дорогу достроили, она сама поедет дальше.
## Вагоны машину не видят (слой cars), машина вагоны тоже: она только ходит по сплайну и не имеет физики.

## Слой пути, по которому ходит машина
const ROAD_LAYER := &"roads"
## Скорость, если в паспорте нет CarConfig, ю/с
const DEFAULT_SPEED := 8.0
## Насколько вперёд заглядываем из остановки, ю: есть ли дальше дорога
const RESUME_PROBE := 0.5
## Запас луча вниз при поиске дороги под машиной после загрузки, ю
const LOAD_RAY_UP := 1.0
const LOAD_RAY_DOWN := 2.0

enum Mode { OFF_ROAD, DRIVING, HALTED }   # не на полосе, едет, стоит на конце дороги

var mode := Mode.OFF_ROAD
## Состояние ходьбы {track, route, dist, dir}. Пусто, когда машина не на полосе
var state: Dictionary = {}
var speed := 0.0

var _saved_on_road := false


func on_entity_ready() -> void:
	CSM.register(self)


func _exit_tree() -> void:
	if is_instance_valid(CSM):
		CSM.unregister(self)


## Посадка на полосу. world_dir: в какую сторону смотрит машина, по нему выбирается направление ходьбы. false: полосы нет
func snap_to(track: Entity, route: int, dist: float, world_dir: Vector3) -> bool:
	var st := PathWalker.from_snap(track, route, dist, world_dir)
	if st.is_empty():
		return false
	state = st
	mode = Mode.DRIVING
	speed = _max_speed()
	_apply_pose()
	return true


## ⚡ Драг посадил машину на полосу: {track, route, offset, world_dir}
func on_car_snapped(data: Dictionary) -> void:
	snap_to(data.track, int(data.get("route", 0)), float(data.offset), data.world_dir)


## ⚡ Машину сняли с полосы (взяли в драг или бросили мимо дороги)
func on_car_unsnapped(_data: Dictionary) -> void:
	_lose_road()


func _physics_process(delta: float) -> void:
	if mode != Mode.DRIVING:
		return
	if entity.has_comp(C_Drag) or entity.has_comp(C_Ghost):
		return
	if not _road_valid():
		_lose_road()
		return
	speed = _max_speed()
	var nxt := PathWalker.advance(state, speed * delta, ROAD_LAYER)
	if nxt.is_empty():
		_halt()
		return
	state = nxt
	_apply_pose()


## Решения 20 Гц (вызывает CSM)
func decide(_dt: float) -> void:
	match mode:
		Mode.DRIVING:
			if not _road_valid():
				_lose_road()
		Mode.HALTED:
			if not _road_valid():
				_lose_road()
			elif not PathWalker.advance(state, RESUME_PROBE, ROAD_LAYER).is_empty():
				mode = Mode.DRIVING   # дорогу достроили
				speed = _max_speed()


func _max_speed() -> float:
	var cfg := CarConfig.from_entity(entity)
	return cfg.max_speed if cfg != null else DEFAULT_SPEED


func _road_valid() -> bool:
	return state.has("track") and is_instance_valid(state.track) and not (state.track as Node).is_queued_for_deletion()


func _lose_road() -> void:
	state = {}
	mode = Mode.OFF_ROAD
	speed = 0.0


## Встали на самом краю маршрута
func _halt() -> void:
	var pc := (state.track as Entity).get_comp(C_Path) as C_Path
	if pc != null and pc.curve_of(state.route) != null:
		state.dist = pc.curve_of(state.route).get_baked_length() if float(state.dir) > 0.0 else 0.0
		_apply_pose()
	mode = Mode.HALTED
	speed = 0.0


func _apply_pose() -> void:
	var heading := PathWalker.heading(state)
	var basis := entity.global_basis
	if absf(heading.dot(Vector3.UP)) < 0.99:
		basis = Basis.looking_at(heading, Vector3.UP)
	entity.global_transform = Transform3D(basis, PathWalker.body_point(state))


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
