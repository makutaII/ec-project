class_name PathSetting extends ComponentSettings

## Путь трака. Параметры (radius, deg, rise, height, allow_underground) берет из паспорта (TrackConfig) и
## переносит в C_Path при создании. Сам C_Path паспорт не читает.

## Фабрика запускает функцию создания
func create_component(entity) -> Component:
	var comp := C_Path.new()
	apply_passport(comp, entity)
	comp.name = 'C_Path'
	entity.add_component(comp) # Добавили комп к объекту
	return comp


## Единственное место, где путь читает паспорт. Пользуются PathSetting, FlexVisualSetting, StyleVisualSetting.
## Без паспорта TrackConfig путь не строится (has_passport = false), как и раньше
static func apply_passport(path: C_Path, entity: Entity) -> void:
	var idc := entity.get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as TrackConfig if idc else null
	if idc == null or idc.setting == null or cfg == null:
		push_error("PathSetting: у сущности нет паспорта TrackConfig (C_Identity.object_config), путь не строится")
		return
	path.has_passport = true
	path.radius = cfg.radius
	path.deg = cfg.deg
	path.rise = cfg.rise
	path.track_height = cfg.height
	path.allow_underground = cfg.allow_underground
	path.collision_width = cfg.collision_width
