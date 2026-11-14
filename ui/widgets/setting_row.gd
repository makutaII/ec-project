class_name SettingRow extends HBoxContainer

# U11 (ATTN_17 §17.3.4): новый файл
## Основа строки настройки: подпись, элемент, кнопка «Сброс» (к значению по умолчанию).
## Наследники: ToggleRow, OptionRow, SpinRow. Использование:
##   var row: ToggleRow = ROW.instantiate(); box.add_child(row); row.setup("Подпись", false); row.set_value(x)
##   row.value_changed.connect(...)  # только от действий игрока, set_value сигнал не шлёт
## Недоступная строка (set_available(false, "Скоро")) серая, значение не меняется.

## ⚡ Игрок изменил значение (или нажал «Сброс»)
signal value_changed(value: Variant)

@onready var _caption: Label = %Caption
@onready var _reset: Button = %ResetButton

var default_value: Variant = null
var _available := true


## Подпись и значение по умолчанию. Вызывать после add_child
func setup(title: String, default: Variant) -> void:
	_caption.text = title
	default_value = default
	if not _reset.pressed.is_connected(_on_reset_pressed):
		_reset.pressed.connect(_on_reset_pressed)
	_refresh_reset()


## Показать значение без сигнала (открытие окна, внешнее изменение)
func set_value(v: Variant) -> void:
	_apply_value(v)
	_refresh_reset()


## Строка серая и не реагирует; hint виден в тултипе строки
func set_available(on: bool, hint: String = "") -> void:
	_available = on
	_set_control_enabled(on)
	tooltip_text = "" if on else hint
	_caption.modulate.a = 1.0 if on else 0.5
	_refresh_reset()


## Переопределить: текущее значение элемента
func get_value() -> Variant:
	return null


## Переопределить: поставить значение элемента без сигнала
func _apply_value(_v: Variant) -> void:
	pass


## Переопределить: включить или выключить элемент
func _set_control_enabled(_on: bool) -> void:
	pass


## Наследник вызывает при действии игрока
func _changed() -> void:
	value_changed.emit(get_value())
	_refresh_reset()


func _refresh_reset() -> void:
	_reset.disabled = not _available or get_value() == default_value


func _on_reset_pressed() -> void:
	_apply_value(default_value)
	_changed()
