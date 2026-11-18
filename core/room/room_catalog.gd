class_name RoomCatalog extends RefCounted

########################
## Каталог комнат: id -> паспорт (RoomConfig). Комната в памяти одна (RoomBuilder.switch_room пересобирает её).
########################
## Источник один: карточка data/rooms/cards/<id>.tres (RoomConfig, id равен имени файла) со сценой в RoomConfig.scene
## (корень RoomRoot, data/models/room_<имя>/room_<имя>.tscn, рядом .glb: как у вагонов). Карточки читаются из одной папки, без вложенных
## (как data/<категория>/objects/ у объектов); в data/rooms лежит только cards/ (скрипты комнат в core/room/).
## Новая комната = новая карточка в cards/ и модель в data/models/room_<имя>/, кода менять не нужно. Карточка без сцены каталогом не читается.
## Процедурных комнат больше нет (ATTN_25 RM9b): детская, куб, стенд и мансарда лежат сценами.
## Комнаты dev_only (стенд, куб) игроку не показываются: entries(true) их пропускает. Проверка папки: validate().

const DEFAULT_ID := &"kid_room_10"
const ROOMS_DIR := "res://data/rooms"
const CARDS_DIR := "res://data/rooms/cards"
## Сцены и модели комнат: по одной папке на комнату, вид читается по префиксу room_ (как wagon_, loco_), data/models/README.md
const MODELS_DIR := "res://data/models"
const MODEL_PREFIX := "room_"

## Все комнаты для списков: [{id, title, tip, dev_only}]. Сначала комната по умолчанию, затем остальные карточки по алфавиту id.
## for_player: без комнат dev_only (список игрока при выборе комнаты в начале игры)
static func entries(for_player := false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for path in _card_paths():
		var id := StringName(path.get_file().get_basename())
		var c := _load_passport(id)
		if c == null:
			continue
		out.append({"id": id, "title": c.title if c.title != "" else String(id), "tip": c.tip, "dev_only": c.dev_only})
	var first := out.filter(func(d: Dictionary) -> bool: return d.id == DEFAULT_ID)
	var rest := out.filter(func(d: Dictionary) -> bool: return d.id != DEFAULT_ID)
	out.assign(first + rest)
	if for_player:
		out = out.filter(func(d: Dictionary) -> bool: return not d.dev_only)
	return out


## Имя модели комнаты: id с префиксом room_ (attic → room_attic; id, что уже начинается с room_, остаётся как есть)
static func model_id(id: StringName) -> String:
	var s := String(id)
	return s if s.begins_with(MODEL_PREFIX) else MODEL_PREFIX + s


## Папка и сцена модели комнаты: data/models/room_<имя>/room_<имя>.tscn
static func model_dir(id: StringName) -> String:
	return "%s/%s" % [MODELS_DIR, model_id(id)]


static func scene_path(id: StringName) -> String:
	return "%s/%s.tscn" % [model_dir(id), model_id(id)]


## true: комната тестовая (игроку не показывается). Неизвестный id: false
static func is_dev_only(id: StringName) -> bool:
	for e in entries():
		if e.id == id:
			return e.dev_only
	return false


static func has(id: StringName) -> bool:
	return ResourceLoader.exists(_passport_path(id))


static func _passport_path(id: StringName) -> String:
	return "%s/%s.tres" % [CARDS_DIR, id]


## Пути карточек data/rooms/cards/*.tres (без вложенных папок), по алфавиту. В экспорте файлы могут стоять как .tres.remap
static func _card_paths(cards_dir := CARDS_DIR) -> PackedStringArray:
	var out := PackedStringArray()
	var base := cards_dir + "/"
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


## Карточка из cards/ (общий ресурс, не менять). null: файла нет или в нём нет сцены
static func _load_passport(id: StringName) -> RoomConfig:
	var path := _passport_path(id)
	if not ResourceLoader.exists(path):
		return null
	var c := load(path) as RoomConfig
	if c == null or c.scene == null:
		return null
	return c


## Проверка папки комнат: список проблем (пусто: всё в порядке). Зовут tests/room_catalog_test.tscn и tests/catalog_lint.gd.
## cards_dir другой (только тест на плохих карточках): проверки старого места и комнаты по умолчанию пропускаются
static func validate(cards_dir := CARDS_DIR) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for path in _card_paths(cards_dir):
		var file_id := path.get_file().get_basename()
		var c := load(path) as RoomConfig
		if c == null:
			out.append("%s: это не RoomConfig" % path)
			continue
		if String(c.id) != file_id:
			out.append("%s: id '%s' не равен имени файла" % [path, c.id])
		if seen.has(c.id):
			out.append("%s: id '%s' уже у %s" % [path, c.id, seen[c.id]])
		seen[c.id] = path
		if c.scene == null:
			out.append("%s: нет сцены (карточка без сцены каталогом не читается)" % path)
		else:
			var sp := c.scene.resource_path
			var folder := sp.get_base_dir().get_file()
			if sp.get_base_dir().get_base_dir() != MODELS_DIR or not folder.begins_with(MODEL_PREFIX) \
					or sp.get_file() != folder + ".tscn":
				out.append("%s: сцена %s, ожидается %s/%s<имя>/%s<имя>.tscn" % [path, sp, MODELS_DIR, MODEL_PREFIX, MODEL_PREFIX])
		if c.title == "":
			out.append("%s: пустое название" % path)
	if cards_dir != CARDS_DIR:
		return out
	# В data/rooms только cards/: сцены в data/models/room_*, скрипты в core/room/
	for dn in DirAccess.get_directories_at(ROOMS_DIR):
		if dn != "cards":
			out.append("%s/%s: лишняя папка, карточки в cards/, сцены в %s/" % [ROOMS_DIR, dn, MODELS_DIR])
	for f in DirAccess.get_files_at(ROOMS_DIR):
		out.append("%s/%s: лишний файл, в data/rooms только cards/ (скрипты в core/room/)" % [ROOMS_DIR, f])
	if not has(DEFAULT_ID):
		out.append("комнаты по умолчанию '%s' нет в каталоге" % DEFAULT_ID)
	return out


## Новый паспорт по id (свой экземпляр: общий ресурс карточки не меняется). Неизвестный id: комната по умолчанию
static func make(id: StringName) -> RoomConfig:
	var passport := _load_passport(id)
	if passport == null:
		passport = _load_passport(DEFAULT_ID)
		id = DEFAULT_ID
	if passport == null:
		push_error("RoomCatalog: нет комнаты по умолчанию '%s' (data/rooms/cards/)" % DEFAULT_ID)
		return RoomConfig.new()
	var c := passport.duplicate() as RoomConfig
	c.id = id
	return c
