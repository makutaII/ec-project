class_name RoomDecor extends RefCounted

########################
## Наполнение комнаты ребёнка 10 лет из примитивов (TDD §14.5, S7).
########################
## Тиры: T1 мебель, окно и свет (всегда), T2 характер ребёнка-моделиста, T3 мелочи.
## RoomBuilder показывает их по QualityPreset.room_detail_lod (0: T1, 1: T1+T2, 2: все).
## Палитра и материалы по ролям (пластик, дерево, ткань, металл, бумага, краска) без текстур:
## это заменитель чек-листа S6, пока нет арт-моделей. Для замены на арт: RoomConfig.scene.
## Варианты (RoomConfig.variants): wall, bedding, curtains, posters. Размеры и места мебели по §14.4.

const PALETTE := {
	"white": Color(0.95, 0.95, 0.93),
	"cream": Color(0.96, 0.90, 0.78),
	"wood_light": Color(0.86, 0.68, 0.45),
	"wood_dark": Color(0.55, 0.38, 0.24),
	"grey": Color(0.62, 0.64, 0.68),
	"dark": Color(0.18, 0.19, 0.22),
	"red": Color(0.90, 0.22, 0.20),
	"orange": Color(0.97, 0.58, 0.18),
	"yellow": Color(0.99, 0.82, 0.20),
	"green": Color(0.30, 0.70, 0.35),
	"blue": Color(0.22, 0.46, 0.88),
	"sky": Color(0.55, 0.78, 0.96),
	"mint": Color(0.62, 0.88, 0.76),
	"dusty": Color(0.52, 0.64, 0.82),
	"slate": Color(0.42, 0.54, 0.72),
	"sage": Color(0.66, 0.76, 0.64),
	"purple": Color(0.58, 0.40, 0.80),
	"brown": Color(0.50, 0.33, 0.22),
}

## Варианты по слотам: слот -> допустимые значения (ключи палитры или набор цветов постеров). Первый = по умолчанию
const VARIANTS := {
	"wall": ["dusty", "cream", "sky", "mint", "slate", "sage", "blue"],
	"bedding": ["red", "blue", "green"],
	"curtains": ["yellow", "red", "blue"],
	"posters": ["trains", "map", "space"],
}
const POSTER_COLORS := {
	"trains": ["blue", "red", "yellow"],
	"map": ["sky", "green", "white"],
	"space": ["dark", "purple", "yellow"],
}

## Роль материала: [roughness, metallic]
const ROLE := {
	"plastic": [0.4, 0.0], "wood": [0.75, 0.0], "fabric": [0.95, 0.0],
	"metal": [0.35, 0.7], "paper": [0.9, 0.0], "paint": [0.8, 0.0],
}

var cfg: RoomConfig
var vis := 1
var fy := -50.0
var lamp_y := 120.0

var tier2: Node3D
var tier3: Node3D
## Рама, шторы и подоконник: отбрасывают тень вместе со стенами (рисунок окна только в Observe)
var window_parts: Array[MeshInstance3D] = []
var bulb_mat: StandardMaterial3D

var _mats := {}


func _init(config: RoomConfig, vis_layer: int, lamp_height := 120.0) -> void:
	cfg = config
	vis = vis_layer
	fy = config.floor_y
	lamp_y = lamp_height


func wall_color() -> Color:
	return PALETTE[_variant("wall")]


func floor_color() -> Color:
	return Color(0.74, 0.58, 0.40)


func set_detail(lod: int) -> void:
	if tier2:
		tier2.visible = lod >= 1
	if tier3:
		tier3.visible = lod >= 2


## Лампа над столом: лампочка светится, когда лампа включена (GFX.lamp_changed)
func set_lamp_glow(on: bool) -> void:
	if bulb_mat:
		bulb_mat.emission_enabled = on


## Строит всё под parent (RoomBuilder.visuals). T2 и T3 в своих нодах, чтобы скрывать целиком
func build(parent: Node3D) -> void:
	_furniture(parent)
	_window_dressing(parent)
	_ceiling_lamp(parent)
	tier2 = Node3D.new()
	tier2.name = "DecorT2"
	parent.add_child(tier2)
	_tier2(tier2)
	tier3 = Node3D.new()
	tier3.name = "DecorT3"
	parent.add_child(tier3)
	_tier3(tier3)


