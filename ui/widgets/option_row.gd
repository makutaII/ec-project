class_name OptionRow extends SettingRow

# U11 (ATTN_17 §17.3.4): новый файл
## Строка с выбором из списка. Значение это id варианта (не номер и не заголовок).

@onready var _option: OptionButton = %Option


func _ready() -> void:
	_option.item_selected.connect(func(_i: int) -> void: _changed())


## Минимальная ширина списка (в узких панелях меньше 200)
func set_min_width(w: float) -> void:
	_option.custom_minimum_size.x = w


## ids и titles одной длины; id любого типа (обычно StringName)
func set_options(ids: Array, titles: Array) -> void:
	_option.clear()
	for i in ids.size():
		_option.add_item(String(titles[i]), i)
		_option.set_item_metadata(i, ids[i])


func get_value() -> Variant:
	var i := _option.selected
	return _option.get_item_metadata(i) if i >= 0 else null


func _apply_value(v: Variant) -> void:
	for i in _option.item_count:
		if _option.get_item_metadata(i) == v:
			_option.select(i)
			return


func _set_control_enabled(on: bool) -> void:
	_option.disabled = not on
