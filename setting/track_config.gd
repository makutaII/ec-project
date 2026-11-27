class_name TrackConfig extends ObjectConfig

########################
## настройки конкретного типа трака 
########################

## Цепляется в C_Identity (object_config). Читать типизированно:
##   var cfg := identity.object_config as TrackConfig   (или SwitchConfig.from_entity(entity))
## Строкового доступа к полям нет: опечатка в имени поля ловится при разборе скрипта

@export var radius := 0.0
@export var deg := 0.0
@export var height := 0.85
# XX claude-terra
## Подъем вдоль трака, ю (только прямые). 0 = ровный. Для пандуса radius = длина ВДОЛЬ уклона
@export var rise := 0.0
# XX claude-terra
## Трак тоннельный сразу при постановке (C_Tunnel): может уходить под листы пенопласта. Обычно включается клавишей U
@export var allow_underground := false
# XX claude-switch
## Ширина коллизии основания (балласт, шпалы), ю. 0 = не задана: берется ширина из TrackStyle (процедурные траки) 
## по умолчанию 2.9ю
## или из глобальных настроек track_ballast_segment (траки со сценой Blender). Больше нуля: перекрывает их у ЛЮБОГО трака
## (flex, стилевой, со сценой, стрелка, кросс, упор). Применяют адаптеры визуала и пути (TrackStyle.with_collision_width,
## C_Path.collision_width), см. TrackConfig.collision_width_of
@export var collision_width := 0.0
#@export var align_ends := false # Выравнивание торцов коллизий


## Пределы формы flex-трака из паспорта (FlexSolver.Limits). null = обычные, из GlobalSetting (flex_r_min, flex_l_*, flex_max_grade).
## XX claude-coaster C8: RideFlexConfig задаёт свои, у горок они шире. Спрашивает C_FlexShape
func flex_limits() -> FlexSolver.Limits:
	return null


## Каким компонентом строится путь трака. XX claude-coaster C4: по умолчанию обычный C_Path, траки с особой формой
## (RideTrackConfig) подменяют. Спрашивает StyleVisualSetting
func create_path() -> C_Path:
	return C_Path.new()


## Ширина коллизии основания из паспорта трака, ю (0 = не задана или у сущности нет паспорта TrackConfig)
static func collision_width_of(entity: Entity) -> float:
	var idc := entity.get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as TrackConfig if idc else null
	return cfg.collision_width if cfg else 0.0
