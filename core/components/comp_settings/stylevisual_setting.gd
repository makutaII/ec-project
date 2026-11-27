class_name StyleVisualSetting extends ComponentSettings

# XX claude-terra (новый файл)
## Собирает жёсткий трак (прямая/дуга/пандус) по форме из TrackConfig (Identity) в стиле сессии.
## Процедурный стиль: компонентами C_Path (centered = true) и C_StyleVisual. C_Path создаётся ПЕРВЫМ: на его
## on_entity_ready() генерируется curve/path_node, а C_StyleVisual (идёт следом по порядку детей) строит геометрию
## по этой кривой в СВОЁМ on_entity_ready(). Порядок важен: Path должен быть раньше визуала.
## Стиль-сцена (TrackStyle.use_scene, «бюджет»): C_TrackVisual со сценой Blender из `budget_scene`, затем C_Path
## (порядок как у прежних сцен-траков).
##
## Остальной массив компонентов в .tres как у обычного трека: Draggable, Pivot, Hoverable,
## Selectable, Blockable, Socket, PowerTrack, TrackSupport. radius/deg/rise берутся из
## TrackConfig (Identity).

## Рельсы, шпалы, балласт. Пусто = «следовать сессии»: стиль берётся у TSM (активный стиль или стиль из
## сейва, ATTN_17 §17.13). Непусто = стиль зафиксирован в объекте
@export var style: TrackStyle
## Сцена Blender для стиля-сцены (budget). Пусто: в этом стиле форма строится запасным стилем набора
## (TrackStyleSet.scene_fallback_id) и в Output одно предупреждение
@export var budget_scene: PackedScene

## Формы без сцены, о которых уже предупредили (по одному разу за запуск)
static var _warned := {}


func create_component(entity: Entity) -> Component:
	var st := TSM.resolve_for(entity, style)
	if st != null and st.use_scene:
		if budget_scene != null:
			return _create_scene_visual(entity)
		st = TSM.scene_fallback()
		if not _warned.has(resource_path):
			_warned[resource_path] = true
			push_warning("StyleVisualSetting: у формы нет budget_scene, в стиле '%s' она строится запасным стилем (%s)" % [entity.style_id, resource_path])
	return _create_style_visual(entity, st)


func _create_style_visual(entity: Entity, st: TrackStyle) -> Component:
	# 1. Путь: нужен ПЕРЕД визуалом (визуал строит геометрию по его кривой в on_entity_ready)
	_add_path(entity)

	# 2. Визуал: строит каркас сразу (on_added), геометрию по кривой - в on_entity_ready
	var vis := C_StyleVisual.new()
	# Ширина коллизии из паспорта (0 = как в стиле)
	vis.style = TrackStyle.with_collision_width(st, TrackConfig.collision_width_of(entity))
	vis.name = 'C_StyleVisual'
	entity.add_component(vis)
	return vis


func _create_scene_visual(entity: Entity) -> Component:
	# Как у прежних сцен-траков: сначала визуал со сценой, потом путь
	var vis := C_TrackVisual.new()
	vis.scene = budget_scene
	vis.name = 'C_TrackVisual'
	entity.add_component(vis)
	_add_path(entity)
	return vis


func _add_path(entity: Entity) -> void:
	# XX claude-coaster C4: паспорт может подменить компонент пути (TrackConfig.create_path)
	var idc := entity.get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as TrackConfig if idc else null
	var path: C_Path = cfg.create_path() if cfg else C_Path.new()
	PathSetting.apply_passport(path, entity)   # radius, deg, rise, height, allow_underground из паспорта
	path.centered = true   # как у обычных жёстких траков: origin в середине кривой
	path.name = 'C_Path'
	entity.add_component(path)
