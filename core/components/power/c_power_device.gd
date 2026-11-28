class_name C_PowerDevice extends C_Visual

#####################
## Устройство коммутации (ATTN_10 §10.5.7, D5): основа селектора блоков, реверсора и предохранителя
#####################
## Коробка из примитивов с клеммами на лицевой грани и одной областью управления на слое handles
## (SelectTool при нажатии шлёт `on_lever_pressed`, как у рычага стрелки и ручек пульта).
## Наследник задаёт клеммы (`_build_terminals`), положения (`positions`, `pos_text`) и внутренние связи (`_links_of`).
## Клеммы: DEV_IN принимает один провод (ниже по току), DEV_OUT несколько (выше по току для следующего потребителя).
## Состояние `pos` и наследника лежит в сейве сущности.

const W := 5.0
const H := 1.2
const DEPTH := 3.0

var pos := 0

var _body: StaticBody3D
var _ctl: StaticBody3D
var _knob: MeshInstance3D
var _label: Label3D
var _terms: Dictionary = {}   # key -> PowerTerminal


# --- для наследников ---

## Подпись устройства
func title() -> String:
	return "Коммутатор"


## Сколько положений у переключателя (0 если переключателя нет)
func positions() -> int:
	return 2


func pos_text(p: int) -> String:
	return str(p)


## Создать клеммы через `_add_term`
func _build_terminals() -> void:
	pass


## Внутренняя проводимость: клемма -> [{"terminal", "flip", "via"}]
func _links_of(_t: PowerTerminal) -> Array:
	return []


## Дополнительный текст состояния на подписи и во вкладке
func state_text() -> String:
	return pos_text(pos)


## Нажатие на область управления (по умолчанию переключатель: следующее положение)
func activate() -> void:
	var n := positions()
	if n > 0:
		set_pos((pos + 1) % n)


# --- общее ---

func on_added() -> void:
	name = "C_PowerDevice"
	add_to_group(&"power_device")
	_build()
	_collect_meshes()


