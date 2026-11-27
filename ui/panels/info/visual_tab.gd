class_name InfoVisualTab extends InfoTab

# U13 (ATTN_17 D13): новый файл
## Вкладка «Вид»: рисует секции компонентов цели (InfoSection из get_info_sections()).
## Показывается, если хоть один компонент цели описал секцию или есть блок (U5a.3). Секции: стиль трака
## (C_StyleVisual) и камера вагона (C_CameraTarget). Строки с живыми значениями обновляются в refresh().
## Блоки (U5a.3): готовые вкладки, встроенные в эту (InfoTab.embed): механизмы и свет (InfoMechTab), толщина и
## стадия листа (InfoTerrainTab). Их сообщения и действия идут в подвал этой вкладки.

var _box: VBoxContainer
## Контролы, которым нужно обновление: [{type, row, control}]
var _live: Array[Dictionary] = []
## Строки типа note (InfoSection.note): в тело не попадают, идут в подвал вкладки
var _notes: Array[Dictionary] = []


func _setup() -> void:
	# В info_panel.tscn лежит пустая заготовка VisualTab: чистим и строим свой контейнер
	for c in control.get_children():
		c.queue_free()
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	control.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 6)
	root.add_child(_box)
	_blocks_box = VBoxContainer.new()
	_blocks_box.add_theme_constant_override("separation", 6)
	root.add_child(_blocks_box)
	_embed_blocks([InfoMechTab.new(), InfoTerrainTab.new()])


func can_show(entity: Entity) -> bool:
	if entity == null:
		return false
	return _blocks_can_show(entity) or not _collect(entity).is_empty()


func _on_bind() -> void:
	_rebuild()
	_bind_blocks()


func _on_unbind() -> void:
	_clear()
	_unbind_blocks()


func components_changed() -> void:
	if target != null:
		_rebuild()
		_bind_blocks()
		panel.refresh_tab_visibility()


func refresh() -> void:
	for v in _live:
		InfoSectionView.refresh_row(v)
	_refresh_blocks()
	for i in _notes.size():
		var val: Variant = _notes[i].text
		footer_message(StringName("note%d" % i), str((val as Callable).call() if val is Callable else val), _notes[i].kind)


## Секции всех компонентов цели, у которых есть get_info_sections()
static func _collect(entity: Entity) -> Array[InfoSection]:
	var out: Array[InfoSection] = []
	for child in entity.get_children():
		if child is Component and child.has_method(&"get_info_sections"):
			var comp: Variant = child   # метод есть не у всех компонентов: вызываем без статической проверки
			for s in comp.get_info_sections():
				out.append(s)
	return out


func _clear() -> void:
	_live.clear()
	_notes.clear()
	footer_clear()
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()


func _rebuild() -> void:
	_clear()
	if target == null:
		return
	for section in _collect(target):
		var body_rows: Array[Dictionary] = []
		for row in section.rows:
			if row.type == &"note":
				_notes.append(row)
			else:
				body_rows.append(row)
		if body_rows.is_empty():
			continue
		var head := Label.new()
		head.text = section.title
		head.theme_type_variation = &"LabelDim"
		_box.add_child(head)
		for row in body_rows:
			_box.add_child(InfoSectionView.make_row(row, _live))
	refresh()
