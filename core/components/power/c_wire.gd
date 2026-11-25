class_name C_Wire extends Component

#####################
## Провод (ATTN_10 §10.5.7, D4; ATTN_23 §23.9, W1)
#####################
## Сущность-провод: два конца (клеммы PowerTerminal), точки излома между ними, «скрутка» (меняет полярность).
## Вид: двужильный кабель одним мешем (WireMesh) по трассе со скруглёнными углами (WireRoute), одна область выбора на провод.
## Узел `_vis` лежит в сущности, но не наследует её позу (top_level). Выбор и ховер обводят кабель контуром (next_pass, раздутая оболочка), цвет жил не меняют.
## Концы следуют за клеммами: двигаешь пульт или трак, провод перерисовывается. Клемма исчезла (трак удалён,
## клип снят): провод удаляется. Любое изменение проводки просит PGM пересчитать сеть.
## Сейв: тип, ключ и позиция каждой клеммы; второй проход после загрузки (restore_after_load) находит клеммы по геометрии.

const WIRE_SETTING_PATH := "res://ui/dc_controllers/objects/wire_01.tres"
const HIT_RADIUS := 0.3
## Изоляция жил: красная и чёрная. Скрутка меняет жилы местами по ходу провода
const COLOR_RED := Color(0.85, 0.15, 0.12)
const COLOR_BLACK := Color(0.08, 0.08, 0.09)
## Цвет и толщина контура выбора и ховера
const COLOR_SELECTED := Color(1.0, 0.85, 0.2)
const COLOR_HOVER := Color(1.0, 0.6, 0.35)
const OUTLINE_GROW := 0.035
## Радиус поиска клеммы при восстановлении из сейва, ю
const RESTORE_RADIUS := 1.0

var a: PowerTerminal
var b: PowerTerminal
## Точки излома между концами, мировые координаты
var points := PackedVector3Array()
## «Скрутка»: провода перекрещены, полярность на другом конце обратная
var twist := false

var _vis: Node3D
var _mi: MeshInstance3D
var _area: Area3D
var _mats: Array[StandardMaterial3D] = []
var _outline_selected: StandardMaterial3D
var _outline_hover: StandardMaterial3D
var _sig := Vector3.ZERO
var _loaded: Dictionary = {}
var _attached := false
var _restore_tries := 0
## Сколько физкадров ждать клеммы после загрузки
const RESTORE_FRAMES := 180


## Создает сущность-провод из паспорта wire_01.tres и подключает её. parent: куда положить сущность (EntitiesRoot)
static func create_wire(parent: Node, term_a: PowerTerminal, term_b: PowerTerminal, mid_points: PackedVector3Array = PackedVector3Array(), with_twist := false) -> Entity:
	if not PowerTerminal.can_connect(term_a, term_b):
		return null
	var setting := load(WIRE_SETTING_PATH) as EntitySetting
	if setting == null:
		push_error("C_Wire: нет паспорта провода %s" % WIRE_SETTING_PATH)
		return null
	var e: Entity = EntityFactory.new().create_from_setting(setting)
	parent.add_child(e)
	var w := e.get_comp(C_Wire) as C_Wire
	w.setup(term_a, term_b, mid_points, with_twist)
	return e


func setup(term_a: PowerTerminal, term_b: PowerTerminal, mid_points: PackedVector3Array, with_twist := false) -> void:
	a = term_a
	b = term_b
	points = mid_points
	twist = with_twist
	_attach()


func on_added() -> void:
	name = "C_Wire"
	add_to_group(&"power_wire")


func _attach() -> void:
	if _attached or a == null or b == null:
		return
	_attached = true
	a.add_wire(self)
	b.add_wire(self)
	_ensure_visual()
	_rebuild()
	PGM.request_recalculate()


func is_valid_wire() -> bool:
	return _attached and is_instance_valid(a) and is_instance_valid(b) and not is_queued_for_deletion() \
		and (entity == null or not entity.is_queued_for_deletion())


func toggle_twist() -> void:
	twist = not twist
	_rebuild()
	PGM.request_recalculate()


func _exit_tree() -> void:
	if is_instance_valid(a):
		a.remove_wire(self)
	if is_instance_valid(b):
		b.remove_wire(self)
	_attached = false
	if is_instance_valid(_vis):
		_vis.queue_free()
	if is_inside_tree() and is_instance_valid(PGM):
		PGM.request_recalculate()


func _physics_process(_delta: float) -> void:
	if not _attached:
		# Загрузка из сейва: клеммы (клипы flex, пульты) могут появиться на несколько кадров позже
		if not _loaded.is_empty():
			_restore_tries += 1
			if not restore_after_load() and _restore_tries > RESTORE_FRAMES:
				push_warning("C_Wire: не нашлись клеммы провода после загрузки, провод удалён")
				_loaded = {}
				entity.kill_me()
		return
	if not is_instance_valid(a) or not is_instance_valid(b):
		entity.kill_me()   # клемма исчезла: провод не висит в воздухе
		return
	if not a.is_inside_tree() or not b.is_inside_tree():
		return
	var sig := a.global_position + b.global_position * 3.0
	if not sig.is_equal_approx(_sig):
		_rebuild()


func on_component_added(type: Script) -> void:
	if type == C_Selected or type == C_Hovered:
		_apply_highlight()


