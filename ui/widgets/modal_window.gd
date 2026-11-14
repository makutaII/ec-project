class_name ModalWindow extends Control

# U10 (ATTN_17 §17.3.4): новый файл
## Модальное окно: затемнение (блокирует мышь), заголовок, Esc закрывает верхнее окно стека.
## Сцена наследника содержит узлы Dim, Title и Content (см. confirm_dialog.tscn). Окна лежат
## в слое Windows (layer 20). Пока окно открыто, инструменты и камера клавиши не читают (UIPointer.modal_open).
## Наследник: переопределяет _opened() (подготовка) и _on_cancel() (что значит Esc).

## ⚡ Окно закрыто (любым способом)
signal closed

@onready var _title_label: Label = %Title


func _exit_tree() -> void:
	WindowStack.remove(self)


## Открыть. Пустой заголовок оставляет прежний
func open(title_text: String = "") -> void:
	if title_text != "":
		_title_label.text = title_text
	visible = true
	if get_parent() != null:
		get_parent().move_child(self, -1)   # поверх остальных окон слоя (вопрос поверх списка)
	WindowStack.push(self)
	_opened()


func close() -> void:
	if not visible:
		return
	visible = false
	WindowStack.remove(self)
	closed.emit()


## Переопределить: подготовка после открытия
func _opened() -> void:
	pass


## Переопределить: Esc. По умолчанию закрывает
func _on_cancel() -> void:
	close()


func _input(event: InputEvent) -> void:
	if not visible or WindowStack.top() != self:
		return
	if Actions.pressed(event, &"cancel"):
		get_viewport().set_input_as_handled()
		_on_cancel()
