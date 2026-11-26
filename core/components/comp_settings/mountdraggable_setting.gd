class_name MountDraggableSettings extends ComponentSettings

# XX claude-wire W4 (новый файл)
## Драг блока, который стоит на плите сверху или на нижней полке (C_MountDraggable, Mount)


## Фабрика запустит эту функцию создания
func create_component(_entity: Entity) -> Component:
	var comp := C_MountDraggable.new()
	comp.name = 'C_MountDraggable'
	_entity.add_component(comp)
	return comp
