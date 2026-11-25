class_name ToolbarController extends Node

########################
##    ToolbarController - UI
## 💡 Единая панель инструментов (ToolDock) для режимов Build и Operate 💡
########################
## Заменила BuildController, OperateController и отрисовку в ObserveController (копии друг друга).
## Строит кнопки «категория → тег → объект» из CatalogProvider режима. Что делать с нажатым объектом,
## знает приемник режима (Callable), его регистрирует адаптер режима через register_mode().
##
## Вид (U15a, ui/hud/tool_dock.tscn, ToolDockView): слева панель категорий (кнопки 40×40 в 2 колонки), справа ToolDock:
## хедер (режим, категория, тег, теги, число объектов, «Дубль»), тело (объекты с переносом строк).
## Режимы подключаются к ModeController контрактом show_mode_ui / hide_mode_ui (см. ModeController).
##
## Связь с игрой через сигналы: object_selected и duplicate_requested уходят в ToolController,
## сигналы BuildTool.last_changed и ToolController.build_selection_cleared приходят обратно (_connect_game).

@export var anim_time := 0.4

## ⚡Сигнал: выбран объект в режиме Build (приемник Build, его слушает ToolController)
signal object_selected(setting: EntitySetting)
## ⚡Сигнал: нажата кнопка «Дубль» (выбранный объект, а если ничего не выбрано, последний поставленный)
signal duplicate_requested

@onready var _view: ToolDockView = %DockRow
@onready var _categories: Control = _view.categories_panel()
@onready var _category_bar: Container = _view.category_grid()
@onready var _dock: Control = _view.dock_column()
@onready var _title: Label = _view.category_label()
@onready var _grid: Container = _view.objects_flow()
@onready var _tag_panel: Container = _view.tags_box()

var _cat_btn_scene := preload("res://ui/buttons/category_button.tscn")
var _tag_btn_scene := preload("res://ui/buttons/tag_button.tscn")

## Текущие выбор: нужен ModeController и адаптерам режимов
var current_cat: StringName = &'idle'
var current_tag: StringName = &'idle'

var _mode: StringName = &""
var _providers := {}   # режим -> CatalogProvider
var _receivers := {}   # режим -> Callable(setting)
var _dup_btn: Button
# XX claude-wire W3: режим «Монтаж»: кнопки «Плита» (показать и скрыть столешницу) и «Схема» (пути)
var _plate_btn: Button
var _scheme_btn: Button
var _del_dc_btn: Button       # Operate: вместо «Дубль» кнопка «Удалить 2D-контроллер» (U15)
var _dup_has_last := false     # есть последний поставленный объект
var _dup_sel_name := ""        # название выбранного настоящего объекта, пусто: ничего не выбрано
var _dup_last_name := ""       # название последнего поставленного объекта
var _dup_sel_icon: Texture2D   # иконка выбранного объекта (U15: на кнопке «Дубль»)
var _dup_last_setting: EntitySetting   # XX claude-coaster C6.1: настройка последнего поставленного, для проверки режима
var _dup_sel_setting: EntitySetting    # и выбранного: в Coaster дублируются только объекты горок, в Build только остальные
var _dup_last_icon: Texture2D  # иконка последнего поставленного
var _filter_bar: FilterBar
var _filters := {}   # "режим/категория" -> {id фильтра: значение}, на время сессии


