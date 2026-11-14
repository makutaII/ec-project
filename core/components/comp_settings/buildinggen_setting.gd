class_name BuildingGenSetting extends ComponentSettings

# XX claude-library L7 (новый файл)
## Собирает здание из генератора: C_BuildingGen и следом C_Mechanisms со светом окон (ATTN_22 §22.7.6).
## По образцу StyleVisualSetting: визуал строится в on_added, поэтому данные задаются до add_component.
## Здание берётся из Entity.variant["building"] (фабрика отдаёт variant до компонентов); нет ключа: здание по умолчанию.
## C_Mechanisms добавляется здесь, а не отдельным сеттингом: MechanismsSetting читает свет из WagonConfig, у здания
## свет считает генератор (BuildingBuilder.make_lights) по раскладке окон.
## Порядок в массиве components .tres: Identity, BuildingGen, затем Draggable, Hoverable, Selectable, Blockable.


func create_component(entity: Entity) -> Component:
	var vis := C_BuildingGen.new()
	vis.spec = BuildingSpec.from_variant(entity.variant)
	vis.name = 'C_BuildingGen'
	entity.add_component(vis)

	var mech := C_Mechanisms.new()
	mech.light_configs = vis.make_lights()
	mech.name = 'C_Mechanisms'
	entity.add_component(mech)
	return vis
