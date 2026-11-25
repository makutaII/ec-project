class_name RoadConfig extends TrackConfig

###########################
## Паспорт сегмента дороги (ATTN_28 §28.2)
###########################
## Подкласс TrackConfig (проходит приведение `as TrackConfig` в PathSetting.apply_passport, как RideTrackConfig у горок).
## Форма задаётся унаследованными полями: radius (у прямой это длина вдоль оси) и deg (дуга в плане, + вправо).
## Ширина коллизии основания работает как у трака: collision_width паспорта > 0 меняет только этот объект,
## иначе берётся collision_width стиля (общая для всех объектов стиля). Ширина меша и ложа рельефа по умолчанию равна
## ширине коллизии (профиль стиля масштабируется по x), road_width нужна, только если полотно должно быть шире или уже коллизии.
## Поля lane_width и control читают CS3 и CS4: в CS1 они только хранятся.

## Сеть сокетов: ключ совместимости. Сокет дороги стыкуется только с дорогой (C_Path.network_id, C_Socket.network)
@export var network: StringName = &"road"
## Ширина полосы, ю (как у Faller H0: 5 на прямой, 7 в кривой). Коридор машины, читают CS2 и CS3
@export var lane_width := 5.0
## Ширина видимого полотна и ложа рельефа, ю. 0 = как ширина коллизии (collision_width паспорта или стиля)
@export var road_width := 0.0
## Управляющий элемент куска: none, stop, junction, parking, sensor (CS4)
@export var control: StringName = &"none"


## Меш полотна растягивается до road_width, а без неё до ширины коллизии стиля (st уже несёт collision_width паспорта)
func shape_style(st: TrackStyle) -> TrackStyle:
	var w := road_width
	if w <= 0.0 and st != null:
		w = st.collision_width
	return TrackStyle.with_ballast_width(st, w)


## StyleVisualSetting спрашивает у паспорта, каким компонентом строить путь
func create_path() -> C_Path:
	return C_RoadPath.new()
