class_name Gimbal extends Node3D

########################
##  Орбитальная камера над столом.
##  Gimbal (этот узел)  : пивот на высоте стола (y = 0) + поворот yaw
##  Elevation           : наклон (pitch)
##  Camera              : дистанция (position.z)
##
##  Ввод меняет ЦЕЛЕВОЕ состояние (t_pivot, t_yaw, t_pitch, t_dist),
##  а реальные ноды плавно догоняют его в _process (не зависит от fps).
##  Ограничения (стол, границы комнаты) применяются к цели, поэтому
##  камера не "скользит" вдоль границы и пивот не уезжает по высоте.
########################

## Follow был прерван игроком (пан или WASD)
signal follow_stopped

const PIVOT_Y := 0.0               # пивот всегда на уровне столешницы
const VEL_SMOOTH := 25.0           # сглаживание измерения скорости для броска

########################
# EXPORT PARAMS
########################
## Свободная камера: наклон до +15 градусов (взгляд снизу) и зум до 1000
const FREE_PITCH_MAX_DEG := 15.0
const FREE_ZOOM_MAX := 1000.0

@export_group("Move")
## Скорость WASD: единиц/сек на каждую единицу дистанции камеры (чем дальше, тем быстрее)
@export_range(0.1, 3.0, 0.05) var wasd_speed := 0.8
## Как быстро WASD набирает скорость
@export_range(1.0, 30.0, 0.5) var wasd_accel := 10.0
## Инерция панорамы после отпускания RMB, секунды затухания. 0 = без инерции
@export_range(0.0, 1.5, 0.05) var pan_inertia := 0.35
## Плавность догоняния цели для позиции и зума (больше = резче)
@export_range(2.0, 40.0, 0.5) var smooth := 14.0
## Прямоугольник (x, z), в котором может быть пивот. Стол 200x100 + запас 40
@export var pivot_limits := Rect2(-140, -90, 280, 180)
@export var limits_enabled := true

@export_group("Zoom")
## Зум к точке под курсором
@export var zoom_to_cursor := true
## Ближняя дистанция до пивота
@export_range(0.5, 50.0, 0.5) var zoom_min := 3.0
## Дальняя дистанция (в комнате ещё режется границами)
@export_range(10.0, 1000.0, 1.0) var zoom_max := 400.0
## Во сколько раз меняется дистанция за один тик колеса
@export_range(1.02, 1.5, 0.01) var zoom_step := 1.12

@export_group("Rotate")
## Радиан на пиксель
@export_range(0.001, 0.02, 0.0001) var rotate_speed := 0.005
## Плавность догоняния поворота
@export_range(2.0, 40.0, 0.5) var rotate_smooth := 18.0
## Инерция вращения после отпускания MMB, секунды. 0 = без инерции
@export_range(0.0, 1.5, 0.05) var rotate_inertia := 0.35
@export var rotate_invert := false
## Самый крутой наклон (вид сверху = -90)
@export_range(-90.0, -10.0, 1.0) var pitch_min_deg := -85.0
## Самый пологий наклон (0 = горизонт, плюс = взгляд снизу вверх). Свободная камера разрешает чуть выше нуля
@export_range(-45.0, 30.0, 1.0) var pitch_max_deg := -5.0

@export_group("Bounds")
## Границы камеры (AABB комнаты). Обычно подаёт CameraBounds.
## position.y = минимальная высота камеры над столом
@export var bounds_enabled := false
@export var bounds := AABB(Vector3(-230.0, 3.0, -180.0), Vector3(460.0, 190.0, 360.0))

@export_group("Helpers")
## Маркер центра (узел %MeshCenter)
@export var center_visible := true


########################
# STATE
########################
@onready var camera: Camera3D = $Elevation/Camera
@onready var elevation: Node3D = $Elevation

# Целевое состояние
var t_pivot := Vector3.ZERO
var t_yaw := 0.0
var t_pitch := deg_to_rad(-45.0)
var t_dist := 20.0

# Скорости для инерции
var pan_vel := Vector3.ZERO     # единиц/сек
var rot_vel := Vector2.ZERO     # рад/сек (x = yaw, y = pitch)

var follow_target: Node3D
var _default_limits := {}
## Свободная камера включена (границы комнаты и пределы сдвига не действуют)
var free_camera := false
## Нужны ли границы комнаты, если свободная камера выключена (их задаёт CameraBounds)
var _bounds_wanted := false

var _grabbing := false
var _rotating := false
var _grab_point := Vector3.ZERO
var _pan_accum := Vector3.ZERO  # сдвиг цели за кадр (для расчёта скорости броска)
var _rot_accum := Vector2.ZERO


