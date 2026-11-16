class_name PaintLayers extends RefCounted

# XX claude-library (новый файл)
########################
## PaintLayers. Слои кисти из исполнения как накладки материала (ATTN_22 §22.7.2.1, шаг C2.1b)
########################
## Игра не строит SubViewport: слой кисти это PNG (поле data слоя), из него делается ImageTexture с мипмапами и
## накладка (overlay.gdshader). Одинаковые байты PNG дают одну общую текстуру (кэш по SHA-1 содержимого): десять вагонов
## с одним исполнением не держат десять копий. У PackedByteArray нет hash(), поэтому ключ считает HashingContext. Library при редактировании подставляет живую текстуру движка
## (PaintEngine.make_overlay), для сохранённых слоёв без движка берёт PNG из файла (Model Studio).

const OVERLAY_SHADER := preload("res://core/library/paint/overlay.gdshader")

static var _cache := {}


## Накладка с текстурой слоя
static func make_overlay(tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = OVERLAY_SHADER
	m.set_shader_parameter("layer", tex)
	return m


## Текстура из байт PNG (RGBA8, с мипмапами); null, если картинка не читается. Кэшируется по содержимому
static func texture_from_png(bytes: PackedByteArray) -> Texture2D:
	if bytes.is_empty():
		return null
	var key := _key(bytes)
	if _cache.has(key):
		return _cache[key]
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		push_warning("PaintLayers: слой кисти не читается как PNG")
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## Ключ кэша: SHA-1 байт PNG плюс длина (дёшево: PNG слоя в десятки килобайт)
static func _key(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(bytes)
	return "%d:%s" % [bytes.size(), ctx.finish().hex_encode()]


## Накладки сущности: имя меша -> ShaderMaterial. Только видимые слои, у которых PNG лежит внутри (data).
## Слой общего атласа даёт накладку на каждый меш из его списка (текстура одна)
static func overlays_from(variant: Dictionary) -> Dictionary:
	var out := {}
	var pv: Variant = variant.get("paint")
	if not (pv is Dictionary):
		return out
	for layer in PaintData.texture_layers(pv):
		if not bool(layer.get("visible", true)):
			continue
		var data: Variant = layer.get("data")
		if not (data is PackedByteArray):
			continue
		var tex := texture_from_png(data)
		if tex == null:
			continue
		for mesh_name in PaintData.layer_meshes(layer):
			out[mesh_name] = make_overlay(tex)
	return out


static func clear_cache() -> void:
	_cache.clear()
