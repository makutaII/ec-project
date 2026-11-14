class_name BuildingPresetSetting extends EntitySetting

# XX claude-library L8 (новый файл)
###########################
## BuildingPresetSetting. Кнопка «Мои здания» в каталоге Build (ATTN_22 §22.7.6, шаг L8)
###########################
## Обёртка, как ConsistSetting у составов: здание игрока едет по тому же пути, что объекты каталога (теги, сортировка,
## ObjectButton, ToolbarController). Это не объект мира, компонентов нет. ToolController.select_build_object разворачивает
## её в общий объект генератора (base) с исполнением {"building": spec}: призрак и поставленное здание строятся по spec.
## Создаётся в EntityCatalogProvider из записей BuildingStore.

const TAG := &"mybuildings"

## Общий объект генератора (building_gen.tres): из него создаётся сущность
var base: EntitySetting
## Идентификатор записи в BuildingStore
var entry_id := ""
## BuildingSpec.to_dict() здания
var spec_dict: Dictionary = {}


## Кнопка здания. base_setting: building_gen из каталога. null, если генератора в каталоге нет (кнопка не показывается)
static func from_entry(entry: Dictionary, base_setting: EntitySetting) -> BuildingPresetSetting:
	if base_setting == null:
		return null
	var spec := entry["spec"] as BuildingSpec
	var s := BuildingPresetSetting.new()
	s.base = base_setting
	s.entry_id = str(entry["id"])
	s.spec_dict = spec.to_dict()
	s.key = StringName("building.mine.%s" % s.entry_id)
	s.category = &"building"
	s.tag = TAG
	s.name = str(entry["name"])
	s.description = "Здание игрока: %s на %s ю, этажей %d" % [
		"Г-образное" if spec.is_l() else "прямоугольное", "%.1f x %.1f" % [spec.width, spec.depth], spec.floors]
	s.icon = base_setting.icon
	s.build_behavior = base_setting.build_behavior
	return s


## Исполнение для призрака: здание целиком
func make_variant() -> Dictionary:
	return {"building": spec_dict.duplicate(true)}
