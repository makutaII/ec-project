class_name GroupSelectionPanel extends PanelContainer

# XX claude-switch (новый файл)
#########################
## Временная панель сводки по группе (выделение рамкой). Инфопанель при группе не трогаем.
## Раньше называлась InfoToolTip (переименована 20.11.2026, U20a: имя InfoToolTip занято сообщением инструмента).
#########################
## Показывает, сколько объектов выбрано, и по каждой категории (траки, вагоны, домики, террейн) число объектов рамки и галку фильтра:
## снятая галка убирает категорию из группы. Кнопка «Удалить» и клавиша Del удаляют группу.
## Строится кодом, живет в CanvasLayer SelectTool, справа сверху. Позиция в константах PANEL_*.
## Сигналы наружу: category_toggled, delete_pressed. Состояние задает SelectTool через set_state().

signal category_toggled(category: StringName, on: bool)
signal delete_pressed

const PANEL_WIDTH := 238.0
const PANEL_RIGHT_MARGIN := 12.0
const PANEL_TOP := 70.0

var _title: Label
var _checks := {}          # категория -> CheckBox
var _delete_btn: Button
var _note: Label
var _syncing := false


func _init() -> void:
	name = "GroupSelectionPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -(PANEL_WIDTH + PANEL_RIGHT_MARGIN)
	offset_right = -PANEL_RIGHT_MARGIN
	offset_top = PANEL_TOP
	offset_bottom = PANEL_TOP
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_END

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, 0.88)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	add_theme_stylebox_override("panel", sb)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	_title = Label.new()
	_title.text = "Выбрано: 0"
	box.add_child(_title)

	for cat in GroupSelection.CATEGORIES + GroupSelection.COASTER_CATEGORIES:
		var cb := CheckBox.new()
		cb.text = GroupSelection.LABELS[cat]
		cb.button_pressed = true
		cb.focus_mode = Control.FOCUS_NONE   # как у кнопок тулбара: Пробел и Enter не нажимают галку, клавиши остаются инструментам
		cb.toggled.connect(_on_check_toggled.bind(cat))
		box.add_child(cb)
		_checks[cat] = cb

	_delete_btn = Button.new()
	_delete_btn.text = "Удалить (Del)"
	_delete_btn.focus_mode = Control.FOCUS_NONE
	_delete_btn.pressed.connect(func(): delete_pressed.emit())
	box.add_child(_delete_btn)

	var hint := Label.new()
	hint.text = "ПКМ: снять выбор. Тащить объект группы: двигать группу"
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = PANEL_WIDTH - 24.0
	box.add_child(hint)

	_note = Label.new()
	_note.modulate = Color(1.0, 0.45, 0.35)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size.x = PANEL_WIDTH - 24.0
	_note.visible = false
	box.add_child(_note)


## selected: сколько в группе; counts: категория -> число объектов рамки; enabled: категория -> галка
func set_state(selected: int, counts: Dictionary, enabled: Dictionary) -> void:
	_syncing = true
	set_note("")   # состав группы изменился: старое сообщение устарело
	_title.text = "Выбрано: %d" % selected
	for cat in _checks:
		var cb: CheckBox = _checks[cat]
		var n := int(counts.get(cat, 0))
		cb.text = "%s (%d)" % [GroupSelection.LABELS[cat], n]
		cb.set_pressed_no_signal(bool(enabled.get(cat, true)))
		cb.disabled = n == 0
		cb.visible = GroupSelection.categories_for_mode(Global.current_mode).has(cat)   # строки только режима
	_delete_btn.disabled = selected == 0
	_syncing = false


## Сообщение в панели (например, почему группа не двигается). Пустое скрывает
func set_note(text: String) -> void:
	_note.text = text
	_note.visible = text != ""


func _on_check_toggled(on: bool, category: StringName) -> void:
	if not _syncing:
		category_toggled.emit(category, on)
