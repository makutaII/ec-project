class_name RoomRoot extends Node3D

########################
## Корень сцены комнаты (data/rooms/<id>/<id>.tscn). Контракт: что RoomBuilder ждёт от сцены.
########################
## Сцену можно крутить в редакторе: двигать блоки, лампы, добавлять новые. Мир в см, центр комнаты (0, 0),
## столешница подмакетника на y = 0, пол на RoomConfig.floor_y (карточка data/rooms/cards/<id>.tres).
##
## Дети корня по именам (всё необязательное, кроме нужного вам):
##   Floor     пол (visual layer комнаты)
##   Shell     стены, скос, рама окна, шторы: всё в нём получает слой оболочки (SkyFill его не видит) и отбрасывает тень в Observe
##   Ceiling   потолок: ребёнок CeilingSlab (MeshInstance3D). Кнопка «Потолок» и тень потолка идут через него
##   Decor     мебель и декор T1
##   DecorT2   мелочи, видны при QualityPreset.room_detail_lod >= 1
##   DecorT3   мелочи, видны при room_detail_lod >= 2
##   FakeAO    ложные AO-квады
##   Lights    SpotLight3D / OmniLight3D комнаты: RoomBuilder выносит их из комнаты, кнопка «Комната» свет не гасит
## Всё остальное считается декором. Меш с слоем по умолчанию (1) вне Shell получает visual layer комнаты, поэтому слой у новых блоков
## выставлять не нужно. Коллизия: StaticBody3D со слоем room (бит 8). Меш с именем SkyCard* попадает в группу gfx_sky (небо в окне).
## Меш с именем Bulb* светится, пока включена лампа (StandardMaterial3D, emission).
## Лампы на сцене работают так же, как раньше RoomConfig.lamps: энергия и тень настраиваются на самой ноде.
## Добавлять в карточку <id>.tres lamps не нужно (массив пустой).
##
## Комната из .glb (RM8): сцена-обёртка data/models/room_<имя>/room_<имя>.tscn = этот корень + экземпляр .glb. Группы там задаются
## не именами, а ролями Blender (role = floor, shell, ceiling, decor_t1..3, fake_ao на пустышке или меше; всё под узлом роли в группе),
## прокси и якоря света превращает в объекты Godot RoomGlb (import_glb). Имена детей корня (Floor, Shell...) при этом тоже работают.

const SHELL := "Shell"
const CEILING := "Ceiling"
const LIGHTS := "Lights"
const WALL_GROUP := &"room_wall"   # доп. способ пометить меш как стену (тень в Observe), если он не в Shell

## Роль группы (&"floor", &"shell", &"ceiling", &"decor_t1", &"decor_t2", &"decor_t3", &"fake_ao") -> узлы. Имена детей корня и роли .glb
const NAME_ROLES := {"Floor": &"floor", "Shell": &"shell", "Ceiling": &"ceiling", "Decor": &"decor_t1", "DecorT2": &"decor_t2",
		"DecorT3": &"decor_t3", "FakeAO": &"fake_ao"}

## Результат разбора .glb (после import_glb). present = false: в сцене ролей Blender нет
var glb: RoomGlb

var _shell_layer := 0
var _vis_layer := 0
var _imported := false
var _groups := {}   # StringName -> Array[Node]


## Корень комнаты из экземпляра сцены: свой RoomRoot остаётся как есть; сцена с другим Node3D-корнем (например, унаследованная от .glb без скрипта)
## заворачивается в новый RoomRoot, чтобы роли .glb и контракт работали. null: корень не Node3D
static func wrap(inst: Node) -> RoomRoot:
	if inst is RoomRoot:
		return inst as RoomRoot
	if not (inst is Node3D):
		return null
	var r := RoomRoot.new()
	r.name = inst.name
	r.add_child(inst)
	return r


