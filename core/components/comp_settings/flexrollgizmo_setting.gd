class_name FlexRollGizmoSetting extends ComponentSettings

## Кольцо со стрелкой на конце flex для задания крена свободного конца (ATTN_27, шаг C8.3).
## Ставится в список компонентов flex горок; у рельсового flex не нужен.

func create_component(entity: Entity) -> Component:
	var comp := C_FlexRollGizmo.new()
	comp.name = 'C_FlexRollGizmo'
	entity.add_component(comp)
	return comp
