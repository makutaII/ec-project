class_name CatalogMeta extends RefCounted

###########################
## 📚 CatalogMeta. Метаданные каталога объектов
###########################
## Что не лежит в самих объектах: какие категории есть у режима, в каком порядке идут категории и теги,
## иконки и подписи категорий, какие фильтры (facets) показывать в категории.
## Заменяет словари category_list в контроллерах Build и Operate.
##
## Сделано константами в скрипте, а не .tres: правится текстом, не ломается без редактора. Когда понадобится
## править в инспекторе (U18, Icon Studio), переедет в Resource с теми же полями.
##
## Подписи (`name`) пока обычные строки. После шага локализации (U10) вместо них tr("cat.<id>") и tr("tag.<id>").
## Иконка тега и категории, которой тут нет, берется у первого объекта (как было до U3a).

## Категории по режимам, в порядке показа кнопок
const MODE_CATEGORIES := {
	&"build": [&"train", &"track", &"building", &"decor", &"terrain"],
	&"operate": [&"dc_controller", &"dcc_controller"],
}

const CATEGORIES := {
	&"train": {"name": "Trains", "icon": preload("res://ui/icons/transport/steam-locomotive.svg")},
	&"track": {"name": "Tracks", "icon": preload("res://ui/icons/transport/railway.svg")},
	&"building": {"name": "Building", "icon": preload("res://ui/icons/house/house.svg")},
	&"decor": {"name": "Decor", "icon": preload("res://ui/icons/house/beech.svg")},
	&"terrain": {"name": "Terrain", "icon": preload("res://ui/icons/tool/spade.svg")},
	&"dc_controller": {"name": "DC Controllers", "icon": preload("res://ui/icons/settings-knobs.svg")},
	&"dcc_controller": {"name": "DCC Controllers", "icon": preload("res://ui/icons/transport/steam-locomotive.svg")},
}

## Порядок тегов внутри категории. Теги, которых тут нет, идут после этих в порядке появления.
## "name" и "icon" необязательны: без них подпись это id тега, иконка у первого объекта
const TAGS := {
	&"train": [&"loco", &"boxcar"],
	&"track": [&"straight", &"curve", &"switch", &"flex", &"crossing", &"buffer", &"rulette"],
	&"building": [&"house"],
	&"terrain": [&"foam", &"cut"],
	&"dc_controller": [&"2d", &"3d"],
}

## Подписи и иконки тегов (необязательно): {category: {tag: {"name": String, "icon": Texture2D}}}.
## Пока пусто: подпись это id тега, иконка у первого объекта тега. Заполнять по мере появления иконок (U18)
const TAG_META := {}

## Фильтры категории: какие признаки (facets) объектов показывать и с какими значениями.
## Интерфейс фильтров делается в U3b, данные нужны уже сейчас для lint и выбора рамкой.
const FACET_SPECS := {
	&"track": [
		{"id": &"ballast", "title": "Балласт", "options": ["yes", "no"], "labels": {"yes": "с балластом", "no": "без балласта"}},
		{"id": &"sleeper", "title": "Шпалы", "options": ["wood", "concrete"], "labels": {"wood": "дерево", "concrete": "бетон"}},
	],
}

## Признаки, допустимые у объекта, но не показываемые фильтрами (нужны для выбора рамкой и сводки на кнопке)
const EXTRA_FACETS := [&"shape"]


## Данные категории для кнопки: {"id", "name", "icon"}. Неизвестная категория получает имя по id
static func category_info(cat: StringName) -> Dictionary:
	var meta: Dictionary = CATEGORIES.get(cat, {})
	return {"id": cat, "name": meta.get("name", str(cat)), "icon": meta.get("icon", null)}


## Данные тега из TAG_META, пустой словарь если не задано
static func tag_info(cat: StringName, tag: StringName) -> Dictionary:
	var by_cat: Dictionary = TAG_META.get(cat, {})
	return by_cat.get(tag, {})


## Категории режима в порядке показа
static func categories_for_mode(mode: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for c in MODE_CATEGORIES.get(mode, []):
		out.append(c)
	return out


## Теги категории: сначала по порядку из TAGS, затем остальные (found) в порядке появления
static func sort_tags(cat: StringName, found: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for t in TAGS.get(cat, []):
		if found.has(t):
			out.append(t)
	for t in found:
		if not out.has(t):
			out.append(t)
	return out


## Признаки, которые разрешены объекту категории (для lint)
static func allowed_facets(cat: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for spec in FACET_SPECS.get(cat, []):
		out.append(spec["id"])
	for f in EXTRA_FACETS:
		out.append(f)
	return out


## Фильтры категории для показа: [{"id", "title", "options": [{"id", "name"}]}]
static func filter_specs(cat: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for spec in FACET_SPECS.get(cat, []):
		var opts: Array[Dictionary] = []
		for o in spec["options"]:
			opts.append({"id": o, "name": spec.get("labels", {}).get(o, o)})
		out.append({"id": spec["id"], "title": spec.get("title", str(spec["id"])), "options": opts})
	return out


## Короткая сводка объекта для кнопки: подписи его значений фильтров через « · » (форма не входит)
static func facet_summary(cat: StringName, facets_of: Callable) -> String:
	var parts: Array[String] = []
	for spec in FACET_SPECS.get(cat, []):
		var v: String = facets_of.call(spec["id"])
		if v != "":
			parts.append(spec.get("labels", {}).get(v, v))
	return " · ".join(parts)