########################
# LIFECYCLE
########################
func _ready() -> void:
	var m := get_node_or_null("%MeshCenter") as Node3D
	if m:
		m.visible = center_visible
	# берём стартовое состояние из сцены
	position.y = PIVOT_Y
	t_pivot = position
	t_yaw = rotation.y
	t_pitch = elevation.rotation.x
	t_dist = camera.position.z
	_default_limits = {"limits": limits_enabled, "pitch_max": pitch_max_deg, "zoom_max": zoom_max}
	_bounds_wanted = bounds_enabled
	_clamp_target()


func _unhandled_input(event: InputEvent) -> void:
	if not camera.current:
		return
	if event is InputEventKey:
		_wake()   # WASD опрашивается в _process
	if event.is_action_pressed("rmb"):
		_begin_grab()
	elif event.is_action_pressed("mmb"):
		_begin_rotate()
	elif event.is_action_pressed("mouse_wheel_up"):
		_zoom_tick(-1)
	elif event.is_action_pressed("mouse_wheel_down"):
		_zoom_tick(1)


## Движение мыши при активном драге берём в _input, чтобы драг не залипал над UI
func _input(event: InputEvent) -> void:
	if not (_grabbing or _rotating) or not (event is InputEventMouseMotion):
		return
	if _grabbing:
		_on_pan_motion(event)
	if _rotating:
		_on_rotate_motion(event)


func _process(delta: float) -> void:
	# отпускание кнопки могло прийти над UI
	if _grabbing and not Input.is_action_pressed("rmb"):
		_grabbing = false
	if _rotating and not Input.is_action_pressed("mmb"):
		_rotating = false

	var wasd := Vector2.ZERO
	# Ctrl зажат: это сочетание (Ctrl+S быстрое сохранение и др.), а не движение камеры
	if camera.current and get_window().has_focus() and not Actions.ctrl():
		wasd = Vector2(Input.get_axis("key_a", "key_d"), Input.get_axis("key_w", "key_s")).limit_length(1.0)

	# --- панорама и инерция ---
	if wasd != Vector2.ZERO and follow_target:
		stop_follow()
	if is_instance_valid(follow_target):
		t_pivot.x = follow_target.global_position.x
		t_pivot.z = follow_target.global_position.z
		pan_vel = Vector3.ZERO
	else:
		follow_target = null
		if _grabbing:
			pan_vel = pan_vel.lerp(_pan_accum / maxf(delta, 0.0001), 1.0 - exp(-delta * VEL_SMOOTH))
			_pan_accum = Vector3.ZERO
		elif wasd != Vector2.ZERO:
			var dir := Vector3(wasd.x, 0.0, wasd.y).rotated(Vector3.UP, t_yaw)
			pan_vel = pan_vel.lerp(dir * t_dist * wasd_speed, 1.0 - exp(-delta * wasd_accel))
		elif pan_inertia > 0.0:
			pan_vel *= exp(-delta / pan_inertia)
			if pan_vel.length_squared() < 0.01:
				pan_vel = Vector3.ZERO
		else:
			pan_vel = Vector3.ZERO
		if not _grabbing:
			t_pivot += pan_vel * delta

	# --- вращение и инерция ---
	if _rotating:
		rot_vel = rot_vel.lerp(_rot_accum / maxf(delta, 0.0001), 1.0 - exp(-delta * VEL_SMOOTH))
		_rot_accum = Vector2.ZERO
	elif rotate_inertia > 0.0:
		rot_vel *= exp(-delta / rotate_inertia)
		if rot_vel.length() < 0.002:
			rot_vel = Vector2.ZERO
	else:
		rot_vel = Vector2.ZERO
	if not _rotating:
		t_yaw += rot_vel.x * delta
		t_pitch += rot_vel.y * delta

	# --- ограничения; при упоре гасим скорость по этой оси ---
	var want_pivot := t_pivot
	var want_pitch := t_pitch
	_clamp_target()
	if not is_equal_approx(want_pivot.x, t_pivot.x):
		pan_vel.x = 0.0
	if not is_equal_approx(want_pivot.z, t_pivot.z):
		pan_vel.z = 0.0
	if not is_equal_approx(want_pitch, t_pitch):
		rot_vel.y = 0.0

	# --- плавное догоняние цели ---
	var k := 1.0 - exp(-delta * smooth)
	var kr := 1.0 - exp(-delta * rotate_smooth)
	position = position.lerp(t_pivot, k)
	camera.position.z = lerpf(camera.position.z, t_dist, k)
	rotation.y = lerp_angle(rotation.y, t_yaw, kr)
	elevation.rotation.x = lerpf(elevation.rotation.x, t_pitch, kr)

	# --- сон, когда делать нечего ---
	if _is_idle(wasd):
		_snap()
		set_process(false)


