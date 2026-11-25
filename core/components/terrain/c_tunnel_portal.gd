class_name C_TunnelPortal extends C_Visual

# XX claude-terra 13.14 H7b (новый файл)
###################################
## Объект «Портал тоннеля» (ATTN_13 §13.14, H7b). Вход в пещеру для поезда: арка стиля (бетон или камень) глубиной 1-5 ю,
## на дальнем конце тёмная плоскость. Рельеф на портал не реагирует: игрок ставит рельсы с флагом U (без ложа), лепит скалу поверх,
## задвигает портал задом в гору, и вагон въезжает в тёмный проём.
###################################
## Сцены нет: арка строится кодом (TunnelPortal.make_arch). Привязки к рельсам нет, коллизии для вагонов нет.
## Выбор объекта идёт по телу StaticBody3D с коробками по арке (проём свободен): слой power, пока объект не выбран, и ghost, пока выбран
## или в драге (как у блоков питания, C_PowerDevice), поэтому вагон тело не замечает.
## Размер проёма не меняется: ширина балласта плюс зазор выреза (terrain_cut_margin), высота рельса плюс габарит (tunnel_clearance).
## Пол арки это y объекта (низ балласта трака, на уровень которого игрок ставит портал). Лицевая плоскость на локальном z = 0,
## наружу смотрит +z, арка уходит в -z.
## Сохраняется стиль и глубина. Меняются в InfoPanel (вкладка «Вид»), стиль ещё клавишей G (как у рамки листа).

## Стили объекта: рамка «нет» тут не имеет смысла
const STYLES: Array[StringName] = [TunnelPortal.STYLE_CONCRETE, TunnelPortal.STYLE_STONE]

var style: StringName = TunnelPortal.STYLE_CONCRETE
var depth: int = TunnelPortal.DEPTH_DEFAULT

var body: StaticBody3D
var _arch: Node3D
var _shapes: Array[CollisionShape3D] = []


func on_added() -> void:
	name = "C_TunnelPortal"
	body = StaticBody3D.new()
	body.name = "PortalBody"
	body.collision_layer = Global.active_layers([&"power"])
	body.collision_mask = 0
	instance = body
	entity.add_child(body)
	_build()
	_on_instance_ready()


## Ширина проёма, ю
static func opening_width() -> float:
	var seg: Dictionary = Global.settings.track_ballast_segment
	return float((seg["size"] as Vector2).x) + 2.0 * float(Global.settings.terrain_cut_margin)


## Высота проёма над полом, ю
static func opening_height() -> float:
	return Global.settings.get_track_height() + float(Global.settings.tunnel_clearance)


static func clamp_depth(v: int) -> int:
	return clampi(v, TunnelPortal.DEPTH_MIN, TunnelPortal.DEPTH_MAX)


static func next_style(cur: StringName) -> StringName:
	var i := STYLES.find(cur)
	return STYLES[(i + 1) % STYLES.size()] if i >= 0 else STYLES[0]


func set_style(new_style: StringName) -> void:
	if not STYLES.has(new_style) or new_style == style:
		return
	style = new_style
	_rebuild()


func set_depth(new_depth: int) -> void:
	var d := clamp_depth(new_depth)
	if d == depth:
		return
	depth = d
	_rebuild()


## Стиль и глубина после ввода игрока или загрузки: арка пересобирается, оверлеи и контур возвращаются на новые меши
func _rebuild() -> void:
	if body == null:
		return   # on_added ещё не было: арка построится с новыми значениями
	_build()
	_outline_state = -1   # контур на новые меши ставится заново
	update_visual()


func _build() -> void:
	if _arch != null and is_instance_valid(_arch):
		body.remove_child(_arch)
		_arch.queue_free()
	for cs in _shapes:
		if is_instance_valid(cs):
			body.remove_child(cs)
			cs.queue_free()
	_shapes.clear()
	var w := opening_width()
	var h := opening_height()
	_arch = TunnelPortal.make_arch(style, w, h, float(depth))
	body.add_child(_arch)
	parts = PartRegistry.build(instance)
	_collect_meshes()
	for part: Dictionary in _collision_parts(w, h, float(depth)):
		_add_shape(part)


## Коробки выбора: рамка, тело арки и тёмная плоскость. Проём между стенками свободен для луча
static func _collision_parts(w: float, h: float, d: float) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	res.append_array(TunnelPortal.parts(w, 0.0, h, h + TunnelPortal.ROOF))
	res.append_array(TunnelPortal.body_parts(w, h, d))
	res.append({"pos": Vector3(0.0, h * 0.5, -d + 0.02), "size": Vector3(w, h, 0.04), "rot_y": 0.0, "rot_z": 0.0})
	return res


func _add_shape(part: Dictionary) -> void:
	var cs := CollisionShape3D.new()
	cs.name = "PortalShape"
	var bx := BoxShape3D.new()
	bx.size = part["size"]
	cs.shape = bx
	cs.position = part["pos"]
	cs.rotation = Vector3(0.0, part["rot_y"], part["rot_z"])
	body.add_child(cs)
	_shapes.append(cs)


## Выбранный объект и объект в драге лежат на слое ghost (чтобы луч постановки не попал в сам портал), остальное время на power
func on_select_layer(data: Dictionary) -> void:
	if body == null:
		return
	body.collision_layer = Global.active_layers([&"ghost"] if data.get("enabled", false) else [&"power"])


## G на выбранном портале: следующий стиль (бетон, камень)
func on_portal_cycle(_d: Dictionary) -> void:
	set_style(next_style(style))


## Дубль и призрак переносят стиль и глубину (BuildTool: on_clone_state_to у источника)
func on_clone_state_to(data: Dictionary) -> void:
	var target: Entity = data.get("target")
	if target == null:
		return
	var t := target.get_comp(C_TunnelPortal) as C_TunnelPortal
	if t != null:
		t.set_style(style)
		t.set_depth(depth)


func get_info_sections() -> Array[InfoSection]:
	var ids: Array = []
	var titles: Array = []
	for st in STYLES:
		ids.append(st)
		titles.append(String(TunnelPortal.NAMES.get(st, st)))
	return [InfoSection.make("Портал тоннеля", [
		InfoSection.list("Стиль", ids, titles, Callable(self, "_get_style"), Callable(self, "_set_style_row")),
		InfoSection.slider("Глубина, ю", float(TunnelPortal.DEPTH_MIN), float(TunnelPortal.DEPTH_MAX), 1.0,
				Callable(self, "_get_depth"), Callable(self, "_set_depth_row")),
	])]


func _get_style() -> Variant:
	return style


func _set_style_row(v: Variant) -> void:
	set_style(StringName(v))


func _get_depth() -> float:
	return float(depth)


func _set_depth_row(v: float) -> void:
	set_depth(roundi(v))


## --- Сейв ---
func save_data() -> Dictionary:
	return {"style": String(style), "depth": depth}


func load_data(data: Dictionary) -> void:
	var st := StringName(String(data.get("style", String(TunnelPortal.STYLE_CONCRETE))))
	style = st if STYLES.has(st) else TunnelPortal.STYLE_CONCRETE
	depth = clamp_depth(int(data.get("depth", TunnelPortal.DEPTH_DEFAULT)))
	_rebuild()
