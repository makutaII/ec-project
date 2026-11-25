class_name PortalDraggableSetting extends ComponentSettings

# XX claude-terra 13.14 H7b (новый файл)
## Драг портала тоннеля: C_PortalDraggable (уровень пола арки, а не поверхность под курсором)


func create_component(_entity: Entity) -> Component:
	var comp := C_PortalDraggable.new()
	comp.name = 'C_PortalDraggable'
	_entity.add_component(comp)
	return comp
