@tool
class_name RoomConfig extends Resource

########################
## Паспорт комнаты. Значения по умолчанию = kid_room_10 (комната ребёнка 10 лет).
########################
## Единицы: 1 u = 1 см реального стола (TDD §9). Центр комнаты по X/Z в (0, 0), столешница подмакетника на y = 0.
## Комната целиком лежит в сцене (scene, корень RoomRoot, модель из Blender): здесь только паспортные числа, которые читает игра
## (границы камеры, правила стола, свет). Кода, строящего комнату по этим числам, нет (ATTN_25 RM9b).

@export var id: StringName = &"kid_room_10"
## Название и подсказка карточки комнаты (список комнат, Room Studio). Карточка лежит в data/rooms/cards/<id>.tres
@export var title := ""
@export var tip := ""
## Тестовая комната (стенд, куб): игроку не показывается (sandbox_setup, карточки старта), админу и Room Studio видна с пометкой
@export var dev_only := false
## Сцена комнаты (data/models/room_<имя>/room_<имя>.tscn, корень RoomRoot): стены, мебель, коллизии и лампы лежат в ней.
## Карточка без сцены каталогом не читается. Здесь остаются паспортные данные: floor_y, стол, bounds, daylight, ambient_mul
@export var scene: PackedScene

@export_category("Room")
## Внутренний размер: X ширина, Y высота, Z глубина
@export var size := Vector3(480.0, 250.0, 380.0)
## Уровень пола (стол 0.5 м: столешница на y = 0)
@export var floor_y := -50.0
## Проёмы: x - центр вдоль стены, w / h - размер, sill - высота низа от пола.
## Окно в северной стене (-Z), дверь в южной (+Z)
## Окно в северной стене. Пятно солнца на столе: ширина окна ≈ ширина пятна, высота окна / tan(высота солнца) ≈ глубина пятна
@export var window := {"x": 0.0, "w": 170.0, "sill": 80.0, "h": 140.0}
@export var door := {"x": 100.0, "w": 80.0, "sill": 0.0, "h": 200.0}

@export_category("Shape")
## Форма для правил стола (TableRules): &"box": прямоугольная коробка. &"attic": скос крыши у восточной стены, к ней стол не крепится.
## &"none": комнаты нет, только стол (стенд для замеров, без пола, стен и потолка)
@export var shape: StringName = &"box"

## Включать оверлей статистики (GFX.stats) при входе в комнату (стенд)
@export var show_stats := false

@export_category("Light")
## false: окна закрыты, солнца и неба нет. Свет: лампы комнаты (из сцены) и ambient (GFX гасит Sun и SkyFill)
@export var daylight := true
## Множитель ambient комнаты (Look.ambient_energy × ambient_mul). Без окон ambient ниже, иначе плоско
@export var ambient_mul := 1.0

@export_category("Table (подмакетник v1)")
## Столешница: X, Z
@export var table_top := Vector2(200.0, 100.0)
@export var table_top_thickness := 5.0
@export var table_leg := 6.0

@export_category("Camera")
## Границы, в которых держим камеру (CameraBounds). Низ выше столешницы, верх ниже потолка
@export var bounds := AABB(Vector3(-230.0, 3.0, -180.0), Vector3(460.0, 190.0, 360.0))