########################
# INPUT HANDLERS
########################
func _begin_grab() -> void:
	stop_follow()
	pan_vel = Vector3.ZERO
	var mouse := get_viewport().get_mouse_position()
	var hit = _ground_under_cursor(mouse)
	if hit == null:
		hit = _ground_under_cursor(get_viewport().get_visible_rect().size * 0.5)
	if hit == null:
		return
	_grab_point = hit
	_pan_accum = Vector3.ZERO
	_grabbing = true
	_wake()


func _begin_rotate() -> void:
	rot_vel = Vector2.ZERO
	_rot_accum = Vector2.ZERO
	_rotating = true
	_wake()


## "Хватаем мир": точка стола под курсором остаётся под курсором
func _on_pan_motion(event: InputEventMouseMotion) -> void:
	var hit = _ground_under_cursor(event.position)
	if hit == null:
		return   # курсор выше горизонта
	var gp: Vector3 = hit
	var d := _grab_point - gp
	d.y = 0.0
	var max_step := t_dist * 2.0   # страховка у горизонта
	if d.length() > max_step:
		d = d.normalized() * max_step
	var before := t_pivot
	t_pivot += d
	_clamp_target()
	var moved := t_pivot - before
	_pan_accum += moved
	if not moved.is_equal_approx(d):
		# упёрлись в границу: переякориваемся, чтобы не "залипало"
		var h2 = _ground_under_cursor(event.position)
		if h2 != null:
			_grab_point = h2
	_wake()


func _on_rotate_motion(event: InputEventMouseMotion) -> void:
	var d := event.relative * rotate_speed
	var before := Vector2(t_yaw, t_pitch)
	t_yaw += (d.x if rotate_invert else -d.x)
	t_pitch -= d.y
	_clamp_target()
	_rot_accum += Vector2(t_yaw, t_pitch) - before
	_wake()


func _zoom_tick(dir: int) -> void:
	var mouse := get_viewport().get_mouse_position()
	var anchor = _ground_under_cursor(mouse) if zoom_to_cursor else null
	t_dist *= pow(zoom_step, dir)
	_clamp_target()
	if anchor != null:
		var after = _ground_under_cursor(mouse)
		if after != null:
			var a: Vector3 = anchor
			var b: Vector3 = after
			t_pivot += Vector3(a.x - b.x, 0.0, a.z - b.z)
			_clamp_target()
	_wake()


########################
# LIMITS
########################
func _clamp_target() -> void:
	t_pitch = clampf(t_pitch, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))
	if limits_enabled:
		t_pivot.x = clampf(t_pivot.x, pivot_limits.position.x, pivot_limits.end.x)
		t_pivot.z = clampf(t_pivot.z, pivot_limits.position.y, pivot_limits.end.y)
	t_pivot.y = PIVOT_Y
	t_dist = clampf(t_dist, zoom_min, zoom_max)
	if not bounds_enabled:
		return
	# 1) не дальше стен/потолка
	t_dist = minf(t_dist, _max_dist_in_bounds(t_pivot, _basis(t_yaw, t_pitch) * Vector3.BACK))
	# 2) не ниже минимальной высоты: при необходимости делаем наклон круче
	var y_min := bounds.position.y
	if t_dist > 0.001 and t_dist * sin(-t_pitch) < y_min:
		t_pitch = minf(t_pitch, -asin(minf(y_min / t_dist, 1.0)))
		t_pitch = maxf(t_pitch, deg_to_rad(pitch_min_deg))
		t_dist = minf(t_dist, _max_dist_in_bounds(t_pivot, _basis(t_yaw, t_pitch) * Vector3.BACK))


## Максимальная дистанция назад от пивота по направлению dir до границы AABB
func _max_dist_in_bounds(pivot: Vector3, dir: Vector3) -> float:
	var d := zoom_max
	for i in 3:
		var c := dir[i]
		if c > 0.0001:
			d = minf(d, (bounds.end[i] - pivot[i]) / c)
		elif c < -0.0001:
			d = minf(d, (bounds.position[i] - pivot[i]) / c)
	return maxf(d, 0.0)


########################
# HELPERS
########################
func _basis(yaw: float, pitch: float) -> Basis:
	return Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)


