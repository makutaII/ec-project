class_name ModelRig extends RefCounted

###################################
## Тележки и колёса из модели (.glb): узлы unit_<n> с колёсными парами wheel_<n>_<k> (0_ATTN_24, паровоз)
###################################
## Модель сама задаёт тележки: сколько узлов, где они по длине, сколько осей и какого радиуса колёса.
## Паспорт тележек (WagonConfig.bogie_configs) такой модели не нужен: ModelRig строит BogieConfig по модели.
##
## Разметка в Blender (кнопка «Узел из выделенных колёс»):
##  - unit_<n>: пустышка посередине между крайними осями узла, детьми колёсные пары (и рама frame_<n>);
##  - wheel_<n>_<k>: колёсная пара (оба колеса и ось), origin в центре оси, extras radius (радиус круга катания без реборды).
## Роли читаются как у PartRegistry: meta "role" или glTF extras {"role": ...}.
##
## extract() зовётся ДО PartRegistry.build и сбора мешей C_Visual: узлы unit_* вынимаются из кузова и в mesh_nodes не попадают,
## то есть кистью и оверлеями выделения не красятся, и подъём кузова (offset_mesh_y) их не уносит. Дальше C_TrainVisual
## ставит их в корень вагона на высоту оси (y = радиус) и строит датчик рельса и коллизию кодом.
## Модель без узлов unit_* (все прежние): extract() возвращает null, тележки собираются по паспорту.

## Датчик рельса берём у стандартной тележки: настройки луча (слои, длина) остаются в одном месте
const RAY_SOURCE := preload("res://data/trains/default_bogie.tscn")

static var _unit_re: RegEx
static var _wheel_re: RegEx


class Wheel extends RefCounted:
	var node: Node3D
	var role: StringName
	var radius := 0.0
	var z := 0.0                       # смещение оси от центра узла (ось Z узла)
	var meshes: Array[MeshInstance3D] = []


class Unit extends RefCounted:
	var node: Node3D
	var number := 0
	var z := 0.0                       # положение центра узла по Z в осях вагона (начало вагона = центр кузова)
	var radius := 0.0
	var wheels: Array[Wheel] = []
	var config: BogieConfig


var units: Array[Unit] = []
var bogie_configs: Array[BogieConfig] = []


## Номер узла по роли "unit_<n>"; -1, если роль другая
static func parse_unit(role: String) -> int:
	_init_re()
	var m := _unit_re.search(role)
	return int(m.get_string(1)) if m != null else -1


## [номер узла, номер колеса] по роли "wheel_<n>_<k>"; пустой массив, если роль другая
static func parse_wheel(role: String) -> Array[int]:
	_init_re()
	var out: Array[int] = []
	var m := _wheel_re.search(role)
	if m != null:
		out.append(int(m.get_string(1)))
		out.append(int(m.get_string(2)))
	return out


static func _init_re() -> void:
	if _unit_re == null:
		_unit_re = RegEx.create_from_string("^unit_(\\d+)$")
		_wheel_re = RegEx.create_from_string("^wheel_(\\d+)_(\\d+)$")


## Роль узла: meta "role" или glTF extras (как PartRegistry). Пустая строка, если роли нет
static func role_of(n: Node) -> String:
	if n.has_meta(&"role"):
		return str(n.get_meta(&"role"))
	if n.has_meta(&"extras"):
		var ex: Variant = n.get_meta(&"extras")
		if ex is Dictionary and ex.has("role"):
			return str(ex["role"])
	return ""


## Радиус круга катания из glTF extras {"radius": ...} (или meta "radius"). 0, если не задан
static func radius_of(n: Node) -> float:
	if n.has_meta(&"extras"):
		var ex: Variant = n.get_meta(&"extras")
		if ex is Dictionary and ex.has("radius"):
			return float(ex["radius"])
	if n.has_meta(&"radius"):
		return float(n.get_meta(&"radius"))
	return 0.0