func _ready() -> void:
	# Build: объекты каталога, приемник это сигнал object_selected
	register_mode(&"build", EntityCatalogProvider.new(&"build"), _emit_build_selected)
	# XX claude-table T2: режим «Секции»: категория table (пресеты секций), приёмник тот же: ToolController включит TableTool
	register_mode(&"sections", EntityCatalogProvider.new(&"sections"), _emit_build_selected)
	# XX claude-coaster C1: режим «Coaster» (ATTN_27): каталог траков горок, приёмник тот же: ToolController включит BuildTool
	register_mode(&"coaster", EntityCatalogProvider.new(&"coaster"), _emit_build_selected)
	# XX claude-wire W3: режим «Монтаж» (ATTN_23 §23.9): категория dc_controller, теги режима в CatalogMeta.MODE_TAGS
	register_mode(&"wiring", EntityCatalogProvider.new(&"wiring"), _emit_build_selected)

	_dup_btn = Button.new()
	_dup_btn.text = "V"   # U15: на кнопке иконка того объекта, который будет повторён, и клавиша
	_dup_btn.custom_minimum_size = Vector2(52, 24)
	_dup_btn.add_theme_constant_override(&"icon_max_width", 18)
	_dup_btn.focus_mode = Control.FOCUS_NONE   # чтобы Пробел и Enter не нажимали кнопку, а клавиши работали в игре
	_dup_btn.disabled = true
	_dup_btn.tooltip_text = "Копия выбранного объекта, а если ничего не выбрано, еще один такой же, как последний построенный (клавиша V)"
	_dup_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_dup_btn.pressed.connect(func() -> void: duplicate_requested.emit())
	_dup_btn.theme_type_variation = &"ButtonSmall"
	_dup_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_view.actions_strip().add_child(_dup_btn)   # ActionsStrip: правая часть хедера

	# Operate: удалить 2D-контроллер (с подтверждением). Активна, пока панель есть (U15)
	_del_dc_btn = Button.new()
	_del_dc_btn.text = "Удалить 2D-контроллер"
	_del_dc_btn.custom_minimum_size = Vector2(0, 24)
	_del_dc_btn.focus_mode = Control.FOCUS_NONE
	_del_dc_btn.disabled = true
	_del_dc_btn.visible = false
	_del_dc_btn.tooltip_text = "Убрать панель управления питанием с экрана. Источник питания и его команды остаются на столе"
	_del_dc_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_del_dc_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_del_dc_btn.theme_type_variation = &"ButtonSmall"
	var dc_host := get_node_or_null("%DCPanelHost") as DCPanelHost
	if dc_host:
		_del_dc_btn.pressed.connect(dc_host.request_remove)
		dc_host.panel_changed.connect(func(has_panel: bool) -> void: _del_dc_btn.disabled = not has_panel)
		_del_dc_btn.disabled = not dc_host.has_panel()
	_view.actions_strip().add_child(_del_dc_btn)

	# XX claude-wire W3: «Монтаж»: плита и пути
	_plate_btn = _make_wiring_toggle("Плита", "Показать или скрыть столешницу. Блоки и провода под ней видны, когда плиты нет")
	_plate_btn.button_pressed = LYM.plate_visible
	_plate_btn.toggled.connect(func(on: bool) -> void: LYM.set_plate_visible(on))
	LYM.plate_visible_changed.connect(func(on: bool) -> void: _plate_btn.set_pressed_no_signal(on))
	_scheme_btn = _make_wiring_toggle("Схема", "Показывать только пути и проводку: поезда, здания, декор, рельеф и вода скрыты")
	_scheme_btn.toggled.connect(_on_scheme_toggled)

	# Ряд фильтров над объектами (первым в теле ToolDock)
	_filter_bar = FilterBar.new()
	_filter_bar.filters_changed.connect(_on_filters_changed)
	var body := _view.objects_box()
	body.add_child(_filter_bar)
	body.move_child(_filter_bar, 0)

	# ToolController к этому моменту может быть не готов, поэтому связываем в конце кадра
	_connect_game.call_deferred()


## Кнопка-переключатель в полосе действий ToolDock, видна только в режиме «Монтаж»
func _make_wiring_toggle(label: String, tip: String) -> Button:
	var b := Button.new()
	b.text = label
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(0, 24)
	b.focus_mode = Control.FOCUS_NONE
	b.visible = false
	b.tooltip_text = tip
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.theme_type_variation = &"ButtonSmall"
	_view.actions_strip().add_child(b)
	return b


func _wiring_view() -> WiringView:
	var tc := get_tree().get_first_node_in_group(&"tool_controller") as ToolController
	return tc.wiring_view if tc != null else null


func _on_scheme_toggled(on: bool) -> void:
	var wv := _wiring_view()
	if wv != null:
		wv.set_paths(WiringView.Paths.SCHEME if on else WiringView.Paths.ALL)


func _emit_build_selected(setting: Resource) -> void:
	object_selected.emit(setting)


## Адаптер режима сообщает: «у меня такой каталог, объект отдавать сюда»
func register_mode(mode: StringName, provider: CatalogProvider, receiver: Callable) -> void:
	_providers[mode] = provider
	provider.on_changed = _on_catalog_changed
	_receivers[mode] = receiver


func _connect_game() -> void:
	var tc := get_tree().get_first_node_in_group(&"tool_controller") as ToolController
	if tc == null:
		push_error("ToolbarController: ToolController не найден (группа tool_controller)")
		return
	object_selected.connect(tc.select_build_object)
	duplicate_requested.connect(tc.duplicate_last_object)
	tc.build_tool.last_changed.connect(on_last_changed)
	tc.selection_changed.connect(_on_selection_for_duplicate)
	tc.build_selection_cleared.connect(object_deselected)


