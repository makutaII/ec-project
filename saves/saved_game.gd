class_name SavedGame extends Resource


########################
## Ресурс содержит данные для сохранения всех объектов
########################

## Название макета для TopBar (U10). Пусто в старых сейвах: тогда «Новый макет»
@export var layout_name: String = ""

## данные камеры
#@export var gimbal_transform 	:Transform3D
#@export var gimbal_elevation 	:Transform3D 
#@export var gimbal_camera		:Transform3D 

@export var gimbal = {
	"transform": Transform3D.IDENTITY,
	"elevation": Transform3D.IDENTITY,
	"camera": Transform3D.IDENTITY,
}
@export var entities: Array = []
## Комната мира (RoomCatalog). В сейвах до второй комнаты поля нет: детская
@export var room_id: StringName = &"kid_room_10"
## Устарело (RM9b): варианты процедурной комнаты (стена, покрывало, шторы, постеры). Поле оставлено, чтобы старые сейвы читались; игра его не пишет и не читает
@export var room_variants: Dictionary = {}
## Состояние управляемых объектов комнаты со scope = observe: id управления -> значение 0..1 (RoomBuilder.get_control_state, ATTN_25 RM6).
## В старых сейвах поля нет: начальные значения. Относится к room_id этого же сейва
@export var room_controls: Dictionary = {}
## Подмакетник (LYM.get_state, ATTN_23). Пусто = сейв до подмакетника: стол как в v1, варианты комнаты не трогаем
@export var layout: Dictionary = {}
## Активный стиль траков макета (TSM.current_id). Пусто = стиль по умолчанию из набора
@export var track_style: StringName = &""

## Состояние источников питания и сети (PGM.save_state, ATTN_10 D2): модели, выводы, команды, estop, защита.
## Пусто в сейвах до D2: после загрузки питание 0
@export var power_state: Dictionary = {}

## Краска кистей (TGM.paint.save_data, ATTN_13 §13.13). Пусто = краски нет (в том числе сейвы до кистей)
@export var paint: Dictionary = {}

### массив в GM контуры питания
#@export var clip_numbers		:Array[int] = []
#@export var power_pwm 			:Dictionary[int, int] = {}

### Данные контролера питания
#@export var controller_setting 	:ControllerSetting
#
#### трак 
#@export var	saved_data: Array[SavedData] = [] # это уже перенесено в SavedData
#### Это массив, который содержит все данные объектов, которые передали эти данные