func on_component_removed(type: Script) -> void:
	if type == C_Selected or type == C_Hovered:
		_apply_highlight()


# XX claude-wire W0: провод и секция
## Точки в плане (x = X, y = Z), по которым провод считается «стоящим» на секции (LYM.objects_on_section).
## Сущность провода стоит в нуле мира, поэтому её позиция не считается: только точки излома. Провод без изломов
## висит между клеммами хозяев, секцию не держит (хозяева считаются сами)
func probe_points() -> Array[Vector2]:
	var res: Array[Vector2] = []
	for p in points:
		res.append(Vector2(p.x, p.z))
	return res


## Ломаная в мировых координатах
func polyline() -> PackedVector3Array:
	var res := PackedVector3Array()
	if is_instance_valid(a):
		res.append(a.global_position)
	res.append_array(points)
	if is_instance_valid(b):
		res.append(b.global_position)
	return res


func _ensure_visual() -> void:
	if is_instance_valid(_vis) or entity == null:
		return
	_vis = Node3D.new()
	_vis.name = "WireVisual"
	_vis.top_level = true
	entity.add_child(_vis)
	_mi = MeshInstance3D.new()
	_mi.name = "Cable"
	_vis.add_child(_mi)
	_mats.clear()
	for col in [COLOR_RED, COLOR_BLACK]:
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.45
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mats.append(m)
	_outline_selected = _make_outline(COLOR_SELECTED)
	_outline_hover = _make_outline(COLOR_HOVER)
	# область выбора мышью: одна на провод, по форме на отрезок
	_area = Area3D.new()
	_area.name = "Hit"
	_area.collision_layer = Global.active_layers(["power"])
	_area.collision_mask = 0
	_area.monitoring = false
	_vis.add_child(_area)


## Контур: раздутая по нормалям копия без лицевых граней, видна только кромкой вокруг жил
func _make_outline(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_FRONT
	m.grow = true
	m.grow_amount = OUTLINE_GROW
	return m


## Выбор и ховер: контур вокруг кабеля (выбор важнее ховера), цвет жил не меняется
func _apply_highlight() -> void:
	var outline: StandardMaterial3D = null
	if entity != null and entity.has_comp(C_Selected):
		outline = _outline_selected
	elif entity != null and entity.has_comp(C_Hovered):
		outline = _outline_hover
	for m in _mats:
		m.next_pass = outline


func _rebuild() -> void:
	_ensure_visual()
	if not is_instance_valid(_vis) or not _vis.is_inside_tree():
		return
	_clear_hit()
	if is_instance_valid(a) and is_instance_valid(b):
		_sig = a.global_position + b.global_position * 3.0
	var route := WireRoute.from_polyline(polyline())
	if route.points.size() < 2:
		_mi.mesh = null
		return
	var mesh := WireMesh.build(route.smooth(), twist)
	for k in mesh.get_surface_count():
		mesh.surface_set_material(k, _mats[k])
	_mi.mesh = mesh
	_add_hit(route.points)
	_apply_highlight()


func _clear_hit() -> void:
	for c in _area.get_children():
		_area.remove_child(c)
		c.queue_free()


## Область выбора: цилиндр на каждый отрезок исходной ломаной (углы без скругления)
func _add_hit(line: PackedVector3Array) -> void:
	for i in line.size() - 1:
		var p0 := line[i]
		var p1 := line[i + 1]
		var seg_len := p0.distance_to(p1)
		if seg_len < WireRoute.MIN_SEG:
			continue
		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = HIT_RADIUS
		shape.height = seg_len
		cs.shape = shape
		cs.transform = Transform3D(WireRoute.basis_along(p1 - p0), (p0 + p1) * 0.5)
		_area.add_child(cs)


# ------ СЕЙВ ------

func save_data() -> Dictionary:
	if not is_valid_wire():
		return {}
	return {
		"a": _term_data(a),
		"b": _term_data(b),
		"points": points,
		"twist": twist,
	}


func _term_data(t: PowerTerminal) -> Dictionary:
	return {"key": String(t.key), "kind": int(t.kind), "pos": t.global_position}


func load_data(d: Dictionary) -> void:
	_loaded = d
	points = d.get("points", PackedVector3Array())
	twist = bool(d.get("twist", false))


## Одна попытка восстановления после загрузки: ищем клеммы по ключу и геометрии
func restore_after_load() -> bool:
	if _loaded.is_empty() or _attached:
		return _attached
	var ta := _find_terminal(_loaded.get("a", {}))
	var tb := _find_terminal(_loaded.get("b", {}))
	if ta == null or tb == null or not PowerTerminal.can_connect(ta, tb):
		return false
	_loaded = {}
	a = ta
	b = tb
	_attach()
	return true


func _find_terminal(d: Dictionary) -> PowerTerminal:
	if d.is_empty():
		return null
	var best: PowerTerminal = null
	var best_d := RESTORE_RADIUS
	var pos: Vector3 = d.get("pos", Vector3.ZERO)
	for n in get_tree().get_nodes_in_group(&"power_terminal"):
		var t := n as PowerTerminal
		if t == null or not t.is_free() or String(t.key) != String(d.get("key", "")) or int(t.kind) != int(d.get("kind", 0)):
			continue
		var dist := t.global_position.distance_to(pos)
		if dist < best_d:
			best_d = dist
			best = t
	return best
