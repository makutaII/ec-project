class_name CardCatalogProvider extends CatalogProvider

###########################
## CardCatalogProvider. Карточки режима Observe (пресеты, время суток, камеры, фото, погода)
###########################
## Вместо отрисовки в ObserveController. Данные карточек (CARDS) и состояние радио-групп и переключателей
## живут здесь: состояние переживает пересборку категории (кнопки создаются заново при каждом показе).
## Нажатие карточки уходит приемнику режима: on_pressed.call(category, id, pressed).
## Тегов у Observe нет, кнопки категории строятся сразу.
## TODO S3: источник правды станет GraphicsManager.state

## Категории (нижний ряд). TODO иконки
const CATEGORIES := [
	{"id": &"look", "name": "Look", "icon": null},
	{"id": &"light", "name": "Light", "icon": null},
	{"id": &"camera", "name": "Camera", "icon": null},
	{"id": &"photo", "name": "Photo", "icon": null},
	{"id": &"weather", "name": "Weather", "icon": null},
]

## Карточки по категориям. group: радио-группа, toggle: переключатель, без них: разовое действие.
## Большинство пока заглушки, рабочими их делают шаги S3-S9.
const CARDS := {
	&"look": [
		{"id": &"toy", "title": "Toy", "group": &"look", "default": true},
		{"id": &"workshop", "title": "Workshop", "group": &"look"},
		{"id": &"clean", "title": "Clean", "group": &"look"},
		{"id": &"low", "title": "Low", "group": &"quality"},
		{"id": &"medium", "title": "Medium", "group": &"quality", "default": true},
		{"id": &"high", "title": "High", "group": &"quality"},
		# Только debug (см. _cards_for): чистый дефолт Godot для корректора графики (GfxLab, ATTN_14 §14.16)
		{"id": &"lab", "title": "Lab", "tip": "Корректор графики: сброс всего к дефолту Godot: Look, Time, Quality, свет, камера (без позиции и зума). Дальше правки в Remote или во вкладке Lab (F3). Любая другая карточка Look, Time или Quality возвращает игру"},
	],
	&"light": [
		{"id": &"morning", "title": "Утро", "group": &"time"},
		{"id": &"day", "title": "День", "group": &"time", "default": true},
		{"id": &"evening", "title": "Вечер", "group": &"time"},
		{"id": &"night", "title": "Ночь", "group": &"time"},
		{"id": &"lamp", "title": "Лампа", "toggle": true},
	],
	&"camera": [
		{"id": &"bookmark_1", "title": "1", "tip": "Закладка 1: перейти, пустая: сохранить. Shift: перезаписать (клавиши 1-5, Ctrl+1-5)"},
		{"id": &"bookmark_2", "title": "2", "tip": "Закладка 2: перейти, пустая: сохранить. Shift: перезаписать"},
		{"id": &"bookmark_3", "title": "3", "tip": "Закладка 3: перейти, пустая: сохранить. Shift: перезаписать"},
		{"id": &"bookmark_4", "title": "4", "tip": "Закладка 4: перейти, пустая: сохранить. Shift: перезаписать"},
		{"id": &"bookmark_5", "title": "5", "tip": "Закладка 5: перейти, пустая: сохранить. Shift: перезаписать"},
		{"id": &"follow", "title": "Follow", "toggle": true, "tip": "Камера вагона. Сначала кликните по вагону. Esc: выйти"},
		{"id": &"pov", "title": "POV", "toggle": true, "tip": "Вид из вагона. Сначала кликните по вагону. Esc: выйти"},
		{"id": &"pov_flip", "title": "POV ↔", "toggle": true, "tip": "Развернуть POV-камеру в другую сторону"},
		{"id": &"orbit", "title": "Orbit", "toggle": true, "tip": "Автокамера вокруг стола. Esc: выйти"},
	],
	&"photo": [
		{"id": &"hide_ui", "title": "Скрыть UI", "toggle": true, "tip": "Клавиша H. Esc: вернуть UI"},
		{"id": &"snapshot", "title": "Снять", "tip": "Клавиша P. Снимок без UI на качестве High: user://screenshots/"},
	],
	&"weather": [
		{"id": &"soon", "title": "Weather", "locked": true},
	],
}

## Префикс id карточек света комнаты в категории light: «room:<id управления>» (ATTN_25 §25.4, RM6)
const ROOM_CARD_PREFIX := "room:"

## Источник карточек света комнаты: Callable без аргументов -> Array[Dictionary] (см. room_cards). Задаёт ObserveController.
## Пусто или пустой ответ: в Light только карточки из CARDS. Спрашивается при каждом показе категории, поэтому смена комнаты подхватывается
var room_cards_source: Callable = Callable()

