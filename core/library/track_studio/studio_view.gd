extends Node3D

########################
## Track Studio: 3D-вид (ATTN_20, шаг T1)
########################
## Камера, свет, земля и кусок трака. Трак строится тем же TrackMeshBuilder, что и в игре
## (build_mesh, create_sleepers_node, place_sleepers), но без Entity и компонентов:
## стилю нужны только кривая, меш и шпалы. Добавляется в SubViewport со своим World3D.

signal camera_changed

enum Shape { STRAIGHT, ARC, STRAIGHT_ARC }

const ORBIT_SPEED := 0.4
const PITCH_LIMIT := 89.0
const ZOOM_STEP := 1.12
const FOV := 40.0
const GROUND_Y := -0.02   # чуть ниже низа балласта (y = 0), чтобы не мерцало

var shape: int = Shape.STRAIGHT
var length := 23.9
var radius := 36.0
var angle := 30.0

var yaw := 35.0
var pitch := 25.0         # градусы над горизонтом
var dist := 30.0
var pivot := Vector3.ZERO

## Нужен для масштаба сдвига камеры. Ставит контроллер
var viewport: SubViewport

var _cam: Camera3D
var _sun: DirectionalLight3D
var _track: Node3D
var _style: TrackStyle
var _bounds := AABB(Vector3(-4, 0, -12), Vector3(8, 3, 24))
var _drag_button := 0
var _sleepers_visible := true
var _rails_visible := true
var _sleeper_nodes: Array[MultiMeshInstance3D] = []


func _ready() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.56, 0.59, 0.63)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.87, 0.95)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	_sun.light_energy = 1.2
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 120.0
	add_child(_sun)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30.0, 210.0, 0.0)
	fill.light_energy = 0.35
	add_child(fill)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(600.0, 600.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.33, 0.36, 0.31)
	gm.roughness = 1.0
	ground.material_override = gm
	ground.position.y = GROUND_Y
	add_child(ground)

	_track = Node3D.new()
	_track.name = "Track"
	add_child(_track)

	_cam = Camera3D.new()
	_cam.fov = FOV
	_cam.near = 0.05
	_cam.far = 2000.0
	add_child(_cam)
	_cam.current = true
	_update_camera()


# ==========================================
# Стиль и сборка
# ==========================================

func set_style(style: TrackStyle) -> void:
	_style = style
	rebuild()


## Пересобирает трак из текущего стиля и параметров формы
func rebuild() -> void:
	if _track == null:
		return
	for c in _track.get_children():
		_track.remove_child(c)
		c.free()
	_sleeper_nodes.clear()
	if not TrackStyleValidator.can_build(_style):
		return

	var pts := PackedVector3Array()
	for piece in _make_pieces():
		var curve: Curve3D = piece["curve"]
		var xf: Transform3D = piece["xf"]
		var L := curve.get_baked_length()
		if L < 0.01:
			continue
		var holder := Node3D.new()
		holder.transform = xf
		_track.add_child(holder)

		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		var am := TrackMeshBuilder.build_mesh(_style, curve, L, false)
		mi.mesh = am if _rails_visible else _without_rails(am)
		holder.add_child(mi)

		var sl := TrackMeshBuilder.create_sleepers_node(_style)
		TrackMeshBuilder.place_sleepers(sl.multimesh, _style, curve, L)
		sl.visible = _sleepers_visible
		holder.add_child(sl)
		_sleeper_nodes.append(sl)

		var s := 0.0
		while s < L:
			pts.append(xf * curve.sample_baked(s))
			s += 1.0
		pts.append(xf * curve.sample_baked(L))

	if pts.size() > 0:
		var lo := pts[0]
		var hi := pts[0]
		for p in pts:
			lo = lo.min(p)
			hi = hi.max(p)
		lo -= Vector3(2.0, 0.0, 2.0)
		hi += Vector3(2.0, 3.0, 2.0)
		_bounds = AABB(lo, hi - lo)


func set_rails_visible(on: bool) -> void:
	_rails_visible = on
	rebuild()


## Копия меша без поверхности рельсов (style.rail_surface_index()): так видно профиль балласта и шпалы отдельно.
## Рельсы выключены в стиле: поверхности уже нет, меш возвращается как есть
func _without_rails(am: ArrayMesh) -> ArrayMesh:
	var rail_idx := _style.rail_surface_index()
	if rail_idx < 0:
		return am
	var out := ArrayMesh.new()
	for i in am.get_surface_count():
		if i == rail_idx:
			continue
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, am.surface_get_arrays(i))
		out.surface_set_material(out.get_surface_count() - 1, am.surface_get_material(i))
	return out


