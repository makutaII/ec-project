class_name MountDraggableSettings extends ComponentSettings

# XX claude-wire W4 (новый файл)
## Драг блока, который крепится на плиту сверху, на низ плиты или на раму (C_MountDraggable, Mount)

## Где блок крепится (Mount.Surface)
@export var allowed: Array[int] = [Mount.Surface.TOP, Mount.Surface.UNDER, Mount.Surface.FRAME]


## Фабрика запустит эту функцию создания
func create_component(_entity: Entity) -> Component:
	var comp := C_MountDraggable.new()
	comp.name = 'C_MountDraggable'
	comp.allowed = allowed.duplicate()
	_entity.add_component(comp)
	return comp
