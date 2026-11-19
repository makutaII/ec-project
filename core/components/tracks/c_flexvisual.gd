class_name C_FlexVisual extends C_TrackVisual

# XX claude-terra (новый файл)
###################################
## Визуал flex-трака. Сцены нет: все ноды строятся в коде и принадлежат этому компоненту
## (Mesh, Sleepers, Ballast Area3D, HeadStaticBody3D), структура как у обычного трака,
## поэтому C_Path / C_Blockable / C_Socket работают по тем же правилам.
###################################
## Геометрию и высоты задает TrackStyle (рельсы, шпалы, балласт). Здесь только построение:
##  - свип-меш по кривой C_Path: балласт (если есть) и рельсы. Индекс поверхности рельсов
##    лежит в rail_surface_index (1 с балластом, 0 без), power layer работает по нему;
##  - шпалы: MultiMesh, равномерный шаг по длине кривой;
##  - коллизии: сегменты ~flex_collision_step, пул CollisionShape3D, Area3D балласта не пересоздается
##    (C_Blockable подписан на него один раз). Пересборка не чаще flex_rebuild_period, финал - on_flex_final.
## Высоту поверхности катания отдает C_Path.head_height(), число берется из style.head_height().
## Сами функции построения (репер, свип, шпалы, границы и боксы коллизии) живут в TrackMeshBuilder.

## Задает FlexSetting. null = TrackStyle по умолчанию (как раньше: балласт, 0.85)
var style: TrackStyle

var mesh_node: MeshInstance3D
var sleepers: MultiMeshInstance3D
var ballast: Area3D
var head: StaticBody3D

var _ballast_shapes: Array[CollisionShape3D] = []
var _head_shapes: Array[CollisionShape3D] = []
var _built := false
var _dirty := false
var _last_ms := 0
var _period_ms := 50
var _preview := false


func _init() -> void:
	set_process(false)


## Базовый C_Visual.on_added инстанцирует сцену; у flex сцены нет
func on_added() -> void:
	
	if style == null:
		style = TrackStyle.new()
	rail_surface_index = style.rail_surface_index()
	
	_period_ms = int(Global.settings.flex_rebuild_period * 1000.0)
	instance = _build_instance()
	entity.add_child(instance)
	parts = PartRegistry.build(instance)   # новое
	_collect_meshes()
	_on_instance_ready()   # C_TrackVisual: area_nodes, static_node


## C_Path уже в Entity (а его on_entity_ready еще впереди): отдаем ему высоту поверхности катания
func on_entity_ready() -> void:
	var path := get_comp(C_Path) as C_Path
	if path:
		path.set_head_height(style.head_height())


func _set_overlay(mat: Material) -> void:
	super(mat)
	if sleepers:
		sleepers.material_overlay = mat


# ==========================================
# События
# ==========================================

func on_curve_changed(_d: Dictionary) -> void:
	if not _built:
		_rebuild()
		return
	_dirty = true
	set_process(true)


func on_stretch_started(_d: Dictionary) -> void:
	_preview = true


func on_flex_final(_d: Dictionary) -> void:
	_preview = false
	_rebuild()

## Правка изгиба: пока тянем, меш и коллизии грубее. Финал - on_flex_final
func on_flex_edit_started(_d: Dictionary) -> void:
	_preview = true
	
func _process(_delta: float) -> void:
	if not _dirty:
		set_process(false)
		return
	if Time.get_ticks_msec() - _last_ms >= _period_ms:
		_rebuild()


# ==========================================
# Ноды
# ==========================================

func _build_instance() -> Node3D:
	var sk := TrackMeshBuilder.build_skeleton(style, "FlexTrack")
	mesh_node = sk.mesh_node
	sleepers = sk.sleepers
	ballast = sk.ballast
	head = sk.head
	_ballast_shapes.append(sk.ballast_dummy)
	_head_shapes.append(sk.head_dummy)
	return sk.root


# ==========================================
# Пересборка
# ==========================================

func _rebuild() -> void:
	var path := get_comp(C_Path) as C_Path
	if not path or not path.curve:
		return
	var curve := path.curve
	var L := curve.get_baked_length()
	if L < 0.5:
		return
	_built = true
	_dirty = false
	_last_ms = Time.get_ticks_msec()
	mesh_node.mesh = TrackMeshBuilder.build_mesh(style, curve, L, _preview)
	TrackMeshBuilder.place_sleepers(sleepers.multimesh, style, curve, L)
	_rebuild_collision(curve, L)


# --- коллизии: пул сегментов, Area3D не трогаем ---

func _rebuild_collision(curve: Curve3D, L: float) -> void:
	var cuts := TrackMeshBuilder.collision_cuts(curve, L, _preview)
	var nseg := cuts.size() - 1
	_resize_pool(nseg)
	for i in nseg:
		var bx := TrackMeshBuilder.segment_boxes(style, curve, L, cuts[i], cuts[i + 1])
		TrackMeshBuilder.set_box(_ballast_shapes[i], bx.ballast_size, bx.ballast_xf)
		TrackMeshBuilder.set_box(_head_shapes[3 * i], bx.ballast_size, bx.ballast_xf)
		TrackMeshBuilder.set_box(_head_shapes[3 * i + 1], bx.rail_size, bx.rail_l_xf)
		TrackMeshBuilder.set_box(_head_shapes[3 * i + 2], bx.rail_size, bx.rail_r_xf)


func _resize_pool(nseg: int) -> void:
	while _ballast_shapes.size() < nseg:
		var cs := TrackMeshBuilder.new_shape(Vector3.ONE)
		ballast.add_child(cs)
		_ballast_shapes.append(cs)
	while _ballast_shapes.size() > nseg:
		var old: CollisionShape3D = _ballast_shapes.pop_back()
		old.queue_free()
	while _head_shapes.size() < nseg * 3:
		var cs := TrackMeshBuilder.new_shape(Vector3.ONE)
		head.add_child(cs)
		_head_shapes.append(cs)
	while _head_shapes.size() > nseg * 3:
		var old2: CollisionShape3D = _head_shapes.pop_back()
		old2.queue_free()


## Стиль для подгонки полос слоя питания под UV рельса (тайл, поворот)
func _power_style() -> TrackStyle:
	return style
