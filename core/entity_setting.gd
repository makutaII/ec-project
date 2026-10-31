class_name EntitySetting extends Resource

###########################
## 📦 EntitySetting База. Сеттинг объекта\сущности.
###########################
## Все объекты - это ентити, которые создаются из этого ресурса. 
## Файлы .tres для каждого объекта лежат в папках res://data/.../objects/ 
## UI накидывает кнопки по категориям для каждого объекта папок /objects/

#@export_category("Main & UI")
## Стабильный уникальный ключ объекта: `категория.тег.вариант`, например `track.straight.s239_wood`.
## По нему объект узнают UI, сейвы будущих версий и локализация (`obj.<key>.name`).
## Ключ не меняют после выхода объекта. Решения принимаются по `facets`, а не разбором строки ключа.
## Пусто = временный ключ из пути файла (get_key), но lint это отмечает.
@export var key :StringName = &""

## Признаки для фильтров каталога и выбора рамкой: {"shape": "straight", "sleeper": "wood", "ballast": "yes"}
## Ключи и значения строками. Набор показываемых фильтров задан в CatalogMeta.FACET_SPECS
@export var facets :Dictionary = {}

## Порядок кнопки в своем теге (меньше = левее). Равные (в том числе все нули) идут по имени файла ресурса,
## как было до U3a. Прежний `id` порядок не задает
@export var sort_order :int = 0

## УСТАРЕЛО: прежний числовой id. Читается как раньше (подпись на кнопке в debug), но ничего не решает.
## Заменен на key. Удалим, когда все .tres и сейвы перейдут
@export var id :int = 0
@export var name :String = ''
@export var description :String = 'Прямой трак 1,5см'

@export var category :StringName = &'track'
@export var tag :StringName = &'straight'

@export var icon :Texture2D

@export var hide : bool = false # скрыть кнопку в UI 

# XX claude-terra: PLACE_THEN_STRETCH - flex: клик ставит начало, второй клик ставит конец
# XX claude-terra 13.2: DRAW_POLYGON - лист пенопласта произвольной формы: вершины контура ставятся кликами (C_PolygonDraw)
# 13.2 B5: DRAW_STRIP - лист-полоса: клики ставят точки оси, ширина [ и ], контур = ось, смещённая на полширины
# 13.3 S2: CUT_TOOL - не объект, а инструмент: кнопка включает ThermoCutTool (терморезак), форма выреза в facet "shape" (rect, polygon)
enum BuildBehavior { GHOST_PLACE, SPAWN_AND_DRAG, PLACE_THEN_STRETCH, DRAW_POLYGON, DRAW_STRIP, CUT_TOOL }

## Как BuildTool ставит объект: гост + клик, или сразу спавн в драг
@export var build_behavior: BuildBehavior = BuildBehavior.GHOST_PLACE

## Массив сеттингов компонентов объекта
@export var components :Array[ComponentSettings] = []

# XX claude-terra
## Слои, по которым рейкаст тулов ищет точку под курсором ('ground','tracks','trains'...).
## Пусто = значение по умолчанию из категории (см. get_pick_layers)
@export var pick_layers: Array[StringName] = []

# XX claude-terra
func get_pick_layers() -> Array:
	if not pick_layers.is_empty():
		return pick_layers
	if category == &'track':
		return [&'ground']   # трак ставится на уровень над землей, а не на другие траки
	if category == &'terrain':
		return [&'ground']   # лист пенопласта ставится на стол или на верх другого листа
	return [&'ground', &'tracks', &'trains']


## Ключ объекта. Пустой `key` заменяется ключом из категории, тега и имени файла
func get_key() -> StringName:
	if key != &"":
		return key
	var stem := resource_path.get_file().get_basename()
	if stem == "":
		stem = name.to_snake_case()
	return StringName("%s.%s.%s" % [category, tag, stem])


## Значение признака строкой, пусто если признака нет. Ключи словаря сравниваются как строки
func get_facet(facet: StringName) -> String:
	for k in facets:
		if str(k) == str(facet):
			return str(facets[k])
	return ""
