class_name C_SwitchVisual extends C_TrackVisual

# XX claude-switch (новый файл)
###################################
## Визуал стрелки. Сцены нет: все ноды строятся в коде (как C_FlexVisual) по TrackStyle.
###################################
## Для КАЖДОГО маршрута C_Path строит свой свип-меш (балласт + рельсы) и шпалы через TrackMeshBuilder.
## Физически стрелка всегда целая: коллизии (Ballast Area3D, HeadStaticBody3D) покрывают оба маршрута,
## поэтому тележка, сойдя на стрелку, всегда находит именно эту сущность. Какой путь активен, решает
## C_Path (вагон видит только активный), к визуалу это не относится.
## Рычаг (ground throw): стойка + стрелка-рычаг у носка с обратной от ответвления стороны.
## Area3D рычага на слое handles, мета switch_lever: SelectTool шлет в него on_lever_pressed.
## Положение рычага и цвет следуют за активным маршрутом (on_route_activated).
## Порядок в .tres: Identity, SwitchVisual, ... Pivot, ... Blockable, Path, SwitchShape, Socket, PowerTrack, ..., Switch.

const LEVER_TILT := 0.6          # рад, наклон рычага
const LEVER_HEIGHT := 1.4
const COL_LEVER_OK := Color(0.25, 0.75, 0.30)
const COL_LEVER_DIV := Color(0.95, 0.65, 0.10)
const FLASH_HOLD := 1.5          # с, подсветка активного пути держится
const FLASH_FADE := 1.0          # с, нарастание и затухание (одинаковая скорость)
const FLASH_ALPHA := 0.65        # итоговая непрозрачность ленты
const FLASH_LIFT := 0.04         # ю, лента над поверхностью катания
const FLASH_STEP := 1.0          # ю, шаг ленты вдоль кривой

## Задает SwitchVisualSettings. null = TrackStyle по умолчанию
var style: TrackStyle
## Рычаг стрелки. Выключен у траков без переключения (упор C_BufferStop использует этот же визуал)
var with_lever := true

var ballast: Area3D
var head: StaticBody3D
var lever_area: Area3D

var _meshes: Array[MeshInstance3D] = []
var _sleepers: Array[MultiMeshInstance3D] = []
var _ballast_shapes: Array[CollisionShape3D] = []
var _head_shapes: Array[CollisionShape3D] = []
var _lever_pivot: Node3D
var _lever_mat: StandardMaterial3D
var _lever_dir := 1.0    # сторона, куда рычаг ложится в положении "ответвление" (x знак)
var _lever_on := true
var _flash: MeshInstance3D
var _flash_tween: Tween


## Базовый C_Visual.on_added инстанцирует сцену; у стрелки сцены нет
func on_added() -> void:
	if style == null:
		style = TrackStyle.new()
	rail_surface_index = style.rail_surface_index()
	instance = _build_instance()
	entity.add_child(instance)
	parts = PartRegistry.build(instance)
	_collect_meshes()
	_on_instance_ready()   # C_TrackVisual: area_nodes, static_node


## C_Path уже в Entity, но его on_entity_ready еще впереди: отдаем высоту поверхности катания
func on_entity_ready() -> void:
	var path := get_comp(C_Path) as C_Path
	if path:
		path.set_head_height(style.head_height())


func _set_overlay(mat: Material) -> void:
	super(mat)
	for s in _sleepers:
		s.material_overlay = mat


func on_component_added(type: Script) -> void:
	super(type)
	if type == C_Ghost:
		_set_lever_enabled(false)   # призрак не принимает клики по рычагу


# ==========================================
# События
# ==========================================

## C_SwitchShape отдал маршруты в C_Path: строим меш и коллизии
func on_routes_changed(_d: Dictionary) -> void:
	_rebuild()


func on_route_activated(data: Dictionary) -> void:
	_update_lever(int(data.get("route", 0)))
	# Слой электрики: окраска веток (E1) зависит от активного маршрута, а PGM обновляет вид только у траков, чей контур
	# сменился (у самой стрелки контур тот же). Без этого вид менялся только при наведении мыши
	update_visual()


## Режим питания или тип крестовины сменили в игре (вкладка «Стрелка»): перекрасить ветки сразу
func on_switch_power_mode_changed(_data: Dictionary) -> void:
	update_visual()


