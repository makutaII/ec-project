class_name TrainVisualSettings extends ComponentSettings

## Собирает C_TrainVisual
## Подключается в массив сеттингов компонентов в редакторе ентити. Сцена и тележки берутся из паспорта (WagonConfig).
## Значения задаем ДО add_component: базовый C_Visual строит вагон (в том числе тележки) уже в on_added.

## Фабрика запустит эту функцию создания
func create_component(entity: Entity) -> Component:
	var comp := C_TrainVisual.new()
	var cfg := WagonConfig.from_entity(entity)
	if cfg == null:
		push_error("TrainVisualSettings: в паспорте (C_Identity.object_config) нет WagonConfig, параметры по умолчанию")
	else:
		comp.scene = cfg.scene
		comp.bogie_configs = cfg.bogie_configs
		comp.offset_mesh_y = cfg.offset_mesh_y
		comp.use_model_rig = cfg.use_model_rig

	comp.name = 'C_TrainVisual'
	entity.add_component(comp) # Добавили комп к объекту

	return comp
