class_name RideCarSetting extends ComponentSettings

## Собирает C_RideCar (вагон горок: профиль заезда и пинок рукой, ATTN_27).
## В список компонентов вагона ставится последним: C_RideCar берёт шасси в on_entity_ready

func create_component(entity: Entity) -> Component:
	var comp := C_RideCar.new()
	comp.name = 'C_RideCar'
	entity.add_component(comp)
	return comp
