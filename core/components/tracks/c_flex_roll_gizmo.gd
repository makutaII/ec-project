class_name C_FlexRollGizmo extends ICapability

###########################
## Кольцо со стрелкой на конце flex: крен свободного конца (ATTN_27 §27.15, шаг C8.3)
###########################
## Кольцо стоит на конце flex, перпендикулярно ходу. Стрелка на кольце показывает, куда смотрит «верх» лотка (крен конца),
## тусклая стрелка поменьше показывает крен начала, серая метка нулевой крен. Подпись «крен N°». Мышь: ЛКМ по кольцу и тянуть
## по кольцу, скручивание шагами 5° (Shift: 1°). Клавиши и Shift+колесо делают то же шагами (C_FlexShape.on_roll_input).
## Данные крена хранит C_FlexShape (start_roll, end_roll, roll_twist), здесь только вид и ввод. Видно у растягиваемого flex
## (без ввода мышью) и у выбранного готового flex; у привязанного конца крен берётся у соседа, кольцо скрыто.
## Ввод мышью идёт теми же событиями, что у ручек изгибов (on_pointer_pressed, on_handle_drag, on_handle_released).

const RING_R := 2.4        # радиус кольца (лоток шириной 3,2 внутри)
const TUBE := 0.1          # толщина трубки кольца
const ARROW_LEN := 0.9
const PICK_R := 0.9        # радиус шаров захвата вдоль кольца
const PICK_COUNT := 12
const LIFT := 0.5          # центр кольца над концом кривой вдоль «верха»

static var _mat_ring: StandardMaterial3D
static var _mat_arrow: StandardMaterial3D
static var _mat_start: StandardMaterial3D
static var _mat_zero: StandardMaterial3D

var _shape: C_FlexShape
var _root: Node3D
var _arrow: MeshInstance3D
var _arrow_start: MeshInstance3D
var _zero: MeshInstance3D
var _label: Label3D
var _area: Area3D
var _drag := false
var _t_local := Vector3(0, 0, -1)   # ход в конце, в осях Entity
var _u0_local := Vector3.UP         # «верх» без крена в конце


func on_entity_ready() -> void:
	_shape = get_comp(C_FlexShape) as C_FlexShape
	_build()
	_refresh()


func on_component_added(_t: Script) -> void:
	_refresh()


func on_component_removed(_t: Script) -> void:
	if _drag and not has_comp(C_Selected):
		_end_drag()
	_refresh()


func on_curve_changed(_d: Dictionary) -> void:
	_refresh()


func on_flex_final(_d: Dictionary) -> void:
	_refresh()


func on_flex_edit_started(_d: Dictionary) -> void:
	_refresh()


func on_stretch_ended(_d: Dictionary) -> void:
	_refresh()


func _build() -> void:
	if _mat_ring == null:
		_mat_ring = _unshaded(Color(0.2, 0.75, 1.0))
		_mat_arrow = _unshaded(Color(1.0, 0.85, 0.1))
		_mat_start = _unshaded(Color(0.75, 0.6, 0.15, 0.7))
		_mat_zero = _unshaded(Color(0.65, 0.65, 0.7))
	_root = Node3D.new()
	_root.name = "FlexRollGizmo"
	entity.add_child(_root)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = RING_R - TUBE
	tm.outer_radius = RING_R + TUBE
	ring.mesh = tm
	ring.material_override = _mat_ring
	_root.add_child(ring)
	_arrow = _make_arrow(_mat_arrow, 1.0)
	_arrow_start = _make_arrow(_mat_start, 0.6)
	_zero = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.12, 0.12, 0.5)
	_zero.mesh = bm
	_zero.material_override = _mat_zero
	_zero.position = Vector3(0, 0, RING_R)   # метка нулевого крена: «верх» без крена
	_root.add_child(_zero)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 48
	_label.pixel_size = 0.02
	_root.add_child(_label)
	# Захват: шары вдоль кольца (клик по треку рядом с концом не должен тянуть кольцо)
	_area = Area3D.new()
	_area.name = "FlexRollPick"
	_area.collision_layer = 0
	_area.collision_mask = 0
	for i in PICK_COUNT:
		var a := TAU * float(i) / float(PICK_COUNT)
		var cs := CollisionShape3D.new()
		var sp := SphereShape3D.new()
		sp.radius = PICK_R
		cs.shape = sp
		cs.position = Vector3(sin(a) * RING_R, 0.0, cos(a) * RING_R)
		_area.add_child(cs)
	_root.add_child(_area)


