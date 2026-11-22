class_name InfoSection extends RefCounted

# U13 (ATTN_17 D13): новый файл
## Декларативная секция для вкладки Visual в InfoPanel. Компонент реализует
##   func get_info_sections() -> Array[InfoSection]
## и описывает свои строки данными; панель рисует их, не зная про конкретные компоненты.
## Это только данные (без UI), поэтому лежит в core/.
## Строки это словари, их делают статические помощники ниже. Значения «живые»: вместо строки,
## числа или bool можно передать Callable без аргументов, панель вызывает его 10 раз в секунду.
##   label(title, value)                     подпись и значение (String или Callable -> String)
##   toggle(title, getter, setter)           переключатель: getter -> bool, setter(bool)
##   button(text, action)                    кнопка: action()
##   slider(title, min, max, step, getter, setter)   ползунок: getter -> float, setter(float)
##   list(title, ids, titles, getter, setter)        выбор: getter -> id, setter(id)
##   note(text, kind)                        оперативное сообщение: идёт в подвал вкладки, а не в тело (U5a);
##                                           text: String или Callable -> String (пустая строка убирает), kind: info, ok, warn, bad

var title := ""
var rows: Array[Dictionary] = []


static func make(p_title: String, p_rows: Array) -> InfoSection:
	var s := InfoSection.new()
	s.title = p_title
	for r in p_rows:
		s.rows.append(r)
	return s


static func label(p_title: String, value: Variant) -> Dictionary:
	return {"type": &"label", "title": p_title, "value": value}


static func toggle(p_title: String, getter: Callable, setter: Callable) -> Dictionary:
	return {"type": &"toggle", "title": p_title, "getter": getter, "setter": setter}


static func button(p_text: String, action: Callable) -> Dictionary:
	return {"type": &"button", "title": p_text, "action": action}


static func note(p_text: Variant, p_kind: StringName = &"info") -> Dictionary:
	return {"type": &"note", "text": p_text, "kind": p_kind}


static func slider(p_title: String, min_value: float, max_value: float, step: float, getter: Callable, setter: Callable) -> Dictionary:
	return {"type": &"slider", "title": p_title, "min": min_value, "max": max_value, "step": step, "getter": getter, "setter": setter}


static func list(p_title: String, ids: Array, titles: Array, getter: Callable, setter: Callable) -> Dictionary:
	return {"type": &"list", "title": p_title, "ids": ids, "titles": titles, "getter": getter, "setter": setter}