func _build() -> void:
	instance = Node3D.new()
	instance.name = "PowerDevice"
	entity.add_child(instance)
	_body = StaticBody3D.new()
	_body.name = "Body"
	_body.collision_layer = Global.active_layers(["power"])
	_body.collision_mask = 0
	instance.add_child(_body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(W, H, DEPTH)
	shape.shape = box
	shape.position = Vector3(0, H * 0.5, 0)
	_body.add_child(shape)
	_box(_body, Vector3(W, H, DEPTH), Vector3(0, H * 0.5, 0), Color(0.3, 0.3, 0.34))

	_ctl = StaticBody3D.new()
	_ctl.collision_layer = Global.active_layers(["handles"])
	_ctl.collision_mask = 0
	_ctl.position = Vector3(0, H, -0.5)
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.7
	cyl.height = 0.6
	cs.shape = cyl
	cs.position = Vector3(0, 0.3, 0)
	_ctl.add_child(cs)
	instance.add_child(_ctl)
	_knob = MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = 0.6
	m.bottom_radius = 0.6
	m.height = 0.5
	_knob.mesh = m
	_knob.position = Vector3(0, 0.25, 0)
	_knob.material_override = StandardMaterial3D.new()
	_ctl.add_child(_knob)

	_label = Label3D.new()
	_label.pixel_size = 0.02
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.position = Vector3(0, H + 1.6, 0)
	instance.add_child(_label)
	_build_terminals()
	_refresh()


func _box(parent: Node3D, size: Vector3, p: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = p
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	parent.add_child(mi)
	return mi


## XX claude-wire W8: вид клемм прибора (TRACK: рельсовая проводка; ACCESSORY: шина 12 В у C_BusSource и клеммника в режиме шины)
var term_kind: PowerTerminal.Kind = PowerTerminal.Kind.TRACK


func _add_term(key: StringName, role: PowerTerminal.Role, x: float) -> PowerTerminal:
	var t := PowerTerminal.create(instance, entity, term_kind, role, key, Vector3(x, 0.6, DEPTH * 0.5 + 0.2))
	t.link_fn = Callable(self, "_links_of")
	_terms[key] = t
	return t


func term(key: StringName) -> PowerTerminal:
	return _terms.get(key)


func on_select_layer(data: Dictionary) -> void:
	if _body == null:
		return
	_body.collision_layer = Global.active_layers(["ghost"]) if data.get("enabled", false) else Global.active_layers(["power"])


## Призрак стройки не устройство: клеммы выключаем
func on_component_added(type: Script) -> void:
	super(type)
	if type == C_Ghost:
		remove_from_group(&"power_device")
		for t: PowerTerminal in _terms.values():
			t.collision_layer = 0
			t.remove_from_group(&"power_terminal")


func on_lever_pressed(data: Dictionary) -> void:
	if entity.has_comp(C_Ghost) or data.get("collider") != _ctl:
		return
	activate()
	data.consumed = true


func set_pos(p: int) -> void:
	var n := positions()
	if n <= 0:
		return
	p = clampi(p, 0, n - 1)
	if p == pos:
		return
	pos = p
	_changed()


## Состояние изменилось: обновить вид и пересчитать проводку
func _changed() -> void:
	_refresh()
	PGM.request_recalculate()


func sync_terminals() -> void:
	pass


func _refresh() -> void:
	if _label == null:
		return
	_label.text = "%s\n%s" % [title(), state_text()]
	var c := _knob_color()
	var mat := _knob.material_override as StandardMaterial3D
	mat.albedo_color = c
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = 0.4
	var n := positions()
	if n > 1:
		_ctl.rotation_degrees.y = -90.0 * pos / float(n - 1) + 45.0


func _knob_color() -> Color:
	return Color(0.8, 0.8, 0.85)


## XX claude-wire W7: номер провода в серии автопроводки этого прибора (соседние идут со сдвигом)
var _lane := 0


## Автопроводка (D5): входы к ближайшим выводам пультов (разные входы к разным выводам), выход к клипам с метками этих выводов.
## Возвращает число созданных проводов
func autowire(parent: Node) -> int:
	get_tree().call_group(&"power_device", "sync_terminals")
	_lane = 0
	var made := 0
	var used: Dictionary = {}   # метка -> true: вывод уже занят входом этого устройства
	var feeds: Dictionary = {}  # метки, чьи клипы нужно запитать выходом
	var outs: Array[PowerTerminal] = []
	for t: PowerTerminal in _terms.values():
		if t.role == PowerTerminal.Role.DEV_OUT:
			outs.append(t)
			continue
		if t.has_wire():
			var up := _upstream_label(t)
			if up > 0:
				used[up] = true
				feeds[up] = true
			continue
		var best: PowerTerminal = null
		var best_d := INF
		for c in get_tree().get_nodes_in_group(&"power_terminal"):
			var s := c as PowerTerminal
			if s == null or s.role != PowerTerminal.Role.SRC or s.output_label <= 0 or used.has(s.output_label) or s.host == entity:
				continue
			var d := s.world_pos().distance_to(t.world_pos())
			if d < best_d:
				best_d = d
				best = s
		if best != null and _connect(parent, best, t):
			made += 1
			used[best.output_label] = true
			feeds[best.output_label] = true
	for o in outs:
		for clip in PGM.active_clips:
			if not is_instance_valid(clip) or clip.terminal == null or not is_instance_valid(clip.terminal):
				continue
			if not feeds.has(clip.net_id) or clip.wired or not clip.terminal.is_free():
				continue
			if _connect(parent, o, clip.terminal):
				made += 1
	return made


func _upstream_label(t: PowerTerminal) -> int:
	for w in t.wires:
		var cw := w as C_Wire
		if cw == null:
			continue
		var other: PowerTerminal = cw.a if cw.b == t else cw.b
		if is_instance_valid(other) and other.role == PowerTerminal.Role.SRC:
			return other.output_label
	return 0


func _connect(parent: Node, a: PowerTerminal, b: PowerTerminal) -> bool:
	# XX claude-wire W7: провод лежит на поверхностях, под столом через ввод и по нижней полке (AutoWire), не дугой по воздуху
	var ok := C_Wire.create_wire(parent, a, b, AutoWire.points(a, b, _lane)) != null
	if ok:
		_lane += 1
	return ok


# ------ СЕЙВ ------

func save_data() -> Dictionary:
	return {"pos": pos}


func load_data(d: Dictionary) -> void:
	pos = clampi(int(d.get("pos", 0)), 0, maxi(positions() - 1, 0))
	_refresh()
	PGM.request_recalculate()
