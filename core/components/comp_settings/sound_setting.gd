class_name SoundSetting extends ComponentSettings

## Собирает C_Sound. Профиль берёт из паспорта (WagonConfig.sound_profile), пусто = по умолчанию (локо или вагон):
## его выбирает сам компонент, когда сущность собрана. Ставится В КОНЦЕ массива компонентов вагона.

func create_component(entity: Entity) -> Component:
	var comp := C_Sound.new()
	var cfg := WagonConfig.from_entity(entity)
	if cfg != null and cfg.sound_profile != null:
		comp.profile = cfg.sound_profile
	comp.name = 'C_Sound'
	entity.add_component(comp)
	return comp
