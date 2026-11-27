class_name TerminalBlockSetting extends ComponentSettings

# XX claude-wire W6 (новый файл)
## Клеммник (W6): создаёт C_TerminalBlock. Число клемм (вход и выходы) от 2 до 5, меняется потом во вкладке «Настройки»
@export_range(2, 5) var count := 4


func create_component(entity: Entity) -> Component:
	var comp := C_TerminalBlock.new()
	comp.count = count
	entity.add_component(comp)
	return comp
