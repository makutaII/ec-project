class_name RoadBedSettings extends ComponentSettings

## Собирает C_RoadBed (уведомление рельефа о дороге). Добавляется в массив компонентов сегмента дороги

func create_component(entity: Entity) -> Component:
	var comp = C_RoadBed.new()
	comp.name = 'C_RoadBed'
	entity.add_component(comp)
	return comp
