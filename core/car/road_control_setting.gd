class_name RoadControlSettings extends ComponentSettings

## Собирает C_RoadControl. Вид элемента (стоп, парковка, датчик) берётся из RoadConfig.control паспорта (ATTN_28, CS4a)

func create_component(entity: Entity) -> Component:
	var comp := C_RoadControl.new()
	comp.name = 'C_RoadControl'
	entity.add_component(comp)
	return comp
