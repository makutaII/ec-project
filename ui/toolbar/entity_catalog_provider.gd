class_name EntityCatalogProvider extends CatalogProvider

###########################
## EntityCatalogProvider. Каталог объектов из .tres (EntitySetting)
###########################
## Заменяет данные и словари, которые раньше держал UIGenerator и два контроллера (category_list).
## Какие категории у режима, их порядок и иконки: CatalogMeta. Порядок тегов: CatalogMeta.TAGS.
## Порядок объектов в теге: EntitySetting.sort_order, при равных по имени файла (как было до U3a).
##
## Объекты загружаются один раз на запуск (кэш), провайдеры разных режимов делят его.

## Загруженные объекты, общие для всех провайдеров
static var _cache: Array[EntitySetting] = []
static var _loaded := false

var mode: StringName
var _obj_btn_scene := preload("res://ui/buttons/object_button.tscn")
## category -> tag -> Array[EntitySetting]
var _data := {}


func _init(for_mode: StringName) -> void:
	mode = for_mode
	_build_data(load_all())


## Все объекты из Global.object_dirs. Объект с пустым или повторным key пропускается с ошибкой (проверка U3a)
static func load_all() -> Array[EntitySetting]:
	if _loaded:
		return _cache
	_loaded = true
	var seen := {}
	for dir in Global.object_dirs:
		for path in list_resources(dir):
			var res := load(path) as EntitySetting
			if res == null:
				continue   # другой тип ресурса (например DCControllerSetting): не объект каталога
			var k := res.get_key()
			if res.key == &"":
				push_warning("Catalog: у %s нет key, временный ключ %s" % [path, k])
			if seen.has(k):
				push_error("Catalog: повтор key '%s' (%s и %s), второй пропущен" % [k, seen[k], path])
				continue
			seen[k] = path
			_cache.append(res)
	return _cache


## Пути к .tres в папке. ResourceLoader.list_directory работает и в экспортированной игре (DirAccess там
## видит .remap и .import вместо ресурсов). Запасной вариант: DirAccess
static func list_resources(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var base := dir if dir.ends_with("/") else dir + "/"
	var names := ResourceLoader.list_directory(base)
	if names.is_empty():
		names = DirAccess.get_files_at(base)
	for n in names:
		if n.ends_with(".tres"):
			out.append(base + n)
		elif n.ends_with(".tres.remap"):
			out.append(base + n.trim_suffix(".remap"))
	out.sort()
	return out


func _build_data(objects: Array[EntitySetting]) -> void:
	_data.clear()
	for obj in objects:
		if obj.hide:
			continue   # скрыт в каталоге (файл остаётся: на него могут ссылаться сейвы и тесты)
		if not _data.has(obj.category):
			_data[obj.category] = {}
		if not _data[obj.category].has(obj.tag):
			_data[obj.category][obj.tag] = []
		_data[obj.category][obj.tag].append(obj)
	for cat in _data:
		for tag in _data[cat]:
			_data[cat][tag].sort_custom(_sort_objects)


static func _sort_objects(a: EntitySetting, b: EntitySetting) -> bool:
	if a.sort_order != b.sort_order:
		return a.sort_order < b.sort_order
	return a.resource_path < b.resource_path


func get_categories() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cat in CatalogMeta.categories_for_mode(mode):
		out.append(CatalogMeta.category_info(cat))
	return out


func get_tags(category: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tags: Array = _data.get(category, {}).keys()
	var only := CatalogMeta.mode_tags(mode, category)   # XX claude-wire W3
	if not only.is_empty():
		tags = tags.filter(func(t) -> bool: return only.has(t))
	if not _consists(category).is_empty():
		tags.append(ConsistSetting.TAG)
	if not _my_buildings(category).is_empty():
		tags.append(BuildingPresetSetting.TAG)   # XX claude-library L8
	for tag in CatalogMeta.sort_tags(category, tags):
		var tag_name: String = CatalogMeta.tag_info(category, tag).get("name", str(tag))
		out.append({"id": tag, "name": tag_name, "icon": _tag_icon(category, tag), "tooltip": CatalogMeta.tag_info(category, tag).get("tooltip", "")})
	return out


## Фильтры тега: только те, чьи признаки есть хотя бы у одного объекта тега
func get_filters(category: StringName, tag: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var items: Array = _items(category, tag)
	for spec in CatalogMeta.filter_specs(category):
		for item in items:
			if item.get_facet(spec["id"]) != "":
				out.append(spec)
				break
	return out


## Кнопки объектов, прошедших фильтры. Нажатие: on_pressed.call(setting)
func create_buttons(category: StringName, tag: StringName, on_pressed: Callable, filters: Dictionary = {}) -> Array[Button]:
	var out: Array[Button] = []
	for item in _items(category, tag):
		if not _passes(item, filters):
			continue
		var btn: ObjectButton = _obj_btn_scene.instantiate()
		btn.config(item)
		if on_pressed.is_valid():
			btn.btn_pressed_object_selected.connect(on_pressed)
		if item is ConsistSetting and item.is_user():
			ConsistButtonMenu.attach(btn, item, on_changed)
		out.append(btn)
	return out


static func _passes(item: EntitySetting, filters: Dictionary) -> bool:
	for f in filters:
		var want := str(filters[f])
		if want != "" and item.get_facet(f) != want:
			return false
	return true


## Иконка тега: из CatalogMeta, если задана, иначе у первого объекта тега (как было до U3a)
func _tag_icon(category: StringName, tag: StringName) -> Texture2D:
	var meta_icon: Texture2D = CatalogMeta.tag_info(category, tag).get("icon", null)
	if meta_icon != null:
		return meta_icon
	var items: Array = _items(category, tag)
	return items[0].icon if not items.is_empty() else null


## Объекты тега: из .tres, для тега «Составы» кнопки шаблонов
func _items(category: StringName, tag: StringName) -> Array:
	if tag == ConsistSetting.TAG:
		return _consists(category)
	if tag == BuildingPresetSetting.TAG:
		return _my_buildings(category)   # XX claude-library L8
	return _data.get(category, {}).get(tag, [])


## Кнопки шаблонов составов (категория train режима стройки). Читаются при каждом обращении,
## поэтому только что записанный состав появляется без перезапуска игры
func _consists(category: StringName) -> Array:
	var out: Array = []
	if category != &"train" or not CatalogMeta.categories_for_mode(mode).has(category):
		return out
	var by_key := {}
	for obj in load_all():
		by_key[obj.get_key()] = obj
	for tpl in ConsistStore.load_all():
		var s := ConsistSetting.from_template(tpl, by_key)
		if s != null:
			out.append(s)
	return out


## XX claude-library L8. Кнопки «Мои здания» (категория building режима стройки). Читаются при каждом обращении,
## поэтому только что сохранённое в Library здание появляется без перезапуска игры
func _my_buildings(category: StringName) -> Array:
	var out: Array = []
	if category != &"building" or not CatalogMeta.categories_for_mode(mode).has(category):
		return out
	var entries := BuildingStore.list_all()
	if entries.is_empty():
		return out
	var base: EntitySetting = null
	for obj in load_all():
		if obj.get_key() == BuildingGenSetting.OBJECT_KEY:
			base = obj
			break
	if base == null:
		return out
	for entry in entries:
		var s := BuildingPresetSetting.from_entry(entry, base)
		if s != null:
			out.append(s)
	return out