# ==========================================
# Небо за окном
# ==========================================

## «Небо» за окном: плоскость (лицом на +Z) с вертикальным градиентом, без освещения. Цвета меняет GFX (группа gfx_sky).
## Поворот и положение задаёт вызывающий
static func make_sky_card(size: Vector2, vis_layer: int) -> MeshInstance3D:
	var m := RoomGlb.sky_material()
	var q := QuadMesh.new()
	q.size = size
	var mi := MeshInstance3D.new()
	mi.name = "SkyCard"
	mi.mesh = q
	mi.material_override = m
	mi.layers = vis_layer
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.add_to_group(&"gfx_sky")
	return mi


# ==========================================
# T1: мебель, окно, лампа
# ==========================================

func _furniture(p: Node3D) -> void:
	var bedding := _col(_variant("bedding"))
	# Кровать: у западной стены, изголовье к северу
	_box(p, Vector3(90, 22, 200), _f(-195, 11, -90), PALETTE["wood_light"], "wood")
	_box(p, Vector3(86, 14, 194), _f(-195, 29, -90), PALETTE["white"], "fabric")
	_box(p, Vector3(87, 3, 130), _f(-195, 37.5, -56), bedding, "fabric")
	_ball(p, 12.0, _f(-195, 40, -172), PALETTE["white"], "fabric", true, Vector3(1.6, 0.5, 1.0))
	_box(p, Vector3(90, 50, 4), _f(-195, 25, -188), PALETTE["wood_dark"], "wood")
	_box(p, Vector3(90, 28, 4), _f(-195, 14, 8), PALETTE["wood_dark"], "wood")

	# Рабочий стол у восточной стены
	_box(p, Vector3(60, 4, 120), _f(210, 73, 40), PALETTE["wood_light"], "wood")
	_box(p, Vector3(56, 71, 3), _f(210, 35.5, -18.5), PALETTE["wood_light"], "wood")
	_box(p, Vector3(56, 71, 3), _f(210, 35.5, 98.5), PALETTE["wood_light"], "wood")
	_box(p, Vector3(3, 40, 114), _f(237.5, 50, 40), PALETTE["wood_dark"], "wood")
	_box(p, Vector3(52, 45, 46), _f(212, 24.5, 70), PALETTE["white"], "paint")
	_box(p, Vector3(1, 18, 42), _f(185.5, 15, 70), PALETTE["cream"], "paint")
	_box(p, Vector3(1, 18, 42), _f(185.5, 36, 70), PALETTE["cream"], "paint")
	_ball(p, 1.4, _f(184.5, 15, 70), PALETTE["yellow"], "plastic")
	_ball(p, 1.4, _f(184.5, 36, 70), PALETTE["yellow"], "plastic")

	# Стул
	_box(p, Vector3(36, 4, 36), _f(160, 43, 40), PALETTE["orange"], "plastic")
	_box(p, Vector3(4, 34, 36), _f(143, 62, 40), PALETTE["orange"], "plastic")
	for sx in [-15.0, 15.0]:
		for sz in [-15.0, 15.0]:
			_cyl(p, 1.5, 41.0, _f(160 + sx, 20.5, 40 + sz), PALETTE["grey"], "metal")

	# Шкаф: юго-запад, двери на север
	_box(p, Vector3(100, 200, 48), _f(-190, 100, 166), PALETTE["wood_light"], "wood")
	_box(p, Vector3(48.5, 194, 2), _f(-215, 100, 141), PALETTE["white"], "paint")
	_box(p, Vector3(48.5, 194, 2), _f(-165, 100, 141), PALETTE["white"], "paint")
	_box(p, Vector3(1.5, 14, 1.5), _f(-194, 100, 139), PALETTE["grey"], "metal")
	_box(p, Vector3(1.5, 14, 1.5), _f(-186, 100, 139), PALETTE["grey"], "metal")
	_box(p, Vector3(104, 4, 52), _f(-190, 202, 165), PALETTE["wood_dark"], "wood")

	# Стеллаж: северо-восток
	for sx in [161.5, 238.5]:
		_box(p, Vector3(3, 180, 30), _f(sx, 90, -175), PALETTE["wood_light"], "wood")
	for y in [1.5, 45.0, 90.0, 135.0, 178.5]:
		_box(p, Vector3(80, 3, 28), _f(200, y, -176), PALETTE["wood_light"], "wood")
	_box(p, Vector3(80, 180, 2), _f(200, 90, -189), PALETTE["wood_dark"], "wood")

	# Ковёр с дорогами (задел под Car System)
	_box(p, Vector3(160, 0.6, 110), _f(0, 0.3, 125), PALETTE["green"], "fabric", false)
	_box(p, Vector3(160, 0.2, 22), _f(0, 0.7, 125), PALETTE["grey"], "fabric", false)
	_box(p, Vector3(22, 0.2, 110), _f(-30, 0.7, 125), PALETTE["grey"], "fabric", false)
	for i in range(-3, 4):
		var x := i * 20.0
		if absf(x + 30.0) > 14.0:
			_box(p, Vector3(8, 0.1, 1.6), _f(x, 0.9, 125), PALETTE["yellow"], "fabric", false)

	# Дверь (в проёме южной стены)
	var d: Dictionary = cfg.door
	if not d.is_empty():
		var dx: float = d.x
		var dw: float = d.w
		var dh: float = d.h
		_box(p, Vector3(dw - 4.0, dh - 4.0, 3), _f(dx, (dh - 4.0) * 0.5, 192), PALETTE["white"], "paint")
		_box(p, Vector3(4, dh, 6), _f(dx - dw * 0.5, dh * 0.5, 193), PALETTE["wood_light"], "wood")
		_box(p, Vector3(4, dh, 6), _f(dx + dw * 0.5, dh * 0.5, 193), PALETTE["wood_light"], "wood")
		_box(p, Vector3(dw + 4.0, 4, 6), _f(dx, dh + 2.0, 193), PALETTE["wood_light"], "wood")
		_box(p, Vector3(6, 1.5, 1.5), _f(dx - dw * 0.5 + 8.0, 100, 190), PALETTE["grey"], "metal")


