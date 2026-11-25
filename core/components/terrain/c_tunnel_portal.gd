class_name C_TunnelPortal extends C_Visual

# XX claude-terra 13.14 H7b (новый файл), H7b2 (паспорт PortalConfig, глубина тёмной плоскости, сцена)
###################################
## Объект «Портал тоннеля» (ATTN_13 §13.14, H7b). Визуальный декор входа в гору: арка стиля (бетон или камень) глубиной 1-100 ю,
## тёмная плоскость на своей глубине. Вагон по траку с U проезжает в гору и без портала (механизм H7), портал только рисует вход.
## Рельеф на портал не реагирует: игрок ставит рельсы с флагом U (без ложа), лепит скалу поверх и задвигает портал задом в гору.
###################################
## Паспорт PortalConfig (C_Identity.object_config): габариты проёма, глубины по умолчанию, точка установки (лицевая или тёмная
## плоскость), сцена с визуалом. Без паспорта берутся значения по умолчанию (проём по настройкам, глубина 5, тёмная плоскость на 2).
## Сцена (config.scene) заменяет процедурную арку; узел Dark в ней ставится на глубину тёмной плоскости, нет узла: строится кодом.
## Выбор объекта идёт по телу StaticBody3D с коробками по арке (проём свободен): слой power, пока объект не выбран, и ghost, пока
## выбран или в драге (как у блоков питания, C_PowerDevice). Вагон тело не проверяет, коллизии для вагона нет.
## Местная система: пол на y = 0, центр проёма на x = 0, лицевая плоскость на z = 0, наружу +z. Арка сдвинута по z так, чтобы
## точка установки (config.anchor) стояла в начале координат объекта.
## Сохраняется стиль, глубина и глубина тёмной плоскости. Меняются в InfoPanel (вкладка «Вид»), стиль ещё клавишей G.

## Стили объекта: рамка «нет» тут не имеет смысла
const STYLES: Array[StringName] = [TunnelPortal.STYLE_CONCRETE, TunnelPortal.STYLE_STONE]

var style: StringName = TunnelPortal.STYLE_CONCRETE
var depth: int = TunnelPortal.DEPTH_DEFAULT
## Глубина тёмной плоскости от лицевой плоскости, ю
var dark_depth: float = TunnelPortal.DARK_DEFAULT

var config: PortalConfig
var body: StaticBody3D
var _arch: Node3D
var _shapes: Array[CollisionShape3D] = []


func on_added() -> void:
	name = "C_TunnelPortal"
	config = PortalConfig.from_entity(entity)
	if config != null:
		depth = clamp_depth(config.depth)
		dark_depth = clamp_dark(config.dark_depth, depth)
	body = StaticBody3D.new()
	body.name = "PortalBody"
	body.collision_layer = Global.active_layers([&"power"])
	body.collision_mask = 0
	instance = body
	entity.add_child(body)
	_build()
	_on_instance_ready()


## Ширина проёма, ю: паспорт или ширина балласта плюс зазор выреза
func opening_width() -> float:
	if config != null and config.width > 0.0:
		return config.width
	return default_width()


## Высота проёма над полом, ю: паспорт или высота рельса плюс габарит
func opening_height() -> float:
	if config != null and config.height > 0.0:
		return config.height
	return default_height()


static func default_width() -> float:
	var seg: Dictionary = Global.settings.track_ballast_segment
	return float((seg["size"] as Vector2).x) + 2.0 * float(Global.settings.terrain_cut_margin)


static func default_height() -> float:
	return Global.settings.get_track_height() + float(Global.settings.tunnel_clearance)


static func clamp_depth(v: int) -> int:
	return clampi(v, TunnelPortal.DEPTH_MIN, TunnelPortal.DEPTH_MAX)


## Глубина тёмной плоскости: шаг 0,5 ю, от 0 до глубины арки
static func clamp_dark(v: float, arch_depth: int) -> float:
	return clampf(snappedf(v, TunnelPortal.DARK_STEP), 0.0, float(arch_depth))


static func next_style(cur: StringName) -> StringName:
	var i := STYLES.find(cur)
	return STYLES[(i + 1) % STYLES.size()] if i >= 0 else STYLES[0]


## Сдвиг арки по z, ю: точка установки в начале координат (лицевая плоскость: 0, тёмная плоскость: её глубина)
func anchor_shift() -> float:
	if config != null and config.anchor == PortalConfig.Anchor.DARK:
		return dark_depth
	return 0.0


func uses_scene() -> bool:
	return config != null and config.scene != null


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
	dark_depth = clamp_dark(dark_depth, depth)   # тёмная плоскость не глубже арки
	_rebuild()


func set_dark_depth(new_dark: float) -> void:
	var v := clamp_dark(new_dark, depth)
	if is_equal_approx(v, dark_depth):
		return
	dark_depth = v
	_rebuild()