var _groups := {}         # имя группы -> ButtonGroup (пересоздаются при каждом показе категории)
var _group_state := {}    # группа -> id выбранной карточки
var _toggle_state := {}   # id -> bool
var _cards: Array = []    # созданные сейчас карточки (могут быть уже освобождены, см. is_instance_valid)


## В режиме быстрой загрузки (--fast) Observe недоступен: категорий нет
func get_categories() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if Global.fast_debug:
		return out
	for c in CATEGORIES:
		out.append(c)
	return out


func create_buttons(category: StringName, _tag: StringName, on_pressed: Callable, _filters: Dictionary = {}) -> Array[Button]:
	var out: Array[Button] = []
	_groups.clear()
	_cards.clear()
	for data in _cards_for(category):
		var card := ObserveCard.new()
		card.config(category, data, _group_for(data))
		if card.toggle_mode:
			card.set_pressed_no_signal(_is_on(data))
		card.card_pressed.connect(_on_card_pressed.bind(on_pressed))
		_cards.append(card)
		out.append(card)
	return out


func _group_for(data: Dictionary) -> ButtonGroup:
	var g: StringName = data.get("group", &"")
	if g == &"":
		return null
	if not _groups.has(g):
		_groups[g] = ButtonGroup.new()
	return _groups[g]


## ⚡Сигнал из карточки: запоминаем состояние и отдаем приемнику
func _on_card_pressed(category: StringName, id: StringName, pressed: bool, on_pressed: Callable) -> void:
	var data := _card_data(category, id)
	var g: StringName = data.get("group", &"")
	if g != &"":
		if pressed:
			_group_state[g] = id
	elif data.get("toggle", false):
		_toggle_state[id] = pressed
	if on_pressed.is_valid():
		on_pressed.call(category, id, pressed)


## Программная смена выбранной карточки группы (GFX при смене Look/Time из кода). Сигнал карточки не шлется
func set_group_state(group: StringName, id: StringName) -> void:
	_group_state[group] = id
	var g: ButtonGroup = _groups.get(group)
	if g == null:
		return
	for b in g.get_buttons():
		if b is ObserveCard:
			b.set_pressed_no_signal(b.id == id)


## То же для переключателя
func set_toggle_state(id: StringName, on: bool) -> void:
	_toggle_state[id] = on
	for c in _cards:
		if is_instance_valid(c) and c.id == id and c.toggle_mode:
			c.set_pressed_no_signal(on)


## Карточки света комнаты из реестра: управления со scope = observe, по переключателю на каждое (TOGGLE, SLIDER и MECH).
## Статическая, чтобы проверять без сцены (tests/room_light_test.tscn)
static func room_cards(controls: RoomControlRegistry) -> Array:
	var out: Array = []
	if controls == null:
		return out
	for d in controls.for_scope(RoomControl.Scope.OBSERVE):
		var tip := "Механизм комнаты: открыть и закрыть" if d.kind == RoomControl.Kind.MECH else "Свет комнаты"
		out.append({"id": StringName(ROOM_CARD_PREFIX + String(d.id)), "title": d.display_title(), "toggle": true,
				"on": d.is_on(), "tip": tip})
	return out


## id управления комнаты из id карточки; пусто, если карточка не комнатная
static func room_control_id(card_id: StringName) -> StringName:
	var s := String(card_id)
	return StringName(s.trim_prefix(ROOM_CARD_PREFIX)) if s.begins_with(ROOM_CARD_PREFIX) else &""


## Нажата ли карточка при показе: из сохраненного состояния, иначе по "default"
func _is_on(data: Dictionary) -> bool:
	if data.has("on"):
		return bool(data["on"])   # карточка комнаты: состояние живёт в реестре комнаты, а не здесь
	var g: StringName = data.get("group", &"")
	if g != &"":
		if _group_state.has(g):
			return _group_state[g] == data.id
		return data.get("default", false)
	if data.get("toggle", false):
		return _toggle_state.get(data.id, data.get("default", false))
	return false


## Карточки категории. Lab видна только админу (debug). Комната в Observe не меняется (ATTN_25 §25.4)
func _cards_for(category: StringName) -> Array:
	var base: Array = CARDS.get(category, [])
	if category == &"look" and not Global.debug_mode:
		return base.filter(func(d: Dictionary) -> bool: return d.id != &"lab")
	if category == &"light" and room_cards_source.is_valid():
		var extra: Array = room_cards_source.call()
		if not extra.is_empty():
			var all: Array = base.duplicate()
			all.append_array(extra)
			return all
	return base


func _card_data(category: StringName, id: StringName) -> Dictionary:
	for d in _cards_for(category):
		if d.id == id:
			return d
	return {}
