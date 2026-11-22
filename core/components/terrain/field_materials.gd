class_name FieldMaterials extends Resource

# XX claude-terra 13.14 H4 (новый файл)
###################################
## Набор материалов поверхности поля (ATTN_13 §13.14, H4): текстура, оттенок и размер повтора для каждого из четырёх каналов.
###################################
## Канал это тип поверхности узла поля: 0 гладкая, 1 каменистая, 2 скалистая, 3 запас. Кисть выбирает канал весами surface_mix
## (TerrainBrush), поэтому рельефная кисть красит сразу. Набор один на всю игру (data/terrain/field_materials.tres, его читает FieldView).
## Чтобы поменять текстуру канала, достаточно подставить другую в albedo[канал]; без текстуры канал рисуется цветом tint.
## Текстуры мировые (по XZ, на крутых склонах боковая проекция), нормали и ORM в H4 не используются.

const CHANNELS := 4

## Названия каналов (для подсказок и редактора)
@export var names: PackedStringArray = ["гладкая", "каменистая", "скалистая", "запас"]
## Текстура цвета канала (sRGB). null: канал рисуется однотонно цветом tint
@export var albedo: Array[Texture2D] = []
## Оттенок канала, множится на текстуру (по четыре числа RGBA на канал в PackedColorArray)
@export var tint := PackedColorArray([Color(0.5, 0.78, 0.34), Color(0.92, 0.86, 0.7), Color(0.66, 0.64, 0.61), Color(0.82, 0.74, 0.5)])
## Размер одного повтора текстуры, ю
@export var tile := PackedFloat32Array([3.0, 2.5, 5.0, 3.0])
## Насколько рваной получается граница двух материалов (0 только плавный переход ячеек, 1 сильно рваная)
@export_range(0.0, 1.0, 0.05) var edge_noise := 0.35
## Частота шума границы, 1/ю (больше значение: мельче рваность)
@export_range(0.5, 8.0, 0.1) var edge_scale := 2.5


## Текстура канала или null
func texture_of(ch: int) -> Texture2D:
	return albedo[ch] if ch >= 0 and ch < albedo.size() else null


func tint_of(ch: int) -> Color:
	return tint[ch] if ch >= 0 and ch < tint.size() else Color.WHITE


func tile_of(ch: int) -> float:
	return maxf(tile[ch], 0.1) if ch >= 0 and ch < tile.size() else 3.0


## Выставить параметры шейдера поверхности поля (field_surface.gdshader)
func apply(mat: ShaderMaterial) -> void:
	for ch in CHANNELS:
		mat.set_shader_parameter("tex%d" % ch, texture_of(ch))
		mat.set_shader_parameter("tint%d" % ch, tint_of(ch))
	mat.set_shader_parameter("tile", Vector4(tile_of(0), tile_of(1), tile_of(2), tile_of(3)))
	mat.set_shader_parameter("edge_noise", edge_noise)
	mat.set_shader_parameter("edge_scale", edge_scale)
