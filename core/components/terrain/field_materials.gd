class_name FieldMaterials extends Resource

# XX claude-terra 13.14 H4 (новый файл), H2b (палитра материалов из карточек кистей)
###################################
## Палитра материалов поверхности поля (ATTN_13 §13.14, H4, H2b). До MAX_SLOTS материалов на игру: текстура, оттенок, повтор.
## Узел поля хранит слот материала (TerrainField.MAT_SHIFT), шейдер берёт текстуру слота из Texture2DArray.
## Слоты 0..2 служебные: SLOT_BASE плоская поверхность (узлы без кисти), SLOT_CLIFF крутые склоны, SLOT_BED ложе трака (H5).
## Остальные слоты выдаются поверхностям кистей (TerrainBrush.surfaces) по порядку: карточки в brush_dirs по имени файла, поверхности
## по порядку в карточке; одинаковые (текстура, оттенок, повтор) делят слот, в том числе со служебными.
## Чтобы кисть получила свою текстуру, достаточно назначить texture в её поверхности. Новая текстура занимает свободный слот.
## Порядок слотов строится из каталога при каждом запуске: добавление или удаление карточек кистей сдвигает слоты (сейвы с картой
## материалов из другого набора кистей перекрасятся).
## Набор один на всю игру (data/terrain/field_materials.tres, его читает FieldView).
###################################

const PATH := "res://data/terrain/field_materials.tres"
const SLOT_BASE := 0
const SLOT_CLIFF := 1
const SLOT_BED := 2
const SLOT_FIRST := 3
const MAX_SLOTS := TerrainField.MAT_MASK + 1

## Плоская поверхность, на которую кисть не красит материалом (слот 0)
@export var base: FieldSurface
## Крутые склоны уходят в этот материал (слот 1)
@export var cliff: FieldSurface
## Ложе трака и фиксированная насыпь (слот 2)
@export var bed: FieldSurface
## Папки карточек, где ищутся кисти рельефа
@export var brush_dirs: PackedStringArray = ["res://data/terrain/objects/"]
## Насколько рваной получается граница двух материалов (0 только плавный переход ячеек, 1 сильно рваная)
@export_range(0.0, 1.0, 0.05) var edge_noise := 0.35
## Частота шума границы, 1/ю (больше значение: мельче рваность)
@export_range(0.5, 8.0, 0.1) var edge_scale := 2.5
## Сторона слоя текстуры в массиве, пикс. Все текстуры приводятся к ней
@export_range(256, 2048, 256) var layer_size := 1024

var _slots: Array[FieldSurface] = []
var _warned := {}


## Общая палитра игры (ресурс кэшируется загрузчиком)
static func shared() -> FieldMaterials:
	return load(PATH) as FieldMaterials


## Палитра: служебные слоты и поверхности кистей. Строится один раз, set_brush_surfaces перестраивает
func slots() -> Array[FieldSurface]:
	if _slots.is_empty():
		set_brush_surfaces(_catalog_surfaces())
	return _slots


## Перестроить палитру из списка поверхностей кистей (каталог или тест)
func set_brush_surfaces(list: Array[FieldSurface]) -> void:
	_slots.clear()
	_slots.append(base if base != null else FieldSurface.new())
	_slots.append(cliff if cliff != null else FieldSurface.new())
	_slots.append(bed if bed != null else FieldSurface.new())
	_warned.clear()
	for s in list:
		if s != null:
			slot_of(s, true)


## Слот поверхности. add: занять свободный слот, если такой материал ещё не в палитре. Нет места или поверхности: слот 0
func slot_of(s: FieldSurface, add := false) -> int:
	if s == null:
		return SLOT_BASE
	if _slots.is_empty() and not add:
		slots()
	var key := s.material_key()
	for i in _slots.size():
		if _slots[i] == s or _slots[i].material_key() == key:
			return i
	if add and _slots.size() < MAX_SLOTS:
		_slots.append(s)
		return _slots.size() - 1
	if not _warned.has(key):
		_warned[key] = true
		push_warning("FieldMaterials: нет слота для поверхности %s (занято %d из %d), красим базовым" % [key, _slots.size(), MAX_SLOTS])
	return SLOT_BASE


func _catalog_surfaces() -> Array[FieldSurface]:
	var res: Array[FieldSurface] = []
	for dir in brush_dirs:
		for path in EntityCatalogProvider.list_resources(dir):
			var es := load(path) as EntitySetting
			if es == null:
				continue
			for c in es.components:
				var tb := c as TerrainBrush
				if tb != null:
					for s in tb.surfaces:
						if s != null:
							res.append(s)
	return res


## Выставить параметры шейдера поверхности поля (field_surface.gdshader): массив текстур слотов, оттенки, повторы
func apply(mat: ShaderMaterial) -> void:
	var sl := slots()
	var tints := PackedColorArray()
	var tiles := PackedFloat32Array()
	var imgs: Array[Image] = []
	for i in MAX_SLOTS:
		var s: FieldSurface = sl[i] if i < sl.size() else null
		tints.append(s.tint if s != null else Color.WHITE)
		tiles.append(maxf(s.tile, 0.1) if s != null else 3.0)
	for s in sl:
		imgs.append(_layer_image(s))
	var arr := Texture2DArray.new()
	var err := arr.create_from_images(imgs)
	if err != OK:
		push_error("FieldMaterials: массив текстур не создан (код %d)" % err)
		return
	mat.set_shader_parameter("texs", arr)
	mat.set_shader_parameter("tints", tints)
	mat.set_shader_parameter("tiles", tiles)
	mat.set_shader_parameter("slot_cliff", SLOT_CLIFF)
	mat.set_shader_parameter("edge_noise", edge_noise)
	mat.set_shader_parameter("edge_scale", edge_scale)


## Слой массива: текстура поверхности, приведённая к layer_size x layer_size RGBA8 с мипами. Нет текстуры: белый (красит tint)
func _layer_image(s: FieldSurface) -> Image:
	var size := clampi(layer_size, 64, 4096)
	var img: Image = null
	if s != null and s.texture != null:
		img = s.texture.get_image()
	if img == null or img.is_empty():
		img = Image.create(size, size, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
	else:
		if img.is_compressed():
			img.decompress()
		if img.has_mipmaps():
			img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		if img.get_width() != size or img.get_height() != size:
			img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	img.generate_mipmaps()
	return img
