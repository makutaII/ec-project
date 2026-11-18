extends Node

## ATTN_25 RM3: каталог комнат читает карточки из data/rooms/cards/. Запуск: открыть tests/room_catalog_test.tscn и нажать F6.
## Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: папка карточек чистая (RoomCatalog.validate), порядок и состав списка, dev_only (стенд и куб не видны игроку),
## сцена у всех четырёх комнат (attic, bench, kid_room_10, cube в data/models/room_*), и что validate() ловит плохие карточки
## (временные файлы в user://, в проект ничего не пишется).

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _ids(list: Array[Dictionary]) -> Array:
	return list.map(func(d: Dictionary) -> StringName: return d.id)


func _has_problem(problems: Array[String], part: String) -> bool:
	for p in problems:
		if part in p:
			return true
	return false


func _ready() -> void:
	print("== 1. Папка карточек data/rooms/cards")
	var problems := RoomCatalog.validate()
	check("validate: проблем нет", problems.is_empty(), str(problems))
	check("attic есть в каталоге", RoomCatalog.has(&"attic"))
	check("bench есть в каталоге", RoomCatalog.has(&"bench"))
	check("несуществующей комнаты нет", not RoomCatalog.has(&"no_such_room"))

	print("== 2. Список комнат")
	var all := RoomCatalog.entries()
	var ids := _ids(all)
	var seen := {}
	var dup_ids := 0
	for id in ids:
		if seen.has(id):
			dup_ids += 1
		seen[id] = true
	check("id не повторяются", dup_ids == 0, str(ids))
	for id in [&"kid_room_10", &"cube", &"bench", &"attic"]:
		check("в списке есть %s" % id, ids.has(id))
	check("комната по умолчанию первая", ids[0] == RoomCatalog.DEFAULT_ID, str(ids))
	for e in all:
		check("у '%s' есть название" % e.id, String(e.title) != "")

	print("== 3. dev_only")
	check("bench: dev_only", RoomCatalog.is_dev_only(&"bench"))
	check("cube: dev_only", RoomCatalog.is_dev_only(&"cube"))
	check("attic: не dev_only", not RoomCatalog.is_dev_only(&"attic"))
	check("kid_room_10: не dev_only", not RoomCatalog.is_dev_only(&"kid_room_10"))
	check("неизвестная: не dev_only", not RoomCatalog.is_dev_only(&"no_such_room"))
	var player := _ids(RoomCatalog.entries(true))
	check("игроку не видны bench и cube", not player.has(&"bench") and not player.has(&"cube"), str(player))
	check("игроку видны kid_room_10 и attic", player.has(&"kid_room_10") and player.has(&"attic"), str(player))

	print("== 4. Карточки и сцены")
	var attic := RoomCatalog.make(&"attic")
	var bench := RoomCatalog.make(&"bench")
	check("attic: сцена из карточки", attic.scene != null and attic.id == &"attic", str(attic.scene))
	check("attic: сцена в data/models/room_attic", attic.scene != null and attic.scene.resource_path == RoomCatalog.scene_path(&"attic"),
			attic.scene.resource_path if attic.scene else "")
	check("bench: сцена в data/models/room_bench", bench.scene != null and bench.scene.resource_path == "res://data/models/room_bench/room_bench.tscn")
	check("model_id: attic → room_attic", RoomCatalog.model_id(&"attic") == "room_attic")
	check("model_id: префикс не дублируется", RoomCatalog.model_id(&"room_test_01") == "room_test_01")
	check("scene_path", RoomCatalog.scene_path(&"attic") == "res://data/models/room_attic/room_attic.tscn")
	check("bench: сцена из карточки, dev_only", bench.scene != null and bench.dev_only)
	var kid := RoomCatalog.make(&"kid_room_10")
	var cube := RoomCatalog.make(&"cube")
	check("kid_room_10: сцена в data/models/room_kid_room_10", kid.scene != null and kid.scene.resource_path == "res://data/models/room_kid_room_10/room_kid_room_10.tscn",
			kid.scene.resource_path if kid.scene else "")
	check("cube: сцена в data/models/room_cube, dev_only", cube.scene != null and cube.scene.resource_path == "res://data/models/room_cube/room_cube.tscn" and cube.dev_only)
	check("make даёт свой экземпляр, не общий ресурс", kid != RoomCatalog.make(&"kid_room_10"))
	check("все комнаты каталога со сценой", RoomCatalog.entries().all(func(d: Dictionary) -> bool: return RoomCatalog.make(d.id).scene != null))
	check("неизвестный id: комната по умолчанию", RoomCatalog.make(&"no_such_room").id == RoomCatalog.DEFAULT_ID)

	print("== 5. validate ловит плохие карточки (user://)")
	var dir := "user://room_cards_test"
	DirAccess.make_dir_recursive_absolute(dir)
	var written: Array[String] = []
	var no_scene := RoomConfig.new()
	no_scene.id = &"other"
	written.append(_save(no_scene, dir + "/foo.tres"))
	var wrong_path := RoomConfig.new()
	wrong_path.id = &"baz"
	wrong_path.title = "Baz"
	wrong_path.scene = load("res://data/scenes/gimbal.tscn") as PackedScene   # сцена вне data/models/room_*
	written.append(_save(wrong_path, dir + "/baz.tres"))
	var dup := RoomConfig.new()
	dup.id = &"baz"
	dup.title = "Dup"
	dup.scene = attic.scene
	written.append(_save(dup, dir + "/qux.tres"))
	var bad := RoomCatalog.validate(dir)
	check("id не равен имени файла", _has_problem(bad, "не равен имени файла"), str(bad))
	check("нет сцены", _has_problem(bad, "нет сцены"))
	check("сцена не там, где ожидается", _has_problem(bad, "ожидается"))
	check("повторный id", _has_problem(bad, "уже у"))
	for f in written:
		if f != "":
			DirAccess.remove_absolute(f)
	DirAccess.remove_absolute(dir)

	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)


func _save(c: RoomConfig, path: String) -> String:
	var err := ResourceSaver.save(c, path)
	check("временная карточка записана: %s" % path.get_file(), err == OK, "код %d" % err)
	return path if err == OK else ""
