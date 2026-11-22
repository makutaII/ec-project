class_name PaintDecals extends RefCounted

# XX claude-library (новый файл)
########################
## PaintDecals. Декали кисти (ATTN_22 §22.7.2.1, шаг C2.4)
########################
## Декаль это картинка RGBA, которая ставится на модель одним кликом: номер, звезда, полоса. Лежит в касательной плоскости
## под курсором, поворачивается и зеркалится, цвет берётся из картинки или красится цветом палитры (у белых форм).
## Встроенные формы (звезда, стрелка, крест, кольцо, полоса) рисуются кодом (расстояние до многоугольника, сглаженный край).
## Свои декали это картинки (png, jpg, webp) в папках USER_DIRS: id "f:<имя файла>", название из имени. Альфа-канал задаёт
## форму, цвет берётся как есть. Кроме того, из папок образцов (MIXED_DIRS) берутся файлы, имя которых начинается
## на «decal» (decal_01.png). Список читается при входе в режим «Кисть» (refresh).
## Текстуры готовятся с краевой подчисткой цвета (fix_alpha_edges) и мипмапами, чтобы мелкая декаль на модели не искрила.

const SIZE := 256
const MAX_PX := 512             ## картинки больше уменьшаются до этого размера по большей стороне
const LEVEL := 3                ## с какого уровня правил (paint.level) декали доступны
const ORDER := ["star", "arrow", "cross", "ring", "stripe"]
const NAMES := {"star": "Звезда", "arrow": "Стрелка", "cross": "Крест", "ring": "Кольцо", "stripe": "Полоса"}
const USER_DIRS := ["res://data/library/paint_decals", "user://library/paint_decals"]
const MIXED_DIRS := ["res://data/library/paint_samples", "user://library/paint_samples"]
const DECAL_PREFIX := "decal"
const FILE_PREFIX := "f:"
const FILE_EXT := ["png", "jpg", "jpeg", "webp"]

static var dirs: Array = USER_DIRS.duplicate()         # где искать свои декали (тест подменяет)
static var mixed_dirs: Array = MIXED_DIRS.duplicate()  # папки образцов: оттуда берутся только файлы decal* (в образцах они тоже остаются)
static var _files := {}      # id файла -> путь
static var _cache := {}      # id -> {image, texture, flipped}


static func has(id: String) -> bool:
	return ORDER.has(id) or _files.has(id)


static func is_builtin(id: String) -> bool:
	return ORDER.has(id)


## Все декали по порядку: встроенные, затем файлы по имени
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


## Перечитать папки со своими декалями. Убранные и изменённые файлы сбрасываются из кэша
static func refresh() -> void:
	var found := {}
	var all_dirs: Array = dirs.duplicate()
	all_dirs.append_array(mixed_dirs)
	for dir in all_dirs:
		var only_decals := mixed_dirs.has(dir) and not dirs.has(dir)
		var da := DirAccess.open(str(dir))
		if da == null:
			continue
		for f in da.get_files():
			var name := f
			for suffix in [".import", ".remap"]:      # в собранной игре: «имя.png.import» или «имя.png.remap»
				if name.ends_with(suffix):
					name = name.trim_suffix(suffix)
			if not FILE_EXT.has(name.get_extension().to_lower()):
				continue
			if only_decals and not name.get_basename().to_lower().begins_with(DECAL_PREFIX):
				continue
			found[FILE_PREFIX + name.get_basename()] = str(dir).path_join(name)
	for id in _files.keys():
		if not found.has(id) or found[id] != _files[id]:
			_cache.erase(id)
	_files = found


static func file_path(id: String) -> String:
	return str(_files.get(id, ""))


## Картинка декали (RGBA8, готовая к показу: подчищенные края, мипмапы). null: id нет или файл не читается
static func image(id: String) -> Image:
	var e := _entry(id)
	return e.get("image") if not e.is_empty() else null


## Текстура декали для шейдера (с мипмапами). null: id нет или файл не читается
static func texture(id: String) -> Texture2D:
	var e := _entry(id)
	return e.get("texture") if not e.is_empty() else null


## Та же текстура, отражённая слева направо (предпросмотр зеркальной декали)
static func flipped_texture(id: String) -> Texture2D:
	var e := _entry(id)
	if e.is_empty():
		return null
	if not e.has("flipped"):
		var img: Image = (e["image"] as Image).duplicate()
		img.flip_x()
		img.generate_mipmaps()
		e["flipped"] = ImageTexture.create_from_image(img)
	return e["flipped"]


## У картинки есть прозрачность (хотя бы один неполностью непрозрачный пиксель): у трафарета рисунок это непрозрачная часть
static func has_alpha(id: String) -> bool:
	var img := image(id)
	return img != null and img.detect_alpha() != Image.ALPHA_NONE


