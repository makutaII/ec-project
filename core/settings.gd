extends Node
# class_name не задаём: это синглтон Settings (autoload)

###########################
##💡 Settings - единственный владелец user://settings.cfg (TDD §17)
############################
## Раньше Hints, GFX и ObserveCameraRig сами читали и писали файл (load -> set -> save).
## Теперь все ходят сюда: файл читается один раз, запись отложенная.
##
## Секции файла остаются прежними, старый settings.cfg читается без миграции:
##   [ui] hints_enabled, [graphics] quality/look/time, [camera] bookmarks.
## Новые секции (языки, раскладка окон, клавиши) добавляются теми же вызовами.

## ⚡Сигнал: значение изменилось (в том числе из окна настроек)
signal changed(section: String, key: String, value: Variant)

const PATH := "user://settings.cfg"
## Пауза перед записью на диск после последнего изменения, с
const SAVE_DELAY := 0.5

var _cfg := ConfigFile.new()
var _dirty := false
var _timer: Timer


func _ready() -> void:
	_cfg.load(PATH)   # нет файла: get_value вернёт значения по умолчанию
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = SAVE_DELAY
	_timer.timeout.connect(save_now)
	add_child(_timer)


func get_value(section: String, key: String, default: Variant = null) -> Variant:
	return _cfg.get_value(section, key, default)


func has_value(section: String, key: String) -> bool:
	return _cfg.has_section_key(section, key)


## Записывает значение. Если оно не изменилось, ничего не делает
func set_value(section: String, key: String, value: Variant) -> void:
	if _cfg.has_section_key(section, key) and _cfg.get_value(section, key) == value:
		return
	_cfg.set_value(section, key, value)
	_dirty = true
	if _timer and is_inside_tree():
		_timer.start()   # перезапуск: пишем один раз после серии изменений
	changed.emit(section, key, value)


## Удаляет ключ (сброс к значению по умолчанию)
func erase_value(section: String, key: String) -> void:
	if not _cfg.has_section_key(section, key):
		return
	_cfg.erase_section_key(section, key)
	_dirty = true
	if _timer and is_inside_tree():
		_timer.start()


## Удаляет секцию целиком (сброс раскладки окон и т.п.)
func erase_section(section: String) -> void:
	if not _cfg.has_section(section):
		return
	_cfg.erase_section(section)
	_dirty = true
	if _timer and is_inside_tree():
		_timer.start()


## Немедленная запись. Вызывается сама по таймеру, при закрытии окна и при выходе из дерева
func save_now() -> void:
	if not _dirty:
		return
	var err := _cfg.save(PATH)
	if err == OK:
		_dirty = false
	else:
		push_error("Settings: не удалось сохранить %s (код %d)" % [PATH, err])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		save_now()


func _exit_tree() -> void:
	save_now()
