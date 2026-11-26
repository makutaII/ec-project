class_name RoadVehicleSettings extends ComponentSettings

## Собирает C_RoadVehicle. Подключается в массив компонентов машины (ATTN_28, CS2). Параметры берутся из паспорта CarConfig.

func create_component(entity: Entity) -> Component:
	var comp := C_RoadVehicle.new()
	comp.name = 'C_RoadVehicle'
	entity.add_component(comp)
	return comp
