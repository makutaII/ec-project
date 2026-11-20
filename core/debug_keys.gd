class_name DebugKeys extends RefCounted

###########################
## Перечень отладочных клавиш (ATTN_17 U6.2)
###########################
## Одно место, где описано, какие клавиши работают при Global.debug_mode. Саму клавишу хранит реестр Actions
## (переназначается там же), здесь только действие, подпись на случай, если его нет в InputMap, и описание.
## Вкладка Keys панели F3 строится из этого списка. Новая отладочная клавиша: действие в Actions и строка здесь.
##
## action: действие реестра; label: подпись, если действия нет в InputMap; text: что делает (отладка, без перевода);
## press: у строки есть кнопка «Нажать» (шлёт действие в игру, удобно, когда клавишу занимает система)
const LIST: Array[Dictionary] = [
	{"action": &"debug_panel_toggle", "label": "F3", "text": "Эта панель", "press": false},
	{"action": &"debug_stats_toggle", "label": "F4", "press": true,
		"text": "Оверлей статистики в углу: fps, draw calls, треугольники (все проходы кадра), траки и вагоны, условия прогона"},
	{"action": &"debug_terrain_probe", "label": "F7", "press": false,
		"text": "Печатает surface_y под курсором. С выбранным листом террейна: ниша; Shift: окно; Alt: тоннель; Ctrl: убрать последний вырез"},
	{"action": &"debug_field_toggle", "label": "Ctrl+Shift+F", "press": true,
		"text": "Поле высот (13.14 H1): положить слой шпатлёвки на весь стол или снять всё поле"},
	{"action": &"debug_vsync_toggle", "label": "Ctrl+Shift+V", "press": true,
		"text": "V-Sync вкл/выкл. Раньше был F8, но в редакторе Godot это «Остановить игру»"},
	{"action": &"debug_load_reference", "label": "F9", "press": true, "text": "Загрузить эталонную диораму (заменяет макет)"},
	{"action": &"debug_save_look", "label": "F10", "press": true, "text": "Сохранить встроенные Look и Time в .tres"},
	{"action": &"debug_look_lab", "label": "Ctrl+Shift+L", "press": true,
		"text": "Look Lab, качество High: прогон вариантов Clean + Day по закладкам 1-5, снимки и метрики в user://look_lab/ (лучше в Observe, во время прогона ничего не трогать)"},
	{"action": &"debug_look_lab_medium", "label": "Ctrl+Shift+M", "press": true,
		"text": "Look Lab, качество Medium (те же варианты, для сравнения fps и времени кадра)"},
	{"action": &"debug_look_lab_low", "label": "Ctrl+Shift+K", "press": true, "text": "Look Lab, качество Low"},
	{"action": &"debug_look_matrix", "label": "Ctrl+Shift+N", "press": true,
		"text": "Look Lab, матрица: все Look × все Time на текущих настройках, качество High (L4)"},
	{"action": &"debug_look_matrix_medium", "label": "Ctrl+Shift+B", "press": true, "text": "Look Lab, матрица на Medium"},
	{"action": &"debug_look_matrix_low", "label": "Ctrl+Shift+J", "press": true, "text": "Look Lab, матрица на Low"},
	{"action": &"lights_toggle", "label": "I", "press": false, "text": "У выбранного вагона: свет вкл/выкл"},
	{"action": &"mechanisms_gizmos", "label": "Shift+I", "press": false,
		"text": "У выбранного вагона: метки источников и размеры кузова в Output"},
	{"action": &"mechanisms_toggle", "label": "O", "press": false, "text": "У выбранного вагона: переключить все механизмы"},
	{"action": &"flex_limits_toggle", "label": "L", "press": false, "text": "Лимиты flex (в Build)"},
	{"action": &"flex_zones_toggle", "label": "Z", "press": false, "text": "Зоны проблем flex"},
]


## Подпись клавиши строки: из реестра, а если действия нет, запасная
static func key_label(entry: Dictionary) -> String:
	var t: String = Actions.key_text(entry.action)
	return t if t != "" else String(entry.label)
