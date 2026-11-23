class_name InfoHintsTab extends InfoTab

###########################
## Вкладка «Подсказки» (ATTN_17 U5a.5): развёрнутая подсказка выбранного объекта
###########################
## Создается кодом. Три части: описание объекта, строки характеристик (контракт HoverLines, те же, что в подсказке
## при наведении, но все) и клавиши, которые подходят объекту в текущем режиме (Hints.selected_rows).
## Видна у любого объекта с паспортом. Живая: части пересобираются, только когда их содержимое изменилось.

## Вид строки HoverLines -> вариация темы (пусто: обычный цвет)
const LINE_VARIATIONS := {&"info": &"", &"dim": &"LabelDim", &"ok": &"LampOn", &"warn": &"LampWarn", &"bad": &"LampBad"}

var _box: VBoxContainer
var _sig := ""


func _setup() -> void:
	_box = make_page("Подсказки")


func can_show(entity: Entity) -> bool:
	return entity != null and entity.has_comp(C_Identity)


func _on_bind() -> void:
	_sig = ""
	refresh()


func refresh() -> void:
	if target == null or not is_instance_valid(target):
		return
	var identity := target.get_comp(C_Identity) as C_Identity
	if identity == null:
		return
	var description := identity.get_description()
	var lines := HoverLines.collect(target)
	var rows := Hints.selected_rows(identity.get_category(), target.has_comp(C_Switch))
	var sig := _signature(description, lines, rows)
	if sig == _sig:
		return
	_sig = sig
	_rebuild(description, lines, rows)


func _signature(description: String, lines: Array[Dictionary], rows: Array) -> String:
	var parts: PackedStringArray = [description]
	for l in lines:
		parts.append("%s|%s" % [l.kind, l.text])
	for r in rows:
		parts.append("%s|%s" % [r[0], r[1]])
	return "\n".join(parts)


func _rebuild(description: String, lines: Array[Dictionary], rows: Array) -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	if description != "":
		block_heading(_box, "Описание")
		_box.add_child(_wrapped(description))
	if not lines.is_empty():
		block_heading(_box, "Характеристики")
		for l in lines:
			var label := _wrapped(String(l.text))
			var variation: StringName = LINE_VARIATIONS.get(l.kind, &"")
			if variation != &"":
				label.theme_type_variation = variation
			_box.add_child(label)
	if not rows.is_empty():
		block_heading(_box, "Клавиши")
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 4)
		_box.add_child(grid)
		for r in rows:
			var chip := PanelContainer.new()
			chip.theme_type_variation = &"KeyChip"
			chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var key := Label.new()
			key.text = String(r[0])
			chip.add_child(key)
			grid.add_child(chip)
			grid.add_child(_wrapped(String(r[1])))
	if _box.get_child_count() == 0:
		var empty := _wrapped("Для этого объекта подсказок нет")
		empty.theme_type_variation = &"LabelDim"
		_box.add_child(empty)


func _wrapped(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label
