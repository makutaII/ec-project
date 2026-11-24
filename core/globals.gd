extends Node

##########################
##
## Global  (Global)  глобальные настройки
##
###########################
var object_dirs := [	"res://data/tracks/objects/", 
						"res://data/trains/objects/", 
						"res://data/buildings/objects/",
						"res://data/terrain/objects/",
						"res://data/table/objects/",
						"res://ui/dc_controllers/objects/",
						"res://data/power/objects/",
						"res://data/coaster/objects/",   # XX claude-coaster C0: ATTN_27
						"res://data/roads/objects/"]   # XX claude-car CS1: ATTN_28

# Настройки объектов
var settings: Resource = preload("res://setting/global_setting.tres")

#DD Дебаги вкл
## true в редакторе и debug-сборке, false в релизе
var debug_mode := OS.is_debug_build()

## Режим быстрой загрузки для отладки: без комнаты и карточек Observe, графика по умолчанию (Low, без SDFGI),
## землёй служит скрытый WoodFloor. Включается аргументом запуска `--fast` (Run with args: -- --fast)
## или настройкой проекта ec/fast_debug = true
var fast_debug := false  # Упростил 
#OS.get_cmdline_user_args().has("--fast") or bool(ProjectSettings.get_setting("ec/fast_debug", false))

## Комната, выбранная при запуске: аргумент `--room=<id>` (Run with args: -- --room=attic). Пусто: комната из сейва или по умолчанию.
## Источник «start» (RoomBuilder.request_room): для тестов и ранней сборки, пока нет экрана выбора комнаты (ATTN_25 §25.3)
var start_room: StringName = _cmdline_room()
##=======
## Физика вагона во время драга. false (по умолчанию): rb замораживается и едет за ентити как ребёнок,
## Физика вагона во время драга. false (по умолчанию): rb замораживается и едет за ентити как ребёнок,
## без «догоняния» и броска. true: прежнее поведение, rb догоняет ентити скоростями (можно бросить вагон)
var drag_physics := false

## Отладочные маркеры в кадре: куб над Entity, конусы и шарики сокетов. Отдельно от debug_mode,
## тот включён по умолчанию и держит другие отладочные вещи
var debug_markers := false

## Полуширина подсветки трака (зоны flex, лента активного пути стрелки) в долях rail_x стиля.
## 1.0 = от рельса до рельса, больше - шире колеи. Одна для всех подсветок
var flash_width := 0.2

## Visual layer комнаты (номер 1..20 для set_layer_mask_value / cull_mask). 15-20 заняты контурами Outline
const ROOM_VISUAL_LAYER := 12
## Visual layer оболочки комнаты (стены, потолок, рама окна). Отдельный слой нужен, чтобы заполняющий свет SkyFill
## (light_shadow_caster_mask без этого слоя) не получал тень от стен, потолка, штор и подоконника. Камера и основное солнце видят оба слоя
const ROOM_SHELL_LAYER := 13

var active_ui_category := 1


## Текущий режим из : &'build' &'operate' &'observe' &'library'
var current_mode :StringName = &'build' 

## Общие опции строительства (U12): шаг поворота, привязки, лимиты flex. Панель SideDock меняет их же
var build_options := BuildOptions.new()

## F2: контроль лимитов flex (R, L, уклон, "под землёй"). Переключается клавишей L в BuildTool.
## Свойство-посредник: значение живёт в build_options (U12), старые читатели не менялись
var flex_limits: bool:
	get:
		return build_options.flex_limits
	set(v):
		build_options.flex_limits = v

## 13.1.7: зоны проблем flex (радиус меньше предела, уклон больше предела, близко к пределу) цветной полосой
## над рельсами, клавиша Z. Сигнал: C_FlexShape перерисовывает полосу
signal flex_zones_changed
var flex_zones := true:
	set(v):
		if v != flex_zones:
			flex_zones = v
			flex_zones_changed.emit()

## 13.1.6: вагон на рельсах ищет препятствия по ходу (стоящий вагон, опоры, низкий верхний трак), см. C_Coupler.
## Выключатель на случай просадки по производительности или ложных ударов
var rail_obstacles := true


######### TRACK ##############
 
# Высота трака с балластом
#const TRACK_WITH_BALLAST_HEIGHT = 0.85

########## HELPERS ##################

	#Выдает маску для слоя\маски коллизии из массива строк
func active_layers(data:Array) -> int:
	var i := 0
	
	for d in data:
		match str(d): # XX claude-terra StringName/String
			'ground' : i = i | 1 << 0
			'tracks' : i = i | 1 << 2
			'sokets' : i = i | 1 << 3
			'trains' : i = i | 1 << 4
			# XX claude-terra опоры эстакады (StaticBody3D C_TrackSupport, сталкиваются вагоны, 13.1.5). Бит 8
			'supports' : i = i | 1 << 8
			'handles' : i = i | 1 << 6   # ручки flex
			'room'   : i = i | 1 << 7    # пол, стены, мебель комнаты (Observe)
			'ghost'  : i = i | 1 << 10
			# XX claude-terra 13.4: поверхность воды (C_Water). Не в PROBE_LAYERS: вагон воду не замечает; ищут только инструмент и плавающие
			'water'  : i = i | 1 << 11
			# XX claude-terra 13.5: оболочка гипсового бинта (PlasterSkin). Не в PROBE_LAYERS и не в лучах листов и траков: её видит только постановка зданий и декора
			'plaster': i = i | 1 << 12
			# D4 (ATTN_10): корпуса пультов, клеммы и провода. Слой 13 занят гипсом, поэтому 14. Вагон его не проверяет (нет в PROBE_LAYERS)
			'power'  : i = i | 1 << 13
			# XX claude-wire W0: подстолье (ATTN_23 §23.9): низ плиты, брусья рамы, ножки. Лучи монтажа блоков и проводов под столом. Не в PROBE_LAYERS: вагон его не проверяет
			'underside': i = i | 1 << 14
			# XX claude-car CS1 (ATTN_28 §28.3): основание дороги (балласт и головка C_RoadPath). Слой 16: бит 13 занят под power, бит 14 под underside.
			# Вагон его не проверяет (нет в PROBE_LAYERS), рельсовые траки не видят дорогу и наоборот
			'roads'  : i = i | 1 << 15
			## Контуры Outline это visual layers 15-20 (cull_mask), к физике не относятся
	return i


## Значение `--room=<id>` из пользовательских аргументов запуска или пустое имя
static func _cmdline_room() -> StringName:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--room="):
			return StringName(a.trim_prefix("--room=").strip_edges())
	return &""
