class_name TopBar extends PanelContainer

# U9 (ATTN_17 §17.4): новый файл, заменяет TopPanel и ModeLabel
########################
## Верхняя полоса HUD. Слева: системное меню и название макета. По центру: статистика макета (StatsBar).
## Справа: ModePanel с пятью кнопками режимов.
## Статистику считает LayoutStats, чипы описаны данными (StatSpec). Что не влезло, уходит в список «…».
########################

const CHIP_SCENE := preload("res://ui/widgets/stat_chip.tscn")
## Пути к сервисам игры: HUD → UI → GameRoot
@onready var save_manager: SaveManager = $"../../../SaveManager"
## Кнопка системного меню: пункты и действия задаёт SystemMenu (U10)
@onready var menu_button: MenuButton = %SystemMenu

@onready var _stats_host: Control = %StatsHost
@onready var _stats_bar: HBoxContainer = %StatsBar
@onready var _more: MenuButton = %MoreStats
@onready var _lab_label: Label = %LabLabel
@onready var _layout_name: Label = %LayoutNameLabel
@onready var _layout_edit: LineEdit = %LayoutNameEdit

var _stats: LayoutStats
var _chips: Array[StatChip] = []


## Перечень чипов. Новый чип: одна строка (id, название для тултипа, подпись без иконки, поле LayoutStats,
## путь иконки, единица, знаков после запятой, скрывать ли ноль)
static func stat_specs() -> Array[StatSpec]:
	return [
		StatSpec.make(&"tracks", "Траки на столе", "Траки", &"tracks", "res://ui/icons/railroad/straight_wood_ballast.svg"),
		StatSpec.make(&"length", "Общая длина траков", "Длина", &"track_length", "", "u", 0),
		StatSpec.make(&"wagons", "Вагоны и локомотивы", "Вагоны", &"wagons"),
		StatSpec.make(&"consists", "Составы (сцепленные вагоны, от двух)", "Составы", &"consists"),
		StatSpec.make(&"contours", "Занятые контуры питания", "Контуры", &"contours", "res://ui/icons/electric/electric.svg"),
		StatSpec.make(&"others", "Прочие объекты", "Объекты", &"others"),
	]


func _ready() -> void:
	# Название макета: показывает SaveManager.layout_name, двойной щелчок переименовывает
	save_manager.layout_name_changed.connect(_on_layout_name_changed)
	_on_layout_name_changed(save_manager.layout_name)
	_layout_name.gui_input.connect(_on_layout_name_gui_input)
	_layout_edit.text_submitted.connect(func(_t: String) -> void: _end_rename(true))
	_layout_edit.focus_exited.connect(func() -> void: _end_rename(true))
	_layout_edit.gui_input.connect(_on_layout_edit_gui_input)

	# Метка Lab: прежний «[LAB]» из ModeLabel
	GFX.lab_changed.connect(_on_lab_changed)
	_on_lab_changed(GFX.lab_mode)

	# Статистика
	for spec in stat_specs():
		var chip: StatChip = CHIP_SCENE.instantiate()
		_stats_bar.add_child(chip)
		_stats_bar.move_child(chip, _more.get_index())
		chip.setup(spec)
		_chips.append(chip)
	_stats = LayoutStats.new()
	_stats.name = &"LayoutStats"
	add_child(_stats)
	_stats.changed.connect(_refresh_stats)
	_stats_host.resized.connect(_fit_stats)
	_refresh_stats()


## Кнопка меню для SystemMenu
func get_system_menu_button() -> MenuButton:
	return menu_button


func _on_layout_name_changed(layout: String) -> void:
	_layout_name.text = layout


func _on_layout_name_gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
		_layout_edit.text = _layout_name.text
		_layout_name.visible = false
		_layout_edit.visible = true
		_layout_edit.grab_focus()
		_layout_edit.select_all()


func _on_layout_edit_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE:
		_end_rename(false)
		_layout_edit.accept_event()


func _end_rename(apply: bool) -> void:
	if not _layout_edit.visible:
		return
	var txt := _layout_edit.text
	_layout_edit.visible = false
	_layout_name.visible = true
	if apply:
		save_manager.set_layout_name(txt)


## Кнопки режимов для ModeController (сам узел внутри этой сцены, снаружи по % не виден)
func get_mode_panel() -> Node:
	return %ModePanel


func _on_lab_changed(on: bool) -> void:
	_lab_label.visible = on


func _refresh_stats() -> void:
	for chip in _chips:
		chip.set_value(float(_stats.get(chip.spec.key)))
	_fit_stats()


## Чипы слева направо, пока помещаются; остальные скрыты и перечислены в «…».
## Нулевые (hide_zero) скрыты всегда. Размер StatsHost от содержимого не зависит
func _fit_stats() -> void:
	var avail := _stats_host.size.x
	var sep := float(_stats_bar.get_theme_constant(&"separation"))
	var wanted: Array[StatChip] = []
	for chip in _chips:
		if chip.has_value:
			wanted.append(chip)
		else:
			chip.visible = false
	var total := 0.0
	for chip in wanted:
		total += chip.get_combined_minimum_size().x + sep
	var limit := avail
	if total - sep > avail:
		limit = avail - _more.get_combined_minimum_size().x - sep
	var used := 0.0
	var overflow: Array[String] = []
	for chip in wanted:
		var w := chip.get_combined_minimum_size().x
		if used + w <= limit:
			chip.visible = true
			used += w + sep
		else:
			chip.visible = false
			overflow.append(chip.summary())
	_more.visible = not overflow.is_empty()
	var more_popup := _more.get_popup()
	more_popup.clear()
	for line in overflow:
		more_popup.add_item(line)
		more_popup.set_item_disabled(more_popup.item_count - 1, true)
