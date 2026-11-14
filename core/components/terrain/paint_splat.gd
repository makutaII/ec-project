class_name PaintSplat extends Node

# XX claude-terra 13.13 K3 (новый файл)
###################################
## Сплэт-текстура краски и материалы оболочки (ATTN_13 §13.13). Заменяет временную разметку PaintView.
###################################
## Одна RGBA-текстура по миру: r трава, g скала, b гравий, a запас, PX пикселя на ячейку краски. Покрывает чанки PaintMap
## с запасом MARGIN и растёт при выходе краски за край (тогда перестраивается целиком). Мазок обновляет только изменённые
## чанки (blit 32 x 32) и один раз за кадр заливает картинку в текстуру. Геометрию не трогает.
## Материалы оболочки (ShaderMaterial plaster_surface) строятся от верхнего материала стадии листа, кэшируются и получают
## текстуру и её прямоугольник отсюда. Верхний материал не StandardMaterial3D (свой шейдер стиля): остаётся как есть, без краски.

const SHADER := preload("res://core/visual/materials/plaster_surface.gdshader")
const PX := 2
const CHUNK_PX := PaintMap.CHUNK * PX
## Запас вокруг краски, чанков
const MARGIN := 2
## Сторона текстуры не больше, пикселей
const MAX_PX := 4096
const MAX_CHUNKS := MAX_PX / CHUNK_PX

var map: PaintMap

var _img: Image
var _tex: ImageTexture
var _c0 := Vector2i.ZERO       # индекс первого чанка текстуры
var _cn := Vector2i.ZERO       # чанков по x и z; (0, 0) = краски нет
var _dirty := {}
var _mats := {}                # id верхнего материала -> {"base": Material, "mat": ShaderMaterial}
var _white: ImageTexture


func _ready() -> void:
	name = "PaintSplat"
	var wi := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	wi.fill(Color.WHITE)
	_white = ImageTexture.create_from_image(wi)
	_reset_empty()
	set_process(false)
	if map != null:
		map.changed.connect(_on_changed)


## Прямоугольник текстуры в мире: x0, z0, ширина, глубина. Нули: краски нет
func rect() -> Vector4:
	if _cn == Vector2i.ZERO or map == null or map.cell <= 0.0:
		return Vector4.ZERO
	var s := float(PaintMap.CHUNK) * map.cell
	return Vector4(float(_c0.x) * s, float(_c0.y) * s, float(_cn.x) * s, float(_cn.y) * s)


func texture() -> Texture2D:
	return _tex


## Увеличить каждую ячейку чанка (CHUNK x CHUNK x 4 байта) в PX x PX пикселей. Неверный размер: нули
static func chunk_pixels(bytes: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(CHUNK_PX * CHUNK_PX * 4)
	if bytes.size() != PaintMap.CHUNK_BYTES:
		return out
	for j in PaintMap.CHUNK:
		for i in PaintMap.CHUNK:
			var s := (j * PaintMap.CHUNK + i) * 4
			for dj in PX:
				for di in PX:
					var o := ((j * PX + dj) * CHUNK_PX + i * PX + di) * 4
					out[o] = bytes[s]
					out[o + 1] = bytes[s + 1]
					out[o + 2] = bytes[s + 2]
					out[o + 3] = bytes[s + 3]
	return out


func _reset_empty() -> void:
	_c0 = Vector2i.ZERO
	_cn = Vector2i.ZERO
	_dirty = {}
	_img = Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_img)
	_apply_all()


func _on_changed(keys: Array) -> void:
	if map.is_empty():
		_reset_empty()
		set_process(false)
		return
	var need := false
	if _cn == Vector2i.ZERO:
		need = true
	else:
		for k: Vector2i in keys:
			if k.x < _c0.x or k.y < _c0.y or k.x >= _c0.x + _cn.x or k.y >= _c0.y + _cn.y:
				need = true
				break
	if need:
		_reallocate()
		for k in map.chunk_keys():
			_dirty[k] = true
	else:
		for k: Vector2i in keys:
			_dirty[k] = true
	set_process(true)


