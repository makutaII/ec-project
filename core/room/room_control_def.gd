class_name RoomControlDef extends RefCounted

########################
## Описание одного управляемого объекта комнаты и его текущее значение (ATTN_25 §25.6)
########################
## Одна модель данных для двух источников: метки RoomControl в сцене Godot (RM5) и свойства из .glb (RM8).
## Определение живёт у реестра (RoomControlRegistry). Узлы хранятся по ссылке: RoomBuilder уносит лампы из комнаты
## (RoomRoot.take_lights), управление после этого продолжает работать.
## Значение 0..1. TOGGLE: 0 выключено, всё остальное включено. SLIDER: множитель энергии света. MECH: состояние механизма.

var id: StringName = &""
var kind: RoomControl.Kind = RoomControl.Kind.TOGGLE
var scope: RoomControl.Scope = RoomControl.Scope.STUDIO
var title := ""
var default_value := 1.0
var group: StringName = &""
var nodes: Array[Node] = []
var mechanisms: Array[RoomMechanism] = []
## Лампочки лампы (из .glb: bulb_of): светятся, пока управление включено
var bulbs: Array[Node] = []
var value := 1.0

var _base_energy := {}   # Light3D -> энергия в сцене (1.0 у SLIDER = она)


func display_title() -> String:
	return title if title != "" else String(id)


## Добавить узел под это управление. Для MECH передайте cfg (метка RoomControl.mechanism или MechanismConfig из .glb).
## search_root: где искать плеер анимации mech_<id> (у .glb в корне модели), по умолчанию внутри самого узла
func add_node(node: Node, cfg: MechanismConfig = null, owner_name := "", search_root: Node = null) -> bool:
	if node == null:
		return false
	if kind == RoomControl.Kind.MECH:
		var rm := RoomMechanism.make(node, cfg, owner_name, search_root)
		if rm == null:
			return false
		mechanisms.append(rm)
	elif node is Light3D:
		_base_energy[node] = (node as Light3D).light_energy
	elif kind == RoomControl.Kind.SLIDER:
		push_warning("[RoomControl] %s: SLIDER работает только на Light3D, узел '%s' другой" % [id, node.name])
		return false
	elif not (node is Node3D):
		push_warning("[RoomControl] %s: TOGGLE работает на Light3D и Node3D, узел '%s' другой" % [id, node.name])
		return false
	nodes.append(node)
	return true


## Поставить значение. instant важен только для MECH (ход по времени или сразу)
func set_value(v: float, instant := true) -> void:
	value = clampf(v, 0.0, 1.0)
	if kind == RoomControl.Kind.TOGGLE:
		value = 1.0 if value > 0.0 else 0.0
	for n in nodes:
		if not is_instance_valid(n):
			continue
		if kind == RoomControl.Kind.MECH:
			continue
		if n is Light3D:
			var l := n as Light3D
			var base: float = _base_energy.get(n, l.light_energy)
			l.visible = value > 0.001
			l.light_energy = base * (value if kind == RoomControl.Kind.SLIDER else 1.0)
		elif n is Node3D:
			(n as Node3D).visible = value > 0.0
	for rm in mechanisms:
		rm.set_state(value, instant)
	for b in bulbs:
		RoomGlb.set_glow(b, value > 0.001)


## Включено ли управление для карточки-переключателя (Observe). MECH: по цели (открывается и закрывается целиком)
func is_on() -> bool:
	if kind == RoomControl.Kind.MECH and not mechanisms.is_empty():
		return mechanisms[0].mech.target > 0.5
	return value > 0.0


## Включить или выключить как переключатель. TOGGLE: 1 и 0; SLIDER: начальное значение (если оно 0, то 1) и 0; MECH: ход 1 и 0 по времени
func set_on(on: bool, instant := false) -> void:
	var v := 0.0
	if on:
		v = default_value if kind == RoomControl.Kind.SLIDER and default_value > 0.0 else 1.0
	set_value(v, instant or kind != RoomControl.Kind.MECH)


func is_moving() -> bool:
	for rm in mechanisms:
		if rm.is_moving():
			return true
	return false


## Шаг механизмов по времени
func tick(dt: float) -> void:
	for rm in mechanisms:
		rm.tick(dt)
	if kind == RoomControl.Kind.MECH and not mechanisms.is_empty():
		value = mechanisms[0].state()


func reset() -> void:
	set_value(default_value, true)
