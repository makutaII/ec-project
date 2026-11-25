@tool
extends EditorScript

###########################
## Проверка каталога объектов (U3a). Запуск: открыть файл, File → Run (Ctrl+Shift+X)
###########################
## Ищет: пустые и повторные `key`, key не по схеме `категория.тег.вариант`, объекты без иконки,
## неизвестные фасеты и значения (CatalogMeta.FACET_SPECS), категории и теги, которых нет в CatalogMeta.
## Итог в Output: список проблем или «OK».
## Отдельным блоком «Library: ...» (не входит в проблемы): у объектов train и building нет паспорта Library
## (res://data/library/info/<key>.tres) или паспорт ссылается на несуществующий key (ATTN_22, шаг L0).
## Блок «Комнаты: ...»: карточки data/rooms/cards (RoomCatalog.validate, ATTN_25 RM3).

const DIRS := [
	"res://data/tracks/objects/",
	"res://data/trains/objects/",
	"res://data/buildings/objects/",
	"res://data/terrain/objects/",
	"res://data/table/objects/",
	"res://ui/dc_controllers/objects/",
	"res://data/power/objects/",
	"res://data/coaster/objects/",   # XX claude-coaster C0
	"res://data/roads/objects/",   # XX claude-car CS1
	"res://data/decor/objects/",   # XX claude-terra 13.14 H7b
]


func _run() -> void:
	# EntitySetting должен быть @tool: иначе в редакторе ресурсы это заглушки без методов (get_key, get_facet) и проверка молча врёт
	if not EntitySetting.new().has_method("get_key"):
		print("ОШИБКА: у EntitySetting нет методов в редакторе (нужен @tool в core/entity_setting.gd). Проверка не выполнена")
		return
	var problems: Array[String] = []
	var seen := {}
	var total := 0
	var objects: Array[Dictionary] = []   # XX claude-library L0: для проверки паспортов
	for dir in DIRS:
		for path in EntityCatalogProvider.list_resources(dir):
			var res := load(path) as EntitySetting
			if res == null:
				continue   # DCControllerSetting и прочее: не объект каталога
			total += 1
			problems.append_array(_check(path, res, seen))
			objects.append({"key": res.get_key(), "category": res.category, "path": path})
	print("Каталог: проверено объектов %d" % total)
	if problems.is_empty():
		print("OK: проблем нет")
	else:
		print("Проблем: %d" % problems.size())
		for p in problems:
			print("  - ", p)
	_report_passports(objects)
	_report_rooms()


# XX claude-library L0: паспорта Library (предупреждения, не проблемы каталога)
const PASSPORT_CATEGORIES := [&"train", &"building"]


func _report_passports(objects: Array[Dictionary]) -> void:
	var warns: Array[String] = []
	var keys := {}
	for o in objects:
		keys[o["key"]] = true
		if PASSPORT_CATEGORIES.has(o["category"]) and not ResourceLoader.exists(ModelInfo.path_for(o["key"])):
			warns.append("%s: нет паспорта Library (%s)" % [o["path"], ModelInfo.path_for(o["key"])])
	var checked := 0
	for path in EntityCatalogProvider.list_resources(ModelInfo.DIR):
		checked += 1
		var info := load(path) as ModelInfo
		if info == null:
			warns.append("%s: это не ModelInfo" % path)
		elif not keys.has(info.key):
			warns.append("%s: key '%s' нет в каталоге" % [path, info.key])
		elif path.get_file().get_basename() != String(info.key):
			warns.append("%s: имя файла не совпадает с key '%s'" % [path, info.key])
	print("Library: паспортов проверено %d, предупреждений %d" % [checked, warns.size()])
	for w in warns:
		print("  - ", w)


## Карточки комнат (ATTN_25 RM3): data/rooms/cards/*.tres. Проверки те же, что в tests/room_catalog_test.tscn
func _report_rooms() -> void:
	# RoomConfig должен быть @tool, иначе в редакторе поля карточки недоступны
	if not "dev_only" in RoomConfig.new():
		print("ОШИБКА: у RoomConfig нет полей в редакторе (нужен @tool в setting/room_config.gd). Проверка комнат не выполнена")
		return
	var problems := RoomCatalog.validate()
	print("Комнаты: карточек в каталоге %d, проблем %d" % [RoomCatalog.entries().size(), problems.size()])
	for p in problems:
		print("  - ", p)


func _check(path: String, res: EntitySetting, seen: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if res.key == &"":
		out.append("%s: пустой key (сейчас временный %s)" % [path, res.get_key()])
	var k := res.get_key()
	if seen.has(k):
		out.append("%s: key '%s' уже у %s" % [path, k, seen[k]])
	else:
		seen[k] = path
	var parts := str(k).split(".")
	if parts.size() < 3:
		out.append("%s: key '%s' не по схеме категория.тег.вариант" % [path, k])
	elif parts[0] != str(res.category) or parts[1] != str(res.tag):
		out.append("%s: key '%s' не совпадает с category '%s' и tag '%s'" % [path, k, res.category, res.tag])
	if res.icon == null:
		out.append("%s: нет иконки" % path)

	var allowed := CatalogMeta.allowed_facets(res.category)
	for f in res.facets:
		if not allowed.has(StringName(str(f))):
			out.append("%s: неизвестный фасет '%s' для категории %s" % [path, f, res.category])
	for spec in CatalogMeta.FACET_SPECS.get(res.category, []):
		var v := res.get_facet(spec["id"])
		if v != "" and not (spec["options"] as Array).has(v):
			out.append("%s: фасет %s = '%s', допустимо %s" % [path, spec["id"], v, spec["options"]])

	if not CatalogMeta.CATEGORIES.has(res.category):
		out.append("%s: категории %s нет в CatalogMeta.CATEGORIES" % [path, res.category])
	# Числовой id удалён (ATTN_17 §17.13, C14): в основном ресурсе .tres объекта строки `id = N` быть не должно
	var _text := FileAccess.get_file_as_string(path)
	var _main := _text.rfind("[resource]")
	if _main >= 0 and RegEx.create_from_string("(?m)^id = \\d+").search(_text, _main) != null:
		out.append("%s: осталась строка id = N, числового id больше нет: объект узнают по key" % path)
	if CatalogMeta.TAGS.has(res.category) and not (CatalogMeta.TAGS[res.category] as Array).has(res.tag):
		out.append("%s: тега '%s' нет в CatalogMeta.TAGS[%s]" % [path, res.tag, res.category])
	# Траки: стиль даёт сессия (TSM), во вложенном стиле объекта его не опознать (ATTN_17 §17.13)
	if res.category == &"track":
		for comp in res.components:
			var st = comp.get("style") if comp != null else null
			if st is TrackStyle and (st.resource_path == "" or st.resource_path.contains("::")):
				out.append("%s: вложенный стиль в %s: оставьте поле style пустым (стиль сессии) или ссылкой на файл из data/tracks/styles/" % [path, comp.get_script().resource_path.get_file()])
	return out
