class_name BusSourceSetting extends ComponentSettings

# XX claude-wire W8 (новый файл)
## Шина аксессуаров 12 В как прибор на столе (C_BusSource): клеммы шины, к ним подключают провода потребителей


func create_component(entity: Entity) -> Component:
	var comp := C_BusSource.new()
	entity.add_component(comp)
	return comp
