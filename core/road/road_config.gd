class_name RoadConfig extends TrackConfig

###########################
## Паспорт сегмента дороги (ATTN_28 §28.2)
###########################
## Подкласс TrackConfig (проходит приведение `as TrackConfig` в PathSetting.apply_passport, как RideTrackConfig у горок).
## Форма задаётся унаследованными полями: radius (у прямой это длина вдоль оси) и deg (дуга в плане, + вправо).
## Ширина полотна одна: road_width даёт коллизию основания (effective_collision_width), ширину меша (shape_style) и ложе рельефа
## (C_RoadPath.bed_half_width). collision_width у паспорта и в стиле для дороги не работает, профиль стиля только задаёт форму сечения.
## Поля lane_width и control читают CS3 и CS4: в CS1 они только хранятся.

## Сеть сокетов: ключ совместимости. Сокет дороги стыкуется только с дорогой (C_Path.network_id, C_Socket.network)
@export var network: StringName = &"road"
## Ширина полосы, ю (старт: 5 на прямой, 7 в кривой). Одна полоса на кусок (ATTN_28 Р5)
@export var lane_width := 5.0
## Ширина полотна, ю (старт: 8). Равна ширине меша, коллизии основания и ложа рельефа; меняется только здесь
@export var road_width := 8.0
## Управляющий элемент куска: none, stop, junction, parking, sensor (CS4)
@export var control: StringName = &"none"


## Ширина полотна вместо collision_width: так ширина дороги живёт в одном поле
func effective_collision_width() -> float:
	return road_width if road_width > 0.0 else collision_width


## Меш полотна растягивается до road_width (профиль стиля масштабируется по x)
func shape_style(st: TrackStyle) -> TrackStyle:
	return TrackStyle.with_ballast_width(st, road_width)


## StyleVisualSetting спрашивает у паспорта, каким компонентом строить путь
func create_path() -> C_Path:
	return C_RoadPath.new()
