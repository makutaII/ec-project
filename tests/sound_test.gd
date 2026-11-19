extends Node

## Проверка звука этапа 1 (ATTN_26 S1.0-S1.2): шины, профиль, поиск файлов, петли, расстановка голосов, стыки.
## Запуск: открыть tests/sound_test.tscn и нажать F6. Итог в Output: строки PASS/FAIL и «Sound: n/m».
## Звуковые файлы не нужны: тест работает без data/sounds, поток для петель и стыков собирается кодом.

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_buses()
	_test_profile()
	_test_streams()
	await _test_voices()
	await _test_clicks()
	print("Sound: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _test_buses() -> void:
	for n in [&"World", &"UI", &"Music", &"Ambience"]:
		_check("Шины: %s есть" % n, AudioServer.get_bus_index(n) != -1)
	_check("Шины: шина мира это World", SND.world_bus == &"World")


func _test_profile() -> void:
	var loco := SoundProfile.make_default(true)
	var wagon := SoundProfile.make_default(false)
	_check("Профиль: у вагона качение тише, чем у локо", wagon.roll_gain_db < loco.roll_gain_db)
	_check("Профиль: по умолчанию три варианта стыка и петля качения",
		loco.joint_clicks.size() == 3 and loco.roll_loop == &"roll_loop")
	_check("Профиль: папка звуков data/sounds", loco.folder == "res://data/sounds")


func _test_streams() -> void:
	_check("Файлы: нет файла, null и без ошибки", SND.load_stream("res://data/sounds", &"no_such_file_x", true) == null)
	_check("Файлы: пустое имя, null", SND.load_stream("res://data/sounds", &"", false) == null)
	var w := _make_stream()
	SND.apply_loop(w, true)
	_check("Петля: WAV зациклен на весь файл (loop_end = 8000 кадров)",
		w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_begin == 0 and w.loop_end == 8000)
	SND.apply_loop(w, false)
	_check("Петля: выключение возвращает LOOP_DISABLED", w.loop_mode == AudioStreamWAV.LOOP_DISABLED)
	var ogg := AudioStreamOggVorbis.new()
	SND.apply_loop(ogg, true)
	_check("Петля: OGG зациклен флагом loop", ogg.loop)


func _test_voices() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.global_position = Vector3.ZERO
	var comps: Array[C_Sound] = []
	for i in 20:
		comps.append(_spawn(Vector3(float(i) * 2.0 + 1.0, 0, 0)))
	await get_tree().process_frame
	SND.rebalance()
	var near_ok := true
	for i in 12:
		near_ok = near_ok and comps[i].audible
	var far_ok := true
	for i in range(12, 20):
		far_ok = far_ok and not comps[i].audible
	_check("Голоса: слышимых ровно %d (лимит SND)" % SND.max_roll_voices, SND.audible_count == SND.max_roll_voices)
	_check("Голоса: слышимы 12 ближайших к камере, остальные молчат", near_ok and far_ok)

	cam.global_position = Vector3(38.0, 0, 0)
	SND.rebalance()
	_check("Голоса: камера переехала, слышимыми стали ближайшие к новой точке", comps[19].audible and not comps[0].audible)

	var far := _spawn(Vector3(500.0, 0, 0))
	SND.rebalance()
	_check("Голоса: дальше max_distance сущность не слышима", not far.audible)

	var before := SND.registered_count
	comps[0].entity.free()
	await get_tree().process_frame
	_check("Голоса: удалённая сущность снимается с учёта", SND.registered_count == before - 1)

	for c in comps:
		if is_instance_valid(c) and is_instance_valid(c.entity):
			c.entity.queue_free()
	if is_instance_valid(far.entity):
		far.entity.queue_free()
	cam.queue_free()
	await get_tree().process_frame


func _test_clicks() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var c := _spawn(Vector3(3, 0, 0))
	c._click_streams.append(_make_stream())
	await get_tree().process_frame
	SND.rebalance()
	_check("Стыки: рядом с камерой сущность слышима", c.audible)

	var base := c.entity.get_child_count()
	c.on_rail_joint({"bogie": 0, "kind": &"track", "strength": 1.0})
	_check("Стыки: на стык создан один источник", c.entity.get_child_count() == base + 1)
	c.on_rail_joint({"bogie": 1, "kind": &"track", "strength": 1.0})
	_check("Стыки: второй стык сразу следом отсекает пауза (cooldown)", c.entity.get_child_count() == base + 1)

	c._click_cd = 0.0
	c.audible = false
	c.on_rail_joint({"bogie": 0, "kind": &"track", "strength": 1.0})
	_check("Стыки: неслышимая сущность стыки не играет", c.entity.get_child_count() == base + 1)

	c.audible = true
	var empty := _spawn(Vector3(4, 0, 0))
	empty.audible = true
	var empty_base := empty.entity.get_child_count()
	empty.on_rail_joint({"bogie": 0, "kind": &"track", "strength": 1.0})
	_check("Стыки: нет файлов, событие обходится без ошибок и без источников", empty.entity.get_child_count() == empty_base)

	SND.reset_click_budget()
	var passed := 0
	for i in 100:
		if SND.allow_click():
			passed += 1
	_check("Стыки: бюджет пускает max_clicks_per_sec ударов в секунду", passed == SND.max_clicks_per_sec)
	SND.reset_click_budget()

	c.entity.queue_free()
	empty.entity.queue_free()
	cam.queue_free()
	await get_tree().process_frame


## Сущность с одним C_Sound на заданном месте. Без C_Chassis: качения нет, голоса и стыки работают
func _spawn(pos: Vector3) -> C_Sound:
	var e := Entity.new()
	var c := C_Sound.new()
	c.name = "C_Sound"
	e.add_component(c)
	add_child(e)
	e.global_position = pos
	return c


## WAV 8000 Гц, 1 с, 16 бит, моно, тишина (звука нет, нужен поток)
func _make_stream() -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 8000
	w.stereo = false
	var data := PackedByteArray()
	data.resize(8000 * 2)
	w.data = data
	return w


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS ", title)
	else:
		print("FAIL ", title)
