class_name ToolSettings extends RefCounted

# XX claude-terra 13.14 H2d (новый файл)
###########################
## Настройки инструмента в InfoPanel (вкладка «Инструмент»). Универсальный контракт: любой инструмент (кисть, и позже другие),
## пока он активен, показывает игроку свои настройки в панели рядом с обычными вкладками сущностей.
##
## Как подключить инструмент (дак-тайпинг, базовый класс не нужен):
##   func settings_title() -> String                       заголовок вкладки (живой: перечитывается раз в 0,1 с)
##   func get_info_sections() -> Array[InfoSection]        секции и строки: slider, list, toggle, button, label, note (note идёт в подвал,
##                                                          там удобно держать клавиши инструмента)
##   func settings_version() -> int                         необязательно: смена значения перестраивает строки (список вариантов изменился)
## В enter() инструмента: controller.publish_tool_settings(self), в exit(): controller.clear_tool_settings(self).
## Значения строк читаются getter-ами каждые 0,1 с, поэтому горячие клавиши инструмента и слайдеры остаются синхронными.
## Панель показывает вкладку, только когда выбранной сущности нет (инструмент и сущность панель делят: выбор сущности важнее).
###########################


## Подходит ли объект как поставщик настроек (есть оба обязательных метода)
static func is_provider(o: Object) -> bool:
	return o != null and is_instance_valid(o) and o.has_method(&"settings_title") and o.has_method(&"get_info_sections")


## Версия набора строк (0, если инструмент её не ведёт)
static func version_of(o: Object) -> int:
	return int(o.call(&"settings_version")) if o != null and o.has_method(&"settings_version") else 0
