class_name InfoToolTab extends InfoTab

# XX claude-terra 13.14 H2d (новый файл)
###########################
## Вкладка «Инструмент» (ATTN_17 U5a, ATTN_13 H2d): настройки активного инструмента, см. ToolSettings.
###########################
## Привязана не к сущности, а к поставщику настроек (InfoPanel.tool_provider, его ставит ToolController.publish_tool_settings).
## Видна, только когда сущность не выбрана. Строки те же, что на «Вид» (InfoSectionView), строки note идут в подвал.
## Живая: getter-ы читаются в refresh() (10 Гц), набор строк пересобирается при смене ToolSettings.version_of.

var _box: VBoxContainer
var _title: Label
var _provider: Object
var _version := -1
var _live: Array[Dictionary] = []
var _notes: Array[Dictionary] = []


func _setup() -> void:
	var page := make_page("Инструмент")
	_title = Label.new()
	_title.theme_type_variation = &"LabelDim"
	page.add_child(_title)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 6)
	page.add_child(_box)


func can_show(entity: Entity) -> bool:
	return entity == null and ToolSettings.is_provider(_provider)


## Поставщик настроек сменился (InfoPanel): строки строятся заново. null: вкладка пустеет
func set_provider(provider: Object) -> void:
	_provider = provider if ToolSettings.is_provider(provider) else null
	_rebuild()


func refresh() -> void:
	if not ToolSettings.is_provider(_provider):
		return
	if ToolSettings.version_of(_provider) != _version:
		_rebuild()
		return
	_title.text = String(_provider.call(&"settings_title"))
	for v in _live:
		InfoSectionView.refresh_row(v)
	for i in _notes.size():
		var val: Variant = _notes[i].text
		footer_message(StringName("note%d" % i), str((val as Callable).call() if val is Callable else val), _notes[i].kind)


func _clear() -> void:
	_live.clear()
	_notes.clear()
	footer_clear()
	if _box == null:
		return
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()


func _rebuild() -> void:
	_clear()
	if not ToolSettings.is_provider(_provider):
		_version = -1
		if _title != null:
			_title.text = ""
		return
	_version = ToolSettings.version_of(_provider)
	_title.text = String(_provider.call(&"settings_title"))
	for section: InfoSection in _provider.call(&"get_info_sections"):
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
