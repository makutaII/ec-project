extends Node

# XX claude-library L8 (новый файл)
## Проверка шага L8 (ATTN_22 §22.7.6): хранилище зданий игрока, обёртка каталога «Мои здания», область «Здания».
## Запуск: открыть tests/building_store_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Building store: n/m». Сцена закрывается сама с кодом 0 (всё прошло) или 1.
## Файлы пишутся в user://building_store_test и удаляются в конце.

const TMP := "user://building_store_test"

var _ok := 0
var _all := 0


func _ready() -> void:
	_clean()
	_test_store()
	_test_preset()
	await _test_entity_from_preset()
	await _test_workspace()
	_clean()
	print("Building store: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _check(label: String, cond: bool, detail := "") -> void:
	_all += 1
	if cond:
		_ok += 1
	print("%s %s %s" % ["PASS" if cond else "FAIL", label, detail])


func _clean() -> void:
	var folder := BuildingStore.folder(TMP)
	if DirAccess.dir_exists_absolute(folder):
		for f in DirAccess.get_files_at(folder):
			DirAccess.remove_absolute(folder.path_join(f))
		DirAccess.remove_absolute(folder)
	if DirAccess.dir_exists_absolute(TMP):
		DirAccess.remove_absolute(TMP)


# --- хранилище ---

func _test_store() -> void:
	var spec := BuildingSpec.from_dict({"shape": "l", "width": 12.0, "depth": 9.0, "floors": 3, "style": "stone", "seed": 321})
	var id_a := BuildingStore.make_id()
	_check("store: make_id допустим", ModelVariant.is_valid_id(id_a))
	_check("store: запись здания", BuildingStore.save(id_a, "Бета", spec, TMP) == OK)
	var e := BuildingStore.load_entry(id_a, TMP)
	_check("store: чтение даёт то же здание и имя", not e.is_empty() and (e["spec"] as BuildingSpec).equals(spec) and e["name"] == "Бета")

	var id_b := id_a + "x"
	_check("store: вторая запись", BuildingStore.save(id_b, "Альфа", BuildingSpec.new().sanitize(), TMP) == OK)
	var id_c := id_a + "y"
	BuildingStore.save(id_c, "", BuildingSpec.new().sanitize(), TMP)
	var all := BuildingStore.list_all(TMP)
	_check("store: список по имени (Альфа, Бета, Здание)", all.size() == 3 and all[0]["name"] == "Альфа" and all[1]["name"] == "Бета" and all[2]["name"] == "Здание",
		str(all.map(func(x: Dictionary) -> String: return x["name"])))

	_check("store: недопустимый id не пишется", BuildingStore.save("../evil", "x", spec, TMP) == ERR_INVALID_PARAMETER)
	_check("store: недопустимый id не читается и не удаляется", BuildingStore.load_entry("../evil", TMP).is_empty()
		and BuildingStore.delete("../evil", TMP) == ERR_INVALID_PARAMETER)

	# битые файлы не роняют
	var folder := BuildingStore.folder(TMP)
	var bad := FileAccess.open(folder.path_join("broken.json"), FileAccess.WRITE)
	bad.store_string("{не json")
	bad.close()
	var nospec := FileAccess.open(folder.path_join("nospec.json"), FileAccess.WRITE)
	nospec.store_string(JSON.stringify({"v": 1, "id": "nospec", "name": "без spec"}))
	nospec.close()
	var empty := FileAccess.open(folder.path_join("empty.json"), FileAccess.WRITE)
	empty.close()
	_check("store: битый, пустой и без spec пропускаются", BuildingStore.list_all(TMP).size() == 3 and BuildingStore.load_entry("broken", TMP).is_empty())

	# новые поля будущей версии не ломают чтение
	var fut := BuildingSpec.from_dict({"floors": 2, "future_field": "x"})
	BuildingStore.save("future", "Из будущего", fut, TMP)
	var fe := BuildingStore.load_entry("future", TMP)
	_check("store: неизвестное поле spec сохраняется при записи", (fe["spec"] as BuildingSpec).to_dict().get("future_field") == "x")

	_check("store: удаление", BuildingStore.delete(id_b, TMP) == OK and BuildingStore.load_entry(id_b, TMP).is_empty())
	_check("store: повторное удаление: файла нет", BuildingStore.delete(id_b, TMP) == ERR_FILE_NOT_FOUND)
	_check("store: нет папки: пустой список", BuildingStore.list_all("user://нет_такой_папки").is_empty())


# --- обёртка каталога ---

func _test_preset() -> void:
	var base := load("res://data/buildings/objects/building_gen.tres") as EntitySetting
	var spec := BuildingSpec.from_dict({"width": 9.0, "depth": 8.0, "floors": 3})
	var entry := {"id": "abc123", "name": "Мой дом", "spec": spec}
	var p := BuildingPresetSetting.from_entry(entry, base)
	_check("preset: ключ, категория и тег", p != null and p.get_key() == &"building.mine.abc123" and p.category == &"building" and p.tag == BuildingPresetSetting.TAG)
	_check("preset: имя и иконка как у генератора", p != null and p.name == "Мой дом" and p.icon == base.icon and p.base == base)
	_check("preset: исполнение несёт здание целиком", p != null and BuildingSpec.from_variant(p.make_variant()).equals(spec))
	var v1 := p.make_variant()
	v1["building"]["floors"] = 1
	_check("preset: исполнения независимы", BuildingSpec.from_variant(p.make_variant()).floors == 3)
	_check("preset: нет генератора в каталоге: кнопки нет", BuildingPresetSetting.from_entry(entry, null) == null)
	_check("каталог: тег «Мои здания» зарегистрирован", (CatalogMeta.TAGS[&"building"] as Array).has(BuildingPresetSetting.TAG)
		and CatalogMeta.tag_info(&"building", BuildingPresetSetting.TAG).get("name") == "Мои здания")
	_check("каталог: ключ генератора в BuildingGenSetting и в .tres один", base.get_key() == BuildingGenSetting.OBJECT_KEY)


# --- здание из кнопки «Мои здания» ---

func _test_entity_from_preset() -> void:
	var base := load("res://data/buildings/objects/building_gen.tres") as EntitySetting
	var spec := BuildingSpec.from_dict({"shape": "l", "width": 12.0, "depth": 9.0, "floors": 3, "seed": 9})
	var p := BuildingPresetSetting.from_entry({"id": "t1", "name": "T", "spec": spec}, base)
	var factory := EntityFactory.new()
	add_child(factory)
	# как ToolController.select_build_object: setting = base, variant = make_variant
	var ent := factory.create_from_setting(p.base, &"", p.make_variant())
	add_child(ent)
	await get_tree().process_frame
	var gen := ent.get_comp(C_BuildingGen) as C_BuildingGen
	_check("кнопка: здание построено по spec из кнопки", gen != null and gen.spec.equals(spec))
	ent.queue_free()
	factory.queue_free()


# --- область «Здания» ---

func _test_workspace() -> void:
	var ws = load("res://core/library/workspace/building.gd").new()
	add_child(ws)
	await get_tree().process_frame
	_check("область: интерфейс строится без экрана", ws.id == &"building" and ws.title == "Здания")
	var v := {}
	ws.extend_variant(v)
	_check("область: без генератора исполнение не меняется", v.is_empty())
	_check("область: готовые здания заданы и допустимы", _presets_ok(ws))
	ws.queue_free()


func _presets_ok(ws: Node) -> bool:
	var presets: Array = ws.PRESETS
	if presets.is_empty():
		return false
	for pr in presets:
		var sp := BuildingSpec.from_dict(pr["spec"])
		var lay := BuildingLayout.build(sp)
		var res := BuildingBuilder.build(lay)
		if int(res["vertices"]) == 0 or lay.openings.is_empty():
			return false
		if str(pr["spec"].get("shape", "rect")) == "l" and not sp.is_l():
			return false
	return true