## Стиль и глубины после ввода игрока или загрузки: арка пересобирается, оверлеи и контур возвращаются на новые меши
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
	var shift := anchor_shift()
	var boxes: Array[Dictionary] = []
	_arch = _make_visual(w, h, boxes)
	_arch.position.z = shift
	body.add_child(_arch)
	parts = PartRegistry.build(instance)
	_collect_meshes()
	for part: Dictionary in boxes:
		var moved := part.duplicate()
		moved["pos"] = (part["pos"] as Vector3) + Vector3(0.0, 0.0, shift)
		_add_shape(moved)


## Визуал и коробки выбора (в системе арки, без сдвига точки установки). Сцена паспорта или процедурная арка
func _make_visual(w: float, h: float, boxes: Array[Dictionary]) -> Node3D:
	var dz := TunnelPortal.dark_z(float(depth), dark_depth)
	if uses_scene():
		var inst := config.scene.instantiate() as Node3D
		if inst != null:
			var root := Node3D.new()
			root.name = "Arch"
			root.add_child(inst)
			var dark := inst.find_child("Dark", true, false) as Node3D
			if dark != null:
				dark.position.z = dz
			else:
				root.add_child(TunnelPortal.make_dark(w, h, dz))
			var bb := _scene_box(root)
			if bb.size != Vector3.ZERO:
				boxes.append({"pos": bb.get_center(), "size": bb.size, "rot_y": 0.0, "rot_z": 0.0})
			return root
	var arch := TunnelPortal.make_arch(style, w, h, float(depth), dark_depth)
	boxes.append_array(_collision_parts(w, h, float(depth), dark_depth))
	return arch


## Объединённый AABB мешей сцены в системе арки (корень root без сдвига)
static func _scene_box(root: Node3D) -> AABB:
	var res := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var t := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != null and cur != root:
			if cur is Node3D:
				t = (cur as Node3D).transform * t
			cur = cur.get_parent()
		var bb := t * mi.mesh.get_aabb()
		res = bb if first else res.merge(bb)
		first = false
	return res


## Коробки выбора: рамка, тело арки и тёмная плоскость. Проём между стенками свободен для луча
static func _collision_parts(w: float, h: float, d: float, dark: float) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	res.append_array(TunnelPortal.parts(w, 0.0, h, h + TunnelPortal.ROOF))
	res.append_array(TunnelPortal.body_parts(w, h, d))
	res.append({"pos": Vector3(0.0, h * 0.5, TunnelPortal.dark_z(d, dark)), "size": Vector3(w, h, 0.04), "rot_y": 0.0, "rot_z": 0.0})
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


## G на выбранном портале: следующий стиль (бетон, камень). У портала со сценой стиля нет
func on_portal_cycle(_d: Dictionary) -> void:
	if uses_scene():
		return
	set_style(next_style(style))


## Дубль и призрак переносят стиль и глубины (BuildTool: on_clone_state_to у источника)
func on_clone_state_to(data: Dictionary) -> void:
	var target: Entity = data.get("target")
	if target == null:
		return
	var t := target.get_comp(C_TunnelPortal) as C_TunnelPortal
	if t != null:
		t.style = style
		t.depth = depth
		t.dark_depth = dark_depth
		t._rebuild()


func get_info_sections() -> Array[InfoSection]:
	var rows: Array = []
	if not uses_scene():
		var ids: Array = []
		var titles: Array = []
		for st in STYLES:
			ids.append(st)
			titles.append(String(TunnelPortal.NAMES.get(st, st)))
		rows.append(InfoSection.list("Стиль", ids, titles, Callable(self, "_get_style"), Callable(self, "_set_style_row")))
	rows.append(InfoSection.slider("Глубина арки, ю", float(TunnelPortal.DEPTH_MIN), float(TunnelPortal.DEPTH_MAX), 1.0,
			Callable(self, "_get_depth"), Callable(self, "_set_depth_row")))
	rows.append(InfoSection.slider("Тёмная плоскость, ю", 0.0, float(TunnelPortal.DEPTH_MAX), TunnelPortal.DARK_STEP,
			Callable(self, "_get_dark"), Callable(self, "_set_dark_row")))
	return [InfoSection.make("Портал тоннеля", rows)]


func _get_style() -> Variant:
	return style


func _set_style_row(v: Variant) -> void:
	set_style(StringName(v))


func _get_depth() -> float:
	return float(depth)


func _set_depth_row(v: float) -> void:
	set_depth(roundi(v))


func _get_dark() -> float:
	return dark_depth


func _set_dark_row(v: float) -> void:
	set_dark_depth(v)


## --- Сейв ---
func save_data() -> Dictionary:
	return {"style": String(style), "depth": depth, "dark": dark_depth}


func load_data(data: Dictionary) -> void:
	var st := StringName(String(data.get("style", String(TunnelPortal.STYLE_CONCRETE))))
	style = st if STYLES.has(st) else TunnelPortal.STYLE_CONCRETE
	depth = clamp_depth(int(data.get("depth", TunnelPortal.DEPTH_DEFAULT)))
	dark_depth = clamp_dark(float(data.get("dark", TunnelPortal.DARK_DEFAULT)), depth)
	_rebuild()