## Слои и группы. Вызывает RoomBuilder сразу после instantiate (до добавления в дерево)
func setup(vis_layer: int, shell_layer: int) -> void:
	import_glb()
	_vis_layer = vis_layer
	_shell_layer = shell_layer
	for n in _all_nodes(self):
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if _in_shell(mi):
				mi.layers = shell_layer
			elif mi.layers & 1:
				mi.layers = vis_layer
		if String(n.name).begins_with("SkyCard") and not n.is_in_group(&"gfx_sky"):
			n.add_to_group(&"gfx_sky")


## Разобрать роли .glb (RoomGlb.run) и собрать группы. Один раз (повторный вызов ничего не делает), узел может быть вне дерева.
## Зовут setup, RoomControlRegistry.collect и Room Studio: вызывать вручную не нужно
func import_glb() -> void:
	if _imported:
		return
	_imported = true
	glb = RoomGlb.new()
	glb.run(self)
	_groups.clear()
	for nm in NAME_ROLES:
		var n := get_node_or_null(nm)
		if n != null:
			_add_group(NAME_ROLES[nm], n)
	for r in glb.groups:
		for n in glb.groups[r]:
			_add_group(r, n)


func _add_group(role: StringName, n: Node) -> void:
	if not _groups.has(role):
		_groups[role] = []
	if not (_groups[role] as Array).has(n):
		(_groups[role] as Array).append(n)


## Узлы группы по роли (пустой массив, если группы нет)
func group_nodes(role: StringName) -> Array:
	import_glb()
	return _groups.get(role, [])


## Лампы комнаты отдельной нодой (RoomBuilder ставит её рядом с комнатой). null, если ламп нет
func take_lights() -> Node3D:
	var l := get_node_or_null(LIGHTS) as Node3D
	if l:
		remove_child(l)
	return l


## Меши, отбрасывающие тень только в Observe: всё в Shell (кроме потолка) и меши группы room_wall
func get_wall_meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in _all_nodes(self):
		if n is MeshInstance3D and (_in_shell(n) or n.is_in_group(WALL_GROUP)) and not _in_ceiling(n):
			out.append(n)
	return out


func get_ceiling() -> Node3D:
	var l := group_nodes(&"ceiling")
	return l[0] as Node3D if not l.is_empty() else null


## Меш потолка: сам узел роли ceiling, если это меш; иначе ребёнок CeilingSlab, иначе первый меш внутри
func get_ceiling_mesh() -> MeshInstance3D:
	var c := get_ceiling()
	if c == null:
		return null
	if c is MeshInstance3D:
		return c as MeshInstance3D
	var slab := c.get_node_or_null("CeilingSlab") as MeshInstance3D
	if slab != null:
		return slab
	for n in _all_nodes(c):
		if n is MeshInstance3D:
			return n as MeshInstance3D
	return null


## Мелочи по QualityPreset.room_detail_lod (0: только T1, 1: T1 + T2, 2: все)
func set_detail(lod: int) -> void:
	for n in group_nodes(&"decor_t2"):
		(n as Node3D).visible = lod >= 1
	for n in group_nodes(&"decor_t3"):
		(n as Node3D).visible = lod >= 2


## Лампочки (меши Bulb*) светятся, когда лампа включена (GFX.lamp_changed)
func set_lamp_glow(on: bool) -> void:
	for n in _all_nodes(self):
		if n is MeshInstance3D and String(n.name).begins_with("Bulb"):
			var m := (n as MeshInstance3D).material_override as StandardMaterial3D
			if m:
				m.emission_enabled = on


func _in_shell(n: Node) -> bool:
	return _in_group(n, &"shell") or _in_ceiling(n)


func _in_ceiling(n: Node) -> bool:
	return _in_group(n, &"ceiling")


## n сам узел группы или лежит внутри её узла
func _in_group(n: Node, role: StringName) -> bool:
	import_glb()
	var nodes: Array = _groups.get(role, [])
	if nodes.is_empty():
		return false
	var p := n
	while p != null and p != self:
		if nodes.has(p):
			return true
		p = p.get_parent()
	return false


func _all_nodes(from: Node) -> Array[Node]:
	var out: Array[Node] = []
	for c in from.get_children():
		out.append(c)
		out.append_array(_all_nodes(c))
	return out
