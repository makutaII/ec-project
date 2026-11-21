class_name SystemMenu extends Node

# U10 (ATTN_17 §17.3.1): новый файл, заменяет меню из TopPanel
## Системное меню (кнопка в TopBar): Новый, Сохранить, Загрузить, Настройки, Выход.
## Подсказки (H) переехали в SideDock (21.11.2026).
## Новый и Выход спрашивают подтверждение. Save и Load открывают SaveLoadDialog.
## Настройки открывают SettingsWindow (U11).

const ID_NEW := 0
const ID_SAVE := 1
const ID_LOAD := 2
const ID_SETTINGS := 4
const ID_EXIT := 5

@onready var _top_bar: TopBar = %TopBar
@onready var _confirm: ConfirmDialog = %ConfirmDialog
@onready var _save_load: SaveLoadDialog = %SaveLoadDialog
@onready var _settings: SettingsWindow = %SettingsWindow
@onready var _save_manager: SaveManager = get_node("/root/GameRoot/SaveManager")

var _popup: PopupMenu


func _ready() -> void:
	_save_load.confirm = _confirm
	_save_load.save_requested.connect(_on_save_requested)
	_save_load.load_requested.connect(_on_load_requested)

	_popup = _top_bar.get_system_menu_button().get_popup()
	_popup.clear()
	_popup.add_item("Новый макет", ID_NEW)
	_popup.add_item("Сохранить…", ID_SAVE)
	_popup.add_item("Загрузить…", ID_LOAD)
	_popup.add_separator()
	_popup.add_item("Настройки…", ID_SETTINGS)
	_popup.add_separator()
	_popup.add_item("Выход", ID_EXIT)
	_popup.id_pressed.connect(_on_id_pressed)


func _on_id_pressed(id: int) -> void:
	match id:
		ID_NEW:
			_new_layout()
		ID_SAVE:
			_save_load.open_save(_save_manager.layout_name)
		ID_LOAD:
			_save_load.open_load()
		ID_SETTINGS:
			_settings.open()
		ID_EXIT:
			_exit()


func _new_layout() -> void:
	if await _confirm.ask("Новый макет", "Очистить стол? Несохранённые изменения будут потеряны.", "Очистить", "Отмена"):
		_save_manager.clear_scene()


func _exit() -> void:
	if await _confirm.ask("Выход", "Выйти из игры? Макет сохранится в автосохранение.", "Выйти", "Отмена"):
		_save_manager.quit_game()


func _on_save_requested(layout: String) -> void:
	_save_manager.set_layout_name(layout)
	await _save_manager.save_game(SaveManager.slot_from_name(layout))


func _on_load_requested(slot: String) -> void:
	_save_manager.load_game(slot)