static func _unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 10
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _make_arrow(mat: StandardMaterial3D, k: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = 0.28 * k
	cm.height = ARROW_LEN * k
	mi.mesh = cm
	mi.material_override = mat
	_root.add_child(mi)
	return mi


## Кольцо видно: растягиваемый flex (без ввода мышью) или выбранный готовый, если у него свободный конец
func _is_visible() -> bool:
	if _shape == null or _shape.snapped_end:
		return false
	if _shape.stretching:
		return true
	return has_comp(C_Selected) and not has_comp(C_Ghost) and not has_comp(C_Drag)


func _is_interactive() -> bool:
	return _is_visible() and not _shape.stretching and not has_comp(C_Ghost)


func _refresh() -> void:
	if _root == null or _shape == null:
		return
	var path := get_comp(C_Path) as C_Path
	var show := _is_visible() and path != null and path.curve != null and path.curve.get_point_count() >= 2
	_root.visible = show
	if _area != null:
		var layer := Global.active_layers(['handles']) if (show and _is_interactive()) else 0
		if _area.collision_layer != layer:
			_area.collision_layer = layer
	if not show:
		return
	var cv := path.curve
	var L := cv.get_baked_length()
	var end := cv.get_point_position(cv.get_point_count() - 1)
	var t := (cv.sample_baked(L) - cv.sample_baked(maxf(L - 0.25, 0.0))).normalized()
	if absf(t.dot(Vector3.UP)) > 0.9999:
		_root.visible = false   # ход строго вертикален: ориентации «верха» нет
		return
	var ring := JointMath.ring_basis(t)
	var u0 := ring.z
	_t_local = t
	_u0_local = u0
	# Ось кольца (Y тора) вдоль хода: плоскость кольца это right (X) и «верх» (Z)
	_root.transform = Transform3D(ring, end + u0 * LIFT)
	var roll_end := _shape.end_roll_deg()
	_place_arrow(_arrow, roll_end)
	_place_arrow(_arrow_start, _shape.start_roll)
	_label.text = "крен %+.0f°" % roll_end
	_label.position = Vector3(0, 0, RING_R + 1.2)


## Стрелка на кольце под углом roll (градусы, + «верх» уходит вправо), остриём наружу
func _place_arrow(arrow: MeshInstance3D, roll_deg: float) -> void:
	var a := deg_to_rad(roll_deg)
	var dir := Vector3(sin(a), 0.0, cos(a))   # в осях кольца: X вправо, Z «верх»
	var y_axis := Vector3(0, 1, 0)           # ось тора, она же ход
	arrow.transform = Transform3D(Basis(y_axis, dir, y_axis.cross(dir)), dir * (RING_R + ARROW_LEN * 0.5))


# ==========================================
# Ввод мышью (события шлёт SelectTool, словарь общий с ручками изгибов)
# ==========================================

func on_pointer_pressed(d: Dictionary) -> void:
	if d.get("consumed", false) or _area == null or not _is_interactive():
		return
	if d.get("collider") == _area:
		_drag = true
		entity.send_event("on_roll_edit_begin", {})
		d["consumed"] = true
		d["drag"] = true


func on_handle_drag(d: Dictionary) -> void:
	if not _drag or _shape == null:
		return
	var t_w := (entity.global_basis * _t_local).normalized()
	var end_w := _root.global_position
	var hit = Plane(t_w, end_w).intersects_ray(d.from, d.dir)
	if hit == null:
		return
	var v: Vector3 = (hit as Vector3) - end_w
	if v.length_squared() < 0.01:
		return   # курсор в центре кольца: угла нет
	# Крен, на который указывает курсор вокруг хода (правая тройка, + правый край ниже), это крен конца; скручивание = конец − начало
	var step := 1.0 if Input.is_key_pressed(KEY_SHIFT) else C_FlexShape.ROLL_STEP
	var twist := JointMath.twist_for(JointMath.roll_of_point(t_w, v), _shape.start_roll, step)
	entity.send_event("on_roll_twist_set", {"twist": twist})


func on_handle_released(_d: Dictionary) -> void:
	_end_drag()


func _end_drag() -> void:
	if _drag:
		_drag = false
		entity.send_event("on_roll_edit_end", {})
