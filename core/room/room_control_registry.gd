class_name RoomControlRegistry extends RefCounted

########################
## Реестр управляемых объектов комнаты (ATTN_25 §25.6, RM5)
########################
## Собирает описания RoomControlDef из сцены комнаты из двух источников: метки RoomControl (сцена Godot) и свойства объектов .glb
## (extras: ctl, ctl_id, ctl_title, ctl_scope, ctl_default, ctl_group, bulb_of; ATTN_25 §25.7.3). Разбор .glb (RoomRoot.import_glb) идёт первым.
## Читают реестр вкладка «Объекты» Room Studio и (RM6) карточки Observe → Light. Нарушения правил не бросают: собираются
## в warnings (повтор id, объект не того типа, механизм без анимации), остальное продолжает работать.
## Собирать надо до RoomRoot.take_lights(): метки лежат в ветке ламп.

var defs: Array[RoomControlDef] = []
var warnings := PackedStringArray()

var _by_key := {}   # StringName -> RoomControlDef (ключ: group, иначе id)
var _id_key := {}   # StringName ctl_id -> ключ управления (для лампочек bulb_of)


## Все метки RoomControl под root (включая сам root) -> реестр. Значения приводятся к default_value
static func collect(root: Node, owner_name := "") -> RoomControlRegistry:
	var reg := RoomControlRegistry.new()
	if root == null:
		return reg
	var on := owner_name if owner_name != "" else String(root.name)
	var rr := root as RoomRoot
	if rr != null:
		rr.import_glb()
		reg.warnings.append_array(rr.glb.warnings)
	reg._walk(root, on, root)
	if rr != null:
		reg._bind_bulbs(rr.glb)
	for d in reg.defs:
		d.reset()
	return reg


func by_id(id: StringName) -> RoomControlDef:
	return _by_key.get(id) as RoomControlDef


## Управления с этим scope (OBSERVE: для Observe → Light; STUDIO: только студия)
func for_scope(scope: RoomControl.Scope) -> Array[RoomControlDef]:
	var out: Array[RoomControlDef] = []
	for d in defs:
		if d.scope == scope:
			out.append(d)
	return out


## Шаг механизмов (владелец зовёт каждый кадр, пока что-то движется)
func tick(dt: float) -> void:
	for d in defs:
		d.tick(dt)


func is_moving() -> bool:
	for d in defs:
		if d.is_moving():
			return true
	return false


## Всё в начальные значения
func reset() -> void:
	for d in defs:
		d.reset()


func _walk(n: Node, owner_name: String, root: Node) -> void:
	if n is RoomControl:
		var c := n as RoomControl
		_add_def(c.get_parent(), c.id, c.kind, c.scope, c.title, c.default_value, c.group, c.mechanism, owner_name, null)
	var ex := RoomGlb.extras(n)
	if ex.has("ctl") or ex.has("ctl_id"):
		_add_glb(n, ex, owner_name, root)
	for ch in n.get_children():
		_walk(ch, owner_name, root)


## Управление из свойств .glb. Объект с ctl_id, но без ctl, не управляется (замечание)
func _add_glb(n: Node, ex: Dictionary, owner_name: String, root: Node) -> void:
	var id := StringName(str(ex.get("ctl_id", "")))
	if not ex.has("ctl"):
		warnings.append("у '%s' есть ctl_id, но нет ctl: объект не управляется" % n.name)
		return
	var kind := RoomControl.Kind.TOGGLE
	match str(ex["ctl"]):
		"toggle":
			kind = RoomControl.Kind.TOGGLE
		"slider":
			kind = RoomControl.Kind.SLIDER
		"mech":
			kind = RoomControl.Kind.MECH
		_:
			warnings.append("у '%s' ctl = '%s': нужно toggle, slider или mech" % [n.name, ex["ctl"]])
			return
	var scope := RoomControl.Scope.OBSERVE if str(ex.get("ctl_scope", "studio")) == "observe" else RoomControl.Scope.STUDIO
	var def_v := float(ex.get("ctl_default", 0.0 if kind == RoomControl.Kind.MECH else 1.0))
	var cfg: MechanismConfig = null
	if kind == RoomControl.Kind.MECH:
		cfg = MechanismConfig.new()
		cfg.id = id
		cfg.title = str(ex.get("ctl_title", id))
		cfg.actuator = MechanismConfig.Actuator.ANIM
	_add_def(n, id, kind, scope, str(ex.get("ctl_title", "")), def_v, StringName(str(ex.get("ctl_group", ""))), cfg, owner_name, root)
	_id_key[id] = StringName(str(ex.get("ctl_group", ""))) if str(ex.get("ctl_group", "")) != "" else id


## Лампочки .glb: свечение следует за управлением лампы bulb_of (по ctl_id или группе)
func _bind_bulbs(glb: RoomGlb) -> void:
	for b in glb.bulbs:
		var key: StringName = b["of"]
		if key == &"":
			warnings.append("лампочка '%s' без bulb_of: не светится" % (b["node"] as Node).name)
			continue
		var d := _by_key.get(_id_key.get(key, key)) as RoomControlDef
		if d == null:
			warnings.append("лампочка '%s': управления '%s' нет (bulb_of должен совпадать с ctl_id лампы)" % [(b["node"] as Node).name, key])
			continue
		d.bulbs.append(b["node"])


func _add_def(target: Node, id: StringName, kind: RoomControl.Kind, scope: RoomControl.Scope, title: String, default_value: float,
		group: StringName, cfg: MechanismConfig, owner_name: String, search_root: Node) -> void:
	var key: StringName = group if group != &"" else id
	if key == &"":
		warnings.append("метка RoomControl у '%s' без id" % target.name)
		return
	var d := _by_key.get(key) as RoomControlDef
	if d == null:
		d = RoomControlDef.new()
		d.id = key
		d.kind = kind
		d.scope = scope
		d.title = title
		d.default_value = default_value
		d.group = group
		if d.add_node(target, cfg, owner_name, search_root):
			defs.append(d)
			_by_key[key] = d
		else:
			warnings.append("управление '%s' на узле '%s' не создано (см. Output)" % [key, target.name])
		return
	# Тот же ключ: общее управление группы или повтор id
	if group == &"" or d.group == &"":
		warnings.append("повтор id '%s' (узел '%s'): id должен быть уникален в комнате" % [key, target.name])
		return
	if kind != d.kind or scope != d.scope:
		warnings.append("группа '%s': у узла '%s' другие kind или scope, метка пропущена" % [key, target.name])
		return
	if not d.add_node(target, cfg, owner_name, search_root):
		warnings.append("группа '%s': узел '%s' не добавлен (см. Output)" % [key, target.name])