func _window_dressing(p: Node3D) -> void:
	var w: Dictionary = cfg.window
	if w.is_empty():
		return
	var ox: float = w.x
	var ww: float = w.w
	var top: float = w.sill + w.h
	var curtain := _col(_variant("curtains"))
	var rod := _cyl(p, 1.0, ww + 56.0, _f(ox, top + 6.0, -183), PALETTE["grey"], "metal", true, -1.0, Vector3(0, 0, 90))
	var hang: float = top + 4.0 - (w.sill - 14.0)
	var cy: float = (top + 4.0 + (w.sill - 14.0)) * 0.5
	var left := _box(p, Vector3(26, hang, 3), _f(ox - ww * 0.5 - 14.0, cy, -183), curtain, "fabric")
	var right := _box(p, Vector3(26, hang, 3), _f(ox + ww * 0.5 + 14.0, cy, -183), curtain, "fabric")
	var sill := _box(p, Vector3(ww + 16.0, 4, 16), _f(ox, w.sill - 2.0, -182), PALETTE["white"], "paint")
	var shell := 1 << (Global.ROOM_SHELL_LAYER - 1)   # шторы, карниз и подоконник: оболочка, не отбрасывают тень для SkyFill
	for part in [rod, left, right, sill]:
		part.layers = shell
		window_parts.append(part)


## Лампа над столом: шнур, плафон и лампочка. Источник света (SpotLight3D) создаёт EnvironmentRoot
func _ceiling_lamp(p: Node3D) -> void:
	var top_y: float = cfg.floor_y + cfg.size.y
	var cord_len := top_y - (lamp_y + 12.0)
	_cyl(p, 0.4, maxf(cord_len, 4.0), Vector3(0, lamp_y + 12.0 + cord_len * 0.5, 0), PALETTE["dark"], "paint", false)
	_cyl(p, 3.0, 12.0, Vector3(0, lamp_y + 6.0, 0), PALETTE["yellow"], "paint", false, 11.0)
	var bulb := _ball(p, 3.5, Vector3(0, lamp_y - 1.0, 0), Color(1.0, 0.92, 0.75), "plastic", false)
	bulb_mat = bulb.material_override as StandardMaterial3D
	bulb_mat.emission = Color(1.0, 0.82, 0.55)
	bulb_mat.emission_energy_multiplier = 3.0


# ==========================================
# T2: характер ребёнка-моделиста
# ==========================================

