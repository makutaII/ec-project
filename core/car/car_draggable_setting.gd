class_name CarDraggableSettings extends ComponentSettings

## Собирает C_CarDraggable. Подключается в массив компонентов машины (ATTN_28, CS2). Параметры берутся из паспорта CarConfig.

func create_component(entity: Entity) -> Component:
	var comp := C_CarDraggable.new()
	comp.name = 'C_CarDraggable'
	entity.add_component(comp)
	return comp
