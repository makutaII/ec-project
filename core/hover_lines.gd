class_name HoverLines extends RefCounted

# U5a.5 (ATTN_17): новый файл
## Контракт строк характеристик объекта. Компонент реализует
##   func get_hover_lines() -> Array
## и отдает строки данными: HoverLines.line(text, kind). Строки идут в подсказку при наведении (InfoTips, не больше
## InfoTips.HOVER_MAX_LINES) и целиком во вкладку «Подсказки» в InfoPanel, поэтому в них только короткие факты
## (положение, контур, слои), без клавиш и без описания. Это только данные (без UI), поэтому лежит в core/.
## kind: info (обычная), dim (приглушенная), ok, warn, bad. Значения живые: метод зовут каждый кадр подсказки и 10 раз в секунду панель.

static func line(text: String, kind: StringName = &"info") -> Dictionary:
	return {"text": text, "kind": kind}


## Строки всех компонентов сущности, у которых есть get_hover_lines()
static func collect(entity: Entity) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if entity == null or not is_instance_valid(entity):
		return out
	for child in entity.get_children():
		if child is Component and child.has_method(&"get_hover_lines"):
			var comp: Variant = child   # метод есть не у всех компонентов: вызываем без статической проверки
			for l in comp.get_hover_lines():
				out.append(l)
	return out
