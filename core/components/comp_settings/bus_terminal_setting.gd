class_name BusTerminalSetting extends ComponentSettings

# XX claude-wire W8 (новый файл)
## Клемма шины аксессуаров на потребителе (C_BusTerminal): дом с лампами на шине, позже привод стрелки

## Положение клеммы на объекте, u (локальные координаты)
@export var offset := Vector3(0.0, 1.0, 0.0)


func create_component(entity: Entity) -> Component:
	var comp := C_BusTerminal.new()
	comp.offset = offset
	entity.add_component(comp)
	return comp