func set_sleepers_visible(on: bool) -> void:
	_sleepers_visible = on
	for n in _sleeper_nodes:
		n.visible = on


func set_shadows(on: bool) -> void:
	if _sun:
		_sun.shadow_enabled = on


## Куски превью: [{curve, xf}], у каждого своя кривая в своих координатах (вперёд = -Z)
func _make_pieces() -> Array:
	var pieces: Array = []
	match shape:
		Shape.ARC:
			pieces.append({"curve": _arc(radius, angle), "xf": Transform3D.IDENTITY})
		Shape.STRAIGHT_ARC:
			var xf := Transform3D.IDENTITY
			var c1 := _straight(length)
			pieces.append({"curve": c1, "xf": xf})
			xf = xf * _end_transform(c1)
			var c2 := _arc(radius, angle)
			pieces.append({"curve": c2, "xf": xf})
			xf = xf * _end_transform(c2)
			pieces.append({"curve": _straight(length), "xf": xf})
		_:
			pieces.append({"curve": _straight(length), "xf": Transform3D.IDENTITY})
	return pieces


func _straight(len_: float) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(Vector3.ZERO)
	c.add_point(Vector3(0.0, 0.0, -maxf(len_, 0.5)))
	return c


## Дуга налево, начало в нуле, касательная вдоль -Z
func _arc(r: float, deg: float) -> Curve3D:
	var c := Curve3D.new()
	var rr := maxf(r, 1.0)
	var total := deg_to_rad(clampf(deg, 1.0, 180.0))
	var n := clampi(ceili(rr * total / 0.5), 4, 400)
	for k in n + 1:
		var phi := total * k / float(n)
		c.add_point(Vector3(-rr + rr * cos(phi), 0.0, -rr * sin(phi)))
	return c


## Положение и направление конца кривой: следующий кусок ставим сюда
func _end_transform(curve: Curve3D) -> Transform3D:
	var L := curve.get_baked_length()
	var f := TrackMeshBuilder.frame(curve, L, L)
	return Transform3D(Basis.looking_at(f.f, Vector3.UP), f.p)


# ==========================================
# Камера
# ==========================================

## Вписывает весь трак в кадр
func fit() -> void:
	pivot = _bounds.get_center()
	dist = maxf(_bounds.size.length() * 0.9, 4.0)
	_update_camera()


## Вид вблизи начала трака: детали профиля, шпалы, рельсы
func view_close() -> void:
	yaw = 35.0
	pitch = 20.0
	pivot = Vector3(0.0, 0.5, -3.0)
	dist = 7.0
	_update_camera()


func view_iso() -> void:
	yaw = 35.0
	pitch = 25.0
	fit()


func view_top() -> void:
	yaw = 0.0
	pitch = PITCH_LIMIT
	fit()


## Смотрим вдоль пути с начала трака
func view_along() -> void:
	yaw = 0.0
	pitch = 8.0
	pivot = Vector3(0.0, 0.8, -4.0)
	dist = 9.0
	_update_camera()


func _update_camera() -> void:
	if _cam == null or not _cam.is_inside_tree():
		return
	var py := deg_to_rad(pitch)
	var yw := deg_to_rad(yaw)
	var dir := Vector3(sin(yw) * cos(py), sin(py), cos(yw) * cos(py))
	_cam.position = pivot + dir * dist
	_cam.look_at(pivot, Vector3.UP)
	camera_changed.emit()


## ЛКМ - орбита, ПКМ / СКМ / Shift+ЛКМ - сдвиг, колесо - дистанция
func handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					dist = clampf(dist / ZOOM_STEP, 0.5, 800.0)
					_update_camera()
				MOUSE_BUTTON_WHEEL_DOWN:
					dist = clampf(dist * ZOOM_STEP, 0.5, 800.0)
					_update_camera()
				MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
					_drag_button = mb.button_index
		elif mb.button_index == _drag_button:
			_drag_button = 0
	elif event is InputEventMouseMotion and _drag_button != 0:
		var mm := event as InputEventMouseMotion
		var pan := _drag_button != MOUSE_BUTTON_LEFT or Input.is_key_pressed(KEY_SHIFT)
		if pan:
			var vp_h := maxf(float(viewport.size.y), 1.0) if viewport else 1.0
			var per_px := 2.0 * dist * tan(deg_to_rad(FOV) * 0.5) / vp_h
			var b := _cam.global_basis
			pivot += (-b.x * mm.relative.x + b.y * mm.relative.y) * per_px
		else:
			yaw = fmod(yaw - mm.relative.x * ORBIT_SPEED, 360.0)
			pitch = clampf(pitch + mm.relative.y * ORBIT_SPEED, -PITCH_LIMIT, PITCH_LIMIT)
		_update_camera()
