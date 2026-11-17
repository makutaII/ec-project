class_name RoomGlb extends RefCounted

########################
## Комната из .glb: роли и свойства Blender -> объекты Godot (ATTN_25 §25.8, RM8)
########################
## Blender-скрипт tools/blender/ec_room_tools.py ставит на объекты Custom Properties (role, ctl, light_kind...). Godot-импортёр кладёт их
## в метаданные узла "extras" (Dictionary). RoomRoot.import_glb() один раз прогоняет сцену через run(): служебные узлы превращаются
## в настоящие (прокси collider -> StaticBody3D, якоря light -> SpotLight3D / OmniLight3D), прокси-коробки window / door / camera_bounds /
## room_volume читаются в числа карточки и удаляются. Узлы сцены Godot (не из .glb) не трогаются: они работают как раньше.
## Все числа в см, оси Godot (север = -Z), как в файле: 1 единица Blender = 1 см, root_scale импорта 1.0.
## Нарушения не бросают, а попадают в warnings.

const GROUP_ROLES: Array[StringName] = [&"floor", &"shell", &"ceiling", &"decor_t1", &"decor_t2", &"decor_t3", &"fake_ao"]
const LIGHTS := "Lights"
const FLOOR_DEFAULT := -50.0
## Параметры ламп те же, что у ламп RoomBuilder (в см стандартные значения дают полосы на стенах)
const LAMP_BIAS := 0.6
const LAMP_NORMAL_BIAS := 3.0
const LAMP_SOFT := 15.0

## В сцене найдена хотя бы одна роль из .glb
var present := false
## Роль группы -> узлы с этой ролью (floor, shell, ceiling, decor_t1..3, fake_ao). Всё под узлом роли принадлежит группе
var groups := {}
## Лампочки: [{node: Node3D, of: StringName}], свечение привязывает реестр к управлению лампы
var bulbs: Array[Dictionary] = []
## Числа для карточки RoomConfig: floor_y, size, bounds, window, door, daylight (ключей нет, если исходных прокси нет)
var card := {}
## Вектор луча окна window_sun (мировая ось Godot, нормализован); ZERO: роли нет. Солнцем управляет GFX, это только данные
var sun_dir := Vector3.ZERO
## Центр стола table_origin (по роли); null-вектор NAN: роли нет
var table_origin := Vector3(NAN, NAN, NAN)
var warnings := PackedStringArray()
var lights: Array[Light3D] = []


## Метаданные Blender узла (пустой словарь, если их нет)
static func extras(n: Node) -> Dictionary:
	if n == null:
		return {}
	var v: Variant = n.get_meta("extras", null)
	if v is Dictionary:
		return v
	return {}


static func role_of(n: Node) -> StringName:
	var r: Variant = extras(n).get("role", "")
	return StringName(str(r))


