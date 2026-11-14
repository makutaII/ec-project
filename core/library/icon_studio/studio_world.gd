extends Node3D

########################
## Icon Studio: мир студии (ATTN_18 §18.3.2, шаги I1-I4)
########################
## Живёт внутри SubViewport. Главный вид и вид предпросмотра делят один World3D (создаёт icon_studio.gd),
## у каждого своя камера, положение и параметры камер синхронизируются.
## Держит объект (Entity из фабрики или просто сцена), считает его AABB, ведёт орбитальную камеру,
## свет (следует за камерой), фон, пол-тень и применяет пресет качества к обоим видам.

signal camera_changed

const SOURCE_ENTITY := 0   ## объект собирается EntityFactory, как в игре
const SOURCE_SCENE := 1    ## запасной путь: только PackedScene из визуал-компонента (ATTN_18 R1)

const ORBIT_SPEED := 0.4        # градусов на пиксель
const ZOOM_STEP := 1.1
const PITCH_LIMIT := 89.0
const SLOT_TIME := 0.2
const GROUND_SCALE := 3000.0
const FLEX_LENGTH := 60.0
const CATCHER_STRENGTH := 0.7   # непрозрачность тени на «ловце»

const CATCHER_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, specular_disabled;
uniform float strength : hint_range(0.0, 1.0) = 0.7;
// Пол чёрный и прозрачный. Прозрачность появляется только там, где свет закрыт тенью:
// ATTENUATION в light() уже учитывает тень источника, у источников без тени он равен 1.
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.002;
}
void light() {
	ALPHA = max(ALPHA, (1.0 - ATTENUATION) * strength);
}
"""

var yaw := 35.0
var pitch := -25.0              ## отрицательный = смотрим сверху
var fov := 30.0
var ortho := false
var zoom := 1.0
var pivot_offset := Vector3.ZERO
var fit_margin := 0.08

var subject: Node3D
var bounds := AABB(Vector3(-5.0, 0.0, -5.0), Vector3(10.0, 10.0, 10.0))

var _template: Resource          # icon_template.gd
var _quality: QualityPreset
var _views: Array[SubViewport] = []
var _factory: EntityFactory
var _subject_root: Node3D
var _cam: Camera3D
## Камера вида (Library: попадание кисти)  # XX claude-library C2.1
var camera: Camera3D:
	get:
		return _cam
var _pcam: Camera3D              # камера предпросмотра (в другом SubViewport)
var _key: DirectionalLight3D
var _fill: DirectionalLight3D
var _rim: DirectionalLight3D
var _env: Environment
var _sky: Sky
var _sky_mat: ProceduralSkyMaterial
var _ground: MeshInstance3D
var _mat_ground: StandardMaterial3D
var _mat_catcher: ShaderMaterial          # «ловец тени», способ 0: шейдер с light()
var _mat_catcher_opacity: StandardMaterial3D   # способ 1: shadow_to_opacity
var _tween: Tween
var _token := 0                 # номер последнего запроса: устаревшие ответы отбрасываем
var _drag_button := 0
var _fit_dist := 30.0
var _fit_size := 30.0
var _frozen_basis := Basis.IDENTITY
var _was_follow := true
var _p_contact_env: StringName = &""
var _p_contact_key: StringName = &""


func _ready() -> void:
	_factory = EntityFactory.new()
	add_child(_factory)

	_subject_root = Node3D.new()
	_subject_root.name = "Subject"
	add_child(_subject_root)

	var we := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.56, 0.59, 0.63)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.85, 0.87, 0.95)
	_env.ambient_light_energy = 0.55
	_sky_mat = ProceduralSkyMaterial.new()
	_sky = Sky.new()
	_sky.sky_material = _sky_mat
	_env.sky = _sky
	we.environment = _env
	add_child(we)
	_p_contact_env = _find_bool(_env, ["contact"])

	_key = _make_light("Key", true)
	_fill = _make_light("Fill", false)
	_rim = _make_light("Rim", false)
	_p_contact_key = _find_bool(_key, ["contact_shadows_allow", "contact"])

	_mat_ground = StandardMaterial3D.new()
	_mat_ground.roughness = 1.0
	_mat_catcher = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = CATCHER_SHADER
	_mat_catcher.shader = sh
	_mat_catcher.set_shader_parameter("strength", CATCHER_STRENGTH)
	_mat_catcher_opacity = StandardMaterial3D.new()
	_mat_catcher_opacity.albedo_color = Color(0.0, 0.0, 0.0, CATCHER_STRENGTH)
	_mat_catcher_opacity.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_catcher_opacity.shadow_to_opacity = true
	_mat_catcher_opacity.roughness = 1.0
	_mat_catcher_opacity.metallic_specular = 0.0
	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	_ground.mesh = plane
	_ground.scale = Vector3(GROUND_SCALE, 1.0, GROUND_SCALE)
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ground.visible = false
	add_child(_ground)

	_cam = Camera3D.new()
	_cam.name = "Camera"
	_cam.current = true
	add_child(_cam)
	_update_camera()


func _make_light(light_name: String, shadow: bool) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = light_name
	l.shadow_enabled = shadow
	add_child(l)
	return l


## Ищет bool-свойство по подстроке имени (в 4.8 beta имена contact shadows уточняются, как и в GFX)
func _find_bool(obj: Object, words: Array) -> StringName:
	for p in obj.get_property_list():
		if int(p.type) != TYPE_BOOL:
			continue
		var n := String(p.name).to_lower()
		for w in words:
			if n.contains(String(w)):
				return StringName(p.name)
	return &""


## Виды (главный и предпросмотра), к которым применяются качество и фон, и камера предпросмотра
func register_views(views: Array[SubViewport], preview_cam: Camera3D) -> void:
	_views = views
	_pcam = preview_cam
	_update_camera()


# ==========================================
# ШАБЛОН И КАЧЕСТВО
# ==========================================

func apply_template(t: Resource, q: QualityPreset) -> void:
	_template = t
	_quality = q
	if _env == null:
		return
	fit_margin = t.fit_margin

	# --- окружение и коррекция ---
	_env.tonemap_mode = t.tonemap as Environment.ToneMapper
	_env.tonemap_exposure = t.exposure
	_env.adjustment_enabled = true
	_env.adjustment_brightness = t.brightness
	_env.adjustment_contrast = t.contrast
	_env.adjustment_saturation = t.saturation
	match int(t.bg_mode):
		0:
			_env.background_mode = Environment.BG_CLEAR_COLOR
		1:
			_env.background_mode = Environment.BG_COLOR
			_env.background_color = t.bg_color
		_:
			_env.background_mode = Environment.BG_SKY
			_sky_mat.sky_top_color = t.sky_top
			_sky_mat.sky_horizon_color = t.sky_horizon
			_sky_mat.ground_horizon_color = t.ground_color
			_sky_mat.ground_bottom_color = t.ground_color
	_mat_ground.albedo_color = t.ground_color

	# --- свет ---
	_key.light_energy = t.key_energy
	_fill.light_energy = t.fill_energy
	_rim.light_energy = t.rim_energy
	for l in [_key, _fill, _rim]:
		(l as DirectionalLight3D).light_color = t.light_color
	_key.shadow_enabled = t.shadow
	_key.shadow_blur = t.shadow_softness
	if _was_follow and not t.light_follow_camera:
		_frozen_basis = _cam.global_basis
	_was_follow = t.light_follow_camera

	# --- качество ---
	if q != null:
		for v in _views:
			v.msaa_3d = q.msaa as Viewport.MSAA
			v.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
			v.positional_shadow_atlas_size = q.positional_shadow_atlas
		RenderingServer.directional_shadow_atlas_set_size(q.dir_shadow_atlas, true)
		RenderingServer.directional_soft_shadow_filter_set_quality(q.soft_shadow_quality as RenderingServer.ShadowQuality)
		RenderingServer.positional_soft_shadow_filter_set_quality(q.soft_shadow_quality as RenderingServer.ShadowQuality)
		RenderingServer.environment_set_ssao_quality(q.ssao_quality as RenderingServer.EnvironmentSSAOQuality,
				q.ssao_half_size, 0.5, 2, 50.0, 300.0)
		_env.ssao_enabled = q.ssao
		_env.ssao_radius = 1.5
		_env.ssao_intensity = 2.5
		_env.ssao_power = 1.6
		_env.ssil_enabled = q.ssil
		if _p_contact_env != &"":
			_env.set(_p_contact_env, q.contact_shadows)
		if _p_contact_key != &"":
			_key.set(_p_contact_key, q.contact_shadows)
		match q.dir_shadow_splits:
			4:
				_key.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			2:
				_key.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			_:
				_key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	for v in _views:
		v.transparent_bg = int(t.bg_mode) == 0

	_update_ground()
	_compute_fit()
	_update_camera()
	camera_changed.emit()


## Пол: опорная поверхность (режим «горизонт») или «ловец тени» (в остальных режимах, если тень включена)
func _update_ground() -> void:
	if _template == null:
		return
	var horizon := int(_template.bg_mode) == 2
	_ground.visible = horizon or bool(_template.shadow)
	if horizon:
		_ground.material_override = _mat_ground
	elif int(_template.catcher_mode) == 1:
		_ground.material_override = _mat_catcher_opacity
	else:
		_ground.material_override = _mat_catcher
	var c := bounds.get_center()
	_ground.position = Vector3(c.x, bounds.position.y - 0.01, c.z)


# ==========================================
# ОБЪЕКТ
# ==========================================

## Создаёт объект и ставит в мир. Возвращает словарь:
## ok, via, name, error, meshes, aabb, warn, stale (true: пока грузили, пришёл новый запрос)
func set_subject(setting: EntitySetting, source: int, settle_frames: int) -> Dictionary:
	_token += 1
	var token := _token
	_clear_subject()
	var info := {"ok": false, "via": "", "name": setting.name, "error": "", "meshes": 0,
		"aabb": AABB(), "warn": "", "stale": false}

	var node: Node3D = null
	if source == SOURCE_ENTITY:
		info.via = "entity"
		node = _factory.create_from_setting(setting)
	else:
		info.via = "scene"
		node = _scene_of(setting)
	if node == null:
		info.error = "не удалось создать объект (нет подходящего компонента или сцены)"
		return info

	# Тела не должны падать, пока объект «оживает» в первые кадры
	for body in _find_all(node, "RigidBody3D"):
		(body as RigidBody3D).freeze = true
	_subject_root.add_child(node)
	subject = node

	# Несколько кадров обработки: части компонентов строят меши отложенно. Потом всё замораживаем
	for i in settle_frames:
		await get_tree().process_frame
		if token != _token:
			info.stale = true
			return info
	await get_tree().process_frame
	if token != _token or not is_instance_valid(node):
		info.stale = true
		return info
	node.process_mode = Node.PROCESS_MODE_DISABLED
	_after_measure(info, node)
	return info


## Замерить показанный объект заново после перестройки на месте (здание из генератора) и обновить границы.
## refit: заодно вписать камеру (зум и сдвиг сброшены)
func remeasure(refit := false) -> void:
	if not is_instance_valid(subject):
		return
	var stat := _measure(subject)
	if int(stat.meshes) == 0:
		return
	bounds = stat.aabb
	_update_ground()
	if refit:
		fit()
	else:
		_compute_fit()


func _after_measure(info: Dictionary, node: Node3D) -> void:
	var stat := _measure(node)
	info.meshes = stat.meshes
	if stat.meshes == 0:
		info.warn = "нет видимых мешей (меш мог не построиться, попробуйте больше кадров «settle» или источник «Сцена»)"
	else:
		bounds = stat.aabb
		info.aabb = stat.aabb
	info.ok = true
	_update_ground()
	_compute_fit()
	_update_camera()


func _clear_subject() -> void:
	if is_instance_valid(subject):
		subject.process_mode = Node.PROCESS_MODE_DISABLED
		if subject.has_method("kill_me"):
			subject.kill_me()
		else:
			subject.queue_free()
		_subject_root.remove_child(subject)   # имя и группы освобождаются сразу, не ждём конца кадра
	subject = null


## Убрать объект из мира (Library закрывается: kill_me снимает регистрацию в PGM)  # XX claude-library L1
func clear_subject() -> void:
	_token += 1   # идущий set_subject увидит, что запрос устарел
	_clear_subject()


## Запасной путь: сцена из визуал-компонента (trackvisual) или из object_config (вагон, дом)
func _scene_of(setting: EntitySetting) -> Node3D:
	for cs in setting.components:
		var sc: Variant = cs.get("scene")
		if sc is PackedScene:
			return (sc as PackedScene).instantiate() as Node3D
		var ident := cs as IdentitySetting
		if ident != null and ident.object_config != null:
			var sc2: Variant = ident.object_config.get("scene")
			if sc2 is PackedScene:
				return (sc2 as PackedScene).instantiate() as Node3D
	return null


func _find_all(root: Node, type_name: String) -> Array[Node]:
	var res: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.is_class(type_name):
			res.append(n)
	return res


## Суммарный AABB видимой геометрии. Подписи (Label3D) и невидимые узлы не считаем
func _measure(root: Node) -> Dictionary:
	var total := AABB()
	var has := false
	var count := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is GeometryInstance3D) or n is Label3D:
			continue
		var g := n as GeometryInstance3D
		if not g.is_visible_in_tree():
			continue
		var a := g.get_aabb()
		if a.size == Vector3.ZERO:
			continue
		var wa: AABB = g.global_transform * a
		total = wa if not has else total.merge(wa)
		has = true
		count += 1
	return {"aabb": total, "meshes": count}


# ==========================================
# FLEX: ГОТОВЫЕ ФОРМЫ (ATTN_18 I2, «змейка»)
# ==========================================

func has_flex() -> bool:
	var ent := subject as Entity
	return ent != null and ent.get_comp(C_FlexShape) != null


## preset: &"straight", &"arc", &"snake". Форма задаётся состоянием C_FlexShape без BuildTool.
## Координаты в плоскости начала: x вправо, y вперёд, начало в нуле
func apply_flex_preset(preset: StringName) -> bool:
	var ent := subject as Entity
	if ent == null or ent.get_comp(C_FlexShape) == null:
		return false
	var token := _token
	var st := {"relaxed": true, "end_levels": 0, "snapped_end": false, "start_slope": 0.0}
	match preset:
		&"arc":
			st.target = Vector2(FLEX_LENGTH * 0.45, FLEX_LENGTH * 0.75)
			st.bends = []
		&"snake":
			st.target = Vector2(0.0, FLEX_LENGTH)
			st.bends = [Vector2(FLEX_LENGTH * 0.18, FLEX_LENGTH * 0.33), Vector2(-FLEX_LENGTH * 0.18, FLEX_LENGTH * 0.66)]
		_:
			st.target = Vector2(0.0, FLEX_LENGTH)
			st.bends = []
	ent.process_mode = Node.PROCESS_MODE_INHERIT
	ent.send_event("on_receive_flex_state", {"flex_state": st})
	for i in 6:
		await get_tree().process_frame
	if token != _token or not is_instance_valid(ent):
		return false
	ent.process_mode = Node.PROCESS_MODE_DISABLED
	_after_measure({}, ent)
	fit()
	return true


# ==========================================
# КАМЕРА
# ==========================================

func get_camera_state() -> Dictionary:
	return {"yaw": yaw, "pitch": pitch, "fov": fov, "ortho": ortho}


func set_camera_state(d: Dictionary) -> void:
	yaw = float(d.get("yaw", yaw))
	pitch = clampf(float(d.get("pitch", pitch)), -PITCH_LIMIT, PITCH_LIMIT)
	fov = clampf(float(d.get("fov", fov)), 5.0, 90.0)
	ortho = bool(d.get("ortho", ortho))
	_compute_fit()
	_update_camera()


func set_ortho(on: bool) -> void:
	ortho = on
	_update_camera()
	camera_changed.emit()


func set_fov(v: float) -> void:
	fov = clampf(v, 5.0, 90.0)
	_compute_fit()
	_update_camera()
	camera_changed.emit()


func set_view(new_yaw: float, new_pitch: float) -> void:
	yaw = new_yaw
	pitch = clampf(new_pitch, -PITCH_LIMIT, PITCH_LIMIT)
	_update_camera()
	camera_changed.emit()


## Слот ракурса. Сдвиг хранится в долях диагонали AABB, поэтому слот подходит другому объекту
func capture_slot() -> Dictionary:
	var diag := maxf(bounds.size.length(), 0.01)
	return {"yaw": yaw, "pitch": pitch, "ortho": ortho, "fov": fov, "zoom": zoom, "pivot": pivot_offset / diag}


func go_slot(s: Dictionary, smooth: bool) -> void:
	var diag := maxf(bounds.size.length(), 0.01)
	var to_yaw := float(s.get("yaw", yaw))
	var to_pitch := float(s.get("pitch", pitch))
	var to_zoom := float(s.get("zoom", zoom))
	var to_pivot: Vector3 = (s.get("pivot", Vector3.ZERO) as Vector3) * diag
	ortho = bool(s.get("ortho", ortho))
	fov = clampf(float(s.get("fov", fov)), 5.0, 90.0)
	_compute_fit()
	if _tween:
		_tween.kill()
	if not smooth:
		yaw = to_yaw
		pitch = to_pitch
		zoom = to_zoom
		pivot_offset = to_pivot
		_update_camera()
		camera_changed.emit()
		return
	var from_yaw := yaw
	var from_pitch := pitch
	var from_zoom := zoom
	var from_pivot := pivot_offset
	var d_yaw := wrapf(to_yaw - from_yaw, -180.0, 180.0)
	var step := func(t: float) -> void:
		yaw = from_yaw + d_yaw * t
		pitch = lerpf(from_pitch, to_pitch, t)
		zoom = lerpf(from_zoom, to_zoom, t)
		pivot_offset = from_pivot.lerp(to_pivot, t)
		_update_camera()
		camera_changed.emit()
	_tween = create_tween()
	_tween.tween_method(step, 0.0, 1.0, SLOT_TIME)


func _frame_aspect() -> float:
	if _template != null:
		var sz: Vector2i = _template.output_size
		return float(maxi(sz.x, 1)) / float(maxi(sz.y, 1))
	return 1.0


## Дистанция и размер орто по описанной сфере AABB. Аспект кадра = аспект результата
func _compute_fit() -> void:
	var aspect := _frame_aspect()
	var radius := maxf(bounds.size.length() * 0.5, 0.01)
	var narrow := minf(1.0, aspect)   # в узком кадре ограничивает ширина
	var half := atan(tan(deg_to_rad(fov) * 0.5) * narrow)
	_fit_dist = radius / sin(half) * (1.0 + fit_margin)
	_fit_size = radius * 2.0 / narrow * (1.0 + fit_margin)


## Вписать объект в кадр: зум и сдвиг сброшены
func fit() -> void:
	_compute_fit()
	zoom = 1.0
	pivot_offset = Vector3.ZERO
	_update_camera()
	camera_changed.emit()


func handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					zoom = clampf(zoom / ZOOM_STEP, 0.05, 20.0)
					_update_camera()
					camera_changed.emit()
				MOUSE_BUTTON_WHEEL_DOWN:
					zoom = clampf(zoom * ZOOM_STEP, 0.05, 20.0)
					_update_camera()
					camera_changed.emit()
				MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
					_drag_button = mb.button_index
		elif mb.button_index == _drag_button:
			_drag_button = 0
	elif event is InputEventMouseMotion and _drag_button != 0:
		var mm := event as InputEventMouseMotion
		var pan := _drag_button != MOUSE_BUTTON_LEFT or Input.is_key_pressed(KEY_SHIFT)
		if pan:
			_pan(mm.relative)
		else:
			yaw = fmod(yaw - mm.relative.x * ORBIT_SPEED, 360.0)
			pitch = clampf(pitch - mm.relative.y * ORBIT_SPEED, -PITCH_LIMIT, PITCH_LIMIT)
		_update_camera()
		camera_changed.emit()


func _pan(rel: Vector2) -> void:
	var vp_h := 1.0
	if not _views.is_empty():
		vp_h = maxf(float(_views[0].size.y), 1.0)
	var per_px: float
	if ortho:
		per_px = _fit_size * zoom / vp_h
	else:
		per_px = 2.0 * _fit_dist * zoom * tan(deg_to_rad(fov) * 0.5) / vp_h
	var b := _cam.global_basis
	pivot_offset += (-b.x * rel.x + b.y * rel.y) * per_px


func _update_camera() -> void:
	if _cam == null:
		return
	var up := deg_to_rad(-pitch)
	var yw := deg_to_rad(yaw)
	var dir := Vector3(sin(yw) * cos(up), sin(up), cos(yw) * cos(up))
	var pivot := bounds.get_center() + pivot_offset
	var radius := maxf(bounds.size.length() * 0.5, 0.01)
	var dist := _fit_dist if ortho else _fit_dist * zoom
	var horizon := _template != null and int(_template.bg_mode) == 2
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL if ortho else Camera3D.PROJECTION_PERSPECTIVE
	_cam.fov = fov
	_cam.size = _fit_size * zoom
	_cam.near = maxf(0.05, dist - radius * 3.0)
	_cam.far = dist + radius * 3.0 + 100.0 + (GROUND_SCALE if horizon else 0.0)
	_cam.global_position = pivot + dir * dist
	_cam.look_at(pivot, Vector3.UP)

	# Свет относительно камеры (или зафиксирован, если «следует за камерой» выключено)
	var t := _template
	var base := _cam.global_basis
	if t != null and not t.light_follow_camera:
		base = _frozen_basis
	var kp := -35.0
	var ky := 40.0
	var fp := -10.0
	var fy := -55.0
	var rp := -20.0
	var ry := 160.0
	if t != null:
		kp = t.key_pitch
		ky = t.key_yaw
		fp = t.fill_pitch
		fy = t.fill_yaw
		rp = t.rim_pitch
		ry = t.rim_yaw
	_aim(_key, base, kp, ky)
	_aim(_fill, base, fp, fy)
	_aim(_rim, base, rp, ry)
	_key.directional_shadow_max_distance = dist + radius * 3.0

	# Камера предпросмотра повторяет главную
	if _pcam != null and _pcam.is_inside_tree():
		_pcam.projection = _cam.projection
		_pcam.fov = _cam.fov
		_pcam.size = _cam.size
		_pcam.near = _cam.near
		_pcam.far = _cam.far
		_pcam.global_transform = _cam.global_transform


## Кадр для сохранения: отдельный SubViewport в том же мире, размер = результат × supersample.
## Главная камера и свет не трогаются. Возвращает null, если мир не готов
func render_image(out_size: Vector2i, supersample: int) -> Image:
	if _views.is_empty() or _cam == null or not is_inside_tree():
		return null
	var ss := maxi(1, supersample)
	while ss > 1 and maxi(out_size.x, out_size.y) * ss > 8192:
		ss -= 1
	var src := _views[0]
	var vp := SubViewport.new()
	vp.world_3d = src.world_3d
	vp.size = out_size * ss
	vp.transparent_bg = src.transparent_bg
	vp.msaa_3d = src.msaa_3d
	vp.screen_space_aa = src.screen_space_aa
	vp.positional_shadow_atlas_size = src.positional_shadow_atlas_size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var cam := Camera3D.new()
	vp.add_child(cam)
	add_child(vp)
	cam.projection = _cam.projection
	cam.fov = _cam.fov
	cam.size = _cam.size
	cam.near = _cam.near
	cam.far = _cam.far
	cam.global_transform = _cam.global_transform
	cam.current = true
	# два кадра: первый - установка размера и камеры, второй - готовая картинка
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	return img


## Поворот света относительно базиса (градусы). -Z света = направление луча
func _aim(l: DirectionalLight3D, base: Basis, pitch_deg: float, yaw_deg: float) -> void:
	l.global_basis = base * Basis.from_euler(Vector3(deg_to_rad(pitch_deg), deg_to_rad(yaw_deg), 0.0))
