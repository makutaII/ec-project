class_name WagonConfig extends ObjectConfig

########################
## настройки конкретного типа вагона
########################

## Цепляется в C_Identity (object_config). Читать типизированно: WagonConfig.from_entity(entity)
## (опечатку в имени поля поймает парсер).
## Читают только адаптеры ComponentSettings (Kinematics/Engine/Coupler/TrainVisual/Chassis/Bogie/Mechanisms/TrainDraggable),
## компоненты получают значения в свои поля при создании.

# Kinematics
# Данные заполняются в редакторе, в массиве сеттингов
@export_category("Kinematics (Физика)")
## Масса в кг соответствует реальной х10. 2.0 - это 0.2 кг реальной модели
@export var mass: float = 2.0 
## Макс. поперечная сила до схода (реборда)
@export var max_grip: float = 200.0 
## Трение качения
@export var roll_resistance: float = 0.05 
## Предел продольного сцепления для пробуксовки
@export var longitudinal_grip: float = 3.0 
## Минимальный радиус сплайна (м), который проходит вагон без дерейла
@export var min_curve_radius: float = 15.0 

## μ бокового юза колёс и скольжения лежащим корпусом (на столе)
@export var slide_friction: float = 0.1
## μ юза локо с заблокированными колёсами (нет тяги). Одинаково на рельсах и на столе.
## Больше - короче юз. При пинке 10 м/с: 3.0 -> ~1.7 м, 1.0 -> ~5 м, 0.3 -> ~17 м.
@export var locked_wheel_friction: float = 3.0

@export_category("Rotation Limits (YAW)")
## Максимальный угол поворота тележки
@export var max_yaw_deg: float = 25.0    
## Сила возвратной пружины (стремление выровняться по оси кузова)
@export var yaw_spring: float = 5.0      

@export_category("Suspension (Travel & Play)")
## Подвеска кузова (частоты, упоры, стыки, hunting). Пусто - значения по умолчанию из SuspensionConfig.
@export var suspension: SuspensionConfig


@export_category("Engine Settings (Мотор)")
@export var has_engine: bool = false # Флаг, локомотив ли это # TODO лишний?
@export var max_tractive_force: float = 400.0 # Макс. стартовая тяга мотора в Ньютонах
@export var max_theoretical_speed: float = 40.0 # Макс. скорость мотора без нагрузки (KV)
## Порог страгивания, % напряжения: ниже мотор не тянет (сила 0), питание «есть» (ATTN_10 Q10)
@export var start_voltage: float = 6.0
## Ток мотора на холостом ходу, А
@export var motor_current_idle: float = 0.15
## Стопорный ток мотора (полная сила, разгон, затор), А. Выше лимита вывода `multi` (1.0 А): затор при высоком напряжении отключает вывод. Подбирать по ощущению
@export var motor_current_stall: float = 1.2

@export_category("Sound (Звук)")
## Профиль звука (ATTN_26). Пусто: по умолчанию (у локо качение громче, у вагона на 6 дБ тише)
@export var sound_profile: SoundProfile

@export_category("Visuals & Layout")
@export var scene = preload("res://data/trains/default_wagon.tscn")
## Стандартная высота оси буферов над головкой рельса, единицы игры (1 единица = 1 м прототипа). NEM 303 (2015), H0: 12.2 ±0.5 мм
## при масштабе 1:87 это 1.061 ±0.043. Новые модели рисуются от этой метки (Z=0 в Blender это ось буферов), у них
## offset_mesh_y = BUFFER_HEIGHT: все вагоны стоят буферами на одной высоте (0_ATTN_24 §24.3).
## Дублируется в tools/glb_preflight.py и tools/blender/ec_model_tools.py
const BUFFER_HEIGHT := 1.061
## Высота начала меша кузова над головкой рельса, абсолютная (колёса от неё не зависят). Старые паспорта подобраны под свои модели;
## новые: BUFFER_HEIGHT
@export var offset_mesh_y: float = 1.061 # Смещение меша от пола (меньше диаметра колеса на ~0.2)
@export var bogie_configs: Array[BogieConfig] = []
## true: если в модели есть узлы unit_<n> с колёсными парами wheel_<n>_<k> (радиус в extras), тележки строятся по модели (ModelRig),
## bogie_configs не нужны и игнорируются. false: всегда по bogie_configs. Модели без узлов unit_* на это не реагируют
@export var use_model_rig: bool = true


@export_category("Coupler (Сцепка)")
##[b] На сплайне:[/b] от центра вагона до торца (сцепки) , м 
@export var coupler_offset: float = 6.0         
## Тип сцепки торца: "nem" - обычная, "fixed" - вечная (только с таким же), "" - механизма нет (буфер остаётся)
@export var coupler_front: StringName = &"nem"
@export var coupler_rear: StringName = &"nem"
@export var coupler_slack: float = 0.15			# свободный ход сцепки, м
@export var coupler_travel: float = 0.10           # ход буфера до упора, м
@export var coupler_strength: float = 600.0                # сила разрыва сцепки, Н
@export var couple_speed_max: float = 50.0    # макс. скорость, при которой сцепляемся, м/с
@export var impact_dv_limit: float = 50.0# Δv от удара, после которого вагон сходит, м/с
@export_category("Mechanisms")
@export var mechanisms: Array[MechanismConfig] = []
@export var lights: Array[LightConfig] = []


## Типизированное чтение паспорта. null, если у сущности нет паспорта или в нем конфиг другого семейства
static func from_entity(entity: Entity) -> WagonConfig:
	var idc := entity.get_comp(C_Identity) as C_Identity
	if idc == null:
		return null
	return idc.object_config as WagonConfig
