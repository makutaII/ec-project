class_name BuildingStore extends RefCounted

# XX claude-library L8 (новый файл)
########################
## BuildingStore. Здания игрока из генератора на диске (ATTN_22 §22.7.6, шаг L8)
########################
## JSON в user://library/buildings/<id>.json: {v, id, name, spec}, где spec это BuildingSpec.to_dict().
## Здание в макете хранит свой BuildingSpec внутри сущности (Entity.variant["building"]), поэтому файл нужен только
## каталогу «Мои здания» и Library: удаление файла макет не ломает. Папку можно подменить (тесты).
## Битый или пустой файл не роняет: предупреждение в Output и пропуск.
## Идентификатор идёт в имя файла, поэтому проверяется (ModelVariant.is_valid_id).

const DEFAULT_DIR := "user://library"
const BUILDINGS_DIR := "buildings"
const VERSION := 1


static func folder(dir: String = DEFAULT_DIR) -> String:
	return dir.path_join(BUILDINGS_DIR)


static func path_of(id: String, dir: String = DEFAULT_DIR) -> String:
	return folder(dir).path_join(id + ".json")


static func make_id() -> String:
	return ModelVariant.make_id()


## Записать здание. name пустое: «Здание». Недопустимый id: ERR_INVALID_PARAMETER
static func save(id: String, entry_name: String, spec: BuildingSpec, dir: String = DEFAULT_DIR) -> Error:
	if not ModelVariant.is_valid_id(id):
		push_warning("BuildingStore: недопустимый id здания '%s'" % id)
		return ERR_INVALID_PARAMETER
	var data := {"v": VERSION, "id": id, "name": entry_name if entry_name != "" else "Здание", "spec": spec.to_dict()}
	DirAccess.make_dir_recursive_absolute(folder(dir))
	var f := FileAccess.open(path_of(id, dir), FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_warning("BuildingStore: не удалось записать %s (код %d)" % [path_of(id, dir), err])
		return err
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return OK


## Запись {id, name, spec: BuildingSpec} или пустой словарь (нет файла, битый файл, недопустимый id)
static func load_entry(id: String, dir: String = DEFAULT_DIR) -> Dictionary:
	if not ModelVariant.is_valid_id(id):
		return {}
	var path := path_of(id, dir)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("BuildingStore: не удалось открыть %s (код %d)" % [path, FileAccess.get_open_error()])
		return {}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		push_warning("BuildingStore: %s: не JSON-словарь" % path)
		return {}
	var d: Dictionary = json.data
	var sd: Variant = d.get("spec")
	if not (sd is Dictionary):
		push_warning("BuildingStore: %s: нет поля spec" % path)
		return {}
	return {"id": id, "name": str(d.get("name", "Здание")), "spec": BuildingSpec.from_dict(sd as Dictionary)}


## Все здания игрока: порядок по имени, затем по id
static func list_all(dir: String = DEFAULT_DIR) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path := folder(dir)
	if not DirAccess.dir_exists_absolute(path):
		return out
	for fname in DirAccess.get_files_at(path):
		if not fname.ends_with(".json"):
			continue
		var e := load_entry(fname.get_basename(), dir)
		if not e.is_empty():
			out.append(e)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["name"] != b["name"]:
			return str(a["name"]) < str(b["name"])
		return str(a["id"]) < str(b["id"]))
	return out


static func delete(id: String, dir: String = DEFAULT_DIR) -> Error:
	if not ModelVariant.is_valid_id(id):
		return ERR_INVALID_PARAMETER
	var path := path_of(id, dir)
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	return DirAccess.remove_absolute(path)
