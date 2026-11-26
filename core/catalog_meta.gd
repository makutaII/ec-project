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
	# XX claude-car CS1: road (ATTN_28). Категория car появится в build вместе с первой машиной (CS2), пока объектов нет
	&"build": [&"train", &"track", &"road", &"building", &"decor", &"terrain"],
	&"operate": [&"dc_controller", &"dcc_controller"],
	&"sections": [&"table"],   # XX claude-table T2: секции подмакетника, не категория Build
	&"coaster": [&"coaster_track", &"coaster_car"],   # XX claude-coaster C1, C3: ATTN_27, режим «горки»
}

const CATEGORIES := {
	&"train": {"name": "Trains", "icon": preload("res://ui/icons/transport/steam-locomotive.svg")},
	&"track": {"name": "Tracks", "icon": preload("res://ui/icons/transport/railway.svg")},
	# XX claude-car CS1: дороги и машины (ATTN_28). Иконки пока взяты из набора transport, свои нарисуем позже
	&"road": {"name": "Roads", "icon": preload("res://ui/icons/transport/rail-road.svg")},
	&"car": {"name": "Cars", "icon": preload("res://ui/icons/transport/mine-truck.svg")},
	&"building": {"name": "Building", "icon": preload("res://ui/icons/house/house.svg")},
	&"decor": {"name": "Decor", "icon": preload("res://ui/icons/house/beech.svg")},
	&"terrain": {"name": "Terrain", "icon": preload("res://ui/icons/tool/spade.svg")},
	# XX claude-table T1: секции подмакетника. Не входит в MODE_CATEGORIES[build]: секции ставит TableTool в режиме «Секции» (MODE_CATEGORIES[sections])
	&"table": {"name": "Table", "icon": preload("res://ui/icons/resize.svg")},
	# XX claude-coaster C1: траки горок. Не входит в MODE_CATEGORIES[build]: их ставят в режиме «Coaster»
	&"coaster_track": {"name": "Coaster Tracks", "icon": preload("res://ui/icons/transport/path-distance.svg")},
	&"coaster_car": {"name": "Coaster Cars", "icon": preload("res://ui/icons/transport/mine-wagon.svg")},   # XX claude-coaster C3
	&"dc_controller": {"name": "DC Controllers", "icon": preload("res://ui/icons/settings-knobs.svg")},
	&"dcc_controller": {"name": "DCC Controllers", "icon": preload("res://ui/icons/transport/steam-locomotive.svg")},
}

## Порядок тегов внутри категории. Теги, которых тут нет, идут после этих в порядке появления.
## "name" и "icon" необязательны: без них подпись это id тега, иконка у первого объекта
const TAGS := {
	&"train": [&"loco", &"boxcar", &"parts", &"consist"],
	&"track": [&"straight", &"curve", &"junction", &"special"],
	&"road": [&"straight", &"curve", &"ramp"],   # XX claude-car CS1, ramp: CS1c
	&"building": [&"house", &"mybuildings"],
	&"terrain": [&"foam", &"cut", &"field", &"relief", &"water", &"plaster", &"brush"],   # XX claude-terra 13.14: field (H1b), relief (H2)
	&"decor": [&"portal"],   # XX claude-terra 13.14 H7b
	&"table": [&"section"],
	&"coaster_car": [&"car"],   # XX claude-coaster C3
	&"coaster_track": [&"straight", &"slope", &"bank", &"flex"],   # XX claude-coaster C1: дальше slope, curve, vertical, bank, drive (ATTN_27 §27.4)
	&"dc_controller": [&"2d", &"3d", &"switch", &"wire"],
}

## Подписи и иконки тегов (необязательно): {category: {tag: {"name": String, "icon": Texture2D}}}.
## Пока пусто: подпись это id тега, иконка у первого объекта тега. Заполнять по мере появления иконок (U18)
const TAG_META := {
	&"decor": {   # XX claude-terra 13.14 H7b
		&"portal": {"name": "Порталы", "tooltip": "Портал тоннеля: арка входа в гору. Рельеф не меняет; рельсы с флагом U, портал задвинуть в гору. R/F уровень, G стиль, глубина в панели «Вид»"},
	},
	&"terrain": {   # XX claude-terra 13.14
		&"field": {"name": "Шпатлёвка", "tooltip": "Слой шпатлёвки на стол или лист: прямоугольник, полигон, вся столешница"},
		&"relief": {"name": "Рельеф", "tooltip": "Кисти рельефа: холм, гравий, скалы. Ctrl+колесо подъём и яма, ЛКМ выравнивание"},
	},
	&"train": {
		&"parts": {"name": "Составные", "tooltip": "Части составов по отдельности: паровоз, тендер, секции"},
		&"consist": {"name": "Составы", "tooltip": "Готовые составы: ставятся одной кнопкой. Свой состав: «Записать состав» во вкладке «Сведения»"},
	},
	&"building": {
		&"mybuildings": {"name": "Мои здания", "tooltip": "Здания игрока из генератора. Свои здания: Library, вкладка «Здания», «Сохранить»"},
	},
	&"coaster_track": {
		&"straight": {"name": "Прямые"},
		&"slope": {"name": "Подъёмы и спуски"},
		&"flex": {"name": "Гибкие", "tooltip": "Гибкий трак горок: свои пределы формы (поворот от 8, уклон до 35°)"},
		&"bank": {"name": "Крен", "tooltip": "Траки с креном: штопор (крен меняется вдоль трака) и вираж (крен постоянный). Стык требует совпадения крена"},
	},
	&"coaster_car": {
		&"car": {"name": "Вагоны"},
	},
	&"road": {   # XX claude-car CS1
		&"straight": {"name": "Прямые"},
		&"curve": {"name": "Повороты"},
		&"ramp": {"name": "Пандусы"},   # XX claude-car CS1c
	},
	&"track": {
		&"straight": {"name": "Прямые"},
		&"curve": {"name": "Радиусные"},
		&"junction": {"name": "Стрелки", "tooltip": "Стрелки и кроссы"},
		&"special": {"name": "Прочие"},
	},
}

## Фильтры категории: какие признаки (facets) объектов показывать и с какими значениями.
## Интерфейс фильтров делается в U3b, данные нужны уже сейчас для lint и выбора рамкой.
const FACET_SPECS := {
	# У траков фильтров нет: стиль это настройка сессии (TSM), а не признак кнопки (ATTN_17 §17.13)
}

## Признаки, допустимые у объекта, но не показываемые фильтрами (нужны для выбора рамкой и сводки на кнопке)
const EXTRA_FACETS := [&"shape", &"brush"]


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


## Сводка из паспорта обычного трака для второй строки кнопки: «36 · 30°», «23.9», «23.9 · уклон 0.5°».
## Пусто, если паспорта нет или это не обычный трак (стрелка, кросс, упор, flex)
static func passport_summary(setting: EntitySetting) -> String:
	for comp in setting.components:
		if comp is IdentitySetting and comp.object_config != null:
			var cfg = comp.object_config
			if cfg.get_script() != TrackConfig or cfg.radius <= 0.0:
				return ""
			var out: String = String.num(snappedf(cfg.radius, 0.01))
			if cfg.deg != 0.0:
				out += " · %s°" % String.num(snappedf(cfg.deg, 0.01))
			elif cfg.rise != 0.0:
				out += " · уклон %s°" % String.num(snappedf(cfg.rise, 0.01))
			return out
	return ""