## Преобразование n относительно root (узлы могут быть вне дерева)
static func rel_transform(n: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var p := n
	while p != null and p != root:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


## AABB меша в системе root
static func mesh_aabb(mi: MeshInstance3D, root: Node) -> AABB:
	return rel_transform(mi, root) * mi.get_aabb()


## Свечение лампочки: пока лампа включена, emission включён (если цвета эмиссии нет, берётся цвет материала)
static func set_glow(n: Node, on: bool) -> void:
	if not is_instance_valid(n):
		return
	for mi in _meshes(n):
		for s in mi.get_surface_override_material_count():
			var m := mi.get_surface_override_material(s) as StandardMaterial3D
			if m == null:
				continue
			if on and m.emission.get_luminance() < 0.001:
				m.emission = m.albedo_color
			m.emission_enabled = on


## Один прогон по сцене root (RoomRoot). Повторный вызов даёт то же (узлы уже заменены), но RoomRoot зовёт его один раз
func run(root: Node3D) -> void:
	var found := {}   # роль -> Array[Node]
	_scan(root, root, found)
	present = not found.is_empty()
	if not present:
		return
	for r in GROUP_ROLES:
		if found.has(r):
			groups[r] = found[r]
	_floor(root)
	_volume(root, found)
	_openings(root, found)
	_bounds(root, found)
	_origin_and_sun(root, found)
	_colliders(found)
	_lights(root, found)
	_bulbs(found)
	for n in found.get(&"sky_card", []):
		(n as Node).add_to_group(&"gfx_sky")
	# Проксям больше не нужны меши: числа прочитаны выше
	for r in [&"window", &"door", &"camera_bounds", &"room_volume"]:
		for n in found.get(r, []):
			_drop(n)


## Расхождения карточки cfg и сцены (строки для вкладки «Проверка»). Пусто: числа сходятся. Сравниваются только числа, которые есть в сцене
func diff(cfg: RoomConfig) -> PackedStringArray:
	var out := PackedStringArray()
	if not present or cfg == null:
		return out
	if card.has("floor_y") and absf(cfg.floor_y - float(card["floor_y"])) > 0.5:
		out.append("floor_y: в карточке %.1f, в сцене %.1f" % [cfg.floor_y, card["floor_y"]])
	if card.has("size"):
		var sz: Vector3 = card["size"]
		if (cfg.size - sz).length() > 0.5:
			out.append("size: в карточке %s, в сцене %s" % [cfg.size, sz])
	if card.has("bounds"):
		var b: AABB = card["bounds"]
		if (cfg.bounds.position - b.position).length() > 0.5 or (cfg.bounds.size - b.size).length() > 0.5:
			out.append("bounds: в карточке %s, в сцене %s" % [cfg.bounds, b])
	for r in [&"window", &"door"]:
		var have: Dictionary = cfg.window if r == &"window" else cfg.door
		var want: Dictionary = card.get(String(r), {})
		if want.is_empty() != have.is_empty():
			out.append("%s: в карточке %s, в сцене %s" % [r, "есть" if not have.is_empty() else "нет", "есть" if not want.is_empty() else "нет"])
			continue
		for k in want:
			if absf(float(have.get(k, 0.0)) - float(want[k])) > 0.5:
				out.append("%s.%s: в карточке %s, в сцене %s" % [r, k, have.get(k, "-"), want[k]])
	if card.has("daylight") and cfg.daylight != card["daylight"]:
		out.append("daylight: в карточке %s, в сцене %s" % [cfg.daylight, card["daylight"]])
	return out


## Записать числа сцены в карточку cfg (floor_y, size, bounds, window, door, daylight); чего в сцене нет, то не меняется
func apply_to(cfg: RoomConfig) -> void:
	if not present or cfg == null:
		return
	if card.has("floor_y"):
		cfg.floor_y = card["floor_y"]
	if card.has("size"):
		cfg.size = card["size"]
	if card.has("bounds"):
		cfg.bounds = card["bounds"]
	var w: Dictionary = card.get("window", {})
	var d: Dictionary = card.get("door", {})
	cfg.window = w.duplicate()
	cfg.door = d.duplicate()
	if card.has("daylight"):
		cfg.daylight = card["daylight"]


func _scan(n: Node, root: Node, out: Dictionary) -> void:
	for c in n.get_children():
		var r := role_of(c)
		if r != &"":
			if not out.has(r):
				out[r] = []
			(out[r] as Array).append(c)
		_scan(c, root, out)


func _floor(root: Node3D) -> void:
	if not groups.has(&"floor"):
		warnings.append("в сцене нет роли floor: floor_y = %.0f по умолчанию" % FLOOR_DEFAULT)
		card["floor_y"] = FLOOR_DEFAULT
		return
	var top := -INF
	for g in groups[&"floor"]:
		for mi in _meshes(g):
			var b := mesh_aabb(mi, root)
			top = maxf(top, b.end.y)
	if is_inf(top):
		warnings.append("пол (роль floor) без мешей: floor_y = %.0f по умолчанию" % FLOOR_DEFAULT)
		top = FLOOR_DEFAULT
	card["floor_y"] = snappedf(top, 0.01)


func _first_box(found: Dictionary, role: StringName, root: Node3D) -> Variant:
	var lst: Array = found.get(role, [])
	if lst.is_empty():
		return null
	lst = lst.duplicate()
	lst.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
	if lst.size() > 1 and role != &"collider":
		warnings.append("несколько прокси %s: в карточку идёт первый по имени ('%s')" % [role, (lst[0] as Node).name])
	var mi := lst[0] as MeshInstance3D
	if mi == null or mi.mesh == null:
		warnings.append("прокси %s '%s' не меш: числа не прочитаны" % [role, (lst[0] as Node).name])
		return null
	return mesh_aabb(mi, root)


func _volume(root: Node3D, found: Dictionary) -> void:
	var b: Variant = _first_box(found, &"room_volume", root)
	if b != null:
		var bb: AABB = b
		card["size"] = bb.size.snappedf(0.01)
		card["_volume"] = bb


func _bounds(root: Node3D, found: Dictionary) -> void:
	var b: Variant = _first_box(found, &"camera_bounds", root)
	if b != null:
		var bb: AABB = b
		card["bounds"] = AABB(bb.position.snappedf(0.01), bb.size.snappedf(0.01))


func _openings(root: Node3D, found: Dictionary) -> void:
	var floor_y: float = card.get("floor_y", FLOOR_DEFAULT)
	var vol: AABB = card.get("_volume", AABB())
	var have_vol: bool = card.has("_volume")
	for r in [&"window", &"door"]:
		var b: Variant = _first_box(found, r, root)
		if b == null:
			continue
		var bb: AABB = b
		if bb.size.z > bb.size.x:
			warnings.append("%s в боковой стене (толщина по X): карточка хранит только проём в северной или южной стене" % r)
			continue
		var is_north := (not have_vol) or bb.get_center().z <= vol.get_center().z
		if (r == &"window") != is_north:
			warnings.append("%s в %s стене: карточка ждёт %s в %s" % [r, "северной" if is_north else "южной", r, "северной" if r == &"window" else "южной"])
		card[String(r)] = {"x": snappedf(bb.get_center().x, 0.01), "w": snappedf(bb.size.x, 0.01),
				"sill": snappedf(bb.position.y - floor_y, 0.01), "h": snappedf(bb.size.y, 0.01)}
	card.erase("_volume")
	card["daylight"] = found.has(&"window")


func _origin_and_sun(root: Node3D, found: Dictionary) -> void:
	for n in found.get(&"table_origin", []):
		table_origin = rel_transform(n, root).origin
		_drop(n)
		break
	for n in found.get(&"window_sun", []):
		# Стрелка пустышки Blender (локальная +Z) после экспорта это локальная +Y узла
		sun_dir = (rel_transform(n, root).basis * Vector3.UP).normalized()
		_drop(n)
		break


## Прокси collider -> StaticBody3D (слой room, маска 0) с BoxShape3D по границам меша
func _colliders(found: Dictionary) -> void:
	for n in found.get(&"collider", []):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			warnings.append("collider '%s' не меш: коллизии нет" % n.name)
			continue
		var parent := mi.get_parent()
		var idx := mi.get_index()
		var nm := mi.name
		var local := mi.transform
		var box := mi.get_aabb()
		var ex := extras(mi)
		var sc := local.basis.get_scale().abs()
		var body := StaticBody3D.new()
		body.transform = Transform3D(local.basis.orthonormalized(), local.origin)
		body.collision_layer = Global.active_layers(["room"])
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = box.size * sc
		cs.shape = bs
		cs.position = box.get_center() * sc
		body.add_child(cs)
		body.set_meta("extras", ex)
		parent.remove_child(mi)
		mi.free()
		parent.add_child(body)
		body.name = nm
		parent.move_child(body, idx)


## Якоря light -> настоящие лампы в узле Lights корня (RoomBuilder уносит его из комнаты, кнопка «Комната» свет не гасит)
func _lights(root: Node3D, found: Dictionary) -> void:
	var anchors: Array = found.get(&"light", [])
	if anchors.is_empty():
		return
	var holder := root.get_node_or_null(LIGHTS) as Node3D
	if holder == null:
		holder = Node3D.new()
		holder.name = LIGHTS
		root.add_child(holder)
	for a in anchors:
		var node := a as Node3D
		if node == null:
			continue
		var ex := extras(node)
		var kind := str(ex.get("light_kind", ""))
		if kind != "spot" and kind != "omni":
			warnings.append("якорь света '%s': light_kind '%s', нужно spot или omni, лампа не создана" % [node.name, kind])
			continue
		var rng := float(ex.get("light_range", 0.0))
		var l: Light3D
		if kind == "spot":
			var s := SpotLight3D.new()
			s.spot_range = rng
			s.spot_angle = float(ex.get("light_angle", 60.0))
			l = s
		else:
			var o := OmniLight3D.new()
			o.omni_range = rng
			l = o
		var t := rel_transform(node, root)
		# Стрелка якоря (локальная +Y после экспорта) -> направление света Godot (-Z)
		l.transform = Transform3D(t.basis.orthonormalized() * Basis(Vector3.RIGHT, PI * 0.5), t.origin)
		l.light_energy = float(ex.get("light_energy", 1.0))
		l.light_color = Color.html(str(ex.get("light_color", "#ffffff")))
		l.shadow_enabled = float(ex.get("light_shadow", 0.0)) > 0.5
		l.shadow_bias = LAMP_BIAS
		l.shadow_normal_bias = LAMP_NORMAL_BIAS
		l.light_size = LAMP_SOFT
		l.set_meta("extras", ex)
		var nm := node.name
		var parent := node.get_parent()
		parent.remove_child(node)
		node.free()
		holder.add_child(l)
		l.name = nm
		lights.append(l)


## Лампочки: у каждой свои материалы (иначе свечение одной зажгло бы все с тем же материалом)
func _bulbs(found: Dictionary) -> void:
	for n in found.get(&"bulb", []):
		for mi in _meshes(n):
			for s in mi.mesh.get_surface_count():
				var m := mi.get_active_material(s)
				if m != null:
					mi.set_surface_override_material(s, m.duplicate())
		bulbs.append({"node": n, "of": StringName(str(extras(n).get("bulb_of", "")))})


func _drop(n: Node) -> void:
	if is_instance_valid(n) and n.get_parent() != null:
		n.get_parent().remove_child(n)
		n.free()


static func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n as MeshInstance3D)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
