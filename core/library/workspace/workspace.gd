class_name LibraryWorkspace extends VBoxContainer

# XX claude-library (новый файл)
########################
## LibraryWorkspace. База рабочей области Library (ATTN_22 §22.5.1, шаг L1)
########################
## Область это содержимое правой панели экрана: Осмотр, Покраска, Детали, Свет, Стенд, Здания, Сборка, Реставрация.
## Выбранный объект, камера и мир общие и принадлежат экрану, область их только использует.
## Контракт: enter() при включении, exit() при выключении, can_leave() перед выходом из экрана или областью,
## on_subject(setting, info, ms) когда объект показан (info как у StudioWorld.set_subject), handle_key(event) для клавиш.

var id: StringName = &"workspace"
var title := ""
var screen: Control


func setup(p_screen: Control) -> void:
	screen = p_screen


func enter() -> void:
	pass


func exit() -> void:
	pass


## false: у области есть несохранённая работа, выйти нельзя (область сама спросит игрока)
func can_leave() -> bool:
	return true


## Клавиша экрана (не потреблённая интерфейсом). true: область её обработала
func handle_key(_event: InputEventKey) -> bool:
	return false


## Событие мыши в 3D-виде. true: область его забрала (например, рисует), вид его не получит
func view_input(_event: InputEvent) -> bool:
	return false


func on_loading(_setting: EntitySetting) -> void:
	pass


func on_subject(_setting: EntitySetting, _info: Dictionary, _ms: int) -> void:
	pass


## «В игру»: область может добавить своё в исполнение, которое уйдёт в игру (например, здание из генератора)
func extend_variant(_variant: Dictionary) -> void:
	pass