## Стрелку переложили (рычаг, пульт, привод): подсветить активный путь на пару секунд.
## При старте и загрузке не подсвечиваем
func on_switch_changed(data: Dictionary) -> void:
	var src: StringName = data.get("source", &"")
	if src == &"init" or src == &"load":
		return
	_flash_route(int(data.get("route", 0)))


# ==========================================
# Ноды
# ==========================================

func _new_shape(size: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = size
	cs.shape = bx
	return cs


func _build_instance() -> Node3D:
	TrackMeshBuilder.ensure_materials()
	var root := Node3D.new()
	root.name = "SwitchTrack"

	# Слои как у G239 / flex: треки = слой 3, видят треки и призраков
	ballast = Area3D.new()
	ballast.name = "Ballast"
	ballast.collision_layer = 1 << 2
	ballast.collision_mask = (1 << 2) | (1 << 10)
	root.add_child(ballast)
	# Заглушка: C_Path генерирует свои коллизии, только если у Ballast/Head нет детей
	var b0 := _new_shape(Vector3(0.01, 0.01, 0.01))
	ballast.add_child(b0)
	_ballast_shapes.append(b0)

	head = StaticBody3D.new()
	head.name = "HeadStaticBody3D"
	head.collision_layer = 1 << 2
	head.collision_mask = (1 << 2) | (1 << 10)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.0
	head.physics_material_override = pm
	root.add_child(head)
	var h0 := _new_shape(Vector3(0.01, 0.01, 0.01))
	head.add_child(h0)
	_head_shapes.append(h0)

	if with_lever:
		_build_lever(root)
	return root


func _ensure_route_nodes(n: int) -> void:
	while _meshes.size() < n:
		var mi := MeshInstance3D.new()
		mi.name = "Mesh_%d" % _meshes.size()
		instance.add_child(mi)
		_meshes.append(mi)
		var sl := TrackMeshBuilder.create_sleepers_node(style)
		sl.name = "Sleepers_%d" % _sleepers.size()
		instance.add_child(sl)
		_sleepers.append(sl)


# ==========================================
# Пересборка (один раз: форма стрелки статична)
# ==========================================

func _rebuild() -> void:
	var path := get_comp(C_Path) as C_Path
	if path == null or path.routes.is_empty():
		return
	var curves := path.all_curves()
	_ensure_route_nodes(curves.size())

	var plan: Array = []
	var total := 0
	for i in curves.size():
		var c: Curve3D = curves[i]
		var L := c.get_baked_length()
		if L < 0.5:
			continue
		_meshes[i].mesh = TrackMeshBuilder.build_mesh(style, c, L, false)
		TrackMeshBuilder.place_sleepers(_sleepers[i].multimesh, style, c, L)
		var cuts := TrackMeshBuilder.collision_cuts(c, L, false, false, style.collision_end_inset)
		plan.append({"c": c, "L": L, "cuts": cuts})
		total += cuts.size() - 1

	_resize_pool(total)
	var k := 0
	for pl in plan:
		var cuts: PackedFloat32Array = pl.cuts
		for j in cuts.size() - 1:
			var bx := TrackMeshBuilder.segment_boxes(style, pl.c, pl.L, cuts[j], cuts[j + 1])
			_set_box(_ballast_shapes[k], bx.ballast_size, bx.ballast_xf)
			_set_box(_head_shapes[3 * k], bx.ballast_size, bx.ballast_xf)
			_set_box(_head_shapes[3 * k + 1], bx.rail_size, bx.rail_l_xf)
			_set_box(_head_shapes[3 * k + 2], bx.rail_size, bx.rail_r_xf)
			k += 1

	_collect_meshes()
	_place_lever(path)
	update_visual()


func _resize_pool(nseg: int) -> void:
	while _ballast_shapes.size() < nseg:
		var cs := _new_shape(Vector3.ONE)
		ballast.add_child(cs)
		_ballast_shapes.append(cs)
	while _ballast_shapes.size() > nseg:
		var old: CollisionShape3D = _ballast_shapes.pop_back()
		old.queue_free()
	while _head_shapes.size() < nseg * 3:
		var cs2 := _new_shape(Vector3.ONE)
		head.add_child(cs2)
		_head_shapes.append(cs2)
	while _head_shapes.size() > nseg * 3:
		var old2: CollisionShape3D = _head_shapes.pop_back()
		old2.queue_free()


func _set_box(cs: CollisionShape3D, size: Vector3, xf: Transform3D) -> void:
	var bx := cs.shape as BoxShape3D
	if not bx.size.is_equal_approx(size):
		bx.size = size
	cs.transform = xf


# ==========================================
# Электрика
# ==========================================

const CLIP_S := 6.0       # вдоль кривой от начала (рычаг стоит на 3.0)
const CLIP_GAP := 0.6     # от края основания до оси клипа
const CLIP_LIFT := 0.3    # половина высоты коробки клипа


## Клип стоит у начала пути 0, со стороны, противоположной ответвлению/второму пути (рычаг стрелки на той же стороне,
## но ближе к носку, не пересекаются)
func clip_transform() -> Transform3D:
	var path := get_comp(C_Path) as C_Path
	if style == null or path == null or path.routes.is_empty():
		return super()
	var c0: Curve3D = path.routes[0]
	var L := c0.get_baked_length()
	if L < 0.01:
		return super()
	var side := 1.0
	if path.routes.size() > 1:
		var c1: Curve3D = path.routes[1]
		var d := c1.sample_baked(0.0).x - c0.sample_baked(0.0).x          # кросс: второй путь начинается сбоку
		if absf(d) < 0.01:
			d = c1.sample_baked(c1.get_baked_length()).x - c0.sample_baked(L).x   # стрелка: расходятся на конце
		side = -1.0 if d > 0.0 else 1.0
	var f := TrackMeshBuilder.frame(c0, minf(CLIP_S, L), L)
	var b := Basis(f.r, f.u, f.r.cross(f.u))
	return Transform3D(b, f.p + f.r * (side * (style.collision_width * 0.5 + CLIP_GAP)) + f.u * CLIP_LIFT)


## Слой электрики:
##  - кросс с раздельными цепями: каждый путь красим по своему лучу;
##  - стрелка E1 (power_routing): активная ветка под током, неактивная без подсветки (обесточена);
##  - остальным как раньше (один материал на все).
## У стрелки в зоне носка обе ветки лежат друг на друге, там рельсы мерцают между цветами. Это визуал, физики не касается
func _set_power_view():
	var pc := get_comp(C_PowerTrack) as C_PowerTrack
	var sw := get_comp(C_Switch) as C_Switch
	var routed := sw != null and sw.power_routing
	if pc == null or (pc.legs <= 1 and not routed) or _meshes.size() < 2:
		super()
		return
	if is_inside_tree():
		await get_tree().physics_frame
	var path := get_comp(C_Path) as C_Path
	var active := path.active_route if path else 0
	for i in _meshes.size():
		var m := _meshes[i]
		if not (rail_surface_index >= 0 and m.mesh and m.mesh.get_surface_count() > rail_surface_index):
			continue
		if routed and i != active:
			m.set_surface_override_material(rail_surface_index, null)   # мертвая ветка
			continue
		var leg := mini(i, pc.legs - 1)
		var cid := pc.contour_of(leg)
		var volt: float = PGM.get_power(cid) if cid != 0 else 0.0
		var mat: ShaderMaterial = _rail_power_material(pc, cid, volt, pc.flip_of(leg))
		m.set_surface_override_material(rail_surface_index, mat)


# ==========================================
# Подсветка активного пути
# ==========================================

## КЗ на крестовине: вспышка активного пути красным
func on_switch_short(_data: Dictionary) -> void:
	var path := get_comp(C_Path) as C_Path
	_flash_route(path.active_route if path else 0, Color(0.95, 0.15, 0.10))


func _flash_route(route: int, color: Color = Color(0.0, 0.0, 0.0, 0.0)) -> void:
	var path := get_comp(C_Path) as C_Path
	if path == null or instance == null or route < 0 or route >= path.routes.size():
		return
	var mesh := _build_ribbon(path.routes[route])
	if mesh == null:
		return
	_clear_flash()

	var col := color if color.a > 0.0 else (COL_LEVER_DIV if route == 1 else COL_LEVER_OK)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(col.r, col.g, col.b, 0.0)   # плавно включаем: FLASH_FADE вверх, FLASH_HOLD, FLASH_FADE вниз
	mat.render_priority = 1

	_flash = MeshInstance3D.new()
	_flash.name = "RouteFlash"
	_flash.mesh = mesh
	_flash.material_override = mat
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.add_child(_flash)

	_flash_tween = create_tween()
	_flash_tween.tween_property(mat, "albedo_color:a", FLASH_ALPHA, FLASH_FADE)
	_flash_tween.tween_interval(FLASH_HOLD)
	_flash_tween.tween_property(mat, "albedo_color:a", 0.0, FLASH_FADE)
	_flash_tween.tween_callback(_clear_flash)


func _clear_flash() -> void:
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = null
	if _flash and is_instance_valid(_flash):
		_flash.queue_free()
	_flash = null


## Лента над рельсами вдоль кривой (в системе инстанса: тот же репер, что у меша трака)
func _build_ribbon(crv: Curve3D) -> ArrayMesh:
	var L := crv.get_baked_length()
	if L < 0.5:
		return null
	var path := get_comp(C_Path) as C_Path
	var top := (path.head_height() if path else style.head_height()) + FLASH_LIFT
	var hw := style.rail_x * Global.flash_width
	var n := maxi(1, ceili(L / FLASH_STEP))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	var up := Vector3.UP
	for i in n + 1:
		var fr := TrackMeshBuilder.frame(crv, L * i / n, L)
		var l := fr.p + fr.u * top - fr.r * hw
		var r := fr.p + fr.u * top + fr.r * hw
		if i > 0:
			for v in [prev_l, prev_r, l, prev_r, r, l]:
				st.set_normal(up)
				st.add_vertex(v)
		prev_l = l
		prev_r = r
	return st.commit()


# ==========================================
# Рычаг
# ==========================================

func _build_lever(root: Node3D) -> void:
	var lever := Node3D.new()
	lever.name = "Lever"
	root.add_child(lever)

	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = Color(0.22, 0.22, 0.25)
	base_mat.roughness = 0.8
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 0.5, 1.0)
	base.mesh = bm
	base.material_override = base_mat
	base.position = Vector3(0, 0.25, 0)
	lever.add_child(base)

	_lever_pivot = Node3D.new()
	_lever_pivot.name = "LeverPivot"
	_lever_pivot.position = Vector3(0, 0.5, 0)
	lever.add_child(_lever_pivot)

	_lever_mat = StandardMaterial3D.new()
	_lever_mat.albedo_color = COL_LEVER_OK
	_lever_mat.roughness = 0.5
	var arm := MeshInstance3D.new()
	var am := BoxMesh.new()
	am.size = Vector3(0.22, LEVER_HEIGHT, 0.22)
	arm.mesh = am
	arm.material_override = _lever_mat
	arm.position = Vector3(0, LEVER_HEIGHT * 0.5, 0)
	_lever_pivot.add_child(arm)

	lever_area = Area3D.new()
	lever_area.name = "LeverHandle"
	lever_area.set_meta(&"switch_lever", true)
	lever_area.collision_layer = Global.active_layers(['handles'])
	lever_area.collision_mask = 0
	var cs := CollisionShape3D.new()
	var sp := SphereShape3D.new()
	sp.radius = 0.9
	cs.shape = sp
	cs.position = Vector3(0, LEVER_HEIGHT * 0.8, 0)
	lever_area.add_child(cs)
	_lever_pivot.add_child(lever_area)