func _tier2(p: Node3D) -> void:
	# Коробки от моделей на второй полке стеллажа
	var cols := ["red", "blue", "yellow", "green", "orange", "purple"]
	for i in cols.size():
		var x := 166.0 + i * 11.0
		_box(p, Vector3(6, 20, 14), _f(x, 56.5, -176), PALETTE[cols[i]], "paper")
		_box(p, Vector3(6.4, 3, 14.4), _f(x, 46.5 + 4.0, -176), PALETTE["white"], "paper", false)
	# Книги (MultiMesh) на третьей полке
	_books(p, 164.0, 236.0, 91.5, -176.0)

	# Ящик с инструментами на столе (поверхность стола y = 75)
	_box(p, Vector3(14, 8, 10), _f(225, 79, 10), PALETTE["red"], "metal")
	_box(p, Vector3(8, 1.5, 1.5), _f(225, 84.5, 10), PALETTE["grey"], "metal", false)

	# Настольная лампа с лупой
	_cyl(p, 5.0, 2.0, _f(230, 76, 85), PALETTE["dark"], "metal")
	_box(p, Vector3(1.5, 30, 1.5), _f(228, 91, 85), PALETTE["grey"], "metal", true, Vector3(0, 0, 14))
	_cyl(p, 6.0, 8.0, _f(222, 105, 85), PALETTE["yellow"], "paint", true, 2.0)

	# Глобус
	_cyl(p, 4.0, 1.0, _f(200, 75.5, -8), PALETTE["dark"], "metal")
	_ball(p, 7.0, _f(200, 83, -8), PALETTE["blue"], "plastic")
	var ring := TorusMesh.new()
	ring.inner_radius = 7.6
	ring.outer_radius = 8.2
	_mesh(p, ring, _f(200, 83, -8), PALETTE["grey"], "metal", false, Vector3(0, 0, 23))

	# Постеры на западной и восточной стенах
	var pc: Array = POSTER_COLORS[_variant("posters")]
	_poster(p, -239.5, 1.0, _f(0, 150, -90), pc)
	_poster(p, 239.5, -1.0, _f(0, 150, 40), pc)

	# Рюкзак у стула
	_box(p, Vector3(24, 34, 12), _f(150, 17, 92), PALETTE["slate"], "fabric")
	_box(p, Vector3(20, 14, 5), _f(150, 10, 86), PALETTE["yellow"], "fabric")


## Постер на стене: фон и два акцента (по цветам варианта). x: плоскость стены, dir: куда смотрит (+1 на восток)
func _poster(p: Node3D, x: float, dir: float, at: Vector3, colors: Array) -> void:
	var c0: Color = PALETTE[colors[0]]
	var c1: Color = PALETTE[colors[1]]
	var c2: Color = PALETTE[colors[2]]
	_box(p, Vector3(1, 40, 60), Vector3(x, at.y, at.z), c0, "paper", false)
	_box(p, Vector3(1.2, 14, 36), Vector3(x + dir * 0.2, at.y - 6, at.z), c1, "paper", false)
	_box(p, Vector3(1.2, 10, 10), Vector3(x + dir * 0.2, at.y - 3, at.z - 14), c2, "paper", false)
	_box(p, Vector3(1.2, 6, 6), Vector3(x + dir * 0.2, at.y + 12, at.z + 16), c2, "paper", false)