## Рамка по всем чанкам карты и запас; больше MAX_CHUNKS по стороне не растёт (лишнее не рисуется)
func _reallocate() -> void:
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for k: Vector2i in map.chunk_keys():
		lo = Vector2i(mini(lo.x, k.x), mini(lo.y, k.y))
		hi = Vector2i(maxi(hi.x, k.x), maxi(hi.y, k.y))
	lo -= Vector2i(MARGIN, MARGIN)
	hi += Vector2i(MARGIN, MARGIN)
	var n := hi - lo + Vector2i.ONE
	if n.x > MAX_CHUNKS or n.y > MAX_CHUNKS:
		push_warning("[PaintSplat] краска шире %d чанков, лишнее не рисуется" % MAX_CHUNKS)
		n = Vector2i(mini(n.x, MAX_CHUNKS), mini(n.y, MAX_CHUNKS))
	_c0 = lo
	_cn = n
	_img = Image.create_empty(n.x * CHUNK_PX, n.y * CHUNK_PX, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(_img)
	_apply_all()


func _process(_delta: float) -> void:
	if _cn == Vector2i.ZERO:
		set_process(false)
		return
	for k: Vector2i in _dirty:
		if k.x < _c0.x or k.y < _c0.y or k.x >= _c0.x + _cn.x or k.y >= _c0.y + _cn.y:
			continue
		var px := chunk_pixels(map.chunk_bytes(k))
		var src := Image.create_from_data(CHUNK_PX, CHUNK_PX, false, Image.FORMAT_RGBA8, px)
		_img.blit_rect(src, Rect2i(0, 0, CHUNK_PX, CHUNK_PX), Vector2i((k.x - _c0.x) * CHUNK_PX, (k.y - _c0.y) * CHUNK_PX))
	_dirty = {}
	_tex.update(_img)
	set_process(false)


## --- Материалы ---

## Материал верха оболочки для стадии листа: основа стадии + краска. Кэшируется по материалу основы
func surface_material(style: TerrainStyle, stage: int) -> Material:
	return _material_for(style, style.get_top(stage))


## K3c. Материал стенки листа с бинтом: боковая основа стадии + та же краска. Краска стенки это краска на её верхнем крае
func wall_material(style: TerrainStyle, stage: int) -> Material:
	return _material_for(style, style.get_side(stage))


func _material_for(style: TerrainStyle, base: Material) -> Material:
	var std := base as StandardMaterial3D
	if std == null:
		return base
	var id := base.get_instance_id()
	if _mats.has(id):
		return _mats[id]["mat"]
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("base_tex", std.albedo_texture if std.albedo_texture != null else _white)
	m.set_shader_parameter("base_color", std.albedo_color)
	m.set_shader_parameter("base_scale", std.uv1_scale.x)
	m.set_shader_parameter("edge_noise", TerrainStyle.edge_noise())
	m.set_shader_parameter("grass_tex", style.get_paint_texture(PaintMap.GRASS))
	m.set_shader_parameter("rock_tex", style.get_paint_texture(PaintMap.ROCK))
	m.set_shader_parameter("gravel_tex", style.get_paint_texture(PaintMap.GRAVEL))
	m.set_shader_parameter("grass_color", TerrainStyle.PAINT_COLORS[PaintMap.GRASS])
	m.set_shader_parameter("rock_color", TerrainStyle.PAINT_COLORS[PaintMap.ROCK])
	m.set_shader_parameter("gravel_color", TerrainStyle.PAINT_COLORS[PaintMap.GRAVEL])
	m.set_shader_parameter("rock_layer_height", maxf(float(Global.settings.layer_height), 0.05))
	_apply(m)
	_mats[id] = {"base": base, "mat": m}   # base держим, чтобы id не достался другому ресурсу
	return m


func _apply(m: ShaderMaterial) -> void:
	m.set_shader_parameter("splat", _tex)
	m.set_shader_parameter("splat_rect", rect())
	m.set_shader_parameter("splat_shift", map.cell * 0.5 if map != null else 0.0)


func _apply_all() -> void:
	for id in _mats:
		_apply(_mats[id]["mat"])
