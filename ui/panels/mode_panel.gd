extends Container

######################
## 	ModePanel   Панель выбора режима игры
######################

## 💡 тупой слой, реагирует на события, 📌 не содержит логики, ❗только отправляет сигнал

##⚡
signal mode_selected(mode) # Сигнал в ModeController


## Нажали кнопку 

func _on_build_button_pressed() -> void:
	mode_selected.emit(&'build') ##⚡Сигнал в ModeController


func _on_operate_button_pressed() -> void:
	mode_selected.emit(&'operate') ##⚡Сигнал в ModeController


func _on_observe_button_pressed() -> void:
	mode_selected.emit(&'observe') ##⚡Сигнал в ModeController


func _on_sections_button_pressed() -> void:
	mode_selected.emit(&'sections') ##⚡Сигнал в ModeController (XX claude-table T1b)


func _on_coaster_button_pressed() -> void:
	mode_selected.emit(&'coaster') ##⚡Сигнал в ModeController (XX claude-coaster C1)


func _on_library_button_pressed() -> void:
	mode_selected.emit(&'library') ##⚡Сигнал в ModeController
