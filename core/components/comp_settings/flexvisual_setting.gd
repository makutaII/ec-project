class_name FlexVisualSetting extends ComponentSettings

# XX claude-terra (новый файл)
## Собирает flex-трак одним компонентом настроек: C_FlexVisual, C_Path (centered = false), C_FlexShape.
## Порядок в массиве компонентов .tres: Identity, FlexSetting, Draggable, Pivot, Hoverable, Selectable,
## Blockable, Socket, PowerTrack, TrackSupport. Identity: TrackConfig с radius = 10 (начальная прямая).

## Рельсы, шпалы, балласт. Пусто = «следовать сессии»: стиль берётся у TSM (ATTN_17 §17.13).
## Непусто = стиль зафиксирован в объекте
@export var style: TrackStyle


func create_component(entity: Entity) -> Component:
	# 1. Визуал (строит ноды Ballast / HeadStaticBody3D в коде)
	var vis := C_FlexVisual.new()
	# Ширина коллизии из паспорта (0 = как в стиле)
	vis.style = TrackStyle.with_collision_width(TSM.resolve_for(entity, style), TrackConfig.collision_width_of(entity))

	vis.name = 'C_FlexVisual'
	entity.add_component(vis)

	# 2. Путь: origin в начале кривой
	# XX claude-coaster C8: паспорт может подменить компонент пути (TrackConfig.create_path): у flex горок это C_RidePath
	var pidc := entity.get_comp(C_Identity) as C_Identity
	var pcfg := pidc.object_config as TrackConfig if pidc else null
	var path: C_Path = pcfg.create_path() if pcfg else C_Path.new()
	PathSetting.apply_passport(path, entity)   # radius, deg, rise, height, allow_underground из паспорта
	path.centered = false
	path.name = 'C_Path'
	entity.add_component(path)

	# 3. Форма (после C_Path: в on_entity_ready он уже построен)
	var shape := C_FlexShape.new()
	shape.name = 'C_FlexShape'
	entity.add_component(shape)
	
	# 4. Ручки изгибов (после C_FlexShape)
	var handles := C_FlexHandle.new()
	handles.name = 'C_FlexHandle'
	entity.add_component(handles)
	
	return vis