# ==============================================
# Контракт режима (зовет ModeController)
# ==============================================

## Показать панель режима: нижний ряд категорий выезжает
func show_mode_ui(mode: StringName) -> void:
	_mode = mode
	current_cat = &'idle'
	current_tag = &'idle'
	_dup_btn.visible = mode == &"build" or mode == &"coaster"   # дубль имеет смысл в Build и в Coaster (XX claude-coaster C6.1)
	_refresh_dup_btn()
	_del_dc_btn.visible = mode == &"operate"
	# XX claude-wire W3: кнопки «Плита» и «Схема» только в «Монтаже»; состояние берём из игры
	_plate_btn.visible = mode == &"wiring"
	_scheme_btn.visible = mode == &"wiring"
	if mode == &"wiring":
		_plate_btn.set_pressed_no_signal(LYM.plate_visible)
		var wv := _wiring_view()
		_scheme_btn.set_pressed_no_signal(wv == null or wv.paths == WiringView.Paths.SCHEME)
	_view.mode_label().text = _mode_title(mode)
	_rebuild_category_bar()
	_view.show()
	_categories.show()
	_dock.hide()


## Спрятать панель режима
func hide_mode_ui() -> void:
	current_cat = &'idle'
	current_tag = &'idle'
	_categories.hide()
	_dock.hide()
	_view.hide()


## Только для отладки: открыть категорию по номеру кнопки (Global.active_ui_category)
func debug_open_category(index: int) -> void:
	if index < 0 or index >= _category_bar.get_child_count():
		return
	var btn := _category_bar.get_child(index) as CategoryButton
	if btn:
		btn.set_pressed_no_signal(true)   # кнопка выглядит нажатой, как после обычного клика
		btn._on_pressed()


# ==============================================
# Кнопки
# ==============================================

func _rebuild_category_bar() -> void:
	_clear(_category_bar)
	var provider: CatalogProvider = _providers.get(_mode)
	if provider == null:
		return
	for info in provider.get_categories():
		var btn: CategoryButton = _cat_btn_scene.instantiate()
		btn.config(info)
		_style_category_button(btn)
		_category_bar.add_child(btn)
		btn.category_selected.connect(_on_category_selected)


## Название режима в хедере ToolDock
static func _mode_title(mode: StringName) -> String:
	match mode:
		&"build": return "Build"
		&"operate": return "Operate"
		&"observe": return "Observe"
		&"sections": return "Секции"
		&"wiring": return "Монтаж"   # XX claude-wire W3
		&"coaster": return "Coaster"   # XX claude-coaster C1
	return String(mode)


## Кнопка категории 40×40: иконка 24, название в подсказке. Без иконки остаётся короткий текст
func _style_category_button(btn: CategoryButton) -> void:
	btn.custom_minimum_size = Vector2(40, 40)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	if btn.icon != null:
		btn.tooltip_text = btn.text
		btn.text = ""
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.add_theme_constant_override(&"icon_max_width", 24)
	else:
		btn.clip_text = true


## ⚡Сигнал из кнопок категорий
func _on_category_selected(new_cat: StringName) -> void:
	if new_cat == current_cat:
		new_cat = &'idle'   # Кнопка отжата: в идл
		current_tag = &'idle'
	current_cat = new_cat
	_show_category(current_cat)


func _show_category(cat: StringName) -> void:
	if cat == &'idle':
		_dock.hide()
		_view.category_label().text = ""
		_view.refresh_crumbs()
		return
	var provider: CatalogProvider = _providers.get(_mode)
	_clear(_grid)   # У категории без тегов не должно остаться кнопок прежней
	_clear(_tag_panel)
	_view.tag_label().text = ""
	if provider != null:
		var tags := provider.get_tags(cat)
		if tags.is_empty():
			_fill_grid(cat, &"")   # тегов нет (Observe): кнопки категории сразу
		for i in tags.size():
			var btn: TagButton = _tag_btn_scene.instantiate()
			btn.config(tags[i])
			btn.custom_minimum_size = Vector2(40, 0)
			btn.size_flags_vertical = Control.SIZE_FILL   # тег на всю высоту хедера, линия между тегами
			if i > 0:
				var sep := VSeparator.new()
				sep.add_theme_constant_override(&"separation", 1)
				_tag_panel.add_child(sep)
			_tag_panel.add_child(btn)
			btn.tag_selected.connect(_on_tag_selected)
			if i == 0:
				btn.select_as_default()   # первый тег нажат по умолчанию, он же наполнит сетку
	_title.text = str(cat)
	_view.refresh_crumbs()
	_dock.show()