## Точка плоскости y = PIVOT_Y под курсором, посчитанная для ЦЕЛЕВОЙ камеры
## (а не для текущей, которая отстаёт). null, если луч не попадает в плоскость.
func _ground_under_cursor(screen: Vector2) -> Variant:
	var vp := get_viewport().get_visible_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return null
	var b := _basis(t_yaw, t_pitch)
	var origin := t_pivot + b * Vector3(0.0, 0.0, t_dist)
	var ndc := Vector2(screen.x / vp.x * 2.0 - 1.0, 1.0 - screen.y / vp.y * 2.0)
	var aspect := vp.x / vp.y
	var half := tan(deg_to_rad(camera.fov) * 0.5)
	var hx := half * aspect
	var hy := half
	if camera.keep_aspect == Camera3D.KEEP_WIDTH:
		hx = half
		hy = half / aspect
	var dir := (b * Vector3(ndc.x * hx, ndc.y * hy, -1.0)).normalized()
	if dir.y > -0.02:
		return null
	var t := (PIVOT_Y - origin.y) / dir.y
	return origin + dir * t


func _at_target() -> bool:
	return position.distance_squared_to(t_pivot) < 1e-5 \
		and absf(angle_difference(rotation.y, t_yaw)) < 1e-4 \
		and absf(elevation.rotation.x - t_pitch) < 1e-4 \
		and absf(camera.position.z - t_dist) < 1e-3


func _is_idle(wasd: Vector2) -> bool:
	return not (_grabbing or _rotating) and wasd == Vector2.ZERO \
		and pan_vel == Vector3.ZERO and rot_vel == Vector2.ZERO \
		and not is_instance_valid(follow_target) and _at_target()


func _snap() -> void:
	position = t_pivot
	rotation.y = t_yaw
	elevation.rotation.x = t_pitch
	camera.position.z = t_dist


func _wake() -> void:
	if not is_processing():
		set_process(true)


########################
# PUBLIC API
########################
## Ограничения камеры внутри комнаты (вызывает CameraBounds)
func set_bounds(aabb: AABB, enabled := true) -> void:
	bounds = aabb
	_bounds_wanted = enabled
	bounds_enabled = enabled and not free_camera   # свободная камера границы не соблюдает
	_clamp_target()
	_wake()


## XX claude-table T3. Новые границы без смены включённости (высота стола сдвинула потолок)
func update_bounds(aabb: AABB) -> void:
	bounds = aabb
	_clamp_target()
	_wake()


func set_bounds_enabled(enabled: bool) -> void:
	_bounds_wanted = enabled
	bounds_enabled = enabled and not free_camera
	_clamp_target()
	_wake()


## Свободная камера (fast_debug и кнопка в панели отладки F3): без пределов сдвига и границ комнаты,
## дальний зум, взгляд чуть снизу. off возвращает значения, с которыми Gimbal стартовал, и границы комнаты
func set_free_camera(on: bool) -> void:
	if _default_limits.is_empty():
		_default_limits = {"limits": limits_enabled, "pitch_max": pitch_max_deg, "zoom_max": zoom_max}
	free_camera = on
	bounds_enabled = _bounds_wanted and not on
	if on:
		limits_enabled = false
		pitch_max_deg = FREE_PITCH_MAX_DEG
		zoom_max = FREE_ZOOM_MAX
	else:
		limits_enabled = _default_limits.limits
		pitch_max_deg = _default_limits.pitch_max
		zoom_max = _default_limits.zoom_max
	_clamp_target()
	_wake()


## Камера едет за узлом (например, из C_CameraTarget). Пан или WASD прерывают follow
func follow(node: Node3D) -> void:
	follow_target = node
	_wake()


func stop_follow() -> void:
	if follow_target:
		follow_target = null
		follow_stopped.emit()


## Выставить вид. snap = true мгновенно, иначе плавный переезд (закладки, orbit, фоторежим)
func set_view(pivot: Vector3, yaw: float, pitch: float, dist: float, snap := false) -> void:
	stop_follow()
	pan_vel = Vector3.ZERO
	rot_vel = Vector2.ZERO
	t_pivot = pivot
	t_yaw = yaw
	t_pitch = pitch
	t_dist = dist
	_clamp_target()
	if snap:
		_snap()
	_wake()


func get_view() -> Dictionary:
	return {"pivot": t_pivot, "yaw": t_yaw, "pitch": t_pitch, "dist": t_dist}


## Данные для сейва вызывает SaveLoad Manager
func save_global_state() -> Dictionary:
	return get_view()


## Данные для лоада вызывает SaveLoad Manager. Понимает и старый формат (transform/elevation/camera)
func load_global_state(data: Dictionary) -> void:
	if data.has("pivot"):
		set_view(data.pivot, data.yaw, data.pitch, data.dist, true)
	elif data.has("transform"):
		var _tr: Transform3D = data.transform
		var pitch := t_pitch
		var dist := t_dist
		if data.has("elevation"):
			pitch = (data.elevation as Transform3D).basis.get_euler().x
		if data.has("camera"):
			dist = (data.camera as Transform3D).origin.z
		set_view(_tr.origin, _tr.basis.get_euler().y, pitch, dist, true)
