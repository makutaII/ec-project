class_name PowerTerminal extends Area3D

#####################
## Клемма (ATTN_10 §10.5.7, D4)
#####################
## Точка подключения провода на корпусе пульта или у клипа. Область на слое `power` (ловит луч мыши),
## маленький меш для вида. Провод держит ссылку `wire`, клемма принимает не больше одного.
## Роль задаёт направление: провод всегда соединяет «выше по току» (SRC, DEV_OUT) с «ниже по току» (SINK, DEV_IN).
## Устройства коммутации (D5) задают `link_fn`: какие клеммы устройства соединены внутри и с какой чётностью.

enum Kind { TRACK, SUPPLY, ACCESSORY, SIGNAL }
enum Role { SRC, SINK, DEV_IN, DEV_OUT }

const RADIUS := 0.45

var kind: Kind = Kind.TRACK
var role: Role = Role.SRC
## +1 или -1: маркировка клеммы (цвет), на расчёт не влияет: чётность меняет «скрутка» провода
var polarity := 1
## Метка вывода источника (у SRC), иначе 0
var output_label := 0
## Стабильный ключ клеммы внутри хозяина: "out_1", "clip", "in_a"
var key: StringName = &""
## Сущность-хозяин
var host: Entity
## Провода на клемме (C_Wire). Клемма выше по току (вывод, выход устройства) принимает несколько проводов, как винтовая клемма,
## ниже по току (клип, вход устройства) один
var wires: Array = []
## Внутренняя проводимость устройства: Callable(terminal) -> Array[{"terminal": PowerTerminal, "flip": bool}]
var link_fn: Callable = Callable()

var _mesh: MeshInstance3D


static func create(parent: Node3D, owner_entity: Entity, term_kind: Kind, term_role: Role, term_key: StringName, local_pos: Vector3, term_polarity := 1) -> PowerTerminal:
	var t := PowerTerminal.new()
	t.name = "Terminal_" + String(term_key)
	t.kind = term_kind
	t.role = term_role
	t.key = term_key
	t.host = owner_entity
	t.polarity = term_polarity
	t.position = local_pos
	t.collision_layer = Global.active_layers(["power"])
	t.collision_mask = 0
	t.monitoring = false
	var shape := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = RADIUS
	shape.shape = sph
	t.add_child(shape)
	t._mesh = MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = RADIUS * 0.7
	m.height = RADIUS * 1.4
	t._mesh.mesh = m
	t.add_child(t._mesh)
	t.set_highlight(false)
	t.add_to_group(&"power_terminal")
	parent.add_child(t)
	return t


func is_upstream() -> bool:
	return role == Role.SRC or role == Role.DEV_OUT


func is_free() -> bool:
	_prune()
	return is_upstream() or wires.is_empty()


func _prune() -> void:
	wires = wires.filter(func(w): return is_instance_valid(w))


func add_wire(w: Object) -> void:
	_prune()
	if not wires.has(w):
		wires.append(w)


func remove_wire(w: Object) -> void:
	wires.erase(w)


func has_wire() -> bool:
	_prune()
	return not wires.is_empty()


## Можно ли соединить две клеммы: тот же тип, разные, обе свободны, одна выше по току, другая ниже
static func can_connect(a: PowerTerminal, b: PowerTerminal) -> bool:
	if a == null or b == null or a == b:
		return false
	if a.kind != b.kind:
		return false
	if a.host != null and a.host == b.host:
		return false
	if not a.is_free() or not b.is_free():
		return false
	return a.is_upstream() != b.is_upstream()


## Причина отказа для подсказки игроку, пусто если можно
static func refuse_reason(a: PowerTerminal, b: PowerTerminal) -> String:
	if a == null or b == null or a == b:
		return "нужна вторая клемма"
	if a.kind != b.kind:
		return "разные типы клемм"
	if not a.is_free() or not b.is_free():
		return "на клемме уже есть провод"
	if a.is_upstream() == b.is_upstream():
		return "провод идёт от источника к потребителю, а не между двумя одинаковыми клеммами"
	if not can_connect(a, b):
		return "эти клеммы соединить нельзя"
	return ""


## Внутренние связи клеммы через устройство: [{"terminal", "flip"}]
func links() -> Array:
	if link_fn.is_valid():
		return link_fn.call(self)
	return []


func set_highlight(on: bool) -> void:
	if _mesh == null:
		return
	var mat := StandardMaterial3D.new()
	var base := Color(0.9, 0.15, 0.1) if polarity > 0 else Color(0.1, 0.1, 0.1)
	if kind == Kind.ACCESSORY:   # XX claude-wire W8: шина 12 В отличается от рельсовой проводки
		base = Color(0.2, 0.5, 1.0)
	mat.albedo_color = Color(1.0, 0.85, 0.2) if on else base
	mat.emission_enabled = on
	mat.emission = Color(1.0, 0.85, 0.2)
	_mesh.material_override = mat


func world_pos() -> Vector3:
	return global_position