## ⚡Сигнал из кнопок тегов
func _on_tag_selected(new_tag: StringName) -> void:
	current_tag = new_tag
	_view.tag_label().text = _tag_name(new_tag)
	_view.refresh_crumbs()
	if current_cat != &'idle':
		_fill_grid(current_cat, new_tag)


## Название тега в хедере
func _tag_name(tag: StringName) -> String:
	for b in _tag_panel.get_children():
		if b is TagButton and (b as TagButton).tag == tag:
			var n := (b as TagButton).text
			return n if n != "" else (b as TagButton).tooltip_text
	return ""


func _fill_grid(cat: StringName, tag: StringName) -> void:
	_clear(_grid)
	var provider: CatalogProvider = _providers.get(_mode)
	if provider == null:
		return
	var receiver: Callable = _receivers.get(_mode, Callable())
	var values: Dictionary = _filters.get(_filter_key(), {})
	_filter_bar.setup(provider.get_filters(cat, tag), values)
	var buttons := provider.create_buttons(cat, tag, receiver, values)
	for btn in buttons:
		_grid.add_child(btn)
	_filter_bar.set_empty(buttons.is_empty() and not values.is_empty())
	_view.count_label().text = "Объектов: %d" % buttons.size() if not buttons.is_empty() else ""
	_view.refresh_crumbs()
	_view.empty_label().visible = buttons.is_empty() and values.is_empty()


func _filter_key() -> String:
	return "%s/%s" % [_mode, current_cat]


## Данные каталога изменились (переименован или удалён состав): перестраиваем сетку.
## Если текущего тега больше нет, заново открываем категорию
func _on_catalog_changed() -> void:
	if current_cat == &'idle':
		return
	var provider: CatalogProvider = _providers.get(_mode)
	if provider == null:
		return
	for tag in provider.get_tags(current_cat):
		if tag["id"] == current_tag:
			_fill_grid(current_cat, current_tag)
			return
	_show_category(current_cat)


## ⚡Сигнал из FilterBar: фильтры изменились, пересобираем сетку (фильтры общие для тегов категории)
func _on_filters_changed(values: Dictionary) -> void:
	_filters[_filter_key()] = values
	_fill_grid(current_cat, current_tag)


## Снимает нажатие с кнопок объектов (ПКМ в Build, выход из инструмента стройки)
func object_deselected() -> void:
	for btn in _grid.get_children():
		if btn is ObjectButton:   # карточки Observe не трогаем
			btn.button_pressed = false


## ⚡Сигнал BuildTool.last_changed: появился или сменился последний поставленный объект
func on_last_changed(setting: EntitySetting) -> void:
	_dup_has_last = setting != null
	_dup_last_setting = setting
	_dup_last_name = setting.name if setting != null else ""
	_dup_last_icon = setting.icon if setting != null else null
	_refresh_dup_btn()


## ⚡Сигнал ToolController.selection_changed: выбран объект или выбор снят. Выбранный (не призрак) дублируется по кнопке и V
func _on_selection_for_duplicate(entity: Entity) -> void:
	_dup_sel_name = ""
	_dup_sel_icon = null
	_dup_sel_setting = null
	if entity != null and is_instance_valid(entity) and not entity.has_comp(C_Ghost):
		var idc := entity.get_comp(C_Identity) as C_Identity
		if idc != null and idc.setting != null:
			_dup_sel_name = idc.get_name_e()
			_dup_sel_icon = idc.setting.icon
			_dup_sel_setting = idc.setting
	_refresh_dup_btn()


func _refresh_dup_btn() -> void:
	# XX claude-coaster C6.1: учитываем режим: в Coaster копируются объекты горок, в Build остальные
	var sel_ok := _dup_sel_name != "" and ToolController.duplicate_fits_mode(_dup_sel_setting, _mode)
	var last_ok := _dup_has_last and ToolController.duplicate_fits_mode(_dup_last_setting, _mode)
	_dup_btn.disabled = not sel_ok and not last_ok
	# Иконка того, что повторится: выбранный объект, иначе последний поставленный
	_dup_btn.icon = _dup_sel_icon if sel_ok else (_dup_last_icon if last_ok else null)
	if sel_ok:
		_dup_btn.tooltip_text = "Копия выбранного: %s (клавиша V)" % _dup_sel_name
	elif last_ok:
		_dup_btn.tooltip_text = "Еще один: %s (клавиша V)" % _dup_last_name


static func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
