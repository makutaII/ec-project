class_name CarVisualSettings extends ComponentSettings

## Собирает C_CarVisual. Подключается в массив компонентов машины (ATTN_28, CS2). Параметры берутся из паспорта CarConfig.

func create_component(entity: Entity) -> Component:
	var comp := C_CarVisual.new()
	comp.name = 'C_CarVisual'
	entity.add_component(comp)
	return comp
