class_name RoadConfig extends TrackConfig

###########################
## Паспорт сегмента дороги (ATTN_28 §28.2)
###########################
## Подкласс TrackConfig (проходит приведение `as TrackConfig` в PathSetting.apply_passport, как RideTrackConfig у горок).
## Форма задаётся унаследованными полями: radius (у прямой это длина вдоль оси) и deg (дуга в плане, + вправо).
## Три ширины независимы, каждая меняет только свой параметр:
##  - collision_width (унаследована): ширина коллизии основания. Паспорт > 0 меняет только этот объект, иначе берётся collision_width стиля;
##  - видимая ширина полотна и ложе рельефа: профиль стиля (ballast_profile, TrackStyle.ballast_half_width), паспортом не меняется;
##  - lane_width: ширина полосы, коридор машины (CS3 и далее: смещение машины, парковка, разметка).

## Сеть сокетов: ключ совместимости. Сокет дороги стыкуется только с дорогой (C_Path.network_id, C_Socket.network)
@export var network: StringName = &"road"
## Ширина полосы, ю (как у Faller H0: 50 мм, то есть 5 ю). Коридор машины. На коллизию и видимую ширину не влияет
@export var lane_width := 5.0
## Управляющий элемент куска: none, stop, junction, parking, sensor (CS4)
@export var control: StringName = &"none"


## StyleVisualSetting спрашивает у паспорта, каким компонентом строить путь
func create_path() -> C_Path:
	return C_RoadPath.new()
