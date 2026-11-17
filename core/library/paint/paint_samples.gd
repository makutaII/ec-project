class_name PaintSamples extends RefCounted

# XX claude-library (новый файл)
########################
## PaintSamples. Образцы кисти (ATTN_22 §22.7.2.1, шаг C2.3)
########################
## Образец это бесшовная текстура 256x256 RGBA: цвет и «пятнистость» (альфа). Кисть с образцом красит не плоским цветом,
## а цветом образца, который берётся по позиции на модели (triplanar в шейдере штампа), поэтому рисунок не рвётся на
## швах UV2 и не растягивается. Образец запекается в слой краски при штампе, формат слоя не меняется.
## Рисуются кодом при первом обращении с фиксированным зерном (FastNoiseLite и линии с заворотом), файлов нет.

const SIZE := 256
const LEVEL := 3          ## с какого уровня правил (paint.level) образцы доступны
const ORDER := ["rust", "dirt", "soot", "wear", "streaks"]
const NAMES := {
	"rust": "Ржавчина", "dirt": "Грязь", "soot": "Копоть", "wear": "Потёртость", "streaks": "Подтёки",
}

static var _cache := {}      # id -> {image, texture}


static func has(id: String) -> bool:
	return ORDER.has(id)


static func title(id: String) -> String:
	return str(NAMES.get(id, ""))


## Картинка образца (RGBA8, SIZE x SIZE). null: id нет
static func image(id: String) -> Image:
	if not has(id):
		return null
	return _entry(id)["image"]


## Текстура образца для шейдера (повторяется). null: id нет
static func texture(id: String) -> Texture2D:
	if not has(id):
		return null
	return _entry(id)["texture"]


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
