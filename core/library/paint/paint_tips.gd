class_name PaintTips extends RefCounted

# XX claude-library (новый файл)
########################
## PaintTips. Текстуры концов кисти (ATTN_22 §22.7.2.1, шаг C2.2)
########################
## Конец кисти это картинка плотности 128x128 (канал R, 0 нет краски, 1 полная). Рисуются кодом при первом обращении,
## одинаковы при каждом запуске (фиксированное зерно), файлов нет. Оси картинки: x вдоль направления штриха, y поперёк.
## bristle: щетина, полосы вдоль штриха (плотность зависит почти только от y), поэтому штампы вдоль мазка сливаются
## в сплошные полосы; sponge: пористое пятно; splatter: россыпь точек разной величины.

const SIZE := 128
const ORDER := ["bristle", "sponge", "splatter"]

static var _cache := {}      # id -> {image, texture}


static func has(id: String) -> bool:
	return ORDER.has(id)


## Картинка конца (L8, SIZE x SIZE). null: id нет (пустой id и «white» значат «без текстуры»)
static func image(id: String) -> Image:
	if not has(id):
		return null
	return _entry(id)["image"]


## Текстура конца для шейдера. null: без текстуры
static func texture(id: String) -> Texture2D:
	if not has(id):
		return null
	return _entry(id)["texture"]


static func _entry(id: String) -> Dictionary:
	if not _cache.has(id):
		var img := _build(id)
		_cache[id] = {"image": img, "texture": ImageTexture.create_from_image(img)}
	return _cache[id]


static func _build(id: String) -> Image:
	var vals := PackedFloat32Array()
	vals.resize(SIZE * SIZE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260116 + ORDER.find(id)
	match id:
		"bristle":
			_fill_bristle(vals, rng)
		"sponge":
			_fill_sponge(vals, rng)
		"splatter":
			_fill_splatter(vals, rng)
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_L8)
	for y in SIZE:
		for x in SIZE:
			var v := clampf(vals[y * SIZE + x], 0.0, 1.0)
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return img


## Полосы вдоль x: у каждого ряда своя плотность (группы щетинок), по x лёгкая неровность
static func _fill_bristle(vals: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var rows := PackedFloat32Array()
	rows.resize(SIZE)
	var y := 0
	while y < SIZE:
		var width := rng.randi_range(1, 3)                     # щетинка 1..3 ряда
		var level := 0.25 + 0.75 * pow(rng.randf(), 0.6)       # большинство плотные, часть редкие
		if rng.randf() < 0.12:
			level = 0.0                                        # просвет между пучками
		for k in width:
			if y + k < SIZE:
				rows[y + k] = level
		y += width
	for yy in SIZE:
		for x in SIZE:
			var wobble := 1.0 - 0.18 * rng.randf()
			vals[yy * SIZE + x] = rows[yy] * wobble


## Пористое пятно: два масштаба шума значений, затем контраст
static func _fill_sponge(vals: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	var grids := []
	for cells in [6, 14]:
		var g := PackedFloat32Array()
		g.resize((cells + 1) * (cells + 1))
		for i in g.size():
			g[i] = rng.randf()
		grids.append({"cells": cells, "g": g})
	for y in SIZE:
		for x in SIZE:
			var acc := 0.0
			var wsum := 0.0
			var weight := 1.0
			for e in grids:
				acc += _value_noise(e["g"], int(e["cells"]), float(x) / SIZE, float(y) / SIZE) * weight
				wsum += weight
				weight *= 0.55
			vals[y * SIZE + x] = smoothstep(0.38, 0.62, acc / wsum)


static func _value_noise(g: PackedFloat32Array, cells: int, u: float, v: float) -> float:
	var fx := u * cells
	var fy := v * cells
	var x0 := mini(int(floor(fx)), cells - 1)
	var y0 := mini(int(floor(fy)), cells - 1)
	var tx := smoothstep(0.0, 1.0, fx - x0)
	var ty := smoothstep(0.0, 1.0, fy - y0)
	var w := cells + 1
	var a := lerpf(g[y0 * w + x0], g[y0 * w + x0 + 1], tx)
	var b := lerpf(g[(y0 + 1) * w + x0], g[(y0 + 1) * w + x0 + 1], tx)
	return lerpf(a, b, ty)


## Россыпь точек: много мелких, несколько крупных; края мягкие
static func _fill_splatter(vals: PackedFloat32Array, rng: RandomNumberGenerator) -> void:
	for i in 64:
		var r := 1.2 + 4.8 * pow(rng.randf(), 2.2)
		var cx := rng.randf_range(6.0, SIZE - 6.0)
		var cy := rng.randf_range(6.0, SIZE - 6.0)
		var x0 := maxi(int(floor(cx - r - 1.0)), 0)
		var x1 := mini(int(ceil(cx + r + 1.0)), SIZE - 1)
		var y0 := maxi(int(floor(cy - r - 1.0)), 0)
		var y1 := mini(int(ceil(cy + r + 1.0)), SIZE - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var d := Vector2(x + 0.5 - cx, y + 0.5 - cy).length()
				var v := 1.0 - smoothstep(r * 0.55, r, d)
				var idx := y * SIZE + x
				vals[idx] = maxf(vals[idx], v)
