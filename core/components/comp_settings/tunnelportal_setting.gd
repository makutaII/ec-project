class_name TunnelPortalSetting extends ComponentSettings

# XX claude-terra 13.14 H7b (новый файл)
## Визуал объекта «Портал тоннеля»: C_TunnelPortal (арка стиля и глубины, тёмная плоскость, тело для выбора)


func create_component(entity: Entity) -> Component:
	var comp := C_TunnelPortal.new()
	comp.name = 'C_TunnelPortal'
	entity.add_component(comp)
	return comp
