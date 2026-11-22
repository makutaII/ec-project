class_name InfoTab extends RefCounted

###########################
## InfoTab. Базовый класс вкладки InfoPanel (U5)
###########################
## Вкладка получает цель (bind), решает, показываться ли ей у этой цели (can_show), и обновляет свои значения
## в refresh(): InfoPanel зовет его 10 раз в секунду и только у активной вкладки.
## Вкладки сцены (Сведения, Питание, Вид) находят свои узлы по имени (_n), код-вкладки (Механизмы,
## Материал, Стрелка) создают контролы сами (make_page).
## У каждой вкладки внизу свой подвал (U5a): оперативные сообщения и действия, см. footer_message и footer_add_action.

var panel: InfoPanel
## Контрол вкладки в TabContainer
var control: Control
## Выбранная сущность, null пока вкладка не привязана
var target: Entity
## Вкладка-хозяин, если эта вкладка встроена блоком в другую (U5a.3): её подвал общий с хозяином
var host: InfoTab

## Типы сообщений подвала и вариации темы для них (цвета задаёт тема, в коде их нет)
const FOOTER_VARIATIONS := {&"info": &"LabelDim", &"ok": &"LampOn", &"warn": &"LampWarn", &"bad": &"LampBad"}

var _footer: Control
var _footer_actions: HFlowContainer
var _footer_messages: VBoxContainer
## Сообщения подвала: ключ -> Label
var _footer_labels: Dictionary = {}


## Зовет InfoPanel один раз. control_in_scene: готовая вкладка из info_panel.tscn или null для код-вкладки
func setup(p: InfoPanel, control_in_scene: Control = null) -> void:
	panel = p
	control = control_in_scene
	_setup()
	_build_footer()
	_setup_footer()


## Встраивает вкладку блоком в другую вкладку: интерфейс строится в контейнере хозяина (add_block),
## сообщения и действия идут в подвал хозяина. Хозяин сам зовёт bind, unbind, refresh и can_show блока
func embed(p: InfoPanel, host_tab: InfoTab) -> void:
	panel = p
	host = host_tab
	_setup()
	_setup_footer()


## Для хозяина блоков: создаёт контейнер под новый блок. Базовая вкладка блоков не держит
func add_block() -> VBoxContainer:
	return null


## Показывать ли вкладку у этой сущности. Определяется компонентами цели, а не номером вкладки
func can_show(_entity: Entity) -> bool:
	return true


func bind(entity: Entity) -> void:
	target = entity
	_on_bind()


func unbind() -> void:
	target = null
	_on_unbind()
	if host == null:
		footer_clear()   # сообщения относились к прежней цели (у блока их снимает хозяин)


## Периодическое обновление живых значений (10 Гц, только активная вкладка). Команд не шлет
func refresh() -> void:
	pass


## У цели добавили или убрали компонент
func components_changed() -> void:
	pass


# --- для наследников ---

func _setup() -> void:
	pass


## Подвал уже построен: здесь вкладка добавляет свои кнопки действий (footer_add_action)
func _setup_footer() -> void:
	pass


func _on_bind() -> void:
	pass


func _on_unbind() -> void:
	pass


## Узел панели по имени (узлы info_panel.tscn с unique_name_in_owner и без)
func _n(node_name: String) -> Variant:
	return panel.find_child(node_name, true, false)


## Создает код-вкладку: страницу в TabContainer с отступами. Возвращает контейнер для содержимого
func make_page(title: String) -> VBoxContainer:
	if host != null:   # блок внутри другой вкладки: свой контейнер у хозяина, без отступов и подвала
		var block := host.add_block()
		control = block
		return block
	var page := VBoxContainer.new()
	page.name = title
	panel.tab_container.add_child(page)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	page.add_child(margin)
	var box := VBoxContainer.new()
	margin.add_child(box)
	control = page
	return box


# --- подвал вкладки ---

## Строит подвал внизу страницы: распорка прижимает его ко дну, пустой подвал скрыт
func _build_footer() -> void:
	if control == null:
		return
	var spacer := Control.new()
	spacer.name = "FooterSpacer"
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	control.add_child(spacer)
	_footer = VBoxContainer.new()
	_footer.name = "TabFooter"
	_footer.visible = false
	control.add_child(_footer)
	_footer.add_child(HSeparator.new())
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	_footer.add_child(margin)
	var box := VBoxContainer.new()
	margin.add_child(box)
	_footer_actions = HFlowContainer.new()
	box.add_child(_footer_actions)
	_footer_messages = VBoxContainer.new()
	box.add_child(_footer_messages)


## Сообщение в подвале по ключу: тот же ключ обновляет строку, пустой текст убирает её.
## kind: info, ok, warn, bad (цвет из темы). Сообщения снимаются при смене цели
func footer_message(key: StringName, text: String, kind: StringName = &"info") -> void:
	if host != null:
		host.footer_message(key, text, kind)
		return
	if _footer_messages == null:
		return
	var label := _footer_labels.get(key) as Label
	if text.is_empty():
		if label != null:
			_footer_labels.erase(key)
			_footer_messages.remove_child(label)
			label.queue_free()
		refresh_footer()
		return
	if label == null:
		label = Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_footer_messages.add_child(label)
		_footer_labels[key] = label
	label.text = text
	var variation: StringName = FOOTER_VARIATIONS.get(kind, &"LabelDim")
	if label.theme_type_variation != variation:
		label.theme_type_variation = variation
	refresh_footer()


## Кнопка или другой контрол действия вкладки: ставится в ряд подвала, подвал виден, пока виден хоть один
func footer_add_action(action: Control) -> void:
	if host != null:
		host.footer_add_action(action)
		return
	if _footer_actions == null:
		return
	_footer_actions.add_child(action)
	refresh_footer()


## Убирает все сообщения подвала (действия остаются)
func footer_clear() -> void:
	if host != null:
		host.footer_clear()
		return
	for label in _footer_labels.values():
		if is_instance_valid(label):
			_footer_messages.remove_child(label)
			label.queue_free()
	_footer_labels.clear()
	refresh_footer()


## Показывает подвал, если в нём есть сообщение или видимое действие. Зовут сами footer_*,
## вкладка зовёт, когда сама меняет видимость своей кнопки действия
func refresh_footer() -> void:
	if host != null:
		host.refresh_footer()
		return
	if _footer == null:
		return
	var has := not _footer_labels.is_empty()
	if not has:
		for c in _footer_actions.get_children():
			if c is Control and (c as Control).visible:
				has = true
				break
	_footer.visible = has


## Пишет значение в SpinBox без сигнала и не мешает вводу (поле в фокусе не трогаем)
static func set_spin(spin: SpinBox, value: float) -> void:
	if spin.get_line_edit().has_focus():
		return
	spin.set_value_no_signal(value)
