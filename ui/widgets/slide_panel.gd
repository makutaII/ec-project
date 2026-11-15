class_name SlidePanel extends Control

# U12 (ATTN_17 §17.3.4): новый файл
## Выдвижная панель с язычком. Сцена: корень (этот скрипт), `%Body` (панель шириной custom_minimum_size.x),
## `%Tab` (кнопка справа от тела). Закрытая панель уходит влево, язычок остаётся у края экрана.
## Автозакрытие (U7a, A4): таймер AUTOHIDE_SEC запускается кликом вне панели или действием внутри
## (note_action), каждое новое действие начинает отсчёт заново, пока курсор над панелью или в ней фокус
## клавиатуры, отсчёт стоит. Открыли и ничего не трогали: панель остаётся. Закреплённая (pinned) не закрывается.

## ⚡ Панель выдвинута
signal opened
## ⚡ Панель убрана
signal closed

## SIDEDOCK_AUTOHIDE_SEC из плана
const AUTOHIDE_SEC := 5.0
const SLIDE_TIME := 0.18

var is_open := false
## Закреплённая панель сама не закрывается
var pinned := false:
	set(v):
		pinned = v
		_remaining = -1.0

@onready var _body: Control = %Body
@onready var _tab: Button = %Tab

var _remaining := -1.0
var _tween: Tween


func _ready() -> void:
	_tab.pressed.connect(toggle)
	position.x = -_body.custom_minimum_size.x
	_tab.text = ">"


func open() -> void:
	if is_open:
		return
	is_open = true
	_remaining = -1.0
	_slide_to(0.0)
	_tab.text = "<"
	opened.emit()


func close() -> void:
	if not is_open:
		return
	is_open = false
	_remaining = -1.0
	_slide_to(-_body.custom_minimum_size.x)
	_tab.text = ">"
	closed.emit()


func toggle() -> void:
	if is_open:
		close()
	else:
		open()


## Игрок что-то выбрал внутри панели: (пере)запустить отсчёт автозакрытия.
## Кнопки и переключатели отдают фокус, иначе «фокус внутри» держал бы панель открытой вечно
func note_action() -> void:
	if not is_open or pinned:
		return
	var f := get_viewport().gui_get_focus_owner()
	if f != null and _body.is_ancestor_of(f) and not (f is LineEdit or f is SpinBox or f is TextEdit):
		f.release_focus()
	_remaining = AUTOHIDE_SEC


func _slide_to(x: float) -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "position:x", x, SLIDE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _input(event: InputEvent) -> void:
	if not is_open or pinned:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if _body.get_global_rect().has_point(mb.global_position) or _tab.get_global_rect().has_point(mb.global_position):
		return
	_remaining = AUTOHIDE_SEC   # клик вне панели (в том числе по сцене)


func _process(delta: float) -> void:
	if not is_open or pinned or _remaining < 0.0:
		return
	if _body.get_global_rect().has_point(get_global_mouse_position()):
		return   # курсор над панелью: отсчёт стоит
	var f := get_viewport().gui_get_focus_owner()
	if f != null and _body.is_ancestor_of(f):
		return   # фокус клавиатуры внутри
	_remaining -= delta
	if _remaining <= 0.0:
		close()