## Рычаг у носка, с обратной от ответвления стороны (за пределами балласта)
func _place_lever(path: C_Path) -> void:
	var curves := path.all_curves()
	if curves.size() < 2 or _lever_pivot == null:
		return
	var toe := curves[0].sample_baked(0.0)
	var c1: Curve3D = curves[1]
	var side := signf(c1.sample_baked(c1.get_baked_length()).x)
	if side == 0.0:
		side = 1.0
	_lever_dir = side
	var lever := instance.get_node("Lever") as Node3D
	lever.position = Vector3(toe.x - side * (style.collision_width * 0.5 + 0.9), toe.y, toe.z - 3.0)
	_update_lever(path.active_route)
	_set_lever_enabled(not has_comp(C_Ghost))


func _update_lever(route: int) -> void:
	if _lever_pivot == null:
		return
	# наклон в сторону ответвления в положении 1 и в противоположную в положении 0
	var dir_x := _lever_dir if route == 1 else -_lever_dir
	_lever_pivot.rotation.z = -LEVER_TILT * dir_x
	_lever_mat.albedo_color = COL_LEVER_DIV if route == 1 else COL_LEVER_OK


func _set_lever_enabled(on: bool) -> void:
	_lever_on = on
	if lever_area:
		lever_area.collision_layer = Global.active_layers(['handles']) if on else 0


## Стиль для подгонки полос слоя питания под UV рельса (тайл, поворот)
func _power_style() -> TrackStyle:
	return style
