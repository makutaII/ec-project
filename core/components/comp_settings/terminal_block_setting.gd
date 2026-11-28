class_name TerminalBlockSetting extends ComponentSettings

# XX claude-wire W6 (новый файл)
## Клеммник (W6): создаёт C_TerminalBlock. Число клемм (вход и выходы) от 2 до 5, меняется потом во вкладке «Настройки»
@export_range(2, 5) var count := 4
## Клеммы на шину аксессуаров 12 В (ACCESSORY), по умолчанию рельсовая проводка (TRACK)
@export var accessory := false


func create_component(entity: Entity) -> Component:
	var comp := C_TerminalBlock.new()
	comp.count = count
	comp.accessory = accessory
	entity.add_component(comp)
	return comp
