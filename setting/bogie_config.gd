class_name BogieConfig extends Resource
####################
#### Паспорт настроек одной тележки/оси.
#### Добавляется в массив компонента C_Bogie через инспектор.
####################

@export_category("Base Setup")
## Смещение меша боги от 0 вверх и вдоль. 
#@export var b_offset: = Vector3(0.0, 0.7, -2.43)        

## моя‼️Замена b_offset на b_offset_z. Y - это всегда радиус без реборды
@export var b_offset_z: = -2.43
# Ссылка на визуал именно этой тележки 
@export var scene : PackedScene = preload("res://data/trains/default_bogie.tscn")

@export_category("Wheel Pair Setup")
# x - пока резерв (может для ширины колеи), 
# y - высота оси (Радиус колеса без реборды , которая = 0,1), 
# z - смещение оси от центра тележки (если 0 - ось одна)
@export var wheel_pair_scene : PackedScene = preload("res://data/trains/wheel_pair_01.tscn")

## Установка колесной пары, 0.71 - радиус без реборды.
@export var wheel_pair_position: Vector3 = Vector3(0.0, 0.71, 1.5)  

## Оси узла: смещения по Z от центра узла, любое число осей, средние где угодно (ведущие колёса паровоза: три и больше).
## Крайние оси симметричны относительно центра узла. Пусто: прежняя схема (одна ось при wheel_pair_position.z = 0, иначе две на ±z)
@export var axle_offsets: PackedFloat32Array = PackedFloat32Array()


## Полубаза: расстояние от центра узла до крайней оси
func half_base() -> float:
	if axle_offsets.is_empty():
		return absf(wheel_pair_position.z)
	var m := 0.0
	for z in axle_offsets:
		m = maxf(m, absf(z))
	return m


## Смещения всех осей по Z от центра узла в порядке сборки колёс. Прежняя схема: первая ось +z, вторая -z (или одна в центре)
func axle_list() -> PackedFloat32Array:
	if not axle_offsets.is_empty():
		return axle_offsets
	var z := wheel_pair_position.z
	if absf(z) > 0.001:
		return PackedFloat32Array([z, -z])
	return PackedFloat32Array([0.0])
