class_name PaintSamples extends RefCounted

# XX claude-library (новый файл)
########################
## PaintSamples. Образцы кисти (ATTN_22 §22.7.2.1, шаг C2.3)
########################
## Образец это бесшовная текстура 256x256 RGBA: цвет и «пятнистость» (альфа). Кисть с образцом красит не плоским цветом,
## а цветом образца, который берётся по позиции на модели (triplanar в шейдере штампа), поэтому рисунок не рвётся на
## швах UV2 и не растягивается. Образец запекается в слой краски при штампе, формат слоя не меняется.
## Встроенные образцы рисуются кодом при первом обращении с фиксированным зерном (FastNoiseLite и линии с заворотом).
## Свои образцы это картинки (png, jpg, webp) в папках USER_DIRS: каждый файл становится образцом с id "f:<имя файла>"
## и названием из имени. Картинка должна быть бесшовной (края стыкуются), альфа-канал это пятнистость (без альфы
## образец сплошной), цвет как есть. Список читается при входе в режим «Кисть» (refresh).

const SIZE := 256
const LEVEL := 3          ## с какого уровня правил (paint.level) образцы доступны
const ORDER := ["rust", "dirt", "soot", "wear", "streaks"]
const USER_DIRS := ["res://art/paint_samples", "user://library/paint_samples"]
const FILE_PREFIX := "f:"
const FILE_EXT := ["png", "jpg", "jpeg", "webp"]
const NAMES := {
	"rust": "Ржавчина", "dirt": "Грязь", "soot": "Копоть", "wear": "Потёртость", "streaks": "Подтёки",
}

static var dirs: Array = USER_DIRS.duplicate()   # где искать свои образцы (тест подменяет)
static var _cache := {}      # id -> {image, texture}
static var _files := {}      # id файла -> путь
static var _file_tex := {}   # id файла -> Texture2D


static func has(id: String) -> bool:
	return ORDER.has(id) or _files.has(id)


## Все образцы по порядку: встроенные, затем файлы по имени
static func ids() -> Array[String]:
	var out: Array[String] = []
	for id in ORDER:
		out.append(id)
	var names := _files.keys()
	names.sort()
	for id in names:
		out.append(str(id))
	return out


static func title(id: String) -> String:
	if _files.has(id):
		return id.trim_prefix(FILE_PREFIX).replace("_", " ")
	return str(NAMES.get(id, ""))


## Перечитать папки со своими образцами (USER_DIRS). Убранные файлы пропадают, изменённые загружаются заново
static func refresh() -> void:
	var found := {}
	for dir in dirs:
		var da := DirAccess.open(str(dir))
		if da == null:
			continue
		for f in da.get_files():
			var name := f
			# в собранной игре картинки лежат как «имя.png.import» или «имя.png.remap»
			for suffix in [".import", ".remap"]:
				if name.ends_with(suffix):
					name = name.trim_suffix(suffix)
			if not FILE_EXT.has(name.get_extension().to_lower()):
				continue
			found[FILE_PREFIX + name.get_basename()] = str(dir).path_join(name)
	for id in _files.keys():
		if not found.has(id) or found[id] != _files[id]:
			_file_tex.erase(id)
	_files = found


## Путь картинки файлового образца ("" для встроенных)
static func file_path(id: String) -> String:
	return str(_files.get(id, ""))


## Картинка встроенного образца (RGBA8, SIZE x SIZE). null: id нет или образец из файла
static func image(id: String) -> Image:
	if not ORDER.has(id):
		return null
	return _entry(id)["image"]


## Текстура образца для шейдера (повторяется). null: id нет или файл не читается
static func texture(id: String) -> Texture2D:
	if _files.has(id):
		return _file_texture(id)
	if not ORDER.has(id):
		return null
	return _entry(id)["texture"]


static func _file_texture(id: String) -> Texture2D:
	if _file_tex.has(id):
		return _file_tex[id]
	var path := str(_files[id])
	var tex: Texture2D = null
	if path.begins_with("res://"):
		tex = ResourceLoader.load(path) as Texture2D
	else:
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty():
			tex = ImageTexture.create_from_image(img)
	_file_tex[id] = tex
	return tex


static func _entry(id: String) -> Dictionary:
	if not _cache.has(id):
		var img := _build(id)
		_cache[id] = {"image": img, "texture": ImageTexture.create_from_image(img)}
	return _cache[id]


## Бесшовный шум 0..1 (байты L8). freq: частота шума на пиксель
static func _noise(seed_value: int, freq: float, octaves: int) -> PackedByteArray:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed_value
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	return n.get_seamless_image(SIZE, SIZE).get_data()


