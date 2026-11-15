class_name SpinRow extends SettingRow

# U11 (ATTN_17 §17.3.4): новый файл
## Строка с ползунком (число) и подписью значения справа.

@onready var _slider: HSlider = %Slider
@onready var _value_label: Label = %ValueLabel


func _ready() -> void:
	_slider.value_changed.connect(func(_v: float) -> void:
		_update_label()
		_changed())


## Минимальная ширина ползунка (в узких панелях меньше 160)
func set_slider_min_width(w: float) -> void:
	_slider.custom_minimum_size.x = w


func configure(min_value: float, max_value: float, step: float) -> void:
	_slider.min_value = min_value
	_slider.max_value = max_value
	_slider.step = step


func get_value() -> Variant:
	return _slider.value


func _apply_value(v: Variant) -> void:
	_slider.set_value_no_signal(float(v))
	_update_label()


func _set_control_enabled(on: bool) -> void:
	_slider.editable = on


func _update_label() -> void:
	_value_label.text = str(snappedf(_slider.value, 0.01))
