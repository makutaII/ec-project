class_name BuildingStyles extends RefCounted

# XX claude-library L7 (новый файл)
########################
## BuildingStyles. Стили зданий: материалы пяти поверхностей (ATTN_22 §22.7.6, шаг L7)
########################
## Материалы собирает TrackMaterialBuilder из текстур набора house_01 (res://data/import/textures). UV меша в ю,
## тайл в ю задаётся в стиле («mesh_uv_units» сборщика). Размеры тайлов подобраны на глаз: правятся здесь.
## Нет файла текстуры: поверхность остаётся однотонной (цвет стиля), игра не падает.

enum Surf { WALL, ROOF, PLINTH, TRIM, GLASS }
const SURF_COUNT := 5
const DEFAULT := &"brick"
const TEX_DIR := "res://data/import/textures/130275-1_T_"

## wall, roof, plinth: {tex: часть имени файла (Albedo и Normal), tile: ю на тайл, tint, rough}. trim: цвет окон и дверей
const STYLES := {
	&"brick": {
		"title": "Кирпич",
		"wall": {"tex": "Ziegel", "tile": 3.0, "tint": Color(1, 1, 1), "rough": 0.85},
		"roof": {"tex": "Zink", "tile": 2.5, "tint": Color(0.80, 0.85, 0.92), "rough": 0.6},
		"plinth": {"tex": "Granit", "tile": 2.0, "tint": Color(1, 1, 1), "rough": 0.9},
		"trim": Color(0.93, 0.91, 0.85),
	},
	&"plaster": {
		"title": "Штукатурка",
		"wall": {"tex": "Putz", "tile": 3.0, "tint": Color(1, 1, 1), "rough": 0.9},
		"roof": {"tex": "Zink", "tile": 2.5, "tint": Color(1.0, 0.55, 0.42), "rough": 0.6},
		"plinth": {"tex": "Granit", "tile": 2.0, "tint": Color(0.9, 0.9, 0.9), "rough": 0.9},
		"trim": Color(0.42, 0.28, 0.18),
	},
	&"stone": {
		"title": "Камень",
		"wall": {"tex": "Mauer", "tile": 4.0, "tint": Color(1, 1, 1), "rough": 0.9},
		"roof": {"tex": "Zink", "tile": 2.5, "tint": Color(0.62, 0.62, 0.68), "rough": 0.6},
		"plinth": {"tex": "Granit", "tile": 2.0, "tint": Color(0.8, 0.8, 0.8), "rough": 0.9},
		"trim": Color(0.88, 0.86, 0.80),
	},
}

const GLASS_COLOR := Color(0.10, 0.13, 0.17)

## style id -> Array[Material] (индексы Surf). Один набор на все здания стиля
static var _cache := {}


static func has_style(id: StringName) -> bool:
	return STYLES.has(id)


static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for k in STYLES:
		out.append(k)
	return out


static func title(id: StringName) -> String:
	return str((STYLES.get(id, {}) as Dictionary).get("title", String(id)))


## Материалы по поверхностям. Неизвестный стиль даёт стиль по умолчанию
static func materials(id: StringName) -> Array[Material]:
	if not STYLES.has(id):
		id = DEFAULT
	if _cache.has(id):
		return _cache[id]
	var st: Dictionary = STYLES[id]
	var out: Array[Material] = []
	out.resize(SURF_COUNT)
	out[Surf.WALL] = _textured(st["wall"])
	out[Surf.ROOF] = _textured(st["roof"])
	out[Surf.PLINTH] = _textured(st["plinth"])
	var trim := StandardMaterial3D.new()
	trim.albedo_color = st["trim"]
	trim.roughness = 0.6
	out[Surf.TRIM] = trim
	var glass := StandardMaterial3D.new()
	glass.albedo_color = GLASS_COLOR
	glass.roughness = 0.15
	glass.metallic_specular = 0.8
	out[Surf.GLASS] = glass
	_cache[id] = out
	return out


## Сбросить кэш (после правки стилей в редакторе или в тесте)
static func clear_cache() -> void:
	_cache.clear()


static func _textured(p: Dictionary) -> StandardMaterial3D:
	var tex := {}
	var base := TEX_DIR + str(p["tex"])
	var albedo := _load_tex(base + "_Albedo.png")
	if albedo != null:
		tex["albedo"] = albedo
	var normal := _load_tex(base + "_Normal.png")
	if normal != null:
		tex["normal"] = normal
	var t := float(p["tile"])
	return TrackMaterialBuilder.build(tex, {
		"mesh_uv_units": true, "tile": Vector2(t, t), "tint": p["tint"],
		"roughness": float(p["rough"]), "use_ao": false,
	})


static func _load_tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path) as Texture2D