## Полуразмеры декали в долях радиуса штампа: большая сторона 1, меньшая по пропорции картинки
static func aspect_box(id: String) -> Vector2:
	var img := image(id)
	if img == null:
		return Vector2.ONE
	var w := float(img.get_width())
	var h := float(img.get_height())
	var m := maxf(maxf(w, h), 1.0)
	return Vector2(w / m, h / m)


static func _entry(id: String) -> Dictionary:
	if not has(id):
		return {}
	if not _cache.has(id):
		var img := _build(id) if ORDER.has(id) else _load_file(str(_files[id]))
		if img == null:
			return {}
		img.generate_mipmaps()
		_cache[id] = {"image": img, "texture": ImageTexture.create_from_image(img)}
	return _cache[id]


static func _load_file(path: String) -> Image:
	var img: Image = null
	if path.begins_with("res://") and FileAccess.file_exists(path + ".import"):
		var tex := ResourceLoader.load(path) as Texture2D      # картинка импортирована Godot
		if tex != null:
			img = tex.get_image()
	if img == null or img.is_empty():
		img = Image.load_from_file(path)                       # не импортированная или из user://
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var big := maxi(img.get_width(), img.get_height())
	if big > MAX_PX:
		var k := float(MAX_PX) / big
		img.resize(maxi(int(img.get_width() * k), 1), maxi(int(img.get_height() * k), 1), Image.INTERPOLATE_LANCZOS)
	img.fix_alpha_edges()
	return img


# --- встроенные формы ---

static func _build(id: String) -> Image:
	var w := SIZE
	var h := SIZE
	if id == "stripe":
		h = SIZE / 4                      # полоса 4:1
	var px := PackedByteArray()
	px.resize(w * h * 4)
	var pts := _polygon(id)
	var aa := 2.0 / SIZE                  # один пиксель в единицах формы (форма лежит в квадрате от -1 до 1)
	for y in h:
		for x in w:
			var p := Vector2((x + 0.5) / w * 2.0 - 1.0, 1.0 - (y + 0.5) / h * 2.0)   # y вверх
			var d := 0.0
			match id:
				"ring":
					d = absf(p.length() - 0.68) - 0.2
				"stripe":
					d = _rounded_box(Vector2((x + 0.5) - w * 0.5, (y + 0.5) - h * 0.5), Vector2(w * 0.5 - 4.0, h * 0.5 - 4.0), 10.0) * aa
				_:
					d = _poly_sdf(p, pts)
			var i := (y * w + x) * 4
			px[i] = 255
			px[i + 1] = 255
			px[i + 2] = 255
			px[i + 3] = int(clampf(0.5 - d / aa, 0.0, 1.0) * 255.0 + 0.5)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)


static func _polygon(id: String) -> PackedVector2Array:
	var pts := PackedVector2Array()
	match id:
		"star":
			for k in 10:
				var r := 0.95 if k % 2 == 0 else 0.38
				var a := PI * 0.5 + k * PI / 5.0
				pts.append(Vector2(cos(a), sin(a)) * r)
		"arrow":
			pts = PackedVector2Array([Vector2(-0.9, -0.17), Vector2(0.1, -0.17), Vector2(0.1, -0.55), Vector2(0.95, 0.0),
				Vector2(0.1, 0.55), Vector2(0.1, 0.17), Vector2(-0.9, 0.17)])
		"cross":
			var a := 0.28
			var e := 0.9
			pts = PackedVector2Array([Vector2(-a, -e), Vector2(a, -e), Vector2(a, -a), Vector2(e, -a), Vector2(e, a), Vector2(a, a),
				Vector2(a, e), Vector2(-a, e), Vector2(-a, a), Vector2(-e, a), Vector2(-e, -a), Vector2(-a, -a)])
	return pts


## Расстояние со знаком от точки до многоугольника (отрицательное внутри)
static func _poly_sdf(p: Vector2, v: PackedVector2Array) -> float:
	var n := v.size()
	var d := (p - v[0]).dot(p - v[0])
	var s := 1.0
	var j := n - 1
	for i in n:
		var e := v[j] - v[i]
		var w := p - v[i]
		var b := w - e * clampf(w.dot(e) / e.dot(e), 0.0, 1.0)
		d = minf(d, b.dot(b))
		var c1 := p.y >= v[i].y
		var c2 := p.y < v[j].y
		var c3 := e.x * w.y > e.y * w.x
		if (c1 and c2 and c3) or (not c1 and not c2 and not c3):
			s = -s
		j = i
	return s * sqrt(d)


## Расстояние со знаком до скруглённого прямоугольника (единицы те же, что у p)
static func _rounded_box(p: Vector2, half: Vector2, radius: float) -> float:
	var q := p.abs() - half + Vector2(radius, radius)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - radius