## Находит в root узлы unit_<n> и колёса wheel_<n>_<k>, строит BogieConfig, вынимает узлы из дерева (remove_child).
## null, если в модели нет ни одного узла unit_<n> с колёсами. owner_name только для сообщений
static func extract(root: Node3D, owner_name := "") -> ModelRig:
	var unit_nodes := {}      # номер -> Node3D
	var wheel_list: Array[Dictionary] = []   # {node, unit, k}
	_scan(root, unit_nodes, wheel_list, owner_name)
	if unit_nodes.is_empty():
		return null

	var rig := ModelRig.new()
	var numbers: Array = unit_nodes.keys()
	numbers.sort()
	for n in numbers:
		var u := Unit.new()
		u.number = n
		u.node = unit_nodes[n]
		var mine: Array[Dictionary] = []
		for w in wheel_list:
			if w.unit == n:
				mine.append(w)
		mine.sort_custom(func(a, b): return a.k < b.k)
		for w in mine:
			var node: Node3D = w.node
			if not u.node.is_ancestor_of(node):
				push_warning("[ModelRig] %s: колесо '%s' (wheel_%d_%d) не внутри узла unit_%d, пропущено" % [owner_name, node.name, n, w.k, n])
				continue
			var r := radius_of(node)
			if r <= 0.0:
				push_warning("[ModelRig] %s: у колеса '%s' нет extras radius (число больше 0), пропущено" % [owner_name, node.name])
				continue
			var wh := Wheel.new()
			wh.node = node
			wh.role = StringName(role_of(node))
			wh.radius = r
			wh.meshes = _meshes_of(node)
			u.wheels.append(wh)
		if u.wheels.is_empty():
			push_warning("[ModelRig] %s: у узла unit_%d нет пригодных колёс, узел пропущен" % [owner_name, n])
			continue
		rig.units.append(u)
	if rig.units.is_empty():
		return null

	for u in rig.units:
		rig._finish_unit(u, root, owner_name)
	for u in rig.units:
		# Вынимаем из кузова: дальше узел ставит C_TrainVisual
		u.node.get_parent().remove_child(u.node)
	return rig


static func _scan(n: Node, unit_nodes: Dictionary, wheel_list: Array[Dictionary], owner_name: String) -> void:
	for c in n.get_children():
		if c is Node3D:
			var role := role_of(c)
			var un := parse_unit(role)
			if un >= 0:
				if unit_nodes.has(un):
					push_warning("[ModelRig] %s: роль unit_%d у двух узлов, беру первый" % [owner_name, un])
				else:
					unit_nodes[un] = c
			else:
				var wr := parse_wheel(role)
				if not wr.is_empty():
					wheel_list.append({"node": c, "unit": wr[0], "k": wr[1]})
		_scan(c, unit_nodes, wheel_list, owner_name)


## Положение узла относительно root (цепочка transform родителей, без transform самого root)
static func xform_in(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


static func _meshes_of(node: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for m in node.find_children("*", "MeshInstance3D", true, false):
		out.append(m as MeshInstance3D)
	return out


## Считает положение узла и осей, выстраивает колёса прямыми детьми узла, собирает BogieConfig
func _finish_unit(u: Unit, root: Node3D, owner_name: String) -> void:
	var tag := "[ModelRig] %s: unit_%d" % [owner_name, u.number]
	if not u.node.basis.is_equal_approx(Basis.IDENTITY):
		push_warning("%s: у узла поворот или масштаб, они сброшены (в Blender узел без поворота и масштаба)" % tag)
	var lo := INF
	var hi := -INF
	var r_sum := 0.0
	for w in u.wheels:
		var rel := xform_in(w.node, u.node)
		if w.node.get_parent() != u.node:
			# колесо глубже в иерархии: делаем его прямым ребёнком узла с тем же положением
			w.node.get_parent().remove_child(w.node)
			u.node.add_child(w.node)
			w.node.transform = rel
		if not w.node.basis.is_equal_approx(Basis.IDENTITY):
			push_warning("%s: у колеса '%s' поворот или масштаб, ось вращения может не совпасть с осью колёсной пары" % [tag, w.node.name])
		w.z = rel.origin.z
		lo = minf(lo, w.z)
		hi = maxf(hi, w.z)
		r_sum += w.radius
	u.radius = r_sum / u.wheels.size()
	for w in u.wheels:
		if absf(w.radius - u.radius) > 0.01 * u.radius:
			push_warning("%s: радиусы колёс узла различаются (%.3f и %.3f): один узел один радиус, разведите по узлам" % [tag, w.radius, u.radius])
			break
	# центр узла посередине между крайними осями: так считает C_Bogie (хорда по крайним осям)
	var mid := (lo + hi) * 0.5
	if absf(mid) > 0.02:
		push_warning("%s: центр узла не посередине между крайними осями (на %.3f), узел сдвинут на середину" % [tag, mid])
	for w in u.wheels:
		w.z -= mid
		w.node.position.z -= mid
	u.z = xform_in(u.node, root).origin.z + mid

	var cfg := BogieConfig.new()
	cfg.b_offset_z = u.z
	var offsets := PackedFloat32Array()
	for w in u.wheels:
		offsets.append(w.z)
	cfg.axle_offsets = offsets
	cfg.wheel_pair_position = Vector3(0.0, u.radius, (hi - lo) * 0.5)
	u.config = cfg
	bogie_configs.append(cfg)


## Датчик рельса: копия RayCast3D стандартной тележки (те же слои и длина)
static func make_ray() -> RayCast3D:
	var tmp := RAY_SOURCE.instantiate()
	var ray := (tmp.get_node("RayCast3D") as RayCast3D).duplicate() as RayCast3D
	tmp.free()
	return ray
