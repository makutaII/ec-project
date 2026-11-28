class_name CarConfig extends ObjectConfig

########################
## Паспорт машины (ATTN_28 §28.2)
########################
## Лежит в C_Identity.object_config машины. Числа стартовые, автор подбирает по ощущению. Единицы: ю и ю/с (1 ю = 1 см модели).
## Читать: CarConfig.from_entity(entity). Скорость в повороте, разгон и торможение читает C_RoadVehicle (CS3).

## Сцена машины, как у вагона (WagonConfig.scene). Пусто: кузов, кабина и колёса собираются из примитивов по габаритам и цвету ниже.
## Правила сцены: начало координат на поверхности дороги между колёсами, вперёд -Z; узлы MeshInstance3D; цвет кузова задаёт вариант
## объекта (VariantApplier), как у вагонов. Габариты ниже в сцену не масштабируют: они нужны для проверки аварий и коллайдера выбора
## (коллайдер выбора строится по меши сцены). Образец: art/cars/car_template.tscn
@export var scene: PackedScene

## Габариты кузова, ю (легковая H0: 4.5 м натуры это около 5 ю)
@export var length := 5.0
@export var width := 2.2
@export var height := 1.8
## Радиус колеса, ю
@export var wheel_radius := 0.45
## Цвет кузова
@export var body_color := Color(0.75, 0.15, 0.12)
## Предел скорости, ю/с
@export var max_speed := 10.0
## Разгон и торможение, ю/с^2
@export var accel := 6.0
@export var brake := 12.0
## Допустимое боковое ускорение, ю/с^2: от него считается скорость в кривой v = min(max_speed, sqrt(lat_accel_max * R)).
## При 3.0 поворот R15 ограничивает скорость до 6.7 ю/с, R30 до 9.5 ю/с
@export var lat_accel_max := 3.0


static func from_entity(entity: Entity) -> CarConfig:
	var idc := entity.get_comp(C_Identity) as C_Identity if entity != null else null
	if idc == null:
		return null
	return idc.object_config as CarConfig
