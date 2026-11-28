class_name CarVisualSettings extends ComponentSettings

## Собирает C_CarVisual. Сцена берётся из паспорта CarConfig (scene); пусто: кузов из примитивов по габаритам и цвету паспорта
## Значения задаём ДО add_component: базовый C_Visual строит модель уже в on_added (как TrainVisualSettings)

func create_component(entity: Entity) -> Component:
	var comp := C_CarVisual.new()
	var cfg := CarConfig.from_entity(entity)
	if cfg != null:
		comp.scene = cfg.scene
	comp.name = 'C_CarVisual'
	entity.add_component(comp)
	return comp
