class_name ToggleRow extends SettingRow

# U11 (ATTN_17 §17.3.4): новый файл
## Строка с переключателем (bool).

@onready var _toggle: CheckButton = %Toggle


func _ready() -> void:
	_toggle.toggled.connect(func(_on: bool) -> void: _changed())


func get_value() -> Variant:
	return _toggle.button_pressed


func _apply_value(v: Variant) -> void:
	_toggle.set_pressed_no_signal(bool(v))


func _set_control_enabled(on: bool) -> void:
	_toggle.disabled = not on