static func _build(id: String) -> Image:
	var px := PackedByteArray()
	px.resize(SIZE * SIZE * 4)
	var seed_base := 4100 + ORDER.find(id) * 17
	var big := _noise(seed_base, 0.012, 4)         # крупные пятна
	var fine := _noise(seed_base + 1, 0.06, 3)     # мелкая зернистость
	match id:
		"rust":
			_fill_rust(px, big, fine)
		"dirt":
			_fill_dirt(px, big, fine)
		"soot":
			_fill_soot(px, big, fine)
		"wear":
			_fill_wear(px, big, seed_base)
		"streaks":
			_fill_streaks(px, big, _noise(seed_base + 2, 0.15, 2))
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, px)


static func _put(px: PackedByteArray, i: int, c: Color, a: float) -> void:
	px[i * 4] = int(clampf(c.r, 0.0, 1.0) * 255.0 + 0.5)
	px[i * 4 + 1] = int(clampf(c.g, 0.0, 1.0) * 255.0 + 0.5)
	px[i * 4 + 2] = int(clampf(c.b, 0.0, 1.0) * 255.0 + 0.5)
	px[i * 4 + 3] = int(clampf(a, 0.0, 1.0) * 255.0 + 0.5)


## Ржавчина: рыжие и бурые зёрна, неровными пятнами
static func _fill_rust(px: PackedByteArray, big: PackedByteArray, fine: PackedByteArray) -> void:
	var dark := Color(0.30, 0.12, 0.06)
	var warm := Color(0.74, 0.36, 0.13)
	for i in SIZE * SIZE:
		var f1 := big[i] / 255.0
		var f2 := fine[i] / 255.0
		var c := dark.lerp(warm, f2) * (0.75 + 0.25 * f1)
		_put(px, i, c, smoothstep(0.42, 0.62, f1) * (0.65 + 0.35 * f2))


## Грязь: коричнево-серая, плотная по большей части площади
static func _fill_dirt(px: PackedByteArray, big: PackedByteArray, fine: PackedByteArray) -> void:
	var light := Color(0.36, 0.29, 0.21)
	var dark := Color(0.19, 0.15, 0.11)
	for i in SIZE * SIZE:
		var f1 := big[i] / 255.0
		var f2 := fine[i] / 255.0
		_put(px, i, light.lerp(dark, f2), 0.4 + 0.6 * smoothstep(0.3, 0.7, f1))


## Копоть: почти чёрная, мягкими облаками
static func _fill_soot(px: PackedByteArray, big: PackedByteArray, fine: PackedByteArray) -> void:
	for i in SIZE * SIZE:
		var f1 := big[i] / 255.0
		var f2 := fine[i] / 255.0
		var v := 0.05 + 0.03 * f2
		_put(px, i, Color(v, v, v + 0.005), 0.9 * smoothstep(0.3, 0.7, f1))


## Потёртость: светлый металл, тонкие царапины (линии с заворотом через край) и слабое общее пятно
static func _fill_wear(px: PackedByteArray, big: PackedByteArray, seed_value: int) -> void:
	var metal := Color(0.78, 0.78, 0.74)
	var alpha := PackedFloat32Array()
	alpha.resize(SIZE * SIZE)
	for i in SIZE * SIZE:
		alpha[i] = 0.12 * smoothstep(0.35, 0.75, big[i] / 255.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for k in 90:
		var x := rng.randf() * SIZE
		var y := rng.randf() * SIZE
		var ang := rng.randf_range(-0.5, 0.5) + (PI * 0.5 if rng.randf() < 0.25 else 0.0)
		var len_px := rng.randf_range(16.0, 70.0)
		var strength := rng.randf_range(0.55, 0.95)
		var d := Vector2(cos(ang), sin(ang))
		var s := 0.0
		while s < len_px:
			var ix := posmod(int(x + d.x * s), SIZE)
			var iy := posmod(int(y + d.y * s), SIZE)
			var idx := iy * SIZE + ix
			alpha[idx] = maxf(alpha[idx], strength * (1.0 - s / len_px * 0.5))
			s += 0.5
	for i in SIZE * SIZE:
		_put(px, i, metal, alpha[i])


## Подтёки: вертикальные полосы разной плотности (ось v образца вдоль вертикали модели на боковых гранях)
static func _fill_streaks(px: PackedByteArray, big: PackedByteArray, streak: PackedByteArray) -> void:
	var light := Color(0.24, 0.21, 0.17)
	var dark := Color(0.12, 0.10, 0.08)
	for y in SIZE:
		for x in SIZE:
			var i := y * SIZE + x
			var s := smoothstep(0.5, 0.78, streak[x] / 255.0)      # полоса задана колонкой x
			var f1 := big[i] / 255.0
			_put(px, i, light.lerp(dark, f1), s * (0.3 + 0.7 * f1))