## Книги одним MultiMesh: цвета и размеры детерминированы (фиксированный seed)
func _books(p: Node3D, x0: float, x1: float, y: float, z: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var keys := ["red", "blue", "green", "orange", "purple", "yellow", "sky"]
	var items: Array = []
	var x := x0
	while x < x1 - 3.0:
		var w := rng.randf_range(2.0, 3.6)
		if x + w > x1:
			break
		items.append([x + w * 0.5, w, rng.randf_range(15.0, 23.0), keys[rng.randi() % keys.size()]])
		x += w + 0.1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = BoxMesh.new()
	mm.instance_count = items.size()
	for i in items.size():
		var it: Array = items[i]
		var h: float = it[2]
		var b := Basis.from_scale(Vector3(it[1], h, 14.0))
		mm.set_instance_transform(i, Transform3D(b, _f(it[0], y + h * 0.5, z)))
		mm.set_instance_color(i, PALETTE[it[3]])
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Books"
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.layers = vis
	p.add_child(mmi)


# ==========================================
# T3: мелочи (только вблизи, visibility_range)
# ==========================================

func _tier3(p: Node3D) -> void:
	# Кружка с кистями
	_small(_cyl(p, 3.0, 8.0, _f(232, 79, -10), PALETTE["orange"], "plastic"))
	for i in 3:
		_small(_cyl(p, 0.4, 12.0, _f(232 + (i - 1) * 1.4, 87, -10), PALETTE[["red", "blue", "green"][i]], "wood", true, -1.0, Vector3(0, 0, (i - 1) * 12.0)))
	# Тетради
	var nb := ["green", "red", "blue"]
	for i in 3:
		_small(_box(p, Vector3(16, 1.2, 22), _f(215, 75.6 + i * 1.3, 55), PALETTE[nb[i]], "paper"))
	# Футбольный мяч
	_small(_ball(p, 11.0, _f(40, 11, 140), PALETTE["white"], "plastic"))
	for v in [Vector3(0, 10, 4), Vector3(8, 4, 6), Vector3(-7, 6, 5)]:
		_small(_ball(p, 3.2, _f(40, 11, 140) + v * 0.95, PALETTE["dark"], "plastic", true, Vector3(1, 1, 0.5)))
	# Кубики на ковре
	var bc := ["red", "yellow", "blue", "green"]
	for i in 4:
		_small(_box(p, Vector3(5, 5, 5), _f(-70 + i * 6.0, 3.1, 150 - (i % 2) * 5.0), PALETTE[bc[i]], "plastic", true, Vector3(0, i * 20.0, 0)))
	# Кроссовки у кровати
	_small(_box(p, Vector3(10, 6, 22), _f(-130, 3, 20), PALETTE["dark"], "fabric"))
	_small(_box(p, Vector3(10, 6, 22), _f(-116, 3, 24), PALETTE["red"], "fabric", true, Vector3(0, 12, 0)))
	# Плюшевый мишка на кровати
	_small(_ball(p, 7.0, _f(-195, 45, -20), PALETTE["brown"], "fabric"))
	_small(_ball(p, 5.0, _f(-195, 55, -20), PALETTE["brown"], "fabric"))
	_small(_ball(p, 2.0, _f(-199, 59.5, -20), PALETTE["brown"], "fabric"))
	_small(_ball(p, 2.0, _f(-191, 59.5, -20), PALETTE["brown"], "fabric"))


# ==========================================
# Примитивы
# ==========================================

## Точка в координатах комнаты: y отсчитывается от пола
func _f(x: float, y: float, z: float) -> Vector3:
	return Vector3(x, fy + y, z)


func _variant(slot: String) -> String:
	var list: Array = VARIANTS[slot]
	var v = cfg.variants.get(slot, list[0])
	return v if list.has(v) else list[0]


func _col(key: String) -> Color:
	return PALETTE[key]


func _m(role: String, color: Color) -> StandardMaterial3D:
	var key := role + color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = ROLE[role][0]
		m.metallic = ROLE[role][1]
		_mats[key] = m
	return _mats[key]


func _mesh(parent: Node, mesh: Mesh, pos: Vector3, color: Color, role := "paint", shadow := true,
		rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _m(role, color)
	mi.layers = vis
	mi.position = pos
	mi.rotation_degrees = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _box(parent: Node, size: Vector3, pos: Vector3, color: Color, role := "paint", shadow := true,
		rot := Vector3.ZERO) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return _mesh(parent, bm, pos, color, role, shadow, rot)


## top_r < 0: цилиндр, иначе усечённый конус (верхний радиус top_r)
func _cyl(parent: Node, r: float, h: float, pos: Vector3, color: Color, role := "paint", shadow := true,
		top_r := -1.0, rot := Vector3.ZERO) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r
	cm.top_radius = r if top_r < 0.0 else top_r
	cm.height = h
	cm.radial_segments = 16
	cm.rings = 1
	return _mesh(parent, cm, pos, color, role, shadow, rot)


func _ball(parent: Node, r: float, pos: Vector3, color: Color, role := "paint", shadow := true,
		squash := Vector3.ONE) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 16
	sm.rings = 8
	var mi := _mesh(parent, sm, pos, color, role, shadow)
	mi.scale = squash
	return mi


## Мелочь исчезает с расстояния (дешёвый LOD)
func _small(mi: MeshInstance3D) -> void:
	mi.visibility_range_end = 300.0
